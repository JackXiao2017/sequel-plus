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
	SPPostgresErrorQueryFailed = 5
};
