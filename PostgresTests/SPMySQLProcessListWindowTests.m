#import <XCTest/XCTest.h>
#import "../Source/SPProcessListController.h"

// SPMySQL's headers aren't visible to the test bundle: what the tests use, declared
@interface NSObject (SPMySQLProcessListWindowTests)
- (BOOL)connect;
- (BOOL)isConnected;
- (void)disconnect;
@end

@interface SPProcessListController (SPMySQLProcessListWindowTests)
- (IBAction)refreshProcessList:(id)sender;
@end

/**
 * MySQL's Server Processes window, laid out like PostgreSQL's: the connection summary top left, the filter top right,
 * the list between, and along the bottom the row count, Auto Refresh with its interval, the ⚙︎ menu, then Save As…,
 * Refresh, Kill Query, Kill Connection and Close. Its window is loaded but never shown, and nothing it does here may
 * reach the app's saved preferences. The live list runs on sp-mysql8 (127.0.0.1:55438, root / sptest), skipped when it
 * isn't running.
 */
@interface SPMySQLProcessListWindowTests : XCTestCase
@property (strong) SPProcessListController *controller;
@property (strong) NSDictionary *savedPreferences;
@property (strong) NSDictionary *argumentDomain;
@end

@implementation SPMySQLProcessListWindowTests

- (NSString *)domainName
{
	return [[NSBundle mainBundle] bundleIdentifier];
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	self.savedPreferences = [defaults persistentDomainForName:[self domainName]] ?: @{};
	self.argumentDomain = [defaults volatileDomainForName:NSArgumentDomain] ?: @{};
}

- (void)tearDown
{
	[[self.controller window] orderOut:nil];
	self.controller = nil;
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults removeVolatileDomainForName:NSArgumentDomain];
	[defaults setVolatileDomain:self.argumentDomain forName:NSArgumentDomain];
	XCTAssertEqualObjects([defaults persistentDomainForName:[self domainName]] ?: @{}, self.savedPreferences, @"no saved preference changed");
	[super tearDown];
}

/// Preferences for this test only (the volatile argument domain, never saved).
- (void)usePreferences:(NSDictionary *)values
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *domain = [self.argumentDomain mutableCopy];
	[domain addEntriesFromDictionary:values];
	[defaults removeVolatileDomainForName:NSArgumentDomain];
	[defaults setVolatileDomain:domain forName:NSArgumentDomain];
}

- (NSWindow *)loadWindow
{
	self.controller = [[SPProcessListController alloc] init];
	NSWindow *window = [self.controller window];
	XCTAssertNotNil(window);
	return window;
}

- (id)control:(NSString *)name
{
	return [self.controller valueForKey:name];
}

- (NSArray<NSButton *> *)bottomButtons
{
	return @[[self control:@"saveProcessesButton"], [self control:@"refreshProcessesButton"], [self control:@"killQueryButton"],
			 [self control:@"killConnectionButton"], [self control:@"closeButton"]];
}

- (void)assertNoOverlapsIn:(NSView *)content
{
	NSMutableArray *controls = [NSMutableArray array];
	for (NSView *view in content.subviews) if (!view.isHidden && [view isKindOfClass:[NSControl class]]) [controls addObject:view];
	for (NSUInteger i = 0; i < controls.count; i++) {
		XCTAssertTrue(NSContainsRect(content.bounds, [controls[i] frame]), @"%@ inside", controls[i]);
		for (NSUInteger j = i + 1; j < controls.count; j++) {
			XCTAssertFalse(NSIntersectsRect([controls[i] frame], [controls[j] frame]), @"%@ overlaps %@", controls[i], controls[j]);
		}
	}
}

- (void)testLaidOutLikeThePostgresWindow
{
	NSWindow *window = [self loadWindow];
	NSView *content = window.contentView;
	NSRect bounds = content.bounds;

	// Along the bottom, right to left from the edge: Close, Kill Connection, Kill Query, Refresh, Save As…
	NSArray<NSButton *> *buttons = [self bottomButtons];
	XCTAssertEqualObjects([buttons valueForKey:@"title"], (@[@"Save As...", @"Refresh", @"Kill Query", @"Kill Connection", @"Close"]));
	XCTAssertEqualWithAccuracy(NSMaxX(buttons.lastObject.frame), NSWidth(bounds) - 14, 0.5);
	for (NSUInteger i = 0; i < buttons.count; i++) {
		XCTAssertEqual(NSMinY(buttons[i].frame), 12.0, @"%@", buttons[i].title);
		XCTAssertEqual(buttons[i].bezelStyle, [NSButton buttonWithTitle:@"Close" target:nil action:nil].bezelStyle, @"%@: PostgreSQL's push button", buttons[i].title);
		XCTAssertNil(buttons[i].image, @"%@: a titled button, like PostgreSQL's", buttons[i].title);
		if (i) XCTAssertGreaterThanOrEqual(NSMinX(buttons[i].frame) - NSMaxX(buttons[i - 1].frame), 12.0, @"before %@", buttons[i].title);
	}
	XCTAssertEqualObjects([buttons[4] keyEquivalent], @"\033", @"Escape closes");
	XCTAssertEqualObjects([buttons[1] keyEquivalent], @"r", @"⌘R refreshes");

	// Bottom left: the row count, Auto Refresh and how often, the ⚙︎ menu
	NSTextField *count = [self control:@"processesCountTextField"];
	NSButton *autoRefresh = [self control:@"autoRefreshButton"];
	NSPopUpButton *interval = [self control:@"autoRefreshIntervalPopUp"];
	NSPopUpButton *gear = [self control:@"actionsPopUp"];
	XCTAssertEqual(NSMinX(count.frame), 20.0);
	XCTAssertFalse(count.isHidden);
	XCTAssertEqualObjects(autoRefresh.title, @"Auto Refresh");
	XCTAssertGreaterThan(NSMinX(autoRefresh.frame), NSMaxX(count.frame));
	XCTAssertGreaterThan(NSMinX(interval.frame), NSMaxX(autoRefresh.frame));
	XCTAssertGreaterThan(NSMinX(gear.frame), NSMaxX(interval.frame));
	XCTAssertLessThan(NSMaxX(gear.frame), NSMinX(buttons.firstObject.frame));

	// The ⚙︎ menu keeps Show Process ID and Show FULL Process List; the interval lives in its own menu now
	NSArray *gearTitles = [[gear.itemArray filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"hidden == NO AND separatorItem == NO"]] valueForKey:@"title"];
	XCTAssertEqualObjects(gearTitles, (@[@"Show Process ID", @"Show FULL Process List"]));
	NSArray *intervalTitles = [[interval.itemArray filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"separatorItem == NO"]] valueForKey:@"title"];
	XCTAssertEqualObjects(intervalTitles, (@[@"Every second", @"Every 2 seconds", @"Every 5 seconds", @"Every 10 seconds", @"Every 30 seconds", @"Every 60 seconds", @"Custom…"]));

	// Top: the connection summary on the left, the filter on the right; the list between, inset as PostgreSQL's
	NSSearchField *filter = [self control:@"filterProcessesSearchField"];
	NSTextField *summary = [self control:@"summaryLabel"];
	XCTAssertEqualWithAccuracy(NSMaxX(filter.frame), NSWidth(bounds) - 20, 0.5);
	XCTAssertEqualWithAccuracy(NSWidth(filter.frame), 220, 0.5);
	XCTAssertEqual(NSMinX(summary.frame), 20.0);
	XCTAssertLessThan(NSMaxX(summary.frame), NSMinX(filter.frame));
	NSScrollView *scrollView = [[self control:@"processListTableView"] enclosingScrollView];
	XCTAssertTrue(NSEqualRects(scrollView.frame, NSMakeRect(20, 52, NSWidth(bounds) - 40, NSHeight(bounds) - 100)), @"%@", NSStringFromRect(scrollView.frame));
	XCTAssertEqual(scrollView.borderType, NSBezelBorder);

	[self assertNoOverlapsIn:content];

	// Still nothing overlapping at its narrowest
	[window setContentSize:window.contentMinSize];
	[self assertNoOverlapsIn:content];

	// The table resizing its own columns (as its first layout pass does) is not saved as the user's widths
	// (-tearDown checks nothing saved changed)
	NSTableView *table = [self control:@"processListTableView"];
	[table sizeLastColumnToFit];
	[table.tableColumns.lastObject setWidth:17.5];
	[content layoutSubtreeIfNeeded];
}

- (void)testIntervalMenuShowsThePreference
{
	[self usePreferences:@{@"ProcessListEnableAutoRefresh": @NO, @"ProcessListAutoRrefreshInterval": @30}];
	[self loadWindow];
	NSPopUpButton *interval = [self control:@"autoRefreshIntervalPopUp"];
	XCTAssertEqual(interval.selectedItem.tag, 30);
	XCTAssertFalse(interval.isEnabled, @"off: nothing to time");
	self.controller = nil;

	// A custom interval gets an item of its own, chosen
	[self usePreferences:@{@"ProcessListEnableAutoRefresh": @YES, @"ProcessListAutoRrefreshInterval": @7}];
	[self loadWindow];
	interval = [self control:@"autoRefreshIntervalPopUp"];
	XCTAssertEqualObjects(interval.selectedItem.title, @"Every 7 seconds");
	XCTAssertEqual(interval.selectedItem.tag, 7);
	XCTAssertTrue(interval.isEnabled);
}

- (void)testListShowsTheServersProcessesAndConnections
{
	id connection = [[NSClassFromString(@"SPMySQLConnection") alloc] init];
	[connection setValue:@"127.0.0.1" forKey:@"host"];
	[connection setValue:@55438 forKey:@"port"];
	[connection setValue:@"root" forKey:@"username"];
	[connection setValue:@"sptest" forKey:@"password"];
	[connection setValue:@5 forKey:@"timeout"];
	if (![connection connect] || ![connection isConnected]) {
		XCTSkip(@"sp-mysql8 isn't running on 127.0.0.1:55438");
	}
	[self loadWindow];
	self.controller.connection = connection;
	NSTableView *table = [self control:@"processListTableView"];
	NSTextField *summary = [self control:@"summaryLabel"];
	[self.controller refreshProcessList:nil];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while ((table.numberOfRows == 0 || !summary.stringValue.length) && deadline.timeIntervalSinceNow > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	XCTAssertGreaterThan(table.numberOfRows, 0);
	XCTAssertTrue([summary.stringValue rangeOfString:@" connections"].location != NSNotFound, @"%@", summary.stringValue);
	XCTAssertFalse(summary.isHidden);
	NSTextField *count = [self control:@"processesCountTextField"];
	XCTAssertEqualObjects(count.stringValue, ([NSString stringWithFormat:@"%ld rows", (long)table.numberOfRows]));

	// Kill Query and Kill Connection: one process selected
	NSButton *killQuery = [self control:@"killQueryButton"];
	NSButton *killConnection = [self control:@"killConnectionButton"];
	XCTAssertFalse(killQuery.isEnabled);
	XCTAssertFalse(killConnection.isEnabled);
	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	XCTAssertTrue(killQuery.isEnabled);
	XCTAssertTrue(killConnection.isEnabled);
	[table deselectAll:nil];
	XCTAssertFalse(killConnection.isEnabled);

	// Filtered: "N of M rows"
	NSSearchField *filter = [self control:@"filterProcessesSearchField"];
	filter.stringValue = @"zz-no-such-process";
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:filter];
	XCTAssertEqualObjects(count.stringValue, ([NSString stringWithFormat:@"0 of %ld rows", (long)[[self.controller valueForKey:@"processes"] count]]));

	self.controller.connection = nil;
	[connection disconnect];
}

@end
