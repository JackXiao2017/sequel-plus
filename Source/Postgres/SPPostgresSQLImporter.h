#import <Foundation/Foundation.h>

@class PGPostgresConnection;
@class SPPostgresDumpReader;
@class SPPostgresDumpItem;

/// What to do after a statement fails when each statement runs on its own.
typedef NS_ENUM(NSInteger, SPPostgresImportErrorChoice) {
	SPPostgresImportStop = 0,
	SPPostgresImportIgnore = 1,
	SPPostgresImportIgnoreAll = 2
};

/**
 * Runs a SQL dump read by an SPPostgresDumpReader on a connection of its own (statements through
 * SPPostgresExecuteWithDetails, COPY … FROM stdin blocks through -copyIn:provider:error:). Synchronous, on the
 * caller's thread (a background one in the app).
 *
 * psql meta-commands: \restrict and \unrestrict (pg_dump 17.6+/18) are skipped; any other stops the import.
 * In single-transaction mode everything runs between BEGIN and COMMIT (the dump's own BEGIN / COMMIT lines are
 * skipped) and the first error, or a cancel, rolls everything back. Otherwise each statement commits on its own and
 * errorHandler decides what happens after a failed one.
 */
__attribute__((visibility("default")))
@interface SPPostgresSQLImporter : NSObject
{
	PGPostgresConnection *connection;
	SPPostgresDumpReader *reader;
	BOOL singleTransaction;
	SPPostgresImportErrorChoice (^errorHandler)(NSError *error, SPPostgresDumpItem *item);
	BOOL (^progress)(unsigned long long bytesRead, unsigned long long fileSize);
	NSUInteger statementsRun;
	NSUInteger errorsIgnored;
	NSMutableArray *skippedSettings;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection reader:(SPPostgresDumpReader *)reader;

/// Default YES.
@property BOOL singleTransaction;

/// Asked after a failed item when singleTransaction is NO (error as -run: would report it). nil means Stop.
@property (copy) SPPostgresImportErrorChoice (^errorHandler)(NSError *error, SPPostgresDumpItem *item);

/// Called after each item and each chunk of COPY data; returning NO cancels. Also asked after a failed item: NO then
/// reports the cancel (e.g. a statement interrupted by the cancel) instead of the server's error.
@property (copy) BOOL (^progress)(unsigned long long bytesRead, unsigned long long fileSize);

/**
 * Runs every item. NO with an error (SPPostgresErrorDomain) on failure: SPPostgresErrorQueryFailed, its message
 * "Line <n>: <server message>" followed by the server's DETAIL, HINT and CONTEXT lines, or SPPostgresErrorCancelled.
 */
- (BOOL)run:(NSError **)error;

/// Statements (and COPY blocks) that ran successfully, and failures the error handler chose to ignore.
@property (readonly) NSUInteger statementsRun;
@property (readonly) NSUInteger errorsIgnored;

/**
 * A top-level `SET name …` or `SELECT pg_catalog.set_config('name', …)` naming a configuration parameter this server
 * doesn't know (SQLSTATE 42704, e.g. a newer pg_dump's `SET transaction_timeout = 0;` on PG 12–16) is skipped, not an
 * error; inside a transaction it runs under a savepoint so the failure doesn't abort the transaction.
 * settingsSkipped counts them; skippedSettings names them (each once, in file order).
 */
@property (readonly) NSUInteger settingsSkipped;
@property (readonly) NSArray *skippedSettings;

@end
