#import <XCTest/XCTest.h>
#import "../Source/NSWindow+SPCompactChrome.h"

@interface SPCompactChromeTests : XCTestCase
@end

@implementation SPCompactChromeTests

- (void)testCompactToolbarImageIs24pt
{
	NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
	NSImage *compact = SPCompactToolbarImage(image);
	XCTAssertEqual(compact.size.width, 24.0);
	XCTAssertEqual(compact.size.height, 24.0);
	XCTAssertEqual(image.size.width, 32.0, @"original must be untouched");
}

- (void)testCompactTitleShowsWindowTitle
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400)
												   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
													 backing:NSBackingStoreBuffered
													   defer:YES];
	window.releasedWhenClosed = NO;
	window.title = @"(PostgreSQL 18.0) x/y";
	[window sp_applyCompactTitle];

	NSView *titlebar = [[window standardWindowButton:NSWindowCloseButton] superview];
	NSTextField *label = nil;
	for (NSView *v in titlebar.subviews) {
		if ([v.identifier isEqualToString:@"SPCompactWindowTitle"]) label = (NSTextField *)v;
	}
	XCTAssertNotNil(label);
	XCTAssertEqualObjects(label.stringValue, @"(PostgreSQL 18.0) x/y");
	XCTAssertEqual(window.titleVisibility, NSWindowTitleHidden);

	// Repeated setup keeps a single label and follows title changes on resize
	[window sp_useExpandedCompactToolbar];
	[window sp_useExpandedCompactToolbar];
	window.title = @"changed";
	[window setContentSize:NSMakeSize(700, 400)];
	NSUInteger count = 0;
	for (NSView *v in titlebar.subviews) if ([v.identifier isEqualToString:@"SPCompactWindowTitle"]) count++;
	XCTAssertEqual(count, 1u);
	XCTAssertEqualObjects(label.stringValue, @"changed");
	// The label's frame follows the resized titlebar (single observer effect, still tracking)
	CGFloat inset = NSMaxX([[window standardWindowButton:NSWindowZoomButton] frame]) + 20;
	XCTAssertEqualWithAccuracy(label.frame.size.width, titlebar.bounds.size.width - inset * 2, 1.0);
}

// Tab drag: the departing document must not cancel tracking set up by the source window's new active tab.
// MySQL resign no longer stops tracking; start is remove-then-add, so repeated starts keep tracking alive.
- (void)testTrackingSurvivesRepeatedStartsAcrossTabSwitches
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400)
												   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
													 backing:NSBackingStoreBuffered
													   defer:YES];
	window.releasedWhenClosed = NO;
	window.title = @"one";
	[window sp_useExpandedCompactToolbar];  // tab A becomes active
	[window sp_useExpandedCompactToolbar];  // tab B becomes active (A resigned without stopping)
	window.title = @"two";
	[window setContentSize:NSMakeSize(750, 400)];

	NSView *titlebar = [[window standardWindowButton:NSWindowCloseButton] superview];
	NSTextField *label = nil;
	NSUInteger count = 0;
	for (NSView *v in titlebar.subviews) {
		if ([v.identifier isEqualToString:@"SPCompactWindowTitle"]) { label = (NSTextField *)v; count++; }
	}
	XCTAssertEqual(count, 1u);
	XCTAssertEqualObjects(label.stringValue, @"two");
	CGFloat inset = NSMaxX([[window standardWindowButton:NSWindowZoomButton] frame]) + 20;
	XCTAssertEqualWithAccuracy(label.frame.size.width, titlebar.bounds.size.width - inset * 2, 1.0);

	// Explicit stop still stops it
	[window sp_stopCompactTitleTracking];
	window.title = @"three";
	[window setContentSize:NSMakeSize(800, 400)];
	XCTAssertEqualObjects(label.stringValue, @"two");
}

@end
