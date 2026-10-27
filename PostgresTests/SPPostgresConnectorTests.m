#import <XCTest/XCTest.h>
#import <Cocoa/Cocoa.h>
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// What one connect attempt produced.
@interface SPPGConnectOutcome : NSObject
@property (nonatomic, strong) PGPostgresConnection *connection;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) NSUInteger calls;
@property (nonatomic, assign) BOOL allOnMainThread;
@property (nonatomic, assign) NSTimeInterval elapsed;
@end

@implementation SPPGConnectOutcome
@end

@interface SPPostgresConnectorTests : XCTestCase
@property (nonatomic, strong) NSMutableArray<NSString *> *tempPaths;
@end

@implementation SPPostgresConnectorTests

- (void)setUp
{
	self.tempPaths = [NSMutableArray array];
}

- (void)tearDown
{
	for (NSString *path in self.tempPaths) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

#pragma mark - Helpers

- (SPPostgresFavorite *)favoriteOnPort:(NSUInteger)port
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = port;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	return favorite;
}

- (NSString *)makeTempDirectory
{
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"SPPGConnectorTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
	[[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
	[self.tempPaths addObject:path];
	return path;
}

/// Spins the main run loop until `condition` holds or `seconds` pass.
- (void)spinFor:(NSTimeInterval)seconds until:(BOOL (^)(void))condition
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
	while ((!condition || !condition()) && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
}

/// Starts `connector`, runs `afterStart` (if any) right after the call returns, waits up to `timeout` for the
/// completion and then a little longer to catch a second (illegal) call.
- (SPPGConnectOutcome *)connect:(SPPostgresConnector *)connector timeout:(NSTimeInterval)timeout afterStart:(void (^)(void))afterStart
{
	SPPGConnectOutcome *outcome = [[SPPGConnectOutcome alloc] init];
	outcome.allOnMainThread = YES;
	NSDate *start = [NSDate date];

	[connector connectWithCompletion:^(PGPostgresConnection *connection, NSError *error) {
		outcome.calls++;
		if (![NSThread isMainThread]) outcome.allOnMainThread = NO;
		if (outcome.calls == 1) {
			outcome.connection = connection;
			outcome.error = error;
			outcome.elapsed = [[NSDate date] timeIntervalSinceDate:start];
		}
	}];

	XCTAssertEqual(outcome.calls, 0u, @"completion must not be called from within -connectWithCompletion:");
	if (afterStart) afterStart();

	[self spinFor:timeout until:^BOOL{ return outcome.calls > 0; }];
	XCTAssertEqual(outcome.calls, 1u, @"completion not called within %.0f s", timeout);

	// A late PostgresKit/tunnel callback must not produce a second completion
	[self spinFor:0.5 until:nil];
	XCTAssertLessThanOrEqual(outcome.calls, 1u, @"completion called more than once");
	XCTAssertTrue(outcome.allOnMainThread);
	return outcome;
}

- (SPPGConnectOutcome *)connect:(SPPostgresConnector *)connector timeout:(NSTimeInterval)timeout
{
	return [self connect:connector timeout:timeout afterStart:nil];
}

#pragma mark - TCP/IP and SSL

- (void)testTCPConnectsOnBothServers
{
	for (NSNumber *port in @[@55412, @55418]) {
		SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:port.unsignedIntegerValue] password:@"pgkit" sshPassword:nil parentWindow:nil];
		SPPGConnectOutcome *outcome = [self connect:connector timeout:15];

		XCTAssertNil(outcome.error, @"port %@", port);
		XCTAssertTrue(outcome.connection.isConnected, @"port %@", port);

		PGPostgresResult *result = [outcome.connection execute:@"SELECT current_setting('application_name')"];
		XCTAssertEqualObjects([[result.rowAsArray firstObject] description], @"Sequel Pro", @"port %@", port);

		[connector disconnect];
		XCTAssertFalse(outcome.connection.isConnected, @"port %@: still connected after -disconnect", port);
	}
}

- (void)testWrongPasswordReportsConnectionFailedWithServerMessage
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55412] password:@"wrong" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:15];

	XCTAssertNil(outcome.connection);
	XCTAssertEqualObjects(outcome.error.domain, SPPostgresErrorDomain);
	XCTAssertEqual(outcome.error.code, SPPostgresErrorConnectionFailed);
	XCTAssertTrue([outcome.error.localizedDescription containsString:@"password authentication failed"], @"%@", outcome.error.localizedDescription);
}

- (void)testUnreachableHostFailsWithinTimeout
{
	SPPostgresFavorite *favorite = [self favoriteOnPort:5432];
	favorite.host = @"10.255.255.1";
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:15];

	XCTAssertNil(outcome.connection);
	XCTAssertEqual(outcome.error.code, SPPostgresErrorConnectionFailed);
	XCTAssertLessThan(outcome.elapsed, 15.0);
}

- (void)testSSLRequiredAgainstNonSSLServerFails
{
	SPPostgresFavorite *favorite = [self favoriteOnPort:55412];
	favorite.useSSL = YES;
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:15];

	XCTAssertNil(outcome.connection);
	XCTAssertEqual(outcome.error.code, SPPostgresErrorConnectionFailed);
}

- (void)testSSLRequiredAgainstSSLServerConnectsOverSSL
{
	SPPostgresFavorite *favorite = [self favoriteOnPort:55418];
	favorite.useSSL = YES;
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:15];

	XCTAssertNil(outcome.error);
	PGPostgresResult *result = [outcome.connection execute:@"SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"];
	XCTAssertEqualObjects([[result.rowAsArray firstObject] description], @"1", @"session is not using SSL");
	[connector disconnect];
}

#pragma mark - Sockets

- (void)testDefaultSocketDirectories
{
	NSArray *expected = @[@"/tmp", @"/var/run/postgresql", @"/opt/homebrew/var/run/postgresql"];
	XCTAssertEqualObjects([SPPostgresConnector defaultSocketDirectories], expected);
}

- (void)testSocketDirectoryFindsFirstMatch
{
	NSString *first = [self makeTempDirectory];
	NSString *second = [self makeTempDirectory];
	[[NSFileManager defaultManager] createFileAtPath:[second stringByAppendingPathComponent:@".s.PGSQL.5432"] contents:[NSData data] attributes:nil];

	NSArray *directories = @[first, second];
	XCTAssertEqualObjects([SPPostgresConnector socketDirectoryForPort:5432 searchDirectories:directories], second);
}

- (void)testSocketDirectoryNilWhenNoneMatch
{
	NSString *first = [self makeTempDirectory];
	NSString *second = [self makeTempDirectory];
	[[NSFileManager defaultManager] createFileAtPath:[second stringByAppendingPathComponent:@".s.PGSQL.5433"] contents:[NSData data] attributes:nil];

	NSArray *directories = @[first, second, @"/nonexistent-sp-dir"];
	XCTAssertNil([SPPostgresConnector socketDirectoryForPort:5432 searchDirectories:directories]);
}

- (void)testSocketTypeWithNoSocketReportsNoSocketError
{
	SPPostgresFavorite *favorite = [self favoriteOnPort:59999];
	favorite.type = SPPostgresSocketConnection;
	favorite.host = nil;
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:5];

	XCTAssertNil(outcome.connection);
	XCTAssertEqualObjects(outcome.error.domain, SPPostgresErrorDomain);
	XCTAssertEqual(outcome.error.code, SPPostgresErrorNoSocket);
}

#pragma mark - Threading, cancel, disconnect

- (void)testCompletionRunsOnMainThread
{
	// Success path and an early-failure path; -connect: asserts the main thread for every call
	SPPostgresConnector *ok = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55412] password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:ok timeout:15];
	XCTAssertTrue(outcome.allOnMainThread);
	XCTAssertNotNil(outcome.connection);
	[ok disconnect];

	SPPostgresFavorite *socketFavorite = [self favoriteOnPort:59999];
	socketFavorite.type = SPPostgresSocketConnection;
	SPPostgresConnector *noSocket = [[SPPostgresConnector alloc] initWithFavorite:socketFavorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	outcome = [self connect:noSocket timeout:5];
	XCTAssertTrue(outcome.allOnMainThread);
}

- (void)testCancelWhileConnectingReportsCancelledOnce
{
	SPPostgresFavorite *favorite = [self favoriteOnPort:5432];
	favorite.host = @"10.255.255.1";
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];

	NSDate *start = [NSDate date];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:5 afterStart:^{
		[self spinFor:0.3 until:nil];
		[connector cancel];
	}];

	XCTAssertEqual(outcome.error.code, SPPostgresErrorCancelled);
	XCTAssertNil(outcome.connection);
	XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 3.0);
}

- (void)testCancelImmediatelyIgnoresLateConnectionCallback
{
	// The attempt against a live server would succeed; cancelling in the same run loop turn must win,
	// and any connectionEstablished: that PostgresKit still delivers must be ignored.
	for (NSUInteger i = 0; i < 5; i++) {
		SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55412] password:@"pgkit" sshPassword:nil parentWindow:nil];
		SPPGConnectOutcome *outcome = [self connect:connector timeout:5 afterStart:^{
			[connector cancel];
		}];
		XCTAssertEqual(outcome.error.code, SPPostgresErrorCancelled);
		XCTAssertNil(outcome.connection);
	}
}

- (void)testDisconnectWhilePendingCompletesWithCancelled
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55418] password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:5 afterStart:^{
		[connector disconnect];
	}];
	XCTAssertEqual(outcome.error.code, SPPostgresErrorCancelled);
}

- (void)testReleasingConnectorWhilePendingCompletesWithCancelledOnce
{
	for (NSString *host in @[@"10.255.255.1", @"127.0.0.1"]) {
		SPPostgresFavorite *favorite = [self favoriteOnPort:[host isEqualToString:@"127.0.0.1"] ? 55412 : 5432];
		favorite.host = host;

		__block NSUInteger calls = 0;
		__block NSError *receivedError = nil;
		__block PGPostgresConnection *receivedConnection = nil;
		__block BOOL onMain = YES;
		__block BOOL calledInsideConnect = NO;
		__weak SPPostgresConnector *weakConnector = nil;

		@autoreleasepool {
			SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
			weakConnector = connector;
			[connector connectWithCompletion:^(PGPostgresConnection *connection, NSError *error) {
				calls++;
				onMain = onMain && [NSThread isMainThread];
				receivedError = error;
				receivedConnection = connection;
			}];
			calledInsideConnect = calls > 0;
			connector = nil;
		}

		XCTAssertNil(weakConnector, @"%@: connector was not released", host);
		XCTAssertFalse(calledInsideConnect, @"%@", host);
		[self spinFor:5 until:^BOOL{ return calls > 0; }];
		[self spinFor:1.0 until:nil]; // catch a late PostgresKit callback / second call
		XCTAssertEqual(calls, 1u, @"%@", host);
		XCTAssertTrue(onMain, @"%@", host);
		XCTAssertNil(receivedConnection, @"%@", host);
		XCTAssertEqualObjects(receivedError.domain, SPPostgresErrorDomain, @"%@", host);
		XCTAssertEqual(receivedError.code, SPPostgresErrorCancelled, @"%@", host);
	}
}

- (void)testDisconnectBeforeConnectCompletesWithCancelled
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55412] password:@"pgkit" sshPassword:nil parentWindow:nil];
	[connector disconnect];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:5];
	XCTAssertNil(outcome.connection);
	XCTAssertEqual(outcome.error.code, SPPostgresErrorCancelled);

	SPPostgresConnector *cancelled = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55412] password:@"pgkit" sshPassword:nil parentWindow:nil];
	[cancelled cancel];
	outcome = [self connect:cancelled timeout:5];
	XCTAssertEqual(outcome.error.code, SPPostgresErrorCancelled);
}

- (void)testSecondConnectCallFails
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55412] password:@"pgkit" sshPassword:nil parentWindow:nil];
	SPPGConnectOutcome *first = [self connect:connector timeout:15];
	XCTAssertNotNil(first.connection);

	SPPGConnectOutcome *second = [self connect:connector timeout:5];
	XCTAssertNil(second.connection);
	XCTAssertEqual(second.error.code, SPPostgresErrorConnectionFailed);
	XCTAssertTrue(first.connection.isConnected, @"a rejected second call must not touch the first connection");
	[connector disconnect];
}

#pragma mark - SSH (sp-sshd container: 127.0.0.1:55422, user sshtest/sshtest, forwards to sp-pg18:5432)

/// Points SPSSHTunnel at a wrapper around /usr/bin/ssh that skips host-key confirmation (the container's
/// host key is new and changes whenever it is recreated) and always uses SSH_ASKPASS. Set in the
/// volatile argument domain so the app's saved preferences are never touched.
- (void)useTestSSHClient
{
	NSString *dir = [self makeTempDirectory];
	NSString *wrapper = [dir stringByAppendingPathComponent:@"ssh"];
	NSString *script = @"#!/bin/sh\n"
		"SSH_ASKPASS_REQUIRE=force; export SSH_ASKPASS_REQUIRE\n"
		"exec /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \"$@\"\n";
	[script writeToFile:wrapper atomically:YES encoding:NSUTF8StringEncoding error:nil];
	[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:wrapper error:nil];

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [defaults volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	domain[@"SSHClientPath"] = wrapper;
	[defaults removeVolatileDomainForName:NSArgumentDomain];
	[defaults setVolatileDomain:domain forName:NSArgumentDomain];
	XCTAssertEqualObjects([defaults stringForKey:@"SSHClientPath"], wrapper);

	[self addTeardownBlock:^{
		[defaults removeVolatileDomainForName:NSArgumentDomain];
		[defaults setVolatileDomain:original forName:NSArgumentDomain];
	}];
}

- (SPPostgresFavorite *)sshFavorite
{
	SPPostgresFavorite *favorite = [self favoriteOnPort:5432];
	favorite.type = SPPostgresSSHConnection;
	favorite.host = @"sp-pg18";
	favorite.sshHost = @"127.0.0.1";
	favorite.sshPort = 55422;
	favorite.sshUser = @"sshtest";
	return favorite;
}

- (NSWindow *)parentWindow
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	window.releasedWhenClosed = NO;
	return window;
}

- (void)testSSHTunnelConnects
{
	[self useTestSSHClient];
	NSWindow *window = [self parentWindow];
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self sshFavorite] password:@"pgkit" sshPassword:@"sshtest" parentWindow:window];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:30];

	XCTAssertNil(outcome.error);
	XCTAssertNotNil(connector.tunnel);
	PGPostgresResult *result = [outcome.connection execute:@"SELECT version()"];
	NSString *version = [[result.rowAsArray firstObject] description];
	XCTAssertTrue([version hasPrefix:@"PostgreSQL 18"], @"%@", version);

	[connector disconnect];
	XCTAssertFalse(outcome.connection.isConnected);
}

/// The parent window (the MySQL connection screen's) is only needed while connecting: a finished
/// connector must not keep it alive.
- (void)testParentWindowIsReleasedWhenTheAttemptFinishes
{
	__weak NSWindow *weakWindow = nil;
	SPPostgresConnector *connector = nil;
	SPPGConnectOutcome *outcome = nil;
	@autoreleasepool {
		NSWindow *window = [self parentWindow];
		weakWindow = window;
		connector = [[SPPostgresConnector alloc] initWithFavorite:[self favoriteOnPort:55418] password:@"pgkit" sshPassword:nil parentWindow:window];
		outcome = [self connect:connector timeout:15];
		XCTAssertNil(outcome.error);
		window = nil;
	}
	XCTAssertNil(weakWindow, @"the connector still retains its parent window after connecting");
	XCTAssertTrue(outcome.connection.isConnected, @"the connector (and its connection) stay alive");
	[connector disconnect];
}

- (void)testParentWindowIsReleasedWhenAnSSHAttemptFinishes
{
	[self useTestSSHClient];
	__weak NSWindow *weakWindow = nil;
	SPPostgresConnector *connector = nil;
	SPPGConnectOutcome *outcome = nil;
	@autoreleasepool {
		NSWindow *window = [self parentWindow];
		weakWindow = window;
		connector = [[SPPostgresConnector alloc] initWithFavorite:[self sshFavorite] password:@"pgkit" sshPassword:@"sshtest" parentWindow:window];
		outcome = [self connect:connector timeout:30];
		XCTAssertNil(outcome.error);
		window = nil;
	}
	XCTAssertNil(weakWindow, @"the connector or its tunnel still retains the parent window after connecting");
	XCTAssertTrue(outcome.connection.isConnected);
	[connector disconnect];
}

- (void)testConnectorExposesThePasswordsItWasGiven
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self sshFavorite] password:@"db pw" sshPassword:@"ssh pw" parentWindow:nil];
	XCTAssertEqualObjects(connector.password, @"db pw");
	XCTAssertEqualObjects(connector.sshPassword, @"ssh pw");
	SPPostgresConnector *without = [[SPPostgresConnector alloc] initWithFavorite:[self sshFavorite] password:nil sshPassword:nil parentWindow:nil];
	XCTAssertNil(without.password);
	XCTAssertNil(without.sshPassword);
}

- (void)testSSHWrongPasswordReportsTunnelFailed
{
	[self useTestSSHClient];
	NSWindow *window = [self parentWindow];
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self sshFavorite] password:@"pgkit" sshPassword:@"wrong" parentWindow:window];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:30];

	XCTAssertNil(outcome.connection);
	XCTAssertEqual(outcome.error.code, SPPostgresErrorSSHTunnelFailed);
	XCTAssertTrue([outcome.error.localizedDescription containsString:@"could not authenticate"], @"%@", outcome.error.localizedDescription);
}

- (void)testSSHWithoutParentWindowReportsTunnelFailed
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:[self sshFavorite] password:@"pgkit" sshPassword:@"sshtest" parentWindow:nil];
	SPPGConnectOutcome *outcome = [self connect:connector timeout:10];
	XCTAssertEqual(outcome.error.code, SPPostgresErrorSSHTunnelFailed);
}

@end
