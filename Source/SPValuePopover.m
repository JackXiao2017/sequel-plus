//
//  SPValuePopover.m
//  Sequel Plus
//

#import "SPValuePopover.h"
#import "SPValueFormatter.h"
#import "SPValueHighlighter.h"
#import "SPValueGutterView.h"

static const CGFloat SPValueFoldPlaceholderWidth = 22;

/// Hides folded text: its glyphs draw nothing and take no room (its line breaks included), the first one standing in
/// as a ⋯ placeholder. The text storage is untouched.
@interface SPValueFoldingLayoutManager : NSLayoutManager <NSLayoutManagerDelegate>
@property (nonatomic, copy) NSArray<NSValue *> *hiddenRanges; // ascending, not overlapping
/// The placeholder of a hidden range, in text container coordinates.
- (NSRect)placeholderRectForHiddenRange:(NSRange)range;
@end

@implementation SPValueFoldingLayoutManager

- (instancetype)init
{
	if ((self = [super init])) {
		_hiddenRanges = [[NSArray alloc] init];
		[self setDelegate:self];
	}
	return self;
}

- (void)dealloc
{
	[self setDelegate:nil];
	[_hiddenRanges release];
	[super dealloc];
}

/// The hidden range holding index, or {NSNotFound, 0}.
- (NSRange)_hiddenRangeAt:(NSUInteger)index
{
	NSUInteger low = 0, high = [_hiddenRanges count];
	while (low < high) {
		NSUInteger middle = (low + high) / 2;
		NSRange range = [[_hiddenRanges objectAtIndex:middle] rangeValue];
		if (index < range.location) high = middle;
		else if (index >= NSMaxRange(range)) low = middle + 1;
		else return range;
	}
	return NSMakeRange(NSNotFound, 0);
}

- (NSUInteger)layoutManager:(NSLayoutManager *)layoutManager shouldGenerateGlyphs:(const CGGlyph *)glyphs properties:(const NSGlyphProperty *)properties
		   characterIndexes:(const NSUInteger *)characterIndexes font:(NSFont *)font forGlyphRange:(NSRange)glyphRange
{
	if (![_hiddenRanges count]) return 0;
	NSString *text = [[self textStorage] string];
	NSGlyphProperty *changed = NULL;
	for (NSUInteger i = 0; i < glyphRange.length; i++) {
		NSUInteger index = characterIndexes[i];
		NSRange hidden = [self _hiddenRangeAt:index];
		if (hidden.location == NSNotFound) continue;
		if (!changed) {
			changed = malloc(sizeof(NSGlyphProperty) * glyphRange.length);
			memcpy(changed, properties, sizeof(NSGlyphProperty) * glyphRange.length);
		}
		// The first stands in for the placeholder; line breaks become control characters that break nothing
		BOOL lineBreak = index < [text length] && ([text characterAtIndex:index] == '\n' || [text characterAtIndex:index] == '\r');
		changed[i] = (index == hidden.location || lineBreak) ? NSGlyphPropertyControlCharacter : NSGlyphPropertyNull;
	}
	if (!changed) return 0;
	[layoutManager setGlyphs:glyphs properties:changed characterIndexes:characterIndexes font:font forGlyphRange:glyphRange];
	free(changed);
	return glyphRange.length;
}

- (NSControlCharacterAction)layoutManager:(NSLayoutManager *)layoutManager shouldUseAction:(NSControlCharacterAction)action forControlCharacterAtIndex:(NSUInteger)index
{
	NSRange hidden = [self _hiddenRangeAt:index];
	if (hidden.location == NSNotFound) return action;
	return (index == hidden.location) ? NSControlCharacterActionWhitespace : NSControlCharacterActionZeroAdvancement;
}

- (NSRect)layoutManager:(NSLayoutManager *)layoutManager boundingBoxForControlGlyphAtIndex:(NSUInteger)glyphIndex forTextContainer:(NSTextContainer *)textContainer
   proposedLineFragment:(NSRect)proposedRect glyphPosition:(NSPoint)glyphPosition characterIndex:(NSUInteger)characterIndex
{
	NSRange hidden = [self _hiddenRangeAt:characterIndex];
	CGFloat width = (hidden.location == characterIndex) ? SPValueFoldPlaceholderWidth : 0;
	return NSMakeRect(glyphPosition.x, 0, width, NSHeight(proposedRect));
}

- (NSRect)placeholderRectForHiddenRange:(NSRange)range
{
	NSTextContainer *container = [[self textContainers] firstObject];
	if (!container || range.location >= [[self textStorage] length]) return NSZeroRect;
	NSUInteger glyph = [self glyphIndexForCharacterAtIndex:range.location];
	NSRect box = [self boundingRectForGlyphRange:NSMakeRange(glyph, 1) inTextContainer:container];
	NSRect line = [self lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
	CGFloat height = MIN(NSHeight(line), 16);
	return NSMakeRect(NSMinX(box) + 2, NSMinY(line) + 2, SPValueFoldPlaceholderWidth - 4, height - 3);
}

- (void)drawGlyphsForGlyphRange:(NSRange)glyphsToShow atPoint:(NSPoint)origin
{
	[super drawGlyphsForGlyphRange:glyphsToShow atPoint:origin];
	if (![_hiddenRanges count]) return;
	NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightBold], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
	for (NSValue *value in _hiddenRanges) {
		NSRange hidden = [value rangeValue];
		if (hidden.location >= [[self textStorage] length]) continue;
		NSUInteger glyph = [self glyphIndexForCharacterAtIndex:hidden.location];
		if (!NSLocationInRange(glyph, glyphsToShow)) continue;
		NSRect rect = NSOffsetRect([self placeholderRectForHiddenRange:hidden], origin.x, origin.y);
		[[NSColor quaternaryLabelColor] setFill];
		[[NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4] fill];
		NSString *dots = @"⋯";
		NSSize size = [dots sizeWithAttributes:attributes];
		[dots drawAtPoint:NSMakePoint(NSMidX(rect) - size.width / 2, NSMidY(rect) - size.height / 2) withAttributes:attributes];
	}
}

@end

/// The popover's text view: a click on a fold's ⋯ unfolds it.
@interface SPValueTextView : NSTextView
@property (copy) void (^placeholderClicked)(NSRange hiddenRange);
@end

@implementation SPValueTextView

- (void)dealloc
{
	[_placeholderClicked release];
	[super dealloc];
}

- (void)mouseDown:(NSEvent *)event
{
	SPValueFoldingLayoutManager *layoutManager = (SPValueFoldingLayoutManager *)[self layoutManager];
	if (_placeholderClicked && [layoutManager isKindOfClass:[SPValueFoldingLayoutManager class]] && [[layoutManager hiddenRanges] count]) {
		NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
		NSPoint origin = [self textContainerOrigin];
		point = NSMakePoint(point.x - origin.x, point.y - origin.y);
		for (NSValue *value in [layoutManager hiddenRanges]) {
			if (NSPointInRect(point, NSInsetRect([layoutManager placeholderRectForHiddenRange:[value rangeValue]], -2, -2))) {
				_placeholderClicked([value rangeValue]);
				return;
			}
		}
	}
	[super mouseDown:event];
}

@end

NSString *const SPValuePopoverSizeKey = @"ValuePopoverSize";

static const NSSize SPValuePopoverDefaultSize = {560, 400};
static const NSSize SPValuePopoverMinimumSize = {360, 220};

/// The popover being shown (one at a time); retained while shown.
static SPValuePopover *SPCurrentValuePopover = nil;

/// The bottom-right corner handle: dragging it resizes the popover.
@interface SPValuePopoverResizeHandle : NSView
@property (copy) void (^dragged)(NSSize delta);
@end

@implementation SPValuePopoverResizeHandle

- (void)dealloc
{
	[_dragged release];
	[super dealloc];
}

- (void)drawRect:(NSRect)dirtyRect
{
	[[NSColor tertiaryLabelColor] setStroke];
	NSBezierPath *path = [NSBezierPath bezierPath];
	NSRect b = [self bounds];
	for (CGFloat offset = 3; offset <= 9; offset += 3) {
		[path moveToPoint:NSMakePoint(NSMaxX(b) - offset, NSMinY(b) + 1)];
		[path lineToPoint:NSMakePoint(NSMaxX(b) - 1, NSMinY(b) + offset)];
	}
	[path setLineWidth:1];
	[path stroke];
}

- (void)resetCursorRects
{
	[self addCursorRect:[self bounds] cursor:[NSCursor crosshairCursor]];
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint last = [NSEvent mouseLocation];
	while (YES) {
		NSEvent *next = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		if ([next type] == NSEventTypeLeftMouseUp) break;
		NSPoint now = [NSEvent mouseLocation];
		if (_dragged) _dragged(NSMakeSize(now.x - last.x, last.y - now.y)); // down grows the height
		last = now;
	}
}

@end

@implementation SPValuePopover
{
	NSString *_value;
	NSString *_columnName;
	NSUserDefaults *_defaults;
	void (^_saver)(NSString *, void (^)(NSString *));

	NSView *_contentView;
	NSScrollView *_scrollView;
	NSProgressIndicator *_spinner;
	NSUndoManager *_undoManager;
	NSViewController *_contentController;
	NSPopover *_popover;

	BOOL _typed;            // the user typed in the text (not formatting)
	BOOL _programmatic;     // a format, compact or revert is replacing the text
	BOOL _saving;
	BOOL _finished;         // closed: nothing more happens
	BOOL _closingConfirmed; // the close question was answered (or isn't needed)
	BOOL _hasLastFormat;
	SPValueFormat _lastFormat;
	NSUInteger _generation; // background formats started; a result only applies if it is still the latest
	BOOL _colored;          // drawn in _colorFormat's colors (a format was clicked, no Revert since)
	SPValueFormat _colorFormat;
	SPValueGutterView *_gutter;
	NSArray<NSValue *> *_foldRegions;      // what can be folded, by start (only with a format clicked)
	NSMutableArray<NSValue *> *_folded;    // the folded ones
}

@synthesize closed = _closed;
@synthesize discardConfirmer = _discardConfirmer;
@synthesize backgroundThreshold = _backgroundThreshold;
@synthesize colorLimit = _colorLimit;
@synthesize valueIsNull = _valueIsNull;
@synthesize contentSize = _contentSize;
@synthesize textView = _textView;
@synthesize titleField = _titleField;
@synthesize errorField = _errorField;
@synthesize jsonButton = _jsonButton;
@synthesize xmlButton = _xmlButton;
@synthesize htmlButton = _htmlButton;
@synthesize compactButton = _compactButton;
@synthesize revertButton = _revertButton;
@synthesize saveButton = _saveButton;
@synthesize cancelButton = _cancelButton;
@synthesize busy = _busy;

#pragma mark - Setup

- (instancetype)initWithValue:(NSString *)value columnName:(NSString *)columnName defaults:(NSUserDefaults *)defaults
						saver:(void (^)(NSString *, void (^)(NSString *)))saver
{
	if (!(self = [super init])) return nil;
	_value = [value copy] ?: @"";
	_columnName = [columnName copy] ?: @"";
	_defaults = [defaults retain];
	_saver = [saver copy];
	_backgroundThreshold = 256 * 1024;
	_colorLimit = 512 * 1024;
	_undoManager = [[NSUndoManager alloc] init];

	NSSize size = SPValuePopoverDefaultSize;
	NSString *saved = [_defaults stringForKey:SPValuePopoverSizeKey];
	if (saved) {
		NSSize remembered = NSSizeFromString(saved);
		if (remembered.width > 0 && remembered.height > 0) size = remembered;
	}
	_contentSize = [self _clampedSize:size];
	[self _buildContent];
	[self _updateButtons];
	return self;
}

- (void)dealloc
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[_gutter setToggle:nil];
	[_gutter release];
	[_foldRegions release];
	[_folded release];
	[(SPValueTextView *)_textView setPlaceholderClicked:nil];
	[_textView setDelegate:nil];
	[_popover setDelegate:nil];
	[_value release];
	[_columnName release];
	[_defaults release];
	[_saver release];
	[_closed release];
	[_discardConfirmer release];
	[_contentView release];
	[_undoManager removeAllActions];
	[_undoManager release];
	[_contentController release];
	[_popover release];
	[super dealloc];
}

- (NSSize)_clampedSize:(NSSize)size
{
	return NSMakeSize(MAX(size.width, SPValuePopoverMinimumSize.width), MAX(size.height, SPValuePopoverMinimumSize.height));
}

- (NSButton *)_buttonWithTitle:(NSString *)title action:(SEL)action
{
	NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
	[button setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[button setBezelStyle:NSBezelStyleRounded];
	[button setTranslatesAutoresizingMaskIntoConstraints:NO];
	return button;
}

- (NSTextField *)_labelWithString:(NSString *)string
{
	NSTextField *label = [NSTextField labelWithString:string];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[label setTranslatesAutoresizingMaskIntoConstraints:NO];
	return label;
}

- (void)_buildContent
{
	_contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, _contentSize.width, _contentSize.height)];

	// Top: the column and its length, then Format: JSON XML HTML, Compact, Revert
	NSString *count = [NSNumberFormatter localizedStringFromNumber:@([_value length]) numberStyle:NSNumberFormatterDecimalStyle];
	_titleField = [self _labelWithString:[NSString stringWithFormat:NSLocalizedString(@"%@ — %@ characters", @"value popover title: column name, character count"), _columnName, count]];
	[_titleField setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
	[_titleField setLineBreakMode:NSLineBreakByTruncatingTail];
	[_titleField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSTextField *formatLabel = [self _labelWithString:NSLocalizedString(@"Format:", @"value popover: label before the JSON / XML / HTML buttons")];
	_jsonButton = [self _buttonWithTitle:@"JSON" action:@selector(formatJSON)];
	_xmlButton = [self _buttonWithTitle:@"XML" action:@selector(formatXML)];
	_htmlButton = [self _buttonWithTitle:@"HTML" action:@selector(formatHTML)];
	_compactButton = [self _buttonWithTitle:NSLocalizedString(@"Compact", @"value popover: remove the formatting") action:@selector(compact)];
	_revertButton = [self _buttonWithTitle:NSLocalizedString(@"Revert", @"value popover: put the stored value back") action:@selector(revert)];
	[_compactButton setToolTip:NSLocalizedString(@"Remove the formatting, to save storage", @"value popover: Compact tooltip")];
	[_revertButton setToolTip:NSLocalizedString(@"Show the value as it is stored", @"value popover: Revert tooltip")];

	NSStackView *top = [NSStackView stackViewWithViews:@[_titleField, formatLabel, _jsonButton, _xmlButton, _htmlButton, _compactButton, _revertButton]];
	[top setSpacing:4];
	[top setCustomSpacing:12 afterView:_titleField];
	[top setCustomSpacing:10 afterView:_htmlButton];
	[top setTranslatesAutoresizingMaskIntoConstraints:NO];

	// Middle: the text, monospaced, not wrapped
	_scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, _contentSize.width, _contentSize.height)] autorelease];
	[_scrollView setHasVerticalScroller:YES];
	[_scrollView setHasHorizontalScroller:YES];
	[_scrollView setBorderType:NSBezelBorder];
	[_scrollView setTranslatesAutoresizingMaskIntoConstraints:NO];
	NSSize contentSize = [_scrollView contentSize];
	_textView = [[[SPValueTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)] autorelease];
	[[_textView textContainer] replaceLayoutManager:[[[SPValueFoldingLayoutManager alloc] init] autorelease]];
	_foldRegions = [[NSArray alloc] init];
	_folded = [[NSMutableArray alloc] init];
	[_textView setMinSize:NSMakeSize(0, contentSize.height)];
	[_textView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[_textView setVerticallyResizable:YES];
	[_textView setHorizontallyResizable:YES];
	[_textView setAutoresizingMask:NSViewWidthSizable];
	[[_textView textContainer] setContainerSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[[_textView textContainer] setWidthTracksTextView:NO];
	[_textView setFont:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]];
	[_textView setRichText:NO];
	[_textView setImportsGraphics:NO];
	[_textView setAutomaticQuoteSubstitutionEnabled:NO];
	[_textView setAutomaticDashSubstitutionEnabled:NO];
	[_textView setAutomaticTextReplacementEnabled:NO];
	[_textView setAutomaticSpellingCorrectionEnabled:NO];
	[_textView setContinuousSpellCheckingEnabled:NO];
	[_textView setSmartInsertDeleteEnabled:NO];
	[_textView setAllowsUndo:YES];
	[[_textView layoutManager] setAllowsNonContiguousLayout:YES];
	[self _wrapLinesFor:_value];
	[_textView setString:_value];
	[_textView setEditable:(_saver != nil)];
	[_textView setSelectable:YES];
	[_textView setDelegate:self];
	[_scrollView setDocumentView:_textView];

	// The gutter: line numbers and fold arrows
	SPValuePopover *popoverSelf = self; // the gutter never outlives the popover (its toggle is cleared in -dealloc)
	_gutter = [[SPValueGutterView alloc] initWithScrollView:_scrollView textView:_textView];
	[_gutter setToggle:^(NSUInteger line, BOOL allAtLevel) { [popoverSelf toggleFoldAtLine:line allAtLevel:allAtLevel]; }];
	[_scrollView setVerticalRulerView:_gutter];
	[_scrollView setHasVerticalRuler:YES];
	[_scrollView setRulersVisible:YES];
	[(SPValueTextView *)_textView setPlaceholderClicked:^(NSRange hiddenRange) { [popoverSelf _unfoldRegionsAt:hiddenRange.location]; }];

	// Bottom: an error line, a spinner while formatting, Cancel (Close) and Save, the resize corner
	_errorField = [self _labelWithString:@""];
	[_errorField setTextColor:[NSColor systemRedColor]];
	[_errorField setLineBreakMode:NSLineBreakByTruncatingTail];
	[_errorField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	_spinner = [[[NSProgressIndicator alloc] init] autorelease];
	[_spinner setStyle:NSProgressIndicatorStyleSpinning];
	[_spinner setControlSize:NSControlSizeSmall];
	[_spinner setDisplayedWhenStopped:NO];
	[_spinner setTranslatesAutoresizingMaskIntoConstraints:NO];
	_cancelButton = [self _buttonWithTitle:(_saver ? NSLocalizedString(@"Cancel", @"cancel button") : NSLocalizedString(@"Close", @"close button")) action:@selector(cancel)];
	[_cancelButton setKeyEquivalent:@"\e"];
	_saveButton = [self _buttonWithTitle:NSLocalizedString(@"Save", @"save button") action:@selector(save)];
	[_saveButton setKeyEquivalent:@"\r"];
	[_saveButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[_saveButton setHidden:(_saver == nil)];
	SPValuePopoverResizeHandle *handle = [[[SPValuePopoverResizeHandle alloc] initWithFrame:NSMakeRect(0, 0, 12, 12)] autorelease];
	[handle setTranslatesAutoresizingMaskIntoConstraints:NO];
	SPValuePopover *weakSelf = self; // the content view (and handle) never outlive the popover
	[handle setDragged:^(NSSize delta) {
		NSSize size = weakSelf.contentSize;
		weakSelf.contentSize = NSMakeSize(size.width + delta.width, size.height + delta.height);
	}];

	NSStackView *bottom = [NSStackView stackViewWithViews:@[_errorField, _spinner, _cancelButton, _saveButton]];
	[bottom setSpacing:8];
	[bottom setTranslatesAutoresizingMaskIntoConstraints:NO];

	[_contentView addSubview:top];
	[_contentView addSubview:_scrollView];
	[_contentView addSubview:bottom];
	[_contentView addSubview:handle];
	NSDictionary *views = NSDictionaryOfVariableBindings(top, _scrollView, bottom, handle);
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-10-[top]-10-|" options:0 metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-10-[_scrollView]-10-|" options:0 metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-10-[bottom]-16-|" options:0 metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-8-[top]-6-[_scrollView]-6-[bottom]-8-|" options:0 metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[handle(12)]-2-|" options:0 metrics:nil views:views]];
	[NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[handle(12)]-2-|" options:0 metrics:nil views:views]];
}

#pragma mark - Wrapping

/// Lines are not wrapped (formatted JSON / XML reads better), except when a line is so long that laying it out as
/// one line would stall the window (a minified multi-MB value): then the text wraps at the view's width.
- (void)_wrapLinesFor:(NSString *)text
{
	static const NSUInteger SPValuePopoverLongLine = 5000;
	BOOL wrap = NO;
	NSUInteger length = [text length], lineStart = 0;
	while (lineStart < length && !wrap) {
		NSRange newline = [text rangeOfString:@"\n" options:NSLiteralSearch range:NSMakeRange(lineStart, MIN(length - lineStart, SPValuePopoverLongLine + 1))];
		if (newline.location == NSNotFound) wrap = (length - lineStart > SPValuePopoverLongLine);
		else lineStart = NSMaxRange(newline);
		if (newline.location == NSNotFound) break;
	}
	NSTextContainer *container = [_textView textContainer];
	if (wrap) {
		[_textView setHorizontallyResizable:NO];
		[container setWidthTracksTextView:YES];
		[container setContainerSize:NSMakeSize([_scrollView contentSize].width, CGFLOAT_MAX)];
		[_textView setFrameSize:NSMakeSize([_scrollView contentSize].width, [_textView frame].size.height)];
		[_scrollView setHasHorizontalScroller:NO];
	} else {
		[_textView setHorizontallyResizable:YES];
		[container setWidthTracksTextView:NO];
		[container setContainerSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
		[_scrollView setHasHorizontalScroller:YES];
	}
}

- (void)setValueIsNull:(BOOL)valueIsNull
{
	_valueIsNull = valueIsNull;
	if (valueIsNull) [_titleField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%@ — NULL", @"value popover title: column name of a NULL value"), _columnName]];
}

#pragma mark - Size

- (void)setContentSize:(NSSize)size
{
	_contentSize = [self _clampedSize:size];
	[_contentView setFrameSize:_contentSize];
	if (_popover) [_popover setContentSize:_contentSize];
}

#pragma mark - Showing and closing

- (BOOL)isShown
{
	return _popover && [_popover isShown];
}

- (BOOL)showRelativeToRect:(NSRect)rect ofView:(NSView *)view
{
	if (_finished || _popover || ![view window]) return NO;
	if (SPCurrentValuePopover) [SPCurrentValuePopover closeDiscarding];
	SPCurrentValuePopover = [self retain]; // until it closes

	_contentController = [[NSViewController alloc] init];
	[_contentController setView:_contentView];
	_popover = [[NSPopover alloc] init];
	[_popover setContentViewController:_contentController];
	[_popover setContentSize:_contentSize];
	[_popover setBehavior:NSPopoverBehaviorTransient];
	[_popover setAnimates:NO];
	[_popover setDelegate:self];
	[_popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMaxY];
	[[_contentView window] makeFirstResponder:_textView];
	[_textView setSelectedRange:NSMakeRange(0, 0)];
	return YES;
}

/// Typed changes that closing would lose.
- (BOOL)_hasTypedChanges
{
	return _typed && ![[_textView string] isEqualToString:_value];
}

/// Asks about typed changes (once); YES when closing may go ahead.
- (BOOL)_confirmClose
{
	if (_finished || _closingConfirmed) return YES;
	if (![self _hasTypedChanges]) return YES;
	BOOL discard;
	if (_discardConfirmer) discard = _discardConfirmer(_columnName);
	else {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Discard your changes to %@?", @"value popover: close with typed changes"), _columnName]];
		[alert setInformativeText:NSLocalizedString(@"Your changes haven't been saved.", @"value popover: close with typed changes, informative text")];
		[alert addButtonWithTitle:NSLocalizedString(@"Discard", @"value popover: discard typed changes")];
		[alert addButtonWithTitle:NSLocalizedString(@"Keep Editing", @"value popover: keep the popover open")];
		discard = ([alert runModal] == NSAlertFirstButtonReturn);
	}
	return discard;
}

/// Closes without asking (the question, if any, was answered).
- (void)_close
{
	if (_finished) return;
	_closingConfirmed = YES;
	if ([self isShown]) [_popover close]; // -popoverDidClose: finishes
	[self _finish];
}

/// Once: remembers the size, drops pending work, tells the grid, lets go of the popover.
- (void)_finish
{
	if (_finished) return;
	_finished = YES;
	_generation++;
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_applyColors) object:nil];
	[_defaults setObject:NSStringFromSize(_contentSize) forKey:SPValuePopoverSizeKey];
	[_popover setDelegate:nil];
	void (^closed)(void) = [[_closed retain] autorelease];
	[_closed release];
	_closed = nil;
	if (closed) closed();
	if (SPCurrentValuePopover == self) {
		SPCurrentValuePopover = nil;
		[self autorelease];
	}
}

- (void)closeDiscarding
{
	[self _close];
}

- (void)cancel
{
	if (_finished || ![self _confirmClose]) return;
	[self _close];
}

- (BOOL)popoverShouldClose:(NSPopover *)popover
{
	if (_finished || _closingConfirmed) return YES;
	if (_saving) return NO;
	if (![self _confirmClose]) return NO;
	_closingConfirmed = YES;
	return YES;
}

- (void)popoverDidClose:(NSNotification *)notification
{
	[self _finish];
}

#pragma mark - Formatting

/// Replaces the whole text as one undoable change (typing's undo stack), without counting as typing.
- (void)_replaceTextWith:(NSString *)text
{
	if ([text isEqualToString:[_textView string]]) return;
	[self _unfoldAll];
	[self _setFoldRegions:@[]];
	NSRange all = NSMakeRange(0, [[_textView string] length]);
	BOOL editable = [_textView isEditable];
	_programmatic = YES;
	[_textView breakUndoCoalescing];
	[_textView setEditable:YES];
	[self _wrapLinesFor:text];
	if ([_textView shouldChangeTextInRange:all replacementString:text]) {
		[[_textView textStorage] replaceCharactersInRange:all withString:text];
		[_textView didChangeText];
	}
	[_textView setEditable:editable];
	[_textView breakUndoCoalescing];
	[_undoManager setActionName:NSLocalizedString(@"Format", @"value popover: undo action name")];
	_programmatic = NO;
	[_textView setSelectedRange:NSMakeRange(0, 0)];
	[_textView scrollRangeToVisible:NSMakeRange(0, 0)];
	[self _updateButtons];
}

- (void)_showError:(NSString *)message
{
	[_errorField setStringValue:message ?: @""];
	[_errorField setToolTip:[message length] ? message : nil];
}

/// Formats (pretty) or compacts the current text as format: off the main thread for a long text.
- (void)_layoutAs:(SPValueFormat)format pretty:(BOOL)pretty
{
	if (_finished || _busy) return;
	NSString *text = [[[_textView string] copy] autorelease];

	void (^apply)(NSString *, NSString *) = ^(NSString *result, NSString *error) {
		if (result) {
			_hasLastFormat = YES;
			_lastFormat = format;
			_colored = YES;
			_colorFormat = format;
			[self _showError:nil];
			[self _replaceTextWith:result];
			[self _applyColors];
		} else {
			[self _showError:error];
		}
		[self _updateButtons];
	};

	if ([text length] <= _backgroundThreshold) {
		NSString *error = nil;
		NSString *result = pretty ? [SPValueFormatter prettyString:text format:format error:&error] : [SPValueFormatter compactString:text format:format error:&error];
		apply(result, error);
		return;
	}

	_busy = YES;
	[_spinner startAnimation:nil];
	[self _updateButtons];
	NSUInteger generation = ++_generation;
	[self retain]; // until the result is back on the main thread
	void (^mainApply)(NSString *, NSString *) = [[apply copy] autorelease];
	[mainApply retain];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *error = nil;
		NSString *result = pretty ? [SPValueFormatter prettyString:text format:format error:&error] : [SPValueFormatter compactString:text format:format error:&error];
		[result retain];
		[error retain];
		dispatch_async(dispatch_get_main_queue(), ^{
			_busy = NO;
			[_spinner stopAnimation:nil];
			if (!_finished && generation == _generation) mainApply(result, error);
			else [self _updateButtons];
			[result release];
			[error release];
			[mainApply release];
			[self release];
		});
	});
}

- (void)formatJSON
{
	[self _layoutAs:SPValueFormatJSON pretty:YES];
}

- (void)formatXML
{
	[self _layoutAs:SPValueFormatXML pretty:YES];
}

- (void)formatHTML
{
	[self _layoutAs:SPValueFormatHTML pretty:YES];
}

- (void)compact
{
	if (!_hasLastFormat) return;
	[self _layoutAs:_lastFormat pretty:NO];
}

- (void)revert
{
	if (_finished || _busy) return;
	[self _showError:nil];
	_colored = NO;
	[self _replaceTextWith:_value];
	[self _applyColors];
}

#pragma mark - Folding

- (NSRulerView *)gutterView
{
	return _gutter;
}

- (NSUInteger)lineNumberForCharacterIndex:(NSUInteger)index
{
	return [_gutter lineNumberForCharacterIndex:index];
}

- (NSUInteger)_lineOfRegion:(NSRange)region
{
	return [_gutter lineNumberForCharacterIndex:region.location];
}

- (NSArray<NSNumber *> *)_linesOf:(NSArray<NSValue *> *)regions
{
	NSMutableIndexSet *lines = [NSMutableIndexSet indexSet];
	for (NSValue *value in regions) [lines addIndex:[self _lineOfRegion:[value rangeValue]]];
	NSMutableArray *result = [NSMutableArray array];
	[lines enumerateIndexesUsingBlock:^(NSUInteger line, BOOL *stop) { [result addObject:@(line)]; }];
	return result;
}

- (NSArray<NSNumber *> *)foldableLines
{
	return [self _linesOf:_foldRegions];
}

- (NSArray<NSNumber *> *)foldedLines
{
	return [self _linesOf:_folded];
}

/// How many fold regions contain region (its level).
- (NSUInteger)_levelOfRegion:(NSRange)region
{
	NSUInteger level = 0;
	for (NSValue *value in _foldRegions) {
		NSRange other = [value rangeValue];
		if (!NSEqualRanges(other, region) && other.location <= region.location && NSMaxRange(other) >= NSMaxRange(region)) level++;
	}
	return level;
}

- (void)toggleFoldAtLine:(NSUInteger)line allAtLevel:(BOOL)allAtLevel
{
	NSValue *target = nil;
	for (NSValue *value in _foldRegions) {
		if ([self _lineOfRegion:[value rangeValue]] == line) { target = value; break; }
	}
	if (!target) return;
	BOOL fold = ![_folded containsObject:target];
	NSArray<NSValue *> *regions = @[target];
	if (allAtLevel) {
		NSUInteger level = [self _levelOfRegion:[target rangeValue]];
		NSMutableArray *same = [NSMutableArray array];
		for (NSValue *value in _foldRegions) if ([self _levelOfRegion:[value rangeValue]] == level) [same addObject:value];
		regions = same;
	}
	for (NSValue *value in regions) {
		if (fold && ![_folded containsObject:value]) [_folded addObject:value];
		if (!fold) [_folded removeObject:value];
	}
	[self _foldsChanged];
}

/// The fold regions now (folded ones that no longer exist are dropped).
- (void)_setFoldRegions:(NSArray<NSValue *> *)regions
{
	if ([regions isEqualToArray:_foldRegions]) return;
	[_foldRegions release];
	_foldRegions = [regions copy];
	NSUInteger before = [_folded count];
	[_folded filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSValue *value, NSDictionary *bindings) { return [regions containsObject:value]; }]];
	if ([_folded count] != before) [self _foldsChanged];
	else [self _updateGutter];
}

- (void)_unfoldAll
{
	if (![_folded count]) return;
	[_folded removeAllObjects];
	[self _foldsChanged];
}

/// Unfolds the folded regions holding index (a click on a ⋯, the caret moving in).
- (void)_unfoldRegionsAt:(NSUInteger)index
{
	NSUInteger before = [_folded count];
	[_folded filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSValue *value, NSDictionary *bindings) {
		NSRange range = [value rangeValue];
		return !(index >= range.location && index < NSMaxRange(range));
	}]];
	if ([_folded count] != before) [self _foldsChanged];
}

- (void)_updateGutter
{
	NSMutableIndexSet *foldable = [NSMutableIndexSet indexSet], *folded = [NSMutableIndexSet indexSet];
	for (NSNumber *line in [self foldableLines]) [foldable addIndex:[line unsignedIntegerValue]];
	for (NSNumber *line in [self foldedLines]) [folded addIndex:[line unsignedIntegerValue]];
	[_gutter setFoldableLines:foldable];
	[_gutter setFoldedLines:folded];
	[_gutter setNeedsDisplay:YES];
}

/// Hides the outermost folded regions and redraws.
- (void)_foldsChanged
{
	NSArray<NSValue *> *sorted = [_folded sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
		NSUInteger x = [a rangeValue].location, y = [b rangeValue].location;
		return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
	}];
	NSMutableArray<NSValue *> *hidden = [NSMutableArray array];
	for (NSValue *value in sorted) {
		NSRange range = [value rangeValue];
		if ([hidden count] && NSMaxRange(range) <= NSMaxRange([[hidden lastObject] rangeValue])) continue; // inside an outer fold
		[hidden addObject:value];
	}
	SPValueFoldingLayoutManager *layoutManager = (SPValueFoldingLayoutManager *)[_textView layoutManager];
	[layoutManager setHiddenRanges:hidden];
	NSRange all = NSMakeRange(0, [[_textView string] length]);
	[layoutManager invalidateGlyphsForCharacterRange:all changeInLength:0 actualCharacterRange:NULL];
	[layoutManager invalidateLayoutForCharacterRange:all actualCharacterRange:NULL];
	[_gutter setHiddenRanges:hidden];
	[self _updateGutter];
	[_textView setNeedsDisplay:YES];
}

#pragma mark - Colors

/// Draws the text in the clicked format's colors (or plain): temporary attributes of the layout manager, so the text
/// itself, its undo and what Save writes stay plain.
- (void)_applyColors
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_applyColors) object:nil];
	NSLayoutManager *layoutManager = [_textView layoutManager];
	NSString *text = [_textView string];
	NSRange all = NSMakeRange(0, [text length]);
	[layoutManager removeTemporaryAttribute:NSForegroundColorAttributeName forCharacterRange:all];
	BOOL drawn = !_finished && _colored && [text length] <= _colorLimit;
	[self _setFoldRegions:drawn ? [SPValueHighlighter foldRangesInText:text format:_colorFormat] : @[]];
	if (!drawn) return;
	for (SPValueToken *token in [SPValueHighlighter tokensInText:text format:_colorFormat]) {
		[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName value:[SPValueHighlighter colorForKind:token.kind] forCharacterRange:token.range];
	}
}

#pragma mark - Saving

- (void)save
{
	if (_finished || _busy || _saving || !_saver || [[_textView string] isEqualToString:_value]) return;
	_saving = YES;
	[self _showError:nil];
	[self _updateButtons];
	NSString *text = [[[_textView string] copy] autorelease];

	__block BOOL answered = NO;
	[self retain]; // until the saver answers
	void (^done)(NSString *) = ^(NSString *error) {
		if (answered) return;
		answered = YES;
		_saving = NO;
		if (!_finished) {
			if (error) {
				[self _showError:error];
				[self _updateButtons];
			} else {
				[self _close];
			}
		}
		[self release];
	};
	_saver(text, [[done copy] autorelease]);
}

#pragma mark - Buttons

- (void)_updateButtons
{
	BOOL idle = !_busy && !_saving && !_finished;
	BOOL changed = ![[_textView string] isEqualToString:_value];
	[_jsonButton setEnabled:idle];
	[_xmlButton setEnabled:idle];
	[_htmlButton setEnabled:idle];
	[_compactButton setEnabled:idle && _hasLastFormat];
	[_revertButton setEnabled:idle && changed];
	[_saveButton setEnabled:idle && changed && _saver != nil];
	[_textView setEditable:(_saver != nil) && !_busy && !_saving];
}

#pragma mark - NSTextViewDelegate

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)view
{
	return _undoManager;
}

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString
{
	// Nothing is edited while hidden: an edit unfolds everything, and the arrows wait for the text to settle
	if (!_programmatic) {
		[self _unfoldAll];
		[self _setFoldRegions:@[]];
	}
	return YES;
}

- (NSRange)textView:(NSTextView *)textView willChangeSelectionFromCharacterRange:(NSRange)oldRange toCharacterRange:(NSRange)newRange
{
	// The caret moving into a fold unfolds it
	if ([_folded count] && !_programmatic) {
		BOOL inside = NO;
		for (NSValue *value in _folded) {
			NSRange range = [value rangeValue];
			if (newRange.location > range.location && newRange.location < NSMaxRange(range)) inside = YES;
		}
		if (inside) [self _unfoldRegionsAt:newRange.location];
	}
	return newRange;
}

- (void)textDidChange:(NSNotification *)notification
{
	if (_programmatic) return;
	[self _unfoldAll];
	// The colors follow the text a moment after typing pauses (and after undo or redo)
	if (_colored) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_applyColors) object:nil];
		[self performSelector:@selector(_applyColors) withObject:nil afterDelay:0.25];
	}
	_typed = YES;
	[self _showError:nil];
	[self _updateButtons];
}

@end
