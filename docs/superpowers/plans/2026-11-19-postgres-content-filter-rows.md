# PostgreSQL Content Filter Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PostgreSQL tab's Content filter becomes MySQL-style rows (`NSRuleEditor`, list mode) with − / + per row and a Reset / Add Filter / Filter bar; every complete row is AND-ed.

**Architecture:** The data layer gains array-of-conditions forms (single-condition forms delegate to them). A new `SPPostgresFilterRowsController` owns the rule editor, its button bar and the rows ↔ `SPPostgresFilter` mapping, with no database or table knowledge. `SPPostgresContentController` replaces its one-row bar with that controller's view, keeps an *applied* conditions array for loads/paging/sort/count, and lays the area out (height = rows + 31, capped at one third).

**Tech Stack:** Objective-C, manual retain/release in app code (`Source/`), ARC in tests (`PostgresTests/`), AppKit `NSRuleEditor`, PostgresKit. Tests against PG12 on 127.0.0.1:55412 and PG18 on 55418.

**Spec:** `docs/superpowers/specs/2026-11-19-postgres-content-filter-rows-design.md`

## Global Constraints

- Values are always parameters (`$n::<type>`); only the fixed operators are placed in SQL. Per-operator SQL, casts and error messages unchanged.
- Comparisons, in this order: `=`, `≠`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `ILIKE`, `IS NULL`, `IS NOT NULL`, `IN`.
- A row whose comparison takes a value and whose value is empty is skipped; no complete row = unfiltered.
- AND only; rule editor `NSRuleEditorNestingModeList`; no groups, no enable checkboxes.
- Rows: height 29; area = rows' height + 31 (23 pt `SPButtonBar` + 8 pt gap), capped at one third of the Content view's height above its bottom bar; never a negative frame height; rows always above the bar.
- Bar like DBView.xib: Reset (image `button_clear`, image only, tooltip "Delete any defined filter conditions and reload the table (⌘⎋)", key equivalent ⌘⎋) at left; "Add Filter" (tooltip "Adds a new filter condition which can be used to limit the results displayed below") and "Filter" (tooltip "Query the current table using the filter conditions defined above") at right, small, round rect.
- Visibility preference `SPRuleFilterEditorLastVisibilityChoice` in the controller's `defaults`, written only by the toggle; tests use scratch defaults.
- App classes used by tests carry `__attribute__((visibility("default")))`. New files registered with `ruby Scripts/pg-xcodeproj.rb add-app|add-test`.
- Test command: `xcodebuild -project sequel-plus.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData test -only-testing:"Postgres Tests/<Class>"`.
- Commit only with explicit path lists, message prefix "Sequel Plus 2.0.5: ", no Co-Authored-By trailer. Never commit `Interfaces/English.lproj/IndexesView.xib`, `.idea/`, `FilterTableWindow.strings`, `HelpViewer.strings`, `start_clause.sh`.
- MySQL's filter (`SPRuleFilterController`, `SPTableContent`, DBView.xib) is not changed.

## Review Focus

1. Paging, sort and refresh after editing rows without pressing Filter must use the applied conditions, not the typed rows (Task 3 test `testPagingUsesAppliedNotTypedRows`).
2. Parameter numbering across rows with `IN` lists of several items before another condition (`$1,$2` then `$3`) (Task 1 test `testInBeforeEqualsNumbersParametersInOrder`).
3. Switching to another table while rows are typed: rows empty, menus rebuilt, no stale column in a row (Task 3 test `testSwitchingTablesEmptiesTheRows`).
4. A column name with spaces/quotes/unicode in a row survives the round trip rows → filters → SQL (Task 2 test `testColumnNamesRoundTripVerbatim`, Task 1 uses quoted identifiers already covered).
5. Hiding the area while a value field is being edited moves focus to the grid, and ⌘⎋ in a hidden area does nothing (Task 3 tests `testHidingWhileEditingFocusesTheGrid`, `testResetKeyOnlyWhenVisible`).

---

### Task 1: Several conditions in the data layer

**Files:**
- Modify: `Source/Postgres/SPPostgresTableData.h` (~150-165), `Source/Postgres/SPPostgresTableData.m` (`whereClauseForFilter:values:error:` ~418, `rowsWithFilter:` ~536, `countRowsWithFilter:` ~576)
- Test: `PostgresTests/SPPostgresTableDataTests.m`

**Interfaces:**
- Produces:
  - `- (NSArray *)rowsWithFilters:(NSArray<SPPostgresFilter *> *)filters sortColumn:(NSString *)column ascending:(BOOL)ascending offset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError **)error;` (nil or empty = all rows)
  - `- (NSInteger)countRowsWithFilters:(NSArray<SPPostgresFilter *> *)filters error:(NSError **)error;`
  - Existing `rowsWithFilter:…` / `countRowsWithFilter:` call these with `filter ? @[filter] : @[]`.

- [ ] **Step 1: Write the failing tests** (in the existing class, using its table fixtures; add a fixture table if none has two filterable columns plus NULLs):
  - `testTwoConditionsAreAnded`: `=` on one column and `>` on another → only rows matching both; `countRowsWithFilters:` equals the row count.
  - `testInBeforeEqualsNumbersParametersInOrder`: `IN "a, b"` then `= x` → rows matching both (proves `$1,$2` then `$3`).
  - `testIsNullWithAnotherCondition`: `IS NULL` + `=` → matching rows.
  - `testEmptyOrNilFiltersReturnAllRows`: `@[]` and nil → same as `rowsWithFilter:nil`.
  - `testInvalidConditionFailsTheWholeLoad`: second condition on a missing column → nil, error domain `SPPostgresErrorDomain`, code `SPPostgresErrorQueryFailed` or the existing unknown-column code (whatever `columnNamed:error:` gives today).
- [ ] **Step 2: Run** `… -only-testing:"Postgres Tests/SPPostgresTableDataTests"`. Expected: build fails (unknown selectors).
- [ ] **Step 3: Implement.** Split today's clause into `- (NSString *)_predicateForFilter:(SPPostgresFilter *)filter values:(NSMutableArray *)values error:(NSError **)error` (no " WHERE "), and `whereClauseForFilters:values:error:` returning `@""` for none or `@" WHERE " + predicates joined by @" AND "`. Keep `whereClauseForFilter:` as a wrapper if anything else calls it.
- [ ] **Step 4: Run** the class. Expected: all pass, including the existing 45 filter call sites.
- [ ] **Step 5: Commit** the two source files and the test file.

### Task 2: `SPPostgresFilterRowsController` (rows + button bar, no database)

**Files:**
- Create: `Source/Postgres/SPPostgresFilterRowsController.h`, `.m` (`add-app`)
- Create: `PostgresTests/SPPostgresFilterRowsControllerTests.m` (`add-test`)

**Interfaces:**
- Consumes: `SPPostgresFilter` (`+filterWithColumn:comparison:value:`).
- Produces (`__attribute__((visibility("default")))`, NSObject subclass):
  - `@property (readonly) NSView *view;` — the area: rules scroll view at y = 31 above an `SPButtonBar` at y = 0, height 23, both width-sizable.
  - `@property (readonly) NSRuleEditor *ruleEditor;` `@property (readonly) NSButton *resetButton, *addFilterButton, *filterButton;`
  - `@property (copy) NSArray<NSString *> *columnNames;` — setting it removes all rows; with none, every control is disabled.
  - `- (NSUInteger)numberOfRows;`
  - `- (void)addRowAfter:(NSInteger)row column:(NSString *)column comparison:(NSString *)comparison value:(NSString *)value;` (−1 = append; nil column = first column; nil comparison = `=`)
  - `- (void)removeAllRows;`
  - `- (void)setFilters:(NSArray<SPPostgresFilter *> *)filters;` — replaces the rows (filters on unknown columns skipped).
  - `- (NSArray<SPPostgresFilter *> *)typedFilters;` — every row as typed, in order.
  - `- (NSArray<SPPostgresFilter *> *)completeFilters;` — rows whose comparison takes no value or whose value is non-empty.
  - `- (NSTextField *)valueFieldInRow:(NSUInteger)row;` `- (void)focusValueInRow:(NSUInteger)row;`
  - `@property (readonly) CGFloat preferredHeight;` — rows × 29 + 31.
  - Callbacks (copy blocks, may be nil): `onApply` (Filter button, Return in a value field), `onReset` (Reset), `onLastRowRemoved` (− removed the only row), `onHeightChanged`.

- [ ] **Step 1: Write the failing tests** (no window needed except focus tests, which put `view` in a borderless window):
  - `testListModeWithPostgresComparisons`: nesting mode list; a row's comparison choices equal the Global Constraints list in order.
  - `testAddRowsAndReadThemBack`: `columnNames = @[@"id", @"name", @"note"]`; add `id = 42`, `name IN "a, b"`, `note IS NULL` → `typedFilters` equals those three in order (column, comparison, value; IS NULL value `@""`).
  - `testCompleteFiltersSkipEmptyValues`: rows `id = ""`, `note IS NULL`, `name LIKE "x%"` → `completeFilters` is the last two.
  - `testPlusInsertsBelowWithSameColumn`: `addRowAfter:0 …nil column` after row 0 on `name` → row 1 column `name`, comparison `=`, value empty.
  - `testSetFiltersReplacesRowsAndSkipsUnknownColumns`.
  - `testSettingColumnNamesEmptiesRows` and with `@[]` all buttons and the editor disabled.
  - `testColumnNamesRoundTripVerbatim`: column `"we ird \"col\" ü"` survives add → `typedFilters`.
  - `testComparisonWithoutValueDisablesTheField`: switching a row to `IS NOT NULL` disables and empties its value field.
  - `testButtonsAndTooltipsMatchMySQL`: titles, tooltips, Reset image name `button_clear`, key equivalent `\e` with ⌘; Reset at x = 0, Filter rightmost, Add Filter left of it.
  - `testPreferredHeight`: 0 rows → 31; 2 rows → 89; `onHeightChanged` called after adding a row (spin 0.3 s if the editor resizes late).
  - `testCallbacks`: Filter button and Return (`[valueField performClick:]`/send action) call `onApply`; Reset calls `onReset`; removing the only row through `[ruleEditor removeRowAtIndex:0]` calls `onLastRowRemoved`.
- [ ] **Step 2: Run** the class. Expected: build fails (no such class).
- [ ] **Step 3: Implement.** Delegate model (reference: `SPRuleFilterController` `ruleEditor:numberOfChildrenForCriterion:…` ~405-560): criterion level 0 = column name strings, level 1 = comparison strings, level 2 = one value item displayed as a per-row `NSTextField` (small, `setScrollable:YES`, placeholder "Value", target/action → `onApply`). Read rows back with `criteriaForRow:` / `displayValuesForRow:`. Use `NSRuleEditorRowTypeSimple` rows only. Reset button image `[NSImage imageNamed:@"button_clear"]`.
- [ ] **Step 4: Run** the class. Expected: all pass.
- [ ] **Step 5: Commit** the four new files and `sequel-plus.xcodeproj/project.pbxproj`.

### Task 3: The Content view uses the rows

**Files:**
- Modify: `Source/Postgres/SPPostgresContentController.{h,m}` (bar build ~427-468, `_rebuildFilterBar` ~962, `_setFilterBarVisible:` ~989, `toggleFilterBar:` ~1009, `_showFilterInBar:` ~1029, `applyFilter:` ~1043, loads ~672-850, paging ~1233, FK link ~2010, sort ~2038)
- Modify tests: `PostgresTests/SPPostgresContentBarTests.m` (~859-1000), `SPPostgresContentControllerTests.m` (~338, ~950), `SPPostgresForeignKeyLinkTests.m` (~203, ~289), `SPPostgresTextViewTests.m` (4 references) — keep what they assert, reach the rows through `filterRows`.

**Interfaces:**
- Consumes: Task 1's array methods; Task 2's controller.
- Produces on `SPPostgresContentController`:
  - `@property (readonly) SPPostgresFilterRowsController *filterRows;`
  - `@property (readonly, copy) NSArray<SPPostgresFilter *> *appliedFilters;` (empty when none; replaces the private `filter` ivar)
  - `showTable:inSchema:filter:` unchanged in signature; `applyFilter:`, `toggleFilterBar:`, `filterBarVisible` unchanged in meaning.
  - Removed ivars: `filterColumnPopup`, `filterComparisonPopup`, `filterValueField`, `filterButton` (the controller's `filterButton` replaces the last).

- [ ] **Step 1: Write the failing tests** (in `SPPostgresContentBarTests`, scratch defaults, real `content_test` fixtures already there; add a table with two text columns if needed):
  - `testTwoRowsFilterWithAnd`: add two rows, `applyFilter:` → grid shows only rows matching both; count text says filtered.
  - `testPagingUsesAppliedNotTypedRows`: apply one row; edit its value without applying; next page / sort / refresh → still the applied filter's rows; `appliedFilters` unchanged.
  - `testRemovingTheLastRowReloadsUnfiltered`; `testResetEmptiesRowsAddsOneAndReloadsUnfiltered` (rows = 1, empty; applied empty).
  - `testHidingKeepsRowsUnapplied`: apply, hide → unfiltered load, rows still there; show → rows shown, no query (statement recorder sees none), applied empty.
  - `testShowingByClickWithNoRowsAddsOneFocusedRow`.
  - `testAreaHeightFollowsRows`: 1 row → area 60, grid top = view height − 60; 3 rows → 118; many rows in a 300 pt view → capped at a third of (300 − bottom bar), rules scroll; rows' `minY` ≥ bar's `maxY` in every case, including after hide/show.
  - `testSwitchingTablesEmptiesTheRows`.
  - `testStartFilterReplacesRowsAndShowsArea`: typed rows, then `showTable:…filter:` on the same table → exactly that one row, applied, area shown, preference unchanged.
  - `testHidingWhileEditingFocusesTheGrid`; `testResetKeyOnlyWhenVisible`: hidden area → ⌘⎋ via `performKeyEquivalent:` on the window returns NO and rows unchanged.
  - Update existing tests: bar height asserts (30 → the new heights), `filterBarOf:` → `content.filterRows.view`, popups/field → `addRowAfter:` / `valueFieldInRow:`.
- [ ] **Step 2: Run** `SPPostgresContentBarTests`, `SPPostgresContentControllerTests`, `SPPostgresForeignKeyLinkTests`, `SPPostgresTextViewTests`. Expected: build fails or new tests fail.
- [ ] **Step 3: Implement.** Replace the bar with `filterRows.view` at the top; `_layOutFilterArea` sets area height = visible ? MIN(preferredHeight, (viewHeight − bottomBarHeight)/3) : 0, rules scroll frame `{0, 31, w, MAX(0, areaHeight − 31)}`, grid fills the rest; call it from `onHeightChanged`, visibility changes and view resizes. `_loadWithFilters:` replaces `_loadWithFilter:` (array; the page result keeps the array). Wire `onApply` → `applyFilter:` (reads `completeFilters`), `onReset` → remove all, add one empty row, reload unfiltered if applied non-empty, `onLastRowRemoved` → reload unfiltered if applied non-empty. Start filter: `setFilters:@[f]`, show area without writing the preference. Table switch: `columnNames = …` (empties rows).
- [ ] **Step 4: Run** the four classes. Expected: all pass.
- [ ] **Step 5: Commit** the controller, its header and the four test files.

### Task 4: Strings, CHANGELOG, full suite

**Files:**
- Modify: `Resources/English.lproj/Localizable.strings` (UTF-16; add only keys not already present: check each new `NSLocalizedString` key with `grep`/`iconv`), `CHANGELOG.md` (2.0.5 section, a "PostgreSQL: filter on several columns" entry)

- [ ] **Step 1:** List new keys: `grep -ho 'NSLocalizedString(@"[^"]*"' Source/Postgres/SPPostgresFilterRowsController.m Source/Postgres/SPPostgresContentController.m`; add missing ones to Localizable.strings preserving UTF-16.
- [ ] **Step 2:** CHANGELOG entry: rows with − and +, Add Filter / Reset (⌘⎋) / Filter, all rows must match, hiding keeps rows, FK arrow opens one row.
- [ ] **Step 3:** Full suite with a before/after export of `com.sequelplus.SequelPlus` prefs. Expected: only the known order-dependent `SPPostgresTextViewTests testIndentNewLines` may fail (passes alone); prefs diff empty.
- [ ] **Step 4: Commit** Localizable.strings and CHANGELOG.md.
