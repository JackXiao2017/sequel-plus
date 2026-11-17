#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;

/**
 * The Table Info view of a PostgreSQL tab, laid out as MySQL's Table Info tab: a grid of labels (Type, Owner,
 * Rows, Table size, Index size, Total size), an editable Comments box, and the read-only, monospaced Create
 * syntax (SPPostgresCreateStatement) in MySQL's query editor font. Built in code. Use on the main thread.
 *
 * Owner is a pop-up of the roles the table can be given to when the connected user may change it (see
 * -[SPPostgresTableStructure ownerChoices:]); otherwise it is plain text.
 *
 * Rows is the planner's estimate, `~N`, or `Unknown (not analyzed)` when there is none. The sizes are written
 * by +[SPPostgresCatalog stringForSize:], as the table list writes them.
 *
 * The comment is saved when its edit ends (the box loses the focus, or -commitPendingEdits): COMMENT ON … IS
 * through -[SPPostgresTableStructure setTableComment:error:] (SPPostgresRunStructureChange). If that fails, an
 * alert shows the server's message, the typed text stays, and the edit doesn't end (the box keeps the focus;
 * -commitPendingEdits returns NO), so the tab doesn't move on; Escape in the box puts the saved comment back.
 *
 * Loads (-showTable:inSchema:, -reload) run through taskRunner: with the tab's background runner they return at once
 * and the end state they document holds once the runner is idle. A cancelled load shows no alert: a cancelled table
 * switch leaves the view empty and stale (a reload, or the tab showing it again, loads it); a cancelled reload keeps
 * what was shown. Saving the comment runs on the main thread and is refused (NSBeep; -commitPendingEdits returns NO,
 * the text stays) while the runner is busy.
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

/// The Owner pop-up's action: ALTER … OWNER TO the chosen role, then reads the information again. Refused while the
/// runner is busy; a failure is shown as an alert. The pop-up goes back to the server's owner when it isn't changed.
- (IBAction)changeOwner:(id)sender;

/// Saves a comment edit in progress. YES when there was none or it was saved; NO (after the alert) if it failed.
- (BOOL)commitPendingEdits;

/// Detaches the view's controls and drops the presenters (called by the tab on close or replace; also on dealloc).
- (void)invalidate;

@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;

@property (readonly) NSTextField *typeField;
@property (readonly) NSTextField *ownerField;
/// The owner as a pop-up of the roles it can be given to, shown instead of ownerField when the connected user may
/// change the owner (a superuser, or a user with the owning role's privileges).
@property (readonly) NSPopUpButton *ownerPopup;
/// YES when the owner pop-up is shown.
@property (readonly) BOOL canChangeOwner;
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

/// Runs the loads (default: an inline runner on the connection, so a load has finished when its method returns).
@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;
/// A table switch was cancelled before the table loaded: the view is empty until a reload or the next show loads it.
@property (readonly, getter=isStale) BOOL stale;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Called after the comment was changed (the tab marks the Structure view stale).
@property (copy) void (^tableInfoDidChange)(void);

@end
