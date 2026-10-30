#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresHistory.h"

static const NSUInteger SPPostgresSidebarBarTestPort = 55418;

/// MySQL's SPTableInformationPanelCollapsed (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPTestTableInformationPanelCollapsed = @"TableInformationPanelCollapsed";
static NSString * const SPTestDefaultsSuite = @"SPPostgresStage9Tests";

// Not in the public headers
@interface SPPostgresSidebarController (SPPostgresSidebarBarTests)
- (IBAction)addTable:(id)sender;
- (void)renameTable:(id)sender;
- (void)duplicateTable:(id)sender;
- (void)truncateTables:(id)sender;
- (void)removeRelations:(id)sender;
- (void)openRelationInNewTab:(id)sender;
- (void)openRelationInNewWindow:(id)sender;
- (void)exportRelations:(id)sender;
- (void)showCreateSyntax:(id)sender;
- (void)copyCreateSyntax:(id)sender;
- (void)addSequence:(id)sender;
- (void)deleteSequence:(id)sender;
- (void)installExtension:(id)sender;
- (void)dropExtension:(id)sender;
@end

/// A sidebar delegate that implements every action and records the calls, as @[name, argument…].
@interface SPSidebarMenuTestDelegate : NSObject <SPPostgresSidebarControllerDelegate>
@property (strong) NSMutableArray *calls;
@end

@implementation SPSidebarMenuTestDelegate
- (instancetype)init { if ((self = [super init])) _calls = [NSMutableArray array]; return self; }
- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)sidebar {}
- (void)sidebar:(SPPostgresSidebarController *)sidebar renameTableNamed:(NSString *)table { [self.calls addObject:@[@"rename", table]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar duplicateTableNamed:(NSString *)table { [self.calls addObject:@[@"duplicate", table]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar truncateTables:(NSArray<NSString *> *)tables { [self.calls addObject:@[@"truncate", tables]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar removeRelations:(NSArray<NSString *> *)names { [self.calls addObject:@[@"remove", names]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar openRelation:(NSString *)name inNewWindow:(BOOL)newWindow { [self.calls addObject:@[@"open", name, @(newWindow)]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar exportRelations:(NSArray<NSString *> *)names format:(NSInteger)format { [self.calls addObject:@[@"export", names, @(format)]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar showCreateSyntaxForRelations:(NSArray<NSString *> *)names copy:(BOOL)copy { [self.calls addObject:@[@"syntax", names, @(copy)]]; }
- (void)sidebarAddTable:(SPPostgresSidebarController *)sidebar { [self.calls addObject:@[@"add"]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar addSequenceInSchema:(NSString *)schema { [self.calls addObject:@[@"addSequence", schema]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar deleteSequenceNamed:(NSString *)sequence { [self.calls addObject:@[@"deleteSequence", sequence]]; }
- (void)sidebarInstallExtension:(SPPostgresSidebarController *)sidebar { [self.calls addObject:@[@"installExtension"]]; }
- (void)sidebar:(SPPostgresSidebarController *)sidebar dropExtensionNamed:(NSString *)name { [self.calls addObject:@[@"dropExtension", name]]; }
@end

/// A sidebar delegate with none of the optional actions.
@interface SPSidebarMinimalTestDelegate : NSObject <SPPostgresSidebarControllerDelegate>
@end

@implementation SPSidebarMinimalTestDelegate
- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)sidebar {}
@end

/// -clickedRow of an outline given a row by -setClickedRow:ofOutline: (a right-click, or one AppKit left set), else AppKit's.
static const void *SPTestClickedRowKey = &SPTestClickedRowKey;
static NSInteger SPTestClickedRow(id self, SEL _cmd)
{
	NSNumber *row = objc_getAssociatedObject(self, SPTestClickedRowKey);
	if (row) return row.integerValue;
	struct objc_super superInfo = { self, [NSOutlineView class] };
	return ((NSInteger (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, _cmd);
}

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
	[admin execute:@"DROP SEQUENCE IF EXISTS public.sp9_seq"];
	[admin execute:@"DROP TABLE IF EXISTS public.sp9_a"];
	[admin execute:@"DROP TABLE IF EXISTS public.sp9_b"];
	[admin execute:@"DELETE FROM public.customers WHERE id = 9001"];
	[admin execute:@"DROP VIEW IF EXISTS public.sp9_v"];
	[admin execute:@"DROP TABLE IF EXISTS public.sp9_a2"];
	[admin execute:@"DROP TABLE IF EXISTS public.sp9_b2"];

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

#pragma mark - Multiple selection

- (NSOutlineView *)outlineOfSidebar:(SPPostgresSidebarController *)sidebar
{
	return [(NSScrollView *)sidebar.infoSplitView.subviews.firstObject documentView];
}

/// The outline row of the item titled name (not a section header), or -1.
- (NSInteger)rowNamed:(NSString *)name inSidebar:(SPPostgresSidebarController *)sidebar
{
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		if ([sidebar outlineView:outline isGroupItem:item]) continue;
		if ([[sidebar outlineView:outline objectValueForTableColumn:nil byItem:item] isEqual:name]) return row;
	}
	return -1;
}

- (void)testSelectingTwoTablesReportsBoth
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertEqualObjects(sidebar.selectedSchema, @"public");

	// Asked in reverse: reported in display order (TABLES before VIEWS)
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"v_customers", @"customers"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[@"customers", @"v_customers"]));
	XCTAssertNil(sidebar.selectedTableName);
	XCTAssertFalse(sidebar.selectionIsTable);
	XCTAssertTrue([sidebar relationIsView:@"v_customers"]);
	XCTAssertFalse([sidebar relationIsView:@"customers"]);
	XCTAssertEqual([self outlineOfSidebar:sidebar].selectedRowIndexes.count, 2u);

	// No right-click: the actions act on the selection
	XCTAssertEqualObjects([sidebar actionTargetRelationNames], (@[@"customers", @"v_customers"]));

	// One relation: one name, and selectedTableName again
	XCTAssertTrue([sidebar selectRelationsNamed:@[@"customers"]]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[@"customers"]);
	XCTAssertEqualObjects(sidebar.selectedTableName, @"customers");

	// A name that isn't listed
	XCTAssertFalse([sidebar selectRelationsNamed:@[@"no_such_table"]]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[@"customers"]);

	// Nothing selected, and an extension selected: no relation
	XCTAssertTrue([sidebar selectRelationsNamed:@[]]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[]);
	XCTAssertTrue([sidebar selectExtensionNamed:@"pg_trgm"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[]);
}

- (void)testSequenceCannotJoinMultipleSelection
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort];
	XCTAssertNotNil([admin execute:@"DROP SEQUENCE IF EXISTS public.sp9_seq"]);
	XCTAssertNotNil([admin execute:@"CREATE SEQUENCE public.sp9_seq"]);

	SPPostgresSidebarController *sidebar = self.document.sidebar;
	[sidebar reloadKeepingSelection];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([[sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"sp9_seq"]);

	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	XCTAssertTrue(outline.allowsMultipleSelection);
	NSInteger table = [self rowNamed:@"customers" inSidebar:sidebar];
	NSInteger view = [self rowNamed:@"v_customers" inSidebar:sidebar];
	NSInteger sequence = [self rowNamed:@"sp9_seq" inSidebar:sidebar];
	NSInteger extension = [self rowNamed:@"pg_trgm" inSidebar:sidebar];
	XCTAssertGreaterThanOrEqual(table, 0);
	XCTAssertGreaterThanOrEqual(view, 0);
	XCTAssertGreaterThanOrEqual(sequence, 0);
	XCTAssertGreaterThanOrEqual(extension, 0);

	// Tables and views together stay as proposed
	NSMutableIndexSet *relations = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)table];
	[relations addIndex:(NSUInteger)view];
	XCTAssertEqualObjects([sidebar outlineView:outline selectionIndexesForProposedSelection:relations], relations);

	// customers selected, the sequence added with no click (as Shift-arrow or Select All would): the tables and views stay
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSMutableIndexSet *withSequence = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)table];
	[withSequence addIndex:(NSUInteger)sequence];
	NSIndexSet *kept = [sidebar outlineView:outline selectionIndexesForProposedSelection:withSequence];
	XCTAssertEqualObjects(kept, [NSIndexSet indexSetWithIndex:(NSUInteger)table]);

	// So with an extension
	NSMutableIndexSet *withExtension = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)table];
	[withExtension addIndex:(NSUInteger)extension];
	XCTAssertEqualObjects([sidebar outlineView:outline selectionIndexesForProposedSelection:withExtension], [NSIndexSet indexSetWithIndex:(NSUInteger)table]);

	// A sequence and an extension, no table or view among them: just the row added (the extension)
	XCTAssertTrue([sidebar selectSequenceNamed:@"sp9_seq"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSMutableIndexSet *sequenceAndExtension = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)sequence];
	[sequenceAndExtension addIndex:(NSUInteger)extension];
	XCTAssertEqualObjects([sidebar outlineView:outline selectionIndexesForProposedSelection:sequenceAndExtension], [NSIndexSet indexSetWithIndex:(NSUInteger)extension]);
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// A shift-click range from a table to a view crosses the VIEWS header: the header isn't selected
	NSIndexSet *range = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange((NSUInteger)table, (NSUInteger)(view - table + 1))];
	NSMutableIndexSet *rangeWithoutHeaders = [range mutableCopy];
	[range enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
		if ([sidebar outlineView:outline isGroupItem:[outline itemAtRow:(NSInteger)row]]) [rangeWithoutHeaders removeIndex:row];
	}];
	XCTAssertEqual(rangeWithoutHeaders.count, range.count - 1, @"the range crosses the VIEWS header");
	XCTAssertEqualObjects([sidebar outlineView:outline selectionIndexesForProposedSelection:range], rangeWithoutHeaders);

	// A header alone: the selection stays
	NSInteger header = [self rowNamed:@"VIEWS" inSidebar:sidebar];
	XCTAssertEqual(header, -1, @"rowNamed: skips headers");
	NSUInteger viewsHeader = [range indexPassingTest:^BOOL(NSUInteger row, BOOL *stop) { return [sidebar outlineView:outline isGroupItem:[outline itemAtRow:(NSInteger)row]]; }];
	XCTAssertEqualObjects([sidebar outlineView:outline selectionIndexesForProposedSelection:[NSIndexSet indexSetWithIndex:viewsHeader]], outline.selectedRowIndexes);
}

- (void)testMultipleSelectionClearsPanes
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort];
	XCTAssertNotNil([admin execute:@"DELETE FROM public.customers WHERE id = 9001"]);
	XCTAssertNotNil([admin execute:@"INSERT INTO public.customers (id, name) VALUES (9001, 'sp9')"]);
	PGPostgresResult *count = [admin execute:@"SELECT count(*)::int FROM public.customers"];
	NSInteger rows = [[[count rowAsArray] firstObject] integerValue];
	XCTAssertGreaterThan(rows, 0);

	SPPostgresDocument *document = self.document;
	SPPostgresSidebarController *sidebar = document.sidebar;
	SPPostgresContentController *content = document.contentController;

	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:document.taskRunner timeout:30]);
	XCTAssertEqualObjects(content.table, @"customers");
	XCTAssertEqual(content.tableView.numberOfRows, rows);

	BOOL couldGoBack = document.history.canGoBack;
	NSDictionary *entry = document.history.currentEntry;
	XCTAssertEqualObjects([entry objectForKey:@"table"], @"customers");

	// Two relations: no table in the panes, and no History entry
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"customers", @"v_customers"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:document.taskRunner timeout:30]);
	XCTAssertNil(sidebar.selectedTableName);
	XCTAssertNil(content.table);
	XCTAssertEqual(content.tableView.numberOfRows, 0);
	XCTAssertEqual(document.history.canGoBack, couldGoBack);
	XCTAssertEqualObjects(document.history.currentEntry, entry);
	XCTAssertFalse(document.history.canGoForward);

	// customers alone again: its rows load again
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:document.taskRunner timeout:30]);
	XCTAssertEqualObjects(content.table, @"customers");
	XCTAssertEqual(content.tableView.numberOfRows, rows);
	XCTAssertEqualObjects([document.history.currentEntry objectForKey:@"table"], @"customers");
}

- (void)testReloadKeepsMultipleSelection
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"customers", @"v_customers"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	[sidebar reloadKeepingSelection];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[@"customers", @"v_customers"]));
	XCTAssertEqual([self outlineOfSidebar:sidebar].selectedRowIndexes.count, 2u);
	XCTAssertNil(sidebar.selectedTableName);

	// The bar's Refresh too
	[sidebar.refreshButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[@"customers", @"v_customers"]));
}

/// The outline's own handling of an arrow key (as the keyboard sends it), shift: extending the selection.
- (void)pressArrow:(unichar)arrow shift:(BOOL)shift inOutline:(NSOutlineView *)outline
{
	NSString *characters = [NSString stringWithCharacters:&arrow length:1];
	unsigned short keyCode = (arrow == NSDownArrowFunctionKey) ? 125 : 126;
	NSEventModifierFlags flags = NSEventModifierFlagFunction | NSEventModifierFlagNumericPad | (shift ? NSEventModifierFlagShift : 0);
	NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:outline.window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
	[outline keyDown:event];
}

/// Every table and view of the shown schema, in display order.
- (NSArray<NSString *> *)relationsOfSidebar:(SPPostgresSidebarController *)sidebar
{
	return [[sidebar itemTitlesInSection:@"TABLES"] arrayByAddingObjectsFromArray:[sidebar itemTitlesInSection:@"VIEWS"]];
}

- (void)testSelectAllSelectsEveryRelation
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertGreaterThan([sidebar itemTitlesInSection:@"EXTENSIONS"].count, 0u);

	[outline selectAll:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, [self relationsOfSidebar:sidebar]);
	XCTAssertNil(sidebar.selectedExtensionName);
	XCTAssertNil(sidebar.selectedSequenceName);
	XCTAssertNotEqualObjects(self.document.currentPane, @"extension");

	// From an extension too
	XCTAssertTrue([sidebar selectExtensionNamed:@"pg_trgm"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[outline selectAll:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, [self relationsOfSidebar:sidebar]);
	XCTAssertNil(sidebar.selectedExtensionName);
}

- (void)testDownArrowFromLastTableMovesToFirstView
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	NSString *lastTable = [[sidebar itemTitlesInSection:@"TABLES"] lastObject];
	NSString *firstView = [[sidebar itemTitlesInSection:@"VIEWS"] firstObject];
	XCTAssertNotNil(lastTable);
	XCTAssertNotNil(firstView);
	XCTAssertTrue([sidebar selectTableNamed:lastTable]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	[self pressArrow:NSDownArrowFunctionKey shift:NO inOutline:outline];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[firstView]);
	XCTAssertEqualObjects(sidebar.selectedTableName, firstView);

	// And back up across the header
	[self pressArrow:NSUpArrowFunctionKey shift:NO inOutline:outline];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedTableName, lastTable);
}

- (void)testShiftDownExtendsAcrossViewsHeader
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	NSString *lastTable = [[sidebar itemTitlesInSection:@"TABLES"] lastObject];
	NSString *firstView = [[sidebar itemTitlesInSection:@"VIEWS"] firstObject];
	XCTAssertTrue([sidebar selectTableNamed:lastTable]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	[self pressArrow:NSDownArrowFunctionKey shift:YES inOutline:outline];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[lastTable, firstView]));
	XCTAssertNil(sidebar.selectedTableName);
}

- (void)testReloadWithVanishedNameKeepsSurvivor
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort];
	XCTAssertNotNil([admin execute:@"DROP TABLE IF EXISTS public.sp9_a"]);
	XCTAssertNotNil([admin execute:@"DROP TABLE IF EXISTS public.sp9_b"]);
	XCTAssertNotNil([admin execute:@"CREATE TABLE public.sp9_a (id int)"]);
	XCTAssertNotNil([admin execute:@"CREATE TABLE public.sp9_b (id int)"]);

	SPPostgresSidebarController *sidebar = self.document.sidebar;
	[sidebar reloadKeepingSelection];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"sp9_a", @"sp9_b"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[@"sp9_a", @"sp9_b"]));

	XCTAssertNotNil([admin execute:@"DROP TABLE public.sp9_b"]);
	[sidebar reloadKeepingSelection];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse([[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"sp9_b"]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[@"sp9_a"]);
	XCTAssertEqualObjects(sidebar.selectedTableName, @"sp9_a");
	XCTAssertEqualObjects(self.document.contentController.table, @"sp9_a");
}

- (void)testPartialSelectRelationsNamed
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertFalse(([sidebar selectRelationsNamed:@[@"customers", @"no_such"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[@"customers"]);
	XCTAssertEqualObjects(sidebar.selectedTableName, @"customers");
}

#pragma mark - Gear and right-click menus

/// The relation menus' order and titles, "-" for a separator.
static NSArray *SPOneTableTitles(void)
{
	return @[@"Rename Table…", @"Duplicate Table…", @"-", @"Truncate Table", @"Delete Table", @"-", @"Open Table in New Tab", @"Open Table in New Window", @"-", @"Export", @"-", @"Show Create Table Syntax…", @"Copy Create Table Syntax"];
}

static NSArray *SPOneViewTitles(void)
{
	return @[@"Rename View…", @"Duplicate View…", @"-", @"Delete View", @"-", @"Open View in New Tab", @"Open View in New Window", @"-", @"Export", @"-", @"Show Create View Syntax…", @"Copy Create View Syntax"];
}

/// Validates every item of menu (and its submenus) as AppKit does before showing it, setting each one's enabled state.
- (void)validateMenu:(NSMenu *)menu
{
	for (NSMenuItem *item in menu.itemArray) {
		if (item.action && [item.target respondsToSelector:@selector(validateMenuItem:)]) {
			item.enabled = [(id<NSMenuItemValidation>)item.target validateMenuItem:item];
		}
		if (item.submenu) [self validateMenu:item.submenu];
	}
}

/// After validating: the titles of the visible items from index `from`, "-" for a separator.
- (NSArray *)visibleTitlesOfMenu:(NSMenu *)menu from:(NSInteger)from
{
	[self validateMenu:menu];
	NSMutableArray *titles = [NSMutableArray array];
	for (NSInteger i = from; i < menu.numberOfItems; i++) {
		NSMenuItem *item = [menu itemAtIndex:i];
		if (item.isHidden) continue;
		[titles addObject:item.isSeparatorItem ? @"-" : item.title];
	}
	return titles;
}

/// The item of menu (or of a submenu) with action (and tag, for Export's), or nil.
- (NSMenuItem *)itemWithAction:(SEL)action tag:(NSInteger)tag inMenu:(NSMenu *)menu
{
	for (NSMenuItem *item in menu.itemArray) {
		if (item.action == action && (action != @selector(exportRelations:) || item.tag == tag)) return item;
		NSMenuItem *found = item.submenu ? [self itemWithAction:action tag:tag inMenu:item.submenu] : nil;
		if (found) return found;
	}
	return nil;
}

- (NSMenuItem *)itemWithAction:(SEL)action inMenu:(NSMenu *)menu
{
	return [self itemWithAction:action tag:0 inMenu:menu];
}

/// Validates menu, then chooses the item with action (YES if it was enabled), as a click on it would.
- (BOOL)choose:(SEL)action tag:(NSInteger)tag inMenu:(NSMenu *)menu
{
	[self validateMenu:menu];
	NSMenuItem *item = [self itemWithAction:action tag:tag inMenu:menu];
	XCTAssertNotNil(item);
	if (!item.isEnabled) return NO;
	[item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];
	return YES;
}

- (BOOL)choose:(SEL)action inMenu:(NSMenu *)menu
{
	return [self choose:action tag:0 inMenu:menu];
}

/// Makes the outline's -clickedRow return row (-1: AppKit's again), as a right-click on it, or one AppKit kept after it.
- (void)setClickedRow:(NSInteger)row ofOutline:(NSOutlineView *)outline
{
	class_addMethod([outline class], @selector(clickedRow), (IMP)SPTestClickedRow, "q@:");
	objc_setAssociatedObject(outline, SPTestClickedRowKey, row < 0 ? nil : @(row), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	XCTAssertEqual(outline.clickedRow, row);
}

- (void)reloadSidebarCreating:(NSArray<NSString *> *)statements
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresSidebarBarTestPort];
	for (NSString *statement in statements) XCTAssertNotNil([admin execute:statement], @"%@", statement);
	[self.document.sidebar reloadKeepingSelection];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)testGearMenuOrderAndTitlesForTable
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// The gear: its hidden image item first, then MySQL's items
	NSMenu *gear = sidebar.gearButton.menu;
	XCTAssertNotEqual(gear, sidebar.tableMenu, @"an item belongs to one menu");
	XCTAssertEqualObjects([gear itemAtIndex:0].image.name, @"button_action");
	XCTAssertTrue([gear itemAtIndex:0].isHidden);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], SPOneTableTitles());

	// The right-click menu: the same items
	XCTAssertEqualObjects([self visibleTitlesOfMenu:sidebar.tableMenu from:0], SPOneTableTitles());

	for (NSMenu *menu in @[gear, sidebar.tableMenu]) {
		// The actions, in MySQL's order
		NSInteger from = (menu == gear) ? 1 : 0;
		NSMutableArray *actions = [NSMutableArray array];
		for (NSInteger i = from; i < menu.numberOfItems; i++) {
			NSMenuItem *item = [menu itemAtIndex:i];
			[actions addObject:item.isSeparatorItem ? @"-" : (item.submenu ? @"submenu" : NSStringFromSelector(item.action))];
		}
		XCTAssertEqualObjects(actions, (@[@"renameTable:", @"duplicateTable:", @"-", @"truncateTables:", @"removeRelations:", @"-", @"openRelationInNewTab:", @"openRelationInNewWindow:", @"-", @"submenu", @"-", @"showCreateSyntax:", @"copyCreateSyntax:"]));

		// Open in New Window is the Option alternate of Open in New Tab
		NSMenuItem *newWindow = [self itemWithAction:@selector(openRelationInNewWindow:) inMenu:menu];
		NSMenuItem *newTab = [self itemWithAction:@selector(openRelationInNewTab:) inMenu:menu];
		XCTAssertTrue(newWindow.isAlternate);
		XCTAssertEqual(newWindow.keyEquivalentModifierMask, NSEventModifierFlagOption);
		XCTAssertEqualObjects(newWindow.keyEquivalent, newTab.keyEquivalent);
		XCTAssertEqual([menu indexOfItem:newWindow], [menu indexOfItem:newTab] + 1);

		// Export ▸ SQL dump (tag 0) and CSV (tag 1), MySQL's tags; no XML
		NSMenu *export = [menu itemWithTitle:@"Export"].submenu;
		XCTAssertNotNil(export);
		XCTAssertEqualObjects([export.itemArray valueForKey:@"title"], (@[@"As SQL dump…", @"As CSV file…"]));
		XCTAssertEqual([export itemAtIndex:0].tag, 0);
		XCTAssertEqual([export itemAtIndex:1].tag, 1);
		XCTAssertEqual([export itemAtIndex:0].action, @selector(exportRelations:));
		XCTAssertEqual([export itemAtIndex:1].action, @selector(exportRelations:));
	}
}

- (void)testMenuTitlesForViewAndMultiple
{
	[self reloadSidebarCreating:@[@"DROP TABLE IF EXISTS public.sp9_a", @"DROP VIEW IF EXISTS public.sp9_v", @"CREATE TABLE public.sp9_a (id int)", @"CREATE VIEW public.sp9_v AS SELECT 1 AS one"]];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSMenu *gear = sidebar.gearButton.menu;

	// One view: no Truncate
	XCTAssertTrue([sidebar selectTableNamed:@"v_customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], SPOneViewTitles());
	XCTAssertEqualObjects([self visibleTitlesOfMenu:sidebar.tableMenu from:0], SPOneViewTitles());

	// A table and a view: Delete Items, no Truncate, Rename, Duplicate or Open
	NSArray *mixed = @[@"Delete Items", @"-", @"Export", @"-", @"Show Create Syntaxes…", @"Copy Create Syntaxes"];
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"customers", @"v_customers"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], mixed);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:sidebar.tableMenu from:0], mixed);

	// Two tables: Truncate Tables and Delete Tables
	NSArray *tables = @[@"Truncate Tables", @"Delete Tables", @"-", @"Export", @"-", @"Show Create Syntaxes…", @"Copy Create Syntaxes"];
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"customers", @"sp9_a"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], tables);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:sidebar.tableMenu from:0], tables);

	// Two views: Delete Views
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"v_customers", @"sp9_v"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], (@[@"Delete Views", @"-", @"Export", @"-", @"Show Create Syntaxes…", @"Copy Create Syntaxes"]));

	// Back to one table: its titles again, everything shown
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], SPOneTableTitles());
}

- (void)testRightClickOutsideSelectionTargetsClickedRow
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	SPSidebarMenuTestDelegate *recorder = [[SPSidebarMenuTestDelegate alloc] init];
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	sidebar.delegate = recorder;

	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	[self setClickedRow:[self rowNamed:@"v_customers" inSidebar:sidebar] ofOutline:outline];
	XCTAssertEqualObjects([sidebar actionTargetRelationNames], @[@"v_customers"]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, @[@"customers"], @"the selection stays");

	// The right-click menu is the view's, and acts on it
	XCTAssertEqualObjects([self visibleTitlesOfMenu:sidebar.tableMenu from:0], SPOneViewTitles());
	XCTAssertFalse([self choose:@selector(renameTable:) inMenu:sidebar.tableMenu], @"Rename stays tables-only");
	XCTAssertTrue([self choose:@selector(showCreateSyntax:) inMenu:sidebar.tableMenu]);
	XCTAssertTrue([self choose:@selector(openRelationInNewWindow:) inMenu:sidebar.tableMenu]);
	XCTAssertTrue([self choose:@selector(exportRelations:) tag:1 inMenu:sidebar.tableMenu]);
	XCTAssertEqualObjects(recorder.calls, (@[@[@"syntax", @[@"v_customers"], @NO], @[@"open", @"v_customers", @YES], @[@"export", @[@"v_customers"], @1]]));

	// On a table outside the selection: Rename and Duplicate act on it
	[recorder.calls removeAllObjects];
	XCTAssertTrue([sidebar selectTableNamed:@"v_customers"]);
	[self setClickedRow:[self rowNamed:@"customers" inSidebar:sidebar] ofOutline:outline];
	XCTAssertTrue([self choose:@selector(renameTable:) inMenu:sidebar.tableMenu]);
	XCTAssertTrue([self choose:@selector(duplicateTable:) inMenu:sidebar.tableMenu]);
	XCTAssertTrue([self choose:@selector(truncateTables:) inMenu:sidebar.tableMenu]);
	XCTAssertEqualObjects(recorder.calls, (@[@[@"rename", @"customers"], @[@"duplicate", @"customers"], @[@"truncate", @[@"customers"]]]));

	[self setClickedRow:-1 ofOutline:outline];
	sidebar.delegate = (id<SPPostgresSidebarControllerDelegate>)self.document;
}

- (void)testGearActsOnSelectionNotStaleClickedRow
{
	[self reloadSidebarCreating:@[@"DROP TABLE IF EXISTS public.sp9_a", @"CREATE TABLE public.sp9_a (id int)"]];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	SPSidebarMenuTestDelegate *recorder = [[SPSidebarMenuTestDelegate alloc] init];
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"customers", @"sp9_a"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	sidebar.delegate = recorder;

	// A clicked row left over from an earlier click, outside the selection
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	[self setClickedRow:[self rowNamed:@"v_customers" inSidebar:sidebar] ofOutline:outline];

	// The gear acts on the selection
	NSMenu *gear = sidebar.gearButton.menu;
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], (@[@"Truncate Tables", @"Delete Tables", @"-", @"Export", @"-", @"Show Create Syntaxes…", @"Copy Create Syntaxes"]));
	XCTAssertTrue([self choose:@selector(removeRelations:) inMenu:gear]);
	XCTAssertTrue([self choose:@selector(truncateTables:) inMenu:gear]);
	XCTAssertTrue([self choose:@selector(copyCreateSyntax:) inMenu:gear]);
	XCTAssertTrue([self choose:@selector(exportRelations:) tag:0 inMenu:gear]);
	XCTAssertEqualObjects(recorder.calls, (@[@[@"remove", @[@"customers", @"sp9_a"]], @[@"truncate", @[@"customers", @"sp9_a"]], @[@"syntax", @[@"customers", @"sp9_a"], @YES], @[@"export", @[@"customers", @"sp9_a"], @0]]));

	// One table selected: the gear's Rename acts on it, not on the clicked view
	[recorder.calls removeAllObjects];
	XCTAssertTrue([sidebar selectTableNamed:@"sp9_a"]);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], SPOneTableTitles());
	XCTAssertTrue([self choose:@selector(renameTable:) inMenu:gear]);
	XCTAssertTrue([self choose:@selector(openRelationInNewTab:) inMenu:gear]);
	XCTAssertEqualObjects(recorder.calls, (@[@[@"rename", @"sp9_a"], @[@"open", @"sp9_a", @NO]]));

	// The right-click menu, though, acts on that row
	[recorder.calls removeAllObjects];
	XCTAssertTrue([self choose:@selector(removeRelations:) inMenu:sidebar.tableMenu]);
	XCTAssertEqualObjects(recorder.calls, (@[@[@"remove", @[@"v_customers"]]]));

	[self setClickedRow:-1 ofOutline:outline];
	sidebar.delegate = (id<SPPostgresSidebarControllerDelegate>)self.document;
}

- (void)testGearShowsSequenceMenuForSequence
{
	[self reloadSidebarCreating:@[@"DROP SEQUENCE IF EXISTS public.sp9_seq", @"CREATE SEQUENCE public.sp9_seq"]];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSPopUpButton *gearButton = sidebar.gearButton;

	// A sequence: the sequence menu's items after the image item
	XCTAssertTrue([sidebar selectSequenceNamed:@"sp9_seq"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSMenu *gear = gearButton.menu;
	XCTAssertEqualObjects([gear itemAtIndex:0].image.name, @"button_action");
	XCTAssertTrue([gear itemAtIndex:0].isHidden);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], (@[@"Add Sequence…", @"Delete Sequence…"]));
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], [self visibleTitlesOfMenu:[sidebar menuForRow:[self rowNamed:@"sp9_seq" inSidebar:sidebar]] from:0]);
	XCTAssertTrue([self itemWithAction:@selector(addSequence:) inMenu:gear].isEnabled);
	XCTAssertTrue([self itemWithAction:@selector(deleteSequence:) inMenu:gear].isEnabled);

	// It acts on the selected sequence, whatever row was clicked before
	SPSidebarMenuTestDelegate *recorder = [[SPSidebarMenuTestDelegate alloc] init];
	sidebar.delegate = recorder;
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	[self setClickedRow:[self rowNamed:@"customers" inSidebar:sidebar] ofOutline:outline];
	XCTAssertTrue([self choose:@selector(deleteSequence:) inMenu:gear]);
	XCTAssertEqualObjects(recorder.calls, (@[@[@"deleteSequence", @"sp9_seq"]]));
	[self setClickedRow:-1 ofOutline:outline];
	sidebar.delegate = (id<SPPostgresSidebarControllerDelegate>)self.document;

	// An extension: the extension menu's
	XCTAssertTrue([sidebar selectExtensionNamed:@"pg_trgm"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	gear = gearButton.menu;
	XCTAssertEqualObjects([gear itemAtIndex:0].image.name, @"button_action");
	XCTAssertTrue([gear itemAtIndex:0].isHidden);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], (@[@"Install Extension…", @"Drop Extension…"]));
	XCTAssertTrue([self itemWithAction:@selector(dropExtension:) inMenu:gear].isEnabled);

	// A table again: the table menu's
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	gear = gearButton.menu;
	XCTAssertTrue([gear itemAtIndex:0].isHidden);
	XCTAssertEqualObjects([self visibleTitlesOfMenu:gear from:1], SPOneTableTitles());
}

- (void)testItemsDisabledWhileBusy
{
	[self reloadSidebarCreating:@[@"DROP SEQUENCE IF EXISTS public.sp9_seq", @"CREATE SEQUENCE public.sp9_seq"]];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	SPSidebarMenuTestDelegate *recorder = [[SPSidebarMenuTestDelegate alloc] init];
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	sidebar.delegate = recorder;

	SEL relationActions[] = { @selector(renameTable:), @selector(duplicateTable:), @selector(truncateTables:), @selector(removeRelations:), @selector(openRelationInNewTab:), @selector(openRelationInNewWindow:), @selector(showCreateSyntax:), @selector(copyCreateSyntax:) };
	NSMenu *gear = sidebar.gearButton.menu;
	for (NSMenu *menu in @[gear, sidebar.tableMenu]) {
		[self validateMenu:menu];
		for (size_t i = 0; i < sizeof(relationActions) / sizeof(SEL); i++) {
			XCTAssertTrue([self itemWithAction:relationActions[i] inMenu:menu].isEnabled, @"%@", NSStringFromSelector(relationActions[i]));
		}
		XCTAssertTrue([self itemWithAction:@selector(exportRelations:) tag:0 inMenu:menu].isEnabled);
		XCTAssertTrue([self itemWithAction:@selector(exportRelations:) tag:1 inMenu:menu].isEnabled);
	}

	// Busy: every item disabled, and choosing one does nothing
	sidebar.actionsEnabled = NO;
	for (NSMenu *menu in @[gear, sidebar.tableMenu, sidebar.sequenceMenu, sidebar.extensionMenu]) {
		[self validateMenu:menu];
		for (NSMenuItem *item in menu.itemArray) {
			// The sidebar's items (not the gear's image item or separators, which the pop-up targets); Export ▸ opens,
			// as AppKit's submenu items do, its items disabled
			if (item.target == sidebar && !item.submenu) XCTAssertFalse(item.isEnabled, @"%@", item.title);
			for (NSMenuItem *sub in item.submenu.itemArray) XCTAssertFalse(sub.isEnabled, @"%@", sub.title);
		}
	}
	[sidebar removeRelations:[self itemWithAction:@selector(removeRelations:) inMenu:gear]];
	[sidebar truncateTables:[self itemWithAction:@selector(truncateTables:) inMenu:sidebar.tableMenu]];
	XCTAssertEqual(recorder.calls.count, 0u);
	sidebar.actionsEnabled = YES;

	// A delegate without the actions: disabled
	SPSidebarMinimalTestDelegate *minimal = [[SPSidebarMinimalTestDelegate alloc] init];
	sidebar.delegate = minimal;
	for (NSMenu *menu in @[gear, sidebar.tableMenu]) {
		[self validateMenu:menu];
		for (size_t i = 0; i < sizeof(relationActions) / sizeof(SEL); i++) {
			XCTAssertFalse([self itemWithAction:relationActions[i] inMenu:menu].isEnabled, @"%@", NSStringFromSelector(relationActions[i]));
		}
		XCTAssertFalse([self itemWithAction:@selector(exportRelations:) tag:0 inMenu:menu].isEnabled);
	}

	// The tab busy (a task running): actionsEnabled goes NO, so the items do too
	sidebar.delegate = (id<SPPostgresSidebarControllerDelegate>)self.document;
	[SPPostgresTestServers queueSleep:1 onRunner:self.document.taskRunner];
	XCTAssertFalse(sidebar.actionsEnabled);
	[self validateMenu:gear];
	XCTAssertFalse([self itemWithAction:@selector(renameTable:) inMenu:gear].isEnabled);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self validateMenu:gear];
	XCTAssertTrue([self itemWithAction:@selector(renameTable:) inMenu:gear].isEnabled);
}

- (id)viewWithIdentifier:(NSString *)identifier in:(NSView *)root
{
	NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
	while (queue.count) {
		NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
		if ([v.identifier isEqualToString:identifier]) return v;
		[queue addObjectsFromArray:v.subviews];
	}
	return nil;
}

/// Fills in and confirms the Rename sheet the document shows.
- (void)renameInSheetTo:(NSString *)newName
{
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSWindow *sheet = self.controller.window.attachedSheet;
	XCTAssertNotNil(sheet);
	NSTextField *name = [self viewWithIdentifier:@"renameTableName" in:sheet.contentView];
	name.stringValue = newName;
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:name];
	[(NSButton *)[self viewWithIdentifier:@"renameTableButton" in:sheet.contentView] performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self spinUntil:^BOOL{ return self.controller.window.attachedSheet == nil; } timeout:5]);
}

- (void)testRenameKeepsMultipleSelection
{
	[self reloadSidebarCreating:@[@"DROP TABLE IF EXISTS public.sp9_a", @"DROP TABLE IF EXISTS public.sp9_b", @"CREATE TABLE public.sp9_a (id int)", @"CREATE TABLE public.sp9_b (id int)"]];
	[self.controller showWindow:nil];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertTrue(([sidebar selectRelationsNamed:@[@"customers", @"sp9_a"]]));
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// Right-click on sp9_b (outside the selection), Rename: the selection stays
	NSOutlineView *outline = [self outlineOfSidebar:sidebar];
	[self setClickedRow:[self rowNamed:@"sp9_b" inSidebar:sidebar] ofOutline:outline];
	XCTAssertTrue([self choose:@selector(renameTable:) inMenu:sidebar.tableMenu]);
	[self setClickedRow:-1 ofOutline:outline];
	[self renameInSheetTo:@"sp9_b2"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"sp9_b2"]; } timeout:5]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[@"customers", @"sp9_a"]));

	// A selected one renamed (the delegate asked for it directly): the selection has its new name
	[(id<SPPostgresSidebarControllerDelegate>)self.document sidebar:sidebar renameTableNamed:@"sp9_a"];
	[self renameInSheetTo:@"sp9_a2"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"sp9_a2"]; } timeout:5]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedRelationNames, (@[@"customers", @"sp9_a2"]));
}

@end
