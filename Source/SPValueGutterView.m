//
//  SPValueGutterView.m
//  Sequel Plus
//

#import "SPValueGutterView.h"

static const CGFloat SPValueGutterArrowWidth = 14;

@implementation SPValueGutterView
{
	NSTextView *_textView;         // the client (not retained: the scroll view owns both)
	NSMutableArray<NSNumber *> *_lineStarts; // character index of each line's start; nil: to be worked out again
	NSDictionary *_numberAttributes;
}

@synthesize foldableLines = _foldableLines;
@synthesize foldedLines = _foldedLines;
@synthesize hiddenRanges = _hiddenRanges;
@synthesize toggle = _toggle;
@synthesize drawnLines = _drawnLines;

- (instancetype)initWithScrollView:(NSScrollView *)scrollView textView:(NSTextView *)textView
{
	if (!(self = [super initWithScrollView:scrollView orientation:NSVerticalRuler])) return nil;
	_textView = textView;
	_foldableLines = [[NSIndexSet alloc] init];
	_foldedLines = [[NSIndexSet alloc] init];
	_hiddenRanges = [[NSArray alloc] init];
	_numberAttributes = [@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
						   NSForegroundColorAttributeName: [NSColor secondaryLabelColor]} retain];
	[self setClientView:textView];
	// Since macOS 14 a view may draw outside its bounds: the gutter's fill would cover the popover's top bar
	[self setClipsToBounds:YES];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_textChanged:) name:NSTextStorageDidProcessEditingNotification object:[textView textStorage]];
	[self _updateThickness];
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_lineStarts release];
	[_numberAttributes release];
	[_foldableLines release];
	[_foldedLines release];
	[_hiddenRanges release];
	[_toggle release];
	[_drawnLines release];
	[super dealloc];
}

- (BOOL)isFlipped
{
	return YES;
}

#pragma mark - Lines

- (void)_textChanged:(NSNotification *)notification
{
	[_lineStarts release];
	_lineStarts = nil;
	[self _updateThickness];
	[self setNeedsDisplay:YES];
}

- (NSArray<NSNumber *> *)_lineStarts
{
	if (_lineStarts) return _lineStarts;
	NSString *text = [_textView string];
	NSUInteger length = [text length];
	_lineStarts = [[NSMutableArray alloc] initWithObjects:@0, nil];
	NSUInteger index = 0;
	while (index < length) {
		NSRange newline = [text rangeOfString:@"\n" options:NSLiteralSearch range:NSMakeRange(index, length - index)];
		if (newline.location == NSNotFound) break;
		index = NSMaxRange(newline);
		[_lineStarts addObject:@(index)];
	}
	return _lineStarts;
}

- (NSUInteger)lineNumberForCharacterIndex:(NSUInteger)index
{
	NSArray<NSNumber *> *starts = [self _lineStarts];
	NSUInteger low = 0, high = [starts count];
	while (high - low > 1) {
		NSUInteger middle = (low + high) / 2;
		if ([[starts objectAtIndex:middle] unsignedIntegerValue] <= index) low = middle;
		else high = middle;
	}
	return low + 1;
}

- (NSUInteger)characterIndexOfLine:(NSUInteger)line
{
	NSArray<NSNumber *> *starts = [self _lineStarts];
	if (line < 1 || line > [starts count]) return NSNotFound;
	return [[starts objectAtIndex:line - 1] unsignedIntegerValue];
}

/// Whether a line starting at index is hidden by a fold.
- (BOOL)_lineStartIsHidden:(NSUInteger)index
{
	for (NSValue *value in _hiddenRanges) {
		NSRange range = [value rangeValue];
		if (index > range.location && index <= NSMaxRange(range)) return YES;
	}
	return NO;
}

- (void)_updateThickness
{
	NSUInteger lines = [[self _lineStarts] count];
	NSUInteger digits = 1;
	while (lines >= 10) { digits++; lines /= 10; }
	CGFloat digitWidth = [@"8" sizeWithAttributes:_numberAttributes].width;
	CGFloat thickness = ceil(MAX(digits, 2) * digitWidth + SPValueGutterArrowWidth + 8);
	if (thickness != [self ruleThickness]) [self setRuleThickness:thickness];
}

/// Calls block with each shown line in rect (1-based number, its rect in this view).
- (void)_enumerateShownLinesInRect:(NSRect)rect block:(void (^)(NSUInteger line, NSRect lineRect))block
{
	NSLayoutManager *layoutManager = [_textView layoutManager];
	NSTextContainer *container = [_textView textContainer];
	if (!layoutManager || !container) return;
	NSString *text = [_textView string];
	NSUInteger length = [text length];
	NSArray<NSNumber *> *starts = [self _lineStarts];

	// The part of the text beside rect, laid out first (layout is lazy: after a new text only its start may be)
	NSRect visible = [self convertRect:rect toView:_textView];
	NSPoint origin = [_textView textContainerOrigin];
	visible = NSOffsetRect(visible, -origin.x, -origin.y);
	visible.origin.x = 0;
	visible.size.width = MAX(NSWidth(visible), 1);
	NSRange glyphs = [layoutManager glyphRangeForBoundingRect:visible inTextContainer:container];
	NSRange characters = [layoutManager characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
	NSUInteger line = [self lineNumberForCharacterIndex:characters.location];

	// Each line from there until one starts below rect
	for (; line <= [starts count]; line++) {
		NSUInteger start = [[starts objectAtIndex:line - 1] unsignedIntegerValue];
		if (start > NSMaxRange(characters)) break;
		if ([self _lineStartIsHidden:start]) continue;
		NSRect fragment;
		if (start >= length) {
			fragment = [layoutManager extraLineFragmentRect];
			if (NSIsEmptyRect(fragment)) continue;
		} else {
			NSUInteger glyph = [layoutManager glyphIndexForCharacterAtIndex:start];
			if (glyph >= [layoutManager numberOfGlyphs]) continue;
			fragment = [layoutManager lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
		}
		if (NSMinY(fragment) > NSMaxY(visible)) break;
		NSRect inText = NSOffsetRect(fragment, origin.x, origin.y);
		NSRect inGutter = [self convertRect:inText fromView:_textView];
		block(line, NSMakeRect(0, NSMinY(inGutter), NSWidth([self bounds]), NSHeight(inGutter)));
	}
}

#pragma mark - Drawing


- (void)drawHashMarksAndLabelsInRect:(NSRect)rect
{
	rect = NSIntersectionRect(rect, [self bounds]);
	if (NSIsEmptyRect(rect)) return;
	[[NSColor textBackgroundColor] setFill];
	NSRectFill(rect);
	[[NSColor separatorColor] setFill];
	NSRectFill(NSMakeRect(NSMaxX([self bounds]) - 1, NSMinY(rect), 1, NSHeight(rect)));

	CGFloat numbersRight = NSWidth([self bounds]) - SPValueGutterArrowWidth - 4;
	NSMutableArray<NSNumber *> *drawn = [NSMutableArray array];
	[self _enumerateShownLinesInRect:rect block:^(NSUInteger line, NSRect lineRect) {
		[drawn addObject:@(line)];
		NSString *number = [NSString stringWithFormat:@"%lu", (unsigned long)line];
		NSSize size = [number sizeWithAttributes:_numberAttributes];
		CGFloat y = NSMinY(lineRect) + floor((MIN(NSHeight(lineRect), 16) - size.height) / 2);
		[number drawAtPoint:NSMakePoint(numbersRight - size.width, y) withAttributes:_numberAttributes];

		if ([_foldableLines containsIndex:line]) {
			BOOL folded = [_foldedLines containsIndex:line];
			CGFloat midY = NSMinY(lineRect) + MIN(NSHeight(lineRect), 16) / 2;
			CGFloat x = numbersRight + 5;
			NSBezierPath *arrow = [NSBezierPath bezierPath];
			if (folded) { // ▸
				[arrow moveToPoint:NSMakePoint(x, midY - 4)];
				[arrow lineToPoint:NSMakePoint(x + 6, midY)];
				[arrow lineToPoint:NSMakePoint(x, midY + 4)];
			} else { // ▾
				[arrow moveToPoint:NSMakePoint(x - 1, midY - 3)];
				[arrow lineToPoint:NSMakePoint(x + 7, midY - 3)];
				[arrow lineToPoint:NSMakePoint(x + 3, midY + 3)];
			}
			[arrow closePath];
			[(folded ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor]) setFill];
			[arrow fill];
		}
	}];
	[_drawnLines release];
	_drawnLines = [drawn copy];
}

#pragma mark - Clicking an arrow

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	__block NSUInteger clicked = NSNotFound;
	[self _enumerateShownLinesInRect:[self bounds] block:^(NSUInteger line, NSRect lineRect) {
		if (NSPointInRect(point, lineRect) && [_foldableLines containsIndex:line]) clicked = line;
	}];
	if (clicked != NSNotFound && _toggle) _toggle(clicked, ([event modifierFlags] & NSEventModifierFlagOption) != 0);
}

@end
