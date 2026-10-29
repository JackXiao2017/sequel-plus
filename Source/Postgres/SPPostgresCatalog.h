#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Catalog queries that feed the Postgres window's database/schema/table lists (read-only, except
/// -createDatabase:error:).
/// All names are passed to the server as bound parameters. Methods returning NSArray return nil
/// and fill *error (domain SPPostgresErrorDomain, SPPostgresErrorQueryFailed) on failure.
__attribute__((visibility("default")))
@interface SPPostgresCatalog : NSObject
{
	PGPostgresConnection *_connection;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The connection the queries run on.
@property (readonly) PGPostgresConnection *connection;

/// The server_version setting (e.g. @"18.0"), or nil on failure.
- (NSString *)serverVersionString;

/// Connectable, non-template databases, sorted.
- (NSArray *)databaseNames:(NSError **)error;

/// User-visible schemas (no pg_catalog, information_schema, pg_toast*, pg_temp_*), sorted.
- (NSArray *)schemaNames:(NSError **)error;

/// "public" if present, else the first of current_schemas(false) that is present, else the first in the list, else nil.
- (NSString *)defaultSchemaFromSchemas:(NSArray *)schemas;

/// Tables and partitioned tables (relkind r, p) in the schema, sorted.
- (NSArray *)tableNamesInSchema:(NSString *)schema error:(NSError **)error;

/// Views and materialized views (relkind v, m) in the schema, sorted.
- (NSArray *)viewNamesInSchema:(NSString *)schema error:(NSError **)error;

/// Sequences (relkind S) in the schema, sorted.
- (NSArray *)sequenceNamesInSchema:(NSString *)schema error:(NSError **)error;

/**
 * Sends `CREATE DATABASE <quoted name>` (owner: the connected user; the server's default template and encoding).
 * An empty name, or one over 63 bytes in UTF-8, is refused with SPPostgresErrorInvalidSettings before anything is
 * sent. A server error is SPPostgresErrorQueryFailed with the server's message followed by its DETAIL and HINT.
 * The connection must not be inside a transaction block (the server refuses CREATE DATABASE there).
 */
- (BOOL)createDatabase:(NSString *)name error:(NSError **)error;

/// Installed extensions as dictionaries with @"name" and @"version", sorted by name.
- (NSArray *)installedExtensions:(NSError **)error;

@end
