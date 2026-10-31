# PostgreSQL Stage 6 (Import and Export) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Postgres tab, File ▸ Export… and File ▸ Import… work as they do on MySQL tabs:
- **Export:** export a database, schemas or selected tables as an **SQL dump** or **CSV**, and a Query-view
  result as CSV.
- **Import:** import an **SQL dump** (the app's own, or a plain-format `pg_dump` file) or a **CSV** file, mapped
  onto an existing table.

**Architecture:**
- **PostgresKit** gains COPY support (`COPY … TO STDOUT` / `FROM STDIN`).
- **Four data-layer classes, all without UI:**
  - `SPPostgresDumpReader` streams a dump file into statements, COPY data blocks and psql meta-commands.
  - `SPPostgresSQLImporter` runs them.
  - `SPPostgresDumpWriter` writes the app's own dump.
  - `SPPostgresCSV` exports and imports CSV.
- **Sheets:** an Export sheet, an Import options panel, a CSV column-mapping sheet and a progress sheet drive
  them.
- **Background jobs:** every job runs on a background thread on its **own connection** to the database, opened
  through the document's connection provider (the Stage 4 Users mechanism, generalised). So the window stays
  responsive, Cancel works, and a transaction the user has open in the Query view is never involved.

**Tech Stack:**
- Objective-C (MRC in app sources), AppKit built in code.
- PostgresKit over static libpq.
- Reused **unchanged** from the MySQL side: `SPFileHandle` (gzip/bzip2 reading and writing) and `SPCSVParser`.
- XCTest (ARC). Docker test servers: PG 12 on 55412 with `pg_dump` 12.22, PG 18 on 55418 with `pg_dump` 18.6.

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md`:
- Goals 15 and 16: export "a database, schemas or selected tables as an SQL dump or as CSV, from the File menu
  as in MySQL"; import "an SQL dump or a CSV file into the current database or table, from the File menu as in
  MySQL".
- Builder's calls, "SQL dumps": "Export writes a plain-SQL dump the app generates itself (schema, then data via
  `COPY … FROM stdin` blocks), so it needs no external `pg_dump` and works on any server version. Import accepts
  these files and plain-format `pg_dump` files, including their `COPY … FROM stdin` data blocks. Custom, directory
  and tar `pg_dump` formats are out of scope."
- Builder's calls, "CSV": "export a table or query result to CSV, and import CSV into an existing table with column
  mapping, mirroring MySQL's CSV import and export options (delimiter, quote, header row, NULL representation)".

These are amended by `docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`.

## Builder's decisions (the spec leaves these open)

### Dump contents and order
The dump mirrors `pg_dump`'s order, so it loads into an empty database in one pass and data loading never fires
triggers or trips foreign keys.

1. **Header.**
   - A comment naming the app, the server version, the database and the date.
   - Then `SET client_encoding = 'UTF8'`, `SET standard_conforming_strings = on`,
     `SET check_function_bodies = false`, and `SELECT pg_catalog.set_config('search_path', '', false)`.
2. **Schemas.** `CREATE SCHEMA IF NOT EXISTS` for each non-system schema in scope, except `public`.
3. **Extensions.** `CREATE EXTENSION IF NOT EXISTS "x" WITH SCHEMA "s"`.
   - A database export includes every extension but `plpgsql`.
   - A schema export includes the extensions installed in the exported schemas.
   - A table export includes none.
4. **Types.** Enums, composites, ranges and domains in the exported schemas, with extension members excluded
   (`pg_depend` deptype `e`).
5. **Functions and procedures.** These use `pg_get_functiondef`, with extension members excluded.
   - Functions with a SQL-standard body (`prosqlbody` not null, PG 14+) are written later, after the views,
     because they can reference tables.
6. **Sequences.** `CREATE SEQUENCE` with every option, including those owned by serial columns. Identity columns'
   sequences are skipped, since the table creates them.
7. **Tables.** Each table's own part from `SPPostgresCreateStatement` (see Task 3), without foreign keys,
   triggers or indexes. Then `ALTER SEQUENCE … OWNED BY` for serial sequences.
8. **Views and materialized views.** Ordered by their `pg_depend` dependencies on one another. Materialized views
   are created `WITH NO DATA`. Then the SQL-standard-body functions.
9. **Data.** One `COPY "s"."t" (cols…) FROM stdin;` block per table, filled with `COPY … TO STDOUT` text format
   and ended by `\.`.
   - Generated columns are left out of the column list.
   - Partitioned parents get no block; their partitions do.
10. **Sequence values.** `SELECT pg_catalog.setval('"s"."seq"', last_value, is_called);` for every exported
    sequence, identity sequences included.
11. **After the data.** Indexes, then foreign keys, then triggers (with their enable state), then
    `REFRESH MATERIALIZED VIEW` for the ones that were populated.
12. **Comments.** Comments on schemas, types, functions and sequences; table and column comments come with the
    tables.

Scope rules:
- **Selected tables** export only the tables plus their owned sequences, data, indexes, constraints and triggers.
  Trigger functions and referenced types are not included, as with `pg_dump -t`.
- **No DROP statements and no ownership or GRANTs.** Roles are not exported; objects are created as the importing
  user.
- **Data only:** the Export sheet's Structure/Data checkboxes can drop the structure parts (2–8 and 11) or the
  data parts (9–10).

### Export UI
- File ▸ Export… (⌘⇧E) opens a sheet with a Format choice: **SQL** or **CSV**.
- **Source** is one of:
  - Whole database;
  - Selected schemas (a checkbox list);
  - Selected tables (a checkbox list grouped by schema, preset to the sidebar's selected table);
  - **Query result** (CSV only), enabled when the Query view holds a result.
- **SQL options:** Structure ☑, Data ☑, and "Compress (gzip)" ☐, which writes `.sql.gz` through `SPFileHandle`.
- **CSV options:** Delimiter (`,` `;` Tab `|` or custom), Quote (`"`), Escape (`"` or `\`), "First row holds
  column names" ☑, and NULL as (empty by default).
- **One CSV file per table.** One table, or a query result, asks for a file. Several tables ask for a folder and
  write `<schema>.<table>.csv` each.
- **Table CSV** is produced by the server with `COPY (SELECT …) TO STDOUT WITH (FORMAT csv, …)`. A **query result**
  is written by the client from the rows the Query view already holds; the query is not re-run.
- **Snapshot:** the export connection runs `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY`, so the dump is one
  consistent snapshot, then `COMMIT`.
- **Cancel** stops the job and deletes the partly written file or files.

### Import UI
- File ▸ Import… (⌘⇧I) opens an open panel. Its accessory has:
  - Format: **SQL** or **CSV**, chosen from the extension (`.csv`/`.tsv` → CSV, anything else → SQL), and
    changeable;
  - for SQL: "Run in a single transaction" ☑;
  - for CSV: the CSV options above, plus encoding fixed to UTF-8 (a BOM is skipped).
  - `.gz` and `.bz2` files are read transparently.
- **SQL in a single transaction:** all or nothing. Any error rolls back everything, and the alert names the
  statement's line number with the server message.
- **SQL without a single transaction:** each statement commits on its own. On an error the user chooses **Stop**,
  **Ignore** or **Ignore All**, as MySQL's import asks.
- **psql meta-commands** between statements:
  - `\restrict …` and `\unrestrict …` (written by `pg_dump` 17.6+/18) are skipped.
  - `\.` ends a COPY block.
  - Any other meta-command (`\connect`, `\set`, `\i`, …) stops the import with "psql command “\connect” on line
    <n> can't be run here." In single-transaction mode that rolls back everything.
- **CSV:** after the open panel, a mapping sheet over the current database's tables. The target defaults to the
  sidebar's selected table.
  - It previews the first 10 rows.
  - Each table column gets a pop-up of the CSV's columns (header names, or "Column 1"…) plus "— Not imported —".
    Columns map by matching name (case-insensitive) first, then by position.
  - The CSV is parsed by `SPCSVParser` and sent with `COPY "s"."t" (mapped columns) FROM STDIN` (text format) in
    one transaction. An error rolls back and reports the server's message, which includes `COPY t, line N`.
- **Cancel** during an import rolls back the open transaction. In per-statement mode, what already committed
  stays.
- **After an import:** the sidebar reloads keeping its selection, and every pane is marked stale.

### Shared
- **Connections:** `SPPostgresDocument`'s `usersConnectionProvider` is renamed `connectionProvider` and used by
  Users, Export and Import (Stage 4 tests updated). Its default implementation is unchanged: a connector per
  database with the console logger attached.
- **Console logging:** `SPPostgresConsoleLogger` must take calls from the job's background thread by hopping to
  the main thread. COPY data is never logged, only the COPY statement.
- **Progress sheet** (`SPPostgresProgressSheet`): a title, a status line, a determinate bar and Cancel.
  - Export shows "Table 3 of 12: orders"; import shows bytes read of the file's size.
  - Status updates are throttled to about 10 per second.

## Global Constraints

- **Never break MySQL.**
  - `SPExportController`, `SPDataImport`, `SPFileHandle`, `SPCSVParser` and MySQL's menus are not modified.
  - Postgres tabs implement their own `export:` and `import:` actions, reached through the window's existing
    forwarding.
  - `importFromClipboard:` stays disabled on Postgres tabs.
- PostgreSQL **12 through 18**. Every data-layer test runs on both 55412 and 55418.
- **Quoting:** identifiers go through `SPPostgresQuoteIdentifier`, values through `SPPostgresQuoteLiteral` or `$n`
  parameters.
- **Never cascade:** no `CASCADE`, `DROP OWNED` or `REASSIGN OWNED` in app code.
- **Tests:**
  - Data-layer tests use their own databases, `pgkit_io_src` and `pgkit_io_dst` (created when missing, and
    emptied by dropping their non-system schemas and recreating `public` in setUp, test code only).
  - The source fixture is `PostgresTests/Fixtures/io_source.sql`, loaded into `pgkit_io_src` with
    `loadFixtureNamed:`. It contains:
    - schemas `public` and `"Sales Data"`;
    - an enum `mood`, a domain `posint` with a CHECK, and a composite type;
    - table `"Sales Data"."Orders 2026"`: an identity column, a serial column, a `mood` column, `jsonb`,
      `bytea`, `numeric(12,2)`, `text`, `timestamptz` and a generated column;
    - a self-referencing foreign key, and a second table with an FK to it;
    - a unique index and a partial index;
    - an audit trigger (plpgsql) that inserts into an `audit` table;
    - a view on a view, a populated materialized view, and an unpopulated one;
    - a partitioned table with two partitions;
    - a SQL-standard-body function (on PG 14+ only; the fixture's directive skips it on 12);
    - comments, and `citext` installed in `public`;
    - rows holding tabs, newlines, backslashes, `\N` as text, empty strings vs NULL, emoji and `'` and `"`;
    - a sequence advanced to 42.
  - `pg_dump` fixtures `PostgresTests/Fixtures/pgdump12.sql` and `pgdump18.sql` are generated once from
    `io_source.sql` with the container's own `pg_dump --format=plain --no-owner --no-privileges`, using
    `docker exec sp-pg12 pg_dump …` and `docker exec sp-pg18 pg_dump …`, and committed. A comment line at the top
    says how they were made. Tests never shell out to docker.
- **Tests and prefs:** never write `Favorites.plist`. Tests never persist into real prefs or the login keychain.
  Export tests write only into a temporary directory.
- **Code conventions:**
  - MRC in app sources; ARC in `Postgres Tests`.
  - Add files only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test`.
  - Exported classes and functions need `__attribute__((visibility("default")))`.
- **Test command:** `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests"
  -derivedDataPath build/DerivedData ARCHS=arm64`. Run `bash Scripts/pg-test-servers.sh up` first.
- **App build:** `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath
  build/DerivedData ARCHS=arm64 build`.
- **Agent sessions:**
  - Implementer sessions never launch the GUI app; the controller does the visual checks.
  - Never kill processes you didn't start.
  - Never touch the owner's untracked `start_clause.sh`; stage only your own files.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A real `pg_dump` file from PG 18**, with `\restrict`, `SET` lines, `$$` function bodies and COPY data full of
   tabs, backslashes and `\N`:
   - It imports into an empty database, and the result matches the source.
   - Pinned in Task 2 (`testImportsPgDump18AndPgDump12`).
2. **A table with an audit trigger and self-referencing foreign keys**, exported and imported:
   - Importing doesn't fire the trigger: the audit row count equals the source's, not doubled.
   - The FKs hold, and the sequences continue at the same values.
   - Pinned in Task 3 (`testRoundTripMatchesSource`).
3. **Cancel halfway**:
   - A single-transaction import leaves the database exactly as before.
   - An export leaves no partial file.
   - Pinned in Task 2 (`testCancelInSingleTransactionLeavesNothing`) and Task 3 (`testCancelDeletesPartialFile`).
4. **Awkward values and names**:
   - Values: tabs, newlines, backslashes, the text `\N`, empty string vs NULL, emoji, quotes.
   - Names: `"Sales Data"."Orders 2026"`.
   - They round-trip exactly through both the SQL dump and CSV.
   - Pinned in Task 3 (`testRoundTripMatchesSource`) and Task 4 (`testCSVRoundTripKeepsAwkwardValues`).
5. **The user has a transaction open in the Query view** and starts an import or export:
   - The job runs on its own connection, so the user's transaction is untouched.
   - The window stays responsive, since the job is on a background thread.
   - Pinned in Task 5 (`testExportUsesItsOwnConnection`) and Task 6 (`testImportUsesItsOwnConnection`).

---

### Task 1: COPY in PostgresKit

**Files:**
- Modify: `Frameworks/PostgresKit/Source/PGPostgresConnection.h/.m`.
- Test: `PostgresTests/SPPostgresCopyTests.m`.

**Interfaces:**
- **Produces, on `PGPostgresConnection`:**
  - `- (BOOL)copyOut:(NSString *)sql handler:(BOOL (^)(NSData *chunk))handler error:(NSError **)error;`
    - Runs a `COPY … TO STDOUT` statement and calls `handler` with each row's bytes, from
      `PQgetCopyData(conn, &buf, 0)` freed with `PQfreemem`.
    - Returning NO from the handler cancels: `PQcancel`, then drain the results. The method then returns NO
      with an error whose code is `PGConnectionErrorCancelled` (add it if missing) and message "Cancelled.".
    - A server error returns NO with the server message.
  - `- (BOOL)copyIn:(NSString *)sql provider:(NSData * (^)(BOOL *cancel))provider error:(NSError **)error;`
    - Runs a `COPY … FROM STDIN` statement and sends the provider's chunks with `PQputCopyData` until the
      provider returns nil (`PQputCopyEnd(conn, NULL)`).
    - Setting `*cancel = YES` sends `PQputCopyEnd(conn, "cancelled")` and returns NO with the cancelled error.
    - A server error, such as bad data, returns NO with the server message, DETAIL and CONTEXT (the line number).
  - The delegate's `willExecute` is called with the COPY statement only; data is never passed to it.
  - Both methods are synchronous and run on the caller's thread.

- [ ] **Step 1: Write the failing tests**, on both ports, using temporary tables:
  - `testCopyOutTextAndCSV`:
    - Three rows, including a NULL, a tab, a newline and a backslash.
    - `COPY t TO STDOUT` gives exactly the text-format bytes (`\N`, `\t`, `\n`, `\\`).
    - `WITH (FORMAT csv, HEADER)` gives the header line plus the CSV rows.
  - `testCopyInRoundTrip`: feeding back the text-format bytes in 3-byte chunks recreates identical rows.
  - `testCopyInBadDataReportsLine`: a row with too few columns on line 2 fails, and the message contains `line 2`.
    The connection is usable afterwards (`SELECT 1`).
  - `testCopyCancel`:
    - A handler returning NO on its first chunk of a 100,000-row `generate_series` copy-out gives the cancelled
      error.
    - A provider that sets cancel after one chunk gives the cancelled error with no rows inserted.
    - The connection is usable afterwards.
  - `testCopyNotLoggedAsData`: a capturing delegate sees the COPY statement but none of the row bytes.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** both methods.
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 6 Task 1: COPY in PostgresKit`.

---

### Task 2: Reading and running SQL dumps

**Files:**
- Modify: `Source/Postgres/SPPostgresStatementSplitter.h/.m`. Add
  `+ (NSUInteger)lengthOfCompleteStatementsInSQL:(NSString *)sql;`: the offset just past the last top-level
  terminating `;`, using the same lexer, or 0.
- Create: `Source/Postgres/SPPostgresDumpReader.h/.m` and `Source/Postgres/SPPostgresSQLImporter.h/.m`.
- Modify: `PostgresTests/SPPostgresTestServers.h/.m`. Add `+ (PGPostgresConnection *)ioConnectionOnPort:(NSUInteger)port
  database:(NSString *)name;`, which creates `pgkit_io_src`/`pgkit_io_dst` when missing and empties them as the
  Global Constraints say.
- Create the fixtures `PostgresTests/Fixtures/io_source.sql`, `pgdump12.sql` and `pgdump18.sql` (see Global
  Constraints).
- Test: `PostgresTests/SPPostgresDumpReaderTests.m`, `PostgresTests/SPPostgresSQLImporterTests.m`.

**Interfaces:**
- **Consumes:** Task 1's `copyIn:provider:error:`, `SPFileHandle` (read-only use) and `SPPostgresStatementSplitter`.
- **Produces `SPPostgresDumpItem : NSObject`** (readonly):
  - `kind`: `SPPostgresDumpItemStatement`, `SPPostgresDumpItemCopy` or `SPPostgresDumpItemMetaCommand`;
  - `sql` (the statement, or the meta-command line);
  - `NSUInteger line` (1-based line where it starts).
  - For Copy, the data is not held in the item; it is read through the reader (below).
- **Produces `SPPostgresDumpReader : NSObject`:**
  - `- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;` opens the file through
    `SPFileHandle` (gz/bz2 transparent), decodes it as UTF-8 and skips a BOM.
  - `@property NSUInteger chunkSize;` (default 1 MiB; tests use tiny sizes).
  - `- (SPPostgresDumpItem *)nextItem:(NSError **)error;` returns nil at the end, or nil with an error.
    - It tracks line numbers.
    - A complete statement is one whose terminating `;` lies within what `lengthOfCompleteStatementsInSQL:`
      accepts, so statements and dollar-quoted bodies spanning chunk boundaries are handled.
    - Between statements, a line whose first non-blank character is `\` is a meta-command item.
    - A statement matching `^\s*COPY\b.*\bFROM\s+stdin\b` (case-insensitive) is a Copy item.
  - `- (NSData *)nextCopyData:(NSError **)error;` is valid only after a Copy item.
    - It returns chunks of the data lines, each ending in `\n`, up to but excluding the `\.` line. Then it
      returns nil, and the reader continues after `\.`.
    - It reports a missing `\.` at end of file as an error.
  - `@property (readonly) unsigned long long bytesRead, fileSize;` (compressed sizes for compressed files).
- **Produces `SPPostgresSQLImporter : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection reader:(SPPostgresDumpReader *)reader;`
  - `@property BOOL singleTransaction;` (default YES)
  - `@property (copy) SPPostgresImportErrorChoice (^errorHandler)(NSError *error, SPPostgresDumpItem *item);`
    - Used only when `singleTransaction` is NO. It returns `SPPostgresImportStop`, `SPPostgresImportIgnore` or
      `SPPostgresImportIgnoreAll`.
    - nil means Stop.
  - `@property (copy) BOOL (^progress)(unsigned long long bytesRead, unsigned long long fileSize);` returning NO
    cancels.
  - `- (BOOL)run:(NSError **)error;`
    - Runs every item: statements through `SPPostgresExecuteWithDetails`, Copy items through `copyIn:` fed by
      `nextCopyData:`.
    - Meta-commands follow the decisions: `\restrict` and `\unrestrict` are skipped; others are an error.
    - In single-transaction mode it wraps everything in `BEGIN`/`COMMIT` and rolls back on the first error or
      on cancel. If the dump itself contains `BEGIN`/`COMMIT` lines, they are skipped in single-transaction mode.
    - The error message is `Line <n>: <server message>`, followed by DETAIL, HINT and CONTEXT lines. The code
      is `SPPostgresErrorQueryFailed`, or `SPPostgresErrorCancelled`.
    - `@property (readonly) NSUInteger statementsRun, errorsIgnored;`

- [ ] **Step 1: Write the failing tests**:
  - Reader (no server):
    - `testSplitsStatementsAcrossTinyChunks`: chunkSize 7 over a text holding `$$` bodies with `;` inside, an
      `E'..\'..'` string, comments, and a `BEGIN ATOMIC … END` function. The items and line numbers equal those
      read with chunkSize 1 MiB.
    - `testCopyBlocksAndMetaCommands`: a text with `\restrict k`, a COPY block of 3 rows (one being `\\N`
      literally), `\.`, then a statement, then `\unrestrict k`. The items come out in order with the right
      kinds, and the copy data equals the 3 lines exactly.
    - `testMissingCopyTerminator`: the error mentions the COPY's line.
    - `testReadsGzipAndBOM`: a `.sql.gz` written with `SPFileHandle` gzip, and a BOM-prefixed file, both read.
  - Importer, on both ports, into `pgkit_io_dst`:
    - `testImportsPgDump18AndPgDump12`:
      - Each fixture imports into an emptied `pgkit_io_dst`.
      - Row counts per table equal those in `pgkit_io_src` loaded from `io_source.sql`, plus the checksum of
        `md5(string_agg(t::text, '|' ORDER BY id))` for `"Sales Data"."Orders 2026"`.
      - `pgdump18.sql` runs only on 55418, since PG 12 can't load a PG 18 dump. `pgdump12.sql` runs on both.
    - `testErrorInSingleTransactionRollsBackAndNamesLine`:
      - The file is `CREATE TABLE a(i int);` plus a line-3 bad statement.
      - It fails with a message starting `Line 3:`, and table `a` does not exist afterwards.
    - `testPerStatementModeAsksAndIgnores`:
      - The same file with `singleTransaction = NO`, where the handler returns Ignore. The run succeeds, `a`
        exists, and `errorsIgnored` is 1.
      - With Stop, it fails, and `a` exists (it was committed).
    - `testUnsupportedMetaCommandStops`: `\connect other` on line 2 gives exactly `psql command “\connect” on
      line 2 can't be run here.`
    - `testCancelInSingleTransactionLeavesNothing`: a progress block returning NO after the first call leaves
      `pgkit_io_dst` with no user tables, and the error code is Cancelled.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** the splitter addition, the reader and the importer. Generate the `pg_dump` fixtures as
  described and commit them.
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 6 Task 2: reading and running SQL dumps`.

---

### Task 3: Writing SQL dumps

**Files:**
- Modify: `Source/Postgres/SPPostgresCreateStatement.h/.m`. Add
  `+ (NSDictionary *)partsForTable:(NSString *)table inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error;`.
  - It returns the keys `SPPostgresCreatePartTable`, `SPPostgresCreatePartIndexes`,
    `SPPostgresCreatePartForeignKeys` and `SPPostgresCreatePartTriggers`. Each value is an `NSString` of
    `;`-terminated statements, possibly empty.
  - The table part is the current statement without the FOREIGN KEY constraint lines, the index statements and
    the trigger statements; comments stay.
  - The FK part is `ALTER TABLE … ADD CONSTRAINT "n" <def>` lines.
  - `createStatementForTable:` is unchanged in output; its existing tests must still pass.
- Create: `Source/Postgres/SPPostgresDumpWriter.h/.m`.
- Test: `PostgresTests/SPPostgresDumpWriterTests.m`.

**Interfaces:**
- **Consumes:** Task 1's `copyOut:handler:error:`; Task 2's reader and importer (used by the round-trip test);
  Stage 3's `SPPostgresCreateStatement` and `SPPostgresSequences`; and `SPFileHandle` writing.
- **Produces `SPPostgresDumpWriter : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - Scope, set exactly one of:
    - `@property BOOL wholeDatabase;`
    - `@property (copy) NSArray *schemas;`
    - `@property (copy) NSArray *tables;`, an array of `@[schema, table]` pairs.
  - `@property BOOL includeStructure, includeData;` (both default YES)
  - `@property BOOL compress;` (gzip)
  - `@property (copy) BOOL (^progress)(NSUInteger tableIndex, NSUInteger tableCount, NSString *table);` returning
    NO cancels.
  - `- (BOOL)writeToPath:(NSString *)path error:(NSError **)error;`
    - Runs `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` … `COMMIT` around everything.
    - Writes the sections in the decisions' order.
    - On error or cancel it deletes the file and returns NO (code `SPPostgresErrorCancelled` on cancel).
- [ ] **Step 1: Write the failing tests**, on both ports:
  - `testRoundTripMatchesSource`:
    - Load `io_source.sql` into `pgkit_io_src`, write a whole-database dump, and import it with Task 2's importer
      into an emptied `pgkit_io_dst`.
    - Compare source and destination on:
      - the column list (name, `format_type`, nullability, default, identity, generated) of every table;
      - the constraints (`pg_get_constraintdef`) and index definitions;
      - the trigger definitions and enable states;
      - the view definitions;
      - each table's row count and `md5(string_agg(t::text, '|' ORDER BY 1))`, with materialized views
        compared after both are populated;
      - `last_value`/`is_called` of every sequence;
      - the enum labels;
      - the comments.
    - The `audit` table's row count equals the source's, so the trigger did not fire during load.
    - The unpopulated materialized view is still unpopulated.
  - `testSchemaAndTableScopes`:
    - A dump of schema `"Sales Data"` only, imported, creates that schema and its objects but no `public`
      tables.
    - A dump of the single table `"Sales Data"."Orders 2026"`, imported into a database that has `mood` and
      `posint` created beforehand, gives that table with its data, indexes and sequences.
  - `testStructureOnlyAndDataOnly`:
    - A structure-only dump contains no `COPY`.
    - A data-only dump contains no `CREATE`, and loads into a structure-only import.
  - `testCompressedDump`: `compress = YES` writes a gzip file (magic bytes `1f 8b`) that Task 2's reader imports.
  - `testCancelDeletesPartialFile`: a progress block returning NO at table 2 gives the Cancelled error, and no
    file exists at the path.
  - `testDumpIsConsistentSnapshot`: a row inserted from another connection after `writeToPath:` has started
    (inserted from the progress block at table 1) is not in the dump.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** `partsForTable:` and the writer.
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures, including every existing
  `SPPostgresCreateStatementTests`.
- [ ] **Step 5: Commit** with the message `Postgres Stage 6 Task 3: writing SQL dumps`.

---

### Task 4: CSV export and import (data layer)

**Files:**
- Create: `Source/Postgres/SPPostgresCSV.h/.m`.
- Test: `PostgresTests/SPPostgresCSVTests.m`.

**Interfaces:**
- **Consumes:** Task 1's COPY methods; `SPCSVParser` (read-only use); `SPFileHandle`.
- **Produces `SPPostgresCSVOptions : NSObject <NSCopying>`** (readwrite):
  - `delimiter` (default `,`), `quote` (`"`), `escape` (`"`);
  - `BOOL header` (YES);
  - `nullString` (`@""`).
- **Produces `SPPostgresCSV : NSObject`:**
  - `+ (BOOL)exportTable:(NSString *)table schema:(NSString *)schema connection:(PGPostgresConnection *)connection options:(SPPostgresCSVOptions *)options toPath:(NSString *)path cancel:(BOOL (^)(void))shouldCancel error:(NSError **)error;`
    - Uses `COPY (SELECT * FROM "s"."t") TO STDOUT WITH (FORMAT csv, DELIMITER …, QUOTE …, ESCAPE …, HEADER …,
      NULL …)`.
    - The option values go as quoted literals.
    - Deletes the file on failure or cancel.
  - `+ (BOOL)exportRows:(NSArray *)rows columnNames:(NSArray *)names options:(SPPostgresCSVOptions *)options toPath:(NSString *)path error:(NSError **)error;`
    - For a query result. `rows` is an array of arrays of `NSString` or `NSNull`.
    - Written client-side with the same quoting rules as PostgreSQL's CSV output: a field is quoted when it
      contains the delimiter, quote, `\r`, `\n`, or equals `nullString` while not NULL. Quotes inside are doubled
      (when escape equals quote), else preceded by escape.
  - `+ (NSArray *)previewRowsAtPath:(NSString *)path options:(SPPostgresCSVOptions *)options limit:(NSUInteger)limit error:(NSError **)error;`
    - The first `limit` rows, after the header when `header` is set, as arrays of strings, with NULL as `NSNull`.
  - `+ (NSArray *)headerAtPath:(NSString *)path options:(SPPostgresCSVOptions *)options error:(NSError **)error;`
    - The header names, or "Column 1"… when `header` is NO, sized by the widest of the first 10 rows.
  - `+ (BOOL)importPath:(NSString *)path options:(SPPostgresCSVOptions *)options intoTable:(NSString *)table schema:(NSString *)schema columnMapping:(NSArray *)mapping connection:(PGPostgresConnection *)connection progress:(BOOL (^)(unsigned long long bytesRead, unsigned long long fileSize))progress error:(NSError **)error;`
    - `mapping` holds one entry per table column in attnum order: an `NSNumber` CSV column index, or `NSNull`
      for "not imported".
    - Parses with `SPCSVParser` in chunks.
    - Emits COPY text-format rows (escaping `\\`, `\t`, `\n`, `\r`, and `\N` for NULL) for the mapped columns
      only, inside `BEGIN`/`COMMIT`. On error or cancel it runs `ROLLBACK`.
    - Rows with fewer fields than a mapped index fail with `Row <n> has <k> fields; column “<c>” needs field <i>.`
- [ ] **Step 1: Write the failing tests**, on both ports, using `pgkit_io_src`:
  - `testExportTableCSVWithOptions`:
    - Export `"Sales Data"."Orders 2026"` with `;` delimiter, header and NULL `NULL`.
    - The first line is the column names joined by `;`.
    - A value holding `;` is quoted, a NULL is `NULL`, and an empty string is `""`.
  - `testExportRowsMatchesServerQuoting`: the same 5 awkward rows, exported via `exportRows:` and via
    `exportTable:` of a table holding them, give byte-identical files.
  - `testCSVRoundTripKeepsAwkwardValues`:
    - Export a table holding tabs, newlines, backslashes, `\N`, empty vs NULL, emoji and quotes.
    - Import it into an empty copy of the table with the identity mapping.
    - `md5(string_agg(t::text, '|' ORDER BY id))` is equal.
  - `testImportWithMappingAndSkippedColumn`:
    - A 3-column CSV with header `b,a,ignored` goes into table `(a int, b text, c text default 'd')` with mapping
      `@[@1, @0, NSNull]`.
    - Rows land with `a` and `b` correct and `c` = `d`.
  - `testImportErrorRollsBackAndReportsLine`: a non-integer in row 3 fails with the server message containing
    `line 3`, and the table is unchanged.
  - `testShortRowMessage`: a mapping to field 2 on a 2-field row gives exactly `Row 2 has 2 fields; column “c”
    needs field 3.`
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** `SPPostgresCSV`.
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 6 Task 4: CSV export and import`.

---

### Task 5: The Export sheet, the progress sheet and File ▸ Export…

**Files:**
- Create:
  - `Source/Postgres/SPPostgresExportController.h/.m` (the sheet, built in code);
  - `Source/Postgres/SPPostgresProgressSheet.h/.m`;
  - `Source/Postgres/SPPostgresBackgroundJob.h/.m`: runs a block on a background thread with a connection from
    the provider, and calls a completion on the main thread.
- Modify:
  - `Source/Postgres/SPPostgresDocument.h/.m`:
    - rename `usersConnectionProvider` to `connectionProvider` (and in its Stage 4 tests);
    - add `typedef void (^SPPostgresConnectionProvider)(NSString *database, void (^completion)(PGPostgresConnection *connection, NSError *error));` to its header and use it as the property's type;
    - add `- (IBAction)export:(id)sender;`, validated while connected, not processing and no sheet attached.
  - `Source/Postgres/SPPostgresConsoleLogger.m`: hop to the main thread (see the decisions).
  - `Source/Postgres/SPPostgresQueryController.h/.m`: expose the last result as
    `- (NSArray *)lastResultColumnNames;` and `- (NSArray *)lastResultRows;` (nil when there is none), as arrays
    of `NSString` or `NSNull`.
- Test: `PostgresTests/SPPostgresExportControllerTests.m`.

**Interfaces:**
- **Consumes:** Task 3's writer, Task 4's CSV export, the catalog's `schemaNames:` and `tableNamesInSchema:`, and
  the sidebar's selection.
- **Produces `SPPostgresBackgroundJob`:**
  - `+ (void)runOnDatabase:(NSString *)database provider:(SPPostgresConnectionProvider)provider work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work completion:(void (^)(BOOL ok, NSError *error))completion;`
  - The connection is disconnected after `work` returns.
  - Task 6 reuses it.
- **Produces `SPPostgresProgressSheet`:**
  - `+ (instancetype)beginOnWindow:(NSWindow *)window title:(NSString *)title;`
  - `- (void)setStatus:(NSString *)status fraction:(double)fraction;` is thread-safe and throttled.
  - `@property (readonly) BOOL cancelled;` (thread-safe)
  - `- (void)end;`
- **Produces `SPPostgresExportController`:**
  - `- (instancetype)initWithDocument:(SPPostgresDocument *)document;`
  - `- (void)beginSheet;`
  - Exposed for tests:
    - `formatControl` (SQL/CSV), `sourcePopup` (Whole database / Selected schemas / Selected tables / Query
      result), `schemasTable`, `tablesTable`;
    - `structureCheckbox`, `dataCheckbox`, `compressCheckbox`;
    - `delimiterPopup`, `customDelimiterField`, `quoteField`, `escapePopup`, `headerCheckbox`, `nullField`;
    - `exportButton`;
    - `@property (copy) NSString * (^savePathProvider)(NSString *suggestedName, BOOL directory);`: nil shows
      NSSavePanel/NSOpenPanel; tests return a temporary path;
    - `- (void)export:(id)sender;`, `- (void)cancel:(id)sender;`, and `lastErrorMessage`.
  - Suggested names: `<database>.sql` / `<database>.sql.gz`; `<schema>.<table>.csv`; `query-result.csv`.
- [ ] **Step 1: Write the failing tests**, on both ports, with a document connected to `pgkit_io_src` and a test
  `connectionProvider`:
  - `testExportSQLWholeDatabase`: choose SQL and Whole database, then Export. The file at the provided path
    exists, starts with the header comment and contains `COPY "Sales Data"."Orders 2026"`.
  - `testExportSelectedTablesCSVToFolder`: two tables checked with CSV write the two files
    `<schema>.<table>.csv` into the folder.
  - `testExportQueryResultCSV`: run `SELECT 1 AS a, NULL AS b` in the Query view. Query result is enabled, and
    exporting it gives `a,b\n1,\n`.
  - `testQueryResultDisabledWithoutResult`.
  - `testExportUsesItsOwnConnection`:
    - Open a transaction in the document's connection with an uncommitted insert, then export.
    - The provider was asked for `pgkit_io_src`, and the document's connection is still in its transaction with
      the row.
    - The dump does not contain the uncommitted row.
  - `testCancelDuringExport`: set the progress sheet's cancel at the first progress. No file remains and the
    sheet ends.
  - `testExportMenuValidation`: `validateMenuItem:` for `export:` is YES when connected, and
    `importFromClipboard:` is NO.
  - `testConsoleLoggerFromBackgroundThread`: logging from a background queue appends on the main thread without
    a crash.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and the build succeeds.
- [ ] **Step 5: Commit** with the message `Postgres Stage 6 Task 5: Export sheet and File ▸ Export…`.

---

### Task 6: Import: the open panel, CSV mapping and File ▸ Import…

**Files:**
- Create:
  - `Source/Postgres/SPPostgresImportController.h/.m` (the open panel's accessory view and the flow);
  - `Source/Postgres/SPPostgresCSVMappingSheet.h/.m`.
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`. Add `- (IBAction)import:(id)sender;`, validated like
  `export:`. After a successful (or partly successful) import, reload the sidebar keeping the selection and mark
  every pane stale.
- Test: `PostgresTests/SPPostgresImportControllerTests.m`.

**Interfaces:**
- **Consumes:** Task 2's reader and importer, Task 4's CSV import, preview and header, and Task 5's background job,
  progress sheet and `connectionProvider`.
- **Produces `SPPostgresImportController`:**
  - `- (instancetype)initWithDocument:(SPPostgresDocument *)document;`
  - `- (void)beginImport;`
  - `- (void)importPath:(NSString *)path format:(NSString *)format;` (`@"sql"` or `@"csv"`), the entry after the
    open panel, used by tests.
  - Exposed for tests:
    - `singleTransactionCheckbox`, and `csvOptions` (an `SPPostgresCSVOptions`);
    - `@property (copy) SPPostgresImportErrorChoice (^errorChoiceProvider)(NSError *error);`: nil shows an alert
      with Stop / Ignore / Ignore All;
    - `mappingSheet` (while shown) and `lastErrorMessage`.
- **Produces `SPPostgresCSVMappingSheet`:**
  - `tablePopup` (`schema.table` entries; the default is the sidebar's table);
  - `previewTable`;
  - `- (NSArray *)columnPopups;` (one per table column);
  - `importButton`, `cancelButton`;
  - `- (NSArray *)mapping;`, in the format Task 4 expects.
- [ ] **Step 1: Write the failing tests**, on both ports, with a document on `pgkit_io_dst` and a test
  `connectionProvider`:
  - `testImportSQLDumpRefreshesSidebar`: `importPath:` of a dump made by Task 3 from `pgkit_io_src`. The sidebar
    then lists `"Sales Data"` and its tables, and the Content pane is stale.
  - `testImportSQLErrorShowsLine`: a file whose line 2 is bad. With single transaction on, `lastErrorMessage`
    starts `Line 2:` and nothing was created.
  - `testPerStatementErrorChoice`: single transaction off, with `errorChoiceProvider` returning Ignore. The import
    completes, and the good statements' objects exist.
  - `testCSVMappingDefaultsByNameThenPosition`:
    - A CSV with header `B,a,zzz` targets table `(a, b, c)`. The pop-ups preselect `a`←`a`, `b`←`B`, and
      `c`←"— Not imported —".
    - The preview shows the first rows.
  - `testCSVImportThroughSheet`: change one pop-up, then Import. The rows land as mapped, and the Content pane is
    stale.
  - `testImportUsesItsOwnConnection`: with the document's connection in an open transaction, a CSV import commits
    on its own connection, and the document's transaction is untouched.
  - `testImportMenuValidation`: `import:` is YES when connected.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and the build succeeds.
- [ ] **Step 5: Commit** with the message `Postgres Stage 6 Task 6: Import, CSV mapping and File ▸ Import…`.
