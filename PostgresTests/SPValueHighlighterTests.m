//
//  SPValueHighlighterTests.m
//  Sequel Plus
//
//  The value popover's colors: which parts of JSON, XML and HTML text get which color.
//

#import <XCTest/XCTest.h>
#import "../Source/SPValueHighlighter.h"

@interface SPValueHighlighterTests : XCTestCase
@end

@implementation SPValueHighlighterTests

/// "kind:text" for every token, in order.
- (NSArray<NSString *> *)tokensOf:(NSString *)text format:(SPValueFormat)format
{
	NSArray<NSString *> *names = @[@"key", @"string", @"number", @"literal", @"tag", @"attribute", @"value", @"comment", @"entity", @"declaration"];
	NSMutableArray *result = [NSMutableArray array];
	for (SPValueToken *token in [SPValueHighlighter tokensInText:text format:format]) {
		[result addObject:[NSString stringWithFormat:@"%@:%@", names[(NSUInteger)token.kind], [text substringWithRange:token.range]]];
	}
	return result;
}

- (void)testJSONKeysStringsNumbersLiterals
{
	NSString *json = @"{\n    \"id\": 42,\n    \"name\": \"A \\\"b\\\"\",\n    \"ok\": true,\n    \"x\": [-1.5e3, null, false]\n}";
	XCTAssertEqualObjects([self tokensOf:json format:SPValueFormatJSON], (@[@"key:\"id\"", @"number:42", @"key:\"name\"", @"string:\"A \\\"b\\\"\"",
		@"key:\"ok\"", @"literal:true", @"key:\"x\"", @"number:-1.5e3", @"literal:null", @"literal:false"]));
}

- (void)testJSONKeyWithSpaceBeforeColon
{
	XCTAssertEqualObjects([self tokensOf:@"{\"a\" : \"b\"}" format:SPValueFormatJSON], (@[@"key:\"a\"", @"string:\"b\""]));
}

- (void)testJSONUnterminatedStringDoesNotRunPastTheEnd
{
	XCTAssertEqualObjects([self tokensOf:@"{\"a\": \"bc" format:SPValueFormatJSON], (@[@"key:\"a\"", @"string:\"bc"]));
}

- (void)testXMLTagsAttributesValuesEntities
{
	NSString *xml = @"<?xml version=\"1.0\"?>\n<a x='1' y=\"&quot;\">\n    <b>&amp; text</b>\n    <!-- note -->\n    <![CDATA[ <raw> ]]>\n</a>";
	XCTAssertEqualObjects([self tokensOf:xml format:SPValueFormatXML], (@[@"declaration:<?xml version=\"1.0\"?>",
		@"tag:<a", @"attribute:x", @"value:'1'", @"attribute:y", @"value:\"&quot;\"", @"tag:>",
		@"tag:<b", @"tag:>", @"entity:&amp;", @"tag:</b", @"tag:>",
		@"comment:<!-- note -->", @"comment:<![CDATA[ <raw> ]]>", @"tag:</a", @"tag:>"]));
}

- (void)testSelfClosingAndUnquotedHTMLAttributes
{
	XCTAssertEqualObjects([self tokensOf:@"<br/><input type=text disabled>" format:SPValueFormatHTML],
						  (@[@"tag:<br", @"tag:/>", @"tag:<input", @"attribute:type", @"value:text", @"attribute:disabled", @"tag:>"]));
}

- (void)testHTMLScriptAndStyleContentsAreLeftPlain
{
	XCTAssertEqualObjects([self tokensOf:@"<script>if (a<b) {}</script><!DOCTYPE html>" format:SPValueFormatHTML],
						  (@[@"tag:<script", @"tag:>", @"tag:</script", @"tag:>", @"declaration:<!DOCTYPE html>"]));
}

- (void)testMalformedMarkupDoesNotRunPastTheEnd
{
	XCTAssertEqualObjects([self tokensOf:@"a < b <c d=\"e" format:SPValueFormatHTML], (@[@"tag:<c", @"attribute:d", @"value:\"e"]));
	XCTAssertEqualObjects([self tokensOf:@"<!-- open" format:SPValueFormatXML], (@[@"comment:<!-- open"]));
}

- (void)testEveryKindHasAColor
{
	for (NSInteger kind = SPValueTokenKey; kind <= SPValueTokenDeclaration; kind++) {
		XCTAssertNotNil([SPValueHighlighter colorForKind:(SPValueTokenKind)kind]);
	}
}

#pragma mark - Fold regions

/// What each fold region hides, in order of where it starts.
- (NSArray<NSString *> *)hiddenTextsIn:(NSString *)text format:(SPValueFormat)format
{
	NSMutableArray *result = [NSMutableArray array];
	for (NSValue *range in [SPValueHighlighter foldRangesInText:text format:format]) [result addObject:[text substringWithRange:[range rangeValue]]];
	return result;
}

- (void)testJSONFoldsMultiLineObjectsAndArrays
{
	NSString *json = @"{\n    \"a\": [\n        1,\n        2\n    ],\n    \"b\": {},\n    \"c\": \"}{\"\n}";
	XCTAssertEqualObjects([self hiddenTextsIn:json format:SPValueFormatJSON],
						  (@[@"\n    \"a\": [\n        1,\n        2\n    ],\n    \"b\": {},\n    \"c\": \"}{\"\n", @"\n        1,\n        2\n    "]),
						  @"between the brackets; one-line {} and brackets in strings don't fold");
}

- (void)testJSONOnOneLineHasNoFolds
{
	XCTAssertEqualObjects([self hiddenTextsIn:@"{\"a\":[1,2],\"b\":{\"c\":1}}" format:SPValueFormatJSON], @[]);
}

- (void)testXMLFoldsMultiLineElementsAndComments
{
	NSString *xml = @"<a>\n    <b>1</b>\n    <c x=\"1\">\n        <d/>\n    </c>\n    <!-- one\n    two -->\n</a>";
	XCTAssertEqualObjects([self hiddenTextsIn:xml format:SPValueFormatXML],
						  (@[@"\n    <b>1</b>\n    <c x=\"1\">\n        <d/>\n    </c>\n    <!-- one\n    two -->\n", @"\n        <d/>\n    ", @" one\n    two "]));
}

- (void)testHTMLVoidElementsDoNotOpenFolds
{
	NSString *html = @"<div>\n    <br>\n    <img src=\"x\">\n    <p>a</p>\n</div>";
	XCTAssertEqualObjects([self hiddenTextsIn:html format:SPValueFormatHTML], (@[@"\n    <br>\n    <img src=\"x\">\n    <p>a</p>\n"]));
}

- (void)testUnbalancedMarkupFoldsWhatCloses
{
	XCTAssertEqualObjects([self hiddenTextsIn:@"<a>\n<b>\n</a>" format:SPValueFormatHTML], (@[@"\n<b>\n"]));
	XCTAssertEqualObjects([self hiddenTextsIn:@"<a>\n<b>\n" format:SPValueFormatXML], @[]);
}

@end
