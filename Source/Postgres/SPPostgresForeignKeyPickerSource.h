//
//  SPPostgresForeignKeyPickerSource.h
//  Sequel Plus
//
//  The foreign key picker's PostgreSQL source: SELECTs on the referenced table through the tab's task runner.
//

#import <Foundation/Foundation.h>
#import "../SPForeignKeyPickerDataSource.h"

@class SPPostgresTaskRunner;

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface SPPostgresForeignKeyPickerSource : NSObject <SPForeignKeyPickerDataSource>

- (instancetype)initWithTaskRunner:(SPPostgresTaskRunner *)runner schema:(NSString *)schema table:(NSString *)table keyColumn:(NSString *)keyColumn;

@end

NS_ASSUME_NONNULL_END
