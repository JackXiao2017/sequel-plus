#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresCatalog.h"
#import "../Source/Postgres/SPPostgresErrors.h"
#import "../Source/Postgres/SPPostgresNameSheet.h"
#import "../Source/Postgres/SPPostgresServerListSheet.h"
#import "../Source/Postgres/SPPostgresAlterDatabaseSheet.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

static const NSUInteger SPDatabaseMenuTestPort = 55418;

// The Database menu's actions (not in the public header)
@interface SPPostgresDocument (SPDatabaseMenuTests)
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (IBAction)addDatabase:(id)sender;
- (IBAction)renameDatabase:(id)sender;
- (IBAction)copyDatabase:(id)sender;
- (IBAction)removeDatabase:(id)sender;
- (IBAction)refreshTables:(id)sender;
- (IBAction)setDatabases:(id)sender;
- (IBAction)showServerVariables:(id)sender;
- (IBAction)showServerProcesses:(id)sender;
- (IBAction)openDatabaseInNewTab:(id)sender;
- (IBAction)alterDatabase:(id)sender;
@end

/**
 * Database ▸ for PostgreSQL: the catalog's database changes and server lists, the name and list sheets, and the
 * document's menu items (validation; Add, Rename, Duplicate and Delete Database on databases the tests create, named
 * sp_dbm_*, dropped again in -tearDown).
 */
@interface SPPostgresDatabaseMenuTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSWindow *window;
@end

@implementation SPPostgresDatabaseMenuTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

/// Drops the test databases (sp_dbm_*) on port, ending sessions on them first.
- (void)dropTestDatabasesOnPort:(NSUInteger)port
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:port];
	PGPostgresResult *result = [admin execute:@"SELECT datname::text AS n FROM pg_database WHERE datname LIKE 'sp\\_dbm\\_%'"];
	for (NSDictionary *row in result) {
		NSString *name = row[@"n"];
		[admin execute:@"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()" values:@[name]];
		[self spinUntil:^BOOL{ return NO; } timeout:0.2];
		[admin execute:[@"DROP DATABASE IF EXISTS " stringByAppendingString:[NSString stringWithFormat:@"\"%@\"", name]]];
	}
	// The role Alter Database's test gives a database to (it owns nothing once the databases are gone)
	[admin execute:@"DROP ROLE IF EXISTS sp_dbm_owner"];
	// The schema the + by the schema pop-up adds (empty)
	[[SPPostgresTestServers connectedConnectionOnPort:port database:@"pgkit_test"] execute:@"DROP SCHEMA IF EXISTS sp_dbm_schema"];
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.alerts = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) [self dropTestDatabasesOnPort:port.unsignedIntegerValue];
}

- (void)tearDown
{
	if ([SPPostgresNameSheet currentSheet]) [[SPPostgresNameSheet currentSheet] cancel:nil];
	if ([SPPostgresServerListSheet currentSheet]) [[SPPostgresServerListSheet currentSheet] close:nil];
	if ([SPPostgresAlterDatabaseSheet currentSheet]) [[SPPostgresAlterDatabaseSheet currentSheet] cancel:nil];
	if (self.controller) {
		NSWindow *window = [self.controller window];
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		NSTabView *tabView = [self.controller valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
	}
	[self.window orderOut:nil];
	self.window = nil;
	self.document = nil;
	self.controller = nil;
	[self spinUntil:^BOOL{ return NO; } timeout:0.5]; // the tab's connection closes
	for (NSNumber *port in [SPPostgresTestServers ports]) [self dropTestDatabasesOnPort:port.unsignedIntegerValue];
	[SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest];
	[super tearDown];
}

- (NSWindow *)sheetWindow
{
	if (!self.window) {
		self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
		self.window.releasedWhenClosed = NO;
	}
	return self.window;
}

- (void)openDocument
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 database menu";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPDatabaseMenuTestPort;
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
	NSMutableArray *alerts = self.alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self waitIdle]);
}

- (BOOL)waitIdle
{
	SPPostgresDocument *document = self.document;
	return [self spinUntil:^BOOL{ return !document.isProcessing && !document.taskRunner.isBusy; } timeout:30];
}

- (NSMenuItem *)itemWithAction:(SEL)action
{
	return [[NSMenuItem alloc] initWithTitle:@"x" action:action keyEquivalent:@""];
}

- (NSArray<NSString *> *)databaseNamesOnPort:(NSUInteger)port
{
	NSError *error = nil;
	SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:[SPPostgresTestServers connectedConnectionOnPort:port database:@"pgkit_test"]];
	NSArray *names = [catalog databaseNames:&error];
	XCTAssertNotNil(names, @"%@", error);
	return names ?: @[];
}

/// Answers the open name sheet with text and waits until the tab has done what it starts and is idle.
- (void)answerNameSheet:(NSString *)text
{
	SPPostgresNameSheet *sheet = [SPPostgresNameSheet currentSheet];
	XCTAssertNotNil(sheet);
	sheet.nameField.stringValue = text;
	[sheet controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:sheet.nameField]];
	XCTAssertTrue(sheet.actionButton.isEnabled, @"%@", text);
	[sheet performAction:nil];
	XCTAssertNil([SPPostgresNameSheet currentSheet]);
}

#pragma mark - Catalog

- (void)testCatalogCopiesRenamesAndDropsDatabases
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSUInteger thePort = port.unsignedIntegerValue;
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:[SPPostgresTestServers connectedConnectionOnPort:thePort database:@"pgkit_test"]];
		NSError *error = nil;
		XCTAssertTrue([catalog createDatabase:@"sp_dbm_a" error:&error], @"%@ %@", port, error);
		XCTAssertTrue([catalog copyDatabase:@"sp_dbm_a" toName:@"sp_dbm_b" error:&error], @"%@ %@", port, error);
		XCTAssertTrue([catalog renameDatabase:@"sp_dbm_b" toName:@"sp_dbm \"c\"" error:&error], @"%@ %@", port, error);
		NSArray *names = [self databaseNamesOnPort:thePort];
		XCTAssertTrue([names containsObject:@"sp_dbm_a"]);
		XCTAssertTrue([names containsObject:@"sp_dbm \"c\""], @"quoted: %@", names);
		XCTAssertFalse([names containsObject:@"sp_dbm_b"]);

		// The connected database can't be renamed or dropped (the server's refusal is the error)
		error = nil;
		XCTAssertFalse([catalog renameDatabase:@"pgkit_test" toName:@"sp_dbm_x" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertFalse([catalog dropDatabase:@"pgkit_test" error:&error]);
		XCTAssertFalse([catalog dropDatabase:@"" error:&error]);
		// Names as -createDatabase:error: checks them, before anything is sent
		XCTAssertFalse([catalog copyDatabase:@"sp_dbm_a" toName:@"" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);
		XCTAssertFalse([catalog renameDatabase:@"sp_dbm_a" toName:[@"" stringByPaddingToLength:64 withString:@"x" startingAtIndex:0] error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);

		XCTAssertTrue([catalog dropDatabase:@"sp_dbm_a" error:&error], @"%@", error);
		XCTAssertTrue([catalog dropDatabase:@"sp_dbm \"c\"" error:&error], @"%@", error);
		names = [self databaseNamesOnPort:thePort];
		XCTAssertFalse([names containsObject:@"sp_dbm_a"]);
		XCTAssertFalse([names containsObject:@"sp_dbm \"c\""]);
	}
}

- (void)testCatalogServerSettingsAndProcesses
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSUInteger thePort = port.unsignedIntegerValue;
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:[SPPostgresTestServers connectedConnectionOnPort:thePort database:@"pgkit_test"]];
		NSError *error = nil;

		NSArray *settings = [catalog serverSettings:&error];
		XCTAssertGreaterThan(settings.count, 100u, @"%@", error);
		NSDictionary *version = [[settings filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == 'server_version'"]] firstObject];
		XCTAssertTrue([version[@"setting"] length] > 0, @"%@", version);
		NSDictionary *sharedBuffers = [[settings filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == 'shared_buffers'"]] firstObject];
		XCTAssertEqualObjects(sharedBuffers[@"unit"], @"8kB");
		XCTAssertTrue([sharedBuffers[@"category"] length] && [sharedBuffers[@"description"] length]);

		// Another session to see and signal
		PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:thePort database:@"pgkit_test"];
		NSString *otherPid = nil;
		for (NSDictionary *row in [other execute:@"SELECT pg_backend_pid()::text AS n"]) otherPid = row[@"n"];
		XCTAssertNotNil(otherPid);

		NSArray *processes = [catalog serverProcesses:&error];
		XCTAssertNotNil(processes, @"%@", error);
		NSArray *own = [processes filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"own == 'true'"]];
		XCTAssertEqual(own.count, 1u);
		XCTAssertEqualObjects(own.firstObject[@"database"], @"pgkit_test");
		XCTAssertEqualObjects(own.firstObject[@"user"], @"pgkit_test");
		XCTAssertTrue([own.firstObject[@"query"] containsString:@"pg_stat_activity"]);
		NSDictionary *otherRow = [[processes filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pid == %@", otherPid]] firstObject];
		XCTAssertNotNil(otherRow);
		XCTAssertEqualObjects(otherRow[@"own"], @"false");
		XCTAssertEqualObjects(otherRow[@"state"], @"idle");

		// Cancel (nothing running: still signalled), then terminate: the other session is gone
		XCTAssertTrue([catalog signalProcess:otherPid.integerValue terminate:NO error:&error], @"%@", error);
		XCTAssertTrue([catalog signalProcess:otherPid.integerValue terminate:YES error:&error], @"%@", error);
		NSPredicate *otherOnly = [NSPredicate predicateWithFormat:@"pid == %@", otherPid];
		BOOL (^otherGone)(void) = ^BOOL{ return [[[catalog serverProcesses:NULL] filteredArrayUsingPredicate:otherOnly] count] == 0; };
		XCTAssertTrue([self spinUntil:otherGone timeout:5]);
		error = nil;
		XCTAssertFalse([catalog signalProcess:otherPid.integerValue terminate:YES error:&error], @"no such process any more");
		XCTAssertNotNil(error);
	}
}

#pragma mark - Sheets

- (void)testNameSheetEnablesItsButton
{
	__block NSString *answer = @"unset";
	SPPostgresNameSheet *sheet = [SPPostgresNameSheet beginOnWindow:[self sheetWindow] title:@"Rename Database" message:@"Rename to:" initialName:@"shop" buttonTitle:@"Rename" requiredText:nil completion:^(NSString *name) { answer = name; }];
	XCTAssertNotNil(sheet);
	XCTAssertEqual([SPPostgresNameSheet currentSheet], sheet);
	XCTAssertEqualObjects(sheet.nameField.stringValue, @"shop");
	XCTAssertFalse(sheet.actionButton.isEnabled, @"the same name");
	sheet.nameField.stringValue = @"  ";
	[sheet controlTextDidChange:nil];
	XCTAssertFalse(sheet.actionButton.isEnabled, @"empty");
	sheet.nameField.stringValue = @"  shop_2 ";
	[sheet controlTextDidChange:nil];
	XCTAssertTrue(sheet.actionButton.isEnabled);
	[sheet performAction:nil];
	XCTAssertEqualObjects(answer, @"shop_2", @"trimmed");
	XCTAssertNil([SPPostgresNameSheet currentSheet]);
	XCTAssertNil([self sheetWindow].attachedSheet);

	// Delete's confirmation: exactly the name
	sheet = [SPPostgresNameSheet beginOnWindow:[self sheetWindow] title:@"Delete Database" message:@"Type the name:" initialName:@"" buttonTitle:@"Delete" requiredText:@"shop" completion:^(NSString *name) { answer = name; }];
	XCTAssertFalse(sheet.actionButton.isEnabled);
	for (NSString *wrong in @[@"sho", @"SHOP", @"shop "]) {
		sheet.nameField.stringValue = wrong;
		[sheet controlTextDidChange:nil];
		XCTAssertFalse(sheet.actionButton.isEnabled, @"%@", wrong);
	}
	[sheet performAction:nil];
	XCTAssertNotNil([SPPostgresNameSheet currentSheet], @"a disabled button does nothing");
	[sheet cancel:nil];
	XCTAssertNil(answer, @"Cancel");
	XCTAssertNil([SPPostgresNameSheet currentSheet]);
}

- (void)testServerListSheetFiltersCopiesAndSignals
{
	NSArray *rows = @[@{@"pid": @"10", @"user": @"alice", @"query": @"SELECT 1\nFROM t", @"own": @"false"},
					  @{@"pid": @"11", @"user": @"bob", @"query": @"", @"own": @"true"},
					  @{@"pid": @"12", @"user": @"carol", @"query": @"VACUUM", @"own": @"false"}];
	__block NSMutableArray *signals = [NSMutableArray array];
	__block NSUInteger refreshes = 0;
	__block BOOL closed = NO;
	NSArray *columns = @[@{@"key": @"pid", @"title": @"PID"}, @{@"key": @"user", @"title": @"User"}, @{@"key": @"query", @"title": @"Query"}];
	SPPostgresServerListSheet *list = [SPPostgresServerListSheet beginOnWindow:[self sheetWindow] title:@"Server Processes" columns:columns rows:rows
																		refresh:^{ refreshes++; }
																  processAction:^(NSDictionary *row, BOOL terminate) { [signals addObject:@[row[@"pid"], @(terminate)]]; }
																	 completion:^{ closed = YES; }];
	XCTAssertNotNil(list);
	XCTAssertEqual(list.tableView.numberOfRows, 3);
	XCTAssertEqualObjects(list.countLabel.stringValue, @"3 rows");
	XCTAssertEqualObjects([list tableView:list.tableView objectValueForTableColumn:list.tableView.tableColumns[2] row:0], @"SELECT 1 FROM t", @"one line");
	XCTAssertFalse(list.cancelQueryButton.isEnabled);

	// The tab's own session can't be signalled
	[list.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
	XCTAssertFalse(list.killButton.isEnabled);
	[list.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
	XCTAssertTrue(list.killButton.isEnabled);
	[list cancelQuery:nil];
	[list killConnection:nil];
	XCTAssertEqualObjects(signals, (@[@[@"12", @NO], @[@"12", @YES]]));

	// A refresh keeps the selected process (by pid) though its row moved
	[list setRows:@[rows[2], rows[0]]];
	XCTAssertEqualObjects([list.tableView selectedRowIndexes], [NSIndexSet indexSetWithIndex:0]);
	[list setRows:rows];
	[list refresh:nil];
	XCTAssertEqual(refreshes, 1u);

	// Copy: the selected rows, tab-separated
	[list.tableView selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
	XCTAssertEqualObjects([list selectedRowsText], @"10\talice\tSELECT 1\nFROM t\n11\tbob\t");
	XCTAssertFalse(list.killButton.isEnabled, @"two rows");

	// The filter (any column, case-insensitive)
	list.filterField.stringValue = @"VACU";
	[list updateFilter:nil];
	XCTAssertEqualObjects([list.displayedRows valueForKey:@"pid"], (@[@"12"]));
	XCTAssertEqualObjects(list.countLabel.stringValue, @"1 of 3 rows");
	list.filterField.stringValue = @"";
	[list updateFilter:nil];
	XCTAssertEqual(list.displayedRows.count, 3u);

	[list close:nil];
	XCTAssertTrue(closed);
	XCTAssertNil([SPPostgresServerListSheet currentSheet]);

	// Without the blocks: no Refresh or process buttons
	list = [SPPostgresServerListSheet beginOnWindow:[self sheetWindow] title:@"Server Variables" columns:columns rows:rows refresh:nil processAction:nil completion:nil];
	XCTAssertNil(list.refreshButton);
	XCTAssertNil(list.killButton);
	XCTAssertNil(list.cancelQueryButton);
	[list close:nil];
}

#pragma mark - The document's menu

- (void)testMenuItemsValidate
{
	[self openDocument];
	SPPostgresDocument *document = self.document;
	for (NSString *name in @[@"showGotoDatabase:", @"addDatabase:", @"removeDatabase:", @"copyDatabase:", @"renameDatabase:", @"refreshTables:",
							 @"setDatabases:", @"openDatabaseInNewTab:", @"showServerVariables:", @"showServerProcesses:", @"showUserManager:", @"alterDatabase:"]) {
		XCTAssertTrue([document validateMenuItem:[self itemWithAction:NSSelectorFromString(name)]], @"%@", name);
	}
	// No PostgreSQL equivalent
	for (NSString *name in @[@"flushPrivileges:", @"chooseEncoding:", @"shutdownServer:"]) {
		XCTAssertFalse([document validateMenuItem:[self itemWithAction:NSSelectorFromString(name)]], @"%@", name);
	}
	// Not while processing
	[SPPostgresTestServers queueSleep:1 onRunner:document.taskRunner];
	XCTAssertTrue([self spinUntil:^BOOL{ return document.isProcessing; } timeout:5]);
	XCTAssertFalse([document validateMenuItem:[self itemWithAction:@selector(addDatabase:)]]);
	XCTAssertFalse([document validateMenuItem:[self itemWithAction:@selector(refreshTables:)]]);
	XCTAssertTrue([self waitIdle]);
}

- (void)testCatalogCreatesSchemas
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:SPDatabaseMenuTestPort database:@"pgkit_test"];
	SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];
	NSError *error = nil;
	XCTAssertFalse([catalog createSchema:@"" error:&error]);
	XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);
	error = nil;
	XCTAssertFalse([catalog createSchema:[@"" stringByPaddingToLength:64 withString:@"s" startingAtIndex:0] error:&error]);
	XCTAssertEqual(error.code, SPPostgresErrorInvalidSettings);

	error = nil;
	XCTAssertTrue([catalog createSchema:@"sp_dbm_schema" error:&error], @"%@", error);
	XCTAssertTrue([[catalog schemaNames:&error] containsObject:@"sp_dbm_schema"], @"%@", error);
	error = nil;
	XCTAssertFalse([catalog createSchema:@"sp_dbm_schema" error:&error], @"it exists");
	XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
}

/// The + after the schema pop-up: a name sheet, CREATE SCHEMA, then the new schema listed and shown.
- (void)testAddSchemaButton
{
	[self openDocument];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSButton *button = sidebar.addSchemaButton;
	XCTAssertNotNil(button);
	XCTAssertTrue(button.isEnabled);
	NSPopUpButton *popup = [sidebar valueForKey:@"schemaPopup"];
	XCTAssertEqual(button.superview, popup.superview);
	XCTAssertGreaterThanOrEqual(NSMinX(button.frame), NSMaxX(popup.frame), @"after the pop-up");
	XCTAssertLessThanOrEqual(NSMaxX(button.frame), NSWidth(button.superview.bounds));
	XCTAssertEqualWithAccuracy(NSMidY(button.frame), NSMidY(popup.frame), 1, @"on the pop-up's row");
	XCTAssertEqualObjects(button.toolTip, @"Add a new schema");

	// Cancel adds nothing
	[button performClick:nil];
	XCTAssertNotNil([SPPostgresNameSheet currentSheet]);
	[[SPPostgresNameSheet currentSheet] cancel:nil];
	XCTAssertTrue([self waitIdle]);
	XCTAssertFalse([sidebar.schemaNames containsObject:@"sp_dbm_schema"]);

	// Add: created, listed in the pop-up and shown
	[button performClick:nil];
	[self answerNameSheet:@"sp_dbm_schema"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [sidebar.selectedSchema isEqualToString:@"sp_dbm_schema"] && !self.document.isProcessing; } timeout:30], @"%@ %@", sidebar.selectedSchema, [self.alerts valueForKey:@"informativeText"]);
	XCTAssertTrue([self waitIdle]);
	XCTAssertTrue([sidebar.schemaNames containsObject:@"sp_dbm_schema"]);
	XCTAssertEqualObjects(popup.titleOfSelectedItem, @"sp_dbm_schema");
	XCTAssertEqual(self.alerts.count, 0u);

	// The same name again: the server's refusal is shown, the schema stays shown
	[button performClick:nil];
	[self answerNameSheet:@"sp_dbm_schema"];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.alerts.count > 0; } timeout:30]);
	XCTAssertTrue([self.alerts.firstObject.messageText containsString:@"sp_dbm_schema"], @"%@", self.alerts.firstObject.messageText);
	XCTAssertTrue([self waitIdle]);
	XCTAssertEqualObjects(sidebar.selectedSchema, @"sp_dbm_schema");

	// Not while the tab is busy
	sidebar.actionsEnabled = NO;
	XCTAssertFalse(button.isEnabled);
	sidebar.actionsEnabled = YES;
}

- (void)testAddRenameDuplicateAndDeleteDatabase
{
	[self openDocument];
	SPPostgresDocument *document = self.document;

	// Add: created, then the tab is on it
	[document addDatabase:nil];
	[self answerNameSheet:@"sp_dbm_doc"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_doc"] && !document.isProcessing; } timeout:30], @"%@ %@", document.currentDatabase, self.alerts);
	XCTAssertTrue([self waitIdle]);
	XCTAssertTrue([[self databaseNamesOnPort:SPDatabaseMenuTestPort] containsObject:@"sp_dbm_doc"]);

	// Rename (from another database): the tab is on the new name
	[document renameDatabase:nil];
	XCTAssertEqualObjects([SPPostgresNameSheet currentSheet].nameField.stringValue, @"sp_dbm_doc");
	[self answerNameSheet:@"sp_dbm_renamed"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_renamed"] && !document.isProcessing; } timeout:60], @"%@ %@", document.currentDatabase, [self.alerts valueForKey:@"informativeText"]);
	XCTAssertTrue([self waitIdle]);
	NSArray *names = [self databaseNamesOnPort:SPDatabaseMenuTestPort];
	XCTAssertTrue([names containsObject:@"sp_dbm_renamed"]);
	XCTAssertFalse([names containsObject:@"sp_dbm_doc"]);

	// Duplicate: the copy, and the tab on it
	[document copyDatabase:nil];
	XCTAssertEqualObjects([SPPostgresNameSheet currentSheet].nameField.stringValue, @"sp_dbm_renamed_copy");
	[self answerNameSheet:@"sp_dbm_dup"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_dup"] && !document.isProcessing; } timeout:60], @"%@ %@", document.currentDatabase, [self.alerts valueForKey:@"informativeText"]);
	XCTAssertTrue([self waitIdle]);
	XCTAssertTrue([[self databaseNamesOnPort:SPDatabaseMenuTestPort] containsObject:@"sp_dbm_renamed"], @"the original stays");

	// Delete, once the name is typed: dropped, the tab on postgres
	[document removeDatabase:nil];
	SPPostgresNameSheet *confirm = [SPPostgresNameSheet currentSheet];
	XCTAssertFalse(confirm.actionButton.isEnabled);
	[self answerNameSheet:@"sp_dbm_dup"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"postgres"] && !document.isProcessing; } timeout:60], @"%@", document.currentDatabase);
	XCTAssertTrue([self spinUntil:^BOOL{ return ![[self databaseNamesOnPort:SPDatabaseMenuTestPort] containsObject:@"sp_dbm_dup"]; } timeout:30]);
	XCTAssertTrue([self waitIdle]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts valueForKey:@"informativeText"]);

	// A failure (renaming to a name taken) is reported, and the tab goes back to its database
	[document switchToDatabase:@"sp_dbm_renamed"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_renamed"] && !document.isProcessing; } timeout:30]);
	XCTAssertTrue([self waitIdle]);
	[document renameDatabase:nil];
	[self answerNameSheet:@"pgkit_test"];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.alerts.count > 0; } timeout:60]);
	XCTAssertTrue([self.alerts.firstObject.messageText containsString:@"Could not rename"], @"%@", self.alerts.firstObject.messageText);
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_renamed"] && !document.isProcessing; } timeout:60], @"%@", document.currentDatabase);
	XCTAssertTrue([self waitIdle]);
}

- (void)testCatalogDatabaseOwnerAndComment
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSUInteger thePort = port.unsignedIntegerValue;
		PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:thePort];
		XCTAssertNotNil([admin execute:@"CREATE ROLE sp_dbm_owner NOLOGIN"], @"%@", admin.lastError.errorPrimaryMessage);
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:[SPPostgresTestServers connectedConnectionOnPort:thePort database:@"pgkit_test"]];
		NSError *error = nil;
		XCTAssertTrue([catalog createDatabase:@"sp_dbm_alter" error:&error], @"%@", error);

		NSDictionary *details = [catalog databaseDetails:@"sp_dbm_alter" error:&error];
		XCTAssertEqualObjects(details, (@{@"owner": @"pgkit_test", @"comment": @""}), @"%@", error);
		NSArray *roles = [catalog roleNames:&error];
		XCTAssertTrue([roles containsObject:@"sp_dbm_owner"] && [roles containsObject:@"pgkit_test"], @"%@", roles);
		XCTAssertFalse([roles containsObject:@"pg_monitor"], @"no built-in pg_* roles");

		XCTAssertTrue([catalog setComment:@"Orders, 2026 — it's \"live\"" ofDatabase:@"sp_dbm_alter" error:&error], @"%@", error);
		XCTAssertTrue([catalog setOwner:@"sp_dbm_owner" ofDatabase:@"sp_dbm_alter" error:&error], @"%@", error);
		XCTAssertEqualObjects([catalog databaseDetails:@"sp_dbm_alter" error:&error], (@{@"owner": @"sp_dbm_owner", @"comment": @"Orders, 2026 — it's \"live\""}));
		XCTAssertTrue([catalog setComment:@"" ofDatabase:@"sp_dbm_alter" error:&error], @"an empty comment removes it: %@", error);
		XCTAssertEqualObjects([catalog databaseDetails:@"sp_dbm_alter" error:&error][@"comment"], @"");

		XCTAssertFalse([catalog setOwner:@"sp_dbm_no_such_role" ofDatabase:@"sp_dbm_alter" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"does not exist"], @"%@", error.localizedDescription);
		XCTAssertNil([catalog databaseDetails:@"sp_dbm_gone" error:&error]);
		XCTAssertNotNil(error);

		XCTAssertTrue([catalog dropDatabase:@"sp_dbm_alter" error:&error], @"%@", error);
		[admin execute:@"DROP ROLE sp_dbm_owner"];
	}
}

- (void)testAlterDatabaseSheetEnablesAlter
{
	__block NSDictionary *answer = @{};
	SPPostgresAlterDatabaseSheet *sheet = [SPPostgresAlterDatabaseSheet beginOnWindow:[self sheetWindow] database:@"shop" owner:@"carol" comment:@"old" roles:@[@"alice", @"bob"] completion:^(NSDictionary *values) { answer = values; }];
	XCTAssertNotNil(sheet);
	XCTAssertEqualObjects(sheet.ownerPopup.itemTitles, (@[@"carol", @"alice", @"bob"]), @"an owner not listed is added");
	XCTAssertEqualObjects(sheet.ownerPopup.titleOfSelectedItem, @"carol");
	XCTAssertEqualObjects(sheet.commentView.string, @"old");
	XCTAssertFalse(sheet.alterButton.isEnabled, @"nothing changed");

	[sheet.ownerPopup selectItemWithTitle:@"bob"];
	[sheet validate];
	XCTAssertTrue(sheet.alterButton.isEnabled);
	sheet.nameField.stringValue = @"  ";
	[sheet validate];
	XCTAssertFalse(sheet.alterButton.isEnabled, @"no name");
	sheet.nameField.stringValue = @" shop_2 ";
	sheet.commentView.string = @"new\ntwo lines";
	[sheet validate];
	[sheet alter:nil];
	XCTAssertEqualObjects(answer, (@{@"name": @"shop_2", @"owner": @"bob", @"comment": @"new\ntwo lines"}));
	XCTAssertNil([SPPostgresAlterDatabaseSheet currentSheet]);

	sheet = [SPPostgresAlterDatabaseSheet beginOnWindow:[self sheetWindow] database:@"shop" owner:@"alice" comment:@"" roles:@[@"alice"] completion:^(NSDictionary *values) { answer = values; }];
	[sheet cancel:nil];
	XCTAssertNil(answer, @"Cancel");
}

- (void)testAlterDatabaseFromTheMenu
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPDatabaseMenuTestPort];
	XCTAssertNotNil([admin execute:@"CREATE ROLE sp_dbm_owner NOLOGIN"], @"%@", admin.lastError.errorPrimaryMessage);
	XCTAssertNotNil([admin execute:@"CREATE DATABASE sp_dbm_alter"], @"%@", admin.lastError.errorPrimaryMessage);
	[self openDocument];
	SPPostgresDocument *document = self.document;
	[document switchToDatabase:@"sp_dbm_alter"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_alter"] && !document.isProcessing; } timeout:30]);
	XCTAssertTrue([self waitIdle]);

	// Owner and comment only: changed on this connection, the tab stays
	[document alterDatabase:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [SPPostgresAlterDatabaseSheet currentSheet] != nil; } timeout:30]);
	SPPostgresAlterDatabaseSheet *sheet = [SPPostgresAlterDatabaseSheet currentSheet];
	XCTAssertEqualObjects(sheet.nameField.stringValue, @"sp_dbm_alter");
	XCTAssertEqualObjects(sheet.ownerPopup.titleOfSelectedItem, @"pgkit_test");
	[sheet.ownerPopup selectItemWithTitle:@"sp_dbm_owner"];
	sheet.commentView.string = @"Alter Database test";
	[sheet validate];
	[sheet alter:nil];
	XCTAssertTrue([self waitIdle]);
	SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:[SPPostgresTestServers connectedConnectionOnPort:SPDatabaseMenuTestPort database:@"pgkit_test"]];
	XCTAssertEqualObjects([catalog databaseDetails:@"sp_dbm_alter" error:NULL], (@{@"owner": @"sp_dbm_owner", @"comment": @"Alter Database test"}));
	XCTAssertEqualObjects(document.currentDatabase, @"sp_dbm_alter");

	// A new name (and the comment cleared): renamed from another database, the tab on the new name
	[document alterDatabase:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [SPPostgresAlterDatabaseSheet currentSheet] != nil; } timeout:30]);
	sheet = [SPPostgresAlterDatabaseSheet currentSheet];
	XCTAssertEqualObjects(sheet.commentView.string, @"Alter Database test");
	sheet.nameField.stringValue = @"sp_dbm_altered";
	sheet.commentView.string = @"";
	[sheet validate];
	[sheet alter:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [document.currentDatabase isEqualToString:@"sp_dbm_altered"] && !document.isProcessing; } timeout:60], @"%@ %@", document.currentDatabase, [self.alerts valueForKey:@"informativeText"]);
	XCTAssertTrue([self waitIdle]);
	XCTAssertEqualObjects([catalog databaseDetails:@"sp_dbm_altered" error:NULL], (@{@"owner": @"sp_dbm_owner", @"comment": @""}));
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts valueForKey:@"informativeText"]);
}

- (void)testServerProcessesSheetFromTheMenu
{
	[self openDocument];
	SPPostgresDocument *document = self.document;
	[document showServerProcesses:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [SPPostgresServerListSheet currentSheet] != nil; } timeout:30]);
	SPPostgresServerListSheet *list = [SPPostgresServerListSheet currentSheet];
	NSArray *own = [list.rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"own == 'true'"]];
	XCTAssertEqual(own.count, 1u, @"%@", list.rows);
	XCTAssertEqualObjects(own.firstObject[@"database"], @"pgkit_test");
	XCTAssertNotNil(list.killButton);
	[list refresh:nil];
	XCTAssertTrue([self waitIdle]);
	XCTAssertTrue(list.rows.count > 0);
	[list close:nil];

	[document showServerVariables:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [SPPostgresServerListSheet currentSheet] != nil; } timeout:30]);
	list = [SPPostgresServerListSheet currentSheet];
	XCTAssertTrue([[list.rows valueForKey:@"name"] containsObject:@"server_version"]);
	XCTAssertNil(list.killButton);
	[list close:nil];
	XCTAssertTrue([self waitIdle]);
}

- (void)testRefreshTablesAndOpenDatabaseInNewTab
{
	[self openDocument];
	SPPostgresDocument *document = self.document;
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPDatabaseMenuTestPort];
	[admin execute:@"CREATE TABLE IF NOT EXISTS public.sp_dbm_fresh (id int)"];
	[document refreshTables:nil];
	XCTAssertTrue([self waitIdle]);
	BOOL listed = [[document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"sp_dbm_fresh"];
	[admin execute:@"DROP TABLE IF EXISTS public.sp_dbm_fresh"];
	XCTAssertTrue(listed);

	NSUInteger tabs = [[self.controller valueForKey:@"tabDocuments"] count];
	[document openDatabaseInNewTab:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.controller valueForKey:@"tabDocuments"] count] == tabs + 1; } timeout:30]);
	SPPostgresDocument *opened = [[self.controller valueForKey:@"tabDocuments"] lastObject];
	XCTAssertNotEqual(opened, document);
	XCTAssertEqualObjects(opened.currentDatabase, @"pgkit_test");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:opened.taskRunner timeout:30]);
}

@end
