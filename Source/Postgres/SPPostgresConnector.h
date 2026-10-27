#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresFavorite;
@class SPSSHTunnel;

/**
 * Opens a PostgreSQL connection for a favorite: TCP/IP, Unix socket, or through an SSH tunnel,
 * with the favorite's SSL settings.
 *
 * Use from the main thread. The connector owns the session: keep it alive for as long as the
 * returned connection is in use. Releasing it (or calling -disconnect) closes the connection and
 * the SSH tunnel.
 */
__attribute__((visibility("default")))
@interface SPPostgresConnector : NSObject

/// `parentWindow` hosts the SSH tunnel's password/host-key sheets; required for SSH favorites.
- (instancetype)initWithFavorite:(SPPostgresFavorite *)favorite
						password:(NSString *)password
					 sshPassword:(NSString *)sshPassword
					parentWindow:(NSWindow *)parentWindow;

/**
 * Starts connecting. The completion is always called exactly once, on the main thread, and never
 * from within this call. On success `connection` is connected and `error` is nil; otherwise
 * `connection` is nil and `error` is in SPPostgresErrorDomain. The connector only starts once;
 * a second call completes with SPPostgresErrorConnectionFailed.
 */
- (void)connectWithCompletion:(void (^)(PGPostgresConnection *connection, NSError *error))completion;

/// Abandons a pending attempt: its completion is called (SPPostgresErrorCancelled) and the
/// half-open connection and tunnel are torn down without blocking the main thread.
/// After a successful connect this behaves like -disconnect.
- (void)cancel;

/// Closes the connection and the tunnel. A pending attempt is cancelled first (see -cancel).
- (void)disconnect;

@property (readonly) SPSSHTunnel *tunnel;

+ (NSArray *)defaultSocketDirectories;

/// The first directory in `directories` containing `.s.PGSQL.<port>`, or nil.
+ (NSString *)socketDirectoryForPort:(NSUInteger)port searchDirectories:(NSArray *)directories;

@end
