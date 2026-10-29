#import "SPPostgresTaskDisplay.h"
#import "SPPostgresTaskRunner.h"
#import "YRKSpinningProgressIndicator.h"

static void *SPPostgresTaskDisplayRunnerContext = &SPPostgresTaskDisplayRunnerContext;

// As MySQL's task display (-[SPDatabaseDocument fadeInTaskProgressWindow:])
static const NSTimeInterval SPPostgresTaskDisplayFadeInDelay = 0.5;
static const NSTimeInterval SPPostgresTaskDisplayFadeInDuration = 0.6;
static const NSTimeInterval SPPostgresTaskDisplayFrameInterval = 1.0 / 30.0;

/// Laid over the blocked view while busy: every click, scroll and key it gets goes nowhere.
@interface SPPostgresTaskBlockerView : NSView
@end

@implementation SPPostgresTaskBlockerView

- (NSView *)hitTest:(NSPoint)point
{
	// point is in the superview's coordinates
	return NSMouseInRect(point, [self frame], [[self superview] isFlipped]) ? self : nil;
}

- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {}
- (void)rightMouseDown:(NSEvent *)event {}
- (void)rightMouseUp:(NSEvent *)event {}
- (void)rightMouseDragged:(NSEvent *)event {}
- (void)otherMouseDown:(NSEvent *)event {}
- (void)otherMouseUp:(NSEvent *)event {}
- (void)otherMouseDragged:(NSEvent *)event {}
- (void)scrollWheel:(NSEvent *)event {}
- (void)magnifyWithEvent:(NSEvent *)event {}
- (void)swipeWithEvent:(NSEvent *)event {}
- (void)keyDown:(NSEvent *)event {}
- (void)keyUp:(NSEvent *)event {}
- (NSMenu *)menuForEvent:(NSEvent *)event { return nil; }

- (void)resetCursorRects
{
	[self addCursorRect:[self bounds] cursor:[NSCursor arrowCursor]];
}

@end

@interface SPPostgresTaskDisplay ()

// ProgressIndicatorLayer.xib's outlets (the xib is loaded with the display as its owner, through these setters)
@property (retain) NSBox *taskProgressLayer;
@property (retain) YRKSpinningProgressIndicator *taskProgressIndicator;
@property (retain) NSTextField *taskDescriptionText;
@property (retain) NSButton *taskCancelButton;
@property (retain) NSTextField *taskDurationTime;

- (void)_taskStarted;
- (void)_taskEnded;
- (void)_showDescription;
- (void)_showCancelButton;
- (void)_showDuration;
- (void)_fadeIn:(NSTimer *)timer;
- (void)_centerProgressWindow;
- (void)_stopTimers;
- (void)_updateBlocker;
- (void)_updateProgressWindow;
- (void)_detachProgressWindow;
- (void)_installBlocker;
- (void)_removeBlocker;

@end

@implementation SPPostgresTaskDisplay
{
	SPPostgresTaskRunner *runner;
	BOOL observing;
	BOOL invalidated;

	NSArray *nibObjects;
	NSWindow *progressWindow;
	NSDateComponentsFormatter *durationFormatter;

	/// The runner is busy: the task display is up
	BOOL active;
	/// The Cancel button was clicked for the running task (it stays disabled until another task can be cancelled)
	BOOL cancelClicked;

	NSTimer *fadeTimer;
	NSDate *fadeStartDate;
	NSTimer *durationTimer;
	NSDate *taskStartDate;

	SPPostgresTaskBlockerView *blocker;
	/// The first responder inside the blocked view when the blocker took over (given back afterwards)
	NSResponder *savedResponder;
}

@synthesize parentWindow;
@synthesize blockedView;
@synthesize taskProgressLayer;
@synthesize taskProgressIndicator;
@synthesize taskDescriptionText;
@synthesize taskCancelButton;
@synthesize taskDurationTime;

- (instancetype)initWithRunner:(SPPostgresTaskRunner *)theRunner
{
	if ((self = [super init])) {
		runner = [theRunner retain];

		NSArray *topLevelObjects = nil;
		NSNib *nib = [[NSNib alloc] initWithNibNamed:@"ProgressIndicatorLayer" bundle:[NSBundle mainBundle]];
		if ([nib instantiateWithOwner:self topLevelObjects:&topLevelObjects]) nibObjects = [topLevelObjects retain];
		else NSLog(@"Progress indicator layer could not be loaded; progress display will not function correctly.");
		[nib release];

		// As MySQL's (-[SPDatabaseDocument awakeFromNib]): a white indicator with a shadow, in a clear child window
		[taskProgressIndicator setForeColor:[NSColor whiteColor]];
		NSShadow *indicatorShadow = [[NSShadow alloc] init];
		[indicatorShadow setShadowOffset:NSMakeSize(1.0f, -1.0f)];
		[indicatorShadow setShadowBlurRadius:1.0f];
		[indicatorShadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0f alpha:0.75f]];
		[taskProgressIndicator setShadow:indicatorShadow];
		[indicatorShadow release];

		progressWindow = [[NSWindow alloc] initWithContentRect:(taskProgressLayer ? [taskProgressLayer bounds] : NSMakeRect(0, 0, 437, 160)) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		[progressWindow setReleasedWhenClosed:NO];
		[progressWindow setOpaque:NO];
		[progressWindow setBackgroundColor:[NSColor clearColor]];
		[progressWindow setAlphaValue:0.0f];
		if (taskProgressLayer) [progressWindow setContentView:taskProgressLayer];

		durationFormatter = [[NSDateComponentsFormatter alloc] init];
		[durationFormatter setAllowedUnits:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond];
		[durationFormatter setZeroFormattingBehavior:NSDateComponentsFormatterZeroFormattingBehaviorPad];

		[taskCancelButton setHidden:YES];

		for (NSString *key in @[@"busy", @"currentDescription", @"currentCancelTitle"]) {
			[runner addObserver:self forKeyPath:key options:0 context:SPPostgresTaskDisplayRunnerContext];
		}
		observing = YES;

		if ([runner isBusy]) [self _taskStarted];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	[progressWindow setContentView:nil];
	[progressWindow close];
	[progressWindow release];
	[nibObjects release];
	[taskProgressLayer release];
	[taskProgressIndicator release];
	[taskDescriptionText release];
	[taskCancelButton release];
	[taskDurationTime release];
	[durationFormatter release];
	[super dealloc];
}

- (NSWindow *)progressWindow
{
	return progressWindow;
}

- (NSButton *)cancelButton
{
	return taskCancelButton;
}

- (NSTextField *)descriptionField
{
	return taskDescriptionText;
}

#pragma mark - Windows

- (void)setParentWindow:(NSWindow *)window
{
	if (invalidated) window = nil;

	// As MySQL's -willResignActiveTabInWindow and -didBecomeActiveTabInWindow
	if (window != parentWindow) {
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		if (parentWindow) {
			[center removeObserver:self name:NSWindowDidResizeNotification object:parentWindow];
			[self _detachProgressWindow];
		}
		parentWindow = window;
		if (parentWindow) [center addObserver:self selector:@selector(_parentWindowDidResize:) name:NSWindowDidResizeNotification object:parentWindow];
	}

	// Also when the same window is set again: the blocked view may only now be in it
	[self _updateProgressWindow];
	[self _updateBlocker];
}

/// The child window is in parentWindow while a task is up (an idle tab adds no window; it would be at alpha 0 anyway).
- (void)_updateProgressWindow
{
	if (!invalidated && active && parentWindow) {
		if ([progressWindow parentWindow] == parentWindow) return;
		[self _detachProgressWindow];
		[self _centerProgressWindow];
		[parentWindow addChildWindow:progressWindow ordered:NSWindowAbove];
	}
	else {
		[self _detachProgressWindow];
	}
}

- (void)_detachProgressWindow
{
	NSWindow *parent = [progressWindow parentWindow];
	if (parent) [parent removeChildWindow:progressWindow];
	[progressWindow orderOut:self];
}

/// As -[SPDatabaseDocument tabDidResize]: the task display stays centered while it is up.
- (void)_parentWindowDidResize:(NSNotification *)notification
{
	if (active) [self _centerProgressWindow];
}

- (void)setBlockedView:(NSView *)view
{
	if (invalidated) view = nil;
	if (view == blockedView) return;
	[self _removeBlocker];
	blockedView = view;
	[self _updateBlocker];
}

/// As -[SPDatabaseDocument centerTaskWindow].
- (void)_centerProgressWindow
{
	if (!parentWindow) return;
	NSRect parentRect = [parentWindow frame];
	NSRect taskRect = [progressWindow frame];
	NSPoint origin;
	origin.x = round(NSMinX(parentRect) + NSWidth(parentRect) / 2 - NSWidth(taskRect) / 2);
	origin.y = round(NSMinY(parentRect) + NSHeight(parentRect) / 2 - NSHeight(taskRect) / 2);
	[progressWindow setFrameOrigin:origin];
}

#pragma mark - The runner

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context != SPPostgresTaskDisplayRunnerContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	if (invalidated) return;

	if ([keyPath isEqualToString:@"busy"]) {
		if ([runner isBusy] && !active) [self _taskStarted];
		else if (![runner isBusy] && active) [self _taskEnded];
	}
	else if ([keyPath isEqualToString:@"currentDescription"]) {
		[self _showDescription];
	}
	else if ([keyPath isEqualToString:@"currentCancelTitle"]) {
		// Another task: it can be cancelled again
		cancelClicked = NO;
		[self _showCancelButton];
	}
}

/// As -[SPDatabaseDocument startTaskWithDescription:]: the display fades in after a moment, the time counts up.
- (void)_taskStarted
{
	active = YES;
	cancelClicked = NO;

	[taskProgressIndicator setIndeterminate:YES];
	[taskProgressIndicator startAnimation:self];
	[taskCancelButton setHidden:YES];
	[self _showDescription];
	[self _showCancelButton];

	[self _stopTimers];
	[progressWindow setAlphaValue:0.0f];
	fadeStartDate = [[NSDate alloc] init];
	taskStartDate = [[NSDate alloc] init];
	[self _showDuration];
	fadeTimer = [[NSTimer scheduledTimerWithTimeInterval:SPPostgresTaskDisplayFrameInterval target:self selector:@selector(_fadeIn:) userInfo:nil repeats:YES] retain];
	durationTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(_showDuration) userInfo:nil repeats:YES] retain];

	[self _updateProgressWindow];
	[self _updateBlocker];
}

/// As -[SPDatabaseDocument endTask]: hidden at once, timers stopped.
- (void)_taskEnded
{
	active = NO;
	cancelClicked = NO;

	[self _stopTimers];
	[taskProgressIndicator stopAnimation:self];
	[progressWindow setAlphaValue:0.0f];
	[taskCancelButton setHidden:YES];
	[self _showDuration];

	[self _updateProgressWindow];
	[self _updateBlocker];
}

- (void)_stopTimers
{
	[fadeTimer invalidate];
	[fadeTimer release];
	fadeTimer = nil;
	[fadeStartDate release];
	fadeStartDate = nil;
	[durationTimer invalidate];
	[durationTimer release];
	durationTimer = nil;
	[taskStartDate release];
	taskStartDate = nil;
}

/// Bold 13 pt white text with a shadow, as MySQL's description and duration.
- (NSAttributedString *)_hudString:(NSString *)string
{
	NSShadow *textShadow = [[[NSShadow alloc] init] autorelease];
	[textShadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0f alpha:0.75f]];
	[textShadow setShadowOffset:NSMakeSize(1.0f, -1.0f)];
	[textShadow setShadowBlurRadius:3.0f];
	NSDictionary *attributes = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:13.0f], NSShadowAttributeName: textShadow};
	return [[[NSAttributedString alloc] initWithString:(string ?: @"") attributes:attributes] autorelease];
}

- (void)_showDescription
{
	if (!active) return;
	[taskDescriptionText setAttributedStringValue:[self _hudString:[runner currentDescription]]];
}

/// As -enableTaskCancellationWithTitle: / -disableTaskCancellation: shown, with the task's title, while it can be cancelled.
- (void)_showCancelButton
{
	NSString *title = [runner currentCancelTitle];
	if (!active || ![title length]) {
		[taskCancelButton setHidden:YES];
		return;
	}
	[taskCancelButton setTitle:title];
	[taskCancelButton setEnabled:!cancelClicked];
	[taskCancelButton setHidden:NO];
}

/// The elapsed time (HH:MM:SS), as -[SPDatabaseDocument showQueryExecutionTime]; 00:00:00 when idle.
- (void)_showDuration
{
	NSTimeInterval elapsed = taskStartDate ? -[taskStartDate timeIntervalSinceNow] : 0;
	[taskDurationTime setAttributedStringValue:[self _hudString:[durationFormatter stringFromTimeInterval:elapsed]]];
}

/// As -[SPDatabaseDocument fadeInTaskProgressWindow:]: hidden for the first 0.5 s, then faded in over 0.6 s.
- (void)_fadeIn:(NSTimer *)timer
{
	NSTimeInterval sinceStart = -[fadeStartDate timeIntervalSinceNow];
	if (sinceStart < SPPostgresTaskDisplayFadeInDelay) return;

	CGFloat alpha = [progressWindow alphaValue];
	if (alpha == 0) [self _centerProgressWindow];

	alpha = (CGFloat)((sinceStart - SPPostgresTaskDisplayFadeInDelay) / SPPostgresTaskDisplayFadeInDuration);
	if (alpha > 1) alpha = 1;
	[progressWindow setAlphaValue:alpha];

	if (alpha == 1) {
		[fadeTimer invalidate];
		[fadeTimer release];
		fadeTimer = nil;
		[fadeStartDate release];
		fadeStartDate = nil;
	}
}

- (IBAction)cancelTask:(id)sender
{
	if (invalidated || !active || ![[runner currentCancelTitle] length] || cancelClicked) return;
	cancelClicked = YES;
	[taskCancelButton setEnabled:NO];
	[runner cancelAll];
}

#pragma mark - Blocking input

- (void)_updateBlocker
{
	BOOL block = !invalidated && active && parentWindow && blockedView && [blockedView superview];
	if (block && !blocker) [self _installBlocker];
	else if (!block && blocker) [self _removeBlocker];
}

- (void)_blockedViewFrameDidChange:(NSNotification *)notification
{
	[blocker setFrame:[blockedView frame]];
}

/// Over blockedView (as its sibling: the blocked view may be a split view, whose subviews are its panes), on top.
- (void)_installBlocker
{
	NSView *superview = [blockedView superview];
	blocker = [[SPPostgresTaskBlockerView alloc] initWithFrame:[blockedView frame]];
	[blocker setAutoresizingMask:[blockedView autoresizingMask]];
	[superview addSubview:blocker positioned:NSWindowAbove relativeTo:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_blockedViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:blockedView];

	// Keys go to the blocker while busy (a field being edited ends its editing)
	NSWindow *window = [blockedView window];
	NSResponder *responder = [window firstResponder];
	if ([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder isFieldEditor] && [[(NSTextView *)responder delegate] isKindOfClass:[NSView class]]) {
		responder = (NSView *)[(NSTextView *)responder delegate];
	}
	if ([responder isKindOfClass:[NSView class]] && [(NSView *)responder isDescendantOf:blockedView]) {
		if ([window makeFirstResponder:blocker]) savedResponder = [responder retain];
	}
}

- (void)_removeBlocker
{
	if (!blocker) return;
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewFrameDidChangeNotification object:blockedView];

	NSWindow *window = [blocker window];
	BOOL hadFocus = window && [window firstResponder] == blocker;
	[blocker removeFromSuperview];
	[blocker release];
	blocker = nil;

	NSResponder *responder = [savedResponder autorelease];
	savedResponder = nil;
	if (hadFocus && [responder isKindOfClass:[NSView class]] && [(NSView *)responder window] == window) {
		[window makeFirstResponder:responder];
	}
}

#pragma mark - Invalidating

- (void)invalidate
{
	if (invalidated) return;

	if (observing) {
		for (NSString *key in @[@"busy", @"currentDescription", @"currentCancelTitle"]) {
			[runner removeObserver:self forKeyPath:key context:SPPostgresTaskDisplayRunnerContext];
		}
		observing = NO;
	}

	if (active) [self _taskEnded];
	[self _stopTimers];
	[self _removeBlocker];
	[self setParentWindow:nil];
	blockedView = nil;
	invalidated = YES;

	[runner release];
	runner = nil;
}

@end
