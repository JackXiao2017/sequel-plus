#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;

/**
 * The Table Info view of a PostgreSQL tab, laid out as MySQL's Table Info tab: a grid of labels (Type, Owner,
 * Rows, Table size, Index size, Total size), an editable Comments box, and the read-only, monospaced Create
 * syntax (SPPostgresCreateStatement) in MySQL's query editor font. Built in code. Use on the main thread.
 *
 * Rows is the planner's estimate, `~N`, or `Unknown (not analyzed)` when there is none. The sizes are the
 * server's pg_size_pretty.
 *
 * The comment is saved when its edit ends (the box loses the focus, or -commitPendingEdits): COMMENT ON … IS
 * through -[SPPostgresTableStructure setTableComment:error:] (SPPostgresRunStructureChange). If that fails, an
 * alert shows the server's message, the typed text stays, and the edit doesn't end (the box keeps the focus;
 * -commitPendingEdits returns NO), so the tab doesn't move on; Escape in the box puts the saved comment back.
 */
__attribute__((visibility("default")))
@interface SPPostgresTableInfoController : NSObject <NSTextViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The labels, comment and create syntax. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows schema.table's information (a nil table empties the view). A read error is shown as an alert and in
/// the bottom line.
- (void)showTable:(NSString *)table inSchema:(NSString *)schema;

/// Reads the information again (dropping a comment edit that wasn't saved).
- (void)reload;

/// Saves a comment edit in progress. YES when there was none or it was saved; NO (after the alert) if it failed.
- (BOOL)commitPendingEdits;

/// Detaches the view's controls and drops the presenters (called by the tab on close or replace; also on dealloc).
- (void)invalidate;

@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;

@property (readonly) NSTextField *typeField;
@property (readonly) NSTextField *ownerField;
@property (readonly) NSTextField *rowsField;
@property (readonly) NSTextField *tableSizeField;
@property (readonly) NSTextField *indexSizeField;
@property (readonly) NSTextField *totalSizeField;
/// The table's comment, editable while a table or view is shown.
@property (readonly) NSTextView *commentView;
/// The CREATE statement, read-only.
@property (readonly) NSTextView *createSyntaxView;
/// The bottom line: the read error, or @"".
@property (readonly, copy) NSString *noticeText;
/// YES while the comment box holds text that isn't saved.
@property (readonly) BOOL hasPendingComment;

/// Seconds a comment change waits for a lock held elsewhere before it fails (default 5).
@property (nonatomic) NSTimeInterval lockTimeout;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Called after the comment was changed (the tab marks the Structure view stale).
@property (copy) void (^tableInfoDidChange)(void);

@end
