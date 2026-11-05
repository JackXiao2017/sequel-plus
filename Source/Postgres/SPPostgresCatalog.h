#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Catalog queries that feed the Postgres window's database/schema/table lists, and the Database menu's (read-only,
/// except the database changes and -signalProcess:terminate:error:).
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

/// The column names of the schema's tables, views, materialized views, foreign and partitioned tables (relkind r, p,
/// v, m, f), by relation name, each in column order (no dropped or system columns). One query (the Query editor's
/// completion).
- (NSDictionary<NSString *, NSArray<NSString *> *> *)columnNamesByRelationInSchema:(NSString *)schema error:(NSError **)error;

/**
 * Sends `CREATE DATABASE <quoted name>` (owner: the connected user; the server's default template and encoding).
 * An empty name, or one over 63 bytes in UTF-8, is refused with SPPostgresErrorInvalidSettings before anything is
 * sent. A server error is SPPostgresErrorQueryFailed with the server's message followed by its DETAIL and HINT.
 * The connection must not be inside a transaction block (the server refuses CREATE DATABASE there).
 */
- (BOOL)createDatabase:(NSString *)name error:(NSError **)error;

/// `CREATE SCHEMA <name>` in the connected database, owned by the connected user (the sidebar's + by the schema
/// pop-up). An empty name, or one over 63 bytes in UTF-8, is refused with SPPostgresErrorInvalidSettings before
/// anything is sent; a server error (e.g. the schema exists) is SPPostgresErrorQueryFailed with its message.
- (BOOL)createSchema:(NSString *)name error:(NSError **)error;

/// `CREATE DATABASE <name> TEMPLATE <source>` (Duplicate Database): the server refuses while any other session is
/// connected to source. The name is checked as -createDatabase:error:'s.
- (BOOL)copyDatabase:(NSString *)source toName:(NSString *)name error:(NSError **)error;

/// `ALTER DATABASE <name> RENAME TO <newName>`: the server refuses for the connected database or while others are
/// connected to it. newName is checked as -createDatabase:error:'s.
- (BOOL)renameDatabase:(NSString *)name toName:(NSString *)newName error:(NSError **)error;

/// `DROP DATABASE <name>` (Database ▸ Delete Database… only): the server refuses for the connected database or while
/// others are connected to it.
- (BOOL)dropDatabase:(NSString *)name error:(NSError **)error;

/// The database's owner and comment (@"" for none), as @{@"owner", @"comment"}; nil with *error when it can't be read
/// or doesn't exist.
- (NSDictionary<NSString *, NSString *> *)databaseDetails:(NSString *)name error:(NSError **)error;

/// The roles (logins and groups) a database can be given to, without the built-in pg_* roles, sorted.
- (NSArray<NSString *> *)roleNames:(NSError **)error;

/// `ALTER DATABASE <name> OWNER TO <owner>`: the server allows it to the owner (when a member of the new owner, with
/// CREATEDB) and to superusers.
- (BOOL)setOwner:(NSString *)owner ofDatabase:(NSString *)name error:(NSError **)error;

/// `COMMENT ON DATABASE <name> IS <comment>` (an empty comment removes it: IS NULL).
- (BOOL)setComment:(NSString *)comment ofDatabase:(NSString *)name error:(NSError **)error;

/// pg_settings, by name: dictionaries of strings "name", "setting", "unit", "category", "description".
- (NSArray<NSDictionary *> *)serverSettings:(NSError **)error;

/// pg_stat_activity, by pid: dictionaries of strings "pid", "user", "database", "client" ("local" for a socket),
/// "application", "state", "started" (query_start), "type" (backend_type), "query", "own" ("true" for this session).
- (NSArray<NSDictionary *> *)serverProcesses:(NSError **)error;

/// pg_cancel_backend (terminate NO: the running query) or pg_terminate_backend (YES: the connection) on pid. NO with
/// *error when the server refuses or the process wasn't signalled.
- (BOOL)signalProcess:(NSInteger)pid terminate:(BOOL)terminate error:(NSError **)error;

/// Installed extensions as dictionaries with @"name" and @"version", sorted by name.
- (NSArray *)installedExtensions:(NSError **)error;

@end
