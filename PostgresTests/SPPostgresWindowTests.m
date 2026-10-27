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
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	id oldLogging = [prefs objectForKey:@"ConsoleEnableLogging"];
	id oldInterface = [prefs objectForKey:@"ConsoleEnableInterfaceLogging"];
	[prefs setBool:YES forKey:@"ConsoleEnableLogging"];
	[prefs setBool:YES forKey:@"ConsoleEnableInterfaceLogging"];

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

	if (oldLogging) [prefs setObject:oldLogging forKey:@"ConsoleEnableLogging"]; else [prefs removeObjectForKey:@"ConsoleEnableLogging"];
	if (oldInterface) [prefs setObject:oldInterface forKey:@"ConsoleEnableInterfaceLogging"]; else [prefs removeObjectForKey:@"ConsoleEnableInterfaceLogging"];
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

@end
