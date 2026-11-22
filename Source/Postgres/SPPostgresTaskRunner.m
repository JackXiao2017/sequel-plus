#import "SPPostgresTaskRunner.h"
#import <PostgresKit/PostgresKit.h>

/// Seconds between two cancel requests while the work hasn't returned (as SPPostgresBackgroundJob)
static const int64_t SPPostgresTaskRunnerCancelInterval = 1;

/// Sends a cancel request on token, off the main thread, then again every SPPostgresTaskRunnerCancelInterval until
/// the token is invalidated (the work has returned) or a request can't be sent.
static void SPPostgresTaskRunnerSendCancel(PGPostgresCancelToken *token)
{
	[token retain];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		if ([token cancel]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SPPostgresTaskRunnerCancelInterval * (int64_t)NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				SPPostgresTaskRunnerSendCancel(token);
			});
		}
		[token release];
	});
}

/// One task asked for: what to run and what to tell. Its generation is the runner's when it was enqueued; a cancel
/// moves the runner to the next one, so every task enqueued before it counts as cancelled.
@interface SPPostgresTaskRecord : NSObject
{
@public
	NSString *taskDescription;
	NSString *cancelTitle;
	SPPostgresTaskWork work;
	SPPostgresTaskCompletion completion;
	NSUInteger generation;
}
@end

@implementation SPPostgresTaskRecord

- (void)dealloc
{
	[taskDescription release];
	[cancelTitle release];
	[work release];
	[completion release];
	[super dealloc];
}

@end

/// A main-thread answer the worker waits for: set once, then signalled.
@interface SPPostgresTaskRunnerAnswer : NSObject
{
@public
	dispatch_semaphore_t semaphore;
	id value;
	BOOL answered;
}
@end

@implementation SPPostgresTaskRunnerAnswer

- (instancetype)init
{
	if ((self = [super init])) semaphore = dispatch_semaphore_create(0);
	return self;
}

- (void)answer:(id)theValue
{
	@synchronized (self) {
		if (answered) return;
		answered = YES;
		value = [theValue retain];
	}
	dispatch_semaphore_signal(semaphore);
}

- (void)dealloc
{
	[value release];
	dispatch_release(semaphore);
	[super dealloc];
}

@end

@interface SPPostgresTaskRunner ()
{
	dispatch_queue_t queue;

	// Main thread only
	NSMutableArray<SPPostgresTaskRecord *> *pending; // enqueued, completion not called yet, in order
	NSUInteger inlineDepth;

	// Guarded by @synchronized(self): written on the main thread, read on the worker (and by -isCancelled)
	NSUInteger generation;
	BOOL invalidated;
	SPPostgresTaskRecord *runningRecord; // inside its work block
	PGPostgresCancelToken *runningToken;

	// Worker only: what the last work left (see -_connectionUsableBeforeWork:)
	CFAbsoluteTime lastWorkEnded;
	BOOL connectionBroken;
}
@property (readwrite, getter=isBusy) BOOL busy;
@property (readwrite, copy) NSString *currentDescription;
@property (readwrite, copy) NSString *currentCancelTitle;
@end

@implementation SPPostgresTaskRunner

@synthesize connection = _connection;
@synthesize inlineRunner = _inlineRunner;
@synthesize busy = _busy;
@synthesize currentDescription = _currentDescription;
@synthesize currentCancelTitle = _currentCancelTitle;
@synthesize connectionDelegate = _connectionDelegate;
@synthesize idleCheckInterval = _idleCheckInterval;
@synthesize pingTimeout = _pingTimeout;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection
{
	if ((self = [super init])) {
		_connection = [connection retain];
		pending = [[NSMutableArray alloc] init];
		queue = dispatch_queue_create("com.sequelpro.postgres.taskrunner", DISPATCH_QUEUE_SERIAL);
		_idleCheckInterval = 30;
		_pingTimeout = 10;
		lastWorkEnded = CFAbsoluteTimeGetCurrent();
	}
	return self;
}

+ (instancetype)inlineRunnerWithConnection:(PGPostgresConnection *)connection
{
	SPPostgresTaskRunner *runner = [[self alloc] initWithConnection:connection];
	runner->_inlineRunner = YES;
	return [runner autorelease];
}

- (void)dealloc
{
	[_connection release];
	[pending release];
	[_currentDescription release];
	[_currentCancelTitle release];
	[runningToken release];
	[runningRecord release];
	dispatch_release(queue);
	[super dealloc];
}

#pragma mark - Main thread state

/// Shows the head of pending (the running task, else the next one); nil when idle.
- (void)_showHead
{
	SPPostgresTaskRecord *head = [pending firstObject];
	NSString *text = head ? head->taskDescription : nil;
	NSString *title = head ? head->cancelTitle : nil;
	if (text != self.currentDescription && ![text isEqual:self.currentDescription]) self.currentDescription = text;
	if (title != self.currentCancelTitle && ![title isEqual:self.currentCancelTitle]) self.currentCancelTitle = title;
}

#pragma mark - Running

- (void)runTaskWithDescription:(NSString *)description cancelTitle:(NSString *)cancelTitle
						  work:(SPPostgresTaskWork)work completion:(SPPostgresTaskCompletion)completion
{
	@synchronized(self) {
		if (invalidated) return;
	}
	if (_inlineRunner) {
		[self _runInlineWithDescription:description cancelTitle:cancelTitle work:work completion:completion];
		return;
	}

	SPPostgresTaskRecord *record = [[[SPPostgresTaskRecord alloc] init] autorelease];
	record->taskDescription = [description copy];
	record->cancelTitle = [cancelTitle copy];
	record->work = [work copy];
	record->completion = [completion copy];
	@synchronized(self) {
		record->generation = generation;
	}

	[pending addObject:record];
	if (!self.busy) self.busy = YES;
	[self _showHead];

	// The block retains self and record until the worker is done with them
	dispatch_async(queue, ^{
		[self _workOn:record];
	});
}

/// Worker queue: runs record's work unless it was cancelled, then hands what it returned to the main thread.
- (void)_workOn:(SPPostgresTaskRecord *)record
{
	@autoreleasepool {
		BOOL skip;
		@synchronized(self) {
			skip = invalidated || record->generation != generation;
		}

		id result = nil;
		NSError *error = nil;

		// A connection gone dead while idle is re-established first (or the delegate gives up, cancelling this task)
		if (!skip && ![self _connectionUsableBeforeWork:record]) skip = YES;

		if (!skip) {
			// The cancel token is taken here, on the thread that uses the connection; -cancelAll uses it from the main
			// thread. A cancel that came in between skips the work.
			PGPostgresCancelToken *token = [_connection newCancelToken];
			@synchronized(self) {
				skip = invalidated || record->generation != generation;
				if (!skip) {
					runningRecord = [record retain];
					runningToken = [token retain];
				}
			}
			if (!skip) {
				@autoreleasepool {
					NSError *workError = nil;
					result = [record->work(_connection, &workError) retain];
					error = [workError retain];
				}
				lastWorkEnded = CFAbsoluteTimeGetCurrent();
				connectionBroken = ![_connection isConnected];
				// No cancel request is sent once the work has returned (one being sent finishes first)
				@synchronized(self) {
					[runningRecord release];
					runningRecord = nil;
					[runningToken release];
					runningToken = nil;
				}
			}
			[token invalidate];
			[token release];
		}

		// Released on the main thread, after the completion
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _deliver:record result:result error:error];
			[result release];
			[error release];
		});
	}
}

#pragma mark - Checking the connection

/// Worker: runs start on the main thread (unless invalidated) with a block that answers it, and waits for the answer.
/// NO when the runner was invalidated before an answer came (*value is then untouched).
- (BOOL)_waitOnMainFor:(void (^)(SPPostgresTaskRunnerAnswer *answer))start value:(id *)value
{
	SPPostgresTaskRunnerAnswer *answer = [[[SPPostgresTaskRunnerAnswer alloc] init] autorelease];
	[answer retain]; // released by the main-thread block
	dispatch_async(dispatch_get_main_queue(), ^{
		BOOL gone;
		@synchronized (self) {
			gone = invalidated;
		}
		if (!gone) start(answer);
		[answer release];
	});

	while (dispatch_semaphore_wait(answer->semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
		@synchronized (self) {
			if (invalidated) return NO;
		}
	}
	@synchronized (self) {
		if (invalidated) return NO;
	}
	if (value) *value = [[answer->value retain] autorelease];
	return YES;
}

/// Worker: whether record was cancelled (or the runner invalidated) since it was enqueued.
- (BOOL)_isCancelledRecord:(SPPostgresTaskRecord *)record
{
	@synchronized (self) {
		return invalidated || record->generation != generation;
	}
}

/// Worker, before record's work: YES to run it. Checks the connection when it went unused for idleCheckInterval or is
/// known to be broken; a dead one is re-established (see connectionDelegate). NO when the runner was invalidated or the
/// task cancelled meanwhile (nothing is reconnected for it: the next task checks again), or the delegate gave up
/// (then this task and the queued ones count as cancelled).
- (BOOL)_connectionUsableBeforeWork:(SPPostgresTaskRecord *)record
{
	if (!self.connectionDelegate) return YES;
	// Broken by the last work, or found dead by a query made outside the runner
	BOOL broken = connectionBroken || ![_connection isConnected];
	if (!broken && CFAbsoluteTimeGetCurrent() - lastWorkEnded < self.idleCheckInterval) return YES;

	NSTimeInterval timeout = self.pingTimeout;
	CFAbsoluteTime pingStart = CFAbsoluteTimeGetCurrent();
	if ([_connection pingWithTimeout:timeout]) return YES;
	// No answer at all: a network gone silent, which an SSH tunnel can take minutes to notice. Reopen it regardless.
	BOOL silent = CFAbsoluteTimeGetCurrent() - pingStart >= timeout - 0.05;
	connectionBroken = YES;

	NSString *reason = [_connection connectionError];
	// The state before the statement the drop cut off (or after the last that finished)
	PGPostgresTransactionStatus lastKnown = [_connection lastKnownTransactionStatus];
	BOOL transactionLost = lastKnown == PGPostgresTransactionInTransaction || lastKnown == PGPostgresTransactionInError;
	BOOL attempt = !transactionLost; // an open transaction is lost: say so before reconnecting
	BOOL force = silent;

	for (;;) {
		if ([self _isCancelledRecord:record]) return NO;

		if (attempt) {
			id prepared = nil;
			BOOL forcing = force;
			if (![self _waitOnMainFor:^(SPPostgresTaskRunnerAnswer *answer) {
				id<SPPostgresTaskRunnerConnectionDelegate> delegate = self.connectionDelegate;
				if (!delegate) { [answer answer:[NSNull null]]; return; }
				[delegate taskRunner:self prepareReconnectForcing:forcing completion:^(NSError *error) {
					[answer answer:error ?: (id)[NSNull null]];
				}];
			} value:&prepared]) return NO;

			if ([prepared isKindOfClass:[NSError class]]) {
				reason = [(NSError *)prepared localizedDescription];
			}
			else if ([_connection reestablishConnection]) {
				connectionBroken = NO;
				dispatch_async(dispatch_get_main_queue(), ^{
					@synchronized (self) {
						if (invalidated) return;
					}
					[self.connectionDelegate taskRunnerDidReconnect:self];
				});
				return YES;
			}
			else {
				reason = [_connection connectionError];
			}
		}
		attempt = YES;

		NSString *theReason = [reason length] ? reason : NSLocalizedString(@"The server could not be reached.", @"PostgreSQL connection lost without a reason");
		BOOL theTransactionLost = transactionLost;
		id decision = nil;
		if (![self _waitOnMainFor:^(SPPostgresTaskRunnerAnswer *answer) {
			id<SPPostgresTaskRunnerConnectionDelegate> delegate = self.connectionDelegate;
			if (!delegate) { [answer answer:@NO]; return; }
			[delegate taskRunner:self connectionLost:theReason transactionLost:theTransactionLost decision:^(BOOL reconnect) {
				[answer answer:@(reconnect)];
			}];
		} value:&decision]) return NO;
		transactionLost = NO; // said once
		force = YES;          // the user's Reconnect: reopen a tunnel even if it looks up

		if (![decision boolValue]) {
			connectionBroken = YES;
			@synchronized (self) {
				generation++; // this task and every queued one complete as cancelled
			}
			return NO;
		}
	}
}

/// Main thread: calls record's completion (cancelled when a cancel came after it was enqueued).
- (void)_deliver:(SPPostgresTaskRecord *)record result:(id)result error:(NSError *)error
{
	BOOL cancelled;
	@synchronized(self) {
		if (invalidated) return;
		cancelled = record->generation != generation;
	}
	// Completions come in enqueue order (one serial queue, then the main queue), so record is the head
	NSUInteger index = [pending indexOfObjectIdenticalTo:record];
	if (index == NSNotFound) return;
	[[record retain] autorelease];
	[pending removeObjectAtIndex:index];
	[self _showHead];

	if (record->completion) {
		if (cancelled) record->completion(nil, nil, YES);
		else record->completion(result, error, NO);
	}

	// The completion may have enqueued more, or invalidated the runner (which already set busy NO)
	if (![pending count] && self.busy) self.busy = NO;
}

- (void)_runInlineWithDescription:(NSString *)description cancelTitle:(NSString *)cancelTitle
							 work:(SPPostgresTaskWork)work completion:(SPPostgresTaskCompletion)completion
{
	NSString *previousDescription = [[self.currentDescription retain] autorelease];
	NSString *previousCancelTitle = [[self.currentCancelTitle retain] autorelease];
	inlineDepth++;
	if (!self.busy) self.busy = YES;
	self.currentDescription = description;
	self.currentCancelTitle = cancelTitle;

	NSError *error = nil;
	id result = work ? work(_connection, &error) : nil;
	BOOL dropped;
	@synchronized(self) {
		dropped = invalidated;
	}
	if (completion && !dropped) completion(result, error, NO);

	inlineDepth--;
	self.currentDescription = inlineDepth ? previousDescription : nil;
	self.currentCancelTitle = inlineDepth ? previousCancelTitle : nil;
	if (!inlineDepth && self.busy) self.busy = NO;
}

#pragma mark - Description

- (void)updateDescription:(NSString *)description
{
	NSString *text = [[description copy] autorelease];
	if (_inlineRunner) {
		if ([NSThread isMainThread] && inlineDepth) self.currentDescription = text;
		return;
	}

	SPPostgresTaskRecord *target;
	@synchronized(self) {
		target = [[runningRecord retain] autorelease];
	}
	void (^apply)(void) = ^{
		@synchronized(self) {
			if (invalidated) return;
		}
		SPPostgresTaskRecord *head = [pending firstObject];
		if (!head || (target && head != target)) return; // that task has finished meanwhile
		[head->taskDescription release];
		head->taskDescription = [text copy];
		[self _showHead];
	};
	if ([NSThread isMainThread]) apply();
	else dispatch_async(dispatch_get_main_queue(), apply);
}

#pragma mark - Cancelling

- (void)cancelAll
{
	if (_inlineRunner) return;
	PGPostgresCancelToken *token;
	@synchronized(self) {
		generation++;
		token = [[runningToken retain] autorelease];
	}
	if (token) SPPostgresTaskRunnerSendCancel(token);
}

- (BOOL)isInvalidated
{
	@synchronized(self) {
		return invalidated;
	}
}

- (BOOL)isCancelled
{
	if (_inlineRunner) return NO;
	@synchronized(self) {
		return runningRecord && (invalidated || runningRecord->generation != generation);
	}
}

- (void)invalidateWithCompletion:(void (^)(void))afterIdle
{
	PGPostgresCancelToken *token = nil;
	BOOL wasInvalidated;
	@synchronized(self) {
		wasInvalidated = invalidated;
		invalidated = YES;
		generation++;
		if (!_inlineRunner) token = [[runningToken retain] autorelease];
	}
	if (token) SPPostgresTaskRunnerSendCancel(token);

	if (!wasInvalidated) {
		[pending removeAllObjects];
		if (self.currentDescription) self.currentDescription = nil;
		if (self.currentCancelTitle) self.currentCancelTitle = nil;
		if (self.busy && !inlineDepth) self.busy = NO;
	}

	if (!afterIdle) return;
	void (^idle)(void) = [[afterIdle copy] autorelease];
	if (_inlineRunner) {
		dispatch_async(dispatch_get_main_queue(), idle);
		return;
	}
	// After whatever the worker is running (the queued tasks are skipped), then on the main thread
	dispatch_async(queue, ^{
		dispatch_async(dispatch_get_main_queue(), idle);
	});
}

@end
