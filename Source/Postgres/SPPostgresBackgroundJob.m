#import "SPPostgresBackgroundJob.h"
#import <PostgresKit/PostgresKit.h>
#import <objc/runtime.h>
#import "SPPostgresErrors.h"

static char SPPostgresBackgroundJobOwnerKey;

@implementation SPPostgresBackgroundJob
{
	/// Main thread only: whether every connection arrived (or the job ended before), the index of the provider being
	/// waited for, and the connections that arrived so far (until the work takes them)
	BOOL answered;
	NSUInteger awaitedProvider;
	NSMutableArray *arrived;
	void (^completion)(BOOL ok, NSError *error);
	/// Guarded by @synchronized(self): the job connections' cancel tokens while work runs, and whether a cancel came
	NSArray *cancelTokens;
	BOOL cancelRequested;
}

/// Seconds between two cancel requests while the work hasn't returned
static const int64_t SPPostgresBackgroundJobCancelInterval = 1;

/// Sends a cancel request on token, off the main thread, then again every SPPostgresBackgroundJobCancelInterval until
/// the token is invalidated (the work has returned) or a request can't be sent.
static void SPPostgresBackgroundJobSendCancel(PGPostgresCancelToken *token)
{
	[token retain];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		if ([token cancel]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SPPostgresBackgroundJobCancelInterval * (int64_t)NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				SPPostgresBackgroundJobSendCancel(token);
			});
		}
		[token release];
	});
}

+ (void)keepOwner:(id)owner untilJobEndsOnConnection:(PGPostgresConnection *)connection
{
	if (!owner || !connection) return;
	// The connection keeps its owner (which normally keeps the connection too); the job breaks that cycle when it ends
	objc_setAssociatedObject(connection, &SPPostgresBackgroundJobOwnerKey, owner, OBJC_ASSOCIATION_RETAIN);
}

/// Lets go of the connection's owner (see +keepOwner:untilJobEndsOnConnection:), on the main thread.
+ (void)_releaseOwnerOfConnection:(PGPostgresConnection *)connection
{
	id owner = [objc_getAssociatedObject(connection, &SPPostgresBackgroundJobOwnerKey) retain];
	if (!owner) return;
	objc_setAssociatedObject(connection, &SPPostgresBackgroundJobOwnerKey, nil, OBJC_ASSOCIATION_RETAIN);
	if ([owner respondsToSelector:@selector(disconnect)]) [owner performSelector:@selector(disconnect)];
	[owner release];
}

- (void)dealloc
{
	for (PGPostgresCancelToken *token in cancelTokens) [token invalidate];
	[cancelTokens release];
	[arrived release];
	[completion release];
	[super dealloc];
}

- (BOOL)waitingForConnection
{
	return !answered;
}

/// Calls the completion once, on the main thread from a later run loop turn.
- (void)_finishWithSuccess:(BOOL)ok error:(NSError *)error
{
	void (^theCompletion)(BOOL, NSError *) = completion;
	completion = nil;
	if (!theCompletion) return;
	NSError *theError = [error retain];
	dispatch_async(dispatch_get_main_queue(), ^{
		theCompletion(ok, theError);
		[theCompletion release];
		[theError release];
	});
}

/// Disconnects a connection no work will use, off the main thread, then lets go of its owner on the main thread.
+ (void)_discardConnection:(PGPostgresConnection *)connection
{
	[connection retain];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[connection disconnect];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _releaseOwnerOfConnection:connection];
			[connection release];
		});
	});
}

/// Discards the connections that arrived so far (no work will use them). Main thread.
- (void)_discardArrivedConnections
{
	for (PGPostgresConnection *connection in arrived) [SPPostgresBackgroundJob _discardConnection:connection];
	[arrived removeAllObjects];
}

- (void)cancel
{
	if (answered) {
		// The work runs (or is about to): interrupt what its connections are running
		NSArray *tokens = nil;
		@synchronized(self) {
			cancelRequested = YES;
			tokens = [[cancelTokens retain] autorelease];
		}
		for (PGPostgresCancelToken *token in tokens) SPPostgresBackgroundJobSendCancel(token);
		return;
	}
	answered = YES;
	[self _discardArrivedConnections];
	[self _finishWithSuccess:NO error:SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The job was cancelled.", @"Postgres background job: cancelled while connecting"), nil)];
}

/// Asks providers[index] for a connection to databases[index]; when it arrives, asks the next provider, and once all
/// arrived, runs the work. Main thread.
- (void)_askProviderAtIndex:(NSUInteger)index databases:(NSArray *)databases providers:(NSArray *)providers work:(BOOL (^)(NSArray *, NSError **))work
{
	awaitedProvider = index;
	SPPostgresConnectionProvider provider = [providers objectAtIndex:index];
	SPPostgresBackgroundJob *job = self; // retained by the provider's copy of the block until it answers
	id database = [databases objectAtIndex:index];
	provider(database == [NSNull null] ? nil : database, ^(PGPostgresConnection *connection, NSError *error) {
		if (job->answered || job->awaitedProvider != index) {
			// Too late (cancelled, failed, or a second answer): never used
			if (connection) [SPPostgresBackgroundJob _discardConnection:connection];
			return;
		}
		job->awaitedProvider = NSNotFound;

		if (!connection) {
			job->answered = YES;
			[job _discardArrivedConnections];
			[job _finishWithSuccess:NO error:error];
			return;
		}

		[job->arrived addObject:connection];
		if (index + 1 < [providers count]) {
			[job _askProviderAtIndex:index + 1 databases:databases providers:providers work:work];
			return;
		}
		job->answered = YES;
		[job _runWork:work];
	});
}

/// Runs work with the connections that arrived, on a background thread; disconnects them afterwards and calls the
/// completion on the main thread. Main thread.
- (void)_runWork:(BOOL (^)(NSArray *, NSError **))work
{
	NSArray *connections = [arrived copy]; // released on the main thread after the work
	[arrived removeAllObjects];
	void (^theCompletion)(BOOL, NSError *) = completion;
	completion = nil;
	SPPostgresBackgroundJob *job = self; // retained by the blocks below until the completion was called
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		BOOL ok = NO;
		NSError *workError = nil;
		@autoreleasepool {
			// The cancel tokens are taken here, on the thread that uses the connections; -cancel uses them from the
			// main thread. A cancel that came before they existed is sent now.
			NSMutableArray *tokens = [NSMutableArray array];
			for (PGPostgresConnection *connection in connections) {
				PGPostgresCancelToken *token = [connection newCancelToken];
				if (token) [tokens addObject:token];
				[token release];
			}
			BOOL cancelNow = NO;
			@synchronized(job) {
				[job->cancelTokens release];
				job->cancelTokens = [tokens copy];
				cancelNow = job->cancelRequested;
			}
			if (cancelNow) {
				for (PGPostgresCancelToken *token in tokens) SPPostgresBackgroundJobSendCancel(token);
			}

			NSError *theError = nil;
			ok = work ? work(connections, &theError) : YES;
			workError = [theError retain];

			// No cancel request is sent once the work has returned (one being sent finishes first)
			@synchronized(job) {
				[job->cancelTokens release];
				job->cancelTokens = nil;
			}
			for (PGPostgresCancelToken *token in tokens) [token invalidate];

			// Never reused: after a cancel, a late cancel request could still reach them
			for (PGPostgresConnection *connection in connections) [connection disconnect];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			for (PGPostgresConnection *connection in connections) [SPPostgresBackgroundJob _releaseOwnerOfConnection:connection];
			[connections release];
			if (theCompletion) theCompletion(ok, workError);
			[theCompletion release];
			[workError release];
		});
	});
}

/// Asks the providers in turn (see -_askProviderAtIndex:…), or fails at once when one is missing. Main thread.
- (void)_startWithDatabases:(NSArray *)databases providers:(NSArray *)providers count:(NSUInteger)count work:(BOOL (^)(NSArray *, NSError **))work
{
	if ([providers count] < count) {
		answered = YES;
		[self _finishWithSuccess:NO error:SPPostgresMakeError(SPPostgresErrorConnectionFailed, NSLocalizedString(@"No connection could be opened for this job.", @"Postgres background job: no connection provider"), nil)];
		return;
	}
	arrived = [[NSMutableArray alloc] init];
	[self _askProviderAtIndex:0 databases:databases providers:providers work:[[work copy] autorelease]];
}

+ (instancetype)runOnDatabase:(NSString *)database
					 provider:(SPPostgresConnectionProvider)provider
						 work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work
				   completion:(void (^)(BOOL ok, NSError *error))theCompletion
{
	SPPostgresBackgroundJob *job = [[[self alloc] init] autorelease];
	job->completion = [theCompletion copy];
	BOOL (^oneWork)(PGPostgresConnection *, NSError **) = [[work copy] autorelease];
	[job _startWithDatabases:@[database ?: (id)[NSNull null]] providers:(provider ? @[[[provider copy] autorelease]] : @[]) count:1 work:^BOOL(NSArray *connections, NSError **error) {
		return oneWork ? oneWork([connections objectAtIndex:0], error) : YES;
	}];
	return job;
}

+ (instancetype)runOnDatabase:(NSString *)database
					 provider:(SPPostgresConnectionProvider)provider
			   targetDatabase:(NSString *)targetDatabase
			   targetProvider:(SPPostgresConnectionProvider)targetProvider
						 work:(BOOL (^)(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error))work
				   completion:(void (^)(BOOL ok, NSError *error))theCompletion
{
	SPPostgresBackgroundJob *job = [[[self alloc] init] autorelease];
	job->completion = [theCompletion copy];
	BOOL (^twoWork)(PGPostgresConnection *, PGPostgresConnection *, NSError **) = [[work copy] autorelease];
	NSArray *providers = (provider && targetProvider) ? @[[[provider copy] autorelease], [[targetProvider copy] autorelease]] : @[];
	[job _startWithDatabases:@[database ?: (id)[NSNull null], targetDatabase ?: (id)[NSNull null]] providers:providers count:2 work:^BOOL(NSArray *connections, NSError **error) {
		return twoWork ? twoWork([connections objectAtIndex:0], [connections objectAtIndex:1], error) : YES;
	}];
	return job;
}

@end
