//
//  PGPostgresIntegrationTestCase.m
//  PostgresKit
//
//  Created by Stuart Connolly (stuconnolly.com) on May 21, 2013.
//  Copyright (c) 2013 Stuart Connolly. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.

#import "PGPostgresIntegrationTestCase.h"

static NSString *PGTestDatabaseHost     = @"localhost";
static NSString *PGTestDatabaseUser     = @"pgkit_test";
static NSString *PGTestDatabaseName     = @"pgkit_test";
static NSString *PGTestDatabasePassword = @"pgkit";

// Port of the test server; override with the PGKIT_TEST_PORT environment variable 
// (xcodebuild: TEST_RUNNER_PGKIT_TEST_PORT). See Scripts/pg-test-servers.sh.
static NSUInteger PGTestDefaultDatabasePort = 55418;

static double PGTestConnectionTimeout = 5.0;

@interface PGPostgresIntegrationTestCase ()

- (void)_establishConnection;

@end

@implementation PGPostgresIntegrationTestCase

@synthesize connection = _connection;

#pragma mark -
#pragma mark Setup & Teardown

- (void)setUp
{		
	// The expected values in the data type tests assume this time zone (see Resources/TestData.sql)
	[NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"Europe/London"]];
	
	_connection = [[PGPostgresConnection alloc] init];
	
	[self _establishConnection];	
}

#pragma mark -
#pragma mark Private API

- (void)_establishConnection
{		
	[_connection setHost:PGTestDatabaseHost];
	[_connection setUser:PGTestDatabaseUser];
	const char *portString = getenv("PGKIT_TEST_PORT");
	
	[_connection setPort:(portString && *portString) ? (NSUInteger)strtoul(portString, NULL, 10) : PGTestDefaultDatabasePort];
	[_connection setDatabase:PGTestDatabaseName];
	[_connection setPassword:PGTestDatabasePassword];
	
	if (![_connection connect]) {
		XCTFail(@"Request to establish connection to local database failed.");
		
		exit(1);
	}	
	
    NSDate *startDate = [NSDate date];
    
	do {
		if ([_connection connectionError]) {
			XCTFail(@"Failed to connect to database: %@", [_connection connectionError]);
			exit(1);
		}

		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        
        if([[NSDate date] timeIntervalSinceDate:startDate] > PGTestConnectionTimeout) {
            XCTFail(@"Failed to connect to database after %f seconds. Host:%@ Database:%@ User:%@ Password:%@",
                    PGTestConnectionTimeout,
                    PGTestDatabaseHost,
                    PGTestDatabaseName,
                    PGTestDatabaseUser,
                    PGTestDatabasePassword);
            exit(1);
        }
	}
	while (![_connection isConnected]);
}

#pragma mark -

- (void)dealloc
{
	if (_connection && [_connection isConnected]) {
		[_connection disconnect];
	}
	
	if (_connection) [_connection release], _connection = nil;
	
	[super dealloc];
}

@end
