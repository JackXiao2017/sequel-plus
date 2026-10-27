#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresStatementSplitter.h"

@interface SPPostgresStatementSplitterTests : XCTestCase
@end

@implementation SPPostgresStatementSplitterTests

- (NSArray *)split:(NSString *)sql
{
	return [SPPostgresStatementSplitter statementsInSQL:sql];
}

/// The statement Run Current would run with the cursor at location (nil if none).
- (NSString *)statementAt:(NSUInteger)location inSQL:(NSString *)sql
{
	NSRange range = [SPPostgresStatementSplitter rangeOfStatementAtLocation:location inSQL:sql];
	if (range.location == NSNotFound) return nil;
	return [sql substringWithRange:range];
}

- (void)testSplitsSimple
{
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT 2;"], (@[@"SELECT 1", @"SELECT 2"]));
	XCTAssertEqualObjects([self split:@"  SELECT 1 ;\n\n  ;; SELECT 2\n;\n"], (@[@"SELECT 1", @"SELECT 2"]), @"trimmed, empty statements dropped");
	XCTAssertEqualObjects([self split:@""], @[]);
	XCTAssertEqualObjects([self split:@" ; \n ;"], @[]);
	XCTAssertEqualObjects([self split:nil], @[]);
}

- (void)testSemicolonInSingleQuotes
{
	XCTAssertEqualObjects([self split:@"SELECT 'a;b'; SELECT 'it''s; here'"], (@[@"SELECT 'a;b'", @"SELECT 'it''s; here'"]));
	// A standard string ends at its quote even after a backslash (standard_conforming_strings)
	XCTAssertEqualObjects([self split:@"SELECT 'C:\\'; SELECT 2"], (@[@"SELECT 'C:\\'", @"SELECT 2"]));
	// Quoted identifiers
	XCTAssertEqualObjects([self split:@"SELECT 1 AS \"a;\"\"b\"; SELECT 2"], (@[@"SELECT 1 AS \"a;\"\"b\"", @"SELECT 2"]));
}

- (void)testEscapeStringBackslashQuote
{
	XCTAssertEqualObjects([self split:@"SELECT E'it\\'s; ok'; SELECT 2"], (@[@"SELECT E'it\\'s; ok'", @"SELECT 2"]));
	XCTAssertEqualObjects([self split:@"SELECT e'\\\\'; SELECT 2"], (@[@"SELECT e'\\\\'", @"SELECT 2"]), @"an escaped backslash ends before the quote");
	XCTAssertEqualObjects([self split:@"SELECT E'a''b;c'; SELECT 2"], (@[@"SELECT E'a''b;c'", @"SELECT 2"]));
	// An identifier ending in e is not an E string prefix
	XCTAssertEqualObjects([self split:@"SELECT name'\\'; SELECT 2"], (@[@"SELECT name'\\'", @"SELECT 2"]));
}

- (void)testDollarQuotedFunctionBody
{
	NSString *function = @"CREATE FUNCTION content_test.f() RETURNS int AS $$ BEGIN PERFORM 1; RETURN 2; END $$ LANGUAGE plpgsql";
	NSArray *statements = [self split:[function stringByAppendingString:@";\nSELECT content_test.f();"]];
	XCTAssertEqual(statements.count, 2u);
	XCTAssertEqualObjects(statements.firstObject, function);
	XCTAssertEqualObjects(statements.lastObject, @"SELECT content_test.f()");
}

- (void)testTaggedDollarQuote
{
	NSString *body = @"DO $body$ BEGIN RAISE NOTICE '$$;'; END $body$";
	XCTAssertEqualObjects([self split:[body stringByAppendingString:@"; SELECT 2"]], (@[body, @"SELECT 2"]));
	// Nested different tags
	NSString *nested = @"SELECT $a$ x $b$ ; $b$ ; $a$";
	XCTAssertEqualObjects([self split:[nested stringByAppendingString:@";SELECT 3"]], (@[nested, @"SELECT 3"]));
	// $1 parameters and identifiers containing $ are not dollar quotes
	XCTAssertEqualObjects([self split:@"SELECT $1; SELECT a$b$c FROM t; SELECT 3"], (@[@"SELECT $1", @"SELECT a$b$c FROM t", @"SELECT 3"]));
}

- (void)testLineAndNestedBlockComments
{
	XCTAssertEqualObjects([self split:@"SELECT 1 -- a; comment\n; SELECT 2"], (@[@"SELECT 1 -- a; comment", @"SELECT 2"]));
	XCTAssertEqualObjects([self split:@"SELECT /* a; /* nested; */ still; */ 1; SELECT 2"], (@[@"SELECT /* a; /* nested; */ still; */ 1", @"SELECT 2"]));
	// Comments alone are not statements
	XCTAssertEqualObjects([self split:@"SELECT 1; -- done;\n/* end; */"], (@[@"SELECT 1"]));
	// A quote inside a comment opens nothing
	XCTAssertEqualObjects([self split:@"SELECT 1 -- it's\n; SELECT '/*'; SELECT 3"], (@[@"SELECT 1 -- it's", @"SELECT '/*'", @"SELECT 3"]));
}

- (void)testTrailingNoSemicolon
{
	XCTAssertEqualObjects([self split:@"SELECT 1;\nSELECT 2"], (@[@"SELECT 1", @"SELECT 2"]));
	XCTAssertEqualObjects([self split:@"SELECT 1"], (@[@"SELECT 1"]));
}

- (void)testUnterminatedQuotesAndCommentsRunToTheEnd
{
	// Must neither hang nor crash: the rest of the text is one statement (the server reports the error)
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT 'abc; SELECT 3"], (@[@"SELECT 1", @"SELECT 'abc; SELECT 3"]));
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT E'ab\\"], (@[@"SELECT 1", @"SELECT E'ab\\"]));
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT \"x; y"], (@[@"SELECT 1", @"SELECT \"x; y"]));
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT $t$ x; y"], (@[@"SELECT 1", @"SELECT $t$ x; y"]));
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT 2 /* x; /* y */ ; z"], (@[@"SELECT 1", @"SELECT 2 /* x; /* y */ ; z"]));
	XCTAssertEqualObjects([self split:@"SELECT 1; SELECT 2 -- x; y"], (@[@"SELECT 1", @"SELECT 2 -- x; y"]));
	for (NSString *odd in @[@"'", @"E'", @"E'\\", @"\"", @"$", @"$$", @"$a", @"$a$", @"/*", @"/", @"-", @"--", @"*/", @"$1$"]) {
		XCTAssertNoThrow([self split:odd], @"%@", odd);
		XCTAssertNoThrow([SPPostgresStatementSplitter rangeOfStatementAtLocation:[odd length] inSQL:odd], @"%@", odd);
	}
}

- (void)testBeginAtomicFunctionBody
{
	NSString *function = @"CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END";
	XCTAssertEqualObjects([self split:[function stringByAppendingString:@"; SELECT 3;"]], (@[function, @"SELECT 3"]));

	// Any case, comments between the words, CASE … END inside the body
	NSString *withCase = @"CREATE PROCEDURE p() begin /* x */ -- y\n atomic SELECT CASE WHEN true THEN 1 END; INSERT INTO t VALUES (2); end";
	XCTAssertEqualObjects([self split:[withCase stringByAppendingString:@";SELECT 3"]], (@[withCase, @"SELECT 3"]));

	// Transactions and ordinary words are not bodies
	XCTAssertEqualObjects([self split:@"BEGIN; SELECT 1; COMMIT;"], (@[@"BEGIN", @"SELECT 1", @"COMMIT"]));
	XCTAssertEqualObjects([self split:@"BEGIN; SELECT 1; END;"], (@[@"BEGIN", @"SELECT 1", @"END"]));
	XCTAssertEqualObjects([self split:@"BEGIN TRANSACTION; SELECT CASE WHEN true THEN 1 END; END"], (@[@"BEGIN TRANSACTION", @"SELECT CASE WHEN true THEN 1 END", @"END"]));
	XCTAssertEqualObjects([self split:@"SELECT begin, atomic, \"end\" FROM t; SELECT 2"], (@[@"SELECT begin, atomic, \"end\" FROM t", @"SELECT 2"]));
	XCTAssertEqualObjects([self split:@"SELECT 'BEGIN ATOMIC'; SELECT 2"], (@[@"SELECT 'BEGIN ATOMIC'", @"SELECT 2"]));
	XCTAssertEqualObjects([self split:@"SELECT xbegin atomic; SELECT 2"], (@[@"SELECT xbegin atomic", @"SELECT 2"]));

	// Run Current inside the body: the whole CREATE
	NSString *sql = [function stringByAppendingString:@";\nSELECT 3"];
	NSRange range = [SPPostgresStatementSplitter rangeOfStatementAtLocation:[sql rangeOfString:@"SELECT 2"].location inSQL:sql];
	XCTAssertEqualObjects([sql substringWithRange:range], function);

	// Unterminated: the rest is one statement
	XCTAssertEqualObjects([self split:@"SELECT 0; CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2"],
						  (@[@"SELECT 0", @"CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2"]));
}

- (void)testRangeOfStatementAtCursor
{
	NSString *sql = @"SELECT 1;\n  SELECT 'a;b' ;\n\nSELECT 3";
	XCTAssertEqualObjects([self statementAt:0 inSQL:sql], @"SELECT 1");
	XCTAssertEqualObjects([self statementAt:4 inSQL:sql], @"SELECT 1");
	XCTAssertEqualObjects([self statementAt:9 inSQL:sql], @"SELECT 1", @"just after the semicolon: the statement it ends");
	XCTAssertEqualObjects([self statementAt:10 inSQL:sql], @"SELECT 'a;b'", @"the next line");
	NSUInteger inQuote = [sql rangeOfString:@"a;b"].location + 1;
	XCTAssertEqualObjects([self statementAt:inQuote inSQL:sql], @"SELECT 'a;b'");
	XCTAssertEqualObjects([self statementAt:[sql length] inSQL:sql], @"SELECT 3");
	XCTAssertEqualObjects([self statementAt:[sql length] - 2 inSQL:sql], @"SELECT 3");

	// After the last semicolon, only whitespace or comments follow: the statement before
	NSString *trailing = @"SELECT 1; SELECT 2;\n -- end\n";
	XCTAssertEqualObjects([self statementAt:[trailing length] inSQL:trailing], @"SELECT 2");

	// No statement at all
	XCTAssertEqual([SPPostgresStatementSplitter rangeOfStatementAtLocation:0 inSQL:@"  -- x\n"].location, (NSUInteger)NSNotFound);
	XCTAssertEqual([SPPostgresStatementSplitter rangeOfStatementAtLocation:0 inSQL:@""].location, (NSUInteger)NSNotFound);
	// Beyond the end: clamped
	XCTAssertEqualObjects([self statementAt:999 inSQL:@"SELECT 9"], @"SELECT 9");
}

@end
