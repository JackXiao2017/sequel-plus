#import "SPPostgresConsoleLogger.h"
#import "SPQueryController.h"
#import <objc/runtime.h>

static char SPPostgresConsoleLoggerKey;

@implementation SPPostgresConsoleLogger

@synthesize connectionName;
@synthesize database;
@synthesize nextDelegate;

- (instancetype)initWithConnectionName:(NSString *)theConnectionName database:(NSString *)theDatabase
{
	if ((self = [super init])) {
		connectionName = [theConnectionName copy];
		database = [theDatabase copy];
	}
	return self;
}

- (void)dealloc
{
	[connectionName release];
	[database release];
	[nextDelegate release];
	[super dealloc];
}

- (void)attachToConnection:(PGPostgresConnection *)connection
{
	if (!connection || [connection delegate] == self) return;

	[nextDelegate release];
	nextDelegate = [[connection delegate] retain];

	// PostgresKit keeps its delegate unretained and may call it from its own threads, even after
	// -disconnect: the connection keeps the logger alive for as long as it exists (as the connector does
	// with its proxy). The logger retains the next delegate, which never references the logger.
	objc_setAssociatedObject(connection, &SPPostgresConsoleLoggerKey, self, OBJC_ASSOCIATION_RETAIN);
	[connection setDelegate:self];
}

#pragma mark - PGPostgresConnectionDelegate

- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	NSString *text = nil;
	if ([query isKindOfClass:[NSString class]]) text = (NSString *)query;
	else if ([query isKindOfClass:[PGPostgresStatement class]]) text = [(PGPostgresStatement *)query statement];

	// Stage 1 only runs interface queries; respect the same preferences as MySQL's interface logging.
	// SPQueryController's message list is lock-protected, so this is safe from any thread.
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	if ([text length] && [prefs boolForKey:SPConsoleEnableLogging] && [prefs boolForKey:SPConsoleEnableInterfaceLogging]) {
		[[SPQueryController sharedQueryController] showMessageInConsole:text connection:connectionName database:database];
	}

	if ([nextDelegate respondsToSelector:@selector(connection:willExecute:withValues:)]) [nextDelegate connection:connection willExecute:query withValues:values];
}

- (void)connectionEstablished:(PGPostgresConnection *)connection
{
	if ([nextDelegate respondsToSelector:@selector(connectionEstablished:)]) [nextDelegate connectionEstablished:connection];
}

- (void)connectionReset:(PGPostgresConnection *)connection
{
	if ([nextDelegate respondsToSelector:@selector(connectionReset:)]) [nextDelegate connectionReset:connection];
}

- (void)connectionDisconnected:(PGPostgresConnection *)connection
{
	if ([nextDelegate respondsToSelector:@selector(connectionDisconnected:)]) [nextDelegate connectionDisconnected:connection];
}

- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice
{
	if ([nextDelegate respondsToSelector:@selector(connection:notice:)]) [nextDelegate connection:connection notice:notice];
}

- (void)connectionFailed:(PGPostgresConnection *)connection
{
	if ([nextDelegate respondsToSelector:@selector(connectionFailed:)]) [nextDelegate connectionFailed:connection];
}

@end
