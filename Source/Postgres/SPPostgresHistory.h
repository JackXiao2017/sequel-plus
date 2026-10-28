#import <Foundation/Foundation.h>

/**
 * The Table History of a PostgreSQL tab (the toolbar's back/forward control and View > Back/Forward In
 * History): the places the user has been, each a database, schema, table (absent when none was selected)
 * and pane (@"content" or @"query").
 *
 * Recording the place that is already current is ignored; recording after going back drops the entries
 * ahead (as a browser does). As MySQL's history, at most fifty entries are kept, the oldest going first.
 * Entries are dictionaries with the keys @"database", @"schema", @"table" (when there is one) and @"pane".
 */
__attribute__((visibility("default")))
@interface SPPostgresHistory : NSObject

- (void)recordDatabase:(NSString *)db schema:(NSString *)schema table:(NSString *)table pane:(NSString *)pane;

/// A relation was renamed: the entries naming it (in that database and schema) name it by its new name, so going
/// back to them finds it.
- (void)renameTable:(NSString *)oldName to:(NSString *)newName inDatabase:(NSString *)db schema:(NSString *)schema;

/// Moves back one entry and returns it, or returns nil (staying put) at the oldest entry.
- (NSDictionary *)goBack;

/// Moves forward one entry and returns it, or returns nil (staying put) at the newest entry.
- (NSDictionary *)goForward;

@property (readonly) BOOL canGoBack;
@property (readonly) BOOL canGoForward;

/// The current entry, or nil before anything was recorded.
@property (readonly) NSDictionary *currentEntry;

@end
