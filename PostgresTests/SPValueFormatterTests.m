//
//  SPValueFormatterTests.m
//  Sequel Plus
//
//  The value popover's formatter: pretty and compact for JSON, XML and HTML change only whitespace between
//  tokens and tags (docs/superpowers/specs/2026-11-22-long-text-value-popover-design.md).
//

#import <XCTest/XCTest.h>
#import "../Source/SPValueFormatter.h"

@interface SPValueFormatterTests : XCTestCase
@end

@implementation SPValueFormatterTests

- (NSString *)pretty:(NSString *)text format:(SPValueFormat)format
{
	NSString *error = nil;
	NSString *result = [SPValueFormatter prettyString:text format:format error:&error];
	XCTAssertNotNil(result, @"%@", error);
	XCTAssertNil(error);
	return result;
}

- (NSString *)compact:(NSString *)text format:(SPValueFormat)format
{
	NSString *error = nil;
	NSString *result = [SPValueFormatter compactString:text format:format error:&error];
	XCTAssertNotNil(result, @"%@", error);
	XCTAssertNil(error);
	return result;
}

#pragma mark - JSON

- (void)testJSONPrettyIndentsWithFourSpaces
{
	XCTAssertEqualObjects([self pretty:@"{\"a\":1,\"b\":[1,2],\"c\":{}}" format:SPValueFormatJSON],
						  @"{\n    \"a\": 1,\n    \"b\": [\n        1,\n        2\n    ],\n    \"c\": {}\n}");
}

- (void)testJSONKeepsKeyOrderDuplicatesAndNumberText
{
	NSString *json = @"{\"z\":1.0,\"a\":1e3,\"z\":2}";
	NSString *pretty = [self pretty:json format:SPValueFormatJSON];
	XCTAssertEqualObjects([self compact:pretty format:SPValueFormatJSON], json);
}

- (void)testJSONStringsAreUntouched
{
	NSString *member = @"\"x{, \\\"y\\\": [1]}\\n\\t  \"";
	NSString *json = [NSString stringWithFormat:@"{ \"s\" : %@ , \"t\":[ %@ ] }", member, member];
	NSString *pretty = [self pretty:json format:SPValueFormatJSON];
	NSString *compact = [self compact:json format:SPValueFormatJSON];
	XCTAssertEqualObjects(compact, ([NSString stringWithFormat:@"{\"s\":%@,\"t\":[%@]}", member, member]));
	XCTAssertTrue(([pretty containsString:[NSString stringWithFormat:@"\"s\": %@", member]]), @"%@", pretty);
	XCTAssertEqualObjects([self compact:pretty format:SPValueFormatJSON], compact);
}

- (void)testJSONInvalidReportsError
{
	NSString *error = nil;
	XCTAssertNil([SPValueFormatter prettyString:@"{\"a\":}" format:SPValueFormatJSON error:&error]);
	XCTAssertTrue([error hasPrefix:@"Not valid JSON"], @"%@", error);
	error = nil;
	XCTAssertNil([SPValueFormatter compactString:@"{\"a\":}" format:SPValueFormatJSON error:&error]);
	XCTAssertTrue([error hasPrefix:@"Not valid JSON"], @"%@", error);
}

#pragma mark - XML

- (void)testXMLElementOnlyContentIndents
{
	XCTAssertEqualObjects([self pretty:@"<a><b>1</b><c/></a>" format:SPValueFormatXML], @"<a>\n    <b>1</b>\n    <c/>\n</a>");
}

- (void)testXMLMixedContentKeptAsIs
{
	NSString *xml = @"<p>Hello <b>x</b> world</p>";
	XCTAssertEqualObjects([self pretty:xml format:SPValueFormatXML], xml);
	XCTAssertEqualObjects([self compact:xml format:SPValueFormatXML], xml);
}

- (void)testXMLPreservesEntitiesCommentsCDATA
{
	NSString *xml = @"<a><!-- c --><b>&amp;&#x41;</b><![CDATA[ <x> ]]></a>";
	NSString *pretty = [self pretty:xml format:SPValueFormatXML];
	XCTAssertTrue([pretty containsString:@"<!-- c -->"]);
	XCTAssertTrue([pretty containsString:@"<b>&amp;&#x41;</b>"]);
	XCTAssertTrue([pretty containsString:@"<![CDATA[ <x> ]]>"]);
	XCTAssertEqualObjects([self compact:pretty format:SPValueFormatXML], xml);
}

- (void)testXMLSpacePreserveUntouched
{
	NSString *xml = @"<a><b xml:space=\"preserve\">\n  <c/>\n  <d/>\n</b><e/></a>";
	NSString *pretty = [self pretty:xml format:SPValueFormatXML];
	XCTAssertTrue([pretty containsString:@"<b xml:space=\"preserve\">\n  <c/>\n  <d/>\n</b>"], @"%@", pretty);
	XCTAssertEqualObjects([self compact:pretty format:SPValueFormatXML], xml);
}

- (void)testXMLDeclarationAndAttributesKept
{
	NSString *xml = @"<?xml version='1.0'?><a x='1' y=\"&quot;\"><b/></a>";
	XCTAssertEqualObjects([self pretty:xml format:SPValueFormatXML], @"<?xml version='1.0'?>\n<a x='1' y=\"&quot;\">\n    <b/>\n</a>");
}

- (void)testXMLInvalidReportsError
{
	NSString *error = nil;
	XCTAssertNil([SPValueFormatter prettyString:@"<a><b></a>" format:SPValueFormatXML error:&error]);
	XCTAssertTrue([error hasPrefix:@"Not valid XML"], @"%@", error);
	error = nil;
	XCTAssertNil([SPValueFormatter prettyString:@"<a>" format:SPValueFormatXML error:&error]);
	XCTAssertTrue([error hasPrefix:@"Not valid XML"], @"%@", error);
}

#pragma mark - HTML

- (void)testHTMLBreaksOnlyAroundBlocks
{
	XCTAssertEqualObjects([self pretty:@"<div><p>a <b>b</b></p><p>c</p></div>" format:SPValueFormatHTML],
						  @"<div>\n    <p>a <b>b</b></p>\n    <p>c</p>\n</div>");
}

- (void)testHTMLVoidAndPreservedElements
{
	NSString *html = @"<div><br><pre>  x\n y</pre><script>if(a<b){}</script></div>";
	NSString *pretty = [self pretty:html format:SPValueFormatHTML];
	XCTAssertTrue([pretty containsString:@"<pre>  x\n y</pre>"], @"%@", pretty);
	XCTAssertTrue([pretty containsString:@"<script>if(a<b){}</script>"], @"%@", pretty);
	XCTAssertFalse([pretty containsString:@"</br>"]);
	XCTAssertEqualObjects([self compact:pretty format:SPValueFormatHTML], html);
}

- (void)testHTMLUnclosedTagsTolerated
{
	NSString *error = nil;
	XCTAssertNotNil([SPValueFormatter prettyString:@"<div><p>a<div>b" format:SPValueFormatHTML error:&error]);
	XCTAssertNil(error);
	XCTAssertNotNil([SPValueFormatter prettyString:@"</div>x<" format:SPValueFormatHTML error:&error]);
	XCTAssertNil(error);
}

#pragma mark - Round trips

- (void)testCompactRoundTrips
{
	NSDictionary<NSNumber *, NSArray<NSString *> *> *fixtures = @{
		@(SPValueFormatJSON): @[@"{\"a\":1,\"b\":[1,2],\"c\":{}}", @"[ ]", @"\"s\"", @"[{\"k\":[true,false,null]}]"],
		@(SPValueFormatXML): @[@"<a><b>1</b><c/></a>", @"<p>Hello <b>x</b> world</p>", @"<a>\n  <b/>\n</a>"],
		@(SPValueFormatHTML): @[@"<div><p>a <b>b</b></p><p>c</p></div>", @"<ul>\n<li>1</li>\n<li>2</li></ul>"],
	};
	for (NSNumber *format in fixtures) {
		for (NSString *text in fixtures[format]) {
			SPValueFormat f = (SPValueFormat)[format integerValue];
			XCTAssertEqualObjects([self compact:[self pretty:text format:f] format:f], [self compact:text format:f], @"%@", text);
		}
	}
}

#pragma mark - Deep nesting

/// Formats on a GCD worker (512 KB stack), as the popover does for a long value; YES when it finished.
- (BOOL)formatOnWorker:(NSString *)text format:(SPValueFormat)format pretty:(BOOL)pretty
{
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSString *result = nil;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			result = pretty ? [SPValueFormatter prettyString:text format:format error:NULL] : [SPValueFormatter compactString:text format:format error:NULL];
		}
		dispatch_semaphore_signal(done);
	});
	return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0 && result != nil;
}

- (void)testDeeplyNestedUnclosedHTMLDoesNotCrash
{
	NSString *html = [@"" stringByPaddingToLength:20000 * 5 withString:@"<div>" startingAtIndex:0]; // 20,000 levels, never closed
	XCTAssertTrue([self formatOnWorker:html format:SPValueFormatHTML pretty:YES]);
	XCTAssertTrue([self formatOnWorker:html format:SPValueFormatHTML pretty:NO]);
	NSString *items = [@"<ul>" stringByAppendingString:[@"" stringByPaddingToLength:20000 * 6 withString:@"<li>x " startingAtIndex:0]];
	XCTAssertTrue([self formatOnWorker:items format:SPValueFormatHTML pretty:YES]);
}

- (void)testDeeplyNestedXMLDoesNotCrash
{
	NSUInteger depth = 20000;
	NSMutableString *xml = [NSMutableString string];
	for (NSUInteger i = 0; i < depth; i++) [xml appendString:@"<a>"];
	for (NSUInteger i = 0; i < depth; i++) [xml appendString:@"</a>"];
	XCTAssertTrue([self formatOnWorker:xml format:SPValueFormatXML pretty:YES]);
	XCTAssertTrue([self formatOnWorker:xml format:SPValueFormatXML pretty:NO]);
	// Still only whitespace changes
	NSString *compact = [SPValueFormatter compactString:[SPValueFormatter prettyString:xml format:SPValueFormatXML error:NULL] format:SPValueFormatXML error:NULL];
	XCTAssertEqualObjects(compact, xml);
}

- (void)testManyStrayEndTagsInDeepHTMLStayFast
{
	NSMutableString *html = [NSMutableString string];
	for (NSUInteger i = 0; i < 5000; i++) [html appendString:@"<div>"];
	for (NSUInteger i = 0; i < 20000; i++) [html appendString:@"</span>"];
	NSDate *start = [NSDate date];
	XCTAssertNotNil([SPValueFormatter prettyString:html format:SPValueFormatHTML error:NULL]);
	XCTAssertLessThan(-[start timeIntervalSinceNow], 2.0);
}

@end
