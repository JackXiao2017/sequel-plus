#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresCSV.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// CSV export and import (SPPostgresCSV) against pgkit_io_src / pgkit_io_dst; both ports.
@interface SPPostgresCSVTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresCSVTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)database:(NSString *)name on:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:name];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)text:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : @"(null)";
}

- (NSString *)pathNamed:(NSString *)name
{
	return [self.directory stringByAppendingPathComponent:name];
}

- (NSString *)write:(NSString *)contents named:(NSString *)name
{
	NSString *path = [self pathNamed:name];
	XCTAssertTrue([contents writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
	return path;
}

- (NSString *)contentsOf:(NSString *)path
{
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

- (SPPostgresCSVOptions *)optionsWithDelimiter:(NSString *)delimiter escape:(NSString *)escape header:(BOOL)header null:(NSString *)nullString
{
	SPPostgresCSVOptions *options = [[SPPostgresCSVOptions alloc] init];
	options.delimiter = delimiter;
	options.escape = escape;
	options.header = header;
	options.nullString = nullString;
	return options;
}

- (NSString *)exportTable:(NSString *)table schema:(NSString *)schema from:(PGPostgresConnection *)connection options:(SPPostgresCSVOptions *)options named:(NSString *)name
{
	NSString *path = [self pathNamed:name];
	NSError *error = nil;
	XCTAssertTrue(([SPPostgresCSV exportTable:table schema:schema connection:connection options:options toPath:path cancel:nil error:&error]), @"%@", error.localizedDescription);
	XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
	return path;
}

/// The awkward values, as rows of NSString / NSNull, each row (id, v, w).
- (NSArray *)awkwardRows
{
	return @[
		@[@"1", @"plain", @""],
		@[@"2", [NSNull null], @"tab\there"],
		@[@"3", @"line1\nline2\r\nline3", @"back\\slash \\t not a tab"],
		@[@"4", @"\\N", @"NULL"],
		@[@"5", @"emoji 🎉🐘 and 'single' and \"double\"", @"has,comma;semi|pipe"],
		@[@"6", @"\\.", @"\r"],
		@[@"7", @" leading and trailing ", [NSNull null]],
	];
}

/// public.<name> (id int, v text, w text) holding -awkwardRows.
- (void)createAwkwardTable:(NSString *)name on:(PGPostgresConnection *)connection
{
	[self run:[NSString stringWithFormat:@"CREATE TABLE public.%@ (id integer PRIMARY KEY, v text, w text)", name] on:connection];
	for (NSArray *row in [self awkwardRows]) {
		NSMutableArray *values = [NSMutableArray array];
		for (id value in row) [values addObject:value];
		NSString *insert = [NSString stringWithFormat:@"INSERT INTO public.%@ VALUES ($1::int, $2, $3)", name];
		PGPostgresResult *result = [connection execute:insert values:values];
		XCTAssertNotNil(result, @"%@", connection.lastError.errorPrimaryMessage);
	}
}

- (NSString *)digestOf:(NSString *)table on:(PGPostgresConnection *)connection
{
	return [self text:[NSString stringWithFormat:@"SELECT count(*) || ':' || md5(string_agg(t::text, '|' ORDER BY id)) FROM %@ t", table] on:connection];
}

#pragma mark - Export

- (void)testExportTableCSVWithOptions
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self database:@"pgkit_io_src" on:port];
		[SPPostgresTestServers loadFixtureNamed:@"io_source" onPort:port.unsignedIntegerValue];

		SPPostgresCSVOptions *options = [self optionsWithDelimiter:@";" escape:@"\"" header:YES null:@"NULL"];
		NSString *path = [self exportTable:@"Orders 2026" schema:@"Sales Data" from:source options:options named:@"orders.csv"];
		NSString *csv = [self contentsOf:path];
		XCTAssertNotNil(csv);

		NSString *firstLine = [csv componentsSeparatedByString:@"\n"][0];
		XCTAssertEqualObjects(firstLine, @"id;seq;parent_id;feeling;qty;ship_to;customer;details;blob;amount;note;placed_at;total", @"port %@", port);
		// A value holding the delimiter is quoted (its quotes doubled)
		XCTAssertTrue([csv containsString:@";\"emoji 🎉🐘 and 'single' and \"\"double\"\" and a ; semicolon\";"], @"%@", csv);
		// NULL is NULL (Frank: blob, amount and note). The server quotes only a value equal to the NULL text, so with
		// NULL 'NULL' Eve's empty note is an empty field, and the text NULL would be "NULL"
		XCTAssertTrue([csv containsString:@";Frank;{};NULL;NULL;NULL;"], @"%@", csv);
		XCTAssertTrue([csv containsString:@";2.50;;"], @"%@", csv);
		// The text \N is just text
		XCTAssertTrue([csv containsString:@";1.00;\\N;"], @"%@", csv);

		// With the default NULL (empty), the empty string is "" and NULL is nothing
		SPPostgresCSVOptions *defaults = [self optionsWithDelimiter:@";" escape:@"\"" header:YES null:@""];
		NSString *plain = [self contentsOf:[self exportTable:@"Orders 2026" schema:@"Sales Data" from:source options:defaults named:@"orders-default.csv"]];
		XCTAssertTrue([plain containsString:@";2.50;\"\";"], @"%@", plain);
		XCTAssertTrue([plain containsString:@";Frank;{};;;;"], @"%@", plain);
	}
}

- (void)testExportRowsMatchesServerQuoting
{
	NSArray *optionSets = @[
		[self optionsWithDelimiter:@"," escape:@"\"" header:YES null:@""],
		[self optionsWithDelimiter:@";" escape:@"\\" header:YES null:@"NULL"],
		[self optionsWithDelimiter:@"|" escape:@"\"" header:NO null:@"\\N"],
		[self optionsWithDelimiter:@"\t" escape:@"\\" header:YES null:@""],
	];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self database:@"pgkit_io_src" on:port];
		[self createAwkwardTable:@"awkward" on:source];
		[self run:@"CREATE TABLE public.\"one,col\" (\"v;\" text)" on:source];
		[self run:@"INSERT INTO public.\"one,col\" VALUES (E'\\\\.'), (''), (NULL), ('x'), ('NULL')" on:source];
		NSArray *oneRows = @[@[@"\\."], @[@""], @[[NSNull null]], @[@"x"], @[@"NULL"]];

		NSUInteger set = 0;
		for (SPPostgresCSVOptions *options in optionSets) {
			set++;
			NSString *fromServer = [self exportTable:@"awkward" schema:@"public" from:source options:options named:[NSString stringWithFormat:@"server%lu.csv", (unsigned long)set]];
			NSString *fromClient = [self pathNamed:[NSString stringWithFormat:@"client%lu.csv", (unsigned long)set]];
			NSError *error = nil;
			XCTAssertTrue(([SPPostgresCSV exportRows:[self awkwardRows] columnNames:@[@"id", @"v", @"w"] options:options toPath:fromClient error:&error]), @"%@", error.localizedDescription);
			XCTAssertEqualObjects([NSData dataWithContentsOfFile:fromClient], [NSData dataWithContentsOfFile:fromServer],
								  @"port %@, set %lu:\n%@\n---\n%@", port, (unsigned long)set, [self contentsOf:fromClient], [self contentsOf:fromServer]);

			NSString *oneServer = [self exportTable:@"one,col" schema:@"public" from:source options:options named:[NSString stringWithFormat:@"oneserver%lu.csv", (unsigned long)set]];
			NSString *oneClient = [self pathNamed:[NSString stringWithFormat:@"oneclient%lu.csv", (unsigned long)set]];
			XCTAssertTrue(([SPPostgresCSV exportRows:oneRows columnNames:@[@"v;"] options:options toPath:oneClient error:&error]), @"%@", error.localizedDescription);
			XCTAssertEqualObjects([NSData dataWithContentsOfFile:oneClient], [NSData dataWithContentsOfFile:oneServer],
								  @"port %@, set %lu:\n%@\n---\n%@", port, (unsigned long)set, [self contentsOf:oneClient], [self contentsOf:oneServer]);
		}
	}
}

- (void)testExportCancelDeletesFileAndBadTableFails
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self database:@"pgkit_io_src" on:port];
		[self run:@"CREATE TABLE public.big AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 50000) g" on:source];
		NSString *path = [self pathNamed:@"big.csv"];
		NSError *error = nil;
		__block NSUInteger asked = 0;
		XCTAssertFalse(([SPPostgresCSV exportTable:@"big" schema:@"public" connection:source options:[SPPostgresCSVOptions new] toPath:path cancel:^BOOL{
			return ++asked > 3;
		} error:&error]));
		XCTAssertEqual(error.code, SPPostgresErrorCancelled);
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
		XCTAssertEqual(source.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT 1" on:source], @"1");

		error = nil;
		XCTAssertFalse(([SPPostgresCSV exportTable:@"missing" schema:@"public" connection:source options:[SPPostgresCSVOptions new] toPath:path cancel:nil error:&error]));
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"missing"], @"%@", error.localizedDescription);
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);

		error = nil;
		SPPostgresCSVOptions *bad = [self optionsWithDelimiter:@"\"" escape:@"\"" header:YES null:@""];
		XCTAssertFalse(([SPPostgresCSV exportRows:@[] columnNames:@[@"a"] options:bad toPath:path error:&error]));
		XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
	}
}

#pragma mark - Reading

- (void)testPreviewAndHeader
{
	NSString *path = [self write:@"\xEF\xBB\xBFname,\"x\"\"y\",\n1,\"a,b\",\r\n2,\"multi\nline\",NULL\n3\n\n4,\"\",z,extra\n" named:@"preview.csv"];
	SPPostgresCSVOptions *options = [self optionsWithDelimiter:@"," escape:@"\"" header:YES null:@"NULL"];
	NSError *error = nil;
	NSArray *header = [SPPostgresCSV headerAtPath:path options:options error:&error];
	XCTAssertEqualObjects(header, (@[@"name", @"x\"y", @"Column 3"]), @"%@", error);

	NSArray *rows = [SPPostgresCSV previewRowsAtPath:path options:options limit:10 error:&error];
	NSArray *expected = @[@[@"1", @"a,b", @""], @[@"2", @"multi\nline", [NSNull null]], @[@"3"], @[@""], @[@"4", @"", @"z", @"extra"]];
	XCTAssertEqualObjects(rows, expected, @"%@", error);
	XCTAssertEqualObjects(([SPPostgresCSV previewRowsAtPath:path options:options limit:2 error:&error]), [expected subarrayWithRange:NSMakeRange(0, 2)]);

	options.header = NO;
	XCTAssertEqualObjects(([SPPostgresCSV headerAtPath:path options:options error:&error]), (@[@"Column 1", @"Column 2", @"Column 3", @"Column 4"]));
	XCTAssertEqualObjects(([SPPostgresCSV previewRowsAtPath:path options:options limit:1 error:&error]), (@[@[@"name", @"x\"y", @""]]));

	NSString *unterminated = [self write:@"a,b\n1,\"open\n" named:@"unterminated.csv"];
	error = nil;
	XCTAssertNil([SPPostgresCSV previewRowsAtPath:unterminated options:options limit:10 error:&error]);
	XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);

	NSString *empty = [self write:@"" named:@"empty.csv"];
	XCTAssertEqualObjects(([SPPostgresCSV headerAtPath:empty options:options error:&error]), @[]);
	XCTAssertEqualObjects(([SPPostgresCSV previewRowsAtPath:empty options:options limit:10 error:&error]), @[]);

	// A backslash escape: \" and \\ inside quotes, a lone \ kept
	NSString *escaped = [self write:@"\"a\\\"b\",\"c\\\\d\",\"e\\f\",g\\h\n" named:@"escaped.csv"];
	SPPostgresCSVOptions *backslash = [self optionsWithDelimiter:@"," escape:@"\\" header:NO null:@""];
	XCTAssertEqualObjects(([SPPostgresCSV previewRowsAtPath:escaped options:backslash limit:10 error:&error]), (@[@[@"a\"b", @"c\\d", @"e\\f", @"g\\h"]]));
}

#pragma mark - Import

- (void)testCSVRoundTripKeepsAwkwardValues
{
	NSArray *optionSets = @[
		[self optionsWithDelimiter:@"," escape:@"\"" header:YES null:@""],
		[self optionsWithDelimiter:@";" escape:@"\\" header:NO null:@"NULL"],
		[self optionsWithDelimiter:@"\t" escape:@"\"" header:YES null:@"\\N"],
	];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *source = [self database:@"pgkit_io_src" on:port];
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self createAwkwardTable:@"awkward" on:source];
		NSString *expected = [self digestOf:@"public.awkward" on:source];
		XCTAssertTrue([expected hasPrefix:@"7:"], @"%@", expected);

		NSUInteger set = 0;
		for (SPPostgresCSVOptions *options in optionSets) {
			set++;
			[self run:@"DROP TABLE IF EXISTS public.\"Awk Copy\"" on:destination];
			[self run:@"CREATE TABLE public.\"Awk Copy\" (id integer PRIMARY KEY, v text, w text)" on:destination];
			NSString *path = [self exportTable:@"awkward" schema:@"public" from:source options:options named:[NSString stringWithFormat:@"awkward%lu.csv", (unsigned long)set]];

			NSError *error = nil;
			__block unsigned long long lastRead = 0, lastSize = 0;
			BOOL imported = [SPPostgresCSV importPath:path options:options intoTable:@"Awk Copy" schema:@"public" columnMapping:@[@0, @1, @2]
										   connection:destination progress:^BOOL(unsigned long long bytesRead, unsigned long long fileSize) {
				lastRead = bytesRead;
				lastSize = fileSize;
				return YES;
			} error:&error];
			XCTAssertTrue(imported, @"port %@, set %lu: %@\n%@", port, (unsigned long)set, error.localizedDescription, [self contentsOf:path]);
			XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
			XCTAssertEqualObjects([self digestOf:@"public.\"Awk Copy\"" on:destination], expected, @"port %@, set %lu:\n%@", port, (unsigned long)set, [self contentsOf:path]);
			XCTAssertGreaterThan(lastSize, 0ULL);
			XCTAssertEqual(lastRead, lastSize);
		}
	}
}

- (void)testImportWithMappingAndSkippedColumn
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self run:@"CREATE TABLE public.mapped (a int, b text, c text DEFAULT 'd')" on:destination];
		NSString *path = [self write:@"b,a,ignored\nx,1,zzz\n\"y, why\",2,qqq\n" named:@"mapped.csv"];
		NSError *error = nil;
		XCTAssertTrue(([SPPostgresCSV importPath:path options:[SPPostgresCSVOptions new] intoTable:@"mapped" schema:@"public"
								  columnMapping:@[@1, @0, [NSNull null]] connection:destination progress:nil error:&error]), @"%@", error.localizedDescription);
		XCTAssertEqualObjects([self text:@"SELECT string_agg(a || '/' || b || '/' || c, '|' ORDER BY a) FROM public.mapped" on:destination], @"1/x/d|2/y, why/d");
	}
}

- (void)testImportErrorRollsBackAndReportsLine
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self run:@"CREATE TABLE public.numbers (a int, b text)" on:destination];
		[self run:@"INSERT INTO public.numbers VALUES (0, 'keep')" on:destination];
		NSString *path = [self write:@"a,b\n1,x\n2,\"two\nlines\"\nnope,z\n4,w\n" named:@"numbers.csv"];
		NSError *error = nil;
		XCTAssertFalse(([SPPostgresCSV importPath:path options:[SPPostgresCSVOptions new] intoTable:@"numbers" schema:@"public"
								   columnMapping:@[@0, @1] connection:destination progress:nil error:&error]));
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"line 3"], @"%@", error.localizedDescription);
		XCTAssertTrue([error.localizedDescription containsString:@"nope"], @"%@", error.localizedDescription);
		XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT string_agg(a || b, ',') FROM public.numbers" on:destination], @"0keep");
	}
}

- (void)testShortRowMessage
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self run:@"CREATE TABLE public.short (a text, b text, c text)" on:destination];
		NSString *path = [self write:@"1,2,3\n4,5\n6,7,8\n" named:@"short.csv"];
		SPPostgresCSVOptions *options = [SPPostgresCSVOptions new];
		options.header = NO;
		NSError *error = nil;
		XCTAssertFalse(([SPPostgresCSV importPath:path options:options intoTable:@"short" schema:@"public"
								   columnMapping:@[@0, @1, @2] connection:destination progress:nil error:&error]));
		XCTAssertEqualObjects(error.localizedDescription, @"Row 2 has 2 fields; column “c” needs field 3.");
		XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT count(*) FROM public.short" on:destination], @"0");
	}
}

- (void)testImportCancelAndBadMappings
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self run:@"CREATE TABLE public.many (id int, pad text, twice int GENERATED ALWAYS AS (id * 2) STORED)" on:destination];
		NSMutableString *csv = [NSMutableString stringWithString:@"id,pad\n"];
		for (NSUInteger i = 0; i < 40000; i++) [csv appendFormat:@"%lu,%@\n", (unsigned long)i, [@"" stringByPaddingToLength:60 withString:@"y" startingAtIndex:0]];
		NSString *path = [self write:csv named:@"many.csv"];

		NSError *error = nil;
		__block NSUInteger calls = 0;
		XCTAssertFalse(([SPPostgresCSV importPath:path options:[SPPostgresCSVOptions new] intoTable:@"many" schema:@"public" columnMapping:@[@0, @1, [NSNull null]]
									  connection:destination progress:^BOOL(unsigned long long bytesRead, unsigned long long fileSize) {
			return ++calls < 3;
		} error:&error]));
		XCTAssertEqual(error.code, SPPostgresErrorCancelled);
		XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT count(*) FROM public.many" on:destination], @"0");

		// Wrong length, a generated column mapped, nothing mapped
		for (NSArray *mapping in @[@[@0, @1], @[@0, @1, @0], @[[NSNull null], [NSNull null], [NSNull null]]]) {
			error = nil;
			XCTAssertFalse(([SPPostgresCSV importPath:path options:[SPPostgresCSVOptions new] intoTable:@"many" schema:@"public" columnMapping:mapping
										  connection:destination progress:nil error:&error]));
			XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings, @"%@", error.localizedDescription);
			XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
		}

		// The whole file, then
		error = nil;
		XCTAssertTrue(([SPPostgresCSV importPath:path options:[SPPostgresCSVOptions new] intoTable:@"many" schema:@"public" columnMapping:@[@0, @1, [NSNull null]]
									 connection:destination progress:nil error:&error]), @"%@", error.localizedDescription);
		XCTAssertEqualObjects([self text:@"SELECT count(*) || ':' || sum(twice) FROM public.many" on:destination], @"40000:1599960000");
	}
}

#pragma mark - Compressed files and row numbers

/// text written compressed (1 gzip, 2 bzip2) with the app's SPFileHandle; its bytes.
- (NSData *)compress:(NSString *)text format:(int)format path:(NSString *)path
{
	Class handleClass = NSClassFromString(@"SPFileHandle");
	[[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
	id handle = [handleClass performSelector:@selector(fileHandleForWritingAtPath:) withObject:path];
	XCTAssertNotNil(handle);
	NSMethodSignature *signature = [handle methodSignatureForSelector:@selector(setCompressionFormat:)];
	NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
	invocation.selector = @selector(setCompressionFormat:);
	[invocation setArgument:&format atIndex:2];
	[invocation invokeWithTarget:handle];
	[handle performSelector:@selector(writeData:) withObject:[text dataUsingEncoding:NSUTF8StringEncoding]];
	[handle performSelector:@selector(closeFile)];
	return [NSData dataWithContentsOfFile:path];
}

/// R8: .csv.gz and .csv.bz2 preview, give their header and import as the plain file does; a truncated .csv.gz fails
/// with the damaged/truncated message and imports nothing.
- (void)testCompressedCSVPreviewAndImport
{
	NSMutableString *csv = [NSMutableString stringWithString:@"id,name\n"];
	for (NSUInteger i = 1; i <= 5000; i++) [csv appendFormat:@"%lu,\"row %lu, %@\"\n", (unsigned long)i, (unsigned long)(i * 7919 % 10007), [[NSUUID UUID] UUIDString]];
	NSString *gzPath = [self pathNamed:@"rows.csv.gz"];
	NSString *bzPath = [self pathNamed:@"rows.csv.bz2"];
	NSData *gz = [self compress:csv format:1 path:gzPath];
	[self compress:csv format:2 path:bzPath];
	NSString *halfPath = [self pathNamed:@"half.csv.gz"];
	XCTAssertTrue([[gz subdataWithRange:NSMakeRange(0, gz.length / 2)] writeToFile:halfPath atomically:YES]);

	SPPostgresCSVOptions *options = [SPPostgresCSVOptions new];
	for (NSString *path in @[gzPath, bzPath]) {
		NSError *error = nil;
		XCTAssertEqualObjects([SPPostgresCSV headerAtPath:path options:options error:&error], (@[@"id", @"name"]), @"%@: %@", path, error);
		NSArray *rows = [SPPostgresCSV previewRowsAtPath:path options:options limit:10 error:&error];
		XCTAssertEqual(rows.count, 10u, @"%@: %@", path, error);
		XCTAssertEqualObjects(rows.firstObject[0], @"1");
		XCTAssertTrue([rows.firstObject[1] hasPrefix:@"row 7919, "], @"%@", rows.firstObject);
	}

	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self run:@"CREATE TABLE public.packed (id int, name text)" on:destination];
		for (NSString *path in @[gzPath, bzPath]) {
			[self run:@"TRUNCATE public.packed" on:destination];
			NSError *error = nil;
			__block unsigned long long lastRead = 0, lastSize = 0;
			XCTAssertTrue(([SPPostgresCSV importPath:path options:options intoTable:@"packed" schema:@"public" columnMapping:@[@0, @1]
										 connection:destination progress:^BOOL(unsigned long long bytesRead, unsigned long long fileSize) {
				lastRead = bytesRead;
				lastSize = fileSize;
				return YES;
			} error:&error]), @"%@: %@", path, error.localizedDescription);
			XCTAssertEqualObjects([self text:@"SELECT count(*) || ':' || sum(id) FROM public.packed" on:destination], @"5000:12502500", @"%@", path);
			XCTAssertEqual(lastSize, [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileSize], @"the compressed size");
			XCTAssertEqual(lastRead, lastSize, @"%@: progress counts compressed bytes", path);
		}

		[self run:@"TRUNCATE public.packed" on:destination];
		NSError *error = nil;
		XCTAssertFalse(([SPPostgresCSV importPath:halfPath options:options intoTable:@"packed" schema:@"public" columnMapping:@[@0, @1]
									  connection:destination progress:nil error:&error]));
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription hasPrefix:@"The file is damaged or truncated (near row "], @"%@", error.localizedDescription);
		XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self text:@"SELECT count(*) FROM public.packed" on:destination], @"0");
	}
}

/// R9: the unterminated-quote, invalid-UTF-8 and short-row messages count data rows (the header excluded), so they
/// name the same number for the same row, in the preview and in the import, with or without a header.
- (void)testRowNumbersCountDataRows
{
	NSData *(^bytes)(NSString *) = ^NSData *(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; };
	NSMutableData *notUTF8 = [bytes(@"a,b,c\n1,x,y\n2,") mutableCopy];
	[notUTF8 appendBytes:"\xff\xfe" length:2];
	[notUTF8 appendData:bytes(@",z\n3,w,v\n")];
	NSDictionary *files = @{
		@"quote.csv": bytes(@"a,b,c\n1,x,y\n2,\"open,z\n3,w,v\n"),
		@"utf8.csv": notUTF8,
		@"short.csv": bytes(@"a,b,c\n1,x,y\n2,z\n3,w,v\n"),
	};
	NSDictionary *expected = @{
		@"quote.csv": @"Row 2 has a quoted field that isn't closed.",
		@"utf8.csv": @"Row 2 isn't valid UTF-8 text.",
		@"short.csv": @"Row 2 has 2 fields; column “c” needs field 3.",
	};
	for (NSString *name in files) XCTAssertTrue([files[name] writeToFile:[self pathNamed:name] atomically:YES]);

	SPPostgresCSVOptions *withHeader = [SPPostgresCSVOptions new];
	SPPostgresCSVOptions *withoutHeader = [SPPostgresCSVOptions new];
	withoutHeader.header = NO;

	// The preview reports the first two
	for (NSString *name in @[@"quote.csv", @"utf8.csv"]) {
		NSError *error = nil;
		XCTAssertNil([SPPostgresCSV previewRowsAtPath:[self pathNamed:name] options:withHeader limit:10 error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, expected[name]);
		// Without a header, the first line is row 1
		error = nil;
		XCTAssertNil([SPPostgresCSV previewRowsAtPath:[self pathNamed:name] options:withoutHeader limit:10 error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, [expected[name] stringByReplacingOccurrencesOfString:@"Row 2" withString:@"Row 3"]);
	}
	NSError *headerError = nil;
	XCTAssertNil([SPPostgresCSV headerAtPath:[self write:@"a,\"b\n" named:@"badheader.csv"] options:withHeader error:&headerError]);
	XCTAssertEqualObjects(headerError.localizedDescription, @"The header row has a quoted field that isn't closed.");

	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *destination = [self database:@"pgkit_io_dst" on:port];
		[self run:@"CREATE TABLE public.numbered (a text, b text, c text)" on:destination];
		for (NSString *name in files) {
			NSError *error = nil;
			XCTAssertFalse(([SPPostgresCSV importPath:[self pathNamed:name] options:withHeader intoTable:@"numbered" schema:@"public"
										columnMapping:@[@0, @1, @2] connection:destination progress:nil error:&error]), @"%@", name);
			XCTAssertEqualObjects(error.localizedDescription, expected[name], @"%@", name);
			XCTAssertEqual(destination.transactionStatus, PGPostgresTransactionIdle);
			XCTAssertEqualObjects([self text:@"SELECT count(*) FROM public.numbered" on:destination], @"0", @"%@", name);
		}
	}
}

@end
