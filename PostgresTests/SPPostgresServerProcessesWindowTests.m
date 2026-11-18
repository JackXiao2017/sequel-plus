#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresServerListSheet.h"

/**
 * PostgreSQL's Server Processes as a window of its own (not a sheet), with Auto Refresh and its interval. Preferences
 * go to a throwaway suite, never the app's own.
 */
@interface SPPostgresServerProcessesWindowTests : XCTestCase
@property (strong) NSUserDefaults *defaults;
@property (copy) NSString *suiteName;
@property (strong) SPPostgresServerListSheet *list;
@property (assign) NSUInteger refreshes;
@property (assign) NSUInteger closed;
@end

@implementation SPPostgresServerProcessesWindowTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.suiteName = [NSString stringWithFormat:@"SPPostgresServerProcessesWindowTests.%@", [NSUUID UUID].UUIDString];
	self.defaults = [[NSUserDefaults alloc] initWithSuiteName:self.suiteName];
}

- (void)tearDown
{
	if (self.list.isOpen) [self.list close:nil];
	self.list = nil;
	[self.defaults removePersistentDomainForName:self.suiteName];
	self.defaults = nil;
	[super tearDown];
}

- (NSArray *)columns
{
	return @[@{@"key": @"pid", @"title": @"PID"}, @{@"key": @"user", @"title": @"User"}];
}

- (SPPostgresServerListSheet *)open
{
	__weak SPPostgresServerProcessesWindowTests *weakSelf = self;
	self.list = [SPPostgresServerListSheet openWindowWithTitle:@"Server Processes on test" columns:[self columns]
														  rows:@[@{@"pid": @"10", @"user": @"alice", @"own": @"false"}]
													   refresh:^(void (^done)(void)) { weakSelf.refreshes++; done(); }
												 processAction:^(NSDictionary *row, BOOL terminate) {}
													  defaults:self.defaults
													completion:^{ weakSelf.closed++; }];
	return self.list;
}

- (void)spin:(NSTimeInterval)seconds
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

- (void)testOpensAsAWindowOfItsOwn
{
	SPPostgresServerListSheet *list = [self open];
	XCTAssertNotNil(list);
	XCTAssertTrue(list.isOpen);
	XCTAssertNil(list.sheet.sheetParent, @"not a sheet");
	XCTAssertTrue(list.sheet.isVisible);
	NSWindowStyleMask mask = list.sheet.styleMask;
	XCTAssertTrue(mask & NSWindowStyleMaskClosable);
	XCTAssertTrue(mask & NSWindowStyleMaskResizable);
	XCTAssertTrue(mask & NSWindowStyleMaskMiniaturizable);
	XCTAssertEqualObjects(list.sheet.title, @"Server Processes on test");
	XCTAssertEqual(list.tableView.numberOfRows, 1);
	XCTAssertNil([SPPostgresServerListSheet currentSheet], @"sheets (Server Variables…) can still open");

	// The title bar's close button ends it, once
	[list.sheet performClose:nil];
	XCTAssertFalse(list.isOpen);
	XCTAssertFalse(list.sheet.isVisible);
	XCTAssertEqual(self.closed, 1u);
	[list close:nil];
	XCTAssertEqual(self.closed, 1u);
}

- (void)testAutoRefreshIsOffByDefault
{
	SPPostgresServerListSheet *list = [self open];
	XCTAssertEqual(list.autoRefreshCheckbox.state, NSControlStateValueOff);
	XCTAssertFalse(list.autoRefreshIntervalPopUp.isEnabled);
	XCTAssertEqualObjects([list.autoRefreshIntervalPopUp.itemArray valueForKey:@"tag"], (@[@1, @2, @5, @10, @30, @60]));
	XCTAssertEqualObjects([list.autoRefreshIntervalPopUp.itemArray valueForKey:@"title"],
						  (@[@"Every second", @"Every 2 seconds", @"Every 5 seconds", @"Every 10 seconds", @"Every 30 seconds", @"Every 60 seconds"]));
	XCTAssertEqual(list.autoRefreshIntervalPopUp.selectedTag, 10);
	[self spin:1.2];
	XCTAssertEqual(self.refreshes, 0u);
}

- (void)testAutoRefreshRefreshesEveryIntervalAndIsRemembered
{
	SPPostgresServerListSheet *list = [self open];
	[list.autoRefreshIntervalPopUp selectItemWithTag:1];
	[list setAutoRefreshInterval:list.autoRefreshIntervalPopUp];
	list.autoRefreshCheckbox.state = NSControlStateValueOn;
	[list toggleAutoRefresh:list.autoRefreshCheckbox];
	XCTAssertTrue(list.autoRefreshIntervalPopUp.isEnabled);
	XCTAssertTrue([self.defaults boolForKey:@"PostgresProcessListAutoRefresh"]);
	XCTAssertEqual([self.defaults integerForKey:@"PostgresProcessListAutoRefreshInterval"], 1);
	[self spin:2.6];
	XCTAssertGreaterThanOrEqual(self.refreshes, 2u);
	XCTAssertLessThanOrEqual(self.refreshes, 3u);

	// Off: no more
	list.autoRefreshCheckbox.state = NSControlStateValueOff;
	[list toggleAutoRefresh:list.autoRefreshCheckbox];
	XCTAssertFalse([self.defaults boolForKey:@"PostgresProcessListAutoRefresh"]);
	XCTAssertFalse(list.autoRefreshIntervalPopUp.isEnabled);
	NSUInteger before = self.refreshes;
	[self spin:1.5];
	XCTAssertEqual(self.refreshes, before);

	// Next time it opens as it was left
	[self.defaults setBool:YES forKey:@"PostgresProcessListAutoRefresh"];
	[list close:nil];
	list = [self open];
	XCTAssertEqual(list.autoRefreshCheckbox.state, NSControlStateValueOn);
	XCTAssertEqual(list.autoRefreshIntervalPopUp.selectedTag, 1);
	before = self.refreshes;
	[self spin:1.5];
	XCTAssertGreaterThan(self.refreshes, before, @"refreshing from the start");
}

- (void)testClosingStopsAutoRefresh
{
	[self.defaults setBool:YES forKey:@"PostgresProcessListAutoRefresh"];
	[self.defaults setInteger:1 forKey:@"PostgresProcessListAutoRefreshInterval"];
	SPPostgresServerListSheet *list = [self open];
	[self spin:1.3];
	XCTAssertGreaterThanOrEqual(self.refreshes, 1u);
	[list.sheet performClose:nil];
	NSUInteger before = self.refreshes;
	[self spin:1.5];
	XCTAssertEqual(self.refreshes, before);
}

- (void)testARefreshStillRunningIsNotStartedAgain
{
	__block void (^pending)(void) = nil;
	__block NSUInteger started = 0;
	self.list = [SPPostgresServerListSheet openWindowWithTitle:@"Server Processes" columns:[self columns] rows:@[]
													   refresh:^(void (^done)(void)) { started++; pending = done; }
												 processAction:nil defaults:self.defaults completion:nil];
	[self.list refresh:nil];
	[self.list refresh:nil];
	XCTAssertEqual(started, 1u, @"the first is still reading");
	pending();
	[self.list refresh:nil];
	XCTAssertEqual(started, 2u);
	pending();
}

- (void)testLayoutLeavesRoomBetweenControls
{
	SPPostgresServerListSheet *list = [self open];
	NSView *content = list.sheet.contentView;
	[list.sheet setContentSize:list.sheet.contentMinSize];
	[content layoutSubtreeIfNeeded];
	NSMutableArray *controls = [NSMutableArray array];
	for (NSView *view in content.subviews) if (!view.isHidden && [view isKindOfClass:[NSControl class]]) [controls addObject:view];
	XCTAssertTrue([controls containsObject:list.autoRefreshCheckbox]);
	XCTAssertTrue([controls containsObject:list.autoRefreshIntervalPopUp]);
	for (NSUInteger i = 0; i < controls.count; i++) {
		XCTAssertTrue(NSContainsRect(content.bounds, [controls[i] frame]), @"%@ inside at the narrowest", controls[i]);
		for (NSUInteger j = i + 1; j < controls.count; j++) {
			XCTAssertFalse(NSIntersectsRect([controls[i] frame], [controls[j] frame]), @"%@ overlaps %@", controls[i], controls[j]);
		}
	}
}

@end
