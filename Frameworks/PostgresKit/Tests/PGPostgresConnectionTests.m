//
//  PGPostgresConnectionTests.m
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

#import "PGPostgresConnectionTests.h"
#import <PostgresKit/PostgresKit.h>

@interface PGPostgresConnectionTests ()

- (PGPostgresConnection *)_connectionForHost:(NSString *)host port:(NSUInteger)port;
- (BOOL)_waitForConnectionToSettle:(PGPostgresConnection *)connection timeout:(NSTimeInterval)timeout;

@end

@implementation PGPostgresConnectionTests

- (void)testSecondConnectWhileFirstIsInFlightReturnsNoAndFirstCompletes
{
	PGPostgresConnection *connection = [self _connectionForHost:@"localhost" port:55418];
	
	XCTAssertTrue([connection connect]);
	XCTAssertFalse([connection connect], @"A second connect while the first is being polled must be refused");
	
	XCTAssertTrue([self _waitForConnectionToSettle:connection timeout:10.0]);
	XCTAssertTrue([connection isConnected], @"%@", [connection connectionError]);
	
	[connection disconnect];
	[connection release];
}

- (void)testDisconnectWhileConnectingIsSafe
{
	for (int i = 0; i < 20; i++)
	{
		PGPostgresConnection *connection = [self _connectionForHost:@"localhost" port:55418];
		
		XCTAssertTrue([connection connect]);
		
		[connection disconnect];
		
		XCTAssertFalse([connection isConnected]);
		
		[connection release];
	}
}

- (void)testConnectTimeoutSettlesAgainstUnroutableHost
{
	PGPostgresConnection *connection = [self _connectionForHost:@"10.255.255.1" port:55418];
	
	[connection setTimeout:2];
	
	NSDate *start = [NSDate date];
	
	XCTAssertTrue([connection connect]);
	XCTAssertTrue([self _waitForConnectionToSettle:connection timeout:5.0], @"Connection attempt did not settle within 5 seconds");
	
	XCTAssertFalse([connection isConnected]);
	XCTAssertTrue([[connection connectionError] length] > 0);
	XCTAssertTrue([[NSDate date] timeIntervalSinceDate:start] < 5.0);
	
	[connection disconnect];
	[connection release];
}

#pragma mark -
#pragma mark Private API

- (PGPostgresConnection *)_connectionForHost:(NSString *)host port:(NSUInteger)port
{
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	
	[connection setHost:host];
	[connection setUser:@"pgkit_test"];
	[connection setPort:port];
	[connection setDatabase:@"pgkit_test"];
	[connection setPassword:@"pgkit"];
	
	return connection;
}

- (BOOL)_waitForConnectionToSettle:(PGPostgresConnection *)connection timeout:(NSTimeInterval)timeout
{
	NSDate *start = [NSDate date];
	
	while ([[NSDate date] timeIntervalSinceDate:start] < timeout)
	{
		if ([connection isConnected] || [connection connectionError]) return YES;
		
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	
	return NO;
}

@end
