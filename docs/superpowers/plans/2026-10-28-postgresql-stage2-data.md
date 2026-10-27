# PostgreSQL Stage 2 (Data) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a Postgres tab, the Content, Query and Table History toolbar items work as they do on
MySQL tabs, and Duplicate Table… works from the table list's right-click menu.
- **Content:** browse, filter, sort, and edit, add and delete rows.
- **Query:** run SQL and see results.

**Architecture:**
- New Postgres-only controllers live in `Source/Postgres/` and are owned by `SPPostgresDocument`, which
  swaps them into its right pane:
  - a data-access layer: `SPPostgresTableData`
  - the Content view: `SPPostgresContentController`
  - the Query view: `SPPostgresQueryController`
  - History: `SPPostgresHistory`
  - Duplicate Table: `SPPostgresTableDuplicator`
- They reuse MySQL's look: `SPTableView` for grids, MySQL's preference keys for page size, the NULL
  placeholder and the editor font, and MySQL's toolbar items via the Postgres document's validation.
- No MySQL controller changes.
- Values are fetched and edited **as PostgreSQL text**:
  - fetch: `"col"::text`, so display is Postgres's own format for every type;
  - edit: `$n::<column type>`, so values round-trip exactly.

**Tech Stack:** Objective-C (MRC in app sources), AppKit, PostgresKit, XCTest (ARC), Docker test servers (PG 12 on 55412, PG 18 on 55418).

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md` (Goals 5, 6, 10, the History
toolbar item) as amended by `docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`.

## Global Constraints

- **Never break MySQL.** No change to MySQL controllers' behaviour. Any shared-file edit is additive
  and inert for MySQL tabs.
- PostgreSQL **12 through 18**. Every data-access test runs on both 55412 and 55418.
- Identifiers are always quoted (`"…"`, embedded `"` doubled) or passed as `$n` parameters. Values
  always go as `$n` parameters. SQL is never built from raw user text, except in the Query editor,
  where the user's SQL is the input.
- Use MySQL's existing preference keys so the owner's settings apply to both engines: the page size,
  the NULL placeholder string, and the query editor font. Read them; find each key's name in
  `Source/SPConstants.m` (grep for `LimitResults`, `NullValue`, `CustomQueryEditorFont`).
- Never write `Favorites.plist`. Tests never persist into real prefs or the login keychain
  (`PostgresTests/SPTestPrefsGuard.m` stays effective).
- MRC in app sources; ARC in `Postgres Tests`. Add files only with
  `ruby Scripts/pg-xcodeproj.rb add-app|add-test`. Exported classes need `__attribute__((visibility("default")))`.
- Test command: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests"
  -derivedDataPath build/DerivedData ARCHS=arm64` (`bash Scripts/pg-test-servers.sh up` first).
- Implementer sessions never launch the GUI app; the controller does the visual checks.
- Never touch the owner's untracked `start_clause.sh`; stage only your own files.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Editing a table without a primary key.** The rows must be read-only, with a clear message, as
   MySQL does. An UPDATE must never be issued with a WHERE clause that could match several rows.
   Pinned in Task 1 and Task 2.
2. **Odd values:** NULL vs empty string, `bytea`, arrays, `json`/`jsonb`, `timestamptz`, `numeric` with
   many digits, very long text. They must display losslessly and round-trip unchanged through an edit
   of another column. Pinned in Task 1.
3. **Statement splitting in Query:** semicolons inside quotes, `$$…$$` and `$tag$…$tag$` bodies, and
   comments must not split statements. Pinned in Task 3.
4. **A failing statement in a multi-statement run.** The run stops at the error, earlier results stay
   visible, and the error shows the statement number and the server message. Pinned in Task 3.
5. **Concurrent change.** The row was changed or deleted by someone else before the edit, so UPDATE
   affects 0 rows. The user must be told and the row reloaded, never a silent no-op. Pinned in Task 1 and Task 2.

---

### Task 1: `SPPostgresTableData`, the data-access layer for Content

**Files:**
- Create: `Source/Postgres/SPPostgresTableData.h/.m`
- Create: `PostgresTests/Fixtures/content.sql`, or embed the SQL the way the stage-1 catalog tests do
- Test: `PostgresTests/SPPostgresTableDataTests.m`

**Interfaces:**
- Produces `SPPostgresColumn : NSObject` with readonly properties:
  - `name`
  - `typeName` (from `format_type(atttypid, atttypmod)`)
  - `BOOL nullable`
  - `defaultExpression` (`NSString`, nil if none)
  - `BOOL isPrimaryKey`
  - `NSInteger primaryKeyPosition` (1-based, 0 if not in the key)
  - `BOOL isGenerated` (identity ALWAYS or a generated column)
- Produces `SPPostgresTableData : NSObject`:
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table;`
  - `- (NSArray *)columns:(NSError **)error;` (in `attnum` order, dropped columns excluded)
  - `- (BOOL)isEditable;` (YES when the table has a primary key and is a base or partitioned table)
  - `- (NSString *)readOnlyReason;` (`@"This table has no primary key, so its rows can't be edited."`, or nil)
  - `- (NSArray *)rowsWithFilter:(SPPostgresFilter *)filter sortColumn:(NSString *)column ascending:(BOOL)ascending offset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError **)error;`
    Each row is an `NSArray` of `NSString` (the `::text` value) or `NSNull` for SQL NULL, in column order.
  - `- (NSInteger)countRowsWithFilter:(SPPostgresFilter *)filter error:(NSError **)error;` (exact `count(*)`)
  - `- (BOOL)updateRow:(NSArray *)originalRow column:(NSString *)column value:(id)value error:(NSError **)error;`
    - `value` is an `NSString` or `NSNull`. The SQL is `UPDATE … SET "col" = $1::<type> WHERE <pk cols> = $n::<type> …`.
    - It fails with code `SPPostgresErrorRowChanged = 6` when 0 rows are affected.
  - `- (NSArray *)insertRowWithValues:(NSDictionary *)valuesByColumn error:(NSError **)error;`
    Omitted columns use their defaults. Returns the inserted row via `RETURNING`, in the same text format.
  - `- (BOOL)deleteRows:(NSArray *)rows error:(NSError **)error;` (by primary key, in one transaction)
- Produces `SPPostgresFilter : NSObject`:
  - `column`
  - `operator` (one of `@"="`, `@"≠"`, `@">"`, `@"<"`, `@">="`, `@"<="`, `@"LIKE"`, `@"NOT LIKE"`,
    `@"ILIKE"`, `@"IS NULL"`, `@"IS NOT NULL"`, `@"IN"`)
  - `value` (`NSString`; for IN, a comma-separated list split into separate parameters)

  It compares as `"col"::text <op> $n` for the LIKE family, and as `"col" <op> $n::<type>` otherwise.
- Add `SPPostgresErrorRowChanged = 6` to `Source/Postgres/SPPostgresErrors.h`.

- [ ] **Step 1: Write the fixture.** It must be idempotent and loaded on both ports. Schema
  `content_test` with:
  - `items` (`id serial primary key`, `name text`, `note text`, `price numeric(20,6)`, `flags boolean`,
    `tags text[]`, `doc jsonb`, `blob bytea`, `ts timestamptz`, `"Mixed Case" text`): 30 rows, including
    a NULL `note`, an empty-string `note`, a 10 000-character `name`, `price` 12345678901234.123456,
    `tags` `{a,"b c"}`, `blob` `'\x00ff'`.
  - `composite_pk` (`a int`, `b text`, `v text`, primary key `(a, b)`).
  - `no_pk` (`x int`, `y text`).
  - A view `items_view`.
- [ ] **Step 2: Write the failing tests**, each run on both ports:
  - `testColumnsInOrderWithTypesAndKeys`: `price` has typeName `numeric(20,6)`, `id` isPrimaryKey,
    `"Mixed Case"` is present.
  - `testRowsAreTextAndNullIsNSNull`: the NULL note is `NSNull` and the empty note is `@""`.
  - `testOddValuesRoundTripThroughUnrelatedEdit`: update `name` on the row with
    tags/doc/blob/price/ts set, re-read, and every other column is byte-identical.
  - `testSortAndPaging`: sort by `id` descending, offset 10, limit 5 gives ids 20..16.
  - `testFilterOperators`: `=`, `ILIKE`, `IS NULL`, `IN` (`"1,2,3"`) and `>` on numeric return the
    expected id sets.
  - `testCompositeKeyUpdateTouchesOneRow`.
  - `testNoPrimaryKeyIsReadOnly`: `isEditable` is NO, `readOnlyReason` is the exact string above, and
    `updateRow` returns NO with an error without sending SQL. Assert this through the console logger
    or a connection delegate seam.
  - `testUpdateOfVanishedRowReportsRowChanged`: delete the row through a second connection, then update
    it: code 6.
  - `testInsertUsesDefaultsAndReturnsRow`: insert with only `name`; the returned `id` is non-empty.
  - `testDeleteRowsByKey`.
  - `testViewIsReadOnly`: `items_view` → `isEditable` NO.
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run the full suite and the app build.**
- [ ] **Step 6: Commit.**

### Task 2: Content view in the Postgres tab

**Files:**
- Create: `Source/Postgres/SPPostgresContentController.h/.m`
- Modify: `Source/Postgres/SPPostgresDocument.m`. The right pane hosts the content view. The Content
  toolbar item is enabled when a table or view is selected, and selecting a table shows its content.
- Test: `PostgresTests/SPPostgresContentControllerTests.m`

**Interfaces:**
- Consumes: `SPPostgresTableData`, `SPPostgresFilter`, `SPPostgresColumn` (Task 1); the sidebar's
  selection (`SPPostgresSidebarController selectedSchema`/`selectedTableName` and its delegate);
  `SPTableView`.
- Produces `SPPostgresContentController : NSObject`:
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `- (NSView *)view;`
  - `- (void)showTable:(NSString *)table inSchema:(NSString *)schema;`
  - `- (void)reload;`
  - `@property (readonly) NSTableView *tableView;`
  - `@property (readonly) NSUInteger currentPage;`
  - `@property (readonly) NSUInteger pageCount;`
  - `@property (copy) void (^alertPresenter)(NSAlert *alert);` (same pattern as the document)
- Layout mirrors MySQL's Content tab:
  - **Filter bar on top:** column popup, operator popup, value field, Filter button.
  - **Grid:** an `SPTableView` with one column per table column, header click sorts ascending then
    descending, and NULL is shown with MySQL's NULL placeholder preference in grey.
  - **Bottom bar:** + (add row), − (delete selected rows), refresh, "N rows" / "rows X–Y of N", and
    previous/next page.
  - Page size comes from MySQL's preference; when MySQL's "limit results" preference is off, it is
    unlimited.
- Editing:
  - Double-click a cell, or press Return, to edit as text.
  - Ending the edit runs `updateRow:`. On error, show an alert sheet and reload the row.
  - Code 6 shows "This row was changed or deleted by someone else." and reloads.
  - Read-only tables show `readOnlyReason` in the bottom bar and refuse editing, add and delete.
  - Generated columns are never editable.
  - Delete asks for confirmation ("Delete N rows?"), as MySQL does.

- [ ] **Step 1: Write the failing tests.** Use an app-hosted Postgres document in a window, the Task 1
  fixture, and port 55418.
  - `testSelectingTableShowsItsRows`: 30 rows when the page size is ≥ 30, and the column titles match.
  - `testNullShownWithPlaceholder`: the cell's display string equals the preference value, read from a
    volatile `NSArgumentDomain` override.
  - `testHeaderClickSorts`
  - `testFilterNarrowsRows`
  - `testEditCellUpdatesServer`: drive `tableView:setObjectValue:forTableColumn:row:` and re-read
    through a second connection.
  - `testEditOnNoPrimaryKeyIsRefused`: the bottom-bar text equals `readOnlyReason` and no update is sent.
  - `testAddAndDeleteRow`
  - `testPagingWithSmallPageSize`: page size 7 → `pageCount` 5, and next/previous work.
  - `testContentToolbarItemEnabledOnlyWithTableSelected`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite and the app build.**
- [ ] **Step 5: Commit.**
- [ ] **Step 6 (controller):** visual check against a MySQL Content tab.

### Task 3: Query view in the Postgres tab

**Files:**
- Create: `Source/Postgres/SPPostgresQueryController.h/.m`, `Source/Postgres/SPPostgresStatementSplitter.h/.m`
- Modify: `Source/Postgres/SPPostgresDocument.m`. The Query toolbar item is enabled, and it switches
  the right pane between Content and Query, as MySQL's tabs do.
- Test: `PostgresTests/SPPostgresStatementSplitterTests.m`, `PostgresTests/SPPostgresQueryControllerTests.m`

**Interfaces:**
- Produces: `+ (NSArray *)statementsInSQL:(NSString *)sql;` on `SPPostgresStatementSplitter`. It
  returns trimmed, non-empty statements and respects:
  - `'…'` (including `''`)
  - `E'…'` (with `\'`)
  - `"…"`
  - `$$…$$` and `$tag$…$tag$`
  - `-- …` line comments and `/* … */` block comments (nested)
- Produces: `+ (NSRange)rangeOfStatementAtLocation:(NSUInteger)location inSQL:(NSString *)sql;`, used for
  Run Current.
- Produces `SPPostgresQueryController : NSObject`:
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `- (NSView *)view;`
  - `- (IBAction)runAllQueries:(id)sender;`
  - `- (IBAction)runCurrentQuery:(id)sender;`
  - `@property (readonly) NSTextView *editor;`
  - `@property (readonly) NSTableView *resultsView;`
  - `@property (readonly) NSString *statusText;`
- Layout mirrors MySQL's Query tab:
  - **Editor on top:** an `NSTextView` with MySQL's editor font preference, no smart quotes or
    dashes, and undo.
  - **Buttons:** "Run All" (⌘R) and "Run Current" (⇧⌘R), the same key equivalents as MySQL.
  - **Results grid below:** a read-only `SPTableView` showing the last statement's rows. NULL uses the
    placeholder.
  - **Status line:** "N rows" / "N rows affected" / the error.
- Running:
  - Statements run in order on the connection (main thread acceptable in this stage).
  - On error, stop, keep earlier results, and show `Error in statement K: <server message>`.
  - Every statement is logged to the console through the existing logger.
- The editor's text is kept per Postgres tab for the session; it is not persisted.

- [ ] **Step 1: Write the failing splitter tests:**
  - `testSplitsSimple`
  - `testSemicolonInSingleQuotes`
  - `testEscapeStringBackslashQuote`
  - `testDollarQuotedFunctionBody` (a `CREATE FUNCTION … AS $$ BEGIN …; END $$ LANGUAGE plpgsql;` plus
    another statement → 2)
  - `testTaggedDollarQuote`
  - `testLineAndNestedBlockComments`
  - `testTrailingNoSemicolon`
  - `testRangeOfStatementAtCursor`
- [ ] **Step 2: Write the failing controller tests** (port 55418):
  - `testRunAllShowsLastResult`: `SELECT 1; SELECT 2 AS two` → the grid has column `two` and value `2`.
  - `testRunCurrentRunsOnlyCursorStatement`
  - `testErrorStopsAndReportsStatementNumber`: `SELECT 1; SELEC 2; SELECT 3` → status starts with
    `Error in statement 2:`, and the grid still shows statement 1's result.
  - `testAffectedRows`: an UPDATE on the Task 1 fixture → `3 rows affected`.
  - `testQueryToolbarItemSwitchesPane`
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run the full suite and the app build.**
- [ ] **Step 6: Commit.**

### Task 4: Table History and Duplicate Table…

**Files:**
- Create: `Source/Postgres/SPPostgresHistory.h/.m`, `Source/Postgres/SPPostgresTableDuplicator.h/.m`
- Modify: `Source/Postgres/SPPostgresDocument.m` (History item enabled; back/forward), and
  `Source/Postgres/SPPostgresSidebarController.m` (right-click menu on tables: "Duplicate Table…")
- Test: `PostgresTests/SPPostgresHistoryTests.m`, `PostgresTests/SPPostgresTableDuplicatorTests.m`

**Interfaces:**
- Produces `SPPostgresHistory : NSObject`:
  - `- (void)recordDatabase:(NSString *)db schema:(NSString *)schema table:(NSString *)table pane:(NSString *)pane;`
    `pane` is `@"content"` or `@"query"`. Consecutive duplicates are ignored, and recording after going
    back truncates the forward entries.
  - `- (NSDictionary *)goBack;` and `- (NSDictionary *)goForward;` return keys `@"database"`,
    `@"schema"`, `@"table"`, `@"pane"`, or nil.
  - `@property (readonly) BOOL canGoBack;`
  - `@property (readonly) BOOL canGoForward;`
- Restoring an entry selects that schema, table and pane. If the database differs, it switches
  database first through the existing switch path, then selects.
- The History toolbar control's segments enable and disable with `canGoBack`/`canGoForward`, using
  the same control the toolbar factory builds.
- Produces `SPPostgresTableDuplicator`:
  `+ (BOOL)duplicateTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName withContent:(BOOL)withContent connection:(PGPostgresConnection *)connection error:(NSError **)error;`
  - Runs in one transaction:
    - `CREATE TABLE "s"."new" (LIKE "s"."old" INCLUDING ALL)`, which copies defaults, constraints,
      indexes, identity, comments and storage.
    - For columns whose default is `nextval('<old owned sequence>')` (serial): create a new sequence
      `<new>_<col>_seq`, set the column default to it, `ALTER SEQUENCE … OWNED BY`, and when copying
      content, `setval` it to the old sequence's last value.
    - With content: `INSERT INTO new SELECT * FROM old`. Generated/identity-ALWAYS columns use
      `OVERRIDING SYSTEM VALUE` where needed.
  - On any error, rolls back and returns NO with the server message.
- Duplicate Table… dialog: a sheet like MySQL's. Name field prefilled with `<table>_copy`, a "Duplicate
  content" checkbox, Duplicate/Cancel. On success the new table is selected in the sidebar.

- [ ] **Step 1: Write the failing tests.**
  - History:
    - `testBackForwardOrder`
    - `testRecordingAfterBackTruncatesForward`
    - `testDuplicatesIgnored`
    - `testRestoreAcrossDatabaseSwitches` (live, 55418, `pgkit_test` ↔ `pgkit_nopublic`)
  - Duplicator, both ports:
    - `testStructureOnlyCopyHasNoRowsButSameColumnsIndexesConstraints`
    - `testCopyWithContentHasSameRows`
    - `testSerialGetsOwnSequenceContinuingFromOld`: inserting into the copy doesn't advance the old
      sequence, and the next id is after the copied max.
    - `testFailureRollsBackAndLeavesNoTable` (target name already exists)
    - `testOddNamesQuoted` (schema `"Sales Data"`, table `a"b`)
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite and the app build.**
- [ ] **Step 5: Commit.**
- [ ] **Step 6 (controller):** visual and MySQL regression check:
  - Content and Query on a Postgres tab next to a MySQL tab.
  - History back and forward.
  - Duplicate a table.
  - The MySQL tabs unchanged.
