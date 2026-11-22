#import <XCTest/XCTest.h>
#import "../Source/SPConnectionSummary.h"

// SPMySQL's headers aren't visible to the test bundle: what the tests use, declared
@interface NSObject (SPConnectionSummaryTests)
- (BOOL)connect;
- (BOOL)isConnected;
- (void)disconnect;
- (id)queryString:(NSString *)query;
- (BOOL)queryErrored;
- (NSString *)lastErrorMessage;
@end

/**
 * The connection summary ("N of M connections") shown by both databases' Server Processes lists. The MySQL reader runs
 * on the throwaway docker container sp-mysql8 (127.0.0.1:55438, root / sptest), skipped when it isn't running.
 */
@interface SPConnectionSummaryTests : XCTestCase
@end

@implementation SPConnectionSummaryTests

- (id)mysqlConnection
{
	id connection = [[NSClassFromString(@"SPMySQLConnection") alloc] init];
	[connection setValue:@"127.0.0.1" forKey:@"host"];
	[connection setValue:@55438 forKey:@"port"];
	[connection setValue:@"root" forKey:@"username"];
	[connection setValue:@"sptest" forKey:@"password"];
	[connection setValue:@5 forKey:@"timeout"];
	if (![connection connect] || ![connection isConnected]) return nil;
	return connection;
}

- (void)testText
{
	XCTAssertEqualObjects([[SPConnectionSummary summaryWithCurrent:12 max:151 reserved:0] text], @"12 of 151 connections");
	XCTAssertEqualObjects([[SPConnectionSummary summaryWithCurrent:5 max:100 reserved:3] text], @"5 of 100 connections (3 reserved for superusers)");
	XCTAssertEqualObjects([[SPConnectionSummary summaryWithCurrent:1 max:1 reserved:0] text], @"1 of 1 connection");
}

- (void)testFull
{
	XCTAssertFalse([[SPConnectionSummary summaryWithCurrent:96 max:100 reserved:3] isFull]);
	XCTAssertTrue([[SPConnectionSummary summaryWithCurrent:97 max:100 reserved:3] isFull], @"only superuser slots left");
	XCTAssertTrue([[SPConnectionSummary summaryWithCurrent:151 max:151 reserved:0] isFull]);
	XCTAssertFalse([[SPConnectionSummary summaryWithCurrent:150 max:151 reserved:0] isFull]);
}

- (void)testMySQLSummaryCountsOpenConnections
{
	id connection = [self mysqlConnection];
	if (!connection) {
		XCTSkip(@"sp-mysql8 isn't running on 127.0.0.1:55438");
	}
	id result = [connection queryString:@"SELECT @@GLOBAL.max_connections"];
	XCTAssertFalse([connection queryErrored], @"%@", [connection lastErrorMessage]);
	NSUInteger expectedMax = (NSUInteger)[[[result performSelector:@selector(getRowAsArray)] firstObject] integerValue];

	SPConnectionSummary *before = [SPConnectionSummary summaryForMySQLConnection:connection];
	XCTAssertNotNil(before);
	XCTAssertEqual(before.max, expectedMax);
	XCTAssertEqual(before.reserved, 0u);
	XCTAssertGreaterThanOrEqual(before.current, 1u, @"this connection");

	id other = [self mysqlConnection];
	XCTAssertNotNil(other);
	SPConnectionSummary *after = [SPConnectionSummary summaryForMySQLConnection:connection];
	XCTAssertGreaterThanOrEqual(after.current, before.current + 1, @"the other connection is counted");
	[other disconnect];
	[connection disconnect];
}

@end
