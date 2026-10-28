#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresPrivileges.h"
#import "../Source/Postgres/SPPostgresRoles.h"

/// SPPostgresPrivileges: one role's direct grants and default privileges in one database, on PG 12 and 18.
@interface SPPostgresPrivilegesTests : XCTestCase
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresPrivilegesTests

+ (void)setUp
{
	[super setUp];
	for (NSNumber *port in [SPPostgresTestServers ports]) [SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:port.unsignedIntegerValue];
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self dropTestObjectsOnPort:port];
		[SPPostgresTestServers dropTestRolesOnPort:port.unsignedIntegerValue];
	}
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self dropTestObjectsOnPort:port];
		[SPPostgresTestServers dropTestRolesOnPort:port.unsignedIntegerValue];
	}
	[super tearDown];
}

- (void)dropTestObjectsOnPort:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	[connection execute:@"DROP FUNCTION IF EXISTS public.sp_t4_fn(integer)"];
	[connection execute:@"DROP TABLE IF EXISTS public.sp_t4_owned"];
	[connection execute:@"DROP TABLE IF EXISTS public.sp_t4_later"];
	[connection execute:@"DROP SEQUENCE IF EXISTS public.sp_t4_seq"];
	[connection disconnect];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port database:(NSString *)database
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:database];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	return [self connectOn:port database:@"pgkit_test"];
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	if (!result.numberOfRows) return nil;
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (NSArray<SPPostgresPrivilegeObject *> *)read:(SPPostgresPrivileges *)privileges role:(NSString *)role schema:(NSString *)schema creator:(NSString *)creator
{
	NSError *error = nil;
	NSArray *objects = [privileges privilegesForRole:role schema:schema defaultsCreator:creator error:&error];
	XCTAssertNotNil(objects, @"%@", error);
	return objects;
}

- (SPPostgresPrivilegeObject *)object:(NSString *)name kind:(NSString *)kind in:(NSArray<SPPostgresPrivilegeObject *> *)objects
{
	for (SPPostgresPrivilegeObject *object in objects) {
		if ([object.kind isEqualToString:kind] && [object.name isEqualToString:name]) return object;
	}
	XCTFail(@"no %@ %@ in %@", kind, name, objects);
	return nil;
}

- (NSArray *)draftOf:(NSArray *)objects
{
	NSMutableArray *draft = [NSMutableArray array];
	for (SPPostgresPrivilegeObject *object in objects) [draft addObject:[object copy]];
	return draft;
}

- (void)apply:(SPPostgresPrivileges *)privileges role:(NSString *)role originals:(NSArray *)originals edited:(NSArray *)edited creator:(NSString *)creator
{
	NSArray *statements = [SPPostgresPrivileges statementsForRole:role original:originals edited:edited defaultsCreator:creator];
	NSError *error = nil;
	XCTAssertTrue([privileges applyStatements:statements error:&error], @"%@: %@", statements, error);
}

- (NSSet *)set:(NSArray *)values
{
	return [NSSet setWithArray:values];
}

#pragma mark - Tests

- (void)testReadsDirectGrantsPerKind
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_priv" on:connection];
		[self run:@"CREATE FUNCTION public.sp_t4_fn(integer) RETURNS integer LANGUAGE sql AS 'SELECT $1'" on:connection];
		[self run:@"GRANT CONNECT ON DATABASE pgkit_test TO sp_t4_priv" on:connection];
		[self run:@"GRANT USAGE ON SCHEMA public TO sp_t4_priv" on:connection];
		[self run:@"GRANT SELECT, UPDATE ON public.customers TO sp_t4_priv" on:connection];
		[self run:@"GRANT SELECT ON public.v_customers TO sp_t4_priv" on:connection];
		[self run:@"GRANT EXECUTE ON FUNCTION public.sp_t4_fn(integer) TO sp_t4_priv WITH GRANT OPTION" on:connection];

		SPPostgresPrivileges *privileges = [[SPPostgresPrivileges alloc] initWithConnection:connection];
		NSError *error = nil;
		NSArray *database = [privileges databasePrivilegesForRole:@"sp_t4_priv" database:@"pgkit_test" error:&error];
		XCTAssertEqual(database.count, 1u, @"%@", error);
		SPPostgresPrivilegeObject *db = database.firstObject;
		XCTAssertEqualObjects(db.kind, @"database");
		XCTAssertEqualObjects(db.name, @"pgkit_test");
		XCTAssertEqualObjects(db.availablePrivileges, (@[@"CONNECT", @"CREATE", @"TEMP"]));
		XCTAssertEqualObjects(db.granted, [self set:@[@"CONNECT"]]);

		NSArray *objects = [self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"];
		SPPostgresPrivilegeObject *schema = objects.firstObject;
		XCTAssertEqualObjects(schema.kind, @"schema");
		XCTAssertEqualObjects(schema.name, @"public");
		XCTAssertEqualObjects(schema.availablePrivileges, (@[@"USAGE", @"CREATE"]));
		XCTAssertEqualObjects(schema.granted, [self set:@[@"USAGE"]]);

		SPPostgresPrivilegeObject *customers = [self object:@"customers" kind:@"table" in:objects];
		XCTAssertEqualObjects(customers.schema, @"public");
		XCTAssertEqualObjects(customers.availablePrivileges, (@[@"SELECT", @"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE", @"REFERENCES", @"TRIGGER"]));
		XCTAssertEqualObjects(customers.granted, ([self set:@[@"SELECT", @"UPDATE"]]));
		XCTAssertEqual(customers.grantable.count, 0u);

		SPPostgresPrivilegeObject *view = [self object:@"v_customers" kind:@"view" in:objects];
		XCTAssertEqualObjects(view.granted, [self set:@[@"SELECT"]]);

		SPPostgresPrivilegeObject *function = [self object:@"sp_t4_fn(integer)" kind:@"function" in:objects];
		XCTAssertEqualObjects(function.signature, @"integer");
		XCTAssertEqualObjects(function.availablePrivileges, @[@"EXECUTE"]);
		XCTAssertEqualObjects(function.granted, [self set:@[@"EXECUTE"]]);
		XCTAssertEqualObjects(function.grantable, [self set:@[@"EXECUTE"]]);

		// Order: schema, table-likes, sequences, functions, then the three default rows.
		NSArray *kinds = [objects valueForKey:@"kind"];
		XCTAssertEqualObjects([kinds subarrayWithRange:NSMakeRange(kinds.count - 3, 3)], (@[@"default tables", @"default sequences", @"default functions"]));
		XCTAssertEqualObjects([objects[objects.count - 3] name], @"Tables created later");
		XCTAssertLessThan([kinds indexOfObject:@"table"], [kinds indexOfObject:@"view"]);
		XCTAssertLessThan([kinds indexOfObject:@"view"], [kinds indexOfObject:@"function"]);
		for (SPPostgresPrivilegeObject *object in objects) {
			if (object != customers && object != view && object != function && object != schema) XCTAssertEqual(object.granted.count, 0u, @"%@", object);
		}

		// A role that doesn't exist yet: every row, empty.
		database = [privileges databasePrivilegesForRole:@"sp_t4_pending" database:@"pgkit_test" error:&error];
		XCTAssertEqual(database.count, 1u, @"%@", error);
		XCTAssertEqual([database.firstObject granted].count, 0u);
		NSArray *pending = [self read:privileges role:@"sp_t4_pending" schema:@"public" creator:@"pgkit_test"];
		XCTAssertEqual(pending.count, objects.count);
		for (SPPostgresPrivilegeObject *object in pending) XCTAssertEqual(object.granted.count, 0u, @"%@", object);

		XCTAssertEqualObjects([privileges ownerOfSchema:@"Sales Data" error:&error], @"pgkit_test", @"%@", error);
	}
}

- (void)testOwnerShowsImplicitPrivileges
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_owner" on:connection];
		[self run:@"CREATE TABLE public.sp_t4_owned (id integer)" on:connection];
		[self run:@"ALTER TABLE public.sp_t4_owned OWNER TO sp_t4_owner" on:connection];
		XCTAssertNil([self value:@"SELECT relacl::text FROM pg_class WHERE oid = 'public.sp_t4_owned'::regclass" on:connection]);

		SPPostgresPrivileges *privileges = [[SPPostgresPrivileges alloc] initWithConnection:connection];
		NSArray *objects = [self read:privileges role:@"sp_t4_owner" schema:@"public" creator:nil];
		SPPostgresPrivilegeObject *owned = [self object:@"sp_t4_owned" kind:@"table" in:objects];
		XCTAssertEqualObjects(owned.granted, [NSSet setWithArray:owned.availablePrivileges]);
		XCTAssertEqual(owned.granted.count, 7u);
	}
}

- (void)testStatementsAreMinimalAndOrdered
{
	SPPostgresPrivilegeObject *customers = [[SPPostgresPrivilegeObject alloc] initWithKind:@"table" schema:@"public" name:@"customers" signature:nil
																					granted:[self set:@[@"SELECT"]] grantable:nil];
	SPPostgresPrivilegeObject *edited = [customers copy];
	edited.granted = [self set:@[@"DELETE", @"SELECT", @"INSERT"]];
	XCTAssertEqualObjects([SPPostgresPrivileges statementsForRole:@"sp_t4_priv" original:@[customers] edited:@[edited] defaultsCreator:nil],
						  @[@"GRANT INSERT, DELETE ON TABLE \"public\".\"customers\" TO \"sp_t4_priv\""]);

	SPPostgresPrivilegeObject *function = [[SPPostgresPrivilegeObject alloc] initWithKind:@"function" schema:@"public" name:@"sp_t4_fn(integer)" signature:@"integer"
																				   granted:[self set:@[@"EXECUTE"]] grantable:nil];
	SPPostgresPrivilegeObject *revoked = [function copy];
	revoked.granted = [NSSet set];
	XCTAssertEqualObjects([SPPostgresPrivileges statementsForRole:@"sp_t4_priv" original:@[function] edited:@[revoked] defaultsCreator:nil],
						  @[@"REVOKE EXECUTE ON ROUTINE \"public\".\"sp_t4_fn\"(integer) FROM \"sp_t4_priv\""]);

	// Unchanged gives nothing; both directions give a GRANT then a REVOKE, in the kind's order.
	XCTAssertEqualObjects([SPPostgresPrivileges statementsForRole:@"sp_t4_priv" original:@[customers] edited:@[[customers copy]] defaultsCreator:nil], @[]);
	SPPostgresPrivilegeObject *swapped = [customers copy];
	swapped.granted = [self set:@[@"TRIGGER", @"UPDATE"]];
	XCTAssertEqualObjects([SPPostgresPrivileges statementsForRole:@"sp_t4_priv" original:@[customers] edited:@[swapped] defaultsCreator:nil],
						  (@[@"GRANT UPDATE, TRIGGER ON TABLE \"public\".\"customers\" TO \"sp_t4_priv\"",
							 @"REVOKE SELECT ON TABLE \"public\".\"customers\" FROM \"sp_t4_priv\""]));

	// Every kind's clause.
	SPPostgresPrivilegeObject *db = [[SPPostgresPrivilegeObject alloc] initWithKind:@"database" schema:nil name:@"pgkit_test" signature:nil granted:nil grantable:nil];
	SPPostgresPrivilegeObject *schema = [[SPPostgresPrivilegeObject alloc] initWithKind:@"schema" schema:@"a\"b" name:@"a\"b" signature:nil granted:nil grantable:nil];
	SPPostgresPrivilegeObject *view = [[SPPostgresPrivilegeObject alloc] initWithKind:@"materialized view" schema:@"public" name:@"mv" signature:nil granted:nil grantable:nil];
	SPPostgresPrivilegeObject *sequence = [[SPPostgresPrivilegeObject alloc] initWithKind:@"sequence" schema:@"public" name:@"s" signature:nil granted:nil grantable:nil];
	SPPostgresPrivilegeObject *defaults = [[SPPostgresPrivilegeObject alloc] initWithKind:@"default sequences" schema:@"public" name:@"Sequences created later" signature:nil granted:nil grantable:nil];
	NSArray *originals = @[db, schema, view, sequence, defaults];
	NSMutableArray *ticked = [NSMutableArray array];
	for (SPPostgresPrivilegeObject *object in originals) {
		SPPostgresPrivilegeObject *copy = [object copy];
		copy.granted = [NSSet setWithArray:object.availablePrivileges];
		[ticked addObject:copy];
	}
	XCTAssertEqualObjects([SPPostgresPrivileges statementsForRole:@"sp_t4_a\"b" original:originals edited:ticked defaultsCreator:@"pgkit_test"],
						  (@[@"GRANT CONNECT, CREATE, TEMP ON DATABASE \"pgkit_test\" TO \"sp_t4_a\"\"b\"",
							 @"GRANT USAGE, CREATE ON SCHEMA \"a\"\"b\" TO \"sp_t4_a\"\"b\"",
							 @"GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE \"public\".\"mv\" TO \"sp_t4_a\"\"b\"",
							 @"GRANT USAGE, SELECT ON SEQUENCE \"public\".\"s\" TO \"sp_t4_a\"\"b\"",
							 @"ALTER DEFAULT PRIVILEGES FOR ROLE \"pgkit_test\" IN SCHEMA \"public\" GRANT USAGE, SELECT ON SEQUENCES TO \"sp_t4_a\"\"b\""]));
}

- (void)testApplyRoundTripsEveryKind
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_priv" on:connection];
		[self run:@"CREATE FUNCTION public.sp_t4_fn(integer) RETURNS integer LANGUAGE sql AS 'SELECT $1'" on:connection];
		[self run:@"CREATE SEQUENCE public.sp_t4_seq" on:connection];
		SPPostgresPrivileges *privileges = [[SPPostgresPrivileges alloc] initWithConnection:connection];

		NSError *error = nil;
		NSArray *originals = [[privileges databasePrivilegesForRole:@"sp_t4_priv" database:@"pgkit_test" error:&error]
							  arrayByAddingObjectsFromArray:[self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"]];
		NSDictionary *wanted = @{@"database": @"TEMP", @"schema": @"CREATE", @"table": @"TRUNCATE", @"sequence": @"USAGE", @"function": @"EXECUTE"};
		NSDictionary *names = @{@"database": @"pgkit_test", @"schema": @"public", @"table": @"customers", @"sequence": @"sp_t4_seq", @"function": @"sp_t4_fn(integer)"};
		NSArray *edited = [self draftOf:originals];
		for (NSString *kind in wanted) [self object:names[kind] kind:kind in:edited].granted = [self set:@[wanted[kind]]];
		[self apply:privileges role:@"sp_t4_priv" originals:originals edited:edited creator:@"pgkit_test"];

		NSArray *reread = [[privileges databasePrivilegesForRole:@"sp_t4_priv" database:@"pgkit_test" error:&error]
						   arrayByAddingObjectsFromArray:[self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"]];
		for (NSString *kind in wanted) XCTAssertEqualObjects([self object:names[kind] kind:kind in:reread].granted, [self set:@[wanted[kind]]], @"%@", kind);
		NSUInteger grantedRows = 0;
		for (SPPostgresPrivilegeObject *object in reread) if (object.granted.count) grantedRows++;
		XCTAssertEqual(grantedRows, wanted.count);

		NSArray *cleared = [self draftOf:reread];
		for (SPPostgresPrivilegeObject *object in cleared) object.granted = [NSSet set];
		[self apply:privileges role:@"sp_t4_priv" originals:reread edited:cleared creator:@"pgkit_test"];
		NSArray *empty = [[privileges databasePrivilegesForRole:@"sp_t4_priv" database:@"pgkit_test" error:&error]
						  arrayByAddingObjectsFromArray:[self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"]];
		for (SPPostgresPrivilegeObject *object in empty) XCTAssertEqual(object.granted.count, 0u, @"%@", object);
	}
}

- (void)testDefaultPrivileges
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_priv" on:connection];
		SPPostgresPrivileges *privileges = [[SPPostgresPrivileges alloc] initWithConnection:connection];

		NSArray *originals = [self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"];
		NSArray *edited = [self draftOf:originals];
		SPPostgresPrivilegeObject *later = [self object:@"Tables created later" kind:@"default tables" in:edited];
		XCTAssertEqualObjects(later.availablePrivileges, (@[@"SELECT", @"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE", @"REFERENCES", @"TRIGGER"]));
		XCTAssertEqualObjects([self object:@"Sequences created later" kind:@"default sequences" in:edited].availablePrivileges, (@[@"USAGE", @"SELECT"]));
		XCTAssertEqualObjects([self object:@"Functions created later" kind:@"default functions" in:edited].availablePrivileges, @[@"EXECUTE"]);
		later.granted = [self set:@[@"SELECT"]];
		[self apply:privileges role:@"sp_t4_priv" originals:originals edited:edited creator:@"pgkit_test"];

		NSString *entries = @"SELECT count(*)::text FROM pg_default_acl d, aclexplode(d.defaclacl) a "
			"WHERE d.defaclrole = 'pgkit_test'::regrole AND d.defaclnamespace = 'public'::regnamespace AND d.defaclobjtype = 'r' "
			"AND a.grantee = 'sp_t4_priv'::regrole AND a.privilege_type = 'SELECT'";
		XCTAssertEqualObjects([self value:entries on:connection], @"1");
		[self run:@"CREATE TABLE public.sp_t4_later (id integer)" on:connection];
		XCTAssertEqualObjects([self value:@"SELECT has_table_privilege('sp_t4_priv', 'public.sp_t4_later', 'SELECT')::text" on:connection], @"true");

		NSArray *reread = [self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"];
		XCTAssertEqualObjects([self object:@"Tables created later" kind:@"default tables" in:reread].granted, [self set:@[@"SELECT"]]);
		XCTAssertEqualObjects([self object:@"sp_t4_later" kind:@"table" in:reread].granted, [self set:@[@"SELECT"]]);
		// Another creator's defaults are separate.
		XCTAssertEqual([self object:@"Tables created later" kind:@"default tables" in:[self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"sp_t4_priv"]].granted.count, 0u);

		NSArray *cleared = [self draftOf:reread];
		[self object:@"Tables created later" kind:@"default tables" in:cleared].granted = [NSSet set];
		[self apply:privileges role:@"sp_t4_priv" originals:reread edited:cleared creator:@"pgkit_test"];
		XCTAssertEqualObjects([self value:entries on:connection], @"0");
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_default_acl d WHERE d.defaclrole = 'pgkit_test'::regrole AND d.defaclnamespace = 'public'::regnamespace" on:connection], @"0");
		XCTAssertEqual([self object:@"Tables created later" kind:@"default tables" in:[self read:privileges role:@"sp_t4_priv" schema:@"public" creator:@"pgkit_test"]].granted.count, 0u);
	}
}

- (void)testGrantsWorkForOddNamesAndObjects
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE \"sp_t4_Sales Rep\"" on:connection];
		SPPostgresPrivileges *privileges = [[SPPostgresPrivileges alloc] initWithConnection:connection];
		NSString *role = @"sp_t4_Sales Rep";

		NSArray *originals = [self read:privileges role:role schema:@"Sales Data" creator:@"pgkit_test"];
		NSArray *edited = [self draftOf:originals];
		[self object:@"Sales Data" kind:@"schema" in:edited].granted = [self set:@[@"USAGE"]];
		[self object:@"Orders 2026" kind:@"table" in:edited].granted = [self set:@[@"SELECT", @"INSERT"]];
		[self object:@"Tables created later" kind:@"default tables" in:edited].granted = [self set:@[@"SELECT"]];
		[self apply:privileges role:role originals:originals edited:edited creator:@"pgkit_test"];
		XCTAssertEqualObjects([self value:@"SELECT has_table_privilege('sp_t4_Sales Rep', '\"Sales Data\".\"Orders 2026\"', 'INSERT')::text" on:connection], @"true");
		NSArray *reread = [self read:privileges role:role schema:@"Sales Data" creator:@"pgkit_test"];
		XCTAssertEqualObjects([self object:@"Orders 2026" kind:@"table" in:reread].granted, ([self set:@[@"SELECT", @"INSERT"]]));
		XCTAssertEqualObjects([self object:@"Sales Data" kind:@"schema" in:reread].granted, [self set:@[@"USAGE"]]);
		XCTAssertEqualObjects([self object:@"Tables created later" kind:@"default tables" in:reread].granted, [self set:@[@"SELECT"]]);

		originals = [self read:privileges role:role schema:@"a\"b" creator:@"pgkit_test"];
		edited = [self draftOf:originals];
		[self object:@"a\"b" kind:@"schema" in:edited].granted = [self set:@[@"USAGE", @"CREATE"]];
		[self object:@"x" kind:@"table" in:edited].granted = [self set:@[@"TRIGGER"]];
		[self apply:privileges role:role originals:originals edited:edited creator:@"pgkit_test"];
		reread = [self read:privileges role:role schema:@"a\"b" creator:@"pgkit_test"];
		XCTAssertEqualObjects([self object:@"a\"b" kind:@"schema" in:reread].granted, ([self set:@[@"USAGE", @"CREATE"]]));
		XCTAssertEqualObjects([self object:@"x" kind:@"table" in:reread].granted, [self set:@[@"TRIGGER"]]);

		// Undo it all through the same path (the default ACL too).
		NSArray *cleared = [self draftOf:reread];
		for (SPPostgresPrivilegeObject *object in cleared) object.granted = [NSSet set];
		[self apply:privileges role:role originals:reread edited:cleared creator:@"pgkit_test"];
		reread = [self read:privileges role:role schema:@"Sales Data" creator:@"pgkit_test"];
		cleared = [self draftOf:reread];
		for (SPPostgresPrivilegeObject *object in cleared) object.granted = [NSSet set];
		[self apply:privileges role:role originals:reread edited:cleared creator:@"pgkit_test"];
		for (SPPostgresPrivilegeObject *object in [self read:privileges role:role schema:@"Sales Data" creator:@"pgkit_test"]) XCTAssertEqual(object.granted.count, 0u, @"%@", object);
	}
}

- (void)testOtherDatabase
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *main = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_priv" on:main];
		PGPostgresConnection *connection = [self connectOn:port database:@"pgkit_nopublic"];
		SPPostgresPrivileges *privileges = [[SPPostgresPrivileges alloc] initWithConnection:connection];

		NSArray *originals = [self read:privileges role:@"sp_t4_priv" schema:@"app" creator:@"pgkit_test"];
		SPPostgresPrivilegeObject *items = [self object:@"items" kind:@"table" in:originals];
		XCTAssertEqualObjects(items.schema, @"app");
		NSArray *edited = [self draftOf:originals];
		[self object:@"items" kind:@"table" in:edited].granted = [self set:@[@"SELECT"]];
		[self apply:privileges role:@"sp_t4_priv" originals:originals edited:edited creator:@"pgkit_test"];

		XCTAssertEqualObjects([self value:@"SELECT has_table_privilege('sp_t4_priv', 'app.items', 'SELECT')::text" on:connection], @"true");
		XCTAssertEqualObjects([self object:@"items" kind:@"table" in:[self read:privileges role:@"sp_t4_priv" schema:@"app" creator:@"pgkit_test"]].granted, [self set:@[@"SELECT"]]);
		NSError *error = nil;
		NSArray *database = [privileges databasePrivilegesForRole:@"sp_t4_priv" database:@"pgkit_nopublic" error:&error];
		XCTAssertEqualObjects([database.firstObject name], @"pgkit_nopublic", @"%@", error);
	}
}

@end
