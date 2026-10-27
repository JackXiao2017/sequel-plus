#import "SPPostgresConsoleLogger.h"
#import "SPQueryController.h"
#import <objc/runtime.h>

static char SPPostgresConsoleLoggerKey;

@implementation SPPostgresConsoleLogger

@synthesize connectionName;
@synthesize database;
@synthesize nextDelegate;
@synthesize loggingCustomQueries;

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

+ (SPPostgresConsoleLogger *)loggerForConnection:(PGPostgresConnection *)connection
{
	if (!connection) return nil;
	id logger = objc_getAssociatedObject(connection, &SPPostgresConsoleLoggerKey);
	return [logger isKindOfClass:[SPPostgresConsoleLogger class]] ? logger : nil;
}

- (void)logError:(NSString *)error
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	if ([error length] && [prefs boolForKey:SPConsoleEnableLogging] && [prefs boolForKey:SPConsoleEnableErrorLogging]) {
		[[SPQueryController sharedQueryController] showErrorInConsole:error connection:connectionName database:database];
	}
}

#pragma mark - PGPostgresConnectionDelegate

- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	NSString *text = nil;
	if ([query isKindOfClass:[NSString class]]) text = (NSString *)query;
	else if ([query isKindOfClass:[PGPostgresStatement class]]) text = [(PGPostgresStatement *)query statement];

	// The same preferences as MySQL's logging: the user's statements from the Query view as custom queries,
	// everything else as interface queries. SPQueryController's message list is lock-protected, so this is
	// safe from any thread.
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSString *kindKey = loggingCustomQueries ? SPConsoleEnableCustomQueryLogging : SPConsoleEnableInterfaceLogging;
	if ([text length] && [prefs boolForKey:SPConsoleEnableLogging] && [prefs boolForKey:kindKey]) {
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
