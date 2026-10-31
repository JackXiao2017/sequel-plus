#import <Cocoa/Cocoa.h>

@class SPPostgresCatalog;

/**
 * A bordered, header-less checkbox list (columns @"check" and @"name"), shared by the Export and Transfer sheets.
 *
 * rows holds NSStrings and items. With groupsByFirstElement YES an NSString row is a group row (bold, no checkbox)
 * and an item is @[group, name] shown as its name; with NO every row is an NSString item. Use on the main thread.
 *
 * The table view's dataSource and delegate don't retain the list: its owner must keep it alive while the table view
 * exists (and should clear checksChanged when it must not be called back).
 */
__attribute__((visibility("default")))
@interface SPPostgresCheckList : NSObject <NSTableViewDataSource, NSTableViewDelegate>

/// Adds the list's scroll view to `view` at `frame`.
- (instancetype)initWithFrame:(NSRect)frame inView:(NSView *)view;

@property (readonly) NSTableView *tableView;
@property (copy) NSArray *rows;
@property BOOL groupsByFirstElement;
/// The checked items, in row order.
@property (readonly) NSArray *checkedItems;
- (void)setChecked:(BOOL)checked item:(id)item;
/// Called after the user or setChecked:item: changes a check.
@property (copy) void (^checksChanged)(void);

/// The schema group rows and @[schema, table] items of the catalog's database (schemas without tables left out).
/// A failure is reported through error (the first one); a schema whose tables can't be read is skipped.
+ (NSArray *)groupedRowsForCatalog:(SPPostgresCatalog *)catalog error:(NSError **)error;

/// The rows for the given schema names (what groupedRowsForCatalog:error: builds from the catalog's own); the first
/// failure is stored in error unless it already holds one.
+ (NSArray *)groupedRowsForSchemas:(NSArray *)schemas inCatalog:(SPPostgresCatalog *)catalog error:(NSError **)error;

@end
