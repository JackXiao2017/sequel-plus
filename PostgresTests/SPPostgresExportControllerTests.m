#import <XCTest/XCTest.h>
#import <objc/runtime.h>
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	// The first loads run on the tab's runner
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	// The tab's loads first (the sheet opens only while the tab isn't busy)
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)chooseFormat:(NSInteger)segment in:(SPPostgresExportController *)controller
{
	[controller.formatControl setSelectedSegment:segment];
	[NSApp sendAction:controller.formatControl.action to:controller.formatControl.target from:controller.formatControl];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
			XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertEqual(self.suggestedNames.count, 0u);
	}];
}

- (void)testControllerDeallocatesAfterCancel
{
	[self onEachPort:^(NSNumber *port) {
		__weak SPPostgresExportController *weakController = nil;
		@autoreleasepool {
			SPPostgresExportController *controller = [self openExportSheet];
			weakController = controller;
			[controller cancel:nil];
		}
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:5]);
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertTrue([self spinUntil:^BOOL{ @autoreleasepool { return weakController == nil; } } timeout:5], @"no retain cycle through the lists' checksChanged blocks");
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

		[progress.cancelButton performClick:nil];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:5], @"ends without the provider answering");
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertTrue(progress.cancelled);
		XCTAssertEqual([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL] count], 0u);
		XCTAssertEqual(self.alerts.count, 0u);

		PGPostgresConnection *late = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		XCTAssertTrue(late.isConnected);
		held(late, nil);
		XCTAssertTrue([self spinUntil:^BOOL{ return !late.isConnected; } timeout:5], @"a late connection is closed unused");
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

		// Another sheet waits behind the progress sheet, then the job fails
		NSPanel *other = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
		other.releasedWhenClosed = NO;
		[window beginSheet:other completionHandler:nil];
		held(nil, SPPostgresMakeError(SPPostgresErrorConnectionFailed, @"no route to the server", nil));

		XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == other; } timeout:5], @"%@", window.attachedSheet);
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertEqualObjects(controller.lastErrorMessage, @"no route to the server");
		XCTAssertNil(self.document.exportController);
		[window endSheet:other];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		[other orderOut:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil && window.attachedSheet != other; } timeout:5], @"the alert shows once the window is free");
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		NSWindow *alertWindow = window.attachedSheet;
		XCTAssertTrue([[self textsIn:alertWindow.contentView] containsObject:@"no route to the server"], @"%@", [self textsIn:alertWindow.contentView]);
		[window endSheet:alertWindow];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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

#pragma mark - Final fix wave

/// The user's Query-view transaction holds an ACCESS EXCLUSIVE lock on a table the export reads: Cancel interrupts the
/// statement waiting on it, so the export ends cancelled within seconds and leaves no file.
- (void)testCancelInterruptsExportWaitingOnALock
{
	[self onEachPort:^(NSNumber *port) {
		PGPostgresConnection *mine = self.document.connection;
		[self run:@"BEGIN" on:mine];
		[self run:@"LOCK TABLE \"Sales Data\".order_lines IN ACCESS EXCLUSIVE MODE" on:mine];
		PGPostgresConnection *watcher = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		XCTAssertNotNil(watcher);

		SPPostgresExportController *controller = [self openExportSheet];
		[controller export:nil];
		BOOL waiting = [self spinUntil:^BOOL{
			return [[self value:@"SELECT count(*)::text FROM pg_catalog.pg_locks WHERE NOT granted AND relation = '\"Sales Data\".order_lines'::regclass" on:watcher] isEqualToString:@"1"];
		} timeout:20];
		XCTAssertTrue(waiting, @"the export waits on the lock");
		NSDate *cancelled = [NSDate date];
		[controller.progressSheet cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil && [self window].attachedSheet == nil; } timeout:20]);
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertLessThan(-[cancelled timeIntervalSinceNow], 5.0, @"Cancel doesn't wait for the lock");
		XCTAssertEqualObjects(controller.lastErrorMessage, @"The export was cancelled.");
		XCTAssertEqual(self.alerts.count, 0u, @"a cancel isn't an error");
		XCTAssertEqual([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL] count], 0u, @"no file remains");
		XCTAssertEqual(mine.transactionStatus, PGPostgresTransactionInTransaction, @"the user's transaction is untouched");
		[self run:@"ROLLBACK" on:mine];
		[watcher disconnect];
	}];
}

/// Foreign tables are left out of a SQL dump; the completion says which (an alert, and completionNote).
- (void)testForeignTablesNamedOnCompletion
{
	[self onEachPort:^(NSNumber *port) {
		PGPostgresConnection *mine = self.document.connection;
		[self run:@"CREATE EXTENSION file_fdw WITH SCHEMA public" on:mine];
		[self run:@"CREATE SERVER sp_files FOREIGN DATA WRAPPER file_fdw" on:mine];
		[self run:@"CREATE FOREIGN TABLE public.remote (a integer) SERVER sp_files OPTIONS (filename '/dev/null')" on:mine];

		SPPostgresExportController *controller = [self openExportSheet];
		[self exportWith:controller];
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertTrue([controller.completionNote containsString:@"\"public\".\"remote\""], @"%@", controller.completionNote);
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, @"The export finished");
		XCTAssertEqualObjects(self.alerts.firstObject.informativeText, controller.completionNote);
		NSString *contents = [self contentsOf:[self.directory stringByAppendingPathComponent:@"pgkit_io_src.sql"]];
		XCTAssertTrue([contents containsString:@"-- Foreign tables not exported: \"public\".\"remote\"\n"]);
	}];
}

/// Opening the sheet only reads whether the Query view holds a result and its row count; the rows are read when the
/// query result is exported.
- (void)testSheetReadsQueryRowsOnlyWhenExported
{
	Method method = class_getInstanceMethod([SPPostgresQueryController class], @selector(lastResultRows));
	IMP original = method_getImplementation(method);
	__block NSUInteger reads = 0;
	IMP counting = imp_implementationWithBlock(^NSArray *(id me) {
		reads++;
		return ((NSArray *(*)(id, SEL))original)(me, @selector(lastResultRows));
	});
	method_setImplementation(method, counting);
	@try {
		[self onEachPort:^(NSNumber *port) {
			SPPostgresQueryController *query = self.document.queryController;
			[query.editor setString:@"SELECT g AS n FROM generate_series(1, 3) g"];
			[query runAllQueries:nil];
			XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
			XCTAssertEqual([query lastResultRowCount], 3u);
			reads = 0;

			SPPostgresExportController *controller = [self openExportSheet];
			[self chooseFormat:1 in:controller];
			[self choose:3 inPopup:controller.sourcePopup];
			XCTAssertEqual(reads, 0u, @"the sheet doesn't copy the rows");
			NSTextField *note = [controller valueForKey:@"sourceNote"];
			XCTAssertTrue([note.stringValue containsString:@"3 rows"], @"%@", note.stringValue);

			[self exportWith:controller];
			XCTAssertNil(controller.lastErrorMessage);
			XCTAssertEqual(reads, 1u, @"read once, for the export");
			XCTAssertEqualObjects([self contentsOf:[self.directory stringByAppendingPathComponent:@"query-result.csv"]], @"n\n1\n2\n3\n");
		}];
	}
	@finally {
		method_setImplementation(method, original);
	}
}

/// A cancelled CSV folder export leaves the files it replaced (they existed before), deleting only those it created.
- (void)testCancelledCSVFolderExportKeepsReplacedFiles
{
	[self onEachPort:^(NSNumber *port) {
		SPPostgresExportController *controller = [self openExportSheet];
		[self chooseFormat:1 in:controller];
		[self choose:0 inPopup:controller.sourcePopup];

		// Every table's file but the first already exists, plus an unrelated file
		NSString *folder = [self.directory stringByAppendingPathComponent:@"folder"];
		[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
		NSArray *tables = [controller valueForKey:@"_csvTables"];
		XCTAssertGreaterThan(tables.count, 3u);
		NSMutableSet *existing = [NSMutableSet setWithObject:@"keep.txt"];
		for (NSUInteger index = 1; index < tables.count; index++) {
			NSString *name = [NSString stringWithFormat:@"%@.%@.csv", tables[index][0], tables[index][1]];
			[existing addObject:name];
			XCTAssertTrue([@"old\n" writeToFile:[folder stringByAppendingPathComponent:name] atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
		}
		XCTAssertTrue([@"keep\n" writeToFile:[folder stringByAppendingPathComponent:@"keep.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL]);

		__block NSUInteger progressCalls = 0;
		controller.progressObserver = ^(SPPostgresProgressSheet *sheet) {
			if (++progressCalls == 3) [sheet cancel:nil];
		};
		[self exportWith:controller];
		XCTAssertEqualObjects(controller.lastErrorMessage, @"The export was cancelled.");

		NSSet *files = [NSSet setWithArray:[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL]];
		XCTAssertEqualObjects(files, existing, @"the first table's file (created by the export) is deleted; the others stay");
		NSString *second = [NSString stringWithFormat:@"%@.%@.csv", tables[1][0], tables[1][1]];
		XCTAssertNotEqualObjects([self contentsOf:[folder stringByAppendingPathComponent:second]], @"old\n", @"the second was replaced before the cancel");
		XCTAssertEqualObjects([self contentsOf:[folder stringByAppendingPathComponent:@"keep.txt"]], @"keep\n");
	}];
}

@end
