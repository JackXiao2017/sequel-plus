#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresImportController.h"
#import "../Source/Postgres/SPPostgresCSVMappingSheet.h"
#import "../Source/Postgres/SPPostgresCSV.h"
#import "../Source/Postgres/SPPostgresDumpWriter.h"
#import "../Source/Postgres/SPPostgresProgressSheet.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// File ▸ Import… on a Postgres tab connected to pgkit_io_dst (SPPostgresImportController, the CSV mapping sheet), on
/// PG 12 and 18, with a test connectionProvider. Files go to a temporary directory only.
@interface SPPostgresImportControllerTests : XCTestCase
@property (strong) SPWindowController *windowController;
@property (strong) SPPostgresDocument *document;
@property (strong) NSMutableArray<NSString *> *providedDatabases;
@property (strong) NSMutableArray<PGPostgresConnection *> *providedConnections;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) SPPostgresImportController *controller;
@property BOOL controllerEnded;
@property (copy) NSString *directory;
@end

@implementation SPPostgresImportControllerTests

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

/// A new connection to pgkit_io_dst (not emptied), closed in tearDown.
- (PGPostgresConnection *)destinationOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_dst"];
	XCTAssertNotNil(connection);
	[self.openConnections addObject:connection];
	return connection;
}

- (BOOL)table:(NSString *)name existsOn:(PGPostgresConnection *)connection
{
	return [[self value:[NSString stringWithFormat:@"SELECT (to_regclass('%@') IS NOT NULL)::text", name] on:connection] isEqualToString:@"true"];
}

- (NSWindow *)window
{
	return [self.windowController window];
}

- (NSString *)write:(NSString *)contents named:(NSString *)name
{
	NSString *path = [self.directory stringByAppendingPathComponent:name];
	XCTAssertTrue([contents writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
	return path;
}

/// pgkit_io_dst emptied on port, setup (may be nil) run on it, and a Postgres tab connected to it whose
/// connectionProvider hands out test-server connections (recording the databases asked for).
- (void)buildDocumentOn:(NSNumber *)port setup:(void (^)(PGPostgresConnection *connection))setup
{
	PGPostgresConnection *emptied = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_dst"];
	XCTAssertNotNil(emptied);
	if (setup) setup(emptied);
	[emptied disconnect];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = [NSString stringWithFormat:@"pg %@ import", port];
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = port.unsignedIntegerValue;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_io_dst";

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
}

- (void)closeDocument
{
	if (!self.windowController) return;
	NSWindow *window = [self window];
	if (self.controller) {
		[self spinUntil:^BOOL{ return self.controllerEnded; } timeout:20];
		if (!self.controllerEnded) [self.controller cancel];
		[self spinUntil:^BOOL{ return self.controllerEnded; } timeout:20];
	}
	self.controller = nil;
	[self spinUntil:^BOOL{ return self.document.importController == nil; } timeout:20];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.windowController valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.windowController = nil;
	for (PGPostgresConnection *connection in self.providedConnections) [connection disconnect];
	self.providedConnections = nil;
}

/// Runs body once per test server with a fresh document (setup run on the emptied pgkit_io_dst first).
- (void)onEachPortWithSetup:(void (^)(PGPostgresConnection *connection))setup body:(void (^)(NSNumber *port))body
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self buildDocumentOn:port setup:setup];
		body(port);
		[self closeDocument];
	}
}

/// A new import controller for the document, its end recorded.
- (SPPostgresImportController *)newController
{
	SPPostgresImportController *controller = [[SPPostgresImportController alloc] initWithDocument:self.document];
	self.controller = controller;
	self.controllerEnded = NO;
	__weak SPPostgresImportControllerTests *weakSelf = self;
	controller.didEnd = ^{ weakSelf.controllerEnded = YES; };
	return controller;
}

- (BOOL)waitForEnd
{
	return [self spinUntil:^BOOL{ return self.controllerEnded; } timeout:60];
}

/// The Query pane is shown and every pane marked fresh, so a stale mark afterwards comes from the import.
- (void)markPanesFresh
{
	[self.document showPane:SPPostgresPaneQuery];
	for (NSString *flag in @[@"contentNeedsReset", @"contentNeedsReload", @"structureNeedsReset", @"relationsNeedReset", @"triggersNeedReset", @"infoNeedsReset"]) {
		[self.document setValue:@NO forKey:flag];
	}
}

- (BOOL)flag:(NSString *)name
{
	return [[self.document valueForKey:name] boolValue];
}

- (NSArray<NSString *> *)sidebarSchemas
{
	NSPopUpButton *popup = [self.document.sidebar valueForKey:@"schemaPopup"];
	return [popup itemTitles];
}

- (void)choose:(NSInteger)index inPopup:(NSPopUpButton *)popup
{
	[popup selectItemAtIndex:index];
	[NSApp sendAction:popup.action to:popup.target from:popup];
}

- (void)click:(NSButton *)button
{
	XCTAssertTrue(button.isEnabled, @"%@ is enabled", button.title);
	[NSApp sendAction:button.action to:button.target from:button];
}

/// Shows the mapping sheet for path through the controller (as after the open panel).
- (SPPostgresCSVMappingSheet *)mappingSheetFor:(NSString *)path controller:(SPPostgresImportController *)controller
{
	[controller importPath:path format:@"csv"];
	XCTAssertNil(controller.lastErrorMessage);
	SPPostgresCSVMappingSheet *sheet = controller.mappingSheet;
	XCTAssertNotNil(sheet);
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == sheet.sheet; } timeout:5], @"the mapping sheet is on the window");
	return sheet;
}

- (NSArray<NSString *> *)selectedTitles:(SPPostgresCSVMappingSheet *)sheet
{
	NSMutableArray *titles = [NSMutableArray array];
	for (NSPopUpButton *popup in [sheet columnPopups]) [titles addObject:popup.titleOfSelectedItem];
	return titles;
}

#pragma mark - SQL

- (void)testImportSQLDumpRefreshesSidebar
{
	[self onEachPortWithSetup:nil body:^(NSNumber *port) {
		// A dump of io_source made by the app's writer (Task 3)
		PGPostgresConnection *source = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		[self.openConnections addObject:source];
		[SPPostgresTestServers loadFixtureNamed:@"io_source" onPort:port.unsignedIntegerValue];
		NSString *dump = [self.directory stringByAppendingPathComponent:@"io_source.sql"];
		SPPostgresDumpWriter *writer = [[SPPostgresDumpWriter alloc] initWithConnection:source];
		writer.wholeDatabase = YES;
		NSError *error = nil;
		XCTAssertTrue([writer writeToPath:dump error:&error], @"%@", error);

		XCTAssertFalse([[self sidebarSchemas] containsObject:@"Sales Data"]);
		[self markPanesFresh];

		SPPostgresImportController *controller = [self newController];
		XCTAssertEqual(controller.singleTransactionCheckbox.state, NSControlStateValueOn, @"single transaction by default");
		[controller importPath:dump format:@"sql"];
		XCTAssertNotNil(controller.progressSheet);
		XCTAssertTrue([self waitForEnd]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 0u);
		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_dst"]);

		// The sidebar was reloaded, and every pane is stale
		XCTAssertTrue([[self sidebarSchemas] containsObject:@"Sales Data"], @"%@", [self sidebarSchemas]);
		for (NSString *flag in @[@"contentNeedsReset", @"structureNeedsReset", @"relationsNeedReset", @"triggersNeedReset", @"infoNeedsReset"]) {
			XCTAssertTrue([self flag:flag], @"%@", flag);
		}
		[self.document.sidebar reloadSchema:@"Sales Data"];
		XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"Orders 2026"], @"%@", [self.document.sidebar itemTitlesInSection:@"TABLES"]);

		PGPostgresConnection *destination = [self destinationOn:port];
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM \"Sales Data\".\"Orders 2026\"" on:destination],
							  [self value:@"SELECT count(*)::text FROM \"Sales Data\".\"Orders 2026\"" on:source]);
	}];
}

- (void)testImportSQLErrorShowsLine
{
	[self onEachPortWithSetup:nil body:^(NSNumber *port) {
		NSString *path = [self write:@"CREATE TABLE public.first (i int);\nCREATE TABLE oops oops;\nCREATE TABLE public.third (i int);\n" named:@"bad.sql"];
		SPPostgresImportController *controller = [self newController];
		[controller importPath:path format:@"sql"];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertTrue([controller.lastErrorMessage hasPrefix:@"Line 2:"], @"%@", controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 1u, @"the error is shown");
		XCTAssertTrue([self.alerts.firstObject.informativeText hasPrefix:@"Line 2:"], @"%@", self.alerts.firstObject.informativeText);

		PGPostgresConnection *destination = [self destinationOn:port];
		XCTAssertFalse([self table:@"public.first" existsOn:destination], @"rolled back");
		XCTAssertFalse([self table:@"public.third" existsOn:destination]);
	}];
}

- (void)testPerStatementErrorChoice
{
	[self onEachPortWithSetup:nil body:^(NSNumber *port) {
		NSString *path = [self write:@"CREATE TABLE public.first (i int);\nCREATE TABLE oops oops;\nCREATE TABLE public.third (i int);\nSELECT * FROM nowhere;\nCREATE TABLE public.fifth (i int);\n" named:@"mixed.sql"];
		[self markPanesFresh];

		// The provider answers Ignore for each error
		SPPostgresImportController *controller = [self newController];
		controller.singleTransactionCheckbox.state = NSControlStateValueOff;
		NSMutableArray<NSString *> *asked = [NSMutableArray array];
		controller.errorChoiceProvider = ^SPPostgresImportErrorChoice(NSError *error) {
			XCTAssertTrue([NSThread isMainThread]);
			[asked addObject:error.localizedDescription];
			return SPPostgresImportIgnore;
		};
		[controller importPath:path format:@"sql"];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 0u);
		XCTAssertEqual(asked.count, 2u, @"%@", asked);
		XCTAssertTrue([asked.firstObject hasPrefix:@"Line 2:"], @"%@", asked.firstObject);

		PGPostgresConnection *destination = [self destinationOn:port];
		for (NSString *table in @[@"public.first", @"public.third", @"public.fifth"]) XCTAssertTrue([self table:table existsOn:destination], @"%@", table);
		XCTAssertTrue([self flag:@"contentNeedsReset"]);
		XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"fifth"], @"the sidebar was reloaded");

		// Without a provider, an alert on the progress sheet asks: Stop ends the import, keeping what committed
		[self run:@"DROP TABLE public.first, public.third, public.fifth" on:destination];
		controller = [self newController];
		controller.singleTransactionCheckbox.state = NSControlStateValueOff;
		[controller importPath:path format:@"sql"];
		__block NSWindow *alertWindow = nil;
		XCTAssertTrue([self spinUntil:^BOOL{
			alertWindow = controller.progressSheet.panel.attachedSheet;
			return alertWindow != nil;
		} timeout:20], @"the question is asked on the progress sheet");
		[controller.progressSheet.panel endSheet:alertWindow returnCode:NSAlertFirstButtonReturn]; // Stop
		XCTAssertTrue([self waitForEnd]);
		XCTAssertTrue([controller.lastErrorMessage hasPrefix:@"Line 2:"], @"%@", controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 0u, @"the user already saw the error");
		XCTAssertTrue([self table:@"public.first" existsOn:destination], @"committed before the error");
		XCTAssertFalse([self table:@"public.third" existsOn:destination], @"not run after Stop");
	}];
}

#pragma mark - CSV

- (void)testCSVMappingDefaultsByNameThenPosition
{
	[self onEachPortWithSetup:^(PGPostgresConnection *connection) {
		[self run:@"CREATE TABLE public.aaa_other (x int)" on:connection];
		[self run:@"CREATE TABLE public.t (a int, b text, c text)" on:connection];
	} body:^(NSNumber *port) {
		XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
		NSMutableString *csv = [NSMutableString stringWithString:@"B,a,zzz\n"];
		for (NSUInteger i = 1; i <= 12; i++) [csv appendFormat:@"b%lu,%lu,z%lu\n", (unsigned long)i, (unsigned long)i, (unsigned long)i];
		NSString *path = [self write:csv named:@"mapped.csv"];

		SPPostgresImportController *controller = [self newController];
		SPPostgresCSVMappingSheet *sheet = [self mappingSheetFor:path controller:controller];
		XCTAssertEqualObjects(sheet.tablePopup.titleOfSelectedItem, @"public.t", @"the sidebar's table");
		XCTAssertTrue([sheet.tablePopup.itemTitles containsObject:@"public.aaa_other"]);
		XCTAssertEqualObjects(sheet.tableColumnNames, (@[@"a", @"b", @"c"]));
		XCTAssertEqual([sheet columnPopups].count, 3u);
		XCTAssertEqualObjects([self selectedTitles:sheet], (@[@"a", @"B", @"— Not imported —"]));
		XCTAssertEqualObjects([[sheet columnPopups].firstObject itemTitles], (@[@"— Not imported —", @"B", @"a", @"zzz"]));
		XCTAssertEqualObjects([sheet mapping], (@[@1, @0, [NSNull null]]));

		// The preview: the first 10 rows, one column per CSV column
		NSTableView *preview = sheet.previewTable;
		XCTAssertEqual(preview.numberOfRows, 10);
		XCTAssertEqual(preview.numberOfColumns, 3);
		XCTAssertEqualObjects([preview.tableColumns[0].headerCell stringValue], @"B");
		XCTAssertEqualObjects([preview.dataSource tableView:preview objectValueForTableColumn:preview.tableColumns[0] row:0], @"b1");
		XCTAssertEqualObjects([preview.dataSource tableView:preview objectValueForTableColumn:preview.tableColumns[2] row:9], @"z10");

		// Another table: its columns, preset again
		[self choose:[sheet.tablePopup indexOfItemWithTitle:@"public.aaa_other"] inPopup:sheet.tablePopup];
		XCTAssertEqualObjects(sheet.tableColumnNames, @[@"x"]);
		XCTAssertEqualObjects([self selectedTitles:sheet], @[@"B"], @"no name matches: by position");

		[self click:sheet.cancelButton];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertNil(controller.mappingSheet);
		XCTAssertNil([self window].attachedSheet);
		XCTAssertEqualObjects(self.providedDatabases, @[], @"nothing ran");

		// Without a header the columns are "Column 1"…, mapped by position
		controller = [self newController];
		controller.csvOptions.header = NO;
		sheet = [self mappingSheetFor:path controller:controller];
		XCTAssertEqualObjects([self selectedTitles:sheet], (@[@"Column 1", @"Column 2", @"Column 3"]));
		XCTAssertEqual(sheet.previewTable.numberOfRows, 10);
		XCTAssertEqualObjects([sheet.previewTable.dataSource tableView:sheet.previewTable objectValueForTableColumn:sheet.previewTable.tableColumns[0] row:0], @"B");
		[self click:sheet.cancelButton];
		XCTAssertTrue([self waitForEnd]);
	}];
}

- (void)testCSVImportThroughSheet
{
	[self onEachPortWithSetup:^(PGPostgresConnection *connection) {
		[self run:@"CREATE TABLE public.t (a int, b text, c text DEFAULT 'dflt')" on:connection];
	} body:^(NSNumber *port) {
		XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
		NSString *path = [self write:@"B,a,zzz\nx,1,p\n\"y, why\",2,q\n" named:@"rows.csv"];
		[self markPanesFresh];

		SPPostgresImportController *controller = [self newController];
		SPPostgresCSVMappingSheet *sheet = [self mappingSheetFor:path controller:controller];
		NSPopUpButton *cPopup = [sheet columnPopups][2];
		[self choose:[cPopup indexOfItemWithTitle:@"zzz"] inPopup:cPopup];
		XCTAssertEqualObjects([sheet mapping], (@[@1, @0, @2]));
		[self click:sheet.importButton];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 0u);
		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_dst"]);

		PGPostgresConnection *destination = [self destinationOn:port];
		XCTAssertEqualObjects([self value:@"SELECT string_agg(a || '/' || b || '/' || c, '|' ORDER BY a) FROM public.t" on:destination], @"1/x/p|2/y, why/q");
		XCTAssertTrue([self flag:@"contentNeedsReset"], @"the Content pane is stale");
		XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"t", @"the selection is kept");

		// A server error rolls back and is shown
		NSString *bad = [self write:@"B,a,zzz\nx,1,p\ny,two,q\n" named:@"bad.csv"];
		controller = [self newController];
		sheet = [self mappingSheetFor:bad controller:controller];
		[self click:sheet.importButton];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertTrue([controller.lastErrorMessage containsString:@"line 2"], @"%@", controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM public.t" on:destination], @"2", @"rolled back");
	}];
}

- (void)testImportUsesItsOwnConnection
{
	[self onEachPortWithSetup:^(PGPostgresConnection *connection) {
		[self run:@"CREATE TABLE public.t (a int, b text, c text)" on:connection];
	} body:^(NSNumber *port) {
		PGPostgresConnection *mine = self.document.connection;
		[self run:@"BEGIN" on:mine];
		[self run:@"INSERT INTO public.t VALUES (99, 'mine', 'uncommitted')" on:mine];
		XCTAssertEqual(mine.transactionStatus, PGPostgresTransactionInTransaction);

		NSString *path = [self write:@"a,b,c\n1,x,p\n2,y,q\n" named:@"own.csv"];
		SPPostgresImportController *controller = [self newController];
		SPPostgresCSVMappingSheet *sheet = [self mappingSheetFor:path controller:controller];
		XCTAssertEqualObjects([sheet mapping], (@[@0, @1, @2]));
		[self click:sheet.importButton];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqualObjects(self.providedDatabases, @[@"pgkit_io_dst"], @"a connection of its own");

		// Committed on its own connection; the tab's transaction is still open, its row unseen by others
		PGPostgresConnection *other = [self destinationOn:port];
		XCTAssertEqualObjects([self value:@"SELECT string_agg(a::text, ',' ORDER BY a) FROM public.t" on:other], @"1,2");
		XCTAssertEqual(mine.transactionStatus, PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SELECT string_agg(a::text, ',' ORDER BY a) FROM public.t" on:mine], @"1,2,99");
		[self run:@"ROLLBACK" on:mine];
		XCTAssertEqualObjects([self value:@"SELECT string_agg(a::text, ',' ORDER BY a) FROM public.t" on:other], @"1,2");
	}];
}

#pragma mark - Final fix wave

/// The user's Query-view transaction holds an ACCESS EXCLUSIVE lock on a table the dump writes to: Cancel interrupts the
/// statement waiting on it, so the import ends cancelled within seconds. In one transaction nothing stays; per
/// statement, what committed before stays and nothing is asked.
- (void)testCancelInterruptsImportWaitingOnALock
{
	[self onEachPortWithSetup:^(PGPostgresConnection *connection) {
		[self run:@"CREATE TABLE public.locked (i int)" on:connection];
	} body:^(NSNumber *port) {
		PGPostgresConnection *mine = self.document.connection;
		[self run:@"BEGIN" on:mine];
		[self run:@"LOCK TABLE public.locked IN ACCESS EXCLUSIVE MODE" on:mine];
		PGPostgresConnection *watcher = [self destinationOn:port];
		NSString *path = [self write:@"CREATE TABLE public.before_lock (i int);\nINSERT INTO public.locked VALUES (1);\nCREATE TABLE public.after_lock (i int);\n" named:@"lock.sql"];

		for (NSNumber *single in @[@YES, @NO]) {
			SPPostgresImportController *controller = [self newController];
			__block NSUInteger asked = 0;
			controller.errorChoiceProvider = ^SPPostgresImportErrorChoice(NSError *error) {
				asked++;
				return SPPostgresImportIgnore;
			};
			controller.singleTransactionCheckbox.state = single.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
			[controller importPath:path format:@"sql"];
			BOOL waiting = [self spinUntil:^BOOL{
				return [[self value:@"SELECT count(*)::text FROM pg_catalog.pg_locks WHERE NOT granted AND relation = 'public.locked'::regclass" on:watcher] isEqualToString:@"1"];
			} timeout:20];
			XCTAssertTrue(waiting, @"the import waits on the lock");
			NSDate *cancelled = [NSDate date];
			[controller.progressSheet cancel:nil];
			XCTAssertTrue([self waitForEnd]);
			XCTAssertLessThan(-[cancelled timeIntervalSinceNow], 5.0, @"Cancel doesn't wait for the lock");
			XCTAssertEqualObjects(controller.lastErrorMessage, @"The import was cancelled.");
			XCTAssertEqual(asked, 0u, @"a cancel isn't an error to ask about");
			XCTAssertEqual(self.alerts.count, 0u);
			XCTAssertEqual([self table:@"public.before_lock" existsOn:watcher], !single.boolValue, @"single transaction %@", single);
			XCTAssertFalse([self table:@"public.after_lock" existsOn:watcher]);
			[self spinUntil:^BOOL{ return self.document.importController == nil && [self window].attachedSheet == nil; } timeout:10];
		}
		XCTAssertEqual(mine.transactionStatus, PGPostgresTransactionInTransaction, @"the user's transaction is untouched");
		[self run:@"ROLLBACK" on:mine];
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM public.locked" on:watcher], @"0");
	}];
}

/// A SET naming a parameter this server doesn't know is skipped, and the import's completion says so.
- (void)testUnknownSettingNamedOnCompletion
{
	[self onEachPortWithSetup:nil body:^(NSNumber *port) {
		NSString *path = [self write:@"SET sp_no_such_setting = 0;\nCREATE TABLE public.after_setting (i int);\n" named:@"setting.sql"];
		SPPostgresImportController *controller = [self newController];
		[controller importPath:path format:@"sql"];
		XCTAssertTrue([self waitForEnd]);
		XCTAssertNil(controller.lastErrorMessage);
		XCTAssertEqualObjects(controller.completionNote, @"1 setting this server doesn't know was skipped: sp_no_such_setting.");
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, @"The import finished");
		XCTAssertEqualObjects(self.alerts.firstObject.informativeText, controller.completionNote);
		XCTAssertTrue([self table:@"public.after_setting" existsOn:[self destinationOn:port]]);
	}];
}

#pragma mark - Menu

- (void)testImportMenuValidation
{
	[self onEachPortWithSetup:nil body:^(NSNumber *port) {
		NSMenuItem *import = [[NSMenuItem alloc] initWithTitle:@"Import…" action:@selector(import:) keyEquivalent:@""];
		NSMenuItem *clipboard = [[NSMenuItem alloc] initWithTitle:@"Import from Clipboard…" action:NSSelectorFromString(@"importFromClipboard:") keyEquivalent:@""];
		XCTAssertTrue([self.document validateMenuItem:import]);
		XCTAssertTrue([self.windowController validateMenuItem:import], @"reached through the window's forwarding");
		XCTAssertTrue([self.windowController respondsToSelector:@selector(import:)]);
		XCTAssertFalse([self.document validateMenuItem:clipboard]);
		XCTAssertFalse([self.windowController validateMenuItem:clipboard]);

		// Not while a sheet is attached
		NSPanel *other = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
		[[self window] beginSheet:other completionHandler:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == other; } timeout:5]);
		XCTAssertFalse([self.document validateMenuItem:import]);
		[[self window] endSheet:other];
		XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
		XCTAssertTrue([self.document validateMenuItem:import]);

		// The format follows the extension
		XCTAssertEqualObjects([SPPostgresImportController formatForPath:@"/x/a.csv"], @"csv");
		XCTAssertEqualObjects([SPPostgresImportController formatForPath:@"/x/a.TSV.gz"], @"csv");
		XCTAssertEqualObjects([SPPostgresImportController formatForPath:@"/x/a.csv.bz2"], @"csv");
		XCTAssertEqualObjects([SPPostgresImportController formatForPath:@"/x/a.sql.gz"], @"sql");
		XCTAssertEqualObjects([SPPostgresImportController formatForPath:@"/x/dump"], @"sql");
	}];
}

@end
