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
 */
+ (void)runOnDatabase:(NSString *)database
			 provider:(SPPostgresConnectionProvider)provider
				 work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work
		   completion:(void (^)(BOOL ok, NSError *error))completion;

/**
 * Keeps owner (e.g. the SPPostgresConnector that opened connection, with its SSH tunnel) alive until a job that runs
 * on connection ends; then, on the main thread, owner is sent -disconnect (when it responds to it) and released. For
 * providers that open a connection for a job. Call on the main thread.
 */
+ (void)keepOwner:(id)owner untilJobEndsOnConnection:(PGPostgresConnection *)connection;

@end
