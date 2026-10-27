#import <Foundation/Foundation.h>
#import <PostgresKit/PostgresKit.h>

@class PGPostgresConnection;

/**
 * Shows the queries a PostgreSQL connection runs in the shared query console (SPQueryController),
 * labelled with the favorite name and database, when console logging is enabled in the preferences.
 *
 * PGPostgresConnection has a single delegate, and connections opened by SPPostgresConnector use the
 * connector's own callback proxy. -attachToConnection: therefore inserts the logger in front of the
 * connection's current delegate: every callback is passed on to that delegate unchanged, and
 * connection:willExecute:withValues: is also logged. The connection keeps the logger (and the
 * delegate it forwards to) alive for as long as the connection itself.
 */
__attribute__((visibility("default")))
@interface SPPostgresConsoleLogger : NSObject <PGPostgresConnectionDelegate>

- (instancetype)initWithConnectionName:(NSString *)connectionName database:(NSString *)database;

@property (readonly, copy) NSString *connectionName;
@property (readonly, copy) NSString *database;

/// The delegate callbacks are passed on to (the connection's delegate when the logger was attached).
@property (readonly, retain) NSObject<PGPostgresConnectionDelegate> *nextDelegate;

/**
 * Becomes the connection's delegate, forwarding to the previous one. Call on the main thread, once.
 * PostgresKit decides at init whether its delegate wants willExecute callbacks, so queries are only
 * reported for connections created with such a delegate (all connections from SPPostgresConnector are).
 */
- (void)attachToConnection:(PGPostgresConnection *)connection;

/// The logger attached to connection (see -attachToConnection:), or nil.
+ (SPPostgresConsoleLogger *)loggerForConnection:(PGPostgresConnection *)connection;

/**
 * YES while the Query view runs the user's statements (set and reset on the main thread around the run): they
 * are logged as MySQL logs custom queries (the custom query logging preference) instead of as interface queries.
 */
@property (assign) BOOL loggingCustomQueries;

/// Shows a query error in the console, labelled as the queries, when error logging is enabled (as MySQL's).
- (void)logError:(NSString *)error;

@end
