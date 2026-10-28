#import <Foundation/Foundation.h>

@class PGPostgresConnection;

typedef NS_ENUM(NSInteger, SPPostgresTransferMode) {
	/// Everything in the target database is removed first (every extension but plpgsql, every schema), then public is
	/// recreated as a fresh database has it.
	SPPostgresTransferEmptyTarget = 0,
	/// The copy's objects that already exist on the target are dropped and created again; nothing else is touched.
	SPPostgresTransferOverwrite = 1
};

typedef NS_ENUM(NSInteger, SPPostgresTransferPhase) {
	SPPostgresTransferChecking = 0,
	SPPostgresTransferReading = 1,
	SPPostgresTransferWriting = 2
};

/**
 * Copies a whole database, or some tables with what they need, from one Postgres connection to another, through a
 * temporary SQL dump: SPPostgresDumpWriter reads the source into the file (in one snapshot), then
 * SPPostgresSQLImporter loads it into the target in one transaction, preceded by the mode's emptying or dropping
 * statements. A failure or cancel anywhere leaves the target unchanged; the file is deleted on every path.
 *
 * Both connections must be idle (no transaction open) and are used only by this object while -run: runs. The load
 * leaves the target session's search_path empty (the dump sets it, as pg_dump's does): disconnect it afterwards.
 */
__attribute__((visibility("default")))
@interface SPPostgresTransfer : NSObject
{
	PGPostgresConnection *source;
	PGPostgresConnection *target;
	BOOL wholeDatabase;
	NSArray *tables;
	SPPostgresTransferMode mode;
	NSString *temporaryDirectory;
	BOOL (^progress)(SPPostgresTransferPhase phase, double fraction, NSString *detail);

	NSUInteger tablesCopied;
	NSArray *replacedObjects;
	NSArray *dependenciesCreated;
	NSArray *foreignTablesSkipped;
	NSArray *skippedSettings;
}

- (instancetype)initWithSource:(PGPostgresConnection *)source target:(PGPostgresConnection *)target;

/// The scope: set exactly one (the whole database, or @[schema, table] pairs with their dependencies).
@property BOOL wholeDatabase;
@property (copy) NSArray *tables;

/// Default SPPostgresTransferEmptyTarget.
@property SPPostgresTransferMode mode;

/// Where the dump is written (sequel-pro-transfer-<UUID>.sql); default NSTemporaryDirectory().
@property (copy) NSString *temporaryDirectory;

/**
 * Called on the caller's thread: Checking (fraction 0, detail nil) while the source and target are checked; Reading
 * before each table's data and during long COPYs (fraction (tableIndex - 1) / tableCount, detail the table's name);
 * Writing while the dump loads (fraction bytes read / dump size, detail nil). Returning NO cancels.
 */
@property (copy) BOOL (^progress)(SPPostgresTransferPhase phase, double fraction, NSString *detail);

/**
 * Runs the transfer, synchronously: same-database check, the copy's objects and dependencies on the source, the
 * extension check, the copy's objects existing on the target, (Overwrite) a dry run of the drops (BEGIN, drops,
 * ROLLBACK), the dump to the temporary file, the load (in one transaction, the mode's statements first), and the
 * file's deletion. NO with an error in SPPostgresErrorDomain: SPPostgresErrorTransferRefused (the same database;
 * missing extensions, named under SPPostgresObjectsErrorKey), SPPostgresErrorHasDependents (the dry run: the
 * server's DETAIL lines under SPPostgresDependentsErrorKey), SPPostgresErrorCancelled, SPPostgresErrorInvalidSettings,
 * or the writer's or importer's error unchanged.
 */
- (BOOL)run:(NSError **)error;

/// Results of the last successful -run:.
/// Tables and partitions whose data the dump wrote (one COPY block each; partitioned parents hold none).
@property (readonly) NSUInteger tablesCopied;
/// The target's objects that were dropped and created again (Overwrite), as displayName strings in drop order.
@property (readonly) NSArray *replacedObjects;
/// The dependencies of a table copy the transfer created (those already on the target are reused), as displayNames.
@property (readonly) NSArray *dependenciesCreated;
/// The foreign tables left out of the copy, as @[schema, table] pairs (the writer's foreignTablesSkipped).
@property (readonly) NSArray *foreignTablesSkipped;
/// Settings the target didn't know (the importer's skippedSettings).
@property (readonly) NSArray *skippedSettings;

/// The names in the target's pg_available_extensions (installed extensions are always listed there). Called once
/// per run; a test seam.
- (NSArray *)availableExtensionsOnTarget:(NSError **)error;

/// Empty mode's statements: DROP EXTENSION … CASCADE (none when extensions is empty), DROP SCHEMA … CASCADE (none
/// when schemas is empty), then public as a fresh database of that server version has it. For tests.
+ (NSArray *)emptyingStatementsForSchemas:(NSArray *)schemas extensions:(NSArray *)extensions serverVersion:(NSInteger)versionNumber;

/// Overwrite mode's statements for SPPostgresDumpObjects carrying the target's kinds: one DROP … IF EXISTS per kind
/// (RESTRICT), in the order materialized views, views, foreign tables, tables, sequences, routines, domains, types
/// (extensions are never dropped). For tests.
+ (NSArray *)dropStatementsForObjects:(NSArray *)targetObjects;

@end
