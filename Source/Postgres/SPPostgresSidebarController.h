#import <Cocoa/Cocoa.h>

@class SPPostgresCatalog;
@class SPPostgresSidebarController;

@protocol SPPostgresSidebarControllerDelegate <NSObject>
/// The selected schema or table changed (by the user or through the API).
- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)sidebar;
@end

/**
 * The left panel of the PostgreSQL window: a schema picker on top, then an outline with the
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
- (void)reloadSchema:(NSString *)schema;

/// Switches to another catalog (another database): reloads schemas, extensions and the default schema.
- (void)reloadWithCatalog:(SPPostgresCatalog *)catalog;

/// @[@"TABLES", @"VIEWS", @"EXTENSIONS"]: Extensions is always last.
- (NSArray *)sectionTitles;

/// Names listed under a section (tables, views or extension names), in display order.
- (NSArray *)itemTitlesInSection:(NSString *)sectionTitle;

/// Selects a table or view of the selected schema in the outline; NO if it is not listed.
- (BOOL)selectTableNamed:(NSString *)name;

@property (readonly) NSString *selectedSchema;

/// The selected table or view of the selected schema, or nil.
@property (readonly) NSString *selectedTableName;

/// The error of the last failed catalog query (lists that failed to load are shown empty), or nil.
@property (readonly) NSError *lastError;

@property (assign) id<SPPostgresSidebarControllerDelegate> delegate;

/// Detaches the outline and popup from this controller (called by the window on close; also on dealloc).
- (void)invalidate;

@end
