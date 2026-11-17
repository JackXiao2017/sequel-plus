#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/Postgres/SPPostgresForeignKeyPickerSource.h"

/// Records the statements a connection is about to send.
@interface SPFKPickerStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPFKPickerStatementRecorder
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

/**
 * The foreign key picker's PostgreSQL source, on PG12 and PG18: table "FK Picker Data"."Customer List" (a schema of
 * its own, so the shared catalog fixture's "Sales Data" is never touched), dropped one by one afterwards.
 */
@interface SPPostgresForeignKeyPickerSourceTests : XCTestCase
@property (strong) SPFKPickerStatementRecorder *recorder;
@property (strong) PGPostgresConnection *connection;
@property (strong) SPPostgresForeignKeyPickerSource *source;
@end

@implementation SPPostgresForeignKeyPickerSourceTests

- (void)run:(NSString *)sql
{
	XCTAssertNotNil([self.connection execute:sql], @"%@: %@", sql, [[self.connection lastError] errorPrimaryMessage]);
}

- (void)dropFixture
{
	[self.connection execute:@"DROP TABLE IF EXISTS \"FK Picker Data\".\"Customer List\""];
	[self.connection execute:@"DROP SCHEMA IF EXISTS \"FK Picker Data\""];
}

- (void)setUpOnPort:(NSUInteger)port
{
	self.continueAfterFailure = NO;
	self.recorder = [[SPFKPickerStatementRecorder alloc] init];
	self.connection = [SPPostgresTestServers connectedConnectionOnPort:port database:@"pgkit_test" delegate:self.recorder];
	XCTAssertNotNil(self.connection);
	[self dropFixture];
	[self run:@"CREATE SCHEMA \"FK Picker Data\""];
	[self run:@"CREATE TABLE \"FK Picker Data\".\"Customer List\" (id int PRIMARY KEY, name text, email text, city text, created_at date)"];
	[self run:@"INSERT INTO \"FK Picker Data\".\"Customer List\" VALUES "
			   "(1, 'Anna Smith', 'anna@x', 'Leeds', '2025-03-02'), (2, 'Joe Smithers', 'joe@x', 'Austin', '2026-07-19'), "
			   "(3, 'Mary Lee', 'mary.smi@x', 'Leeds', '2024-01-01'), (4, '100% Pure_Co', 'p@x', NULL, NULL), "
			   "(5, 'O''Neil', 'o@x', 'Cork', '2025-06-01')"];
	[self run:@"INSERT INTO \"FK Picker Data\".\"Customer List\" SELECT n, 'bulk ' || n, 'bulk' || n || '@x', NULL, NULL FROM generate_series(1001, 1250) AS n"];
	SPPostgresTaskRunner *runner = [SPPostgresTaskRunner inlineRunnerWithConnection:self.connection];
	self.source = [[SPPostgresForeignKeyPickerSource alloc] initWithTaskRunner:runner schema:@"FK Picker Data" table:@"Customer List" keyColumn:@"id"];
	[self.recorder.statements removeAllObjects];
}

- (void)tearDownPort
{
	[self dropFixture];
	[self.connection disconnect];
	self.connection = nil;
	self.source = nil;
}

- (void)eachPort:(void (^)(NSUInteger port))body
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self setUpOnPort:[port unsignedIntegerValue]];
		body([port unsignedIntegerValue]);
		[self tearDownPort];
	}
}

- (NSArray<NSArray *> *)fetch:(NSString *)search in:(NSArray *)searchColumns conditions:(NSArray *)conditions columns:(NSArray *)columns offset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSString **)error
{
	__block NSArray *result = nil;
	__block NSString *message = nil;
	__block BOOL done = NO;
	[self.source fetchRowsWithSearch:search inColumns:searchColumns conditions:conditions columns:columns offset:offset limit:limit completion:^(NSArray *rows, NSString *errorMessage) {
		XCTAssertTrue([NSThread isMainThread]);
		result = rows;
		message = errorMessage;
		done = YES;
	}];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while (!done && [deadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	XCTAssertTrue(done);
	if (error) *error = message;
	return result;
}

- (NSArray *)ids:(NSString *)search in:(NSArray *)searchColumns conditions:(NSArray *)conditions
{
	NSString *error = nil;
	NSArray *rows = [self fetch:search in:searchColumns conditions:conditions columns:@[@"id"] offset:0 limit:300 error:&error];
	XCTAssertNotNil(rows, @"%@", error);
	NSMutableArray *ids = [NSMutableArray array];
	for (NSArray *row in rows) [ids addObject:row[0]];
	return ids;
}

- (void)testColumnsAndKinds
{
	[self eachPort:^(NSUInteger port) {
		__block NSArray<SPForeignKeyPickerColumn *> *columns = nil;
		__block BOOL done = NO;
		[self.source loadColumnsWithCompletion:^(NSArray *theColumns, NSString *errorMessage) {
			XCTAssertNil(errorMessage);
			columns = theColumns;
			done = YES;
		}];
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
		while (!done && [deadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		XCTAssertEqualObjects([columns valueForKey:@"name"], (@[@"id", @"name", @"email", @"city", @"created_at"]));
		XCTAssertEqual(columns[0].kind, SPForeignKeyColumnNumber);
		XCTAssertEqual(columns[1].kind, SPForeignKeyColumnText);
		XCTAssertEqual(columns[4].kind, SPForeignKeyColumnDateTime);
		XCTAssertEqualObjects(self.source.keyColumn, @"id");
	}];
}

- (void)testSearchMatchesShownColumnsCaseInsensitive
{
	[self eachPort:^(NSUInteger port) {
		XCTAssertEqualObjects(([self ids:@"smi" in:@[@"name", @"email"] conditions:@[]]), (@[@"1", @"2", @"3"]));
		XCTAssertEqualObjects(([self ids:@"SMI" in:@[@"name"] conditions:@[]]), (@[@"1", @"2"]));
		NSString *error = nil;
		NSArray *rows = [self fetch:@"anna" in:@[@"name"] conditions:@[] columns:@[@"id", @"name", @"created_at"] offset:0 limit:10 error:&error];
		XCTAssertEqualObjects(rows, (@[@[@"1", @"Anna Smith", @"2025-03-02"]]));
		rows = [self fetch:@"Pure" in:@[@"name"] conditions:@[] columns:@[@"id", @"city"] offset:0 limit:10 error:&error];
		XCTAssertEqualObjects(rows, (@[@[@"4", [NSNull null]]]));
	}];
}

- (void)testSearchEscapesWildcardsAndQuotes
{
	[self eachPort:^(NSUInteger port) {
		XCTAssertEqualObjects(([self ids:@"%" in:@[@"name", @"email"] conditions:@[]]), (@[@"4"]));
		XCTAssertEqualObjects(([self ids:@"_" in:@[@"name", @"email"] conditions:@[]]), (@[@"4"]));
		XCTAssertEqualObjects(([self ids:@"'" in:@[@"name", @"email"] conditions:@[]]), (@[@"5"]));
		XCTAssertEqualObjects(([self ids:@"\\" in:@[@"name", @"email"] conditions:@[]]), (@[]));
	}];
}

- (void)testConditionsAreAnded
{
	[self eachPort:^(NSUInteger port) {
		NSArray *both = @[[SPForeignKeyCondition conditionWithColumn:@"name" op:SPForeignKeyOpContains value:@"smi" secondValue:nil],
						  [SPForeignKeyCondition conditionWithColumn:@"city" op:SPForeignKeyOpEquals value:@"Leeds" secondValue:nil]];
		XCTAssertEqualObjects(([self ids:nil in:@[] conditions:both]), (@[@"1"]));
		XCTAssertEqualObjects(([self ids:@"lee" in:@[@"name"] conditions:@[both[1]]]), (@[@"3"]));
		NSArray *between = @[[SPForeignKeyCondition conditionWithColumn:@"created_at" op:SPForeignKeyOpBetween value:@"2025-01-01" secondValue:@"2025-12-31"]];
		XCTAssertEqualObjects(([self ids:nil in:@[] conditions:between]), (@[@"1", @"5"]));
		NSArray *starts = @[[SPForeignKeyCondition conditionWithColumn:@"name" op:SPForeignKeyOpStartsWith value:@"jo" secondValue:nil]];
		XCTAssertEqualObjects(([self ids:nil in:@[] conditions:starts]), (@[@"2"]));
		NSArray *compare = @[[SPForeignKeyCondition conditionWithColumn:@"id" op:SPForeignKeyOpGreater value:@"3" secondValue:nil],
							 [SPForeignKeyCondition conditionWithColumn:@"id" op:SPForeignKeyOpLessOrEqual value:@"5" secondValue:nil],
							 [SPForeignKeyCondition conditionWithColumn:@"id" op:SPForeignKeyOpNotEquals value:@"4" secondValue:nil]];
		XCTAssertEqualObjects(([self ids:nil in:@[] conditions:compare]), (@[@"5"]));
		NSArray *isNull = @[[SPForeignKeyCondition conditionWithColumn:@"city" op:SPForeignKeyOpIsNull value:nil secondValue:nil]];
		NSArray *nullIds = [self ids:nil in:@[] conditions:isNull];
		XCTAssertEqual(nullIds.count, 251u);
		XCTAssertEqualObjects(nullIds.firstObject, @"4");
		NSArray *notNull = @[[SPForeignKeyCondition conditionWithColumn:@"city" op:SPForeignKeyOpIsNotNull value:nil secondValue:nil]];
		XCTAssertEqualObjects(([self ids:nil in:@[] conditions:notNull]), (@[@"1", @"2", @"3", @"5"]));
	}];
}

- (void)testPagingOrderedByKey
{
	[self eachPort:^(NSUInteger port) {
		NSString *error = nil;
		NSArray *first = [self fetch:@"" in:@[@"name"] conditions:@[] columns:@[@"id"] offset:0 limit:200 error:&error];
		NSArray *second = [self fetch:@"" in:@[@"name"] conditions:@[] columns:@[@"id"] offset:200 limit:200 error:&error];
		XCTAssertEqual(first.count, 200u);
		XCTAssertEqual(second.count, 55u);
		NSMutableArray *all = [NSMutableArray array];
		for (NSArray *row in [first arrayByAddingObjectsFromArray:second]) [all addObject:@([row[0] integerValue])];
		XCTAssertEqual([[NSSet setWithArray:all] count], 255u);
		XCTAssertEqualObjects(all, [all sortedArrayUsingSelector:@selector(compare:)]);
	}];
}

- (void)testServerErrorIsReported
{
	[self eachPort:^(NSUInteger port) {
		NSString *error = nil;
		NSArray *rows = [self fetch:nil in:@[] conditions:@[[SPForeignKeyCondition conditionWithColumn:@"id" op:SPForeignKeyOpEquals value:@"abc" secondValue:nil]] columns:@[@"id"] offset:0 limit:10 error:&error];
		XCTAssertNil(rows);
		XCTAssertGreaterThan(error.length, 0u);
		// The connection is still usable afterwards
		XCTAssertEqualObjects(([self ids:@"anna" in:@[@"name"] conditions:@[]]), (@[@"1"]));
	}];
}

- (void)testOnlySelects
{
	[self eachPort:^(NSUInteger port) {
		[self.source loadColumnsWithCompletion:^(NSArray *columns, NSString *errorMessage) {}];
		[self ids:@"o'" in:@[@"name", @"email"] conditions:@[[SPForeignKeyCondition conditionWithColumn:@"created_at" op:SPForeignKeyOpBetween value:@"2020-01-01" secondValue:@"2030-01-01"]]];
		XCTAssertGreaterThan(self.recorder.statements.count, 0u);
		for (NSString *statement in self.recorder.statements) {
			XCTAssertTrue([[statement uppercaseString] hasPrefix:@"SELECT"], @"%@", statement);
		}
	}];
}

@end
