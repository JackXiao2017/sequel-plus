#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresConstraintDefinition;
@class SPPostgresTaskRunner;

/**
 * The Relations view of a PostgreSQL tab, laid out as MySQL's Relations tab: one grid of the table's foreign keys
 * (Name, Columns, References as schema.table, Referenced Columns, On Update, On Delete) with a bottom bar (+, −,
 * refresh, "Relations for table: <name>"). Built in code. Use on the main thread.
 *
 * + opens the constraint sheet in FOREIGN KEY mode (SPPostgresConstraintSheet) and adds the key at once; − asks,
 * then drops it. Each change runs through SPPostgresTableStructure (SPPostgresRunStructureChange); on error an alert
 * shows the server's message and the grid reloads.
 *
 * A non-empty emptyStateText (set by the tab, e.g. for a view) hides the grid and its bar and shows that text.
 *
 * Loads (-showTable:inSchema:, -reload, Refresh) run through taskRunner: with the tab's background runner they return
 * at once and the end state they document holds once the runner is idle. A cancelled load shows no alert: a cancelled
 * table switch leaves the grid empty and the view stale (Refresh, or the tab showing it again, loads it); a cancelled
 * reload keeps what was shown. + and − run on the main thread and are refused (NSBeep) while the runner is busy.
 */
__attribute__((visibility("default")))
@interface SPPostgresRelationsController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The grid and its bar. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the foreign keys of schema.table (a nil table empties the grid). A read error is shown as an alert and
/// in the bottom bar.
- (void)showTable:(NSString *)table inSchema:(NSString *)schema;

/// Reads the foreign keys again (keeping the selection where it still fits).
- (void)reload;

/// Detaches the grid and buttons, ends a sheet still up, and drops the presenters (called by the tab on close or
/// replace; also on dealloc).
- (void)invalidate;

- (IBAction)addRelation:(id)sender;
/// Drops the selected foreign key after confirmation (see confirmationPresenter).
- (IBAction)removeRelation:(id)sender;
- (IBAction)refresh:(id)sender;

@property (readonly) NSTableView *relationsView;
@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;
/// The bottom bar's text: @"Relations for table: <name>", the read error, or @"".
@property (readonly, copy) NSString *noticeText;
/// Shown instead of the grid when not empty (e.g. @"Relations aren't available for views.").
@property (nonatomic, copy) NSString *emptyStateText;

/// Runs the loads (default: an inline runner on the connection, so a load has finished when its method returns).
@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;
/// A table switch was cancelled before the table loaded: the grid is empty until Refresh or the next show loads it.
@property (readonly, getter=isStale) BOOL stale;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm a deletion (first button: delete); call completion exactly once. nil (the default) shows a
/// sheet on the view's window.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

/// Shows the add-foreign-key sheet for the table's columns; call completion once with the definition or nil.
/// nil (the default) shows SPPostgresConstraintSheet (FOREIGN KEY) on the view's window.
@property (copy) void (^constraintSheetPresenter)(NSArray *columnNames, void (^completion)(SPPostgresConstraintDefinition *definitionOrNil));

/// Called after each change that succeeded (a foreign key added or dropped).
@property (copy) void (^relationsDidChange)(void);

@end
