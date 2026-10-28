#import <Foundation/Foundation.h>

@class PGPostgresConnection;
@protocol PGPostgresConnectionDelegate;

/// Helpers for the Docker test servers started by Scripts/pg-test-servers.sh
/// (PG 12 on 55412 without SSL, PG 18 on 55418 with SSL).
@interface SPPostgresTestServers : NSObject

+ (NSArray<NSNumber *> *)ports;

/// Returns a connected connection (user pgkit_test, database pgkit_test) or fails the current test.
+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port;

/// Same, against the named database.
+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database;

/// Same, created with the given delegate (PostgresKit decides at init whether it reports willExecute, so the
/// delegate must be passed here rather than set later). The connection does not retain the delegate.
+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database
										   delegate:(NSObject<PGPostgresConnectionDelegate> *)delegate;

/// Runs PostgresTests/Fixtures/<name>.sql on the server at port (see catalog.sql for its "-- @@" format),
/// failing the current test if a statement fails.
+ (void)loadFixtureNamed:(NSString *)name onPort:(NSUInteger)port;

/**
 * The Structure fixture (schema structure_test: table t with odd columns, indexes, a check, view t_view and table
 * child referencing t; trigger function touch() with triggers t_touch (BEFORE UPDATE OF code, row, WHEN) and
 * t_audit (AFTER INSERT OR DELETE, statement, disabled) on t; and "Sales Data"."Mixed Case"), dropped and rebuilt on the server at port, failing the
 * current test if a statement fails. "Sales Data" belongs to the catalog fixture, so only its "Mixed Case" table
 * is dropped and rebuilt.
 */
+ (void)loadStructureFixtureOnPort:(NSUInteger)port;

/// Drops what -loadStructureFixtureOnPort: built.
+ (void)dropStructureFixtureOnPort:(NSUInteger)port;

@end
