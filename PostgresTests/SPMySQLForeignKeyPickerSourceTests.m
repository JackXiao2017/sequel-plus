#import <XCTest/XCTest.h>
#import "../Source/SPMySQLForeignKeyPickerSource.h"

// SPMySQL's headers aren't visible to the test bundle: what the tests use, declared
@interface NSObject (SPMySQLForeignKeyPickerSourceTests)
- (BOOL)connect;
- (BOOL)isConnected;
- (void)disconnect;
- (id)queryString:(NSString *)query;
- (BOOL)queryErrored;
- (NSString *)lastErrorMessage;
- (void)setDelegate:(id)delegate;
@end

static NSString * const SPFKPickerMySQLDatabase = @"sp_fkpicker_test";

/// Records the statements the connection sends (SPMySQLConnectionDelegate).
@interface SPFKPickerMySQLRecorder : NSObject
@property (strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPFKPickerMySQLRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)willQueryString:(NSString *)query connection:(id)connection { @synchronized (self) { [self.statements addObject:query]; } }
@end

/**
 * The foreign key picker's MySQL source on the throwaway docker container sp-mysql8 (127.0.0.1:55438, root / sptest),
 * skipped when it isn't running. Database sp_fkpicker_test, table `customer list`, created and dropped here.
 */
@interface SPMySQLForeignKeyPickerSourceTests : XCTestCase
@property (strong) id connection;
@property (strong) SPFKPickerMySQLRecorder *recorder;
@property (strong) SPMySQLForeignKeyPickerSource *source;
@end

@implementation SPMySQLForeignKeyPickerSourceTests

- (void)run:(NSString *)sql
{
	[self.connection queryString:sql];
	XCTAssertFalse([self.connection queryErrored], @"%@: %@", sql, [self.connection lastErrorMessage]);
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	id connection = [[NSClassFromString(@"SPMySQLConnection") alloc] init];
	[connection setValue:@"127.0.0.1" forKey:@"host"];
	[connection setValue:@55438 forKey:@"port"];
	[connection setValue:@"root" forKey:@"username"];
	[connection setValue:@"sptest" forKey:@"password"];
	[connection setValue:@5 forKey:@"timeout"];
	if (![connection connect] || ![connection isConnected]) return;
	self.connection = connection;
	[self run:[NSString stringWithFormat:@"DROP DATABASE IF EXISTS %@", SPFKPickerMySQLDatabase]];
	[self run:[NSString stringWithFormat:@"CREATE DATABASE %@ CHARACTER SET utf8mb4", SPFKPickerMySQLDatabase]];
	[self run:@"CREATE TABLE sp_fkpicker_test.`customer list` (id INT PRIMARY KEY, name VARCHAR(50), email VARCHAR(50), city VARCHAR(50), created_at DATE)"];
	[self run:@"INSERT INTO sp_fkpicker_test.`customer list` VALUES "
			   "(1, 'Anna Smith', 'anna@x', 'Leeds', '2025-03-02'), (2, 'Joe Smithers', 'joe@x', 'Austin', '2026-07-19'), "
			   "(3, 'Mary Lee', 'mary.smi@x', 'Leeds', '2024-01-01'), (4, '100% Pure_Co', 'p@x', NULL, NULL), "
			   "(5, 'O''Neil', 'o@x', 'Cork', '2025-06-01')"];
	[self run:@"INSERT INTO sp_fkpicker_test.`customer list` WITH RECURSIVE n (i) AS (SELECT 1001 UNION ALL SELECT i + 1 FROM n WHERE i < 1250) "
			   "SELECT i, CONCAT('bulk ', i), CONCAT('bulk', i, '@x'), NULL, NULL FROM n"];
	self.recorder = [[SPFKPickerMySQLRecorder alloc] init];
	[connection setDelegate:self.recorder];
	self.source = [[SPMySQLForeignKeyPickerSource alloc] initWithConnection:connection database:SPFKPickerMySQLDatabase table:@"customer list" keyColumn:@"id"];
}

- (void)tearDown
{
	self.source = nil;
	if (self.connection) {
		[self.connection setDelegate:nil];
		[self.connection queryString:@"DROP TABLE IF EXISTS sp_fkpicker_test.`customer list`"];
		[self.connection queryString:[NSString stringWithFormat:@"DROP DATABASE IF EXISTS %@", SPFKPickerMySQLDatabase]];
		[self.connection disconnect];
	}
	self.connection = nil;
	[super tearDown];
}

- (void)skipWithoutServer
{
	if (!self.connection) { XCTSkip(@"no MySQL test server on 127.0.0.1:55438 (docker sp-mysql8)"); }
}

- (void)spinUntil:(BOOL *)done
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while (!*done && [deadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	XCTAssertTrue(*done);
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
	[self spinUntil:&done];
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
	[self skipWithoutServer];
	__block NSArray<SPForeignKeyPickerColumn *> *columns = nil;
	__block BOOL done = NO;
	[self.source loadColumnsWithCompletion:^(NSArray *theColumns, NSString *errorMessage) {
		XCTAssertTrue([NSThread isMainThread]);
		XCTAssertNil(errorMessage);
		columns = theColumns;
		done = YES;
	}];
	[self spinUntil:&done];
	XCTAssertEqualObjects([columns valueForKey:@"name"], (@[@"id", @"name", @"email", @"city", @"created_at"]));
	XCTAssertEqual(columns[0].kind, SPForeignKeyColumnNumber);
	XCTAssertEqual(columns[1].kind, SPForeignKeyColumnText);
	XCTAssertEqual(columns[4].kind, SPForeignKeyColumnDateTime);
	XCTAssertEqualObjects(self.source.keyColumn, @"id");
}

- (void)testSearchMatchesShownColumnsCaseInsensitive
{
	[self skipWithoutServer];
	XCTAssertEqualObjects(([self ids:@"smi" in:@[@"name", @"email"] conditions:@[]]), (@[@"1", @"2", @"3"]));
	XCTAssertEqualObjects(([self ids:@"SMI" in:@[@"name"] conditions:@[]]), (@[@"1", @"2"]));
	NSString *error = nil;
	NSArray *rows = [self fetch:@"anna" in:@[@"name"] conditions:@[] columns:@[@"id", @"name", @"created_at"] offset:0 limit:10 error:&error];
	XCTAssertEqualObjects(rows, (@[@[@"1", @"Anna Smith", @"2025-03-02"]]));
	rows = [self fetch:@"Pure" in:@[@"name"] conditions:@[] columns:@[@"id", @"city"] offset:0 limit:10 error:&error];
	XCTAssertEqualObjects(rows, (@[@[@"4", [NSNull null]]]));
}

- (void)testSearchEscapesWildcardsAndQuotes
{
	[self skipWithoutServer];
	XCTAssertEqualObjects(([self ids:@"%" in:@[@"name", @"email"] conditions:@[]]), (@[@"4"]));
	XCTAssertEqualObjects(([self ids:@"_" in:@[@"name", @"email"] conditions:@[]]), (@[@"4"]));
	XCTAssertEqualObjects(([self ids:@"'" in:@[@"name", @"email"] conditions:@[]]), (@[@"5"]));
	XCTAssertEqualObjects(([self ids:@"\\" in:@[@"name", @"email"] conditions:@[]]), (@[]));
}

- (void)testConditionsAreAnded
{
	[self skipWithoutServer];
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
	NSArray *quoted = @[[SPForeignKeyCondition conditionWithColumn:@"name" op:SPForeignKeyOpEquals value:@"O'Neil" secondValue:nil]];
	XCTAssertEqualObjects(([self ids:nil in:@[] conditions:quoted]), (@[@"5"]));
}

- (void)testPagingOrderedByKey
{
	[self skipWithoutServer];
	NSString *error = nil;
	NSArray *first = [self fetch:@"" in:@[@"name"] conditions:@[] columns:@[@"id"] offset:0 limit:200 error:&error];
	NSArray *second = [self fetch:@"" in:@[@"name"] conditions:@[] columns:@[@"id"] offset:200 limit:200 error:&error];
	XCTAssertEqual(first.count, 200u);
	XCTAssertEqual(second.count, 55u);
	NSMutableArray *all = [NSMutableArray array];
	for (NSArray *row in [first arrayByAddingObjectsFromArray:second]) [all addObject:@([row[0] integerValue])];
	XCTAssertEqual([[NSSet setWithArray:all] count], 255u);
	XCTAssertEqualObjects(all, [all sortedArrayUsingSelector:@selector(compare:)]);
}

- (void)testServerErrorIsReported
{
	[self skipWithoutServer];
	// MySQL converts id = 'abc' silently, so the error here is a column the table doesn't have
	NSString *error = nil;
	NSArray *rows = [self fetch:nil in:@[] conditions:@[[SPForeignKeyCondition conditionWithColumn:@"no_such_column" op:SPForeignKeyOpEquals value:@"1" secondValue:nil]] columns:@[@"id"] offset:0 limit:10 error:&error];
	XCTAssertNil(rows);
	XCTAssertGreaterThan(error.length, 0u);
	XCTAssertEqualObjects(([self ids:@"anna" in:@[@"name"] conditions:@[]]), (@[@"1"]));
}

- (void)testOnlySelects
{
	[self skipWithoutServer];
	__block BOOL done = NO;
	[self.source loadColumnsWithCompletion:^(NSArray *columns, NSString *errorMessage) { done = YES; }];
	[self spinUntil:&done];
	[self ids:@"o'" in:@[@"name", @"email"] conditions:@[[SPForeignKeyCondition conditionWithColumn:@"created_at" op:SPForeignKeyOpBetween value:@"2020-01-01" secondValue:@"2030-01-01"]]];
	XCTAssertGreaterThan(self.recorder.statements.count, 0u);
	for (NSString *statement in self.recorder.statements) {
		NSString *upper = [statement uppercaseString];
		XCTAssertTrue([upper hasPrefix:@"SELECT"] || [upper hasPrefix:@"SHOW "], @"%@", statement);
	}
}

@end
