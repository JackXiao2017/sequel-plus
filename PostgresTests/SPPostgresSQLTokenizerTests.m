#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresSQLTokenizer.h"

// Looked up by name: until the app itself uses the tokenizer, the app binary doesn't export its class
// symbol to the test bundle's linker (the class is still registered at runtime).
#define SPTokenizer ((Class<SPTokenizerAPI>)NSClassFromString(@"SPPostgresSQLTokenizer"))

@protocol SPTokenizerAPI
+ (NSArray<SPPostgresSQLToken *> *)tokensInString:(NSString *)string range:(NSRange)range;
+ (NSSet<NSString *> *)keywords;
+ (NSArray<NSString *> *)functionNames;
@end

@interface SPPostgresSQLTokenizerTests : XCTestCase
@end

@implementation SPPostgresSQLTokenizerTests

- (NSArray *)tokens:(NSString *)sql
{
	return [SPTokenizer tokensInString:sql range:NSMakeRange(0, sql.length)];
}

/// Kinds of the tokens that aren't whitespace.
- (NSArray *)kinds:(NSString *)sql
{
	NSMutableArray *kinds = [NSMutableArray array];
	for (SPPostgresSQLToken *token in [self tokens:sql]) {
		if (token.kind != SPPostgresTokenWhitespace) [kinds addObject:@(token.kind)];
	}
	return kinds;
}

- (void)testKindsOfEachToken
{
	NSString *sql = @"SELECT \"Name\", 'it''s', E'a\\'b', $f$x$f$, 1.5e3, $1 FROM t -- c";
	NSArray *tokens = [self tokens:sql];
	NSArray *expected = @[
		@(SPPostgresTokenKeyword), @(SPPostgresTokenWhitespace), @(SPPostgresTokenQuotedIdentifier), @(SPPostgresTokenOther),
		@(SPPostgresTokenWhitespace), @(SPPostgresTokenString), @(SPPostgresTokenOther), @(SPPostgresTokenWhitespace),
		@(SPPostgresTokenString), @(SPPostgresTokenOther), @(SPPostgresTokenWhitespace), @(SPPostgresTokenString),
		@(SPPostgresTokenOther), @(SPPostgresTokenWhitespace), @(SPPostgresTokenNumber), @(SPPostgresTokenOther),
		@(SPPostgresTokenWhitespace), @(SPPostgresTokenParameter), @(SPPostgresTokenWhitespace), @(SPPostgresTokenKeyword),
		@(SPPostgresTokenWhitespace), @(SPPostgresTokenIdentifier), @(SPPostgresTokenWhitespace), @(SPPostgresTokenComment)];
	NSMutableArray *kinds = [NSMutableArray array];
	NSUInteger position = 0;
	for (SPPostgresSQLToken *token in tokens) {
		[kinds addObject:@(token.kind)];
		XCTAssertEqual(token.range.location, position, @"no gaps");
		position = NSMaxRange(token.range);
	}
	XCTAssertEqual(position, sql.length, @"covers the text");
	XCTAssertEqualObjects(kinds, expected);

	SPPostgresSQLToken *escaped = tokens[8];
	XCTAssertEqualObjects([sql substringWithRange:escaped.range], @"E'a\\'b'");
}

- (void)testNumbers
{
	XCTAssertEqualObjects([self kinds:@".5"], @[@(SPPostgresTokenNumber)]);
	XCTAssertEqualObjects([self kinds:@"1.5e-3"], @[@(SPPostgresTokenNumber)]);
	XCTAssertEqualObjects([self kinds:@"0x1F"], (@[@(SPPostgresTokenNumber), @(SPPostgresTokenIdentifier)]));
	XCTAssertEqualObjects([self kinds:@"t1"], @[@(SPPostgresTokenIdentifier)]);
}

- (void)testNestedBlockComments
{
	NSArray *tokens = [self tokens:@"/* a /* b */ c */ SELECT"];
	XCTAssertEqual(tokens.count, 3u);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).kind, SPPostgresTokenComment);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).range.length, 17u);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[1]).kind, SPPostgresTokenWhitespace);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[2]).kind, SPPostgresTokenKeyword);
}

- (void)testDollarTagsMustMatch
{
	NSArray *tokens = [self tokens:@"$a$ $b$ $a$"];
	XCTAssertEqual(tokens.count, 1u);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).kind, SPPostgresTokenString);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).range.length, 11u);
}

- (void)testUnterminatedTokensRunToEnd
{
	NSDictionary *cases = @{@"'abc": @(SPPostgresTokenString), @"$x$abc": @(SPPostgresTokenString),
		@"/* abc": @(SPPostgresTokenComment), @"\"abc": @(SPPostgresTokenQuotedIdentifier), @"E'abc\\": @(SPPostgresTokenString)};
	for (NSString *sql in cases) {
		NSArray *tokens = [self tokens:sql];
		XCTAssertEqual(tokens.count, 1u, @"%@", sql);
		XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).kind, (SPPostgresTokenKind)[cases[sql] unsignedIntegerValue], @"%@", sql);
		XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).range.length, sql.length, @"%@", sql);
	}
}

- (void)testKeywordsAreCaseInsensitiveAndTypesIncluded
{
	for (NSString *word in @[@"select", @"SeLeCt", @"integer", @"timestamptz", @"returning"]) {
		XCTAssertEqualObjects([self kinds:word], @[@(SPPostgresTokenKeyword)], @"%@", word);
	}
	XCTAssertEqualObjects([self kinds:@"items"], @[@(SPPostgresTokenIdentifier)]);
}

- (void)testSubrangeTokenizing
{
	NSString *sql = @"SELECT a FROM b";
	NSArray *tokens = [SPTokenizer tokensInString:sql range:NSMakeRange(7, 8)];
	XCTAssertEqual(((SPPostgresSQLToken *)tokens.firstObject).range.location, 7u);
	XCTAssertEqual(NSMaxRange(((SPPostgresSQLToken *)tokens.lastObject).range), 15u);
	NSUInteger total = 0;
	for (SPPostgresSQLToken *token in tokens) total += token.range.length;
	XCTAssertEqual(total, 8u);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[0]).kind, SPPostgresTokenIdentifier);
	XCTAssertEqual(((SPPostgresSQLToken *)tokens[2]).kind, SPPostgresTokenKeyword);
}

- (void)testWordLists
{
	XCTAssertTrue([[SPTokenizer keywords] containsObject:@"select"]);
	XCTAssertTrue([[SPTokenizer keywords] containsObject:@"bigint"]);
	NSArray *names = [SPTokenizer functionNames];
	XCTAssertTrue([names containsObject:@"count"]);
	XCTAssertTrue([names containsObject:@"pg_sleep"]);
	XCTAssertFalse([names containsObject:@"pg_stat_get_activity"]);
	XCTAssertEqualObjects(names, [names sortedArrayUsingSelector:@selector(compare:)]);
	for (NSString *name in names) XCTAssertEqualObjects(name, name.lowercaseString);
}

- (void)testLargeTextIsLinear
{
	NSMutableString *sql = [NSMutableString string];
	for (int i = 0; i < 100000; i++) [sql appendString:@"SELECT 'a'; "];
	[sql appendString:@"/* open"];
	NSArray *tokens = [self tokens:sql];
	XCTAssertEqual(((SPPostgresSQLToken *)tokens.lastObject).kind, SPPostgresTokenComment);
}

@end
