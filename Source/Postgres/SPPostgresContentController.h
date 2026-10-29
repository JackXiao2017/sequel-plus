#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;

/**
 * The Content view of a PostgreSQL tab, laid out as MySQL's Content tab: a filter bar on top (column,
 * comparison, value, Filter), the rows in an SPTableView, and a bottom bar with add, delete and refresh
 * buttons, the row count, the read-only reason (if any) and previous/next page buttons. Built in code.
 * Use on the main thread.
 *
 * Rows come from SPPostgresTableData as PostgreSQL text. The page size is MySQL's "Limit results"
 * preference (unlimited when it is off); NULL is shown as MySQL's NULL placeholder preference, in grey.
 * Header clicks sort ascending, then descending, from the first page. Cells are edited as text: ending an edit updates the row
 * on the server. Tables without a primary key, views and generated columns are never edited.
 *
 * A data-layer error is shown as an alert (see alertPresenter); the grid keeps the rows it showed.
 *
 * Loads run through taskRunner: with the tab's background runner a load method returns at once and the end state it
 * documents holds once the runner is idle; a cancelled load shows no alert and keeps what was shown (a cancelled
 * table switch shows the new table's columns, if they came, without rows; Refresh loads it). The short writes (a cell
 * edit, add, delete) run on the main thread and are refused (NSBeep) while the runner is busy.
 */
__attribute__((visibility("default")))
@interface SPPostgresContentController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Filter bar, grid and bottom bar. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the rows of schema.table from the first page, unfiltered and unsorted. A nil table empties the grid.
/// If the rows can't be loaded the error is shown and the grid is empty (only Refresh, to retry, is enabled).
- (void)showTable:(NSString *)table inSchema:(NSString *)schema;

/// Reloads the current page (keeping the filter and sort). On failure the rows stay and the error is shown.
- (void)reload;

/// Detaches the grid and controls from this controller and drops the presenters (called by the tab on close; also on dealloc).
- (void)invalidate;

- (IBAction)addRow:(id)sender;
/// Asks for confirmation (see confirmationPresenter), then deletes the selected rows.
- (IBAction)removeRows:(id)sender;
- (IBAction)refresh:(id)sender;
- (IBAction)nextPage:(id)sender;
- (IBAction)previousPage:(id)sender;
/// Applies the filter bar (an empty value, except for IS NULL / IS NOT NULL, removes the filter).
- (IBAction)applyFilter:(id)sender;

@property (readonly) NSTableView *tableView;
@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;

/// 1-based.
@property (readonly) NSUInteger currentPage;
@property (readonly) NSUInteger pageCount;

/// The bottom bar's row count, as MySQL's (e.g. @"30 rows in table", @"Rows 1 - 7 of 30 from table").
@property (readonly, copy) NSString *countText;
/// The bottom bar's notice: why the rows can't be edited, or @"".
@property (readonly, copy) NSString *noticeText;

/// Runs the loads (default: an inline runner on the connection, so a load has finished when its method returns).
/// With a background runner (the tab's, from Stage 8 Task 7) a load returns at once and is applied when it completes.
@property (retain) SPPostgresTaskRunner *taskRunner;

/// Shows errors. nil (the default) shows them as sheets on the view's window. Replaceable (the tab routes them through its own).
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm a deletion; call completion exactly once (later calls are ignored). The completion is a heap
/// block that stays valid until it is called, so a presenter may store it (copying or retaining it is not needed).
/// nil (the default) shows a sheet on the view's window.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

@end
