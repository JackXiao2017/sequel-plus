# PostgreSQL Stage 9: Table List Bar and Info Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Postgres table list MySQL's bottom bar (Add, Gear, Refresh, Info toggle, split handle), its Table Information pane, and MySQL's gear/right-click table actions (Rename, Duplicate, Truncate, Remove, Open in New Tab/Window, Export, Show/Copy Create Syntax, Add Table).

**Architecture:** The sidebar (`SPPostgresSidebarController`) gains a 23 pt `SPButtonBar` with MySQL's buttons at DBView.xib's frames, and an inner horizontal `SPSplitView` that puts a new `SPPostgresSidebarInfoPane` under the outline. The sidebar only builds UI and forwards actions to its delegate (the document), as it does today for Rename/Duplicate. The document runs every read through its Stage 8 task runner and every write as a short synchronous change behind the Stage 8 busy guards. The SQL lives in a new, separately tested `SPPostgresTableActions`.

**Tech Stack:** Objective-C (MRC in `Source/Postgres`, ARC in "Postgres Tests"), AppKit views built in code, PostgresKit/libpq, XCTest against the Docker PG12/PG18 servers.

**Spec:** `docs/superpowers/specs/2026-10-29-postgresql-mysql-parity-ui-design.md` ("Stage 9: the table list bar and its info pane", "Shared settings", "Decisions").

## Global Constraints

- No MySQL source edits. Reusing `SPButtonBar`, `SPSplitView`, `SPConstants` (`SPTableInformationPanelCollapsed`) and the `button_*` images is allowed; MySQL behaviour through them must not change.
- Postgres views are built in code (no xibs). Images: `button_add`, `button_action`, `button_refresh`, `button_pane_hide` / `button_pane_show`, `button_bar_handle`, `button_bar_spacer` (through `SPButtonBar`).
- Truncate and Remove never use CASCADE; a dependency error shows the server's message (spec Decisions).
- Never DROP DATABASE. No writes to `~/Library/Application Support/Sequel Pro/Data/Favorites.plist`.
- Tests never write the real preferences or the login keychain: anything that writes a default uses an injected scratch `NSUserDefaults` (`initWithSuiteName:@"SPPostgresStage9Tests"`, removed in tearDown).
- Stage 8 rules hold: no read of the tab connection on the main thread while the runner may use it (reads go through `document.taskRunner`); every write starts with `_endPaneEditing` and the `isProcessing` / `_refuseWriteWhileBusy` guards; controls that start a query are disabled while `isProcessing`.
- Add files to the project only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test <paths>`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never touch the untracked `start_clause.sh`.
- Test commands (servers: `bash Scripts/pg-test-servers.sh up`):
  - one class: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64 -only-testing:"Postgres Tests"/<Class>`
  - full suite: same without `-only-testing`, `timeout 1500`
  - app: `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`

### Rulings on the spec (made while planning)

- **Button order follows MySQL's DBView.xib, not the spec's table.** Left to right: Add (x −1), Gear (29), Refresh (61), Info toggle (92, 32×25 at y −1), handle (`button_bar_handle` image view at x = width − 15, 15×23). The spec's goal is "position … match MySQL".
- **Multiple selection is supported** for TABLES and VIEWS rows (spec: "selected table(s)/view(s)"), as MySQL's. Sequences, extensions and headers stay single-selection.
- **MySQL's Remove "Force delete (disables integrity checks)" checkbox is left out**: its Postgres equivalent would be CASCADE, which the spec forbids.
- **Multi-item Remove and Truncate are all-or-nothing** (one structure change), where MySQL stops part way; a failure leaves every table in place.
- **Export ▸ has no "As XML file…"** (spec non-goal).
- **The info pane's facts** are those `-[SPPostgresTableStructure tableInfo:]` already reads (kind, owner, row estimate, table/index/total size, comment).

## Review Focus

1. **Names that need quoting**, such as schema `"Sales Data"` / table `"Orders 2026"` and schema `a"b`: every action must act on exactly that object. Pinned in Task 3 (`testActionsQuoteSchemaAndName`).
2. **Removing a table a view depends on**: the server's dependency message is shown and nothing is dropped, including the other items of a multi-selection. Pinned in Task 3 (`testDropWithDependentFailsAndDropsNothing`) and Task 5 (`testRemoveDependencyErrorShowsServerMessage`).
3. **Acting on the table that is open with an unsaved edit, or while a load runs**: the edit is committed first (or the action refused), and nothing runs while `isProcessing`. Pinned in Task 5 (`testRemoveRefusedWhileBusy`, `testRemoveShownTableCommitsEditFirst`).
4. **Multiple selection crossing into single-item behaviour**: two tables selected shows no table in the panes and "multiple selection" in the info pane. Returning to one table loads it again, and History records no multi-selection entry. Pinned in Task 2 (`testMultipleSelectionClearsPanes`).
5. **The info toggle and the shared preference**: the toggle writes `TableInformationPanelCollapsed` only to the injected defaults, and a new tab honours the stored value. Pinned in Task 1 (`testInfoToggleUsesInjectedDefaults`).

---

### Task 1: The bar, the inner split and Refresh

**Files:**
- Modify: `Source/Postgres/SPPostgresSidebarController.h`, `.m` (`_buildView`, `invalidate`)
- Modify: `Source/Postgres/SPPostgresDocument.m` (`_buildContent`, `_updateIsProcessing`)
- Test: `PostgresTests/SPPostgresSidebarBarTests.m` (new; `add-test`)

**Interfaces:**
- Produces, on `SPPostgresSidebarController`:
  - `@property (readonly) NSButton *addButton, *refreshButton, *infoToggleButton;`
  - `@property (readonly) NSPopUpButton *gearButton;` A pull-down whose item 0 is the hidden `button_action` image item. It is added to the view *after* the schema pop-up so that `testSidebarListsTablesViewsAndExtensionsForPublic`'s subview walk still finds the schema pop-up first; check that test still passes.
  - `@property (readonly) NSView *splitHandleView;`, `@property (readonly) SPSplitView *infoSplitView;`, `@property (readonly) NSView *infoPaneContainer;` (166 pt tall, collapsible subview index 1, toggle button `infoToggleButton`)
  - `@property (nonatomic, retain) NSUserDefaults *defaults;` (default `standardUserDefaults`; read when the view is built and on toggle)
  - `@property (nonatomic) BOOL actionsEnabled;` (Add, Gear and Refresh enabled state; the Info toggle stays enabled)
  - `- (IBAction)refreshTables:(id)sender;` calls `reloadKeepingSelection:` through the delegate's quiet completion (new optional delegate method `- (void)sidebarRefresh:(SPPostgresSidebarController *)sidebar;`, implemented by the document as `[sidebar reloadKeepingSelection:[self _quietSidebarCompletion:nil]]` after `_endPaneEditing`, refused while `isProcessing`)
  - `- (IBAction)toggleInfoPane:(id)sender;` toggles `infoSplitView` and writes `[NSNumber numberWithBool:collapsed]` to `defaults` under `SPTableInformationPanelCollapsed`, as `-[SPTablesList togglePaneCollapse:]` does.
- The document passes `splitHandleView` to its `splitView` with `setAdditionalDragHandleView:`, and sets `sidebar.actionsEnabled = !isProcessing` in `_updateIsProcessing`.

Values (from DBView.xib): bar `SPButtonBar` frame `(0,0,width,23)`, `NSViewWidthSizable|NSViewMaxYMargin`. Buttons are siblings over the bar, `NSViewMaxXMargin`:

| Button | Frame | Image / alternate | Tooltip | Style | Action |
|---|---|---|---|---|---|
| Add | (−1,0,32,23) | `button_add` | `Add new table` | `NSSmallSquareBezelStyle`, image only | `addTable:` (enabled only while `actionsEnabled` and the delegate responds to `sidebarAddTable:`, which arrives in Task 6) |
| Gear | (29,0,36,23) | item 0 image `button_action` | none | pull-down, `NSRegularSquareBezelStyle` bevel, no arrow | menu (Task 4) |
| Refresh | (61,0,32,23) | `button_refresh` | `Refresh table list` | `NSSmallSquareBezelStyle` | `refreshTables:` |
| Info | (92,−1,32,25) | `button_pane_hide` / `button_pane_show` | `Toggle the visibility of the Information panel` | `NSTexturedRoundedBezelStyle`, `NSToggleButton` | `toggleInfoPane:` |

Handle: `NSImageView` `(width−15,0,15,23)`, `button_bar_handle`, `NSViewMinXMargin`. The outline's scroll view becomes the top subview of `infoSplitView`, which fills `y = 23` up to the schema bar.

- [ ] **Step 1: Write the failing tests** in `SPPostgresSidebarBarTests` (document scaffold copied from `SPPostgresDocumentTests -setUp/-tearDown`, port 55418, fixture `catalog`):
  - `testBarButtonsMatchMySQL`: for each button, assert the frame, image name (`[[button image] name]`), tooltip, action, and left-to-right order Add < Gear < Refresh < Info; assert `[bar isKindOfClass:[SPButtonBar class]]` and bar height 23.
  - `testSplitHandleIsWired`: `splitHandleView.frame.size.width == 15`, its image is named `button_bar_handle`, and the document's split view's additional drag handle is that view (`[splitView valueForKey:@"additionalDragHandleView"]`).
  - `testRefreshReloadsList`: on a second connection, `CREATE TABLE public.sp9_new (id int)`, then `[sidebar.refreshButton performClick:nil]`, wait for the runner, and assert `sp9_new` is in `itemTitlesInSection:@"TABLES"` with the previous selection kept. Drop it in tearDown.
  - `testInfoToggleUsesInjectedDefaults` (Review Focus 5): with `sidebar.defaults` = scratch suite, `performClick:` collapses the pane, so `isCollapsibleSubviewCollapsed == YES`, the button state is `NSOnState`, and scratch `boolForKey:SPTableInformationPanelCollapsed == YES`. A second click expands it and stores NO. A sidebar built with scratch defaults holding YES starts collapsed.
  - `testBarDisabledWhileBusy`: `queueSleep:1 onRunner:`, then Add/Gear/Refresh are disabled and Info stays enabled; after `waitForRunner:` they are enabled again.
- [ ] **Step 2: Run** the class → FAIL (no such properties).
- [ ] **Step 3: Implement** the bar, the inner split, Refresh, the toggle and the document wiring above. `invalidate` clears every new button's target and the gear menu items' targets.
- [ ] **Step 4: Run** `SPPostgresSidebarBarTests` and `SPPostgresDocumentTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 1: table list bar, info split and Refresh`.

### Task 2: Multiple selection of tables and views

**Files:**
- Modify: `Source/Postgres/SPPostgresSidebarController.h`, `.m`
- Modify: `Source/Postgres/SPPostgresDocument.m` (selection handling, history)
- Test: `PostgresTests/SPPostgresSidebarBarTests.m`

**Interfaces:**
- Produces on the sidebar:
  - `@property (readonly) NSArray<NSString *> *selectedRelationNames;` Tables and views in display order. It holds one name for a single selection and is empty when a sequence, extension or nothing is selected.
  - `- (BOOL)relationIsView:(NSString *)name;` YES if the name is in VIEWS (views and materialized views).
  - `- (BOOL)selectRelationsNamed:(NSArray<NSString *> *)names;` (for tests and for restoring after a reload)
  - `- (NSArray<NSString *> *)actionTargetRelationNames;` The clicked row's name if the click is outside the selection, otherwise `selectedRelationNames`. Every relation action in Tasks 4–8 acts on this list.
- Behaviour: the outline allows multiple selection, but `outlineView:selectionIndexesForProposedSelection:` keeps a multi-row selection only when every row is a TABLES or VIEWS item. Otherwise it keeps just the last-clicked row. With more than one relation selected, `selectedTableName` is nil, so the document shows no table in its panes, and History records nothing. `reloadKeepingSelection` restores the multi-selection by name.

- [ ] **Step 1: Write the failing tests:**
  - `testSelectingTwoTablesReportsBoth`: `selectRelationsNamed:@[@"customers", @"v_customers"]`, then `selectedRelationNames` equals both in display order, `selectedTableName == nil`, and `relationIsView:@"v_customers"` is YES.
  - `testSequenceCannotJoinMultipleSelection`: the proposed indexes table + sequence row reduce to one row.
  - `testMultipleSelectionClearsPanes` (Review Focus 4): with `customers` shown in Content, select two relations. Content shows no table, `history.canGoBack` is unchanged by the multi-selection, and selecting `customers` alone loads its rows again.
  - `testReloadKeepsMultipleSelection`: select two, `reloadKeepingSelection`, wait, both still selected.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresSidebarBarTests`, `SPPostgresDocumentTests` and `SPPostgresHistoryTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 2: multiple selection of tables and views`.

### Task 3: Table actions SQL

**Files:**
- Create: `Source/Postgres/SPPostgresTableActions.h`, `.m` (`add-app`; export the class with `__attribute__((visibility("default")))`)
- Test: `PostgresTests/SPPostgresTableActionsTests.m` (new; `add-test`; runs on PG12 55412 and PG18 55418)

**Interfaces:**
- Produces (all synchronous on the given connection; callers run them as short writes on the main thread when not busy). Each returns NO with the `SPPostgresErrorDomain` error from `SPPostgresRunStructureChange` on failure:
  - `+ (BOOL)truncateTables:(NSArray<NSString *> *)tables inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error;` One `TRUNCATE TABLE "s"."a", "s"."b"` statement (no CASCADE, no RESTART IDENTITY).
  - `+ (BOOL)dropRelations:(NSArray<NSString *> *)names inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error;` Inside one `SPPostgresRunStructureChange`, it reads each name's `relkind` from `pg_class`, then runs `DROP TABLE` (r, p, f→`DROP FOREIGN TABLE`), `DROP VIEW` (v) or `DROP MATERIALIZED VIEW` (m) for every item, with no CASCADE. Either all are dropped or none are. A dependency failure keeps the server's message and its dependents, as `SPPostgresErrorHasDependents` does for sequences.
  - `+ (BOOL)createTableNamed:(NSString *)name inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error;` Runs exactly `CREATE TABLE "s"."n" (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY)` (spec).
  - Quoting is `SPPostgresQuoteIdentifier` on the schema and on each name.

- [ ] **Step 1: Write the failing tests** (create and drop their own `sp9_*` objects in schema `public` and in a schema named `Sales Data`):
  - `testTruncateEmptiesTables`: two tables with rows, truncated together, then both `count(*) == 0` and their definitions are still there.
  - `testDropTablesViewsAndMaterializedViews`: one call with a table, a view and a materialized view, then all three are gone from `pg_class`.
  - `testDropWithDependentFailsAndDropsNothing` (Review Focus 2): table `sp9_base`, view `sp9_dep` on it, and an unrelated table `sp9_other`. `dropRelations:@[@"sp9_other", @"sp9_base"]` returns NO, the error's description contains `sp9_dep`, and `sp9_other` and `sp9_base` still exist.
  - `testTruncateReferencedTableFails`: a table referenced by an FK from a non-selected table returns NO with the server's message and keeps its rows.
  - `testCreateTableMatchesSpec`: `createTableNamed:@"sp9_made"`, then the column `id` is `integer`, `attidentity = 'd'`, and it is the primary key. A second call returns NO (the name already exists).
  - `testActionsQuoteSchemaAndName` (Review Focus 1): create, truncate and drop `"Orders ""x"" 2026"` in schema `Sales Data`, while a same-named lower-case decoy table in `public` stays untouched.
  - `testActionsInsideUserTransaction`: with `BEGIN` open on the connection, a successful drop leaves the transaction open (the change is inside it), and after a failed statement in an aborted transaction the call returns NO without running.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresTableActionsTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 3: truncate, drop and create table statements`.

### Task 4: Gear menu and the right-click menu

**Files:**
- Modify: `Source/Postgres/SPPostgresSidebarController.h`, `.m` (`tableMenu`, gear menu, `validateMenuItem:`, `invalidate`, delegate protocol)
- Test: `PostgresTests/SPPostgresSidebarBarTests.m`; update `testDuplicateTableFromSidebarMenuSelectsCopy` in `SPPostgresDocumentTests` for the new item list

**Interfaces:**
- New optional delegate methods (each takes the target list from `actionTargetRelationNames` and the selected schema; the document implements them in Tasks 5–8):
  - `- (void)sidebar:(SPPostgresSidebarController *)sidebar truncateTables:(NSArray<NSString *> *)tables;`
  - `- (void)sidebar:(SPPostgresSidebarController *)sidebar removeRelations:(NSArray<NSString *> *)names;`
  - `- (void)sidebar:(SPPostgresSidebarController *)sidebar openRelation:(NSString *)name inNewWindow:(BOOL)newWindow;`
  - `- (void)sidebar:(SPPostgresSidebarController *)sidebar exportRelations:(NSArray<NSString *> *)names format:(NSInteger)format;` (0 = SQL dump, 1 = CSV, matching MySQL's tags)
  - `- (void)sidebar:(SPPostgresSidebarController *)sidebar showCreateSyntaxForRelations:(NSArray<NSString *> *)names copy:(BOOL)copy;`
  - `- (void)sidebarAddTable:(SPPostgresSidebarController *)sidebar;`
- Menu order, for both the gear menu (after its hidden image item) and `tableMenu`, as MySQL's: Rename…, Duplicate…, —, Truncate, Remove, —, Open in New Tab, Open in New Window (⌥ alternate: `setAlternate:YES`, `NSAlternateKeyMask`), —, Export ▸ (As SQL dump…, As CSV file…), —, Show Create Syntax…, Copy Create Syntax.
- Titles are set each time the menu is validated, from the targets, using MySQL's runtime strings with `…` as Postgres menus already write it:
  - one table: `Rename Table…`, `Duplicate Table…`, `Truncate Table`, `Delete Table`, `Open Table in New Tab`, `Open Table in New Window`, `Show Create Table Syntax…`, `Copy Create Table Syntax`
  - one view: `Rename View…`, `Duplicate View…`, `Delete View`, `Open View in New Tab`, `Open View in New Window`, `Show Create View Syntax…`, `Copy Create View Syntax`; Truncate is hidden
  - several: `Delete Tables` / `Delete Views` / `Delete Items` (mixed); `Truncate Tables` is shown only when all are tables; Rename, Duplicate and the Open items are hidden; `Show Create Syntaxes…`, `Copy Create Syntaxes`
  - the gear's first item stays the hidden image item. Export ▸ `As SQL dump…` and `As CSV file…`.
- Enabling: Rename/Duplicate/Open need exactly one target (Rename and Duplicate stay tables-only, as today). Truncate, Remove, Export and Create Syntax need at least one target. Every item is disabled when `actionsEnabled` is NO or the delegate doesn't respond. With a sequence or extension selected, the gear button's menu is `sequenceMenu` or `extensionMenu` (as `menuForRow:` does).
- The existing `tableMenu` items `Duplicate Table…`/`Rename Table…` move into MySQL's order (Rename first). Update `testDuplicateTableFromSidebarMenuSelectsCopy` to find Duplicate by action, not index.

- [ ] **Step 1: Write the failing tests:**
  - `testGearMenuOrderAndTitlesForTable`: select `customers`, validate every item, and assert visible titles in order equal the one-table list above with separators where shown.
  - `testMenuTitlesForViewAndMultiple`: for `v_customers` alone and for customers + v_customers, assert the titles and that Truncate is hidden.
  - `testRightClickOutsideSelectionTargetsClickedRow`: with `customers` selected and `v_customers` right-clicked, `actionTargetRelationNames == @[@"v_customers"]`.
  - `testGearShowsSequenceMenuForSequence`.
  - `testItemsDisabledWhileBusy`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresSidebarBarTests` and `SPPostgresDocumentTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 4: gear and right-click menus as MySQL's`.

### Task 5: Truncate and Remove in the document

**Files:**
- Modify: `Source/Postgres/SPPostgresDocument.m` (`#pragma mark - Sidebar`)
- Test: `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- Consumes: Task 3's `SPPostgresTableActions`; Task 4's delegate methods.
- Both actions follow `sidebar:deleteSequenceNamed:` (guard `tornDown || isProcessing || !parentWindow || [parentWindow attachedSheet]`, `_endPaneEditing`, `_confirm:completion:`, `_refuseWriteWhileBusy` at confirm time, errors through `_presentAlert:`, then `[sidebar reloadKeepingSelection:[self _quietSidebarCompletion:nil]]` and the panes marked for reset). A removed table that was shown leaves no table selected.
- Alerts (MySQL's text, critical style, `Cancel` = Return/Escape as `deleteSequence`). `%@` is the name; the kind word is `table`/`view`; the plural is `tables`, `views` or `items`:
  - Truncate one: message `Truncate table '%@'?`, informative `Are you sure you want to delete ALL records in the table '%@'? This operation cannot be undone.`, buttons `Truncate` / `Cancel`
  - Truncate several: `Truncate selected tables?` / `Are you sure you want to delete ALL records in the selected tables? This operation cannot be undone.`
  - Remove one: `Delete %@ '%@'?` / `Are you sure you want to delete the %@ '%@'? This operation cannot be undone.`, buttons `Delete` / `Cancel`
  - Remove several: `Delete selected %@?` / `Are you sure you want to delete the selected %@? This operation cannot be undone.`
  - Errors: title `Error truncating table` or `Error deleting table`, then the server message (with the dependents one per line, as sequences show them).

- [ ] **Step 1: Write the failing tests** (`confirmationPresenter` answers, `captureAlerts`, throwaway `sp9_*` tables):
  - `testTruncateConfirmedEmptiesTable` and `testTruncateCancelledKeepsRows`, asserting the alert texts verbatim for one and for two tables.
  - `testRemoveTwoItemsDropsBothAndClearsSelection`: a table and a view; alert `Delete selected items?`; both gone from the list after the reload.
  - `testRemoveDependencyErrorShowsServerMessage` (Review Focus 2): the alert title is `Error deleting table` and the text contains the dependent view's name; the list is unchanged.
  - `testRemoveRefusedWhileBusy` (Review Focus 3): with `queueSleep:` running, the delegate call shows no alert and drops nothing.
  - `testRemoveShownTableCommitsEditFirst` (Review Focus 3): with a Structure draft or Content cell edit pending on another table shown, the edit is saved before the confirmation appears; if `_endPaneEditing` fails, there is no confirmation and nothing is dropped.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresDocumentTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 5: Truncate and Remove with MySQL's confirmations`.

### Task 6: Add Table

**Files:**
- Modify: `Source/Postgres/SPPostgresDocument.m`, `Source/Postgres/SPPostgresSidebarController.m` (`addTable:` forwards to `sidebarAddTable:`)
- Test: `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- Sheet built in code like `_showDuplicateTableSheetForTable:` (ivar `addTableSheet`, the same guards plus `[selectedSchema length]`). Title `New Table`; one label `Table Name:` with a text field (identifier `addTableName`); buttons `Add` (identifier `addTableButton`, Return, disabled until the name is non-empty after trimming, as MySQL enables it on a valid name) and `Cancel` (Escape). Action `closeAddTableSheet:` ends with the sender's tag.
- On Add: `+[SPPostgresTableActions createTableNamed:inSchema:connection:error:]` as a short write. On success the sidebar reloads the schema, selects the new table and shows `SPPostgresPaneStructure`, as MySQL. On failure the alert is `Error adding new table` with the server message and button `OK`.

- [ ] **Step 1: Write the failing tests:**
  - `testAddTableCreatesSelectsAndShowsStructure`: click `addButton`, type `sp9_added`, click Add, wait. The table exists with the spec's `id` column, the sidebar selects it, and `currentPane == SPPostgresPaneStructure`.
  - `testAddButtonDisabledForBlankName`.
  - `testAddExistingNameShowsError`: `customers` → alert `Error adding new table`, nothing changes.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresDocumentTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 6: Add Table sheet`.

### Task 7: Info pane, Export and Create Syntax

**Files:**
- Create: `Source/Postgres/SPPostgresSidebarInfoPane.h`, `.m` (`add-app`)
- Modify: `Source/Postgres/SPPostgresSidebarController.m` (hosts the pane in `infoPaneContainer`), `Source/Postgres/SPPostgresDocument.m`
- Test: `PostgresTests/SPPostgresSidebarBarTests.m`, `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- `SPPostgresSidebarInfoPane`:
  - `- (instancetype)initWithFrame:(NSRect)frame;`
  - `@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;`
  - `- (void)showRelation:(NSString *)name inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection;`
  - `- (void)showNothing;`, `- (void)showMultipleSelection;`, `- (void)invalidate;`
  - `@property (readonly) NSArray<NSString *> *lines;` (for tests)
- It is a single-column source-list `NSTableView` like MySQL's: group header row 25 pt, other rows not selectable. It reads `-[SPPostgresTableStructure tableInfo:]` in a runner task, using `SPPostgresPaneLoader`'s generation so a stale read never shows.
- Lines:
  - header `TABLE INFORMATION` (tables, partitioned and foreign) or `VIEW INFORMATION` (views and materialized views), then:
    - `type: %@` (the `kind` value)
    - `owner: %@`
    - `rows: ~%@` (decimal-style number formatter), or `rows: unknown` when the estimate is NSNull (tables and materialized views only)
    - `size: %@` (tableSize), `index size: %@`, `total size: %@` (tables and materialized views only)
    - `comment: %@`, omitted when there is no comment
  - nothing selected, or a sequence or extension selected: `INFORMATION`
  - more than one relation: `INFORMATION`, `multiple selection` (MySQL's)
  - on a failed read: the header and `error occurred` (MySQL's)
- While the pane is collapsed, it reads nothing; expanding it loads the current selection. The document refreshes it after a Table Info comment save (`_tableInfoDidChange`) and after Task 5/6 changes.
- Export: `sidebar:exportRelations:format:` runs `export:` (it keeps `_canRunSheetJob`), then checks exactly those names with `setChecked:table:schema:` and sets `formatControl` to SQL (0) or CSV (1). A name the export cannot include is left unchecked.
- Create Syntax: a read in a runner task (`+[SPPostgresCreateStatement createStatementForTable:inSchema:connection:error:]` per name, joined with a `-- Create syntax for %@ '%@'` header when several). With `copy:YES` it goes to the general pasteboard. Otherwise it shows a sheet titled as MySQL's label: `Create syntax for %@ '%@'` (one) or `Create syntaxes for selected items` (several). The sheet has a non-editable monospaced text view (identifier `createSyntaxText`), plus `Copy` and `Close` buttons. On failure: the alert `An error occured while creating table syntax.` followed by the server message.

- [ ] **Step 1: Write the failing tests:**
  - `testInfoPaneShowsTableFacts`: select `customers`, wait, `lines[0] == @"TABLE INFORMATION"`, and lines contain `type: table`, `owner: pgkit_test` and a line with prefix `rows: ` and prefix `total size: `.
  - `testInfoPaneShowsViewAndComment`: after `COMMENT ON VIEW public.v_customers IS 'hello'` (reverted in tearDown), the pane shows `VIEW INFORMATION` and `comment: hello`, and no size lines.
  - `testInfoPaneMultipleAndNothing`.
  - `testInfoPaneReadsNothingWhileCollapsed`: collapsed, select a table, and the runner stays idle (no task queued).
  - `testExportPreselectsRelationsAndFormat`: gear Export ▸ As CSV file… on customers, then the export controller's checked set is exactly `customers` and `formatControl.selectedSegment == 1`.
  - `testCopyCreateSyntaxPutsStatementOnPasteboard`: use a private `NSPasteboard pasteboardWithName:` injected through a test property `createSyntaxPasteboard` on the document (default general), so the user's clipboard is untouched. Its string starts with `CREATE TABLE "public"."customers"` (the formatter's quoting, as Table Info shows it).
  - `testShowCreateSyntaxSheetForTwo`: the sheet's text contains both headers.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresSidebarBarTests`, `SPPostgresDocumentTests` and `SPPostgresExportControllerTests` → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 7: info pane, Export and Create Syntax from the table list`.

### Task 8: Open Table in New Tab / Window

**Files:**
- Modify: `Source/Postgres/SPPostgresDocument.h`, `.m`
- Test: `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- `- (void)openRelation:(NSString *)name inSchema:(NSString *)schema inNewWindow:(BOOL)newWindow;` (public, so tests can call it; the sidebar delegate method forwards here). It copies `favorite`, sets the database to `currentDatabase`, and connects a new `SPPostgresConnector` with the tab's passwords, as `_defaultConnectionProviderAdopting:` builds one. Nothing is written to the keychain or to Favorites.plist. It creates a new `SPPostgresDocument` on the new connection and adds it to `parentWindowController` right after this tab (`addTabDocument:atIndex:select:YES`), or for a new window to a new `SPWindowController` (`initWithWindowNibName:@"MainWindow"`, `showWindow:`).
- The new document selects `schema`, then `name` (table or view), once its first load is done. Add `- (void)selectRelationAfterLoad:(NSString *)name inSchema:(NSString *)schema;` on the new document for this; it waits for the runner instead of polling on the main thread.
- While connecting, the source tab shows its normal connecting state (`pendingConnector` is already part of `isProcessing`). A failed connect shows the connector's error alert in the source tab and opens nothing.

- [ ] **Step 1: Write the failing tests:**
  - `testOpenInNewTabSelectsSameTable`: from schema `Sales Data` with `Orders 2026` selected, `openRelation:inSchema:inNewWindow:NO`, wait for the new document's runner. The window has one more tab, right after the source, and the new document has the same favorite name and database, `sidebar.selectedSchema == @"Sales Data"` and `selectedTableName == @"Orders 2026"`. Its connection is a different object from the source's.
  - `testOpenInNewWindowOpensWindow`: a new `SPWindowController` window whose selected document shows the table; close it in the test.
  - `testOpenFailureOpensNothing`: a favorite copy with a bad port injected through the document's existing connection-provider test seam gives one alert and no new tab.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SPPostgresDocumentTests` → PASS, then the **full suite** → 0 failures, and the **app build** → `** BUILD SUCCEEDED **` with no new warnings in `Source/Postgres`.
- [ ] **Step 5: Commit** `Postgres Stage 9 Task 8: Open Table in New Tab and New Window`.
