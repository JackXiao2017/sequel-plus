#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresExtensions.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPExtensionStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPExtensionStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	[self.statements addObject:[query description]];
}
@end

/// SPPostgresExtensions, on PG 12 and 18, in database pgkit_ext.
@interface SPPostgresExtensionsTests : XCTestCase
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray *recorders;
@end

@implementation SPPostgresExtensionsTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.recorders = [NSMutableArray array];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	self.recorders = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue];
		[connection execute:@"DROP TABLE IF EXISTS public.sp_t5_items"];
		[connection execute:@"DROP SCHEMA IF EXISTS \"Sales Data\" CASCADE"];
		[connection disconnect];
	}
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

/// A connection to pgkit_ext (prepared by extensionTestConnectionOnPort:) whose statements recorder captures.
- (PGPostgresConnection *)connectOn:(NSNumber *)port recorder:(SPExtensionStatementRecorder **)recorder
{
	[[self connectOn:port] disconnect];
	SPExtensionStatementRecorder *newRecorder = [[SPExtensionStatementRecorder alloc] init];
	[self.recorders addObject:newRecorder]; // the connection doesn't retain its delegate
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_ext" delegate:newRecorder];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	*recorder = newRecorder;
	return connection;
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (NSArray *)installedNames:(SPPostgresExtensions *)extensions
{
	NSError *error = nil;
	NSArray *installed = [extensions installedExtensions:&error];
	XCTAssertNotNil(installed, @"%@", error);
	return [installed valueForKey:@"name"];
}

- (SPPostgresExtension *)extension:(NSString *)name of:(SPPostgresExtensions *)extensions
{
	NSError *error = nil;
	SPPostgresExtension *extension = [extensions extensionNamed:name error:&error];
	XCTAssertNotNil(extension, @"%@: %@", name, error);
	return extension;
}

- (void)install:(NSString *)name version:(NSString *)version schema:(NSString *)schema in:(SPPostgresExtensions *)extensions
{
	NSError *error = nil;
	XCTAssertTrue([extensions installExtension:name version:version schema:schema error:&error], @"%@: %@", name, error);
}

/// Versions in ascending NSNumericSearch order.
- (NSArray *)numericallySorted:(NSArray *)versions
{
	return [versions sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b options:NSNumericSearch]; }];
}

#pragma mark - Reading

- (void)testInstalledAndAvailableLists
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		[self install:@"citext" version:nil schema:@"public" in:extensions];

		NSArray *installed = [extensions installedExtensions:NULL];
		XCTAssertEqualObjects([installed valueForKey:@"name"], (@[@"citext", @"plpgsql"]), @"%@", port);
		SPPostgresExtension *citext = [self extension:@"citext" of:extensions];
		XCTAssertEqualObjects(citext.schema, @"public");
		XCTAssertEqualObjects(citext.version, [self value:@"SELECT extversion::text FROM pg_extension WHERE extname = 'citext'" on:connection]);
		XCTAssertEqualObjects(citext.defaultVersion, citext.version);
		XCTAssertNotNil(citext.comment);
		XCTAssertTrue(citext.relocatable);
		XCTAssertEqualObjects(citext.requiredBy, @[]);

		NSError *error = nil;
		NSArray *available = [extensions availableExtensions:&error];
		XCTAssertNotNil(available, @"%@", error);
		NSArray *names = [available valueForKey:@"name"];
		XCTAssertFalse([names containsObject:@"citext"]);
		XCTAssertFalse([names containsObject:@"plpgsql"]);
		XCTAssertEqualObjects(names, [names sortedArrayUsingSelector:@selector(compare:)]);
		NSUInteger index = [names indexOfObject:@"hstore"];
		XCTAssertNotEqual(index, NSNotFound);
		SPPostgresAvailableExtension *hstore = available[index];
		XCTAssertTrue([hstore.versions containsObject:@"1.4"], @"%@", hstore.versions);
		XCTAssertTrue([hstore.versions containsObject:hstore.defaultVersion]);
		XCTAssertEqualObjects(hstore.versions, [self numericallySorted:hstore.versions]);
		XCTAssertNotNil(hstore.comment);
		XCTAssertNil(hstore.fixedSchema);
	}
}

#pragma mark - Installing and updating

- (void)testInstallWithVersionThenUpdate
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		[self install:@"hstore" version:@"1.4" schema:@"public" in:extensions];
		SPPostgresExtension *hstore = [self extension:@"hstore" of:extensions];
		XCTAssertEqualObjects(hstore.version, @"1.4", @"%@", port);
		XCTAssertEqualObjects(hstore.schema, @"public");

		NSError *error = nil;
		NSArray *targets = [extensions updateTargetsForExtension:@"hstore" error:&error];
		XCTAssertNotNil(targets, @"%@", error);
		XCTAssertTrue([targets containsObject:@"1.5"], @"%@", targets);
		XCTAssertTrue([targets containsObject:hstore.defaultVersion], @"%@", targets);
		// Sorted as version numbers (1.10 after 1.9), not in the server's directory order
		XCTAssertEqualObjects(targets, [self numericallySorted:targets]);

		XCTAssertTrue([extensions updateExtension:@"hstore" toVersion:hstore.defaultVersion error:&error], @"%@", error);
		hstore = [self extension:@"hstore" of:extensions];
		XCTAssertEqualObjects(hstore.version, hstore.defaultVersion);
		XCTAssertEqualObjects([extensions updateTargetsForExtension:@"hstore" error:&error], @[], @"%@", error);
	}
}

- (void)testInstallInstallsMissingRequirementsFirst
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		NSError *error = nil;
		XCTAssertEqualObjects([extensions missingRequirementsForExtension:@"earthdistance" version:nil error:&error], @[@"cube"], @"%@ %@", port, error);
		XCTAssertEqualObjects([extensions missingRequirementsForExtension:@"citext" version:nil error:&error], @[], @"%@", error);

		XCTAssertTrue([extensions installExtension:@"earthdistance" version:nil schema:@"public" error:&error], @"%@", error);
		XCTAssertEqualObjects([self installedNames:extensions], (@[@"cube", @"earthdistance", @"plpgsql"]));
		XCTAssertEqualObjects([self extension:@"cube" of:extensions].requiredBy, @[@"earthdistance"]);
		XCTAssertEqualObjects([self extension:@"cube" of:extensions].schema, @"public");
		XCTAssertEqualObjects([self extension:@"earthdistance" of:extensions].requiredBy, @[]);
		XCTAssertEqualObjects([extensions missingRequirementsForExtension:@"earthdistance" version:nil error:&error], @[], @"%@", error);
	}
}

- (void)testFailedInstallLeavesNothingInstalled
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		NSError *error = nil;
		XCTAssertFalse([extensions installExtension:@"earthdistance" version:@"9.9" schema:nil error:&error], @"%@", port);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"9.9"] || [error.localizedDescription containsString:@"cube"], @"%@", error);
		XCTAssertEqualObjects([self installedNames:extensions], @[@"plpgsql"]);
		XCTAssertNil([extensions extensionNamed:@"cube" error:&error]);
		XCTAssertNil(error);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
	}
}

/// cube installs, then earthdistance's CREATE fails (a function earth() is in the way): cube is rolled back too.
- (void)testFailedInstallRollsBackInstalledRequirement
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		XCTAssertNotNil([connection execute:@"CREATE FUNCTION public.earth() RETURNS float8 LANGUAGE sql AS 'SELECT 1::float8'"], @"%@", connection.lastError.errorPrimaryMessage);
		[self addTeardownBlock:^{
			PGPostgresConnection *cleanup = [SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue];
			[cleanup execute:@"DROP FUNCTION IF EXISTS public.earth()"];
			[cleanup disconnect];
		}];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];

		NSError *error = nil;
		XCTAssertFalse([extensions installExtension:@"earthdistance" version:nil schema:@"public" error:&error], @"%@", port);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"earth"], @"%@", error);
		XCTAssertEqualObjects([self installedNames:extensions], @[@"plpgsql"]);
		XCTAssertNil([extensions extensionNamed:@"cube" error:&error]);
		XCTAssertNil(error);
		XCTAssertNil([extensions extensionNamed:@"earthdistance" error:&error]);
		XCTAssertNil(error);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);

		XCTAssertNotNil([connection execute:@"DROP FUNCTION public.earth()"], @"%@", connection.lastError.errorPrimaryMessage);
	}
}

#pragma mark - Dropping

- (void)testDropWithDependentsIsRefusedAndListsThem
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		[self install:@"hstore" version:nil schema:@"public" in:extensions];
		XCTAssertNotNil([connection execute:@"CREATE TABLE public.sp_t5_items (tags hstore)"], @"%@", connection.lastError.errorPrimaryMessage);

		NSError *error = nil;
		XCTAssertFalse([extensions dropExtension:@"hstore" error:&error], @"%@", port);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorHasDependents);
		XCTAssertEqualObjects(error.localizedDescription, @"\"hstore\" can't be dropped because other objects depend on it.");
		NSArray *dependents = error.userInfo[SPPostgresDependentsErrorKey];
		XCTAssertGreaterThanOrEqual([dependents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS 'sp_t5_items'"]].count, 1u, @"%@", dependents);

		[self install:@"earthdistance" version:nil schema:@"public" in:extensions];
		XCTAssertFalse([extensions dropExtension:@"cube" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorHasDependents);
		dependents = error.userInfo[SPPostgresDependentsErrorKey];
		XCTAssertGreaterThanOrEqual([dependents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS 'earthdistance'"]].count, 1u, @"%@", dependents);

		XCTAssertEqualObjects([self installedNames:extensions], (@[@"cube", @"earthdistance", @"hstore", @"plpgsql"]));
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
	}
}

- (void)testDropSucceeds
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		[self install:@"citext" version:nil schema:nil in:extensions];
		NSError *error = nil;
		XCTAssertTrue([extensions dropExtension:@"citext" error:&error], @"%@ %@", port, error);
		XCTAssertNil([extensions extensionNamed:@"citext" error:&error]);
		XCTAssertNil(error);
		XCTAssertEqualObjects([self installedNames:extensions], @[@"plpgsql"]);

		// Not installed: the server's message
		XCTAssertFalse([extensions dropExtension:@"citext" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"citext"], @"%@", error);
	}
}

#pragma mark - The user's transaction

- (void)testFailedChangeInsideUserTransactionKeepsItOpen
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		NSString *before = [self value:@"SHOW lock_timeout" on:connection];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNotNil([connection execute:@"CREATE TEMP TABLE sp_t5_tx (n int)"]);
		XCTAssertNotNil([connection execute:@"INSERT INTO sp_t5_tx VALUES (1)"]);

		XCTAssertFalse([extensions installExtension:@"hstore" version:@"9.9" schema:nil error:&error], @"%@", port);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction, @"%@", port);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM sp_t5_tx" on:connection], @"1");
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);

		XCTAssertFalse([extensions updateExtension:@"plpgsql" toVersion:@"9.9" error:&error]);
		XCTAssertFalse([extensions dropExtension:@"no_such_extension" error:&error]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);

		// A change that succeeds is part of the user's transaction
		[self install:@"citext" version:nil schema:nil in:extensions];
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqualObjects([self installedNames:extensions], @[@"plpgsql"]);
	}
}

- (void)testAbortedTransactionRefusesChanges
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPExtensionStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		[recorder.statements removeAllObjects];
		XCTAssertFalse([extensions installExtension:@"earthdistance" version:nil schema:@"public" error:&error], @"%@", port);
		XCTAssertTrue([error.localizedDescription containsString:@"aborted"], @"%@", error);
		XCTAssertFalse([extensions updateExtension:@"plpgsql" toVersion:@"1.0" error:&error]);
		XCTAssertFalse([extensions dropExtension:@"plpgsql" error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInError);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
	}
}

#pragma mark - Odd names

- (void)testOddNamesAndSchemas
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		XCTAssertNotNil([connection execute:@"CREATE SCHEMA IF NOT EXISTS \"Sales Data\""]);
		[self install:@"uuid-ossp" version:nil schema:@"Sales Data" in:extensions];

		NSArray *installed = [extensions installedExtensions:NULL];
		XCTAssertTrue([[installed valueForKey:@"name"] containsObject:@"uuid-ossp"], @"%@", port);
		SPPostgresExtension *uuid = [self extension:@"uuid-ossp" of:extensions];
		XCTAssertEqualObjects(uuid.schema, @"Sales Data");

		NSError *error = nil;
		XCTAssertEqualObjects([extensions updateTargetsForExtension:@"uuid-ossp" error:&error], @[], @"%@", error);
		XCTAssertEqualObjects([extensions missingRequirementsForExtension:@"uuid-ossp" version:nil error:&error], @[], @"%@", error);

		XCTAssertTrue([extensions dropExtension:@"uuid-ossp" error:&error], @"%@", error);
		XCTAssertNil([extensions extensionNamed:@"uuid-ossp" error:&error]);
		XCTAssertNil(error);
	}
}

@end
