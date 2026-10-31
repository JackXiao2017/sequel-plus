//
//  PGPostgresConnection.m
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

#import "PGPostgresConnection.h"
#import "PGPostgresConnectionParameters.h"
#import "PGPostgresConnectionTypeHandling.h"
#import "PGPostgresKitPrivateAPI.h"
#import "PGPostgresTypeHandlerProtocol.h"
#import "PGPostgresTypeNumberHandler.h"
#import "PGPostgresTypeStringHandler.h"
#import "PGPostgresException.h"
#import "PGPostgresStatement.h"
#import "PGPostgresResult.h"
#import "PGPostgresError.h"

#import <pthread.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>

@interface PGPostgresConnection ()

- (void)_loadDatabaseParameters;
- (void)_createConnectionParameters;
- (void)_pollConnection:(NSNumber *)isReset;
- (void)_setConnectionError:(NSString *)error;
- (NSString *)_applySessionSettings;
- (PGresult *)_startCopy:(NSString *)sql expecting:(ExecStatusType)expected error:(NSError **)error;
- (BOOL)_finishCopyCancelled:(BOOL)cancelled error:(NSError **)error;
- (void)_setLastErrorFromResult:(PGresult *)result;

// libpq callback
static void _PGPostgresConnectionNoticeProcessor(void *arg, const char *message);

@end

@implementation PGPostgresCancelToken

- (id)initWithCancel:(PGcancel *)cancel
{
	if ((self = [super init])) {
		_cancel = cancel;
		pthread_mutex_init(&_lock, NULL);
	}
	
	return self;
}

- (BOOL)cancel
{
	BOOL sent = NO;
	
	// The lock keeps -invalidate from freeing the handle while a request is being sent
	pthread_mutex_lock(&_lock);
	
	if (_cancel) {
		char errorBuf[256];
		
		sent = PQcancel((PGcancel *)_cancel, errorBuf, (int)sizeof(errorBuf)) == 1;
	}
	
	pthread_mutex_unlock(&_lock);
	
	return sent;
}

- (void)invalidate
{
	pthread_mutex_lock(&_lock);
	
	if (_cancel) PQfreeCancel((PGcancel *)_cancel);
	
	_cancel = NULL;
	
	pthread_mutex_unlock(&_lock);
}

- (void)dealloc
{
	[self invalidate];
	
	pthread_mutex_destroy(&_lock);
	
	[super dealloc];
}

@end

@implementation PGPostgresConnection

@synthesize port = _port;
@synthesize host = _host;
@synthesize user = _user;
@synthesize database = _database;
@synthesize password = _password;
@synthesize useSocket = _useSocket;
@synthesize socketPath = _socketPath;
@synthesize delegate = _delegate;
@synthesize timeout = _timeout;
@synthesize useKeepAlive = _useKeepAlive;
@synthesize keepAliveInterval = _keepAliveInterval;
@synthesize lastQueryWasCancelled = _lastQueryWasCancelled;
@synthesize lastError = _lastError;
@synthesize encoding = _encoding;
@synthesize stringEncoding = _stringEncoding;
@synthesize parameters = _parameters;
@synthesize applicationName = _applicationName;
@synthesize sslMode = _sslMode;
@synthesize sslRootCertPath = _sslRootCertPath;
@synthesize sslCertPath = _sslCertPath;
@synthesize sslKeyPath = _sslKeyPath;
@synthesize lastQueryAffectedRowCount = _lastQueryAffectedRowCount;

#pragma mark -
#pragma mark Initialisation

- (id)init 
{
	return [self initWithDelegate:nil];
}

/**
 * Initialise a new connection with the supplied delegate.
 *
 * @param delegate The delegate this connection should use.
 *
 * @return The new connection instance.
 */
- (id)initWithDelegate:(NSObject <PGPostgresConnectionDelegate> *)delegate
{
	if ((self = [super init])) {
		
		_delegate = delegate;
		
		_port = PGPostgresConnectionDefaultServerPort;
		_timeout = PGPostgresConnectionDefaultTimeout;
		
		_useKeepAlive = YES;
		_keepAliveInterval = PGPostgresConnectionDefaultKeepAlive;
		
		_lastQueryAffectedRowCount = 0;
		
		_lastError = nil;
		_connection = nil;
		_connectionError = nil;
		_lastQueryWasCancelled = NO;
		
		_stringEncoding = PGPostgresConnectionDefaultStringEncoding;
		_encoding = [NSString stringWithString:PGPostgresConnectionDefaultEncoding];
		
		_delegateSupportsWillExecute = [_delegate respondsToSelector:@selector(connection:willExecute:withValues:)];
		
		_typeMap = [[NSMutableDictionary alloc] init];
		
		[self registerTypeHandlers];
	}
	
	return self;
}

#pragma mark -
#pragma mark Accessors

/**
 * The description of the last connection failure, or nil. Safe to read while the background
 * connection poll is running.
 */
- (NSString *)connectionError
{
	@synchronized (self) {
		return [[_connectionError retain] autorelease];
	}
}

- (BOOL)connectionNeededPassword
{
	@synchronized (self) {
		return _connectionNeededPassword;
	}
}

- (BOOL)connectionUsedPassword
{
	@synchronized (self) {
		return _connectionUsedPassword;
	}
}

/// Records libpq's password flags for a failed attempt (or clears them when conn is NULL). Call while the
/// PGconn is still valid and owned by the caller.
- (void)_recordPasswordFlagsOf:(PGconn *)conn
{
	BOOL needed = conn ? (PQconnectionNeedsPassword(conn) == 1) : NO;
	BOOL used = conn ? (PQconnectionUsedPassword(conn) == 1) : NO;

	@synchronized (self) {
		_connectionNeededPassword = needed;
		_connectionUsedPassword = used;
	}
}

- (void)_setConnectionError:(NSString *)error
{
	@synchronized (self) {
		[error retain];
		[_connectionError release];
		_connectionError = error;
	}
}

/**
 * Get the underlying connection associated with this wrapper.
 *
 * @return The PGConn instance.
 */
- (PGconn *)postgresConnection
{
	return _connection;
}

#pragma mark -
#pragma mark Connection Handling

/**
 * Does this connection have an underlying connection established with the server.
 *
 * @return A BOOL indicating the result of the query.
 */
- (BOOL)isConnected 
{
	// Not connected until the background poll has applied the session settings, so callers never
	// query the PGconn concurrently with the poller.
	@synchronized (self) {
		if (_sessionPending) return NO;
	}
	
	if (!_connection) return NO;
	
	return PQstatus(_connection) == CONNECTION_OK;
}

- (PGPostgresTransactionStatus)transactionStatus
{
	if (![self isConnected]) return PGPostgresTransactionUnknown;
	
	switch (PQtransactionStatus(_connection))
	{
		case PQTRANS_IDLE:    return PGPostgresTransactionIdle;
		case PQTRANS_ACTIVE:  return PGPostgresTransactionActive;
		case PQTRANS_INTRANS: return PGPostgresTransactionInTransaction;
		case PQTRANS_INERROR: return PGPostgresTransactionInError;
		default:              return PGPostgresTransactionUnknown;
	}
}

- (NSString *)libpqErrorMessage
{
	if (!_connection) return nil;
	
	const char *message = PQerrorMessage(_connection);
	
	if (!message || !*message) return nil;
	
	NSString *string = [[NSString stringWithUTF8String:message] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	
	return [string length] ? string : nil;
}

/**
 * Attempts to disconnect the underlying connection with the server.
 */
- (void)disconnect 
{
	if (!_connection) return;
	
	// If a connection attempt is still being polled on the background thread, ask it to stop 
	// and wait for it to let go of the PGconn before freeing it.
	@synchronized (self) {
		if (_connecting) _disconnectRequested = YES;
	}
	
	for (;;)
	{
		@synchronized (self) {
			if (!_connecting) break;
		}
		
		usleep(5000);
	}
	
	@synchronized (self) {
		_disconnectRequested = NO;
	}
	
	[self cancelCurrentQuery:nil];
	
	PQfinish(_connection);
	
	_connection = nil;
	
	if (_delegate && [_delegate respondsToSelector:@selector(connectionDisconnected:)]) {
		[_delegate connectionDisconnected:self];
	}
}

/**
 * Initiates the underlying connection to the server asynchronously.
 *
 * Note, that if no user, host or database is set when connect is called, then libpq's defaults are used.
 * For no host, this means a socket connection to /tmp is attempted.
 *
 * @return A BOOL indicating the success of requesting the connection. Note, that this does not indicate
 *         that a successful connection has been made, only that it has successfullly been requested.
 */
- (BOOL)connect 
{
	// An attempt is still being polled on the background thread, which owns the PGconn until it finishes
	@synchronized (self) {
		if (_connecting) return NO;
		
		if ([self isConnected]) return YES;
		
		_connecting = YES;
		_sessionPending = YES;
	}
	
	// Discard the remains of any previous failed attempt (safe: no poller is running)
	if (_connection) {
		PQfinish(_connection);
		
		_connection = nil;
	}
	
	[self _setConnectionError:nil];
	[self _recordPasswordFlagsOf:NULL];
	
	[self _createConnectionParameters];
	
	// Perform the connection
	_connection = PQconnectStartParams(_connectionParamNames, _connectionParamValues, 0);
	
	if (!_connection || PQstatus(_connection) == CONNECTION_BAD) {
		
		NSString *error = _connection ? [NSString stringWithUTF8String:PQerrorMessage(_connection)] : @"Out of memory";
		
		[self _setConnectionError:error];
		[self _recordPasswordFlagsOf:_connection];
		
		if (_connection) PQfinish(_connection);
		
		_connection = nil;
		
		@synchronized (self) {
			_connecting = NO;
			_sessionPending = NO;
		}
		
		return NO;
	}
	
	[self performSelectorInBackground:@selector(_pollConnection:) withObject:nil];
	
	return YES;
}

/**
 * Attempts the reset the underlying connection.
 *
 * @note A return value of NO means that the connection is not currently 
 *       connected or the request to reset it failed. YES means the reset request was successful, 
 *       not that the connection re-establishment has succeeded. Wait for the
 *       delegate connection reset method to be called and check -isConnected.
 *
 * @return A BOOL indicating the success of the call.
 */
- (BOOL)reset 
{
	@synchronized (self) {
		if (_connecting || ![self isConnected]) return NO;
		
		_connecting = YES;
		_sessionPending = YES;
	}
	
	if (!PQresetStart(_connection)) {
		@synchronized (self) {
			_connecting = NO;
			_sessionPending = NO;
		}
		
		return NO;
	}
	
	[self performSelectorInBackground:@selector(_pollConnection:) withObject:[NSNumber numberWithBool:YES]];
	
	return YES;
}

/**
 * Returns the PostgreSQL client library (libpq) version being used.
 *
 * @return The library version (e.g. version 9.1 is 90100).
 */
- (NSUInteger)clientVersion
{
	return PQlibVersion();
}

/**
 * Returns the version of the server we're connected to.
 *
 * @return The server version (e.g. version 9.1 is 90100). -1 is returned if there's no connection.
 */
- (NSUInteger)serverVersion
{
	if (![self isConnected]) return -1;
	
	return PQserverVersion(_connection);
}

/**
 * Returns the ID of the process handling this connection on the remote host.
 *
 * @return The process ID or -1 if no connection is available.
 */
- (NSUInteger)serverProcessId
{
	if (![self isConnected]) return -1;
	
	return PQbackendPID(_connection);
}

/**
 * Attempts to cancel the query currently executing on this connection.
 *
 * @param error Populated if query was unabled to be cancelled.
 *
 * @return A BOOL indicating the success of the request
 */
- (BOOL)cancelCurrentQuery:(NSError **)error
{
	if (![self isConnected]) return NO;
	
	PGcancel *cancel = PQgetCancel(_connection);
	
	if (!cancel) return NO;
	
	char errorBuf[256]; 
	
	int result = PQcancel(cancel, errorBuf, 256);
	
	PQfreeCancel(cancel);
	
	if (!result) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:PGPostgresConnectionErrorDomain 
										 code:0 
									 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithUTF8String:errorBuf] forKey:NSLocalizedDescriptionKey]];
		}

		return NO;
	}
	
	_lastQueryWasCancelled = YES;
	
	return YES;
}

- (PGPostgresCancelToken *)newCancelToken
{
	if (![self isConnected]) return nil;
	
	PGcancel *cancel = PQgetCancel(_connection);
	
	if (!cancel) return nil;
	
	return [[PGPostgresCancelToken alloc] initWithCancel:cancel];
}

- (NSString *)encryptedPassword:(NSString *)password forRole:(NSString *)role
{
	if (!password || !role || ![self isConnected]) return nil;
	
	char *hashed = PQencryptPasswordConn(_connection, [password UTF8String], [role UTF8String], NULL);
	
	if (!hashed) return nil;
	
	NSString *result = [NSString stringWithUTF8String:hashed];
	
	PQfreemem(hashed);
	
	return result;
}

#pragma mark -
#pragma mark COPY

/**
 * An NSError in PGPostgresConnectionErrorDomain with the given code and description.
 */
static NSError *_PGConnectionError(PGConnectionErrorCode code, NSString *message)
{
	return [NSError errorWithDomain:PGPostgresConnectionErrorDomain
							   code:code
						   userInfo:[NSDictionary dictionaryWithObject:(message ? message : @"Unknown error.") forKey:NSLocalizedDescriptionKey]];
}

/**
 * A libpq C string as an NSString (UTF-8, falling back to Latin-1 for invalid bytes), or nil for NULL/empty.
 */
static NSString *_PGCopyString(const char *string)
{
	if (!string || !*string) return nil;
	
	NSString *result = [NSString stringWithUTF8String:string];
	
	if (!result) result = [NSString stringWithCString:string encoding:NSISOLatin1StringEncoding];
	
	return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/**
 * The message of an error result: the primary message, then "DETAIL: …" and "CONTEXT: …" lines when present
 * (for COPY the context names the line, e.g. "COPY t, line 2: …").
 */
static NSString *_PGCopyErrorMessage(const PGresult *result)
{
	NSString *primary = _PGCopyString(PQresultErrorField(result, PG_DIAG_MESSAGE_PRIMARY));
	
	if (!primary) primary = _PGCopyString(PQresultErrorMessage(result));
	
	NSMutableString *message = [NSMutableString stringWithString:primary ? primary : @"Unknown error."];
	
	NSString *detail = _PGCopyString(PQresultErrorField(result, PG_DIAG_MESSAGE_DETAIL));
	NSString *context = _PGCopyString(PQresultErrorField(result, PG_DIAG_CONTEXT));
	
	if (detail) [message appendFormat:@"\nDETAIL: %@", detail];
	if (context) [message appendFormat:@"\nCONTEXT: %@", context];
	
	return message;
}

- (BOOL)copyOut:(NSString *)sql handler:(BOOL (^)(NSData *chunk))handler error:(NSError **)error
{
	PGresult *result = [self _startCopy:sql expecting:PGRES_COPY_OUT error:error];
	
	if (!result) return NO;
	
	PQclear(result);
	
	BOOL cancelled = NO;
	char *buffer = NULL;
	int length = 0;
	
	// > 0: a row; -1: done; -2: failed. After a cancel the remaining rows are discarded.
	while ((length = PQgetCopyData(_connection, &buffer, 0)) > 0)
	{
		if (!cancelled && handler) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSData *chunk = [[NSData alloc] initWithBytes:buffer length:(NSUInteger)length];
			
			if (!handler(chunk)) {
				cancelled = YES;
				
				[self cancelCurrentQuery:NULL];
			}
			
			[chunk release];
			[pool drain];
		}
		
		PQfreemem(buffer);
		buffer = NULL;
	}
	
	return [self _finishCopyCancelled:cancelled error:error];
}

- (BOOL)copyIn:(NSString *)sql provider:(NSData * (^)(BOOL *cancel))provider error:(NSError **)error
{
	PGresult *result = [self _startCopy:sql expecting:PGRES_COPY_IN error:error];
	
	if (!result) return NO;
	
	PQclear(result);
	
	BOOL cancelled = NO;
	BOOL sendFailed = NO;
	
	while (!cancelled && !sendFailed)
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		BOOL cancel = NO;
		NSData *chunk = provider ? provider(&cancel) : nil;
		
		if (cancel) {
			cancelled = YES;
		}
		else if (!chunk) {
			[pool drain];
			break;
		}
		else {
			const char *bytes = (const char *)[chunk bytes];
			NSUInteger remaining = [chunk length];
			
			while (remaining > 0)
			{
				int piece = remaining > INT_MAX ? INT_MAX : (int)remaining;
				
				// 1: queued; -1: failed (e.g. the server already rejected the data; the error comes from PQgetResult)
				if (PQputCopyData(_connection, bytes, piece) != 1) {
					sendFailed = YES;
					break;
				}
				
				bytes += piece;
				remaining -= (NSUInteger)piece;
			}
		}
		
		[pool drain];
	}
	
	if (cancelled) {
		PQputCopyEnd(_connection, "cancelled");
	}
	else if (!sendFailed) {
		PQputCopyEnd(_connection, NULL);
	}
	
	return [self _finishCopyCancelled:cancelled error:error];
}

/**
 * Sends a COPY statement (reporting it, and only it, to the delegate) and checks it entered the expected copy mode.
 *
 * @return The copy-mode result (the caller clears it), or NULL with *error set: on a server error, when not
 *         connected, or when the statement isn't a COPY in the expected direction (any copy it started is ended).
 */
- (PGresult *)_startCopy:(NSString *)sql expecting:(ExecStatusType)expected error:(NSError **)error
{
	_lastQueryWasCancelled = NO;
	_lastQueryAffectedRowCount = 0;
	
	if (!sql || ![self isConnected]) {
		if (error) *error = _PGConnectionError(PGConnectionErrorNotConnected, @"Not connected.");
		
		return NULL;
	}
	
	if (_delegate && _delegateSupportsWillExecute) {
		[_delegate connection:self willExecute:sql withValues:nil];
	}
	
	// The extended protocol (no parameters) runs a single statement
	PGresult *result = PQexecParams(_connection, [sql UTF8String], 0, NULL, NULL, NULL, NULL, 0);
	
	if (!result) {
		if (error) *error = _PGConnectionError(PGConnectionErrorServer, [self libpqErrorMessage]);
		
		return NULL;
	}
	
	ExecStatusType status = PQresultStatus(result);
	
	if (status == expected) return result;
	
	if (status == PGRES_BAD_RESPONSE || status == PGRES_FATAL_ERROR) {
		[self _setLastErrorFromResult:result];
		
		if (error) *error = _PGConnectionError(PGConnectionErrorServer, _PGCopyErrorMessage(result));
		
		PQclear(result);
		
		return NULL;
	}
	
	PQclear(result);
	
	// Not a COPY in the expected direction: end any copy it started and leave the connection idle
	if (status == PGRES_COPY_IN || status == PGRES_COPY_OUT || status == PGRES_COPY_BOTH) {
		[self _finishCopyCancelled:YES error:NULL];
		
		_lastQueryWasCancelled = NO;
	}
	
	if (error) {
		*error = _PGConnectionError(PGConnectionErrorNotCopy, expected == PGRES_COPY_IN ?
									@"The statement is not a COPY … FROM STDIN." :
									@"The statement is not a COPY … TO STDOUT.");
	}
	
	return NULL;
}

/**
 * Collects a COPY's final result once its data has been sent or received, leaving the connection idle.
 *
 * @param cancelled Whether the caller cancelled; the result is then the cancelled error whatever the server said.
 *
 * @return YES when the COPY succeeded (lastQueryAffectedRowCount set), NO with *error set otherwise.
 */
- (BOOL)_finishCopyCancelled:(BOOL)cancelled error:(NSError **)error
{
	PGresult *failure = NULL;
	PGresult *next = NULL;
	BOOL succeeded = NO;
	NSUInteger unexpectedCopies = 0;
	
	while ((next = PQgetResult(_connection)))
	{
		ExecStatusType status = PQresultStatus(next);
		
		if (status == PGRES_COMMAND_OK) {
			const char *tuples = PQcmdTuples(next);
			
			_lastQueryAffectedRowCount = (tuples && *tuples) ? strtoull(tuples, NULL, 10) : 0;
			succeeded = YES;
		}
		else if ((status == PGRES_BAD_RESPONSE || status == PGRES_FATAL_ERROR) && !failure) {
			failure = next;
			
			continue;
		}
		else if (status == PGRES_COPY_IN || status == PGRES_COPY_OUT || status == PGRES_COPY_BOTH) {
			// Still in copy mode (e.g. ending the copy failed): end it, once, rather than loop forever
			PQclear(next);
			
			if (++unexpectedCopies > 1) break;
			
			if (status != PGRES_COPY_OUT) PQputCopyEnd(_connection, "cancelled");
			
			if (status != PGRES_COPY_IN) {
				char *buffer = NULL;
				
				while (PQgetCopyData(_connection, &buffer, 0) > 0) 
				{
					PQfreemem(buffer);
					buffer = NULL;
				}
			}
			
			continue;
		}
		
		PQclear(next);
	}
	
	if (cancelled) {
		if (failure) PQclear(failure);
		
		_lastQueryWasCancelled = YES;
		_lastQueryAffectedRowCount = 0;
		
		if (error) *error = _PGConnectionError(PGConnectionErrorCancelled, @"Cancelled.");
		
		return NO;
	}
	
	if (failure) {
		[self _setLastErrorFromResult:failure];
		
		if (error) *error = _PGConnectionError(PGConnectionErrorServer, _PGCopyErrorMessage(failure));
		
		PQclear(failure);
		
		return NO;
	}
	
	if (!succeeded) {
		NSString *message = [self libpqErrorMessage];
		
		if (error) *error = _PGConnectionError(PGConnectionErrorServer, message ? message : @"The COPY did not complete.");
		
		return NO;
	}
	
	return YES;
}

/**
 * Replaces lastError with the error in the given result (not cleared).
 */
- (void)_setLastErrorFromResult:(PGresult *)result
{
	if (_lastError) [_lastError release], _lastError = nil;
	
	_lastError = [[PGPostgresError alloc] initWithResult:result];
}

#pragma mark -
#pragma mark Private API

/**
 * Polls the connection that was previously requested via -connect and waits for meaninful status.
 *
 * @note This method should be called on a background thread as it will block waiting for the connection.
 */
- (void)_pollConnection:(NSNumber *)isReset
{
	@autoreleasepool {
		BOOL reset = isReset && [isReset boolValue];

		PostgresPollingStatusType status;

		// Per the libpq documentation, the first poll is made as if the status were PGRES_POLLING_WRITING,
		// and the socket must be re-fetched after each poll as it can change (e.g. when falling back from
		// SSL to a plain connection).
		status = PGRES_POLLING_WRITING;

		NSDate *start = [NSDate date];
		BOOL timedOut = NO;
		BOOL cancelled = NO;

		do
		{
			@synchronized (self) {
				cancelled = _disconnectRequested;
			}

			if (cancelled) break;

			if (_timeout > 0 && [[NSDate date] timeIntervalSinceDate:start] > (NSTimeInterval)_timeout) {
				timedOut = YES;
				
				break;
			}

			int sock = PQsocket(_connection);

			if (sock == -1) {
				status = PGRES_POLLING_FAILED;
				
				break;
			}

			struct pollfd fdinfo[1];

			fdinfo[0].fd = sock;
			fdinfo[0].events = (status == PGRES_POLLING_READING) ? POLLIN : POLLOUT;

			// Wake regularly to notice a disconnect request or the connection timeout
			int ready = poll(fdinfo, 1, 100);

			if (ready < 0 && errno != EINTR) {
				status = PGRES_POLLING_FAILED;
				
				break;
			}

			if (ready <= 0) continue;

			status = reset ? PQresetPoll(_connection) : PQconnectPoll(_connection);
		}
		while (status != PGRES_POLLING_OK && status != PGRES_POLLING_FAILED);

		if (cancelled) {
			@synchronized (self) {
				_connecting = NO;
				_sessionPending = NO;
			}
			
			return;
		}

		if (timedOut || status == PGRES_POLLING_FAILED) {
			const char *message = _connection ? PQerrorMessage(_connection) : NULL;
			
			NSString *error = timedOut ? [NSString stringWithFormat:@"Connection timed out after %lu seconds", (unsigned long)_timeout] : [NSString stringWithUTF8String:(message && *message) ? message : "Connection failed"];
			
			[self _setConnectionError:error];

			// Before _connecting clears: until then this thread owns the PGconn and -disconnect can't free it
			[self _recordPasswordFlagsOf:_connection];

			@synchronized (self) {
				_connecting = NO;
				_sessionPending = NO;
			}

			if (_delegate && [_delegate respondsToSelector:@selector(connectionFailed:)]) {
				[_delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:NO];
			}
			
			return;
		}

		if (status == PGRES_POLLING_OK && _connection && PQstatus(_connection) == CONNECTION_OK) {

			// Increase error verbosity
			PQsetErrorVerbosity(_connection, PQERRORS_VERBOSE);

			// Set notice processor
			PQsetNoticeProcessor(_connection, _PGPostgresConnectionNoticeProcessor, self);

			// Apply the session settings (also after a reset, which starts a new backend). If the server
			// refuses them the connection is unusable for the type handlers, so report it as failed.
			NSString *settingsError = [self _applySessionSettings];

			if (settingsError) {
				[self _setConnectionError:settingsError];

				// Still owned by this thread: -disconnect waits for _connecting to clear before touching it
				PQfinish(_connection);

				_connection = nil;

				@synchronized (self) {
					_connecting = NO;
					_sessionPending = NO;
				}

				if (_delegate && [_delegate respondsToSelector:@selector(connectionFailed:)]) {
					[_delegate performSelectorOnMainThread:@selector(connectionFailed:) withObject:self waitUntilDone:NO];
				}

				return;
			}

			@synchronized (self) {
				_sessionPending = NO;
			}

			[self _loadDatabaseParameters];

			@synchronized (self) {
				_connecting = NO;
			}

			if (reset) {
				if (_delegate && [_delegate respondsToSelector:@selector(connectionReset:)]) {
					[_delegate performSelectorOnMainThread:@selector(connectionReset:) withObject:self waitUntilDone:NO];
				}
			}
			else {
				if (_delegate && [_delegate respondsToSelector:@selector(connectionEstablished:)]) {
					[_delegate performSelectorOnMainThread:@selector(connectionEstablished:) withObject:self waitUntilDone:NO];
				}
			}
		}
		else {
			@synchronized (self) {
				_connecting = NO;
				_sessionPending = NO;
			}
		}
	}
}

/**
 * Applies the session settings the type handlers rely on (see PGPostgresSessionSettingsQuery). Called on
 * the polling thread, which owns the PGconn until _connecting is cleared.
 *
 * @return nil on success, otherwise the server's error message.
 */
- (NSString *)_applySessionSettings
{
	PGresult *result = PQexec(_connection, PGPostgresSessionSettingsQuery);
	
	NSString *error = nil;
	
	if (!result || PQresultStatus(result) != PGRES_COMMAND_OK) {
		const char *message = result ? PQresultErrorMessage(result) : PQerrorMessage(_connection);
		
		error = [NSString stringWithFormat:@"Failed to apply the session settings: %@", (message && *message) ? [NSString stringWithUTF8String:message] : @"unknown error"];
	}
	
	if (result) PQclear(result);
	
	return error;
}

/**
 * Loads the database parameters.
 */
- (void)_loadDatabaseParameters
{
	if (_parameters) [_parameters release];
	
	_parameters = [[PGPostgresConnectionParameters alloc] initWithConnection:self];
	
	BOOL success = [_parameters loadParameters];
	
	if (!success) NSLog(@"PostgresKit: Warning: Failed to load database parameters.");
}

/**
 * libpq notice processor function. Simply passes the message onto the connection delegate.
 *
 * @param arg     The calling connection.
 * @param message The message that was sent.
 */
static void _PGPostgresConnectionNoticeProcessor(void *arg, const char *message) 
{
	PGPostgresConnection *connection = (PGPostgresConnection *)arg;
	
	if ([connection isKindOfClass:[PGPostgresConnection class]]) {
		
		if ([connection delegate] && [[connection delegate] respondsToSelector:@selector(connection:notice:)]) {
			[[connection delegate] connection:connection notice:[NSString stringWithUTF8String:message]];
		}
	}
}

/**
 * Creates the parameter arrays required to establish a connection.
 */
- (void)_createConnectionParameters
{
	BOOL hasUser = NO;
	BOOL hasHost = NO;
	BOOL hasPassword = NO;
	BOOL hasDatabase = NO;
	
	if (_connectionParamNames) free(_connectionParamNames);
	if (_connectionParamValues) free(_connectionParamValues);
	
	// Application name, port, client encoding, keep alive and keep alive interval are always set
	int paramCount = 5;
	
	if (_user && [_user length]) paramCount++, hasUser = YES;
	if (_host && [_host length]) paramCount++, hasHost = YES;
	if (_password && [_password length]) paramCount++, hasPassword = YES;
	if (_database && [_database length]) paramCount++, hasDatabase = YES;
	
	BOOL hasSSLMode = _sslMode && [_sslMode length];
	BOOL hasSSLRootCert = _sslRootCertPath && [_sslRootCertPath length];
	BOOL hasSSLCert = _sslCertPath && [_sslCertPath length];
	BOOL hasSSLKey = _sslKeyPath && [_sslKeyPath length];
	
	BOOL hasTimeout = _timeout > 0;
	
	if (hasTimeout) paramCount++;
	if (hasSSLMode) paramCount++;
	if (hasSSLRootCert) paramCount++;
	if (hasSSLCert) paramCount++;
	if (hasSSLKey) paramCount++;
	
	// One extra entry for the terminating NULL
	_connectionParamNames = malloc((paramCount + 1) * sizeof(*_connectionParamNames));
	_connectionParamValues = malloc((paramCount + 1) * sizeof(*_connectionParamValues));
	
	_connectionParamNames[0] = PGPostgresApplicationParam;
	_connectionParamValues[0] = _applicationName ? [_applicationName UTF8String] : PGPostgresKitApplicationName;
	
	_connectionParamNames[1] = PGPostgresPortParam;
	_connectionParamValues[1] = [[[NSNumber numberWithUnsignedInteger:_port] stringValue] UTF8String];
	
	_connectionParamNames[2] = PGPostgresClientEncodingParam;
	_connectionParamValues[2] = [_encoding UTF8String];
	
	_connectionParamNames[3] = PGPostgresKeepAliveParam;
	_connectionParamValues[3] = _useKeepAlive ? "1" : "0";
	
	_connectionParamNames[4] = PGPostgresKeepAliveIntervalParam;
	_connectionParamValues[4] = [[[NSNumber numberWithUnsignedInteger:_keepAliveInterval] stringValue] UTF8String];
	
	// The session settings the type handlers need are applied after connecting (see -_applySessionSettings)
	NSUInteger i = 5;
	
	if (hasUser) {
		_connectionParamNames[i] = PGPostgresUserParam;
		_connectionParamValues[i] = [_user UTF8String];
		
		i++;
	}
	
	if (hasHost) {
		_connectionParamNames[i] = PGPostgresHostParam;
		_connectionParamValues[i] = [_host UTF8String];
		
		i++;
	}
	
	if (hasPassword) {
		_connectionParamNames[i] = PGPostgresPasswordParam;
		_connectionParamValues[i] = [_password UTF8String];
		
		i++;
	}	
	
	if (hasDatabase) {
		_connectionParamNames[i] = PGPostgresDatabaseParam;
		_connectionParamValues[i] = [_database UTF8String];
		
		i++;
	}
	
	if (hasTimeout) {
		_connectionParamNames[i] = PGPostgresConnectTimeoutParam;
		_connectionParamValues[i] = [[[NSNumber numberWithUnsignedInteger:_timeout] stringValue] UTF8String];
		
		i++;
	}
	
	if (hasSSLMode) {
		_connectionParamNames[i] = PGPostgresSSLModeParam;
		_connectionParamValues[i] = [_sslMode UTF8String];
		
		i++;
	}
	
	if (hasSSLRootCert) {
		_connectionParamNames[i] = PGPostgresSSLRootCertParam;
		_connectionParamValues[i] = [_sslRootCertPath UTF8String];
		
		i++;
	}
	
	if (hasSSLCert) {
		_connectionParamNames[i] = PGPostgresSSLCertParam;
		_connectionParamValues[i] = [_sslCertPath UTF8String];
		
		i++;
	}
	
	if (hasSSLKey) {
		_connectionParamNames[i] = PGPostgresSSLKeyParam;
		_connectionParamValues[i] = [_sslKeyPath UTF8String];
		
		i++;
	}
	
	_connectionParamNames[i] = NULL;
	_connectionParamValues[i] = NULL;
}

#pragma mark -

- (void)dealloc 
{
	[_typeMap release];
	
	[self disconnect];
	
	[self setHost:nil];
	[self setUser:nil];
	[self setDatabase:nil];
	
	if (_connectionParamNames) free(_connectionParamNames);
	if (_connectionParamValues) free(_connectionParamValues);
	
	if (_lastError) [_lastError release], _lastError = nil;
	if (_parameters) [_parameters release], _parameters = nil;
	if (_connectionError) [_connectionError release], _connectionError = nil;
	if (_applicationName) [_applicationName release], _applicationName = nil;
	if (_sslMode) [_sslMode release], _sslMode = nil;
	if (_sslRootCertPath) [_sslRootCertPath release], _sslRootCertPath = nil;
	if (_sslCertPath) [_sslCertPath release], _sslCertPath = nil;
	if (_sslKeyPath) [_sslKeyPath release], _sslKeyPath = nil;
	
	[super dealloc];
}

@end
