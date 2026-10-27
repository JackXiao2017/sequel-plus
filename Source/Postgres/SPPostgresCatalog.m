#import "SPPostgresCatalog.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

@implementation SPPostgresCatalog

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
		*error = [NSError errorWithDomain:SPPostgresErrorDomain
									 code:SPPostgresErrorQueryFailed
								 userInfo:@{NSLocalizedDescriptionKey: message}];
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
