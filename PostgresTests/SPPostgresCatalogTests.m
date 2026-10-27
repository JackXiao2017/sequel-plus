#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresCatalog.h"
#import "../Source/Postgres/SPPostgresErrors.h"

@interface SPPostgresCatalogTests : XCTestCase
@end

@implementation SPPostgresCatalogTests

#pragma mark - Fixture

// The fixture is read from PostgresTests/Fixtures/catalog.sql next to this source file (located via __FILE__),
// not bundled as a test resource.
+ (void)loadFixtureOnPort:(NSUInteger)port
{
	NSString *path = [[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
					   stringByAppendingPathComponent:@"Fixtures"] stringByAppendingPathComponent:@"catalog.sql"];
	NSError *readError = nil;
	NSString *sql = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
	if (!sql) { XCTFail(@"Cannot read fixture: %@", readError); return; }

	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port];
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

		if ([directive hasPrefix:@"db "]) {
			[connection disconnect];
			connection = [SPPostgresTestServers connectedConnectionOnPort:port database:[directive substringFromIndex:3]];
			if (!connection) return;
		} else if ([directive hasPrefix:@"createdb "]) {
			NSString *name = [directive substringFromIndex:9];
			PGPostgresResult *exists = [connection execute:@"SELECT 1 FROM pg_database WHERE datname = $1::text" values:@[name]];
			if (exists.numberOfRows == 0) {
				// Name comes from the fixture file, quoted as an identifier.
				NSString *quoted = [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
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

- (void)setUp
{
	self.continueAfterFailure = NO;
	for (NSNumber *port in [SPPostgresTestServers ports]) [[self class] loadFixtureOnPort:port.unsignedIntegerValue];
}

- (SPPostgresCatalog *)catalogOnPort:(NSUInteger)port database:(NSString *)database
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port database:database];
	XCTAssertNotNil(connection);
	return [[SPPostgresCatalog alloc] initWithConnection:connection];
}

#pragma mark - Tests

- (void)testSchemasIncludeOddNamesAndExcludeSystemSchemas
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSError *error = nil;
		NSArray *schemas = [[self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"] schemaNames:&error];
		XCTAssertNotNil(schemas, @"%@", error);
		XCTAssertTrue([schemas containsObject:@"public"]);
		XCTAssertTrue([schemas containsObject:@"Sales Data"]);
		XCTAssertTrue([schemas containsObject:@"a\"b"]);
		XCTAssertFalse([schemas containsObject:@"pg_catalog"]);
		XCTAssertFalse([schemas containsObject:@"information_schema"]);
		for (NSString *s in schemas) {
			XCTAssertFalse([s hasPrefix:@"pg_toast"]);
			XCTAssertFalse([s hasPrefix:@"pg_temp_"]);
		}
		XCTAssertEqualObjects(schemas, [schemas sortedArrayUsingSelector:@selector(compare:)]);
	}
}

- (void)testTablesInOddlyNamedSchema
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresCatalog *catalog = [self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"];
		NSError *error = nil;
		XCTAssertEqualObjects([catalog tableNamesInSchema:@"Sales Data" error:&error], (@[@"Orders 2026"]), @"%@", error);
		XCTAssertEqualObjects([catalog tableNamesInSchema:@"a\"b" error:&error], (@[@"x"]), @"%@", error);
		XCTAssertTrue([[catalog tableNamesInSchema:@"public" error:&error] containsObject:@"customers"], @"%@", error); // other suites may add public tables
	}
}

- (void)testViewsListed
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSError *error = nil;
		XCTAssertEqualObjects([[self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"] viewNamesInSchema:@"public" error:&error],
							  (@[@"v_customers"]), @"%@", error);
	}
}

- (void)testExtensionsIncludeVersion
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSError *error = nil;
		NSArray *extensions = [[self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"] installedExtensions:&error];
		XCTAssertNotNil(extensions, @"%@", error);
		NSDictionary *trgm = nil;
		for (NSDictionary *e in extensions) if ([e[@"name"] isEqualToString:@"pg_trgm"]) trgm = e;
		XCTAssertNotNil(trgm);
		XCTAssertTrue([trgm[@"version"] length] > 0);
	}
}

- (void)testDefaultSchemaPrefersPublic
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresCatalog *catalog = [self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"];
		XCTAssertEqualObjects([catalog defaultSchemaFromSchemas:[catalog schemaNames:NULL]], @"public");
		XCTAssertNil([catalog defaultSchemaFromSchemas:@[]]);
		XCTAssertEqualObjects([catalog defaultSchemaFromSchemas:(@[@"zeta", @"alpha"])], @"zeta");
	}
}

- (void)testDefaultSchemaWithoutPublic
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresCatalog *catalog = [self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_nopublic"];
		NSError *error = nil;
		NSArray *schemas = [catalog schemaNames:&error];
		XCTAssertEqualObjects(schemas, (@[@"app"]), @"%@", error);
		XCTAssertEqualObjects([catalog defaultSchemaFromSchemas:schemas], @"app");
		XCTAssertEqualObjects([catalog tableNamesInSchema:@"app" error:&error], (@[@"items"]), @"%@", error);
	}
}

- (void)testServerVersionMatchesPort
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *version = [[self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"] serverVersionString];
		NSString *prefix = port.unsignedIntegerValue == 55412 ? @"12." : @"18.";
		XCTAssertTrue([version hasPrefix:prefix], @"%@ on %@", version, port);
	}
}

- (void)testDatabaseNamesExcludeTemplates
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSError *error = nil;
		NSArray *names = [[self catalogOnPort:port.unsignedIntegerValue database:@"pgkit_test"] databaseNames:&error];
		XCTAssertNotNil(names, @"%@", error);
		XCTAssertTrue([names containsObject:@"pgkit_test"]);
		XCTAssertFalse([names containsObject:@"template0"]);
		XCTAssertFalse([names containsObject:@"template1"]);
	}
}

- (void)testQueryFailurePopulatesError
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:55412];
	SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];
	[connection disconnect];
	NSError *error = nil;
	XCTAssertNil([catalog schemaNames:&error]);
	XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
	XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
}

@end
