#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"

@interface SPPostgresSmokeTests : XCTestCase
@end

@implementation SPPostgresSmokeTests

- (void)testConnectsToEveryTestServer
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		XCTAssertNotNil(connection, @"port %@", port);
		if (!connection) continue;

		PGPostgresResult *result = [connection execute:@"SELECT 1"];
		XCTAssertNotNil(result, @"port %@: %@", port, connection.lastError);
		XCTAssertEqual(result.numberOfRows, 1ull, @"port %@", port);
		XCTAssertEqualObjects([[result.rowAsArray firstObject] description], @"1", @"port %@", port);
		[connection disconnect];
	}
}

@end
