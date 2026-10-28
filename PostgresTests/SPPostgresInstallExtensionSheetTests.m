#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresInstallExtensionSheet.h"
#import "../Source/Postgres/SPPostgresExtensions.h"

/// The Install Extension sheet, on PG 12 and 18, in database pgkit_ext, on an offscreen window.
@interface SPPostgresInstallExtensionSheetTests : XCTestCase
@property (strong) NSWindow *window;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray *completions;
@end

@implementation SPPostgresInstallExtensionSheetTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.alerts = [NSMutableArray array];
	self.completions = [NSMutableArray array];
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 900, 700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
}

- (void)tearDown
{
	[[SPPostgresInstallExtensionSheet currentSheet] cancel:nil];
	if (self.window.attachedSheet) [self.window endSheet:self.window.attachedSheet];
	[self spinUntil:^BOOL{ return [SPPostgresInstallExtensionSheet currentSheet] == nil; } timeout:2];
	[self.window orderOut:nil];
	self.window = nil;
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[[SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue] disconnect];
	}
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

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

/// Opens the sheet on the window (default schema public); its alerts are recorded, its completions too.
- (SPPostgresInstallExtensionSheet *)sheetOn:(PGPostgresConnection *)connection
{
	[self.completions removeAllObjects];
	[self.alerts removeAllObjects];
	NSMutableArray *completions = self.completions;
	[SPPostgresInstallExtensionSheet beginWithConnection:connection schema:@"public" window:self.window completion:^(NSString *name) {
		[completions addObject:name ?: (id)[NSNull null]];
	}];
	SPPostgresInstallExtensionSheet *sheet = [SPPostgresInstallExtensionSheet currentSheet];
	XCTAssertNotNil(sheet);
	XCTAssertNotNil(self.window.attachedSheet);
	NSMutableArray *alerts = self.alerts;
	sheet.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	return sheet;
}

- (NSArray<NSString *> *)listedNamesIn:(SPPostgresInstallExtensionSheet *)sheet
{
	NSTableView *table = sheet.extensionsTable;
	NSTableColumn *column = [table tableColumnWithIdentifier:@"name"];
	NSMutableArray *names = [NSMutableArray array];
	for (NSInteger row = 0; row < table.numberOfRows; row++) {
		[names addObject:[table.dataSource tableView:table objectValueForTableColumn:column row:row]];
	}
	return names;
}

- (NSArray<NSString *> *)installedOn:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:@"SELECT extname::text FROM pg_extension ORDER BY 1"];
	NSMutableArray *names = [NSMutableArray array];
	for (NSUInteger row = 0; row < result.numberOfRows; row++) [names addObject:[result textValueAtRow:row column:0]];
	return names;
}

- (void)filter:(SPPostgresInstallExtensionSheet *)sheet with:(NSString *)text
{
	sheet.filterField.stringValue = text;
	[NSApp sendAction:sheet.filterField.action to:sheet.filterField.target from:sheet.filterField];
}

- (void)choose:(NSString *)title in:(NSPopUpButton *)popup
{
	XCTAssertTrue([popup.itemTitles containsObject:title], @"%@ in %@", title, popup.itemTitles);
	[popup selectItemWithTitle:title];
	[NSApp sendAction:popup.action to:popup.target from:popup];
}

#pragma mark - Tests

- (void)testListsOnlyUninstalledAndFilters
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		XCTAssertNotNil([connection execute:@"CREATE EXTENSION citext"]);
		SPPostgresInstallExtensionSheet *sheet = [self sheetOn:connection];

		XCTAssertEqualObjects(self.window.attachedSheet.title, @"Install Extension");
		XCTAssertEqual(NSWidth([self.window.attachedSheet contentRectForFrameRect:self.window.attachedSheet.frame]), 560);
		XCTAssertTrue(self.window.attachedSheet.styleMask & NSWindowStyleMaskResizable);
		XCTAssertEqualObjects([sheet.extensionsTable.tableColumns valueForKeyPath:@"headerCell.stringValue"], (@[@"Name", @"Default version", @"Description"]));

		NSArray *names = [self listedNamesIn:sheet];
		XCTAssertFalse([names containsObject:@"citext"], @"%@: installed", port);
		XCTAssertFalse([names containsObject:@"plpgsql"], @"installed");
		XCTAssertTrue([names containsObject:@"hstore"], @"%@", names);
		XCTAssertFalse(sheet.installButton.isEnabled, @"nothing selected");

		[self filter:sheet with:@"earth"];
		XCTAssertEqualObjects([self listedNamesIn:sheet], @[@"earthdistance"]);
		[self filter:sheet with:@"EARTH"];
		XCTAssertEqualObjects([self listedNamesIn:sheet], @[@"earthdistance"], @"case-insensitive");

		// The description matches too
		[self filter:sheet with:@"(KEY, value)"];
		XCTAssertTrue([[self listedNamesIn:sheet] containsObject:@"hstore"], @"%@", [self listedNamesIn:sheet]);

		[self filter:sheet with:@""];
		XCTAssertEqualObjects([self listedNamesIn:sheet], names);

		[sheet cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.completions.count == 1; } timeout:5]);
	}
}

- (void)testSheetShowsAlsoInstalls
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresInstallExtensionSheet *sheet = [self sheetOn:connection];
		XCTAssertTrue(sheet.alsoInstallsLabel.isHidden);

		XCTAssertTrue([sheet selectExtensionNamed:@"earthdistance"], @"%@", port);
		XCTAssertTrue(sheet.installButton.isEnabled);
		XCTAssertFalse(sheet.alsoInstallsLabel.isHidden);
		XCTAssertEqualObjects(sheet.alsoInstallsLabel.stringValue, @"Also installs: cube");

		XCTAssertTrue([sheet selectExtensionNamed:@"hstore"]);
		XCTAssertTrue(sheet.alsoInstallsLabel.isHidden);

		XCTAssertFalse([sheet selectExtensionNamed:@"no_such_extension"]);
		[sheet cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.completions.count == 1; } timeout:5]);
	}
}

- (void)testInstallWithVersionAndSchema
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		XCTAssertNotNil([connection execute:@"DROP SCHEMA IF EXISTS sp_t5_other"]);
		XCTAssertNotNil([connection execute:@"CREATE SCHEMA sp_t5_other"]);
		SPPostgresInstallExtensionSheet *sheet = [self sheetOn:connection];

		XCTAssertTrue([sheet selectExtensionNamed:@"hstore"], @"%@", port);
		SPPostgresAvailableExtension *hstore = nil;
		for (SPPostgresAvailableExtension *available in [[[SPPostgresExtensions alloc] initWithConnection:connection] availableExtensions:NULL]) {
			if ([available.name isEqualToString:@"hstore"]) hstore = available;
		}
		XCTAssertEqualObjects(sheet.versionPopup.itemTitles, hstore.versions);
		XCTAssertEqualObjects(sheet.versionPopup.titleOfSelectedItem, hstore.defaultVersion, @"the default preselected");
		XCTAssertTrue([sheet.schemaPopup.itemTitles containsObject:@"sp_t5_other"]);
		XCTAssertEqualObjects(sheet.schemaPopup.titleOfSelectedItem, @"public", @"the given default");
		XCTAssertTrue(sheet.schemaPopup.isEnabled);

		[self choose:@"sp_t5_other" in:sheet.schemaPopup];
		[self choose:@"1.4" in:sheet.versionPopup];
		[self choose:@"public" in:sheet.schemaPopup];
		[sheet install:sheet.installButton];

		XCTAssertTrue([self spinUntil:^BOOL{ return self.completions.count == 1; } timeout:5]);
		XCTAssertEqualObjects(self.completions, @[@"hstore"]);
		XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
		XCTAssertNil(self.window.attachedSheet);
		XCTAssertNil([SPPostgresInstallExtensionSheet currentSheet]);
		PGPostgresResult *result = [connection execute:@"SELECT e.extversion::text, n.nspname::text FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'hstore'"];
		XCTAssertEqual(result.numberOfRows, 1u);
		XCTAssertEqualObjects([result textValueAtRow:0 column:0], @"1.4");
		XCTAssertEqualObjects([result textValueAtRow:0 column:1], @"public");
		XCTAssertNotNil([connection execute:@"DROP SCHEMA IF EXISTS sp_t5_other"]);
	}
}

/// An extension whose control file fixes its schema shows that schema, disabled.
- (void)testFixedSchemaShownDisabled
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		PGPostgresResult *result = [connection execute:@"SELECT a.name::text, v.schema::text FROM pg_available_extensions a JOIN pg_available_extension_versions v ON v.name = a.name AND v.version = a.default_version WHERE v.schema IS NOT NULL AND a.installed_version IS NULL ORDER BY 1 LIMIT 1"];
		if (result.numberOfRows == 0) continue; // none on this server
		NSString *name = [result textValueAtRow:0 column:0];
		NSString *schema = [result textValueAtRow:0 column:1];

		SPPostgresInstallExtensionSheet *sheet = [self sheetOn:connection];
		XCTAssertTrue([sheet selectExtensionNamed:name], @"%@", name);
		XCTAssertEqualObjects(sheet.schemaPopup.titleOfSelectedItem, schema, @"%@", port);
		XCTAssertFalse(sheet.schemaPopup.isEnabled);

		// Back to a relocatable one: the chosen schema again, enabled
		XCTAssertTrue([sheet selectExtensionNamed:@"hstore"]);
		XCTAssertEqualObjects(sheet.schemaPopup.titleOfSelectedItem, @"public");
		XCTAssertTrue(sheet.schemaPopup.isEnabled);
		[sheet cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.completions.count == 1; } timeout:5]);
	}
}

- (void)testInstallFailureKeepsSheetOpen
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresInstallExtensionSheet *sheet = [self sheetOn:connection];
		NSWindow *attached = self.window.attachedSheet;
		XCTAssertTrue([sheet selectExtensionNamed:@"hstore"], @"%@", port);

		// Behind the sheet's back
		XCTAssertNotNil([connection execute:@"CREATE EXTENSION hstore"]);
		[sheet install:sheet.installButton];

		XCTAssertTrue([sheet.lastErrorMessage containsString:@"already exists"], @"%@", sheet.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"already exists"], @"%@", self.alerts.firstObject.informativeText);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, @"Could not install the extension “hstore”");
		[self spinUntil:^BOOL{ return NO; } timeout:0.2];
		XCTAssertEqual(self.window.attachedSheet, attached, @"still open");
		XCTAssertEqual([SPPostgresInstallExtensionSheet currentSheet], sheet);
		XCTAssertEqual(self.completions.count, 0u);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);

		[sheet cancel:nil];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.completions.count == 1; } timeout:5]);
		XCTAssertEqualObjects(self.completions, @[[NSNull null]]);
	}
}

- (void)testCancelInstallsNothing
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSArray *before = [self installedOn:connection];
		SPPostgresInstallExtensionSheet *sheet = [self sheetOn:connection];
		XCTAssertTrue([sheet selectExtensionNamed:@"earthdistance"], @"%@", port);
		[sheet.cancelButton performClick:nil];

		XCTAssertTrue([self spinUntil:^BOOL{ return self.completions.count == 1; } timeout:5]);
		[self spinUntil:^BOOL{ return NO; } timeout:0.2];
		XCTAssertEqualObjects(self.completions, @[[NSNull null]], @"called once, with nil");
		XCTAssertNil(self.window.attachedSheet);
		XCTAssertNil([SPPostgresInstallExtensionSheet currentSheet]);
		XCTAssertEqualObjects([self installedOn:connection], before);
	}
}

@end
