#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableData.h"
#import "../Source/Postgres/SPPostgresQueryResultEditor.h"

/// Records the statements a connection is about to send (PostgresKit reports willExecute only to a delegate
/// passed at init).
@interface SPQueryEditStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPQueryEditStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	@synchronized (self) { [self.statements addObject:[query description]]; }
}
@end

@interface SPPostgresQueryResultEditorTests : XCTestCase
/// Kept alive past the test's end: a connection doesn't retain its delegate, and it is disconnected after the test.
@property (strong) NSMutableArray<SPQueryEditStatementRecorder *> *recorders;
@end

@implementation SPPostgresQueryResultEditorTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	for (NSNumber *port in [SPPostgresTestServers ports]) [self buildFixtureOnPort:port.unsignedIntegerValue];
}

#pragma mark - Fixture

/// Drops and rebuilds schema query_edit_test (items, pair, nokey, "Mixed Case", customers, orders, flags, items_view).
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
		@"CREATE TABLE query_edit_test.flags (b boolean, c char(4), ip inet)",
		@"INSERT INTO query_edit_test.flags VALUES (true, 'ab', '10.0.0.1'), (false, 'cd', '10.0.0.2')",
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

#pragma mark - Editor

/// An editor over sql's result on a new connection to port.
- (SPPostgresQueryResultEditor *)editorForSQL:(NSString *)sql port:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	return [self editorForSQL:sql connection:connection];
}

- (SPPostgresQueryResultEditor *)editorForSQL:(NSString *)sql connection:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@ failed: %@", sql, [connection lastError]);
	return [[SPPostgresQueryResultEditor alloc] initWithResult:result connection:connection];
}

/// MySQL's strings (Source/SPCustomQuery.m), as the editor must give them.
- (NSString *)noOriginMessage
{
	return NSLocalizedString(@"Field is not editable. Field has no or multiple table or database origin(s).",@"field is not editable due to no table/database");
}

- (void)testValuesAreResultTextAndNull
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, price FROM query_edit_test.items ORDER BY id" port:port];
		XCTAssertEqual([editor rowCount], 2u);
		XCTAssertEqual([editor columnCount], 2u);
		XCTAssertEqualObjects([editor valueAtRow:0 column:0], @"1", @"port %@", port);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"1.50", @"port %@", port);
		XCTAssertEqualObjects([editor valueAtRow:1 column:0], @"2", @"port %@", port);
		XCTAssertEqualObjects([editor valueAtRow:1 column:1], [NSNull null], @"port %@", port);
	}
}

- (void)testKeyedTableCellIsEditable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT name, id FROM query_edit_test.items ORDER BY id" port:port];
		NSInteger count = -2;
		NSString *message = @"unset";
		XCTAssertEqual([editor editabilityOfRow:0 column:0 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
		XCTAssertNil(message);
		XCTAssertEqualObjects([editor typeNameOfColumn:0], @"text");
		XCTAssertTrue([editor columnIsNullable:0]);
		XCTAssertFalse([editor columnIsNullable:1]);
		XCTAssertEqualObjects([editor qualifiedTableNameOfColumn:0], @"\"query_edit_test\".\"items\"");
	}
}

- (void)testExpressionIsNoOrigin
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, upper(name) FROM query_edit_test.items" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellNoOrigin, @"port %@", port);
		XCTAssertEqual(count, -1);
		XCTAssertEqualObjects(message, [self noOriginMessage]);
		XCTAssertNil([editor typeNameOfColumn:1]);
		XCTAssertTrue([editor columnIsNullable:1]);
		XCTAssertNil([editor qualifiedTableNameOfColumn:1]);
	}
}

- (void)testViewIsNotATable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items_view" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellNotATable, @"port %@: %@", port, message);
		XCTAssertEqual(count, -1);
		XCTAssertEqualObjects(message, NSLocalizedString(@"This is a view, so its rows can't be edited.", @"Postgres content: view is read-only"));
	}
}

- (void)testGeneratedColumnRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, twice FROM query_edit_test.items" port:port];
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:NULL message:&message], SPPostgresCellGeneratedColumn, @"port %@: %@", port, message);
		XCTAssertEqualObjects(message, @"This column is generated, so it can't be edited.");
	}
}

- (void)testDuplicateRowsWithoutKeyCountTwo
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT n, t FROM query_edit_test.nokey ORDER BY n" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellTooManyMatches, @"port %@: %@", port, message);
		XCTAssertEqual(count, 2);
		XCTAssertTrue([message containsString:@"(2 matches)"], @"%@", message);
		XCTAssertEqual([editor editabilityOfRow:2 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
	}
}

- (void)testPartialKeyFallsBackToCount
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT a, v FROM query_edit_test.pair ORDER BY a, b" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellTooManyMatches, @"port %@: %@", port, message);
		XCTAssertEqual(count, 2);

		editor = [self editorForSQL:@"SELECT a, b, v FROM query_edit_test.pair ORDER BY a, b" port:port];
		XCTAssertEqual([editor editabilityOfRow:0 column:2 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
	}
}

- (void)testJoinColumnsEditTheirOwnTable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT o.id, o.note, c.id, c.name, o.note || c.name FROM query_edit_test.orders o JOIN query_edit_test.customers c ON c.id = o.customer" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
		XCTAssertEqual([editor editabilityOfRow:0 column:3 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
		XCTAssertEqualObjects([editor qualifiedTableNameOfColumn:3], @"\"query_edit_test\".\"customers\"");
		XCTAssertEqualObjects([editor qualifiedTableNameOfColumn:1], @"\"query_edit_test\".\"orders\"");
		XCTAssertEqual([editor editabilityOfRow:0 column:4 matchCount:&count message:&message], SPPostgresCellNoOrigin, @"port %@", port);
		XCTAssertEqualObjects(message, [self noOriginMessage]);
	}
}

- (void)testTextComparisonForTypesWithoutEquality
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT n, t, p FROM query_edit_test.nokey WHERE n = 2" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
	}
}

/// Output text differs from ::text for these types (t vs true, space padding, 10.0.0.1 vs 10.0.0.1/32), so both
/// sides are compared through the column's type.
- (void)testCastTextComparisonForBoolCharInet
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT b, c, ip FROM query_edit_test.flags ORDER BY ip" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:0 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
	}
}

- (void)testNoMatchMessageNamesTheTable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.customers" connection:connection];
		NSError *error = nil;
		XCTAssertNotNil(SPPostgresExecute(connection, @"DELETE FROM query_edit_test.customers", nil, &error), @"%@", error);
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellNoMatch, @"port %@: %@", port, message);
		XCTAssertEqual(count, 0);
		NSString *expected = [NSString stringWithFormat:NSLocalizedString(@"Field is not editable. No matching record found.\nReload data, check encoding, or try to add\na primary key field or more fields\nin your SELECT statement for table '%@'\nto identify field origin unambiguously.", @"Custom Query result editing error - could not identify original row"), @"customers"];
		XCTAssertEqualObjects(message, expected);
	}
}

- (void)testCatalogLookupRunsOnce
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPQueryEditStatementRecorder *recorder = [[SPQueryEditStatementRecorder alloc] init];
		if (!self.recorders) self.recorders = [NSMutableArray array];
		[self.recorders addObject:recorder];
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:recorder];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT name, id FROM query_edit_test.items ORDER BY id" connection:connection];
		[recorder.statements removeAllObjects];

		XCTAssertEqual([editor editabilityOfRow:0 column:0 matchCount:NULL message:NULL], SPPostgresCellEditable);
		XCTAssertEqual([editor editabilityOfRow:1 column:0 matchCount:NULL message:NULL], SPPostgresCellEditable);
		XCTAssertNotNil([editor typeNameOfColumn:0]);

		NSPredicate *catalog = [NSPredicate predicateWithFormat:@"SELF CONTAINS 'pg_attribute'"];
		NSPredicate *counts = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'SELECT count(*)'"];
		XCTAssertEqual([[recorder.statements filteredArrayUsingPredicate:catalog] count], 1u, @"port %@: %@", port, recorder.statements);
		XCTAssertEqual([[recorder.statements filteredArrayUsingPredicate:counts] count], 2u, @"port %@: %@", port, recorder.statements);
	}
}

- (void)testCheckInAbortedTransactionFails
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		[self addTeardownBlock:^{ [connection execute:@"ROLLBACK"]; }];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT name, id FROM query_edit_test.items ORDER BY id" connection:connection];
		[connection execute:@"BEGIN"];
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInError);

		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:0 matchCount:&count message:&message], SPPostgresCellCheckFailed, @"port %@", port);
		XCTAssertEqual(count, -1);
		XCTAssertEqualObjects(message, @"The current transaction is aborted, so the cell can't be checked for editing. Roll it back first.");
	}
}

@end
