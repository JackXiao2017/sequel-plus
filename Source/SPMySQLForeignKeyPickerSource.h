//
//  SPMySQLForeignKeyPickerSource.h
//  Sequel Plus
//
//  The foreign key picker's MySQL source: SELECTs on the referenced table over the view's own connection, from a
//  private serial background queue (SPMySQL locks the connection per query); completions on the main queue.
//

#import <Foundation/Foundation.h>
#import "SPForeignKeyPickerDataSource.h"

@class SPMySQLConnection;

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface SPMySQLForeignKeyPickerSource : NSObject <SPForeignKeyPickerDataSource>

- (instancetype)initWithConnection:(SPMySQLConnection *)connection database:(NSString *)database table:(NSString *)table keyColumn:(NSString *)keyColumn;

/// As above, on queue (a serial queue; tests suspend it) instead of a queue of its own.
- (instancetype)initWithConnection:(SPMySQLConnection *)connection database:(NSString *)database table:(NSString *)table keyColumn:(NSString *)keyColumn queue:(dispatch_queue_t)queue;

@end

NS_ASSUME_NONNULL_END
