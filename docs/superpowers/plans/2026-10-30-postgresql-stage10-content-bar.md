# PostgreSQL Stage 10: Content Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Postgres Content tab MySQL's bottom bar: Add row, Delete row(s), Duplicate row, Refresh, the edit mode toggle, the filter show/hide toggle, the row count, and Previous / Jump to page / Next. Use MySQL's positions, images, tooltips, shortcuts and behaviour.

**Architecture:** The bar stays inside `SPPostgresContentController` (built in code). This stage moves the existing buttons to DBView.xib's frames and adds the four new ones. Each new function goes in its own task:
- **Duplicate:** a new `SPPostgresTableData` insert.
- **Edit mode:** the shared `SPFieldEditorController` sheet, behind a presenter seam.
- **Filter toggle:** shows or hides the existing filter bar.
- **Jump to page:** a code-built popover view controller in a new file.

Every preference the bar reads or writes goes through an injectable `defaults`, so tests use a scratch domain. The Stage 8 rules are unchanged: loads go through `taskRunner`, short writes run on main and are refused while busy, and the bar is disabled while the runner is busy.

**Tech Stack:** Objective-C (MRC in `Source/Postgres`, ARC in "Postgres Tests"), AppKit built in code, PostgresKit/libpq, XCTest against the Docker PG12/PG18 servers.

**Spec:** `docs/superpowers/specs/2026-10-29-postgresql-mysql-parity-ui-design.md` ("Stage 10: the Content bar", "Shared settings", "Anti-goals").

## Global Constraints

- **No MySQL source edits.** Reusing these is allowed, but MySQL behaviour through them must not change:
  - `SPButtonBar`, `SPTableView` (subclassing it is fine), `SPFieldEditorController`
  - `SPConstants` keys and the `button_*` images
- **Images:**
  - `button_add`, `button_remove`, `button_duplicate`, `button_refresh`
  - `button_edit_mode` / `button_edit_mode_selected`
  - `button_filter` / `button_filter_active`
  - `button_left`, `button_pagination` (and `button_action` while the popover is shown), `button_right`
- **Shared preference keys (same as MySQL):**
  - `SPEditInSheetEnabled` (`EditInSheetEnabled`)
  - `SPRuleFilterEditorLastVisibilityChoice` (`RuleFilterEditorLastVisibilityChoice`)
  - `SPLimitResults` (`LimitResults`) and `SPLimitResultsValue` (`LimitResultsValue`)
- **Defaults:** every read and write of those keys goes through the controller's `defaults` property, which defaults to `standardUserDefaults`.
- **Tests never write the real preferences.** A test that writes a default injects `[[NSUserDefaults alloc] initWithSuiteName:@"SPPostgresStage10Tests"]`, sets the keys it reads explicitly, and calls `removePersistentDomainForName:` in tearDown.
- **Stage 8 rules:**
  - No main-thread read of the connection while the runner may use it.
  - Short writes (add, duplicate, delete, cell or sheet edit) run on main, after `_endEditing`, and beep and do nothing while `[taskRunner isBusy]` or `isInvalidated` (`_refuseWriteWhileBusy`).
- **New files:** add them only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test <paths>`.
- **Commits:** trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never touch the untracked `start_clause.sh`.
- **Test commands** (start the servers first with `bash Scripts/pg-test-servers.sh up`):
  - one class: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64 -only-testing:"Postgres Tests"/<Class>`
  - full suite: same without `-only-testing`, `timeout 1500`
  - app: `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`

### Rulings on the spec (made while planning)

- **The filter button's active image means "the filter bar is shown", as in MySQL.** The spec says "the active image when a filter is applied, as MySQL". MySQL's `toggleRuleFilterButton` is an on/off button whose on state (`button_filter_active`) is "editor visible". Its state is not tied to a filter being applied. "As MySQL" wins.
- **The filter bar's visibility is MySQL's preference** (`RuleFilterEditorLastVisibilityChoice`, read at each table load, written by the toggle). It defaults to hidden, so a Postgres tab now starts with the filter bar hidden, as MySQL's does.
- **Hiding the filter bar while a filter is applied reloads unfiltered** (page 1, sort kept). MySQL drops the filter but leaves the filtered rows on screen until the next load. A filter you can't see must not keep narrowing the rows.
- **The Jump to page popover leaves out "Defer loading of blobs and texts".** Postgres rows always load as text, so the checkbox would do nothing. The popover keeps "Jump to page:", the page field, stepper and Go, a separator, and "Limit result to: [n] rows" with its stepper.
- **⌫ / ⌦ in the grid delete the selected rows,** as the tooltip "Delete selected row(s) (⌫)" says. This is done by a Postgres subclass of `SPTableView`; `SPTableView` itself is not changed.
- **The Delete Row confirmation uses MySQL's keys:** ⌘D on Delete, Return on Cancel, as `-[SPTableContent removeRow:]` does. Postgres currently has Return on Delete and Escape on Cancel.
- **The bar is disabled while the runner is busy** (MySQL: `![tableDocumentInstance isWorking]`), except the edit mode toggle, which in MySQL is only a preference binding.
- **Edit mode on a read-only table (view, no primary key, generated column) opens the sheet read-only**, as MySQL opens it with `isEditable:NO`.
- **MySQL's spinner in the bar (DBView.xib id 858) is not cloned.** Stage 8's tab spinner and loading display already show a load.

## Review Focus

1. **Duplicating a row whose primary key is not auto-numbered** (e.g. a `text` key): the server's unique-violation message is shown, nothing is added, and the grid and counts are unchanged. Pinned in Task 2 (`testDuplicateWithPlainKeyShowsServerErrorAndAddsNothing`).
2. **Jump to page with 0, an empty field, or a page past the end**: the page shown is clamped to 1 or the last page, with no error. Pinned in Task 5 (`testGoToPageClampsOutOfRangePages`).
3. **Changing "Limit result to" in the popover without pressing Go**: the count line keeps describing the rows on screen (computed with the page size they were loaded with); Go or Refresh applies the new size. Pinned in Task 5 (`testCountTextUsesLoadedPageSize`).
4. **Edit mode turned on in another tab**: the Postgres toggle follows the shared preference without a reload, and the next double-click opens the sheet. Pinned in Task 3 (`testEditModeButtonFollowsPreferenceChangedElsewhere`).
5. **⌘D, ⌥⌘A or ⌫ while a load runs, or while a cell is being edited**:
   - While a load runs, nothing is written: the buttons are disabled and the direct calls beep.
   - ⌫ while editing deletes characters, not rows.
   - Pinned in Task 1 (`testDeleteKeyWhileEditingDoesNotDeleteRows`, `testBarDisabledWhileBusy`) and Task 2 (`testDuplicateRefusedWhileBusy`).

---

### Task 1: The bar in MySQL's layout, ⌫ in the grid, busy state

**Files:**
- Modify: `Source/Postgres/SPPostgresContentController.h`, `.m` (`_buildView`, `_updateBottomBar`, `invalidate`, `removeRows:`, preference reads)
- Test: `PostgresTests/SPPostgresContentBarTests.m` (new; `add-test`). Bar tests go here; leave `SPPostgresContentControllerTests.m` as it is except where a test pinned the old Delete-alert keys.

**Interfaces:**
- Produces, on `SPPostgresContentController`:
  - `@property (readonly) NSButton *addButton, *removeButton, *duplicateButton, *refreshButton, *editModeButton, *filterToggleButton, *previousPageButton, *paginationButton, *nextPageButton;`
  - `@property (readonly) NSTextField *countField;`
  - `@property (nonatomic, retain) NSUserDefaults *defaults;` Default `standardUserDefaults`. `_pageSize`, `_nullPlaceholder` and `_tableFont` read through it.
  - Private: `SPPostgresContentGrid : SPTableView` (in the .m), the grid's class.
- **Buttons created but not yet wired:** `duplicateButton`, `editModeButton`, `filterToggleButton` and `paginationButton` exist in this task with their images, tooltips and key equivalents, but are disabled with no action until Tasks 2–5.

- [ ] **Step 1: Write the failing tests** in `SPPostgresContentBarTests` (use the same server and fixture setup as `SPPostgresContentControllerTests`; the view is 700 pt wide when built):
  - `testBarButtonsAtMySQLFrames`:
    - Every button's frame is `{x, -1, 32, 25}`, with x as follows:
      - add −1, remove 30, duplicate 61, refresh 93, editMode 124, filterToggle 155
      - previous `width − 110`, pagination `width − 79`, next `width − 48`
    - Every button uses `NSBezelStyleTexturedRounded`.
    - After resizing the view to 900 pt, the right three keep their distance from the right edge.
  - `testBarImagesTooltipsAndKeys`:
    - Images and alternate images as in Global Constraints.
    - `editModeButton` and `filterToggleButton` have `NSButtonTypePushOnPushOff`.
    - Exact tooltips:
      - Add: `@"Add row (⌥⌘A)"`
      - Remove: `@"Delete selected row(s) (⌫)"`
      - Duplicate: `@"Duplicate selected row (⌘D)"`
      - Refresh: `@"Refresh table contents (⌘R)"`
      - Edit mode: `@"Toggle between editing simple text cells as a spreadsheet or in pop-up sheets"`
      - Filter: `@"Show/Hide table content filters"`
      - Previous: `@"View previous page of results"`
      - Pagination: `@"Jump to page (⌘J) or view pagination options"`
      - Next: `@"View next page of results"`
    - Key equivalents:
      - Add `@"a"` with ⌥⌘; duplicate `@"d"` with ⌘; refresh `@"r"` with ⌘; pagination `@"j"` with ⌘.
      - Remove `@""`.
  - `testCountFieldBetweenFilterAndPrevious`: `countField.frame.origin.x == 193`. Its right edge, and the notice field's right edge if shown, are ≤ `width − 140`.
  - `testDeleteKeyInGridAsksToDeleteSelectedRows`: select row 0, then send the grid a keyDown with keyCode 51 (`NSEvent keyEventWithType:`). `confirmationPresenter` is called once with message `@"Delete selected row?"`. keyCode 117 does the same. With no selection, the presenter is not called.
  - `testDeleteKeyWhileEditingDoesNotDeleteRows`: with a cell edit in progress (`editColumn:row:withEvent:select:` in a window), keyCode 51 does not call the presenter.
  - `testDeleteRowAlertUsesMySQLKeys`: in the alert passed to `confirmationPresenter`:
    - Button 0 is `@"Delete"`, with `keyEquivalent @"d"` and mask `NSEventModifierFlagCommand`.
    - Button 1 is `@"Cancel"`, with `@"\r"`.
  - `testBarDisabledWhileBusy`: block a background runner, as `testRemoveRowsRefusedWhileBusy` does.
    - While busy, every bar button except `editModeButton` is disabled.
    - Once idle, add, refresh and pagination are enabled again, and remove is enabled again if a row is selected.
- [ ] **Step 2: Run** `SPPostgresContentBarTests`. Expected: FAIL (`addButton` etc. undeclared).
- [ ] **Step 3: Implement.**
  - **Layout:** move the existing buttons to the frames above and add the four new ones.
  - **Text fields:** `countField` sits at x 193 and the notice field fills up to `width − 140`, both width-sizable.
  - **Busy state:** observe the runner's `busy` with KVO (re-registered in `-setTaskRunner:`, removed in `invalidate` and dealloc). `_updateBottomBar` disables everything but `editModeButton` while busy.
  - **⌫ / ⌦:** `SPPostgresContentGrid -keyDown:` handles keyCode 51 and 117 with no ⌘, ⌥ or ⌃ held, no `currentEditor` and a non-empty selection by calling `[(SPPostgresContentController *)delegate removeRows:self]`. Any other key goes to super.
  - **Delete alert keys:** change them to MySQL's.
- [ ] **Step 4: Run** `SPPostgresContentBarTests` and `SPPostgresContentControllerTests`. Expected: PASS (update only assertions that pinned the old alert keys).
- [ ] **Step 5: Commit**: "Postgres Stage 10: Content bar in MySQL's layout, ⌫ deletes rows, bar disabled while busy".

### Task 2: Duplicate row

**Files:**
- Modify: `Source/Postgres/SPPostgresTableData.h`, `.m` (column query; new insert)
- Modify: `Source/Postgres/SPPostgresContentController.h`, `.m`
- Test: `PostgresTests/SPPostgresTableDataTests.m`, `PostgresTests/SPPostgresContentBarTests.m`

**Interfaces:**
- Consumes: `duplicateButton` (Task 1).
- Produces:
  - `SPPostgresColumn`: `@property (readonly) BOOL isAutoNumbered;`, YES for any identity column (`attidentity <> ''`) and for a default that starts with `nextval(` (serial). Read in the same column query as `generated`.
  - `SPPostgresTableData`: `- (NSArray *)insertCopyOfRow:(NSArray *)row error:(NSError **)error;`. Inserts the row's values (NSString/NSNull, cast as `-insertRowWithValues:` does) for every column that is neither `isGenerated` nor `isAutoNumbered`; those take their defaults. Returns the inserted row via RETURNING, as `-insertRowWithValues:` does.
  - `SPPostgresContentController`: `- (IBAction)duplicateRow:(id)sender;`

- [ ] **Step 1: Write the failing tests.**
  - **Fixture:** a table with a `serial` primary key, an `int GENERATED BY DEFAULT AS IDENTITY` column, a `text` column, a NULL `int` column and a `GENERATED ALWAYS AS (…) STORED` column. Also a table with a `text` primary key.
  - In `SPPostgresTableDataTests`:
    - `testIsAutoNumbered`: YES for the serial and the identity columns, NO for the text, int and generated columns.
    - `testInsertCopyOfRowTakesNewKeyAndSameValues`: the returned row has new serial and identity values. The text value is the same, the NULL stays `NSNull`, and the generated value is recomputed.
  - In `SPPostgresContentBarTests`:
    - `testDuplicateRowAppendsCopyAndSelectsIt`: select row 0 and `duplicateRow:`.
      - The grid has one more row, the last one, which is selected.
      - The count text says one more row in the table.
      - No cell editor is open.
    - `testDuplicateEnabledOnlyForOneSelectedRow`: disabled with 0 or 2 rows selected, enabled with 1. Disabled for a view and for a table without a primary key.
    - `testDuplicateWithSeveralRowsShowsMySQLError`: calling `duplicateRow:` directly with 2 rows selected passes `alertPresenter` an alert with message `@"Error"` and informative text `@"You can only copy single rows."`. Nothing is inserted.
    - `testDuplicateWithPlainKeyShowsServerErrorAndAddsNothing`: on the text-key table, the alert's title is `@"Could not duplicate the row"` and its text contains `duplicate key`. The row count and the count text are unchanged.
    - `testDuplicateRefusedWhileBusy`: with the runner blocked, `duplicateRow:` inserts nothing. Check that the server count is unchanged after idle.
- [ ] **Step 2: Run** both classes. Expected: FAIL (`isAutoNumbered` / `insertCopyOfRow:error:` / `duplicateRow:` undeclared).
- [ ] **Step 3: Implement.**
  - **TableData:** add the column flag and `insertCopyOfRow:error:`. Share the INSERT building with `-insertRowWithValues:`.
  - **Controller:** `duplicateRow:` runs `_endEditing` and the busy refusal, then inserts.
  - **Shared append path:** factor `addRow:`'s "append the inserted row, recount pages, select, scroll" into a helper both actions use. Duplicate starts no edit.
  - **Wiring:** wire `duplicateButton` and enable it in `_updateBottomBar` when the table is editable and loaded, exactly one row is selected, and the runner is not busy.
- [ ] **Step 4: Run** both classes. Expected: PASS.
- [ ] **Step 5: Commit**: "Postgres Stage 10: Duplicate row (⌘D) with new identity/serial values".

### Task 3: Edit mode toggle and the field editor sheet

**Files:**
- Modify: `Source/Postgres/SPPostgresContentController.h`, `.m`
- Test: `PostgresTests/SPPostgresContentBarTests.m`

**Interfaces:**
- Consumes: `editModeButton`, `defaults` (Task 1).
- Produces:
  - `- (IBAction)toggleEditMode:(id)sender;`: writes the button's state to `SPEditInSheetEnabled` in `defaults`.
  - `@property (copy) void (^fieldEditorPresenter)(NSString *value, NSString *columnName, NSString *typeName, BOOL editable, BOOL allowNull, void (^completion)(id newValue));`
    - `completion(nil)` means cancelled; otherwise it gets an NSString or NSNull.
    - nil (the default) shows `SPFieldEditorController` as a sheet on the view's window, with these arguments:
      - `fieldName` = the column name; `usingEncoding:NSUTF8StringEncoding`; `isObjectBlob:NO`; `setTextMaxLength:0`; `setAllowNULL:` = nullable.
      - `setFieldType:` = the column's `typeName`, except `@""` when its uppercase string is `BIT`, `JSON`, `GEOMETRY`, `BINARY`, `VARBINARY` or `FLOAT`. Those trigger MySQL-only handling, such as JSON reformatting, which would rewrite unchanged values.
      - The controller is `SPFieldEditorControllerDelegate`, and `-processFieldEditorResult:contextInfo:` calls the completion.

- [ ] **Step 1: Write the failing tests.** Inject scratch `defaults` and set `EditInSheetEnabled` explicitly.
  - `testEditModeButtonReflectsAndWritesSharedPreference`: the button's state follows the scratch value at build. Clicking it (`performClick:`) writes the opposite BOOL to `EditInSheetEnabled` in the scratch domain only; `standardUserDefaults` is untouched.
  - `testEditModeButtonFollowsPreferenceChangedElsewhere`: `[scratch setBool:YES forKey:@"EditInSheetEnabled"]` turns the button on without any call to the controller.
  - `testSheetModeOpensFieldEditorInsteadOfInlineEdit`: with the preference on, `tableView:shouldEditTableColumn:row:` returns NO and calls the presenter once, with the cell's value, column name, type name, `editable:YES`, and `allowNull` matching the column.
  - `testSheetResultUpdatesServer`: calling the presenter's completion with `@"changed"` updates that row on the server, and the grid shows it after the reload. Calling it with nil sends nothing (use the connection's statement recorder, as the existing tests do).
  - `testSheetNullPlaceholderWritesNull`: completion with the NULL placeholder string on a nullable column stores SQL NULL.
  - `testSheetModeOnReadOnlyRelationOpensReadOnly`: on a view, the presenter gets `editable:NO`, and calling its completion with `@"x"` sends nothing.
  - `testAddRowInSheetModeOpensOneSheet`: with the preference on, `addRow:` inserts the row and calls the presenter exactly once, for the first editable column. No inline editor is open.
  - `testInlineEditUnchangedWhenSheetModeOff`: with the preference off, `shouldEditTableColumn` returns YES and the presenter is not called.
- [ ] **Step 2: Run** `SPPostgresContentBarTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Button state:** observe `defaults` with KVO for the key `EditInSheetEnabled` to keep the button's state in sync. Remove the observer in `invalidate`.
  - **Shared commit path:** move `tableView:setObjectValue:…`'s body (NULL placeholder, unchanged check, busy refusal, update, reload) into `- (void)_commitValue:(id)value forColumn:(SPPostgresColumn *)column row:(NSInteger)row`. The cell edit and the sheet completion both call it. A completion that arrives after `invalidate`, after a table switch, or for a row index that is now out of range sends nothing.
  - **addRow:** check editability with a private method that never opens the sheet. In sheet mode, open the sheet for the first editable column; otherwise start the inline edit as now.
- [ ] **Step 4: Run** `SPPostgresContentBarTests` and `SPPostgresContentControllerTests`. Expected: PASS.
- [ ] **Step 5: Commit**: "Postgres Stage 10: edit mode toggle opens the field editor sheet (shared EditInSheetEnabled)".

### Task 4: Filter bar show/hide

**Files:**
- Modify: `Source/Postgres/SPPostgresContentController.h`, `.m`
- Test: `PostgresTests/SPPostgresContentBarTests.m`

**Interfaces:**
- Consumes: `filterToggleButton`, `defaults` (Task 1).
- Produces:
  - `- (IBAction)toggleFilterBar:(id)sender;`
  - `@property (readonly, getter=isFilterBarVisible) BOOL filterBarVisible;`

- [ ] **Step 1: Write the failing tests.** Use scratch `defaults`.
  - `testFilterBarHiddenByDefault`: with `RuleFilterEditorLastVisibilityChoice` unset, after `showTable:`:
    - the filter bar view is hidden and the button is off;
    - the grid's scroll view top edge is at the view's top (it takes the 30 pt).
  - `testToggleShowsBarAndStoresChoice`: `toggleFilterBar:` shows the bar, turns the button on, moves the scroll view's top down 30 pt, and writes YES to the scratch key. Toggling again hides the bar and writes NO.
  - `testVisibilityReadAtEachTableLoad`: set the key to YES directly, then `showTable:` another table. The bar is visible.
  - `testHidingBarWithFilterAppliedReloadsUnfiltered`: apply a filter matching 1 of N rows, then hide the bar.
    - Once idle, the grid has N rows and the count text is `@"N rows in table"`.
    - The sort column is kept.
  - `testFilterToggleDisabledWithoutTable`: disabled when there is no table and while busy (Task 1's busy rule).
- [ ] **Step 2: Run** `SPPostgresContentBarTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Filter bar:** keep a reference to the filter bar view. Showing or hiding it sets `hidden` and resizes the scroll view's height.
  - **Visibility:** apply it from `defaults` in `showTable:inSchema:`; the toggle flips and stores it. Remove the existing applied-filter tests' dependence on the bar being visible, if any (they call `applyFilter:` directly).
  - **Focus:** showing the bar by a click makes the value field first responder when the view has a window and the field is enabled.
  - **Hiding with a filter:** hiding while `filter` is set runs `_loadWithFilter:nil sortColumn:sortColumn ascending:sortAscending page:1 …` with the existing "Filtering table..." description.
- [ ] **Step 4: Run** `SPPostgresContentBarTests` and `SPPostgresContentControllerTests`. Expected: PASS.
- [ ] **Step 5: Commit**: "Postgres Stage 10: filter bar show/hide toggle (shared RuleFilterEditorLastVisibilityChoice)".

### Task 5: Jump to page popover

**Files:**
- Create: `Source/Postgres/SPPostgresPaginationView.h`, `.m` (`add-app`)
- Modify: `Source/Postgres/SPPostgresContentController.h`, `.m`
- Test: `PostgresTests/SPPostgresContentBarTests.m`

**Interfaces:**
- Consumes: `paginationButton`, `previousPageButton`, `nextPageButton`, `defaults` (Task 1).
- Produces:
  - `SPPostgresPaginationView : NSViewController`, `__attribute__((visibility("default")))`, built in code in `-loadView`.
    - **Frames:** take MySQL's `ContentPaginationView.xib` frames, drop the "Defer loading" row, and move every remaining control down 25 pt. The view is 330 × 64.
    - **Page row:** `@"Jump to page:"` label, `pageField` (NSNumberFormatter, no floats, minimum 1), `pageStepper` (min 1, max `maxPage`), `goButton` (`@"Go"`, small, round rect). The page field's action is Go's `performClick:`.
    - **Settings row:** separator; `limitCheckbox` (`@"Limit result to:"`, small check) bound to `LimitResults`; `limitField` (formatter 0…100000) and `limitStepper` (1…100000) bound to `LimitResultsValue`; a `@"rows"` label.
    - **Defaults:** all bindings use the given defaults through an `NSUserDefaultsController` made with `initWithDefaults:initialValues:`, so tests stay in the scratch domain.
    - **Enabled state:** the page field, stepper, Go, the limit field and the limit stepper are enabled only while `LimitResults` is on, as MySQL's bindings.
    - API:
      - `- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;`
      - `@property (nonatomic) NSUInteger page, maxPage;`
      - `@property (assign) id target; @property SEL action;` (Go sends `action` to `target` with self)
      - `@property (readonly) NSTextField *pageField, *limitField; @property (readonly) NSButton *goButton, *limitCheckbox;`
      - `- (void)makeInputFirstResponder;`
  - `SPPostgresContentController`:
    - `- (IBAction)togglePagination:(id)sender;`: shows or closes an `NSPopover`.
      - The popover is transient, its delegate is the controller, and it is shown relative to `paginationButton`'s bounds at `NSMinYEdge`.
      - While it is shown, `paginationButton` has state on and image `button_action`; otherwise state off and `button_pagination`. `-popoverDidClose:` restores the off state.
      - Showing it sets `page`/`maxPage` from `currentPage`/`pageCount` and calls `makeInputFirstResponder`.
    - `- (void)goToPage:(NSUInteger)page;`: closes the popover and loads that page with the current filter and sort ("Loading page %lu..."). 0 is treated as 1; the load's own clamp handles pages past the end.
    - `@property (readonly) SPPostgresPaginationView *paginationView;`
    - `@property (readonly) NSPopover *paginationPopover;`

- [ ] **Step 1: Write the failing tests.** Use scratch `defaults` with `LimitResults` YES and `LimitResultsValue` 7, and a table of 30 rows.
  - `testPaginationViewLayout`: the view is 330 × 64. It has the label `@"Jump to page:"`, a Go button titled `@"Go"`, a checkbox titled `@"Limit result to:"` and the `@"rows"` label. There is no control titled `@"Defer loading of blobs and texts"`.
  - `testGoLoadsTypedPage`: set `pageField` to `@"3"`, then `[goButton performClick:nil]`. Once idle, `currentPage == 3` and the count text is `@"Rows 15 - 21 of 30 from table"`.
  - `testGoToPageClampsOutOfRangePages`: `goToPage:0` shows page 1, and `goToPage:99` shows page 5. Neither shows an alert.
  - `testLimitControlsWriteSharedKeysInInjectedDefaults`: unchecking `limitCheckbox` writes NO to `LimitResults` in the scratch domain and disables `pageField` and `goButton`. Typing 3 into `limitField` and ending editing writes 3 to `LimitResultsValue`. `standardUserDefaults`' values are unchanged.
  - `testCountTextUsesLoadedPageSize`: on page 1 with 7 rows per page, set `LimitResultsValue` to 3 in the scratch domain without reloading. The count text is still `@"Rows 1 - 7 of 30 from table"`. After `goToPage:1`, it is `@"Rows 1 - 3 of 30 from table"`.
  - `testPaginationButtonStateFollowsPopover`: in a window, `togglePagination:` shows the popover (`isShown`), turns the button on and switches its image to `button_action`. Toggling again closes it and restores the off state and `button_pagination`.
  - `testPaginationButtonEnabledWithLimitOff`: with `LimitResults` NO and a table loaded, previous and next are disabled and the pagination button is enabled.
- [ ] **Step 2: Run** `SPPostgresContentBarTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Page size:** store the page size each load used in `SPPostgresContentPage`, and use it in `_updateBottomBar`'s count text.
  - **Wiring:** wire `paginationButton` and enable it when a table is loaded and the runner is not busy.
  - **Teardown:** close the popover and clear its delegate and the view's target in `invalidate`.
- [ ] **Step 4: Run** `SPPostgresContentBarTests` and `SPPostgresContentControllerTests`. Expected: PASS.
- [ ] **Step 5: Run the full suite and build the app** (commands in Global Constraints). Expected:
  - The suite reports `0 failures`.
  - The app build ends with `** BUILD SUCCEEDED **`.
  - MySQL's tests and `SPToolbarParityTests` still pass.
- [ ] **Step 6: Commit**: "Postgres Stage 10: Jump to page popover (⌘J) with MySQL's rows-per-page settings".
