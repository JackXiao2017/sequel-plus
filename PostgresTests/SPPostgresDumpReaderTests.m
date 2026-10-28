#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresDumpReader.h"
#import "../Source/Postgres/SPPostgresStatementSplitter.h"

/// The parts of the app's SPFileHandle the tests use (the class isn't exported; it is looked up at run time).
@protocol SPTestFileHandle <NSObject>
+ (id)fileHandleForWritingAtPath:(NSString *)path;
- (void)setCompressionFormat:(int)format;
- (void)writeData:(NSData *)data;
- (void)closeFile;
@end

@interface SPPostgresDumpReaderTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@end

@implementation SPPostgresDumpReaderTests

- (void)setUp
{
	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
}

- (NSString *)writeText:(NSString *)text named:(NSString *)name
{
	NSString *path = [self.directory stringByAppendingPathComponent:name];
	XCTAssertTrue([[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
	return path;
}

/// Every item of the file as "kind|line|sql", with each Copy item followed by "data|<its data>".
- (NSArray<NSString *> *)itemsAtPath:(NSString *)path chunkSize:(NSUInteger)chunkSize error:(NSError **)outError
{
	NSError *error = nil;
	SPPostgresDumpReader *reader = [[SPPostgresDumpReader alloc] initWithPath:path error:&error];
	XCTAssertNotNil(reader, @"%@", error);
	if (chunkSize) reader.chunkSize = chunkSize;
	NSMutableArray *items = [NSMutableArray array];
	SPPostgresDumpItem *item;
	while ((item = [reader nextItem:&error])) {
		[items addObject:[NSString stringWithFormat:@"%ld|%lu|%@", (long)item.kind, (unsigned long)item.line, item.sql]];
		if (item.kind == SPPostgresDumpItemCopy) {
			NSMutableData *data = [NSMutableData data];
			NSData *chunk;
			while ((chunk = [reader nextCopyData:&error])) {
				XCTAssertTrue(chunk.length > 0);
				XCTAssertEqual(((const char *)chunk.bytes)[chunk.length - 1], '\n', @"chunks are whole lines");
				[data appendData:chunk];
			}
			if (error) break;
			[items addObject:[@"data|" stringByAppendingString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
		}
	}
	if (outError) *outError = error;
	else XCTAssertNil(error);
	return items;
}

#pragma mark - Splitter

- (void)testLengthOfCompleteStatements
{
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@""], 0u);
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"SELECT 1"], 0u);
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"SELECT 1;"], 9u);
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"SELECT 1; SELECT 2"], 9u);
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"SELECT 1; SELECT 'a;"], 9u, @"an open string isn't complete");
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"SELECT 1; SELECT $$ a; b"], 9u, @"an open dollar body isn't complete");
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"SELECT 1; SELECT $$ a; b $$; x"], 28u);
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfCompleteStatementsInSQL:@"CREATE FUNCTION f() RETURNS int BEGIN ATOMIC SELECT 1; "], 0u);

	NSString *sql = @"SELECT 'x;y'; SELECT 2;";
	unichar chars[64];
	[sql getCharacters:chars range:NSMakeRange(0, sql.length)];
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfFirstStatementInCharacters:chars length:sql.length], 13u);
	XCTAssertEqual([SPPostgresStatementSplitter lengthOfFirstStatementInCharacters:chars length:12], 0u);
}

#pragma mark - Reader

- (void)testSplitsStatementsAcrossTinyChunks
{
	NSString *text = @"-- leading comment; with a semicolon\n"
		@"CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$;\n"
		@"SELECT E'it\\'s; here', 'plain;''quote';\n"
		@"/* block ; comment /* nested ; */ */ SELECT 2;\n"
		@"\n"
		@"CREATE FUNCTION g() RETURNS int LANGUAGE sql\n"
		@"BEGIN ATOMIC\n"
		@"  SELECT CASE WHEN true THEN 1 ELSE 2 END;\n"
		@"  SELECT 3;\n"
		@"END;\n"
		@"SELECT $tag$ a $$ ; b $tag$ -- trailing ; comment\n"
		@";\n"
		@"SELECT 'ünïcödé 🎉;' AS \"q;\"\"\";\n"
		@"SELECT 'no semicolon at the end'\n";
	NSString *path = [self writeText:text named:@"split.sql"];

	NSArray *big = [self itemsAtPath:path chunkSize:0 error:NULL];
	NSArray *tiny = [self itemsAtPath:path chunkSize:7 error:NULL];
	NSArray *single = [self itemsAtPath:path chunkSize:1 error:NULL];
	XCTAssertEqualObjects(tiny, big);
	XCTAssertEqualObjects(single, big);

	NSArray *expected = @[
		@"0|2|CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$",
		@"0|3|SELECT E'it\\'s; here', 'plain;''quote'",
		@"0|4|SELECT 2",
		@"0|6|CREATE FUNCTION g() RETURNS int LANGUAGE sql\nBEGIN ATOMIC\n  SELECT CASE WHEN true THEN 1 ELSE 2 END;\n  SELECT 3;\nEND",
		@"0|11|SELECT $tag$ a $$ ; b $tag$ -- trailing ; comment",
		@"0|13|SELECT 'ünïcödé 🎉;' AS \"q;\"\"\"",
		@"0|14|SELECT 'no semicolon at the end'",
	];
	XCTAssertEqualObjects(big, expected);
}

- (void)testCopyBlocksAndMetaCommands
{
	NSString *text = @"\\restrict k\n"
		@"COPY t (a, b) FROM stdin;\n"
		@"1\tx\n"
		@"2\t\\\\N\n"
		@"3\t\\N\n"
		@"\\.\n"
		@"SELECT 1;\n"
		@"\\unrestrict k";
	NSString *path = [self writeText:text named:@"copy.sql"];

	NSArray *expected = @[
		@"2|1|\\restrict k",
		@"1|2|COPY t (a, b) FROM stdin",
		@"data|1\tx\n2\t\\\\N\n3\t\\N\n",
		@"0|7|SELECT 1",
		@"2|8|\\unrestrict k",
	];
	XCTAssertEqualObjects([self itemsAtPath:path chunkSize:0 error:NULL], expected);
	XCTAssertEqualObjects([self itemsAtPath:path chunkSize:7 error:NULL], expected);
	XCTAssertEqualObjects([self itemsAtPath:path chunkSize:1 error:NULL], expected);

	// An unread COPY's data is skipped
	SPPostgresDumpReader *reader = [[SPPostgresDumpReader alloc] initWithPath:path error:NULL];
	reader.chunkSize = 5;
	NSError *error = nil;
	XCTAssertEqual([reader nextItem:&error].kind, SPPostgresDumpItemMetaCommand);
	XCTAssertEqual([reader nextItem:&error].kind, SPPostgresDumpItemCopy);
	SPPostgresDumpItem *after = [reader nextItem:&error];
	XCTAssertEqualObjects(after.sql, @"SELECT 1");
	XCTAssertEqual(after.line, 7u);
	XCTAssertNil(error);
}

- (void)testMissingCopyTerminator
{
	NSString *path = [self writeText:@"SELECT 1;\n\nCOPY t FROM stdin;\n1\n2\n" named:@"open.sql"];
	for (NSNumber *size in @[@0, @3]) {
		NSError *error = nil;
		NSArray *items = [self itemsAtPath:path chunkSize:size.unsignedIntegerValue error:&error];
		XCTAssertEqual(items.count, 2u);
		XCTAssertNotNil(error);
		XCTAssertTrue([error.localizedDescription containsString:@"line 3"], @"%@", error.localizedDescription);
	}
}

- (void)testReadsGzipAndBOM
{
	NSString *text = @"CREATE TABLE a (i int);\nCOPY a FROM stdin;\n1\n\\.\nSELECT 'é🎉';\n";
	NSArray *expected = @[@"0|1|CREATE TABLE a (i int)", @"1|2|COPY a FROM stdin", @"data|1\n", @"0|5|SELECT 'é🎉'"];

	// gzip, written with the app's SPFileHandle
	Class handleClass = NSClassFromString(@"SPFileHandle");
	XCTAssertNotNil(handleClass);
	NSString *gzPath = [self.directory stringByAppendingPathComponent:@"dump.sql.gz"];
	id<SPTestFileHandle> handle = [(id)handleClass fileHandleForWritingAtPath:gzPath];
	if (!handle) {
		[[NSFileManager defaultManager] createFileAtPath:gzPath contents:nil attributes:nil];
		handle = [(id)handleClass fileHandleForWritingAtPath:gzPath];
	}
	XCTAssertNotNil(handle);
	[handle setCompressionFormat:1]; // SPGzipCompression
	[handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
	[handle closeFile];
	NSData *gz = [NSData dataWithContentsOfFile:gzPath];
	XCTAssertTrue(gz.length > 2 && ((const unsigned char *)gz.bytes)[0] == 0x1f && ((const unsigned char *)gz.bytes)[1] == 0x8b, @"gzip data");

	XCTAssertEqualObjects([self itemsAtPath:gzPath chunkSize:0 error:NULL], expected);
	XCTAssertEqualObjects([self itemsAtPath:gzPath chunkSize:4 error:NULL], expected);

	SPPostgresDumpReader *reader = [[SPPostgresDumpReader alloc] initWithPath:gzPath error:NULL];
	XCTAssertEqual(reader.fileSize, (unsigned long long)gz.length, @"the compressed size");
	while ([reader nextItem:NULL]) { while ([reader nextCopyData:NULL]) {} }
	XCTAssertEqual(reader.bytesRead, (unsigned long long)gz.length);

	// A byte order mark is skipped
	NSString *bomPath = [self writeText:[@"\uFEFF" stringByAppendingString:text] named:@"bom.sql"];
	NSData *bom = [NSData dataWithContentsOfFile:bomPath];
	XCTAssertEqual(((const unsigned char *)bom.bytes)[0], 0xEF);
	XCTAssertEqualObjects([self itemsAtPath:bomPath chunkSize:0 error:NULL], expected);
	XCTAssertEqualObjects([self itemsAtPath:bomPath chunkSize:1 error:NULL], expected);

	// Not found
	NSError *error = nil;
	XCTAssertNil([[SPPostgresDumpReader alloc] initWithPath:[self.directory stringByAppendingPathComponent:@"none.sql"] error:&error]);
	XCTAssertNotNil(error);
}

@end
