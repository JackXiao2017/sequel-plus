#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresConnectionScreenAdapter.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoritesStore.h"
#import "../Source/Postgres/SPPostgresWindowController.h"

@interface NSObject (SPPGConnectionControllerForTests)
- (void)resizeTabViewToConnectionType:(NSUInteger)theType animating:(BOOL)animate;
@end

#pragma mark - Test doubles

/// Stands in for SPConnectionController: the same form properties, no nib, no document window.
@interface SPPGFakeConnectionScreen : NSObject <SPPostgresConnectionScreenHost>
@property (readwrite, assign) NSInteger type;
@property (readwrite, retain) NSString *name;
@property (readwrite, retain) NSString *host;
@property (readwrite, retain) NSString *user;
@property (readwrite, retain) NSString *password;
@property (readwrite, retain) NSString *database;
@property (readwrite, retain) NSString *socket;
@property (readwrite, retain) NSString *port;
@property (readwrite, assign) NSInteger useSSL;
@property (readwrite, assign) NSInteger colorIndex;
@property (readwrite, assign) NSInteger sslKeyFileLocationEnabled;
@property (readwrite, retain) NSString *sslKeyFileLocation;
@property (readwrite, assign) NSInteger sslCertificateFileLocationEnabled;
@property (readwrite, retain) NSString *sslCertificateFileLocation;
@property (readwrite, assign) NSInteger sslCACertFileLocationEnabled;
@property (readwrite, retain) NSString *sslCACertFileLocation;
@property (readwrite, retain) NSString *sshHost;
@property (readwrite, retain) NSString *sshUser;
@property (readwrite, retain) NSString *sshPassword;
@property (readwrite, assign) NSInteger sshKeyLocationEnabled;
@property (readwrite, retain) NSString *sshKeyLocation;
@property (readwrite, retain) NSString *sshPort;
@property (assign) NSUInteger favoritesChangedCount;
@property (assign) BOOL connecting;
@property (assign) NSUInteger connectingCalls;
@end

@implementation SPPGFakeConnectionScreen
- (void)postgresFavoritesDidChange { self.favoritesChangedCount++; }
- (void)postgresSetConnecting:(BOOL)connecting { self.connecting = connecting; self.connectingCalls++; }
@end

/// In-memory keychain so the tests never touch the login keychain.
@interface SPPGFakeKeychain : NSObject <SPPostgresKeychainAccess>
@property (strong) NSMutableDictionary *items;
@end

@implementation SPPGFakeKeychain
- (instancetype)init { if ((self = [super init])) _items = [NSMutableDictionary dictionary]; return self; }
- (NSString *)k:(NSString *)name account:(NSString *)account { return [NSString stringWithFormat:@"%@|%@", name, account]; }
- (void)addPassword:(NSString *)password forName:(NSString *)name account:(NSString *)account { self.items[[self k:name account:account]] = password; }
- (NSString *)getPasswordForName:(NSString *)name account:(NSString *)account { return self.items[[self k:name account:account]]; }
- (void)deletePasswordForName:(NSString *)name account:(NSString *)account { [self.items removeObjectForKey:[self k:name account:account]]; }
- (BOOL)passwordExistsForName:(NSString *)name account:(NSString *)account { return self.items[[self k:name account:account]] != nil; }
- (void)updateItemWithName:(NSString *)name account:(NSString *)account toName:(NSString *)newName account:(NSString *)newAccount password:(NSString *)password
{
	[self deletePasswordForName:name account:account];
	[self addPassword:password forName:newName account:newAccount];
}
@end

#pragma mark - Tests

@interface SPPostgresConnectionScreenAdapterTests : XCTestCase
@property (strong) NSURL *dir;
@property (strong) SPPostgresFavoritesStore *store;
@property (strong) SPPGFakeConnectionScreen *screen;
@property (strong) SPPGFakeKeychain *keychain;
@property (strong) SPPostgresConnectionScreenAdapter *adapter;
@end

@implementation SPPostgresConnectionScreenAdapterTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	NSString *name = [@"SPPGAdapterTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
	self.store = [[SPPostgresFavoritesStore alloc] initWithFileURL:[self.dir URLByAppendingPathComponent:@"PostgresFavorites.plist"]];
	self.screen = [[SPPGFakeConnectionScreen alloc] init];
	self.keychain = [[SPPGFakeKeychain alloc] init];
	self.adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:self.screen store:self.store];
	self.adapter.keychain = self.keychain;
}

- (void)tearDown
{
	[self.adapter invalidate];
	self.adapter = nil;
	[[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
}

- (SPPostgresFavorite *)fullFavorite
{
	SPPostgresFavorite *f = [[SPPostgresFavorite alloc] init];
	f.name = @"Prod";
	f.colorIndex = 3;
	f.type = SPPostgresSSHConnection;
	f.host = @"db.example.com";
	f.port = 6543;
	f.user = @"alice";
	f.database = @"appdb";
	f.socketPath = @"/tmp/.s.PGSQL.6543";
	f.useSSL = YES;
	f.sslCACertPath = @"/ca.pem";
	f.sslCertPath = @"/cert.pem";
	f.sslKeyPath = @"/key.pem";
	f.sshHost = @"bastion";
	f.sshUser = @"bob";
	f.sshPort = 2222;
	f.sshKeyPath = @"~/.ssh/id_ed25519";
	return f;
}

- (void)testFormRoundTripsFavorite
{
	SPPostgresFavorite *original = [self fullFavorite];
	[self.keychain addPassword:@"pw" forName:[original keychainName] account:[original keychainAccount]];
	[self.keychain addPassword:@"sshpw" forName:[original sshKeychainName] account:[original sshKeychainAccount]];

	[self.adapter loadFavoriteIntoForm:original];

	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEnginePostgreSQL);
	XCTAssertEqualObjects(self.screen.host, @"db.example.com");
	XCTAssertEqualObjects(self.screen.port, @"6543");
	XCTAssertEqual(self.screen.type, (NSInteger)SPPostgresSSHConnection);
	XCTAssertEqualObjects(self.screen.password, @"pw");
	XCTAssertEqualObjects(self.screen.sshPassword, @"sshpw");

	SPPostgresFavorite *roundTripped = [self.adapter favoriteFromForm];
	XCTAssertEqualObjects([roundTripped dictionaryRepresentation], [original dictionaryRepresentation]);
}

- (void)testSavingPostgresFavoriteWritesOnlyPostgresStore
{
	// R4: read-only snapshot of the real MySQL favorites file (shared with Sequel Pro 1.1.2)
	NSString *mysqlFavorites = [@"~/Library/Application Support/Sequel Pro/Data/Favorites.plist" stringByExpandingTildeInPath];
	NSData *before = [NSData dataWithContentsOfFile:mysqlFavorites];

	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.name = @"Local PG";
	self.screen.host = @"127.0.0.1";
	self.screen.port = @"55418";
	self.screen.user = @"pgkit_test";
	self.screen.password = @"secret";
	self.screen.database = @"pgkit_test";

	NSError *error = nil;
	XCTAssertTrue([self.adapter saveFormAsFavorite:&error], @"%@", error);

	NSArray *saved = [self.store favorites];
	XCTAssertEqual([saved count], 1u);
	SPPostgresFavorite *favorite = saved[0];
	XCTAssertEqualObjects(favorite.name, @"Local PG");
	XCTAssertEqual(favorite.port, 55418u);
	XCTAssertEqualObjects([self.keychain getPasswordForName:[favorite keychainName] account:[favorite keychainAccount]], @"secret");
	XCTAssertTrue([[favorite keychainName] hasPrefix:@"Sequel Pro (PostgreSQL)"]);

	// The new favorite shows in the POSTGRESQL section
	NSArray *nodes = [self.adapter favoriteNodesForOutline];
	XCTAssertEqual([nodes count], 1u);
	XCTAssertTrue([self.adapter isPostgresNode:nodes[0]]);
	XCTAssertEqualObjects([[self.adapter favoriteForNode:nodes[0]] favoriteID], favorite.favoriteID);
	XCTAssertGreaterThan(self.screen.favoritesChangedCount, 0u);

	NSData *after = [NSData dataWithContentsOfFile:mysqlFavorites];
	XCTAssertTrue((before == nil && after == nil) || [before isEqualToData:after], @"Favorites.plist changed");
}

- (void)testTCPIPFavoriteWithEmptyHostIsRejected
{
	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.host = @"";
	NSError *error = nil;
	XCTAssertFalse([self.adapter saveFormAsFavorite:&error]);
	XCTAssertNotNil(error);
	XCTAssertNotNil([self.adapter validationErrorForForm]);
	XCTAssertEqual([[self.store favorites] count], 0u);
}

- (void)testMySQLFavoriteWithoutEngineKeyIsNotPostgres
{
	// SPTreeNode / SPFavoriteNode are app classes without exported symbols: look them up at run time
	Class treeNodeClass = NSClassFromString(@"SPTreeNode");
	Class favoriteNodeClass = NSClassFromString(@"SPFavoriteNode");
	XCTAssertNotNil(treeNodeClass);
	XCTAssertNotNil(favoriteNodeClass);

	NSMutableDictionary *mysqlFavorite = [@{ @"name": @"MySQL prod", @"host": @"db", @"type": @0, @"id": @12345 } mutableCopy];
	id favoriteNode = [favoriteNodeClass performSelector:@selector(favoriteNodeWithDictionary:) withObject:mysqlFavorite];
	id treeNode = [treeNodeClass treeNodeWithRepresentedObject:favoriteNode];

	XCTAssertFalse([self.adapter isPostgresNode:treeNode]);
	XCTAssertFalse([self.adapter isPostgresNode:nil]);
	XCTAssertFalse([self.adapter isPostgresNode:@"not a node"]);
}

- (void)testEngineSwitchSetsDefaultPort
{
	// A container shaped like the connection screen: a tab view whose port field is bound to "port"
	NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 446, 472)];
	NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(3, 61, 440, 417)];
	NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"1"];
	NSView *itemView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 371)];
	NSTextField *portField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 100, 22)];
	[[portField cell] setPlaceholderString:@"3306"];
	// As in ConnectionView.xib: the binding's null placeholder shows the default port
	[portField bind:NSValueBinding toObject:self.screen withKeyPath:@"port" options:@{ NSNullPlaceholderBindingOption: @"3306", NSContinuouslyUpdatesValueBindingOption: @YES }];
	[itemView addSubview:portField];
	[item setView:itemView];
	[tabView addTabViewItem:item];
	[container addSubview:tabView];

	CGFloat extra = [self.adapter installEngineControlInContainer:container];
	XCTAssertGreaterThan(extra, 0);
	NSSegmentedControl *control = [self.adapter engineControl];
	XCTAssertEqual([control superview], container);
	XCTAssertEqualObjects([control labelForSegment:0], @"MySQL");
	XCTAssertEqualObjects([control labelForSegment:1], @"PostgreSQL");
	XCTAssertGreaterThanOrEqual(NSMinY([control frame]), NSMaxY([tabView frame]) - 8, @"control sits above the tabs");
	XCTAssertEqualWithAccuracy(NSMidX([control frame]), NSMidX([container bounds]), 1.0, @"control is centred");
	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEngineMySQL);

	self.screen.port = nil;
	XCTAssertEqualObjects([[portField cell] placeholderString], @"3306");
	[control setSelectedSegment:SPConnectionEnginePostgreSQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEnginePostgreSQL);
	XCTAssertEqualObjects([[portField cell] placeholderString], @"5432");
	self.screen.port = @"";
	XCTAssertEqualObjects([[portField cell] placeholderString], @"5432");
	self.screen.port = nil;
	XCTAssertEqualObjects([[portField cell] placeholderString], @"5432");
	self.screen.host = @"127.0.0.1";
	XCTAssertEqual([[self.adapter favoriteFromForm] port], 5432u);

	[control setSelectedSegment:SPConnectionEngineMySQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEngineMySQL);
	XCTAssertEqualObjects([[portField cell] placeholderString], @"3306");
	self.screen.port = @"";
	XCTAssertEqualObjects([[portField cell] placeholderString], @"3306");
	XCTAssertEqualObjects([[portField infoForBinding:NSValueBinding] objectForKey:NSObservedKeyPathKey], @"port", @"binding restored");

	[portField unbind:NSValueBinding];
}

/// The real ConnectionView nib (owned by a bare SPConnectionController, no document): the control fits
/// above the tabs, the tab view keeps its height, and the two port fields switch placeholder.
- (void)testEngineControlFitsTheRealConnectionForm
{
	static NSMutableArray *keepAlive; // the bare controller can't be deallocated (it never registered its observers)
	if (!keepAlive) keepAlive = [NSMutableArray array];

	id controller = [[NSClassFromString(@"SPConnectionController") alloc] init];
	XCTAssertNotNil(controller);
	[keepAlive addObject:controller];
	[controller performSelector:@selector(loadNib)];

	NSView *container = [controller valueForKey:@"connectionResizeContainer"];
	XCTAssertNotNil(container);
	NSTabView *tabView = nil;
	for (NSView *subview in [container subviews]) if ([subview isKindOfClass:[NSTabView class]]) tabView = (NSTabView *)subview;
	XCTAssertNotNil(tabView);

	// Form height without the control
	[controller resizeTabViewToConnectionType:0 animating:NO];
	CGFloat containerHeightBefore = NSHeight([container frame]);
	CGFloat tabHeightBefore = NSHeight([tabView frame]);

	SPPostgresConnectionScreenAdapter *adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:controller store:self.store];
	adapter.keychain = self.keychain;
	CGFloat extra = [adapter installEngineControlInContainer:container];
	[controller setValue:adapter forKey:@"postgresAdapter"];

	[controller resizeTabViewToConnectionType:0 animating:NO];
	XCTAssertEqualWithAccuracy(NSHeight([container frame]), containerHeightBefore + extra, 0.5);
	XCTAssertEqualWithAccuracy(NSHeight([tabView frame]), tabHeightBefore, 0.5, @"tabs keep their height");

	NSRect controlFrame = [[adapter engineControl] frame];
	XCTAssertTrue(NSContainsRect([container bounds], controlFrame), @"control inside the form");
	XCTAssertGreaterThanOrEqual(NSMinY(controlFrame), NSMaxY([tabView frame]) - 8, @"control above the tabs");
	XCTAssertEqualWithAccuracy(NSMidX(controlFrame), NSMidX([container bounds]), 1.0);

	// The TCP/IP and SSH port fields, bound to "port" with NSNullPlaceholder 3306 in the nib
	NSMutableArray *portFields = [NSMutableArray array];
	NSMutableArray *stack = [NSMutableArray array];
	for (NSTabViewItem *item in [tabView tabViewItems]) [stack addObject:[item view]];
	while ([stack count]) {
		NSView *view = [stack lastObject];
		[stack removeLastObject];
		[stack addObjectsFromArray:[view subviews]];
		if ([view isKindOfClass:[NSTextField class]] && [[[view infoForBinding:NSValueBinding] objectForKey:NSObservedKeyPathKey] isEqualToString:@"port"]) [portFields addObject:view];
	}
	XCTAssertEqual([portFields count], 2u);

	[controller setValue:nil forKey:@"port"];
	for (NSTextField *field in portFields) XCTAssertEqualObjects([[field cell] placeholderString], @"3306");
	[adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	for (NSTextField *field in portFields) XCTAssertEqualObjects([[field cell] placeholderString], @"5432");
	[adapter setSelectedEngine:SPConnectionEngineMySQL];
	for (NSTextField *field in portFields) XCTAssertEqualObjects([[field cell] placeholderString], @"3306");

	[controller setValue:nil forKey:@"postgresAdapter"];
	[adapter invalidate];
}

/// Live: a saved favorite whose password is only in the (Postgres-named) keychain connects and opens
/// a separate PostgreSQL window (test server PG 18 on 55418, Scripts/pg-test-servers.sh).
- (void)testConnectFromFormOpensPostgresWindow
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"adapter connect test";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = 55418;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	[self.keychain addPassword:@"pgkit" forName:[favorite keychainName] account:[favorite keychainAccount]];

	[self.adapter loadFavoriteIntoForm:favorite];
	XCTAssertEqualObjects(self.screen.password, @"pgkit");
	self.screen.password = nil; // read from the keychain at connect time

	NSPredicate *isPostgresWindow = [NSPredicate predicateWithBlock:^BOOL(NSWindow *window, NSDictionary *bindings) {
		return [[window windowController] isKindOfClass:[SPPostgresWindowController class]] && [window isVisible];
	}];
	NSArray *before = [[NSApp windows] filteredArrayUsingPredicate:isPostgresWindow];

	[self.adapter connectFromForm];
	XCTAssertTrue([self.adapter isConnecting]);
	XCTAssertTrue(self.screen.connecting);

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
	while ([self.adapter isConnecting] && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	XCTAssertFalse([self.adapter isConnecting]);
	XCTAssertFalse(self.screen.connecting);
	XCTAssertEqual(self.screen.connectingCalls, 2u);

	NSMutableArray *opened = [[[NSApp windows] filteredArrayUsingPredicate:isPostgresWindow] mutableCopy];
	[opened removeObjectsInArray:before];
	XCTAssertEqual([opened count], 1u, @"one PostgreSQL window opened");
	SPPostgresWindowController *windowController = [[opened firstObject] windowController];
	XCTAssertTrue([[windowController windowTitleString] containsString:@"adapter connect test"], @"%@", [windowController windowTitleString]);
	XCTAssertNotNil([windowController connection]);
	[windowController close];
}

@end
