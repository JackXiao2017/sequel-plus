#import "SPPostgresTestServers.h"
#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>

@implementation SPPostgresTestServers

+ (NSArray<NSNumber *> *)ports
{
	return @[@55412, @55418];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port
{
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = port;
	connection.user = @"pgkit_test";
	connection.password = @"pgkit";
	connection.database = @"pgkit_test";

	// -connect is asynchronous: wait for success or failure, up to 10 seconds.
	[connection connect];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
	while (!connection.isConnected && !connection.connectionError && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}

	if (!connection.isConnected) {
		XCTFail(@"Could not connect to test server on port %lu: %@", (unsigned long)port,
				connection.connectionError ?: @"timed out after 10 s");
		return nil;
	}
	return connection;
}

@end
