#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresTextView.h"
#import "../Source/Postgres/SPPostgresSQLTokenizer.h"
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

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
static NSString * const SPTextViewTestCompleteWithBackticksKey = @"SPCustomQueryEditorCompleteWithBackticks";
static NSString * const SPTextViewTestFunctionArgumentsKey = @"CustomQueryFunctionCompletionInsertsArguments";
static const NSUInteger SPTextViewTestPort = 55418;

/// SPNarrowDownCompletion's private action (what Return or Tab does in the pop-up): inserts the selected item.
@interface NSWindow (SPTextViewTestCompletion)
- (void)completeAndInsertSnippet;
@end

/// The Query editor (Stage 11 Task 4): MySQL's SPTextView with Postgres colouring, auto-uppercase, auto-pair and
/// indent. The Query view is built (without a connection) in an offscreen window; SPTextView's preference reads are
/// pinned in the volatile argument domain.
@interface SPPostgresTextViewTests : XCTestCase
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSDictionary<NSString *, NSColor *> *colors;
// A connected tab (the tests that need one: -openDocument)
@property (strong) SPWindowController *windowController;
@property (strong) SPPostgresDocument *document;
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
	// A pop-up a failed test left open (closed before the run loop turns again, so its event loop never starts)
	for (SPPostgresTextView *editor in @[[self editor] ?: (id)[NSNull null], [self documentEditor] ?: (id)[NSNull null]]) {
		if ([editor isKindOfClass:[SPPostgresTextView class]] && [editor completionIsOpen]) [[self popupOfEditor:editor] close];
	}

	if (self.document) {
		NSWindow *window = [self.windowController window];
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		NSTabView *tabView = [self.windowController valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
		self.document = nil;
		self.windowController = nil;
	}
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

#pragma mark - Completion helpers

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (NSArray<NSDictionary *> *)suggestionsFor:(NSString *)word inEditor:(SPPostgresTextView *)editor
{
	return [editor suggestionsForSQLCompletionWith:word dictMode:NO browseMode:NO withTableName:nil withDbName:nil];
}

- (NSArray<NSDictionary *> *)suggestionsFor:(NSString *)word
{
	return [self suggestionsFor:word inEditor:[self editor]];
}

/// The first suggestion displayed as display, or nil.
- (NSDictionary *)item:(NSString *)display inSuggestions:(NSArray<NSDictionary *> *)suggestions
{
	for (NSDictionary *item in suggestions) {
		if ([item[@"display"] isEqualToString:display]) return item;
	}
	return nil;
}

/// The completion pop-up the editor opened last (SPTextView's completionPopup), or nil.
- (NSWindow *)popupOfEditor:(SPPostgresTextView *)editor
{
	return [editor valueForKey:@"completionPopup"];
}

/// What a pop-up offers (its items before filtering) and what it shows (after).
- (NSArray<NSString *> *)displaysOf:(NSArray<NSDictionary *> *)items
{
	NSMutableArray *displays = [NSMutableArray array];
	for (NSDictionary *item in items) [displays addObject:item[@"display"]];
	return displays;
}

/// Closes the pop-up (before the run loop turns, so its event loop never starts).
- (void)closePopup:(NSWindow *)popup
{
	[popup close];
	XCTAssertFalse([[self editor] completionIsOpen]);
}

/// A connected tab on the content fixture, in an SPWindowController (as SPPostgresQueryControllerTests).
- (void)openDocument
{
	[SPPostgresTestServers loadFixtureNamed:@"content" onPort:SPTextViewTestPort];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 completion";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPTextViewTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

	self.windowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.windowController window]);

	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block NSError *error = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) {
		connection = theConnection;
		error = theError;
		done = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection, @"%@", error);

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	self.document.alertPresenter = ^(NSAlert *alert) { XCTFail(@"alert: %@ %@", alert.messageText, alert.informativeText); };
	[self.windowController addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// content_test.items selected
	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"items"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (SPPostgresTextView *)documentEditor
{
	return (SPPostgresTextView *)self.document.queryController.editor;
}

/// The console's messages (test-only read of SPQueryController's storage, as SPPostgresQueryControllerTests).
- (NSUInteger)consoleMessageCount
{
	id console = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	return [[console valueForKey:@"messagesFullSet"] count];
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
	// As MySQL's (token < 4): a comment is marked as quoted, so auto-help skips its words
	XCTAssertEqualObjects([storage attribute:@"Quote" atIndex:comment + 3 effectiveRange:NULL], @"isQuoted");
	XCTAssertNil([storage attribute:@"Quote" atIndex:items effectiveRange:NULL]);
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


#pragma mark - Completion

- (void)testSuggestionsIncludeKeywordsFunctionsAndNames
{
	[self editor].completionNamesProvider = ^NSDictionary *{
		return @{@"tables": @[@"items", @"Order Items"]};
	};
	[[self editor] setString:@"SELECT * FROM "];

	NSArray *suggestions = [self suggestionsFor:@"it"];
	XCTAssertNotNil([self item:@"items" inSuggestions:suggestions], @"%@", [self displaysOf:suggestions]);
	XCTAssertEqualObjects([self item:@"items" inSuggestions:suggestions][@"image"], @"table-small-square");
	XCTAssertNil([self item:@"items" inSuggestions:suggestions][@"match"], @"inserted as shown");

	suggestions = [self suggestionsFor:@"ret"];
	XCTAssertNotNil([self item:@"RETURNING" inSuggestions:suggestions], @"keywords, shown uppercased");
	XCTAssertNil([self item:@"returning" inSuggestions:suggestions]);

	suggestions = [self suggestionsFor:@"pg_sl"];
	XCTAssertNotNil([self item:@"pg_sleep" inSuggestions:suggestions], @"function names");
	XCTAssertEqualObjects([self item:@"pg_sleep" inSuggestions:suggestions][@"image"], @"func-small");

	// The buffer's words
	[[self editor] setString:@"SELECT widget_count FROM "];
	XCTAssertNotNil([self item:@"widget_count" inSuggestions:[self suggestionsFor:@"wid"]]);

	// Never a reference SPNarrowDownCompletion would backtick-quote
	for (NSDictionary *item in suggestions) XCTAssertNil(item[@"isRef"], @"%@", item);

	// No provider: keywords and words only
	[self editor].completionNamesProvider = nil;
	XCTAssertNil([self item:@"items" inSuggestions:[self suggestionsFor:@"it"]]);
	XCTAssertNotNil([self item:@"SELECT" inSuggestions:[self suggestionsFor:@"sel"]]);
}

- (void)testCompletionQuotesMixedCaseNames
{
	[self overridePrefs:@{SPTextViewTestCompleteWithBackticksKey: @YES, SPTextViewTestFunctionArgumentsKey: @YES}];
	[self editor].completionNamesProvider = ^NSDictionary *{
		return @{@"schemas": @[@"Sales", @"content_test"], @"tables": @[@"items", @"Order Items", @"order", @"say\"hi"]};
	};

	NSArray *suggestions = [self suggestionsFor:@"Ord"];
	XCTAssertEqualObjects([self item:@"Order Items" inSuggestions:suggestions][@"match"], @"\"Order Items\"");
	XCTAssertEqualObjects([self item:@"order" inSuggestions:suggestions][@"match"], @"\"order\"", @"a keyword is quoted");
	XCTAssertEqualObjects([self item:@"Sales" inSuggestions:suggestions][@"match"], @"\"Sales\"");
	XCTAssertEqualObjects([self item:@"say\"hi" inSuggestions:suggestions][@"match"], @"\"say\"\"hi\"");
	XCTAssertNil([self item:@"content_test" inSuggestions:suggestions][@"match"]);
	for (NSDictionary *item in suggestions) XCTAssertNil(item[@"isRef"], @"%@", item);

	// Through the pop-up, as Return inserts the selected item: typed unquoted, the quoted name is offered and inserted
	[[self editor] setString:@"SELECT * FROM Ord"];
	[[self editor] setSelectedRange:NSMakeRange(17, 0)];
	[[self editor] doCompletionByUsingSpellChecker:NO fuzzyMode:NO autoCompleteMode:NO];
	NSWindow *popup = [self popupOfEditor:[self editor]];
	XCTAssertNotNil(popup);
	NSArray *shown = [popup valueForKey:@"filtered"];
	XCTAssertTrue([[self displaysOf:shown] containsObject:@"Order Items"], @"%@", [self displaysOf:shown]);
	NSUInteger row = [[self displaysOf:shown] indexOfObject:@"Order Items"];
	[(NSTableView *)[popup valueForKey:@"theTableView"] selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[popup completeAndInsertSnippet];
	XCTAssertEqualObjects([[self editor] string], @"SELECT * FROM \"Order Items\"");
	XCTAssertFalse([[[self editor] string] containsString:@"`"]);
	[self closePopup:popup];

	// Typed after an opening quote (auto-paired): the closing quote is replaced, not doubled
	[[self editor] setString:@"SELECT * FROM \"Ord\""];
	[[self editor] setSelectedRange:NSMakeRange(18, 0)];
	[[self editor] doCompletionByUsingSpellChecker:NO fuzzyMode:NO autoCompleteMode:NO];
	popup = [self popupOfEditor:[self editor]];
	shown = [popup valueForKey:@"filtered"];
	XCTAssertEqualObjects([self displaysOf:shown], (@[@"Order Items", @"order"]), @"only names, inside quotes");
	[popup completeAndInsertSnippet];
	XCTAssertEqualObjects([[self editor] string], @"SELECT * FROM \"Order Items\"");
	[self closePopup:popup];

	// A function gets "()" (no MySQL argument snippet), the caret inside
	[[self editor] setString:@"SELECT pg_sle"];
	[[self editor] setSelectedRange:NSMakeRange(13, 0)];
	[[self editor] doCompletionByUsingSpellChecker:NO fuzzyMode:NO autoCompleteMode:NO];
	popup = [self popupOfEditor:[self editor]];
	XCTAssertEqualObjects([self displaysOf:[popup valueForKey:@"filtered"]], @[@"pg_sleep"]);
	[popup completeAndInsertSnippet];
	XCTAssertEqualObjects([[self editor] string], @"SELECT pg_sleep()");
	XCTAssertEqual([[self editor] selectedRange].location, 16u);
	[self closePopup:popup];
}

/// Only a name that isn't a plain lowercase identifier, or is a RESERVED keyword, is quoted (Ruling 6): name and type
/// are (unreserved) keywords, used as plain column names.
- (void)testCompletionQuotesOnlyReservedKeywords
{
	[self editor].completionNamesProvider = ^NSDictionary *{
		return @{@"tables": @[@"select", @"order", @"name", @"type"], @"columns": @[@"name", @"date"]};
	};

	XCTAssertTrue([[SPPostgresSQLTokenizer reservedKeywords] containsObject:@"select"]);
	XCTAssertFalse([[SPPostgresSQLTokenizer reservedKeywords] containsObject:@"name"]);
	XCTAssertEqual([[SPPostgresSQLTokenizer reservedKeywords] count], 78u);

	NSArray *suggestions = [self suggestionsFor:@""];
	for (NSDictionary *item in suggestions) {
		if ([item[@"image"] isEqualToString:@"table-small-square"] || [item[@"image"] isEqualToString:@"field-small-square"]) {
			if ([item[@"display"] isEqualToString:@"select"]) XCTAssertEqualObjects(item[@"match"], @"\"select\"");
			else if ([item[@"display"] isEqualToString:@"order"]) XCTAssertEqualObjects(item[@"match"], @"\"order\"");
			else XCTAssertNil(item[@"match"], @"%@ completes unquoted", item[@"display"]);
		}
	}
	XCTAssertNotNil([self item:@"name" inSuggestions:suggestions]);
}

- (void)testCompletionListKinds
{
	[self editor].completionNamesProvider = ^NSDictionary *{
		return @{@"databases": @[@"pgkit_test", @"Other DB"], @"schemas": @[@"public"], @"tables": @[@"items"],
				 @"views": @[@"items_view"], @"columns": @[@"id", @"Name"]};
	};
	[[self editor] setString:@"SELECT "];
	[[self editor] setSelectedRange:NSMakeRange(7, 0)];

	NSDictionary *expected = @{@"$SP_ASLIST_ALL_DATABASES": @[@"pgkit_test", @"Other DB"],
							   @"$SP_ASLIST_ALL_TABLES": @[@"items", @"items_view"],
							   @"$SP_ASLIST_ALL_FIELDS": @[@"id", @"Name"]};
	for (NSString *kind in expected) {
		// The delegate (the Query controller) is never asked for MySQL's tablesListInstance
		XCTAssertNoThrow([[self editor] showCompletionListFor:kind atRange:NSMakeRange(7, 0) fuzzySearch:NO], @"%@", kind);
		NSWindow *popup = [self popupOfEditor:[self editor]];
		XCTAssertNotNil(popup, @"%@", kind);
		XCTAssertTrue([[self editor] completionIsOpen]);
		NSArray *items = [popup valueForKey:@"suggestions"];
		XCTAssertEqualObjects([self displaysOf:items], expected[kind], @"%@", kind);
		for (NSDictionary *item in items) XCTAssertNil(item[@"isRef"], @"%@", item);
		if ([kind isEqualToString:@"$SP_ASLIST_ALL_FIELDS"]) {
			XCTAssertEqualObjects([self item:@"Name" inSuggestions:items][@"match"], @"\"Name\"");
		}
		[self closePopup:popup];
	}
}

- (void)testCompletionWhileBusyUsesHeldLists
{
	[self overridePrefs:@{@"ConsoleEnableLogging": @YES, @"ConsoleEnableInterfaceLogging": @YES, @"ConsoleEnableCustomQueryLogging": @YES, @"ConsoleEnableErrorLogging": @YES}];
	[self openDocument];
	[self.document viewQuery:nil];
	SPPostgresQueryController *query = self.document.queryController;
	SPPostgresTaskRunner *runner = self.document.taskRunner;
	SPPostgresTextView *editor = [self documentEditor];

	[editor setString:@"SELECT pg_sleep(2)"];
	[editor setSelectedRange:NSMakeRange(0, 0)];
	[query runAllQueries:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [runner.currentDescription isEqualToString:@"Running query..."]; } timeout:10], @"%@", runner.currentDescription);
	[self spinUntil:^BOOL{ return NO; } timeout:0.3]; // the run's own statement reaches the console
	NSUInteger messages = [self consoleMessageCount];

	// Names, keywords and functions while the runner holds the connection
	NSArray *suggestions = [self suggestionsFor:@"ite" inEditor:editor];
	XCTAssertNotNil([self item:@"items" inSuggestions:suggestions], @"%@", [self displaysOf:suggestions]);
	XCTAssertNotNil([self item:@"SELECT" inSuggestions:suggestions]);
	XCTAssertNotNil([self item:@"pg_sleep" inSuggestions:suggestions]);

	// The pop-up too
	[editor setString:@"SELECT * FROM ite"];
	[editor setSelectedRange:NSMakeRange(17, 0)];
	[editor doCompletionByUsingSpellChecker:NO fuzzyMode:NO autoCompleteMode:NO];
	NSWindow *popup = [self popupOfEditor:editor];
	XCTAssertTrue([[self displaysOf:[popup valueForKey:@"filtered"]] containsObject:@"items"]);
	[popup close];
	[editor showCompletionListFor:@"$SP_ASLIST_ALL_TABLES" atRange:NSMakeRange(17, 0) fuzzySearch:NO];
	popup = [self popupOfEditor:editor];
	XCTAssertTrue([[self displaysOf:[popup valueForKey:@"suggestions"]] containsObject:@"items"]);
	[popup close];

	[self spinUntil:^BOOL{ return NO; } timeout:0.3];
	XCTAssertTrue(runner.isBusy, @"measured during the run");
	XCTAssertEqual([self consoleMessageCount], messages, @"no query was sent for the completion");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
}

- (void)testDocumentProviderListsSidebarAndContent
{
	[self openDocument];
	[self.document viewContent:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSMutableArray *gridColumns = [NSMutableArray array];
	for (NSTableColumn *column in [self.document.contentController.tableView tableColumns]) [gridColumns addObject:[[column headerCell] stringValue]];
	XCTAssertTrue([gridColumns containsObject:@"name"], @"%@", gridColumns);

	NSDictionary *(^provider)(void) = [self documentEditor].completionNamesProvider;
	XCTAssertNotNil(provider);
	NSDictionary *names = provider();
	XCTAssertTrue([names[@"databases"] containsObject:@"pgkit_test"], @"%@", names[@"databases"]);
	XCTAssertFalse([names[@"databases"] containsObject:@"Refresh Databases"]);
	XCTAssertTrue([names[@"schemas"] containsObject:@"content_test"], @"%@", names[@"schemas"]);
	XCTAssertTrue([names[@"tables"] containsObject:@"items"], @"%@", names[@"tables"]);
	XCTAssertFalse([names[@"tables"] containsObject:@"items_view"]);
	XCTAssertTrue([names[@"views"] containsObject:@"items_view"], @"%@", names[@"views"]);
	XCTAssertEqualObjects(names[@"columns"], gridColumns);

	// Another table selected, its columns not loaded yet (Content not shown): none
	[self.document viewQuery:nil];
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"no_pk"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSArray *columns = provider()[@"columns"];
	XCTAssertTrue(columns.count == 0 || [columns isEqualToArray:(@[@"x", @"y"])], @"%@", columns);

	// Dropped with the controller
	[self.document.queryController invalidate];
	XCTAssertNil([self documentEditor].completionNamesProvider);
}

@end
