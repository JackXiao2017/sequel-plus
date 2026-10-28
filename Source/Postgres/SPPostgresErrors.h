#import <Foundation/Foundation.h>

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
	/// A column was not dropped because other objects (views, indexes, constraints, foreign keys of other
	/// tables, …) depend on it. Nothing was sent; the dependents are listed under SPPostgresDependentsErrorKey.
	SPPostgresErrorHasDependents = 9
};

/// userInfo key of SPPostgresErrorHasDependents: an NSArray of NSString, one description per dependent object.
extern NSString * const SPPostgresDependentsErrorKey __attribute__((visibility("default")));
