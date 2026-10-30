#import <Cocoa/Cocoa.h>

@class SPPostgresCatalog;
@class SPPostgresTaskRunner;
@class SPPostgresSidebarController;
@class SPSplitView;

@protocol SPPostgresSidebarControllerDelegate <NSObject>
/// The selected schema or table changed (by the user or through the API).
- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)sidebar;
@optional
/// A reload (-reloadWithCatalog:, or a schema change by the user or -reloadSchema:) had catalog queries
/// that failed: called once per reload, with the first error. The lists that failed keep what they showed.
- (void)sidebar:(SPPostgresSidebarController *)sidebar didFailToLoadWithError:(NSError *)error;
/// The user is about to select another table or schema (click, keys or the schema pop-up): NO keeps the
/// current selection (e.g. an edit that can't be saved). Not asked for changes made through the API.
- (BOOL)sidebarShouldChangeSelection:(SPPostgresSidebarController *)sidebar;
/// "Duplicate Table…" was chosen in the outline's menu for `table`, a table of the selected schema.
- (void)sidebar:(SPPostgresSidebarController *)sidebar duplicateTableNamed:(NSString *)table;
/// "Rename Table…" was chosen in the outline's menu for `table`, a table of the selected schema.
- (void)sidebar:(SPPostgresSidebarController *)sidebar renameTableNamed:(NSString *)table;
/// "Add Sequence…" was chosen in the outline's menu: a sequence for `schema`, the selected schema.
- (void)sidebar:(SPPostgresSidebarController *)sidebar addSequenceInSchema:(NSString *)schema;
/// "Delete Sequence…" was chosen in the outline's menu for `sequence`, a sequence of the selected schema.
- (void)sidebar:(SPPostgresSidebarController *)sidebar deleteSequenceNamed:(NSString *)sequence;
/// "Install Extension…" was chosen in the outline's menu.
- (void)sidebarInstallExtension:(SPPostgresSidebarController *)sidebar;
/// "Drop Extension…" was chosen in the outline's menu for `name`, an installed extension.
- (void)sidebar:(SPPostgresSidebarController *)sidebar dropExtensionNamed:(NSString *)name;
/// The bar's Refresh button: reload the lists keeping the selection (the delegate decides whether it may run now).
- (void)sidebarRefresh:(SPPostgresSidebarController *)sidebar;
/// The bar's Add button ("Add new table"): the Add Table sheet for the selected schema.
- (void)sidebarAddTable:(SPPostgresSidebarController *)sidebar;
@end

/**
 * The left panel of a PostgreSQL tab: a schema picker on top, then an outline with the
 * TABLES, VIEWS and SEQUENCES of the selected schema and, last, the EXTENSIONS installed in the database.
 * Use on the main thread.
 *
 * Reloads run through taskRunner ("Reloading...", cancellable): with a background runner a reload method returns at
 * once and the end state it documents holds once the reload's task has completed (the runner idle). The catalog queries
 * run on the runner's thread, on a catalog of their own over the runner's connection; the lists, the pop-up and the
 * selection change on the main thread, all at once, in the order the reloads were asked for. A cancelled reload
 * changes nothing (the pop-up goes back to the shown schema) and reports no error. The completion variants are called
 * once the reload has been applied (or has failed or been cancelled), never after -invalidate.
 */
__attribute__((visibility("default")))
@interface SPPostgresSidebarController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

/// Loads the schemas (selecting the catalog's default schema), the tables and views, and the extensions, on an inline
/// runner over the catalog's connection (so they are loaded when this returns).
- (instancetype)initWithCatalog:(SPPostgresCatalog *)catalog;

/// Schema popup on top, outline below (over the information pane), MySQL's table list bar along the bottom. Built
/// once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the tables, views and sequences of `schema` and selects it in the popup. Clears the selection of a table,
/// view or sequence; a selected extension (the database's, not the schema's) stays selected if it is still listed.
/// If the tables or views can't be loaded, the schema, lists and selection stay as they were.
- (void)reloadSchema:(NSString *)schema;
/// -reloadSchema:, then completion (loaded: NO if a list failed or the reload was cancelled, the lists as they were).
- (void)reloadSchema:(NSString *)schema completion:(void (^)(BOOL loaded))completion;

/**
 * Shows the tables, views and sequences of `schema` (as -reloadSchema:) and selects its sequence `sequence`, the
 * delegate hearing of one selection change at the end (none if the selection is the same), not of the empty
 * selection on the way. A sequence that isn't listed leaves nothing selected.
 */
- (void)reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence;
/// The same, then completion (loaded: NO if a list failed or the reload was cancelled).
- (void)reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence completion:(void (^)(BOOL loaded))completion;

/// Switches to another catalog (another database): reloads schemas, extensions and the default schema, with nothing
/// selected.
/// A list that can't be loaded keeps what it showed.
- (void)reloadWithCatalog:(SPPostgresCatalog *)catalog;
/// The same, then completion (loaded: NO if a list failed or the reload was cancelled). The queries run on taskRunner's
/// connection, which must be the catalog's (an owner that sets taskRunner sets one over the new connection first; the
/// default inline runner follows the catalog by itself).
- (void)reloadWithCatalog:(SPPostgresCatalog *)catalog completion:(void (^)(BOOL loaded))completion;

/**
 * Another database's catalog (a database switch), as -reloadWithCatalog:completion: but with no Cancel button (no cancel
 * title), and keeping none of the lists shown before: a list that can't be loaded (or every list, if the reload is
 * cancelled all the same) is shown empty, a schema list that fails leaving no schema selected. Failures are reported to
 * the delegate as for any reload (a cancel isn't).
 */
- (void)reloadWithNewCatalog:(SPPostgresCatalog *)catalog completion:(void (^)(BOOL loaded))completion;

/**
 * Reloads the schemas, the extensions and the shown schema's tables, views and sequences (after the Query view
 * changed them), keeping the selected table, sequence or extension if it is still listed. A schema that is gone gives way to the default one.
 * The delegate hears of a selection change only if the selection ends up different.
 */
- (void)reloadKeepingSelection;
/// The same, then completion (loaded: NO if a list failed or the reload was cancelled). The selection kept is the one
/// shown when the reload is applied.
- (void)reloadKeepingSelection:(void (^)(BOOL loaded))completion;

/// @[@"TABLES", @"VIEWS", @"SEQUENCES", @"EXTENSIONS"]: Extensions is always last.
- (NSArray *)sectionTitles;

/// Names listed under a section (tables, views, sequences or extension names), in display order.
- (NSArray *)itemTitlesInSection:(NSString *)sectionTitle;

/// Selects a table or view of the selected schema in the outline; NO if it is not listed. nil clears the selection.
- (BOOL)selectTableNamed:(NSString *)name;

/// Selects a sequence of the selected schema in the outline; NO if it is not listed. nil clears the selection.
- (BOOL)selectSequenceNamed:(NSString *)name;

/// Selects an installed extension in the outline; NO if it is not listed. nil clears the selection.
- (BOOL)selectExtensionNamed:(NSString *)name;

/**
 * The outline's right-click menu: "Duplicate Table…" and "Rename Table…", enabled on a table (not a view or
 * extension). They act on the row that was right-clicked, or else on the selected one, through the delegate.
 */
@property (readonly) NSMenu *tableMenu;

/**
 * The outline's right-click menu on a sequence, the SEQUENCES header or empty space: "Add Sequence…" (for the
 * selected schema) and "Delete Sequence…" (on a sequence only: the row that was right-clicked, or else the selected
 * one; hidden elsewhere), through the delegate.
 */
@property (readonly) NSMenu *sequenceMenu;

/**
 * The outline's right-click menu on an extension, the EXTENSIONS header or empty space below it: "Install
 * Extension…" (always) and "Drop Extension…" (on an extension only: the row that was right-clicked, or else the
 * selected one; hidden elsewhere), through the delegate.
 */
@property (readonly) NSMenu *extensionMenu;

/// The right-click menu for a row of the outline (-1: empty space, which is below EXTENSIONS, the last section):
/// sequenceMenu on a sequence or the SEQUENCES header, extensionMenu on an extension, the EXTENSIONS header or
/// empty space, else tableMenu.
- (NSMenu *)menuForRow:(NSInteger)row;

@property (readonly) NSString *selectedSchema;
/// The schema a schema reload (-reloadSchema:…) has been asked for and not yet completed, nil when none is queued: the
/// schema about to be shown.
@property (readonly, copy) NSString *pendingSchema;

/// The selected table or view of the selected schema, or nil (also while a sequence or extension is selected).
@property (readonly) NSString *selectedTableName;

/// The selected sequence of the selected schema, or nil (also while a table, view or extension is selected).
@property (readonly) NSString *selectedSequenceName;

/// The selected extension, or nil (also while a table, view or sequence is selected).
@property (readonly) NSString *selectedExtensionName;

/// The selection is listed under TABLES (a table or partitioned table), not VIEWS.
@property (readonly) BOOL selectionIsTable;

/// The first catalog error of the last reload (whose failed lists kept what they showed), or nil.
@property (readonly) NSError *lastError;

@property (assign) id<SPPostgresSidebarControllerDelegate> delegate;

/// Runs the reloads (default: an inline runner on the catalog's connection, so a reload has been applied when its
/// method returns). With a background runner (the tab's, from Stage 8 Task 7) a reload returns at once.
@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;

#pragma mark - Bottom bar (MySQL's table list bar, DBView.xib)

/// "Add new table" (button_add): -addTable:, enabled while actionsEnabled and the delegate implements -sidebarAddTable:.
@property (readonly) NSButton *addButton;
/// The gear: a pull-down whose item 0 is the hidden button_action image item.
@property (readonly) NSPopUpButton *gearButton;
/// "Refresh table list" (button_refresh): -refreshTables:.
@property (readonly) NSButton *refreshButton;
/// Shows or hides the information pane below the outline (button_pane_hide / button_pane_show): -toggleInfoPane:.
/// On (button_pane_show) while the pane is collapsed. Always enabled.
@property (readonly) NSButton *infoToggleButton;
/// The bar's handle (button_bar_handle) at its right end: an extra drag handle for the owner's divider.
@property (readonly) NSView *splitHandleView;
/// The outline (top) over infoPaneContainer (bottom, collapsible: subview 1, toggled by infoToggleButton).
@property (readonly) SPSplitView *infoSplitView;
/// The information pane's container, 166 pt tall.
@property (readonly) NSView *infoPaneContainer;

/// Where the information pane's collapsed state (SPTableInformationPanelCollapsed) is read and stored (default:
/// standardUserDefaults). Setting it applies the state it stores (as a view built with it would start).
@property (nonatomic, retain) NSUserDefaults *defaults;

/// Whether Add, the gear and Refresh are enabled (NO while the owner is processing; default YES). The info toggle
/// stays enabled.
@property (nonatomic) BOOL actionsEnabled;

/// Refresh: the delegate's -sidebarRefresh: (else -reloadKeepingSelection).
- (IBAction)refreshTables:(id)sender;
/// Collapses or expands the information pane, storing the new state in defaults (as -[SPTablesList togglePaneCollapse:]).
- (IBAction)toggleInfoPane:(id)sender;
/// Add: the delegate's -sidebarAddTable:.
- (IBAction)addTable:(id)sender;

/// Detaches the outline and popup from this controller, and drops the reloads still to come (no completion is called
/// after this). Called by the window on close; also on dealloc.
- (void)invalidate;

@end
