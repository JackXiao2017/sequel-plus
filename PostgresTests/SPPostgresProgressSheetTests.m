#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresProgressSheet.h"

/// The progress sheet always ends its sheet, also when it was still queued behind another sheet.
@interface SPPostgresProgressSheetTests : XCTestCase
@end

@implementation SPPostgresProgressSheetTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)spinFor:(NSTimeInterval)seconds
{
	[self spinUntil:^BOOL{ return NO; } timeout:seconds];
}

- (NSWindow *)makeWindow
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-5000, -5000, 600, 400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[window orderFront:nil];
	return window;
}

- (void)testEndWhileQueuedLeavesNoSheet
{
	NSWindow *window = [self makeWindow];
	NSPanel *first = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[first setReleasedWhenClosed:NO];
	[window beginSheet:first completionHandler:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == first; } timeout:5]);

	SPPostgresProgressSheet *progress = [SPPostgresProgressSheet beginOnWindow:window title:@"Queued"];
	[progress end];
	[window endSheet:first];

	[self spinFor:2];
	XCTAssertNil(window.attachedSheet, @"the queued progress sheet must not attach after -end");
	XCTAssertFalse([[progress panel] isVisible]);
	[window close];
}

- (void)testEndWhileQueuedAfterSpinLeavesNoSheet
{
	NSWindow *window = [self makeWindow];
	NSPanel *first = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[first setReleasedWhenClosed:NO];
	[window beginSheet:first completionHandler:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == first; } timeout:5]);

	SPPostgresProgressSheet *progress = [SPPostgresProgressSheet beginOnWindow:window title:@"Queued"];
	[self spinFor:0.2];
	[progress end];
	[window endSheet:first];

	[self spinFor:2];
	XCTAssertNil(window.attachedSheet, @"the queued progress sheet must not attach after -end");
	XCTAssertFalse([[progress panel] isVisible]);
	[window close];
}

- (void)testEndAfterAttachEndsSheet
{
	NSWindow *window = [self makeWindow];
	SPPostgresProgressSheet *progress = [SPPostgresProgressSheet beginOnWindow:window title:@"Attached"];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == [progress panel]; } timeout:5]);
	[progress end];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);
	[window close];
}

@end
