#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresUsersController.h"
#import "../Source/Postgres/SPPostgresRoles.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static NSString * const SPUsersTestToolbarUsers = @"SwitchToUserManagerToolbarItemIdentifier";

/// The Users sheet (SPPostgresUsersController) and its wiring into SPPostgresDocument, on PG 12 and 18.
@interface SPPostgresUsersControllerTests : XCTestCase
@property (strong) NSWindow *window;
@property (strong) NSMutableArray<SPPostgresUsersController *> *controllers;
@property (strong) NSMutableArray<NSNumber *> *completions;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
// Document tests
@property (strong) SPWindowController *windowController;
@property (strong) SPPostgresDocument *document;
@end

@implementation SPPostgresUsersControllerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.controllers = [NSMutableArray array];
	self.completions = [NSMutableArray array];
	self.alerts = [NSMutableArray array];
	self.openConnections = [NSMutableArray array];
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 900, 700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;

	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[SPPostgresTestServers dropTestRolesOnPort:port.unsignedIntegerValue];
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"DROP TABLE IF EXISTS public.sp_t4_owned" on:connection];
		[self run:@"CREATE ROLE sp_t4_group NOLOGIN" on:connection];
		[self run:@"CREATE ROLE sp_t4_login LOGIN PASSWORD 'Pw-sp_t4!' IN ROLE sp_t4_group" on:connection];
		[self run:@"CREATE ROLE sp_t4_owner LOGIN" on:connection];
		[self run:@"CREATE TABLE public.sp_t4_owned (id int)" on:connection];
		[self run:@"ALTER TABLE public.sp_t4_owned OWNER TO sp_t4_owner" on:connection];
	}
}

- (void)tearDown
{
	for (SPPostgresUsersController *controller in self.controllers) [controller endSheet];
	if (self.window.attachedSheet) [self.window endSheet:self.window.attachedSheet];
	[self.window orderOut:nil];
	self.controllers = nil;

	if (self.windowController) {
		NSWindow *window = [self.windowController window];
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		NSTabView *tabView = [self.windowController valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
		self.document = nil;
		self.windowController = nil;
	}

	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		[connection execute:@"DROP TABLE IF EXISTS public.sp_t4_owned"];
		[connection disconnect];
		[SPPostgresTestServers dropTestRolesOnPort:port.unsignedIntegerValue];
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
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	[self.openConnections addObject:connection];
	return connection;
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	if (!result.numberOfRows) return nil;
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// A provider handing out fresh test-server connections on port (synchronously).
- (void (^)(NSString *, void (^)(PGPostgresConnection *, NSError *)))providerOn:(NSNumber *)port
{
	return ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:database];
		completion(connection, connection ? nil : [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no connection"}]);
	};
}

/// The sheet, begun on the test window for pgkit_test on port; its completion's value lands in self.completions.
- (SPPostgresUsersController *)beginOn:(NSNumber *)port
{
	SPPostgresUsersController *controller = [[SPPostgresUsersController alloc] initWithDatabase:@"pgkit_test" connectionProvider:[self providerOn:port]];
	__weak SPPostgresUsersControllerTests *weakSelf = self;
	controller.alertPresenter = ^(NSAlert *alert) { [weakSelf.alerts addObject:alert]; };
	[self.controllers addObject:controller];
	[controller beginSheetForWindow:self.window completion:^(BOOL applied) { [weakSelf.completions addObject:@(applied)]; }];
	XCTAssertNotNil(controller.sheet, @"port %@: %@", port, controller.lastErrorMessage);
	XCTAssertEqual(self.window.attachedSheet, controller.sheet, @"port %@", port);
	return controller;
}

- (void)waitForEndOf:(SPPostgresUsersController *)controller
{
	XCTAssertTrue([self spinUntil:^BOOL{ return self.window.attachedSheet == nil; } timeout:5]);
	XCTAssertEqual(self.completions.count, 1u);
}

- (NSInteger)rowOf:(NSString *)name in:(SPPostgresUsersController *)controller
{
	NSUInteger index = [[controller.editedRoles valueForKey:@"name"] indexOfObject:name];
	return index == NSNotFound ? -1 : (NSInteger)index;
}

- (NSTableCellView *)cellOf:(NSString *)name in:(SPPostgresUsersController *)controller
{
	NSInteger row = [self rowOf:name in:controller];
	XCTAssertGreaterThanOrEqual(row, 0, @"%@", name);
	return (NSTableCellView *)[controller tableView:controller.rolesTable viewForTableColumn:controller.rolesTable.tableColumns.firstObject row:row];
}

- (NSTextField *)subtitleIn:(NSView *)cell
{
	for (NSView *view in cell.subviews) if ([view.identifier isEqualToString:@"subtitle"]) return (NSTextField *)view;
	return nil;
}

- (void)select:(NSString *)name in:(SPPostgresUsersController *)controller
{
	XCTAssertTrue([controller selectRoleNamed:name], @"%@", name);
	XCTAssertEqualObjects(controller.selectedRole.name, name);
	XCTAssertEqualObjects(controller.nameField.stringValue, name);
}

/// The role's attributes as "login inherit super createdb createrole replication bypassrls connlimit validuntil".
- (NSString *)attributesOf:(NSString *)role on:(PGPostgresConnection *)connection
{
	return [self value:[NSString stringWithFormat:@"SELECT concat_ws(' ', rolcanlogin, rolinherit, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolconnlimit, coalesce(nullif(rolvaliduntil, 'infinity')::text, 'never')) FROM pg_catalog.pg_roles WHERE rolname = '%@'", role] on:connection];
}

- (NSArray<NSString *> *)groupsOf:(NSString *)role on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:[NSString stringWithFormat:@"SELECT g.rolname::text FROM pg_catalog.pg_auth_members a JOIN pg_catalog.pg_roles m ON m.oid = a.member JOIN pg_catalog.pg_roles g ON g.oid = a.roleid WHERE m.rolname = '%@' ORDER BY 1", role]];
	NSMutableArray *names = [NSMutableArray array];
	for (unsigned long long row = 0; row < result.numberOfRows; row++) [names addObject:[result textValueAtRow:row column:0]];
	return names;
}

#pragma mark - The sheet

- (void)testSheetListsRolesAndShowsGeneral
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresUsersController *controller = [self beginOn:port];
		XCTAssertTrue(NSEqualSizes(controller.sheet.contentView.frame.size, NSMakeSize(760, 520)), @"%@", NSStringFromSize(controller.sheet.contentView.frame.size));
		XCTAssertTrue(NSEqualSizes(controller.sheet.contentMinSize, NSMakeSize(680, 460)));
		XCTAssertTrue(controller.sheet.styleMask & NSWindowStyleMaskResizable);
		XCTAssertEqualObjects([controller.tabView.tabViewItems valueForKey:@"label"], (@[@"General", @"Membership", @"Privileges"]));

		NSArray *names = [controller.editedRoles valueForKey:@"name"];
		XCTAssertTrue([names containsObject:@"sp_t4_login"]);
		XCTAssertTrue([names containsObject:@"sp_t4_group"]);
		for (NSString *name in names) XCTAssertFalse([name hasPrefix:@"pg_"], @"predefined roles are hidden: %@", name);

		NSTableCellView *login = [self cellOf:@"sp_t4_login" in:controller];
		XCTAssertEqualObjects(login.textField.stringValue, @"sp_t4_login");
		XCTAssertEqualObjects([self subtitleIn:login].stringValue ?: @"", @"");
		XCTAssertEqualObjects(login.imageView.image.name, NSImageNameUser);
		NSTableCellView *group = [self cellOf:@"sp_t4_group" in:controller];
		XCTAssertEqualObjects([self subtitleIn:group].stringValue, @"group, no login");
		XCTAssertEqualObjects(group.imageView.image.name, NSImageNameUserGroup);
		XCTAssertEqualObjects([self subtitleIn:[self cellOf:@"pgkit_test" in:controller]].stringValue, @"superuser");

		[self select:@"sp_t4_login" in:controller];
		XCTAssertEqualObjects(controller.passwordField.stringValue, @"", @"the password is never shown");
		XCTAssertEqual(controller.loginCheckbox.state, NSControlStateValueOn);
		XCTAssertEqual(controller.inheritCheckbox.state, NSControlStateValueOn);
		XCTAssertEqual(controller.superuserCheckbox.state, NSControlStateValueOff);
		XCTAssertEqual(controller.createDBCheckbox.state, NSControlStateValueOff);
		XCTAssertEqual(controller.clearPasswordCheckbox.state, NSControlStateValueOff);
		XCTAssertEqual(controller.validUntilCheckbox.state, NSControlStateValueOff);
		XCTAssertFalse(controller.validUntilPicker.isEnabled);
		XCTAssertEqualObjects(controller.connectionLimitField.stringValue, @"");
		XCTAssertEqualObjects(controller.connectionLimitField.placeholderString, @"-1 = unlimited");
		XCTAssertEqualObjects(controller.passwordField.placeholderString, @"unchanged");
		XCTAssertEqualObjects(controller.bypassRLSCheckbox.title, @"Bypass row-level security");
		XCTAssertEqual(controller.selectedRole.hasMD5Password, port.unsignedIntegerValue == 55412, @"PG12 stores md5, PG18 scram");

		// Membership: sp_t4_group ticked; predefined roles offered
		NSUInteger groupRow = [controller.memberOfCandidates indexOfObject:@"sp_t4_group"];
		XCTAssertNotEqual(groupRow, NSNotFound);
		XCTAssertTrue([controller.memberOfCandidates containsObject:@"pg_monitor"]);
		XCTAssertFalse([controller.memberOfCandidates containsObject:@"sp_t4_login"], @"not itself");
		NSTableColumn *member = [controller.memberOfTable tableColumnWithIdentifier:@"member"];
		XCTAssertEqualObjects([controller tableView:controller.memberOfTable objectValueForTableColumn:member row:(NSInteger)groupRow], @YES);
		XCTAssertFalse(controller.applyButton.isEnabled, @"nothing changed");
		XCTAssertEqual(controller.sheet.defaultButtonCell, controller.applyButton.cell, @"Apply is the default button");

		[controller cancel:nil];
		[self waitForEndOf:controller];
		[self.completions removeAllObjects];
	}
}

- (void)testAddEditApplyCreatesRole
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresUsersController *controller = [self beginOn:port];
		NSUInteger count = controller.editedRoles.count;
		[controller addRole:nil];
		XCTAssertEqual(controller.editedRoles.count, count + 1);
		XCTAssertNil(controller.selectedRole.originalName);
		controller.nameField.stringValue = @"sp_t4_ui";
		controller.connectionLimitField.stringValue = @"4";
		[controller.createDBCheckbox performClick:nil];
		XCTAssertTrue(controller.applyButton.isEnabled);

		[controller apply:nil];
		[self waitForEndOf:controller];
		XCTAssertEqualObjects(self.completions.firstObject, @YES);
		XCTAssertNil(controller.lastErrorMessage);

		PGPostgresConnection *check = [self connectOn:port];
		XCTAssertEqualObjects([self attributesOf:@"sp_t4_ui" on:check], @"f t f t f f f 4 never");
		[self.completions removeAllObjects];
	}
}

- (void)testCancelDiscardsEverything
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresUsersController *controller = [self beginOn:port];
		[self select:@"sp_t4_login" in:controller];
		controller.nameField.stringValue = @"sp_t4_renamed";
		[controller.superuserCheckbox performClick:nil];
		XCTAssertTrue(controller.applyButton.isEnabled);

		[controller cancel:nil];
		[self waitForEndOf:controller];
		XCTAssertEqualObjects(self.completions.firstObject, @NO);

		PGPostgresConnection *check = [self connectOn:port];
		XCTAssertEqualObjects([self attributesOf:@"sp_t4_login" on:check], @"t t f f f f f -1 never");
		XCTAssertNil([self attributesOf:@"sp_t4_renamed" on:check]);
		[self.completions removeAllObjects];
	}
}

- (void)testDuplicateCopiesAttributesAndMemberships
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *check = [self connectOn:port];
		[self run:@"ALTER ROLE sp_t4_login CREATEDB CONNECTION LIMIT 3 VALID UNTIL '2031-02-03 04:05:06+00'" on:check];

		SPPostgresUsersController *controller = [self beginOn:port];
		[self select:@"sp_t4_login" in:controller];
		[controller duplicateRole:nil];
		XCTAssertEqualObjects(controller.selectedRole.name, @"sp_t4_login_copy");
		XCTAssertEqualObjects(controller.nameField.stringValue, @"sp_t4_login_copy");
		XCTAssertNil(controller.selectedRole.originalName);
		XCTAssertEqualObjects(controller.selectedRole.memberOf, @{@"sp_t4_group": @NO});
		XCTAssertEqualObjects(controller.selectedRole.members, @{});
		XCTAssertFalse(controller.selectedRole.hasMD5Password);
		XCTAssertTrue(controller.applyButton.isEnabled);

		[controller apply:nil];
		[self waitForEndOf:controller];
		XCTAssertEqualObjects(self.completions.firstObject, @YES);

		NSString *expected = [self attributesOf:@"sp_t4_login" on:check];
		XCTAssertTrue([expected hasPrefix:@"t t f t f f f 3 2031-02-03"], @"%@", expected);
		XCTAssertEqualObjects([self attributesOf:@"sp_t4_login_copy" on:check], expected);
		XCTAssertEqualObjects([self groupsOf:@"sp_t4_login_copy" on:check], @[@"sp_t4_group"]);
		XCTAssertEqualObjects([self value:@"SELECT (rolpassword IS NULL)::text FROM pg_catalog.pg_authid WHERE rolname = 'sp_t4_login_copy'" on:check], @"true", @"no password copied");

		// A second duplicate gets _copy2
		controller = [self beginOn:port];
		[self select:@"sp_t4_login" in:controller];
		[controller duplicateRole:nil];
		XCTAssertEqualObjects(controller.selectedRole.name, @"sp_t4_login_copy2");
		[controller cancel:nil];
		[self.completions removeAllObjects];
		XCTAssertTrue([self spinUntil:^BOOL{ return self.window.attachedSheet == nil; } timeout:5]);
		[self.completions removeAllObjects];
	}
}

- (void)testRemoveMarksThenApplyDrops
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresUsersController *controller = [self beginOn:port];

		// − on a new role just removes it
		NSUInteger count = controller.editedRoles.count;
		[controller addRole:nil];
		[controller removeRole:nil];
		XCTAssertEqual(controller.editedRoles.count, count);
		XCTAssertFalse(controller.applyButton.isEnabled);

		[self select:@"sp_t4_group" in:controller];
		XCTAssertTrue(controller.removeButton.isEnabled);
		[controller removeRole:nil];
		XCTAssertTrue(controller.selectedRole.markedForDeletion);
		XCTAssertEqual(controller.editedRoles.count, count, @"still listed until Apply");
		NSTableCellView *cell = [self cellOf:@"sp_t4_group" in:controller];
		NSNumber *strike = [cell.textField.attributedStringValue attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL];
		XCTAssertEqual(strike.integerValue, NSUnderlineStyleSingle, @"marked for deletion: struck through");
		XCTAssertFalse(controller.nameField.isEnabled, @"a role marked for deletion isn't edited");
		XCTAssertTrue(controller.applyButton.isEnabled);

		[controller apply:nil];
		[self waitForEndOf:controller];
		XCTAssertEqualObjects(self.completions.firstObject, @YES);
		PGPostgresConnection *check = [self connectOn:port];
		XCTAssertNil([self attributesOf:@"sp_t4_group" on:check]);
		XCTAssertNotNil([self attributesOf:@"sp_t4_login" on:check]);
		[self.completions removeAllObjects];
	}
}

- (void)testRemoveDisabledForSessionRole
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresUsersController *controller = [self beginOn:port];
		[self select:@"pgkit_test" in:controller];
		XCTAssertFalse(controller.removeButton.isEnabled, @"the connected role can't be removed");
		[controller removeRole:nil];
		XCTAssertFalse(controller.selectedRole.markedForDeletion);
		[self select:@"sp_t4_login" in:controller];
		XCTAssertTrue(controller.removeButton.isEnabled);
		[controller cancel:nil];
		[self waitForEndOf:controller];
		[self.completions removeAllObjects];
	}
}

- (void)testApplyFailureKeepsSheetAndEdits
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresUsersController *controller = [self beginOn:port];
		[self select:@"sp_t4_owner" in:controller];
		[controller removeRole:nil];
		[self select:@"sp_t4_login" in:controller];
		[controller.createRoleCheckbox performClick:nil];

		[controller apply:nil];
		XCTAssertTrue([controller.lastErrorMessage containsString:@"\"sp_t4_owner\" cannot be dropped"], @"%@", controller.lastErrorMessage);
		XCTAssertTrue([controller.lastErrorMessage containsString:@"owner of table sp_t4_owned"], @"the DETAIL list: %@", controller.lastErrorMessage);
		XCTAssertEqual(self.alerts.count, 1u, @"the error is shown");
		XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"cannot be dropped"], @"%@", self.alerts.firstObject.informativeText);
		[self spinUntil:^BOOL{ return NO; } timeout:0.2];
		XCTAssertEqual(self.window.attachedSheet, controller.sheet, @"the sheet stays");
		XCTAssertEqual(self.completions.count, 0u);

		// Both edits still pending, nothing applied
		SPPostgresRole *owner = controller.editedRoles[(NSUInteger)[self rowOf:@"sp_t4_owner" in:controller]];
		SPPostgresRole *login = controller.editedRoles[(NSUInteger)[self rowOf:@"sp_t4_login" in:controller]];
		XCTAssertTrue(owner.markedForDeletion);
		XCTAssertTrue(login.createRole);
		XCTAssertTrue(controller.applyButton.isEnabled);
		PGPostgresConnection *check = [self connectOn:port];
		XCTAssertNotNil([self attributesOf:@"sp_t4_owner" on:check]);
		XCTAssertEqualObjects([self attributesOf:@"sp_t4_login" on:check], @"t t f f f f f -1 never");

		[controller cancel:nil];
		[self waitForEndOf:controller];
		[self.completions removeAllObjects];
		[self.alerts removeAllObjects];
	}
}

/// R2: on PG12 (password_encryption md5) a rename silently clears an MD5 password, so the sheet asks for a new one.
- (void)testRenameMD5LoginNeedsNewPassword
{
	NSNumber *port = @55412;
	PGPostgresConnection *raw = [self connectOn:port];
	[self run:@"SET password_encryption = 'md5'" on:raw];
	[self run:@"ALTER ROLE sp_t4_login PASSWORD 'Old-pw-1'" on:raw];
	XCTAssertEqualObjects([self value:@"SELECT left(rolpassword, 3) FROM pg_catalog.pg_authid WHERE rolname = 'sp_t4_login'" on:raw], @"md5");

	SPPostgresUsersController *controller = [self beginOn:port];
	[self select:@"sp_t4_login" in:controller];
	XCTAssertTrue(controller.selectedRole.hasMD5Password);
	controller.nameField.stringValue = @"sp_t4_login2";

	[controller apply:nil];
	XCTAssertEqualObjects(controller.lastErrorMessage, @"Renaming “sp_t4_login” clears its MD5 password. Enter a new password for “sp_t4_login2” too.");
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqual(self.window.attachedSheet, controller.sheet);
	XCTAssertEqual(self.completions.count, 0u);
	XCTAssertNotNil([self attributesOf:@"sp_t4_login" on:raw], @"nothing sent");
	XCTAssertNil([self attributesOf:@"sp_t4_login2" on:raw]);

	// With a new password it goes ahead
	controller.passwordField.stringValue = @"New-pw-2";
	[controller apply:nil];
	[self waitForEndOf:controller];
	XCTAssertEqualObjects(self.completions.firstObject, @YES);
	XCTAssertNil([self attributesOf:@"sp_t4_login" on:raw]);
	XCTAssertEqualObjects([self value:@"SELECT (rolpassword IS NOT NULL)::text FROM pg_catalog.pg_authid WHERE rolname = 'sp_t4_login2'" on:raw], @"true");
}

#pragma mark - The document

- (void)buildDocument
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 users";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = 55418;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

	self.windowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.windowController window]);

	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *error) {
		connection = theConnection;
		done = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection);

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	__weak SPPostgresUsersControllerTests *weakSelf = self;
	self.document.alertPresenter = ^(NSAlert *alert) { [weakSelf.alerts addObject:alert]; };
	[self.windowController addTabDocument:self.document atIndex:0 select:YES];

	// As SPPostgresDocumentTests: a sheet attaches to the nib's window once it has been shown (kept off screen)
	[[self.windowController window] setFrameOrigin:NSMakePoint(-10000, -10000)];
	[self.windowController showWindow:nil];
}

- (void)testUsersSheetNeverUsesTheDocumentConnection
{
	[self buildDocument];
	PGPostgresConnection *documentConnection = self.document.connection;
	[self run:@"BEGIN" on:documentConnection];
	[self run:@"CREATE TEMPORARY TABLE sp_t4_pending (id int)" on:documentConnection];
	[self run:@"INSERT INTO sp_t4_pending VALUES (1)" on:documentConnection];
	XCTAssertEqual(documentConnection.transactionStatus, PGPostgresTransactionInTransaction);

	__block NSUInteger provided = 0;
	void (^provider)(NSString *, void (^)(PGPostgresConnection *, NSError *)) = [self providerOn:@55418];
	self.document.usersConnectionProvider = ^(NSString *database, void (^completion)(PGPostgresConnection *, NSError *)) {
		provided++;
		XCTAssertEqualObjects(database, @"pgkit_test");
		provider(database, completion);
	};
	NSWindow *window = [self.windowController window];
	[self.document showUserManager:nil];
	SPPostgresUsersController *controller = self.document.usersController;
	XCTAssertNotNil(controller);
	XCTAssertEqual(provided, 1u);
	XCTAssertEqual(window.attachedSheet, controller.sheet);

	[self select:@"sp_t4_login" in:controller];
	[controller.createDBCheckbox performClick:nil];
	[controller apply:nil];
	XCTAssertNil(controller.lastErrorMessage);
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil && self.document.usersController == nil; } timeout:5]);

	PGPostgresConnection *check = [self connectOn:@55418];
	XCTAssertEqualObjects([self attributesOf:@"sp_t4_login" on:check], @"t t f t f f f -1 never");
	XCTAssertEqual(documentConnection.transactionStatus, PGPostgresTransactionInTransaction, @"the user's transaction is untouched");
	XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM sp_t4_pending" on:documentConnection], @"1");
	[self run:@"ROLLBACK" on:documentConnection];
}

- (void)testUsersToolbarItemAndMenuEnabled
{
	[self buildDocument];
	NSToolbarItem *item = [self.document toolbar:self.document.toolbar itemForItemIdentifier:SPUsersTestToolbarUsers willBeInsertedIntoToolbar:NO];
	XCTAssertEqual(item.action, @selector(showUserManager:));
	XCTAssertEqual(item.target, self.document);
	XCTAssertTrue([self.document validateToolbarItem:item]);
	NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:@"User Accounts…" action:@selector(showUserManager:) keyEquivalent:@""];
	XCTAssertTrue([self.document validateMenuItem:menuItem]);

	// The default provider: a connector of its own for the same favorite and password (connects later)
	NSWindow *window = [self.windowController window];
	[self.document showUserManager:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:20], @"%@", self.alerts);
	SPPostgresUsersController *controller = self.document.usersController;
	XCTAssertEqual(window.attachedSheet, controller.sheet);
	XCTAssertTrue([[controller.editedRoles valueForKey:@"name"] containsObject:@"sp_t4_login"]);

	// Not while a sheet is attached
	XCTAssertFalse([self.document validateToolbarItem:item]);
	XCTAssertFalse([self.document validateMenuItem:menuItem]);
	[controller endSheet];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil && self.document.usersController == nil; } timeout:5]);
	XCTAssertTrue([self.document validateToolbarItem:item]);
}

@end
