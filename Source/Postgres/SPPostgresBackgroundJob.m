#import "SPPostgresBackgroundJob.h"
#import <PostgresKit/PostgresKit.h>
#import <objc/runtime.h>
#import "SPPostgresErrors.h"

static char SPPostgresBackgroundJobOwnerKey;

@implementation SPPostgresBackgroundJob

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

+ (void)runOnDatabase:(NSString *)database
			 provider:(SPPostgresConnectionProvider)provider
				 work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work
		   completion:(void (^)(BOOL ok, NSError *error))completion
{
	BOOL (^jobWork)(PGPostgresConnection *, NSError **) = [[work copy] autorelease];
	void (^jobCompletion)(BOOL, NSError *) = [[completion copy] autorelease];

	// Called on the main thread, always from a later run loop turn
	void (^finish)(BOOL, NSError *) = [[^(BOOL ok, NSError *error) {
		NSError *theError = [error retain];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (jobCompletion) jobCompletion(ok, theError);
			[theError release];
		});
	} copy] autorelease];

	if (!provider) {
		finish(NO, SPPostgresMakeError(SPPostgresErrorConnectionFailed, NSLocalizedString(@"No connection could be opened for this job.", @"Postgres background job: no connection provider"), nil));
		return;
	}

	__block BOOL answered = NO;
	provider(database, ^(PGPostgresConnection *connection, NSError *error) {
		if (answered) return;
		answered = YES;

		if (!connection) {
			finish(NO, error);
			return;
		}

		[connection retain];
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			BOOL ok = NO;
			NSError *workError = nil;
			@autoreleasepool {
				NSError *theError = nil;
				ok = jobWork ? jobWork(connection, &theError) : YES;
				workError = [theError retain];
				// Never reused: after a cancel, a late cancel request could still reach it
				[connection disconnect];
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				[self _releaseOwnerOfConnection:connection];
				[connection release];
				if (jobCompletion) jobCompletion(ok, workError);
				[workError release];
			});
		});
	});
}

@end
