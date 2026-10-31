#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/Postgres/SPPostgresTaskDisplay.h"

/// SPPostgresTaskDisplay over a background runner on PG 18, in a real borderless window.
@interface SPPostgresTaskDisplayTests : XCTestCase
@property (strong) PGPostgresConnection *connection;
@property (strong) SPPostgresTaskRunner *runner;
@property (strong) SPPostgresTaskDisplay *display;
@property (strong) NSWindow *window;
/// The tab's view (blocked while busy), and the control filling it
@property (strong) NSView *blockedView;
@property (strong) NSTextView *inner;
@end

@implementation SPPostgresTaskDisplayTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.connection = [SPPostgresTestServers connectedConnectionOnPort:55418];
	XCTAssertNotNil(self.connection);
	self.runner = [[SPPostgresTaskRunner alloc] initWithConnection:self.connection];

	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 600, 400) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
	[self.window setReleasedWhenClosed:NO];
	NSView *contentView = [self.window contentView];
	self.blockedView = [[NSView alloc] initWithFrame:NSMakeRect(100, 50, 400, 300)];
	[self.blockedView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	self.inner = [[NSTextView alloc] initWithFrame:[self.blockedView bounds]];
	[self.inner setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[self.blockedView addSubview:self.inner];
	[contentView addSubview:self.blockedView];
	[self.window orderFront:nil];

	self.display = [[SPPostgresTaskDisplay alloc] initWithRunner:self.runner];
	self.display.blockedView = self.blockedView;
}

- (void)tearDown
{
	[self.display invalidate];
	self.display = nil;
	__block BOOL idle = NO;
	[self.runner invalidateWithCompletion:^{ idle = YES; }];
	[self spinUntil:^BOOL{ return idle; } timeout:40];
	self.runner = nil;
	[self.connection disconnect];
	self.connection = nil;
	[self.window orderOut:nil];
	[self.window close];
	self.window = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
	}
	return condition();
}

/// Spins until `seconds` after start.
- (void)spinUntilTime:(NSTimeInterval)seconds since:(NSDate *)start
{
	[self spinUntil:^BOOL{ return -[start timeIntervalSinceNow] >= seconds; } timeout:seconds + 1];
}

/// A pg_sleep(seconds) task; *outCancelled (when given) is set from its completion.
- (void)sleep:(double)seconds description:(NSString *)description cancelTitle:(NSString *)cancelTitle done:(BOOL *)outDone cancelled:(BOOL *)outCancelled
{
	NSString *query = [NSString stringWithFormat:@"SELECT pg_sleep(%g)", seconds];
	[self.runner runTaskWithDescription:description cancelTitle:cancelTitle work:^id(PGPostgresConnection *connection, NSError **error) {
		return [connection execute:query];
	} completion:^(id result, NSError *error, BOOL cancelled) {
		if (outCancelled) *outCancelled = cancelled;
		if (outDone) *outDone = YES;
	}];
}

/// What the window shows at the middle of blockedView.
- (NSView *)hitAtBlockedViewCenter
{
	NSView *contentView = [self.window contentView];
	NSPoint point = NSMakePoint(NSMidX([self.blockedView frame]), NSMidY([self.blockedView frame]));
	return [contentView hitTest:[contentView convertPoint:point toView:[contentView superview]]];
}

#pragma mark - Tests

- (void)testHiddenForHalfASecondThenFadesIn
{
	self.display.parentWindow = self.window;
	NSDate *start = [NSDate date];
	BOOL done = NO;
	[self sleep:2 description:@"Loading table data..." cancelTitle:nil done:&done cancelled:NULL];

	NSWindow *progressWindow = self.display.progressWindow;
	XCTAssertNotNil(progressWindow);
	XCTAssertTrue([[self.window childWindows] containsObject:progressWindow], @"a child of the parent window");
	XCTAssertEqualObjects([self.display.descriptionField stringValue], @"Loading table data...");

	[self spinUntilTime:0.3 since:start];
	XCTAssertEqual([progressWindow alphaValue], 0.0, @"hidden for the first half second");
	[self spinUntilTime:0.8 since:start];
	XCTAssertGreaterThan([progressWindow alphaValue], 0.0, @"fading in");
	XCTAssertLessThan([progressWindow alphaValue], 1.0);
	[self spinUntilTime:1.3 since:start];
	XCTAssertEqual([progressWindow alphaValue], 1.0, @"faded in over 0.6 s");

	// Centered on the parent window
	NSRect parent = [self.window frame], child = [progressWindow frame];
	XCTAssertEqualWithAccuracy(NSMidX(child), NSMidX(parent), 1);
	XCTAssertEqualWithAccuracy(NSMidY(child), NSMidY(parent), 1);

	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
	XCTAssertTrue(done);
	XCTAssertEqual([progressWindow alphaValue], 0.0, @"hidden once the task is over");
	XCTAssertFalse([[self.window childWindows] containsObject:progressWindow], @"an idle tab adds no window");
	XCTAssertFalse([progressWindow isVisible]);
}

- (void)testCancelButtonShowsTitleAndCancels
{
	self.display.parentWindow = self.window;
	BOOL done = NO, cancelled = NO;
	[self sleep:30 description:@"Loading..." cancelTitle:@"Stop" done:&done cancelled:&cancelled];

	NSButton *button = self.display.cancelButton;
	XCTAssertNotNil(button);
	XCTAssertFalse([button isHidden]);
	XCTAssertTrue([button isEnabled]);
	XCTAssertEqualObjects([button title], @"Stop");

	[self spinUntil:^BOOL{ return NO; } timeout:0.3]; // the statement is running
	[button performClick:nil];
	XCTAssertFalse([button isEnabled], @"disabled as soon as it is clicked");

	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10], @"the statement was cancelled");
	XCTAssertTrue(done);
	XCTAssertTrue(cancelled);
	XCTAssertEqual([self.display.progressWindow alphaValue], 0.0);
	XCTAssertTrue([button isHidden]);
}

- (void)testNoCancelTitleHidesButton
{
	self.display.parentWindow = self.window;
	[self sleep:0.3 description:@"Loading..." cancelTitle:nil done:NULL cancelled:NULL];
	XCTAssertTrue([self.display.cancelButton isHidden]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
}

- (void)testInputBlockedWhileBusy
{
	self.display.parentWindow = self.window;
	XCTAssertEqual([self hitAtBlockedViewCenter], self.inner);
	XCTAssertTrue([self.window makeFirstResponder:self.inner]);

	[self sleep:0.5 description:@"Loading..." cancelTitle:nil done:NULL cancelled:NULL];
	NSView *blocker = [self hitAtBlockedViewCenter];
	XCTAssertNotEqual(blocker, self.inner);
	XCTAssertNotNil(blocker);
	XCTAssertFalse([blocker isDescendantOf:self.inner]);
	XCTAssertEqual((id)[self.window firstResponder], blocker, @"keys go to the blocker");

	// Mouse, scroll and key events stop at the blocker
	NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(300, 200) modifierFlags:0 timestamp:0 windowNumber:[self.window windowNumber] context:nil eventNumber:0 clickCount:1 pressure:1];
	[blocker mouseDown:down];
	NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:[self.window windowNumber] context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
	[blocker keyDown:key];

	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
	XCTAssertEqual([self hitAtBlockedViewCenter], self.inner, @"the blocker is gone once idle");
	XCTAssertNil([blocker superview]);
	XCTAssertEqual((id)[self.window firstResponder], self.inner, @"the first responder is given back");
}

- (void)testNoParentWindowShowsNothing
{
	[self sleep:2 description:@"Loading..." cancelTitle:nil done:NULL cancelled:NULL];
	[self spinUntil:^BOOL{ return NO; } timeout:0.8];
	XCTAssertFalse([[self.window childWindows] containsObject:self.display.progressWindow], @"no child window");
	XCTAssertFalse([self.display.progressWindow isVisible]);

	// The tab becomes active mid-task: shown, and input is blocked
	self.display.parentWindow = self.window;
	XCTAssertTrue([[self.window childWindows] containsObject:self.display.progressWindow]);
	XCTAssertNotEqual([self hitAtBlockedViewCenter], self.inner);

	// And resigns: taken down again
	self.display.parentWindow = nil;
	XCTAssertFalse([[self.window childWindows] containsObject:self.display.progressWindow]);
	XCTAssertEqual([self hitAtBlockedViewCenter], self.inner);

	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
}

- (void)testInvalidateTakesEverythingDown
{
	self.display.parentWindow = self.window;
	[self sleep:2 description:@"Loading..." cancelTitle:@"Cancel" done:NULL cancelled:NULL];
	XCTAssertNotEqual([self hitAtBlockedViewCenter], self.inner);
	[self.display invalidate];
	XCTAssertFalse([[self.window childWindows] containsObject:self.display.progressWindow]);
	XCTAssertEqual([self hitAtBlockedViewCenter], self.inner);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.runner timeout:10]);
}

@end
