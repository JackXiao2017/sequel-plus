#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresCatalog.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPCatalogStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPCatalogStatementRecorder
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

@interface SPPostgresCatalogTests : XCTestCase
@end

@implementation SPPostgresCatalogTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	for (NSNumber *port in [SPPostgresTestServers ports]) [SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:port.unsignedIntegerValue];
}

- (SPPostgresCatalog *)catalogOnPort:(NSUInteger)port database:(NSString *)database
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port database:database];
	XCTAssertNotNil(connection);
	return [[SPPostgresCatalog alloc] initWithConnection:connection];
}

/// Drops every sp_t7_% database (test code only: app code never drops databases).
- (void)tearDown
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test"];
		PGPostgresResult *result = [connection execute:@"SELECT datname::text AS n FROM pg_database WHERE datname LIKE 'sp\\_t7\\_%'"];
		for (NSDictionary *row in result) {
			NSString *name = row[@"n"];
			NSString *quoted = [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
			XCTAssertNotNil([connection execute:[@"DROP DATABASE IF EXISTS " stringByAppendingString:quoted]], @"%@", [[connection lastError] errorPrimaryMessage]);
		}
		[connection disconnect];
	}
}

#pragma mark - Tests

- (void)testCreateDatabase
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPCatalogStatementRecorder *recorder = [[SPCatalogStatementRecorder alloc] init];
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:recorder];
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];

		NSError *error = nil;
		XCTAssertTrue([catalog createDatabase:@"sp_t7_new" error:&error], @"port %@: %@", port, error);
		XCTAssertEqualObjects(recorder.statements.lastObject, @"CREATE DATABASE \"sp_t7_new\"");
		XCTAssertTrue([[catalog databaseNames:&error] containsObject:@"sp_t7_new"], @"port %@: %@", port, error);

		error = nil;
		XCTAssertFalse([catalog createDatabase:@"sp_t7_new" error:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"already exists"], @"%@", error.localizedDescription);

		NSUInteger sent = recorder.statements.count;
		NSString *tooLong = [@"sp_t7_" stringByPaddingToLength:64 withString:@"x" startingAtIndex:0];
		XCTAssertEqual([tooLong lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 64u);
		for (NSString *name in @[@"", tooLong]) {
			error = nil;
			XCTAssertFalse([catalog createDatabase:name error:&error], @"%@", name);
			XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
			XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);
			XCTAssertTrue(error.localizedDescription.length > 0);
		}
		XCTAssertEqual(recorder.statements.count, sent, @"a refused name must send nothing");

		// 63 bytes in UTF-8 is the limit, not 63 characters
		NSString *multibyte = [@"sp_t7_" stringByPaddingToLength:35 withString:@"\u00e9" startingAtIndex:0];
		XCTAssertEqual([multibyte lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 64u);
		error = nil;
		XCTAssertFalse([catalog createDatabase:multibyte error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);
		XCTAssertEqual(recorder.statements.count, sent);

		[connection disconnect];
	}
}

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
