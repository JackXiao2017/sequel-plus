#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresWindowController.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConsoleLogger.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

// The catalog fixture loader lives in SPPostgresCatalogTests (same test bundle); reuse it rather than duplicating SQL.
@interface SPPostgresCatalogTests : XCTestCase
+ (void)loadFixtureOnPort:(NSUInteger)port;
@end

static const NSUInteger SPPostgresWindowTestPort = 55418;

// The "Refresh Databases" menu item's action (not in the public header)
@interface SPPostgresWindowController (SPPostgresWindowTestsActions)
- (void)refreshDatabases:(id)sender;
@end

@interface SPPostgresWindowTests : XCTestCase
@property (strong) SPPostgresWindowController *controller;
@property (strong) PGPostgresConnection *connection;
@property (strong) SPPostgresFavorite *favorite;
@end

@implementation SPPostgresWindowTests

+ (void)setUp
{
	[super setUp];
	[SPPostgresCatalogTests loadFixtureOnPort:SPPostgresWindowTestPort];
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

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 test";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPPostgresWindowTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	self.favorite = favorite;

	// The window takes a connected connection and the connector that owns it
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
	self.controller = [[SPPostgresWindowController alloc] initWithConnection:connection connector:connector favorite:favorite];
	XCTAssertNotNil(self.controller.window);
}

- (void)tearDown
{
	NSWindow *window = self.controller.window;
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	[self.controller close];
	self.controller = nil;
	self.connection = nil;
	[super tearDown];
}

#pragma mark - Toolbar

- (void)testToolbarOrderMatchesSpec
{
	NSArray *expected = @[SPPostgresToolbarDatabase, SPPostgresToolbarStructure, SPPostgresToolbarContent,
						  SPPostgresToolbarRelations, SPPostgresToolbarTriggers, SPPostgresToolbarTableInfo,
						  SPPostgresToolbarQuery, NSToolbarFlexibleSpaceItemIdentifier,
						  SPPostgresToolbarUsers, SPPostgresToolbarTransfer, SPPostgresToolbarHistory, SPPostgresToolbarConsole];
	NSToolbar *toolbar = self.controller.window.toolbar;
	XCTAssertNotNil(toolbar);
	XCTAssertEqualObjects([self.controller toolbarDefaultItemIdentifiers:toolbar], expected);
	XCTAssertEqualObjects([toolbar.items valueForKey:@"itemIdentifier"], expected);

	// Stage 1: everything but the database picker and the console is present but disabled
	NSArray *disabled = @[SPPostgresToolbarStructure, SPPostgresToolbarContent, SPPostgresToolbarRelations,
						  SPPostgresToolbarTriggers, SPPostgresToolbarTableInfo, SPPostgresToolbarQuery,
						  SPPostgresToolbarUsers, SPPostgresToolbarTransfer, SPPostgresToolbarHistory];
	for (NSToolbarItem *item in toolbar.items) {
		if ([disabled containsObject:item.itemIdentifier]) {
			BOOL enabled = item.view ? [(NSControl *)item.view isEnabled] && item.isEnabled : [self.controller validateToolbarItem:item];
			XCTAssertFalse(enabled, @"%@ should be disabled in stage 1", item.itemIdentifier);
		}
	}
	NSToolbarItem *console = toolbar.items.lastObject;
	XCTAssertTrue([self.controller validateToolbarItem:console]);
	XCTAssertNotNil(console.image);
}

#pragma mark - Title

- (void)testTitleIncludesVersionFavoriteAndDatabase
{
	NSString *title = [self.controller windowTitleString];
	XCTAssertTrue([title hasPrefix:@"(PostgreSQL 18."], @"%@", title);
	XCTAssertTrue([title hasSuffix:@") pg18 test/pgkit_test"], @"%@", title);
	XCTAssertNotEqual([title rangeOfString:@"^\\(PostgreSQL 18\\.[0-9]+\\) pg18 test/pgkit_test$" options:NSRegularExpressionSearch].location, NSNotFound,
					  @"version number only, no build suffix: %@", title);
	XCTAssertEqualObjects(self.controller.window.title, title);
}

- (void)testTitleIncludesSelectedTable
{
	SPPostgresSidebarController *sidebar = self.controller.sidebar;
	XCTAssertTrue([sidebar selectTableNamed:@"customers"]);
	XCTAssertEqualObjects(sidebar.selectedTableName, @"customers");
	XCTAssertTrue([[self.controller windowTitleString] hasSuffix:@"/pgkit_test/public.customers"], @"%@", [self.controller windowTitleString]);
	XCTAssertEqualObjects(self.controller.window.title, [self.controller windowTitleString]);
}

#pragma mark - Sidebar

- (void)testSidebarSectionsEndWithExtensions
{
	XCTAssertEqualObjects([self.controller.sidebar sectionTitles], (@[@"TABLES", @"VIEWS", @"EXTENSIONS"]));
}

- (void)testSidebarListsTablesViewsAndExtensionsForPublic
{
	SPPostgresSidebarController *sidebar = self.controller.sidebar;
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
	SPPostgresSidebarController *sidebar = self.controller.sidebar;
	[sidebar reloadSchema:@"Sales Data"];
	XCTAssertEqualObjects(sidebar.selectedSchema, @"Sales Data");
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"TABLES"], (@[@"Orders 2026"]));
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"VIEWS"], (@[]));
	XCTAssertTrue([[sidebar itemTitlesInSection:@"EXTENSIONS"] containsObject:@"pg_trgm"], @"extensions are per database");

	XCTAssertTrue([sidebar selectTableNamed:@"Orders 2026"]);
	XCTAssertTrue([[self.controller windowTitleString] hasSuffix:@"/pgkit_test/Sales Data.Orders 2026"], @"%@", [self.controller windowTitleString]);
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

	XCTAssertNotNil([self.connection execute:@"SELECT 42"]);

	// Test-only read of the console's existing storage (no public accessor; ruling R3)
	id queryController = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSArray *messages = [queryController valueForKey:@"messagesFullSet"];
	id found = nil;
	for (id message in messages) {
		if ([[message valueForKey:@"message"] hasPrefix:@"SELECT 42"]) found = message;
	}
	XCTAssertNotNil(found);
	XCTAssertEqualObjects([found valueForKey:@"messageConnection"], @"pg18 test");
	XCTAssertEqualObjects([found valueForKey:@"messageDatabase"], @"pgkit_test");
}

#pragma mark - Database switching and teardown

- (void)testSwitchingDatabaseReconnects
{
	PGPostgresConnection *oldConnection = self.connection;
	[self.controller switchToDatabase:@"pgkit_nopublic"];

	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.controller windowTitleString] hasSuffix:@"/pgkit_nopublic"]; } timeout:20],
				  @"%@ (sheet: %@)", [self.controller windowTitleString], self.controller.window.attachedSheet);
	XCTAssertTrue([self spinUntil:^BOOL{ return !oldConnection.isConnected; } timeout:5], @"the previous connection is closed");
	XCTAssertFalse([[self.controller.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
	XCTAssertNotEqualObjects(self.controller.sidebar.selectedSchema, @"public");
	XCTAssertEqualObjects(self.controller.window.title, [self.controller windowTitleString]);
}

- (void)testFailedDatabaseSwitchKeepsConnectionAndShowsSheet
{
	[self.controller showWindow:nil];
	[self.controller switchToDatabase:@"sp_no_such_database"];

	XCTAssertTrue([self spinUntil:^BOOL{ return self.controller.window.attachedSheet != nil; } timeout:20]);
	XCTAssertTrue(self.connection.isConnected);
	XCTAssertTrue([[self.controller windowTitleString] hasSuffix:@"/pgkit_test"]);
	XCTAssertTrue([[self.controller.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
}

- (void)testClosingWindowDisconnects
{
	[self.controller showWindow:nil];
	[self.controller close];
	XCTAssertTrue([self spinUntil:^BOOL{ return !self.connection.isConnected; } timeout:5]);
}

#pragma mark - Catalog errors

- (NSPopUpButton *)databasePopup
{
	for (NSToolbarItem *item in self.controller.window.toolbar.items) {
		if ([item.itemIdentifier isEqualToString:SPPostgresToolbarDatabase]) return (NSPopUpButton *)item.view;
	}
	return nil;
}

/// Collects what the window would show as sheets.
- (NSMutableArray<NSAlert *> *)captureAlerts
{
	NSMutableArray<NSAlert *> *alerts = [NSMutableArray array];
	self.controller.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	return alerts;
}

/// The connection goes away under the window (as after a server restart or an idle-killed tunnel):
/// reloading reports the loss once per reload and keeps the lists that were shown.
- (void)testCatalogFailuresAfterDisconnectAreReportedAndListsKept
{
	NSMutableArray<NSAlert *> *alerts = [self captureAlerts];
	SPPostgresSidebarController *sidebar = self.controller.sidebar;
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
	[self.controller refreshDatabases:nil];
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

	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresWindowTestPort];
	NSString *terminate = [NSString stringWithFormat:@"SELECT pg_terminate_backend(%lu)", (unsigned long)pid];
	XCTAssertNotNil([admin execute:terminate]);
	[admin disconnect];

	[self.controller.sidebar reloadSchema:@"public"];
	XCTAssertFalse(self.connection.isConnected);
	XCTAssertEqual(alerts.count, 1u);
	NSAlert *alert = alerts.firstObject;
	XCTAssertTrue([alert.messageText.lowercaseString containsString:@"lost"], @"%@", alert.messageText);
	XCTAssertTrue([alert.informativeText containsString:@"terminat"] || [alert.informativeText containsString:@"closed"],
				  @"the server's reason is included: %@", alert.informativeText);
	XCTAssertTrue([[self.controller.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"customers"]);
}

/// Without a presenter the error is a sheet on the PostgreSQL window.
- (void)testCatalogFailureShowsSheetOnWindow
{
	[self.controller showWindow:nil];
	[self.connection disconnect];
	[self.controller refreshDatabases:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.controller.window.attachedSheet != nil; } timeout:5]);
}

#pragma mark - Database switch passwords

/// The switch connector gets the passwords the window's connector was given, so an SSH favorite
/// isn't asked for its SSH password again.
- (void)testDatabaseSwitchReusesPasswords
{
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:self.favorite password:@"pgkit" sshPassword:@"ssh secret" parentWindow:nil];
	XCTAssertEqualObjects(connector.password, @"pgkit");
	XCTAssertEqualObjects(connector.sshPassword, @"ssh secret");

	__block PGPostgresConnection *connection = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) { connection = theConnection; done = YES; }];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection);

	SPPostgresWindowController *controller = [[SPPostgresWindowController alloc] initWithConnection:connection connector:connector favorite:self.favorite];
	[self addTeardownBlock:^{ [controller close]; }];

	[controller switchToDatabase:@"pgkit_nopublic"];
	SPPostgresConnector *pending = [controller valueForKey:@"pendingConnector"];
	XCTAssertNotNil(pending);
	XCTAssertEqualObjects(pending.password, @"pgkit");
	XCTAssertEqualObjects(pending.sshPassword, @"ssh secret");

	XCTAssertTrue([self spinUntil:^BOOL{ return [[controller windowTitleString] hasSuffix:@"/pgkit_nopublic"]; } timeout:20]);

	// ...and the next switch still has them
	[controller switchToDatabase:@"pgkit_test"];
	pending = [controller valueForKey:@"pendingConnector"];
	XCTAssertEqualObjects(pending.password, @"pgkit");
	XCTAssertEqualObjects(pending.sshPassword, @"ssh secret");
	XCTAssertTrue([self spinUntil:^BOOL{ return [[controller windowTitleString] hasSuffix:@"/pgkit_test"]; } timeout:20]);
}

@end
