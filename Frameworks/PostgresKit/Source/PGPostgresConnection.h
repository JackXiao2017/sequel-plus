//
//  PGPostgresConnection.h
//  PostgresKit
//
//  Copyright (c) 2008-2009 David Thorpe, djt@mutablelogic.com
//
//  Forked by the Sequel Pro Team on July 22, 2012.
// 
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not 
//  use this file except in compliance with the License. You may obtain a copy of 
//  the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software 
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
//  License for the specific language governing permissions and limitations under
//  the License.

#import "PGPostgresConnectionDelegate.h"
#import <pthread.h>

/**
 * The connection's transaction state (libpq's PQtransactionStatus).
 */
typedef enum
{
	PGPostgresTransactionIdle = 0,     // PQTRANS_IDLE: not in a transaction block
	PGPostgresTransactionActive,       // PQTRANS_ACTIVE: a command is in progress
	PGPostgresTransactionInTransaction,// PQTRANS_INTRANS: idle, in a valid transaction block
	PGPostgresTransactionInError,      // PQTRANS_INERROR: idle, in a failed transaction block
	PGPostgresTransactionUnknown       // PQTRANS_UNKNOWN: no (or a bad) connection
}
PGPostgresTransactionStatus;

/**
 * The domain of the NSErrors PGPostgresConnection returns (also declared in PGConstants.h).
 */
extern NSString *PGPostgresConnectionErrorDomain;

/**
 * Codes of the NSErrors in PGPostgresConnectionErrorDomain returned by -copyOut:handler:error: and
 * -copyIn:provider:error:.
 */
typedef enum
{
	PGConnectionErrorServer = 1,       // The server (or libpq) reported an error; the description holds its message
	PGConnectionErrorCancelled = 2,    // The caller cancelled the operation ("Cancelled.")
	PGConnectionErrorNotConnected = 3, // There is no usable connection
	PGConnectionErrorNotCopy = 4       // The statement isn't a COPY in the expected direction
}
PGConnectionErrorCode;

@class PGPostgresError;
@class PGPostgresResult;
@class PGPostgresStatement;
@class PGPostgresConnectionParameters;

/**
 * A libpq cancel handle (PGcancel) for one connection, from -[PGPostgresConnection newCancelToken]: lets another
 * thread interrupt the statement that connection is running (e.g. one waiting on a lock) without touching the
 * connection itself.
 */
@interface PGPostgresCancelToken : NSObject
{
	void *_cancel;
	pthread_mutex_t _lock;
}

/**
 * Asks the server to cancel whatever the connection is running (PQcancel). Callable from any thread, also after
 * -invalidate (it then does nothing). A request that reaches an idle connection is ignored by the server.
 * Blocks while it connects to the server to send the request.
 *
 * @return YES when the request was sent; NO after -invalidate or when it couldn't be sent.
 */
- (BOOL)cancel;

/// Frees the handle (PQfreeCancel); later -cancel calls do nothing. Callable from any thread, more than once.
- (void)invalidate;

@end

@interface PGPostgresConnection : NSObject 
{
	void *_connection;
	
	NSString *_host;
	NSString *_user;
	NSString *_database;
	NSString *_password;
	NSString *_socketPath;
	NSString *_encoding;
	NSString *_connectionError;
	NSString *_applicationName;
	NSString *_sslMode;
	NSString *_sslRootCertPath;
	NSString *_sslCertPath;
	NSString *_sslKeyPath;
	
	const char **_connectionParamNames;
	const char **_connectionParamValues;
	
	NSStringEncoding _stringEncoding;
	
	NSUInteger _port;
	NSUInteger _timeout;
	NSUInteger _keepAliveInterval;
	
	unsigned long long _lastQueryAffectedRowCount;
	
	BOOL _useSocket;
	BOOL _useKeepAlive;
	BOOL _lastQueryWasCancelled;
	BOOL _delegateSupportsWillExecute;
	BOOL _connecting;
	BOOL _disconnectRequested;
	BOOL _sessionPending;
	
	NSMutableDictionary *_typeMap;
	
	PGPostgresError *_lastError;
	PGPostgresConnectionParameters *_parameters;
	
	NSObject <PGPostgresConnectionDelegate> *_delegate;
}

@property (readwrite, assign) NSObject <PGPostgresConnectionDelegate> *delegate;

@property (readwrite, retain) NSString *host;
@property (readwrite, retain) NSString *user;
@property (readwrite, retain) NSString *database;
@property (readwrite, retain) NSString *password;
@property (readwrite, retain) NSString *socketPath;
@property (readwrite, retain) NSString *applicationName;

/**
 * @property The libpq 'sslmode' (disable, allow, prefer, require, verify-ca or verify-full).
 *           nil means libpq's default (currently 'prefer').
 */
@property (readwrite, retain) NSString *sslMode;

/**
 * @property Paths passed as libpq's 'sslrootcert', 'sslcert' and 'sslkey' parameters when non-nil.
 */
@property (readwrite, retain) NSString *sslRootCertPath;
@property (readwrite, retain) NSString *sslCertPath;
@property (readwrite, retain) NSString *sslKeyPath;

@property (readonly) NSString *encoding;
@property (readonly) NSString *connectionError;
@property (readonly) PGPostgresError *lastError;
@property (readonly) NSStringEncoding stringEncoding;
@property (readonly) PGPostgresConnectionParameters *parameters;

@property (readonly) unsigned long long lastQueryAffectedRowCount;

@property (readwrite, assign) BOOL useSocket;
@property (readwrite, assign) BOOL useKeepAlive;
@property (readwrite, assign) BOOL lastQueryWasCancelled;

@property (readwrite, assign) NSUInteger timeout;
@property (readwrite, assign) NSUInteger port;
@property (readwrite, assign) NSUInteger keepAliveInterval;

- (id)initWithDelegate:(NSObject <PGPostgresConnectionDelegate> *)delegate;

- (BOOL)connect;
- (void)disconnect;
- (BOOL)isConnected;

/**
 * libpq's most recent error message for the underlying connection (PQerrorMessage), e.g. why the server
 * closed it. nil when there is no underlying connection or no message. Use when not connecting.
 */
- (NSString *)libpqErrorMessage;

/**
 * Whether the session is idle, inside a transaction block, or inside a failed one (PQtransactionStatus).
 * PGPostgresTransactionUnknown when there is no usable connection.
 */
- (PGPostgresTransactionStatus)transactionStatus;
- (BOOL)reset;

- (NSUInteger)clientVersion;
- (NSUInteger)serverVersion;
- (NSUInteger)serverProcessId;

- (BOOL)cancelCurrentQuery:(NSError **)error;

/**
 * A cancel token for this connection (PQgetCancel), retained (release it), or nil when not connected. Call on the
 * thread that uses the connection; the token's -cancel may then be called from any thread while the connection runs
 * a statement. Invalidate it when the work on the connection has ended.
 */
- (PGPostgresCancelToken *)newCancelToken;

/**
 * The password hashed for role by libpq (PQencryptPasswordConn with the server's password_encryption, e.g.
 * "SCRAM-SHA-256$…" or "md5…"), for ALTER/CREATE ROLE … PASSWORD, so the plain password is never sent. libpq
 * may run SHOW password_encryption on the connection to choose the algorithm (not reported to the delegate).
 * nil when not connected or when hashing fails.
 */
- (NSString *)encryptedPassword:(NSString *)password forRole:(NSString *)role;

/**
 * Runs a COPY … TO STDOUT statement, calling handler with each row's bytes (in the COPY's format, line ending
 * included). Synchronous, on the caller's thread. The delegate's willExecute gets the statement only, never the data.
 *
 * Returning NO from handler cancels: the query is cancelled (PQcancel), the rest of the output is discarded, and the
 * method returns NO with a PGConnectionErrorCancelled error ("Cancelled."). A server error returns NO with a
 * PGConnectionErrorServer error holding the server's message (plus DETAIL and CONTEXT when present), also in
 * lastError. On success lastQueryAffectedRowCount holds the number of rows copied.
 */
- (BOOL)copyOut:(NSString *)sql handler:(BOOL (^)(NSData *chunk))handler error:(NSError **)error;

/**
 * Runs a COPY … FROM STDIN statement, sending the chunks provider returns (any split of the COPY data) until it
 * returns nil. Synchronous, on the caller's thread. The delegate's willExecute gets the statement only, never the data.
 *
 * Setting *cancel = YES ends the COPY with a failure (the server rolls it back) and returns NO with a
 * PGConnectionErrorCancelled error ("Cancelled."). A server error, e.g. bad data, returns NO with a
 * PGConnectionErrorServer error holding the server's message, DETAIL and CONTEXT (which names the line), also in
 * lastError. On success lastQueryAffectedRowCount holds the number of rows copied.
 */
- (BOOL)copyIn:(NSString *)sql provider:(NSData * (^)(BOOL *cancel))provider error:(NSError **)error;

@end
