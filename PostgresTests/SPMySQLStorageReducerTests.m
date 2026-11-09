#import <XCTest/XCTest.h>
#import "../Source/SPMySQLStorageReducer.h"

/// A fake MySQL connection: records every statement, and answers from `replies` (first matching prefix wins). A reply
/// is an array of rows, or an NSString: the statement fails with that message.
@interface SPMySQLStorageReducerFake : NSObject
@property (strong) NSMutableArray<NSString *> *statements;
@property (strong) NSMutableArray<NSArray *> *replies; // @[prefix, reply]
- (SPMySQLStorageReducerQuery)query;
- (void)on:(NSString *)prefix reply:(id)reply;
@end

@implementation SPMySQLStorageReducerFake

- (instancetype)init
{
	if ((self = [super init])) {
		_statements = [NSMutableArray array];
		_replies = [NSMutableArray array];
	}
	return self;
}

- (void)on:(NSString *)prefix reply:(id)reply
{
	[self.replies addObject:@[prefix, reply]];
}

- (SPMySQLStorageReducerQuery)query
{
	__weak SPMySQLStorageReducerFake *fake = self;
	return ^NSArray *(NSString *sql, NSString **message) {
		[fake.statements addObject:sql];
		for (NSArray *pair in fake.replies) {
			if (![sql hasPrefix:pair[0]]) continue;
			if ([pair[1] isKindOfClass:[NSString class]]) {
				if (message) *message = pair[1];
				return nil;
			}
			return pair[1];
		}
		return @[];
	};
}

@end

/// The SELECT the reducer sends for a table's size (its name as a hex literal of its UTF-8 bytes).
static NSString *SPSizeQuery(NSString *hexName)
{
	return [NSString stringWithFormat:@"SELECT CAST(COALESCE(DATA_LENGTH, 0) + COALESCE(INDEX_LENGTH, 0) AS CHAR) AS bytes FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = CONVERT(0x%@ USING utf8mb4)", hexName];
}

static NSArray *SPOptimizeOK(NSString *table)
{
	// InnoDB's answer: a note, then the status
	return @[@{@"Table": table, @"Op": @"optimize", @"Msg_type": @"note", @"Msg_text": @"Table does not support optimize, doing recreate + analyze instead"},
			 @{@"Table": table, @"Op": @"optimize", @"Msg_type": @"status", @"Msg_text": @"OK"}];
}

@interface SPMySQLStorageReducerTests : XCTestCase
@end

@implementation SPMySQLStorageReducerTests

- (SPMySQLStorageReducerFake *)fakeWithExpiry:(NSString *)expiry
{
	SPMySQLStorageReducerFake *fake = [[SPMySQLStorageReducerFake alloc] init];
	if (expiry) [fake on:@"SELECT CAST(@@SESSION.information_schema_stats_expiry" reply:@[@{@"expiry": expiry}]];
	else [fake on:@"SELECT CAST(@@SESSION.information_schema_stats_expiry" reply:@"Unknown system variable 'information_schema_stats_expiry'"];
	return fake;
}

- (void)testOptimizesEachTableReadingFreshSizes
{
	SPMySQLStorageReducerFake *fake = [self fakeWithExpiry:@"86400"];
	// "orders" is 6F7264657273; "a`b" is 616062
	__block NSUInteger ordersSizeReads = 0;
	SPMySQLStorageReducerQuery base = [fake query];
	SPMySQLStorageReducerQuery scripted = ^NSArray *(NSString *sql, NSString **message) {
		if ([sql isEqualToString:SPSizeQuery(@"6F7264657273")]) {
			[fake.statements addObject:sql];
			return @[@{@"bytes": (ordersSizeReads++ == 0) ? @"5242880" : @"327680"}];
		}
		if ([sql isEqualToString:SPSizeQuery(@"616062")]) {
			[fake.statements addObject:sql];
			return @[@{@"bytes": @"16384"}];
		}
		return base(sql, message);
	};
	[fake on:@"OPTIMIZE TABLE `orders`" reply:SPOptimizeOK(@"db.orders")];
	[fake on:@"OPTIMIZE TABLE `a``b`" reply:SPOptimizeOK(@"db.a`b")];

	NSString *error = @"untouched";
	NSArray *results = [SPMySQLStorageReducer reduceStorageOfTables:@[@"orders", @"a`b"] skippingFailures:NO query:scripted isCancelled:nil errorMessage:&error];
	XCTAssertNil(error);
	XCTAssertEqualObjects(results, (@[@{@"table": @"orders", @"before": @5242880, @"after": @327680},
									  @{@"table": @"a`b", @"before": @16384, @"after": @16384}]));
	XCTAssertEqualObjects(fake.statements, (@[@"SELECT CAST(@@SESSION.information_schema_stats_expiry AS CHAR) AS expiry",
											  @"SET SESSION information_schema_stats_expiry = 0",
											  SPSizeQuery(@"6F7264657273"), @"OPTIMIZE TABLE `orders`", SPSizeQuery(@"6F7264657273"),
											  SPSizeQuery(@"616062"), @"OPTIMIZE TABLE `a``b`", SPSizeQuery(@"616062"),
											  @"SET SESSION information_schema_stats_expiry = 86400"]));
}

- (void)testServerWithoutStatsExpiryIsLeftAlone
{
	SPMySQLStorageReducerFake *fake = [self fakeWithExpiry:nil];
	[fake on:@"SELECT CAST(COALESCE" reply:@[@{@"bytes": @"100"}]];
	[fake on:@"OPTIMIZE TABLE" reply:@[@{@"Msg_type": @"status", @"Msg_text": @"OK"}]];
	NSString *error = nil;
	NSArray *results = [SPMySQLStorageReducer reduceStorageOfTables:@[@"t"] skippingFailures:NO query:[fake query] isCancelled:nil errorMessage:&error];
	XCTAssertEqual(results.count, 1u, @"%@", error);
	for (NSString *statement in fake.statements) XCTAssertFalse([statement hasPrefix:@"SET SESSION"], @"%@", statement);
}

- (void)testSelectedTablesStopAtTheFirstFailure
{
	SPMySQLStorageReducerFake *fake = [self fakeWithExpiry:@"0"];
	[fake on:@"SELECT CAST(COALESCE" reply:@[@{@"bytes": @"100"}]];
	[fake on:@"OPTIMIZE TABLE `a`" reply:SPOptimizeOK(@"db.a")];
	[fake on:@"OPTIMIZE TABLE `b`" reply:@[@{@"Msg_type": @"Error", @"Msg_text": @"INSERT command denied to user 'u'@'h' for table 'b'"},
										 @{@"Msg_type": @"status", @"Msg_text": @"Operation failed"}]];
	NSString *error = nil;
	XCTAssertNil(([SPMySQLStorageReducer reduceStorageOfTables:@[@"a", @"b", @"c"] skippingFailures:NO query:[fake query] isCancelled:nil errorMessage:&error]));
	XCTAssertEqualObjects(error, @"b: INSERT command denied to user 'u'@'h' for table 'b'");
	XCTAssertFalse([fake.statements containsObject:@"OPTIMIZE TABLE `c`"], @"nothing after the failure");
	XCTAssertEqualObjects(fake.statements.lastObject, @"SET SESSION information_schema_stats_expiry = 0", @"the session's value back");
}

- (void)testAllTablesSkipFailuresAndGoOn
{
	SPMySQLStorageReducerFake *fake = [self fakeWithExpiry:@"86400"];
	[fake on:@"SELECT CAST(COALESCE" reply:@[@{@"bytes": @"2048"}]];
	[fake on:@"OPTIMIZE TABLE `b`" reply:@[@{@"Msg_type": @"error", @"Msg_text": @"denied"}]];
	[fake on:@"OPTIMIZE TABLE" reply:SPOptimizeOK(@"db.x")];
	NSString *error = nil;
	NSArray *results = [SPMySQLStorageReducer reduceStorageOfTables:@[@"a", @"b", @"c"] skippingFailures:YES query:[fake query] isCancelled:nil errorMessage:&error];
	XCTAssertNil(error);
	XCTAssertEqualObjects(results, (@[@{@"table": @"a", @"before": @2048, @"after": @2048},
									  @{@"table": @"b", @"skipped": @"denied"},
									  @{@"table": @"c", @"before": @2048, @"after": @2048}]));
	XCTAssertEqualObjects(fake.statements.lastObject, @"SET SESSION information_schema_stats_expiry = 86400");
}

- (void)testFailedStatementStopsEvenForAllTables
{
	SPMySQLStorageReducerFake *fake = [self fakeWithExpiry:@"86400"];
	[fake on:@"SELECT CAST(COALESCE" reply:@[@{@"bytes": @"2048"}]];
	[fake on:@"OPTIMIZE TABLE `a`" reply:@"Lost connection to MySQL server during query"];
	NSString *error = nil;
	XCTAssertNil(([SPMySQLStorageReducer reduceStorageOfTables:@[@"a", @"b"] skippingFailures:YES query:[fake query] isCancelled:nil errorMessage:&error]));
	XCTAssertEqualObjects(error, @"a: Lost connection to MySQL server during query");
	XCTAssertFalse([fake.statements containsObject:@"OPTIMIZE TABLE `b`"]);
}

- (void)testCancelStopsBeforeTheNextTable
{
	SPMySQLStorageReducerFake *fake = [self fakeWithExpiry:@"86400"];
	[fake on:@"SELECT CAST(COALESCE" reply:@[@{@"bytes": @"2048"}]];
	[fake on:@"OPTIMIZE TABLE" reply:SPOptimizeOK(@"db.x")];
	__block BOOL cancelled = NO;
	SPMySQLStorageReducerQuery base = [fake query];
	SPMySQLStorageReducerQuery scripted = ^NSArray *(NSString *sql, NSString **message) {
		NSArray *rows = base(sql, message);
		if ([sql isEqualToString:@"OPTIMIZE TABLE `a`"]) cancelled = YES; // Cancel pressed while `a` runs
		return rows;
	};
	NSString *error = @"untouched";
	XCTAssertNil(([SPMySQLStorageReducer reduceStorageOfTables:@[@"a", @"b"] skippingFailures:YES query:scripted isCancelled:^BOOL{ return cancelled; } errorMessage:&error]));
	XCTAssertNil(error, @"a cancel is no error");
	XCTAssertFalse([fake.statements containsObject:@"OPTIMIZE TABLE `b`"]);
	XCTAssertEqualObjects(fake.statements.lastObject, @"SET SESSION information_schema_stats_expiry = 86400");
}

- (void)testResultLines
{
	NSString *(^format)(long long) = ^NSString *(long long bytes) { return [NSString stringWithFormat:@"%lld B", bytes]; };
	XCTAssertEqualObjects(([SPMySQLStorageReducer resultLinesFor:@[@{@"table": @"a", @"before": @100, @"after": @10}] sizeFormatter:format]), (@[@"a: 100 B → 10 B"]));
	NSArray *results = @[@{@"table": @"a", @"before": @100, @"after": @10},
						 @{@"table": @"b", @"skipped": @"denied"},
						 @{@"table": @"c", @"before": @50, @"after": @40}];
	XCTAssertEqualObjects(([SPMySQLStorageReducer resultLinesFor:results sizeFormatter:format]),
						  (@[@"Total: 150 B → 50 B", @"", @"a: 100 B → 10 B", @"c: 50 B → 40 B", @"", @"b: skipped (denied)"]));
	XCTAssertEqualObjects(([SPMySQLStorageReducer resultLinesFor:@[@{@"table": @"b", @"skipped": @"denied"}] sizeFormatter:format]), (@[@"b: skipped (denied)"]));
}

@end
