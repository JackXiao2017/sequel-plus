#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import <stdatomic.h>
#import <objc/runtime.h>
#import "SPPostgresTestServers.h"
#import "SPTestTCPRelay.h"
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

/// Records the runner's connection delegate calls ("prepare", "prepare!" when forced, "lost", "reconnected") and
/// answers from blocks.
@interface SPTaskRunnerFakeConnectionDelegate : NSObject <SPPostgresTaskRunnerConnectionDelegate>
@property (strong) NSMutableArray<NSString *> *calls;
/// The error prepare answers for its nth call (1-based); nil block: nil.
@property (copy) NSError *(^prepareAnswer)(NSUInteger attempt);
/// Runs in prepare (e.g. to move the connection to another port, as a reopened tunnel does).
@property (copy) void (^prepareAction)(BOOL force);
/// The decision for a lost connection; nil block or nil result: never answered.
@property (copy) NSNumber *(^decisionAnswer)(NSString *reason, BOOL transactionLost);
@property (copy) NSString *lastReason;
@property BOOL lastTransactionLost;
@property BOOL offMain;
@end

@implementation SPTaskRunnerFakeConnectionDelegate

- (instancetype)init
{
	if ((self = [super init])) _calls = [NSMutableArray array];
	return self;
}

- (void)taskRunner:(SPPostgresTaskRunner *)runner prepareReconnectForcing:(BOOL)force completion:(void (^)(NSError *))completion
{
	if (![NSThread isMainThread]) self.offMain = YES;
	[self.calls addObject:force ? @"prepare!" : @"prepare"];
	if (self.prepareAction) self.prepareAction(force);
	NSUInteger attempt = 0;
	for (NSString *call in self.calls) if ([call hasPrefix:@"prepare"]) attempt++;
	NSError *error = self.prepareAnswer ? self.prepareAnswer(attempt) : nil;
	dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

- (void)taskRunner:(SPPostgresTaskRunner *)runner connectionLost:(NSString *)reason transactionLost:(BOOL)transactionLost decision:(void (^)(BOOL))decision
{
	if (![NSThread isMainThread]) self.offMain = YES;
	[self.calls addObject:@"lost"];
	self.lastReason = reason;
	self.lastTransactionLost = transactionLost;
	NSNumber *answer = self.decisionAnswer ? self.decisionAnswer(reason, transactionLost) : nil;
	if (answer) dispatch_async(dispatch_get_main_queue(), ^{ decision([answer boolValue]); });
}

- (void)taskRunnerDidReconnect:(SPPostgresTaskRunner *)runner
{
	if (![NSThread isMainThread]) self.offMain = YES;
	[self.calls addObject:@"reconnected"];
}

@end

/// What a task's completion got.
@interface SPTaskRunnerOutcome : NSObject
@property BOOL done;
@property BOOL cancelled;
@property BOOL workRan;
@property (strong) id result;
@property (strong) NSError *error;
@end

@implementation SPTaskRunnerOutcome
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

#pragma mark - Checking the connection before use

/// Runs sql as a task; the outcome fills in when its completion is called.
- (SPTaskRunnerOutcome *)run:(NSString *)sql
{
	SPTaskRunnerOutcome *outcome = [[SPTaskRunnerOutcome alloc] init];
	[self.runner runTaskWithDescription:@"Test" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		outcome.workRan = YES;
		PGPostgresResult *result = [connection execute:sql];
		if (!result) {
			if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: connection.lastError.errorPrimaryMessage ?: connection.libpqErrorMessage ?: @"failed"}];
			return nil;
		}
		return [[result rowAsArray] firstObject];
	} completion:^(id result, NSError *error, BOOL cancelled) {
		outcome.done = YES;
		outcome.result = result;
		outcome.error = error;
		outcome.cancelled = cancelled;
	}];
	return outcome;
}

- (void)waitFor:(SPTaskRunnerOutcome *)outcome
{
	XCTAssertTrue([self spinUntil:^BOOL{ return outcome.done; } timeout:30]);
}

/// Ends the connection's server session from another connection, as a server restart or an idle timeout would.
- (void)dropConnection
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:55418];
	NSString *sql = [NSString stringWithFormat:@"SELECT pg_terminate_backend(%lu)", (unsigned long)[self.connection serverProcessId]];
	XCTAssertNotNil([admin execute:sql]);
	[NSThread sleepForTimeInterval:0.2];
}

- (SPTaskRunnerFakeConnectionDelegate *)fakeDelegate
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [[SPTaskRunnerFakeConnectionDelegate alloc] init];
	objc_setAssociatedObject(self, @selector(fakeDelegate), delegate, OBJC_ASSOCIATION_RETAIN); // the runner doesn't retain it
	self.runner.connectionDelegate = delegate;
	self.runner.idleCheckInterval = 0;
	return delegate;
}

- (void)testCheckDefaults
{
	XCTAssertNil(self.runner.connectionDelegate);
	XCTAssertEqual(self.runner.idleCheckInterval, 30);
	XCTAssertEqual(self.runner.pingTimeout, 10);
}

- (void)testNoCheckWithoutDelegate
{
	self.runner.idleCheckInterval = 0;
	[self dropConnection];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertTrue(outcome.workRan);
	XCTAssertNotNil(outcome.error, @"as today: the statement fails");
}

- (void)testDroppedConnectionReconnectsSilentlyAndRunsTheTask
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	NSUInteger oldProcess = [self.connection serverProcessId];
	[self dropConnection];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertNil(outcome.error);
	XCTAssertEqualObjects(outcome.result, @1);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare", @"reconnected"]));
	XCTAssertFalse(delegate.offMain);
	XCTAssertNotEqual([self.connection serverProcessId], oldProcess);
}

- (void)testHealthyConnectionIsNotReconnected
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	NSUInteger process = [self.connection serverProcessId];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertEqualObjects(outcome.result, @1);
	XCTAssertEqualObjects(delegate.calls, (@[]));
	XCTAssertEqual([self.connection serverProcessId], process);
}

- (void)testRecentlyUsedConnectionIsNotPinged
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	self.runner.idleCheckInterval = 30;
	[self waitFor:[self run:@"SELECT 1"]];
	[self dropConnection];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertNotNil(outcome.error, @"used moments ago: not checked, fails as today");
	XCTAssertEqualObjects(delegate.calls, (@[]));
}

- (void)testBrokenConnectionIsCheckedEvenWhenRecentlyUsed
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	self.runner.idleCheckInterval = 30;
	[self dropConnection];
	SPTaskRunnerOutcome *first = [self run:@"SELECT 1"];
	[self waitFor:first];
	XCTAssertNotNil(first.error, @"a statement that fails is never re-run");
	SPTaskRunnerOutcome *second = [self run:@"SELECT 2"];
	[self waitFor:second];
	XCTAssertEqualObjects(second.result, @2);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare", @"reconnected"]));
}

- (void)testFailedReconnectAsksAndRetries
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	delegate.prepareAnswer = ^NSError *(NSUInteger attempt) {
		return attempt == 1 ? [NSError errorWithDomain:@"test" code:2 userInfo:@{NSLocalizedDescriptionKey: @"tunnel down"}] : nil;
	};
	delegate.decisionAnswer = ^NSNumber *(NSString *reason, BOOL transactionLost) { return @YES; };
	[self dropConnection];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertEqualObjects(outcome.result, @1);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare", @"lost", @"prepare!", @"reconnected"]), @"Reconnect from the sheet reopens the tunnel even if it looks up");
	XCTAssertTrue([delegate.lastReason containsString:@"tunnel down"], @"%@", delegate.lastReason);
	XCTAssertFalse(delegate.lastTransactionLost);
}

- (void)testFailedReestablishAsksWithTheServersReason
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	__block NSUInteger asked = 0;
	NSUInteger realPort = self.connection.port;
	delegate.decisionAnswer = ^NSNumber *(NSString *reason, BOOL transactionLost) {
		asked++;
		self.connection.port = realPort; // the server is reachable again
		return @YES;
	};
	[self dropConnection];
	self.connection.port = 1; // nothing listens there
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertEqualObjects(outcome.result, @1);
	XCTAssertEqual(asked, 1u);
	XCTAssertGreaterThan([delegate.lastReason length], 0u);
}

- (void)testDisconnectDecisionCancelsTheQueuedTasks
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	delegate.prepareAnswer = ^NSError *(NSUInteger attempt) { return [NSError errorWithDomain:@"test" code:2 userInfo:nil]; };
	delegate.decisionAnswer = ^NSNumber *(NSString *reason, BOOL transactionLost) { return @NO; };
	[self dropConnection];
	SPTaskRunnerOutcome *first = [self run:@"SELECT 1"];
	SPTaskRunnerOutcome *second = [self run:@"SELECT 2"];
	[self waitFor:first];
	[self waitFor:second];
	XCTAssertTrue(first.cancelled);
	XCTAssertTrue(second.cancelled);
	XCTAssertFalse(first.workRan);
	XCTAssertFalse(second.workRan);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare", @"lost"]));
}

- (void)testOpenTransactionAsksFirst
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	delegate.decisionAnswer = ^NSNumber *(NSString *reason, BOOL transactionLost) { return @YES; };
	[self waitFor:[self run:@"BEGIN"]];
	[self dropConnection];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertEqualObjects(outcome.result, @1);
	XCTAssertEqualObjects(delegate.calls, (@[@"lost", @"prepare!", @"reconnected"]), @"asked before any silent attempt");
	XCTAssertTrue(delegate.lastTransactionLost);
}

- (void)testQueuedTasksShareOneReconnect
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	[self dropConnection];
	SPTaskRunnerOutcome *first = [self run:@"SELECT pg_backend_pid()"];
	SPTaskRunnerOutcome *second = [self run:@"SELECT pg_backend_pid()"];
	[self waitFor:first];
	[self waitFor:second];
	XCTAssertNotNil(first.result);
	XCTAssertEqualObjects(first.result, second.result);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare", @"reconnected"]));
}

- (void)testInvalidateWhileWaitingForDecision
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	delegate.prepareAnswer = ^NSError *(NSUInteger attempt) { return [NSError errorWithDomain:@"test" code:2 userInfo:nil]; };
	// decisionAnswer nil: never answered (the sheet still up when the tab closes)
	[self dropConnection];
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [delegate.calls containsObject:@"lost"]; } timeout:20]);
	__block BOOL idle = NO;
	[self.runner invalidateWithCompletion:^{ idle = YES; }];
	XCTAssertTrue([self spinUntil:^BOOL{ return idle; } timeout:5]);
	[self spinFor:0.3];
	XCTAssertFalse(outcome.done);
	XCTAssertFalse(outcome.workRan);
}

- (void)testTransactionOpenedInTheDroppedTaskAsksFirst
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	delegate.decisionAnswer = ^NSNumber *(NSString *reason, BOOL transactionLost) { return @YES; };
	NSUInteger process = [self.connection serverProcessId];
	SPTaskRunnerOutcome *dropped = [[SPTaskRunnerOutcome alloc] init];
	[self.runner runTaskWithDescription:@"Test" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		[connection execute:@"BEGIN"];
		PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:55418];
		[admin execute:[NSString stringWithFormat:@"SELECT pg_terminate_backend(%lu)", (unsigned long)process]];
		[admin disconnect];
		[NSThread sleepForTimeInterval:0.2];
		return [connection execute:@"SELECT 1"]; // fails: the session was dropped under it
	} completion:^(id result, NSError *error, BOOL cancelled) { dropped.done = YES; dropped.result = result; }];
	[self waitFor:dropped];
	XCTAssertNil(dropped.result);

	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 1"];
	[self waitFor:outcome];
	XCTAssertEqualObjects(outcome.result, @1);
	XCTAssertEqualObjects(delegate.calls, (@[@"lost", @"prepare!", @"reconnected"]));
	XCTAssertTrue(delegate.lastTransactionLost);
}

- (void)testDropFoundOutsideTheRunnerIsChecked
{
	SPTaskRunnerFakeConnectionDelegate *delegate = [self fakeDelegate];
	self.runner.idleCheckInterval = 30;
	[self dropConnection];
	XCTAssertNil([self.connection execute:@"SELECT 1"], @"a main-thread query finds the drop");
	SPTaskRunnerOutcome *outcome = [self run:@"SELECT 2"];
	[self waitFor:outcome];
	XCTAssertEqualObjects(outcome.result, @2);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare", @"reconnected"]));
}

/// A network gone silent: the ping times out; the tunnel is reopened even if it still looks connected (after sleep an
/// SSH tunnel reports connected for a while), then the connection follows it.
- (void)testSilentNetworkForcesTheReopen
{
	SPTestTCPRelay *relay = [[SPTestTCPRelay alloc] initForwardingToPort:55418];
	SPTestTCPRelay *second = [[SPTestTCPRelay alloc] initForwardingToPort:55418];
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = relay.localPort;
	connection.user = @"pgkit_test";
	connection.password = @"pgkit";
	connection.database = @"pgkit_test";
	connection.timeout = 5;
	[connection connect];
	XCTAssertTrue([self spinUntil:^BOOL{ return connection.isConnected || connection.connectionError; } timeout:10]);
	XCTAssertTrue(connection.isConnected);
	SPPostgresTaskRunner *runner = [[SPPostgresTaskRunner alloc] initWithConnection:connection];
	SPTaskRunnerFakeConnectionDelegate *delegate = [[SPTaskRunnerFakeConnectionDelegate alloc] init];
	delegate.prepareAction = ^(BOOL force) { if (force) connection.port = second.localPort; };
	runner.connectionDelegate = delegate;
	runner.idleCheckInterval = 0;
	runner.pingTimeout = 1;
	[self addTeardownBlock:^{
		[runner invalidateWithCompletion:nil];
		[relay stop];
		[second stop];
		[connection disconnect];
	}];

	[relay freeze];
	__block id result = nil;
	__block BOOL done = NO;
	[runner runTaskWithDescription:@"Test" cancelTitle:nil work:^id(PGPostgresConnection *c, NSError **error) {
		return [[[c execute:@"SELECT 1"] rowAsArray] firstObject];
	} completion:^(id r, NSError *error, BOOL cancelled) { result = r; done = YES; }];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertEqualObjects(result, @1);
	XCTAssertEqualObjects(delegate.calls, (@[@"prepare!", @"reconnected"]));
}

- (void)testCancelDuringTheCheckSkipsTheReconnect
{
	SPTestTCPRelay *relay = [[SPTestTCPRelay alloc] initForwardingToPort:55418];
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = relay.localPort;
	connection.user = @"pgkit_test";
	connection.password = @"pgkit";
	connection.database = @"pgkit_test";
	[connection connect];
	XCTAssertTrue([self spinUntil:^BOOL{ return connection.isConnected || connection.connectionError; } timeout:10]);
	SPPostgresTaskRunner *runner = [[SPPostgresTaskRunner alloc] initWithConnection:connection];
	SPTaskRunnerFakeConnectionDelegate *delegate = [[SPTaskRunnerFakeConnectionDelegate alloc] init];
	runner.connectionDelegate = delegate;
	runner.idleCheckInterval = 0;
	runner.pingTimeout = 2;
	[self addTeardownBlock:^{
		[runner invalidateWithCompletion:nil];
		[relay stop];
		[connection disconnect];
	}];

	[relay freeze];
	__block BOOL done = NO, wasCancelled = NO;
	[runner runTaskWithDescription:@"Test" cancelTitle:@"Cancel" work:^id(PGPostgresConnection *c, NSError **error) {
		return [c execute:@"SELECT 1"];
	} completion:^(id r, NSError *error, BOOL cancelled) { wasCancelled = cancelled; done = YES; }];
	[self spinFor:0.3];
	[runner cancelAll];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:5]);
	XCTAssertTrue(wasCancelled);
	XCTAssertEqualObjects(delegate.calls, (@[]), @"cancelled: no reconnect for it");
}

@end
