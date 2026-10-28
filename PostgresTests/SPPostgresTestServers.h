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
 * t_audit (AFTER INSERT OR DELETE, statement, disabled) on t; sequences seq_free (increment 5, start 100, comment
 * "free") and seq_used (the default of used_t.n), next to t's own t_id_seq (serial) and t_ident_seq (identity); and
 * "Sales Data"."Mixed Case" and the sequence "Sales Data"."Odd ""Seq"""), dropped and rebuilt on the server at port,
 * failing the current test if a statement fails. "Sales Data" belongs to the catalog fixture, so only its "Mixed
 * Case" table and "Odd ""Seq""" sequence are dropped and rebuilt.
 */
+ (void)loadStructureFixtureOnPort:(NSUInteger)port;

/// Drops what -loadStructureFixtureOnPort: built.
+ (void)dropStructureFixtureOnPort:(NSUInteger)port;

/// Drops every role named sp_t4_% (roles are cluster-wide on the shared servers), after DROP OWNED BY them in
/// pgkit_test and pgkit_nopublic (when it exists). Test-only cleanup: app code never uses DROP OWNED.
+ (void)dropTestRolesOnPort:(NSUInteger)port;

/// Returns a connection to database pgkit_ext (created when missing) after dropping every extension installed there
/// except plpgsql, dependents first (test code only: DROP EXTENSION … CASCADE), or fails the current test.
+ (PGPostgresConnection *)extensionTestConnectionOnPort:(NSUInteger)port;

@end
