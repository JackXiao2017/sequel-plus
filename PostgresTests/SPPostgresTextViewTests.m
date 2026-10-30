#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresTextView.h"

// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPTextViewTestFontKey = @"CustomQueryEditorFont";
static NSString * const SPTextViewTestTextColorKey = @"CustomQueryEditorTextColor";
static NSString * const SPTextViewTestCommentColorKey = @"CustomQueryEditorCommentColor";
static NSString * const SPTextViewTestKeywordColorKey = @"CustomQueryEditorSQLKeywordColor";
static NSString * const SPTextViewTestNumericColorKey = @"CustomQueryEditorNumericColor";
static NSString * const SPTextViewTestQuoteColorKey = @"CustomQueryEditorQuoteColor";
static NSString * const SPTextViewTestBacktickColorKey = @"CustomQueryEditorBacktickColor";
static NSString * const SPTextViewTestVariableColorKey = @"CustomQueryEditorVariableColor";
static NSString * const SPTextViewTestAutoIndentKey = @"CustomQueryAutoIndent";
static NSString * const SPTextViewTestAutoPairKey = @"CustomQueryAutoPairCharacters";
static NSString * const SPTextViewTestAutoUppercaseKey = @"CustomQueryAutoUppercaseKeywords";
static NSString * const SPTextViewTestAutoHelpKey = @"CustomQueryUpdateAutoHelp";
static NSString * const SPTextViewTestAutoCompleteKey = @"CustomQueryAutoComplete";
static NSString * const SPTextViewTestHighlightQueryKey = @"CustomQueryHighlightCurrentQuery";

/// The Query editor (Stage 11 Task 4): MySQL's SPTextView with Postgres colouring, auto-uppercase, auto-pair and
/// indent. The Query view is built (without a connection) in an offscreen window; SPTextView's preference reads are
/// pinned in the volatile argument domain.
@interface SPPostgresTextViewTests : XCTestCase
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSDictionary<NSString *, NSColor *> *colors;
@end

@implementation SPPostgresTextViewTests

/// Overrides preferences for this test in the volatile argument domain (never the saved preferences).
- (void)overridePrefs:(NSDictionary *)values
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	[domain addEntriesFromDictionary:values];
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];
}

- (NSData *)archived:(id)object
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return [NSArchiver archivedDataWithRootObject:object];
#pragma clang diagnostic pop
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	// Colours that are easy to tell apart
	self.colors = @{
		SPTextViewTestTextColorKey: [NSColor colorWithCalibratedRed:0.10 green:0.10 blue:0.10 alpha:1],
		SPTextViewTestCommentColorKey: [NSColor colorWithCalibratedRed:0.20 green:0.60 blue:0.20 alpha:1],
		SPTextViewTestKeywordColorKey: [NSColor colorWithCalibratedRed:0.70 green:0.00 blue:0.70 alpha:1],
		SPTextViewTestNumericColorKey: [NSColor colorWithCalibratedRed:0.00 green:0.00 blue:0.90 alpha:1],
		SPTextViewTestQuoteColorKey: [NSColor colorWithCalibratedRed:0.90 green:0.00 blue:0.00 alpha:1],
		SPTextViewTestBacktickColorKey: [NSColor colorWithCalibratedRed:0.00 green:0.50 blue:0.50 alpha:1],
		SPTextViewTestVariableColorKey: [NSColor colorWithCalibratedRed:0.90 green:0.50 blue:0.00 alpha:1],
	};
	NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
	[self.colors enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSColor *color, BOOL *stop) {
		prefs[key] = [self archived:color];
	}];
	prefs[SPTextViewTestFontKey] = [self archived:[NSFont fontWithName:@"Menlo" size:15]];
	prefs[SPTextViewTestAutoIndentKey] = @YES;
	prefs[SPTextViewTestAutoPairKey] = @YES;
	prefs[SPTextViewTestAutoUppercaseKey] = @YES;
	prefs[SPTextViewTestAutoHelpKey] = @NO;
	prefs[SPTextViewTestAutoCompleteKey] = @NO;
	prefs[SPTextViewTestHighlightQueryKey] = @NO;
	[self overridePrefs:prefs];

	self.query = [[SPPostgresQueryController alloc] initWithConnection:nil];
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 695, 534) styleMask:NSWindowStyleMaskTitled
												backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
	[[self.window contentView] addSubview:[self.query view]];
	[[self.query view] setFrame:[[self.window contentView] bounds]];
	[self.window makeFirstResponder:self.query.editor];
}

- (void)tearDown
{
	[self.query invalidate];
	[[self.query view] removeFromSuperview];
	[self.window close];
	self.window = nil;
	self.query = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresTextView *)editor
{
	return (SPPostgresTextView *)self.query.editor;
}

- (NSColor *)colorAt:(NSUInteger)index
{
	return [[[self editor] textStorage] attribute:NSForegroundColorAttributeName atIndex:index effectiveRange:NULL];
}

- (void)assertText:(NSString *)text ofString:(NSString *)string hasColor:(NSString *)key
{
	NSRange range = [string rangeOfString:text];
	XCTAssertNotEqual(range.location, (NSUInteger)NSNotFound, @"%@", text);
	NSColor *expected = self.colors[key];
	for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
		XCTAssertEqualObjects([self colorAt:i], expected, @"%@ (index %lu) has %@", text, (unsigned long)i, key);
	}
}

/// Types text one character at a time, each in its own undo group as a key press event would be.
- (void)typeText:(NSString *)text
{
	NSUndoManager *undoManager = [[self editor] undoManager];
	BOOL groupsByEvent = [undoManager groupsByEvent];
	[undoManager setGroupsByEvent:NO];
	for (NSUInteger i = 0; i < text.length; i++) {
		[undoManager beginUndoGrouping];
		[[self editor] insertText:[text substringWithRange:NSMakeRange(i, 1)] replacementRange:[[self editor] selectedRange]];
		[undoManager endUndoGrouping];
	}
	[undoManager setGroupsByEvent:groupsByEvent];
}

/// A key press, as the window would send it to the editor.
- (void)pressKey:(NSString *)characters
{
	NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
								  windowNumber:[self.window windowNumber] context:nil characters:characters
				   charactersIgnoringModifiers:characters isARepeat:NO keyCode:0];
	[[self editor] keyDown:event];
}

#pragma mark - Tests

- (void)testColoursByTokenKind
{
	NSString *sql = @"select 'x', \"T\", 42, $1 from items -- c";
	[[self editor] setString:sql];
	[[self editor] doSyntaxHighlighting];

	[self assertText:@"select" ofString:sql hasColor:SPTextViewTestKeywordColorKey];
	[self assertText:@"from" ofString:sql hasColor:SPTextViewTestKeywordColorKey];
	[self assertText:@"'x'" ofString:sql hasColor:SPTextViewTestQuoteColorKey];
	[self assertText:@"\"T\"" ofString:sql hasColor:SPTextViewTestBacktickColorKey];
	[self assertText:@"-- c" ofString:sql hasColor:SPTextViewTestCommentColorKey];
	[self assertText:@"42" ofString:sql hasColor:SPTextViewTestNumericColorKey];
	[self assertText:@"$1" ofString:sql hasColor:SPTextViewTestVariableColorKey];
	[self assertText:@"items" ofString:sql hasColor:SPTextViewTestTextColorKey];

	// SPTextView's own markers, which its auto-pair and auto-help read
	NSTextStorage *storage = [[self editor] textStorage];
	NSString *editorString = [[self editor] string];
	NSUInteger quote = [editorString rangeOfString:@"'x'"].location;
	NSUInteger identifier = [editorString rangeOfString:@"\"T\""].location;
	NSUInteger comment = [editorString rangeOfString:@"-- c"].location;
	NSUInteger items = [editorString rangeOfString:@"items"].location;
	XCTAssertEqualObjects([storage attribute:@"Quoted" atIndex:quote effectiveRange:NULL], @"isMarked");
	XCTAssertEqualObjects([storage attribute:@"Quoted" atIndex:identifier effectiveRange:NULL], @"isMarked");
	XCTAssertEqualObjects([storage attribute:@"Quoted" atIndex:comment effectiveRange:NULL], @"isMarked");
	XCTAssertNil([storage attribute:@"Quoted" atIndex:items effectiveRange:NULL]);
	XCTAssertEqualObjects([storage attribute:@"Quote" atIndex:quote effectiveRange:NULL], @"isQuoted");
	XCTAssertNil([storage attribute:@"Quote" atIndex:identifier effectiveRange:NULL]);
	XCTAssertNotNil([storage attribute:@"s" atIndex:0 effectiveRange:NULL]);
	XCTAssertNil([storage attribute:@"s" atIndex:items effectiveRange:NULL]);
}

- (void)testAutoUppercaseSkipsQuotedText
{
	XCTAssertTrue([[self editor] autouppercaseKeywords], @"from CustomQueryAutoUppercaseKeywords");
	[self typeText:@"select 'select' \"select\" -- select"];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'select' \"select\" -- select");

	// Undo restores the typed text: as MySQL's, the uppercasing is undone with the key press that caused it
	[[self editor] setString:@""];
	[[[self editor] undoManager] removeAllActions]; // setString: doesn't register for undo
	[self typeText:@"select "];
	XCTAssertEqualObjects([[self editor] string], @"SELECT ");
	[[[self editor] undoManager] undo];
	XCTAssertEqualObjects([[self editor] string], @"select", @"undo restores the typed text");

	// Off: left as typed
	[[self editor] setString:@""];
	[[self editor] setAutouppercaseKeywords:NO];
	[self typeText:@"select 1"];
	XCTAssertEqualObjects([[self editor] string], @"select 1");
}

- (void)testAutoPairInsertsClosingQuote
{
	[self pressKey:@"("];
	XCTAssertEqualObjects([[self editor] string], @"()");
	XCTAssertTrue(NSEqualRanges([[self editor] selectedRange], NSMakeRange(1, 0)), @"%@", NSStringFromRange([[self editor] selectedRange]));

	// Inside a string, a quote is not paired
	[[self editor] setString:@"SELECT 'a  b'"];
	[[self editor] setSelectedRange:NSMakeRange(10, 0)];
	[self pressKey:@"'"];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'a ' b'");
}

- (void)testIndentNewLines
{
	[[self editor] setString:@"    SELECT"];
	[[self editor] setSelectedRange:NSMakeRange(10, 0)];
	[[self editor] doCommandBySelector:@selector(insertNewline:)];
	XCTAssertEqualObjects([[self editor] string], @"    SELECT\n    ");
}

- (void)testLargeTextHighlightsWithoutHang
{
	NSMutableString *sql = [NSMutableString string];
	while (sql.length < 1024 * 1024) [sql appendString:@"SELECT 1;\n"];

	NSDate *start = [NSDate date];
	XCTAssertNoThrow([[self editor] setString:sql]);
	NSTextView *editor = [self editor];
	[[editor layoutManager] ensureLayoutForBoundingRect:[editor visibleRect] inTextContainer:[editor textContainer]];
	XCTAssertNoThrow([[self editor] doSyntaxHighlighting]);
	NSTimeInterval elapsed = -[start timeIntervalSinceNow];
	XCTAssertLessThan(elapsed, 2.0);

	// The visible text is coloured
	XCTAssertEqualObjects([self colorAt:0], self.colors[SPTextViewTestKeywordColorKey]);
	XCTAssertEqualObjects([self colorAt:7], self.colors[SPTextViewTestNumericColorKey]);
}

- (void)testEditorKeepsPreviousGuarantees
{
	NSTextView *editor = self.query.editor;
	XCTAssertTrue([editor isKindOfClass:[SPPostgresTextView class]]);
	XCTAssertEqualObjects([[editor font] fontName], @"Menlo-Regular");
	XCTAssertEqual([[editor font] pointSize], 15);
	XCTAssertFalse([editor isAutomaticQuoteSubstitutionEnabled]);
	XCTAssertFalse([editor isAutomaticDashSubstitutionEnabled]);
	XCTAssertFalse([editor isAutomaticTextReplacementEnabled]);
	XCTAssertFalse([editor isAutomaticSpellingCorrectionEnabled]);
	XCTAssertTrue([editor allowsUndo]);
	XCTAssertFalse([editor isRichText]);

	// The line number ruler, as MySQL's
	NSScrollView *scrollView = [editor enclosingScrollView];
	XCTAssertTrue([scrollView hasVerticalRuler]);
	XCTAssertEqual([[scrollView verticalRulerView] clientView], editor);
}

@end
