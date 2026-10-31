#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableData.h"
#import "../Source/Postgres/SPPostgresQueryResultEditor.h"
#import "../Source/Postgres/SPPostgresErrors.h"

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

/// Drops and rebuilds schema query_edit_test (items, pair, nokey, "Mixed Case", customers, orders, flags, emp, parts, base, child, pp, items_view).
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
		@"INSERT INTO query_edit_test.pair VALUES (1, 1, 'x'), (1, 2, 'x')",
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
		@"CREATE TABLE query_edit_test.emp (id integer PRIMARY KEY, name text, dept text, manager integer)",
		@"INSERT INTO query_edit_test.emp VALUES (1, 'boss', 'A', NULL), (2, 'worker', 'B', 1), (3, 'boss', 'B', NULL)",
		@"CREATE TABLE query_edit_test.parts (id integer, k integer, v text, PRIMARY KEY (id, k)) PARTITION BY LIST (k)",
		@"CREATE TABLE query_edit_test.parts_1 PARTITION OF query_edit_test.parts FOR VALUES IN (1)",
		@"CREATE TABLE query_edit_test.parts_2 PARTITION OF query_edit_test.parts FOR VALUES IN (2)",
		@"INSERT INTO query_edit_test.parts VALUES (1, 1, 'a'), (2, 2, 'b')",
		@"CREATE TABLE query_edit_test.base (id integer PRIMARY KEY, v text)",
		@"CREATE TABLE query_edit_test.child () INHERITS (query_edit_test.base)",
		@"INSERT INTO query_edit_test.base VALUES (1, 'a')",
		@"INSERT INTO query_edit_test.child VALUES (2, 'c')",
		@"CREATE TABLE query_edit_test.pp (id integer, k integer, name text, PRIMARY KEY (id, k)) PARTITION BY RANGE (k)",
		@"CREATE TABLE query_edit_test.pp1 PARTITION OF query_edit_test.pp FOR VALUES FROM (0) TO (10)",
		@"CREATE TABLE query_edit_test.pp2 PARTITION OF query_edit_test.pp FOR VALUES FROM (10) TO (20)",
		@"INSERT INTO query_edit_test.pp VALUES (1, 1, 'a'), (2, 11, 'x'), (1, 12, 'x')",
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
	return [[SPPostgresQueryResultEditor alloc] initWithResult:result connection:connection statement:sql];
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
		NSPredicate *plans = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'EXPLAIN'"];
		XCTAssertEqual([[recorder.statements filteredArrayUsingPredicate:plans] count], 1u, @"port %@: %@", port, recorder.statements);
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

#pragma mark - Saving

/// The first cell of sql's result, read on a fresh connection to port (so it sees only committed data).
- (id)serverValue:(NSString *)sql port:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	NSError *error = nil;
	PGPostgresResult *result = SPPostgresExecute(connection, sql, nil, &error);
	XCTAssertNotNil(result, @"%@ failed: %@", sql, error);
	return [result textValueAtRow:0 column:0];
}

- (void)testSaveUpdatesRowAndCell
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items ORDER BY id" port:port];
		NSInteger count = -2;
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"uno" row:0 column:1 matchCount:&count error:&error], @"uno", @"port %@: %@", port, error);
		XCTAssertEqual(count, -1);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"uno");
		XCTAssertEqualObjects([editor valueAtRow:1 column:1], @"two");
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"uno");
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 2" port:port], @"two");
	}
}

- (void)testSaveNullAndServerFormat
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name, price FROM query_edit_test.items ORDER BY id" port:port];
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:[NSNull null] row:0 column:1 matchCount:NULL error:&error], [NSNull null], @"port %@: %@", port, error);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], [NSNull null]);
		XCTAssertEqualObjects([self serverValue:@"SELECT (name IS NULL)::text FROM query_edit_test.items WHERE id = 1" port:port], @"true");

		XCTAssertEqualObjects([editor saveValue:@"3.5" row:0 column:2 matchCount:NULL error:&error], @"3.50", @"port %@: %@", port, error);
		XCTAssertEqualObjects([editor valueAtRow:0 column:2], @"3.50");
		XCTAssertEqualObjects([self serverValue:@"SELECT price::text FROM query_edit_test.items WHERE id = 1" port:port], @"3.50");
	}
}

- (void)testSecondEditUsesEditedKey
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items ORDER BY id" port:port];
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"5" row:0 column:0 matchCount:NULL error:&error], @"5", @"port %@: %@", port, error);
		XCTAssertEqualObjects([editor saveValue:@"five" row:0 column:1 matchCount:NULL error:&error], @"five", @"port %@: %@", port, error);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 5" port:port], @"five");
		XCTAssertEqualObjects([self serverValue:@"SELECT count(*)::text FROM query_edit_test.items WHERE id = 1" port:port], @"0");
	}
}

- (void)testDuplicateResultColumnsUpdatedTogether
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name, name FROM query_edit_test.items ORDER BY id" port:port];
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"uno" row:0 column:1 matchCount:NULL error:&error], @"uno", @"port %@: %@", port, error);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"uno");
		XCTAssertEqualObjects([editor valueAtRow:0 column:2], @"uno");
		XCTAssertEqualObjects([editor valueAtRow:1 column:2], @"two");
	}
}

- (void)testUpdateMatchingTwoRowsIsRolledBack
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT n, t FROM query_edit_test.nokey WHERE n = 2" port:port];
		PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		NSError *error = nil;
		XCTAssertNotNil(SPPostgresExecute(other, @"INSERT INTO query_edit_test.nokey VALUES (2, 'b', '(2,2)')", nil, &error), @"%@", error);

		NSInteger count = -2;
		error = nil;
		XCTAssertNil([editor saveValue:@"z" row:0 column:1 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqualObjects([error domain], SPPostgresErrorDomain);
		XCTAssertEqual([error code], SPPostgresErrorRowChanged);
		XCTAssertEqual(count, 2);
		XCTAssertTrue([[error localizedDescription] containsString:@"(2 matches)"], @"%@", [error localizedDescription]);
		XCTAssertTrue([[error localizedDescription] containsString:@"\"query_edit_test\".\"nokey\""], @"%@", [error localizedDescription]);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"b");
		XCTAssertEqualObjects([self serverValue:@"SELECT count(*)::text FROM query_edit_test.nokey WHERE t = 'z'" port:port], @"0");
	}
}

- (void)testRowDeletedMeanwhileMatchesZero
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items ORDER BY id" port:port];
		PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		NSError *error = nil;
		XCTAssertNotNil(SPPostgresExecute(other, @"DELETE FROM query_edit_test.items WHERE id = 1", nil, &error), @"%@", error);

		NSInteger count = -2;
		error = nil;
		XCTAssertNil([editor saveValue:@"uno" row:0 column:1 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorRowChanged);
		XCTAssertEqual(count, 0);
		XCTAssertTrue([[error localizedDescription] containsString:@"(0 matches)"], @"%@", [error localizedDescription]);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"one");
	}
}

- (void)testJoinUpdatesOnlyTheOriginTable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT o.id, o.note, c.id, c.name, o.note || c.name FROM query_edit_test.orders o JOIN query_edit_test.customers c ON c.id = o.customer" port:port];
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"Bea" row:0 column:3 matchCount:NULL error:&error], @"Bea", @"port %@: %@", port, error);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.customers WHERE id = 1" port:port], @"Bea");
		XCTAssertEqualObjects([self serverValue:@"SELECT id::text || ',' || customer::text || ',' || note FROM query_edit_test.orders" port:port], @"10,1,first");
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"first");
		XCTAssertEqualObjects([editor valueAtRow:0 column:4], @"firstAnn"); // an expression isn't an edit of the column
	}
}

- (void)testMixedCaseNamesUpdate
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT \"Key\", \"Value\" FROM query_edit_test.\"Mixed Case\"" port:port];
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"w" row:0 column:1 matchCount:NULL error:&error], @"w", @"port %@: %@", port, error);
		XCTAssertEqualObjects([self serverValue:@"SELECT \"Value\" FROM query_edit_test.\"Mixed Case\" WHERE \"Key\" = 1" port:port], @"w");
	}
}

- (void)testEditInsideOpenTransactionKeepsItOpen
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		[self addTeardownBlock:^{ [connection execute:@"ROLLBACK"]; }];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items ORDER BY id" connection:connection];
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"uno" row:0 column:1 matchCount:NULL error:&error], @"uno", @"port %@: %@", port, error);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction, @"port %@", port);
		XCTAssertEqualObjects([[connection execute:@"SELECT name FROM query_edit_test.items WHERE id = 1"] textValueAtRow:0 column:0], @"uno");
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"one");
	}
}

- (void)testEditInsideAbortedTransactionIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		[self addTeardownBlock:^{ [connection execute:@"ROLLBACK"]; }];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items ORDER BY id" connection:connection];
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInError);

		NSInteger count = -2;
		NSError *error = nil;
		XCTAssertNil([editor saveValue:@"uno" row:0 column:1 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqual(count, -1);
		XCTAssertEqualObjects([error localizedDescription], @"The current transaction is aborted, so the row was not changed. Roll it back first.");
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"one");
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"one");
	}
}

- (void)testBadValueReportsServerError
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items ORDER BY id" port:port];
		NSInteger count = -2;
		NSError *error = nil;
		XCTAssertNil([editor saveValue:@"abc" row:0 column:0 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqual(count, -1);
		XCTAssertTrue([[error localizedDescription] containsString:@"invalid input syntax"], @"%@", [error localizedDescription]);
		XCTAssertEqualObjects([editor valueAtRow:0 column:0], @"1");
	}
}

/// A cell Task 3's rule refuses before counting is refused without an UPDATE, with the same message.
- (void)testNotEditableCellsAreRefusedWithoutUpdate
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPQueryEditStatementRecorder *recorder = [[SPQueryEditStatementRecorder alloc] init];
		if (!self.recorders) self.recorders = [NSMutableArray array];
		[self.recorders addObject:recorder];
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:recorder];

		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, twice, upper(name) FROM query_edit_test.items ORDER BY id" connection:connection];
		NSInteger count = -2;
		NSError *error = nil;
		XCTAssertNil([editor saveValue:@"x" row:0 column:2 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		XCTAssertEqual(count, -1);
		XCTAssertEqualObjects([error localizedDescription], [self noOriginMessage]);

		error = nil;
		XCTAssertNil([editor saveValue:@"4" row:0 column:1 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		XCTAssertEqualObjects([error localizedDescription], @"This column is generated, so it can't be edited.");

		SPPostgresQueryResultEditor *view = [self editorForSQL:@"SELECT id, name FROM query_edit_test.items_view ORDER BY id" connection:connection];
		error = nil;
		XCTAssertNil([view saveValue:@"x" row:0 column:1 matchCount:&count error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		XCTAssertEqualObjects([error localizedDescription], NSLocalizedString(@"This is a view, so its rows can't be edited.", @"Postgres content: view is read-only"));

		NSPredicate *updates = [NSPredicate predicateWithFormat:@"SELF CONTAINS[c] 'UPDATE'"];
		XCTAssertEqual([[recorder.statements filteredArrayUsingPredicate:updates] count], 0u, @"port %@: %@", port, recorder.statements);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"one");
	}
}

/// The saved value is the column's output text, as the result shows it, not its ::text.
- (void)testSavedValueIsOutputText
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT b, c, ip FROM query_edit_test.flags ORDER BY ip" port:port];
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"false" row:0 column:0 matchCount:NULL error:&error], @"f", @"port %@: %@", port, error);
		XCTAssertEqualObjects([editor valueAtRow:0 column:0], @"f");
		XCTAssertEqualObjects([editor saveValue:@"xy" row:0 column:1 matchCount:NULL error:&error], @"xy  ", @"port %@: %@", port, error);
		XCTAssertEqualObjects([editor saveValue:@"10.0.0.5" row:0 column:2 matchCount:NULL error:&error], @"10.0.0.5", @"port %@: %@", port, error);
		// A later edit of the row still finds it by these values
		XCTAssertEqualObjects([editor saveValue:@"true" row:0 column:0 matchCount:NULL error:&error], @"t", @"port %@: %@", port, error);
		XCTAssertEqualObjects([self serverValue:@"SELECT b::text || ',' || c::text || ',' || host(ip) FROM query_edit_test.flags WHERE ip = '10.0.0.5'" port:port], @"true,xy,10.0.0.5");
	}
}

#pragma mark - Tables read more than once

- (NSString *)originRepeatedMessage
{
	return NSLocalizedString(@"This table appears more than once in the query, so its rows can't be identified.", @"Postgres query result: origin table read more than once (self-join)");
}

/// sql's cell (row, column) is refused by the check (OriginRepeated, no count) and by the save (NotEditable, nothing
/// changed on the server).
- (void)assertOriginRepeatedForSQL:(NSString *)sql row:(NSUInteger)row column:(NSUInteger)column port:(NSNumber *)port
{
	NSString *before = [self serverValue:@"SELECT string_agg(id || ':' || name || ':' || dept, ',' ORDER BY id) FROM query_edit_test.emp" port:port];
	SPPostgresQueryResultEditor *editor = [self editorForSQL:sql port:port];
	NSInteger count = -2;
	NSString *message = nil;
	XCTAssertEqual([editor editabilityOfRow:row column:column matchCount:&count message:&message], SPPostgresCellOriginRepeated, @"port %@ %@: %@", port, sql, message);
	XCTAssertEqual(count, -1);
	XCTAssertEqualObjects(message, [self originRepeatedMessage]);

	NSError *error = nil;
	count = -2;
	id original = [editor valueAtRow:row column:column];
	XCTAssertNil([editor saveValue:@"chief" row:row column:column matchCount:&count error:&error], @"port %@ %@", port, sql);
	XCTAssertEqual([error code], SPPostgresErrorNotEditable);
	XCTAssertEqualObjects([error localizedDescription], [self originRepeatedMessage]);
	XCTAssertEqual(count, -1);
	XCTAssertEqualObjects([editor valueAtRow:row column:column], original);
	XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(id || ':' || name || ':' || dept, ',' ORDER BY id) FROM query_edit_test.emp" port:port], before);
}

/// PostgreSQL reports a field's table and column, not its alias, so a self-join's values can't tell its aliases apart.
- (void)testSelfJoinIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *join = @"FROM query_edit_test.emp e JOIN query_edit_test.emp m ON m.id = e.manager";
		[self assertOriginRepeatedForSQL:[@"SELECT e.id, e.name, m.id, m.name " stringByAppendingString:join] row:0 column:3 port:port];
		[self assertOriginRepeatedForSQL:[@"SELECT e.id, e.name, m.id, m.name " stringByAppendingString:join] row:0 column:1 port:port];
		[self assertOriginRepeatedForSQL:[@"SELECT e.name, m.name " stringByAppendingString:join] row:0 column:1 port:port];
		[self assertOriginRepeatedForSQL:[@"SELECT e.id, m.name " stringByAppendingString:join] row:0 column:1 port:port];
	}
}

/// Case A: with equal names, e.id plus m.name would identify e's row (2) for m's cell.
- (void)testSelfJoinWithCoincidingValuesIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		NSError *error = nil;
		XCTAssertNotNil(SPPostgresExecute(connection, @"UPDATE query_edit_test.emp SET name = 'Sam' WHERE id IN (1, 2)", nil, &error), @"%@", error);
		[self assertOriginRepeatedForSQL:@"SELECT e.id, m.name FROM query_edit_test.emp e JOIN query_edit_test.emp m ON m.id = e.manager" row:0 column:1 port:port];
	}
}

/// Case B: e.dept plus m.name of the worker row (B, boss) would identify row 3, in neither alias.
- (void)testSelfJoinMatchingNeitherAliasIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self assertOriginRepeatedForSQL:@"SELECT e.dept, m.name FROM query_edit_test.emp e JOIN query_edit_test.emp m ON m.id = e.manager" row:0 column:1 port:port];
	}
}

/// Conservative: any second read of the table refuses it, also a subquery's.
- (void)testSubqueryOnSameTableIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self assertOriginRepeatedForSQL:@"SELECT * FROM query_edit_test.emp WHERE id IN (SELECT manager FROM query_edit_test.emp)" row:0 column:1 port:port];
	}
}

- (void)testSingleReadOfEmpIsEditable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, name FROM query_edit_test.emp WHERE id = 2" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
	}
}

/// A partitioned table's partitions are one read (one Append).
- (void)testPartitionedTableIsEditable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, k, v FROM query_edit_test.parts ORDER BY id" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:1 column:2 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"bb" row:1 column:2 matchCount:&count error:&error], @"bb", @"port %@: %@", port, error);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(v, ',' ORDER BY id) FROM query_edit_test.parts" port:port], @"a,bb");
	}
}

/// An inheritance parent and its child are one read (one Append).
- (void)testInheritanceParentIsEditable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresQueryResultEditor *editor = [self editorForSQL:@"SELECT id, v FROM query_edit_test.base ORDER BY id" port:port];
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
		XCTAssertEqual([editor editabilityOfRow:1 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@: %@", port, message);
		XCTAssertEqual(count, 1);
		NSError *error = nil;
		XCTAssertEqualObjects([editor saveValue:@"cc" row:1 column:1 matchCount:&count error:&error], @"cc", @"port %@: %@", port, error);
		XCTAssertEqualObjects([self serverValue:@"SELECT v FROM query_edit_test.child" port:port], @"cc");
		XCTAssertEqualObjects([self serverValue:@"SELECT v FROM ONLY query_edit_test.base" port:port], @"a");
	}
}

#pragma mark - Common table expressions

/// A CTE's columns report the CTE's table as their origin (checked on PG12 and PG18), and a CTE read twice is a
/// self-join whose plan has no second scan of the table: one Seq Scan in the InitPlan "CTE x", read by two CTE Scans.
/// Case A data (both names 'Sam'): editing b.name would build id = 2 AND name = 'Sam', the other alias's row.
- (void)testCTEReadTwiceIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		NSError *error = nil;
		XCTAssertNotNil(SPPostgresExecute(connection, @"UPDATE query_edit_test.emp SET name = 'Sam' WHERE id IN (1, 2)", nil, &error), @"%@", error);
		for (NSString *with in @[@"WITH x AS (SELECT * FROM query_edit_test.emp) ", @"WITH x AS MATERIALIZED (SELECT * FROM query_edit_test.emp) "]) {
			[self assertOriginRepeatedForSQL:[with stringByAppendingString:@"SELECT a.id, b.name FROM x a JOIN x b ON b.id = a.manager"] row:0 column:1 port:port];
			[self assertOriginRepeatedForSQL:[with stringByAppendingString:@"SELECT a.id, b.name FROM x a JOIN x b ON b.id = a.manager"] row:0 column:0 port:port];
		}
	}
}

/// Case B through a CTE: e.dept plus m.name of the worker row (B, boss) would identify row 3, in neither alias.
- (void)testCTESelfJoinMatchingNeitherAliasIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self assertOriginRepeatedForSQL:@"WITH x AS (SELECT * FROM query_edit_test.emp) SELECT e.dept, m.name FROM x e JOIN x m ON m.id = e.manager" row:0 column:1 port:port];
		[self assertOriginRepeatedForSQL:@"WITH x AS MATERIALIZED (SELECT * FROM query_edit_test.emp) SELECT e.dept, m.name FROM x e JOIN x m ON m.id = e.manager" row:0 column:1 port:port];
	}
}

/// A CTE referenced once is one read of its table, also through a second CTE (y reads x once, the query reads y once).
/// PQftable reports emp for the CTE's columns on both servers, so the cell is editable and the save finds the row.
- (void)testCTEReadOnceIsEditable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSArray *statements = @[
			@"WITH x AS MATERIALIZED (SELECT * FROM query_edit_test.emp) SELECT id, name FROM x WHERE id = 2",
			@"WITH x AS (SELECT * FROM query_edit_test.emp) SELECT id, name FROM x WHERE id = 2",
			@"WITH x AS MATERIALIZED (SELECT * FROM query_edit_test.emp), y AS MATERIALIZED (SELECT * FROM x) SELECT id, name FROM y WHERE id = 2",
		];
		for (NSString *sql in statements) {
			SPPostgresQueryResultEditor *editor = [self editorForSQL:sql port:port];
			NSInteger count = -2;
			NSString *message = nil;
			XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellEditable, @"port %@ %@: %@", port, sql, message);
			XCTAssertEqual(count, 1);
			NSError *error = nil;
			NSString *saved = [NSString stringWithFormat:@"w%lu", (unsigned long)[statements indexOfObject:sql]];
			XCTAssertEqualObjects([editor saveValue:saved row:0 column:1 matchCount:&count error:&error], saved, @"port %@ %@: %@", port, sql, error);
			NSString *expected = [NSString stringWithFormat:@"boss,%@,boss", saved];
			XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(name, ',' ORDER BY id) FROM query_edit_test.emp" port:port], expected);
		}
	}
}

/// A CTE read twice inside another CTE, or a CTE over a CTE read twice: the reads are expanded through every level.
- (void)testNestedCTEReadTwiceIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self assertOriginRepeatedForSQL:@"WITH x AS MATERIALIZED (SELECT * FROM query_edit_test.emp), y AS MATERIALIZED (SELECT a.id, b.name FROM x a JOIN x b ON b.id = a.manager) SELECT id, name FROM y" row:0 column:1 port:port];
		[self assertOriginRepeatedForSQL:@"WITH x AS MATERIALIZED (SELECT * FROM query_edit_test.emp), y AS MATERIALIZED (SELECT * FROM x) SELECT a.id, b.name FROM y a JOIN y b ON b.id = a.manager" row:0 column:1 port:port];
	}
}

/// A recursive CTE's columns have no origin (PQftable reports 0), but a table joined to it is read again through the
/// CTE, whose WorkTable Scan is a further read.
- (void)testRecursiveCTEJoinedWithItsTableIsRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *sql = @"WITH RECURSIVE r AS (SELECT id, manager FROM query_edit_test.emp WHERE manager IS NULL "
			"UNION ALL SELECT e.id, e.manager FROM query_edit_test.emp e JOIN r ON e.manager = r.id) "
			"SELECT e.id, e.name, r.id FROM query_edit_test.emp e JOIN r ON r.id = e.id ORDER BY e.id";
		[self assertOriginRepeatedForSQL:sql row:0 column:1 port:port];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:sql port:port];
		XCTAssertEqual([editor editabilityOfRow:0 column:2 matchCount:NULL message:NULL], SPPostgresCellNoOrigin, @"port %@", port);
	}
}

/// Each CTE reads the previous one twice, so expanding every CTE Scan visits 2^25 scans: the walk gives up after its
/// budget (CheckFailed, "too complex") or, were it to finish, refuses the repeated table; either way, quickly.
- (void)testChainedCTEsAreRefusedQuickly
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSMutableString *sql = [NSMutableString stringWithString:@"WITH x0 AS MATERIALIZED (SELECT * FROM query_edit_test.emp)"];
		for (NSUInteger level = 1; level <= 25; level++) {
			// WHERE a.id keeps the row estimate at 1: without it the costs reach 1e100 at level 25, which no JSON parser reads
			[sql appendFormat:@", x%lu AS MATERIALIZED (SELECT a.* FROM x%lu a JOIN x%lu b ON b.id = a.id WHERE a.id = 2)", (unsigned long)level, (unsigned long)level - 1, (unsigned long)level - 1];
		}
		[sql appendString:@" SELECT id, name FROM x25"];
		NSDate *start = [NSDate date];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:sql port:port];
		NSInteger count = -2;
		NSString *message = nil;
		SPPostgresCellEditability status = [editor editabilityOfRow:0 column:1 matchCount:&count message:&message];
		if (status == SPPostgresCellCheckFailed) {
			XCTAssertEqualObjects(message, [self tooComplexMessage], @"port %@", port);
		} else {
			XCTAssertEqual(status, SPPostgresCellOriginRepeated, @"port %@: %@", port, message);
		}
		NSError *error = nil;
		XCTAssertNil([editor saveValue:@"chief" row:0 column:1 matchCount:NULL error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		XCTAssertLessThan(-[start timeIntervalSinceNow], 20.0, @"port %@", port);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.emp WHERE id = 2" port:port], @"worker");
	}
}

/// Partitions of one table, each read once in its own scan inside one WITH query (a reads pp1, b reads pp2, after
/// pruning), are two reads of pp: the result's row 1|x is a's id with b's name, and WHERE id = 1 AND name = 'x'
/// identifies (1, 12, 'x'), a row of neither alias.
- (void)testPartitionsReadSeparatelyInsideCTEAreRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *sql = @"WITH x AS MATERIALIZED (SELECT a.id, b.name FROM query_edit_test.pp a JOIN query_edit_test.pp b "
			"ON b.id = a.id + 1 WHERE a.k < 10 AND b.k >= 10) SELECT id, name FROM x";
		NSString *before = [self serverValue:@"SELECT string_agg(id || ':' || k || ':' || name, ',' ORDER BY id, k) FROM query_edit_test.pp" port:port];
		SPPostgresQueryResultEditor *editor = [self editorForSQL:sql port:port];
		XCTAssertEqual([editor rowCount], 1u);
		XCTAssertEqualObjects([editor valueAtRow:0 column:1], @"x");
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:&count message:&message], SPPostgresCellOriginRepeated, @"port %@: %@", port, message);
		XCTAssertEqualObjects(message, [self originRepeatedMessage]);
		NSError *error = nil;
		XCTAssertNil([editor saveValue:@"changed" row:0 column:1 matchCount:NULL error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(id || ':' || k || ':' || name, ',' ORDER BY id, k) FROM query_edit_test.pp" port:port], before);
	}
}

/// ONLY the inheritance parent and its child, each read once inside one WITH query, are two reads of the parent's family.
- (void)testOnlyParentAndChildInsideCTEAreRefused
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *sql = @"WITH x AS MATERIALIZED (SELECT a.id, b.v FROM ONLY query_edit_test.base a JOIN query_edit_test.child b "
			"ON b.id = a.id + 1) SELECT id, v FROM x";
		SPPostgresQueryResultEditor *editor = [self editorForSQL:sql port:port];
		XCTAssertEqual([editor rowCount], 1u);
		NSInteger count = -2;
		NSString *message = nil;
		XCTAssertEqual([editor editabilityOfRow:0 column:0 matchCount:&count message:&message], SPPostgresCellOriginRepeated, @"port %@: %@", port, message);
		NSError *error = nil;
		XCTAssertNil([editor saveValue:@"5" row:0 column:0 matchCount:NULL error:&error], @"port %@", port);
		XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM query_edit_test.base" port:port], @"1:a,2:c");
	}
}

#pragma mark - Plan walk on hand-written plans

- (NSString *)tooComplexMessage
{
	return NSLocalizedString(@"This query is too complex to check which rows it shows.", @"Postgres query result: edit check gave up on a plan too large to walk");
}

- (NSString *)customScanMessage
{
	return NSLocalizedString(@"The query's plan uses an extension's scan, so its rows can't be identified.", @"Postgres query result: edit check found a Custom Scan without a relation");
}

- (id)plan:(NSString *)json
{
	id plan = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
	XCTAssertNotNil(plan, @"%@", json);
	return plan;
}

/// An extension's Custom Scan without "Relation Name" (Citus plans a multi-shard self-join as one) can hide reads
/// while PQftable still reports the table, so the check fails; one naming its relation counts as a read.
- (void)testCustomScanWithoutRelationFailsTheWalk
{
	NSError *error = nil;
	XCTAssertNil([SPPostgresQueryResultEditor readsInPlan:[self plan:@"[{\"Plan\": {\"Node Type\": \"Custom Scan\", \"Custom Plan Provider\": \"Citus Adaptive\", \"Plans\": []}}]"] error:&error]);
	XCTAssertEqualObjects([error localizedDescription], [self customScanMessage]);

	// Inside a CTE's plan
	error = nil;
	XCTAssertNil([SPPostgresQueryResultEditor readsInPlan:[self plan:@"[{\"Plan\": {\"Node Type\": \"Hash Join\", \"Plans\": ["
		"{\"Node Type\": \"Custom Scan\", \"Subplan Name\": \"CTE x\", \"Parent Relationship\": \"InitPlan\"},"
		"{\"Node Type\": \"CTE Scan\", \"CTE Name\": \"x\"}]}}]"] error:&error]);
	XCTAssertEqualObjects([error localizedDescription], [self customScanMessage]);

	// With a relation: one read
	error = nil;
	NSArray *reads = [SPPostgresQueryResultEditor readsInPlan:[self plan:@"[{\"Plan\": {\"Node Type\": \"Custom Scan\", \"Schema\": \"s\", \"Relation Name\": \"t\"}}]"] error:&error];
	XCTAssertEqual([reads count], 1u, @"%@", error);
	XCTAssertEqualObjects([[reads firstObject] subarrayWithRange:NSMakeRange(0, 2)], (@[@"s", @"t"]));
}

/// A CTE Scan whose CTE has no plan in the tree fails the walk; a CTE read twice gives two reads of its table.
- (void)testCTEWalkOnHandWrittenPlans
{
	NSError *error = nil;
	XCTAssertNil([SPPostgresQueryResultEditor readsInPlan:[self plan:@"[{\"Plan\": {\"Node Type\": \"CTE Scan\", \"CTE Name\": \"x\"}}]"] error:&error]);
	XCTAssertGreaterThan([[error localizedDescription] length], 0u);

	NSArray *reads = [SPPostgresQueryResultEditor readsInPlan:[self plan:@"[{\"Plan\": {\"Node Type\": \"Hash Join\", \"Plans\": ["
		"{\"Node Type\": \"Seq Scan\", \"Schema\": \"s\", \"Relation Name\": \"emp\", \"Subplan Name\": \"CTE x\", \"Parent Relationship\": \"InitPlan\"},"
		"{\"Node Type\": \"CTE Scan\", \"CTE Name\": \"x\"},"
		"{\"Node Type\": \"Hash\", \"Plans\": [{\"Node Type\": \"CTE Scan\", \"CTE Name\": \"x\"}]}]}}]"] error:&error];
	XCTAssertEqual([reads count], 2u, @"%@", error);
	XCTAssertNotEqualObjects([[reads objectAtIndex:0] objectAtIndex:2], [[reads objectAtIndex:1] objectAtIndex:2]);
}

/// Every CTE Scan expands its WITH query again: a chain of 14 WITH queries each scanning the previous one twice is
/// 2^14 scans, past the walk's budget of 10,000 node visits, so the walk fails as too complex.
- (void)testWalkOverBudgetFailsAsTooComplex
{
	NSMutableArray *nodes = [NSMutableArray arrayWithObject:@{@"Node Type": @"Seq Scan", @"Schema": @"s", @"Relation Name": @"t", @"Subplan Name": @"CTE x0", @"Parent Relationship": @"InitPlan"}];
	for (NSUInteger level = 1; level <= 14; level++) {
		NSString *previous = [NSString stringWithFormat:@"x%lu", (unsigned long)level - 1];
		[nodes addObject:@{@"Node Type": @"Nested Loop", @"Subplan Name": [NSString stringWithFormat:@"CTE x%lu", (unsigned long)level], @"Parent Relationship": @"InitPlan",
						   @"Plans": @[@{@"Node Type": @"CTE Scan", @"CTE Name": previous}, @{@"Node Type": @"CTE Scan", @"CTE Name": previous}]}];
	}
	[nodes addObject:@{@"Node Type": @"CTE Scan", @"CTE Name": @"x14"}];
	NSArray *plan = @[@{@"Plan": @{@"Node Type": @"Result", @"Plans": [nodes copy]}}];
	NSError *error = nil;
	XCTAssertNil([SPPostgresQueryResultEditor readsInPlan:plan error:&error]);
	XCTAssertEqualObjects([error localizedDescription], [self tooComplexMessage]);

	// Within the budget (5 levels, 2^5 scans) the walk finishes: the table's reads are one per path.
	[nodes removeAllObjects];
	[nodes addObject:@{@"Node Type": @"Seq Scan", @"Schema": @"s", @"Relation Name": @"t", @"Subplan Name": @"CTE x0", @"Parent Relationship": @"InitPlan"}];
	for (NSUInteger level = 1; level <= 5; level++) {
		NSString *previous = [NSString stringWithFormat:@"x%lu", (unsigned long)level - 1];
		[nodes addObject:@{@"Node Type": @"Nested Loop", @"Subplan Name": [NSString stringWithFormat:@"CTE x%lu", (unsigned long)level], @"Parent Relationship": @"InitPlan",
						   @"Plans": @[@{@"Node Type": @"CTE Scan", @"CTE Name": previous}, @{@"Node Type": @"CTE Scan", @"CTE Name": previous}]}];
	}
	[nodes addObject:@{@"Node Type": @"CTE Scan", @"CTE Name": @"x5"}];
	plan = @[@{@"Plan": @{@"Node Type": @"Result", @"Plans": [nodes copy]}}];
	error = nil;
	NSArray *reads = [SPPostgresQueryResultEditor readsInPlan:plan error:&error];
	XCTAssertEqual([reads count], 32u, @"%@", error);
}

/// Without the statement (or with one that can't be explained) nothing can be checked, and nothing is saved.
- (void)testMissingOrUnexplainableStatementFailsCheck
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		PGPostgresResult *result = [connection execute:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		for (NSString *statement in @[@"", @"SELECT id, name FROM query_edit_test.missing"]) {
			SPPostgresQueryResultEditor *editor = [[SPPostgresQueryResultEditor alloc] initWithResult:result connection:connection statement:statement];
			NSString *message = nil;
			XCTAssertEqual([editor editabilityOfRow:0 column:1 matchCount:NULL message:&message], SPPostgresCellCheckFailed, @"port %@ '%@'", port, statement);
			XCTAssertGreaterThan([message length], 0u);
			NSError *error = nil;
			XCTAssertNil([editor saveValue:@"uno" row:0 column:1 matchCount:NULL error:&error]);
			XCTAssertEqual([error code], SPPostgresErrorNotEditable);
		}
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"one");
	}
}

@end
