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
}

@end
