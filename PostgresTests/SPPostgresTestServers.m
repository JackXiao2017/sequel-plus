#import "SPPostgresTestServers.h"
#import <XCTest/XCTest.h>
#import <Cocoa/Cocoa.h>
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresTaskRunner.h"

// Connections handed out while a test case runs. PostgresKit's connection <-> type-handler retain cycle means a
// connection is never deallocated, so one nobody disconnects stays open for the whole suite.
static NSMutableArray<PGPostgresConnection *> *SPTrackedConnections = nil; // nil: no test case is running
static NSObject *SPTrackedConnectionsLock = nil;

@interface SPPostgresTestConnectionObserver : NSObject <XCTestObservation>
@end

@implementation SPPostgresTestConnectionObserver

+ (void)load
{
	SPTrackedConnectionsLock = [[NSObject alloc] init];
	[[XCTestObservationCenter sharedTestObservationCenter] addTestObserver:[[SPPostgresTestConnectionObserver alloc] init]];
}

- (void)testCaseWillStart:(XCTestCase *)testCase
{
	@synchronized (SPTrackedConnectionsLock) { SPTrackedConnections = [NSMutableArray array]; }
}

- (void)testCaseDidFinish:(XCTestCase *)testCase
{
	[SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest];
	@synchronized (SPTrackedConnectionsLock) { SPTrackedConnections = nil; }
}

@end

@implementation SPPostgresTestServers

+ (void)disconnectConnectionsOpenedDuringCurrentTest
{
	NSArray<PGPostgresConnection *> *connections;
	@synchronized (SPTrackedConnectionsLock) {
		connections = [SPTrackedConnections copy];
		[SPTrackedConnections removeAllObjects];
	}
	for (PGPostgresConnection *connection in connections) {
		if (connection.isConnected) [connection disconnect];
	}
}

+ (NSArray<NSNumber *> *)ports
{
	return @[@55412, @55418];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port
{
	return [self connectedConnectionOnPort:port database:@"pgkit_test"];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database
{
	return [self connectedConnectionOnPort:port database:database delegate:nil];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database
										   delegate:(NSObject<PGPostgresConnectionDelegate> *)delegate
{
	PGPostgresConnection *connection = delegate ? [[PGPostgresConnection alloc] initWithDelegate:delegate] : [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = port;
	connection.user = @"pgkit_test";
	connection.password = @"pgkit";
	connection.database = database;

	// -connect is asynchronous: wait for success or failure, up to 10 seconds.
	[connection connect];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
	while (!connection.isConnected && !connection.connectionError && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}

	if (!connection.isConnected) {
		XCTFail(@"Could not connect to test server on port %lu: %@", (unsigned long)port,
				connection.connectionError ?: @"timed out after 10 s");
		return nil;
	}
	@synchronized (SPTrackedConnectionsLock) { [SPTrackedConnections addObject:connection]; }
	return connection;
}

#pragma mark - Fixtures

// Fixtures are read from PostgresTests/Fixtures/ next to this source file (located via __FILE__), not bundled
// as test resources.
+ (NSString *)fixturePathNamed:(NSString *)fileName
{
	return [[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
			 stringByAppendingPathComponent:@"Fixtures"] stringByAppendingPathComponent:fileName];
}

+ (void)loadFixtureNamed:(NSString *)name onPort:(NSUInteger)port
{
	NSString *path = [self fixturePathNamed:[name stringByAppendingPathExtension:@"sql"]];
	NSError *readError = nil;
	NSString *sql = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
	if (!sql) { XCTFail(@"Cannot read fixture: %@", readError); return; }

	PGPostgresConnection *connection = [self connectedConnectionOnPort:port];
	if (!connection) return;

	for (NSString *chunk in [sql componentsSeparatedByString:@"\n-- @@"]) {
		NSMutableArray *lines = [[chunk componentsSeparatedByString:@"\n"] mutableCopy];
		NSString *directive = [lines.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([chunk hasPrefix:@"-- @@"]) { // very first chunk starts with the marker itself
			directive = [[chunk substringFromIndex:5] componentsSeparatedByString:@"\n"].firstObject;
		}
		[lines removeObjectAtIndex:0];
		NSString *statement = [[lines componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		directive = [directive stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

		if ([directive hasPrefix:@"minversion "]) {
			// The chunk runs only on servers at least this version (server_version_num, e.g. 140000)
			NSInteger minimum = [[directive substringFromIndex:11] integerValue];
			if ((NSInteger)[connection serverVersion] < minimum) continue;
		} else if ([directive hasPrefix:@"db "]) {
			[connection disconnect];
			connection = [self connectedConnectionOnPort:port database:[directive substringFromIndex:3]];
			if (!connection) return;
		} else if ([directive hasPrefix:@"createdb "]) {
			NSString *dbName = [directive substringFromIndex:9];
			PGPostgresResult *exists = [connection execute:@"SELECT 1 FROM pg_database WHERE datname = $1::text" values:@[dbName]];
			if (exists.numberOfRows == 0) {
				// Name comes from the fixture file, quoted as an identifier.
				NSString *quoted = [dbName stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
				NSString *create = [NSString stringWithFormat:@"CREATE DATABASE \"%@\"", quoted];
				XCTAssertNotNil([connection execute:create], @"CREATE DATABASE: %@", connection.lastError.errorPrimaryMessage);
			}
		}
		if (statement.length) {
			XCTAssertNotNil([connection execute:statement], @"%@ failed: %@", statement, connection.lastError.errorPrimaryMessage);
		}
	}
	[connection disconnect];
}

#pragma mark - Import / export databases

+ (PGPostgresConnection *)ioConnectionOnPort:(NSUInteger)port database:(NSString *)name
{
	if (![name isEqualToString:@"pgkit_io_src"] && ![name isEqualToString:@"pgkit_io_dst"]) {
		XCTFail(@"ioConnectionOnPort: only empties pgkit_io_src and pgkit_io_dst, not %@", name);
		return nil;
	}
	PGPostgresConnection *admin = [self connectedConnectionOnPort:port];
	if (!admin) return nil;
	PGPostgresResult *exists = [admin execute:@"SELECT 1 FROM pg_catalog.pg_database WHERE datname = $1::text" values:@[name]];
	if (exists.numberOfRows == 0) {
		NSString *create = [NSString stringWithFormat:@"CREATE DATABASE \"%@\"", name];
		XCTAssertNotNil([admin execute:create], @"%@: %@", create, admin.lastError.errorPrimaryMessage);
	}
	[admin disconnect];

	PGPostgresConnection *connection = [self connectedConnectionOnPort:port database:name];
	if (!connection) return nil;
	[connection execute:@"SET lock_timeout = '10s'"];
	// Empty it: drop every non-system schema (test code only: CASCADE), then recreate public
	PGPostgresResult *schemas = [connection execute:(@"SELECT nspname::text FROM pg_catalog.pg_namespace"
													 @" WHERE nspname <> 'information_schema' AND nspname NOT LIKE 'pg\\_%' ORDER BY 1")];
	for (unsigned long long row = 0; row < schemas.numberOfRows; row++) {
		NSString *schema = [schemas textValueAtRow:row column:0];
		NSString *drop = [NSString stringWithFormat:@"DROP SCHEMA IF EXISTS \"%@\" CASCADE",
						  [schema stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
		XCTAssertNotNil([connection execute:drop], @"%@: %@", drop, connection.lastError.errorPrimaryMessage);
	}
	XCTAssertNotNil([connection execute:@"CREATE SCHEMA public"], @"CREATE SCHEMA public: %@", connection.lastError.errorPrimaryMessage);
	[connection execute:@"RESET lock_timeout"];
	return connection;
}

#pragma mark - Database descriptions

static NSString * const SPUserSchemas = @"nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'";

+ (NSString *)describeText:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : @"(null)";
}

+ (NSArray<NSString *> *)describeFirstColumn:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	NSMutableArray *values = [NSMutableArray array];
	for (unsigned long long row = 0; row < result.numberOfRows; row++) {
		id value = [result textValueAtRow:row column:0];
		[values addObject:[value isKindOfClass:[NSString class]] ? value : @"(null)"];
	}
	return values;
}

+ (NSDictionary *)describeDatabase:(PGPostgresConnection *)connection
{
	NSMutableDictionary *description = [NSMutableDictionary dictionary];
	NSString *(^aggregate)(NSString *) = ^NSString *(NSString *rowsSQL) {
		return [self describeText:[NSString stringWithFormat:@"SELECT coalesce(string_agg(x, E'\\n' ORDER BY x COLLATE \"C\"), '') FROM (%@) s(x)", rowsSQL] on:connection];
	};

	description[@"columns"] = aggregate([NSString stringWithFormat:
		@"SELECT format('%%I.%%I.%%I %%s notnull=%%s default=%%s identity=%%s generated=%%s', n.nspname, c.relname, a.attname,"
		" format_type(a.atttypid, a.atttypmod), a.attnotnull, coalesce(pg_get_expr(d.adbin, d.adrelid), '-'), a.attidentity, a.attgenerated)"
		" FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace"
		" LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum"
		" WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped AND %@", SPUserSchemas]);
	description[@"constraints"] = aggregate([NSString stringWithFormat:
		@"SELECT CASE WHEN con.conrelid <> 0 THEN con.conrelid::regclass::text ELSE con.contypid::regtype::text END"
		" || ' ' || con.conname || ' ' || pg_get_constraintdef(con.oid) || ' validated=' || con.convalidated"
		" FROM pg_constraint con JOIN pg_namespace n ON n.oid = con.connamespace WHERE %@", SPUserSchemas]);
	description[@"indexes"] = aggregate(@"SELECT indexdef FROM pg_indexes WHERE schemaname NOT LIKE 'pg\\_%' AND schemaname <> 'information_schema'");
	description[@"triggers"] = aggregate(@"SELECT pg_get_triggerdef(t.oid) || ' enabled=' || t.tgenabled::text FROM pg_trigger t WHERE NOT t.tgisinternal");
	description[@"views"] = aggregate([NSString stringWithFormat:
		@"SELECT c.oid::regclass::text || ' ' || c.relkind::text || ' ' || pg_get_viewdef(c.oid)"
		" FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('v', 'm') AND %@", SPUserSchemas]);
	description[@"populated"] = aggregate([NSString stringWithFormat:
		@"SELECT c.oid::regclass::text || ' ' || c.relispopulated"
		" FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'm' AND %@", SPUserSchemas]);
	description[@"functions"] = aggregate([NSString stringWithFormat:
		@"SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
		" WHERE p.prokind IN ('f', 'p') AND %@ AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')", SPUserSchemas]);
	description[@"enums"] = aggregate(@"SELECT t.typname || ': ' || string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid GROUP BY t.typname");
	description[@"comments"] = aggregate(@"SELECT pg_describe_object(classoid, objoid, objsubid) || ' = ' || description FROM pg_description WHERE objoid >= 16384");
	description[@"extensions"] = aggregate(@"SELECT extname || ' ' || extnamespace::regnamespace::text FROM pg_extension");

	// Rows of every table and populated materialized view
	NSArray *relations = [self describeFirstColumn:[NSString stringWithFormat:
		@"SELECT format('%%I.%%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
		" WHERE (c.relkind IN ('r', 'p') OR (c.relkind = 'm' AND c.relispopulated)) AND %@ ORDER BY 1", SPUserSchemas] on:connection];
	for (NSString *relation in relations) {
		NSString *sql = [NSString stringWithFormat:@"SELECT count(*) || ' ' || coalesce(md5(string_agg(t::text, '|' ORDER BY t::text)), '-') FROM %@ t", relation];
		description[[@"rows " stringByAppendingString:relation]] = [self describeText:sql on:connection];
	}

	// Sequences
	NSArray *sequences = [self describeFirstColumn:@"SELECT format('%I.%I', schemaname, sequencename) FROM pg_sequences ORDER BY 1" on:connection];
	for (NSString *sequence in sequences) {
		NSString *sql = [NSString stringWithFormat:@"SELECT last_value || ' ' || is_called FROM %@", sequence];
		description[[@"sequence " stringByAppendingString:sequence]] = [self describeText:sql on:connection];
	}
	return description;
}

+ (void)assertDescription:(NSDictionary *)actual equals:(NSDictionary *)expected context:(NSString *)context
{
	NSMutableSet *keys = [NSMutableSet setWithArray:expected.allKeys];
	[keys addObjectsFromArray:actual.allKeys];
	for (NSString *key in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
		XCTAssertEqualObjects(actual[key], expected[key], @"%@: %@", context, key);
	}
}

#pragma mark - Structure fixture

+ (NSArray<NSString *> *)structureFixtureStatements
{
	return @[
		@"SET lock_timeout = '10s'",
		@"DROP SCHEMA IF EXISTS structure_test CASCADE",
		@"CREATE SCHEMA structure_test",
		(@"CREATE TABLE structure_test.t ("
			" id serial PRIMARY KEY,"
			" code text UNIQUE,"
			" qty text,"
			" amount numeric(10,2) DEFAULT 0,"
			" \"Order\" int,"
			" \"a \"\"q\"\" b\" text,"
			" gen int GENERATED ALWAYS AS (id * 2) STORED,"
			" ident bigint GENERATED BY DEFAULT AS IDENTITY)"),
		@"COMMENT ON TABLE structure_test.t IS 'the t table'",
		@"COMMENT ON COLUMN structure_test.t.code IS 'the code'",
		@"INSERT INTO structure_test.t (qty) VALUES ('5'), ('12a')",
		@"CREATE INDEX t_amount_idx ON structure_test.t (amount)",
		@"CREATE INDEX t_qty_amount_idx ON structure_test.t (qty, amount)",
		@"ALTER TABLE structure_test.t ADD CONSTRAINT t_amount_check CHECK (amount >= 0)",
		@"CREATE VIEW structure_test.t_view AS SELECT code FROM structure_test.t",
		@"CREATE TABLE structure_test.child (id int PRIMARY KEY, t_id int REFERENCES structure_test.t (id) ON DELETE CASCADE)",
		// Triggers (Task 3): a row trigger on UPDATE OF code with a WHEN, and a disabled statement-level one
		@"CREATE FUNCTION structure_test.touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
		(@"CREATE TRIGGER t_touch BEFORE UPDATE OF code ON structure_test.t FOR EACH ROW"
			" WHEN (OLD.code IS DISTINCT FROM NEW.code) EXECUTE FUNCTION structure_test.touch()"),
		@"CREATE TRIGGER t_audit AFTER INSERT OR DELETE ON structure_test.t FOR EACH STATEMENT EXECUTE FUNCTION structure_test.touch()",
		@"ALTER TABLE structure_test.t DISABLE TRIGGER t_audit",
		// Sequences (Task 5): a free one, one a column default uses; t's serial (t_id_seq) and identity (t_ident_seq)
		// sequences come with t
		@"CREATE SEQUENCE structure_test.seq_free INCREMENT 5 START 100",
		@"COMMENT ON SEQUENCE structure_test.seq_free IS 'free'",
		@"CREATE SEQUENCE structure_test.seq_used",
		@"CREATE TABLE structure_test.used_t (n int DEFAULT nextval('structure_test.seq_used'))",
		@"CREATE SCHEMA IF NOT EXISTS \"Sales Data\"",
		@"DROP TABLE IF EXISTS \"Sales Data\".\"Mixed Case\" CASCADE",
		@"CREATE TABLE \"Sales Data\".\"Mixed Case\" (\"order\" int PRIMARY KEY, \"select\" text)",
		@"DROP SEQUENCE IF EXISTS \"Sales Data\".\"Odd \"\"Seq\"\"\"",
		@"CREATE SEQUENCE \"Sales Data\".\"Odd \"\"Seq\"\"\"",
	];
}

+ (void)loadStructureFixtureOnPort:(NSUInteger)port
{
	PGPostgresConnection *connection = [self connectedConnectionOnPort:port];
	if (!connection) return;
	for (NSString *sql in [self structureFixtureStatements]) {
		XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	}
	[connection disconnect];
}

+ (void)dropStructureFixtureOnPort:(NSUInteger)port
{
	PGPostgresConnection *connection = [self connectedConnectionOnPort:port];
	[connection execute:@"SET lock_timeout = '10s'"];
	[connection execute:@"DROP SCHEMA IF EXISTS structure_test CASCADE"];
	[connection execute:@"DROP TABLE IF EXISTS \"Sales Data\".\"Mixed Case\" CASCADE"];
	[connection execute:@"DROP SEQUENCE IF EXISTS \"Sales Data\".\"Odd \"\"Seq\"\"\""];
	[connection disconnect];
}

#pragma mark - Test roles

+ (void)dropTestRolesOnPort:(NSUInteger)port
{
	PGPostgresConnection *connection = [self connectedConnectionOnPort:port];
	if (!connection) return;
	PGPostgresResult *result = [connection execute:@"SELECT rolname::text FROM pg_catalog.pg_roles WHERE left(rolname, 6) = 'sp_t4_' ORDER BY 1"];
	NSMutableArray *quoted = [NSMutableArray array];
	for (unsigned long long row = 0; row < result.numberOfRows; row++) {
		NSString *name = [result textValueAtRow:row column:0];
		[quoted addObject:[NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]]];
	}
	PGPostgresResult *databases = [connection execute:@"SELECT datname::text FROM pg_catalog.pg_database WHERE datname IN ('pgkit_test', 'pgkit_nopublic') ORDER BY 1"];
	NSMutableArray *names = [NSMutableArray array];
	for (unsigned long long row = 0; row < databases.numberOfRows; row++) [names addObject:[databases textValueAtRow:row column:0]];
	[connection disconnect];
	if (!quoted.count) return;

	// One role at a time: DROP OWNED BY a, b fails ("could not find tuple for default ACL") when a's default
	// privileges grant to b, as both try to remove the same pg_default_acl row.
	PGPostgresConnection *last = nil;
	for (NSString *database in names) {
		PGPostgresConnection *databaseConnection = [self connectedConnectionOnPort:port database:database];
		for (NSString *role in quoted) {
			NSString *owned = [NSString stringWithFormat:@"DROP OWNED BY %@", role];
			XCTAssertNotNil([databaseConnection execute:owned], @"%@ in %@: %@", owned, database, databaseConnection.lastError.errorPrimaryMessage);
		}
		if (last) [last disconnect];
		last = databaseConnection;
	}
	for (NSString *role in quoted) {
		NSString *drop = [NSString stringWithFormat:@"DROP ROLE IF EXISTS %@", role];
		XCTAssertNotNil([last execute:drop], @"%@: %@", drop, last.lastError.errorPrimaryMessage);
	}
	[last disconnect];
}

#pragma mark - Extensions database

+ (PGPostgresConnection *)extensionTestConnectionOnPort:(NSUInteger)port
{
	PGPostgresConnection *admin = [self connectedConnectionOnPort:port];
	if (!admin) return nil;
	PGPostgresResult *exists = [admin execute:@"SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'pgkit_ext'"];
	if (exists.numberOfRows == 0) {
		XCTAssertNotNil([admin execute:@"CREATE DATABASE pgkit_ext"], @"CREATE DATABASE pgkit_ext: %@", admin.lastError.errorPrimaryMessage);
	}
	[admin disconnect];

	PGPostgresConnection *connection = [self connectedConnectionOnPort:port database:@"pgkit_ext"];
	if (!connection) return nil;
	[connection execute:@"SET lock_timeout = '10s'"];
	[connection execute:@"DROP TABLE IF EXISTS public.sp_t5_items"];
	// Dependents first: an extension no other installed extension requires, one at a time, until only plpgsql is left
	for (NSUInteger round = 0; round < 50; round++) {
		PGPostgresResult *leaves = [connection execute:(@"SELECT e.extname::text FROM pg_catalog.pg_extension e"
														@" WHERE e.extname <> 'plpgsql' AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d"
														@" JOIN pg_catalog.pg_extension r ON r.oid = d.objid"
														@" WHERE d.classid = 'pg_catalog.pg_extension'::regclass"
														@" AND d.refclassid = 'pg_catalog.pg_extension'::regclass AND d.refobjid = e.oid)"
														@" ORDER BY 1 LIMIT 1")];
		if (!leaves.numberOfRows) break;
		NSString *name = [leaves textValueAtRow:0 column:0];
		NSString *drop = [NSString stringWithFormat:@"DROP EXTENSION IF EXISTS \"%@\" CASCADE",
						  [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
		if (![connection execute:drop]) {
			XCTFail(@"%@: %@", drop, connection.lastError.errorPrimaryMessage);
			break;
		}
	}
	[connection execute:@"RESET lock_timeout"];
	return connection;
}

#pragma mark - Task runner

+ (BOOL)waitForRunner:(SPPostgresTaskRunner *)runner timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (runner.isBusy && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	return !runner.isBusy;
}

+ (void)queueSleep:(NSTimeInterval)seconds onRunner:(SPPostgresTaskRunner *)runner
{
	NSString *sql = [NSString stringWithFormat:@"SELECT pg_sleep(%g)", seconds];
	[runner runTaskWithDescription:@"Sleeping..." cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		return [connection execute:sql];
	} completion:nil];
}

+ (NSArray<NSArray *> *)rowsOfTableView:(NSTableView *)tableView
{
	NSMutableArray *rows = [NSMutableArray array];
	for (NSInteger row = 0; row < [tableView numberOfRows]; row++) {
		NSMutableArray *values = [NSMutableArray array];
		for (NSTableColumn *column in [tableView tableColumns]) {
			[values addObject:[[tableView dataSource] tableView:tableView objectValueForTableColumn:column row:row] ?: [NSNull null]];
		}
		[rows addObject:values];
	}
	return rows;
}

@end
