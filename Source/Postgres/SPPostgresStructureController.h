#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresConstraintDefinition;

/**
 * The Structure view of a PostgreSQL tab, laid out as MySQL's Structure tab: the columns grid on top (Name, Type,
 * Nullable, Default, Auto, Comment) with a bottom bar (+ / − for columns, refresh), and below it the Indexes grid
 * (Name, Columns, Unique, Method) and the Constraints grid (Name, Type, Definition), each with + / −. Built in code.
 * Use on the main thread.
 *
 * Every edited cell runs its one change at once (rename, type, nullable, default, comment) through
 * SPPostgresTableStructure, then the grids reload; on error an alert shows the server's message and the grids
 * reload. A type change the data can't take goes to usingPresenter, retried with the USING expression given until
 * it succeeds or is cancelled.
 *
 * + appends a draft column (column_N, text, nullable), saved with ADD COLUMN when Return is pressed or the
 * selection leaves it, discarded with Esc; a draft that fails to save stays for correction.
 *
 * A view or materialized view shows its columns read-only, with the bottom-bar text "Views can't be edited here.";
 * a generated column's Type and Default are read-only.
 */
__attribute__((visibility("default")))
@interface SPPostgresStructureController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The three grids and their bars. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the structure of schema.table (a nil table empties the grids). A draft column of the previous table is
/// saved first (an alert says so if it can't be). If the structure can't be read (e.g. the relation is gone), the
/// error is shown, as an alert and in the bottom bar.
- (void)showTable:(NSString *)table inSchema:(NSString *)schema;

/// Reads the structure again (keeping a draft column and the selection where it still fits).
- (void)reload;

/// Ends a cell edit in progress and saves a draft column. NO if either can't be done (the draft stays, and the
/// error is shown): the caller should not move away.
- (BOOL)commitPendingEdits;

/// Detaches the grids and controls from this controller and drops the presenters (called by the tab on close; also on dealloc).
- (void)invalidate;

- (IBAction)addColumn:(id)sender;
/// A draft is discarded; a column is dropped after confirmation (see confirmationPresenter).
- (IBAction)removeColumn:(id)sender;
- (IBAction)refresh:(id)sender;
- (IBAction)addIndex:(id)sender;
- (IBAction)removeIndex:(id)sender;
- (IBAction)addConstraint:(id)sender;
- (IBAction)removeConstraint:(id)sender;

@property (readonly) NSTableView *columnsView, *indexesView, *constraintsView;
@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;
/// The shown relation is a table or partitioned table (its structure can be changed here).
@property (readonly) BOOL editable;
/// A + column not saved yet (the last row of the columns grid).
@property (readonly) BOOL hasDraftColumn;
/// The bottom bar's text: @"Views can't be edited here.", the read error, or @"".
@property (readonly, copy) NSString *noticeText;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm a deletion (first button: delete); call completion exactly once. The completion is a heap block
/// that stays valid until it is called. nil (the default) shows a sheet on the view's window.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

/// Offers a USING expression after a type change failed: serverMessage is the server's error, prefilled
/// @"\"<col>\"::<new type>" (or the expression last tried). Call completion once with the expression to retry, or
/// nil to give up (the column keeps its type). nil (the default) shows a sheet on the view's window.
@property (copy) void (^usingPresenter)(NSString *serverMessage, NSString *prefilled, void (^completion)(NSString *usingOrNil));

/// Shows the add-index (kind @"INDEX") or add-constraint sheet for the table's columns; call completion once with
/// the definition or nil. nil (the default) shows SPPostgresConstraintSheet on the view's window.
@property (copy) void (^constraintSheetPresenter)(NSString *kind, NSArray *columnNames, void (^completion)(SPPostgresConstraintDefinition *definitionOrNil));

/// Called after each change that succeeded; columnsChanged unless only a comment changed.
@property (copy) void (^structureDidChange)(BOOL columnsChanged);

@end
