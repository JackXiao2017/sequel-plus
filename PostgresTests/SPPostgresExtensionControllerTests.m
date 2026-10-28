#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresExtensionController.h"
#import "../Source/Postgres/SPPostgresExtensions.h"

/// A data layer whose update-targets read fails (the server can't be made to fail only that read).
@interface SPFailingTargetsExtensions : SPPostgresExtensions
@end

@implementation SPFailingTargetsExtensions
- (NSArray *)updateTargetsForExtension:(NSString *)name error:(NSError **)error
{
	if (error) *error = [NSError errorWithDomain:@"SPTest" code:1 userInfo:@{NSLocalizedDescriptionKey: @"could not open extension control file"}];
	return nil;
}
@end

/// The test seam: the pane's data layer is made by -newExtensionsWithConnection:.
@interface SPPostgresExtensionController (SPTestSeam)
- (SPPostgresExtensions *)newExtensionsWithConnection:(PGPostgresConnection *)connection;
@end

/// A pane whose update-targets read fails.
@interface SPFailingTargetsExtensionController : SPPostgresExtensionController
@end

@implementation SPFailingTargetsExtensionController
- (SPPostgresExtensions *)newExtensionsWithConnection:(PGPostgresConnection *)connection
{
	return [[SPFailingTargetsExtensions alloc] initWithConnection:connection];
}
@end

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

/// An installed extension whose control file is gone (renamed in pg_extension, so the server has none for it): the
/// pane shows it with Drop enabled, sends no update-paths read, and leaves the user's transaction open.
- (void)testMissingControlFileKeepsDetailsAndDrop
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self.alerts removeAllObjects];
		[self.dropRequests removeAllObjects];
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"citext" version:nil on:connection];
		XCTAssertNotNil([connection execute:@"UPDATE pg_catalog.pg_extension SET extname = 'sp_t5_ghost' WHERE extname = 'citext'"]);

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		SPPostgresExtensionController *pane = [self paneOn:connection];
		[pane showExtension:@"sp_t5_ghost"];
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction, @"%@", port);
		XCTAssertNotNil([connection execute:@"SELECT 1"]);
		XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
		XCTAssertNotNil(pane.extension);
		XCTAssertEqualObjects(pane.nameField.stringValue, @"sp_t5_ghost");
		XCTAssertGreaterThan(pane.versionField.stringValue.length, 0u);
		XCTAssertTrue(pane.dropButton.isEnabled);
		XCTAssertFalse(pane.updateButton.isEnabled);
		XCTAssertTrue(pane.updatePopup.isHidden);
		XCTAssertFalse(pane.noUpdateLabel.isHidden);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);

		[pane.dropButton performClick:nil];
		XCTAssertEqualObjects(self.dropRequests, @[@"sp_t5_ghost"]);
	}
}

/// The update targets can't be read: the details stay, Drop stays enabled, Update is off and the error is shown.
- (void)testTargetsReadFailureKeepsDetailsAndDrop
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self.alerts removeAllObjects];
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"hstore" version:@"1.4" on:connection];

		SPPostgresExtensionController *pane = [[SPFailingTargetsExtensionController alloc] initWithConnection:connection];
		NSMutableArray *alerts = self.alerts;
		pane.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
		pane.delegate = self;
		[self addTeardownBlock:^{ [pane invalidate]; }];

		[pane showExtension:@"hstore"];
		XCTAssertNotNil(pane.extension, @"%@", port);
		XCTAssertEqualObjects(pane.nameField.stringValue, @"hstore");
		XCTAssertEqualObjects(pane.versionField.stringValue, @"1.4");
		XCTAssertTrue(pane.dropButton.isEnabled);
		XCTAssertFalse(pane.updateButton.isEnabled);
		XCTAssertTrue(pane.updatePopup.isHidden);
		XCTAssertFalse(pane.noUpdateLabel.isHidden);
		XCTAssertEqual(self.alerts.count, 1u);
		XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"control file"], @"%@", self.alerts.firstObject.informativeText);
	}
}

/// Update inside an aborted transaction is refused without sending: one alert, and the pane keeps the extension.
- (void)testFailedUpdateInAbortedTransactionKeepsPane
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self.alerts removeAllObjects];
		[self.changed removeAllObjects];
		PGPostgresConnection *connection = [self connectOn:port];
		[self install:@"hstore" version:@"1.4" on:connection];

		SPPostgresExtensionController *pane = [self paneOn:connection];
		[pane showExtension:@"hstore"];
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		[pane update:pane.updateButton];

		XCTAssertEqual(self.alerts.count, 1u, @"%@: %@", port, [self.alerts valueForKey:@"informativeText"]);
		XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"aborted"], @"%@", self.alerts.firstObject.informativeText);
		XCTAssertEqualObjects(self.changed, @[]);
		XCTAssertEqualObjects(pane.nameField.stringValue, @"hstore");
		XCTAssertEqualObjects(pane.versionField.stringValue, @"1.4");
		XCTAssertTrue(pane.dropButton.isEnabled);
		XCTAssertTrue(pane.updateButton.isEnabled);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInError);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
	}
}

@end
