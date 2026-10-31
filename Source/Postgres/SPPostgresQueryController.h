#import <Cocoa/Cocoa.h>
#import <PostgresKit/PostgresKit.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;
@class SPComboPopupButton;
@class SPSplitView;
@class SPPostgresQueryStore;
@class SPPostgresQueryFavoriteManager;
@class SPPostgresQueryResultEditor;

/**
 * The Query view of a PostgreSQL tab, laid out as MySQL's Query tab (DBView.xib): an outer SPSplitView holding
 * the editor and results (an inner SPSplitView: the SQL editor on top, the results below) over the query information
 * pane (collapsed at start, not saved), over MySQL's results bar. The results pane has MySQL's top bar: the gear,
 * Query Favorites and Query History pop-ups, and the run pop-up button (MySQL's SPComboPopupButton: Run Current / Run
 * Previous / Run Selection, or Run All, with its menu). The results bar has the info pane toggle, the results gear
 * (Export Result ▸ As CSV file…), the edit mode toggle (MySQL's shared "EditInSheetEnabled" preference) and the
 * status line. As MySQL's: ⌘R runs the primary action and ⌥⌘R the secondary one; by default the primary action is
 * Run Current, and MySQL's "QueryPrimaryControlRunsAll" preference (Switch Default) makes it Run All. Built in code.
 * Use on the main thread.
 *
 * Statements (see SPPostgresStatementSplitter) run in order on the tab's connection, in one task of taskRunner. The
 * grid shows the last row set the run returned, values in PostgreSQL's text format and NULL as MySQL's NULL
 * placeholder preference, in grey. On an error the run stops (MySQL's error sheet is not cloned): the grid keeps
 * the run's earlier row set. Statements are logged to the console as MySQL's custom queries, and errors as MySQL's.
 *
 * The status line and the info pane use MySQL's words (SPCustomQuery.m), times as +[NSString stringForTimeInterval:]:
 * - the status line: "No errors; 3 rows affected, taking 1.2 ms" (a row set with rows: ", first row available
 *   after …"), "Errors; 1 row affected in total, by 2 queries taking 3 ms", "Errors; Cancelled after 5 s" or
 *   "Errors; Cancelled in query K, after …" (K > 1). Rows are a row set's rows or a command's affected rows, summed
 *   over the statements that succeeded; the queries (K) are those sent to the server, the failing or interrupted one
 *   too (a cancel between statements: those run; before the run starts: none). The status line is cleared when a
 *   run starts.
 * - the info pane: while running, "Query Status" and the run's description ("Running query..." / "Running query K
 *   of N...", as each statement starts), without opening. On an error, a cancel being one as MySQL's, it opens,
 *   titled "Last Error Message", with the server's message and its DETAIL/HINT lines (in a run of several
 *   statements "[ERROR in query K] <message>", then "Execution stopped!" when statements remain), or "Query
 *   cancelled." ("[ERROR in query K] Query cancelled." in a run of several statements, once one was sent);
 *   otherwise it closes and says "There were no errors.". The Postgres-only notes
 *   follow, one per line: COPY … TO STDOUT output not shown, the grid's rows being an earlier statement's (after
 *   a run that completed: "Note: results shown from statement N, …"), an aborted transaction.
 *
 * A run is described as MySQL's ("Running query..." / "Running query K of N...", per statement) and can be
 * stopped ("Stop query" / "Stop queries"): the grid then shows the last row set returned before the cancel, and
 * what ran before it is still reported (runDidChangeDatabase).
 * While the runner is busy the run button and its run items are disabled, and ⌘R, ⌥⌘R and the run actions do
 * nothing (NSBeep). The editor's text is read on the main thread when the run is asked for; the statements run on
 * the runner's thread. The tests' statement hook (-setStatementWillRunHook:, a test seam) is called on that thread,
 * before each statement.
 *
 * The editor is an SPPostgresTextView (MySQL's SPTextView with Postgres colouring): MySQL's query editor font and
 * colour preferences, line numbers, auto-pair, auto-indent and auto-uppercase, without smart quotes or dashes, with undo.
 * Its auto-indent, auto-pair, auto-uppercase and auto-help toggles follow defaults (and the gear's toggles).
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Runs the statements (default: an inline runner on the connection, so a run has finished when its action returns).
/// With a background runner (the tab's, from Stage 8 Task 7) an action returns at once and the run is applied when it
/// completes; the documented end state then holds once the runner is idle.
@property (retain) SPPostgresTaskRunner *taskRunner;

/// Editor, bars, grid and info pane. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Runs every statement of the editor.
- (IBAction)runAllQueries:(id)sender;

/// Runs the statement at the cursor (see -currentQueryRange); with text selected, the statements of the selection
/// (as MySQL's Run Selection). Nothing to run (only whitespace or comments): NSBeep.
- (IBAction)runCurrentQuery:(id)sender;

/// As MySQL's: Run All when defaults' "QueryPrimaryControlRunsAll" is set, else Run Current (the run button, ⌘R).
- (IBAction)runPrimaryQueryAction:(id)sender;

/// As MySQL's: the other one (⌥⌘R).
- (IBAction)runSecondaryQueryAction:(id)sender;

/// As MySQL's Switch Default: flips "QueryPrimaryControlRunsAll" in defaults and retitles the run button and items.
- (IBAction)switchDefaultQueryAction:(id)sender;

/**
 * The statement Run Current runs: the one the caret is in, or (as MySQL's "Run Previous") the one before it when the
 * caret is after its semicolon, in the whitespace or comments that follow. Trimmed as SPPostgresStatementSplitter
 * returns it; {NSNotFound, 0} when the editor holds no statement.
 */
- (NSRange)currentQueryRange;

/// Where MySQL's shared preferences are read and written (QueryPrimaryControlRunsAll, EditInSheetEnabled, the gear's
/// toggles, through an NSUserDefaultsController for the bindings and the toggles' states). Default: standardUserDefaults.
@property (nonatomic, retain) NSUserDefaults *defaults;

/// Called by the results gear's Export Result ▸ As CSV file… (set by the tab to its -exportQueryResult:). The item is
/// enabled while the grid shows a row set and the runner is idle. Dropped by -invalidate.
@property (copy) void (^exportResultHandler)(void);

#pragma mark - MySQL's bars (DBView.xib)

/// The top bar: the gear (see -gearMenuItemSelected:), Query Favorites and Query History (see below) and the run
/// button.
@property (readonly) NSPopUpButton *gearButton;
@property (readonly) NSPopUpButton *favoritesButton;
@property (readonly) NSPopUpButton *historyButton;
@property (readonly) SPComboPopupButton *runButton;

#pragma mark - Query History (DBView.xib)

/**
 * The query history, stored apart from MySQL's (never its queryHistory preference): one entry per run that sent at
 * least one statement, the statements sent joined with ";\n" (lastRunQueryText, MySQL's usedQuery), most recent
 * first, without duplicates (an entry run again moves to the front), capped at MySQL's shared
 * "CustomQueryMaxHistoryItems" (read from defaults; 0 records nothing). Postgres tabs have no documents, so the history
 * is global. Default: +[SPPostgresQueryStore sharedHistoryStore]. The menu follows the store (a change made by another
 * tab too).
 *
 * The Query History pop-up's menu, as MySQL's: its hidden title, Copy History, Save History… (an alternate), Clear
 * Global History, a separator, the filter (an NSSearchField), a separator, then the entries (titles cut to 64
 * characters, tooltips to 256). It is hidden while "CustomQueryMaxHistoryItems" is 0 (following defaults).
 */
@property (nonatomic, retain) SPPostgresQueryStore *historyStore;

/// Where Copy History puts the history. Default: the general pasteboard.
@property (nonatomic, retain) NSPasteboard *pasteboard;

/// Save History…'s destination: called with the suggested file name ("history.sql"), returns the path to write or nil
/// to cancel. nil (the default) shows an NSSavePanel (a sheet on the view's window). Tests return a temporary path.
@property (copy) NSString * (^savePathProvider)(NSString *suggestedName);

/// Shows the history's alerts (a failed save or clear). nil (the default): a sheet on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm Clear History; call completion exactly once (later calls are ignored). nil (the default): a sheet
/// on the view's window.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

/// An entry chosen in the pop-up: inserted at the caret (undoably), or replacing the editor's text when
/// "QueryHistoryReplacesContent" is set (a modifier key held inverts it), as MySQL's.
- (IBAction)chooseQueryHistory:(id)sender;
/// The entries joined with ";\n", on pasteboard.
- (IBAction)copyQueryHistory:(id)sender;
/// The entries joined with ";\n", written (UTF-8) to the file savePathProvider (or the save panel) gives.
- (IBAction)saveQueryHistory:(id)sender;
/// Asks (confirmationPresenter), then empties the history store (-replaceItems:error:: an unreadable history file is
/// moved aside, never deleted).
- (IBAction)clearQueryHistory:(id)sender;
/// Hides the entries that don't contain the filter's text (case-insensitive); they stay in the menu, as MySQL's.
- (IBAction)filterQueryHistory:(id)sender;

#pragma mark - Query Favorites (DBView.xib)

/**
 * The query favorites (each @{@"name": …, @"query": …}), stored apart from MySQL's (never its queryFavorites
 * preference). Postgres tabs have no documents, so the favorites are global. Default:
 * +[SPPostgresQueryStore sharedFavoritesStore]. The menu follows the store (a change made by another tab too).
 *
 * The Query Favorites pop-up's menu, as MySQL's: its hidden title, Save Query to Favorites (tag 100000, retitled as
 * MySQL's -validateMenuItem:: "Save Selection to Favorites" / "Save Current Query to Favorites" / "Save All to
 * Favorites"), Save All to Favorites (tag 100001, its ⌥ alternate), Edit Favorites..., a separator, the filter (an
 * NSSearchField), a separator, the "Global" header (disabled) and the favorites (indented, the query as tooltip).
 * Saving asks for a name in MySQL's "Query Favorite Sheet"; an empty editor shows MySQL's "Empty query" alert.
 * Writes the user confirms are explicit saves (see +[SPPostgresQueryFavoriteManager writeFavorites:…]).
 */
@property (nonatomic, retain) SPPostgresQueryStore *favoritesStore;

/// As MySQL's: Save Query / Save All open the name sheet, Edit Favorites... the favorites manager; a favorite is
/// inserted at the caret (undoably), or replaces the editor's text when "QueryFavoriteReplacesContent" is set (a
/// modifier key held inverts it).
- (IBAction)chooseQueryFavorite:(id)sender;
/// Hides the favorites whose name doesn't contain the filter's text (case-insensitive); the header stays.
- (IBAction)filterQueryFavorites:(id)sender;

/// The name sheet (MySQL's "Query Favorite Sheet") while it is shown, its name field and buttons (for tests).
@property (readonly) NSPanel *favoriteNameSheet;
@property (readonly) NSTextField *favoriteNameField;
@property (readonly) NSButton *favoriteNameSaveButton;
@property (readonly) NSButton *favoriteNameCancelButton;
/// The favorites manager while it is shown (for tests).
@property (readonly) SPPostgresQueryFavoriteManager *favoritesManager;

#pragma mark - The gear menu (DBView.xib)

/**
 * The gear's items, as MySQL's -[SPCustomQuery gearMenuItemSelected:]: Previous / Next Query from History (⌃↑ / ⌃↓:
 * the next older / newer entry, inserted at the caret and selected, so a second ⌃↑ replaces it; past either end, or
 * with no history, NSBeep; moving the caret starts again from the newest), Shift Right / Left (⌘] / ⌘[, SPTextView's), Comment Line / Comment Selection (⌘/: "-- " on the
 * caret's line, or the selection wrapped in / * * /) and Comment Current Query (⌥⌘/, the current statement wrapped, or
 * unwrapped when it is already), Completion List (Esc; ⌃ fuzzy), Editor Font… (the font panel, as MySQL's) and the
 * toggles: History / Favorite Replaces Editor Content, Indent New Lines, Auto-pair Characters, Auto-uppercase
 * Keywords, Auto-completion and Update Help while typing. A toggle flips its MySQL preference in defaults and sets the
 * editor's SPTextView toggle where there is one; the toggles follow defaults (a change made elsewhere too).
 */
- (IBAction)gearMenuItemSelected:(id)sender;

/// Show Completion List ▸ (tags 8000, 8001, 8002): the editor's databases, tables and views, or current table's columns.
- (IBAction)showCompletionList:(id)sender;

#pragma mark - Help

/**
 * Shows the help for a search string (the tab's PostgreSQL help window), autoHelp YES when it is Update Help while
 * typing's. Set by the tab; dropped by -invalidate.
 */
@property (copy) void (^helpHandler)(NSString *searchString, BOOL autoHelp);

/// The editor's auto-help (SPTextView's -autoHelp, as MySQL's): the help for the selection, or for the word at the caret
/// and the next word ("create table"), through helpHandler.
- (void)showAutoHelpForCurrentWord:(id)sender;

/// The same, for the editor's context menu item (⌃H).
- (void)showHelpForCurrentWord:(id)sender;

/// As MySQL's: the help window was closed by the user, so Update Help while typing is turned off (in defaults).
- (void)helpWindowClosedByUser:(NSNotification *)notification;

/// The results bar.
@property (readonly) NSButton *infoPaneButton;
@property (readonly) NSPopUpButton *resultsGearButton;
@property (readonly) NSButton *editModeButton;
@property (readonly) NSTextField *statusField;

/// The query information pane's title (MySQL's errorTextTitle: "Query Status", or "Last Error Message" after an
/// error), its text, and the split view whose second subview (the pane) collapses.
@property (readonly) NSTextField *infoPaneTitle;
@property (readonly) NSTextView *infoPaneText;
@property (readonly) SPSplitView *infoPaneSplitView;

/// The info pane's text (see the class comment).
- (NSString *)infoPaneString;

/// Whether a run opens and closes the info pane animated (default YES; the tests turn it off).
@property (assign) BOOL infoPaneAnimates;

/// The statements the last run sent to the server (the failing or interrupted one too), joined with ";\n", as MySQL's
/// usedQuery. Unchanged by a run that sent none (cancelled before it started); nil before the first.
@property (readonly, copy) NSString *lastRunQueryText;

/// The editor font from MySQL's query editor font preference data (an archived NSFont), else the monospaced system font.
+ (NSFont *)editorFontFromPreferenceData:(NSData *)data;

/**
 * Whether a statement that ran may have changed what the tab lists (tables, views, schemas, databases): as
 * MySQL's Query tab (SPCustomQuery), statements starting with CREATE, ALTER, DROP or RENAME; for PostgreSQL also
 * IMPORT (IMPORT FOREIGN SCHEMA creates tables) and ROLLBACK / ABORT (DDL is transactional, so a rollback can
 * undo a CREATE or DROP). Leading whitespace and comments are skipped. Not detected (as MySQL): SELECT … INTO.
 */
+ (BOOL)statementMayChangeSchema:(NSString *)statement;

/// Whether a statement that ran may have changed table rows: anything but SELECT, SHOW, EXPLAIN, VALUES or TABLE
/// (a WITH may hold an INSERT, UPDATE or DELETE, so it counts as a change).
+ (BOOL)statementMayChangeData:(NSString *)statement;

/**
 * Called on the main thread after each run in which at least one statement succeeded that may have changed the
 * listed objects (schemaChanged) or rows (dataChanged), as classified by the class methods above. The tab uses it
 * to reload its lists and the Content view. Not called after -invalidate.
 */
@property (copy) void (^runDidChangeDatabase)(BOOL schemaChanged, BOOL dataChanged);
/// The session's transaction status at the end of the last run, read on the runner's thread (valid from the run's
/// completion, e.g. inside runDidChangeDatabase; libpq's status read on the main thread meanwhile could be another
/// task's).
@property (readonly) PGPostgresTransactionStatus lastRunTransactionStatus;

/// Detaches the grid, editor, bars and bindings from this controller, and drops the editor's completionNamesProvider
/// and the helpHandler
/// (called by the tab when it closes or replaces it; also on dealloc).
- (void)invalidate;

/// An SPPostgresTextView. Its completionNamesProvider is set by the tab and dropped by -invalidate (it may capture the tab).
@property (readonly) NSTextView *editor;
@property (readonly) NSTableView *resultsView;
/// The column names of the row set the grid shows, or nil when it shows none.
- (NSArray *)lastResultColumnNames;

/// The rows the grid shows, each an array of NSString (PostgreSQL's text format) or NSNull, or nil when it shows none.
- (NSArray *)lastResultRows;

/// How many rows the grid shows (0 when it shows none), without copying them.
- (NSUInteger)lastResultRowCount;

#pragma mark - Editing the result (MySQL's SPCustomQuery)

/**
 * The editor of the shown result (nil when none): each run that shows a row set makes a new one, on the statement
 * that produced it (the run's shown statement), and -invalidate (also a database switch, which replaces this
 * controller) drops it. The grid's cells and -lastResultRows (so an export) read their values from it, edits included.
 *
 * As MySQL's Query tab, a cell is edited in the grid (double-click or Return): the editor's check runs when editing
 * starts (on the main thread, only while the runner is idle: nothing is edited while it is busy). A cell that can't
 * be edited beeps and shows why (editRefusalPresenter, MySQL's messages and the editor's own). A new value goes to the
 * server (the NULL placeholder is NULL where the column is nullable; an unchanged value sends nothing); a failure
 * shows MySQL's "Error" alert (alertPresenter) and the grid keeps the old value. After a save runDidChangeDatabase
 * gets (NO, YES); then, with MySQL's "ReloadAfterEditingRow" (read from defaults) and when the shown statement may
 * change neither data nor schema, that statement alone is run again through the runner, adding no history entry,
 * keeping lastRunQueryText, the selected rows and the scroll position, and never while a cell is being edited (it
 * waits for that edit to end). Otherwise the grid shows the saved value. In edit mode (MySQL's "EditInSheetEnabled")
 * no cell is edited in the grid. A run, a new result and -invalidate close a cell editor still open without
 * committing it, and a value is saved only into the result whose editor let its cell be edited.
 */
@property (readonly) SPPostgresQueryResultEditor *resultEditor;

/// Test seam: shows why a cell can't be edited (default: NSBeep and an SPTooltip under the cell, as MySQL's). row is
/// the grid's row, column the table column's index in the grid.
@property (copy) void (^editRefusalPresenter)(NSString *message, NSInteger row, NSInteger column);

/// The status line (see the class comment): @"" before the first run and while a run runs.
@property (readonly, copy) NSString *statusText;

@end
