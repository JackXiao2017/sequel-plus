#import <XCTest/XCTest.h>
#include <sys/resource.h>
#include <signal.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresDumpWriter.h"
#import "../Source/Postgres/SPPostgresDumpReader.h"
#import "../Source/Postgres/SPPostgresSQLImporter.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// SQL dumps written by SPPostgresDumpWriter from io_source.sql (pgkit_io_src), imported with Task 2's importer into
/// pgkit_io_dst; both ports.
@interface SPPostgresDumpWriterTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresDumpWriterTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)kept:(PGPostgresConnection *)connection
{
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

/// pgkit_io_src emptied and loaded with io_source.sql.
- (PGPostgresConnection *)sourceOn:(NSNumber *)port
{
	PGPostgresConnection *source = [self kept:[SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]];
	[SPPostgresTestServers loadFixtureNamed:@"io_source" onPort:port.unsignedIntegerValue];
	return source;
}

/// pgkit_io_dst emptied.
- (PGPostgresConnection *)destinationOn:(NSNumber *)port
{
	return [self kept:[SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_dst"]];
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)text:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : @"(null)";
}

- (NSArray<NSArray *> *)rows:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	NSMutableArray *rows = [NSMutableArray array];
	for (unsigned long long row = 0; row < result.numberOfRows; row++) {
		NSMutableArray *fields = [NSMutableArray array];
		for (NSUInteger column = 0; column < result.numberOfFields; column++) {
			id value = [result textValueAtRow:row column:column];
			[fields addObject:[value isKindOfClass:[NSString class]] ? value : @"(null)"];
		}
		[rows addObject:fields];
	}
	return rows;
}

- (NSString *)pathNamed:(NSString *)name
{
	return [self.directory stringByAppendingPathComponent:name];
}

/// Writes a dump of connection's database, configured by configure, and returns its path.
- (NSString *)dumpFrom:(PGPostgresConnection *)connection named:(NSString *)name configure:(void (^)(SPPostgresDumpWriter *writer))configure
{
	SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:connection];
	configure(writer);
	NSString *path = [self pathNamed:name];
	NSError *error = nil;
	XCTAssertTrue([writer writeToPath:path error:&error], @"%@", error.localizedDescription);
	XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
	return path;
}

- (NSString *)contentsOf:(NSString *)path
{
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

/// Imports the dump in a single transaction.
- (void)import:(NSString *)path into:(PGPostgresConnection *)connection
{
	NSError *error = nil;
	SPPostgresDumpReader *reader = [[SPPostgresDumpReader alloc] initWithPath:path error:&error];
	XCTAssertNotNil(reader, @"%@", error);
	SPPostgresSQLImporter *importer = [[SPPostgresSQLImporter alloc] initWithConnection:connection reader:reader];
	XCTAssertTrue([importer run:&error], @"%@\n\n%@", error.localizedDescription, [self contentsOf:path]);
	XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
	// The dump empties search_path for the session, as pg_dump's does; compare under the default one
	[self run:@"RESET search_path" on:connection];
}

/// What a dump of the fixture's "Sales Data" refers to in public, created beforehand.
- (void)createPublicDependenciesOn:(PGPostgresConnection *)connection
{
	[self run:@"CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public" on:connection];
	[self run:@"CREATE TYPE public.mood AS ENUM ('sad', 'ok', 'happy')" on:connection];
	[self run:@"CREATE DOMAIN public.posint AS integer CONSTRAINT posint_positive CHECK (VALUE > 0)" on:connection];
	[self run:@"CREATE TYPE public.address AS (street text, city text, zip text)" on:connection];
	[self run:@"CREATE FUNCTION public.audit_row() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$" on:connection];
}

static NSString * const SPUserSchemas = @"nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'";

/// Everything the round trip compares, keyed by what it is.
- (NSDictionary *)describe:(PGPostgresConnection *)connection
{
	NSMutableDictionary *description = [NSMutableDictionary dictionary];
	NSString *(^aggregate)(NSString *) = ^NSString *(NSString *rowsSQL) {
		return [self text:[NSString stringWithFormat:@"SELECT coalesce(string_agg(x, E'\\n' ORDER BY x COLLATE \"C\"), '') FROM (%@) s(x)", rowsSQL] on:connection];
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
	NSArray *relations = [self rows:[NSString stringWithFormat:
		@"SELECT format('%%I.%%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
		" WHERE (c.relkind IN ('r', 'p') OR (c.relkind = 'm' AND c.relispopulated)) AND %@ ORDER BY 1", SPUserSchemas] on:connection];
	for (NSArray *relation in relations) {
		NSString *sql = [NSString stringWithFormat:@"SELECT count(*) || ' ' || coalesce(md5(string_agg(t::text, '|' ORDER BY t::text)), '-') FROM %@ t", relation[0]];
		description[[@"rows " stringByAppendingString:relation[0]]] = [self text:sql on:connection];
	}

	// Sequences
	NSArray *sequences = [self rows:@"SELECT format('%I.%I', schemaname, sequencename) FROM pg_sequences ORDER BY 1" on:connection];
	for (NSArray *sequence in sequences) {
		NSString *sql = [NSString stringWithFormat:@"SELECT last_value || ' ' || is_called FROM %@", sequence[0]];
		description[[@"sequence " stringByAppendingString:sequence[0]]] = [self text:sql on:connection];
	}
	return description;
}

- (void)assertDescription:(NSDictionary *)actual equals:(NSDictionary *)expected context:(NSString *)context
{
	NSMutableSet *keys = [NSMutableSet setWithArray:expected.allKeys];
	[keys addObjectsFromArray:actual.allKeys];
	for (NSString *key in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
		XCTAssertEqualObjects(actual[key], expected[key], @"%@: %@", context, key);
	}
}

#pragma mark - Tests

- (void)testRoundTripMatchesSource
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *destination = [self destinationOn:port];

		NSString *path = [self dumpFrom:source named:[NSString stringWithFormat:@"whole-%@.sql", port] configure:^(SPPostgresDumpWriter *writer) {
			writer.wholeDatabase = YES;
		}];
		NSString *dump = [self contentsOf:path];
		XCTAssertTrue([dump containsString:@"SET client_encoding = 'UTF8';"]);
		XCTAssertTrue([dump containsString:@"SELECT pg_catalog.set_config('search_path', '', false);"]);
		XCTAssertTrue([dump containsString:@"CREATE EXTENSION IF NOT EXISTS \"citext\" WITH SCHEMA \"public\";"]);
		XCTAssertFalse([dump containsString:@"CREATE EXTENSION IF NOT EXISTS \"plpgsql\""]);
		XCTAssertFalse([dump containsString:@"OWNER TO"]);
		XCTAssertFalse([dump containsString:@"GRANT "]);

		[self import:path into:destination];

		// The trigger didn't fire during the load: the audit rows are the source's
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM public.audit" on:destination], @"7");
		XCTAssertEqualObjects([self text:@"SELECT relispopulated::text FROM pg_class WHERE oid = '\"Sales Data\".mv_unpopulated'::regclass" on:destination], @"false");

		NSDictionary *expected = [self describe:source];
		NSDictionary *actual = [self describe:destination];
		XCTAssertEqualObjects(expected[@"rows public.audit"], actual[@"rows public.audit"]);
		XCTAssertEqualObjects(expected[@"sequence public.counter"], @"42 true");
		[self assertDescription:actual equals:expected context:[NSString stringWithFormat:@"port %@", port]];

		// Materialized views compared once both are populated
		for (PGPostgresConnection *connection in @[source, destination]) {
			[self run:@"REFRESH MATERIALIZED VIEW \"Sales Data\".mv_unpopulated" on:connection];
		}
		[self assertDescription:[self describe:destination] equals:[self describe:source] context:[NSString stringWithFormat:@"port %@, refreshed", port]];

		// The foreign keys hold and the sequences continue where the source's do
		XCTAssertNil([destination execute:@"INSERT INTO \"Sales Data\".order_lines (order_id, item) VALUES (999, 'none')"]);
		for (PGPostgresConnection *connection in @[source, destination]) {
			[self run:@"INSERT INTO \"Sales Data\".\"Orders 2026\" (customer, qty) VALUES ('Next', 1)" on:connection];
		}
		NSString *nextRow = @"SELECT id || ' ' || seq FROM \"Sales Data\".\"Orders 2026\" WHERE customer = 'Next'";
		XCTAssertEqualObjects([self text:nextRow on:destination], [self text:nextRow on:source]);
		XCTAssertEqualObjects([self text:@"SELECT nextval('public.counter')::text" on:destination], @"43");
	}
}

- (void)testSchemaAndTableScopes
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		NSDictionary *expected = [self describe:source];

		// Schema "Sales Data" only
		PGPostgresConnection *destination = [self destinationOn:port];
		[self createPublicDependenciesOn:destination];
		NSString *path = [self dumpFrom:source named:@"schema.sql" configure:^(SPPostgresDumpWriter *writer) {
			writer.schemas = @[@"Sales Data"];
		}];
		NSString *dump = [self contentsOf:path];
		XCTAssertTrue([dump containsString:@"CREATE SCHEMA IF NOT EXISTS \"Sales Data\";"]);
		XCTAssertFalse([dump containsString:@"CREATE SCHEMA IF NOT EXISTS \"public\""]);
		XCTAssertFalse([dump containsString:@"CREATE EXTENSION"]); // citext is in public
		XCTAssertFalse([dump containsString:@"\"public\".\"audit\""]);
		[self import:path into:destination];

		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')" on:destination], @"0");
		NSDictionary *actual = [self describe:destination];
		for (NSString *key in @[@"rows \"Sales Data\".\"Orders 2026\"", @"rows \"Sales Data\".order_lines", @"rows \"Sales Data\".mv_by_feeling",
								@"sequence \"Sales Data\".\"Orders 2026_id_seq\"", @"sequence \"Sales Data\".\"Orders 2026_seq_seq\"", @"sequence \"Sales Data\".order_lines_id_seq"]) {
			XCTAssertNotNil(expected[key], @"%@", key);
			XCTAssertEqualObjects(actual[key], expected[key], @"port %@: %@", port, key);
		}
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'Sales Data' AND c.relkind IN ('v', 'm')" on:destination], @"4");
		XCTAssertEqualObjects([self text:@"SELECT obj_description('\"Sales Data\"'::regnamespace, 'pg_namespace')" on:destination], @"Sales, with a space");

		// The single table "Sales Data"."Orders 2026"
		destination = [self destinationOn:port];
		[self createPublicDependenciesOn:destination];
		path = [self dumpFrom:source named:@"table.sql" configure:^(SPPostgresDumpWriter *writer) {
			writer.tables = @[@[@"Sales Data", @"Orders 2026"]];
		}];
		dump = [self contentsOf:path];
		XCTAssertFalse([dump containsString:@"CREATE TYPE"]);
		XCTAssertFalse([dump containsString:@"CREATE FUNCTION"]);
		XCTAssertFalse([dump containsString:@"CREATE EXTENSION"]);
		XCTAssertFalse([dump containsString:@"order_lines"]);
		XCTAssertFalse([dump containsString:@"public.counter"]);
		[self import:path into:destination];

		actual = [self describe:destination];
		for (NSString *key in @[@"rows \"Sales Data\".\"Orders 2026\"", @"sequence \"Sales Data\".\"Orders 2026_id_seq\"", @"sequence \"Sales Data\".\"Orders 2026_seq_seq\""]) {
			XCTAssertEqualObjects(actual[key], expected[key], @"port %@: %@", port, key);
		}
		XCTAssertEqualObjects([self text:@"SELECT string_agg(indexname, ', ' ORDER BY indexname COLLATE \"C\") FROM pg_indexes WHERE schemaname = 'Sales Data'" on:destination],
							  @"Orders 2026 customer, Orders 2026_pkey, orders_noted");
		XCTAssertEqualObjects([self text:@"SELECT string_agg(conname, ', ' ORDER BY conname COLLATE \"C\") FROM pg_constraint WHERE conrelid = '\"Sales Data\".\"Orders 2026\"'::regclass AND contype IN ('p', 'f')" on:destination],
							  @"Orders 2026_parent_id_fkey, Orders 2026_pkey");
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_trigger WHERE tgname = 'orders_audit'" on:destination], @"1");
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'Sales Data' AND c.relkind <> 'i' AND c.relkind <> 'S'" on:destination], @"1");
	}
}

- (void)testStructureOnlyAndDataOnly
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		NSString *structurePath = [self dumpFrom:source named:@"structure.sql" configure:^(SPPostgresDumpWriter *writer) {
			writer.wholeDatabase = YES;
			writer.includeData = NO;
		}];
		NSString *dataPath = [self dumpFrom:source named:@"data.sql" configure:^(SPPostgresDumpWriter *writer) {
			writer.wholeDatabase = YES;
			writer.includeStructure = NO;
		}];

		NSString *structure = [self contentsOf:structurePath];
		XCTAssertFalse([structure containsString:@"COPY "]);
		XCTAssertFalse([structure containsString:@"setval"]);
		XCTAssertTrue([structure containsString:@"CREATE TABLE"]);
		NSString *data = [self contentsOf:dataPath];
		XCTAssertFalse([data containsString:@"CREATE"]);
		XCTAssertTrue([data containsString:@"COPY "]);

		PGPostgresConnection *destination = [self destinationOn:port];
		[self import:structurePath into:destination];
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM \"Sales Data\".\"Orders 2026\"" on:destination], @"0");
		[self import:dataPath into:destination];

		// The data loads into the structure: triggers didn't fire, foreign keys held, sequences match
		NSDictionary *expected = [self describe:source];
		NSDictionary *actual = [self describe:destination];
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM public.audit" on:destination], @"7");
		for (NSString *key in expected) {
			if ([key hasPrefix:@"rows "] && [key containsString:@"mv_"]) continue; // refreshed by the structure dump while empty
			if ([key hasPrefix:@"rows "] || [key hasPrefix:@"sequence "]) XCTAssertEqualObjects(actual[key], expected[key], @"port %@: %@", port, key);
		}
		XCTAssertEqualObjects(actual[@"triggers"], expected[@"triggers"]);
	}
}

- (void)testCompressedDump
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		NSString *path = [self dumpFrom:source named:@"whole.sql.gz" configure:^(SPPostgresDumpWriter *writer) {
			writer.wholeDatabase = YES;
			writer.compress = YES;
		}];
		NSData *data = [NSData dataWithContentsOfFile:path];
		XCTAssertTrue(data.length > 2);
		const unsigned char *bytes = data.bytes;
		XCTAssertEqual(bytes[0], 0x1f);
		XCTAssertEqual(bytes[1], 0x8b);

		PGPostgresConnection *destination = [self destinationOn:port];
		[self import:path into:destination];
		NSDictionary *expected = [self describe:source];
		NSDictionary *actual = [self describe:destination];
		XCTAssertEqualObjects(actual[@"rows \"Sales Data\".\"Orders 2026\""], expected[@"rows \"Sales Data\".\"Orders 2026\""]);
		XCTAssertEqualObjects(actual[@"rows public.events"], expected[@"rows public.events"]);
		XCTAssertEqualObjects(actual[@"sequence public.counter"], @"42 true");
	}
}

- (void)testCancelDeletesPartialFile
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		for (NSNumber *compress in @[@NO, @YES]) {
			SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:source];
			writer.wholeDatabase = YES;
			writer.compress = compress.boolValue;
			__block NSUInteger calls = 0;
			__block NSUInteger lastCount = 0;
			writer.progress = ^BOOL(NSUInteger tableIndex, NSUInteger tableCount, NSString *table) {
				calls++;
				lastCount = tableCount;
				XCTAssertEqual(tableIndex, calls);
				XCTAssertTrue(table.length > 0);
				return tableIndex < 2;
			};
			NSString *path = [self pathNamed:compress.boolValue ? @"cancelled.sql.gz" : @"cancelled.sql"];
			NSError *error = nil;
			XCTAssertFalse([writer writeToPath:path error:&error]);
			XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
			XCTAssertEqual(error.code, SPPostgresErrorCancelled);
			XCTAssertEqual(calls, 2);
			XCTAssertTrue(lastCount > 2);
			XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
			XCTAssertEqual(source.transactionStatus, PGPostgresTransactionIdle);
			XCTAssertEqualObjects([self text:@"SELECT 1::text" on:source], @"1");
		}
	}
}

- (void)testDumpIsConsistentSnapshot
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *other = [self kept:[SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]];

		SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:source];
		writer.wholeDatabase = YES;
		__block BOOL inserted = NO;
		writer.progress = ^BOOL(NSUInteger tableIndex, NSUInteger tableCount, NSString *table) {
			if (tableIndex == 1) {
				inserted = [other execute:@"INSERT INTO \"Sales Data\".\"Orders 2026\" (customer, qty, note) VALUES ('Zed', 1, 'inserted meanwhile')"] != nil;
				[other execute:@"INSERT INTO public.events VALUES (99, '2026-09-09', 'inserted meanwhile')"];
			}
			return YES;
		};
		NSString *path = [self pathNamed:@"snapshot.sql"];
		NSError *error = nil;
		XCTAssertTrue([writer writeToPath:path error:&error], @"%@", error.localizedDescription);
		XCTAssertTrue(inserted, @"%@", other.lastError.errorPrimaryMessage);
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM \"Sales Data\".\"Orders 2026\" WHERE customer = 'Zed'" on:source], @"1");

		NSString *dump = [self contentsOf:path];
		XCTAssertFalse([dump containsString:@"inserted meanwhile"]);
		XCTAssertFalse([dump containsString:@"Zed"]);
		XCTAssertTrue([dump containsString:@"Grace"]);
	}
}

- (void)testInvalidSettingsFailAtOnce
{
	PGPostgresConnection *source = [self sourceOn:[SPPostgresTestServers ports].firstObject];
	NSArray *configurations = @[
		^(SPPostgresDumpWriter *w) { w.schemas = @[]; },
		^(SPPostgresDumpWriter *w) { w.tables = @[]; },
		^(SPPostgresDumpWriter *w) { w.wholeDatabase = YES; w.includeStructure = NO; w.includeData = NO; },
		^(SPPostgresDumpWriter *w) { },
		^(SPPostgresDumpWriter *w) { w.wholeDatabase = YES; w.schemas = @[@"public"]; }
	];
	for (void (^configure)(SPPostgresDumpWriter *) in configurations) {
		SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:source];
		configure(writer);
		NSString *path = [self pathNamed:@"invalid.sql"];
		NSError *error = nil;
		XCTAssertFalse([writer writeToPath:path error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);
		XCTAssertTrue(error.localizedDescription.length > 0);
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
	}
}

/// Runs a whole-database dump to path with a writer released before the error is read: the error must outlive it.
- (NSString *)failedDumpMessageFrom:(PGPostgresConnection *)connection toPath:(NSString *)path compress:(BOOL)compress
{
	__autoreleasing NSError *error = nil; // not retained by this frame: only what the writer handed out keeps it
	NSString *message = nil;
	@autoreleasepool {
		SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:connection];
		writer.wholeDatabase = YES;
		writer.compress = compress;
		XCTAssertFalse([writer writeToPath:path error:&error]);
		writer = nil;
		message = [error.localizedDescription copy];
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
	}
	return message;
}

- (void)testWriteErrorsOutliveTheWriter
{
	PGPostgresConnection *source = [self sourceOn:[SPPostgresTestServers ports].lastObject];

	// The file can't be created
	NSString *missing = [self.directory stringByAppendingPathComponent:@"no such folder/dump.sql"];
	NSString *message = [self failedDumpMessageFrom:source toPath:missing compress:NO];
	XCTAssertTrue([message containsString:@"can't be written"], @"%@", message);
	XCTAssertEqual(source.transactionStatus, PGPostgresTransactionIdle);

	// A write fails part-way (the file size limit, EFBIG): the partial file is deleted
	for (NSNumber *compress in @[@NO, @YES]) {
		NSString *path = [self pathNamed:compress.boolValue ? @"limited.sql.gz" : @"limited.sql"];
		struct rlimit previous;
		XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &previous), 0);
		void (*previousHandler)(int) = signal(SIGXFSZ, SIG_IGN);
		struct rlimit limited = previous;
		limited.rlim_cur = 2048;
		XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limited), 0);
		message = [self failedDumpMessageFrom:source toPath:path compress:compress.boolValue];
		setrlimit(RLIMIT_FSIZE, &previous);
		signal(SIGXFSZ, previousHandler);

		XCTAssertTrue([message containsString:@"The file can't be written"], @"%@", message);
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
		XCTAssertEqual(source.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT 1::text" on:source], @"1");
	}
}

- (void)testCancelDuringLargeTableCopy
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		[self run:@"CREATE TABLE public.big AS SELECT g AS id, md5(g::text) AS label FROM generate_series(1, 200000) g" on:source];

		SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:source];
		writer.tables = @[@[@"public", @"big"]];
		__block NSUInteger calls = 0;
		writer.progress = ^BOOL(NSUInteger tableIndex, NSUInteger tableCount, NSString *table) {
			calls++;
			XCTAssertEqual(tableIndex, 1);
			XCTAssertEqual(tableCount, 1);
			XCTAssertEqualObjects(table, @"big");
			return calls < 3; // the first call is before the COPY; the third comes after 2 MiB of it
		};
		NSString *path = [self pathNamed:@"big.sql"];
		NSError *error = nil;
		XCTAssertFalse([writer writeToPath:path error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorCancelled, @"%@", error.localizedDescription);
		XCTAssertEqual(calls, 3);
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
		XCTAssertEqual(source.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM public.big" on:source], @"200000");

		// Uncancelled, the same table is written whole
		writer.progress = nil;
		XCTAssertTrue([writer writeToPath:path error:&error], @"%@", error.localizedDescription);
		XCTAssertTrue([[self contentsOf:path] containsString:@"200000\t"]);
	}
}

- (void)testPartitionedTableBringsItsPartitions
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		[self run:@"CREATE TABLE public.events_2027 PARTITION OF public.events FOR VALUES FROM ('2027-01-01') TO ('2028-01-01') PARTITION BY LIST (label)" on:source];
		[self run:@"CREATE TABLE public.events_2027_x PARTITION OF public.events_2027 FOR VALUES IN ('x')" on:source];
		[self run:@"INSERT INTO public.events VALUES (4, '2027-03-03', 'x')" on:source];

		PGPostgresConnection *destination = [self destinationOn:port];
		NSString *path = [self dumpFrom:source named:@"events.sql" configure:^(SPPostgresDumpWriter *writer) {
			writer.tables = @[@[@"public", @"events"]];
		}];
		[self import:path into:destination];

		NSString *(^counts)(PGPostgresConnection *) = ^NSString *(PGPostgresConnection *connection) {
			NSMutableArray *parts = [NSMutableArray array];
			for (NSString *table in @[@"events", @"events_2025", @"events_2026", @"events_2027", @"events_2027_x"]) {
				[parts addObject:[NSString stringWithFormat:@"%@=%@", table, [self text:[NSString stringWithFormat:@"SELECT count(*)::text FROM public.%@", table] on:connection]]];
			}
			return [parts componentsJoinedByString:@", "];
		};
		XCTAssertEqualObjects(counts(destination), @"events=4, events_2025=1, events_2026=2, events_2027=1, events_2027_x=1");
		XCTAssertEqualObjects(counts(destination), counts(source));
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_inherits WHERE inhparent IN ('public.events'::regclass, 'public.events_2027'::regclass)" on:destination], @"4");
	}
}

@end
