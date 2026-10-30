#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/SPSplitView.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/Postgres/SPPostgresCatalog.h"

static const NSUInteger SPPostgresSidebarBarTestPort = 55418;

/// MySQL's SPTableInformationPanelCollapsed (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPTestTableInformationPanelCollapsed = @"TableInformationPanelCollapsed";
static NSString * const SPTestDefaultsSuite = @"SPPostgresStage9Tests";

// Not in the public headers
@interface SPPostgresSidebarController (SPPostgresSidebarBarTests)
- (IBAction)addTable:(id)sender;
@end

@interface SPPostgresSidebarBarTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *connection;
@property (strong) NSUserDefaults *scratchDefaults;
@end

@implementation SPPostgresSidebarBarTests

+ (void)setUp
{
	[super setUp];
	[SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:SPPostgresSidebarBarTestPort];
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPTestDefaultsSuite];
	self.scratchDefaults = [[NSUserDefaults alloc] initWithSuiteName:SPTestDefaultsSuite];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 test";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPPostgresSidebarBarTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

	// As -[SPAppController newWindow] does. The window's delegate is deliberately not set: its
	// -windowWillClose: autoreleases the controller, which this (ARC) test owns.
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);

	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block NSError *error = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) {
		connection = theConnection;
		error = theError;
		done = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection, @"%@", error);
	self.connection = connection;

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertEqual([self.controller selectedDocument], self.document);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];

	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) {
		[tabView removeTabViewItem:item];
	}
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	self.connection = nil;

	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort];
	[admin execute:@"DROP TABLE IF EXISTS public.sp9_new"];

	self.scratchDefaults = nil;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPTestDefaultsSuite];
	[super tearDown];
}

/// The collapsed state written to the scratch suite itself (a suite's reads also see the app's registered defaults).
- (id)storedCollapsedValue
{
	return [[self.scratchDefaults persistentDomainForName:SPTestDefaultsSuite] objectForKey:SPTestTableInformationPanelCollapsed];
}

#pragma mark - The bar

- (void)testBarButtonsMatchMySQL
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	// Expanded whatever the real preferences hold (the scratch defaults hold nothing)
	sidebar.defaults = self.scratchDefaults;
	NSView *view = [sidebar view];

	// The bar itself: MySQL's SPButtonBar, 23 pt at the bottom
	NSView *bar = nil;
	for (NSView *subview in view.subviews) {
		if ([subview isKindOfClass:NSClassFromString(@"SPButtonBar")]) bar = subview;
	}
	XCTAssertNotNil(bar);
	XCTAssertTrue([bar isKindOfClass:NSClassFromString(@"SPButtonBar")]);
	XCTAssertEqual(NSHeight(bar.frame), 23);
	XCTAssertEqual(NSMinX(bar.frame), 0);
	XCTAssertEqual(NSMinY(bar.frame), 0);
	XCTAssertEqual(NSWidth(bar.frame), NSWidth(view.bounds));
	XCTAssertEqual(bar.autoresizingMask, (NSUInteger)(NSViewWidthSizable | NSViewMaxYMargin));

	// The buttons, at DBView.xib's frames, as siblings over the bar
	NSButton *add = sidebar.addButton;
	NSPopUpButton *gear = sidebar.gearButton;
	NSButton *refresh = sidebar.refreshButton;
	NSButton *info = sidebar.infoToggleButton;
	for (NSView *button in @[add, gear, refresh, info]) {
		XCTAssertEqual(button.superview, view);
		XCTAssertEqual(button.autoresizingMask, (NSUInteger)NSViewMaxXMargin);
	}

	XCTAssertTrue(NSEqualRects(add.frame, NSMakeRect(-1, 0, 32, 23)), @"%@", NSStringFromRect(add.frame));
	XCTAssertEqualObjects([[add image] name], @"button_add");
	XCTAssertEqualObjects(add.toolTip, @"Add new table");
	XCTAssertEqual(add.action, @selector(addTable:));
	XCTAssertEqual(add.target, sidebar);
	XCTAssertEqual(add.bezelStyle, NSBezelStyleSmallSquare);
	XCTAssertEqual(add.imagePosition, NSImageOnly);

	XCTAssertTrue(NSEqualRects(gear.frame, NSMakeRect(29, 0, 36, 23)), @"%@", NSStringFromRect(gear.frame));
	XCTAssertTrue(gear.pullsDown);
	XCTAssertEqualObjects([[[gear itemAtIndex:0] image] name], @"button_action");
	XCTAssertTrue([[gear itemAtIndex:0] isHidden]);
	XCTAssertNil(gear.toolTip);
	XCTAssertEqual(gear.bezelStyle, NSBezelStyleRegularSquare);
	XCTAssertEqual([(NSPopUpButtonCell *)gear.cell arrowPosition], NSPopUpNoArrow);

	XCTAssertTrue(NSEqualRects(refresh.frame, NSMakeRect(61, 0, 32, 23)), @"%@", NSStringFromRect(refresh.frame));
	XCTAssertEqualObjects([[refresh image] name], @"button_refresh");
	XCTAssertEqualObjects(refresh.toolTip, @"Refresh table list");
	XCTAssertEqual(refresh.action, @selector(refreshTables:));
	XCTAssertEqual(refresh.target, sidebar);
	XCTAssertEqual(refresh.bezelStyle, NSBezelStyleSmallSquare);

	XCTAssertTrue(NSEqualRects(info.frame, NSMakeRect(92, -1, 32, 25)), @"%@", NSStringFromRect(info.frame));
	XCTAssertEqualObjects([[info image] name], @"button_pane_hide");
	XCTAssertEqualObjects([[info alternateImage] name], @"button_pane_show");
	XCTAssertEqualObjects(info.toolTip, @"Toggle the visibility of the Information panel");
	XCTAssertEqual(info.action, @selector(toggleInfoPane:));
	XCTAssertEqual(info.target, sidebar);
	XCTAssertEqual(info.bezelStyle, NSBezelStyleTexturedRounded);

	// The schema pop-up stays the panel's first pop-up (walks of the subviews look for it)
	NSUInteger firstPopup = [view.subviews indexOfObjectPassingTest:^BOOL(NSView *v, NSUInteger idx, BOOL *stop) { return [v isKindOfClass:[NSPopUpButton class]]; }];
	XCTAssertLessThan(firstPopup, [view.subviews indexOfObject:gear]);

	// Left to right: Add < Gear < Refresh < Info
	XCTAssertLessThan(NSMinX(add.frame), NSMinX(gear.frame));
	XCTAssertLessThan(NSMinX(gear.frame), NSMinX(refresh.frame));
	XCTAssertLessThan(NSMinX(refresh.frame), NSMinX(info.frame));

	// The outline sits in the info split, between the bar and the schema bar
	NSSplitView *split = (NSSplitView *)sidebar.infoSplitView;
	XCTAssertFalse(split.isVertical);
	XCTAssertEqual(NSMinY(split.frame), 23);
	XCTAssertEqual(split.subviews.count, 2u);
	XCTAssertTrue([split.subviews.firstObject isKindOfClass:[NSScrollView class]]);
	XCTAssertTrue([[(NSScrollView *)split.subviews.firstObject documentView] isKindOfClass:[NSOutlineView class]]);
	XCTAssertEqual(split.subviews.lastObject, sidebar.infoPaneContainer);
	XCTAssertEqual(NSHeight(sidebar.infoPaneContainer.frame), 166);
}

- (void)testSplitHandleIsWired
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSView *handle = sidebar.splitHandleView;
	XCTAssertTrue([handle isKindOfClass:[NSImageView class]]);
	XCTAssertEqual(NSWidth(handle.frame), 15);
	XCTAssertEqual(NSHeight(handle.frame), 23);
	XCTAssertEqual(NSMaxX(handle.frame), NSWidth([sidebar view].bounds));
	XCTAssertEqual(handle.autoresizingMask, (NSUInteger)NSViewMinXMargin);
	XCTAssertEqualObjects([[(NSImageView *)handle image] name], @"button_bar_handle");

	NSSplitView *splitView = (NSSplitView *)[self.document databaseView];
	XCTAssertEqual([splitView valueForKey:@"additionalDragHandleView"], handle);
}

#pragma mark - Refresh

- (void)testRefreshReloadsList
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse([[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"sp9_new"]);

	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort];
	XCTAssertNotNil([admin execute:@"DROP TABLE IF EXISTS public.sp9_new"]);
	XCTAssertNotNil([admin execute:@"CREATE TABLE public.sp9_new (id int)"]);

	XCTAssertTrue(sidebar.refreshButton.isEnabled);
	[sidebar.refreshButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	XCTAssertTrue([[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"sp9_new"]);
	XCTAssertEqualObjects(sidebar.selectedSchema, @"public");
	XCTAssertEqualObjects(sidebar.selectedTableName, @"customers");
}

#pragma mark - Info toggle

- (void)testInfoToggleUsesInjectedDefaults
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	sidebar.defaults = self.scratchDefaults;
	SPSplitView *split = sidebar.infoSplitView;
	NSButton *info = sidebar.infoToggleButton;
	XCTAssertFalse([split isCollapsibleSubviewCollapsed]);
	XCTAssertEqual(info.state, NSControlStateValueOff);
	XCTAssertNil([self storedCollapsedValue]);

	id realValue = [[NSUserDefaults standardUserDefaults] objectForKey:SPTestTableInformationPanelCollapsed];

	// Collapse
	[info performClick:nil];
	XCTAssertTrue([split isCollapsibleSubviewCollapsed]);
	XCTAssertEqual(info.state, NSControlStateValueOn);
	XCTAssertTrue([self.scratchDefaults boolForKey:SPTestTableInformationPanelCollapsed]);
	XCTAssertEqualObjects([self storedCollapsedValue], @YES);

	// Expand
	[info performClick:nil];
	XCTAssertFalse([split isCollapsibleSubviewCollapsed]);
	XCTAssertEqual(info.state, NSControlStateValueOff);
	XCTAssertFalse([self.scratchDefaults boolForKey:SPTestTableInformationPanelCollapsed]);
	XCTAssertEqualObjects([self storedCollapsedValue], @NO);

	// The real preferences were never written
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] objectForKey:SPTestTableInformationPanelCollapsed], realValue);

	// A sidebar given defaults holding YES starts collapsed (as a new tab honours the stored value)
	[self.scratchDefaults setBool:YES forKey:SPTestTableInformationPanelCollapsed];
	SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:[SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort]];
	SPPostgresSidebarController *other = [[SPPostgresSidebarController alloc] initWithCatalog:catalog];
	other.defaults = self.scratchDefaults;
	XCTAssertTrue([other.infoSplitView isCollapsibleSubviewCollapsed]);
	XCTAssertEqual(other.infoToggleButton.state, NSControlStateValueOn);
	[other invalidate];
}

#pragma mark - Busy

- (void)testBarDisabledWhileBusy
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertTrue(sidebar.actionsEnabled);
	XCTAssertTrue(sidebar.gearButton.isEnabled);
	XCTAssertTrue(sidebar.refreshButton.isEnabled);
	XCTAssertTrue(sidebar.infoToggleButton.isEnabled);
	// Add Table arrives with the document's -sidebarAddTable: (Task 6)
	XCTAssertEqual(sidebar.addButton.isEnabled, [self.document respondsToSelector:@selector(sidebarAddTable:)]);

	[SPPostgresTestServers queueSleep:1 onRunner:self.document.taskRunner];
	XCTAssertTrue(self.document.isProcessing);
	XCTAssertFalse(sidebar.actionsEnabled);
	XCTAssertFalse(sidebar.addButton.isEnabled);
	XCTAssertFalse(sidebar.gearButton.isEnabled);
	XCTAssertFalse(sidebar.refreshButton.isEnabled);
	XCTAssertTrue(sidebar.infoToggleButton.isEnabled);

	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue(sidebar.actionsEnabled);
	XCTAssertTrue(sidebar.gearButton.isEnabled);
	XCTAssertTrue(sidebar.refreshButton.isEnabled);
	XCTAssertTrue(sidebar.infoToggleButton.isEnabled);
	XCTAssertEqual(sidebar.addButton.isEnabled, [self.document respondsToSelector:@selector(sidebarAddTable:)]);
}

@end
