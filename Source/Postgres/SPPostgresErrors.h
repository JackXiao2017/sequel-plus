#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Error domain for the PostgreSQL side of Sequel Pro.
extern NSString * const SPPostgresErrorDomain __attribute__((visibility("default")));

typedef NS_ENUM(NSInteger, SPPostgresErrorCode) {
	/// The server could not be reached, refused the connection, or rejected the login/SSL settings.
	SPPostgresErrorConnectionFailed = 1,
	/// The SSH tunnel could not be established (or broke while connecting).
	SPPostgresErrorSSHTunnelFailed = 2,
	/// A socket connection was requested but no socket file was found.
	SPPostgresErrorNoSocket = 3,
	/// The attempt was cancelled (by -cancel/-disconnect, or by dismissing the SSH password prompt).
	SPPostgresErrorCancelled = 4,
	/// A catalog or other query failed on the server (the server's message is the localized description).
	SPPostgresErrorQueryFailed = 5,
	/// The connection form is missing required details (e.g. a TCP/IP favorite without a host).
	SPPostgresErrorInvalidSettings = 6,
	/// An edit affected no rows: the row was changed or deleted by someone else since it was read.
	/// (The stage-2 plan named this code 6, which was already taken by SPPostgresErrorInvalidSettings.)
	SPPostgresErrorRowChanged = 7,
	/// An edit was refused before any SQL was sent: the relation is read-only (a view, or a table without
	/// a primary key). The read-only reason is the localized description.
	SPPostgresErrorNotEditable = 8,
	/// An object (a column, a sequence, an extension, …) was not dropped because other objects depend on it.
	/// Nothing was changed: either the dependents were found first and nothing was sent, or the DROP was sent and
	/// rolled back (an extension: the server's DETAIL). The dependents are listed under SPPostgresDependentsErrorKey.
	SPPostgresErrorHasDependents = 9,
	/// A transfer (SPPostgresTransfer) refused to start, before changing anything: the localized description says why
	/// (the target is the database being copied, or extensions the copy needs aren't available on the target); the
	/// objects concerned, if any, are listed under SPPostgresObjectsErrorKey.
	SPPostgresErrorTransferRefused = 10,
	/// The server wants a password and none was given, or the one given was rejected ("password authentication
	/// failed"). The server's message is the localized description; asking for the password and retrying can succeed.
	SPPostgresErrorPasswordRequired = 11
};

/// userInfo key of SPPostgresErrorHasDependents: an NSArray of NSString, one description per dependent object.
extern NSString * const SPPostgresDependentsErrorKey __attribute__((visibility("default")));

/// userInfo key of SPPostgresErrorTransferRefused: an NSArray of NSString, the objects concerned (e.g. extension names).
extern NSString * const SPPostgresObjectsErrorKey __attribute__((visibility("default")));

/// userInfo key of an SPPostgresErrorQueryFailed error the server reported: its SQLSTATE (NSString, e.g. @"42804").
extern NSString * const SPPostgresSQLStateErrorKey __attribute__((visibility("default")));

/// An error in SPPostgresErrorDomain with message as its localized description, plus userInfo's entries (may be nil).
extern NSError *SPPostgresMakeError(NSInteger code, NSString *message, NSDictionary *userInfo) __attribute__((visibility("default")));

/**
 * For a failed DROP: when serverError is the server's dependency refusal (SQLSTATE 2BP01) returns an
 * SPPostgresErrorHasDependents error whose SPPostgresDependentsErrorKey lists the DETAIL lines of connection's last
 * error (read now, so call it before the savepoint or transaction is rolled back), with messageOrNil as its
 * description (nil: serverError's own message). Any other serverError is returned unchanged.
 */
extern NSError *SPPostgresDependentsError(PGPostgresConnection *connection, NSError *serverError, NSString *messageOrNil) __attribute__((visibility("default")));
