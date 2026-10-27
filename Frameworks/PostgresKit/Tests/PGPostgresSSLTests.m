//
//  PGPostgresSSLTests.m
//  PostgresKit
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not 
//  use this file except in compliance with the License. You may obtain a copy of 
//  the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software 
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
//  License for the specific language governing permissions and limitations under
//  the License.

#import "PGPostgresSSLTests.h"
#import <PostgresKit/PostgresKit.h>

static const NSUInteger PGSSLTestSSLServerPort = 55418;
static const NSUInteger PGSSLTestPlainServerPort = 55412;

static const NSTimeInterval PGSSLTestTimeout = 10.0;

@interface PGPostgresSSLTests ()

- (PGPostgresConnection *)_connectionForPort:(NSUInteger)port sslMode:(NSString *)sslMode;
- (BOOL)_waitForConnectionToSettle:(PGPostgresConnection *)connection;

@end

@implementation PGPostgresSSLTests

#pragma mark -
#pragma mark Tests

- (void)testRequireSSLConnectsToSSLServer
{
	PGPostgresConnection *connection = [self _connectionForPort:PGSSLTestSSLServerPort sslMode:@"require"];
	
	XCTAssertTrue([connection connect]);
	XCTAssertTrue([self _waitForConnectionToSettle:connection], @"Timed out waiting for connection: %@", [connection connectionError]);
	XCTAssertTrue([connection isConnected], @"%@", [connection connectionError]);
	
	PGPostgresResult *result = [connection execute:@"SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"];
	
	XCTAssertNotNil(result);
	XCTAssertEqualObjects([[result row] objectForKey:@"ssl"], [NSNumber numberWithBool:YES]);
	
	[connection disconnect];
	[connection release];
}

- (void)testRequireSSLFailsAgainstNonSSLServer
{
	PGPostgresConnection *connection = [self _connectionForPort:PGSSLTestPlainServerPort sslMode:@"require"];
	
	// Connection establishment is asynchronous, so the request itself succeeds and the failure 
	// is reported through -isConnected and -connectionError once libpq has given up.
	XCTAssertTrue([connection connect]);
	XCTAssertTrue([self _waitForConnectionToSettle:connection], @"Timed out waiting for connection failure");
	
	XCTAssertFalse([connection isConnected]);
	XCTAssertNotNil([connection connectionError]);
	XCTAssertTrue([[connection connectionError] rangeOfString:@"SSL"].location != NSNotFound, @"Unexpected error: %@", [connection connectionError]);
	
	[connection release];
}

- (void)testPreferSSLConnectsToNonSSLServer
{
	PGPostgresConnection *connection = [self _connectionForPort:PGSSLTestPlainServerPort sslMode:@"prefer"];
	
	XCTAssertTrue([connection connect]);
	XCTAssertTrue([self _waitForConnectionToSettle:connection], @"Timed out waiting for connection: %@", [connection connectionError]);
	XCTAssertTrue([connection isConnected], @"%@", [connection connectionError]);
	
	[connection disconnect];
	[connection release];
}

#pragma mark -
#pragma mark Private API

/**
 * Creates (but doesn't connect) a connection to the local test server on the given port.
 */
- (PGPostgresConnection *)_connectionForPort:(NSUInteger)port sslMode:(NSString *)sslMode
{
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	
	[connection setHost:@"localhost"];
	[connection setUser:@"pgkit_test"];
	[connection setPort:port];
	[connection setDatabase:@"pgkit_test"];
	[connection setPassword:@"pgkit"];
	[connection setSslMode:sslMode];
	
	return connection;
}

/**
 * Spins until the connection has either been established or has failed.
 *
 * @return NO if neither happened within the timeout.
 */
- (BOOL)_waitForConnectionToSettle:(PGPostgresConnection *)connection
{
	NSDate *start = [NSDate date];
	
	while ([[NSDate date] timeIntervalSinceDate:start] < PGSSLTestTimeout)
	{
		if ([connection isConnected] || [connection connectionError]) return YES;
		
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	
	return NO;
}

@end
