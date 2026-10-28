#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConsoleLogger.h"
#import "../Source/Postgres/SPPostgresExportController.h"
#import "../Source/Postgres/SPPostgresProgressSheet.h"
#import "../Source/Postgres/SPPostgresBackgroundJob.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// The Export sheet (SPPostgresExportController), the progress sheet, the background job and File ▸ Export… on a
/// Postgres tab connected to pgkit_io_src (io_source.sql), on PG 12 and 18. Files go to a temporary directory only.
@interface SPPostgresExportControllerTests : XCTestCase
@property (strong) SPWindowController *windowController;
@property (strong) SPPostgresDocument *document;
@property (strong) NSMutableArray<NSString *> *providedDatabases;
@property (strong) NSMutableArray<PGPostgresConnection *> *providedConnections;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<NSString *> *suggestedNames;
@property (copy) NSString *directory;
@end

@implementation SPPostgresExportControllerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
	[self closeDocument];
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

/// pgkit_io_src loaded with io_source.sql on port, and a Postgres tab connected to it whose connectionProvider hands out
/// test-server connections (recording the databases asked for).
- (void)buildDocumentOn:(NSNumber *)port
{
	PGPostgresConnection *loader = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
	XCTAssertNotNil(loader);
	[SPPostgresTestServers loadFixtureNamed:@"io_source" onPort:port.unsignedIntegerValue];
	[loader disconnect];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = [NSString stringWithFormat:@"pg %@ export", port];
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = port.unsignedIntegerValue;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_io_src";

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
	NSUInteger thePort = port.unsignedIntegerValue;
	self.document.connectionProvider = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		[databases addObject:database];
		PGPostgresConnection *provided = [SPPostgresTestServers connectedConnectionOnPort:thePort database:database];
		if (provided) [connections addObject:provided];
		completion(provided, provided ? nil : [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no connection"}]);
	};

	[self.windowController addTabDocument:self.document atIndex:0 select:YES];
	// A sheet attaches to the nib's window once it has been shown (kept off screen)
	[[self window] setFrameOrigin:NSMakePoint(-10000, -10000)];
	[self.windowController showWindow:nil];
	self.suggestedNames = [NSMutableArray array];
}

- (void)closeDocument
{
	if (!self.windowController) return;
	NSWindow *window = [self window];
	[self spinUntil:^BOOL{ return self.document.exportController == nil; } timeout:20];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.windowController valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.windowController = nil;
	for (PGPostgresConnection *connection in self.providedConnections) [connection disconnect];
	self.providedConnections = nil;
}

/// Runs body once per test server, with a fresh document each time.
- (void)onEachPort:(void (^)(NSNumber *port))body
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self buildDocumentOn:port];
		body(port);
		[self closeDocument];
	}
}

/// Opens the Export sheet through File ▸ Export…'s action; its save panel is replaced by a path in the directory.
- (SPPostgresExportController *)openExportSheet
{
	[self.document export:nil];
	SPPostgresExportController *controller = self.document.exportController;
	XCTAssertNotNil(controller);
	XCTAssertNotNil([self window].attachedSheet, @"the Export sheet is shown");
	NSString *directory = self.directory;
	NSMutableArray *suggested = self.suggestedNames;
	controller.savePathProvider = ^NSString *(NSString *suggestedName, BOOL isDirectory) {
		[suggested addObject:[NSString stringWithFormat:@"%@%@", suggestedName, isDirectory ? @"/" : @""]];
		if (!isDirectory) return [directory stringByAppendingPathComponent:suggestedName];
		NSString *folder = [directory stringByAppendingPathComponent:@"folder"];
		[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
		return folder;
	};
	return controller;
}

- (void)choose:(NSInteger)index inPopup:(NSPopUpButton *)popup
{
	XCTAssertTrue([[popup itemAtIndex:index] isEnabled], @"%@ is enabled", [popup itemTitleAtIndex:index]);
	[popup selectItemAtIndex:index];
	[NSApp sendAction:popup.action to:popup.target from:popup];
}

- (void)chooseFormat:(NSInteger)segment in:(SPPostgresExportController *)controller
{
	[controller.formatControl setSelectedSegment:segment];
	[NSApp sendAction:controller.formatControl.action to:controller.formatControl.target from:controller.formatControl];
}

/// Checks the row named table under schema in the Selected tables list (through its data source, as a click would).
- (void)check:(NSString *)table schema:(NSString *)schema in:(SPPostgresExportController *)controller
{
	NSTableView *tableView = controller.tablesTable;
	NSTableColumn *checkColumn = [tableView tableColumnWithIdentifier:@"check"];
	NSTableColumn *nameColumn = [tableView tableColumnWithIdentifier:@"name"];
	NSString *currentSchema = nil;
	for (NSInteger row = 0; row < [tableView numberOfRows]; row++) {
		NSString *name = [tableView.dataSource tableView:tableView objectValueForTableColumn:nameColumn row:row];
		if ([tableView.delegate tableView:tableView isGroupRow:row]) {
			currentSchema = name;
			continue;
		}
		if ([currentSchema isEqualToString:schema] && [name isEqualToString:table]) {
			[tableView.dataSource tableView:tableView setObjectValue:@YES forTableColumn:checkColumn row:row];
			return;
		}
	}
	XCTFail(@"No table %@.%@ in the list", schema, table);
}

/// Runs the export and waits until it has ended.
- (void)exportWith:(SPPostgresExportController *)controller
{
	XCTAssertTrue(controller.exportButton.isEnabled);
	[controller export:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:60],
				  @"the export ends (%@)", controller.lastErrorMessage);
}

- (NSString *)contentsOf:(NSString *)path
{
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - Tests

- (void)testExportSQLWholeDatabase
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:0 in:controller];
		[self choose:0 inPopup:controller.sourcePopup];
		XCTAssertEqual(controller.structureCheckbox.state, NSControlStateValueOn);
		XCTAssertEqual(controller.dataCheckbox.state, NSControlStateValueOn);
		XCTAssertEqual(controller.compressCheckbox.state, NSControlStateValueOff);
		[self exportWith:controller];

		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqualObjects(self.suggestedNames, @[@"pgkit_io_src.sql"]);
		NSString *contents = [self contentsOf:[self.directory stringByAppendingPathComponent:@"pgkit_io_src.sql"]];
		XCTAssertNotNil(contents, @"port %@", port);
		XCTAssertTrue([contents hasPrefix:@"--"], @"%@", [contents substringToIndex:MIN(200u, contents.length)]);
		XCTAssertTrue([contents containsString:@"COPY \"Sales Data\".\"Orders 2026\""]);
		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_src"]);
		XCTAssertEqual(self.alerts.count, 0u);
		for (PGPostgresConnection *provided in self.providedConnections) XCTAssertFalse(provided.isConnected, @"the job's connection is closed");
	}];
}

- (void)testExportSQLCompressedSuggestsGz
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[controller.compressCheckbox performClick:nil];
		[self exportWith:controller];
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqualObjects(self.suggestedNames, @[@"pgkit_io_src.sql.gz"]);
		NSData *data = [NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"pgkit_io_src.sql.gz"]];
		XCTAssertGreaterThan(data.length, 2u);
		XCTAssertEqual(((const unsigned char *)data.bytes)[0], 0x1f, @"gzip");
		XCTAssertEqual(((const unsigned char *)data.bytes)[1], 0x8b, @"gzip");
	}];
}

- (void)testExportSelectedTablesCSVToFolder
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		[self choose:2 inPopup:controller.sourcePopup];
		XCTAssertFalse(controller.tablesTable.enclosingScrollView.isHidden);
		XCTAssertTrue(controller.schemasTable.enclosingScrollView.isHidden);
		[self check:@"Orders 2026" schema:@"Sales Data" in:controller];
		[self check:@"order_lines" schema:@"Sales Data" in:controller];
		[self exportWith:controller];

		XCTAssertNil(controller.lastErrorMessage, @"port %@", port);
		XCTAssertEqual(self.suggestedNames.count, 1u);
		XCTAssertTrue([self.suggestedNames.firstObject hasSuffix:@"/"], @"a folder is asked for: %@", self.suggestedNames);
		NSString *folder = [self.directory stringByAppendingPathComponent:@"folder"];
		NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL] sortedArrayUsingSelector:@selector(compare:)];
		XCTAssertEqualObjects(files, (@[@"Sales Data.Orders 2026.csv", @"Sales Data.order_lines.csv"]));
		NSString *lines = [self contentsOf:[folder stringByAppendingPathComponent:@"Sales Data.order_lines.csv"]];
		XCTAssertTrue([lines hasPrefix:@"id,order_id,item\n"], @"%@", lines);
		XCTAssertTrue([lines containsString:@"\"gadget\twith tab\""] || [lines containsString:@"gadget\twith tab"], @"%@", lines);
	}];
}

- (void)testExportOneTableCSVAsksForAFile
{
	[self onEachPort:^(NSNumber *port) {
		// Preset to the sidebar's selected table
		XCTAssertTrue([self.document.sidebar selectTableNamed:@"audit"]);
		XCTAssertEqualObjects(self.document.sidebar.selectedSchema, @"public");
		SPPostgresExportController *controller = [self openExportSheet];
		XCTAssertEqualObjects(controller.checkedTables, (@[@[@"public", @"audit"]]));
		[self chooseFormat:1 in:controller];
		[self choose:2 inPopup:controller.sourcePopup];
		[controller setChecked:NO table:@"audit" schema:@"public"];
		XCTAssertFalse(controller.exportButton.isEnabled, @"no table checked");
		[self check:@"order_lines" schema:@"Sales Data" in:controller];
		XCTAssertEqualObjects(controller.checkedTables, (@[@[@"Sales Data", @"order_lines"]]));
		[self exportWith:controller];
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqualObjects(self.suggestedNames, @[@"Sales Data.order_lines.csv"]);
		XCTAssertTrue([[self contentsOf:[self.directory stringByAppendingPathComponent:@"Sales Data.order_lines.csv"]] hasPrefix:@"id,order_id,item\n"]);
	}];
}

- (void)testExportQueryResultCSV
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresQueryController *query = self.document.queryController;
		XCTAssertNil([query lastResultColumnNames]);
		XCTAssertNil([query lastResultRows]);
		[query.editor setString:@"SELECT 1 AS a, NULL AS b"];
		[query runAllQueries:nil];
		XCTAssertEqualObjects([query lastResultColumnNames], (@[@"a", @"b"]));
		XCTAssertEqualObjects([query lastResultRows], (@[@[@"1", [NSNull null]]]));

		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		XCTAssertTrue([[controller.sourcePopup itemAtIndex:3] isEnabled], @"Query result is enabled");
		[self choose:3 inPopup:controller.sourcePopup];
		[self exportWith:controller];

		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqualObjects(self.suggestedNames, @[@"query-result.csv"]);
		XCTAssertEqualObjects([self contentsOf:[self.directory stringByAppendingPathComponent:@"query-result.csv"]], @"a,b\n1,\n");
		XCTAssertEqual(self.providedDatabases.count, 0u, @"the query isn't run again");
	}];
}

- (void)testQueryResultDisabledWithoutResult
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		XCTAssertFalse([[controller.sourcePopup itemAtIndex:3] isEnabled], @"no result in the Query view");
		[self chooseFormat:0 in:controller];
		XCTAssertFalse([[controller.sourcePopup itemAtIndex:3] isEnabled], @"CSV only");
		[controller cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:5]);
		XCTAssertEqual(self.suggestedNames.count, 0u);
	}];
}

- (void)testExportUsesItsOwnConnection
{
	[self onEachPort:^(NSNumber *port) {
		PGPostgresConnection *documentConnection = self.document.connection;
		[self run:@"BEGIN" on:documentConnection];
		[self run:@"INSERT INTO \"Sales Data\".order_lines (order_id, item) VALUES (1, 'uncommitted-marker-xyz')" on:documentConnection];
		XCTAssertEqual(documentConnection.transactionStatus, PGPostgresTransactionInTransaction);

		SPPostgresExportController *controller = [self openExportSheet];
		[self exportWith:controller];
		XCTAssertNil(controller.lastErrorMessage);

		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_src"]);
		XCTAssertEqual(documentConnection.transactionStatus, PGPostgresTransactionInTransaction, @"the user's transaction is untouched");
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM \"Sales Data\".order_lines WHERE item = 'uncommitted-marker-xyz'" on:documentConnection], @"1");
		NSString *contents = [self contentsOf:[self.directory stringByAppendingPathComponent:@"pgkit_io_src.sql"]];
		XCTAssertTrue([contents containsString:@"\twidget\n"], @"the committed rows are there");
		XCTAssertFalse([contents containsString:@"uncommitted-marker-xyz"]);
		[self run:@"ROLLBACK" on:documentConnection];
	}];
}

- (void)testCancelDuringExport
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		__block NSUInteger progressCalls = 0;
		__block SPPostgresProgressSheet *seen = nil;
		controller.progressObserver = ^(SPPostgresProgressSheet *sheet) {
			progressCalls++;
			seen = sheet;
			[sheet cancel:nil];
		};
		[self exportWith:controller];

		XCTAssertGreaterThan(progressCalls, 0u);
		XCTAssertTrue(seen.cancelled);
		XCTAssertNil(seen.panel.sheetParent, @"the progress sheet ended");
		XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"pgkit_io_src.sql"]], @"no file remains");
		XCTAssertEqual([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL] count], 0u);
		XCTAssertEqual(self.alerts.count, 0u, @"a cancel isn't an error");
	}];
}

- (void)testCancelDuringCSVFolderExportDeletesEveryFile
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		[self choose:0 inPopup:controller.sourcePopup];
		__block NSUInteger progressCalls = 0;
		controller.progressObserver = ^(SPPostgresProgressSheet *sheet) {
			if (++progressCalls == 3) [sheet cancel:nil];
		};
		[self exportWith:controller];
		XCTAssertGreaterThanOrEqual(progressCalls, 3u);
		NSString *folder = [self.directory stringByAppendingPathComponent:@"folder"];
		XCTAssertEqual([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL] count], 0u, @"the files written are deleted");
	}];
}

- (void)testExportMenuValidation
{
	[self onEachPort:^(NSNumber *port) {
		NSMenuItem *export = [[NSMenuItem alloc] initWithTitle:@"Export…" action:@selector(export:) keyEquivalent:@""];
		NSMenuItem *clipboard = [[NSMenuItem alloc] initWithTitle:@"Import from Clipboard…" action:NSSelectorFromString(@"importFromClipboard:") keyEquivalent:@""];
		XCTAssertTrue([self.document validateMenuItem:export]);
		XCTAssertTrue([self.windowController validateMenuItem:export], @"reached through the window's forwarding");
		XCTAssertTrue([self.windowController respondsToSelector:@selector(export:)]);
		XCTAssertFalse([self.document validateMenuItem:clipboard]);
		XCTAssertFalse([self.windowController validateMenuItem:clipboard]);

		// Not while a sheet is attached
		SPPostgresExportController *controller = [self openExportSheet];
		XCTAssertFalse([self.document validateMenuItem:export]);
		[controller cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:5]);
		XCTAssertTrue([self.document validateMenuItem:export]);
	}];
}

- (void)testBackgroundJobRunsOffMainAndDisconnects
{
	NSNumber *port = [SPPostgresTestServers ports].lastObject;
	__block PGPostgresConnection *provided = nil;
	__block BOOL workOnMain = YES, completionOnMain = NO, finished = NO, result = NO;
	__block NSError *failure = nil;
	[SPPostgresBackgroundJob runOnDatabase:@"pgkit_test" provider:^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		provided = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:database];
		completion(provided, nil);
	} work:^BOOL(PGPostgresConnection *connection, NSError **error) {
		workOnMain = [NSThread isMainThread];
		XCTAssertNotNil([connection execute:@"SELECT 1"]);
		*error = [NSError errorWithDomain:@"test" code:7 userInfo:nil];
		return NO;
	} completion:^(BOOL ok, NSError *error) {
		completionOnMain = [NSThread isMainThread];
		result = ok;
		failure = error;
		finished = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:20]);
	XCTAssertFalse(workOnMain);
	XCTAssertTrue(completionOnMain);
	XCTAssertFalse(result);
	XCTAssertEqual(failure.code, 7);
	XCTAssertFalse(provided.isConnected, @"disconnected after the work");

	// A provider failure goes straight to the completion
	finished = NO;
	[SPPostgresBackgroundJob runOnDatabase:@"x" provider:^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		completion(nil, [NSError errorWithDomain:@"test" code:9 userInfo:nil]);
	} work:^BOOL(PGPostgresConnection *connection, NSError **error) {
		XCTFail(@"no work without a connection");
		return YES;
	} completion:^(BOOL ok, NSError *error) {
		result = ok;
		failure = error;
		finished = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return finished; } timeout:5]);
	XCTAssertFalse(result);
	XCTAssertEqual(failure.code, 9);
}

- (void)testConsoleLoggerFromBackgroundThread
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	domain[@"ConsoleEnableLogging"] = @YES;
	domain[@"ConsoleEnableInterfaceLogging"] = @YES;
	domain[@"ConsoleEnableErrorLogging"] = @YES;
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];

	SPPostgresConsoleLogger *logger = [[SPPostgresConsoleLogger alloc] initWithConnectionName:@"bg logger" database:@"pgkit_io_src"];
	id console = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSString *marker = [NSString stringWithFormat:@"SELECT 'bg-%@'", [[NSUUID UUID] UUIDString]];
	NSString *errorMarker = [NSString stringWithFormat:@"bg-error-%@", [[NSUUID UUID] UUIDString]];
	BOOL (^logged)(NSString *) = ^BOOL(NSString *text) {
		for (id message in [[console valueForKey:@"messagesFullSet"] copy]) {
			if ([[message valueForKey:@"message"] hasPrefix:text]) return YES;
		}
		return NO;
	};

	// Called from a background queue while the main thread waits: nothing is appended until the main thread runs
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		for (NSUInteger i = 0; i < 50; i++) [logger connection:nil willExecute:(i == 49 ? marker : @"SELECT 'noise'") withValues:nil];
		[logger logError:errorMarker];
		dispatch_semaphore_signal(done);
	});
	XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
	XCTAssertFalse(logged(marker), @"appended on the main thread, not the caller's");
	XCTAssertTrue([self spinUntil:^BOOL{ return logged(marker) && logged(errorMarker); } timeout:5]);
}

#pragma mark - Fix round 1

/// The default provider's connector shows its SSH prompts on the progress sheet (the window has that sheet attached).
- (void)testDefaultProviderConnectorHostsSheetsOnProgressSheet
{
	[self onEachPort:^(NSNumber *port) {
		self.document.connectionProvider = nil;
		SPPostgresExportController *controller = [self openExportSheet];
		[controller export:nil];
		XCTAssertNotNil(controller.progressSheet);
		SPPostgresConnector *connector = controller.pendingConnector;
		XCTAssertNotNil(connector, @"the default provider is connecting");
		XCTAssertNotEqual(connector, (SPPostgresConnector *)[self.document valueForKey:@"connector"]);
		XCTAssertEqual(connector.parentWindow, (NSWindow *)controller.progressSheet.panel);

		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:60]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertNil(controller.pendingConnector);
		XCTAssertTrue([[self contentsOf:[self.directory stringByAppendingPathComponent:@"pgkit_io_src.sql"]] containsString:@"COPY \"Sales Data\".\"Orders 2026\""]);
	}];
}

/// Cancel while the provider hasn't answered ends the export at once; a connection handed out later is closed unused.
- (void)testCancelWhileConnectingEndsExport
{
	[self onEachPort:^(NSNumber *port) {
		__block void (^held)(PGPostgresConnection *, NSError *) = nil;
		self.document.connectionProvider = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
			held = [completion copy];
		};
		SPPostgresExportController *controller = [self openExportSheet];
		[controller export:nil];
		XCTAssertNotNil(held);
		SPPostgresProgressSheet *progress = controller.progressSheet;
		XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == progress.panel; } timeout:5]);

		[progress.cancelButton performClick:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:5], @"ends without the provider answering");
		XCTAssertTrue(progress.cancelled);
		XCTAssertEqual([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL] count], 0u);
		XCTAssertEqual(self.alerts.count, 0u);

		PGPostgresConnection *late = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		XCTAssertTrue(late.isConnected);
		held(late, nil);
		XCTAssertTrue([self spinUntil:^BOOL{ return !late.isConnected; } timeout:5], @"a late connection is closed unused");
	}];
}

/// CSV of the whole database leaves partitioned parents out (their partitions export their own rows); ticked, one exports.
- (void)testCSVWholeDatabaseSkipsPartitionedParents
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		[self choose:0 inPopup:controller.sourcePopup];
		[self exportWith:controller];
		XCTAssertNil(controller.lastErrorMessage);
		NSString *folder = [self.directory stringByAppendingPathComponent:@"folder"];
		NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL];
		XCTAssertTrue([files containsObject:@"public.events_2025.csv"], @"%@", files);
		XCTAssertTrue([files containsObject:@"public.events_2026.csv"], @"%@", files);
		XCTAssertFalse([files containsObject:@"public.events.csv"], @"no duplicated rows: %@", files);
		XCTAssertTrue([files containsObject:@"Sales Data.Orders 2026.csv"]);
		[[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];

		[self.suggestedNames removeAllObjects];
		controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		[self choose:2 inPopup:controller.sourcePopup];
		for (NSArray *pair in controller.checkedTables) [controller setChecked:NO table:pair[1] schema:pair[0]];
		[self check:@"events" schema:@"public" in:controller];
		[self exportWith:controller];
		XCTAssertEqualObjects(self.suggestedNames, @[@"public.events.csv"]);
		NSString *events = [self contentsOf:[self.directory stringByAppendingPathComponent:@"public.events.csv"]];
		XCTAssertEqual([[events componentsSeparatedByString:@"\n"] count], 5u, @"header, 3 rows, end: %@", events);
	}];
}

/// An error alert is never dropped because a sheet is attached: it waits its turn.
- (void)testErrorAlertWaitsForAttachedSheet
{
	[self onEachPort:^(NSNumber *port) {
		self.document.alertPresenter = nil;
		__block void (^held)(PGPostgresConnection *, NSError *) = nil;
		self.document.connectionProvider = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
			held = [completion copy];
		};
		SPPostgresExportController *controller = [self openExportSheet];
		[controller export:nil];
		NSWindow *window = [self window];
		XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == controller.progressSheet.panel; } timeout:5]);

		// Another sheet waits behind the progress sheet, then the job fails
		NSPanel *other = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
		other.releasedWhenClosed = NO;
		[window beginSheet:other completionHandler:nil];
		held(nil, SPPostgresMakeError(SPPostgresErrorConnectionFailed, @"no route to the server", nil));

		XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == other; } timeout:5], @"%@", window.attachedSheet);
		XCTAssertEqualObjects(controller.lastErrorMessage, @"no route to the server");
		XCTAssertNil(self.document.exportController);
		[window endSheet:other];
		[other orderOut:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil && window.attachedSheet != other; } timeout:5], @"the alert shows once the window is free");
		NSWindow *alertWindow = window.attachedSheet;
		XCTAssertTrue([[self textsIn:alertWindow.contentView] containsObject:@"no route to the server"], @"%@", [self textsIn:alertWindow.contentView]);
		[window endSheet:alertWindow];
		[alertWindow orderOut:nil];
	}];
}

/// SPTestPrefsGuard turns Sparkle's automatic checks off for the run, without saving it.
- (void)testSparkleChecksOffDuringTests
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	XCTAssertEqualObjects([prefs volatileDomainForName:NSArgumentDomain][@"SUEnableAutomaticChecks"], @NO);
	XCTAssertFalse([prefs boolForKey:@"SUEnableAutomaticChecks"]);
	id updater = [NSClassFromString(@"SUUpdater") valueForKey:@"sharedUpdater"];
	XCTAssertNotNil(updater);
	XCTAssertFalse([[updater valueForKey:@"automaticallyChecksForUpdates"] boolValue]);
}

- (NSArray<NSString *> *)textsIn:(NSView *)view
{
	NSMutableArray *texts = [NSMutableArray array];
	if ([view isKindOfClass:[NSTextField class]]) [texts addObject:[(NSTextField *)view stringValue]];
	for (NSView *subview in view.subviews) [texts addObjectsFromArray:[self textsIn:subview]];
	return texts;
}

@end
