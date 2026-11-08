#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresCatalog.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresConnectionScreenAdapter.h"
#import "../Source/Postgres/SPPostgresFavoritesStore.h"

// App classes without exported symbols: looked up at run time
@interface NSObject (SPShowAllDatabasesTests)
- (void)loadNib;
@end

/// No passwords: nothing is read from or written to the login keychain.
@interface SPShowAllDatabasesNoKeychain : NSObject <SPPostgresKeychainAccess>
@end

@implementation SPShowAllDatabasesNoKeychain
- (void)addPassword:(NSString *)password forName:(NSString *)name account:(NSString *)account {}
- (NSString *)getPasswordForName:(NSString *)name account:(NSString *)account { return nil; }
- (void)deletePasswordForName:(NSString *)name account:(NSString *)account {}
- (BOOL)passwordExistsForName:(NSString *)name account:(NSString *)account { return NO; }
- (void)updateItemWithName:(NSString *)name account:(NSString *)account toName:(NSString *)newName account:(NSString *)newAccount password:(NSString *)password {}
@end

static const NSUInteger SPShowAllDatabasesTestPort = 55418;
static NSString * const SPShowAllDatabasesRole = @"sp_t4_dblist";
static NSString * const SPShowAllDatabasesPassword = @"Pw-sp_t4-dblist!";
static NSString * const SPShowAllDatabasesHidden = @"sp_t4_dblist_hidden";

/// The connection editor's "Show all databases" (MySQL and PostgreSQL), the favorite's setting, and the databases the catalog
/// lists (only those the user may connect to).
@interface SPPostgresShowAllDatabasesTests : XCTestCase
@property (strong) id controller;
@property (strong) SPPostgresConnectionScreenAdapter *adapter;
@end

@implementation SPPostgresShowAllDatabasesTests

- (void)tearDown
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPShowAllDatabasesTestPort];
	[admin execute:[NSString stringWithFormat:@"DROP DATABASE IF EXISTS %@", SPShowAllDatabasesHidden]];
	[SPPostgresTestServers dropTestRolesOnPort:SPShowAllDatabasesTestPort];
	[super tearDown];
}

#pragma mark - Favorite

- (void)testFavoriteKeepsTheSetting
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	XCTAssertTrue(favorite.showAllDatabases, @"on by default");
	XCTAssertNil([favorite dictionaryRepresentation][@"showAllDatabases"], @"on: not saved (the default)");

	favorite.showAllDatabases = NO;
	XCTAssertFalse(((SPPostgresFavorite *)[favorite copy]).showAllDatabases);
	NSDictionary *saved = [favorite dictionaryRepresentation];
	XCTAssertEqualObjects(saved[@"showAllDatabases"], @NO);
	XCTAssertFalse([SPPostgresFavorite favoriteWithDictionary:saved].showAllDatabases);

	// A favorite saved before the option shows every database
	NSMutableDictionary *older = [saved mutableCopy];
	[older removeObjectForKey:@"showAllDatabases"];
	XCTAssertTrue([SPPostgresFavorite favoriteWithDictionary:older].showAllDatabases);
}

#pragma mark - Databases listed

- (PGPostgresConnection *)loginAs:(NSString *)user password:(NSString *)password
{
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = SPShowAllDatabasesTestPort;
	connection.user = user;
	connection.password = password;
	connection.database = @"pgkit_test";
	[connection connect];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
	while (!connection.isConnected && !connection.connectionError && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	if (!connection.isConnected) {
		[connection disconnect];
		return nil;
	}
	[self addTeardownBlock:^{ [connection disconnect]; }];
	return connection;
}

- (void)testOnlyDatabasesTheUserMayConnectToAreListed
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPShowAllDatabasesTestPort];
	[admin execute:[NSString stringWithFormat:@"DROP DATABASE IF EXISTS %@", SPShowAllDatabasesHidden]];
	[SPPostgresTestServers dropTestRolesOnPort:SPShowAllDatabasesTestPort];
	XCTAssertNotNil(([admin execute:[NSString stringWithFormat:@"CREATE DATABASE %@", SPShowAllDatabasesHidden]]), @"%@", admin.lastError.errorPrimaryMessage);
	XCTAssertNotNil(([admin execute:[NSString stringWithFormat:@"REVOKE CONNECT ON DATABASE %@ FROM PUBLIC", SPShowAllDatabasesHidden]]));
	XCTAssertNotNil(([admin execute:[NSString stringWithFormat:@"CREATE ROLE %@ LOGIN PASSWORD '%@'", SPShowAllDatabasesRole, SPShowAllDatabasesPassword]]));

	// The superuser may connect to every database
	NSError *error = nil;
	NSArray *all = [[[SPPostgresCatalog alloc] initWithConnection:admin] databaseNames:&error];
	XCTAssertTrue([all containsObject:SPShowAllDatabasesHidden], @"%@ %@", all, error);
	XCTAssertTrue([all containsObject:@"pgkit_test"]);

	// The role: not the database it has no CONNECT on
	PGPostgresConnection *user = [self loginAs:SPShowAllDatabasesRole password:SPShowAllDatabasesPassword];
	XCTAssertNotNil(user);
	NSArray *listed = [[[SPPostgresCatalog alloc] initWithConnection:user] databaseNames:&error];
	XCTAssertNotNil(listed, @"%@", error);
	XCTAssertFalse([listed containsObject:SPShowAllDatabasesHidden], @"%@", listed);
	XCTAssertTrue([listed containsObject:@"pgkit_test"]);

	// Granted: listed
	XCTAssertNotNil(([admin execute:[NSString stringWithFormat:@"GRANT CONNECT ON DATABASE %@ TO %@", SPShowAllDatabasesHidden, SPShowAllDatabasesRole]]));
	listed = [[[SPPostgresCatalog alloc] initWithConnection:user] databaseNames:&error];
	XCTAssertTrue([listed containsObject:SPShowAllDatabasesHidden], @"%@", listed);
}

#pragma mark - Connection editor

static NSArray *SPShowAllDatabasesFormOutlets(void)
{
	return @[@"standardConnectionFormContainer", @"socketConnectionFormContainer", @"sshConnectionFormContainer"];
}

/// The connection screen on the real nib, with its adapter. `asLoaded`: per form outlet, before the adapter is
/// installed, the form's distance from the top, its height, and the Database and Port fields' frames.
- (void)loadConnectionScreenRecording:(NSDictionary **)asLoaded
{
	// Controllers are kept alive (the nib's objects outlive a test)
	static NSMutableArray *keepAlive;
	if (!keepAlive) keepAlive = [NSMutableArray array];
	self.controller = [[NSClassFromString(@"SPConnectionController") alloc] init];
	[keepAlive addObject:self.controller];
	[self.controller loadNib];
	if (asLoaded) {
		NSMutableDictionary *frames = [NSMutableDictionary dictionary];
		for (NSString *outlet in SPShowAllDatabasesFormOutlets()) {
			NSView *container = [self.controller valueForKey:outlet];
			frames[outlet] = @[@(NSHeight(container.superview.bounds) - NSMaxY(container.frame)), @(NSHeight(container.frame)),
			                   [NSValue valueWithRect:[self fieldBoundTo:@"database" in:container].frame],
			                   [NSValue valueWithRect:[self fieldBoundTo:@"port" in:container].frame]];
		}
		*asLoaded = frames;
	}
	// An adapter with a favorites tree of its own (never SPFavoritesController's) and no keychain
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initInMemory];
	self.adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:self.controller store:store];
	self.adapter.keychain = [[SPShowAllDatabasesNoKeychain alloc] init];
	[keepAlive addObjectsFromArray:@[store, self.adapter]];
	[self.adapter installEngineControlInContainer:[self.controller valueForKey:@"connectionResizeContainer"]];
	[self.controller setValue:self.adapter forKey:@"postgresAdapter"];
	[self.controller resizeTabViewToConnectionType:0 animating:NO];
}

- (void)loadConnectionScreen
{
	[self loadConnectionScreenRecording:NULL];
}

/// The checkbox in a form container.
- (NSButton *)checkboxIn:(NSView *)container
{
	for (NSView *view in [container subviews]) {
		if ([view isKindOfClass:[NSButton class]] && [[(NSButton *)view title] isEqualToString:@"Show all databases"]) return (NSButton *)view;
	}
	return nil;
}

- (NSView *)fieldBoundTo:(NSString *)keyPath in:(NSView *)container
{
	for (NSView *view in [container subviews]) {
		if ([[[view infoForBinding:NSValueBinding] objectForKey:NSObservedKeyPathKey] isEqualToString:keyPath]) return view;
	}
	return nil;
}

/// Every form shows the checkbox under its Database field, for MySQL and PostgreSQL alike (switching engines moves nothing).
- (void)checkFormsAgainst:(NSDictionary *)asLoaded engine:(NSString *)engineName
{
	for (NSString *outlet in SPShowAllDatabasesFormOutlets()) {
		NSView *container = [self.controller valueForKey:outlet];
		NSButton *checkbox = [self checkboxIn:container];
		NSView *database = [self fieldBoundTo:@"database" in:container];
		NSView *port = [self fieldBoundTo:@"port" in:container];
		XCTAssertNotNil(checkbox, @"%@ %@", engineName, outlet);
		XCTAssertFalse(checkbox.hidden, @"%@ %@", engineName, outlet);
		XCTAssertEqual(NSMinX(checkbox.frame), NSMinX(database.frame) - 2, @"%@ %@: aligned with the field", engineName, outlet);
		XCTAssertLessThanOrEqual(NSMaxY(checkbox.frame), NSMinY(database.frame), @"%@ %@: under the Database field", engineName, outlet);
		XCTAssertGreaterThanOrEqual(NSMinY(checkbox.frame), NSMaxY(port.frame), @"%@ %@: above the next row", engineName, outlet);
		XCTAssertEqual(NSHeight(container.superview.bounds) - NSMaxY(container.frame), [asLoaded[outlet][0] doubleValue], @"%@ %@: the form's top stays", engineName, outlet);
		XCTAssertEqual(NSHeight(container.frame), [asLoaded[outlet][1] doubleValue] + 26, @"%@ %@: grows by the row", engineName, outlet);
		XCTAssertEqual(NSMinY(database.frame), NSMinY([asLoaded[outlet][2] rectValue]) + 26, @"%@ %@: the Database row keeps its place from the top", engineName, outlet);
		XCTAssertTrue(NSEqualRects(port.frame, [asLoaded[outlet][3] rectValue]), @"%@ %@: the rows below move down with the bottom", engineName, outlet);
		XCTAssertTrue(NSContainsRect(container.bounds, checkbox.frame), @"%@ %@", engineName, outlet);
	}
}

- (void)testCheckboxUnderTheDatabaseFieldForMySQLAndPostgreSQL
{
	NSDictionary *asLoaded = nil;
	[self loadConnectionScreenRecording:&asLoaded];
	XCTAssertEqual(asLoaded.count, 3u);

	[self checkFormsAgainst:asLoaded engine:@"MySQL"];
	XCTAssertEqual([self checkboxIn:[self.controller valueForKey:@"standardConnectionFormContainer"]].state, NSControlStateValueOn, @"on by default");

	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	[self checkFormsAgainst:asLoaded engine:@"PostgreSQL"];

	// Screenshots of the forms, for a look
	NSString *directory = [[NSProcessInfo processInfo] environment][@"SP_FORM_SNAPSHOT_DIR"];
	if (directory.length) {
		NSView *container = [self.controller valueForKey:@"connectionResizeContainer"];
		for (NSString *engineName in @[@"PostgreSQL", @"MySQL"]) {
			[self.adapter setSelectedEngine:[engineName isEqualToString:@"MySQL"] ? SPConnectionEngineMySQL : SPConnectionEnginePostgreSQL];
			for (NSString *outlet in SPShowAllDatabasesFormOutlets()) {
				NSView *form = [self.controller valueForKey:outlet];
				NSView *tabView = form.superview.superview;
				NSTabView *tabs = [tabView isKindOfClass:[NSTabView class]] ? (NSTabView *)tabView : nil;
				for (NSTabViewItem *item in tabs.tabViewItems) if (item.view == form.superview) [tabs selectTabViewItem:item];
				[(id<SPPostgresConnectionScreenHost>)self.controller setType:(NSInteger)[SPShowAllDatabasesFormOutlets() indexOfObject:outlet]];
				[self.controller resizeTabViewToConnectionType:[SPShowAllDatabasesFormOutlets() indexOfObject:outlet] animating:NO];
				[container layoutSubtreeIfNeeded];
				NSBitmapImageRep *rep = [container bitmapImageRepForCachingDisplayInRect:container.bounds];
				[container cacheDisplayInRect:container.bounds toBitmapImageRep:rep];
				NSString *file = [NSString stringWithFormat:@"%@-%@.png", engineName, outlet];
				[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:file] atomically:YES];
			}
		}
		[(id<SPPostgresConnectionScreenHost>)self.controller setType:0];
		[self.controller resizeTabViewToConnectionType:0 animating:NO];
	}

	[self.adapter setSelectedEngine:SPConnectionEngineMySQL];
	[self checkFormsAgainst:asLoaded engine:@"MySQL again"];
}

/// Clicking the checkbox is an edit of the form: the Save Changes, Add to Favorites and Test Connection buttons show.
- (void)testClickingTheCheckboxShowsTheEditButtons
{
	for (NSNumber *engineNumber in @[@(SPConnectionEngineMySQL), @(SPConnectionEnginePostgreSQL)]) {
		[self loadConnectionScreen];
		[self.adapter setSelectedEngine:(SPConnectionEngine)engineNumber.integerValue];
		XCTAssertFalse([[self.controller valueForKey:@"isEditingConnection"] boolValue], @"engine %@", engineNumber);
		[[self checkboxIn:[self.controller valueForKey:@"standardConnectionFormContainer"]] performClick:nil];
		XCTAssertTrue([[self.controller valueForKey:@"isEditingConnection"] boolValue], @"engine %@", engineNumber);
		XCTAssertFalse([[self.controller valueForKey:@"editButtonsView"] isHidden], @"engine %@", engineNumber);
		XCTAssertFalse([(id)self.controller showAllDatabases], @"engine %@: the host reads the form's setting", engineNumber);
	}
}

/// Show all databases off: the Database field must be filled (connect, test, save; MySQL and PostgreSQL).
- (void)testDatabaseIsRequiredWhenNotShowingAll
{
	[self loadConnectionScreen];
	id<SPPostgresConnectionScreenHost> host = (id<SPPostgresConnectionScreenHost>)self.controller;
	[host setType:0];
	[host setHost:@"127.0.0.1"];
	[host setDatabase:@""];

	XCTAssertNil([self.adapter databaseOptionValidationError], @"on: no database needed");
	XCTAssertEqualObjects([[(NSTextField *)[self fieldBoundTo:@"database" in:[self.controller valueForKey:@"standardConnectionFormContainer"]] cell] placeholderString], @"optional");
	XCTAssertNil([self.adapter validationErrorForForm]);

	self.adapter.showAllDatabases = NO;
	NSError *error = [self.adapter databaseOptionValidationError];
	XCTAssertNotNil(error);
	XCTAssertEqualObjects(error.userInfo[NSLocalizedRecoverySuggestionErrorKey], @"Please enter a database, or turn on Show all databases.");
	XCTAssertNotNil([self.adapter validationErrorForForm], @"PostgreSQL connect and save check it");
	NSError *saveError = nil;
	XCTAssertFalse([self.adapter saveFormAsNewFavorite:&saveError]);
	XCTAssertEqualObjects(saveError.userInfo[NSLocalizedRecoverySuggestionErrorKey], @"Please enter a database, or turn on Show all databases.");

	NSTextField *databaseField = (NSTextField *)[self fieldBoundTo:@"database" in:[self.controller valueForKey:@"standardConnectionFormContainer"]];
	XCTAssertEqualObjects([databaseField.cell placeholderString], @"required");
	XCTAssertEqualObjects([databaseField infoForBinding:NSValueBinding][NSOptionsKey][NSNullPlaceholderBindingOption], @"required", @"also for a nil database");
	XCTAssertEqualObjects([databaseField infoForBinding:NSValueBinding][NSObservedKeyPathKey], @"database", @"still bound");
	[host setDatabase:nil];
	XCTAssertEqualObjects([databaseField.cell placeholderString], @"required");

	[host setDatabase:@"   "];
	XCTAssertNotNil([self.adapter databaseOptionValidationError], @"spaces are no database");

	[host setDatabase:@"pgkit_test"];
	XCTAssertNil([self.adapter databaseOptionValidationError]);
	XCTAssertNil([self.adapter validationErrorForForm]);

	self.adapter.showAllDatabases = YES;
	XCTAssertEqualObjects([databaseField.cell placeholderString], @"optional", @"the nib's placeholder again");
	XCTAssertEqualObjects([databaseField infoForBinding:NSValueBinding][NSOptionsKey][NSNullPlaceholderBindingOption], @"optional");
	XCTAssertEqualObjects(databaseField.stringValue, @"pgkit_test", @"the binding still shows the value");
}

- (void)testCheckboxIsSavedInTheFavorite
{
	[self loadConnectionScreen];
	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	NSButton *checkbox = [self checkboxIn:[self.controller valueForKey:@"standardConnectionFormContainer"]];
	NSButton *sshCheckbox = [self checkboxIn:[self.controller valueForKey:@"sshConnectionFormContainer"]];

	XCTAssertTrue([self.adapter favoriteFromForm].showAllDatabases);
	[checkbox performClick:nil];
	XCTAssertFalse(self.adapter.showAllDatabases);
	XCTAssertEqual(sshCheckbox.state, NSControlStateValueOff, @"every tab's checkbox follows");
	XCTAssertFalse([self.adapter favoriteFromForm].showAllDatabases);

	// A favorite loaded into the form sets it
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"all";
	favorite.host = @"127.0.0.1";
	[self.adapter loadFavoriteIntoForm:favorite];
	XCTAssertEqual(checkbox.state, NSControlStateValueOn);
	favorite.showAllDatabases = NO;
	[self.adapter loadFavoriteIntoForm:favorite];
	XCTAssertEqual(checkbox.state, NSControlStateValueOff);

	// Quick Connect: on again
	[self.adapter didSelectMySQLItemIsFavorite:NO];
	XCTAssertEqual(checkbox.state, NSControlStateValueOn);
	XCTAssertTrue([self.adapter favoriteFromForm].showAllDatabases);
}

@end
