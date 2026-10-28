#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// One extension installed in the current database (pg_extension, with pg_available_extensions' comment and
/// default version).
__attribute__((visibility("default")))
@interface SPPostgresExtension : NSObject
{
	NSString *_name;
	NSString *_version;
	NSString *_schema;
	NSString *_comment;
	BOOL _relocatable;
	NSString *_defaultVersion;
	NSArray *_requiredBy;
}

@property (readonly, copy) NSString *name;
/// The installed version.
@property (readonly, copy) NSString *version;
/// The schema its objects are in.
@property (readonly, copy) NSString *schema;
/// pg_available_extensions.comment, nil if none (or when its control file is gone).
@property (readonly, copy) NSString *comment;
@property (readonly) BOOL relocatable;
/// The server's default version for it, nil when its control file is gone.
@property (readonly, copy) NSString *defaultVersion;
/// The names of installed extensions that require it, sorted.
@property (readonly, copy) NSArray *requiredBy;

@end

/// One extension the server offers that is not installed in the current database.
__attribute__((visibility("default")))
@interface SPPostgresAvailableExtension : NSObject
{
	NSString *_name;
	NSString *_defaultVersion;
	NSString *_comment;
	NSArray *_versions;
	NSString *_fixedSchema;
}

@property (readonly, copy) NSString *name;
@property (readonly, copy) NSString *defaultVersion;
/// nil if none.
@property (readonly, copy) NSString *comment;
/// Every available version, sorted as version numbers (NSNumericSearch: 1.10 after 1.9).
@property (readonly, copy) NSArray *versions;
/// The schema the control file fixes for the default version (it can't go anywhere else), nil if none.
@property (readonly, copy) NSString *fixedSchema;

@end

/**
 * Reads and changes the extensions of the connection's database. Every change runs through
 * SPPostgresRunStructureChange (savepoint sp_structure inside the user's transaction, lock_timeout = lockTimeout),
 * so a failure leaves everything as it was and the user's transaction open; inside an aborted transaction nothing
 * is sent. Extension names are quoted with SPPostgresQuoteIdentifier, versions with SPPostgresQuoteLiteral; reads
 * use $n parameters. Never cascades. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresExtensions : NSObject
{
	PGPostgresConnection *_connection;
	NSTimeInterval _lockTimeout;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Seconds a change waits for a lock held elsewhere before it fails (default 5; 0: no limit).
@property NSTimeInterval lockTimeout;

/// The installed extensions (SPPostgresExtension), sorted by name; nil on failure.
- (NSArray *)installedExtensions:(NSError **)error;

/// The installed extension, nil with a nil error when it isn't installed, nil with an error on failure.
- (SPPostgresExtension *)extensionNamed:(NSString *)name error:(NSError **)error;

/// The extensions the server offers that are not installed (SPPostgresAvailableExtension), sorted by name; nil on
/// failure.
- (NSArray *)availableExtensions:(NSError **)error;

/// The versions the installed extension can be updated to (pg_extension_update_paths from the installed version,
/// with a path), sorted as version numbers (NSNumericSearch: 1.10 after 1.9); empty when there are none or it isn't installed, nil on failure.
- (NSArray *)updateTargetsForExtension:(NSString *)name error:(NSError **)error;

/**
 * The extensions that installing name at version (nil: its default) needs and are not installed, found
 * transitively from pg_available_extension_versions.requires (each requirement at its default version), in install
 * order: dependencies first, no duplicates. nil on failure.
 */
- (NSArray *)missingRequirementsForExtension:(NSString *)name version:(NSString *)version error:(NSError **)error;

/**
 * CREATE EXTENSION for each missing requirement (at its default version), then for name, all or nothing, without
 * CASCADE. VERSION '<v>' is sent only when version is given and differs from the default; WITH SCHEMA "<s>" only
 * when schema is given and the extension's control file doesn't fix one (for requirements too).
 */
- (BOOL)installExtension:(NSString *)name version:(NSString *)version schema:(NSString *)schema error:(NSError **)error;

/// ALTER EXTENSION "name" UPDATE TO '<version>'.
- (BOOL)updateExtension:(NSString *)name toVersion:(NSString *)version error:(NSError **)error;

/**
 * DROP EXTENSION "name", without CASCADE. When other objects depend on it (SQLSTATE 2BP01) the error is
 * SPPostgresErrorHasDependents, "\"name\" can't be dropped because other objects depend on it.", with the server's
 * DETAIL lines under SPPostgresDependentsErrorKey; other errors carry the server's message with DETAIL and HINT.
 */
- (BOOL)dropExtension:(NSString *)name error:(NSError **)error;

@end
