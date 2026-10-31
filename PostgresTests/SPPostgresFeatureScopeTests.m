#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresFeatureScope.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresHistory.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static const NSUInteger SPFeatureScopeTestPort = 55418;

// The app's constants aren't exported to the test bundle: their values, spelled out (SPMainToolbar.m)
static NSString * const SPScopeDatabase = @"DatabaseSelectToolbarItemIdentifier";
static NSString * const SPScopeHistory = @"HistoryNavigationToolbarItemIdentifier";
static NSString * const SPScopeShowConsole = @"ShowConsoleIdentifier";
static NSString * const SPScopeClearConsole = @"ClearConsoleIdentifier";
static NSString * const SPScopeStructure = @"SwitchToTableStructureToolbarItemIdentifier";
static NSString * const SPScopeContent = @"SwitchToTableContentToolbarItemIdentifier";
static NSString * const SPScopeQuery = @"SwitchToRunQueryToolbarItemIdentifier";
static NSString * const SPScopeTableInfo = @"SwitchToTableInfoToolbarItemIdentifier";
static NSString * const SPScopeRelations = @"SwitchToTableRelationsToolbarItemIdentifier";
static NSString * const SPScopeTriggers = @"SwitchToTableTriggersToolbarItemIdentifier";
static NSString * const SPScopeUsers = @"SwitchToUserManagerToolbarItemIdentifier";
static NSString * const SPScopeTransfer = @"TransferToolbarItemIdentifier";

// Not in the public headers
@interface SPPostgresDocument (SPFeatureScopeTests)
- (BOOL)validateToolbarItem:(NSToolbarItem *)item;
- (IBAction)backForwardInHistory:(id)sender;
- (void)toggleConsole:(id)sender;
- (void)_applyHistoryEntry:(NSDictionary *)entry;
- (void)sidebar:(SPPostgresSidebarController *)sidebar exportRelations:(NSArray<NSString *> *)names format:(NSInteger)format;
@end

@interface SPWindowController (SPFeatureScopeTests)
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

@interface SPPostgresSidebarController (SPFeatureScopeTests)
- (BOOL)validateMenuItem:(NSMenuItem *)item;
@end

/**
 * The 2.0.0-RC1 scope of a PostgreSQL tab (SPPostgresFeatureScope): only Content, Query and Console (plus the table
 * list and the database picker) can be used; Structure, Relations, Triggers, Table Info, Sequences, Extensions, Users,
 * Import/Export, Transfer, Table History and Create Syntax are shown disabled or hidden, and never reached.
 * Every other test runs with the full scope (SPTestPrefsGuard); these set the release scope in -setUp.
 */
@interface SPPostgresFeatureScopeTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@end

@implementation SPPostgresFeatureScopeTests

+ (void)setUp
{
	[super setUp];
	[SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:SPFeatureScopeTestPort];
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

	// The release's scope (set before the document builds its sidebar)
	SPPostgresFeatureScopeSetFullScopeForTesting(NO);

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 scope";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPFeatureScopeTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

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

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	self.document.alertPresenter = ^(NSAlert *alert) {};
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	SPPostgresFeatureScopeSetFullScopeForTesting(YES);
	[super tearDown];
}

#pragma mark - Helpers

- (void)selectTable:(NSString *)table
{
	XCTAssertTrue([self.document.sidebar selectTableNamed:table]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

/// The item the tab's installed toolbar shows, else a new one from the tab (e.g. Transfer, not in the default layout).
- (NSToolbarItem *)toolbarItem:(NSString *)identifier
{
	for (NSToolbarItem *installed in [[self.document toolbar] items]) {
		if ([[installed itemIdentifier] isEqualToString:identifier]) return installed;
	}
	NSToolbarItem *item = [self.document toolbar:[self.document toolbar] itemForItemIdentifier:identifier willBeInsertedIntoToolbar:NO];
	XCTAssertNotNil(item, @"%@", identifier);
	return item;
}

- (BOOL)menuItemEnabled:(SEL)action tag:(NSInteger)tag
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSStringFromSelector(action) action:action keyEquivalent:@""];
	[item setTag:tag];
	BOOL byDocument = [self.document validateMenuItem:item];
	BOOL byWindow = [self.controller validateMenuItem:item];
	XCTAssertEqual(byDocument, byWindow, @"the window asks the Postgres tab for %@", NSStringFromSelector(action));
	return byDocument;
}

#pragma mark - The switch

- (void)testReleaseScopeHasOnlyContentQueryAndConsole
{
	XCTAssertFalse(SPPostgresFeatureScopeIsFullScopeForTesting());
	XCTAssertTrue(SPPostgresFeatureIsAvailable(SPPostgresFeatureContent));
	XCTAssertTrue(SPPostgresFeatureIsAvailable(SPPostgresFeatureQuery));
	XCTAssertTrue(SPPostgresFeatureIsAvailable(SPPostgresFeatureConsole));
	SPPostgresFeature heldBack[] = {SPPostgresFeatureStructure, SPPostgresFeatureRelations, SPPostgresFeatureTriggers, SPPostgresFeatureTableInfo,
		SPPostgresFeatureSequences, SPPostgresFeatureExtensions, SPPostgresFeatureUsers, SPPostgresFeatureImportExport,
		SPPostgresFeatureTransfer, SPPostgresFeatureTableHistory, SPPostgresFeatureCreateSyntax};
	for (size_t i = 0; i < sizeof(heldBack) / sizeof(heldBack[0]); i++) XCTAssertFalse(SPPostgresFeatureIsAvailable(heldBack[i]), @"feature %ld", (long)heldBack[i]);

	// The test override: every feature
	SPPostgresFeatureScopeSetFullScopeForTesting(YES);
	for (size_t i = 0; i < sizeof(heldBack) / sizeof(heldBack[0]); i++) XCTAssertTrue(SPPostgresFeatureIsAvailable(heldBack[i]));
	SPPostgresFeatureScopeSetFullScopeForTesting(NO);
}

#pragma mark - Toolbar

- (void)testToolbarShowsEveryItemButOnlyContentQueryConsoleAndDatabaseAreEnabled
{
	// Every item a MySQL tab has is still served (all icons visible)
	NSArray *defaults = [self.document toolbarDefaultItemIdentifiers:[self.document toolbar]];
	for (NSString *identifier in @[SPScopeDatabase, SPScopeHistory, SPScopeShowConsole, SPScopeStructure, SPScopeContent, SPScopeRelations,
								   SPScopeTriggers, SPScopeTableInfo, SPScopeQuery, SPScopeUsers]) {
		XCTAssertTrue([defaults containsObject:identifier], @"%@", identifier);
	}
	XCTAssertTrue([[self.document toolbarAllowedItemIdentifiers:[self.document toolbar]] containsObject:SPScopeTransfer]);

	[self selectTable:@"customers"];
	XCTAssertTrue([self.document.sidebar selectionIsTable]);

	for (NSString *identifier in @[SPScopeContent, SPScopeQuery, SPScopeShowConsole, SPScopeDatabase]) {
		XCTAssertTrue([self.document validateToolbarItem:[self toolbarItem:identifier]], @"%@ is enabled", identifier);
	}
	for (NSString *identifier in @[SPScopeStructure, SPScopeRelations, SPScopeTriggers, SPScopeTableInfo, SPScopeUsers, SPScopeTransfer, SPScopeHistory, SPScopeClearConsole]) {
		XCTAssertFalse([self.document validateToolbarItem:[self toolbarItem:identifier]], @"%@ is disabled", identifier);
	}

	// The same items in the toolbar the tab installs
	for (NSToolbarItem *item in [[self.document toolbar] items]) {
		NSString *identifier = [item itemIdentifier];
		if ([@[SPScopeStructure, SPScopeRelations, SPScopeTriggers, SPScopeTableInfo, SPScopeUsers, SPScopeTransfer] containsObject:identifier]) {
			XCTAssertFalse([self.document validateToolbarItem:item], @"%@", identifier);
		}
	}
}

- (void)testHistoryControlStaysDisabled
{
	[self selectTable:@"customers"];
	[self.document viewQuery:nil];
	[self.document viewContent:nil];
	XCTAssertTrue([self.document.history canGoBack], @"entries are still recorded");

	NSSegmentedControl *control = [self.document valueForKey:@"historyControl"];
	XCTAssertTrue([control isKindOfClass:[NSSegmentedControl class]]);
	XCTAssertFalse([control isEnabledForSegment:0]);
	XCTAssertFalse([control isEnabledForSegment:1]);

	// View > Back In History does nothing
	NSMenuItem *back = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	[back setTag:0];
	[self.document backForwardInHistory:back];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	XCTAssertTrue([self.document.history canGoBack]);
}

#pragma mark - Menus

- (void)testMenuValidationDisablesHeldBackFeatures
{
	[self selectTable:@"customers"];

	XCTAssertFalse([self menuItemEnabled:@selector(import:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(export:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(exportQueryResult:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(showUserManager:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(showTransfer:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(showInstallExtensionSheet:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(viewStructure:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(viewRelations:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(viewTriggers:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(viewStatus:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(backForwardInHistory:) tag:0]);
	XCTAssertFalse([self menuItemEnabled:@selector(backForwardInHistory:) tag:1]);

	XCTAssertTrue([self menuItemEnabled:@selector(viewContent:) tag:0]);
	XCTAssertTrue([self menuItemEnabled:@selector(viewQuery:) tag:0]);
	XCTAssertTrue([self menuItemEnabled:@selector(toggleConsole:) tag:0]);
}

- (void)testHeldBackActionsDoNothing
{
	[self selectTable:@"customers"];
	NSWindow *window = [self.controller window];

	[self.document import:nil];
	XCTAssertNil(self.document.importController);
	[self.document export:nil];
	XCTAssertNil(self.document.exportController);
	[self.document exportQueryResult:nil];
	XCTAssertNil(self.document.exportController);
	[self.document sidebar:self.document.sidebar exportRelations:@[@"customers"] format:0];
	XCTAssertNil(self.document.exportController);
	[self.document showUserManager:nil];
	XCTAssertNil(self.document.usersController);
	[self.document showTransfer:nil];
	XCTAssertNil(self.document.transferController);
	[self.document showInstallExtensionSheet:nil];
	XCTAssertNil(window.attachedSheet);
}

#pragma mark - Panes

- (void)testHeldBackPanesFallBackToContent
{
	[self selectTable:@"customers"];

	for (NSString *pane in @[SPPostgresPaneStructure, SPPostgresPaneRelations, SPPostgresPaneTriggers, SPPostgresPaneInfo, SPPostgresPaneSequence, SPPostgresPaneExtension]) {
		[self.document showPane:SPPostgresPaneQuery];
		XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
		[self.document showPane:pane];
		XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent, @"%@ shows Content", pane);
	}

	// The View menu's actions (and their ⌘ shortcuts) don't switch at all
	[self.document viewQuery:nil];
	for (NSString *selectorName in @[@"viewStructure:", @"viewRelations:", @"viewTriggers:", @"viewStatus:"]) {
		[NSApp sendAction:NSSelectorFromString(selectorName) to:self.document from:nil];
		XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery, @"%@", selectorName);
	}

	// Content and Query work
	[self.document viewContent:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
}

- (void)testHistoryEntryAndOpenRelationOnAHeldBackPaneShowContent
{
	[self.document viewQuery:nil];
	[self.document _applyHistoryEntry:@{@"database": @"pgkit_test", @"schema": @"public", @"table": @"customers", @"pane": SPPostgresPaneStructure}];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"customers");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);

	// As a new tab opened on a table from a tab showing Triggers
	[self.document viewQuery:nil];
	[self.document selectRelationAfterLoad:@"customers" inSchema:@"public" pane:SPPostgresPaneTriggers];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
}

#pragma mark - Table list

- (void)testSidebarHidesSequencesAndExtensions
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertEqualObjects([sidebar sectionTitles], (@[@"TABLES", @"VIEWS"]));

	// The outline's group rows
	NSOutlineView *outline = nil;
	NSMutableArray *queue = [NSMutableArray arrayWithObject:[sidebar view]];
	while (queue.count) {
		NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
		if ([v isKindOfClass:[NSOutlineView class]]) outline = (NSOutlineView *)v;
		[queue addObjectsFromArray:v.subviews];
	}
	XCTAssertNotNil(outline);
	NSMutableArray *groups = [NSMutableArray array];
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		if ([outline.delegate outlineView:outline isGroupItem:item]) [groups addObject:[item valueForKey:@"title"]];
	}
	XCTAssertEqualObjects(groups, (@[@"TABLES", @"VIEWS"]));

	// Their items can't be selected, and empty space gets the table menu (no Install Extension…)
	NSString *extension = [[sidebar itemTitlesInSection:@"EXTENSIONS"] firstObject];
	if (extension) XCTAssertFalse([sidebar selectExtensionNamed:extension]);
	NSString *sequence = [[sidebar itemTitlesInSection:@"SEQUENCES"] firstObject];
	if (sequence) XCTAssertFalse([sidebar selectSequenceNamed:sequence]);
	XCTAssertNil(sidebar.selectedExtensionName);
	XCTAssertNil(sidebar.selectedSequenceName);
	XCTAssertEqual([sidebar menuForRow:-1], sidebar.tableMenu);

	for (NSMenuItem *item in [sidebar.extensionMenu itemArray]) {
		if ([item action]) XCTAssertFalse([sidebar validateMenuItem:item], @"%@", [item title]);
	}
	for (NSMenuItem *item in [sidebar.sequenceMenu itemArray]) {
		if ([item action]) XCTAssertFalse([sidebar validateMenuItem:item], @"%@", [item title]);
	}
}

- (void)testGearMenuKeepsTableListItemsAndDisablesHeldBackOnes
{
	[self selectTable:@"customers"];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSMenu *gear = [sidebar.gearButton menu];
	XCTAssertNotNil(gear);

	NSMutableDictionary<NSString *, NSNumber *> *enabled = [NSMutableDictionary dictionary];
	NSMutableArray<NSMenuItem *> *items = [NSMutableArray arrayWithArray:[gear itemArray]];
	while (items.count) {
		NSMenuItem *item = items.firstObject; [items removeObjectAtIndex:0];
		if ([item submenu]) [items addObjectsFromArray:[[item submenu] itemArray]];
		if (![item action] || [item isSeparatorItem]) continue;
		enabled[NSStringFromSelector([item action])] = @([sidebar validateMenuItem:item]);
	}

	for (NSString *action in @[@"renameTable:", @"duplicateTable:", @"truncateTables:", @"removeRelations:", @"openRelationInNewTab:", @"openRelationInNewWindow:"]) {
		XCTAssertEqualObjects(enabled[action], @YES, @"%@", action);
	}
	for (NSString *action in @[@"exportRelations:", @"showCreateSyntax:", @"copyCreateSyntax:"]) {
		XCTAssertEqualObjects(enabled[action], @NO, @"%@", action);
	}

	// The bottom bar's buttons stay
	XCTAssertTrue([sidebar.addButton isEnabled]);
	XCTAssertTrue([sidebar.refreshButton isEnabled]);
	XCTAssertTrue([sidebar.infoToggleButton isEnabled]);
}

- (void)testQueryExportResultIsDisabled
{
	[self.document viewQuery:nil];
	SPPostgresQueryController *query = self.document.queryController;
	[query.editor setString:@"SELECT 1 AS one"];
	[query.editor setSelectedRange:NSMakeRange(0, 0)];
	[query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);

	NSMenuItem *export = [[query.resultsGearButton menu] itemWithTitle:@"Export Result"];
	NSMenuItem *csv = [[export submenu] itemWithTitle:@"As CSV file…"];
	XCTAssertNotNil(csv);
	XCTAssertFalse([csv isEnabled]);
	NSMenu *submenu = [csv menu];
	[submenu performActionForItemAtIndex:[submenu indexOfItem:csv]];
	XCTAssertNil(self.document.exportController);
}

@end
