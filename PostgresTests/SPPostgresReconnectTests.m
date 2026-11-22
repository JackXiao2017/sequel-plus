//
//  SPPostgresReconnectTests.m
//  Sequel Plus
//
//  PostgresKit's keep-alive parameters, its ping with a deadline and its in-place reconnect, against the PostgreSQL 18
//  test server (Scripts/pg-test-servers.sh up). A silent network is made with SPTestTCPRelay's -freeze.
//

#import <XCTest/XCTest.h>
#import <stdatomic.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestTCPRelay.h"

static const NSUInteger SPReconnectTestPort = 55418;

@interface SPPostgresReconnectTests : XCTestCase
@end

@implementation SPPostgresReconnectTests

/// A connection to the test server on port (the server's, or a relay's), keep-alive interval as given (0: default).
- (PGPostgresConnection *)connectToPort:(NSUInteger)port keepAliveInterval:(NSUInteger)interval
{
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = port;
	connection.user = @"pgkit_test";
	connection.password = @"pgkit";
	connection.database = @"pgkit_test";
	connection.timeout = 5;
	if (interval) connection.keepAliveInterval = interval;
	[connection connect];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while (!connection.isConnected && !connection.connectionError && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	XCTAssertTrue(connection.isConnected, @"%@", connection.connectionError);
	[self addTeardownBlock:^{ [connection disconnect]; }];
	return connection;
}

/// Ends connection's server session from another connection (the server closes it: the client sees an EOF).
- (void)terminateBackendOf:(PGPostgresConnection *)connection
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPReconnectTestPort];
	NSString *sql = [NSString stringWithFormat:@"SELECT pg_terminate_backend(%lu)", (unsigned long)[connection serverProcessId]];
	XCTAssertNotNil([admin execute:sql]);
	[NSThread sleepForTimeInterval:0.2];
}

- (id)valueOf:(NSString *)sql on:(PGPostgresConnection *)connection
{
	return [[[connection execute:sql] rowAsArray] firstObject];
}

- (void)testKeepAliveParametersReachLibpq
{
	PGPostgresConnection *connection = [self connectToPort:SPReconnectTestPort keepAliveInterval:45];
	XCTAssertEqualObjects([connection libpqOption:@"keepalives"], @"1");
	XCTAssertEqualObjects([connection libpqOption:@"keepalives_idle"], @"45");
	XCTAssertEqualObjects([connection libpqOption:@"keepalives_interval"], @"45");
	XCTAssertEqualObjects([connection libpqOption:@"keepalives_count"], @"3");
}

- (void)testPingAnswersOnAHealthyConnection
{
	PGPostgresConnection *connection = [self connectToPort:SPReconnectTestPort keepAliveInterval:0];
	XCTAssertTrue([connection pingWithTimeout:5]);
	XCTAssertEqualObjects([self valueOf:@"SELECT 1" on:connection], @1);
	XCTAssertTrue([connection pingWithTimeout:5]);
}

- (void)testPingFailsFastWhenTheBackendIsGone
{
	PGPostgresConnection *connection = [self connectToPort:SPReconnectTestPort keepAliveInterval:0];
	[self terminateBackendOf:connection];
	NSDate *start = [NSDate date];
	XCTAssertFalse([connection pingWithTimeout:5]);
	XCTAssertLessThan(-[start timeIntervalSinceNow], 2.0);
	XCTAssertFalse([connection isConnected]);
	XCTAssertGreaterThan([connection.connectionError length], 0u, @"why the server closed it");
}

- (void)testPingGivesUpAtTheDeadlineWhenTheNetworkIsSilent
{
	SPTestTCPRelay *relay = [[SPTestTCPRelay alloc] initForwardingToPort:SPReconnectTestPort];
	XCTAssertNotNil(relay);
	PGPostgresConnection *connection = [self connectToPort:relay.localPort keepAliveInterval:0];
	[self addTeardownBlock:^{ [relay stop]; }]; // runs before the disconnect (teardown blocks run last-added first)
	XCTAssertTrue([connection pingWithTimeout:5]);

	[relay freeze];
	NSDate *start = [NSDate date];
	XCTAssertFalse([connection pingWithTimeout:1]);
	NSTimeInterval elapsed = -[start timeIntervalSinceNow];
	XCTAssertGreaterThan(elapsed, 0.9);
	XCTAssertLessThan(elapsed, 3.0);
	// The dead session is closed at once, with the reason kept: closing the connection later sends no cancel
	// request into the silent network (which would block)
	XCTAssertFalse([connection isConnected]);
	XCTAssertGreaterThan([connection.connectionError length], 0u);
	start = [NSDate date];
	[connection disconnect];
	XCTAssertLessThan(-[start timeIntervalSinceNow], 1.0);
}

- (void)testReestablishGivesANewSessionWithTheSessionSettings
{
	PGPostgresConnection *connection = [self connectToPort:SPReconnectTestPort keepAliveInterval:0];
	XCTAssertNotNil([connection execute:@"SET datestyle TO 'SQL'"]);
	NSUInteger oldProcess = [connection serverProcessId];
	[self terminateBackendOf:connection];
	XCTAssertFalse([connection pingWithTimeout:5]);

	XCTAssertTrue([connection reestablishConnection], @"%@", connection.connectionError);
	XCTAssertTrue([connection isConnected]);
	XCTAssertNotEqual([connection serverProcessId], oldProcess);
	XCTAssertTrue([[self valueOf:@"SHOW datestyle" on:connection] hasPrefix:@"ISO"]);
	XCTAssertEqualObjects([self valueOf:@"SELECT 1" on:connection], @1);
	XCTAssertTrue([connection pingWithTimeout:5]);
}

- (void)testReestablishAfterASilentNetworkThroughANewRelay
{
	SPTestTCPRelay *relay = [[SPTestTCPRelay alloc] initForwardingToPort:SPReconnectTestPort];
	PGPostgresConnection *connection = [self connectToPort:relay.localPort keepAliveInterval:0];
	[self addTeardownBlock:^{ [relay stop]; }]; // before the disconnect
	[relay freeze];
	XCTAssertFalse([connection pingWithTimeout:1]);

	// As an SSH tunnel reopened on a new local port
	SPTestTCPRelay *second = [[SPTestTCPRelay alloc] initForwardingToPort:SPReconnectTestPort];
	connection.port = second.localPort;
	XCTAssertTrue([connection reestablishConnection], @"%@", connection.connectionError);
	[self addTeardownBlock:^{ [second stop]; }];
	XCTAssertEqualObjects([self valueOf:@"SELECT 1" on:connection], @1);
}

- (void)testReestablishFailsWithAReasonWhenTheServerIsUnreachable
{
	SPTestTCPRelay *relay = [[SPTestTCPRelay alloc] initForwardingToPort:SPReconnectTestPort];
	PGPostgresConnection *connection = [self connectToPort:relay.localPort keepAliveInterval:0];
	[relay stop];
	XCTAssertFalse([connection pingWithTimeout:2]);

	XCTAssertFalse([connection reestablishConnection]);
	XCTAssertGreaterThan([connection.connectionError length], 0u);
	XCTAssertFalse([connection isConnected]);
}

- (void)testLastKnownTransactionStatusSurvivesADrop
{
	PGPostgresConnection *connection = [self connectToPort:SPReconnectTestPort keepAliveInterval:0];
	XCTAssertEqual(connection.lastKnownTransactionStatus, PGPostgresTransactionIdle);
	XCTAssertNotNil([connection execute:@"BEGIN"]);
	XCTAssertEqual(connection.lastKnownTransactionStatus, PGPostgresTransactionInTransaction);
	XCTAssertNotNil([connection execute:@"COMMIT"]);
	XCTAssertEqual(connection.lastKnownTransactionStatus, PGPostgresTransactionIdle);

	// BEGIN, then the session is dropped under the next statement: what was known before it stays
	XCTAssertNotNil([connection execute:@"BEGIN"]);
	[self terminateBackendOf:connection];
	XCTAssertNil([connection execute:@"SELECT 1"]);
	XCTAssertEqual(connection.lastKnownTransactionStatus, PGPostgresTransactionInTransaction);

	XCTAssertTrue([connection reestablishConnection]);
	XCTAssertEqual(connection.lastKnownTransactionStatus, PGPostgresTransactionIdle);
}

/// The worker closes a dead session (a failed ping, a reconnect) while the main thread asks whether the connection
/// is connected, as the document's completions do: never a read of a freed session.
- (void)testStateReadsRaceNoSessionBeingFreed
{
	PGPostgresConnection *connection = [self connectToPort:SPReconnectTestPort keepAliveInterval:0];
	__block atomic_bool stop = false;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		while (!atomic_load(&stop)) {
			(void)[connection isConnected];
			(void)[connection libpqErrorMessage];
			(void)[connection transactionStatus];
		}
		dispatch_semaphore_signal(done);
	});
	for (NSUInteger i = 0; i < 15; i++) {
		[self terminateBackendOf:connection];
		XCTAssertFalse([connection pingWithTimeout:2]);
		XCTAssertTrue([connection reestablishConnection], @"%@", connection.connectionError);
	}
	atomic_store(&stop, true);
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

@end
