#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestPrefsGuard.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresHistory.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static const NSUInteger SPPostgresHistoryTestPort = 55418;

static NSDictionary *SPHistoryEntry(NSString *db, NSString *schema, NSString *table, NSString *pane)
{
	NSMutableDictionary *entry = [NSMutableDictionary dictionary];
	entry[@"database"] = db;
	entry[@"schema"] = schema;
	if (table) entry[@"table"] = table;
	entry[@"pane"] = pane;
	return entry;
}

#pragma mark - The model

@interface SPPostgresHistoryTests : XCTestCase
@end

@implementation SPPostgresHistoryTests

- (void)testBackForwardOrder
{
	SPPostgresHistory *history = [[SPPostgresHistory alloc] init];
	XCTAssertFalse(history.canGoBack);
	XCTAssertFalse(history.canGoForward);
	XCTAssertNil([history goBack]);
	XCTAssertNil([history goForward]);

	[history recordDatabase:@"db" schema:@"public" table:@"a" pane:@"content"];
	XCTAssertFalse(history.canGoBack, @"one entry: nowhere to go back to");
	[history recordDatabase:@"db" schema:@"public" table:@"b" pane:@"content"];
	[history recordDatabase:@"db" schema:@"public" table:@"b" pane:@"query"];
	[history recordDatabase:@"db2" schema:@"app" table:nil pane:@"query"];

	XCTAssertTrue(history.canGoBack);
	XCTAssertFalse(history.canGoForward);

	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"public", @"b", @"query"));
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"public", @"b", @"content"));
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"public", @"a", @"content"));
	XCTAssertFalse(history.canGoBack);
	XCTAssertTrue(history.canGoForward);
	XCTAssertNil([history goBack]);

	XCTAssertEqualObjects([history goForward], SPHistoryEntry(@"db", @"public", @"b", @"content"));
	XCTAssertEqualObjects([history goForward], SPHistoryEntry(@"db", @"public", @"b", @"query"));
	XCTAssertEqualObjects([history goForward], SPHistoryEntry(@"db2", @"app", nil, @"query"));
	XCTAssertFalse(history.canGoForward);
	XCTAssertNil([history goForward]);
	XCTAssertTrue(history.canGoBack);
}

- (void)testRecordingAfterBackTruncatesForward
{
	SPPostgresHistory *history = [[SPPostgresHistory alloc] init];
	[history recordDatabase:@"db" schema:@"s" table:@"a" pane:@"content"];
	[history recordDatabase:@"db" schema:@"s" table:@"b" pane:@"content"];
	[history recordDatabase:@"db" schema:@"s" table:@"c" pane:@"content"];

	[history goBack];
	[history goBack];
	XCTAssertTrue(history.canGoForward);

	[history recordDatabase:@"db" schema:@"s" table:@"d" pane:@"content"];
	XCTAssertFalse(history.canGoForward, @"b and c are gone");
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"s", @"a", @"content"));
	XCTAssertFalse(history.canGoBack);
	XCTAssertEqualObjects([history goForward], SPHistoryEntry(@"db", @"s", @"d", @"content"));
	XCTAssertFalse(history.canGoForward);
}

- (void)testDuplicatesIgnored
{
	SPPostgresHistory *history = [[SPPostgresHistory alloc] init];
	[history recordDatabase:@"db" schema:@"s" table:@"a" pane:@"content"];
	[history recordDatabase:@"db" schema:@"s" table:@"a" pane:@"content"];
	XCTAssertFalse(history.canGoBack, @"a repeat of the current entry is not recorded");

	[history recordDatabase:@"db" schema:@"s" table:nil pane:@"content"];
	[history recordDatabase:@"db" schema:@"s" table:nil pane:@"content"];
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"s", @"a", @"content"));
	XCTAssertFalse(history.canGoBack);

	// Recording the entry we went back to (as restoring it does) keeps the forward entries
	[history recordDatabase:@"db" schema:@"s" table:@"a" pane:@"content"];
	XCTAssertTrue(history.canGoForward);

	// Non-consecutive repeats are kept
	[history goForward];
	[history recordDatabase:@"db" schema:@"s" table:@"a" pane:@"content"];
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"s", nil, @"content"));
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"s", @"a", @"content"));
}

- (void)testRenameRewritesMatchingEntriesOnly
{
	SPPostgresHistory *history = [[SPPostgresHistory alloc] init];
	[history recordDatabase:@"db" schema:@"public" table:@"seq" pane:@"sequence"];
	[history recordDatabase:@"db" schema:@"other" table:@"seq" pane:@"sequence"];
	[history recordDatabase:@"db2" schema:@"public" table:@"seq" pane:@"sequence"];
	[history recordDatabase:@"db" schema:@"public" table:@"t" pane:@"content"];

	[history renameTable:@"seq" to:@"seq2" inDatabase:@"db" schema:@"public"];
	XCTAssertEqualObjects(history.currentEntry, SPHistoryEntry(@"db", @"public", @"t", @"content"));
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db2", @"public", @"seq", @"sequence"), @"another database");
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"other", @"seq", @"sequence"), @"another schema");
	XCTAssertEqualObjects([history goBack], SPHistoryEntry(@"db", @"public", @"seq2", @"sequence"));

	// The new name's entry is the current one: recording it again adds nothing
	[history recordDatabase:@"db" schema:@"public" table:@"seq2" pane:@"sequence"];
	XCTAssertTrue(history.canGoForward);
}

- (void)testHistoryIsCappedAtFiftyEntries
{
	SPPostgresHistory *history = [[SPPostgresHistory alloc] init];
	for (NSUInteger i = 0; i < 60; i++) {
		[history recordDatabase:@"db" schema:@"s" table:[NSString stringWithFormat:@"t%lu", (unsigned long)i] pane:@"content"];
	}
	NSUInteger backs = 0;
	NSDictionary *last = nil;
	while (history.canGoBack) { last = [history goBack]; backs++; }
	XCTAssertEqual(backs, 49u, @"as MySQL's, the oldest entries go beyond fifty");
	XCTAssertEqualObjects(last[@"table"], @"t10");
}

@end

#pragma mark - In a Postgres tab

@interface SPPostgresDocument (SPPostgresHistoryTestsActions)
- (IBAction)backForwardInHistory:(id)sender;
- (IBAction)historyControlClicked:(NSSegmentedControl *)sender;
@end

@interface SPPostgresDocumentHistoryTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@end

@implementation SPPostgresDocumentHistoryTests

+ (void)setUp
{
	[super setUp];
	[SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:SPPostgresHistoryTestPort];
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
	favorite.name = @"pg18 history";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPPostgresHistoryTestPort;
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
	NSMutableArray<NSAlert *> *alerts = [NSMutableArray array];
	self.alerts = alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	if ([tabView numberOfTabViewItems] > 1) [self spinUntil:^BOOL{ return NO; } timeout:0.4];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[super tearDown];
}

- (NSSegmentedControl *)historyControl
{
	for (NSToolbarItem *item in [self.document toolbar].items) {
		if ([item.itemIdentifier isEqualToString:@"HistoryNavigationToolbarItemIdentifier"]) return (NSSegmentedControl *)item.view;
	}
	XCTFail(@"no History item in the toolbar");
	return nil;
}

- (BOOL)waitForTitleSuffix:(NSString *)suffix
{
	return [self spinUntil:^BOOL{ return [[self.document windowTitleString] hasSuffix:suffix] && !self.document.isProcessing; } timeout:20];
}

- (NSMenuItem *)historyMenuItemWithTag:(NSInteger)tag
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	item.tag = tag;
	return item;
}

/// A click on a segment of the (momentary) History control.
- (void)clickSegment:(NSInteger)segment of:(NSSegmentedControl *)control
{
	control.trackingMode = NSSegmentSwitchTrackingSelectOne;
	control.selectedSegment = segment;
	[self.document historyControlClicked:control];
	control.trackingMode = NSSegmentSwitchTrackingMomentary;
}

- (void)testRestoreAcrossDatabaseSwitches
{
	SPPostgresDocument *document = self.document;
	NSSegmentedControl *control = [self historyControl];
	XCTAssertNotNil(control);
	XCTAssertFalse([control isEnabledForSegment:0]);
	XCTAssertFalse([control isEnabledForSegment:1]);

	// pgkit_test public.customers (Content), then pgkit_nopublic app.items (Query)
	XCTAssertTrue([document.sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([control isEnabledForSegment:0], @"back is enabled once there is somewhere to go back to");
	XCTAssertFalse([control isEnabledForSegment:1]);

	[document switchToDatabase:@"pgkit_nopublic"];
	XCTAssertTrue([self waitForTitleSuffix:@"/pgkit_nopublic"], @"%@ %@", [document windowTitleString], self.alerts);
	XCTAssertTrue([document.sidebar selectTableNamed:@"items"]);
	[document viewQuery:nil];
	XCTAssertTrue([[document windowTitleString] hasSuffix:@"/pgkit_nopublic/app.items"]);

	// The menu items validate on the document as MySQL's do
	XCTAssertTrue([document validateMenuItem:[self historyMenuItemWithTag:0]]);
	XCTAssertFalse([document validateMenuItem:[self historyMenuItemWithTag:1]]);

	// Back: the Content view of app.items (same database)
	[document backForwardInHistory:[self historyMenuItemWithTag:0]];
	XCTAssertEqualObjects([document toolbar].selectedItemIdentifier, @"SwitchToTableContentToolbarItemIdentifier");
	XCTAssertEqualObjects(document.sidebar.selectedTableName, @"items");
	XCTAssertTrue([control isEnabledForSegment:1]);

	// Back twice more, through the toolbar control: app without a table, then the other database
	[self clickSegment:0 of:control];
	XCTAssertNil(document.sidebar.selectedTableName);
	PGPostgresConnection *nopublicConnection = document.connection;
	[self clickSegment:0 of:control];
	XCTAssertFalse([control isEnabledForSegment:0], @"history is disabled while the database switch connects");
	XCTAssertFalse([control isEnabledForSegment:1]);
	XCTAssertTrue([self waitForTitleSuffix:@"/pgkit_test/public.customers"], @"%@ %@", [document windowTitleString], self.alerts);
	XCTAssertNotEqual(document.connection, nopublicConnection);
	XCTAssertEqualObjects(document.sidebar.selectedSchema, @"public");
	XCTAssertEqualObjects(document.sidebar.selectedTableName, @"customers");
	XCTAssertEqualObjects([document toolbar].selectedItemIdentifier, @"SwitchToTableContentToolbarItemIdentifier");
	XCTAssertTrue([control isEnabledForSegment:0]);
	XCTAssertTrue([control isEnabledForSegment:1]);
	XCTAssertEqual(self.alerts.count, 0u);

	// Forward to the end: back in pgkit_nopublic, app.items, Query view
	[document backForwardInHistory:[self historyMenuItemWithTag:1]];
	XCTAssertTrue([self waitForTitleSuffix:@"/pgkit_nopublic"], @"%@ %@", [document windowTitleString], self.alerts);
	[document backForwardInHistory:[self historyMenuItemWithTag:1]];
	[document backForwardInHistory:[self historyMenuItemWithTag:1]];
	[document backForwardInHistory:[self historyMenuItemWithTag:1]];
	XCTAssertTrue([[document windowTitleString] hasSuffix:@"/pgkit_nopublic/app.items"], @"%@", [document windowTitleString]);
	XCTAssertEqualObjects([document toolbar].selectedItemIdentifier, @"SwitchToRunQueryToolbarItemIdentifier");
	XCTAssertFalse([control isEnabledForSegment:1]);
	XCTAssertTrue([control isEnabledForSegment:0]);

	// Restoring didn't add entries: four steps back to the first one
	NSUInteger backs = 0;
	while (document.history.canGoBack) { [document.history goBack]; backs++; }
	XCTAssertEqual(backs, 4u);
}

- (void)testFailedRestoreKeepsPositionAndConnection
{
	SPPostgresDocument *document = self.document;
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPPostgresHistoryTestPort];
	[admin execute:@"DROP DATABASE IF EXISTS sp_history_gone WITH (FORCE)"];
	XCTAssertNotNil([admin execute:@"CREATE DATABASE sp_history_gone"], @"%@", admin.lastError.errorPrimaryMessage);

	XCTAssertTrue([document.sidebar selectTableNamed:@"customers"]);
	[document switchToDatabase:@"sp_history_gone"];
	XCTAssertTrue([self waitForTitleSuffix:@"/sp_history_gone"], @"%@", self.alerts);
	[document backForwardInHistory:[self historyMenuItemWithTag:0]];
	XCTAssertTrue([self waitForTitleSuffix:@"/pgkit_test/public.customers"], @"%@", self.alerts);

	XCTAssertNotNil([admin execute:@"DROP DATABASE sp_history_gone WITH (FORCE)"], @"%@", admin.lastError.errorPrimaryMessage);
	PGPostgresConnection *kept = document.connection;
	NSSegmentedControl *control = [self historyControl];

	[document backForwardInHistory:[self historyMenuItemWithTag:1]];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.alerts.count > 0 && !document.isProcessing; } timeout:20]);
	XCTAssertEqual(document.connection, kept);
	XCTAssertTrue([[document windowTitleString] hasSuffix:@"/pgkit_test/public.customers"]);
	XCTAssertTrue(document.history.canGoForward, @"the failed entry can be tried again");
	XCTAssertTrue([control isEnabledForSegment:1]);
	XCTAssertTrue([control isEnabledForSegment:0]);
	[admin disconnect];
}

- (void)testHistoryMoveToAnotherDatabaseConfirmsOpenTransaction
{
	SPPostgresDocument *document = self.document;
	XCTAssertTrue([document.sidebar selectTableNamed:@"customers"]);
	[document switchToDatabase:@"pgkit_nopublic"];
	XCTAssertTrue([self waitForTitleSuffix:@"/pgkit_nopublic"], @"%@", self.alerts);

	__block BOOL answer = NO;
	NSMutableArray<NSAlert *> *asked = [NSMutableArray array];
	document.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) {
		[asked addObject:alert];
		completion(answer);
	};
	PGPostgresConnection *kept = document.connection;
	XCTAssertNotNil([kept execute:@"BEGIN"]);

	// Cancelled: nothing moves, and the history (and its recording) carries on from where it was
	[document backForwardInHistory:[self historyMenuItemWithTag:0]];
	XCTAssertEqual(asked.count, 1u);
	XCTAssertFalse(document.isProcessing);
	XCTAssertEqual(document.connection, kept);
	XCTAssertEqual([kept transactionStatus], PGPostgresTransactionInTransaction);
	XCTAssertTrue([[document windowTitleString] hasSuffix:@"/pgkit_nopublic"]);
	XCTAssertTrue(document.history.canGoBack);
	XCTAssertFalse(document.history.canGoForward, @"the history index is unchanged");
	XCTAssertTrue([[self historyControl] isEnabledForSegment:0]);
	XCTAssertTrue([document.sidebar selectTableNamed:@"items"]);
	XCTAssertTrue([[document windowTitleString] hasSuffix:@"/pgkit_nopublic/app.items"]);

	// Confirmed: back to the other database (two steps: app.items was recorded after the cancel)
	answer = YES;
	[document backForwardInHistory:[self historyMenuItemWithTag:0]];
	XCTAssertEqual(asked.count, 1u, @"same database: no switch, no question");
	[document backForwardInHistory:[self historyMenuItemWithTag:0]];
	XCTAssertEqual(asked.count, 2u);
	XCTAssertTrue([self waitForTitleSuffix:@"/pgkit_test/public.customers"], @"%@ %@", [document windowTitleString], self.alerts);
	XCTAssertNotEqual(document.connection, kept);
}

- (void)testHistoryControlStateSurvivesTabSwitches
{
	SPPostgresDocument *document = self.document;
	NSSegmentedControl *control = [self historyControl];
	XCTAssertTrue([document.sidebar selectTableNamed:@"customers"]);
	XCTAssertTrue([control isEnabledForSegment:0]);

	id mysql = [self.controller addNewConnection];
	XCTAssertEqual([self.controller selectedDocument], mysql);
	NSToolbar *mysqlToolbar = [self.controller window].toolbar;
	XCTAssertNotEqual(mysqlToolbar, [document toolbar]);
	for (NSToolbarItem *item in mysqlToolbar.items) {
		if (![item.itemIdentifier isEqualToString:@"HistoryNavigationToolbarItemIdentifier"]) continue;
		XCTAssertNotEqual(item.view, control, @"the MySQL tab has its own control");
		XCTAssertFalse([(NSSegmentedControl *)item.view isEnabledForSegment:0], @"the MySQL tab's history is its own");
	}

	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	[tabView selectTabViewItem:document.parentTabViewItem];
	XCTAssertEqual([self.controller window].toolbar, [document toolbar]);
	XCTAssertEqual([self historyControl], control);
	XCTAssertTrue([control isEnabledForSegment:0]);
	XCTAssertFalse([control isEnabledForSegment:1]);
}

@end
