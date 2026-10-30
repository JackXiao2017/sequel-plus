# PostgreSQL Stage 11: Query Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Postgres Query tab MySQL's Query tab: its layout, both bars, the run pop-up button, the gear menu and the editor features behind it, query favorites and history (stored apart from MySQL's), MySQL's status text and query info pane, and Export Result ▸ As CSV file….

**Architecture:**
- `SPPostgresQueryController` keeps owning the Query view, built in code. This stage rebuilds the view in DBView.xib's layout and reuses MySQL's view classes: `SPSplitView`, `SPButtonBar`, `SPComboPopupButton`.
- The editor becomes `SPPostgresTextView`, a subclass of MySQL's `SPTextView`. It inherits auto-pair, indent, shift, line numbers, the completion pop-up and the editor colour preferences. It overrides the methods that are tied to MySQL:
  - syntax colouring, which uses a new pure `SPPostgresSQLTokenizer` instead of MySQL's flex lexer
  - completion suggestions
  - auto-completion's gate
  - the completion-list kinds
  - auto-help
- Favorites and history get their own plist stores beside `PostgresFavorites.plist`.
- Help uses MySQL's help window controller, subclassed, with a Postgres data source that shows a title and a link to postgresql.org.
- Runs still go through the tab's `SPPostgresTaskRunner` (Stage 8).

**Tech Stack:** Objective-C (MRC in `Source/Postgres`, ARC in "Postgres Tests"), AppKit built in code, PostgresKit/libpq, XCTest against the Docker PG12/PG18 servers.

**Spec:** `docs/superpowers/specs/2026-10-29-postgresql-mysql-parity-ui-design.md`. The relevant sections are "Stage 11: the Query tab", "Shared settings", "Anti-goals", "Decisions" and "Left to the builder".

## Global Constraints

- **No MySQL source edits.** These may be reused or subclassed, but MySQL behaviour through them must not change, and no file outside `Source/Postgres`, `PostgresTests` and `docs` changes:
  - `SPTextView`, `SPNarrowDownCompletion`, `SPSplitView`, `SPButtonBar`, `SPComboPopupButton`
  - `SPTableView`, `SPHelpViewerController`, `SPConstants` keys, `NSString (SPStringAdditions)`, the `button_*` images
- **Never write MySQL's stores:**
  - Never write the `queryFavorites` (`SPQueryFavorites`) or `queryHistory` (`SPQueryHistory`) preferences.
  - Never post `SPQueryFavoritesHaveBeenUpdatedNotification` or `SPHistoryItemsHaveBeenUpdatedNotification`.
  - Never call `SPQueryController` favorites or history methods.
  - Never write `~/Library/Application Support/Sequel Pro/Data/Favorites.plist`.
- **Shared preference keys, read and written as MySQL's controls do:**
  - `CustomQueryAutoIndent`, `CustomQueryAutoPairCharacters`, `CustomQueryAutoUppercaseKeywords`
  - `CustomQueryAutoComplete`, `CustomQueryUpdateAutoHelp`
  - `QueryHistoryReplacesContent`, `QueryFavoriteReplacesContent`
  - `QueryPrimaryControlRunsAll`, `EditInSheetEnabled`
  - `CustomQueryMaxHistoryItems`, read only
  - The editor reads the `CustomQueryEditor*` font, colour and tab preferences, as `SPTextView` does.
- **Defaults:** `SPPostgresQueryController` gets `@property (nonatomic, retain) NSUserDefaults *defaults;` (default `standardUserDefaults`). Every write of a key above goes through it, including the menu bindings: use `[[NSUserDefaultsController alloc] initWithDefaults:defaults initialValues:nil]`, as Stage 10's popover does, and unbind in `invalidate`. `SPTextView`'s own preference reads and its observers stay on `standardUserDefaults`; tests pin those reads in the volatile argument domain (`overridePrefs:`).
- **Tests never write real preferences, real stores or the general pasteboard:**
  - A test that writes a default injects `[[NSUserDefaults alloc] initWithSuiteName:@"SPPostgresStage11Tests"]` and calls `removePersistentDomainForName:` in tearDown.
  - The stores are created with `initWithFileURL:` on a temporary directory.
  - Copy History is tested with an injected pasteboard (`[NSPasteboard pasteboardWithUniqueName]`).
  - The font panel's `changeFont:` is never sent.
- **Stage 8 rules:**
  - No main-thread read of the connection while the runner may use it. Completion names come from lists the tab already holds, never from a new query on main.
  - Runs are refused with a beep while `[taskRunner isBusy]`, and the run controls are disabled while busy.
- **New files:** add them only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test <paths>`.
- **Commits:** trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never touch the untracked `start_clause.sh`.
- **Test commands** (start the servers first with `bash Scripts/pg-test-servers.sh up`):
  - one class: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64 -only-testing:"Postgres Tests"/<Class>`
  - full suite: same without `-only-testing`, `timeout 1500`
  - app: `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`

### MySQL reference (what "as MySQL" means here)

- **Layout:** `Interfaces/English.lproj/DBView.xib`, tab item "Custom Query" (line ≈1330). Behaviour is in `Source/SPCustomQuery.m`. The controller is the `SPCustomQuery` object, and the editor is `SPTextView`.
- **Tab root:**
  - An `SPButtonBar` background `{7,10,695,23}` at the bottom.
  - An outer `SPSplitView` (thin divider) `{7,33,695,511}`, split into:
    - editor + results `{0,0,695,391}`
    - the query info pane `{0,392,695,119}`, collapsible (index 1) and collapsed at start, with an undraggable divider
  - The inner `SPSplitView` (default divider) is split into:
    - the editor `{0,0,695,142}`
    - the results `{0,151,695,236}`
  - Both editor and results have a minimum size of 100.
  - Nothing is autosaved.
- **Top bar** (`SPButtonBar` 23 pt high, at the top of the results pane), controls at y 0:
  1. Gear pop-up `{0,0,35,23}` (`button_action`, pulls down).
  2. Query Favorites pop-up `{38,0,129,22}`: recessed, small, ⌥⌘F, tooltip "Choose a favorite from the menu or save queries to the favorites (⌥⌘F)".
  3. Query History pop-up `{177,0,145,22}`: recessed, small, ⌥⌘Y, tooltip "Choose a query from your recent queries (⌥⌘Y)". It is hidden when `CustomQueryMaxHistoryItems` is 0.
  4. Run `SPComboPopupButton` `{507,0,180,22}`: round-rect, small, flexible left margin. Its menu:
     - [0] hidden title
     - "Run Current Query", ⌘R, tag 2, `runPrimaryQueryAction:`
     - separator
     - "Run All Queries", ⌥⌘R, tag 1, `runSecondaryQueryAction:`
     - "Switch Default"
- **Bottom bar:**
  - Info pane toggle `{6,9,32,25}`:
    - images `button_pane_hide` / `button_pane_show`
    - ⌥⌘A
    - tooltip "Toggle the visibility of the Query Information Pane"
    - `toggleCollapse:` on the outer split
  - Gear `{36,10,36,23}` with "Export Result ▸ As CSV file…".
  - Edit mode toggle `{68,9,32,25}`:
    - images `button_edit_mode` / `button_edit_mode_selected`
    - tooltip "Toggle between editing simple text cells as a spreadsheet or in pop-up sheets"
    - bound to `EditInSheetEnabled`
  - Status text `{103,12,582,17}`, small system font.
- **Gear menu:** the items, keys and tags are listed in Task 6. `-[SPCustomQuery gearMenuItemSelected:]` (SPCustomQuery.m:395–514) is the behaviour.
- **Favorites and history menus:** `SPCustomQuery.m`:
  - `chooseQueryFavorite:` :282, `chooseQueryHistory:` :362
  - `queryFavoritesHaveBeenUpdated:` :2966, `historyItemsHaveBeenUpdated:` :2944
  - `filterQueryFavorites:` / `filterQueryHistory:` :3348–3372
  - copy, save and clear history :517–592
  - `validateMenuItem:` :3220–3256
- **Status and info pane:** `SPCustomQuery.m:889–950` and `updateStatusInterfaceWithDetails:` :1342–1430. The time is formatted by `+[NSString stringForTimeInterval:]`.

### Rulings on the spec (made while planning)

- **The status line uses MySQL's real strings, not "N rows in set".** The spec quotes "N rows in set", but MySQL's code has no such string. "As MySQL" wins, so the status line reads, for example:
  - "No errors; 3 rows affected, taking 1.2 ms"
  - "Errors; 0 rows affected, taking 2 ms"
  - "No errors; 1 row affected in total, by 2 queries taking 3 ms"
  - "No errors; Cancelled after 5 s"

  The Postgres-only notes move into the info pane:
  - the server's DETAIL/HINT lines
  - the aborted-transaction note
  - "results shown from statement N"
  - COPY output not shown

  The info pane opens on an error and closes on a clean run, as MySQL's does. Existing tests that assert the old status strings are updated to the new ones; the behaviour they pin (which statement errored, the cancel, the shown rows) stays.
- **A run still stops at the first error.** MySQL's multi-query error sheet (Run All / Continue / Stop) is not cloned, so Postgres keeps its tested stop-at-first-error. The info pane says "[ERROR in query K] <message>" then "Execution stopped!", in MySQL's words.
- **⌘R and ⌥⌘R stay handled by `SPPostgresQueryView`,** which is tested. The run menu shows the keys as MySQL's does, but the view takes the key first, so a key press never runs twice.
- **The editor is a subclass of `SPTextView`,** with no edit to `SPTextView`. MySQL features that `SPTextView` gates on `SPCustomQuery`, or on its class name being exactly "SPTextView", are left out for Postgres:
  - tab-trigger snippets
  - the current-query highlight background
  - bundle commands
- **Postgres-specific colouring:**
  - `"…"` is a quoted identifier, coloured with MySQL's backtick colour.
  - `'…'`, `E'…'` and `$tag$…$tag$` are strings, coloured with the quote colour.
  - `/* */` comments may nest.
  - Keywords and built-in type names get the keyword colour and are auto-uppercased. Function names are completion only. Auto-uppercase can't change meaning, because PostgreSQL folds unquoted identifiers.
- **Completion never inserts a backtick.** A name that needs quoting is offered and inserted as `"Name"`.
- **The help window is MySQL's `SPHelpViewerController`, subclassed only to title it "PostgreSQL Help".** Its MySQL/Page/Web target control is left as it is.
- **Favorites manager:** a code-built sheet with:
  - the favorites list
  - add, remove and duplicate buttons
  - a name field
  - the query in an `SPPostgresTextView`
  - Cancel and Save

  It leaves out MySQL's tab triggers (they need snippets, see above) and the import/export of `.spf` favorites files. Postgres tabs have no documents, so all Postgres favorites and history are global; there are no "‘file’ based" sections.
- **History records one entry per run:** the statements run, joined with ";\n", as MySQL's `usedQuery`. Entries are most recent first and deduplicated, capped at `CustomQueryMaxHistoryItems`, and stored in `Data/PostgresQueryHistory.plist`.
- **The edit mode toggle in the results bar only sets the preference in this stage.** Results stay read-only until Stage 12.
- **The info pane's visibility is not saved,** as MySQL's isn't.

## Review Focus

1. **A history or favorites file that is corrupt, or written by a newer build:**
   - The menus show what can be read.
   - The file is never overwritten until the user saves or clears.
   - A failed save is reported, not silent.

   Pinned in Task 7 (`testCorruptStoreIsNotOverwritten`).
2. **Colouring a large or half-typed editor text** (an unterminated `'`, `$tag$` or `/*`, 1 MB of text): no hang and no exception; the rest of the text is coloured as the open string or comment. Pinned in Task 3 (`testUnterminatedTokensRunToEnd`) and Task 4 (`testLargeTextHighlightsWithoutHang`).
3. **Completion while a run is in progress or before the lists have loaded:**
   - Keywords and buffer words are still offered.
   - No query is sent on main.
   - Pinned in Task 5 (`testCompletionWhileBusyUsesHeldLists`).
4. **Running with the caret after the last statement, inside a comment, or with only whitespace selected:**
   - The run button's title matches what ⌘R runs: "Run Previous", "Run Current" or "Run Selection".
   - Whitespace alone runs nothing and beeps.
   - Pinned in Task 1 (`testRunTitleFollowsCaret`).
5. **Mixed-case or quoted names** (`"Order Items"`, schema `Sales`): completion inserts them quoted, and auto-uppercase leaves quoted identifiers and strings alone. Pinned in Task 4 (`testAutoUppercaseSkipsQuotedText`) and Task 5 (`testCompletionQuotesMixedCaseNames`).

---

### Task 1: MySQL's layout, the run pop-up button and the results bar

**Files:**
- Modify: `Source/Postgres/SPPostgresQueryController.h`, `.m` (`_buildView`, run actions, `invalidate`, busy KVO)
- Modify: `Source/Postgres/SPPostgresDocument.m` (an `exportQueryResult:` entry for the bar's Export item)
- Modify: `Source/Postgres/SPPostgresExportController.h`, `.m` (start the sheet with a source chosen)
- Test: `PostgresTests/SPPostgresQueryBarTests.m` (new; `add-test`)
- Test: `PostgresTests/SPPostgresQueryControllerTests.m` (only tests that found the old "Run All" / "Run Current" buttons)

**Interfaces:**
- Produces, on `SPPostgresQueryController`:
  - `@property (nonatomic, retain) NSUserDefaults *defaults;`
  - `@property (readonly) NSPopUpButton *gearButton, *favoritesButton, *historyButton, *resultsGearButton;`. The menus are created here: the gear with its hidden image item only, favorites and history with their hidden title item only. Tasks 6–8 fill them.
  - `@property (readonly) SPComboPopupButton *runButton;`
  - `@property (readonly) NSButton *infoPaneButton, *editModeButton;`
  - `@property (readonly) NSTextField *statusField;`
  - `@property (readonly) NSTextView *infoPaneText;`
  - `@property (readonly) SPSplitView *infoPaneSplitView;`
  - `- (IBAction)runPrimaryQueryAction:(id)sender;`, `- (IBAction)runSecondaryQueryAction:(id)sender;`, `- (IBAction)switchDefaultQueryAction:(id)sender;`
  - `- (NSRange)currentQueryRange;`: the statement at the caret, as the Run Current title describes it (Task 6 uses it).
  - `@property (copy) void (^exportResultHandler)(void);`, set by the document to `exportQueryResult:`.
- Produces on `SPPostgresExportController`: `- (void)beginSheetWithQueryResultSource;`. It starts the sheet with "Query result" chosen and the format on CSV.

- [ ] **Step 1: Write the failing tests** in `SPPostgresQueryBarTests`. Copy the fixture from `SPPostgresQueryControllerTests`, with `defaults` injected:
  - `testLayoutMatchesDBView`:
    - The top bar is 23 pt high and sits directly above the results.
    - The gear, favorites, history and run button frames are `{0,0,35,23}`, `{38,0,129,22}`, `{177,0,145,22}` and `{width−188,0,180,22}`.
    - The bottom bar has the info toggle at `{6,9,32,25}` and the results gear at `{36,10,36,23}`, measured from the Query view's root origin minus the 7 pt inset as in DBView.xib. The edit mode toggle is at `{68,9,32,25}`. The status field is at x 103.
    - The images, tooltips and ⌥⌘A are as in the MySQL reference.
    - The info pane is collapsed at start.
  - `testRunMenuItemsAndSwitchDefault`:
    - The menu titles are `["Run Current", "Run Current Query", <separator>, "Run All Queries", "Switch Default"]`.
    - The key equivalents are "r"/⌘ on tag 2 and "r"/⌥⌘ on tag 1.
    - Switch Default writes `QueryPrimaryControlRunsAll` YES into `defaults`. Then the button title is "Run All", and the tag 2 item reads "Run All Queries".
  - `testRunTitleFollowsCaret`:
    - The caret is in `SELECT 1; SELECT 2` → "Run Current".
    - The caret is after the final `;` plus whitespace → "Run Previous", and ⌘R runs `SELECT 2`.
    - Selecting text → "Run Selection".
    - A whitespace-only selection runs nothing and beeps (the grid is unchanged).
  - `testRunControlsDisabledWhileBusy`: during a `pg_sleep(2)` run, the run button and both run items are disabled. They are enabled again after the run.
  - `testInfoPaneToggle`: `infoPaneButton` performClick expands the pane; a second click collapses it. Nothing is written to `defaults`.
  - `testEditModeToggleWritesSharedPreference`: a click sets `EditInSheetEnabled` YES in `defaults`. Changing `defaults` elsewhere updates the button state.
  - `testExportResultOpensCSVSheetWithQueryResult`:
    - "As CSV file…" is disabled with no result.
    - After `SELECT 1 AS one`, it is enabled. It opens the export sheet with the source popup on "Query result" and the format on CSV.
    - End the sheet with cancel.
- [ ] **Step 2: Run `SPPostgresQueryBarTests` and confirm they fail** (missing properties).
- [ ] **Step 3: Implement.**
  - Rebuild `_buildView` with `SPSplitView`s and the frames above.
  - The run button is `[[SPComboPopupButton alloc] initWithFrame:… pullsDown:YES]`. Its target/action is `runPrimaryQueryAction:` and its menu is MySQL's.
  - Contextual titles:
    - Port `updateQueryInteractionInterface` / `updateContextualRunInterface` (SPCustomQuery.m:1442–1520).
    - Call them on selection change (editor delegate `textViewDidChangeSelection:`) and on Switch Default.
    - For the "previous" case, use `SPPostgresStatementSplitter` ranges.
  - `runPrimaryQueryAction:` / `runSecondaryQueryAction:` follow MySQL's semantics. `SPPostgresQueryView`'s keys call them.
  - Delete the old Run All / Run Current buttons and their tooltip owner code.
  - Bind the edit mode toggle through the `NSUserDefaultsController` (Global Constraints).
- [ ] **Step 4: Run `SPPostgresQueryBarTests` and `SPPostgresQueryControllerTests`. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 1: MySQL's Query tab layout, run pop-up button and results bar".

### Task 2: MySQL's status text and the query info pane

**Files:**
- Modify: `Source/Postgres/SPPostgresQueryController.m` (`SPPostgresQueryRun`, `_runStatements:…`, the completion)
- Test: `PostgresTests/SPPostgresQueryBarTests.m`
- Test: `PostgresTests/SPPostgresQueryControllerTests.m` (the status-string assertions)

**Interfaces:**
- Consumes: from Task 1, `statusField`, `infoPaneText` and `infoPaneSplitView`.
- Produces:
  - `statusText` in MySQL's format (the ruling above).
  - `- (NSString *)infoPaneString;`: the info pane's text.
  - `@property (readonly) NSString *lastRunQueryText;`: the statements run, joined with ";\n" (Task 7 records it).

- [ ] **Step 1: Write the failing tests.** Match the times with a regex `taking [0-9.,]+ (ms|s)`:
  - `testStatusTextSingleQuery`:
    - `SELECT * FROM content_test.items` gives "No errors; N rows affected, first row available after …".
    - `UPDATE … WHERE false` gives "No errors; 0 rows affected, taking …".
  - `testStatusTextMultipleQueries`: two UPDATEs affecting 2 and 1 rows give "No errors; 3 rows affected in total, by 2 queries taking …".
  - `testErrorOpensInfoPane`:
    - `SELECT 1; SELECT nope; SELECT 3` gives a status that begins "Errors; ".
    - The info pane is expanded. Its text contains "[ERROR in query 2] " followed by the server's message and its DETAIL/HINT lines, then "Execution stopped!".
    - The next clean run collapses it, and its text is "There were no errors.".
  - `testCancelledStatus`: cancelling a `pg_sleep(30)` run gives "No errors; Cancelled after …". With two statements it gives "Cancelled in query 1, after …".
  - `testPostgresNotesInInfoPane`: the aborted-transaction note, "results shown from statement 1" and the COPY note appear in the info pane text.
  - Update the old `SPPostgresQueryControllerTests` status assertions to the new strings. Keep what each test pins.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
  - Time the work on the runner's thread (`CFAbsoluteTimeGetCurrent` around the statements; for a row set, to the first row).
  - Collect per-statement errors and notes into `SPPostgresQueryRun`.
  - Build the strings with MySQL's `NSLocalizedString` keys, unchanged, so MySQL's translations apply.
  - Expand or collapse the info pane as `updateStatusInterfaceWithDetails:` does, animated off in tests.
  - While running, set the title "Query Status" and the text "Running query...", without expanding (as MySQL).
- [ ] **Step 4: Run both classes. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 2: MySQL's status text and query info pane".

### Task 3: `SPPostgresSQLTokenizer`

**Files:**
- Create: `Source/Postgres/SPPostgresSQLTokenizer.h`, `.m` (`add-app`)
- Test: `PostgresTests/SPPostgresSQLTokenizerTests.m` (`add-test`; pure, no server)

**Interfaces:**
- Produces:
  - `typedef NS_ENUM(NSUInteger, SPPostgresTokenKind) { SPPostgresTokenWhitespace, SPPostgresTokenKeyword, SPPostgresTokenIdentifier, SPPostgresTokenQuotedIdentifier, SPPostgresTokenString, SPPostgresTokenComment, SPPostgresTokenNumber, SPPostgresTokenParameter, SPPostgresTokenOther };`
  - `@interface SPPostgresSQLToken : NSObject` with `@property (readonly) SPPostgresTokenKind kind; @property (readonly) NSRange range;`
  - `+ (NSArray<SPPostgresSQLToken *> *)tokensInString:(NSString *)string range:(NSRange)range;`: it covers `range` exactly, with no gaps.
  - `+ (NSSet<NSString *> *)keywords;`: lowercase. It holds every word of PG18's `SELECT word FROM pg_get_keywords()`, frozen into the source at implementation time, plus the built-in type names `SELECT typname FROM pg_type WHERE typnamespace = 'pg_catalog'::regnamespace AND typtype IN ('b','p','r','m') AND typname !~ '^_'`.
  - `+ (NSArray<NSString *> *)functionNames;`: sorted and lowercase, from `SELECT DISTINCT proname FROM pg_proc WHERE pronamespace = 'pg_catalog'::regnamespace AND proname !~ '^_' AND proname !~ '^pg_'`, frozen. The `pg_*` admin functions are added back for `pg_sleep`, `pg_size_pretty`, `pg_typeof`, `pg_get_viewdef`, `pg_cancel_backend`, `pg_terminate_backend`.
  - Record the exact query output count in a comment beside each list.

- [ ] **Step 1: Write the failing tests:**
  - `testKindsOfEachToken`: `SELECT "Name", 'it''s', E'a\'b', $f$x$f$, 1.5e3, $1 FROM t -- c` gives kinds in order:
    - keyword, quoted identifier, other(,), string, other, string, other, string, other, number, other, parameter, keyword, identifier, comment
    - with whitespace between
    - and ranges that cover the text exactly
  - `testNestedBlockComments`: `/* a /* b */ c */ SELECT` is one comment, then whitespace, then a keyword.
  - `testDollarTagsMustMatch`: in `$a$ $b$ $a$`, `$b$` is inside the string.
  - `testUnterminatedTokensRunToEnd`: `'abc`, `$x$abc`, `/* abc` and `"abc` each give one token to the end of the text, of the right kind.
  - `testKeywordsAreCaseInsensitiveAndTypesIncluded`: `select`, `SeLeCt`, `integer`, `timestamptz` and `returning` are keywords. `items` is an identifier.
  - `testSubrangeTokenizing`: tokenizing `range` {7,8} of `SELECT a FROM b` gives tokens inside that range only.
- [ ] **Step 2: Run `SPPostgresSQLTokenizerTests` and confirm they fail.**
- [ ] **Step 3: Implement** a single pass over UTF-16 code units. Lexing rules are the same as `SPPostgresStatementSplitter`'s (`E'` escapes, `''` doubling, dollar tags, nested comments), but the tokenizer stays a separate class, because the splitter's API is statement-level.
- [ ] **Step 4: Run the tests. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 3: SQL tokenizer for the Postgres editor".

### Task 4: `SPPostgresTextView`: colouring, auto-uppercase, auto-pair, indent

**Files:**
- Create: `Source/Postgres/SPPostgresTextView.h`, `.m` (`add-app`)
- Modify: `Source/Postgres/SPPostgresQueryController.h`, `.m` (the editor becomes `SPPostgresTextView`; `editor` is still typed `NSTextView *`)
- Test: `PostgresTests/SPPostgresTextViewTests.m` (`add-test`)

**Interfaces:**
- Consumes: Task 3's tokenizer.
- Produces:
  - `@interface SPPostgresTextView : SPTextView`
  - `- (instancetype)initWithFrame:(NSRect)frame scrollView:(NSScrollView *)scrollView;`: it sets the `scrollView` ivar and calls `awakeFromNib`, so the line number ruler is added as in MySQL.
  - The editor's toggles are MySQL's setters (`setAutoindent:`, `setAutopair:`, `setAutouppercaseKeywords:`, `setAutohelp:`). The controller sets them from `defaults` at build time and when the gear toggles change (Task 6).
  - `doSyntaxHighlighting` is overridden. It uses the tokenizer and sets the same attributes `SPTextView`'s own does, so the inherited auto-pair and auto-help logic works:
    - `NSForegroundColorAttributeName` from the inherited colour properties
    - `@"Quoted"` = `@"isMarked"` on strings, quoted identifiers and comments
    - `@"Quote"` = `@"isQuoted"` on strings
    - `@"s"` on keywords

    It uses `SPTextView`'s partial-parsing limits (the visible range plus a bias, nothing above its maximum size). Auto-uppercase applies to keyword tokens only, as `SPTextView.m:2855–2880` does.

- [ ] **Step 1: Write the failing tests.** Build the Query view in a window, with colours pinned via `overridePrefs:` to archived colours that are easy to tell apart:
  - `testColoursByTokenKind`: after `setString:` and `doSyntaxHighlighting`:
    - `select` has the keyword colour.
    - `'x'` has the quote colour.
    - `"T"` has the backtick colour.
    - `-- c` has the comment colour.
    - `42` has the numeric colour.
    - `$1` has the variable colour.
    - `items` has the text colour.
  - `testAutoUppercaseSkipsQuotedText`:
    - With auto-uppercase on, typing `select 'select' "select" -- select` through `insertText:` gives `SELECT 'select' "select" -- select`.
    - Undo restores the typed text.
  - `testAutoPairInsertsClosingQuote`: with auto-pair on, `insertText:@"("` gives `()` with the caret between. Inside a string, `'` is not paired.
  - `testIndentNewLines`: with auto-indent on, `insertNewline:` after `    SELECT` starts the new line with four spaces.
  - `testLargeTextHighlightsWithoutHang`: 1 MB of `SELECT 1;\n` lines colours in under 2 s, with no exception.
  - `testEditorKeepsPreviousGuarantees`: re-run `testEditorUsesQueryEditorPreferences` unchanged:
    - font Menlo 15
    - no smart quotes, dashes, text replacement or spelling correction
    - undo on
    - plain text
  - Also check `[editor isKindOfClass:SPPostgresTextView.class]`.
- [ ] **Step 2: Run `SPPostgresTextViewTests` and confirm they fail.**
- [ ] **Step 3: Implement.** Create the editor with `initWithFrame:scrollView:`. Keep the existing `setAutomatic…:NO` calls after `awakeFromNib`. The `kLEXToken`/`kQuote` names are private `#define`s in `SPTextView.m`: repeat their string values in `SPPostgresTextView.m`, with a comment naming the source.
- [ ] **Step 4: Run `SPPostgresTextViewTests` and `SPPostgresQueryControllerTests`. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 4: Postgres editor on SPTextView with Postgres colouring".

### Task 5: Completion

**Files:**
- Modify: `Source/Postgres/SPPostgresTextView.h`, `.m`
- Modify: `Source/Postgres/SPPostgresQueryController.h`, `.m`
- Modify: `Source/Postgres/SPPostgresDocument.m` (supplies the names)
- Test: `PostgresTests/SPPostgresTextViewTests.m`

**Interfaces:**
- Produces, on `SPPostgresTextView`:
  - `@property (copy) NSDictionary<NSString *, NSArray<NSString *> *> * (^completionNamesProvider)(void);`, with keys `@"databases"`, `@"schemas"`, `@"tables"`, `@"views"`, `@"columns"`. It is called on main and must return at once, from lists the tab already holds.
  - `- (NSArray *)suggestionsForSQLCompletionWith:dictMode:browseMode:withTableName:withDbName:` (override). It returns `SPNarrowDownCompletion` item dictionaries (`display`, `match`, `image`, `isRef` never set) for:
    - the buffer's words
    - `+[SPPostgresSQLTokenizer keywords]`, shown uppercased
    - the function names
    - the provider's names, quoted with `"…"` when they are not all-lowercase identifiers or are keywords
  - `doAutoCompletion` (override): `SPTextView`'s timer behaviour without the `SPCustomQuery` gate, honouring `CustomQueryAutoComplete` and `CustomQueryAutoCompleteDelay`.
  - `showCompletionListFor:atRange:fuzzySearch:` (override): `$SP_ASLIST_ALL_DATABASES` / `_TABLES` / `_FIELDS` list the provider's databases, tables and views, or the current table's columns. It never calls `valueForKeyPath:` on the delegate.
- Produces, on `SPPostgresDocument`: the provider is set on the query controller's editor. Its sources:
  - the database names the tab lists
  - the schema names
  - the current schema's tables and views from the sidebar
  - the current table's column names from the Content view's loaded columns (empty if none)

- [ ] **Step 1: Write the failing tests:**
  - `testSuggestionsIncludeKeywordsFunctionsAndNames`:
    - With a provider returning `tables: [items, Order Items]`, the suggestions for `it` include `items`.
    - For `ret` they include `RETURNING`.
    - For `pg_sl` they include `pg_sleep`.
  - `testCompletionQuotesMixedCaseNames`: the suggestion for `Ord` has `match` `"Order Items"`. Inserting it through the completion pop-up's `insert_text:` path with `CustomQueryEditorCompleteWithBackticks` YES (pinned) inserts `"Order Items"` and no backtick.
  - `testCompletionListKinds`: the three `$SP_ASLIST_*` kinds open a pop-up whose items are the provider's lists. Close it with `[popup close]`.
  - `testCompletionWhileBusyUsesHeldLists`:
    - During a `pg_sleep(2)` run, the suggestions still come from the provider and the keywords.
    - The runner's connection sees no extra query: count `SPPostgresConsoleLogger` messages before and after.
  - `testDocumentProviderListsSidebarAndContent`: on the `content_test` fixture, with `items` selected and Content loaded, the provider's `tables` contains `items` and `columns` contains Content's column names.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `SPPostgresTextViewTests`. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 5: editor completion from the tab's lists".

### Task 6: The gear menu and Update Help while typing

**Files:**
- Create: `Source/Postgres/SPPostgresHelp.h`, `.m` (`add-app`): the help data source and the `SPHelpViewerController` subclass
- Modify: `Source/Postgres/SPPostgresQueryController.h`, `.m`, `Source/Postgres/SPPostgresTextView.m` (the `autoHelp` override), `Source/Postgres/SPPostgresDocument.m` (owns the help window and the server major version)
- Test: `PostgresTests/SPPostgresQueryGearTests.m` (`add-test`)

**Interfaces:**
- Consumes:
  - from Task 1: `gearButton`, `currentQueryRange`, `defaults`
  - from Task 5: the editor
- Produces:
  - The gear menu items, in MySQL's order, with MySQL's titles, tags, keys and tooltips:
    - the hidden `button_action` item
    - "Previous Query from History" (tag 3, ⌃↑) and "Next Query from History" (tag 4, ⌃↓): Task 7 implements these
    - "History Replaces Editor Content"
    - separator
    - "Favorite Replaces Editor Content"
    - separator
    - "Shift Right" (tag 6, ⌘]), "Shift Left" (tag 7, ⌘[)
    - "Comment Line" (tag 11, ⌘/), "Comment Current Query" (tag 12, ⌥⌘/, alternate)
    - "Completion List" (tag 8, Esc, no modifiers)
    - "Show Completion List ▸" with "All Databases Names" (8000, ⌥⌘1), "All Table and View Names" (8001, ⌥⌘2), "All Field Names From Current Table" (8002, ⌥⌘3)
    - separator
    - "Editor Font..."
    - "Indent New Lines" (tag 9), "Auto-pair Characters" (tag 10), "Auto-uppercase Keywords", "Auto-completion", "Update Help while typing"
  - `- (IBAction)gearMenuItemSelected:(id)sender;`, `- (IBAction)showCompletionList:(id)sender;`
  - `SPPostgresHelpDataSource <SPHelpViewerDataSource>`:
    - `- (instancetype)initWithServerMajorVersion:(NSString *)major;`. `major` is @"18", or @"9.6" for servers before 10.
    - `+ (NSString *)documentationPathForKeyword:(NSString *)keyword;` returns, for example, @"sql-select.html", or nil when the word is not a keyword. A keyword without a page of its own maps to @"sql-commands.html".
  - `SPPostgresHelpViewerController : SPHelpViewerController`, whose window title is "PostgreSQL Help".

- [ ] **Step 1: Write the failing tests:**
  - `testGearMenuItems`: the titles, tags, key equivalents and modifier masks are exactly as listed.
  - `testToggleItemsWriteSharedPreferences`:
    - Each toggle (Indent, Auto-pair, Auto-uppercase, Auto-completion, Update Help, History/Favorite Replaces) flips its key in `defaults`.
    - Where `SPTextView` has a setter, the editor's getter follows (`autoindent`, `autopair`, `autouppercaseKeywords`, `autohelp`).
    - A change made to `defaults` elsewhere updates the item's state.
  - `testShiftAndComment`:
    - Shift Right on `SELECT 1` indents it by `CustomQuerySoftIndentWidth` or a tab, as `SPTextView` does. Shift Left undoes it.
    - Comment Line toggles `-- ` on the caret's line.
    - With a selection, the item reads "Comment Selection" and wraps the selection in `/* */`.
    - Comment Current Query wraps `currentQueryRange` and unwraps it on a second use.
  - `testHelpPathsAndLinks`:
    - `select` maps to `sql-select.html`, `create table` to `sql-createtable.html`, and `returning` to `sql-commands.html`. `items` maps to nil.
    - `HTMLHelpContentsForSearchString:@"select" autoHelp:YES` contains `<a href="https://www.postgresql.org/docs/18/sql-select.html">` and the title `SELECT`.
    - For a 9.6 major the link is `/docs/9.6/`.
  - `testAutoHelpShowsWordAtCaret`:
    - With "Update Help while typing" on, `[editor autoHelp]` with the caret in `select` makes the tab's help window visible, titled "PostgreSQL Help", with the SELECT page.
    - In `'select'` nothing is shown.
    - Closing the window turns the key off in `defaults`, as MySQL's `helpWindowClosedByUser:`.
- [ ] **Step 2: Run `SPPostgresQueryGearTests` and confirm they fail.**
- [ ] **Step 3: Implement.**
  - **Comment Line / Comment Current Query:** port `commentOut` and `commentOutCurrentQueryTakingSelection:` (SPCustomQuery.m:1240–1340), without MySQL's `#` comments.
  - **Editor Font…:** port SPCustomQuery.m:465–470.
  - **Help:**
    - The help page is HTML with the keyword's title and one link. It is never fetched; links open in the browser through the controller's existing policy.
    - Map the SQL command pages from the docs' "SQL Commands" list: one entry per command, keyed by its words lowercased (`"alter table"` → `sql-altertable.html`). Two-word lookups try the word at the caret plus the next word, then the word alone.
- [ ] **Step 4: Run `SPPostgresQueryGearTests`. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 6: Query gear menu and PostgreSQL help while typing".

### Task 7: Query history

**Files:**
- Create: `Source/Postgres/SPPostgresQueryStore.h`, `.m` (`add-app`): one class used for both stores
- Modify: `Source/Postgres/SPPostgresQueryController.h`, `.m`
- Test: `PostgresTests/SPPostgresQueryStoreTests.m` (`add-test`; pure), `PostgresTests/SPPostgresQueryHistoryTests.m` (`add-test`)

**Interfaces:**
- Produces:
  - `SPPostgresQueryStore`:
    - `- (instancetype)initWithFileURL:(NSURL *)url;`
    - `+ (instancetype)sharedHistoryStore;` (`…/Sequel Pro/Data/PostgresQueryHistory.plist`)
    - `+ (instancetype)sharedFavoritesStore;` (`…/Sequel Pro/Data/PostgresQueryFavorites.plist`)
    - `@property (readonly) NSArray *items;`: reloaded from the file when it changed
    - `- (BOOL)setItems:(NSArray *)items error:(NSError **)error;`: atomic write; posts `SPPostgresQueryStoreDidChangeNotification` with the store as the object
    - `@property (readonly) NSError *lastLoadError;`
    - It never overwrites a file it could not read (as `SPPostgresFavoritesStore`). A history item is an `NSString`; a favorite is `@{@"name": …, @"query": …}`.
  - On `SPPostgresQueryController`:
    - `@property (nonatomic, retain) SPPostgresQueryStore *historyStore;` (default shared)
    - `@property (nonatomic, retain) NSPasteboard *pasteboard;` (default general)
    - `- (IBAction)chooseQueryHistory:(id)sender, copyQueryHistory:, saveQueryHistory:, clearQueryHistory:;`
    - the Previous/Next gear items

- [ ] **Step 1: Write the failing tests:**
  - `SPPostgresQueryStoreTests`:
    - `testRoundTrip`
    - `testCorruptStoreIsNotOverwritten`: garbage bytes give empty `items`, a `lastLoadError`, and `setItems:` refusing with an error while the file is unchanged. A missing file is fine and is created on save.
    - `testChangeNotification`
  - `SPPostgresQueryHistoryTests`, with a temp store and the `defaults` suite (`CustomQueryMaxHistoryItems` = 3):
    - `testRunAddsHistoryEntry`: running `SELECT 1; SELECT 2` adds `"SELECT 1;\nSELECT 2"` first. Running it again doesn't duplicate it. Five runs keep three. MySQL's `queryHistory` preference is unchanged (read `[NSUserDefaults standardUserDefaults]` before and after).
    - `testHistoryMenu`:
      - The items are `["Query History", "Copy History", "Save History…", "Clear History", <sep>, <search field>, <sep>, entries…]`, with MySQL's tags and tooltips.
      - Choosing an entry inserts it at the caret. With `QueryHistoryReplacesContent` YES it replaces the text.
      - Copy History puts the entries joined with ";\n" on the injected pasteboard.
      - Clear History (confirm via the test alert presenter seam) empties the store.
      - The pop-up is hidden when the max is 0.
    - `testSearchFiltersHistory`: typing `two` in the search field leaves only the matching entries visible (hidden items stay in the menu, as MySQL).
    - `testPreviousNextFromHistory`: ⌃↑ inserts the newest entry and a second ⌃↑ the next one. ⌃↓ steps back. Going past either end beeps.
    - `testSaveHistoryWritesFile`: with a save-path seam (`savePathProvider`, as the export controller's), the file holds the entries joined with ";\n".
- [ ] **Step 2: Run both classes and confirm they fail.**
- [ ] **Step 3: Implement.** Record history in the run's completion from `lastRunQueryText` (Task 2). The search field is an `NSSearchField` as the menu item's view, as MySQL.
- [ ] **Step 4: Run both classes. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 7: query history stored apart from MySQL's".

### Task 8: Query favorites and the favorites manager

**Files:**
- Create: `Source/Postgres/SPPostgresQueryFavoriteManager.h`, `.m` (`add-app`): a code-built sheet
- Modify: `Source/Postgres/SPPostgresQueryController.h`, `.m`
- Test: `PostgresTests/SPPostgresQueryFavoritesTests.m` (`add-test`)

**Interfaces:**
- Consumes: Task 7's `SPPostgresQueryStore`; Task 4's `SPPostgresTextView`.
- Produces:
  - On `SPPostgresQueryController`: `@property (nonatomic, retain) SPPostgresQueryStore *favoritesStore;` and `- (IBAction)chooseQueryFavorite:(id)sender;`
  - `SPPostgresQueryFavoriteManager`:
    - `- (instancetype)initWithStore:(SPPostgresQueryStore *)store;`
    - `- (void)beginSheetForWindow:(NSWindow *)window completion:(void (^)(BOOL saved))completion;`
    - `@property (readonly) NSTableView *favoritesTable;`, `NSTextField *nameField;`, `NSTextView *queryView;`, `NSButton *addButton, *removeButton, *duplicateButton, *saveButton, *cancelButton;`

- [ ] **Step 1: Write the failing tests**, with a temp store:
  - `testFavoritesMenu`:
    - The items are `["Query Favorites", "Save Query to Favorites", "Save All to Favorites" (alternate), "Edit Favorites...", <sep>, <search field>, <sep>, "Global" header (disabled, tooltip "Globally stored favorites"), favorites indented 1 with the query as tooltip]`.
    - The tags are 100000 and 100001.
  - `testSaveQueryToFavorites`:
    - Save Query opens the name sheet. Set the name and confirm through the sheet's seam. The store then holds `{name, query}` of the current query, or of the selection when there is one.
    - The item's title follows MySQL's `validateMenuItem:`: "Save Selection to Favorites" / "Save Current Query to Favorites".
    - Save All stores the whole text.
    - An empty editor shows MySQL's "Empty query" alert and saves nothing.
    - MySQL's `queryFavorites` preference is unchanged.
  - `testChooseFavoriteInsertsOrReplaces`: choosing a favorite inserts its query at the caret. With `QueryFavoriteReplacesContent` YES it replaces the text.
  - `testManagerEditsAndSaves`:
    - In the manager: add a favorite, set its name and query, duplicate it, remove the original.
    - Save writes the store and the menu updates. Cancel writes nothing.
  - `testSearchFiltersFavorites`
- [ ] **Step 2: Run `SPPostgresQueryFavoritesTests` and confirm they fail.**
- [ ] **Step 3: Implement.**
  - The manager uses MySQL's QueryFavoriteManager.xib as the layout reference: the list on the left with an `SPButtonBar` holding add/remove/duplicate (`button_add`, `button_remove`, `button_duplicate`), the name field and query editor on the right, and Cancel and Save at the bottom.
  - Both menus rebuild on `SPPostgresQueryStoreDidChangeNotification`, so every Postgres tab updates.
- [ ] **Step 4: Run it, then the full suite and the app build. All pass.**
- [ ] **Step 5: Commit** with the message "Postgres Stage 11 Task 8: query favorites and favorites manager stored apart from MySQL's".
