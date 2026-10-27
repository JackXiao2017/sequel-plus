#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Helpers for the Docker test servers started by Scripts/pg-test-servers.sh
/// (PG 12 on 55412 without SSL, PG 18 on 55418 with SSL).
@interface SPPostgresTestServers : NSObject

+ (NSArray<NSNumber *> *)ports;

/// Returns a connected connection (user pgkit_test, database pgkit_test) or fails the current test.
+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port;

/// Same, against the named database.
+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database;

@end
