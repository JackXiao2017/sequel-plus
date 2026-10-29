#import "SPPostgresPaneLoader.h"
#import <Cocoa/Cocoa.h>

@implementation SPPostgresPaneLoader
{
	SPPostgresTaskRunner *taskRunner;
	NSUInteger loadGeneration; // taken by each load (and by -loadNothing and -invalidate)
	BOOL switchPending;        // a switch's table hasn't loaded yet
	BOOL stale;
	BOOL invalidated;
}

@synthesize taskRunner;
@synthesize stale;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection
{
	if ((self = [super init])) {
		taskRunner = [[SPPostgresTaskRunner inlineRunnerWithConnection:connection] retain];
	}
	return self;
}

- (void)dealloc
{
	[taskRunner release];
	[super dealloc];
}

- (void)loadSwitching:(BOOL)switching work:(SPPostgresTaskWork)work apply:(void (^)(id result, NSError *error))apply
{
	if (invalidated) return;
	NSUInteger generation = ++loadGeneration;
	stale = NO;
	if (switching) switchPending = YES;

	void (^applyResult)(id, NSError *) = [[apply copy] autorelease];
	[taskRunner runTaskWithDescription:NSLocalizedString(@"Reloading...", @"Reloading table task string") cancelTitle:NSLocalizedString(@"Cancel", @"cancel button") work:work completion:^(id result, NSError *error, BOOL cancelled) {
		if (invalidated || generation != loadGeneration) return;
		if (cancelled) {
			if (switchPending) stale = YES;
			return;
		}
		switchPending = NO;
		applyResult(result, error);
	}];
}

- (void)loadNothing
{
	loadGeneration++;
	stale = NO;
	switchPending = NO;
}

- (BOOL)refuseChangeWhileBusy
{
	// Also once the runner is invalidated (a database switch dropped it; the pane goes when the new one is installed)
	if (![taskRunner isBusy] && ![taskRunner isInvalidated]) return NO;
	NSBeep();
	return YES;
}

- (void)invalidate
{
	invalidated = YES;
	loadGeneration++;
}

@end
