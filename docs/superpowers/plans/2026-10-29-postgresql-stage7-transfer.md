# PostgreSQL Stage 7 (Transfer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Postgres tab, the toolbar's **Transfer** item copies selected tables, or the whole current database,
to a database on another PostgreSQL server (any Postgres favorite), either emptying the target database first or
replacing the copied tables that already exist there.

**Architecture:**
- **No new data path.** Transfer is Stage 6's two tested halves joined through a temporary file:
  `SPPostgresDumpWriter` reads the source (one REPEATABLE READ snapshot) into a temporary plain-SQL dump, and
  `SPPostgresSQLImporter` loads it into the target **in one transaction**. The emptying or replacing statements run
  first, inside that same transaction. So every failure, or Cancel, leaves the target exactly as it was.
- **New data-layer class `SPPostgresTransfer`** (no UI): checks, then the dump, then the load. Before reading the
  source it checks the target: same database refused, extensions not available refused, and (Overwrite) a dry run
  of the replacing DROPs inside a rolled-back transaction, whose server DETAIL lists what's in the way.
- **The writer learns two things:** list what a dump would create (`objectsInScope:`), and, for a table copy,
  bring the types, trigger functions, sequences and extensions the tables need (`includeDependencies`), leaving out
  those that already exist on the target (`skippedObjects`).
- **UI:** `SPPostgresTransferController` (a sheet built in code), run as a background job holding **two**
  connections (source from the tab's connection provider, target from a connector for the chosen favorite), under
  Stage 6's progress sheet. The Postgres tab's Transfer toolbar item becomes enabled. MySQL's stays disabled.

**Tech Stack:** Objective-C (MRC in app sources), AppKit built in code, PostgresKit over static libpq, XCTest (ARC).
Docker test servers: PG 12 on 55412, PG 18 on 55418.

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md`, as amended by
`docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`:
- Goal 12: "copy selected tables, or a whole database, from the current server to another PostgreSQL server".
- "Transfer" (owner): the target "is normally an existing favorite and may need its own SSH tunnel"; mode 1
  "Empty the target database before transfer" removes "everything inside the target database: all schemas
  (including `public`), tables, views, functions, types and extensions … Only the target database is touched";
  mode 2 "Overwrite tables that already exist on the target": "Tables on the target that are not part of the copy
  are left alone. If replacing a table would break something on the target that depends on it … Transfer stops
  before changing anything and lists what's in the way. It never cascades deletes onto objects outside the copy."
- Builder's calls: "Transfer scope", "Transfer contents" ("If an extension is not available on the target server,
  stop and report it rather than skipping it silently. Roles and ownership are not transferred. Objects are created
  as the connecting target user.") and "Confirming destructive Transfer" ("asks for confirmation by typing the
  target database's name, and shows the target server and database clearly before running").
- "Server versions and privileges": Transfer may assume superuser rights.
- Amendment: "The MySQL toolbar gains one disabled Transfer item, its only toolbar change; Transfer is
  PostgreSQL-only."

## Builder's decisions (the spec leaves these open)

### How the data moves
- **Through a temporary file**, `<NSTemporaryDirectory()>/sequel-pro-transfer-<UUID>.sql`, uncompressed, deleted
  on every path (success, failure, cancel). It costs disk space equal to the dump and reads the data twice; in
  return, both halves are the Stage 6 code already round-trip-tested on PG 12 and 18, and the target's transaction
  only starts once the source has been read completely.
- **One transaction on the target** (the importer's single-transaction mode): emptying or dropping, then the whole
  dump, then `COMMIT`. A failure or Cancel at any point rolls back, so **the target is never left half-copied**.
- Progress: "Checking the target…", then "Reading table 3 of 12: orders" (bar 0–50 %), then
  "Writing to “<database>”…" by bytes of the dump (bar 50–100 %).

### Scope and contents
- **Whole database** = what Stage 6's whole-database dump writes: every non-system schema with its types,
  functions, sequences, tables, views, materialized views, data, indexes, constraints, triggers, comments, and every
  extension but `plpgsql`. Foreign tables are left out and named in the completion note.
- **Selected tables** = the tables (partitioned ones with their partitions) with their data, owned sequences,
  indexes, constraints and triggers, in their own schema names (schemas created if missing), **plus what they need
  to be usable** (new writer option `includeDependencies`):
  - the types their columns use, followed through domains' base types, composite types' attributes, array element
    types and range subtypes (user types only, not extension members);
  - the extensions owning any type in that set (for example `citext`);
  - the functions their triggers call;
  - sequences their column defaults call with `nextval` that the tables don't own.
  Dependencies that **already exist on the target** (same kind, schema and name; routines also same argument
  types) are **used as they are** and never dropped or replaced.
- **Same database refused:** if source and target are the same database of the same cluster
  (`pg_control_system().system_identifier` and `current_database()` both equal), Transfer refuses with "The target
  is the database being copied." If the identifier can't be read on either side, the check is skipped.
- **Extensions:** every extension the copy creates must be installed on the target already or listed in its
  `pg_available_extensions`; otherwise Transfer refuses before changing anything and names them.

### Mode 1: Empty the target database
- Confirmation first (before connecting): an alert naming the target favorite, `user@host:port` (and "via SSH
  user@host" when tunnelled) and the database, with a text field. Its **Empty and Transfer** button
  (destructive) is enabled only while the field holds exactly the database's name.
- Statements, first in the target transaction, built from the target's catalog:
  1. `DROP EXTENSION IF EXISTS "a", "b" CASCADE;`: every extension except `plpgsql` (kept: every new database has
     it, in `pg_catalog`).
  2. `DROP SCHEMA IF EXISTS "public", "s", … CASCADE;`: every schema not named `pg_*` or `information_schema`.
  3. `CREATE SCHEMA public;` then, as a fresh database has it: on PG 15+
     `ALTER SCHEMA public OWNER TO pg_database_owner; GRANT USAGE ON SCHEMA public TO PUBLIC;`, on PG 12–14
     `GRANT CREATE, USAGE ON SCHEMA public TO PUBLIC;`; then `COMMENT ON SCHEMA public IS 'standard public schema';`.
- **`CASCADE` is used here, and only here.** Earlier stages' rule is "no `CASCADE` in app code"; this mode's whole
  purpose is to remove everything in the database, after the user has typed its name, inside a transaction that
  rolls back on any failure. Emptying without `CASCADE` would mean ordering every kind of object by hand
  (aggregates, operators, casts, rules, policies, FDW servers…) and would break on the first kind missed.
  The `CASCADE` stays within the target database (it can't reach roles or other databases).

### Mode 2: Overwrite tables that already exist on the target
- The copy's objects (`objectsInScope:`) that already exist on the target are **replaced**: dropped, then created
  by the dump. Dependencies of a table copy are not replaced (above). Tables, views and everything else on the
  target that aren't in the copy are left alone.
- Drops are `RESTRICT` (no `CASCADE`), `IF EXISTS`, one statement per kind, by the **target's** kind of the object,
  in this order: materialized views, views, foreign tables, tables, sequences, routines (`DROP ROUTINE
  "s"."f"(args)`), domains, types. Objects of one kind go in one statement, so foreign keys and partitions among the
  replaced tables don't get in the way.
- **Dry run before reading the source:** `BEGIN`, the drops, `ROLLBACK`. A refused drop (SQLSTATE `2BP01`) stops
  Transfer with `SPPostgresErrorHasDependents`; the dependents are the server's DETAIL lines (for example
  "view public.report depends on table public.orders"). Nothing has changed on the target.
- No second confirmation: choosing this mode is the consent. The completion note lists what was replaced.
- Known cost: a dependency among replaced objects that this fixed order can't satisfy (a replaced function using a
  replaced table's row type) is also reported as in the way; Empty mode is the way out.

### Target connection and the sheet
- The target is any Postgres favorite (`SPPostgresFavoritesStore`), including this tab's own favorite with another
  database. The pop-up preselects the first favorite that isn't this tab's.
- **Database** field: defaults to the favorite's database, follows the favorite until edited.
- **Password** field (secure): empty means the password saved in the Keychain for that favorite is used; the
  Keychain is read only when Transfer starts (never while the sheet is open). A typed password is never saved.
- The SSH password comes from the Keychain; SSH prompts (passphrase, host key) appear on the progress sheet, as for
  Export.
- The target connection's statements go to the Console under the target favorite's name. COPY data never does.
- A line under the pop-up shows `user@host:port`, `user@<socket directory>` or `user@host:port via SSH
  sshUser@sshHost`.
- **Scope** radio: "Whole database “<db>”" (default) / "Selected tables", with Export's grouped checkbox list
  (preset to the sidebar's selected table).
- **Mode** radio: "Empty the target database first" (default, the usual case) / "Overwrite tables that already
  exist on the target".
- Transfer is disabled with no favorite, an empty database name, or Selected tables with none checked.
- **Success alert:** "Transfer complete", "Copied <n> tables to “<db>” on “<favorite>”." plus, when any: replaced
  objects, dependencies created, foreign tables left out, settings skipped.
- **Failure alert:** "The transfer failed. “<db>” on “<favorite>” wasn't changed." with the error, and the list
  of what's in the way, missing extensions, or the server's message.

### Shared pieces
- **`SPPostgresBackgroundJob` gains a two-connection run.** Source connection first, then target (so SSH prompts
  come one at a time); both get cancel tokens, Cancel interrupts both, both are disconnected afterwards. The
  one-connection method becomes a wrapper over the same code.
- **`SPPostgresCheckList`** (new): the grouped checkbox list extracted from the Export sheet, used by Export (its
  schemas list and its tables list) and Transfer. Export's behaviour and tests are unchanged.
- The Transfer item on Postgres tabs is a plain enabled `NSToolbarItem` configured by
  `SPConfigureTransferToolbarItem`, action `showTransfer:`, validated like Export. `SPMainToolbar.m`,
  `SPToolbarTransferItem.h/.m` and `SPDatabaseDocument` are not modified.

## Global Constraints

- **Never break MySQL.** No MySQL source file changes. `SPMainToolbar.m`, `SPToolbarTransferItem.*` and
  `SPDatabaseDocument.*` are untouched, and MySQL's Transfer item stays an always-disabled `SPDisabledToolbarItem`.
  The only non-Postgres change is additive `sequel-pro.xcodeproj/project.pbxproj` entries.
- PostgreSQL **12 through 18**. Every data-layer test runs on both 55412 and 55418; cross-version tests copy
  12 → 18 and 18 → 12.
- **Quoting:** identifiers through `SPPostgresQuoteIdentifier`, values through `SPPostgresQuoteLiteral` or `$n`
  parameters.
- **`CASCADE` only in Empty mode's two statements** (see the decisions). No `DROP OWNED`, `REASSIGN OWNED`,
  `DROP DATABASE` or `CREATE DATABASE` in app code. Nothing outside the target database is touched.
- **The target is changed only inside one transaction**, and only after the source has been read completely.
- **Tests:**
  - Use `pgkit_io_src` (loaded with `io_source.sql`) and `pgkit_io_dst`, via
    `+[SPPostgresTestServers ioConnectionOnPort:database:]`. Never touch `pgkit_test`'s `pg_trgm`.
  - Never write `Favorites.plist`, `PostgresFavorites.plist`, real prefs or the login keychain. Controller tests
    set the `favorites` and `targetProviderForFavorite` seams, so the store and the Keychain are never read.
  - Temporary files only under a test-owned temporary directory (the engine's `temporaryDirectory`), checked empty
    at the end of each engine test.
- **Code conventions:** MRC in app sources; ARC in `Postgres Tests`. Add files only with
  `ruby Scripts/pg-xcodeproj.rb add-app|add-test`. Exported classes and functions need
  `__attribute__((visibility("default")))`.
- **Test command:** `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests"
  -derivedDataPath build/DerivedData ARCHS=arm64` (after `bash Scripts/pg-test-servers.sh up`).
- **App build:** `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug
  -derivedDataPath build/DerivedData ARCHS=arm64 build`.
- **Agent sessions:** implementers never launch the GUI app; never kill processes you didn't start; never touch
  the owner's untracked `start_clause.sh`; stage only your own files.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Copying 18 → 12 when the source uses something PG 12 lacks** (the fixture's `BEGIN ATOMIC` function): the
   load fails, the alert says why, and the target is exactly as before, including its emptied-then-restored
   contents. Pinned in Task 2 (`testFailedLoadLeavesTargetUnchanged`).
2. **Overwriting two tables that a target view and a target foreign key depend on:** stops before reading the
   source, lists both dependents, target unchanged. Pinned in Task 2 (`testOverwriteStopsAndListsWhatIsInTheWay`).
3. **Copying a table with enum, domain, composite and `citext` columns and an audit trigger (with its audit table)
   into an empty target:** loads and works (an insert fires the trigger). Into a target that already has `mood` used by another
   table: `mood` is reused, not dropped. Pinned in Task 1 (`testDependencyDumpLoadsIntoEmptyDatabase`) and
   Task 2 (`testSelectedTablesIntoEmptiedTarget`, `testExistingDependenciesAreReused`).
4. **Cancel while the target transaction waits on a lock** held by another session: Cancel ends the job within
   seconds and the target is unchanged. Pinned in Task 3 (`testCancelInterruptsTargetLockWait`).
5. **Typing the database name:** a near miss (`pgkit_io_ds`, different case, trailing space) keeps the destructive
   button disabled; Cancel of the confirmation starts nothing and opens no connection. Pinned in Task 5
   (`testEmptyConfirmationNeedsExactName`).

---

### Task 1: What a dump creates, and a table copy's dependencies

**Files:**
- Modify: `Source/Postgres/SPPostgresDumpWriter.h/.m`
- Create: `Source/Postgres/SPPostgresDumpObject.h/.m`
- Test: `PostgresTests/SPPostgresDumpWriterTests.m` (add tests)

**Interfaces:**
- **Consumes:** the writer's existing scope rules (`wholeDatabase`, `schemas`, `tables`).
- **Produces `SPPostgresDumpObject : NSObject <NSCopying>`**, value equality (`isEqual:`/`hash` on kind, schema,
  name, arguments):
  - `+ (instancetype)objectWithKind:(NSString *)kind schema:(NSString *)schema name:(NSString *)name arguments:(NSString *)arguments;`
  - `@property (readonly, copy) NSString *kind, *schema, *name;` `arguments` (routines: the
    `pg_get_function_identity_arguments` text; nil otherwise; extensions: schema is the schema it's installed in).
  - `@property (readonly, copy) NSString *displayName;`: `table "Sales Data"."Orders 2026"`, `routine
    public.audit_row()`, `extension citext`. Kind word + qualified, quoted-where-needed name.
  - Kind constants (`NSString *const`, exported): `SPPostgresDumpObjectTable` (`r`, `p`),
    `SPPostgresDumpObjectForeignTable`, `SPPostgresDumpObjectView`, `SPPostgresDumpObjectMaterializedView`,
    `SPPostgresDumpObjectSequence`, `SPPostgresDumpObjectRoutine`, `SPPostgresDumpObjectType` (enum, composite,
    range), `SPPostgresDumpObjectDomain`, `SPPostgresDumpObjectExtension`.
- **Produces on `SPPostgresDumpWriter`:**
  - `@property BOOL includeDependencies;` (default NO; only with `tables`): the dependencies listed in the
    decisions are written in their usual sections (extensions in 3, types in 4, trigger functions in 5, sequences in
    6 with their `setval` in 10).
  - `@property (copy) NSArray *skippedObjects;` (`SPPostgresDumpObject`s): dependencies equal to one of these are
    not written. Non-dependency objects are never skipped.
  - `- (NSArray *)objectsInScope:(NSError **)error;`: the objects `writeToPath:` would create with the current
    settings, as `SPPostgresDumpObject`s, sorted by kind then schema then name; foreign tables are not included
    (never written). Sequences include serial-owned ones (not identity sequences).
  - `- (NSArray *)dependenciesInScope:(NSError **)error;`: the subset of `objectsInScope:` that
    `includeDependencies` adds (empty when it is NO).
  - Both read on the writer's connection outside any transaction; they run no DDL.

- [ ] **Step 1: Write the failing tests**, on both ports, with `io_source.sql` loaded in `pgkit_io_src`:
  - `testObjectsInScopeWholeDatabase`: contains tables `"Sales Data"."Orders 2026"`, `"Sales Data".order_lines`,
    `public.audit`, `public.events`, `public.events_2025`; views `v_orders`, `v_big_orders`; materialized views
    `mv_by_feeling`, `mv_unpopulated`; sequences `public.counter`, `public.audit_id_seq`; routine
    `public.audit_row` with arguments `@""`; type `public.mood`, `public.address`; domain `public.posint`;
    extension `citext` with schema `public`. Does not contain `plpgsql`, nor `"Orders 2026_id_seq"` (identity).
    On PG 14+ (`server_version_num >= 140000`) it also contains routine `public.order_count`.
  - `testDependenciesOfSelectedTables`: tables `@[@[@"Sales Data", @"Orders 2026"]]` with `includeDependencies`:
    `dependenciesInScope:` is exactly {extension `citext`, type `public.mood`, type `public.address`, domain
    `public.posint`, routine `public.audit_row`}; without `includeDependencies` it is empty.
  - `testDependenciesFollowNestedTypes`: create in `pgkit_io_src` a domain `public.mood_d` over `public.mood`, a
    composite `public.wrap (m public.mood_d[])` and a table `public.nested (w public.wrap)`; the dependencies of
    `public.nested` include `mood`, `mood_d` and `wrap`.
  - `testDependencyDumpLoadsIntoEmptyDatabase`: dump `"Sales Data"."Orders 2026"`, `"Sales Data".order_lines` and
    `public.audit` with `includeDependencies` and import it into an emptied `pgkit_io_dst`: rows match the source's,
    `INSERT INTO "Sales Data"."Orders 2026"(qty) VALUES (1)` succeeds and adds a row to `public.audit`.
  - `testSkippedDependenciesAreNotWritten`: with `skippedObjects` = {type `public.mood`}, the dump contains no
    `CREATE TYPE public.mood` and still contains `CREATE TYPE public.address`; skipping table `"Sales Data".order_lines`
    has no effect (still written).
  - `testDefaultSequenceDependency`: a table `public.uses_counter (n bigint DEFAULT nextval('public.counter'))`;
    its dependencies include sequence `public.counter`, and the dump sets it to 42.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** `SPPostgresDumpObject`, `objectsInScope:`, `dependenciesInScope:`,
  `includeDependencies` and `skippedObjects`. Share the scope queries between `objectsInScope:` and `_writeDump:`
  instead of copying them; type dependencies with a recursive CTE over `pg_type` (`typbasetype`, `typelem`,
  `pg_attribute` of `typrelid`, `pg_range.rngsubtype`), excluding extension members except to find their extension.
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures, every existing `SPPostgresDumpWriterTests` included.
- [ ] **Step 5: Commit** with the message `Postgres Stage 7 Task 1: dump scope objects and table dependencies`.

---

### Task 2: The transfer engine

**Files:**
- Create: `Source/Postgres/SPPostgresTransfer.h/.m`
- Modify:
  - `Source/Postgres/SPPostgresSQLImporter.h/.m`: `statementsBeforeImport`.
  - `Source/Postgres/SPPostgresErrors.h/.m`: code `SPPostgresErrorTransferRefused = 10` and key
    `SPPostgresObjectsErrorKey`.
  - `PostgresTests/SPPostgresTestServers.h/.m`: move `describe:` / `assertDescription:equals:context:` out of
    `SPPostgresDumpWriterTests.m` as `+ (NSDictionary *)describeDatabase:(PGPostgresConnection *)connection;` and
    `+ (void)assertDescription:(NSDictionary *)actual equals:(NSDictionary *)expected context:(NSString *)context;`
    (the writer tests call them; their behaviour is unchanged).
- Test: `PostgresTests/SPPostgresTransferTests.m`

**Interfaces:**
- **Consumes:** Task 1's `SPPostgresDumpObject`, `objectsInScope:`, `dependenciesInScope:`,
  `includeDependencies`, `skippedObjects`; Stage 6's writer and importer.
- **Produces on `SPPostgresSQLImporter`:** `@property (copy) NSArray *statementsBeforeImport;` (NSString SQL):
  run first, in order, inside the transaction when `singleTransaction`; a failure fails the run with the server's
  message, DETAIL and HINT (no line number), and rolls back.
- **Produces errors:** `SPPostgresErrorTransferRefused` (localized description says why; the objects concerned,
  as NSString, under `SPPostgresObjectsErrorKey`).
- **Produces `SPPostgresTransfer : NSObject`:**
  - `typedef NS_ENUM(NSInteger, SPPostgresTransferMode) { SPPostgresTransferEmptyTarget = 0, SPPostgresTransferOverwrite = 1 };`
  - `typedef NS_ENUM(NSInteger, SPPostgresTransferPhase) { SPPostgresTransferChecking = 0, SPPostgresTransferReading = 1, SPPostgresTransferWriting = 2 };`
  - `- (instancetype)initWithSource:(PGPostgresConnection *)source target:(PGPostgresConnection *)target;`
  - `@property BOOL wholeDatabase;` / `@property (copy) NSArray *tables;` (`@[schema, table]`), exactly one.
  - `@property SPPostgresTransferMode mode;`
  - `@property (copy) NSString *temporaryDirectory;` (default `NSTemporaryDirectory()`).
  - `@property (copy) BOOL (^progress)(SPPostgresTransferPhase phase, double fraction, NSString *detail);`: Checking
    (fraction 0, detail nil); Reading (fraction `(tableIndex - 1) / tableCount`, detail the table name);
    Writing (fraction bytes read / dump size, detail nil). NO cancels (also mid-COPY, through the writer and
    importer).
  - `- (BOOL)run:(NSError **)error;`, synchronous. In order: same-database check → scope objects and
    dependencies → extension check → existing objects on the target → Overwrite dry run → dump to the temporary
    file → load with `statementsBeforeImport` → delete the file. Errors: `SPPostgresErrorTransferRefused` (same
    database; missing extensions, named in `SPPostgresObjectsErrorKey`), `SPPostgresErrorHasDependents` (Overwrite
    dry run; DETAIL lines under `SPPostgresDependentsErrorKey`), `SPPostgresErrorCancelled`, or the writer's or
    importer's error unchanged.
  - Results (readonly, valid after a successful run): `NSUInteger tablesCopied` (tables and partitions with a
    COPY block), `NSArray *replacedObjects` and `NSArray *dependenciesCreated` (`displayName` strings),
    `NSArray *foreignTablesSkipped` (from the writer), `NSArray *skippedSettings` (from the importer).
  - Test seam: `- (NSArray *)availableExtensionsOnTarget:(NSError **)error;`: the names in the target's
    `pg_available_extensions` (installed ones are always listed there); the engine calls it once per run.
  - For tests: `+ (NSArray *)emptyingStatementsForSchemas:(NSArray *)schemas extensions:(NSArray *)extensions serverVersion:(NSInteger)versionNumber;`
    and `+ (NSArray *)dropStatementsForObjects:(NSArray *)targetObjects;` (`SPPostgresDumpObject`s carrying the
    target's kinds), both producing the exact statements in the decisions.

- [ ] **Step 1: Write the failing tests.** Same-server tests run on both ports (`pgkit_io_src` → `pgkit_io_dst`);
  each engine test uses its own temporary directory and asserts it is empty afterwards.
  - `testEmptyingStatements`: schemas `@[@"public", @"Sales Data"]`, extensions `@[@"citext", @"pg_trgm"]`,
    version 150000 gives exactly
    `DROP EXTENSION IF EXISTS "citext", "pg_trgm" CASCADE`, `DROP SCHEMA IF EXISTS "public", "Sales Data" CASCADE`,
    `CREATE SCHEMA public`, `ALTER SCHEMA public OWNER TO pg_database_owner`,
    `GRANT USAGE ON SCHEMA public TO PUBLIC`, `COMMENT ON SCHEMA public IS 'standard public schema'`; version
    140000 has `GRANT CREATE, USAGE ON SCHEMA public TO PUBLIC` and no `ALTER SCHEMA`. No extensions → no
    `DROP EXTENSION` statement.
  - `testDropStatementsOrderAndKinds`: a view, two tables, a routine `public.f` with arguments `integer, text`, a
    domain and a type give, in order, `DROP VIEW IF EXISTS …`, `DROP TABLE IF EXISTS "a"."t1", "a"."t2"`,
    `DROP ROUTINE IF EXISTS "public"."f"(integer, text)`, `DROP DOMAIN IF EXISTS …`, `DROP TYPE IF EXISTS …`; none
    contains `CASCADE`.
  - `testWholeDatabaseIntoEmptiedTarget`: `pgkit_io_dst` first gets schema `junk` with a table, a table
    `public.leftover`, and extension `pg_trgm`. After an Empty-mode whole-database transfer, `describeDatabase:` of
    the target equals the source's; `junk`, `leftover` and `pg_trgm` are gone; on PG 15+ `public`'s owner is
    `pg_database_owner`. `tablesCopied` counts the tables with rows.
  - `testSelectedTablesIntoEmptiedTarget`: tables `"Sales Data"."Orders 2026"` and `"Sales Data".order_lines`;
    both tables' rows match the source's; `dependenciesCreated` lists `citext`, `mood`, `address`, `posint`,
    `audit_row`; `public.audit` doesn't exist on the target (not copied; the trigger function is, and only fails when it
    fires — documented, not asserted).
  - `testOverwriteReplacesOnlyCopiedTables`: target holds an older copy of the two tables (one row each, made by
    an earlier transfer) and an unrelated `public.keep` with one row. Overwrite the two tables: their rows match
    the source's, `public.keep` still has its row, `replacedObjects` lists exactly the two tables (and their owned
    sequences when they existed).
  - `testExistingDependenciesAreReused`: target has `public.mood` (same labels) used by a table `public.other`
    with a row. Overwrite-copy `"Sales Data"."Orders 2026"`: succeeds, `public.other` and its row intact, `mood`'s
    oid unchanged, `dependenciesCreated` doesn't list `mood`.
  - `testOverwriteStopsAndListsWhatIsInTheWay`: target has the older copy of `"Sales Data"."Orders 2026"`, a view
    `public.report` over it and a table `public.refs` with a foreign key to it. Overwrite-copy that table: fails
    with `SPPostgresErrorHasDependents`; the dependents mention `public.report` and `public.refs`; the progress
    block never saw the Reading phase; the target's `describeDatabase:` is unchanged.
  - `testSameDatabaseRefused`: source and target both `pgkit_io_src` on one port: `SPPostgresErrorTransferRefused`,
    source unchanged.
  - `testMissingExtensionRefused`: install `pg_trgm` in the source, and run a test subclass of
    `SPPostgresTransfer` whose `availableExtensionsOnTarget:` returns the real list minus `pg_trgm`: fails with
    `SPPostgresErrorTransferRefused`, `SPPostgresObjectsErrorKey` holds `pg_trgm`, target unchanged.
  - `testFailedLoadLeavesTargetUnchanged`: copy 18 → 12, whole database, Empty mode, into a `pgkit_io_dst` on 12
    that holds `public.marker` with one row: fails (the PG 14+ `BEGIN ATOMIC` function), the error is the
    importer's; `public.marker` and its row are still there; no temporary file remains.
  - `testCrossVersion12To18`: copy 12 → 18, whole database, Empty mode: every `rows …` and `sequence …` key of
    `describeDatabase:` matches.
  - `testCancelWhileReadingLeavesTargetUnchanged`: progress returns NO at Reading table 2: Cancelled, target
    unchanged (it held `public.marker`), no temporary file.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** the importer's `statementsBeforeImport`, the error code, and `SPPostgresTransfer`.
  The target's existing objects: one query per kind group matching the copy's `(kind, schema, name, arguments)`
  JSON against `pg_class` (any relkind except index, TOAST and composite type), `pg_type` (`typtype` e, c with a
  standalone `typrelid`, r, d) and `pg_proc` (with `pg_get_function_identity_arguments`). Dependencies existing on
  the target go to `skippedObjects`; non-dependencies existing go to the drops. The Overwrite dry run runs on the
  target connection before the dump: `BEGIN`, drops, `ROLLBACK` (also after a failure).
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 7 Task 2: the transfer engine`.

---

### Task 3: Background jobs with two connections

**Files:**
- Modify: `Source/Postgres/SPPostgresBackgroundJob.h/.m`
- Test: `PostgresTests/SPPostgresBackgroundJobTests.m` (create)

**Interfaces:**
- **Consumes:** `SPPostgresConnectionProvider`, `PGPostgresCancelToken`.
- **Produces:**
  `+ (instancetype)runOnDatabase:(NSString *)database provider:(SPPostgresConnectionProvider)provider targetDatabase:(NSString *)targetDatabase targetProvider:(SPPostgresConnectionProvider)targetProvider work:(BOOL (^)(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error))work completion:(void (^)(BOOL ok, NSError *error))completion;`
  - The source provider is asked first; the target provider only after the source connection arrived. If either
    fails, work isn't called, a connection already handed out is disconnected, and completion gets that error.
  - `waitingForConnection` is YES until both arrived. `-cancel` behaves as today for each state, with both cancel
    tokens signalled (every second until work returns).
  - The existing one-connection method keeps its behaviour and header comment, implemented on the same code.

- [ ] **Step 1: Write the failing tests** (live connections from `SPPostgresTestServers` through test providers):
  - `testBothConnectionsHandedToWork`: work sees two connected connections to the two databases asked for; both
    are disconnected after completion.
  - `testTargetProviderAskedAfterSource`: the target provider's block runs only after the source provider's
    completion was called (record the order).
  - `testTargetFailureSkipsWork`: target provider fails with `SPPostgresErrorConnectionFailed`: work not called,
    completion gets that error, the source connection is disconnected.
  - `testCancelWhileWaitingForTarget`: cancel after the source arrived but before the target provider answers:
    completion with `SPPostgresErrorCancelled`; the target connection handed out later is disconnected unused.
  - `testCancelInterruptsTargetLockWait`: a second session takes `LOCK TABLE` on a `pgkit_io_dst` table in an open
    transaction; work runs `LOCK TABLE` on the target connection and blocks; `-cancel` makes completion arrive
    within 5 seconds with work having seen the cancel error.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures, every Export and Import controller test included.
- [ ] **Step 5: Commit** with the message `Postgres Stage 7 Task 3: background jobs with two connections`.

---

### Task 4: The checkbox list, extracted from Export

**Files:**
- Create: `Source/Postgres/SPPostgresCheckList.h/.m`
- Modify: `Source/Postgres/SPPostgresExportController.m` (use it for its schemas and tables lists)
- Test: `PostgresTests/SPPostgresCheckListTests.m` (create); `SPPostgresExportControllerTests.m` unchanged and passing.

**Interfaces:**
- **Produces `SPPostgresCheckList : NSObject <NSTableViewDataSource, NSTableViewDelegate>`:**
  - `- (instancetype)initWithFrame:(NSRect)frame inView:(NSView *)view;`: adds a bordered scroll view holding a
    header-less table with columns `@"check"` (switch cell, 22 pt) and `@"name"`, as Export's today.
  - `@property (readonly) NSTableView *tableView;`
  - `@property (copy) NSArray *rows;`: each an `NSString` (a group row, bold, no checkbox) or an item; an item is
    `@[schema, table]` (shown as the table) or an `NSString` in a list without groups (`groupsByFirstElement` NO).
  - `@property BOOL groupsByFirstElement;` (YES: NSString rows are group rows).
  - `@property (readonly) NSArray *checkedItems;` (in row order);
    `- (void)setChecked:(BOOL)checked item:(id)item;`
  - `@property (copy) void (^checksChanged)(void);`
  - `+ (NSArray *)groupedRowsForCatalog:(SPPostgresCatalog *)catalog error:(NSError **)error;`: the schema
    group rows and `@[schema, table]` items Export builds today (schemas without tables left out).
- Export keeps every property and method in its header (`schemasTable`, `tablesTable`, `checkedSchemas`,
  `checkedTables`, `setChecked:schema:`, `setChecked:table:schema:`), now forwarding to its two lists.

- [ ] **Step 1: Write the failing tests**: `testGroupRowsHaveNoCheckbox`, `testCheckedItemsInRowOrder`,
  `testSettingRowsKeepsChecksOfItemsStillPresent`, `testChecksChangedCalledOnToggle` (through
  `tableView:setObjectValue:forTableColumn:row:`), `testGroupedRowsForCatalog` (on `pgkit_io_src`: group rows
  `public` and `Sales Data`, `@[@"Sales Data", @"Orders 2026"]` among the items).
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** and switch Export over.
- [ ] **Step 4: Run the full test suite.** Expected: 0 failures, every `SPPostgresExportControllerTests` unchanged.
- [ ] **Step 5: Commit** with the message `Postgres Stage 7 Task 4: SPPostgresCheckList, shared with Export`.

---

### Task 5: The Transfer sheet and the toolbar item

**Files:**
- Create: `Source/Postgres/SPPostgresTransferController.h/.m`
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`:
  - `- (IBAction)showTransfer:(id)sender;`, a `transferController` ivar like `exportController`, and
    `_canRunSheetJob` also requiring no `transferController`;
  - `_availableToolbarItemIdentifiers` gains `SPMainToolbarTransfer`;
  - `toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:` returns, for `SPMainToolbarTransfer`, a plain
    `NSToolbarItem` configured by `SPConfigureTransferToolbarItem` with target self and action `showTransfer:`;
  - `validateToolbarItem:` and `validateMenuItem:` for it: `_canRunSheetJob`.
- Test: `PostgresTests/SPPostgresTransferControllerTests.m` (create); update `SPPostgresToolbarTests.m` where it
  asserts the Postgres Transfer item is disabled (MySQL's assertions stay as they are).

**Interfaces:**
- **Consumes:** Task 2's engine, Task 3's two-connection job, Task 4's check list, Stage 6's progress sheet,
  `connectionProviderForJobWithSheetWindow:connecting:`, `SPPostgresConnector`, `SPPostgresConsoleLogger`,
  `SPPostgresFavoritesStore`, `SPKeychain`.
- **Produces `SPPostgresTransferController : NSObject <NSTextFieldDelegate>`:**
  - `- (instancetype)initWithDocument:(SPPostgresDocument *)document;` `- (void)beginSheet;`
    `@property (copy) void (^didEnd)(void);`
  - For tests: `sheet`, `wholeDatabaseRadio`, `selectedTablesRadio`, `tablesList` (`SPPostgresCheckList`),
    `favoritePopup`, `targetDescriptionField`, `databaseField`, `passwordField`, `emptyModeRadio`,
    `overwriteModeRadio`, `transferButton`, `progressSheet`, `lastErrorMessage`, `completionNote`,
    `- (IBAction)transfer:(id)sender;`, `- (IBAction)cancel:(id)sender;`.
  - Seams:
    - `@property (copy) NSArray *favorites;`: default `[[SPPostgresFavoritesStore sharedStore] favorites]`, read
      in `beginSheet` only when nil.
    - `@property (copy) SPPostgresConnectionProvider (^targetProviderForFavorite)(SPPostgresFavorite *favorite, NSString *password);`:
      nil means the default (a connector with the typed or Keychain password and the Keychain SSH password,
      `parentWindow` the progress sheet's panel, console logger named after the favorite, kept until the job ends).
    - `@property (copy) void (^emptyConfirmation)(NSString *database, NSString *targetDescription, void (^answer)(BOOL confirmed));`:
      nil shows `-emptyConfirmationAlertForDatabase:targetDescription:` as a sheet.
    - `- (NSAlert *)emptyConfirmationAlertForDatabase:(NSString *)database targetDescription:(NSString *)description;`
      (its accessory is an `NSTextField`; its first button is **Empty and Transfer**, `hasDestructiveAction`).
    - `@property (copy) void (^progressObserver)(SPPostgresProgressSheet *sheet);` (as Export's).
    - `@property (copy) NSString *temporaryDirectory;` passed to the engine.
  - Copy (exact): title "Transfer"; scope radios "Whole database “<db>”" / "Selected tables"; "To:" pop-up; "Database:";
    "Password:" with placeholder "Saved in Keychain"; mode radios "Empty the target database first" / "Overwrite
    tables that already exist on the target"; buttons "Cancel" / "Transfer". Confirmation: message "Empty “<db>”
    and transfer into it?", informative "Everything in database “<db>” on <targetDescription> will be deleted: all
    schemas (including public), tables, views, functions, types and extensions. Other databases on that server
    aren't touched.\n\nType the database's name to confirm." Alerts as in the decisions.
- [ ] **Step 1: Write the failing tests**, on both ports, with a document connected to `pgkit_io_src` (as
  `SPPostgresExportControllerTests` does), `alertPresenter` collecting alerts, `favorites` set to one in-memory
  `SPPostgresFavorite` named "Test target" with database `pgkit_io_dst`, and `targetProviderForFavorite` returning
  `SPPostgresTestServers` connections:
  - `testDefaults`: whole database selected, Empty mode selected, the database field shows `pgkit_io_dst`, the
    target line shows `pgkit_test@127.0.0.1:<port>`, Transfer enabled.
  - `testTransferDisabledWithoutTablesOrDatabase`: Selected tables with none checked → disabled; empty database
    field → disabled; no favorites → pop-up disabled and Transfer disabled.
  - `testDatabaseFollowsFavoriteUntilEdited`: two favorites; switching changes the field; after typing in it,
    switching no longer does.
  - `testEmptyConfirmationNeedsExactName`: the alert's button is disabled for `""`, `pgkit_io_ds`, `PGKIT_IO_DST`,
    `pgkit_io_dst ` and enabled for `pgkit_io_dst`. With `emptyConfirmation` answering NO, Transfer asks no provider.
  - `testWholeDatabaseTransferEndToEnd`: confirm YES, run, wait for `didEnd`: the target's rows match the source's,
    `completionNote` starts with "Copied", one alert titled "Transfer complete".
  - `testOverwriteBlockedShowsWhatIsInTheWay`: as Task 2's blocked case through the sheet: `lastErrorMessage`
    contains "wasn't changed" and the view's name.
  - `testCancelDuringTransfer`: `progressObserver` cancels at the first Reading report: target unchanged, the
    sheet ends, `lastErrorMessage` is the cancel message.
  - `testToolbarTransferItemEnabledOnPostgresTab`: the document's item for `SPMainToolbarTransfer` is not an
    `SPDisabledToolbarItem`, has action `showTransfer:`, and validates YES when connected and NO while
    `exportController` is up; a MySQL document's Transfer item is still an `SPDisabledToolbarItem`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** with the message `Postgres Stage 7 Task 5: the Transfer sheet and toolbar item`.
