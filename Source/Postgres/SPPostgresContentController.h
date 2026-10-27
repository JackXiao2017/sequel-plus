#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;

/**
 * The Content view of a PostgreSQL tab, laid out as MySQL's Content tab: a filter bar on top (column,
 * comparison, value, Filter), the rows in an SPTableView, and a bottom bar with add, delete and refresh
 * buttons, the row count, the read-only reason (if any) and previous/next page buttons. Built in code.
 * Use on the main thread.
 *
 * Rows come from SPPostgresTableData as PostgreSQL text. The page size is MySQL's "Limit results"
 * preference (unlimited when it is off); NULL is shown as MySQL's NULL placeholder preference, in grey.
 * Header clicks sort ascending, then descending. Cells are edited as text: ending an edit updates the row
 * on the server. Tables without a primary key, views and generated columns are never edited.
 *
 * A data-layer error is shown as an alert (see alertPresenter); the grid keeps the rows it showed.
 */
__attribute__((visibility("default")))
@interface SPPostgresContentController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Filter bar, grid and bottom bar. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the rows of schema.table from the first page, unfiltered and unsorted. A nil table empties the grid.
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

/// Shows errors. nil (the default) shows them as sheets on the view's window. Replaceable (the tab routes them through its own).
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm a deletion; call completion exactly once. nil (the default) shows a sheet on the view's window.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

@end
