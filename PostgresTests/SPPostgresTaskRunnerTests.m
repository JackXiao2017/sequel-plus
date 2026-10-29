#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import <stdatomic.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

/// Records every change of a key path it observes, and the thread it came on.
@interface SPTaskRunnerTestObserver : NSObject
@property (strong) NSMutableArray *values;
@property BOOL changeOffMain;
@end

@implementation SPTaskRunnerTestObserver

- (instancetype)init
{
	if ((self = [super init])) _values = [NSMutableArray array];
	return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (![NSThread isMainThread]) self.changeOffMain = YES;
	id value = change[NSKeyValueChangeNewKey];
	[self.values addObject:value ?: [NSNull null]];
}

@end

/// SPPostgresTaskRunner, with a live connection to pgkit_test on PG 18.
@interface SPPostgresTaskRunnerTests : XCTestCase
@property (strong) PGPostgresConnection *connection;
@property (strong) SPPostgresTaskRunner *runner;
@end

@implementation SPPostgresTaskRunnerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.connection = [SPPostgresTestServers connectedConnectionOnPort:55418];
	XCTAssertNotNil(self.connection);
	self.runner = [[SPPostgresTaskRunner alloc] initWithConnection:self.connection];
}

- (void)tearDown
{
	__block BOOL idle = NO;
	[self.runner invalidateWithCompletion:^{ idle = YES; }];
	[self spinUntil:^BOOL{ return idle; } timeout:40];
	self.runner = nil;
	[self.connection disconnect];
	self.connection = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	return condition();
}

- (void)spinFor:(NSTimeInterval)interval
{
	[self spinUntil:^BOOL{ return NO; } timeout:interval];
}

#pragma mark - Tests

- (void)testRunsWorkOffMainAndCompletionOnMain
{
	__block BOOL workOffMain = NO, completionOnMain = NO, called = NO, completedSynchronously = NO;
	__block id gotResult = nil;
	__block BOOL gotCancelled = YES;
	__block PGPostgresConnection *gotConnection = nil;
	__block BOOL returned = NO;
	[self.runner runTaskWithDescription:@"Loading..." cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		workOffMain = ![NSThread isMainThread];
		gotConnection = connection;
		return @42;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		completedSynchronously = !returned;
		completionOnMain = [NSThread isMainThread];
		gotResult = result;
		gotCancelled = cancelled;
		called = YES;
	}];
	returned = YES;
	XCTAssertTrue(self.runner.isBusy);
	XCTAssertEqualObjects(self.runner.currentDescription, @"Loading...");
	XCTAssertEqualObjects(self.runner.currentCancelTitle, @"Cancel");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
	XCTAssertTrue(called);
	XCTAssertFalse(completedSynchronously);
	XCTAssertTrue(workOffMain);
	XCTAssertTrue(completionOnMain);
	XCTAssertEqual(gotConnection, self.connection);
	XCTAssertEqualObjects(gotResult, @42);
	XCTAssertFalse(gotCancelled);
	XCTAssertFalse(self.runner.isBusy);
	XCTAssertNil(self.runner.currentDescription);
	XCTAssertNil(self.runner.currentCancelTitle);
	XCTAssertFalse(self.runner.isInline);
	XCTAssertEqual(self.runner.connection, self.connection);
}

- (void)testTasksRunInOrderOneAtATime
{
	NSMutableArray *workOrder = [NSMutableArray array];
	NSMutableArray *completionOrder = [NSMutableArray array];
	__block atomic_int running = 0;
	__block atomic_int maxRunning = 0;
	for (NSInteger i = 1; i <= 3; i++) {
		[self.runner runTaskWithDescription:[NSString stringWithFormat:@"Task %ld", (long)i] cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
			int now = atomic_fetch_add(&running, 1) + 1;
			int seen = atomic_load(&maxRunning);
			while (now > seen && !atomic_compare_exchange_weak(&maxRunning, &seen, now)) {}
			@synchronized (workOrder) { [workOrder addObject:@(i)]; }
			PGPostgresResult *result = [connection execute:@"SELECT pg_sleep(0.1)"];
			atomic_fetch_sub(&running, 1);
			return result ? @(i) : nil;
		} completion:^(id result, NSError *error, BOOL cancelled) {
			XCTAssertTrue([NSThread isMainThread]);
			XCTAssertFalse(cancelled);
			XCTAssertEqualObjects(result, @(i));
			[completionOrder addObject:@(i)];
		}];
	}
	XCTAssertEqualObjects(self.runner.currentDescription, @"Task 1");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
	XCTAssertEqualObjects(workOrder, (@[@1, @2, @3]));
	XCTAssertEqualObjects(completionOrder, (@[@1, @2, @3]));
	XCTAssertEqual(atomic_load(&maxRunning), 1);
}

- (void)testBusyIsKVOObservable
{
	SPTaskRunnerTestObserver *observer = [[SPTaskRunnerTestObserver alloc] init];
	[self.runner addObserver:observer forKeyPath:@"busy" options:NSKeyValueObservingOptionNew context:NULL];
	__block BOOL busyInLastCompletion = NO;
	__block NSUInteger changesBeforeLastCompletion = 0;
	[self.runner runTaskWithDescription:@"One" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		return @1;
	} completion:^(id result, NSError *error, BOOL cancelled) {}];
	XCTAssertEqualObjects(observer.values, (@[@YES]));
	[self.runner runTaskWithDescription:@"Two" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		return @2;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		busyInLastCompletion = self.runner.isBusy;
		changesBeforeLastCompletion = observer.values.count;
	}];
	XCTAssertEqualObjects(observer.values, (@[@YES]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
	[self.runner removeObserver:observer forKeyPath:@"busy"];
	XCTAssertTrue(busyInLastCompletion);
	XCTAssertEqual(changesBeforeLastCompletion, 1u);
	XCTAssertEqualObjects(observer.values, (@[@YES, @NO]));
	XCTAssertFalse(observer.changeOffMain);
}

- (void)testErrorIsPassedToCompletion
{
	__block NSError *gotError = nil;
	__block id gotResult = @"unset";
	__block BOOL gotCancelled = YES, called = NO;
	[self.runner runTaskWithDescription:@"Failing" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		if (![connection execute:@"SELECT 1/0"]) {
			if (error) *error = [NSError errorWithDomain:@"SPPostgresTaskRunnerTests" code:1
												userInfo:@{NSLocalizedDescriptionKey: connection.lastError.errorPrimaryMessage ?: @"?"}];
			return nil;
		}
		return @"no error";
	} completion:^(id result, NSError *error, BOOL cancelled) {
		gotError = error;
		gotResult = result;
		gotCancelled = cancelled;
		called = YES;
	}];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
	XCTAssertTrue(called);
	XCTAssertNil(gotResult);
	XCTAssertFalse(gotCancelled);
	XCTAssertEqualObjects(gotError.domain, @"SPPostgresTaskRunnerTests");
	XCTAssertTrue([gotError.localizedDescription rangeOfString:@"division by zero"].location != NSNotFound, @"%@", gotError);
}

- (void)testCancelInterruptsRunningStatement
{
	__block BOOL called = NO, gotCancelled = NO;
	__block id gotResult = @"unset";
	__block NSError *gotError = (NSError *)@"unset";
	__block BOOL sawCancelled = NO;
	[self.runner runTaskWithDescription:@"Sleeping" cancelTitle:@"Stop" work:^id(PGPostgresConnection *connection, NSError **error) {
		PGPostgresResult *result = [connection execute:@"SELECT pg_sleep(30)"];
		sawCancelled = [self.runner isCancelled];
		return result ? @"finished" : nil;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		gotResult = result;
		gotError = error;
		gotCancelled = cancelled;
		called = YES;
	}];
	XCTAssertEqualObjects(self.runner.currentCancelTitle, @"Stop");
	[self spinFor:0.3];
	XCTAssertFalse(called);
	NSDate *cancelledAt = [NSDate date];
	[self.runner cancelAll];
	XCTAssertTrue([self spinUntil:^BOOL{ return called; } timeout:5]);
	XCTAssertLessThan(-[cancelledAt timeIntervalSinceNow], 5.0);
	XCTAssertTrue(gotCancelled);
	XCTAssertNil(gotResult);
	XCTAssertNil(gotError);
	XCTAssertTrue(sawCancelled);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:5]);
	XCTAssertFalse([self.runner isCancelled]);

	PGPostgresResult *after = [self.connection execute:@"SELECT 1"];
	XCTAssertNotNil(after, @"%@", self.connection.lastError.errorPrimaryMessage);
	XCTAssertEqualObjects([after textValueAtRow:0 column:0], @"1");

	// A task enqueued after the cancel runs normally
	__block id laterResult = nil;
	__block BOOL laterCancelled = YES;
	[self.runner runTaskWithDescription:@"Later" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		return @"later";
	} completion:^(id result, NSError *error, BOOL cancelled) {
		laterResult = result;
		laterCancelled = cancelled;
	}];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:5]);
	XCTAssertEqualObjects(laterResult, @"later");
	XCTAssertFalse(laterCancelled);
}

- (void)testCancelSkipsQueuedTasks
{
	NSMutableArray *completions = [NSMutableArray array];
	__block BOOL secondWorkRan = NO;
	[self.runner runTaskWithDescription:@"First" cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		[connection execute:@"SELECT pg_sleep(30)"];
		return @1;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		XCTAssertNil(result);
		[completions addObject:[NSString stringWithFormat:@"first %d", cancelled]];
	}];
	[self.runner runTaskWithDescription:@"Second" cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		secondWorkRan = YES;
		return @2;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		XCTAssertNil(result);
		[completions addObject:[NSString stringWithFormat:@"second %d", cancelled]];
	}];
	[self spinFor:0.3];
	[self.runner cancelAll];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:5]);
	XCTAssertFalse(secondWorkRan);
	XCTAssertEqualObjects(completions, (@[@"first 1", @"second 1"]));
}

- (void)testCancelAfterWorkFinishedDropsResult
{
	dispatch_semaphore_t workDone = dispatch_semaphore_create(0);
	__block BOOL called = NO, gotCancelled = NO;
	__block id gotResult = @"unset";
	[self.runner runTaskWithDescription:@"Quick" cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		dispatch_semaphore_signal(workDone);
		return @"done";
	} completion:^(id result, NSError *error, BOOL cancelled) {
		gotResult = result;
		gotCancelled = cancelled;
		called = YES;
	}];
	// The main thread is blocked here, so the completion can't have run yet
	XCTAssertEqual(dispatch_semaphore_wait(workDone, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
	[NSThread sleepForTimeInterval:0.1]; // let the work block return
	XCTAssertFalse(called);
	[self.runner cancelAll];
	XCTAssertFalse(called);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:5]);
	XCTAssertTrue(called);
	XCTAssertTrue(gotCancelled);
	XCTAssertNil(gotResult);
}

- (void)testInvalidateCallsNoCompletionAndAfterIdleAfterWorker
{
	__block BOOL completionCalled = NO, workReturned = NO, workReturnedWhenAfterIdle = NO, afterIdleOnMain = NO;
	__block NSUInteger afterIdleCalls = 0;
	[self.runner runTaskWithDescription:@"Sleeping" cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		[connection execute:@"SELECT pg_sleep(30)"];
		[NSThread sleepForTimeInterval:0.2];
		workReturned = YES;
		return @1;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		completionCalled = YES;
	}];
	__block BOOL queuedWorkRan = NO;
	[self.runner runTaskWithDescription:@"Queued" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		queuedWorkRan = YES;
		return nil;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		completionCalled = YES;
	}];
	[self spinFor:0.3];
	[self.runner invalidateWithCompletion:^{
		afterIdleOnMain = [NSThread isMainThread];
		workReturnedWhenAfterIdle = workReturned;
		afterIdleCalls++;
	}];
	XCTAssertEqual(afterIdleCalls, 0u);
	XCTAssertTrue([self spinUntil:^BOOL{ return afterIdleCalls > 0; } timeout:5]);
	[self spinFor:0.3];
	XCTAssertEqual(afterIdleCalls, 1u);
	XCTAssertTrue(afterIdleOnMain);
	XCTAssertTrue(workReturnedWhenAfterIdle);
	XCTAssertFalse(completionCalled);
	XCTAssertFalse(queuedWorkRan);
	XCTAssertFalse(self.runner.isBusy);

	// Dropped after invalidation
	__block BOOL laterCalled = NO;
	[self.runner runTaskWithDescription:@"Later" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		laterCalled = YES;
		return nil;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		laterCalled = YES;
	}];
	[self spinFor:0.3];
	XCTAssertFalse(laterCalled);
	XCTAssertFalse(self.runner.isBusy);

	// The connection is usable again
	XCTAssertNotNil([self.connection execute:@"SELECT 1"], @"%@", self.connection.lastError.errorPrimaryMessage);
}

- (void)testInvalidateWhenIdleCallsAfterIdleLater
{
	__block NSUInteger calls = 0;
	[self.runner invalidateWithCompletion:^{
		XCTAssertTrue([NSThread isMainThread]);
		calls++;
	}];
	XCTAssertEqual(calls, 0u);
	XCTAssertTrue([self spinUntil:^BOOL{ return calls > 0; } timeout:5]);
	[self spinFor:0.2];
	XCTAssertEqual(calls, 1u);
}

- (void)testInlineRunnerIsSynchronous
{
	SPPostgresTaskRunner *inlineRunner = [SPPostgresTaskRunner inlineRunnerWithConnection:self.connection];
	XCTAssertTrue(inlineRunner.isInline);
	XCTAssertEqual(inlineRunner.connection, self.connection);
	__block BOOL workRan = NO, workOnMain = NO, completionRan = NO, completionOnMain = NO, busyInWork = NO, busyInCompletion = NO;
	__block id gotResult = nil;
	__block BOOL gotCancelled = YES;
	__block NSString *descriptionInWork = nil;
	[inlineRunner runTaskWithDescription:@"Inline" cancelTitle:@"Cancel" work:^id(PGPostgresConnection *connection, NSError **error) {
		workRan = YES;
		workOnMain = [NSThread isMainThread];
		busyInWork = inlineRunner.isBusy;
		descriptionInWork = inlineRunner.currentDescription;
		[inlineRunner cancelAll];
		XCTAssertFalse([inlineRunner isCancelled]);
		PGPostgresResult *result = [connection execute:@"SELECT 7"];
		return [result textValueAtRow:0 column:0];
	} completion:^(id result, NSError *error, BOOL cancelled) {
		completionRan = YES;
		completionOnMain = [NSThread isMainThread];
		busyInCompletion = inlineRunner.isBusy;
		gotResult = result;
		gotCancelled = cancelled;
	}];
	XCTAssertTrue(workRan);
	XCTAssertTrue(completionRan);
	XCTAssertTrue(workOnMain);
	XCTAssertTrue(completionOnMain);
	XCTAssertTrue(busyInWork);
	XCTAssertTrue(busyInCompletion);
	XCTAssertEqualObjects(descriptionInWork, @"Inline");
	XCTAssertEqualObjects(gotResult, @"7");
	XCTAssertFalse(gotCancelled);
	XCTAssertFalse(inlineRunner.isBusy);
	XCTAssertNil(inlineRunner.currentDescription);
	XCTAssertFalse([inlineRunner isCancelled]);

	__block BOOL idle = NO;
	[inlineRunner invalidateWithCompletion:^{ idle = YES; }];
	XCTAssertFalse(idle);
	XCTAssertTrue([self spinUntil:^BOOL{ return idle; } timeout:5]);
	__block BOOL laterCalled = NO;
	[inlineRunner runTaskWithDescription:@"Later" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		laterCalled = YES;
		return nil;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		laterCalled = YES;
	}];
	XCTAssertFalse(laterCalled);
}

- (void)testUpdateDescriptionFromWorkReachesMain
{
	SPTaskRunnerTestObserver *observer = [[SPTaskRunnerTestObserver alloc] init];
	[self.runner addObserver:observer forKeyPath:@"currentDescription" options:NSKeyValueObservingOptionNew context:NULL];
	dispatch_semaphore_t updated = dispatch_semaphore_create(0);
	dispatch_semaphore_t proceed = dispatch_semaphore_create(0);
	[self.runner runTaskWithDescription:@"Running query 1 of 2..." cancelTitle:@"Stop" work:^id(PGPostgresConnection *connection, NSError **error) {
		[self.runner updateDescription:@"Running query 2 of 2..."];
		dispatch_semaphore_signal(updated);
		dispatch_semaphore_wait(proceed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
		return nil;
	} completion:^(id result, NSError *error, BOOL cancelled) {}];
	XCTAssertEqual(dispatch_semaphore_wait(updated, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
	BOOL reached = [self spinUntil:^BOOL{ return [self.runner.currentDescription isEqual:@"Running query 2 of 2..."]; } timeout:5];
	dispatch_semaphore_signal(proceed);
	XCTAssertTrue(reached);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:5]);
	[self.runner removeObserver:observer forKeyPath:@"currentDescription"];
	XCTAssertFalse(observer.changeOffMain);
	XCTAssertEqualObjects(observer.values, (@[@"Running query 1 of 2...", @"Running query 2 of 2...", [NSNull null]]));
	XCTAssertNil(self.runner.currentDescription);
}

@end
