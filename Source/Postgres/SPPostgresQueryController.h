#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;

/**
 * The Query view of a PostgreSQL tab, laid out as MySQL's Query tab: the SQL editor on top, then a bar with
 * Run Current and Run All, the read-only results grid (an SPTableView) and a status line at the bottom. As
 * MySQL's: ⌘R runs Current and ⌥⌘R runs All, swapped by MySQL's "QueryPrimaryControlRunsAll" preference.
 * Built in code. Use on the main thread.
 *
 * Statements (see SPPostgresStatementSplitter) run in order on the tab's connection, on the main thread. The
 * grid shows the last row set the run returned, values in PostgreSQL's text format and NULL as MySQL's NULL
 * placeholder preference, in grey. The status line says "N rows" (a row set) or "N rows affected" (a command)
 * for the last statement. On an error the run stops: the grid keeps the run's earlier row set and the status
 * line says "Error in statement K: <server message>" (noting an aborted transaction). Statements are logged to
 * the console as MySQL's custom queries, and errors as MySQL's.
 *
 * The editor uses MySQL's query editor font preference, without smart quotes or dashes, with undo.
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSViewToolTipOwner>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Editor, run bar, grid and status line. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Runs every statement of the editor.
- (IBAction)runAllQueries:(id)sender;

/// Runs the statement at the cursor; with text selected, the statements of the selection (as MySQL's Run Selection).
- (IBAction)runCurrentQuery:(id)sender;

/// The editor font from MySQL's query editor font preference data (an archived NSFont), else the monospaced system font.
+ (NSFont *)editorFontFromPreferenceData:(NSData *)data;

/// Detaches the grid, editor and buttons from this controller (called by the tab when it closes or replaces it; also on dealloc).
- (void)invalidate;

@property (readonly) NSTextView *editor;
@property (readonly) NSTableView *resultsView;
/// The status line: @"" before the first run.
@property (readonly, copy) NSString *statusText;

@end
