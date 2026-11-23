# Foreign Key Value Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Editing a single-column foreign-key cell in the MySQL or PostgreSQL Content view opens a pop-up listing the referenced table's rows (search box + optional conditions, ⚙︎ column choice remembered per table); choosing a row puts its key into the cell's in-place editor.

**Architecture:** One shared popover (`SPForeignKeyPicker`) talks to an `SPForeignKeyPickerDataSource` protocol; `SPPostgresForeignKeyPickerSource` and `SPMySQLForeignKeyPickerSource` build and run the SELECT on each view's existing connection. `SPForeignKeyPickerSettings` stores shown columns in injected defaults. Each Content view opens the picker from `shouldEditTableColumn:` through the date picker's existing handoff.

**Tech Stack:** Objective-C (manual retain/release), AppKit (NSPopover, NSTableView), PostgresKit (PGPostgresConnection), SPMySQL, XCTest (scheme "Postgres Tests").

**Spec:** `docs/superpowers/specs/2026-11-17-foreign-key-value-picker-design.md`

## Global Constraints

- Branch `2.0.5`. Objective-C with manual retain/release, like the surrounding code. Deployment target macOS 12, arm64.
- Add new files to the Xcode project only with `ruby Scripts/pg-xcodeproj.rb add-app <files>` (app target) / `add-test <files>` (test target). Never hand-edit `project.pbxproj` for this.
- Run tests: `xcodebuild -project sequel-plus.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData test -only-testing:"Postgres Tests/<TestClass>"`.
- Test servers: PostgreSQL `sp-pg12` (127.0.0.1:55412) and `sp-pg18` (127.0.0.1:55418) as in existing `PostgresTests/SPPostgres*Tests.m`; MySQL `sp-mysql8` (127.0.0.1:55438, root / sptest) as in `PostgresTests/SPMySQLTransferTests.m`, with `XCTSkip` when it isn't running. Never use `encompass_2-mysql-1`.
- Each test creates its own database / schema / tables and drops them one by one afterwards (no CASCADE).
- Tests never write the real preferences, the login keychain or the general pasteboard: use a throwaway `NSUserDefaults` suite, removed in tearDown.
- Never break MySQL: a cell that isn't a single-column, non-binary foreign key edits exactly as before; with the preference off every cell edits exactly as before.
- The picker only ever runs SELECT on the referenced table. Identifiers quoted for their engine (PostgreSQL `quote_ident`-style double quotes, MySQL backticks); values as parameters (PostgreSQL `$n`) or escaped literals (MySQL `escapeAndQuoteString:`).
- Page size 200. Search debounce 250 ms. Search is case-insensitive "contains" over shown columns: PostgreSQL `col::text ILIKE $n ESCAPE '\'`, MySQL `CAST(col AS CHAR) LIKE '…' ESCAPE '\\'`, with `\`, `%`, `_` in typed text escaped.
- Preference keys: `SPForeignKeyPickerEnabled = @"ForeignKeyPickerEnabled"` (default YES in `Resources/Plists/PreferenceDefaults.plist`), `SPForeignKeyPickerShownColumns = @"ForeignKeyPickerShownColumns"` (dictionary, no default).
- User-visible strings via `NSLocalizedString`. Copy: "Search %@" placeholder (shown column names joined by ", "), "+ Condition", "Show columns", "Show All Columns", "Reset to Default", "NULL", "Type a value…", "Cancel", "Choose", "Choose…", "Open the value picker when editing a foreign key", "%lu matches", "%lu shown, more…".
- Commits: explicit path lists, `git add --` for new files first; no Co-Authored-By trailer; never commit `.idea/`, `Resources/English.lproj/FilterTableWindow.strings`, `HelpViewer.strings`, `start_clause.sh`.

## Review Focus

- Fast typing: a slow fetch for "sm" finishing after the fetch for "smi" must not replace the "smi" list (Task 4 test `testStaleFetchResultIsIgnored`).
- Typed text containing `%`, `_`, `\` or `'` is matched literally, never as a wildcard or broken SQL (Tasks 2 and 3 tests `testSearchEscapesWildcardsAndQuotes`).
- Referenced table and column names that need quoting (mixed case, spaces, in another schema) work (Tasks 2 and 3 fixtures use `"Sales Data"."Customer List"` / `` `customer list` ``).
- A self-referencing key (employees.manager_id → employees.id) opens the picker on the same table and the chosen value lands in the edited row (Tasks 5 and 6 tests `testSelfReferencingKey`).
- The table reloads or switches while the picker is open: the choice is dropped and nothing is written (Tasks 5 and 6 tests `testChoiceAfterTableSwitchIsDropped`).

---

### Task 1: Settings store and preference keys

**Files:**
- Create: `Source/SPForeignKeyPickerSettings.h`, `Source/SPForeignKeyPickerSettings.m`
- Modify: `Source/SPConstants.h`, `Source/SPConstants.m` (two keys), `Resources/Plists/PreferenceDefaults.plist` (`ForeignKeyPickerEnabled` = true)
- Test: `PostgresTests/SPForeignKeyPickerSettingsTests.m`

**Interfaces:**
- Produces:
  - `extern NSString *SPForeignKeyPickerEnabled; extern NSString *SPForeignKeyPickerShownColumns;`
  - `@interface SPForeignKeyPickerSettings : NSObject`
  - `- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;`
  - `+ (NSString *)tableKeyWithKind:(NSString *)kind host:(NSString *)host port:(NSInteger)port database:(NSString *)database schema:(NSString *)schema table:(NSString *)table;` — kind `@"mysql"` / `@"postgres"`; schema nil for MySQL; components joined so that no two different inputs give the same key (e.g. a JSON array string).
  - `- (NSArray<NSString *> *)shownColumnsForTableKey:(NSString *)key available:(NSArray<NSString *> *)available keyColumn:(NSString *)keyColumn;` — returns the key column first, then the remembered columns that are still in `available`, in `available` order; with nothing remembered, all of `available` (key first).
  - `- (void)setShownColumns:(NSArray<NSString *> *)columns forTableKey:(NSString *)key;` — nil removes the entry (Reset to Default).
  - `- (BOOL)pickerEnabled;`

- [ ] **Step 1: Write the failing tests** (`SPForeignKeyPickerSettingsTests`, throwaway suite `[[NSUserDefaults alloc] initWithSuiteName:@"SPForeignKeyPickerSettingsTests"]`, `removePersistentDomainForName:` in tearDown)
  - `testDefaultIsAllColumnsKeyFirst`: available `@[@"name", @"id", @"email"]`, key `@"id"` → `@[@"id", @"name", @"email"]`.
  - `testRememberedColumnsInTableOrder`: set `@[@"email", @"name"]` → `@[@"id", @"name", @"email"]` given available `@[@"id", @"name", @"email", @"city"]`.
  - `testDroppedColumnIsSkipped`: set `@[@"name", @"phone"]`, available without `phone` → `@[@"id", @"name"]`.
  - `testResetRemovesEntry`: set then set nil → default.
  - `testKeysDifferPerKindServerDatabaseSchemaTable`: changing any one component gives a different key; `@"a.b"`/`@"c"` vs `@"a"`/`@"b.c"` differ.
  - `testPickerEnabledDefaultsToYesAndFollowsDefaults`: registered default from the plist → YES; set NO → NO.
- [ ] **Step 2: Run, expect failure** (class missing).
- [ ] **Step 3: Implement** the keys, plist default and `SPForeignKeyPickerSettings`; add files with `pg-xcodeproj.rb add-app` / `add-test`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: foreign key picker settings store and preference keys`.

### Task 2: Shared model and the PostgreSQL data source

**Files:**
- Create: `Source/SPForeignKeyPickerDataSource.h` (protocol + model classes), `Source/SPForeignKeyPickerDataSource.m`, `Source/Postgres/SPPostgresForeignKeyPickerSource.h`, `.m`
- Test: `PostgresTests/SPPostgresForeignKeyPickerSourceTests.m`

**Interfaces:**
- Produces (in `SPForeignKeyPickerDataSource.h`):
  - `typedef NS_ENUM(NSInteger, SPForeignKeyColumnKind) { SPForeignKeyColumnText, SPForeignKeyColumnNumber, SPForeignKeyColumnDateTime, SPForeignKeyColumnOther };`
  - `@interface SPForeignKeyPickerColumn : NSObject` — `name` (NSString), `kind`; `+ columnWithName:kind:`.
  - Operator constants (`NSString *const`): `SPForeignKeyOpContains`, `SPForeignKeyOpStartsWith`, `SPForeignKeyOpEquals`, `SPForeignKeyOpNotEquals`, `SPForeignKeyOpLess`, `SPForeignKeyOpLessOrEqual`, `SPForeignKeyOpGreater`, `SPForeignKeyOpGreaterOrEqual`, `SPForeignKeyOpBetween`, `SPForeignKeyOpIsNull`, `SPForeignKeyOpIsNotNull`; `+ (NSArray<NSString *> *)operatorsForKind:(SPForeignKeyColumnKind)kind` per the spec (text: contains, starts with, =, ≠; number/date-time: =, ≠, <, ≤, >, ≥, between; every kind adds is NULL, is not NULL; other: =, ≠ + NULL ops).
  - `@interface SPForeignKeyCondition : NSObject` — `column`, `op`, `value`, `secondValue` (between); `+ conditionWithColumn:op:value:secondValue:`.
  - `@protocol SPForeignKeyPickerDataSource <NSObject>`
    - `- (void)loadColumnsWithCompletion:(void (^)(NSArray<SPForeignKeyPickerColumn *> *columns, NSString *errorMessage))completion;`
    - `- (void)fetchRowsWithSearch:(NSString *)search inColumns:(NSArray<NSString *> *)searchColumns conditions:(NSArray<SPForeignKeyCondition *> *)conditions columns:(NSArray<NSString *> *)columns offset:(NSUInteger)offset limit:(NSUInteger)limit completion:(void (^)(NSArray<NSArray *> *rows, NSString *errorMessage))completion;` — rows are arrays of NSString / NSNull in `columns` order; ordered by the key column, then the table's primary key columns; completions on the main queue.
    - `@property (readonly) NSString *keyColumn;`
- Produces (PostgreSQL): `- (instancetype)initWithTaskRunner:(SPPostgresTaskRunner *)runner schema:(NSString *)schema table:(NSString *)table keyColumn:(NSString *)keyColumn;` — work runs through `runTaskWithDescription:…` on the runner (the inline runner in tests). Kinds from `pg_type.typcategory` (S → text, N → number, D → date-time, else other); values read as text.

- [ ] **Step 1: Write the failing tests** on both PG ports (fixture: schema `"Sales Data"`, table `"Customer List"(id int PRIMARY KEY, name text, email text, city text, created_at date)` with rows 1 Anna Smith / 2 Joe Smithers / 3 Mary Lee (email mary.smi@x) / 4 `100% Pure_Co` / 5 `O'Neil`; plus 250 rows `bulk N` for paging; inline runner):
  - `testColumnsAndKinds`: names in table order; `id` number, `name` text, `created_at` date-time.
  - `testSearchMatchesShownColumnsCaseInsensitive`: search `smi` over name,email → ids 1, 2, 3 in that order.
  - `testSearchEscapesWildcardsAndQuotes`: `%` → only 4; `_` → only 4; `'` → only 5.
  - `testConditionsAreAnded`: name contains `smi` AND city = `Leeds` (set Anna's city to Leeds) → id 1; `between` on created_at; `is NULL`.
  - `testPagingOrderedByKey`: offset 0 limit 200 then offset 200 → 255 distinct ids, ascending, no overlap.
  - `testServerErrorIsReported`: condition id = `abc` → rows nil, errorMessage non-empty.
  - `testOnlySelects`: statements seen by the connection delegate all start with `SELECT` (or are catalog reads).
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** the model and PostgreSQL source; register files.
- [ ] **Step 4: Run, expect PASS on 55412 and 55418.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: foreign key picker data source protocol and its PostgreSQL source`.

### Task 3: MySQL data source

**Files:**
- Create: `Source/SPMySQLForeignKeyPickerSource.h`, `.m`
- Test: `PostgresTests/SPMySQLForeignKeyPickerSourceTests.m`

**Interfaces:**
- Consumes: Task 2's protocol and model.
- Produces: `- (instancetype)initWithConnection:(SPMySQLConnection *)connection database:(NSString *)database table:(NSString *)table keyColumn:(NSString *)keyColumn;` — queries on a private serial background queue (SPMySQL serialises access); completions on main. Kinds from `SHOW COLUMNS` / information_schema type (char/text/enum/set → text; int/decimal/float/double/bit → number; date/time/datetime/timestamp/year → date-time; else other). Primary key columns from `SHOW KEYS … WHERE Key_name = 'PRIMARY'`.

- [ ] **Step 1: Write the failing tests** — same seven cases as Task 2, on `sp-mysql8` in a throwaway database `sp_fkpicker_test` with table `` `customer list` ``; `XCTSkip` when the server isn't reachable. Case-insensitivity follows the column's collation (the fixture uses the server default, utf8mb4_0900_ai_ci).
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement**; register files.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: foreign key picker MySQL source`.

### Task 4: The picker popover

**Files:**
- Create: `Source/SPForeignKeyPicker.h`, `Source/SPForeignKeyPicker.m` (popover and its view built in code; no xib)
- Test: `PostgresTests/SPForeignKeyPickerTests.m` (fake data source in the test file: records calls, answers after an optional delay)

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces:
  - `typedef NS_ENUM(NSInteger, SPForeignKeyPickerOutcome) { SPForeignKeyPickerChose, SPForeignKeyPickerChoseNull, SPForeignKeyPickerTypeValue, SPForeignKeyPickerCancelled };`
  - `- (instancetype)initWithDataSource:(id<SPForeignKeyPickerDataSource>)source settings:(SPForeignKeyPickerSettings *)settings tableKey:(NSString *)tableKey title:(NSString *)title currentValue:(id)value allowNull:(BOOL)allowNull completion:(void (^)(SPForeignKeyPickerOutcome outcome, NSString *value))completion;` — `title` e.g. "customers.id · public.customers"; completion called exactly once, on main.
  - `- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view;` (NSPopover, transient; closing it = Cancelled).
  - Test hooks (in the header, documented as for tests): `searchField`, `resultsTable`, `conditionsView`, `- (void)addCondition`, `- (NSMenu *)columnsMenu`, `- (void)loadMore`, `- (void)choose`, `- (void)chooseNull`, `- (void)typeValue`, `- (void)cancel`, `@property NSTimeInterval searchDelay` (tests set 0).

- [ ] **Step 1: Write the failing tests:**
  - `testOpensWithAllShownColumnsKeyFirstAndBold` and `testPlaceholderNamesSearchedColumns` ("Search name, email" after unticking city).
  - `testSearchFetchesAfterDebounceOverShownColumns`.
  - `testStaleFetchResultIsIgnored`: fetch A delayed 0.3 s, fetch B immediate; after both, rows are B's.
  - `testConditionRowOperatorsFollowKind` and `testConditionsSentAnded`.
  - `testColumnsMenuKeyColumnDisabledAndTicked`, `testUntickSavesAndRefetches` (settings for tableKey updated), `testShowAllAndResetToDefault`.
  - `testNullOnlyWhenAllowed`.
  - `testChooseReturnsKeyText`, `testDoubleClickAndReturnChoose`, `testArrowKeysMoveSelectionFromSearchField`, `testEscapeCancels`, `testNullRowKeyCannotBeChosen`, `testTypeValueAndCancelOutcomes`, `testCompletionCalledOnce`.
  - `testCurrentValueRowIsTinted` (row index reported by a test hook `currentValueRow`).
  - `testLoadMoreAppendsNextPageAndFooterCounts` ("200 shown, more…" then "255 matches" style).
  - `testErrorMessageReplacesList`.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** the popover per the spec and the mockups in `.superpowers/brainstorm/68875-1794891541/content/fk-picker-b-multi.html` (A + B) and `fk-picker-v2.html` (⚙︎ menu). Layout values are the implementer's.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: foreign key picker popover (search, conditions, column menu)`.

### Task 5: PostgreSQL Content view hook

**Files:**
- Modify: `Source/Postgres/SPPostgresTableData.{h,m}` (`-foreignKeyReferences:` adds `@"columns"` (NSNumber, the key's column count) and `@"binary"` (NSNumber BOOL, the referencing column's type is bytea) to each entry)
- Modify: `Source/Postgres/SPPostgresContentController.{h,m}` (open the picker in `shouldEditTableColumn:` before the date picker check; Choose… in the sheet)
- Modify: `Source/Postgres/SPPostgresFieldEditorSheet.{h,m}` (optional Choose… button: `+editValue:…choose:(void (^)(void (^setText)(NSString *)))chooser` or equivalent; absent when nil)
- Test: `PostgresTests/SPPostgresForeignKeyPickerHookTests.m`

**Interfaces:**
- Consumes: Tasks 1, 2, 4.
- Produces: `@property (copy) SPForeignKeyPicker *(^foreignKeyPickerPresenter)(SPForeignKeyPicker *picker, NSRect cellRect);` on the controller for tests (default shows it). Settings come from `[[SPForeignKeyPickerSettings alloc] initWithDefaults:self.defaults]`; tableKey from the tab connection's host, port and database plus the reference's schema and table.

- [ ] **Step 1: Write the failing tests** (PG18, tables `customers(id int PK, name text)`, `orders(id int PK, customer_id int REFERENCES customers, note text)`, `pairs(a int, b int, FOREIGN KEY (a,b) REFERENCES …)`, `blobs(k bytea PK)`/`blobrefs(k bytea REFERENCES blobs)`, `employees(id int PK, manager_id int REFERENCES employees)`; throwaway defaults):
  - `testEditingForeignKeyCellOpensPicker` and `testNonForeignKeyCellEditsInPlace`.
  - `testMultiColumnAndBinaryKeysEditInPlace`.
  - `testPreferenceOffEditsInPlace` (and the sheet has no Choose…).
  - `testChoosePutsKeyInEditorAndReturnSaves` (row's customer_id updated on the server).
  - `testNullPutsPlaceholderInEditor`, `testTypeValueOpensEditorOnCurrentValue`, `testCancelLeavesCellNotEditing`.
  - `testSelfReferencingKey`.
  - `testChoiceAfterTableSwitchIsDropped`.
  - `testSheetChooseReplacesSheetText` (with edit-in-sheet on).
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the new class plus `SPPostgresContentControllerTests`, `SPPostgresContentBarTests`, `SPPostgresForeignKeyLinkTests`; expect PASS.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: PostgreSQL Content view opens the foreign key picker`.

### Task 6: MySQL Content view hook

**Files:**
- Modify: `Source/SPTableContent.m` (the `foreignkeyreference` dictionary also records `columns` count from the constraint's `columns` array and whether the column's type is binary/varbinary/blob; open the picker in `tableView:shouldEditTableColumn:row:` right before the date picker check, through the same `datePickerHandoff` + `continueEditingColumn:row:ofTableView:withText:` path and the same "unchanged" checks)
- Modify: `Source/SPFieldEditorController.{h,m}` and its xib only if needed for the Choose… button (hidden unless a chooser is given)
- Test: `PostgresTests/SPMySQLForeignKeyPickerHookTests.m` (pattern: `PostgresTests/SPMySQLDateTimePickerTests.m` and `SPMySQLFieldEditorSheetTests.m`)

**Interfaces:**
- Consumes: Tasks 1, 3, 4. Settings from `[NSUserDefaults standardUserDefaults]` in the app (the view's `prefs`), a throwaway suite in tests; tableKey from the connection's host, port and the current database.

- [ ] **Step 1: Write the failing tests** on `sp-mysql8` (database `sp_fkpicker_hook`, InnoDB tables mirroring Task 5's, binary key as `VARBINARY(16)`), `XCTSkip` without the server: the same ten cases as Task 5, plus `testEnumAndSetCellsStillUseComboBox`.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the new class plus `SPMySQLDateTimePickerTests`, `SPMySQLFieldEditorSheetTests`; expect PASS.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: MySQL Content view opens the foreign key picker`.

### Task 7: Preferences checkbox, CHANGELOG, strings

**Files:**
- Modify: `Interfaces/English.lproj/Preferences.xib` (Tables pane: checkbox "Open the value picker when editing a foreign key", bound to `values.ForeignKeyPickerEnabled` on the shared defaults controller (`destination="117"`, as "Display vertical grid lines"), placed under it; grow the pane as needed)
- Modify: `CHANGELOG.md` (2.0.5 section: "### Foreign key value picker" in the CHANGELOG's style, covering both databases, the ⚙︎ memory, the checkbox, and what keeps the normal editor)
- Modify: `Resources/English.lproj/Localizable.strings` and the Preferences strings by the project's usual regeneration (`Scripts/localize.sh` runs in Release builds)
- Test: `PostgresTests/SPForeignKeyPickerPreferenceTests.m` — `testTablesPaneHasPickerCheckboxBoundToDefault` (load the pane's view, find the checkbox by title, check its `value` binding key path).

- [ ] **Step 1: Write the failing test.**
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** the checkbox and CHANGELOG; build Release once so the strings regenerate, and keep only the strings changes for this feature.
- [ ] **Step 4: Run it, then the full "Postgres Tests" scheme; expect PASS except known flaky `SPPostgresTextViewTests testIndentNewLines`.**
- [ ] **Step 5: Commit** `Sequel Plus 2.0.5: Preferences ▸ Tables checkbox for the foreign key picker; CHANGELOG`.
