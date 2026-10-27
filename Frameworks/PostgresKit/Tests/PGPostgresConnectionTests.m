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
- (NSUInteger)_testPort;
- (void)_assertSessionSettingsOnConnection:(PGPostgresConnection *)connection;

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
#pragma mark Session settings

/**
 * The type handlers need datestyle=ISO, intervalstyle=postgres and extra_float_digits=1. They must be
 * applied with SET after connecting (source "session"), not through the startup "options" parameter
 * (source "client"), which connection poolers such as PgBouncer reject. A temporary role whose default
 * datestyle is non-ISO proves the settings override role defaults.
 */
- (void)testSessionSettingsAreAppliedWithSetAfterConnectNotStartupOptions
{
	PGPostgresConnection *admin = [self _connectionForHost:@"localhost" port:[self _testPort]];
	
	XCTAssertTrue([admin connect]);
	XCTAssertTrue([self _waitForConnectionToSettle:admin timeout:10.0]);
	XCTAssertTrue([admin isConnected], @"%@", [admin connectionError]);
	
	[admin execute:@"DROP ROLE IF EXISTS \"pgkit_test_datestyle\""];
	XCTAssertNotNil([admin execute:@"CREATE ROLE \"pgkit_test_datestyle\" LOGIN PASSWORD 'pgkit'"], @"%@", [admin lastError]);
	[admin execute:@"ALTER ROLE \"pgkit_test_datestyle\" SET datestyle = 'SQL, DMY'"];
	[admin execute:@"ALTER ROLE \"pgkit_test_datestyle\" SET intervalstyle = 'sql_standard'"];
	[admin execute:@"ALTER ROLE \"pgkit_test_datestyle\" SET extra_float_digits = 0"];
	
	PGPostgresConnection *connection = [self _connectionForHost:@"localhost" port:[self _testPort]];
	
	[connection setUser:@"pgkit_test_datestyle"];
	
	XCTAssertTrue([connection connect]);
	XCTAssertTrue([self _waitForConnectionToSettle:connection timeout:10.0]);
	XCTAssertTrue([connection isConnected], @"%@", [connection connectionError]);
	
	[self _assertSessionSettingsOnConnection:connection];
	
	// The settings must be re-applied after a reset, which starts a new backend
	NSUInteger pid = [connection serverProcessId];
	
	XCTAssertTrue([connection reset]);
	
	NSDate *start = [NSDate date];
	
	while ((![connection isConnected] || [connection serverProcessId] == pid) && [[NSDate date] timeIntervalSinceDate:start] < 10.0)
	{
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	
	XCTAssertTrue([connection isConnected]);
	XCTAssertNotEqual([connection serverProcessId], pid);
	
	[self _assertSessionSettingsOnConnection:connection];
	
	[connection disconnect];
	[connection release];
	
	[admin execute:@"DROP ROLE IF EXISTS \"pgkit_test_datestyle\""];
	[admin disconnect];
	[admin release];
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

- (NSUInteger)_testPort
{
	const char *portString = getenv("PGKIT_TEST_PORT");
	
	return (portString && *portString) ? (NSUInteger)strtoul(portString, NULL, 10) : 55418;
}

- (void)_assertSessionSettingsOnConnection:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:@"SELECT \"name\", \"setting\", \"source\" FROM \"pg_catalog\".\"pg_settings\" WHERE \"name\" IN ('DateStyle', 'IntervalStyle', 'extra_float_digits') ORDER BY \"name\""];
	
	XCTAssertNotNil(result, @"%@", [connection lastError]);
	XCTAssertEqual([result numberOfRows], 3ULL);
	
	NSMutableDictionary *settings = [NSMutableDictionary dictionary];
	NSMutableDictionary *sources = [NSMutableDictionary dictionary];
	
	for (unsigned long long i = 0; i < [result numberOfRows]; i++)
	{
		NSArray *row = [result rowAsArray];
		
		[settings setObject:[row objectAtIndex:1] forKey:[row objectAtIndex:0]];
		[sources setObject:[row objectAtIndex:2] forKey:[row objectAtIndex:0]];
	}
	
	XCTAssertTrue([[settings objectForKey:@"DateStyle"] hasPrefix:@"ISO"], @"%@", settings);
	XCTAssertEqualObjects([settings objectForKey:@"IntervalStyle"], @"postgres");
	XCTAssertEqualObjects([settings objectForKey:@"extra_float_digits"], @"1");
	
	for (NSString *name in sources)
	{
		XCTAssertEqualObjects([sources objectForKey:name], @"session", @"%@ must be applied with SET after connecting, not as a startup option", name);
	}
	
	// Decoding relies on the ISO date style
	PGPostgresResult *dateResult = [connection execute:@"SELECT '2013-05-21'::date, '1 day 02:03:04'::interval"];
	NSArray *dateRow = [dateResult rowAsArray];
	
	XCTAssertTrue([[dateRow objectAtIndex:0] isKindOfClass:[NSDate class]], @"%@", dateRow);
}

@end
