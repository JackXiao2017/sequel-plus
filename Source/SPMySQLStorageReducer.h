#import <Foundation/Foundation.h>

/**
 * Runs one statement on the MySQL connection: the result's rows (each a dictionary of column name to string, NSNull for
 * NULL; an empty array for a statement without rows), or nil when it failed, with *errorMessage the server's message.
 */
typedef NSArray<NSDictionary *> *(^SPMySQLStorageReducerQuery)(NSString *sql, NSString **errorMessage);

/**
 * The MySQL side of the table list's Reduce Storage: `OPTIMIZE TABLE` on each table, in order. On InnoDB the table is
 * rebuilt ("recreate + analyze"), which gives the space of deleted rows back to the disk when the table has its own
 * file (innodb_file_per_table, the default); MyISAM tables are defragmented. No row changes.
 *
 * Sizes are DATA_LENGTH + INDEX_LENGTH from information_schema.TABLES. MySQL 8 caches those figures
 * (information_schema_stats_expiry); while this runs the session reads them fresh, then gets its own value back.
 */
__attribute__((visibility("default")))
@interface SPMySQLStorageReducer : NSObject

/**
 * Reduces the storage of tables (of the connection's current database) through query, in order. Returns one
 * dictionary per table: @"table", @"before" and @"after" (NSNumber, bytes), or @"table" and @"skipped" (NSString,
 * the server's message) for a table OPTIMIZE reported an error for.
 *
 * With skipping NO (the selected tables), the first failure stops: nil is returned with *errorMessage naming the table
 * and the server's message (tables done before it stay done). With skipping YES (all tables), a table that fails is
 * listed as skipped and the others are done; only a failure of the connection itself returns nil.
 *
 * isCancelled (may be nil) is asked before each table: once it says YES, nil is returned with *errorMessage nil.
 */
+ (NSArray<NSDictionary *> *)reduceStorageOfTables:(NSArray<NSString *> *)tables skippingFailures:(BOOL)skipping query:(SPMySQLStorageReducerQuery)query isCancelled:(BOOL (^)(void))isCancelled errorMessage:(NSString **)errorMessage;

/// The result lines for an alert: for several tables done the total first and a blank line, then "table: before → after"
/// per table done, then (after a blank line) "table: skipped (message)". sizeFormatter turns bytes into text.
+ (NSArray<NSString *> *)resultLinesFor:(NSArray<NSDictionary *> *)results sizeFormatter:(NSString *(^)(long long bytes))sizeFormatter;

@end
