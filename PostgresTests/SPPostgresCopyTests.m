#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPCopyStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPCopyStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	[self.statements addObject:[query description]];
	for (id value in values) [self.statements addObject:[value description]];
}
@end

/// The three rows of the copy table: a NULL, a tab, a newline and a backslash, and their COPY text form.
static NSString * const SPCopyCreateTable = @"CREATE TEMPORARY TABLE copy_t (id int, a text, b text)";
static NSString * const SPCopyInsertRows = @"INSERT INTO copy_t VALUES (1, NULL, 'plain'), (2, E'tab\\there', E'new\\nline'), (3, E'back\\\\slash', '')";
static NSString * const SPCopyTextBytes = @"1\t\\N\tplain\n2\ttab\\there\tnew\\nline\n3\tback\\\\slash\t\n";
static NSString * const SPCopyCSVBytes = @"id,a,b\n1,,plain\n2,tab\there,\"new\nline\"\n3,back\\slash,\"\"\n";

/// PGPostgresConnection's COPY TO STDOUT / FROM STDIN, on PG 12 and 18.
@interface SPPostgresCopyTests : XCTestCase
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray *recorders;
@end

@implementation SPPostgresCopyTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.recorders = [NSMutableArray array];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	self.recorders = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

- (PGPostgresConnection *)connectOn:(NSNumber *)port recorder:(SPCopyStatementRecorder **)recorder
{
	SPCopyStatementRecorder *newRecorder = [[SPCopyStatementRecorder alloc] init];
	[self.recorders addObject:newRecorder]; // the connection doesn't retain its delegate
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:newRecorder];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	*recorder = newRecorder;
	return connection;
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	if (!result.numberOfRows) return nil;
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (void)assertUsable:(PGPostgresConnection *)connection
{
	XCTAssertEqualObjects([self value:@"SELECT 1" on:connection], @"1");
}

- (NSString *)copyOut:(NSString *)sql on:(PGPostgresConnection *)connection
{
	NSMutableData *data = [NSMutableData data];
	NSError *error = nil;
	BOOL ok = [connection copyOut:sql handler:^BOOL(NSData *chunk) { [data appendData:chunk]; return YES; } error:&error];
	XCTAssertTrue(ok, @"%@: %@", sql, error);
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/// A provider handing out bytes in chunks of the given size, then nil.
- (NSData * (^)(BOOL *))providerFor:(NSData *)bytes chunkSize:(NSUInteger)size
{
	__block NSUInteger offset = 0;
	return ^NSData *(BOOL *cancel) {
		if (offset >= bytes.length) return nil;
		NSUInteger length = MIN(size, bytes.length - offset);
		NSData *chunk = [bytes subdataWithRange:NSMakeRange(offset, length)];
		offset += length;
		return chunk;
	};
}

- (void)makeTableOn:(PGPostgresConnection *)connection
{
	[self run:SPCopyCreateTable on:connection];
	[self run:SPCopyInsertRows on:connection];
}

#pragma mark - Tests

- (void)testCopyOutTextAndCSV
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self makeTableOn:connection];

		XCTAssertEqualObjects([self copyOut:@"COPY (SELECT * FROM copy_t ORDER BY id) TO STDOUT" on:connection], SPCopyTextBytes, @"port %@", port);
		XCTAssertEqualObjects([self copyOut:@"COPY (SELECT * FROM copy_t ORDER BY id) TO STDOUT WITH (FORMAT csv, HEADER)" on:connection], SPCopyCSVBytes, @"port %@", port);
		XCTAssertEqual(connection.lastQueryAffectedRowCount, 3ULL);
		[self assertUsable:connection];
	}
}

- (void)testCopyInRoundTrip
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self makeTableOn:connection];
		[self run:@"CREATE TEMPORARY TABLE copy_u (id int, a text, b text)" on:connection];

		NSData *bytes = [SPCopyTextBytes dataUsingEncoding:NSUTF8StringEncoding];
		NSError *error = nil;
		BOOL ok = [connection copyIn:@"COPY copy_u FROM STDIN" provider:[self providerFor:bytes chunkSize:3] error:&error];
		XCTAssertTrue(ok, @"port %@: %@", port, error);
		XCTAssertEqual(connection.lastQueryAffectedRowCount, 3ULL);

		XCTAssertEqualObjects([self copyOut:@"COPY (SELECT * FROM copy_u ORDER BY id) TO STDOUT" on:connection], SPCopyTextBytes, @"port %@", port);
		XCTAssertEqualObjects([self value:@"SELECT count(*) FROM (SELECT * FROM copy_t EXCEPT SELECT * FROM copy_u) d" on:connection], @"0");
		XCTAssertEqualObjects([self value:@"SELECT count(*) FROM copy_u WHERE a IS NULL" on:connection], @"1");
		XCTAssertEqualObjects([self value:@"SELECT b FROM copy_u WHERE id = 2" on:connection], @"new\nline");
		XCTAssertEqualObjects([self value:@"SELECT a FROM copy_u WHERE id = 3" on:connection], @"back\\slash");
	}
}

- (void)testCopyInBadDataReportsLine
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE TEMPORARY TABLE copy_u (id int, a text, b text)" on:connection];

		NSData *bytes = [@"1\tx\ty\n2\tonly\n3\tz\tw\n" dataUsingEncoding:NSUTF8StringEncoding];
		NSError *error = nil;
		BOOL ok = [connection copyIn:@"COPY copy_u FROM STDIN" provider:[self providerFor:bytes chunkSize:4] error:&error];
		XCTAssertFalse(ok, @"port %@", port);
		XCTAssertNotNil(error);
		XCTAssertEqualObjects(error.domain, PGPostgresConnectionErrorDomain);
		XCTAssertNotEqual(error.code, (NSInteger)PGConnectionErrorCancelled);
		XCTAssertTrue([error.localizedDescription containsString:@"line 2"], @"port %@: %@", port, error.localizedDescription);
		XCTAssertTrue([error.localizedDescription containsString:@"missing data"], @"port %@: %@", port, error.localizedDescription);
		XCTAssertEqualObjects([self value:@"SELECT count(*) FROM copy_u" on:connection], @"0");
		[self assertUsable:connection];
	}
}

- (void)testCopyCancel
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];

		// Copy-out: the handler stops on its first chunk
		__block NSUInteger chunks = 0;
		NSError *error = nil;
		BOOL ok = [connection copyOut:@"COPY (SELECT g, repeat('x', 50) FROM generate_series(1, 100000) g) TO STDOUT"
							  handler:^BOOL(NSData *chunk) { chunks++; return NO; } error:&error];
		XCTAssertFalse(ok, @"port %@", port);
		XCTAssertEqual(chunks, 1U);
		XCTAssertEqualObjects(error.domain, PGPostgresConnectionErrorDomain);
		XCTAssertEqual(error.code, (NSInteger)PGConnectionErrorCancelled);
		XCTAssertEqualObjects(error.localizedDescription, @"Cancelled.");
		[self assertUsable:connection];

		// Copy-in: the provider cancels after one chunk
		[self run:@"CREATE TEMPORARY TABLE copy_u (id int, a text, b text)" on:connection];
		__block NSUInteger provided = 0;
		error = nil;
		ok = [connection copyIn:@"COPY copy_u FROM STDIN" provider:^NSData *(BOOL *cancel) {
			if (provided++ == 0) return [@"1\tx\ty\n" dataUsingEncoding:NSUTF8StringEncoding];
			*cancel = YES;
			return nil;
		} error:&error];
		XCTAssertFalse(ok, @"port %@", port);
		XCTAssertEqualObjects(error.domain, PGPostgresConnectionErrorDomain);
		XCTAssertEqual(error.code, (NSInteger)PGConnectionErrorCancelled);
		XCTAssertEqualObjects(error.localizedDescription, @"Cancelled.");
		XCTAssertEqualObjects([self value:@"SELECT count(*) FROM copy_u" on:connection], @"0");
		[self assertUsable:connection];
	}
}

- (void)testCopyNotLoggedAsData
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPCopyStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		[self run:@"CREATE TEMPORARY TABLE copy_u (id int, a text, b text)" on:connection];
		[recorder.statements removeAllObjects];

		NSString *copyIn = @"COPY copy_u FROM STDIN";
		NSData *bytes = [@"7\tsecret-in\tvalue\n" dataUsingEncoding:NSUTF8StringEncoding];
		NSError *error = nil;
		XCTAssertTrue([connection copyIn:copyIn provider:[self providerFor:bytes chunkSize:5] error:&error], @"%@", error);

		NSString *copyOut = @"COPY (SELECT a || '-out' FROM copy_u) TO STDOUT";
		XCTAssertEqualObjects([self copyOut:copyOut on:connection], @"secret-in-out\n");

		XCTAssertEqualObjects(recorder.statements, (@[copyIn, copyOut]), @"port %@", port);
		for (NSString *statement in recorder.statements) {
			XCTAssertFalse([statement containsString:@"secret-in\t"], @"%@", statement);
			XCTAssertFalse([statement containsString:@"secret-in-out"], @"%@", statement);
		}
	}
}

#pragma mark - Cancel token

/// A cancel token taken from a connection interrupts the statement it runs on another thread (a lock wait), can be
/// used from the main thread, and does nothing once invalidated.
- (void)testCancelTokenInterruptsStatementOnAnotherThread
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *holder = [self connectOn:port];
		PGPostgresConnection *worker = [self connectOn:port];
		[self run:@"DROP TABLE IF EXISTS public.cancel_token_t" on:holder];
		[self run:@"CREATE TABLE public.cancel_token_t (i int)" on:holder];
		[self run:@"BEGIN" on:holder];
		[self run:@"LOCK TABLE public.cancel_token_t IN ACCESS EXCLUSIVE MODE" on:holder];

		// Taken on the thread that uses the connection (here, before handing it to the background)
		PGPostgresCancelToken *token = [worker newCancelToken];
		XCTAssertNotNil(token);

		__block BOOL done = NO;
		__block BOOL succeeded = YES;
		__block NSString *state = nil;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			succeeded = [worker execute:@"SELECT count(*) FROM public.cancel_token_t"] != nil;
			state = worker.lastError.errorStateCode;
			dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
		});

		// Wait until the worker waits on the lock, then cancel from the main thread
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
		while (![[self value:@"SELECT count(*)::text FROM pg_catalog.pg_locks WHERE NOT granted AND relation = 'public.cancel_token_t'::regclass" on:holder] isEqualToString:@"1"]
			   && [deadline timeIntervalSinceNow] > 0) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		}
		XCTAssertFalse(done, @"the statement waits on the lock");
		NSDate *cancelled = [NSDate date];
		XCTAssertTrue([token cancel]);
		deadline = [NSDate dateWithTimeIntervalSinceNow:10];
		while (!done && [deadline timeIntervalSinceNow] > 0) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		}
		XCTAssertTrue(done, @"the statement ended");
		XCTAssertLessThan(-[cancelled timeIntervalSinceNow], 5.0);
		XCTAssertFalse(succeeded);
		XCTAssertEqualObjects(state, @"57014", @"query_canceled");

		// Once invalidated it does nothing; the connection stays usable
		[token invalidate];
		XCTAssertFalse([token cancel]);
		[token invalidate];
		[self assertUsable:worker];
		[self run:@"ROLLBACK" on:holder];
		[self run:@"DROP TABLE public.cancel_token_t" on:holder];
	}
}

@end
