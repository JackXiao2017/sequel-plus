#import "SPPostgresCatalog.h"
#import "SPPostgresErrors.h"
#import "SPPostgresTableData.h"
#import <PostgresKit/PostgresKit.h>

@implementation SPPostgresCatalog

@synthesize connection = _connection;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection
{
	if ((self = [super init])) {
		_connection = [connection retain];
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[super dealloc];
}

#pragma mark - Helpers

- (PGPostgresResult *)run:(NSString *)sql values:(NSArray *)values error:(NSError **)error
{
	PGPostgresResult *result = [_connection execute:sql values:values ?: @[]];
	if (!result && error) {
		PGPostgresError *pgError = [_connection lastError];
		NSString *message = nil;
		if ([_connection isConnected]) {
			message = [pgError errorPrimaryMessage];
			if (![message length]) message = NSLocalizedString(@"The catalog query failed.", @"Postgres catalog query failure");
		}
		else {
			// The connection is gone: libpq's message says why (e.g. the server closed it). The last query
			// error may be older than that, so it isn't used.
			message = [_connection libpqErrorMessage];
			if (![message length]) message = NSLocalizedString(@"There is no connection to the server.", @"Postgres catalog query without a connection");
		}
		// The shared builder, with the server's SQLSTATE (as every other Postgres error has it)
		NSString *state = [_connection isConnected] ? [pgError errorStateCode] : nil;
		*error = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, [state length] ? @{SPPostgresSQLStateErrorKey: state} : nil);
	}
	return result;
}

/// Runs a query (whose column must be aliased "n") and returns that column of every row as strings.
- (NSArray *)firstColumnOf:(NSString *)sql values:(NSArray *)values error:(NSError **)error
{
	PGPostgresResult *result = [self run:sql values:values error:error];
	if (!result) return nil;

	NSMutableArray *names = [NSMutableArray array];
	for (NSDictionary *row in result) { // fast enumeration yields row dictionaries keyed by column name
		id value = [row objectForKey:@"n"];
		if ([value isKindOfClass:[NSString class]]) [names addObject:value];
	}
	return names;
}

#pragma mark - Queries

- (NSString *)serverVersionString
{
	NSArray *rows = [self firstColumnOf:@"SELECT current_setting('server_version')::text AS n" values:nil error:NULL];
	return [rows firstObject];
}

- (NSArray *)databaseNames:(NSError **)error
{
	return [self firstColumnOf:@"SELECT datname::text AS n FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname COLLATE \"C\""
						values:nil error:error];
}

- (NSArray *)schemaNames:(NSError **)error
{
	// Underscores are escaped so that "_" matches literally rather than as a LIKE wildcard.
	return [self firstColumnOf:@"SELECT nspname::text AS n FROM pg_namespace "
			"WHERE nspname NOT IN ('pg_catalog', 'information_schema') "
			"AND nspname NOT LIKE 'pg\\_toast%' AND nspname NOT LIKE 'pg\\_temp\\_%' "
			"ORDER BY nspname COLLATE \"C\""
						values:nil error:error];
}

- (NSString *)defaultSchemaFromSchemas:(NSArray *)schemas
{
	if ([schemas containsObject:@"public"]) return @"public";

	NSArray *searchPath = [self firstColumnOf:@"SELECT unnest(current_schemas(false))::text AS n" values:nil error:NULL];
	for (NSString *name in searchPath) {
		if ([schemas containsObject:name]) return name;
	}
	return [schemas firstObject];
}

- (NSArray *)relationNamesInSchema:(NSString *)schema kinds:(NSString *)kinds error:(NSError **)error
{
	// kinds is a fixed internal literal list, never caller input.
	NSString *sql = [NSString stringWithFormat:
		@"SELECT c.relname::text AS n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
		 "WHERE n.nspname = $1::text AND c.relkind IN (%@) ORDER BY c.relname COLLATE \"C\"", kinds];
	return [self firstColumnOf:sql values:@[schema ?: @""] error:error];
}

- (NSArray *)tableNamesInSchema:(NSString *)schema error:(NSError **)error
{
	return [self relationNamesInSchema:schema kinds:@"'r', 'p'" error:error];
}

- (NSArray *)viewNamesInSchema:(NSString *)schema error:(NSError **)error
{
	return [self relationNamesInSchema:schema kinds:@"'v', 'm'" error:error];
}

- (NSArray *)sequenceNamesInSchema:(NSString *)schema error:(NSError **)error
{
	return [self relationNamesInSchema:schema kinds:@"'S'" error:error];
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)columnNamesByRelationInSchema:(NSString *)schema error:(NSError **)error
{
	PGPostgresResult *result = [self run:@"SELECT c.relname::text AS r, a.attname::text AS n FROM pg_catalog.pg_attribute a "
										  "JOIN pg_catalog.pg_class c ON c.oid = a.attrelid "
										  "JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace "
										  "WHERE ns.nspname = $1::text AND c.relkind IN ('r', 'p', 'v', 'm', 'f') "
										  "AND a.attnum > 0 AND NOT a.attisdropped "
										  "ORDER BY c.relname COLLATE \"C\", a.attnum"
								  values:@[schema ?: @""] error:error];
	if (!result) return nil;

	NSMutableDictionary *columns = [NSMutableDictionary dictionary];
	for (NSDictionary *row in result) {
		id relation = [row objectForKey:@"r"];
		id column = [row objectForKey:@"n"];
		if (![relation isKindOfClass:[NSString class]] || ![column isKindOfClass:[NSString class]]) continue;
		NSMutableArray *list = [columns objectForKey:relation];
		if (!list) [columns setObject:(list = [NSMutableArray array]) forKey:relation];
		[list addObject:column];
	}
	return columns;
}

/// A new database name the server takes as it is: not empty, at most NAMEDATALEN - 1 (63) bytes in UTF-8 (a longer
/// one would be silently truncated). NO with *error (SPPostgresErrorInvalidSettings) otherwise.
static BOOL SPPostgresCheckDatabaseName(NSString *name, NSError **error)
{
	NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	if (bytes && bytes <= 63) return YES;
	if (error) {
		NSString *message = bytes
			? NSLocalizedString(@"A database name can be at most 63 bytes long.", @"Postgres new database: name too long")
			: NSLocalizedString(@"Enter a name for the new database.", @"Postgres new database: empty name");
		*error = SPPostgresMakeError(SPPostgresErrorInvalidSettings, message, nil);
	}
	return NO;
}

- (BOOL)createDatabase:(NSString *)name error:(NSError **)error
{
	if (!SPPostgresCheckDatabaseName(name, error)) return NO;

	// The connected user owns it, with the server's default template and encoding
	NSString *sql = [@"CREATE DATABASE " stringByAppendingString:SPPostgresQuoteIdentifier(name)];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (BOOL)copyDatabase:(NSString *)source toName:(NSString *)name error:(NSError **)error
{
	if (!SPPostgresCheckDatabaseName(name, error)) return NO;
	NSString *sql = [NSString stringWithFormat:@"CREATE DATABASE %@ TEMPLATE %@", SPPostgresQuoteIdentifier(name), SPPostgresQuoteIdentifier(source ?: @"")];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (BOOL)createSchema:(NSString *)name error:(NSError **)error
{
	NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	if (!bytes || bytes > 63) {
		if (error) {
			NSString *message = bytes
				? NSLocalizedString(@"A schema name can be at most 63 bytes long.", @"Postgres new schema: name too long")
				: NSLocalizedString(@"Enter a name for the new schema.", @"Postgres new schema: empty name");
			*error = SPPostgresMakeError(SPPostgresErrorInvalidSettings, message, nil);
		}
		return NO;
	}
	NSString *sql = [@"CREATE SCHEMA " stringByAppendingString:SPPostgresQuoteIdentifier(name)];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (BOOL)renameDatabase:(NSString *)name toName:(NSString *)newName error:(NSError **)error
{
	if (!SPPostgresCheckDatabaseName(newName, error)) return NO;
	NSString *sql = [NSString stringWithFormat:@"ALTER DATABASE %@ RENAME TO %@", SPPostgresQuoteIdentifier(name ?: @""), SPPostgresQuoteIdentifier(newName)];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (BOOL)dropDatabase:(NSString *)name error:(NSError **)error
{
	if (![name length]) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorInvalidSettings, NSLocalizedString(@"No database was named.", @"Postgres drop database: no name"), nil);
		return NO;
	}
	// The only DROP DATABASE in the app (Database ▸ Delete Database…, confirmed by typing the name)
	NSString *sql = [@"DROP DATABASE " stringByAppendingString:SPPostgresQuoteIdentifier(name)];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (NSDictionary<NSString *, NSString *> *)databaseDetails:(NSString *)name error:(NSError **)error
{
	PGPostgresResult *result = [self run:@"SELECT pg_get_userbyid(d.datdba)::text AS owner, coalesce(shobj_description(d.oid, 'pg_database'), '')::text AS comment "
										  "FROM pg_catalog.pg_database d WHERE d.datname = $1::text"
								  values:@[name ?: @""] error:error];
	if (!result) return nil;
	for (NSDictionary *row in result) {
		id owner = [row objectForKey:@"owner"];
		id comment = [row objectForKey:@"comment"];
		return @{@"owner": [owner isKindOfClass:[NSString class]] ? owner : @"", @"comment": [comment isKindOfClass:[NSString class]] ? comment : @""};
	}
	if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, [NSString stringWithFormat:NSLocalizedString(@"The database “%@” doesn't exist any more.", @"Postgres alter database: database gone"), name], nil);
	return nil;
}

- (NSArray<NSString *> *)roleNames:(NSError **)error
{
	return [self firstColumnOf:@"SELECT rolname::text AS n FROM pg_catalog.pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname COLLATE \"C\""
						values:nil error:error];
}

- (BOOL)setOwner:(NSString *)owner ofDatabase:(NSString *)name error:(NSError **)error
{
	NSString *sql = [NSString stringWithFormat:@"ALTER DATABASE %@ OWNER TO %@", SPPostgresQuoteIdentifier(name ?: @""), SPPostgresQuoteIdentifier(owner ?: @"")];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (BOOL)setComment:(NSString *)comment ofDatabase:(NSString *)name error:(NSError **)error
{
	NSString *value = [comment length] ? SPPostgresQuoteLiteral(comment) : @"NULL";
	NSString *sql = [NSString stringWithFormat:@"COMMENT ON DATABASE %@ IS %@", SPPostgresQuoteIdentifier(name ?: @""), value];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

/// The rows of a query as dictionaries of strings (NULL: @""), keyed by the given column names.
- (NSArray<NSDictionary *> *)rowsOf:(NSString *)sql keys:(NSArray *)keys error:(NSError **)error
{
	PGPostgresResult *result = [self run:sql values:nil error:error];
	if (!result) return nil;
	NSMutableArray *rows = [NSMutableArray array];
	for (NSDictionary *row in result) {
		NSMutableDictionary *strings = [NSMutableDictionary dictionaryWithCapacity:[keys count]];
		for (NSString *key in keys) {
			id value = [row objectForKey:key];
			[strings setObject:([value isKindOfClass:[NSString class]] ? value : @"") forKey:key];
		}
		[rows addObject:strings];
	}
	return rows;
}

- (NSArray<NSDictionary *> *)serverSettings:(NSError **)error
{
	return [self rowsOf:@"SELECT name::text AS name, setting::text AS setting, coalesce(unit, '')::text AS unit, "
						 "category::text AS category, coalesce(short_desc, '')::text AS description "
						 "FROM pg_catalog.pg_settings ORDER BY name COLLATE \"C\""
				   keys:@[@"name", @"setting", @"unit", @"category", @"description"] error:error];
}

- (NSArray<NSDictionary *> *)serverProcesses:(NSError **)error
{
	return [self rowsOf:@"SELECT pid::text AS pid, coalesce(usename::text, '') AS \"user\", coalesce(datname::text, '') AS database, "
						 "coalesce(host(client_addr), CASE WHEN client_port = -1 THEN 'local' ELSE '' END) AS client, "
						 "coalesce(application_name, '')::text AS application, coalesce(state, '')::text AS state, "
						 "coalesce(to_char(query_start, 'YYYY-MM-DD HH24:MI:SS'), '') AS started, "
						 "coalesce(backend_type, '')::text AS type, coalesce(query, '')::text AS query, "
						 "(pid = pg_backend_pid())::text AS own "
						 "FROM pg_catalog.pg_stat_activity ORDER BY pid"
				   keys:@[@"pid", @"user", @"database", @"client", @"application", @"state", @"started", @"type", @"query", @"own"] error:error];
}

- (BOOL)signalProcess:(NSInteger)pid terminate:(BOOL)terminate error:(NSError **)error
{
	NSString *sql = terminate ? @"SELECT pg_terminate_backend($1::int)::text AS n" : @"SELECT pg_cancel_backend($1::int)::text AS n";
	NSArray *rows = [self firstColumnOf:sql values:@[[NSString stringWithFormat:@"%ld", (long)pid]] error:error];
	if (!rows) return NO;
	if ([[rows firstObject] isEqualToString:@"true"]) return YES;
	if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The server did not signal the process (it may have ended already).", @"Postgres process list: signal not sent"), nil);
	return NO;
}

- (NSArray *)installedExtensions:(NSError **)error
{
	PGPostgresResult *result = [self run:@"SELECT extname::text AS n, extversion::text AS v FROM pg_extension ORDER BY extname COLLATE \"C\""
								  values:nil error:error];
	if (!result) return nil;

	NSMutableArray *extensions = [NSMutableArray array];
	for (NSDictionary *row in result) {
		id name = [row objectForKey:@"n"];
		if (![name isKindOfClass:[NSString class]]) continue;
		id version = [row objectForKey:@"v"];
		if (![version isKindOfClass:[NSString class]]) version = @"";
		[extensions addObject:@{@"name": name, @"version": version}];
	}
	return extensions;
}

@end
