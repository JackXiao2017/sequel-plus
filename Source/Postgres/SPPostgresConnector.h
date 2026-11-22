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
 * its own SSH tunnel (a connector sharing another's tunnel never closes that tunnel).
 */
__attribute__((visibility("default")))
@interface SPPostgresConnector : NSObject

/// `parentWindow` hosts the SSH tunnel's password/host-key sheets; required for SSH favorites.
- (instancetype)initWithFavorite:(SPPostgresFavorite *)favorite
						password:(NSString *)password
					 sshPassword:(NSString *)sshPassword
					parentWindow:(NSWindow *)parentWindow;

/**
 * A connector that reuses `other`'s SSH tunnel instead of opening one (so no second SSH prompt), with no parent
 * window. For an SSH favorite it connects to 127.0.0.1:<other's tunnel local port>; if `other` has no connected
 * tunnel the attempt fails with SPPostgresErrorSSHTunnelFailed. `other` (and so its tunnel) is retained until this
 * connector disconnects or is released; this connector's -disconnect/-cancel never close `other`'s tunnel (but
 * if `other` is disconnected explicitly, this connection loses its tunnel). For other favorites this is the
 * normal initializer with no SSH password and no parent window.
 */
- (instancetype)initWithFavorite:(SPPostgresFavorite *)favorite
						password:(NSString *)password
				 sharingTunnelOf:(SPPostgresConnector *)other;

/**
 * Starts connecting. The completion is always called exactly once, on the main thread, and never
 * from within this call. On success `connection` is connected and `error` is nil; otherwise
 * `connection` is nil and `error` is in SPPostgresErrorDomain. The connector only starts once;
 * a second call completes with SPPostgresErrorConnectionFailed.
 *
 * Nothing keeps the connector alive during an attempt: the caller owns it. If it is released while
 * the attempt is pending, the attempt is torn down and the completion is still called (once, on the
 * main thread, from a later run loop turn) with SPPostgresErrorCancelled. If -disconnect or -cancel
 * was called before this method, the completion is called with SPPostgresErrorCancelled.
 *
 * SPPostgresErrorPasswordRequired: the server asked for a password and none was given (detected in any server
 * language), or the one sent was rejected (detected only from the server's English "password authentication failed"
 * message; in another lc_messages language a wrong password is SPPostgresErrorConnectionFailed).
 */
- (void)connectWithCompletion:(void (^)(PGPostgresConnection *connection, NSError *error))completion;

/// Abandons a pending attempt: its completion is called (SPPostgresErrorCancelled) and the
/// half-open connection and tunnel are torn down without blocking the main thread.
/// After a successful connect this behaves like -disconnect.
- (void)cancel;

/// Closes the connection and the tunnel. A pending attempt is cancelled first (see -cancel).
- (void)disconnect;

/**
 * After the connection was found dead: makes sure the way to the server is open again before the connection is
 * re-established in place (PGPostgresConnection -reestablishConnection). Main thread; the completion is called once,
 * on the main thread, from a later run loop turn.
 *
 * Not an SSH favorite, or its tunnel is still connected (and not force): nil. force replaces its own tunnel even when it
 * reports connected (after sleep or a network change ssh can take minutes to notice its link is gone). A connector sharing another's tunnel never opens one: nil
 * when that tunnel is connected (the connection follows its local port), else SPPostgresErrorSSHTunnelFailed. Its own
 * tunnel down: a new tunnel is opened as the first connect opened it (password or keychain, key file; its sheets on
 * window), and once it is connected the connection's host and port become 127.0.0.1 and the new local port, then nil.
 * A failed tunnel completes with SPPostgresErrorSSHTunnelFailed, a cancelled password prompt (or -disconnect)
 * with SPPostgresErrorCancelled.
 */
- (void)reopenTunnelOnWindow:(NSWindow *)window force:(BOOL)force completion:(void (^)(NSError *error))completion;

@property (readonly) SPSSHTunnel *tunnel;

/// The window the SSH tunnel's sheets are shown on while connecting (nil once the attempt is over).
@property (readonly) NSWindow *parentWindow;

/// The database and SSH passwords this connector was given (nil if none), e.g. to open another
/// session for the same favorite without asking again.
@property (readonly, copy) NSString *password;
@property (readonly, copy) NSString *sshPassword;

+ (NSArray *)defaultSocketDirectories;

/// The first directory in `directories` containing `.s.PGSQL.<port>`, or nil.
+ (NSString *)socketDirectoryForPort:(NSUInteger)port searchDirectories:(NSArray *)directories;

@end
