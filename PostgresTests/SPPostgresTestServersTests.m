#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"

@interface SPPostgresTestServersTests : XCTestCase
@end

@implementation SPPostgresTestServersTests

- (void)testConnectionsOpenedInTestAreDisconnected
{
	PGPostgresConnection *a = [SPPostgresTestServers connectedConnectionOnPort:55412];
	PGPostgresConnection *b = [SPPostgresTestServers connectedConnectionOnPort:55418];
	XCTAssertTrue([a isConnected]);
	XCTAssertTrue([b isConnected]);
	[SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest];
	XCTAssertFalse([a isConnected]);
	XCTAssertFalse([b isConnected]);
}

- (void)testAlreadyDisconnectedConnectionIsSkipped
{
	PGPostgresConnection *a = [SPPostgresTestServers connectedConnectionOnPort:55412];
	PGPostgresConnection *b = [SPPostgresTestServers connectedConnectionOnPort:55418];
	[a disconnect];
	XCTAssertNoThrow([SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest]);
	XCTAssertFalse([a isConnected]);
	XCTAssertFalse([b isConnected]);
}

@end
