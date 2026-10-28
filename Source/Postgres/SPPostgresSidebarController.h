#import <Cocoa/Cocoa.h>

@class SPPostgresCatalog;
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
@end

/**
 * The left panel of a PostgreSQL tab: a schema picker on top, then an outline with the
 * TABLES and VIEWS of the selected schema and, last, the EXTENSIONS installed in the database.
 * Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresSidebarController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

/// Loads the schemas (selecting the catalog's default schema), the tables and views, and the extensions.
- (instancetype)initWithCatalog:(SPPostgresCatalog *)catalog;

/// Schema popup on top, outline below. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the tables and views of `schema` and selects it in the popup. Clears the table selection.
/// If the tables or views can't be loaded, the schema, lists and selection stay as they were.
- (void)reloadSchema:(NSString *)schema;

/// Switches to another catalog (another database): reloads schemas, extensions and the default schema.
/// A list that can't be loaded keeps what it showed.
- (void)reloadWithCatalog:(SPPostgresCatalog *)catalog;

/**
 * Reloads the schemas, the extensions and the shown schema's tables and views (after the Query view changed
 * them), keeping the selected table if it is still listed. A schema that is gone gives way to the default one.
 * The delegate hears of a selection change only if the selection ends up different.
 */
- (void)reloadKeepingSelection;

/// @[@"TABLES", @"VIEWS", @"EXTENSIONS"]: Extensions is always last.
- (NSArray *)sectionTitles;

/// Names listed under a section (tables, views or extension names), in display order.
- (NSArray *)itemTitlesInSection:(NSString *)sectionTitle;

/// Selects a table or view of the selected schema in the outline; NO if it is not listed. nil clears the selection.
- (BOOL)selectTableNamed:(NSString *)name;

/**
 * The outline's right-click menu: "Duplicate Table…" and "Rename Table…", enabled on a table (not a view or
 * extension). They act on the row that was right-clicked, or else on the selected one, through the delegate.
 */
@property (readonly) NSMenu *tableMenu;

@property (readonly) NSString *selectedSchema;

/// The selected table or view of the selected schema, or nil.
@property (readonly) NSString *selectedTableName;

/// The selection is listed under TABLES (a table or partitioned table), not VIEWS.
@property (readonly) BOOL selectionIsTable;

/// The first catalog error of the last reload (whose failed lists kept what they showed), or nil.
@property (readonly) NSError *lastError;

@property (assign) id<SPPostgresSidebarControllerDelegate> delegate;

/// Detaches the outline and popup from this controller (called by the window on close; also on dealloc).
- (void)invalidate;

@end
