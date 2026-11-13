#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../Source/SPWindowController.h"

@interface NSObject (SPConnectionScreenLayoutTests)
- (id)connectionController;
- (void)_layOutConnectionDetails;
@end

/// The MySQL connection screen keeps its details centered as views resize. That layout ran again for every frame it set,
/// and when a display change (e.g. the screen waking after the app sat idle) made the details scroller appear and go,
/// it ran without end until the app crashed (stack overflow in -[SPConnectionController scrollViewFrameChanged:]).
@interface SPConnectionScreenLayoutTests : XCTestCase
@end

@implementation SPConnectionScreenLayoutTests

/// Layouts (-_layOutConnectionDetails) on the stack right now, and the most seen at once.
static NSInteger SPLayoutDepth = 0;
static NSInteger SPLayoutMaxDepth = 0;

- (void)testDetailsLayoutNeverRunsInsideItself
{
	SPWindowController *controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([controller window]);
	[controller showWindow:nil];
	id mysql = [controller addNewConnection];
	XCTAssertNotNil(mysql);
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
	id connectionController = [mysql connectionController];
	NSScrollView *scrollView = [connectionController valueForKey:@"connectionDetailsScrollView"];
	NSView *details = [connectionController valueForKey:@"connectionResizeContainer"];
	XCTAssertNotNil(scrollView);
	XCTAssertNotNil(details);

	// Count how deep the layout nests (bounded here, so a regression fails instead of crashing)
	Method method = class_getInstanceMethod([connectionController class], @selector(_layOutConnectionDetails));
	XCTAssertTrue(method != NULL);
	IMP original = method_getImplementation(method);
	IMP counting = imp_implementationWithBlock(^(id me) {
		SPLayoutDepth++;
		SPLayoutMaxDepth = MAX(SPLayoutMaxDepth, SPLayoutDepth);
		if (SPLayoutDepth < 40) ((void (*)(id, SEL))original)(me, @selector(_layOutConnectionDetails));
		SPLayoutDepth--;
	});
	method_setImplementation(method, counting);
	SPLayoutDepth = 0;
	SPLayoutMaxDepth = 0;

	[self addTeardownBlock:^{
		method_setImplementation(method, original);
		NSWindow *window = [controller window];
		NSTabView *tabView = [controller valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
	}];

	// Scrollers that take space (a mouse attached, or "Show scroll bars: Always"), as a display change can switch to
	[scrollView setScrollerStyle:NSScrollerStyleLegacy];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutohidesScrollers:YES];

	NSSize size = [scrollView frame].size;
	CGFloat detailsHeight = NSHeight([details frame]);
	// Heights around the details' own (where the vertical scroller comes and goes), and widths around theirs
	for (CGFloat height = detailsHeight - 30; height <= detailsHeight + 30; height += 1) {
		for (CGFloat width = NSWidth([details frame]) - 10; width <= NSWidth([details frame]) + 30; width += 5) {
			[scrollView setFrameSize:NSMakeSize(width, height)];
		}
	}
	[scrollView setFrameSize:size];

	XCTAssertGreaterThan(SPLayoutMaxDepth, 0, @"the layout ran");
	XCTAssertLessThanOrEqual(SPLayoutMaxDepth, 1, @"the layout ran inside itself %ld deep", (long)SPLayoutMaxDepth);
	// Still laid out: centered horizontally in what is visible
	CGFloat visible = [scrollView contentSize].width;
	XCTAssertEqualWithAccuracy(NSMinX([details frame]), round(MAX(0, (visible - NSWidth([details frame])) / 2)), 1);
}

@end
