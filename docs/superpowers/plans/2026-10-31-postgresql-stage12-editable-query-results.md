# PostgreSQL Stage 12: Editable Query Results Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cells in the Postgres Query tab's results can be edited as MySQL's: inline or in the field editor sheet (per the edit mode toggle), saved with an UPDATE that identifies the row, and refused with MySQL's explanation where the row can't be identified.

**Architecture:**
- PostgresKit's `PGPostgresResult` gains each field's origin (libpq `PQftable` / `PQftablecol`).
- A new model class, `SPPostgresQueryResultEditor`, wraps one shown result. It owns:
  - the values the grid shows, including the edits made since the run
  - each column's origin table and column, looked up lazily in the catalog
  - MySQL's per-cell rule: whether a cell is editable, and which WHERE identifies its row
  - the UPDATE itself
- `SPPostgresQueryController` keeps only the glue: the table view delegate, refusals, alerts, and the reload after an edit. The new logic stays out of its 2,780-line file.
- The field editor sheet code moves out of `SPPostgresContentController` into `SPPostgresFieldEditorSheet`, so the Content and Query tabs share it.

**Tech Stack:** Objective-C (MRC in `Source/Postgres` and `Frameworks/PostgresKit`, ARC in "Postgres Tests"), AppKit built in code, libpq, XCTest against the Docker PG12/PG18 servers.

**Spec:** `docs/superpowers/specs/2026-10-29-postgresql-mysql-parity-ui-design.md`. The relevant sections are "Stage 12: editable query results", "Shared settings", "Anti-goals" and "Decisions" ("Short writes stay synchronous").

## Global Constraints

- **No MySQL source edits.**
  - `SPFieldEditorController`, `SPTooltip`, `SPTableView`, the `SPConstants` keys and MySQL's localized strings may be reused, but no file outside these changes:
    - `Source/Postgres`
    - `Frameworks/PostgresKit/Source/PGPostgresResult.{h,m}`
    - `PostgresTests`
    - `docs`
  - MySQL's tests and toolbar parity tests stay green.
- **Shared preferences, read as MySQL reads them, through the controller's `defaults`:**
  - `EditInSheetEnabled` (`SPEditInSheetEnabled`): edit in the sheet.
  - `ReloadAfterEditingRow` (`SPReloadAfterEditingRow`): reload after a saved edit.
  - `NullValue` (`SPNullValue`): the NULL placeholder.
- **Tests:**
  - They never write real preferences. A test that writes a default injects `[[NSUserDefaults alloc] initWithSuiteName:@"SPPostgresStage12Tests"]` and calls `removePersistentDomainForName:` in tearDown.
  - They never open a real sheet or tooltip. They use the `fieldEditorPresenter`, `alertPresenter` and `editRefusalPresenter` seams.
- **Stage 8 rules:**
  - Nothing is edited, and no sheet opens, while `[taskRunner isBusy]`. MySQL does the same: NO while the document is working.
  - The edit-time catalog lookup, match count and UPDATE run synchronously on the main thread only while the runner is idle ("Short writes stay synchronous").
  - The reload after an edit is a normal run through the runner.
- **Transactions:** every write goes through `SPPostgresRunAtomically`, and every read through `SPPostgresRunGuardedRead`. Inside the user's open transaction they use a savepoint, so a failure leaves that transaction open. Inside an aborted transaction the write is refused.
- **SQL:**
  - Identifiers are always quoted with `SPPostgresQuoteIdentifier`.
  - Values are always sent as `$n` parameters.
  - No CASCADE, no DDL.
- **New files:** add them only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test <paths>`. Exported classes are marked `__attribute__((visibility("default")))`.
- **Commits:** trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never touch the untracked `start_clause.sh`.
- **Test commands** (start the servers first with `bash Scripts/pg-test-servers.sh up`):
  - one class: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64 -only-testing:"Postgres Tests"/<Class>`
  - full suite: same without `-only-testing`, `timeout 1500`
  - app: `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`

### MySQL reference (what "as MySQL" means here)

All of this is in `Source/SPCustomQuery.m`.

- **The rule is per cell, not per result** (`fieldEditStatusForRow:andColumn:`, `argumentForRow:ofTable:andDatabase:includeBlobs:`):
  - A column with no single origin table (an expression, UNION, `SELECT 1`) is not editable.
  - Otherwise the row is identified by the origin table's primary-key columns present in the result. With none of them present, it uses every result column from that table.
  - `SELECT COUNT(1) … WHERE` on those values must be exactly 1.
- **Inline refusal** (`control:textShouldBeginEditing:`): `NSBeep()` and an `SPTooltip` under the cell with one of three messages. Postgres uses MySQL's strings, set from the `init` of `SPCustomQuery.m`:
  - **-1:** "Field is not editable. Field has no or multiple table or database origin(s)."
  - **0:** "Field is not editable. No matching record found.\nReload data, check encoding, or try to add\na primary key field or more fields\nin your SELECT statement for table '%@'\nto identify field origin unambiguously."
  - **>1:** "Field is not editable. Couldn't identify field origin unambiguously (%ld matches)."
- **Sheet** (`tableView:shouldEditTableColumn:row:`): when `shouldUseFieldEditorForRow:` holds (edit mode on), the sheet opens. It is editable only when the count is 1, and read-only otherwise.
- **Save** (`saveCellValue:forTableColumn:row:`):
  - It re-checks the count, then sends `UPDATE … SET col = value WHERE … LIMIT 1`.
  - The value's placeholder text means NULL.
  - Errors:
    - a failed UPDATE: alert "Error" / "Couldn't write field.\nMySQL said: %@"
    - a count that isn't 1: alert "Error" / "Updating field content failed. Couldn't identify field origin unambiguously (%1$ld matches). It's very likely that while editing this field of table `%2$@` was changed."
  - Afterwards:
    - with `ReloadAfterEditingRow` on, it re-runs the last executed query, keeping the selection and scroll position (`storeCurrentResultViewForRestoration`)
    - with it off, it replaces the cell's value in place

## Rulings in this plan (the owner may overrule)

1. **Per-cell rule, as MySQL's.** The spec says "all its columns come from one table that has a primary key (or the conditions MySQL uses)". MySQL's actual rule is per cell, so each origin table's columns are editable on their own (a join is partly editable). Tables without a primary key are editable where the values match exactly one row. MySQL's blob-first refinement is dropped: all identifying columns are always used.
2. **Atomic save, no LIMIT 1.** PostgreSQL has no `UPDATE … LIMIT`. The UPDATE runs in `SPPostgresRunAtomically` and is undone unless it changed exactly 1 row, so it can never change two rows.
3. **The inline check runs when editing starts** (double-click or Return) rather than at the first keystroke. A refused cell beeps and shows the tooltip without opening the in-cell editor.
4. **Postgres-only refusals get their own messages,** shown the same way:
   - a view or other non-table
   - a generated or `GENERATED ALWAYS` identity column
   - an aborted transaction
   - a failed catalog lookup
5. **The reload re-runs only a read.** With `ReloadAfterEditingRow` on, only the statement that produced the shown result is re-run, and only when `statementMayChangeData:` and `statementMayChangeSchema:` are both NO. Otherwise the grid keeps the value the server returned (`RETURNING`), so an edit never re-runs an `INSERT … RETURNING`. The reload adds no history entry.
6. **Values follow the Content tab, not MySQL:**
   - An unchanged value sends nothing.
   - The NULL placeholder means NULL only where the column is nullable.
   - An empty string is sent as `''`; MySQL turns it into NULL for numbers and dates.
7. **Test connections:** before this stage adds tests, connections opened during a test are closed when it ends (Task 1), as the Stage 11 final review recommended.
8. **No move of existing code** out of `SPPostgresQueryController.m`. New logic goes into new classes instead; a wider split stays optional.

## Review Focus

1. **A join of two tables** (`SELECT o.id, o.note, c.name FROM orders o JOIN customers c …`): each table's columns edit their own table by their own key, and an expression column is refused with the "-1" message. Covered by Task 3's `testJoinColumnsEditTheirOwnTable` and Task 4's `testJoinUpdatesOnlyTheOriginTable`.
2. **An open or aborted transaction in the Query tab:**
   - After `BEGIN` an edit goes into a savepoint and the transaction stays open.
   - After a failed statement in the transaction, the edit is refused with the aborted message and nothing is sent.
   - Covered by Task 4's `testEditInsideOpenTransactionKeepsItOpen` and `testEditInsideAbortedTransactionIsRefused`.
3. **Editing a key, then another cell of the same row:** the second edit finds the row by the new key. Covered by Task 4's `testSecondEditUsesEditedKey`.
4. **No primary key and duplicate rows:**
   - The count is 2, so the cell is refused with "(2 matches)".
   - A save whose rows became duplicates since the check is rolled back.
   - Covered by Task 3's `testDuplicateRowsWithoutKeyCountTwo` and Task 4's `testUpdateMatchingTwoRowsIsRolledBack`.
5. **Types without `=`, and quoted names:**
   - A `json` or `point` column in a table without a key still identifies its row, because it is compared as `::text`.
   - `"Sales Data"."Mixed Case"`-style names are quoted.
   - Covered by Task 3's `testTextComparisonForTypesWithoutEquality` and Task 4's `testMixedCaseNamesUpdate`.

## Test fixture (Tasks 3, 4, 6, 7)

The test fixture is a schema `query_edit_test`, dropped and rebuilt in each test class's `setUp` on both ports. It is built with `SPPostgresExecute` on a test connection:

- `items (id integer PRIMARY KEY, name text, price numeric(8,2), doc json, twice integer GENERATED ALWAYS AS (id * 2) STORED)`, rows (1,'one',1.50,'{"a":1}'), (2,'two',NULL,NULL)
- `pair (a integer, b integer, v text, PRIMARY KEY (a, b))`, rows (1,1,'x'), (1,2,'y')
- `nokey (n integer, t text, p point)`, rows (1,'a','(1,1)'), (1,'a','(1,1)'), (2,'b','(2,2)')
- `"Mixed Case" ("Key" integer PRIMARY KEY, "Value" text)`, row (1,'v')
- `customers (id integer PRIMARY KEY, name text)` (1,'Ann'); `orders (id integer PRIMARY KEY, customer integer, note text)` (10,1,'first')
- `VIEW items_view AS SELECT id, name FROM items`

Tests run against both servers (`[SPPostgresTestServers ports]`), as the existing classes do.

---

### Task 1: Test connections close when their test ends

**Files:**
- Modify: `PostgresTests/SPPostgresTestServers.{h,m}`
- Create: `PostgresTests/SPPostgresTestServersTests.m`

**Interfaces:**
- Produces:
  - `+ (void)disconnectConnectionsOpenedDuringCurrentTest;` on `SPPostgresTestServers`.
  - An `XCTestObservation` observer, registered once (from `+load` of a small observer class in `SPPostgresTestServers.m`). Its `testCaseWillStart:` starts tracking. Its `testCaseDidFinish:` disconnects every connection that `+connectedConnectionOnPort:…`, `+ioConnectionOnPort:database:` and `+extensionTestConnectionOnPort:` handed out since the test started.
  - Connections opened outside a test case (a class `+setUp`) are not tracked. PostgresKit's connection ↔ type-handler retain cycle means an untracked connection is never closed, so test classes must not rely on dealloc.

- [ ] **Step 1: Write the failing tests** in `SPPostgresTestServersTests`:
  - `testConnectionsOpenedInTestAreDisconnected`: open two connections with `connectedConnectionOnPort:`, call `+disconnectConnectionsOpenedDuringCurrentTest`, and `XCTAssertFalse([c isConnected])` for both.
  - `testAlreadyDisconnectedConnectionIsSkipped`: disconnect one first, then call the method; no exception, and the other is disconnected.
- [ ] **Step 2: Run it** (`-only-testing:"Postgres Tests"/SPPostgresTestServersTests`). Expected: FAIL, the method is unknown.
- [ ] **Step 3: Implement it.**
  - Keep a strong `NSMutableArray` of the connections handed out while a test runs, guarded by `@synchronized`.
  - Clear it at `testCaseWillStart:` and after disconnecting.
  - Disconnect only connections that are still `isConnected`.
- [ ] **Step 4: Run the class, then the full suite.** Expected: both pass. While the full suite runs, poll `SELECT count(*) FROM pg_stat_activity WHERE usename = 'pgkit_test'` on 55418 every few seconds from a shell loop. Record the peak in the report; it was 91 before.
- [ ] **Step 5: Commit** `Postgres tests: connections opened during a test are closed when it ends`.

### Task 2: PostgresKit field origins

**Files:**
- Modify: `Frameworks/PostgresKit/Source/PGPostgresResult.{h,m}`
- Test: `PostgresTests/SPPostgresQueryResultEditorTests.m` (create; it is shared with Tasks 3–4)

**Interfaces:**
- Produces:
  - `- (PGPostgresOid)tableOIDForField:(NSUInteger)field;` returns `PQftable`, or 0 when the field is not a plain column of a table or view, or is out of range.
  - `- (NSInteger)tableColumnForField:(NSUInteger)field;` returns `PQftablecol` (the attnum), or 0 likewise.

- [ ] **Step 1: Write the failing test** `testFieldOrigins` on both ports:
  - Run `SELECT i.name, i.id, 1 AS one, i.id + 1 AS next FROM query_edit_test.items i` through `[connection execute:]`.
  - `tableOIDForField:0` equals `(SELECT 'query_edit_test.items'::regclass::oid)`, read as text and compared as an integer.
  - `tableColumnForField:0` == 2 and `tableColumnForField:1` == 1.
  - Fields 2 and 3 give 0 and 0.
  - `tableOIDForField:99` == 0.
- [ ] **Step 2: Run it.** Expected: FAIL to compile.
- [ ] **Step 3: Implement both methods** with libpq's `PQftable` / `PQftablecol`, guarded by `_result` and `field < _numberOfFields`.
- [ ] **Step 4: Run it.** Expected: PASS.
- [ ] **Step 5: Commit** `PostgresKit: a result field's origin table and column`.

### Task 3: SPPostgresQueryResultEditor: values and editability

**Files:**
- Create: `Source/Postgres/SPPostgresQueryResultEditor.{h,m}`
- Test: `PostgresTests/SPPostgresQueryResultEditorTests.m`

**Interfaces:**
- Consumes: Task 2's origin methods; `SPPostgresExecute`, `SPPostgresRunGuardedRead`, `SPPostgresQuoteIdentifier` (`SPPostgresTableData.h`); `SPPostgresMakeError` and the error codes in `SPPostgresErrors.h`.
- Produces:

```objc
typedef NS_ENUM(NSInteger, SPPostgresCellEditability) {
	SPPostgresCellEditable = 0,            // exactly one row matches
	SPPostgresCellNoOrigin,                // MySQL's -1: expression, no single table
	SPPostgresCellNoMatch,                 // MySQL's 0
	SPPostgresCellTooManyMatches,          // MySQL's >1
	SPPostgresCellNotATable,               // view, materialized view, foreign table…
	SPPostgresCellGeneratedColumn,         // GENERATED … STORED or GENERATED ALWAYS identity
	SPPostgresCellCheckFailed              // catalog lookup or count failed (aborted transaction, lost connection)
};

__attribute__((visibility("default")))
@interface SPPostgresQueryResultEditor : NSObject
- (instancetype)initWithResult:(PGPostgresResult *)result connection:(PGPostgresConnection *)connection;
@property (readonly) PGPostgresResult *result;
- (NSUInteger)rowCount;
- (NSUInteger)columnCount;
/// The cell's text (NSString) or NSNull, with this editor's saved edits applied.
- (id)valueAtRow:(NSUInteger)row column:(NSUInteger)column;
/// Checks the cell (catalog lookup once per editor, then a count). matchCount is the count (or -1 when not counted);
/// message is the explanation to show when not editable (MySQL's text for NoOrigin/NoMatch/TooManyMatches), else nil.
- (SPPostgresCellEditability)editabilityOfRow:(NSUInteger)row column:(NSUInteger)column
								   matchCount:(NSInteger *)matchCount message:(NSString **)message;
/// For the field editor sheet: the origin column's type (format_type, typmod -1) or nil; nullable is YES when unknown.
- (NSString *)typeNameOfColumn:(NSUInteger)column;
- (BOOL)columnIsNullable:(NSUInteger)column;
/// "schema"."table" of the column's origin, quoted, or nil.
- (NSString *)qualifiedTableNameOfColumn:(NSUInteger)column;
@end
```

- **The catalog lookup is one query for all of the result's origin OIDs, through `SPPostgresRunGuardedRead`** with the savepoint `sp_query_edit_read`. Per attribute it reads:
  - the schema, the relname and the relkind
  - attnum and attname
  - `format_type(atttypid, -1)`
  - nullable, i.e. NOT attnotnull
  - `(attidentity = 'a' OR attgenerated <> '')`
  - the primary-key position, from `pg_index.indisprimary` via `unnest(indkey::int2[]) WITH ORDINALITY`, as `SPPostgresTableData`'s metadata query does

  It is filtered by `c.oid = ANY($1::oid[])` and covers every live column of those tables, so key columns missing from the result are still known.
- **The rule for cell (r, c):**
  1. No origin → NoOrigin.
  2. relkind not `r`/`p` → NotATable.
  3. Generated → GeneratedColumn.
  4. Otherwise the identifying columns are the result columns from the same origin OID that are part of that table's primary key. If none are present, they are all result columns from that OID. A result column that repeats an attnum counts once.
  5. Then the count is `SELECT count(*) FROM "s"."t" WHERE …`:
     - each key column is `"col" = $n::<type>`
     - each other column is `"col"::text = $n`
     - a NULL value is `"col" IS NULL`
  6. A count of 0 gives NoMatch, more than 1 gives TooManyMatches, and exactly 1 gives Editable.
- **Messages:**
  - NoOrigin, NoMatch (with the relname, unquoted, as MySQL's `org_table`) and TooManyMatches use MySQL's exact strings and comments (see the MySQL reference).
  - NotATable: "This is a view, so its rows can't be edited." for `v`/`m`, else "This is not a table, so its rows can't be edited." These are `SPPostgresTableData`'s strings.
  - GeneratedColumn: "This column is generated, so it can't be edited."
  - CheckFailed: the error's localized description.

- [ ] **Step 1: Write the failing tests** (fixture above, both ports). Each one runs the SELECT through `[connection execute:]` and builds an editor from it:
  - `testValuesAreResultTextAndNull`: `SELECT id, price FROM query_edit_test.items ORDER BY id`. Values `@"1"`, `@"1.50"`, `@"2"`, and NSNull for row 1, column 1.
  - `testKeyedTableCellIsEditable`: `SELECT name, id FROM …items ORDER BY id`, cell (0,0). Editable with matchCount 1.
  - `testExpressionIsNoOrigin`: `SELECT id, upper(name) FROM …items`, cell (0,1). NoOrigin, with message equal to MySQL's -1 string.
  - `testViewIsNotATable`: `SELECT id, name FROM …items_view`, cell (0,1). NotATable, with the view message.
  - `testGeneratedColumnRefused`: `SELECT id, twice FROM …items`, cell (0,1). GeneratedColumn.
  - `testDuplicateRowsWithoutKeyCountTwo`: `SELECT n, t FROM …nokey ORDER BY n`, cell (0,1). TooManyMatches, matchCount 2, and the message contains "(2 matches)". Cell (2,1) is Editable.
  - `testPartialKeyFallsBackToCount`: `SELECT a, v FROM …pair ORDER BY a, b`, cell (0,1). TooManyMatches, because a = 1 matches 2 rows, as MySQL's partial-key rule gives. `SELECT a, b, v` (0,2) is Editable.
  - `testJoinColumnsEditTheirOwnTable`: `SELECT o.id, o.note, c.id, c.name, o.note || c.name FROM …orders o JOIN …customers c ON c.id = o.customer`. Cells (0,1) and (0,3) are Editable; `qualifiedTableNameOfColumn:3` is `"query_edit_test"."customers"`; (0,4) is NoOrigin.
  - `testTextComparisonForTypesWithoutEquality`: `SELECT n, t, p FROM …nokey WHERE n = 2`, cell (0,1). Editable, which proves `point` is compared as text.
  - `testCatalogLookupRunsOnce`: count the statements the editor sends (a `PGPostgresConnection` delegate, or wrap with the console logger hook the other tests use). Two checks on the same editor send one catalog query.
  - `testCheckInAbortedTransactionFails`: `BEGIN`, a failing statement, then a check gives CheckFailed with a non-empty message. ROLLBACK in teardown.
- [ ] **Step 2: Run it.** Expected: FAIL, the class is unknown.
- [ ] **Step 3: Implement the class** (MRC). It retains the result and the connection. The catalog lookup is cached in an ivar per editor; a failed lookup is not cached, so a later check retries.
- [ ] **Step 4: Run it.** Expected: PASS on both ports.
- [ ] **Step 5: Commit** `Postgres query results: per-cell editability, as MySQL's rule`.

### Task 4: SPPostgresQueryResultEditor: saving an edit

**Files:**
- Modify: `Source/Postgres/SPPostgresQueryResultEditor.{h,m}`
- Test: `PostgresTests/SPPostgresQueryResultEditorTests.m`

**Interfaces:**
- Consumes: Task 3's rule (the same identifying columns and WHERE); `SPPostgresRunAtomically`.
- Produces:

```objc
/// Sets the cell's origin column in the one row the cell's values identify. value: NSString or NSNull. On success the
/// server's text of the new value (NSString or NSNull) replaces the cell, and every result column of the same origin
/// column in that row, and is returned. On failure nil; matchCount (if given) is the rows the UPDATE matched when that
/// was not 1, else -1.
- (id)saveValue:(id)value row:(NSUInteger)row column:(NSUInteger)column matchCount:(NSInteger *)matchCount error:(NSError **)error;
```

- **SQL:** `UPDATE "s"."t" SET "col" = $1::<type> WHERE <Task 3's conditions, numbered from $2> RETURNING "col"::text`, inside `SPPostgresRunAtomically` with the savepoint `sp_query_edit` and the aborted message "The current transaction is aborted, so the row was not changed. Roll it back first." (`SPPostgresTableData`'s string).
  - Unless `numberOfRows` of the result is exactly 1, the body returns NO, which undoes it. The error is `SPPostgresErrorRowChanged`.
  - Its description is MySQL's "Updating field content failed. Couldn't identify field origin unambiguously (%1$ld matches). It's very likely that while editing this field of table %2$@ was changed.", with the table quoted the PostgreSQL way (`"s"."t"`) instead of in backticks. Ruling 1.
- A cell that isn't editable by Task 3's rule (other than the count) fails with `SPPostgresErrorNotEditable` and its message, without an UPDATE.

- [ ] **Step 1: Write the failing tests** (both ports). Each one verifies the server with a fresh `SELECT`:
  - `testSaveUpdatesRowAndCell`: `SELECT id, name FROM …items ORDER BY id`, save `@"uno"` at (0,1). It returns `@"uno"`, `valueAtRow:0 column:1` is `@"uno"`, the server has `uno` for id 1, and id 2 is unchanged.
  - `testSaveNullAndServerFormat`: save NSNull into `name`, then `@"3.5"` into `price`. These return NSNull and `@"3.50"`, the server's format.
  - `testSecondEditUsesEditedKey`: save `@"5"` into `id` at row 0, then `@"five"` into `name` of row 0. The server has (5,'five').
  - `testDuplicateResultColumnsUpdatedTogether`: `SELECT id, name, name FROM …items`, save at (0,1). Columns 1 and 2 both show the new value.
  - `testUpdateMatchingTwoRowsIsRolledBack`: `SELECT n, t FROM …nokey WHERE n = 2`. On a second connection, `INSERT` a duplicate (2,'b','(2,2)'), then save `@"z"` at (0,1). It returns nil with `SPPostgresErrorRowChanged`, matchCount 2, and the message contains "(2 matches)". The server still has no 'z'.
  - `testRowDeletedMeanwhileMatchesZero`: delete the row from a second connection, then save. Nil, matchCount 0.
  - `testJoinUpdatesOnlyTheOriginTable`: the join from Task 3; save `@"Bea"` at (0,3). `customers` has Bea and `orders` is unchanged.
  - `testMixedCaseNamesUpdate`: `SELECT "Key", "Value" FROM query_edit_test."Mixed Case"`, save at (0,1). The server has the new value.
  - `testEditInsideOpenTransactionKeepsItOpen`: `BEGIN`, then save. `[connection transactionStatus]` is still in-transaction, and after `ROLLBACK` the server has the old value.
  - `testEditInsideAbortedTransactionIsRefused`: `BEGIN` and a failing statement, then save. Nil with the aborted message; after `ROLLBACK` the value is unchanged.
  - `testBadValueReportsServerError`: save `@"abc"` into `id`. Nil, and the error description contains `invalid input syntax`.
- [ ] **Step 2: Run it.** Expected: FAIL, the selector is unknown.
- [ ] **Step 3: Implement `saveValue:row:column:matchCount:error:`.** Edits are kept in an `NSMutableDictionary` keyed by `@[@(row), @(column)]`, which `valueAtRow:column:` reads first.
- [ ] **Step 4: Run it.** Expected: PASS on both ports.
- [ ] **Step 5: Commit** `Postgres query results: save an edit by the row's key, atomically`.

### Task 5: SPPostgresFieldEditorSheet, shared with the Content tab

**Files:**
- Create: `Source/Postgres/SPPostgresFieldEditorSheet.{h,m}`
- Modify: `Source/Postgres/SPPostgresContentController.m`, whose `_showFieldEditorWithValue:…`, `processFieldEditorResult:`, `fieldEditorSelectedRange` and `setFieldEditorSelectedRange:` move out, and whose ivars `fieldEditor`, `fieldEditorType` and `fieldEditorCompletion` go.
- Test: `PostgresTests/SPPostgresContentBarTests.m` (existing, must stay green); new tests in `PostgresTests/SPPostgresFieldEditorSheetTests.m`

**Interfaces:**
- Produces:

```objc
__attribute__((visibility("default")))
@interface SPPostgresFieldEditorSheet : NSObject
/// MySQL's SPFieldEditorController as a sheet on window. completion gets the new value (NSString; a loaded file as
/// UTF-8 text, or nil with NSBeep when it isn't UTF-8) or nil when cancelled or not editable. Calls completion(nil) at
/// once when window is nil, already has a sheet, or another SPPostgresFieldEditorSheet is open on it.
+ (void)editValue:(NSString *)value columnName:(NSString *)columnName typeName:(NSString *)typeName
		 editable:(BOOL)editable allowNull:(BOOL)allowNull window:(NSWindow *)window completion:(void (^)(id newValue))completion;
/// The type passed to SPFieldEditorController: @"" for the MySQL-only types (BIT, JSON, GEOMETRY, BINARY, VARBINARY,
/// FLOAT, case-insensitive) and nil, else typeName.
+ (NSString *)fieldEditorTypeForTypeName:(NSString *)typeName;
@end
```

- The sheet object keeps itself alive while open, retaining itself until `processFieldEditorResult:` has returned (autorelease, as the Content code does now). The Content controller keeps its `fieldEditorPresenter` seam, its `once` block and its `makeFirstResponder:` call, the latter moved into its completion.

- [ ] **Step 1: Write the failing tests** in `SPPostgresFieldEditorSheetTests`:
  - `testMySQLOnlyTypesBlanked`: `json`, `JSON`, `bit`, `float` and nil give `@""`; `integer` and `text` are returned unchanged.
  - `testNoWindowCompletesWithNil`: `window:nil`, and the completion runs synchronously with nil.
- [ ] **Step 2: Run it.** Expected: FAIL, the class is unknown.
- [ ] **Step 3: Implement it and switch the Content controller over.** There is no behaviour change in Content.
- [ ] **Step 4: Run `SPPostgresFieldEditorSheetTests`, `SPPostgresContentBarTests` and `SPPostgresContentControllerTests`.** Expected: all PASS.
- [ ] **Step 5: Commit** `Postgres: the field editor sheet shared by the Content and Query tabs`.

### Task 6: Query tab: inline editing, refusals, save, reload

**Files:**
- Modify: `Source/Postgres/SPPostgresQueryController.{h,m}`
- Create: `PostgresTests/SPPostgresQueryEditingTests.m`

**Interfaces:**
- Consumes: Tasks 3–4 (`SPPostgresQueryResultEditor`); the existing `taskRunner`, `defaults`, `alertPresenter`, `runDidChangeDatabase`, `_runStatements:`, `statementMayChangeData:` / `statementMayChangeSchema:` and `SPPostgresQueryRun`'s `shownStatement` / `ranStatements`.
- Produces (in `SPPostgresQueryController.h`):

```objc
/// Test seam: shows why a cell can't be edited (default: NSBeep and an SPTooltip under the cell, as MySQL's).
@property (copy) void (^editRefusalPresenter)(NSString *message, NSInteger row, NSInteger column);
/// The editor of the shown result (nil when none).
@property (readonly) SPPostgresQueryResultEditor *resultEditor;
```

- **`_showResult:`:**
  - It makes a new `SPPostgresQueryResultEditor`, or nil when there is no result.
  - It records the shown statement's text, `ranStatements[shownStatement - 1]`.
  - Columns and cells become editable (`setEditable:YES`).
  - `_valueAtRow:tableColumn:` and `lastResultRows` read the editor's `valueAtRow:column:`, so export includes edits.
- **`tableView:shouldEditTableColumn:row:`:**
  - NO when invalidated, while the runner is busy, or with no editor.
  - In edit mode (`EditInSheetEnabled` through `defaults`), Task 7's sheet path.
  - Otherwise it asks the editor. When the cell isn't Editable, it calls the refusal presenter with the message and returns NO. When it is, it returns YES.
- **`tableView:setObjectValue:forTableColumn:row:` → `_commitValue:row:column:`:**
  1. The placeholder means NULL where the column is nullable.
  2. An unchanged value is a no-op.
  3. While busy the value is not sent.
  4. Otherwise it sends `saveValue:…`.
- **On failure:**
  - `SPPostgresErrorRowChanged` gives the alert "Error" with the error's description.
  - Anything else gives "Error" / "Couldn't write field.\nPostgreSQL said: %@". This is a new string modelled on MySQL's.
  - Alerts go through `alertPresenter`, and the grid redisplays the old value.
- **On success:**
  1. `runDidChangeDatabase(NO, YES)`.
  2. If `ReloadAfterEditingRow` is on and the shown statement may change neither data nor schema, re-run that one statement (Ruling 5):
     - not added to history
     - `lastRunQueryText` left as it was
     - the selected rows and the scroll position restored after the run
     - never started while a cell is being edited: deferred, as `SPPostgresContentController`'s `reloadPending` / `controlTextDidEndEditing:` does, until that edit ends
  3. Otherwise only the row is redisplayed.
- A database switch or `invalidate` drops the editor.

- [ ] **Step 1: Write the failing tests** (fixture, both ports, inline runner as `SPPostgresQueryControllerTests` sets up). Run the SELECT through `runAllQueries:` and drive the grid through the data source and delegate methods:
  - `testKeyedCellEditsInline`: `shouldEditTableColumn` is YES for `name` of `SELECT id, name FROM …items ORDER BY id`. `setObjectValue:@"uno"` updates the server, and the grid's object value is `@"uno"`.
  - `testExpressionCellRefusedWithMySQLMessage`: `SELECT id, id + 1 FROM …items`. `shouldEdit` on column 1 is NO, and the refusal presenter got MySQL's -1 string.
  - `testDuplicateRowsRefusedWithMatchCount`: `nokey`. The presenter's message contains "(2 matches)".
  - `testEditRefusedWhileRunnerBusy`: queue a sleep on the runner (`queueSleep:onRunner:`). `shouldEdit` is NO, and the presenter is not called.
  - `testSaveErrorShowsAlert`: `@"abc"` into `id`. The alert's informative text starts "Couldn't write field.\nPostgreSQL said:".
  - `testReloadAfterEditRerunsSelect`: `ReloadAfterEditingRow` YES in the injected defaults.
    - The statement hook (`setStatementWillRunHook:`) sees the SELECT run again after the save.
    - The history store has one entry, not two.
    - The selected row is still selected.
  - `testNoReloadWhenPreferenceOff`: with it NO, the hook sees no second run, and the cell shows the saved value.
  - `testDataChangingStatementIsNotRerun`: `UPDATE …items SET name = name WHERE id = 1 RETURNING id, name` is the shown result. After an edit of `name`, there is no re-run with the preference on, and the cell shows the new value.
  - `testEditTellsTabDataChanged`: the `runDidChangeDatabase` block gets (NO, YES).
  - `testExportIncludesEdits`: `lastResultRows` has the edited value.
  - `testNullPlaceholderSavesNull`: the placeholder into `name` gives SQL NULL on the server.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement it.** The default refusal presenter calls `NSBeep()` and `[SPTooltip showWithObject:message atLocation:<the cell's screen origin, y − 20> ofType:@"text"]`, as MySQL's `control:textShouldBeginEditing:` does.
- [ ] **Step 4: Run `SPPostgresQueryEditingTests`, `SPPostgresQueryControllerTests` and `SPPostgresQueryBarTests`.** Expected: PASS.
- [ ] **Step 5: Commit** `Postgres Query tab: edit result cells inline, as MySQL's`.

### Task 7: Query tab: edit mode toggle and the field editor sheet

**Files:**
- Modify: `Source/Postgres/SPPostgresQueryController.{h,m}`
- Test: `PostgresTests/SPPostgresQueryEditingTests.m`

**Interfaces:**
- Consumes: Task 5's `SPPostgresFieldEditorSheet`; Task 6's `_commitValue:row:column:`.
- Produces:

```objc
/// Test seam, as SPPostgresContentController's: presents the field editor instead of the sheet.
@property (copy) void (^fieldEditorPresenter)(NSString *value, NSString *columnName, NSString *typeName, BOOL editable, BOOL allowNull, void (^completion)(id newValue));
```

- **In edit mode, `shouldEdit` opens the sheet and returns NO** (MySQL's behaviour):
  - It shows the cell's text, or the placeholder for NULL.
  - Its column name is the result column's name.
  - Its type is `typeNameOfColumn:` (or `@""`), and allowNull is `columnIsNullable:`.
  - It is editable only when the cell is Editable. Otherwise the sheet is read-only; MySQL shows no tooltip in this path.
- **The result is committed through `_commitValue:` to the row it was opened on,** and only if the same editor is still shown: a run or a database switch meanwhile drops it. Only one sheet is open at a time.
- **The edit mode toggle** (Stage 11's `editModeButton`, already bound to `EditInSheetEnabled`) now takes effect.

- [ ] **Step 1: Write the failing tests:**
  - `testEditModeOpensSheetInsteadOfInline`: with `EditInSheetEnabled` YES, `shouldEdit` is NO. The presenter got `name`'s value and `editable` YES, with type `text`. Calling its completion with `@"sheet"` saves it.
  - `testSheetReadOnlyForUneditableCell`: an expression column gives `editable` NO, and the completion with a value sends nothing (the server is unchanged).
  - `testSheetResultDroppedAfterNewRun`: open the sheet, run another query, then complete. Nothing is sent.
  - `testCancelledSheetSendsNothing`: completion(nil) leaves the server unchanged.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement it.** Mirror `SPPostgresContentController`'s `_editInSheetTableColumn:row:` (its `once` block and `fieldEditorPending` guard), and call `SPPostgresFieldEditorSheet` by default.
- [ ] **Step 4: Run `SPPostgresQueryEditingTests`, then the full suite and the app build.** Expected: "** TEST SUCCEEDED **" and "** BUILD SUCCEEDED **". No `PostgresQuery*.plist` appears in the real `~/Library/Application Support/Sequel Pro/Data`.
- [ ] **Step 5: Commit** `Postgres Query tab: edit mode toggle opens the field editor sheet`.

## Manual checks for the owner (after Task 7)

1. `SELECT * FROM` a table with a key: double-click a cell, type, and press Return. The value is saved, and the result re-runs and keeps the selection.
2. `SELECT 1`, or a column like `upper(name)`: a double-click beeps and shows MySQL's tooltip.
3. Turn on the edit mode toggle: a double-click opens the sheet. It is read-only on an expression column.
4. A join: each table's columns save to their own table.
5. After `BEGIN`, an edit stays in your transaction until you COMMIT or ROLLBACK.
