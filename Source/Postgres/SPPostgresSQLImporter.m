#import "SPPostgresSQLImporter.h"
#import "SPPostgresDumpReader.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

@interface SPPostgresSQLImporter ()

- (NSString *)_serverMessageFallingBackTo:(NSString *)fallback;
- (void)_rollBackIfInTransaction;

@end

@implementation SPPostgresSQLImporter

@synthesize singleTransaction;
@synthesize errorHandler;
@synthesize progress;
@synthesize statementsRun;
@synthesize errorsIgnored;

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection reader:(SPPostgresDumpReader *)theReader
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		reader = [theReader retain];
		singleTransaction = YES;
	}
	return self;
}

- (void)dealloc
{
	[connection release];
	[reader release];
	[errorHandler release];
	[progress release];
	[super dealloc];
}

#pragma mark - Helpers

/// The server's last error as the import reports it: its message, then DETAIL, HINT and CONTEXT lines.
- (NSString *)_serverMessageFallingBackTo:(NSString *)fallback
{
	PGPostgresError *serverError = [connection isConnected] ? [connection lastError] : nil;
	NSString *primary = [serverError errorPrimaryMessage];
	if (![primary length]) {
		if ([fallback length]) return fallback;
		NSString *libpq = [connection libpqErrorMessage];
		return [libpq length] ? libpq : NSLocalizedString(@"The statement failed.", @"Postgres import: statement failed without a message");
	}
	NSMutableString *message = [NSMutableString stringWithString:primary];
	[message appendString:SPPostgresErrorDetailLines(serverError)];
	NSString *context = [[serverError errorContext] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([context length]) [message appendFormat:@"\n%@ %@", NSLocalizedString(@"CONTEXT:", @"Postgres import: error context label"), context];
	return message;
}

- (void)_rollBackIfInTransaction
{
	PGPostgresTransactionStatus status = [connection transactionStatus];
	if (status == PGPostgresTransactionInTransaction || status == PGPostgresTransactionInError) {
		[connection execute:@"ROLLBACK"];
	}
}

/// YES for a statement that opens or ends a transaction block (BEGIN, START TRANSACTION, COMMIT, END).
static BOOL SPIsTransactionControl(NSString *sql)
{
	static NSRegularExpression *pattern = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		pattern = [[NSRegularExpression alloc] initWithPattern:@"\\A\\s*(BEGIN|START\\s+TRANSACTION|COMMIT|END)(?!\\s+PREPARED\\b)(\\s.*)?\\z"
													   options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
														 error:NULL];
	});
	// (BEGIN ATOMIC only appears inside CREATE FUNCTION, never at the start of a statement)
	return [pattern firstMatchInString:sql options:0 range:NSMakeRange(0, [sql length])] != nil;
}

#pragma mark - Running

- (BOOL)run:(NSError **)error
{
	statementsRun = 0;
	errorsIgnored = 0;

	NSError *failure = nil;
	BOOL cancelled = NO;
	BOOL ignoreAll = NO;

	if (singleTransaction) {
		if (!SPPostgresExecuteWithDetails(connection, @"BEGIN", nil, &failure)) {
			if (error) *error = failure;
			return NO;
		}
	}

	BOOL (^stillGoing)(void) = ^BOOL(void) {
		if (!self->progress) return YES;
		return self->progress([self->reader bytesRead], [self->reader fileSize]);
	};

	for (;;) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		BOOL stop = NO;

		NSError *readError = nil;
		SPPostgresDumpItem *item = [reader nextItem:&readError];
		if (!item) {
			if (readError) failure = [readError retain];
			[pool drain];
			break;
		}

		NSString *itemFailure = nil; // the server's message when the item failed

		switch ([item kind]) {
			case SPPostgresDumpItemMetaCommand: {
				NSString *command = [[[item sql] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] firstObject];
				if ([command isEqualToString:@"\\restrict"] || [command isEqualToString:@"\\unrestrict"]) break;
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"psql command “%@” on line %lu can't be run here.", @"Postgres import: unsupported psql meta-command"), command, (unsigned long)[item line]];
				failure = [SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil) retain];
				stop = YES;
				break;
			}

			case SPPostgresDumpItemStatement: {
				if (singleTransaction && SPIsTransactionControl([item sql])) break;
				NSError *executeError = nil;
				if (SPPostgresExecuteWithDetails(connection, [item sql], nil, &executeError)) {
					statementsRun++;
				}
				else {
					itemFailure = [self _serverMessageFallingBackTo:[executeError localizedDescription]];
				}
				break;
			}

			case SPPostgresDumpItemCopy: {
				__block NSError *dataError = nil;
				__block BOOL copyCancelled = NO;
				NSError *copyError = nil;
				BOOL copied = [connection copyIn:[item sql] provider:^NSData *(BOOL *cancel) {
					NSError *nextError = nil;
					NSData *data = [self->reader nextCopyData:&nextError];
					if (!data && nextError) {
						dataError = [nextError retain];
						*cancel = YES;
						return nil;
					}
					if (data && !stillGoing()) {
						copyCancelled = YES;
						*cancel = YES;
						return nil;
					}
					return data;
				} error:&copyError];

				if (copied) {
					statementsRun++;
				}
				else if (dataError) {
					failure = dataError; // retained by the provider
					stop = YES;
				}
				else if (copyCancelled) {
					cancelled = YES;
					stop = YES;
				}
				else {
					itemFailure = [self _serverMessageFallingBackTo:[copyError localizedDescription]];
				}
				break;
			}
		}

		if (itemFailure && !stop) {
			NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Line %lu: %@", @"Postgres import: error at a line of the file"), (unsigned long)[item line], itemFailure];
			NSError *itemError = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil);

			SPPostgresImportErrorChoice choice = SPPostgresImportStop;
			if (!singleTransaction) {
				if (ignoreAll) choice = SPPostgresImportIgnoreAll;
				else if (errorHandler) choice = errorHandler(itemError, item);
			}

			if (choice == SPPostgresImportIgnore || choice == SPPostgresImportIgnoreAll) {
				errorsIgnored++;
				if (choice == SPPostgresImportIgnoreAll) ignoreAll = YES;
			}
			else {
				failure = [itemError retain];
				stop = YES;
			}
		}

		if (!stop && !stillGoing()) {
			cancelled = YES;
			stop = YES;
		}

		[pool drain];
		if (stop) break;
	}

	[failure autorelease];

	if (cancelled) {
		[self _rollBackIfInTransaction];
		if (error) *error = SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The import was cancelled.", @"Postgres import: cancelled"), nil);
		return NO;
	}

	if (failure) {
		// Single transaction: everything is undone. Otherwise only a transaction the dump itself left open.
		[self _rollBackIfInTransaction];
		if (error) *error = failure;
		return NO;
	}

	if (singleTransaction) {
		NSError *commitError = nil;
		if (!SPPostgresExecuteWithDetails(connection, @"COMMIT", nil, &commitError)) {
			[self _rollBackIfInTransaction];
			if (error) *error = commitError;
			return NO;
		}
	}

	return YES;
}

@end
