#import "SPPostgresConnector.h"
#import "SPPostgresErrors.h"
#import "SPPostgresFavorite.h"
#import "SPSSHTunnel.h"
#import "SPKeychain.h"
#import <PostgresKit/PostgresKit.h>
#import <objc/runtime.h>

static const NSUInteger SPPostgresConnectTimeout = 10;
static NSString * const SPPostgresApplicationName = @"Sequel Pro";
static const NSUInteger SPPostgresDefaultPort = 5432;
static char SPPostgresConnectorProxyKey;

@interface SPPostgresConnector ()

- (void)_postgresConnectionEstablished:(PGPostgresConnection *)theConnection;
- (void)_postgresConnectionFailed:(PGPostgresConnection *)theConnection message:(NSString *)message;
- (void)_sshTunnelStateChanged:(SPSSHTunnel *)theTunnel;

@end

#pragma mark -

/**
 * Receives PostgresKit and SSH tunnel callbacks for a connector.
 *
 * Both PGPostgresConnection and SPSSHTunnel keep an unretained delegate and read it on their worker
 * threads; PostgresKit can even deliver a callback after -disconnect has returned. So the delegate they
 * see is this proxy, which is retained by the connection and the tunnel themselves (associated object):
 * it lives at least as long as their worker threads, whatever happens to the connector. It forwards to
 * the connector on the main thread only while `target` is set; the connector clears `target` (on the
 * main thread) as soon as it no longer wants callbacks.
 */
@interface SPPostgresConnectorProxy : NSObject <PGPostgresConnectionDelegate>
{
	SPPostgresConnector *target; // not retained; main thread only
	BOOL abandoned;              // guarded by @synchronized(self); read on the connect queue
}

@property (assign) SPPostgresConnector *target;

- (void)abandon;
- (BOOL)isAbandoned;

@end

@implementation SPPostgresConnectorProxy

@synthesize target;

- (void)abandon
{
	@synchronized (self) {
		abandoned = YES;
	}
	target = nil;
}

- (BOOL)isAbandoned
{
	@synchronized (self) {
		return abandoned;
	}
}

- (void)connectionEstablished:(PGPostgresConnection *)connection
{
	[target _postgresConnectionEstablished:connection];
}

- (void)connectionFailed:(PGPostgresConnection *)connection
{
	[target _postgresConnectionFailed:connection message:[connection connectionError]];
}

/// Called on the main thread when -connect could not even start the attempt.
- (void)connectionCouldNotStart:(NSArray *)connectionAndMessage
{
	[target _postgresConnectionFailed:[connectionAndMessage objectAtIndex:0] message:[connectionAndMessage count] > 1 ? [connectionAndMessage objectAtIndex:1] : nil];
}

- (void)sshTunnelStateChanged:(SPSSHTunnel *)theTunnel
{
	[target _sshTunnelStateChanged:theTunnel];
}

// Not used by the connector (and -connectionDisconnected: may arrive on the connect queue)
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values {}

@end

#pragma mark -

@implementation SPPostgresConnector
{
	SPPostgresFavorite *favorite;
	NSString *password;
	NSString *sshPassword;
	NSWindow *parentWindow;

	SPPostgresConnectorProxy *proxy;
	PGPostgresConnection *connection;
	SPSSHTunnel *tunnel;
	dispatch_queue_t connectQueue;

	void (^completion)(PGPostgresConnection *, NSError *);

	BOOL started;
	BOOL finished;
	BOOL postgresStarted;
}

@synthesize tunnel;

- (instancetype)initWithFavorite:(SPPostgresFavorite *)theFavorite password:(NSString *)thePassword sshPassword:(NSString *)theSSHPassword parentWindow:(NSWindow *)theParentWindow
{
	if ((self = [super init])) {
		favorite = [theFavorite copy];
		password = [thePassword copy];
		sshPassword = [theSSHPassword copy];
		parentWindow = [theParentWindow retain];

		proxy = [[SPPostgresConnectorProxy alloc] init];
		[proxy setTarget:self];

		// Serial: the connect call and any later -disconnect of the same connection never overlap
		connectQueue = dispatch_queue_create("com.sequelpro.postgres.connector", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (void)dealloc
{
	[proxy abandon];
	[self _closeTunnel];
	[self _closeConnectionWaiting:NO];

	// Released while an attempt was pending: the completion is still owed exactly one call. Deliver it
	// from a later main-queue turn (never from inside dealloc, nor re-entrantly). The block takes over
	// our reference to the completion.
	if (started && !finished && completion) {
		void (^theCompletion)(PGPostgresConnection *, NSError *) = completion;
		NSError *error = [[self class] _errorWithCode:SPPostgresErrorCancelled message:nil];
		dispatch_async(dispatch_get_main_queue(), ^{
			theCompletion(nil, error);
			[theCompletion release];
		});
	}
	else {
		[completion release];
	}
	completion = nil;

	[proxy release];
	dispatch_release(connectQueue);
	[favorite release];
	[password release];
	[sshPassword release];
	[parentWindow release];

	[super dealloc];
}

#pragma mark - Errors

+ (NSError *)_errorWithCode:(SPPostgresErrorCode)code message:(NSString *)message
{
	NSString *description = [message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![description length]) {
		switch (code) {
			case SPPostgresErrorSSHTunnelFailed: description = NSLocalizedString(@"The SSH tunnel could not be established.", @"PostgreSQL SSH tunnel failed without details"); break;
			case SPPostgresErrorNoSocket:        description = NSLocalizedString(@"No PostgreSQL socket was found.", @"PostgreSQL socket not found"); break;
			case SPPostgresErrorCancelled:       description = NSLocalizedString(@"The connection attempt was cancelled.", @"PostgreSQL connection cancelled"); break;
			default:                             description = NSLocalizedString(@"The connection to the PostgreSQL server failed.", @"PostgreSQL connection failed without details"); break;
		}
	}
	return [NSError errorWithDomain:SPPostgresErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - Connecting

- (void)connectWithCompletion:(void (^)(PGPostgresConnection *, NSError *))theCompletion
{
	if (![NSThread isMainThread]) {
		void (^copied)(PGPostgresConnection *, NSError *) = [[theCompletion copy] autorelease];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self connectWithCompletion:copied];
		});
		return;
	}

	if (started) {
		NSError *error = [[self class] _errorWithCode:SPPostgresErrorConnectionFailed message:NSLocalizedString(@"This connector has already been used to connect.", @"PostgreSQL connector reused")];
		void (^copied)(PGPostgresConnection *, NSError *) = [[theCompletion copy] autorelease];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (copied) copied(nil, error);
		});
		return;
	}

	started = YES;
	completion = [theCompletion copy];

	// -disconnect (or -cancel) before connecting: the connector is already shut down
	if ([proxy isAbandoned]) {
		[self _finishLaterWithError:[[self class] _errorWithCode:SPPostgresErrorCancelled message:nil]];
		return;
	}

	NSUInteger port = [favorite port] ? [favorite port] : SPPostgresDefaultPort;

	switch ([favorite type]) {
		case SPPostgresSocketConnection: {
			NSString *directory = nil;
			NSString *explicitPath = [[favorite socketPath] stringByExpandingTildeInPath];

			if ([explicitPath length]) {
				// Accept the socket file itself as well as its directory
				NSString *file = [explicitPath lastPathComponent];
				if ([file hasPrefix:@".s.PGSQL."]) {
					NSInteger filePort = [[file substringFromIndex:[@".s.PGSQL." length]] integerValue];
					if (filePort > 0) port = (NSUInteger)filePort;
					directory = [explicitPath stringByDeletingLastPathComponent];
				}
				else {
					directory = explicitPath;
				}
			}
			else {
				directory = [[self class] socketDirectoryForPort:port searchDirectories:[[self class] defaultSocketDirectories]];
			}

			if (!directory) {
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"No PostgreSQL socket for port %lu was found in %@. Enter the socket path in the connection settings.", @"PostgreSQL socket not found (port, directories)"), (unsigned long)port, [[[self class] defaultSocketDirectories] componentsJoinedByString:@", "]];
				[self _finishLaterWithError:[[self class] _errorWithCode:SPPostgresErrorNoSocket message:message]];
				return;
			}

			[self _startPostgresWithHost:directory port:port useSocket:YES];
			break;
		}
		case SPPostgresSSHConnection:
			[self _startTunnelToPort:port];
			break;
		case SPPostgresTCPIPConnection:
		default:
			[self _startPostgresWithHost:[favorite host] port:port useSocket:NO];
			break;
	}
}

- (void)_startPostgresWithHost:(NSString *)host port:(NSUInteger)port useSocket:(BOOL)useSocket
{
	postgresStarted = YES;

	PGPostgresConnection *theConnection = [[[PGPostgresConnection alloc] initWithDelegate:proxy] autorelease];
	objc_setAssociatedObject(theConnection, &SPPostgresConnectorProxyKey, proxy, OBJC_ASSOCIATION_RETAIN);

	// For a socket, libpq takes the socket directory as the host
	[theConnection setHost:host];
	[theConnection setPort:port];
	[theConnection setUseSocket:useSocket];
	if (useSocket) [theConnection setSocketPath:host];
	[theConnection setUser:[favorite user]];
	[theConnection setPassword:password];
	[theConnection setDatabase:[favorite database]];
	[theConnection setTimeout:SPPostgresConnectTimeout];
	[theConnection setApplicationName:SPPostgresApplicationName];

	[theConnection setSslMode:[favorite useSSL] ? @"require" : @"prefer"];
	if ([[favorite sslCACertPath] length]) [theConnection setSslRootCertPath:[[favorite sslCACertPath] stringByExpandingTildeInPath]];
	if ([[favorite sslCertPath] length]) [theConnection setSslCertPath:[[favorite sslCertPath] stringByExpandingTildeInPath]];
	if ([[favorite sslKeyPath] length]) [theConnection setSslKeyPath:[[favorite sslKeyPath] stringByExpandingTildeInPath]];

	connection = [theConnection retain];

	// -connect resolves the host name synchronously, so keep it off the main thread. The block only
	// captures the connection and the proxy, never the connector.
	SPPostgresConnectorProxy *theProxy = proxy;
	dispatch_async(connectQueue, ^{
		if ([theProxy isAbandoned]) return;

		if (![theConnection connect]) {
			NSArray *info = [NSArray arrayWithObjects:theConnection, [theConnection connectionError], nil];
			[theProxy performSelectorOnMainThread:@selector(connectionCouldNotStart:) withObject:info waitUntilDone:NO];
		}
	});
}

- (void)_startTunnelToPort:(NSUInteger)port
{
	SPSSHTunnel *theTunnel = nil;

	if ([[favorite sshHost] length] && [[favorite host] length]) {
		theTunnel = [[SPSSHTunnel alloc] initToHost:[favorite sshHost]
		                                       port:(NSInteger)[favorite sshPort]
		                                      login:[favorite sshUser]
		                           tunnellingToPort:(NSInteger)port
		                                     onHost:[favorite host]];
	}

	if (!theTunnel) {
		NSString *message = ([[favorite sshHost] length] && [[favorite host] length])
			? NSLocalizedString(@"The SSH tunnel could not be created.", @"PostgreSQL SSH tunnel could not be created")
			: NSLocalizedString(@"Enter both the SSH host and the PostgreSQL host.", @"PostgreSQL SSH connection missing host");
		[self _finishLaterWithError:[[self class] _errorWithCode:SPPostgresErrorSSHTunnelFailed message:message]];
		return;
	}

	tunnel = theTunnel;
	objc_setAssociatedObject(tunnel, &SPPostgresConnectorProxyKey, proxy, OBJC_ASSOCIATION_RETAIN);

	// Without a parent window the tunnel fails at once (reported through the state callback)
	if (parentWindow) [tunnel setParentWindow:parentWindow];

	if ([sshPassword length]) {
		[tunnel setPassword:sshPassword];
	}
	else if ([[favorite favoriteID] length]) {
		SPKeychain *keychain = [[SPKeychain alloc] init];
		if ([keychain passwordExistsForName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]]) {
			[tunnel setPasswordKeychainName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
		}
		[keychain release];
	}

	if ([[favorite sshKeyPath] length]) [tunnel setKeyFilePath:[favorite sshKeyPath]];

	[tunnel setConnectionStateChangeSelector:@selector(sshTunnelStateChanged:) delegate:proxy];

	// Launches ssh on a background thread; progress arrives through -_sshTunnelStateChanged:
	[tunnel connect];
}

#pragma mark - Callbacks (main thread, via the proxy)

- (void)_sshTunnelStateChanged:(SPSSHTunnel *)theTunnel
{
	if (finished || theTunnel != tunnel) return;

	// Mirrors SPConnectionController's -sshTunnelCallback:
	if ([theTunnel passwordPromptCancelled]) {
		[self _finishWithConnection:nil error:[[self class] _errorWithCode:SPPostgresErrorCancelled message:nil]];
		return;
	}

	SPMySQLConnectionProxyState state = [theTunnel state];

	if (state == SPMySQLProxyIdle) {
		[self _finishWithConnection:nil error:[[self class] _errorWithCode:SPPostgresErrorSSHTunnelFailed message:[theTunnel lastError]]];
	}
	else if (state == SPMySQLProxyConnected && !postgresStarted) {
		[self _startPostgresWithHost:@"127.0.0.1" port:[theTunnel localPort] useSocket:NO];
	}
}

- (void)_postgresConnectionEstablished:(PGPostgresConnection *)theConnection
{
	// A callback for an abandoned attempt (PostgresKit can deliver one after -disconnect)
	if (finished || theConnection != connection) return;

	[self _finishWithConnection:theConnection error:nil];
}

- (void)_postgresConnectionFailed:(PGPostgresConnection *)theConnection message:(NSString *)message
{
	if (finished || theConnection != connection) return;

	// The tunnel came up but could not reach the server: report the tunnel's explanation
	if (tunnel && [tunnel state] == SPMySQLProxyForwardingFailed && [[tunnel lastError] length]) {
		[self _finishWithConnection:nil error:[[self class] _errorWithCode:SPPostgresErrorSSHTunnelFailed message:[tunnel lastError]]];
		return;
	}

	[self _finishWithConnection:nil error:[[self class] _errorWithCode:SPPostgresErrorConnectionFailed message:message]];
}

#pragma mark - Finishing and tearing down

/// Reports an error from a later run loop turn, so the completion never runs inside -connectWithCompletion:.
- (void)_finishLaterWithError:(NSError *)error
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[self _finishWithConnection:nil error:error];
	});
}

/// Calls the completion (once). On failure the connection and tunnel are torn down first.
- (void)_finishWithConnection:(PGPostgresConnection *)theConnection error:(NSError *)error
{
	if (finished) return;
	finished = YES;

	// The completion may release the connector
	[[self retain] autorelease];

	if (error) {
		[proxy abandon];
		[self _closeTunnel];
		[self _closeConnectionWaiting:NO];
	}

	void (^theCompletion)(PGPostgresConnection *, NSError *) = completion;
	completion = nil;

	if (theCompletion) theCompletion(error ? nil : theConnection, error);
	[theCompletion release];
}

- (void)_closeTunnel
{
	if (!tunnel) return;

	SPSSHTunnel *theTunnel = tunnel;
	tunnel = nil;

	[theTunnel setConnectionStateChangeSelector:NULL delegate:nil];
	[theTunnel disconnect];

	// SPSSHTunnel's -disconnect does nothing if ssh has not been launched yet; it is launched moments after
	// -connect on the tunnel's thread. Repeat the disconnect once that window has passed.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[theTunnel disconnect];
	});

	[theTunnel release];
}

/// `wait`: block until the connection is closed (it waits for an in-flight -connect call to return).
- (void)_closeConnectionWaiting:(BOOL)wait
{
	if (!connection) return;

	PGPostgresConnection *theConnection = connection;
	connection = nil;

	// On the connect queue: after any pending -connect call, and never on PostgresKit's poller thread
	void (^close)(void) = ^{
		[theConnection disconnect];
	};

	if (wait) dispatch_sync(connectQueue, close);
	else dispatch_async(connectQueue, close);

	[theConnection release];
}

- (void)cancel
{
	if (!started) {
		// Shut down before connecting: a later -connectWithCompletion: completes with Cancelled
		[proxy abandon];
		return;
	}

	if (finished) {
		[self disconnect];
		return;
	}

	[self _finishWithConnection:nil error:[[self class] _errorWithCode:SPPostgresErrorCancelled message:nil]];
}

- (void)disconnect
{
	[[self retain] autorelease];

	// Close first (synchronously), then report a pending attempt as cancelled
	[proxy abandon];
	[self _closeConnectionWaiting:YES];
	[self _closeTunnel];

	if (started && !finished) {
		[self _finishWithConnection:nil error:[[self class] _errorWithCode:SPPostgresErrorCancelled message:nil]];
	}
}

#pragma mark - Sockets

+ (NSArray *)defaultSocketDirectories
{
	return @[@"/tmp", @"/var/run/postgresql", @"/opt/homebrew/var/run/postgresql"];
}

+ (NSString *)socketDirectoryForPort:(NSUInteger)port searchDirectories:(NSArray *)directories
{
	NSString *socketName = [NSString stringWithFormat:@".s.PGSQL.%lu", (unsigned long)port];
	NSFileManager *fileManager = [NSFileManager defaultManager];

	for (NSString *directory in directories) {
		if ([fileManager fileExistsAtPath:[directory stringByAppendingPathComponent:socketName]]) return directory;
	}

	return nil;
}

@end
