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
 * The 2.0.0-RC3 scope of a PostgreSQL tab (SPPostgresFeatureScope): every feature can be used. Every other test runs
 * with the full scope (SPTestPrefsGuard); these set the release scope in -setUp, so they check what the app ships.
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

- (void)testReleaseScopeHasEveryFeature
{
	XCTAssertFalse(SPPostgresFeatureScopeIsFullScopeForTesting());
	SPPostgresFeature all[] = {SPPostgresFeatureContent, SPPostgresFeatureQuery, SPPostgresFeatureConsole, SPPostgresFeatureStructure,
		SPPostgresFeatureRelations, SPPostgresFeatureTriggers, SPPostgresFeatureTableInfo, SPPostgresFeatureSequences,
		SPPostgresFeatureExtensions, SPPostgresFeatureUsers, SPPostgresFeatureImportExport, SPPostgresFeatureTransfer,
		SPPostgresFeatureTableHistory, SPPostgresFeatureCreateSyntax};
	for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) XCTAssertTrue(SPPostgresFeatureIsAvailable(all[i]), @"feature %ld", (long)all[i]);
}

#pragma mark - Toolbar

- (void)testToolbarItemsAreEnabled
{
	NSArray *defaults = [self.document toolbarDefaultItemIdentifiers:[self.document toolbar]];
	for (NSString *identifier in @[SPScopeDatabase, SPScopeHistory, SPScopeShowConsole, SPScopeStructure, SPScopeContent, SPScopeRelations,
								   SPScopeTriggers, SPScopeTableInfo, SPScopeQuery, SPScopeUsers]) {
		XCTAssertTrue([defaults containsObject:identifier], @"%@", identifier);
	}
	XCTAssertTrue([[self.document toolbarAllowedItemIdentifiers:[self.document toolbar]] containsObject:SPScopeTransfer]);

	[self selectTable:@"customers"];
	for (NSString *identifier in @[SPScopeContent, SPScopeQuery, SPScopeShowConsole, SPScopeDatabase, SPScopeStructure, SPScopeRelations,
								   SPScopeTriggers, SPScopeTableInfo, SPScopeUsers, SPScopeTransfer, SPScopeHistory]) {
		XCTAssertTrue([self.document validateToolbarItem:[self toolbarItem:identifier]], @"%@ is enabled", identifier);
	}
}

- (void)testHistoryGoesBack
{
	[self selectTable:@"customers"];
	[self.document viewQuery:nil];
	[self.document viewContent:nil];
	XCTAssertTrue([self.document.history canGoBack]);

	NSSegmentedControl *control = [self.document valueForKey:@"historyControl"];
	XCTAssertTrue([control isKindOfClass:[NSSegmentedControl class]]);
	XCTAssertTrue([control isEnabledForSegment:0]);
	XCTAssertTrue([self menuItemEnabled:@selector(backForwardInHistory:) tag:0]);

	// View > Back In History
	NSMenuItem *back = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	[back setTag:0];
	[self.document backForwardInHistory:back];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
}

#pragma mark - Menus

- (void)testMenuItemsAreEnabled
{
	[self selectTable:@"customers"];

	for (NSString *selectorName in @[@"import:", @"export:", @"exportQueryResult:", @"showUserManager:", @"showTransfer:", @"showInstallExtensionSheet:",
									 @"viewContent:", @"viewQuery:", @"toggleConsole:", @"viewStructure:", @"viewRelations:", @"viewTriggers:", @"viewStatus:"]) {
		XCTAssertTrue([self menuItemEnabled:NSSelectorFromString(selectorName) tag:0], @"%@", selectorName);
	}
}

#pragma mark - Panes

- (void)testEveryTablePaneIsShown
{
	[self selectTable:@"customers"];

	for (NSString *pane in @[SPPostgresPaneStructure, SPPostgresPaneRelations, SPPostgresPaneTriggers, SPPostgresPaneInfo, SPPostgresPaneContent, SPPostgresPaneQuery]) {
		[self.document showPane:pane];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertEqualObjects(self.document.currentPane, pane);
	}
	NSDictionary *actions = @{@"viewStructure:": SPPostgresPaneStructure, @"viewRelations:": SPPostgresPaneRelations,
							  @"viewTriggers:": SPPostgresPaneTriggers, @"viewStatus:": SPPostgresPaneInfo};
	for (NSString *selectorName in actions) {
		[self.document viewQuery:nil];
		[NSApp sendAction:NSSelectorFromString(selectorName) to:self.document from:nil];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertEqualObjects(self.document.currentPane, actions[selectorName], @"%@", selectorName);
	}
}

#pragma mark - Table list

- (void)testSidebarShowsSequencesAndExtensions
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertEqualObjects([sidebar sectionTitles], (@[@"TABLES", @"VIEWS", @"SEQUENCES", @"EXTENSIONS"]));

	NSString *sequence = [[sidebar itemTitlesInSection:@"SEQUENCES"] firstObject];
	if (sequence) {
		XCTAssertTrue([sidebar selectSequenceNamed:sequence]);
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertEqualObjects(sidebar.selectedSequenceName, sequence);
	}
	XCTAssertNotEqual([sidebar menuForRow:-1], nil);
}

- (void)testGearMenuItemsAreEnabled
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

	for (NSString *action in @[@"renameTable:", @"duplicateTable:", @"truncateTables:", @"removeRelations:", @"openRelationInNewTab:",
							   @"openRelationInNewWindow:", @"exportRelations:", @"showCreateSyntax:", @"copyCreateSyntax:"]) {
		XCTAssertEqualObjects(enabled[action], @YES, @"%@", action);
	}
}

- (void)testQueryExportResultIsEnabled
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
	XCTAssertTrue([csv isEnabled]);
}

@end
