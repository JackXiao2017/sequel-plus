#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTransfer.h"
#import "../Source/Postgres/SPPostgresDumpObject.h"
#import "../Source/Postgres/SPPostgresErrors.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresBackgroundJob.h"

/// A transfer whose target lacks one available extension.
@interface SPPostgresTransferWithoutExtension : SPPostgresTransfer
@property (copy) NSString *unavailable;
@property NSUInteger calls;
@end

@implementation SPPostgresTransferWithoutExtension
- (NSArray *)availableExtensionsOnTarget:(NSError **)error
{
	self.calls++;
	NSMutableArray *names = [[super availableExtensionsOnTarget:error] mutableCopy];
	XCTAssertTrue([names containsObject:self.unavailable], @"%@", names);
	[names removeObject:self.unavailable];
	return names;
}
@end

/// The same-database check's identity (private).
@interface SPPostgresTransfer (IdentityForTests)
- (NSArray *)_identityOf:(PGPostgresConnection *)connection;
@end

/// SPPostgresTransfer between pgkit_io_src (io_source.sql) and pgkit_io_dst, on both ports and across them.
@interface SPPostgresTransferTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresTransferTests

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
- (PGPostgresConnection *)targetOn:(NSNumber *)port
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

/// The database described under the default search_path (a load leaves the target's session with an empty one).
- (NSDictionary *)describe:(PGPostgresConnection *)connection
{
	[self run:@"RESET search_path" on:connection];
	return [SPPostgresTestServers describeDatabase:connection];
}

- (SPPostgresTransfer *)transferFrom:(PGPostgresConnection *)source to:(PGPostgresConnection *)target
{
	SPPostgresTransfer *transfer = [[SPPostgresTransfer alloc] initWithSource:source target:target];
	transfer.temporaryDirectory = self.directory;
	return transfer;
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)assertTemporaryDirectoryEmpty
{
	NSArray *left = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL];
	XCTAssertEqualObjects(left, @[], @"the transfer's file is deleted");
}

- (void)assertIdle:(PGPostgresConnection *)connection
{
	XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
}

- (NSArray<NSString *> *)orderTables
{
	return @[@"Sales Data", @"Orders 2026"];
}

/// A one-row table public.marker on the target.
- (void)addMarkerTo:(PGPostgresConnection *)target
{
	[self run:@"CREATE TABLE public.marker (note text)" on:target];
	[self run:@"INSERT INTO public.marker VALUES ('still here')" on:target];
}

- (void)assertMarkerOn:(PGPostgresConnection *)target
{
	[self run:@"RESET search_path" on:target];
	XCTAssertEqualObjects([self text:@"SELECT string_agg(note, ',') FROM public.marker" on:target], @"still here");
}

static SPPostgresDumpObject *SPObject(NSString *kind, NSString *schema, NSString *name)
{
	return [SPPostgresDumpObject objectWithKind:kind schema:schema name:name arguments:nil];
}

static NSString *const SPPublicComment = @"schema public = standard public schema";

/// The description without Empty mode's comment on the recreated public (ruling P1).
- (NSDictionary *)withoutPublicComment:(NSDictionary *)description
{
	NSMutableDictionary *copy = [description mutableCopy];
	NSMutableArray *lines = [[description[@"comments"] componentsSeparatedByString:@"\n"] mutableCopy];
	[lines removeObject:SPPublicComment];
	copy[@"comments"] = [lines componentsJoinedByString:@"\n"];
	return copy;
}

#pragma mark - Statements

- (void)testEmptyingStatements
{
	NSArray *statements = [SPPostgresTransfer emptyingStatementsForSchemas:@[@"public", @"Sales Data"] extensions:@[@"citext", @"pg_trgm"] serverVersion:150000];
	XCTAssertEqualObjects(statements, (@[@"DROP EXTENSION IF EXISTS \"citext\", \"pg_trgm\" CASCADE",
										 @"DROP SCHEMA IF EXISTS \"public\", \"Sales Data\" CASCADE",
										 @"CREATE SCHEMA public",
										 @"ALTER SCHEMA public OWNER TO pg_database_owner",
										 @"GRANT USAGE ON SCHEMA public TO PUBLIC",
										 @"COMMENT ON SCHEMA public IS 'standard public schema'"]));

	statements = [SPPostgresTransfer emptyingStatementsForSchemas:@[@"public", @"Sales Data"] extensions:@[@"citext", @"pg_trgm"] serverVersion:140000];
	XCTAssertEqualObjects(statements, (@[@"DROP EXTENSION IF EXISTS \"citext\", \"pg_trgm\" CASCADE",
										 @"DROP SCHEMA IF EXISTS \"public\", \"Sales Data\" CASCADE",
										 @"CREATE SCHEMA public",
										 @"GRANT CREATE, USAGE ON SCHEMA public TO PUBLIC",
										 @"COMMENT ON SCHEMA public IS 'standard public schema'"]));

	statements = [SPPostgresTransfer emptyingStatementsForSchemas:@[@"public"] extensions:@[] serverVersion:120000];
	XCTAssertEqualObjects(statements, (@[@"DROP SCHEMA IF EXISTS \"public\" CASCADE",
										 @"CREATE SCHEMA public",
										 @"GRANT CREATE, USAGE ON SCHEMA public TO PUBLIC",
										 @"COMMENT ON SCHEMA public IS 'standard public schema'"]));
}

- (void)testDropStatementsOrderAndKinds
{
	NSArray *objects = @[
		SPObject(SPPostgresDumpObjectType, @"a", @"ty"),
		SPObject(SPPostgresDumpObjectTable, @"a", @"t1"),
		[SPPostgresDumpObject objectWithKind:SPPostgresDumpObjectRoutine schema:@"public" name:@"f" arguments:@"integer, text"],
		SPObject(SPPostgresDumpObjectDomain, @"a", @"d"),
		SPObject(SPPostgresDumpObjectExtension, @"public", @"citext"),
		SPObject(SPPostgresDumpObjectView, @"a", @"v"),
		SPObject(SPPostgresDumpObjectTable, @"a", @"t2"),
	];
	NSArray *statements = [SPPostgresTransfer dropStatementsForObjects:objects];
	XCTAssertEqualObjects(statements, (@[@"DROP VIEW IF EXISTS \"a\".\"v\"",
										 @"DROP TABLE IF EXISTS \"a\".\"t1\", \"a\".\"t2\"",
										 @"DROP ROUTINE IF EXISTS \"public\".\"f\"(integer, text)",
										 @"DROP DOMAIN IF EXISTS \"a\".\"d\"",
										 @"DROP TYPE IF EXISTS \"a\".\"ty\""]));
	for (NSString *statement in statements) XCTAssertFalse([statement containsString:@"CASCADE"], @"%@", statement);

	statements = [SPPostgresTransfer dropStatementsForObjects:@[
		SPObject(SPPostgresDumpObjectSequence, @"s", @"q"), SPObject(SPPostgresDumpObjectForeignTable, @"s", @"f"),
		[SPPostgresDumpObject objectWithKind:SPPostgresDumpObjectRoutine schema:@"s" name:@"g" arguments:@""],
		SPObject(SPPostgresDumpObjectMaterializedView, @"s", @"m")]];
	XCTAssertEqualObjects(statements, (@[@"DROP MATERIALIZED VIEW IF EXISTS \"s\".\"m\"",
										 @"DROP FOREIGN TABLE IF EXISTS \"s\".\"f\"",
										 @"DROP SEQUENCE IF EXISTS \"s\".\"q\"",
										 @"DROP ROUTINE IF EXISTS \"s\".\"g\"()"]));
	XCTAssertEqualObjects([SPPostgresTransfer dropStatementsForObjects:@[]], @[]);
}

#pragma mark - Empty mode

- (void)testWholeDatabaseIntoEmptiedTarget
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		[self run:@"CREATE SCHEMA junk" on:target];
		[self run:@"CREATE TABLE junk.t (i int)" on:target];
		[self run:@"CREATE TABLE public.leftover (i int)" on:target];
		[self run:@"CREATE EXTENSION pg_trgm WITH SCHEMA public" on:target];

		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.wholeDatabase = YES;
		NSMutableArray *phases = [NSMutableArray array];
		transfer.progress = ^BOOL(SPPostgresTransferPhase phase, double fraction, NSString *detail) {
			XCTAssertTrue(fraction >= 0 && fraction <= 1, @"%f", fraction);
			if (![phases.lastObject isEqual:@(phase)]) [phases addObject:@(phase)];
			return YES;
		};
		NSError *error = nil;
		XCTAssertTrue([transfer run:&error], @"port %@: %@", port, error.localizedDescription);
		XCTAssertEqualObjects(phases, (@[@(SPPostgresTransferChecking), @(SPPostgresTransferReading), @(SPPostgresTransferWriting)]));
		[self assertIdle:source];
		[self assertIdle:target];
		[self assertTemporaryDirectoryEmpty];

		[SPPostgresTestServers assertDescription:[self withoutPublicComment:[self describe:target]]
										  equals:[self withoutPublicComment:[self describe:source]]
										 context:[NSString stringWithFormat:@"port %@", port]];
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_namespace WHERE nspname = 'junk'" on:target], @"0");
		XCTAssertEqualObjects([self text:@"SELECT (to_regclass('public.leftover') IS NULL)::text" on:target], @"true");
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_extension WHERE extname = 'pg_trgm'" on:target], @"0");
		if (target.serverVersion >= 150000) {
			XCTAssertEqualObjects([self text:@"SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'public'" on:target], @"pg_database_owner");
		}
		// Orders 2026, order_lines, audit, events_2025 and events_2026 (events is partitioned: no rows of its own)
		XCTAssertEqual(transfer.tablesCopied, 5u);
		XCTAssertEqualObjects(transfer.replacedObjects, @[]);
		XCTAssertEqualObjects(transfer.dependenciesCreated, @[]);
		XCTAssertEqualObjects(transfer.foreignTablesSkipped, @[]);
		XCTAssertEqualObjects(transfer.skippedSettings, @[]);
	}
}

- (void)testSelectedTablesIntoEmptiedTarget
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.tables = @[[self orderTables], @[@"Sales Data", @"order_lines"]];
		NSError *error = nil;
		XCTAssertTrue([transfer run:&error], @"port %@: %@", port, error.localizedDescription);
		[self assertTemporaryDirectoryEmpty];

		NSDictionary *expected = [self describe:source];
		NSDictionary *actual = [self describe:target];
		for (NSString *key in @[@"rows \"Sales Data\".\"Orders 2026\"", @"rows \"Sales Data\".order_lines"]) {
			XCTAssertNotNil(expected[key], @"%@", key);
			XCTAssertEqualObjects(actual[key], expected[key], @"port %@: %@", port, key);
		}
		XCTAssertEqualObjects([NSSet setWithArray:transfer.dependenciesCreated],
							  ([NSSet setWithArray:@[@"extension citext", @"type public.mood", @"type public.address", @"domain public.posint", @"routine public.audit_row()"]]),
							  @"%@", transfer.dependenciesCreated);
		XCTAssertEqual(transfer.dependenciesCreated.count, 5u);
		XCTAssertEqualObjects([self text:@"SELECT (to_regclass('public.audit') IS NULL)::text" on:target], @"true", @"the trigger's table isn't copied");
		XCTAssertEqual(transfer.tablesCopied, 2u);
		XCTAssertEqualObjects(transfer.replacedObjects, @[]);
	}
}

#pragma mark - Overwrite mode

/// The target holds an older copy of the tables (made by an Empty-mode transfer), cut to one row each.
- (void)copyTables:(NSArray *)tables from:(PGPostgresConnection *)source to:(PGPostgresConnection *)target
{
	SPPostgresTransfer *earlier = [self transferFrom:source to:target];
	earlier.tables = tables;
	NSError *error = nil;
	XCTAssertTrue([earlier run:&error], @"%@", error.localizedDescription);
	[self run:@"RESET search_path" on:target];
	if ([tables containsObject:@[@"Sales Data", @"order_lines"]]) [self run:@"DELETE FROM \"Sales Data\".order_lines WHERE item <> 'widget'" on:target];
	[self run:@"DELETE FROM \"Sales Data\".\"Orders 2026\" WHERE id <> 1" on:target];
}

- (void)testOverwriteReplacesOnlyCopiedTables
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		NSArray *tables = @[[self orderTables], @[@"Sales Data", @"order_lines"]];
		[self copyTables:tables from:source to:target];
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM \"Sales Data\".\"Orders 2026\"" on:target], @"1");
		[self run:@"CREATE TABLE public.keep (note text)" on:target];
		[self run:@"INSERT INTO public.keep VALUES ('kept')" on:target];

		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.tables = tables;
		transfer.mode = SPPostgresTransferOverwrite;
		NSError *error = nil;
		XCTAssertTrue([transfer run:&error], @"port %@: %@", port, error.localizedDescription);
		[self assertIdle:target];
		[self assertTemporaryDirectoryEmpty];

		NSDictionary *expected = [self describe:source];
		NSDictionary *actual = [self describe:target];
		for (NSString *key in @[@"rows \"Sales Data\".\"Orders 2026\"", @"rows \"Sales Data\".order_lines"]) {
			XCTAssertEqualObjects(actual[key], expected[key], @"port %@: %@", port, key);
		}
		XCTAssertEqualObjects([self text:@"SELECT string_agg(note, ',') FROM public.keep" on:target], @"kept");
		XCTAssertEqualObjects([NSSet setWithArray:transfer.replacedObjects],
							  ([NSSet setWithArray:@[@"table \"Sales Data\".\"Orders 2026\"", @"table \"Sales Data\".order_lines",
													 @"sequence \"Sales Data\".\"Orders 2026_seq_seq\"", @"sequence \"Sales Data\".order_lines_id_seq"]]),
							  @"%@", transfer.replacedObjects);
		XCTAssertEqual(transfer.replacedObjects.count, 4u);
		XCTAssertEqualObjects(transfer.dependenciesCreated, @[], @"every dependency was already there");
		XCTAssertEqual(transfer.tablesCopied, 2u);
	}
}

- (void)testExistingDependenciesAreReused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		[self run:@"CREATE TYPE public.mood AS ENUM ('sad', 'ok', 'happy')" on:target];
		[self run:@"CREATE TABLE public.other (m public.mood)" on:target];
		[self run:@"INSERT INTO public.other VALUES ('ok')" on:target];
		NSString *moodOid = [self text:@"SELECT 'public.mood'::regtype::oid::text" on:target];

		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.tables = @[[self orderTables]];
		transfer.mode = SPPostgresTransferOverwrite;
		NSError *error = nil;
		XCTAssertTrue([transfer run:&error], @"port %@: %@", port, error.localizedDescription);
		[self assertTemporaryDirectoryEmpty];

		[self run:@"RESET search_path" on:target];
		XCTAssertEqualObjects([self text:@"SELECT string_agg(m::text, ',') FROM public.other" on:target], @"ok");
		XCTAssertEqualObjects([self text:@"SELECT 'public.mood'::regtype::oid::text" on:target], moodOid);
		XCTAssertFalse([transfer.dependenciesCreated containsObject:@"type public.mood"], @"%@", transfer.dependenciesCreated);
		XCTAssertTrue([transfer.dependenciesCreated containsObject:@"type public.address"], @"%@", transfer.dependenciesCreated);
		XCTAssertEqualObjects(transfer.replacedObjects, @[]);
		NSDictionary *expected = [self describe:source];
		XCTAssertEqualObjects([self describe:target][@"rows \"Sales Data\".\"Orders 2026\""], expected[@"rows \"Sales Data\".\"Orders 2026\""]);
	}
}

- (void)testOverwriteStopsAndListsWhatIsInTheWay
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		[self copyTables:@[[self orderTables]] from:source to:target];
		[self run:@"CREATE VIEW public.report AS SELECT id FROM \"Sales Data\".\"Orders 2026\"" on:target];
		[self run:@"CREATE TABLE public.refs (order_id int REFERENCES \"Sales Data\".\"Orders 2026\" (id))" on:target];
		NSDictionary *before = [self describe:target];

		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.tables = @[[self orderTables]];
		transfer.mode = SPPostgresTransferOverwrite;
		NSMutableSet *phases = [NSMutableSet set];
		transfer.progress = ^BOOL(SPPostgresTransferPhase phase, double fraction, NSString *detail) {
			[phases addObject:@(phase)];
			return YES;
		};
		NSError *error = nil;
		XCTAssertFalse([transfer run:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorHasDependents, @"%@", error.localizedDescription);
		NSString *dependents = [error.userInfo[SPPostgresDependentsErrorKey] componentsJoinedByString:@"\n"];
		XCTAssertTrue([dependents containsString:@"public.report"], @"%@", dependents);
		XCTAssertTrue([dependents containsString:@"public.refs"], @"%@", dependents);
		XCTAssertFalse([phases containsObject:@(SPPostgresTransferReading)], @"stopped before reading the source");
		[self assertIdle:target];
		[self assertTemporaryDirectoryEmpty];
		[SPPostgresTestServers assertDescription:[self describe:target] equals:before context:[NSString stringWithFormat:@"port %@", port]];
	}
}

#pragma mark - Refusals and failures

- (void)testSameDatabaseRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *again = [self kept:[SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]];
		NSDictionary *before = [self describe:source];

		SPPostgresTransfer *transfer = [self transferFrom:source to:again];
		transfer.wholeDatabase = YES;
		NSError *error = nil;
		XCTAssertFalse([transfer run:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorTransferRefused, @"%@", error.localizedDescription);
		XCTAssertEqualObjects(error.localizedDescription, @"The target is the database being copied.");
		[self assertIdle:source];
		[self assertIdle:again];
		[self assertTemporaryDirectoryEmpty];
		[SPPostgresTestServers assertDescription:[self describe:source] equals:before context:[NSString stringWithFormat:@"port %@", port]];
	}
}

/// The identity is the system identifier, the postmaster's start time (a physical clone shares the identifier but
/// not the running server) and the database: equal for two sessions on one database, different across databases.
- (void)testIdentityIncludesServerStartTime
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self kept:[SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]];
		PGPostgresConnection *again = [self kept:[SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]];
		PGPostgresConnection *target = [self targetOn:port];
		// A different time zone on one session doesn't change the start time read
		[self run:@"SET TIME ZONE 'Pacific/Kiritimati'" on:again];
		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		NSArray *identity = [transfer _identityOf:source];
		XCTAssertEqual(identity.count, 3u, @"%@", identity);
		XCTAssertEqualObjects(identity[0], [self text:@"SELECT system_identifier::text FROM pg_catalog.pg_control_system()" on:source]);
		XCTAssertEqualObjects(identity[1], [self text:@"SELECT (EXTRACT(EPOCH FROM pg_catalog.pg_postmaster_start_time()) * 1000000)::bigint::text" on:source]);
		XCTAssertEqualObjects(identity[2], @"pgkit_io_src");
		XCTAssertEqualObjects([transfer _identityOf:again], identity);
		NSArray *targetIdentity = [transfer _identityOf:target];
		XCTAssertEqualObjects([targetIdentity subarrayWithRange:NSMakeRange(0, 2)], [identity subarrayWithRange:NSMakeRange(0, 2)]);
		XCTAssertEqualObjects(targetIdentity[2], @"pgkit_io_dst");
		[self assertIdle:source];
		[self assertIdle:again];
		[self assertIdle:target];
	}
}

- (void)testMissingExtensionRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		[self run:@"CREATE EXTENSION pg_trgm WITH SCHEMA public" on:source];
		PGPostgresConnection *target = [self targetOn:port];
		[self addMarkerTo:target];
		NSDictionary *before = [self describe:target];

		SPPostgresTransferWithoutExtension *transfer = [[SPPostgresTransferWithoutExtension alloc] initWithSource:source target:target];
		transfer.temporaryDirectory = self.directory;
		transfer.unavailable = @"pg_trgm";
		transfer.wholeDatabase = YES;
		NSError *error = nil;
		XCTAssertFalse([transfer run:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorTransferRefused, @"%@", error.localizedDescription);
		XCTAssertEqualObjects(error.userInfo[SPPostgresObjectsErrorKey], @[@"pg_trgm"]);
		XCTAssertTrue([error.localizedDescription containsString:@"pg_trgm"], @"%@", error.localizedDescription);
		XCTAssertEqual(transfer.calls, 1u);
		[self assertIdle:target];
		[self assertTemporaryDirectoryEmpty];
		[SPPostgresTestServers assertDescription:[self describe:target] equals:before context:[NSString stringWithFormat:@"port %@", port]];
	}
}

- (void)testFailedLoadLeavesTargetUnchanged
{
	// PG 18's BEGIN ATOMIC function (public.order_count) can't be created on PG 12
	PGPostgresConnection *source = [self sourceOn:@55418];
	PGPostgresConnection *target = [self targetOn:@55412];
	[self addMarkerTo:target];
	NSDictionary *before = [self describe:target];

	SPPostgresTransfer *transfer = [self transferFrom:source to:target];
	transfer.wholeDatabase = YES;
	NSError *error = nil;
	XCTAssertFalse([transfer run:&error]);
	XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
	XCTAssertEqual(error.code, SPPostgresErrorQueryFailed, @"%@", error.localizedDescription);
	XCTAssertTrue([error.localizedDescription hasPrefix:@"Line "], @"the importer's error: %@", error.localizedDescription);
	[self assertIdle:target];
	[self assertTemporaryDirectoryEmpty];
	[self assertMarkerOn:target];
	[SPPostgresTestServers assertDescription:[self describe:target] equals:before context:@"18 → 12"];
}

- (void)testCrossVersion12To18
{
	PGPostgresConnection *source = [self sourceOn:@55412];
	PGPostgresConnection *target = [self targetOn:@55418];
	SPPostgresTransfer *transfer = [self transferFrom:source to:target];
	transfer.wholeDatabase = YES;
	NSError *error = nil;
	XCTAssertTrue([transfer run:&error], @"%@", error.localizedDescription);
	[self assertTemporaryDirectoryEmpty];

	NSDictionary *expected = [self describe:source];
	NSDictionary *actual = [self describe:target];
	NSUInteger compared = 0;
	for (NSString *key in expected) {
		if (![key hasPrefix:@"rows "] && ![key hasPrefix:@"sequence "]) continue;
		XCTAssertEqualObjects(actual[key], expected[key], @"12 → 18: %@", key);
		compared++;
	}
	XCTAssertGreaterThan(compared, 8u);
	XCTAssertEqual(transfer.tablesCopied, 5u);
}

- (void)testCancelWhileReadingLeavesTargetUnchanged
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		[self addMarkerTo:target];
		NSDictionary *before = [self describe:target];

		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.wholeDatabase = YES;
		__block NSString *cancelledAt = nil;
		transfer.progress = ^BOOL(SPPostgresTransferPhase phase, double fraction, NSString *detail) {
			XCTAssertNotEqual(phase, SPPostgresTransferWriting);
			if (phase == SPPostgresTransferReading && fraction > 0) {
				cancelledAt = detail;
				return NO;
			}
			return YES;
		};
		NSError *error = nil;
		XCTAssertFalse([transfer run:&error]);
		XCTAssertNotNil(cancelledAt, @"cancelled at the second table");
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorCancelled, @"%@", error.localizedDescription);
		[self assertIdle:source];
		[self assertIdle:target];
		[self assertTemporaryDirectoryEmpty];
		[self assertMarkerOn:target];
		[SPPostgresTestServers assertDescription:[self describe:target] equals:before context:[NSString stringWithFormat:@"port %@", port]];
	}
}

/// Empty mode, cancelled from the progress block once the load has started (the emptying statements, with their
/// CASCADE, already ran in the target's transaction): everything rolls back.
- (void)testCancelWhileWritingLeavesTargetUnchanged
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		PGPostgresConnection *target = [self targetOn:port];
		[self addMarkerTo:target];
		NSDictionary *before = [self describe:target];

		SPPostgresTransfer *transfer = [self transferFrom:source to:target];
		transfer.wholeDatabase = YES;
		XCTAssertEqual(transfer.mode, SPPostgresTransferEmptyTarget);
		__block BOOL cancelled = NO;
		__block BOOL markerGoneInTransaction = NO;
		transfer.progress = ^BOOL(SPPostgresTransferPhase phase, double fraction, NSString *detail) {
			if (phase == SPPostgresTransferWriting && fraction > 0) {
				// The emptying ran: inside the load's transaction the marker is gone
				markerGoneInTransaction = target.transactionStatus == PGPostgresTransactionInTransaction
					&& [[self text:@"SELECT count(*)::text FROM pg_catalog.pg_class WHERE relname = 'marker'" on:target] isEqualToString:@"0"];
				cancelled = YES;
				return NO;
			}
			return YES;
		};
		NSError *error = nil;
		XCTAssertFalse([transfer run:&error]);
		XCTAssertTrue(cancelled, @"cancelled while writing");
		XCTAssertTrue(markerGoneInTransaction, @"the emptying statements had run when the cancel came");
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorCancelled, @"%@", error.localizedDescription);
		[self assertIdle:source];
		[self assertIdle:target];
		[self assertTemporaryDirectoryEmpty];
		[self assertMarkerOn:target];
		[SPPostgresTestServers assertDescription:[self describe:target] equals:before context:[NSString stringWithFormat:@"port %@", port]];
	}
}

/// The same through SPPostgresBackgroundJob, as the sheet runs it: Cancel (the flag, then -cancel) comes while a
/// statement of the load is running on the target (a CHECK that sleeps there), and PQcancel interrupts it.
- (void)testJobCancelWhileWritingInterruptsLoad
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self sourceOn:port];
		// Sleeps only when evaluated in pgkit_io_dst, i.e. while the load fills public.slow there
		[self run:@"CREATE FUNCTION public.slow_on_target(i integer) RETURNS boolean LANGUAGE sql"
		 " AS $$SELECT CASE WHEN current_database() = 'pgkit_io_dst' THEN pg_sleep(60) IS NOT NULL ELSE true END$$" on:source];
		[self run:@"CREATE TABLE public.slow (i integer CHECK (public.slow_on_target(i)))" on:source];
		[self run:@"INSERT INTO public.slow VALUES (1)" on:source];
		PGPostgresConnection *target = [self targetOn:port];
		[self addMarkerTo:target];
		NSDictionary *before = [self describe:target];

		SPPostgresConnectionProvider (^provider)(void) = ^SPPostgresConnectionProvider(void) {
			return ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
				completion([self kept:[SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:database]], nil);
			};
		};
		__block volatile BOOL cancelRequested = NO;
		__block volatile BOOL writing = NO;
		__block BOOL finished = NO, ok = YES, targetIdleAfterRun = NO;
		__block NSError *failure = nil;
		NSString *directory = self.directory;
		SPPostgresBackgroundJob *job = [SPPostgresBackgroundJob runOnDatabase:@"pgkit_io_src" provider:provider() targetDatabase:@"pgkit_io_dst" targetProvider:provider() work:^BOOL(PGPostgresConnection *jobSource, PGPostgresConnection *jobTarget, NSError **error) {
			SPPostgresTransfer *transfer = [[SPPostgresTransfer alloc] initWithSource:jobSource target:jobTarget];
			transfer.temporaryDirectory = directory;
			transfer.wholeDatabase = YES;
			transfer.progress = ^BOOL(SPPostgresTransferPhase phase, double fraction, NSString *detail) {
				if (phase == SPPostgresTransferWriting && fraction > 0) writing = YES;
				return !cancelRequested;
			};
			BOOL transferred = [transfer run:error];
			targetIdleAfterRun = jobTarget.transactionStatus == PGPostgresTransactionIdle;
			return transferred;
		} completion:^(BOOL done, NSError *error) {
			ok = done;
			failure = error;
			finished = YES;
		}];

		// Once the load is under way and the target's backend sleeps in the CHECK
		PGPostgresConnection *monitor = [self kept:[SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]];
		BOOL sleeping = [self spinUntil:^BOOL{
			return writing && [[self text:@"SELECT count(*)::text FROM pg_catalog.pg_stat_activity WHERE datname = 'pgkit_io_dst' AND wait_event = 'PgSleep'" on:monitor] isEqualToString:@"1"];
		} timeout:60];
		XCTAssertTrue(sleeping, @"the load runs the sleeping CHECK (finished: %d, %@)", finished, failure.localizedDescription);

		NSDate *cancelledAt = [NSDate date];
		cancelRequested = YES;
		[job cancel];
		XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:10], @"the job ends soon after Cancel");
		XCTAssertLessThan(-[cancelledAt timeIntervalSinceNow], 10.0, @"the running statement was interrupted");
		XCTAssertFalse(ok);
		XCTAssertEqualObjects(failure.domain, SPPostgresErrorDomain);
		XCTAssertEqual(failure.code, SPPostgresErrorCancelled, @"%@", failure.localizedDescription);
		XCTAssertTrue(targetIdleAfterRun, @"no transaction left open on the target");
		[self assertTemporaryDirectoryEmpty];
		[self assertIdle:target];
		[self assertMarkerOn:target];
		XCTAssertEqualObjects([self text:@"SELECT count(*)::text FROM pg_catalog.pg_stat_activity WHERE datname = 'pgkit_io_dst' AND state LIKE 'idle in transaction%'" on:monitor], @"0");
		[SPPostgresTestServers assertDescription:[self describe:target] equals:before context:[NSString stringWithFormat:@"port %@", port]];
	}
}

@end
