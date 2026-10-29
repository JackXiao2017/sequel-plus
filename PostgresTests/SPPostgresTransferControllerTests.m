#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/SPToolbarTransferItem.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresExportController.h"
#import "../Source/Postgres/SPPostgresTransferController.h"
#import "../Source/Postgres/SPPostgresTransfer.h"
#import "../Source/Postgres/SPPostgresCheckList.h"
#import "../Source/Postgres/SPPostgresProgressSheet.h"
#import "../Source/Postgres/SPPostgresErrors.h"
#import "../Source/Postgres/SPPostgresFavoritesStore.h"

static NSString * const SPTestTransferIdentifier = @"TransferToolbarItemIdentifier";

/// The Transfer sheet (SPPostgresTransferController) and the Transfer toolbar item of a Postgres tab connected to
/// pgkit_io_src (io_source.sql), copying into pgkit_io_dst, on PG 12 and 18. The favorites and the target's provider
/// are the test's (the favorites store and the Keychain are never read); the dump goes to a test-owned directory.
@interface SPPostgresTransferControllerTests : XCTestCase
@property (strong) SPWindowController *windowController;
@property (strong) SPPostgresDocument *document;
@property (strong) NSNumber *port;
@property (strong) NSMutableArray<NSString *> *providedDatabases;
/// "<favorite name>|<password or (none)>|<database>" per target provider call
@property (strong) NSMutableArray<NSString *> *targetRequests;
@property (strong) NSMutableArray<PGPostgresConnection *> *providedConnections;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (copy) NSString *directory;
@property (strong) SPPostgresTransferController *controller;
@property BOOL ended;
@end

@implementation SPPostgresTransferControllerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
	[self closeDocument];
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[super tearDown];
}

#pragma mark - Helpers

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = result.numberOfRows ? [result textValueAtRow:0 column:0] : nil;
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (NSWindow *)window
{
	return [self.windowController window];
}

- (SPPostgresFavorite *)favoriteNamed:(NSString *)name database:(NSString *)database
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = name;
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = self.port.unsignedIntegerValue;
	favorite.user = @"pgkit_test";
	favorite.database = database;
	return favorite;
}

/// pgkit_io_src loaded with io_source.sql, pgkit_io_dst emptied (held open, for checks), and a Postgres tab connected to
/// pgkit_io_src whose connectionProvider hands out test-server connections.
- (PGPostgresConnection *)buildDocumentOn:(NSNumber *)port
{
	self.port = port;
	PGPostgresConnection *loader = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
	XCTAssertNotNil(loader);
	[SPPostgresTestServers loadFixtureNamed:@"io_source" onPort:port.unsignedIntegerValue];
	[loader disconnect];
	PGPostgresConnection *target = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_dst"];
	XCTAssertNotNil(target);
	[self.openConnections addObject:target];

	SPPostgresFavorite *favorite = [self favoriteNamed:[NSString stringWithFormat:@"pg %@ source", port] database:@"pgkit_io_src"];

	self.windowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self window]);

	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block NSError *connectError = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *error) {
		connection = theConnection;
		connectError = error;
		done = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection, @"%@", connectError);

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	NSMutableArray *alerts = [NSMutableArray array];
	self.alerts = alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };

	NSMutableArray *databases = [NSMutableArray array];
	NSMutableArray *connections = [NSMutableArray array];
	self.providedDatabases = databases;
	self.providedConnections = connections;
	self.targetRequests = [NSMutableArray array];
	NSUInteger thePort = port.unsignedIntegerValue;
	self.document.connectionProvider = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		[databases addObject:database];
		PGPostgresConnection *provided = [SPPostgresTestServers connectedConnectionOnPort:thePort database:database];
		if (provided) [connections addObject:provided];
		completion(provided, provided ? nil : [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no connection"}]);
	};

	[self.windowController addTabDocument:self.document atIndex:0 select:YES];
	[[self window] setFrameOrigin:NSMakePoint(-10000, -10000)];
	[self.windowController showWindow:nil];
	return target;
}

- (void)closeDocument
{
	if (!self.windowController) return;
	NSWindow *window = [self window];
	if (self.controller && !self.ended) {
		[self.controller cancel:nil];
		[self spinUntil:^BOOL{ return self.ended; } timeout:20];
	}
	self.controller = nil;
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.windowController valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.windowController = nil;
	for (PGPostgresConnection *connection in self.providedConnections) [connection disconnect];
	self.providedConnections = nil;
}

/// Runs body once per test server, with a fresh document each time (body gets a connection to pgkit_io_dst).
- (void)onEachPort:(void (^)(NSNumber *port, PGPostgresConnection *target))body
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *target = [self buildDocumentOn:port];
		body(port, target);
		[self closeDocument];
	}
}

/// A Transfer sheet with the test's favorites (default: "Test target" for pgkit_io_dst) and target provider.
- (SPPostgresTransferController *)openSheetWithFavorites:(NSArray *)favorites
{
	SPPostgresTransferController *controller = [[SPPostgresTransferController alloc] initWithDocument:self.document];
	self.controller = controller;
	self.ended = NO;
	controller.favorites = favorites ?: @[[self favoriteNamed:@"Test target" database:@"pgkit_io_dst"]];
	controller.temporaryDirectory = self.directory;
	NSMutableArray *requests = self.targetRequests;
	NSMutableArray *connections = self.providedConnections;
	NSUInteger thePort = self.port.unsignedIntegerValue;
	controller.targetProviderForFavorite = ^SPPostgresConnectionProvider(SPPostgresFavorite *favorite, NSString *password) {
		NSString *name = favorite.name;
		return ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
			[requests addObject:[NSString stringWithFormat:@"%@|%@|%@", name, password.length ? password : @"(none)", database]];
			PGPostgresConnection *provided = [SPPostgresTestServers connectedConnectionOnPort:thePort database:database];
			if (provided) [connections addObject:provided];
			completion(provided, provided ? nil : [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no connection"}]);
		};
	};
	__weak SPPostgresTransferControllerTests *weakSelf = self;
	controller.didEnd = ^{ weakSelf.ended = YES; };
	[controller beginSheet];
	XCTAssertEqual([self window].attachedSheet, controller.sheet, @"the Transfer sheet is shown");
	return controller;
}

- (SPPostgresTransferController *)openSheet
{
	return [self openSheetWithFavorites:nil];
}

- (void)click:(NSButton *)button
{
	XCTAssertTrue(button.isEnabled, @"%@ is enabled", button.title);
	[button performClick:nil];
}

- (void)type:(NSString *)text into:(NSTextField *)field
{
	field.stringValue = text;
	[field.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
}

- (void)chooseFavorite:(NSInteger)index in:(SPPostgresTransferController *)controller
{
	NSPopUpButton *popup = controller.favoritePopup;
	[popup selectItemAtIndex:index];
	[NSApp sendAction:popup.action to:popup.target from:popup];
}

- (void)uncheckAll:(SPPostgresTransferController *)controller
{
	for (id item in controller.tablesList.checkedItems) [controller.tablesList setChecked:NO item:item];
}

/// Starts the transfer and waits until the controller has ended.
- (void)transferWith:(SPPostgresTransferController *)controller
{
	XCTAssertTrue(controller.transferButton.isEnabled);
	[controller transfer:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:120],
				  @"the transfer ends (%@)", controller.lastErrorMessage);
}

- (NSDictionary *)rowsOf:(PGPostgresConnection *)connection
{
	[self run:@"RESET search_path" on:connection];
	NSDictionary *description = [SPPostgresTestServers describeDatabase:connection];
	NSMutableDictionary *rows = [NSMutableDictionary dictionary];
	for (NSString *key in description) if ([key hasPrefix:@"rows "]) rows[key] = description[key];
	return rows;
}

- (void)assertTemporaryDirectoryEmpty
{
	XCTAssertEqualObjects([[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL], @[], @"the dump is deleted");
}

/// A one-row table public.marker on the target.
- (void)addMarkerTo:(PGPostgresConnection *)target
{
	[self run:@"CREATE TABLE public.marker (note text)" on:target];
	[self run:@"INSERT INTO public.marker VALUES ('still here')" on:target];
}

#pragma mark - The sheet

- (void)testDefaults
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		SPPostgresTransferController *controller = [self openSheet];
		XCTAssertEqual(controller.wholeDatabaseRadio.state, NSControlStateValueOn);
		XCTAssertEqual(controller.selectedTablesRadio.state, NSControlStateValueOff);
		XCTAssertEqualObjects(controller.wholeDatabaseRadio.title, @"Whole database “pgkit_io_src”");
		XCTAssertEqualObjects(controller.selectedTablesRadio.title, @"Selected tables");
		XCTAssertEqual(controller.emptyModeRadio.state, NSControlStateValueOn);
		XCTAssertEqual(controller.overwriteModeRadio.state, NSControlStateValueOff);
		XCTAssertEqualObjects(controller.emptyModeRadio.title, @"Empty the target database first");
		XCTAssertEqualObjects(controller.overwriteModeRadio.title, @"Overwrite tables that already exist on the target");
		XCTAssertEqualObjects(controller.favoritePopup.titleOfSelectedItem, @"Test target");
		XCTAssertTrue(controller.favoritePopup.isEnabled);
		XCTAssertEqualObjects(controller.databaseField.stringValue, @"pgkit_io_dst");
		XCTAssertEqualObjects(controller.targetDescriptionField.stringValue, ([NSString stringWithFormat:@"pgkit_test@127.0.0.1:%@", port]));
		XCTAssertEqualObjects(controller.passwordField.stringValue, @"");
		XCTAssertEqualObjects(controller.passwordField.placeholderString, @"Saved in Keychain");
		XCTAssertEqualObjects(controller.transferButton.title, @"Transfer");
		XCTAssertTrue(controller.transferButton.isEnabled);
		XCTAssertEqual(self.providedDatabases.count, 0u, @"nothing connects while the sheet is open");
		XCTAssertEqual(self.targetRequests.count, 0u);
	}];
}

- (void)testTargetDescriptions
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.user = @"ann";
	favorite.host = @"db.example.com";
	favorite.port = 5433;
	XCTAssertEqualObjects([SPPostgresTransferController targetDescriptionForFavorite:favorite], @"ann@db.example.com:5433");
	favorite.port = 0;
	XCTAssertEqualObjects([SPPostgresTransferController targetDescriptionForFavorite:favorite], @"ann@db.example.com:5432");
	favorite.type = SPPostgresSocketConnection;
	XCTAssertEqualObjects([SPPostgresTransferController targetDescriptionForFavorite:favorite], @"ann@local socket");
	favorite.socketPath = @"/tmp";
	XCTAssertEqualObjects([SPPostgresTransferController targetDescriptionForFavorite:favorite], @"ann@/tmp");
	favorite.type = SPPostgresSSHConnection;
	favorite.host = @"127.0.0.1";
	favorite.sshUser = @"bob";
	favorite.sshHost = @"gate.example.com";
	XCTAssertEqualObjects([SPPostgresTransferController targetDescriptionForFavorite:favorite], @"ann@127.0.0.1:5432 via SSH bob@gate.example.com");
}

/// A catalog error while the tables list loads is shown (an alert), not just an empty list.
- (void)testTablesListErrorIsShown
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		// The tab's session in a failed transaction: the catalog queries fail
		PGPostgresConnection *tab = self.document.connection;
		[self run:@"BEGIN" on:tab];
		XCTAssertNil([tab execute:@"SELECT 1/0"]);
		[self.alerts removeAllObjects];
		SPPostgresTransferController *controller = [self openSheet];
		XCTAssertEqual(self.alerts.count, 1u, @"%@", [self.alerts valueForKey:@"messageText"]);
		NSAlert *alert = self.alerts.firstObject;
		XCTAssertEqualObjects(alert.messageText, @"The tables couldn't be read");
		XCTAssertTrue([alert.informativeText containsString:@"current transaction is aborted"], @"%@", alert.informativeText);
		XCTAssertEqualObjects(controller.lastErrorMessage, alert.informativeText);
		XCTAssertEqual(controller.tablesList.rows.count, 0u);
		[self run:@"ROLLBACK" on:tab];

		[controller cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:5]);

		// Readable again: no alert
		[self.alerts removeAllObjects];
		controller = [self openSheet];
		XCTAssertEqual(self.alerts.count, 0u);
		XCTAssertGreaterThan(controller.tablesList.rows.count, 0u);
		[controller cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:5]);
	}];
}

- (void)testTransferDisabledWithoutTablesOrDatabase
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		SPPostgresTransferController *controller = [self openSheet];
		[self click:controller.selectedTablesRadio];
		XCTAssertEqual(controller.selectedTablesRadio.state, NSControlStateValueOn);
		XCTAssertEqual(controller.wholeDatabaseRadio.state, NSControlStateValueOff);
		[self uncheckAll:controller];
		XCTAssertFalse(controller.transferButton.isEnabled, @"no table checked");
		[controller.tablesList setChecked:YES item:@[@"Sales Data", @"order_lines"]];
		XCTAssertTrue(controller.transferButton.isEnabled);
		[self uncheckAll:controller];
		XCTAssertFalse(controller.transferButton.isEnabled);
		[self click:controller.wholeDatabaseRadio];
		XCTAssertTrue(controller.transferButton.isEnabled, @"the whole database needs no table checked");

		[self type:@"" into:controller.databaseField];
		XCTAssertFalse(controller.transferButton.isEnabled, @"no database name");
		[self type:@"pgkit_io_dst" into:controller.databaseField];
		XCTAssertTrue(controller.transferButton.isEnabled);

		[controller cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:5]);

		controller = [self openSheetWithFavorites:@[]];
		XCTAssertFalse(controller.favoritePopup.isEnabled, @"no favorites");
		XCTAssertFalse(controller.transferButton.isEnabled);
		[self type:@"pgkit_io_dst" into:controller.databaseField];
		XCTAssertFalse(controller.transferButton.isEnabled, @"still no favorite");
		[controller transfer:nil];
		XCTAssertEqual(self.targetRequests.count, 0u);
		[controller cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:5]);
	}];
}

- (void)testDatabaseFollowsFavoriteUntilEdited
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		SPPostgresFavorite *first = [self favoriteNamed:@"Test target" database:@"pgkit_io_dst"];
		SPPostgresFavorite *second = [self favoriteNamed:@"Other target" database:@"other_db"];
		second.user = @"someone";
		SPPostgresTransferController *controller = [self openSheetWithFavorites:@[first, second]];
		XCTAssertEqualObjects(controller.databaseField.stringValue, @"pgkit_io_dst");

		[self chooseFavorite:1 in:controller];
		XCTAssertEqualObjects(controller.databaseField.stringValue, @"other_db");
		XCTAssertEqualObjects(controller.targetDescriptionField.stringValue, ([NSString stringWithFormat:@"someone@127.0.0.1:%@", port]));
		[self chooseFavorite:0 in:controller];
		XCTAssertEqualObjects(controller.databaseField.stringValue, @"pgkit_io_dst");

		[self type:@"mine" into:controller.databaseField];
		[self chooseFavorite:1 in:controller];
		XCTAssertEqualObjects(controller.databaseField.stringValue, @"mine", @"edited: it stays");
		XCTAssertEqualObjects(controller.targetDescriptionField.stringValue, ([NSString stringWithFormat:@"someone@127.0.0.1:%@", port]));
	}];
}

- (void)testPopupSkipsThisTabsFavorite
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		self.document.favorite.favoriteID = @"this-tab";
		SPPostgresFavorite *mine = [self.document.favorite copy];
		mine.name = @"A this tab";
		SPPostgresFavorite *other = [self favoriteNamed:@"B other" database:@"pgkit_io_dst"];
		other.favoriteID = @"other";
		SPPostgresTransferController *controller = [self openSheetWithFavorites:@[mine, other]];
		XCTAssertEqualObjects(controller.favoritePopup.titleOfSelectedItem, @"B other");
		XCTAssertEqual(controller.favoritePopup.numberOfItems, 2, @"this tab's favorite is offered too (another database)");
	}];
}

#pragma mark - Empty mode's confirmation

- (void)testEmptyConfirmationNeedsExactName
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		SPPostgresTransferController *controller = [self openSheet];
		NSString *description = [NSString stringWithFormat:@"“Test target” (pgkit_test@127.0.0.1:%@)", port];
		NSAlert *alert = [controller emptyConfirmationAlertForDatabase:@"pgkit_io_dst" targetDescription:description];
		XCTAssertEqualObjects(alert.messageText, @"Empty “pgkit_io_dst” and transfer into it?");
		XCTAssertEqualObjects(alert.informativeText, ([NSString stringWithFormat:@"Everything in database “pgkit_io_dst” on %@ will be deleted: all schemas (including public), tables, views, functions, types and extensions. Other databases on that server aren't touched.\n\nType the database's name to confirm.", description]));
		XCTAssertTrue([alert.accessoryView isKindOfClass:[NSTextField class]]);
		NSTextField *field = (NSTextField *)alert.accessoryView;
		NSButton *button = alert.buttons.firstObject;
		XCTAssertEqualObjects(button.title, @"Empty and Transfer");
		XCTAssertTrue(button.hasDestructiveAction);
		XCTAssertEqualObjects(alert.buttons[1].title, @"Cancel");
		XCTAssertFalse(button.isEnabled, @"empty at first");
		for (NSString *text in @[@"", @"pgkit_io_ds", @"PGKIT_IO_DST", @"pgkit_io_dst ", @" pgkit_io_dst", @"pgkit_io_dstx"]) {
			field.stringValue = text;
			XCTAssertFalse(button.isEnabled, @"“%@”", text);
		}
		field.stringValue = @"pgkit_io_dst";
		XCTAssertTrue(button.isEnabled);
		// As typed (the field's text did change)
		field.stringValue = @"pgkit_io_ds";
		[field textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:[[NSTextView alloc] init]]];
		XCTAssertFalse(button.isEnabled);

		// Declined: nothing starts, no connection is asked for, the sheet stays
		__block NSUInteger asked = 0;
		__block NSString *askedDatabase = nil, *askedDescription = nil;
		controller.emptyConfirmation = ^(NSString *database, NSString *targetDescription, void (^answer)(BOOL)) {
			asked++;
			askedDatabase = database;
			askedDescription = targetDescription;
			answer(NO);
		};
		[controller transfer:nil];
		XCTAssertEqual(asked, 1u);
		XCTAssertEqualObjects(askedDatabase, @"pgkit_io_dst");
		XCTAssertEqualObjects(askedDescription, description);
		[self spinUntil:^BOOL{ return NO; } timeout:0.5];
		XCTAssertEqual(self.providedDatabases.count, 0u, @"no source connection");
		XCTAssertEqual(self.targetRequests.count, 0u, @"no target connection");
		XCTAssertNil(controller.progressSheet);
		XCTAssertFalse(self.ended);
		XCTAssertEqual([self window].attachedSheet, controller.sheet);
		XCTAssertTrue(controller.transferButton.isEnabled);

		// Overwrite mode asks nothing
		asked = 0;
		[self click:controller.overwriteModeRadio];
		XCTAssertEqual(controller.emptyModeRadio.state, NSControlStateValueOff);
		XCTAssertEqual(asked, 0u);
	}];
}

/// Without the seam the alert is a sheet on the Transfer sheet; Cancel there starts nothing.
- (void)testConfirmationSheetCancelStartsNothing
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		SPPostgresTransferController *controller = [self openSheet];
		[controller transfer:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return controller.sheet.attachedSheet != nil; } timeout:5], @"the confirmation is a sheet on the Transfer sheet");
		NSWindow *alertWindow = controller.sheet.attachedSheet;
		[controller.sheet endSheet:alertWindow returnCode:NSAlertSecondButtonReturn];
		[self spinUntil:^BOOL{ return NO; } timeout:0.5];
		XCTAssertEqual(self.providedDatabases.count, 0u);
		XCTAssertEqual(self.targetRequests.count, 0u);
		XCTAssertFalse(self.ended);
		XCTAssertEqual([self window].attachedSheet, controller.sheet);
	}];
}

#pragma mark - Transfers

- (void)testWholeDatabaseTransferEndToEnd
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		[self addMarkerTo:target];
		SPPostgresTransferController *controller = [self openSheet];
		controller.emptyConfirmation = ^(NSString *database, NSString *targetDescription, void (^answer)(BOOL)) { answer(YES); };
		NSMutableArray *statuses = [NSMutableArray array];
		NSMutableArray *fractions = [NSMutableArray array];
		controller.progressObserver = ^(SPPostgresProgressSheet *sheet) {
			// On the job's thread, right after the status was set there
			NSString *status = [sheet valueForKey:@"pendingStatus"];
			@synchronized (statuses) {
				if (status && ![statuses.lastObject isEqualToString:status]) [statuses addObject:status];
				[fractions addObject:[sheet valueForKey:@"pendingFraction"]];
			}
		};
		[self transferWith:controller];

		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertTrue([controller.completionNote hasPrefix:@"Copied"], @"%@", controller.completionNote);
		XCTAssertTrue([controller.completionNote containsString:@"Copied 5 tables to “pgkit_io_dst” on “Test target”."], @"%@", controller.completionNote);
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, @"Transfer complete");
		XCTAssertEqualObjects(self.alerts.firstObject.informativeText, controller.completionNote);

		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_src"]);
		XCTAssertEqualObjects(self.targetRequests, @[@"Test target|(none)|pgkit_io_dst"]);
		for (PGPostgresConnection *provided in self.providedConnections) XCTAssertFalse(provided.isConnected, @"the job's connections are closed");
		[self assertTemporaryDirectoryEmpty];

		PGPostgresConnection *source = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		[self.openConnections addObject:source];
		NSDictionary *expected = [self rowsOf:source];
		XCTAssertGreaterThan(expected.count, 3u);
		XCTAssertEqualObjects([self rowsOf:target], expected, @"port %@", port);
		XCTAssertEqualObjects([self value:@"SELECT (to_regclass('public.marker') IS NULL)::text" on:target], @"true", @"emptied first");

		XCTAssertEqualObjects(statuses.firstObject, @"Checking the target…", @"%@", statuses);
		// Every table the dump reads, the partitioned parent public.events included
		XCTAssertEqual([[statuses filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF MATCHES 'Reading table 1 of 6: .+'"]] count], 1u, @"%@", statuses);
		XCTAssertEqual([[statuses filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF MATCHES 'Reading table 6 of 6: .+'"]] count], 1u, @"%@", statuses);
		XCTAssertEqualObjects(statuses.lastObject, @"Writing to “pgkit_io_dst”…", @"%@", statuses);
		for (NSNumber *fraction in fractions) XCTAssertTrue(fraction.doubleValue >= 0 && fraction.doubleValue <= 1);
		XCTAssertEqualWithAccuracy([fractions.lastObject doubleValue], 1.0, 0.001);
	}];
}

- (void)testSelectedTablesOverwriteEndToEnd
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		[self addMarkerTo:target];
		SPPostgresTransferController *controller = [self openSheet];
		controller.emptyConfirmation = ^(NSString *database, NSString *targetDescription, void (^answer)(BOOL)) {
			XCTFail(@"Overwrite isn't confirmed");
			answer(NO);
		};
		[self click:controller.selectedTablesRadio];
		[self uncheckAll:controller];
		// order_lines references "Orders 2026": both go
		[controller.tablesList setChecked:YES item:@[@"Sales Data", @"Orders 2026"]];
		[controller.tablesList setChecked:YES item:@[@"Sales Data", @"order_lines"]];
		[self click:controller.overwriteModeRadio];
		[self type:@"secret" into:controller.passwordField];
		[self transferWith:controller];

		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertTrue([controller.completionNote hasPrefix:@"Copied 2 tables to “pgkit_io_dst” on “Test target”.\n\nAlso created, as the tables need them: "], @"%@", controller.completionNote);
		XCTAssertTrue([controller.completionNote containsString:@"type public.mood"], @"%@", controller.completionNote);
		XCTAssertEqualObjects(self.targetRequests, @[@"Test target|secret|pgkit_io_dst"], @"the typed password");
		XCTAssertEqualObjects([self value:@"SELECT string_agg(note, ',') FROM public.marker" on:target], @"still here", @"left alone");
		PGPostgresConnection *source = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		[self.openConnections addObject:source];
		NSDictionary *expected = [self rowsOf:source], *actual = [self rowsOf:target];
		for (NSString *key in @[@"rows \"Sales Data\".\"Orders 2026\"", @"rows \"Sales Data\".order_lines"]) {
			XCTAssertNotNil(expected[key], @"%@", key);
			XCTAssertEqualObjects(actual[key], expected[key], @"port %@: %@", port, key);
		}
		[self assertTemporaryDirectoryEmpty];
	}];
}

/// The default target provider (no seam): a connector with the typed password (so the Keychain isn't read for a TCP
/// favorite), its SSH prompts on the progress sheet.
- (void)testDefaultTargetProviderConnectsOnProgressSheet
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		SPPostgresTransferController *controller = [self openSheet];
		controller.targetProviderForFavorite = nil;
		controller.emptyConfirmation = ^(NSString *database, NSString *targetDescription, void (^answer)(BOOL)) { answer(YES); };
		[self type:@"pgkit" into:controller.passwordField];
		[controller transfer:nil];
		XCTAssertNotNil(controller.progressSheet);
		SPPostgresConnector *connector = controller.pendingConnector;
		XCTAssertNotNil(connector, @"the default target provider is connecting");
		XCTAssertEqual(connector.parentWindow, (NSWindow *)controller.progressSheet.panel);
		XCTAssertEqualObjects(connector.password, @"pgkit");
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:120]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertNil(controller.pendingConnector);
		XCTAssertTrue([controller.completionNote hasPrefix:@"Copied 5 tables"], @"%@", controller.completionNote);
		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_src"]);
	}];
}

- (void)testOverwriteBlockedShowsWhatIsInTheWay
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		// An older copy of "Orders 2026" on the target, a view over it and a table referencing it
		PGPostgresConnection *source = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		[self.openConnections addObject:source];
		SPPostgresTransfer *earlier = [[SPPostgresTransfer alloc] initWithSource:source target:target];
		earlier.temporaryDirectory = self.directory;
		earlier.tables = @[@[@"Sales Data", @"Orders 2026"]];
		NSError *error = nil;
		XCTAssertTrue([earlier run:&error], @"%@", error.localizedDescription);
		[self run:@"RESET search_path" on:target];
		[self run:@"CREATE VIEW public.report AS SELECT id FROM \"Sales Data\".\"Orders 2026\"" on:target];
		[self run:@"CREATE TABLE public.refs (order_id int REFERENCES \"Sales Data\".\"Orders 2026\" (id))" on:target];
		NSDictionary *before = [self rowsOf:target];

		SPPostgresTransferController *controller = [self openSheet];
		[self click:controller.selectedTablesRadio];
		[self uncheckAll:controller];
		[controller.tablesList setChecked:YES item:@[@"Sales Data", @"Orders 2026"]];
		[self click:controller.overwriteModeRadio];
		[self transferWith:controller];

		XCTAssertNil(controller.completionNote);
		XCTAssertTrue([controller.lastErrorMessage containsString:@"wasn't changed"], @"%@", controller.lastErrorMessage);
		XCTAssertTrue([controller.lastErrorMessage containsString:@"“pgkit_io_dst” on “Test target”"], @"%@", controller.lastErrorMessage);
		XCTAssertTrue([controller.lastErrorMessage containsString:@"public.report"], @"%@", controller.lastErrorMessage);
		XCTAssertTrue([controller.lastErrorMessage containsString:@"public.refs"], @"%@", controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, @"The transfer failed. “pgkit_io_dst” on “Test target” wasn't changed.");
		XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"public.report"]);
		XCTAssertEqualObjects([self rowsOf:target], before);
		[self assertTemporaryDirectoryEmpty];
	}];
}

- (void)testCancelDuringTransfer
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		[self addMarkerTo:target];
		NSDictionary *before = [self rowsOf:target];
		SPPostgresTransferController *controller = [self openSheet];
		controller.emptyConfirmation = ^(NSString *database, NSString *targetDescription, void (^answer)(BOOL)) { answer(YES); };
		__block BOOL cancelledWhileReading = NO;
		__block SPPostgresProgressSheet *seen = nil;
		controller.progressObserver = ^(SPPostgresProgressSheet *sheet) {
			NSString *status = [sheet valueForKey:@"pendingStatus"];
			if (!cancelledWhileReading && [status hasPrefix:@"Reading table "]) {
				cancelledWhileReading = YES;
				seen = sheet;
				[sheet cancel:nil];
			}
		};
		[self transferWith:controller];

		XCTAssertTrue(cancelledWhileReading);
		XCTAssertTrue(seen.cancelled);
		XCTAssertNil(seen.panel.sheetParent, @"the progress sheet ended");
		XCTAssertEqualObjects(controller.lastErrorMessage, @"The transfer was cancelled.");
		XCTAssertNil(controller.completionNote);
		XCTAssertEqual(self.alerts.count, 0u, @"a cancel isn't an error");
		XCTAssertEqualObjects([self rowsOf:target], before, @"the target is unchanged");
		XCTAssertEqualObjects([self value:@"SELECT string_agg(note, ',') FROM public.marker" on:target], @"still here");
		[self assertTemporaryDirectoryEmpty];
	}];
}

/// Cancel right after Transfer, before the Transfer sheet's completion handler could have run: the job never starts
/// (when the progress sheet hasn't begun yet) and the controller ends cleanly.
- (void)testCancelRightAfterTransferEndsCleanly
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		__weak SPPostgresTransferController *weakController = nil;
		@autoreleasepool {
			SPPostgresTransferController *controller = [self openSheet];
			weakController = controller;
			controller.emptyConfirmation = ^(NSString *database, NSString *targetDescription, void (^answer)(BOOL)) { answer(YES); };
			[controller transfer:nil];
			BOOL progressBegan = controller.progressSheet != nil;
			[controller cancel:nil];
			if (!progressBegan) XCTAssertEqual(self.targetRequests.count, 0u, @"no provider asked");
			self.controller = nil;
		}
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:30]);
		XCTAssertNil([self window].attachedSheet, @"no progress sheet attached");
		XCTAssertTrue([self spinUntil:^BOOL{ @autoreleasepool { return weakController == nil; } } timeout:10], @"the controller deallocates");
	}];
}

- (void)testControllerDeallocatesAfterCancel
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		__weak SPPostgresTransferController *weakController = nil;
		@autoreleasepool {
			SPPostgresTransferController *controller = [self openSheet];
			weakController = controller;
			[self click:controller.selectedTablesRadio];
			[controller cancel:nil];
			self.controller = nil;
		}
		XCTAssertTrue([self spinUntil:^BOOL{ return self.ended && [self window].attachedSheet == nil; } timeout:5]);
		XCTAssertTrue([self spinUntil:^BOOL{ @autoreleasepool { return weakController == nil; } } timeout:5], @"no retain cycle through stored blocks");
	}];
}

- (void)testControllerDeallocatesAfterTransfer
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		__weak SPPostgresTransferController *weakController = nil;
		@autoreleasepool {
			SPPostgresTransferController *controller = [self openSheet];
			weakController = controller;
			[self click:controller.overwriteModeRadio];
			[self transferWith:controller];
			XCTAssertNil(controller.lastErrorMessage);
			self.controller = nil;
		}
		XCTAssertTrue([self spinUntil:^BOOL{ @autoreleasepool { return weakController == nil; } } timeout:5], @"no retain cycle through stored blocks");
	}];
}

#pragma mark - The toolbar item

- (void)testToolbarTransferItemEnabledOnPostgresTab
{
	[self onEachPort:^(NSNumber *port, PGPostgresConnection *target) {
		NSToolbar *toolbar = [self.document toolbar];
		NSToolbarItem *item = [self.document toolbar:toolbar itemForItemIdentifier:SPTestTransferIdentifier willBeInsertedIntoToolbar:NO];
		XCTAssertNotNil(item);
		XCTAssertFalse([item isKindOfClass:[SPDisabledToolbarItem class]]);
		XCTAssertEqualObjects(item.label, @"Transfer");
		XCTAssertNotNil(item.image);
		XCTAssertEqual(item.target, self.document);
		XCTAssertEqual(item.action, NSSelectorFromString(@"showTransfer:"));
		XCTAssertTrue([self.document respondsToSelector:NSSelectorFromString(@"showTransfer:")]);
		XCTAssertTrue([self.document validateToolbarItem:item], @"connected, no sheet");
		NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:@"Transfer…" action:NSSelectorFromString(@"showTransfer:") keyEquivalent:@""];
		XCTAssertTrue([self.document validateMenuItem:menuItem]);

		// The one in the window's toolbar is the same kind
		NSToolbarItem *inToolbar = nil;
		for (NSToolbarItem *candidate in toolbar.items) if ([candidate.itemIdentifier isEqualToString:SPTestTransferIdentifier]) inToolbar = candidate;
		XCTAssertNotNil(inToolbar);
		XCTAssertFalse([inToolbar isKindOfClass:[SPDisabledToolbarItem class]]);
		XCTAssertEqual(inToolbar.action, NSSelectorFromString(@"showTransfer:"));

		// Not while Export is up
		[self.document export:nil];
		XCTAssertNotNil(self.document.exportController);
		XCTAssertFalse([self.document validateToolbarItem:item]);
		XCTAssertFalse([self.document validateMenuItem:menuItem]);
		[self.document.exportController cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:5]);
		XCTAssertTrue([self.document validateToolbarItem:item]);
		XCTAssertFalse(item.isBordered, @"as MySQL's");

		// Clicking it opens the Transfer sheet (the favorites come from a test-owned store, never the real one)
		NSString *storeDirectory = [self.directory stringByAppendingPathComponent:@"store"];
		[[NSFileManager defaultManager] createDirectoryAtPath:storeDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
		SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:[NSURL fileURLWithPath:[storeDirectory stringByAppendingPathComponent:@"PostgresFavorites.plist"]]];
		Method shared = class_getClassMethod([SPPostgresFavoritesStore class], @selector(sharedStore));
		IMP original = method_setImplementation(shared, imp_implementationWithBlock(^id(id me) { return store; }));
		@try {
			XCTAssertTrue([NSApp sendAction:inToolbar.action to:inToolbar.target from:inToolbar]);
			SPPostgresTransferController *opened = self.document.transferController;
			XCTAssertNotNil(opened);
			XCTAssertEqual([self window].attachedSheet, opened.sheet);
			XCTAssertEqualObjects(opened.favorites, @[]);
			XCTAssertFalse([self.document validateToolbarItem:item], @"not while Transfer is up");
			[opened cancel:nil];
			XCTAssertTrue([self spinUntil:^BOOL{ return self.document.transferController == nil && [self window].attachedSheet == nil; } timeout:5]);
		}
		@finally {
			method_setImplementation(shared, original);
		}
	}];

	// MySQL's Transfer item stays a never-enabled SPDisabledToolbarItem
	SPWindowController *windowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([windowController window]);
	id mysql = [windowController addNewConnection];
	NSToolbar *toolbar = [[windowController window] toolbar];
	NSToolbarItem *mysqlItem = [mysql toolbar:toolbar itemForItemIdentifier:SPTestTransferIdentifier willBeInsertedIntoToolbar:NO];
	XCTAssertTrue([mysqlItem isKindOfClass:[SPDisabledToolbarItem class]]);
	XCTAssertTrue(mysqlItem.action == NULL);
	[mysqlItem setEnabled:YES];
	XCTAssertFalse(mysqlItem.isEnabled);
	// A MySQL tab's filter editor resizes itself 0.2 s after it is built: let that run while the tab is alive
	[self spinUntil:^BOOL{ return NO; } timeout:0.4];
	NSTabView *tabView = [windowController valueForKey:@"tabView"];
	for (NSTabViewItem *tabItem in [tabView tabViewItems]) [tabView removeTabViewItem:tabItem];
	[[windowController window] orderOut:nil];
}

@end
