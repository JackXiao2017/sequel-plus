#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresExtensionController.h"
#import "../Source/Postgres/SPPostgresExtensions.h"

/// The Extension pane, on PG 12 and 18, in database pgkit_ext.
@interface SPPostgresExtensionControllerTests : XCTestCase <SPPostgresExtensionControllerDelegate>
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<NSString *> *changed;
@property (strong) NSMutableArray<NSString *> *dropRequests;
@end

@implementation SPPostgresExtensionControllerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.alerts = [NSMutableArray array];
	self.changed = [NSMutableArray array];
	self.dropRequests = [NSMutableArray array];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[[SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue] disconnect];
	}
	[super tearDown];
}

#pragma mark - Delegate

- (void)extensionController:(SPPostgresExtensionController *)controller didChangeExtension:(NSString *)name
{
	[self.changed addObject:name];
}

- (void)extensionController:(SPPostgresExtensionController *)controller wantsToDropExtension:(NSString *)name
{
	[self.dropRequests addObject:name];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers extensionTestConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

- (SPPostgresExtensionController *)paneOn:(PGPostgresConnection *)connection
{
	SPPostgresExtensionController *pane = [[SPPostgresExtensionController alloc] initWithConnection:connection];
	NSMutableArray *alerts = self.alerts;
	pane.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	pane.delegate = self;
	[self addTeardownBlock:^{ [pane invalidate]; }];
	return pane;
}

- (void)install:(NSString *)name version:(NSString *)version on:(PGPostgresConnection *)connection
{
	SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
	NSError *error = nil;
	XCTAssertTrue([extensions installExtension:name version:version schema:@"public" error:&error], @"%@: %@", name, error);
}

- (NSString *)defaultVersionOf:(NSString *)name on:(PGPostgresConnection *)connection
{
	SPPostgresExtensions *extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
	SPPostgresExtension *extension = [extensions extensionNamed:name error:NULL];
	XCTAssertNotNil(extension.defaultVersion, @"%@", name);
	return extension.defaultVersion;
}

#pragma mark - Tests

- (void)testPaneShowsDetailsAndUpdateTargets
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"hstore" version:@"1.4" on:connection];
		NSString *defaultVersion = [self defaultVersionOf:@"hstore" on:connection];
		NSString *defaultTitle = [defaultVersion stringByAppendingString:@" (default)"];

		SPPostgresExtensionController *pane = [self paneOn:connection];
		[pane showExtension:@"hstore"];
		XCTAssertEqualObjects(pane.extensionName, @"hstore");
		XCTAssertEqualObjects(pane.nameField.stringValue, @"hstore", @"%@", port);
		XCTAssertEqualObjects(pane.versionField.stringValue, @"1.4");
		XCTAssertEqualObjects(pane.schemaField.stringValue, @"public");
		XCTAssertGreaterThan(pane.commentField.stringValue.length, 0u);
		XCTAssertTrue(pane.requiredByField.isHidden, @"nothing requires hstore");

		NSArray *titles = pane.updatePopup.itemTitles;
		XCTAssertTrue([titles containsObject:@"1.5"], @"%@", titles);
		XCTAssertTrue([titles containsObject:defaultTitle], @"%@", titles);
		XCTAssertFalse([titles containsObject:defaultVersion], @"the default is marked: %@", titles);
		XCTAssertEqualObjects(titles.firstObject, @"1.5", @"sorted: %@", titles);
		XCTAssertEqualObjects(pane.updatePopup.titleOfSelectedItem, defaultTitle, @"the default is preselected");
		XCTAssertEqualObjects(pane.updatePopup.selectedItem.representedObject, defaultVersion);
		XCTAssertFalse(pane.updatePopup.isHidden);
		XCTAssertTrue(pane.updateButton.isEnabled);
		XCTAssertTrue(pane.noUpdateLabel.isHidden);
		XCTAssertTrue(pane.dropButton.isEnabled);
		XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

		// Nothing shown: empty, the buttons off
		[pane showExtension:nil];
		XCTAssertEqualObjects(pane.nameField.stringValue, @"");
		XCTAssertFalse(pane.updateButton.isEnabled);
		XCTAssertFalse(pane.dropButton.isEnabled);
	}
}

- (void)testUpdateFromPane
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self.changed removeAllObjects];
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"hstore" version:@"1.4" on:connection];
		NSString *defaultVersion = [self defaultVersionOf:@"hstore" on:connection];

		SPPostgresExtensionController *pane = [self paneOn:connection];
		[pane showExtension:@"hstore"];
		[pane update:pane.updateButton];

		XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
		XCTAssertEqualObjects([[connection execute:@"SELECT extversion::text FROM pg_extension WHERE extname = 'hstore'"] textValueAtRow:0 column:0], defaultVersion, @"%@", port);
		XCTAssertEqualObjects(pane.versionField.stringValue, defaultVersion);
		XCTAssertFalse(pane.noUpdateLabel.isHidden);
		XCTAssertEqualObjects(pane.noUpdateLabel.stringValue, @"No other version available");
		XCTAssertTrue(pane.updatePopup.isHidden);
		XCTAssertFalse(pane.updateButton.isEnabled);
		XCTAssertEqualObjects(self.changed, @[@"hstore"]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);
	}
}

/// The server refuses (the extension went away meanwhile): its message is shown, and no change is reported.
- (void)testUpdateFailureShowsAlert
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self.alerts removeAllObjects];
		[self.changed removeAllObjects];
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"hstore" version:@"1.4" on:connection];

		SPPostgresExtensionController *pane = [self paneOn:connection];
		[pane showExtension:@"hstore"];
		XCTAssertNotNil([connection execute:@"DROP EXTENSION hstore"]);
		[pane update:pane.updateButton];

		XCTAssertEqual(self.alerts.count, 1u, @"%@", port);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, @"Could not update the extension “hstore”");
		XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"hstore"], @"%@", self.alerts.firstObject.informativeText);
		XCTAssertEqualObjects(self.changed, @[]);
		XCTAssertFalse(pane.updateButton.isEnabled, @"the pane read again: not installed");
	}
}

- (void)testRequiredByShown
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self.dropRequests removeAllObjects];
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"earthdistance" version:nil on:connection];

		SPPostgresExtensionController *pane = [self paneOn:connection];
		[pane showExtension:@"cube"];
		XCTAssertFalse(pane.requiredByField.isHidden, @"%@", port);
		XCTAssertEqualObjects(pane.requiredByField.stringValue, @"Required by: earthdistance");
		XCTAssertTrue(pane.updatePopup.isHidden);
		XCTAssertFalse(pane.noUpdateLabel.isHidden);
		XCTAssertFalse(pane.updateButton.isEnabled);

		// Drop asks the delegate
		[pane.dropButton performClick:nil];
		XCTAssertEqualObjects(self.dropRequests, @[@"cube"]);
		XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	}
}

@end
