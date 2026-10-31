#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableData.h"

@interface SPPostgresQueryResultEditorTests : XCTestCase
@end

@implementation SPPostgresQueryResultEditorTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	for (NSNumber *port in [SPPostgresTestServers ports]) [self buildFixtureOnPort:port.unsignedIntegerValue];
}

#pragma mark - Fixture

/// Drops and rebuilds schema query_edit_test (items, pair, nokey, "Mixed Case", customers, orders, items_view).
- (void)buildFixtureOnPort:(NSUInteger)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port];
	XCTAssertNotNil(connection);
	NSArray *statements = @[
		@"DROP SCHEMA IF EXISTS query_edit_test CASCADE",
		@"CREATE SCHEMA query_edit_test",
		@"CREATE TABLE query_edit_test.items (id integer PRIMARY KEY, name text, price numeric(8,2), doc json, twice integer GENERATED ALWAYS AS (id * 2) STORED)",
		@"INSERT INTO query_edit_test.items (id, name, price, doc) VALUES (1, 'one', 1.50, '{\"a\":1}'), (2, 'two', NULL, NULL)",
		@"CREATE TABLE query_edit_test.pair (a integer, b integer, v text, PRIMARY KEY (a, b))",
		@"INSERT INTO query_edit_test.pair VALUES (1, 1, 'x'), (1, 2, 'y')",
		@"CREATE TABLE query_edit_test.nokey (n integer, t text, p point)",
		@"INSERT INTO query_edit_test.nokey VALUES (1, 'a', '(1,1)'), (1, 'a', '(1,1)'), (2, 'b', '(2,2)')",
		@"CREATE TABLE query_edit_test.\"Mixed Case\" (\"Key\" integer PRIMARY KEY, \"Value\" text)",
		@"INSERT INTO query_edit_test.\"Mixed Case\" VALUES (1, 'v')",
		@"CREATE TABLE query_edit_test.customers (id integer PRIMARY KEY, name text)",
		@"INSERT INTO query_edit_test.customers VALUES (1, 'Ann')",
		@"CREATE TABLE query_edit_test.orders (id integer PRIMARY KEY, customer integer, note text)",
		@"INSERT INTO query_edit_test.orders VALUES (10, 1, 'first')",
		@"CREATE VIEW query_edit_test.items_view AS SELECT id, name FROM query_edit_test.items",
	];
	for (NSString *sql in statements) {
		NSError *error = nil;
		XCTAssertNotNil(SPPostgresExecute(connection, sql, nil, &error), @"%@ failed: %@", sql, error);
	}
}

#pragma mark - Field origins

- (void)testFieldOrigins
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		PGPostgresResult *oidResult = [connection execute:@"SELECT 'query_edit_test.items'::regclass::oid::text"];
		NSInteger oid = [[[oidResult rowAsArray] firstObject] integerValue];
		XCTAssertGreaterThan(oid, 0);

		PGPostgresResult *result = [connection execute:@"SELECT i.name, i.id, 1 AS one, i.id + 1 AS next FROM query_edit_test.items i"];
		XCTAssertEqual((NSInteger)[result tableOIDForField:0], oid, @"port %@", port);
		XCTAssertEqual([result tableColumnForField:0], 2, @"port %@", port);
		XCTAssertEqual([result tableColumnForField:1], 1, @"port %@", port);
		XCTAssertEqual([result tableOIDForField:2], 0u);
		XCTAssertEqual([result tableColumnForField:2], 0);
		XCTAssertEqual([result tableOIDForField:3], 0u);
		XCTAssertEqual([result tableColumnForField:3], 0);
		XCTAssertEqual([result tableOIDForField:99], 0u);
		XCTAssertEqual([result tableColumnForField:99], 0);
	}
}

@end
