#import <Foundation/Foundation.h>
#import "SPPostgresDocument.h"

@class PGPostgresConnection;

/**
 * Runs a piece of work (an export, an import) on a background thread, on a connection of its own that the
 * provider (SPPostgresDocument's connectionProvider) hands out, never the tab's: the user's session, its
 * transaction and its search_path stay untouched, and the window stays responsive.
 */
__attribute__((visibility("default")))
@interface SPPostgresBackgroundJob : NSObject

/**
 * Call on the main thread. Asks provider for a connection to database (on the main thread), then calls work on a
 * background thread with it. After work returns, the connection is disconnected (it is never reused: after a cancel a
 * late cancel request could still reach it), and completion is called on the main thread, always from a later run
 * loop turn: ok is what work returned, error what it set (or the provider's error, when no connection could be had;
 * work isn't called then). A provider that calls its completion more than once is only listened to the first time.
 * Returns the job (autoreleased; keep it to -cancel it while it waits for its connection).
 */
+ (instancetype)runOnDatabase:(NSString *)database
					 provider:(SPPostgresConnectionProvider)provider
						 work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work
				   completion:(void (^)(BOOL ok, NSError *error))completion;

/**
 * The same with two connections (a Transfer: the source, then the target). Call on the main thread. provider is asked
 * for a connection to database first; targetProvider is asked for one to targetDatabase only once the source
 * connection has arrived (so a second SSH prompt never comes while the first is up). work then gets both, on a
 * background thread; afterwards both are disconnected, and completion is called as above. If either provider fails,
 * work isn't called, a connection already handed out is disconnected (its owner released), and completion gets that
 * provider's error. Each provider is only listened to the first time it answers.
 */
+ (instancetype)runOnDatabase:(NSString *)database
					 provider:(SPPostgresConnectionProvider)provider
			   targetDatabase:(NSString *)targetDatabase
			   targetProvider:(SPPostgresConnectionProvider)targetProvider
						 work:(BOOL (^)(PGPostgresConnection *connection, PGPostgresConnection *target, NSError **error))work
				   completion:(void (^)(BOOL ok, NSError *error))completion;

/// YES until the provider has answered (or the job was cancelled before it did); with two connections, until both
/// arrived. Main thread.
@property (readonly) BOOL waitingForConnection;

/**
 * While the job waits for its connection: completion is called at once (from a later run loop turn) with NO and
 * SPPostgresErrorCancelled, work is never called, and a connection the provider hands out later is disconnected
 * unused (its owner released). With two connections, a source connection that already arrived is disconnected too.
 *
 * Once work runs: the statement the job's connection is running is interrupted (PQcancel through a cancel token the
 * job takes on its own thread before work starts), and the request is sent again every second until work returns,
 * so a statement waiting on a lock, or a long one, ends. With two connections, both get a token and both are
 * interrupted. work still checks its own cancel flag (set it before calling this) and reports the cancel. Main thread.
 */
- (void)cancel;

/**
 * Keeps owner (e.g. the SPPostgresConnector that opened connection, with its SSH tunnel) alive until a job that runs
 * on connection ends; then, on the main thread, owner is sent -disconnect (when it responds to it) and released. For
 * providers that open a connection for a job. Call on the main thread.
 */
+ (void)keepOwner:(id)owner untilJobEndsOnConnection:(PGPostgresConnection *)connection;

@end
