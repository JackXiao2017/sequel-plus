#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;

/**
 * The Query view of a PostgreSQL tab, laid out as MySQL's Query tab: the SQL editor on top, then a bar with
 * Run Current and Run All, the read-only results grid (an SPTableView) and a status line at the bottom. As
 * MySQL's: ⌘R runs Current and ⌥⌘R runs All, swapped by MySQL's "QueryPrimaryControlRunsAll" preference.
 * Built in code. Use on the main thread.
 *
 * Statements (see SPPostgresStatementSplitter) run in order on the tab's connection, in one task of taskRunner. The
 * grid shows the last row set the run returned, values in PostgreSQL's text format and NULL as MySQL's NULL
 * placeholder preference, in grey. The status line says "N rows" (a row set) or "N rows affected" (a command)
 * for the last statement. On an error the run stops: the grid keeps the run's earlier row set and the status
 * line says "Error in statement K: <server message>" (noting an aborted transaction). Statements are logged to
 * the console as MySQL's custom queries, and errors as MySQL's.
 *
 * A run is described as MySQL's ("Running query..." / "Running query K of N...", per statement) and can be
 * stopped ("Stop query" / "Stop queries"): the status line then says "Query cancelled.", the grid shows the
 * last row set returned before the cancel, and what ran before it is still reported (runDidChangeDatabase).
 * While the runner is busy, ⌘R, ⌥⌘R and the run buttons do nothing (NSBeep). The editor's text is read on the
 * main thread when the run is asked for; the statements run on the runner's thread. The tests' statement hook
 * (-setStatementWillRunHook:, a test seam) is called on that thread, before each statement.
 *
 * The editor uses MySQL's query editor font preference, without smart quotes or dashes, with undo.
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSViewToolTipOwner>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Runs the statements (default: an inline runner on the connection, so a run has finished when its action returns).
/// With a background runner (the tab's, from Stage 8 Task 7) an action returns at once and the run is applied when it
/// completes; the documented end state then holds once the runner is idle.
@property (retain) SPPostgresTaskRunner *taskRunner;

/// Editor, run bar, grid and status line. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Runs every statement of the editor.
- (IBAction)runAllQueries:(id)sender;

/// Runs the statement at the cursor; with text selected, the statements of the selection (as MySQL's Run Selection).
- (IBAction)runCurrentQuery:(id)sender;

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

/// Detaches the grid, editor and buttons from this controller (called by the tab when it closes or replaces it; also on dealloc).
- (void)invalidate;

@property (readonly) NSTextView *editor;
@property (readonly) NSTableView *resultsView;
/// The column names of the row set the grid shows, or nil when it shows none.
- (NSArray *)lastResultColumnNames;

/// The rows the grid shows, each an array of NSString (PostgreSQL's text format) or NSNull, or nil when it shows none.
- (NSArray *)lastResultRows;

/// How many rows the grid shows (0 when it shows none), without copying them.
- (NSUInteger)lastResultRowCount;

/// The status line: @"" before the first run.
@property (readonly, copy) NSString *statusText;

@end
