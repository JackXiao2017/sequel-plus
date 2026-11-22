//
//  SPValuePopoverTests.m
//  Sequel Plus
//
//  The value popover: opens raw, formats only when a button is clicked, Compact and Revert, undo, Save as the only
//  write, the discard question for typed changes, the remembered size, and large values formatted in the background.
//

#import <XCTest/XCTest.h>
#import "../Source/SPValuePopover.h"
#import "../Source/SPValueHighlighter.h"
#import "../Source/SPValueGutterView.h"

static NSString *const SPValuePopoverTestSuite = @"SPValuePopoverTests";

@interface SPValuePopoverTests : XCTestCase
@property (strong) NSUserDefaults *defaults;
@property (strong) NSMutableArray<NSString *> *saved;     // the texts the saver got
@property (copy) void (^pendingDone)(NSString *error);    // the last saver's done
@property NSUInteger closedCount;
@end

@implementation SPValuePopoverTests

- (void)setUp
{
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPValuePopoverTestSuite];
	self.defaults = [[NSUserDefaults alloc] initWithSuiteName:SPValuePopoverTestSuite];
	self.saved = [NSMutableArray array];
	self.closedCount = 0;
}

- (void)tearDown
{
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPValuePopoverTestSuite];
	self.defaults = nil;
}

- (SPValuePopover *)popoverWithValue:(NSString *)value editable:(BOOL)editable
{
	__weak SPValuePopoverTests *weakSelf = self;
	SPValuePopover *popover = [[SPValuePopover alloc] initWithValue:value columnName:@"notes" defaults:self.defaults
		saver:editable ? ^(NSString *text, void (^done)(NSString *)) {
			[weakSelf.saved addObject:text];
			weakSelf.pendingDone = done;
		} : nil];
	popover.closed = ^{ weakSelf.closedCount++; };
	popover.discardConfirmer = ^BOOL(NSString *column) {
		XCTFail(@"unexpected discard question for %@", column);
		return YES;
	};
	return popover;
}

/// Types text at the end, as the user would.
- (void)type:(NSString *)text into:(SPValuePopover *)popover
{
	NSTextView *textView = popover.textView;
	[textView setSelectedRange:NSMakeRange([[textView string] length], 0)];
	[textView insertText:text replacementRange:[textView selectedRange]];
}

/// One pass of the run loop: what separates two clicks (the undo manager closes its group per event).
- (void)tick
{
	[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	}
	return condition();
}

static NSString *const SPJSONValue = @"{\"id\":42,\"tags\":[\"a\",\"b\"]}";
static NSString *const SPPrettyJSONValue = @"{\n    \"id\": 42,\n    \"tags\": [\n        \"a\",\n        \"b\"\n    ]\n}";

- (void)testOpensRawWithTitleAndLength
{
	NSString *value = [@"" stringByPaddingToLength:4812 withString:@"x" startingAtIndex:0];
	SPValuePopover *popover = [self popoverWithValue:value editable:YES];
	XCTAssertEqualObjects([popover.textView string], value);
	XCTAssertEqualObjects([popover.titleField stringValue], @"notes — 4,812 characters");
	XCTAssertTrue([popover.textView isEditable]);
	XCTAssertEqualObjects([popover.errorField stringValue], @"");
}

- (void)testNullOpensEmptyUntilSomethingIsTyped
{
	SPValuePopover *popover = [self popoverWithValue:@"" editable:YES];
	popover.valueIsNull = YES;
	XCTAssertEqualObjects([popover.titleField stringValue], @"notes — NULL");
	XCTAssertEqualObjects([popover.textView string], @"");
	XCTAssertFalse([popover.saveButton isEnabled], @"the value stays NULL");
	[self type:@"x" into:popover];
	XCTAssertTrue([popover.saveButton isEnabled]);
	[popover save];
	XCTAssertEqualObjects(self.saved, @[@"x"]);
}

- (void)testFormatButtonsFormatOnceOnClick
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertEqualObjects([popover.textView string], SPJSONValue, @"nothing formats by itself");
	[popover formatJSON];
	XCTAssertEqualObjects([popover.textView string], SPPrettyJSONValue);
	XCTAssertEqual(self.saved.count, 0u, @"formatting never saves");
	XCTAssertEqual(self.closedCount, 0u);
}

- (void)testInvalidFormatShowsErrorKeepsText
{
	SPValuePopover *popover = [self popoverWithValue:@"<a><b></a> and some more text to look at" editable:YES];
	[popover formatJSON];
	XCTAssertTrue([[popover.errorField stringValue] hasPrefix:@"Not valid JSON"], @"%@", [popover.errorField stringValue]);
	XCTAssertEqualObjects([popover.textView string], @"<a><b></a> and some more text to look at");
	[popover formatHTML];
	XCTAssertEqualObjects([popover.errorField stringValue], @"", @"a successful action clears it");

	[popover formatXML];
	XCTAssertTrue([[popover.errorField stringValue] hasPrefix:@"Not valid XML"]);
	[self type:@"!" into:popover];
	XCTAssertEqualObjects([popover.errorField stringValue], @"", @"typing clears it");
}

- (void)testCompactDisabledUntilAFormatSucceeds
{
	SPValuePopover *popover = [self popoverWithValue:@"<a>\n  <b/>\n</a>" editable:YES];
	XCTAssertFalse([popover.compactButton isEnabled]);
	[popover formatJSON]; // fails
	XCTAssertFalse([popover.compactButton isEnabled]);
	[popover formatXML];
	XCTAssertTrue([popover.compactButton isEnabled]);
	[popover compact];
	XCTAssertEqualObjects([popover.textView string], @"<a><b/></a>", @"compacted as the last clicked format (XML)");
}

- (void)testRevertRestoresStoredValueAndIsUndoable
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertFalse([popover.revertButton isEnabled]);
	[popover formatJSON];
	[self tick];
	XCTAssertTrue([popover.revertButton isEnabled]);
	NSUndoManager *undo = [popover.textView undoManager];
	XCTAssertNotNil(undo);
	[undo undo];
	XCTAssertEqualObjects([popover.textView string], SPJSONValue, @"formatting is undoable");
	[self tick];
	[undo redo];
	XCTAssertEqualObjects([popover.textView string], SPPrettyJSONValue);
	[self tick];

	[self type:@" " into:popover];
	[self tick];
	NSString *edited = [popover.textView string];
	[popover revert];
	[self tick];
	XCTAssertEqualObjects([popover.textView string], SPJSONValue);
	XCTAssertFalse([popover.revertButton isEnabled]);
	[undo undo];
	XCTAssertEqualObjects([popover.textView string], edited, @"revert is undoable: typed text comes back");
}

- (void)testSaveSendsTextAsShownAndCloses
{
	SPValuePopover *popover = [self popoverWithValue:@"{ \"a\" : [ 1 , 2 ] }" editable:YES];
	[popover formatJSON];
	[popover compact];
	XCTAssertTrue([popover.saveButton isEnabled]);
	[popover save];
	XCTAssertEqualObjects(self.saved, (@[@"{\"a\":[1,2]}"]));
	XCTAssertFalse([popover.saveButton isEnabled], @"no second save while the first runs");
	XCTAssertEqual(self.closedCount, 0u);
	self.pendingDone(nil);
	XCTAssertEqual(self.closedCount, 1u);
	self.pendingDone(nil); // a second call does nothing
	XCTAssertEqual(self.closedCount, 1u);
}

- (void)testSaveFailureKeepsPopoverOpen
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	[popover formatJSON];
	[popover save];
	self.pendingDone(@"duplicate key value violates unique constraint");
	XCTAssertEqual(self.closedCount, 0u);
	XCTAssertEqualObjects([popover.errorField stringValue], @"duplicate key value violates unique constraint");
	XCTAssertEqualObjects([popover.textView string], SPPrettyJSONValue);
	XCTAssertTrue([popover.saveButton isEnabled]);
}

- (void)testSaveDisabledWhenTextEqualsStoredValue
{
	SPValuePopover *popover = [self popoverWithValue:@"[1,2]" editable:YES];
	XCTAssertFalse([popover.saveButton isEnabled]);
	[popover formatJSON];
	XCTAssertTrue([popover.saveButton isEnabled]);
	[popover compact];
	XCTAssertFalse([popover.saveButton isEnabled], @"compact gives back the stored text");
	[popover save];
	XCTAssertEqual(self.saved.count, 0u);
}

- (void)testReadOnlyHasCloseOnly
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:NO];
	XCTAssertFalse([popover.textView isEditable]);
	XCTAssertTrue([popover.textView isSelectable]);
	XCTAssertTrue([popover.saveButton isHidden]);
	XCTAssertEqualObjects([popover.cancelButton title], @"Close");
	[popover formatJSON];
	XCTAssertEqualObjects([popover.textView string], SPPrettyJSONValue, @"formatting still works for reading");
	[popover cancel];
	XCTAssertEqual(self.closedCount, 1u, @"formatting alone never asks");
}

- (void)testTypedChangesAskBeforeClosing
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	[popover formatJSON];
	[popover compact];
	[popover formatJSON];
	__block NSMutableArray<NSString *> *asked = [NSMutableArray array];
	__block BOOL answer = NO;
	popover.discardConfirmer = ^BOOL(NSString *column) { [asked addObject:column]; return answer; };
	[popover revert];
	[popover formatJSON];
	[popover cancel];
	XCTAssertEqual(asked.count, 0u, @"formatting only: no question");
	XCTAssertEqual(self.closedCount, 1u);

	SPValuePopover *typed = [self popoverWithValue:SPJSONValue editable:YES];
	typed.discardConfirmer = ^BOOL(NSString *column) { [asked addObject:column]; return answer; };
	[self type:@"x" into:typed];
	[typed cancel];
	XCTAssertEqualObjects(asked, (@[@"notes"]));
	XCTAssertEqual(self.closedCount, 1u, @"Keep Editing: still open");
	answer = YES;
	[typed cancel];
	XCTAssertEqual(self.closedCount, 2u);
	XCTAssertEqual(self.saved.count, 0u);
}

- (void)testCloseWithoutPromptDiscards
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	[self type:@"x" into:popover];
	[popover closeDiscarding];
	XCTAssertEqual(self.closedCount, 1u);
	XCTAssertEqual(self.saved.count, 0u);
	[popover closeDiscarding];
	[popover cancel];
	XCTAssertEqual(self.closedCount, 1u, @"closed once");
}

- (void)testSizeRemembered
{
	id realSize = [[NSUserDefaults standardUserDefaults] objectForKey:SPValuePopoverSizeKey]; // the owner's own, if any
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertTrue(NSEqualSizes(popover.contentSize, NSMakeSize(560, 400)));
	popover.contentSize = NSMakeSize(100, 50);
	XCTAssertTrue(NSEqualSizes(popover.contentSize, NSMakeSize(360, 220)), @"not below the minimum");
	popover.contentSize = NSMakeSize(700, 500);
	[popover cancel];
	XCTAssertEqualObjects([self.defaults stringForKey:SPValuePopoverSizeKey], NSStringFromSize(NSMakeSize(700, 500)));
	SPValuePopover *next = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertTrue(NSEqualSizes(next.contentSize, NSMakeSize(700, 500)));
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] objectForKey:SPValuePopoverSizeKey], realSize, @"never the real preferences");
}

- (void)testLargeValueFormatsOffTheMainThread
{
	NSMutableString *json = [NSMutableString stringWithString:@"["];
	for (NSUInteger i = 0; i < 2000; i++) [json appendFormat:@"%@{\"i\":%lu}", i ? @"," : @"", (unsigned long)i];
	[json appendString:@"]"];
	SPValuePopover *popover = [self popoverWithValue:json editable:YES];
	popover.backgroundThreshold = 10;
	[popover formatJSON];
	XCTAssertTrue(popover.busy);
	XCTAssertFalse([popover.jsonButton isEnabled]);
	XCTAssertFalse([popover.saveButton isEnabled]);
	XCTAssertTrue([self spinUntil:^BOOL{ return !popover.busy; } timeout:10]);
	XCTAssertTrue([[popover.textView string] hasPrefix:@"[\n    {\n        \"i\": 0\n    },"]);
	XCTAssertTrue([popover.jsonButton isEnabled]);

	// Closed while formatting: the result is dropped
	[popover compact];
	XCTAssertTrue(popover.busy);
	[popover closeDiscarding];
	XCTAssertTrue([self spinUntil:^BOOL{ return !popover.busy; } timeout:10]);
	XCTAssertEqual(self.saved.count, 0u);
}

- (void)testKeyEquivalents
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertEqualObjects([popover.saveButton keyEquivalent], @"\r");
	XCTAssertEqual([popover.saveButton keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqualObjects([popover.cancelButton keyEquivalent], @"\e");
}

- (void)testShowsOnACellAndClosesWithoutWriting
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window orderFront:nil];
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertTrue([popover showRelativeToRect:NSMakeRect(10, 10, 100, 17) ofView:[window contentView]]);
	XCTAssertTrue(popover.isShown);
	[popover formatJSON];
	[popover cancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return !popover.isShown; } timeout:5]);
	XCTAssertEqual(self.closedCount, 1u);
	XCTAssertEqual(self.saved.count, 0u);
	[window close];

	SPValuePopover *orphan = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertFalse([orphan showRelativeToRect:NSZeroRect ofView:[[NSView alloc] init]], @"no window: not shown");
}

- (void)testOpensAMultiMegabyteSingleLineValueQuickly
{
	NSMutableString *json = [NSMutableString stringWithString:@"["];
	for (NSUInteger i = 0; i < 300000; i++) [json appendFormat:@"%@{\"i\":%lu}", i ? @"," : @"", (unsigned long)i];
	[json appendString:@"]"]; // one line, about 3.5 MB
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window orderFront:nil];
	NSDate *start = [NSDate date];
	SPValuePopover *popover = [self popoverWithValue:json editable:YES];
	XCTAssertTrue([popover showRelativeToRect:NSMakeRect(10, 10, 100, 17) ofView:[window contentView]]);
	[popover.textView display];
	[self tick];
	NSTimeInterval elapsed = -[start timeIntervalSinceNow];
	XCTAssertLessThan(elapsed, 2.0, @"opening took %.2f s", elapsed);
	[popover closeDiscarding];
	[window close];
}

#pragma mark - Colors

/// The color drawn at the first occurrence of fragment (nil: plain).
- (NSColor *)colorOf:(NSString *)fragment in:(SPValuePopover *)popover
{
	NSRange range = [[popover.textView string] rangeOfString:fragment];
	XCTAssertNotEqual(range.location, NSNotFound, @"%@", fragment);
	return [[popover.textView layoutManager] temporaryAttribute:NSForegroundColorAttributeName atCharacterIndex:range.location effectiveRange:NULL];
}

- (void)testRawShowsNoColors
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	XCTAssertNil([self colorOf:@"\"id\"" in:popover]);
}

- (void)testFormatJSONColorsTheText
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	[popover formatJSON];
	XCTAssertEqualObjects([self colorOf:@"\"id\"" in:popover], [SPValueHighlighter colorForKind:SPValueTokenKey]);
	XCTAssertEqualObjects([self colorOf:@"42" in:popover], [SPValueHighlighter colorForKind:SPValueTokenNumber]);
	XCTAssertEqualObjects([self colorOf:@"\"a\"" in:popover], [SPValueHighlighter colorForKind:SPValueTokenString]);
	// Only drawn: the text itself stays plain (what Save writes, undo restores and copy takes)
	NSRange key = [[popover.textView string] rangeOfString:@"\"id\""];
	XCTAssertNotEqualObjects([[popover.textView textStorage] attribute:NSForegroundColorAttributeName atIndex:key.location effectiveRange:NULL],
							 [SPValueHighlighter colorForKind:SPValueTokenKey]);
}

- (void)testFormatXMLAndHTMLColorTags
{
	SPValuePopover *xml = [self popoverWithValue:@"<a x=\"1\"><b>&amp;</b></a>" editable:YES];
	[xml formatXML];
	XCTAssertEqualObjects([self colorOf:@"<a" in:xml], [SPValueHighlighter colorForKind:SPValueTokenTag]);
	XCTAssertEqualObjects([self colorOf:@"x=" in:xml], [SPValueHighlighter colorForKind:SPValueTokenAttribute]);
	XCTAssertEqualObjects([self colorOf:@"&amp;" in:xml], [SPValueHighlighter colorForKind:SPValueTokenEntity]);
	SPValuePopover *html = [self popoverWithValue:@"<div><!-- c --><p>x</p></div>" editable:YES];
	[html formatHTML];
	XCTAssertEqualObjects([self colorOf:@"<!--" in:html], [SPValueHighlighter colorForKind:SPValueTokenComment]);
}

- (void)testCompactKeepsColorsAndRevertClearsThem
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	[popover formatJSON];
	[popover compact];
	XCTAssertEqualObjects([self colorOf:@"\"id\"" in:popover], [SPValueHighlighter colorForKind:SPValueTokenKey]);
	[popover formatJSON];
	[popover revert];
	XCTAssertNil([self colorOf:@"\"id\"" in:popover], @"the stored value is shown plain");
}

- (void)testFailedFormatLeavesColorsAlone
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	[popover formatXML]; // not XML
	XCTAssertNil([self colorOf:@"\"id\"" in:popover]);
}

- (void)testTypingRecolors
{
	SPValuePopover *popover = [self popoverWithValue:@"{\"a\":1}" editable:YES];
	[popover formatJSON];
	NSTextView *textView = popover.textView;
	NSRange close = [[textView string] rangeOfString:@"}" options:NSBackwardsSearch];
	[textView setSelectedRange:NSMakeRange(close.location, 0)];
	[textView insertText:@", \"typed\": true" replacementRange:[textView selectedRange]];
	XCTAssertTrue([self spinUntil:^BOOL{
		NSRange typed = [[textView string] rangeOfString:@"\"typed\""];
		return [[[textView layoutManager] temporaryAttribute:NSForegroundColorAttributeName atCharacterIndex:typed.location effectiveRange:NULL]
				isEqual:[SPValueHighlighter colorForKind:SPValueTokenKey]];
	} timeout:3]);
}

- (void)testVeryLargeValueIsNotColored
{
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	popover.colorLimit = 10;
	[popover formatJSON];
	XCTAssertNil([self colorOf:@"\"id\"" in:popover]);
}

#pragma mark - Line numbers and folding

static NSString *const SPNestedJSON = @"{\"a\":{\"b\":1,\"c\":2},\"tags\":[\"x\",\"y\"],\"id\":42}";
// Formatted:
//  1 {
//  2     "a": {
//  3         "b": 1,
//  4         "c": 2
//  5     },
//  6     "tags": [
//  7         "x",
//  8         "y"
//  9     ],
// 10     "id": 42
// 11 }

- (CGFloat)laidOutHeightOf:(SPValuePopover *)popover
{
	NSLayoutManager *layoutManager = [popover.textView layoutManager];
	[layoutManager ensureLayoutForTextContainer:[popover.textView textContainer]];
	return NSHeight([layoutManager usedRectForTextContainer:[popover.textView textContainer]]);
}

- (void)testGutterShowsLineNumbers
{
	SPValuePopover *popover = [self popoverWithValue:@"one\ntwo\nthree and more text to make it long enough" editable:YES];
	NSScrollView *scrollView = [popover.textView enclosingScrollView];
	XCTAssertTrue([scrollView rulersVisible]);
	XCTAssertEqual([scrollView verticalRulerView], popover.gutterView);
	XCTAssertEqual([popover.gutterView clientView], popover.textView);
	XCTAssertGreaterThan([popover.gutterView requiredThickness], 0.0);
	XCTAssertEqual([popover lineNumberForCharacterIndex:0], 1u);
	XCTAssertEqual([popover lineNumberForCharacterIndex:4], 2u);
	XCTAssertEqual([popover lineNumberForCharacterIndex:9], 3u);
	XCTAssertEqualObjects(popover.foldableLines, @[], @"raw: numbers, no folds");
}

/// Draws view now (into a bitmap), as the screen would.
- (void)render:(NSView *)view
{
	[view layoutSubtreeIfNeeded];
	(void)[view dataWithPDFInsideRect:[view bounds]];
}

- (void)testGutterDrawsEveryLineAfterAFormat
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window orderFront:nil];
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	NSView *content = [[popover.textView enclosingScrollView] superview];
	[[window contentView] addSubview:content];
	[self render:content];
	XCTAssertEqualObjects([(id)popover.gutterView drawnLines], @[@1], @"raw: one line");

	[popover formatJSON];
	// As on screen: the gutter may draw before the new text is laid out (layout is lazy)
	NSLayoutManager *layoutManager = [popover.textView layoutManager];
	[layoutManager invalidateLayoutForCharacterRange:NSMakeRange(0, [[popover.textView string] length]) actualCharacterRange:NULL];
	[self render:popover.gutterView];
	NSMutableArray *all = [NSMutableArray array];
	for (NSUInteger line = 1; line <= 11; line++) [all addObject:@(line)];
	XCTAssertEqualObjects([(id)popover.gutterView drawnLines], all, @"every formatted line is numbered");

	[popover toggleFoldAtLine:2 allAtLevel:NO];
	[self render:content];
	XCTAssertEqualObjects([(id)popover.gutterView drawnLines], (@[@1, @2, @6, @7, @8, @9, @10, @11]), @"a folded block's lines are skipped");
	[window close];
}

- (void)testFoldArrowsComeWithAFormat
{
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	[popover formatJSON];
	XCTAssertEqualObjects(popover.foldableLines, (@[@1, @2, @6]));
	XCTAssertEqualObjects(popover.foldedLines, @[]);
}

- (void)testFoldHidesLinesButNotTheText
{
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	[popover formatJSON];
	NSString *pretty = [popover.textView string];
	CGFloat before = [self laidOutHeightOf:popover];
	[popover toggleFoldAtLine:2 allAtLevel:NO];
	XCTAssertEqualObjects(popover.foldedLines, @[@2]);
	CGFloat after = [self laidOutHeightOf:popover];
	XCTAssertLessThan(after, before - 2.5 * ([popover.textView font].pointSize), @"lines 3-5 no longer take room");
	XCTAssertEqualObjects([popover.textView string], pretty, @"the text is all still there");

	// Hidden characters draw nothing
	NSLayoutManager *layoutManager = [popover.textView layoutManager];
	NSUInteger hidden = [pretty rangeOfString:@"\"b\""].location;
	XCTAssertEqual([layoutManager propertyForGlyphAtIndex:[layoutManager glyphIndexForCharacterAtIndex:hidden]], NSGlyphPropertyNull);

	// Save writes the whole value
	[popover save];
	XCTAssertEqualObjects(self.saved.lastObject, pretty);
	self.pendingDone(@"kept open");

	[popover toggleFoldAtLine:2 allAtLevel:NO];
	XCTAssertEqualObjects(popover.foldedLines, @[]);
	XCTAssertEqualWithAccuracy([self laidOutHeightOf:popover], before, 0.5);
}

- (void)testOptionClickFoldsEveryBlockAtThatLevel
{
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	[popover formatJSON];
	[popover toggleFoldAtLine:2 allAtLevel:YES];
	XCTAssertEqualObjects(popover.foldedLines, (@[@2, @6]));
	[popover toggleFoldAtLine:6 allAtLevel:YES];
	XCTAssertEqualObjects(popover.foldedLines, @[]);
	[popover toggleFoldAtLine:1 allAtLevel:NO];
	XCTAssertEqualObjects(popover.foldedLines, @[@1]);
	[popover toggleFoldAtLine:4 allAtLevel:NO]; // no fold starts there
	XCTAssertEqualObjects(popover.foldedLines, @[@1]);
}

- (void)testTypingFormatAndRevertUnfold
{
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	[popover formatJSON];
	[popover toggleFoldAtLine:6 allAtLevel:NO];
	[self type:@" " into:popover];
	XCTAssertEqualObjects(popover.foldedLines, @[], @"typing unfolds everything");
	XCTAssertTrue([self spinUntil:^BOOL{ return [popover.foldableLines count] == 3; } timeout:3], @"the arrows come back");

	[popover toggleFoldAtLine:2 allAtLevel:NO];
	[popover compact];
	XCTAssertEqualObjects(popover.foldedLines, @[]);
	XCTAssertEqualObjects(popover.foldableLines, @[], @"one line: nothing to fold");
	[popover formatJSON];
	[popover toggleFoldAtLine:2 allAtLevel:NO];
	[popover revert];
	XCTAssertEqualObjects(popover.foldedLines, @[]);
	XCTAssertEqualObjects(popover.foldableLines, @[]);
}

- (void)testCaretIntoAFoldUnfoldsIt
{
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	[popover formatJSON];
	[popover toggleFoldAtLine:2 allAtLevel:NO];
	NSUInteger inside = [[popover.textView string] rangeOfString:@"\"c\""].location;
	[popover.textView setSelectedRange:NSMakeRange(inside, 0)];
	XCTAssertEqualObjects(popover.foldedLines, @[]);
}

- (void)testXMLFolds
{
	SPValuePopover *popover = [self popoverWithValue:@"<a><b><c/><d/></b><e/></a>" editable:YES];
	[popover formatXML];
	XCTAssertEqualObjects(popover.foldableLines, (@[@1, @2]));
	[popover toggleFoldAtLine:1 allAtLevel:NO];
	XCTAssertEqualObjects(popover.foldedLines, @[@1]);
}

- (void)testVeryLargeValueHasLineNumbersButNoFolds
{
	SPValuePopover *popover = [self popoverWithValue:SPNestedJSON editable:YES];
	popover.colorLimit = 10;
	[popover formatJSON];
	XCTAssertEqualObjects(popover.foldableLines, @[]);
	XCTAssertEqual([popover lineNumberForCharacterIndex:[[popover.textView string] length]], 11u);
}

/// The darkest pixel (0 black … 1 white) of view's rect in a rendering of root.
- (CGFloat)darkestPixelOf:(NSView *)view in:(NSView *)root
{
	[root layoutSubtreeIfNeeded];
	[root display];
	NSBitmapImageRep *rep = [root bitmapImageRepForCachingDisplayInRect:[root bounds]];
	[root cacheDisplayInRect:[root bounds] toBitmapImageRep:rep];
	NSRect rect = [root convertRect:[view bounds] fromView:view];
	CGFloat scale = (CGFloat)[rep pixelsWide] / NSWidth([root bounds]);
	CGFloat darkest = 1;
	for (NSInteger x = (NSInteger)(NSMinX(rect) * scale); x < (NSInteger)(NSMaxX(rect) * scale); x++) {
		for (NSInteger y = (NSInteger)(NSMinY(rect) * scale); y < (NSInteger)(NSMaxY(rect) * scale); y++) {
			NSInteger row = [root isFlipped] ? y : (NSInteger)[rep pixelsHigh] - 1 - y;
			NSColor *color = [[rep colorAtX:x y:row] colorUsingColorSpace:[NSColorSpace genericGrayColorSpace]];
			darkest = MIN(darkest, [color whiteComponent]);
		}
	}
	return darkest;
}

- (void)testTopBarIsNotPaintedOverByTheGutter
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	[window orderFront:nil];
	SPValuePopover *popover = [self popoverWithValue:SPJSONValue editable:YES];
	NSView *content = [[popover.textView enclosingScrollView] superview];
	[[window contentView] addSubview:content];
	XCTAssertLessThan([self darkestPixelOf:popover.jsonButton in:content], 0.5, @"the JSON button's title is drawn");
	XCTAssertLessThan([self darkestPixelOf:popover.titleField in:content], 0.5, @"the title is drawn");
	XCTAssertTrue([popover.gutterView clipsToBounds]);
	[window close];
}

@end
