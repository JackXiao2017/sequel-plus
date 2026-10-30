#import <Cocoa/Cocoa.h>
#import <PostgresKit/PostgresKit.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;
@class SPComboPopupButton;
@class SPSplitView;

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
 * The editor uses MySQL's query editor font preference, without smart quotes or dashes, with undo.
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

/// Where MySQL's shared preferences are read and written (QueryPrimaryControlRunsAll, EditInSheetEnabled, through an
/// NSUserDefaultsController for the bindings). Default: standardUserDefaults.
@property (nonatomic, retain) NSUserDefaults *defaults;

/// Called by the results gear's Export Result ▸ As CSV file… (set by the tab to its -exportQueryResult:). The item is
/// enabled while the grid shows a row set and the runner is idle. Dropped by -invalidate.
@property (copy) void (^exportResultHandler)(void);

#pragma mark - MySQL's bars (DBView.xib)

/// The top bar: the gear (its hidden image item only, for now), Query Favorites and Query History (their hidden title
/// item only, for now) and the run button.
@property (readonly) NSPopUpButton *gearButton;
@property (readonly) NSPopUpButton *favoritesButton;
@property (readonly) NSPopUpButton *historyButton;
@property (readonly) SPComboPopupButton *runButton;

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

/// Detaches the grid, editor, bars and bindings from this controller (called by the tab when it closes or replaces it; also on dealloc).
- (void)invalidate;

@property (readonly) NSTextView *editor;
@property (readonly) NSTableView *resultsView;
/// The column names of the row set the grid shows, or nil when it shows none.
- (NSArray *)lastResultColumnNames;

/// The rows the grid shows, each an array of NSString (PostgreSQL's text format) or NSNull, or nil when it shows none.
- (NSArray *)lastResultRows;

/// How many rows the grid shows (0 when it shows none), without copying them.
- (NSUInteger)lastResultRowCount;

/// The status line (see the class comment): @"" before the first run and while a run runs.
@property (readonly, copy) NSString *statusText;

@end
