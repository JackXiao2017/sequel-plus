#import "SPPostgresBackgroundJob.h"
#import <PostgresKit/PostgresKit.h>
#import <objc/runtime.h>
#import "SPPostgresErrors.h"

static char SPPostgresBackgroundJobOwnerKey;

@implementation SPPostgresBackgroundJob
{
	/// Main thread only
	BOOL answered;
	void (^completion)(BOOL ok, NSError *error);
	/// Guarded by @synchronized(self): the job connection's cancel token while work runs, and whether a cancel came
	PGPostgresCancelToken *cancelToken;
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
	[cancelToken invalidate];
	[cancelToken release];
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

- (void)cancel
{
	if (answered) {
		// The work runs (or is about to): interrupt what its connection is running
		PGPostgresCancelToken *token = nil;
		@synchronized(self) {
			cancelRequested = YES;
			token = [[cancelToken retain] autorelease];
		}
		if (token) SPPostgresBackgroundJobSendCancel(token);
		return;
	}
	answered = YES;
	[self _finishWithSuccess:NO error:SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The job was cancelled.", @"Postgres background job: cancelled while connecting"), nil)];
}

- (void)_startWithDatabase:(NSString *)database provider:(SPPostgresConnectionProvider)provider work:(BOOL (^)(PGPostgresConnection *, NSError **))work
{
	if (!provider) {
		answered = YES;
		[self _finishWithSuccess:NO error:SPPostgresMakeError(SPPostgresErrorConnectionFailed, NSLocalizedString(@"No connection could be opened for this job.", @"Postgres background job: no connection provider"), nil)];
		return;
	}

	BOOL (^jobWork)(PGPostgresConnection *, NSError **) = [[work copy] autorelease];
	SPPostgresBackgroundJob *job = self; // retained by the provider's copy of the block until it answers
	provider(database, ^(PGPostgresConnection *connection, NSError *error) {
		if (job->answered) {
			// Too late (cancelled, or a second answer): never used
			if (connection) [SPPostgresBackgroundJob _discardConnection:connection];
			return;
		}
		job->answered = YES;

		if (!connection) {
			[job _finishWithSuccess:NO error:error];
			return;
		}

		void (^theCompletion)(BOOL, NSError *) = job->completion;
		job->completion = nil;
		[connection retain];
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			BOOL ok = NO;
			NSError *workError = nil;
			@autoreleasepool {
				// The cancel token is taken here, on the thread that uses the connection; -cancel uses it from the
				// main thread. A cancel that came before it existed is sent now.
				PGPostgresCancelToken *token = [connection newCancelToken];
				BOOL cancelNow = NO;
				@synchronized(job) {
					job->cancelToken = token;
					cancelNow = job->cancelRequested;
				}
				if (cancelNow && token) SPPostgresBackgroundJobSendCancel(token);

				NSError *theError = nil;
				ok = jobWork ? jobWork(connection, &theError) : YES;
				workError = [theError retain];

				// No cancel request is sent once the work has returned (one being sent finishes first)
				@synchronized(job) {
					job->cancelToken = nil;
				}
				[token invalidate];
				[token release];

				// Never reused: after a cancel, a late cancel request could still reach it
				[connection disconnect];
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				[SPPostgresBackgroundJob _releaseOwnerOfConnection:connection];
				[connection release];
				if (theCompletion) theCompletion(ok, workError);
				[theCompletion release];
				[workError release];
			});
		});
	});
}

+ (instancetype)runOnDatabase:(NSString *)database
					 provider:(SPPostgresConnectionProvider)provider
						 work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work
				   completion:(void (^)(BOOL ok, NSError *error))theCompletion
{
	SPPostgresBackgroundJob *job = [[[self alloc] init] autorelease];
	job->completion = [theCompletion copy];
	[job _startWithDatabase:database provider:provider work:work];
	return job;
}

@end
