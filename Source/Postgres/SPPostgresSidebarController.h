#import <Cocoa/Cocoa.h>

@class SPPostgresCatalog;
@class SPPostgresTaskRunner;
@class SPPostgresSidebarController;

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

/// Schema popup on top, outline below. Built once; sized by the caller (autoresizes).
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
@property (retain) SPPostgresTaskRunner *taskRunner;

/// Detaches the outline and popup from this controller, and drops the reloads still to come (no completion is called
/// after this). Called by the window on close; also on dealloc.
- (void)invalidate;

@end
