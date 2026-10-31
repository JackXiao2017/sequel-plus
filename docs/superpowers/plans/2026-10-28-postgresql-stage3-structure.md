# PostgreSQL Stage 3 (Structure, Relations, Triggers, Table Info) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a Postgres tab, the Structure, Relations, Triggers and Table Info toolbar items (and View ▸ ⌘1/⌘3/⌘4/⌘5)
work as they do on MySQL tabs:
- **Structure:** add, rename, retype and delete columns; defaults, NOT NULL and comments; add and drop indexes and
  constraints.
- **Relations:** foreign keys.
- **Triggers:** a table's triggers and their functions.
- **Table Info:** owner, sizes and the CREATE statement.
- **Sequences:** a SEQUENCES section in the left panel, where sequences can be listed, added, modified and deleted.

**Architecture:**
- A new metadata + DDL layer, `SPPostgresTableStructure`, serves all four views. Every change runs immediately
  (as MySQL's Structure tab does) through the existing `SPPostgresRunAtomically`, so a failed change leaves the
  table as it was and a user's open Query transaction survives.
- `SPPostgresDocument`'s right pane generalises from Content/Query to six named panes. Each pane's controller is
  created on first show and rebuilt on a database switch, like Content.
- New view controllers live in `Source/Postgres/`. There are no MySQL controller changes.

**Tech Stack:** Objective-C (MRC in app sources), AppKit, PostgresKit, XCTest (ARC), Docker test servers (PG 12 on 55412, PG 18 on 55418).

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md` (Goals 7, 8, 9, 14; "Structure"; the
builder's calls on USING, dependent columns and transactions) as amended by
`docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`.

**Amendment (owner, 2026-10-28):** "add the sequence management, such as list, modify, delete, add sequence".
- This overrides the spec's non-goal for sequences only.
- Views and functions stay out of scope.
- Task 5 implements it.

## Global Constraints

- **Never break MySQL.** No change to MySQL controllers' behaviour. Any shared-file edit is additive and inert for
  MySQL tabs.
- PostgreSQL **12 through 18**. Every data-layer test runs on both 55412 and 55418.
- **Identifiers** are always quoted with `SPPostgresQuoteIdentifier`, and values go as `$n` parameters.
- **Raw SQL fragments:** the user types these in, as in MySQL's Structure tab; they are sent as typed, and nothing
  else is:
  - a column type (`varchar(50)`, `numeric(10,2)`);
  - a default expression;
  - a CHECK expression;
  - a `USING` expression;
  - a trigger `WHEN` condition.
- **Never cascade.** No DDL uses `CASCADE`. When something depends on what is being dropped, stop and list it
  (spec: "never cascade silently").
- Every DDL change runs inside `SPPostgresRunAtomically(connection, @"sp_structure", …)`.
- **Lock waits:** every DDL change runs with `lock_timeout` set to `lockTimeout` (default 5 s). The previous
  value is restored afterwards, so a lock held elsewhere gives an error instead of freezing the window.
- PostgreSQL cannot reorder columns: no drag-to-reorder.
- **Tests and prefs:**
  - Never write `Favorites.plist`.
  - Tests never persist into real prefs or the login keychain; `PostgresTests/SPTestPrefsGuard.m` stays effective.
- **Code conventions:**
  - MRC in app sources; ARC in `Postgres Tests`.
  - Add files only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test`.
  - Exported classes need `__attribute__((visibility("default")))`.
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

1. **A type change the data can't take automatically** (text `'12a'` → integer, text → boolean).
   - The server's error is shown, with a `USING` field prefilled `"col"::newtype` and Retry/Cancel.
   - Until a retry succeeds, the column is unchanged.
   - Pinned in Task 1 (`testChangeTypeNeedsUsingThenSucceedsWithIt`) and Task 2 (`testTypeChangeFailureOffersUsing`).
2. **Dropping a column that something depends on:** a view, an index (single- or multi-column), a constraint, or
   a foreign key from another table.
   - Nothing is dropped, and every dependent is listed by name.
   - PostgreSQL itself would silently drop the indexes and constraints, so this needs a pre-check.
   - Pinned in Task 1 (`testDropColumnWithDependentsIsRefusedAndListsThem`).
   - The same applies to deleting a sequence that a column default uses: it is refused, and the columns are
     listed. Pinned in Task 5 (`testDropSequenceInUseIsRefusedAndListsColumns`).
3. **The user's open transaction from the Query view.**
   - A failing DDL leaves it open and usable.
   - An aborted transaction refuses DDL without sending it.
   - Pinned in Task 1 (`testFailedChangeInsideUserTransactionKeepsItOpen`, `testAbortedTransactionRefusesChanges`).
4. **Odd identifiers:** column names with spaces, `"`, mixed case, and reserved words (`order`), in a schema named
   `Sales Data`. Every DDL and the generated CREATE statement must work.
   - Pinned in Task 1 (`testOddIdentifiersEverywhere`) and Task 4 (`testCreateStatementRecreatesTable` on the odd fixture).
5. **Another session holds a lock on the table**: an open transaction elsewhere has touched it.
   - The change fails after `lockTimeout` with the server's lock-timeout message, and the window doesn't hang.
   - The session's `lock_timeout` is back to its previous value afterwards.
   - Pinned in Task 1 (`testLockHeldElsewhereTimesOutAndRestoresSetting`).

---

### Task 1: `SPPostgresTableStructure`, metadata and DDL

**Files:**
- Create: `Source/Postgres/SPPostgresTableStructure.h/.m`.
- Modify: `Source/Postgres/SPPostgresErrors.h`. Add `SPPostgresErrorHasDependents = 9` and the userInfo key
  `SPPostgresDependentsErrorKey` (an `NSArray` of `NSString`), defined in `SPPostgresErrors.m`.
- Modify: `Source/Postgres/SPPostgresTableData.h/.m`. Move the duplicator's static `SPPostgresQuoteLiteral` here
  as an exported function next to `SPPostgresQuoteIdentifier`, and make the duplicator use it.
- Test: `PostgresTests/SPPostgresTableStructureTests.m`. Its fixture is schema `structure_test`, built
  idempotently in the test file or `PostgresTests/Fixtures/`, on both ports.

**Interfaces:**
- **Consumes:** `SPPostgresRunAtomically`, `SPPostgresExecute`, `SPPostgresQuoteIdentifier` (stage 2).
  It also uses `+[SPPostgresTableDuplicator isValidTableName:]`, the 63-byte rule, for any new table, column,
  index or constraint name.
- **Produces `SPPostgresStructureColumn : NSObject`** (readonly):
  - `name`, `typeName` (`format_type(atttypid, atttypmod)`), `BOOL nullable`;
  - `defaultExpression` (`pg_get_expr`, nil if none);
  - `autoKind`: one of `@""`, `@"serial"` (default is `nextval` of a sequence owned by this column),
    `@"identity"` (BY DEFAULT), `@"identity always"`, `@"generated"`;
  - `generationExpression` (nil unless generated), `comment` (nil if none), `NSInteger attnum`.
- **Produces `SPPostgresIndex : NSObject`** (readonly):
  - `name`, `definition` (`pg_get_indexdef`), `NSArray *columns` (names, or expression text), `method`;
  - `BOOL isUnique`, `BOOL isPrimary`;
  - `constraintName` (nil when the index backs no constraint).
- **Produces `SPPostgresConstraint : NSObject`** (readonly):
  - `name`, `kind` (`@"PRIMARY KEY"`, `@"UNIQUE"`, `@"CHECK"`, `@"FOREIGN KEY"`, `@"EXCLUDE"`),
    `definition` (`pg_get_constraintdef`), `NSArray *columns`;
  - FK only: `referencedSchema`, `referencedTable`, `NSArray *referencedColumns`, and `onUpdate`/`onDelete`
    (`@"NO ACTION"`, `@"RESTRICT"`, `@"CASCADE"`, `@"SET NULL"`, `@"SET DEFAULT"`).
  - Lists `contype` `p`, `u`, `c`, `f`, `x` only. PG 18's `n` (NOT NULL) and `t` (constraint trigger) are excluded.
- **Produces `SPPostgresColumnDefinition : NSObject`** (readwrite): `name`, `typeName`, `defaultExpression`,
  `BOOL notNull`, `autoKind` (`@""`, `@"serial"`, `@"identity"`, `@"identity always"`), `comment`.
- **Produces `SPPostgresConstraintDefinition : NSObject`** (readwrite):
  - `kind` (as above, minus EXCLUDE), `name` (nil lets the server name it), `NSArray *columns`;
  - `checkExpression`;
  - `referencedSchema`, `referencedTable`, `NSArray *referencedColumns`, `onUpdate`, `onDelete`.
- **Produces `SPPostgresTableStructure : NSObject`:**
  - Setup and reads:
    - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table;`
    - `@property NSTimeInterval lockTimeout;` (default 5)
    - `- (NSArray *)columns:(NSError **)error;`, `- (NSArray *)indexes:(NSError **)error;`,
      `- (NSArray *)constraints:(NSError **)error;`, `- (NSString *)tableComment:(NSError **)error;`
    - `- (NSString *)relationKind:(NSError **)error;` returns `@"table"`, `@"partitioned table"`, `@"view"`,
      `@"materialized view"` or `@"foreign table"`.
    - Views and materialized views return columns only; their indexes and constraints are empty.
  - Every change below returns NO with the server message (including DETAIL/HINT, as the Query view shows) on
    failure:
    - `- (BOOL)addColumn:(SPPostgresColumnDefinition *)definition error:(NSError **)error;`
      - Runs `ADD COLUMN`, then `COMMENT ON COLUMN` when a comment is given.
      - `serial` maps `integer`/`int`/`int4`→`serial`, `bigint`/`int8`→`bigserial`, `smallint`/`int2`→`smallserial`.
        Any other type fails before sending, with "Only integer columns can be serial."
      - identity adds `GENERATED BY DEFAULT|ALWAYS AS IDENTITY`.
    - `- (BOOL)renameColumn:(NSString *)column to:(NSString *)newName error:(NSError **)error;`
    - `- (BOOL)changeColumn:(NSString *)column toType:(NSString *)typeName using:(NSString *)usingExpression error:(NSError **)error;`
      (`usingExpression` is nil for none)
    - `- (BOOL)setDefault:(NSString *)expression forColumn:(NSString *)column error:(NSError **)error;`
      (nil or empty runs `DROP DEFAULT`)
    - `- (BOOL)setNullable:(BOOL)nullable forColumn:(NSString *)column error:(NSError **)error;`
    - `- (BOOL)setComment:(NSString *)comment forColumn:(NSString *)column error:(NSError **)error;`
      (nil or empty runs `IS NULL`; the comment is a quoted literal)
    - `- (NSArray *)dependentsOfColumn:(NSString *)column error:(NSError **)error;`
    - `- (BOOL)dropColumn:(NSString *)column error:(NSError **)error;`
      - First calls `dependentsOfColumn:`. When any exist, it fails with `SPPostgresErrorHasDependents`, the
        message `"<column>" can't be deleted because other objects depend on it.`, and the list in
        `SPPostgresDependentsErrorKey`. Nothing is sent.
    - `- (BOOL)addIndexNamed:(NSString *)name columns:(NSArray *)columns unique:(BOOL)unique method:(NSString *)method error:(NSError **)error;`
      - nil `name` lets the server name it. `method` is one of `btree`, `hash`, `gist`, `gin`, `brin`; nil means btree.
      - No `CONCURRENTLY`, since it can't run in a transaction.
    - `- (BOOL)dropIndexNamed:(NSString *)name error:(NSError **)error;`
      - An index that backs a constraint runs `ALTER TABLE … DROP CONSTRAINT` for that constraint instead.
    - `- (BOOL)addConstraint:(SPPostgresConstraintDefinition *)definition error:(NSError **)error;`
    - `- (BOOL)dropConstraintNamed:(NSString *)name error:(NSError **)error;`
    - `- (BOOL)renameTableTo:(NSString *)newName error:(NSError **)error;`
    - `- (BOOL)setTableComment:(NSString *)comment error:(NSError **)error;`
- **Dependents query:** objects in `pg_depend` with `refobjid` = the table and `refobjsubid` = the column's attnum.
  - Excluded: the column's own default (`pg_attrdef`), and a sequence it owns (deptype `a` on a `pg_class` sequence).
  - Each is described with `pg_describe_object`, except that a `pg_rewrite` rule is described as the view (or
    materialized view) that owns it: `view "s"."v"`.
  - Also included: foreign keys of other tables that reference this column (`pg_constraint.confkey`).

- [ ] **Step 1: Write the fixture.** In schema `structure_test`:
  - `t` (`id serial primary key`, `code text unique`, `qty text`, `amount numeric(10,2) default 0`,
    `"Order" int`, `"a ""q"" b" text`, `gen int generated always as (id * 2) stored`,
    `ident bigint generated by default as identity`), with a comment on `t` and on `code`, and the rows
    `qty` = `'5'`, `'12a'`;
  - index `t_amount_idx` on `amount`, and a two-column index on `(qty, amount)`;
  - check `t_amount_check (amount >= 0)`;
  - view `t_view` selecting `code`;
  - `child` (`id int primary key`, `t_id int references t(id) on delete cascade`);
  - schema `"Sales Data"` with table `"Mixed Case"` (`"order" int primary key`, `"select" text`).

  Rebuild it per test (drop and recreate the schemas), so DDL tests don't leak.
- [ ] **Step 2: Write the failing tests**, each on both ports:
  - `testColumnsReportTypesDefaultsAutoKindsAndComments`:
    - `id` is `serial`, `ident` is `identity`, `gen` is `generated` with its expression;
    - `amount`'s typeName is `numeric(10,2)` with default `0`;
    - `code`'s comment is read.
  - `testIndexesAndConstraintsExcludeNotNullRows`:
    - `t_pkey` is primary, and `t_code_key` has constraintName `t_code_key`;
    - the CHECK appears, and no constraint of kind NOT NULL is listed (PG 18).
  - `testForeignKeyDetails`, on `child`: referencedTable `t`, columns `t_id`→`id`, onDelete `CASCADE`, onUpdate
    `NO ACTION`.
  - `testAddColumnVariants`:
    - `varchar(20)` NOT NULL with a default `'x'` and a comment;
    - `serial` on `bigint` → the type reads `bigint` and autoKind `serial`;
    - `identity always`;
    - `serial` on `text` → error, nothing sent.
  - `testRenameAndCommentAndNullAndDefault`
  - `testChangeTypeNeedsUsingThenSucceedsWithIt`:
    - `qty` → `integer` fails; the column is still `text`.
    - With `using:@"nullif(regexp_replace(\"qty\", '\\D', '', 'g'), '')::integer"` it succeeds, and the rows
      read `5` and `12`.
  - `testDropColumnWithDependentsIsRefusedAndListsThem`:
    - `code` lists the view and the unique constraint;
    - `amount` lists both indexes and the check;
    - `id` lists the FK from `child`.
    - Each has code 9, and the column still exists.
  - `testDropFreeColumn` (`"Order"`).
  - `testAddAndDropIndexUniqueAndMethod`: `gin` isn't valid on `text` without an opclass, so use `hash`.
    Dropping `t_code_key`'s index drops the constraint.
  - `testAddAndDropConstraintsAllKinds`: PK on a new table, UNIQUE, CHECK, and an FK with ON DELETE SET NULL.
  - `testDropReferencedPrimaryKeyFailsWithServerMessage`: no CASCADE, and the message mentions `child`.
  - `testRenameTableAndTableComment`: rename to a 64-byte name is refused before sending.
  - `testOddIdentifiersEverywhere`, on `"Sales Data"."Mixed Case"`: add, rename, retype, comment, index and drop a
    column named `a "q" b`.
  - `testFailedChangeInsideUserTransactionKeepsItOpen`:
    - Run BEGIN, then insert a row into `t`, on the same connection.
    - A failing type change follows.
    - The transaction status is still in-transaction and the inserted row is visible.
    - Then ROLLBACK.
  - `testAbortedTransactionRefusesChanges`
  - `testLockHeldElsewhereTimesOutAndRestoresSetting`:
    - A second connection runs `BEGIN; LOCK TABLE … IN ACCESS SHARE MODE`.
    - With lockTimeout 1, addColumn fails within 5 s and the message contains `lock timeout`.
    - `SHOW lock_timeout` afterwards equals the value before.
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run the full suite and the app build.**
- [ ] **Step 6: Commit.**

### Task 2: Panes in the Postgres tab, and the Structure view

**Files:**
- Create: `Source/Postgres/SPPostgresStructureController.h/.m`, `Source/Postgres/SPPostgresConstraintSheet.h/.m`.
  The add-index and add-constraint sheet is built in code and reused by Relations in Task 3.
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`:
  - **Panes:** replace `showingQuery` with named panes, `- (void)showPane:(NSString *)pane;` and
    `@property (readonly) NSString *currentPane;`. Pane names: `SPPostgresPaneStructure` `@"structure"`,
    `…Content` `@"content"`, `…Relations` `@"relations"`, `…Triggers` `@"triggers"`, `…Info` `@"info"` and
    `…Query` `@"query"`, exported constants in `SPPostgresDocument.h`.
  - **Actions:** the menu actions `viewStructure:`, `viewRelations:`, `viewTriggers:` and `viewStatus:` (MainMenu's
    selectors, reached through SPWindowController's forwarding, as `viewContent:` already is) plus the toolbar
    items for those identifiers.
  - **Pane behaviour:** `_showQueryPane:` and the stale-content logic generalise to all panes.
  - **History:** records and restores any pane name. An unknown pane restores as `content`.
  - **Rename Table…:** a new item in the sidebar's table menu.
- Modify: `Source/Postgres/SPPostgresSidebarController.h/.m`. The delegate gains
  `- (void)sidebar:(SPPostgresSidebarController *)sidebar renameTableNamed:(NSString *)table;`.
- Test: `PostgresTests/SPPostgresStructureControllerTests.m`, and additions to `SPPostgresDocumentTests.m`.

**Interfaces:**
- **Consumes:** Task 1's classes; the document's `alertPresenter` and `confirmationPresenter`; `SPTableView`.
- **Produces `SPPostgresStructureController : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `- (NSView *)view;`
  - `- (void)showTable:(NSString *)table inSchema:(NSString *)schema;`
  - `- (void)reload;`
  - `- (void)invalidate;`
  - `@property (readonly) NSTableView *columnsView, *indexesView, *constraintsView;`
  - `@property (copy) void (^alertPresenter)(NSAlert *alert);`
  - `@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));`
  - `@property (copy) void (^usingPresenter)(NSString *serverMessage, NSString *prefilled, void (^completion)(NSString *usingOrNil));`
    The default shows a sheet; tests answer it.
  - `@property (copy) void (^structureDidChange)(BOOL columnsChanged);` The document marks Content stale and,
    after a table rename, reloads the sidebar while keeping the selection.
- Produces `SPPostgresConstraintSheet` with
  `+ (void)beginForKind:(NSString *)kind columns:(NSArray *)columnNames connection:(PGPostgresConnection *)connection window:(NSWindow *)window completion:(void (^)(SPPostgresConstraintDefinition *definitionOrNil))completion;`
  - `kind` is `@"INDEX"`, or a constraint kind from Task 1.
  - The FK mode lists the referenced schema/table from the catalog, and that table's columns.
- **Layout mirrors MySQL's Structure tab** (`SPTableStructure`, DBView.xib):
  - **Columns grid on top:** Name, Type, Nullable (checkbox), Default, Auto, Comment.
    - Type is an editable combo box suggesting `integer`, `bigint`, `smallint`, `numeric(10,2)`, `real`,
      `double precision`, `text`, `varchar(255)`, `char(1)`, `boolean`, `date`, `time`, `timestamp`,
      `timestamptz`, `interval`, `uuid`, `json`, `jsonb`, `bytea` and `inet`.
    - Auto is a popup (`""`, `serial`, `identity`, `identity always`), editable only on a new row.
  - **Bottom bar:** + / − for columns, and refresh.
  - **Below:** an Indexes grid (Name, Columns, Unique, Method) and a Constraints grid (Name, Type, Definition),
    each with + / −.
- **Behaviour:**
  - Each edited cell runs its one change immediately (rename, type, nullable, default, comment), then reloads. On
    error, an alert sheet shows the message and the grid reloads.
  - **Type failure:** `usingPresenter` gets the server message and `"<col>"::<new type>`. Retry calls
    `changeColumn:toType:using:`, and repeats on further failure until Cancel.
  - **+ column:** appends a draft row: name `column_N`, the lowest free N, type `text`, nullable YES. Its Name cell
    goes into editing.
    - The draft is saved with `addColumn:` when the selection leaves it or Return is pressed. Esc discards it.
    - A failed save keeps the draft for correction.
  - **− column:** asks "Delete column "x"?". `SPPostgresErrorHasDependents` shows an alert listing the dependents,
    one per line, under the message.
  - **Views and other relations:** a view or materialized view shows its columns read-only, and +/− are disabled
    with the bottom-bar text `Views can't be edited here.` Generated columns' Type and Default cells are read-only.
- **Toolbar and menu validation:**
  - Structure, Content and Table Info are enabled when any relation is selected.
  - Relations and Triggers are enabled for tables and partitioned tables only.
  - Query is always enabled.
  - A pane whose item is disabled for the new selection shows its empty-state text instead of switching:
    `Relations aren't available for views.` / `Triggers aren't available for views.`

- [ ] **Step 1: Write the failing tests** (app-hosted document in a window, port 55418, Task 1's fixture):
  - `testViewStructureMenuAndToolbarShowStructurePane`: `currentPane` is `structure`; ⌘1's menu item validates YES.
  - `testColumnsGridShowsFixtureColumns`: titles and values, `id` Auto = `serial`.
  - `testEditingTypeCellAltersColumn`
  - `testTypeChangeFailureOffersUsing`:
    - The presenter gets `"qty"::integer` as the prefill.
    - Answering with the Task 1 USING expression succeeds.
    - Answering nil leaves the column `text`.
  - `testDraftRowSavedOnReturnAndDiscardedOnEscape`
  - `testDeleteColumnWithDependentsShowsList`: the alert's informative text contains `view "structure_test"."t_view"`.
  - `testAddIndexAndConstraintViaSheetCompletion`: drive the sheet's completion block directly.
  - `testViewSelectedIsReadOnlyAndRelationsDisabled`
  - `testRenameTableFromSidebarMenuReloadsAndKeepsSelection`
  - `testStructureChangeMarksContentStale`: add a column, switch to Content, and the new column title is present.
  - `testHistoryRecordsAndRestoresStructurePane`
  - `testMySQLTabUnaffected`: a MySQL tab in the same window still validates its own Structure item through
    `SPDatabaseDocument`. Only `SPPostgresDocument` answers on Postgres tabs.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite and the app build.**
- [ ] **Step 5: Commit.**
- [ ] **Step 6 (controller):** visual check of Structure against a MySQL Structure tab.

### Task 3: Relations and Triggers

**Files:**
- Create: `Source/Postgres/SPPostgresRelationsController.h/.m`, `Source/Postgres/SPPostgresTriggersController.h/.m`.
- Modify: `Source/Postgres/SPPostgresTableStructure.h/.m`, to add triggers.
- Modify: `Source/Postgres/SPPostgresDocument.m`, to host both panes.
- Test: `PostgresTests/SPPostgresRelationsControllerTests.m` and `PostgresTests/SPPostgresTriggersTests.m`. The
  trigger data tests run on both ports.

**Interfaces:**
- **Consumes:** `constraints:`, `addConstraint:`, `dropConstraintNamed:` and `SPPostgresConstraintSheet` (FK mode)
  from Tasks 1–2; the pane mechanism from Task 2.
- **Produces `SPPostgresTrigger : NSObject`** (readonly):
  - `name`;
  - `timing` (`@"BEFORE"`, `@"AFTER"`, `@"INSTEAD OF"`);
  - `events`, e.g. `@"INSERT OR UPDATE OF \"code\""`, parsed from `pg_get_triggerdef`'s text between the timing
    and ` ON `;
  - `level` (`@"ROW"`, `@"STATEMENT"`);
  - `functionSchema`, `functionName`;
  - `condition` (the WHEN text, nil if none);
  - `BOOL enabled` (`tgenabled <> 'D'`);
  - `definition` (`pg_get_triggerdef`), `functionDefinition` (`pg_get_functiondef`).
  - Internal triggers (`tgisinternal`) are excluded.
- **Produces on `SPPostgresTableStructure`:**
  - `- (NSArray *)triggers:(NSError **)error;`
  - `- (NSArray *)triggerFunctions:(NSError **)error;`: `@"schema.name"` strings, quoted when needed, for
    functions returning `trigger` outside `pg_catalog` and `information_schema`.
  - `- (BOOL)addTriggerNamed:(NSString *)name timing:(NSString *)timing events:(NSArray *)events updateColumns:(NSArray *)columns level:(NSString *)level function:(NSString *)qualifiedFunction condition:(NSString *)condition error:(NSError **)error;`
  - `- (BOOL)dropTriggerNamed:(NSString *)name error:(NSError **)error;`
  - `- (BOOL)setTrigger:(NSString *)name enabled:(BOOL)enabled error:(NSError **)error;` runs
    `ALTER TABLE … ENABLE|DISABLE TRIGGER`.
- **Relations view** mirrors MySQL's Relations tab:
  - One grid of the table's foreign keys: Name, Columns, References (`schema.table`), Referenced Columns,
    On Update, On Delete.
  - + opens the constraint sheet in FK mode; − asks, then drops.
- **Triggers view** mirrors MySQL's Triggers tab:
  - A grid: Name, Timing, Event, Level, Function, Enabled (checkbox, editable).
  - Below it, a read-only monospaced text view with the selected trigger's `functionDefinition`.
  - + opens an add-trigger sheet: name, timing popup, event checkboxes with an optional UPDATE OF column list,
    level popup, function popup from `triggerFunctions:`, and an optional WHEN field.
  - − asks, then drops.
  - Editing function bodies is out of scope (spec non-goal); the user does that in Query.

- [ ] **Step 1: Extend the fixture:**
  - a plpgsql function `structure_test.touch() returns trigger`;
  - a trigger `t_touch BEFORE UPDATE OF code ON t FOR EACH ROW WHEN (OLD.code IS DISTINCT FROM NEW.code)`;
  - a disabled statement-level trigger `t_audit AFTER INSERT OR DELETE`.
- [ ] **Step 2: Write the failing tests:**
  - **Data, both ports:**
    - `testTriggersListParsed`: timing, events `UPDATE OF code`, level, condition, enabled flags, and
      functionDefinition containing `RETURN NEW`.
    - `testInternalFKTriggersExcluded`
    - `testAddDropEnableDisableTrigger`
    - `testTriggerFunctionsListed`
  - **Views, port 55418:**
    - `testRelationsGridListsChildForeignKey`
    - `testAddForeignKeyViaSheetCompletionAndDrop`
    - `testTriggersGridAndFunctionSource`
    - `testEnabledCheckboxTogglesTrigger`
    - `testRelationsAndTriggersPanesFromMenuItems` (⌘3, ⌘4).
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run the full suite and the app build.**
- [ ] **Step 6: Commit.**

### Task 4: Table Info, and the CREATE statement

**Files:**
- Create: `Source/Postgres/SPPostgresTableInfoController.h/.m`, `Source/Postgres/SPPostgresCreateStatement.h/.m`.
- Modify: `Source/Postgres/SPPostgresDocument.m`. It hosts the Info pane, and the Query view's DDL refresh marks
  Structure, Relations, Triggers and Info stale too, not only Content.
- Test: `PostgresTests/SPPostgresCreateStatementTests.m` (both ports) and
  `PostgresTests/SPPostgresTableInfoControllerTests.m`.

**Interfaces:**
- **Produces `SPPostgresCreateStatement`:**
  `+ (NSString *)createStatementForTable:(NSString *)table inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error;`
  - **Tables:** `CREATE TABLE "s"."t" (` followed by one line per column, in attnum order:
    - quoted name, `format_type`;
    - `COLLATE "x"` when the collation isn't the type's default;
    - `GENERATED ALWAYS AS (expr) STORED`, or `GENERATED BY DEFAULT|ALWAYS AS IDENTITY`;
    - otherwise `DEFAULT expr`;
    - `NOT NULL`.

    Then one `CONSTRAINT "n" <pg_get_constraintdef>` line per `p`, `u`, `c`, `f` and `x` constraint, and `)`.
    It ends with `PARTITION BY <pg_get_partkeydef>` for a partitioned table, and `INHERITS (…)` when the table
    has parents. Then:
    - one `pg_get_indexdef` line per index that backs no constraint;
    - `COMMENT ON TABLE` and `COMMENT ON COLUMN` lines;
    - one `pg_get_triggerdef` line per non-internal trigger.

    Statements end with `;` and are separated by blank lines. Serial columns appear as their
    `DEFAULT nextval(…)`, and no sequence DDL is emitted (noted in the header).
  - **Views:** `CREATE VIEW "s"."v" AS` followed by `pg_get_viewdef(oid, true)`, or `CREATE MATERIALIZED VIEW …`
    plus its indexes.
- **Produces `SPPostgresTableInfoController : NSObject`:** `initWithConnection:`, `view`, `showTable:inSchema:`,
  `reload`, `invalidate`, and `@property (copy) void (^alertPresenter)(NSAlert *alert);`.
- **Data, via `SPPostgresTableStructure`:** `- (NSDictionary *)tableInfo:(NSError **)error;` with these keys:
  - `@"kind"` (as `relationKind:`), `@"owner"`;
  - `@"rowEstimate"` (`NSNumber` from `reltuples`, or `NSNull` when it is `-1` or the table was never analysed);
  - `@"tableSize"`, `@"indexSize"`, `@"totalSize"` (from `pg_size_pretty` of `pg_table_size`, `pg_indexes_size`
    and `pg_total_relation_size`);
  - `@"comment"`.
- **Layout mirrors MySQL's Table Info tab:**
  - A label grid: Type, Owner, Rows (estimate), shown as `~N` or `Unknown (not analyzed)`; Table size; Index size;
    Total size.
  - An editable Comment box. Ending its edit calls `setTableComment:`, and the Structure pane goes stale.
  - A read-only, monospaced "Create syntax" text view, using MySQL's query-editor font preference.

- [ ] **Step 1: Write the failing tests:**
  - **Both ports:**
    - `testCreateStatementRecreatesTable`:
      - Fixture: a table with identity, generated, a check, unique and an FK to another table, a non-constraint
        index, comments and a trigger, plus the odd `"Sales Data"."Mixed Case"`.
      - Generate its CREATE statement, drop the table, execute the statement, then compare. Task 1's `columns:`,
        `indexes:` and `constraints:`, plus `triggers:`, must equal the originals: names, types, defaults,
        definitions and comments.
    - `testSerialEmitsNextvalDefault`
    - `testPartitionedAndInheritedTables`
    - `testViewAndMaterializedView`
    - `testNoNotNullConstraintDuplicatesOnPG18`
  - **View, port 55418:**
    - `testInfoShowsOwnerSizesAndEstimate`: before ANALYZE the estimate is `Unknown (not analyzed)`; after
      ANALYZE it is `~2`.
    - `testCommentEditPersists`
    - `testCreateSyntaxShown`
    - `testQueryDDLMarksStructurePanesStale`: `ALTER TABLE … ADD COLUMN z int` in Query, then ⌘1 shows `z`.
    - `testTableInfoMenuItem` (⌘5).
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite and the app build.**
- [ ] **Step 5: Commit.**
- [ ] **Step 6 (controller):** visual and MySQL regression check:
  - all six panes on a Postgres tab next to a MySQL tab;
  - ⌘1–⌘6 on both;
  - a USING retry;
  - a refused column drop.

### Task 5: Sequences

**Files:**
- Create: `Source/Postgres/SPPostgresSequences.h/.m` (data and DDL) and
  `Source/Postgres/SPPostgresSequenceController.h/.m` (the editor pane).
- Modify: `Source/Postgres/SPPostgresCatalog.h/.m`. Add
  `- (NSArray *)sequenceNamesInSchema:(NSString *)schema error:(NSError **)error;` (relkind `S`, sorted).
- Modify: `Source/Postgres/SPPostgresSidebarController.h/.m`:
  - A `SEQUENCES` section between `VIEWS` and `EXTENSIONS`.
  - `@property (readonly) NSString *selectedSequenceName;` (nil unless a sequence is selected; `selectedTableName`
    is nil then).
  - Right-click menu on a sequence: "Add Sequence…" and "Delete Sequence…". On the section header or empty
    space: "Add Sequence…".
  - Delegate methods `sidebar:addSequenceInSchema:` and `sidebar:deleteSequenceNamed:`.
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`:
  - Pane `SPPostgresPaneSequence` `@"sequence"`, shown whenever a sequence is selected.
  - Toolbar: only Query and the document-level items stay enabled while it shows.
  - History records sequence selections with `pane` `sequence` and `table` = the sequence name.
- Test: `PostgresTests/SPPostgresSequencesTests.m` (both ports) and `PostgresTests/SPPostgresSequenceControllerTests.m`.

**Interfaces:**
- **Consumes:** `SPPostgresRunAtomically` with savepoint `sp_structure`, the lock_timeout rule (Global Constraints),
  `SPPostgresQuoteIdentifier`/`SPPostgresQuoteLiteral`, `isValidTableName:` (63 bytes), and the pane mechanism and
  presenters from Task 2.
- **Produces `SPPostgresSequence : NSObject`** (readonly):
  - `schema`, `name`, `dataType` (`smallint`, `integer` or `bigint`);
  - `NSNumber` values `start`, `increment`, `minValue`, `maxValue`, `cache`, and `BOOL cycle`, all from
    `pg_sequence`;
  - `lastValue` (`NSNumber`, nil when never called; read with `SELECT last_value, is_called FROM "s"."seq"`) and
    `BOOL isCalled`;
  - `ownedBy` (`@"schema.table.column"` from `pg_depend` deptype `a`, nil if none);
  - `BOOL isIdentity` (deptype `i`: the sequence behind an identity column), `owner`, `comment`.
  - Values are `NSNumber` (`long long`); bigint limits fit.
- **Produces `SPPostgresSequenceDefinition : NSObject`** (readwrite): the same settable fields — `name`,
  `dataType`, `start`, `increment`, `minValue`, `maxValue`, `cache`, `cycle`, `ownedBy`, `comment`. A nil number
  means the server default.
- **Produces `SPPostgresSequences : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema;`
  - `@property NSTimeInterval lockTimeout;` (default 5)
  - `- (SPPostgresSequence *)sequenceNamed:(NSString *)name error:(NSError **)error;`
  - `- (BOOL)createSequence:(SPPostgresSequenceDefinition *)definition error:(NSError **)error;`
    Runs `CREATE SEQUENCE "s"."n" AS <type> INCREMENT BY … MINVALUE … MAXVALUE … START WITH … CACHE … [NO] CYCLE
    [OWNED BY "s"."t"."c"]`, then `COMMENT ON SEQUENCE` when a comment is given. Numbers are formatted from
    `NSNumber`, never from typed text.
  - `- (BOOL)alterSequence:(NSString *)name to:(SPPostgresSequenceDefinition *)definition error:(NSError **)error;`
    - Sends only what changed, in one atomic block: `ALTER SEQUENCE … AS/INCREMENT/MINVALUE/MAXVALUE/START/CACHE/
      CYCLE/OWNED BY` (`OWNED BY NONE` when cleared), `RENAME TO`, and `COMMENT`.
    - For an identity sequence, the same options go through `ALTER TABLE "s"."t" ALTER COLUMN "c" SET …` instead,
      and rename and OWNED BY are refused with "This sequence belongs to identity column t.c; rename or detach it
      from the column."
  - `- (BOOL)setValue:(NSNumber *)value isCalled:(BOOL)isCalled ofSequence:(NSString *)name error:(NSError **)error;`
    (`SELECT setval($1::regclass, $2::bigint, $3::boolean)`)
  - `- (NSArray *)columnsUsingSequence:(NSString *)name error:(NSError **)error;`
    - Lists `"s"."t"."c"` for every column whose default refers to the sequence: `pg_depend` from `pg_attrdef`
      to the sequence, then to the column.
    - For an identity sequence, it lists its column.
  - `- (BOOL)dropSequence:(NSString *)name error:(NSError **)error;`
    - When `columnsUsingSequence:` is non-empty, it fails with `SPPostgresErrorHasDependents`, the message
      `"<name>" can't be deleted because these columns use it.`, and the list. Nothing is sent.
    - Otherwise it runs plain `DROP SEQUENCE` (never CASCADE).
- **Sequence pane layout** follows Table Info's label-grid style:
  - Editable fields: Name, Type popup, Start, Increment, Min, Max, Cache, Cycle checkbox, Owned by (a popup of
    `schema.table.column` for integer columns of tables in the schema, plus "None"), and Comment.
  - Read-only: Owner, and "Current value" (`lastValue`, or `Not used yet`).
  - Buttons:
    - **Apply** calls `alterSequence:to:` and reloads.
    - **Revert** reloads.
    - **Set Value…** opens a small sheet with a value field and a "next call returns this value" checkbox, which
      means `isCalled` NO.
  - Number fields accept integers only, enforced by an `NSNumberFormatter` with no fraction digits.
  - Identity sequences show the note above, with Name and Owned by read-only.
- **Add Sequence…** opens a sheet with the same fields, prefilled with the defaults (`bigint`, start 1,
  increment 1, cache 1, no cycle, owned by None). On success the new sequence is selected in the sidebar.
- **Delete Sequence…** asks "Delete sequence "x"?". When the sequence is in use, an alert lists the columns,
  one per line.

- [ ] **Step 1: Extend the fixture** in `structure_test`:
  - `seq_free` (`increment 5 start 100`, comment "free");
  - `seq_used`, used by `used_t.n int default nextval('structure_test.seq_used')`;
  - `t`'s serial sequence `t_id_seq` and its identity sequence `t_ident_seq` already exist (Task 1);
  - in `"Sales Data"`, a sequence `"Odd ""Seq"""`.
- [ ] **Step 2: Write the failing tests:**
  - **Data, both ports:**
    - `testCatalogListsSequencesSorted`
    - `testSequenceDetails`: `seq_free` has start 100, increment 5, comment "free", lastValue nil; after
      `nextval` it is 100, isCalled YES; `t_id_seq` ownedBy is `structure_test.t.id`; `t_ident_seq` isIdentity.
    - `testCreateWithAllOptionsAndOwnedBy`
    - `testAlterChangesOnlyWhatChangedAndRenames`: rename to a 64-byte name is refused before sending.
    - `testAlterIdentitySequenceGoesThroughColumnAndRefusesRename`
    - `testSetValueNextCallReturnsIt`
    - `testDropSequenceInUseIsRefusedAndListsColumns`: `seq_used` lists `structure_test.used_t.n`;
      `t_id_seq` lists `structure_test.t.id`; both still exist.
    - `testDropFreeSequence`
    - `testOddSequenceName`
    - `testChangesInsideUserTransactionKeepItOpen`
  - **View, port 55418:**
    - `testSidebarShowsSequencesSectionBeforeExtensions`
    - `testSelectingSequenceShowsPaneAndDisablesTableItems`
    - `testApplyEditsSequence`
    - `testAddSequenceSheetCreatesAndSelects`: drive the sheet's completion.
    - `testDeleteInUseSequenceShowsColumns`
    - `testHistoryRestoresSequenceSelection`
    - `testQueryCreateSequenceAppearsInSidebar`: uses stage 2's DDL refresh.
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run the full suite and the app build.**
- [ ] **Step 6: Commit.**
- [ ] **Step 7 (controller):** visual check of the SEQUENCES section and the sequence pane.
