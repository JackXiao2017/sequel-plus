#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableStructure.h"
#import "../Source/Postgres/SPPostgresCatalog.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// The trigger part of SPPostgresTableStructure (Stage 3 Task 3), on both test servers.
@interface SPPostgresTriggersTests : XCTestCase
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresTriggersTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[SPPostgresTestServers loadStructureFixtureOnPort:port.unsignedIntegerValue];
		[self dropOddFunctionOnPort:port.unsignedIntegerValue];
	}
}

- (void)dropOddFunctionOnPort:(NSUInteger)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port];
	[connection execute:@"SET lock_timeout = '10s'"];
	[connection execute:@"DROP FUNCTION IF EXISTS \"Sales Data\".\"Odd \"\"fn\"\"\"()"];
	[connection disconnect];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[SPPostgresTestServers dropStructureFixtureOnPort:port.unsignedIntegerValue];
		[self dropOddFunctionOnPort:port.unsignedIntegerValue];
	}
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

- (SPPostgresTableStructure *)structureOn:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table
{
	return [[SPPostgresTableStructure alloc] initWithConnection:connection schema:schema table:table];
}

- (SPPostgresTrigger *)trigger:(NSString *)name of:(SPPostgresTableStructure *)structure
{
	NSError *error = nil;
	NSArray *triggers = [structure triggers:&error];
	XCTAssertNotNil(triggers, @"%@", error);
	for (SPPostgresTrigger *trigger in triggers) {
		if ([trigger.name isEqualToString:name]) return trigger;
	}
	return nil;
}

- (id)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	return result.numberOfRows ? [result textValueAtRow:0 column:0] : nil;
}

#pragma mark - Reading

- (void)testTriggersListParsed
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection schema:@"structure_test" table:@"t"];
		NSError *error = nil;
		NSArray *triggers = [structure triggers:&error];
		XCTAssertNotNil(triggers, @"%@", error);
		XCTAssertEqualObjects([triggers valueForKey:@"name"], (@[@"t_audit", @"t_touch"]), @"%@", port);

		SPPostgresTrigger *touch = triggers[1];
		XCTAssertEqualObjects(touch.timing, @"BEFORE");
		XCTAssertEqualObjects(touch.events, @"UPDATE OF code");
		XCTAssertEqualObjects(touch.level, @"ROW");
		XCTAssertEqualObjects(touch.functionSchema, @"structure_test");
		XCTAssertEqualObjects(touch.functionName, @"touch");
		XCTAssertEqualObjects(touch.condition, @"old.code IS DISTINCT FROM new.code");
		XCTAssertTrue(touch.enabled);
		XCTAssertTrue([touch.definition hasPrefix:@"CREATE TRIGGER t_touch BEFORE UPDATE OF code ON structure_test.t"], @"%@", touch.definition);
		XCTAssertTrue([touch.functionDefinition containsString:@"RETURN NEW"], @"%@", touch.functionDefinition);
		XCTAssertTrue([touch.functionDefinition containsString:@"FUNCTION structure_test.touch()"], @"%@", touch.functionDefinition);

		SPPostgresTrigger *audit = triggers[0];
		XCTAssertEqualObjects(audit.timing, @"AFTER");
		XCTAssertEqualObjects(audit.events, @"INSERT OR DELETE");
		XCTAssertEqualObjects(audit.level, @"STATEMENT");
		XCTAssertNil(audit.condition);
		XCTAssertFalse(audit.enabled);

		// A view has none (and isn't an error); a missing table is
		XCTAssertEqualObjects([[self structureOn:connection schema:@"structure_test" table:@"t_view"] triggers:&error], @[], @"%@", error);
		error = nil;
		XCTAssertNil([[self structureOn:connection schema:@"structure_test" table:@"nope"] triggers:&error]);
		XCTAssertNotNil(error);
	}
}

- (void)testInternalFKTriggersExcluded
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		// child's foreign key to t makes internal triggers on both tables
		XCTAssertTrue([[self value:@"SELECT count(*)::text FROM pg_trigger WHERE tgrelid = 'structure_test.child'::regclass AND tgisinternal" on:connection] integerValue] > 0);
		XCTAssertTrue([[self value:@"SELECT count(*)::text FROM pg_trigger WHERE tgrelid = 'structure_test.t'::regclass AND tgisinternal" on:connection] integerValue] > 0);

		NSError *error = nil;
		XCTAssertEqualObjects([[self structureOn:connection schema:@"structure_test" table:@"child"] triggers:&error], @[], @"%@", error);
		XCTAssertEqualObjects([[[self structureOn:connection schema:@"structure_test" table:@"t"] triggers:&error] valueForKey:@"name"], (@[@"t_audit", @"t_touch"]));
	}
}

- (void)testTriggerFunctionsListed
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		XCTAssertNotNil([connection execute:@"CREATE FUNCTION \"Sales Data\".\"Odd \"\"fn\"\"\"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$"], @"%@", connection.lastError.errorPrimaryMessage);
		SPPostgresTableStructure *structure = [self structureOn:connection schema:@"structure_test" table:@"t"];
		NSError *error = nil;
		NSArray *functions = [structure triggerFunctions:&error];
		XCTAssertNotNil(functions, @"%@", error);
		XCTAssertTrue([functions containsObject:@"structure_test.touch"], @"%@", functions);
		XCTAssertTrue([functions containsObject:@"\"Sales Data\".\"Odd \"\"fn\"\"\""], @"quoted when needed: %@", functions);
		for (NSString *function in functions) {
			XCTAssertFalse([function hasPrefix:@"pg_catalog."], @"%@", function);
			XCTAssertFalse([function hasPrefix:@"information_schema."], @"%@", function);
		}
		// Only functions returning trigger
		XCTAssertNotNil([connection execute:@"CREATE FUNCTION structure_test.not_a_trigger() RETURNS int LANGUAGE sql AS 'SELECT 1'"], @"%@", connection.lastError.errorPrimaryMessage);
		XCTAssertFalse([[structure triggerFunctions:&error] containsObject:@"structure_test.not_a_trigger"]);
	}
}

#pragma mark - Changes

- (void)testAddDropEnableDisableTrigger
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection schema:@"structure_test" table:@"t"];
		NSError *error = nil;

		XCTAssertTrue(([structure addTriggerNamed:@"t_new" timing:@"AFTER" events:@[@"INSERT", @"UPDATE", @"DELETE"] updateColumns:@[@"qty", @"a \"q\" b"]
										   level:@"ROW" function:@"structure_test.touch" condition:@"pg_trigger_depth() < 2" error:&error]), @"%@", error);
		SPPostgresTrigger *added = [self trigger:@"t_new" of:structure];
		XCTAssertNotNil(added);
		XCTAssertEqualObjects(added.timing, @"AFTER");
		XCTAssertEqualObjects(added.events, @"INSERT OR DELETE OR UPDATE OF qty, \"a \"\"q\"\" b\"");
		XCTAssertEqualObjects(added.level, @"ROW");
		XCTAssertEqualObjects(added.condition, @"pg_trigger_depth() < 2");
		XCTAssertTrue(added.enabled);

		// Disable, enable
		XCTAssertTrue([structure setTrigger:@"t_new" enabled:NO error:&error], @"%@", error);
		XCTAssertFalse([self trigger:@"t_new" of:structure].enabled);
		XCTAssertEqualObjects([self value:@"SELECT tgenabled::text FROM pg_trigger WHERE tgname = 't_new'" on:connection], @"D");
		XCTAssertTrue([structure setTrigger:@"t_audit" enabled:YES error:&error], @"%@", error);
		XCTAssertTrue([self trigger:@"t_audit" of:structure].enabled);

		// Statement level, no condition, no columns
		XCTAssertTrue(([structure addTriggerNamed:@"t_stmt" timing:@"BEFORE" events:@[@"TRUNCATE"] updateColumns:nil level:@"STATEMENT"
										function:@"structure_test.touch" condition:nil error:&error]), @"%@", error);
		XCTAssertEqualObjects([self trigger:@"t_stmt" of:structure].events, @"TRUNCATE");
		XCTAssertNil([self trigger:@"t_stmt" of:structure].condition);

		// Drop
		XCTAssertTrue([structure dropTriggerNamed:@"t_new" error:&error], @"%@", error);
		XCTAssertTrue([structure dropTriggerNamed:@"t_stmt" error:&error], @"%@", error);
		XCTAssertEqualObjects([[structure triggers:&error] valueForKey:@"name"], (@[@"t_audit", @"t_touch"]));

		// The server's refusals come back with its message; nothing is left behind
		error = nil;
		XCTAssertFalse([structure dropTriggerNamed:@"no_such" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"no_such"], @"%@", error);
		error = nil;
		XCTAssertFalse(([structure addTriggerNamed:@"t_bad" timing:@"AFTER" events:@[@"INSERT"] updateColumns:nil level:@"STATEMENT"
										 function:@"structure_test.touch" condition:@"NEW.qty IS NULL" error:&error]));
		XCTAssertNotNil(error.userInfo[SPPostgresSQLStateErrorKey], @"%@", error);
		XCTAssertNil([self trigger:@"t_bad" of:structure]);
		XCTAssertEqualObjects([self value:@"SELECT pg_catalog.current_setting('lock_timeout')::text" on:connection], @"0");
	}
}

/// Refused before anything is sent: unknown timing, event or level, no event, a function that isn't a listed
/// trigger function (so the text can't carry SQL), names PostgreSQL wouldn't keep.
- (void)testAddTriggerRefusesBadInput
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection schema:@"structure_test" table:@"t"];
		NSString *fn = @"structure_test.touch";
		NSError *error = nil;
		XCTAssertFalse(([structure addTriggerNamed:@"" timing:@"AFTER" events:@[@"INSERT"] updateColumns:nil level:@"ROW" function:fn condition:nil error:&error]));
		XCTAssertFalse(([structure addTriggerNamed:[@"" stringByPaddingToLength:64 withString:@"x" startingAtIndex:0] timing:@"AFTER" events:@[@"INSERT"] updateColumns:nil level:@"ROW" function:fn condition:nil error:&error]));
		XCTAssertFalse(([structure addTriggerNamed:@"x" timing:@"DURING" events:@[@"INSERT"] updateColumns:nil level:@"ROW" function:fn condition:nil error:&error]));
		XCTAssertFalse(([structure addTriggerNamed:@"x" timing:@"AFTER" events:@[] updateColumns:nil level:@"ROW" function:fn condition:nil error:&error]));
		XCTAssertFalse(([structure addTriggerNamed:@"x" timing:@"AFTER" events:@[@"SELECT"] updateColumns:nil level:@"ROW" function:fn condition:nil error:&error]));
		XCTAssertFalse(([structure addTriggerNamed:@"x" timing:@"AFTER" events:@[@"INSERT"] updateColumns:nil level:@"ROWS" function:fn condition:nil error:&error]));
		XCTAssertFalse(([structure addTriggerNamed:@"x" timing:@"AFTER" events:@[@"INSERT"] updateColumns:@[@"qty"] level:@"ROW" function:fn condition:nil error:&error]), @"columns without UPDATE");
		XCTAssertFalse(([structure addTriggerNamed:@"x" timing:@"AFTER" events:@[@"INSERT"] updateColumns:nil level:@"ROW"
										 function:@"structure_test.touch(); DROP TABLE structure_test.child; --" condition:nil error:&error]));
		XCTAssertTrue([error.localizedDescription containsString:@"trigger function"], @"%@", error);
		XCTAssertNotNil([self value:@"SELECT 'structure_test.child'::regclass::text" on:connection]);
		XCTAssertNil([self trigger:@"x" of:structure]);
	}
}

/// pg_get_triggerdef's events are parsed exactly, whatever the names: the order the server writes
/// (INSERT OR DELETE OR UPDATE), quoted column names, and a trigger and function whose names hold " ON ".
- (void)testEventsParsingWithOddNames
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		XCTAssertNotNil([connection execute:@"CREATE FUNCTION \"Sales Data\".\"Odd \"\"fn\"\"\"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$"], @"%@", connection.lastError.errorPrimaryMessage);
		XCTAssertNotNil([connection execute:@"ALTER TABLE \"Sales Data\".\"Mixed Case\" ADD COLUMN \"x ON y\" int, ADD COLUMN \"Up\"\"d\" int"]);
		SPPostgresTableStructure *structure = [self structureOn:connection schema:@"Sales Data" table:@"Mixed Case"];
		NSError *error = nil;
		NSString *function = @"\"Sales Data\".\"Odd \"\"fn\"\"\"";
		XCTAssertTrue([[structure triggerFunctions:&error] containsObject:function]);

		XCTAssertTrue(([structure addTriggerNamed:@" ON \"odd\" " timing:@"AFTER" events:@[@"UPDATE", @"DELETE", @"INSERT"] updateColumns:@[@"x ON y", @"Up\"d", @"order"]
										   level:@"ROW" function:function condition:@"current_setting('application_name') <> ' ON x WHEN (' AND pg_trigger_depth() < 2" error:&error]), @"%@", error);
		SPPostgresTrigger *odd = [self trigger:@" ON \"odd\" " of:structure];
		XCTAssertNotNil(odd);
		XCTAssertEqualObjects(odd.events, @"INSERT OR DELETE OR UPDATE OF \"x ON y\", \"Up\"\"d\", \"order\"");
		XCTAssertEqualObjects(odd.timing, @"AFTER");
		XCTAssertEqualObjects(odd.level, @"ROW");
		XCTAssertEqualObjects(odd.functionSchema, @"Sales Data");
		XCTAssertEqualObjects(odd.functionName, @"Odd \"fn\"");
		XCTAssertTrue([odd.condition containsString:@"' ON x WHEN ('"], @"%@", odd.condition);
		XCTAssertTrue([odd.condition hasPrefix:@"(current_setting('application_name'::text) <> ' ON x WHEN ('::text)"], @"%@", odd.condition);
		XCTAssertTrue([odd.condition hasSuffix:@"(pg_trigger_depth() < 2)"], @"%@", odd.condition);

		XCTAssertTrue([structure setTrigger:@" ON \"odd\" " enabled:NO error:&error], @"%@", error);
		XCTAssertFalse([self trigger:@" ON \"odd\" " of:structure].enabled);
		XCTAssertTrue([structure dropTriggerNamed:@" ON \"odd\" " error:&error], @"%@", error);
		XCTAssertEqualObjects([structure triggers:&error], @[]);
	}
}

#pragma mark - Ruling R6

/// The catalog's errors carry the server's SQLSTATE, as every other Postgres error does.
- (void)testCatalogErrorCarriesSQLState
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];
		NSError *error = nil;
		XCTAssertNil([catalog schemaNames:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertEqualObjects(error.userInfo[SPPostgresSQLStateErrorKey], @"25P02");
		XCTAssertTrue([error.localizedDescription length] > 0);
		[connection execute:@"ROLLBACK"];
	}
}

@end
