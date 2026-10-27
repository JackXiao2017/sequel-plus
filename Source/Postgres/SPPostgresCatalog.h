#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Read-only catalog queries that feed the Postgres window's database/schema/table lists.
/// All names are passed to the server as bound parameters. Methods returning NSArray return nil
/// and fill *error (domain SPPostgresErrorDomain, SPPostgresErrorQueryFailed) on failure.
__attribute__((visibility("default")))
@interface SPPostgresCatalog : NSObject
{
	PGPostgresConnection *_connection;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

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

/// Installed extensions as dictionaries with @"name" and @"version", sorted by name.
- (NSArray *)installedExtensions:(NSError **)error;

@end
