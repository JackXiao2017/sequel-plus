#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestPrefsGuard.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static const NSUInteger SPPostgresDocumentTestPort = 55418;

// Not in the public headers
@interface SPPostgresDocument (SPPostgresDocumentTestsActions)
- (void)refreshDatabases:(id)sender;
- (void)toggleConsole:(id)sender;
@end

@interface SPWindowController (SPPostgresDocumentTests)
- (IBAction)showServerVariables:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

@interface NSObject (SPPostgresDocumentTestsColors)
- (NSColor *)colorForIndex:(NSInteger)colorIndex;
@end

@interface SPPostgresDocumentTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *connection;
@property (strong) SPPostgresFavorite *favorite;
@end

@implementation SPPostgresDocumentTests

+ (void)setUp
{
	[super setUp];
	[SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:SPPostgresDocumentTestPort];
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

/// A connected connector for `favorite`, or nil (with a failure).
- (SPPostgresConnector *)connectorForFavorite:(SPPostgresFavorite *)favorite sshPassword:(NSString *)sshPassword connection:(PGPostgresConnection * __autoreleasing *)outConnection
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:sshPassword parentWindow:nil];
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
	*outConnection = connection;
	return connector;
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 test";
	favorite.colorIndex = 2;
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPPostgresDocumentTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	self.favorite = favorite;

	// As -[SPAppController newWindow] does. The window's delegate is deliberately not set: its
	// -windowWillClose: autoreleases the controller, which this (ARC) test owns.
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);

	// The document takes a connected connection and the connector that owns it
	PGPostgresConnection *connection = nil;
	SPPostgresConnector *connector = [self connectorForFavorite:favorite sshPassword:nil connection:&connection];
	self.connection = connection;

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertEqual([self.controller selectedDocument], self.document);
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];

	// Close every tab the way the tab bar does, so documents get -parentTabDidClose
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];

	// A MySQL tab's filter editor resizes itself 0.2 s after it is built (SPRuleFilterController -_resize);
	// let that run while the MySQL document is still alive, or it messages freed objects in the next test.
	if ([tabView numberOfTabViewItems] > 1) [self spinUntil:^BOOL{ return NO; } timeout:0.4];

	for (NSTabViewItem *item in [tabView tabViewItems]) {
		[tabView removeTabViewItem:item];
	}
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	self.connection = nil;
	[super tearDown];
}

- (NSWindow *)window
{
	return [self.controller window];
}

- (NSTabView *)tabView
{
	return [self.controller valueForKey:@"tabView"];
}

#pragma mark - Hosting

- (void)testDocumentIsHostedInTheWindow
{
	XCTAssertEqual(self.document.parentWindowController, self.controller);
	XCTAssertEqual(self.document.parentWindow, [self window]);
	XCTAssertEqual([self.document.parentTabViewItem identifier], self.document);
	XCTAssertNil([self.controller selectedTableDocument], @"MySQL-only code sees no document");

	// The tab's view is the split view (left panel | content), with no tab bar of its own
	NSView *view = [self.document databaseView];
	XCTAssertTrue([view isKindOfClass:[NSSplitView class]], @"%@", view);
	XCTAssertEqual([self.document.parentTabViewItem view], view);
	// The app saves the divider under MySQL's "DBViewSplitter" (one left pane width for both engines);
	// in tests the name is recorded, not set (SPTestPrefsGuard)
	XCTAssertEqualObjects([(NSSplitView *)view sp_requestedAutosaveName], @"DBViewSplitter");
	XCTAssertNil([(NSSplitView *)view autosaveName]);
	XCTAssertNil([(NSSplitView *)view autosaveName]);
	XCTAssertEqual([[view subviews] count], 2u);
	XCTAssertEqual([[view subviews] firstObject], [self.document.sidebar view]);
	NSMutableArray *queue = [NSMutableArray arrayWithObject:view];
	while (queue.count) {
		NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
		XCTAssertFalse([NSStringFromClass([v class]) hasPrefix:@"PSMTabBar"], @"no tab bar inside the tab");
		[queue addObjectsFromArray:v.subviews];
	}
}

/// Split views in tests never save their divider positions into the real preferences (SPTestPrefsGuard).
- (void)testSplitViewAutosaveNeverReachesPreferences
{
	NSString *name = @"SPTestPrefsGuardSplitProbe";
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSArray *keys = @[[@"NSSplitView Subview Frames " stringByAppendingString:name], [@"SPSplitView Lengths " stringByAppendingString:name]];
	for (NSString *key in keys) XCTAssertNil([prefs objectForKey:key]);

	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[window setReleasedWhenClosed:NO];
	NSSplitView *splitView = [[NSClassFromString(@"SPSplitView") alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	[splitView setVertical:YES];
	[splitView addSubview:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 150, 300)]];
	[splitView addSubview:[[NSView alloc] initWithFrame:NSMakeRect(151, 0, 249, 300)]];
	[[window contentView] addSubview:splitView];
	[splitView setAutosaveName:name];
	XCTAssertEqualObjects([splitView sp_requestedAutosaveName], name);
	XCTAssertNil([splitView autosaveName]);

	[splitView adjustSubviews];
	[splitView setPosition:200 ofDividerAtIndex:0];
	[splitView resizeSubviewsWithOldSize:NSMakeSize(380, 300)];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	[splitView removeFromSuperview];
	[window close];

	for (NSString *key in keys) XCTAssertNil([prefs objectForKey:key], @"%@", key);
}

- (void)testTabLabelAndColourComeFromFavorite
{
	NSTabViewItem *item = self.document.parentTabViewItem;
	XCTAssertEqualObjects([item label], @"pg18 test");

	id colors = [NSClassFromString(@"SPFavoriteColorSupport") valueForKey:@"sharedInstance"];
	NSColor *expected = [colors colorForIndex:2];
	XCTAssertNotNil(expected);
	XCTAssertEqualObjects([item color], expected);
}

/// A second tab for the same favorite on another database (not selected).
- (SPPostgresDocument *)addNamesakeOnDatabase:(NSString *)database select:(BOOL)select
{
	SPPostgresFavorite *other = [self.favorite copy];
	other.database = database;
	PGPostgresConnection *connection = nil;
	SPPostgresConnector *connector = [self connectorForFavorite:other sshPassword:nil connection:&connection];
	SPPostgresDocument *document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:other];
	[self.controller addTabDocument:document atIndex:1 select:select];
	return document;
}

- (void)testTabLabelsAddDatabaseForNamesakes
{
	XCTAssertEqualObjects([self.document.parentTabViewItem label], @"pg18 test", @"alone: the favorite name");

	// Added in the background: both labels gain their database
	SPPostgresDocument *second = [self addNamesakeOnDatabase:@"pgkit_nopublic" select:NO];
	XCTAssertEqual([self.controller selectedDocument], self.document);
	XCTAssertEqualObjects([self.document.parentTabViewItem label], @"pg18 test/pgkit_test");
	XCTAssertEqualObjects([second.parentTabViewItem label], @"pg18 test/pgkit_nopublic");

	// A database switch renames that tab
	[self.document switchToDatabase:@"postgres"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.document.parentTabViewItem label] isEqualToString:@"pg18 test/postgres"]; } timeout:20],
				  @"%@", [self.document.parentTabViewItem label]);
	XCTAssertEqualObjects([second.parentTabViewItem label], @"pg18 test/pgkit_nopublic");

	// Closing one leaves the other alone again
	[[self tabView] removeTabViewItem:second.parentTabViewItem];
	XCTAssertEqualObjects([self.document.parentTabViewItem label], @"pg18 test");
}

- (void)testTabLabelsAddDatabaseForSelectedNamesake
{
	SPPostgresDocument *second = [self addNamesakeOnDatabase:@"pgkit_nopublic" select:YES];
	XCTAssertEqual([self.controller selectedDocument], second);
	XCTAssertEqualObjects([self.document.parentTabViewItem label], @"pg18 test/pgkit_test");
	XCTAssertEqualObjects([second.parentTabViewItem label], @"pg18 test/pgkit_nopublic");
}

- (void)testActivationClearsProxyIcon
{
	id mysql = [self.controller addNewConnection];
	XCTAssertEqual([self.controller selectedDocument], mysql);
	[[self window] setRepresentedURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
	XCTAssertNotNil([self window].representedURL);

	[[self tabView] selectTabViewItem:self.document.parentTabViewItem];
	XCTAssertNil([self window].representedURL);
}

- (void)testConsoleMenuItemTitle
{
	NSWindow *console = [[NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"] window];
	[console orderOut:nil];

	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Console" action:@selector(toggleConsole:) keyEquivalent:@""];
	XCTAssertTrue([self.document validateMenuItem:item]);
	XCTAssertEqualObjects(item.title, @"Show Console");
}

- (void)testClosingTabDisconnects
{
	PGPostgresConnection *connection = self.connection;
	XCTAssertTrue(connection.isConnected);
	[[self tabView] removeTabViewItem:self.document.parentTabViewItem];
	XCTAssertTrue([self spinUntil:^BOOL{ return !connection.isConnected; } timeout:2]);
	XCTAssertNil([self.controller selectedDocument]);
}

- (void)testMenuValidationDisablesUnsupportedActions
{
	NSMenuItem *variables = [[NSMenuItem alloc] initWithTitle:@"Server Variables" action:@selector(showServerVariables:) keyEquivalent:@""];
	XCTAssertFalse([self.document validateMenuItem:variables]);
	XCTAssertFalse([self.controller validateMenuItem:variables], @"the window asks the selected Postgres tab");
	XCTAssertFalse([self.controller respondsToSelector:@selector(showServerVariables:)], @"not forwarded to the Postgres tab");

	// The window's own items and the tab's own actions stay enabled
	NSMenuItem *closeTab = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:closeTab]);
	NSMenuItem *newTab = [[NSMenuItem alloc] initWithTitle:@"New Tab" action:@selector(addNewConnection:) keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:newTab]);
	NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh Databases" action:@selector(refreshDatabases:) keyEquivalent:@""];
	XCTAssertTrue([self.document validateMenuItem:refresh]);
}

- (void)testSwitchingTabsSwapsToolbarAndTitle
{
	NSToolbar *postgresToolbar = [self.document toolbar];
	XCTAssertEqual([self window].toolbar, postgresToolbar);

	// A MySQL tab takes the window over...
	id mysql = [self.controller addNewConnection];
	XCTAssertEqual([self.controller selectedDocument], mysql);
	XCTAssertNotEqual([self window].toolbar, postgresToolbar);
	XCTAssertNotEqualObjects([self window].title, [self.document windowTitleString]);

	// ...and selecting the Postgres tab gives it back, keeping the toolbar's visibility
	[[self window].toolbar setVisible:NO];
	[[self tabView] selectTabViewItem:self.document.parentTabViewItem];
	XCTAssertEqual([self.controller selectedDocument], self.document);
	XCTAssertEqual([self window].toolbar, postgresToolbar);
	XCTAssertFalse([postgresToolbar isVisible]);
	XCTAssertEqualObjects([self window].title, [self.document windowTitleString]);
	XCTAssertEqualObjects([self.document.parentTabViewItem label], @"pg18 test");
}

#pragma mark - Toolbar

- (void)testToolbarOrderMatchesSpec
{
	// MySQL's identifiers (the app's constants aren't exported to the test bundle)
	NSString *database = @"DatabaseSelectToolbarItemIdentifier", *history = @"HistoryNavigationToolbarItemIdentifier",
		*console = @"ShowConsoleIdentifier", *structure = @"SwitchToTableStructureToolbarItemIdentifier",
		*content = @"SwitchToTableContentToolbarItemIdentifier", *query = @"SwitchToRunQueryToolbarItemIdentifier",
		*tableInfo = @"SwitchToTableInfoToolbarItemIdentifier", *relations = @"SwitchToTableRelationsToolbarItemIdentifier",
		*triggers = @"SwitchToTableTriggersToolbarItemIdentifier", *users = @"SwitchToUserManagerToolbarItemIdentifier",
		*transfer = @"TransferToolbarItemIdentifier";
	NSArray *expected = @[database, structure, content, relations, triggers, tableInfo, query,
						  NSToolbarFlexibleSpaceItemIdentifier, history, users, transfer, console];
	NSToolbar *toolbar = [self window].toolbar;
	XCTAssertNotNil(toolbar);
	XCTAssertEqual(toolbar, [self.document toolbar]);
	XCTAssertEqualObjects([toolbar identifier], @"TableWindowToolbar");
	XCTAssertEqualObjects([self.document toolbarDefaultItemIdentifiers:toolbar], expected);
	XCTAssertEqualObjects([toolbar.items valueForKey:@"itemIdentifier"], expected);

	// Everything but the database picker, Query and the console is present but disabled (Content until a table is selected)
	NSArray *disabled = @[structure, content, relations, triggers, tableInfo, users, transfer, history];
	for (NSToolbarItem *item in toolbar.items) {
		if ([disabled containsObject:item.itemIdentifier]) {
			BOOL enabled = item.view ? [(NSControl *)item.view isEnabled] && item.isEnabled : [self.document validateToolbarItem:item];
			if ([item.view isKindOfClass:[NSSegmentedControl class]]) {
				NSSegmentedControl *control = (NSSegmentedControl *)item.view;
				enabled = enabled && ([control isEnabledForSegment:0] || [control isEnabledForSegment:1]);
			}
			XCTAssertFalse(enabled, @"%@ should be disabled", item.itemIdentifier);
		}
	}
	NSToolbarItem *queryItem = toolbar.items[[expected indexOfObject:query]];
	XCTAssertTrue([self.document validateToolbarItem:queryItem]);
	NSToolbarItem *consoleItem = toolbar.items.lastObject;
	XCTAssertTrue([self.document validateToolbarItem:consoleItem]);
	XCTAssertNotNil(consoleItem.image);
}

#pragma mark - Title

- (void)testTitleIncludesVersionFavoriteAndDatabase
{
	NSString *title = [self.document windowTitleString];
	XCTAssertTrue([title hasPrefix:@"(PostgreSQL 18."], @"%@", title);
	XCTAssertTrue([title hasSuffix:@") pg18 test/pgkit_test"], @"%@", title);
	XCTAssertNotEqual([title rangeOfString:@"^\\(PostgreSQL 18\\.[0-9]+\\) pg18 test/pgkit_test$" options:NSRegularExpressionSearch].location, NSNotFound,
					  @"version number only, no build suffix: %@", title);
	XCTAssertEqualObjects([self window].title, title);
}

- (void)testTitleIncludesSelectedTable
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertEqualObjects(sidebar.selectedTableName, @"customers");
	XCTAssertTrue([[self.document windowTitleString] hasSuffix:@"/pgkit_test/public.customers"], @"%@", [self.document windowTitleString]);
	XCTAssertEqualObjects([self window].title, [self.document windowTitleString]);
}

#pragma mark - Sidebar

- (void)testSidebarSectionsEndWithExtensions
{
	XCTAssertEqualObjects([self.document.sidebar sectionTitles], (@[@"TABLES", @"VIEWS", @"EXTENSIONS"]));
}

- (void)testSidebarListsTablesViewsAndExtensionsForPublic
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertEqualObjects(sidebar.selectedSchema, @"public");
	XCTAssertTrue([[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"VIEWS"], (@[@"v_customers"]));
	XCTAssertTrue([[sidebar itemTitlesInSection:@"EXTENSIONS"] containsObject:@"pg_trgm"]);

	// The view: schema picker on top of the outline
	NSView *view = [sidebar view];
	XCTAssertNotNil(view);
	NSPopUpButton *popup = nil;
	NSOutlineView *outline = nil;
	NSMutableArray *queue = [NSMutableArray arrayWithObject:view];
	while (queue.count) {
		NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
		if ([v isKindOfClass:[NSPopUpButton class]]) popup = (NSPopUpButton *)v;
		if ([v isKindOfClass:[NSOutlineView class]]) outline = (NSOutlineView *)v;
		[queue addObjectsFromArray:v.subviews];
	}
	XCTAssertNotNil(popup);
	XCTAssertNotNil(outline);
	XCTAssertEqualObjects(popup.titleOfSelectedItem, @"public");
	XCTAssertTrue([popup.itemTitles containsObject:@"Sales Data"]);
	XCTAssertGreaterThan(NSMinY([popup convertRect:popup.bounds toView:nil]), NSMaxY([outline.enclosingScrollView convertRect:outline.enclosingScrollView.bounds toView:nil]) - 1);

	// Section rows appear in order with Extensions last
	NSMutableArray *groupTitles = [NSMutableArray array];
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		if ([outline.delegate outlineView:outline isGroupItem:item]) [groupTitles addObject:[item valueForKey:@"title"]];
	}
	XCTAssertEqualObjects(groupTitles, (@[@"TABLES", @"VIEWS", @"EXTENSIONS"]));
	id lastItem = [outline itemAtRow:outline.numberOfRows - 1];
	XCTAssertTrue([[sidebar itemTitlesInSection:@"EXTENSIONS"] containsObject:[lastItem valueForKey:@"title"]]);
}

- (void)testSwitchingSchemaReloadsTables
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	[sidebar reloadSchema:@"Sales Data"];
	XCTAssertEqualObjects(sidebar.selectedSchema, @"Sales Data");
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"TABLES"], (@[@"Orders 2026"]));
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"VIEWS"], (@[]));
	XCTAssertTrue([[sidebar itemTitlesInSection:@"EXTENSIONS"] containsObject:@"pg_trgm"], @"extensions are per database");

	XCTAssertTrue([sidebar selectTableNamed:@"Orders 2026"]);
	XCTAssertTrue([[self.document windowTitleString] hasSuffix:@"/pgkit_test/Sales Data.Orders 2026"], @"%@", [self.document windowTitleString]);
	XCTAssertEqualObjects([self window].title, [self.document windowTitleString]);
}

#pragma mark - Console

- (void)testConsoleLoggerForwardsQueries
{
	// The console reads these with -boolForKey:, so the volatile argument domain is enough: nothing is
	// written to the app's saved preferences, and the teardown block restores the domain even on failure.
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	domain[@"ConsoleEnableLogging"] = @YES;
	domain[@"ConsoleEnableInterfaceLogging"] = @YES;
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];
	XCTAssertTrue([prefs boolForKey:@"ConsoleEnableLogging"]);
	XCTAssertTrue([prefs boolForKey:@"ConsoleEnableInterfaceLogging"]);

	XCTAssertNotNil([self.connection execute:@"SELECT 4242"]);

	// Test-only read of the console's existing storage (no public accessor)
	id queryController = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSArray *messages = [queryController valueForKey:@"messagesFullSet"];
	id found = nil;
	for (id message in messages) {
		if ([[message valueForKey:@"message"] hasPrefix:@"SELECT 4242"]) found = message;
	}
	XCTAssertNotNil(found);
	XCTAssertEqualObjects([found valueForKey:@"messageConnection"], @"pg18 test");
	XCTAssertEqualObjects([found valueForKey:@"messageDatabase"], @"pgkit_test");
}

#pragma mark - Database switching

- (void)testSwitchingDatabaseReconnects
{
	PGPostgresConnection *oldConnection = self.connection;
	[self.document switchToDatabase:@"pgkit_nopublic"];
	XCTAssertTrue(self.document.isProcessing, @"the tab shows progress while the new session connects");

	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.document windowTitleString] hasSuffix:@"/pgkit_nopublic"]; } timeout:20],
				  @"%@ (sheet: %@)", [self.document windowTitleString], [self window].attachedSheet);
	XCTAssertFalse(self.document.isProcessing);
	XCTAssertTrue([self spinUntil:^BOOL{ return !oldConnection.isConnected; } timeout:5], @"the previous connection is closed");
	XCTAssertFalse([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
	XCTAssertNotEqualObjects(self.document.sidebar.selectedSchema, @"public");
	XCTAssertEqualObjects([self window].title, [self.document windowTitleString]);
	XCTAssertEqualObjects(self.document.favorite.database, @"pgkit_nopublic");
	XCTAssertNotEqual(self.document.connection, oldConnection);
	XCTAssertEqualObjects([self.document.parentTabViewItem label], @"pg18 test");
}

- (void)testFailedDatabaseSwitchKeepsConnectionAndShowsSheet
{
	[self.controller showWindow:nil];
	[self.document switchToDatabase:@"sp_no_such_database"];

	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet != nil; } timeout:20]);
	XCTAssertFalse(self.document.isProcessing);
	XCTAssertTrue(self.connection.isConnected);
	XCTAssertEqual(self.document.connection, self.connection);
	XCTAssertTrue([[self.document windowTitleString] hasSuffix:@"/pgkit_test"]);
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
}

#pragma mark - Catalog errors

- (NSPopUpButton *)databasePopup
{
	for (NSToolbarItem *item in [self.document toolbar].items) {
		if ([item.itemIdentifier isEqualToString:@"DatabaseSelectToolbarItemIdentifier"]) return (NSPopUpButton *)item.view;
	}
	return nil;
}

/// Collects what the tab would show as sheets.
- (NSMutableArray<NSAlert *> *)captureAlerts
{
	NSMutableArray<NSAlert *> *alerts = [NSMutableArray array];
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	return alerts;
}

/// The connection goes away under the tab (as after a server restart or an idle-killed tunnel):
/// reloading reports the loss once per reload and keeps the lists that were shown.
- (void)testCatalogFailuresAfterDisconnectAreReportedAndListsKept
{
	NSMutableArray<NSAlert *> *alerts = [self captureAlerts];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSArray *tables = [sidebar itemTitlesInSection:@"TABLES"];
	NSArray *views = [sidebar itemTitlesInSection:@"VIEWS"];
	NSArray *extensions = [sidebar itemTitlesInSection:@"EXTENSIONS"];
	NSArray *databases = [[self databasePopup] itemTitles];
	XCTAssertTrue([tables containsObject:@"customers"]);
	XCTAssertTrue([databases containsObject:@"pgkit_nopublic"]);
	XCTAssertEqual(alerts.count, 0u);

	[self.connection disconnect];

	// Schema change: tables and views both fail, reported once
	[sidebar reloadSchema:@"public"];
	XCTAssertNotNil(sidebar.lastError);
	XCTAssertEqual(alerts.count, 1u);
	XCTAssertTrue([alerts.lastObject.messageText.lowercaseString containsString:@"lost"], @"%@", alerts.lastObject.messageText);
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"TABLES"], tables, @"lists are kept");
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"VIEWS"], views);
	XCTAssertEqualObjects(sidebar.selectedSchema, @"public");

	// Full sidebar reload (schemas, extensions, tables): once
	[sidebar reloadWithCatalog:[sidebar valueForKey:@"catalog"]];
	XCTAssertEqual(alerts.count, 2u);
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"TABLES"], tables);
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"EXTENSIONS"], extensions);

	// Refresh Databases: reported, and the picker keeps its databases
	[self.document refreshDatabases:nil];
	XCTAssertEqual(alerts.count, 3u);
	XCTAssertTrue([alerts.lastObject.messageText.lowercaseString containsString:@"lost"], @"%@", alerts.lastObject.messageText);
	XCTAssertEqualObjects([[self databasePopup] itemTitles], databases);
	XCTAssertEqualObjects([[self databasePopup] titleOfSelectedItem], @"pgkit_test");
}

/// A backend killed on the server: the next catalog query fails, the connection is then not connected,
/// and the server's reason is included.
- (void)testServerTerminatedConnectionIsReportedAsLost
{
	NSMutableArray<NSAlert *> *alerts = [self captureAlerts];
	NSUInteger pid = [self.connection serverProcessId];

	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresDocumentTestPort];
	NSString *terminate = [NSString stringWithFormat:@"SELECT pg_terminate_backend(%lu)", (unsigned long)pid];
	XCTAssertNotNil([admin execute:terminate]);
	[admin disconnect];

	[self.document.sidebar reloadSchema:@"public"];
	XCTAssertFalse(self.connection.isConnected);
	XCTAssertEqual(alerts.count, 1u);
	NSAlert *alert = alerts.firstObject;
	XCTAssertTrue([alert.messageText.lowercaseString containsString:@"lost"], @"%@", alert.messageText);
	XCTAssertTrue([alert.informativeText containsString:@"terminat"] || [alert.informativeText containsString:@"closed"],
				  @"the server's reason is included: %@", alert.informativeText);
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
}

/// Without a presenter the error is a sheet on the tab's window.
- (void)testCatalogFailureShowsSheetOnWindow
{
	[self.controller showWindow:nil];
	[self.connection disconnect];
	[self.document refreshDatabases:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet != nil; } timeout:5]);
}

/// An error while the tab is in the background waits until the tab is active again.
- (void)testCatalogFailureInBackgroundTabWaitsUntilActive
{
	[self.controller showWindow:nil];
	[self.controller addNewConnection];
	XCTAssertNotEqual([self.controller selectedDocument], self.document);

	[self.connection disconnect];
	[self.document refreshDatabases:nil];
	(void)[self spinUntil:^BOOL{ return NO; } timeout:0.3];
	XCTAssertNil([self window].attachedSheet);

	[[self tabView] selectTabViewItem:self.document.parentTabViewItem];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet != nil; } timeout:5]);
}

#pragma mark - Database switch passwords

/// The switch connector gets the passwords the tab's connector was given, so an SSH favorite
/// isn't asked for its SSH password again.
- (void)testDatabaseSwitchReusesPasswords
{
	PGPostgresConnection *connection = nil;
	SPPostgresConnector *connector = [self connectorForFavorite:self.favorite sshPassword:@"ssh secret" connection:&connection];
	XCTAssertEqualObjects(connector.password, @"pgkit");
	XCTAssertEqualObjects(connector.sshPassword, @"ssh secret");

	SPPostgresDocument *document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:self.favorite];
	[self.controller addTabDocument:document atIndex:1 select:YES];

	[document switchToDatabase:@"pgkit_nopublic"];
	SPPostgresConnector *pending = [document valueForKey:@"pendingConnector"];
	XCTAssertNotNil(pending);
	XCTAssertEqualObjects(pending.password, @"pgkit");
	XCTAssertEqualObjects(pending.sshPassword, @"ssh secret");

	XCTAssertTrue([self spinUntil:^BOOL{ return [[document windowTitleString] hasSuffix:@"/pgkit_nopublic"]; } timeout:20]);

	// ...and the next switch still has them
	[document switchToDatabase:@"pgkit_test"];
	pending = [document valueForKey:@"pendingConnector"];
	XCTAssertEqualObjects(pending.password, @"pgkit");
	XCTAssertEqualObjects(pending.sshPassword, @"ssh secret");
	XCTAssertTrue([self spinUntil:^BOOL{ return [[document windowTitleString] hasSuffix:@"/pgkit_test"]; } timeout:20]);
}

@end
