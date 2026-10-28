#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresBackgroundJob.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// SPPostgresBackgroundJob's two-connection run (source, then target), with live connections to pgkit_io_src and
/// pgkit_io_dst on PG 12 and 18 handed out by test providers.
@interface SPPostgresBackgroundJobTests : XCTestCase
/// Every connection a test provider handed out (checked disconnected where a test expects it)
@property (strong) NSMutableArray<PGPostgresConnection *> *handedOut;
@end

@implementation SPPostgresBackgroundJobTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.handedOut = [NSMutableArray array];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.handedOut) [connection disconnect];
	[super tearDown];
}

#pragma mark - Helpers

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = result.numberOfRows ? [result textValueAtRow:0 column:0] : nil;
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Runs body on each test server, after making sure pgkit_io_src and pgkit_io_dst exist (emptied).
- (void)onEachPort:(void (^)(NSNumber *port))body
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		XCTAssertNotNil([SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"]);
		XCTAssertNotNil([SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_dst"]);
		body(port);
	}
}

/// A provider handing out a new connection to the database asked for on port, at once; log (when given) records
/// "<name> asked <database>" when it is called and "<name> answered" right before its completion is called.
- (SPPostgresConnectionProvider)providerOnPort:(NSNumber *)port named:(NSString *)name log:(NSMutableArray<NSString *> *)log
{
	return ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		[log addObject:[NSString stringWithFormat:@"%@ asked %@", name, database]];
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:database];
		[self.handedOut addObject:connection];
		[log addObject:[NSString stringWithFormat:@"%@ answered", name]];
		completion(connection, nil);
	};
}

#pragma mark - Tests

- (void)testBothConnectionsHandedToWork
{
	[self onEachPort:^(NSNumber *port) {
		__block NSString *sourceDatabase = nil, *targetDatabase = nil;
		__block BOOL bothConnected = NO, distinct = NO, workOnMain = YES, finished = NO, result = NO;
		__block PGPostgresConnection *seenSource = nil, *seenTarget = nil;
		__block NSError *failure = nil;
		SPPostgresBackgroundJob *job = [SPPostgresBackgroundJob runOnDatabase:@"pgkit_io_src" provider:[self providerOnPort:port named:@"source" log:nil] targetDatabase:@"pgkit_io_dst" targetProvider:[self providerOnPort:port named:@"target" log:nil] work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error) {
			workOnMain = [NSThread isMainThread];
			seenSource = connection;
			seenTarget = target;
			bothConnected = connection.isConnected && target.isConnected;
			distinct = connection != target;
			sourceDatabase = [self value:@"SELECT current_database()" on:connection];
			targetDatabase = [self value:@"SELECT current_database()" on:target];
			return YES;
		} completion:^(BOOL ok, NSError *error) {
			result = ok;
			failure = error;
			finished = YES;
		}];
		XCTAssertNotNil(job);
		XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:20]);
		XCTAssertFalse(job.waitingForConnection);
		XCTAssertTrue(result);
		XCTAssertNil(failure);
		XCTAssertFalse(workOnMain);
		XCTAssertTrue(bothConnected);
		XCTAssertTrue(distinct);
		XCTAssertEqualObjects(sourceDatabase, @"pgkit_io_src");
		XCTAssertEqualObjects(targetDatabase, @"pgkit_io_dst");
		XCTAssertFalse(seenSource.isConnected, @"source disconnected after the work");
		XCTAssertFalse(seenTarget.isConnected, @"target disconnected after the work");
	}];
}

- (void)testTargetProviderAskedAfterSource
{
	NSNumber *port = [SPPostgresTestServers ports].lastObject;
	NSMutableArray<NSString *> *log = [NSMutableArray array];
	__block BOOL finished = NO, workCalled = NO;
	// The source answers from a later run loop turn: the target must not be asked meanwhile
	SPPostgresConnectionProvider immediateSource = [self providerOnPort:port named:@"source" log:log];
	SPPostgresConnectionProvider source = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		[log addObject:@"source called"];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			immediateSource(database, completion);
		});
	};
	__block BOOL waitingWhileSourcePending = NO, waitingWhileTargetPending = NO;
	__block SPPostgresBackgroundJob *job = nil;
	SPPostgresConnectionProvider immediateTarget = [self providerOnPort:port named:@"target" log:log];
	SPPostgresConnectionProvider target = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		waitingWhileTargetPending = job.waitingForConnection;
		immediateTarget(database, completion);
	};
	job = [SPPostgresBackgroundJob runOnDatabase:@"pgkit_test" provider:source targetDatabase:@"pgkit_test" targetProvider:target work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *targetConnection, NSError **error) {
		workCalled = YES;
		return YES;
	} completion:^(BOOL ok, NSError *error) {
		finished = YES;
	}];
	waitingWhileSourcePending = job.waitingForConnection;
	XCTAssertEqualObjects(log, @[@"source called"], @"the target isn't asked before the source answered");
	XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:20]);
	XCTAssertTrue(workCalled);
	XCTAssertTrue(waitingWhileSourcePending);
	XCTAssertTrue(waitingWhileTargetPending, @"waiting until both arrived");
	XCTAssertFalse(job.waitingForConnection);
	NSArray *expected = @[@"source called", @"source asked pgkit_test", @"source answered", @"target asked pgkit_test", @"target answered"];
	XCTAssertEqualObjects(log, expected);
}

- (void)testTargetFailureSkipsWork
{
	NSNumber *port = [SPPostgresTestServers ports].lastObject;
	__block BOOL finished = NO, workCalled = NO, result = YES, completionOnMain = NO;
	__block NSError *failure = nil;
	__block NSUInteger sourceAsked = 0;
	SPPostgresConnectionProvider immediateSource = [self providerOnPort:port named:@"source" log:nil];
	SPPostgresConnectionProvider source = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		sourceAsked++;
		immediateSource(database, completion);
	};
	NSError *targetError = SPPostgresMakeError(SPPostgresErrorConnectionFailed, @"The target can't be reached.", nil);
	[SPPostgresBackgroundJob runOnDatabase:@"pgkit_test" provider:source targetDatabase:@"pgkit_test" targetProvider:^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		completion(nil, targetError);
	} work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error) {
		workCalled = YES;
		return YES;
	} completion:^(BOOL ok, NSError *error) {
		completionOnMain = [NSThread isMainThread];
		result = ok;
		failure = error;
		finished = YES;
	}];
	XCTAssertFalse(finished, @"completion comes from a later run loop turn");
	XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:20]);
	XCTAssertFalse(workCalled);
	XCTAssertFalse(result);
	XCTAssertTrue(completionOnMain);
	XCTAssertEqualObjects(failure.domain, SPPostgresErrorDomain);
	XCTAssertEqual(failure.code, SPPostgresErrorConnectionFailed);
	XCTAssertEqualObjects(failure.localizedDescription, @"The target can't be reached.");
	XCTAssertEqual(sourceAsked, 1u);
	XCTAssertEqual(self.handedOut.count, 1u);
	PGPostgresConnection *sourceConnection = self.handedOut.firstObject;
	XCTAssertTrue([self spinUntil:^BOOL{ return !sourceConnection.isConnected; } timeout:10], @"the source connection is disconnected");

	// A source failure: the target is never asked
	finished = NO;
	__block BOOL targetAsked = NO;
	[SPPostgresBackgroundJob runOnDatabase:@"pgkit_test" provider:^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		completion(nil, [NSError errorWithDomain:@"test" code:9 userInfo:nil]);
	} targetDatabase:@"pgkit_test" targetProvider:^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		targetAsked = YES;
		completion(nil, nil);
	} work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error) {
		workCalled = YES;
		return YES;
	} completion:^(BOOL ok, NSError *error) {
		result = ok;
		failure = error;
		finished = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:5]);
	XCTAssertFalse(targetAsked);
	XCTAssertFalse(workCalled);
	XCTAssertEqual(failure.code, 9);
}

- (void)testCancelWhileWaitingForTarget
{
	NSNumber *port = [SPPostgresTestServers ports].lastObject;
	__block void (^pendingTarget)(PGPostgresConnection *, NSError *) = nil;
	__block BOOL finished = NO, workCalled = NO, result = YES;
	__block NSError *failure = nil;
	SPPostgresBackgroundJob *job = [SPPostgresBackgroundJob runOnDatabase:@"pgkit_test" provider:[self providerOnPort:port named:@"source" log:nil] targetDatabase:@"pgkit_test" targetProvider:^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		pendingTarget = [completion copy];
	} work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error) {
		workCalled = YES;
		return YES;
	} completion:^(BOOL ok, NSError *error) {
		result = ok;
		failure = error;
		finished = YES;
	}];
	XCTAssertEqual(self.handedOut.count, 1u, @"the source arrived");
	XCTAssertNotNil(pendingTarget, @"the target was asked");
	XCTAssertTrue(job.waitingForConnection);
	PGPostgresConnection *sourceConnection = self.handedOut.firstObject;

	[job cancel];
	XCTAssertFalse(finished, @"completion comes from a later run loop turn");
	XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:5]);
	XCTAssertFalse(result);
	XCTAssertEqualObjects(failure.domain, SPPostgresErrorDomain);
	XCTAssertEqual(failure.code, SPPostgresErrorCancelled);
	XCTAssertFalse(job.waitingForConnection);
	XCTAssertTrue([self spinUntil:^BOOL{ return !sourceConnection.isConnected; } timeout:10], @"the source connection is disconnected");

	// The target arrives late: disconnected unused, and the completion isn't called again
	PGPostgresConnection *late = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test"];
	[self.handedOut addObject:late];
	finished = NO;
	pendingTarget(late, nil);
	XCTAssertTrue([self spinUntil:^BOOL{ return !late.isConnected; } timeout:10], @"the late target connection is disconnected");
	[self spinUntil:^BOOL{ return finished; } timeout:1];
	XCTAssertFalse(finished, @"completion is called once");
	XCTAssertFalse(workCalled);
}

/// Another session holds a lock on a pgkit_io_dst table in an open transaction; the work's LOCK TABLE on the target
/// waits on it; -cancel ends that wait, so the completion comes within 5 seconds and the work saw the cancel.
- (void)testCancelInterruptsTargetLockWait
{
	[self onEachPort:^(NSNumber *port) {
		PGPostgresConnection *holder = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_dst"];
		XCTAssertNotNil(holder);
		[self addTeardownBlock:^{
			[holder execute:@"ROLLBACK"];
			[holder disconnect];
		}];
		[self run:@"CREATE TABLE public.locked (i int)" on:holder];
		[self run:@"BEGIN" on:holder];
		[self run:@"LOCK TABLE public.locked IN ACCESS EXCLUSIVE MODE" on:holder];

		__block BOOL finished = NO, result = YES, lockSucceeded = YES, workOnTarget = NO;
		__block NSString *lockState = nil;
		__block NSError *failure = nil;
		SPPostgresBackgroundJob *job = [SPPostgresBackgroundJob runOnDatabase:@"pgkit_io_src" provider:[self providerOnPort:port named:@"source" log:nil] targetDatabase:@"pgkit_io_dst" targetProvider:[self providerOnPort:port named:@"target" log:nil] work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error) {
			workOnTarget = [[target execute:@"SELECT current_database()"] textValueAtRow:0 column:0] != nil;
			[target execute:@"BEGIN"];
			lockSucceeded = [target execute:@"LOCK TABLE public.locked IN ACCESS EXCLUSIVE MODE"] != nil;
			lockState = target.lastError.errorStateCode;
			[target execute:@"ROLLBACK"];
			*error = SPPostgresMakeError(SPPostgresErrorCancelled, @"cancelled", nil);
			return NO;
		} completion:^(BOOL ok, NSError *error) {
			result = ok;
			failure = error;
			finished = YES;
		}];

		BOOL waiting = [self spinUntil:^BOOL{
			return [[self value:@"SELECT count(*)::text FROM pg_catalog.pg_locks WHERE NOT granted AND relation = 'public.locked'::regclass" on:holder] isEqualToString:@"1"];
		} timeout:20];
		XCTAssertTrue(waiting, @"the work waits on the lock");
		XCTAssertFalse(finished);

		NSDate *cancelled = [NSDate date];
		[job cancel];
		XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:5], @"completion within 5 seconds of the cancel");
		XCTAssertLessThan(-[cancelled timeIntervalSinceNow], 5.0);
		XCTAssertTrue(workOnTarget);
		XCTAssertFalse(lockSucceeded, @"the lock wait was interrupted");
		XCTAssertEqualObjects(lockState, @"57014", @"the work saw the cancel (query_canceled)");
		XCTAssertFalse(result);
		XCTAssertEqual(failure.code, SPPostgresErrorCancelled);
		for (PGPostgresConnection *connection in self.handedOut) XCTAssertFalse(connection.isConnected);

		[self run:@"ROLLBACK" on:holder];
		[holder disconnect];
	}];
}

/// Cancel interrupts a statement on the source connection too (both connections' tokens are signalled).
- (void)testCancelInterruptsSourceStatement
{
	[self onEachPort:^(NSNumber *port) {
		__block BOOL finished = NO, sleepSucceeded = YES;
		__block NSString *sleepState = nil;
		__block BOOL started = NO;
		SPPostgresBackgroundJob *job = [SPPostgresBackgroundJob runOnDatabase:@"pgkit_io_src" provider:[self providerOnPort:port named:@"source" log:nil] targetDatabase:@"pgkit_io_dst" targetProvider:[self providerOnPort:port named:@"target" log:nil] work:^BOOL(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error) {
			started = YES;
			sleepSucceeded = [connection execute:@"SELECT pg_sleep(60)"] != nil;
			sleepState = connection.lastError.errorStateCode;
			return NO;
		} completion:^(BOOL ok, NSError *error) {
			finished = YES;
		}];
		XCTAssertTrue([self spinUntil:^BOOL{ return started; } timeout:20]);
		[self spinUntil:^BOOL{ return NO; } timeout:0.5];
		NSDate *cancelled = [NSDate date];
		[job cancel];
		XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:5], @"completion within 5 seconds of the cancel");
		XCTAssertLessThan(-[cancelled timeIntervalSinceNow], 5.0);
		XCTAssertFalse(sleepSucceeded);
		XCTAssertEqualObjects(sleepState, @"57014");
	}];
}

@end
