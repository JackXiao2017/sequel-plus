#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;

/**
 * The Table Information pane under a PostgreSQL tab's table list, as MySQL's (SPTableInfo's info table in DBView.xib): a
 * single-column source-list table view in a borderless scroll view, its first row a 25 pt group header, the other
 * rows (not selectable) indented with the table-property image.
 *
 * - A table (table, partitioned table, foreign table): "TABLE INFORMATION"; a view or materialized view: "VIEW
 *   INFORMATION". Then "type: …", "owner: …", for tables and materialized views "rows: ~N" (or "rows: unknown"),
 *   "size: …", "index size: …", "total size: …", and "comment: …" when there is one.
 * - Nothing (or a sequence or extension): "INFORMATION"; several relations: "INFORMATION", "multiple selection".
 * - A failed read: the header and "error occurred".
 *
 * The facts are read by -[SPPostgresTableStructure tableInfo:] in a task of taskRunner, through an SPPostgresPaneLoader:
 * only the latest read is shown. Main thread only.
 */
__attribute__((visibility("default")))
@interface SPPostgresSidebarInfoPane : NSObject <NSTableViewDataSource, NSTableViewDelegate>

/// The pane's view (frame's size, autoresizing): the scroll view holding the table view.
- (instancetype)initWithFrame:(NSRect)frame;

@property (readonly) NSView *view;
/// The table view (for tests).
@property (readonly) NSTableView *tableView;

/// Runs the reads. Until one is set, an inline runner on the connection of the last -showRelation:… call.
@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;

/// Reads and shows a table or view of schema ("INFORMATION" until the read has completed, and if it is cancelled).
- (void)showRelation:(NSString *)name inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection;
/// The same, isView giving the header shown if the read fails.
- (void)showRelation:(NSString *)name inSchema:(NSString *)schema view:(BOOL)isView connection:(PGPostgresConnection *)connection;
/// "INFORMATION" (a read in progress is dropped; nothing is queued).
- (void)showNothing;
/// "INFORMATION", "multiple selection" (a read in progress is dropped; nothing is queued).
- (void)showMultipleSelection;
/**
 * The comment of schema.name is now comment (nil or empty: none): the "comment:" line of the facts shown for that
 * relation is updated, added or removed. Nothing is read; another relation shown (or none, or no facts) is left as is.
 */
- (void)setComment:(NSString *)comment forRelation:(NSString *)name inSchema:(NSString *)schema;
/// No read is applied after this; the table view is detached.
- (void)invalidate;

/// The rows shown, header first (for tests).
@property (readonly) NSArray<NSString *> *lines;

@end
