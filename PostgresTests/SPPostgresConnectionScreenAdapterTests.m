#import <XCTest/XCTest.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresConnectionScreenAdapter.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoritesStore.h"
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/SPWindowController.h"

// SPTreeNode / SPGroupNode / SPFavoriteNode are app classes without exported symbols: look them up at run time
@interface NSObject (SPPGAdapterTestsMySQLNodes)
+ (id)groupNodeWithName:(NSString *)name;
+ (id)favoriteNodeWithDictionary:(NSMutableDictionary *)dictionary;
- (NSString *)nodeName;
@end

@interface NSObject (SPPGConnectionControllerForTests)
- (void)resizeTabViewToConnectionType:(NSUInteger)theType animating:(BOOL)animate;
- (id)connectionController;
- (IBAction)initiateConnection:(id)sender;
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
/// When set, behaves like the outline: a reload that moves the selected row re-selects it, and the
/// selection change loads the favorite into the form (as SPConnectionController does).
@property (weak) SPPostgresConnectionScreenAdapter *reselectingAdapter;
@property (copy) NSString *selectedFavoriteID;
@property (assign) NSUInteger formReloads;
@property (copy) void (^onFavoritesDidChange)(void);
/// Returned by -postgresSheetWindow (nil: the adapter has no window for sheets).
@property (strong) NSWindow *sheetWindow;
/// The documents handed over by -postgresReplaceConnectionTabWithDocument:.
@property (strong) NSMutableArray<SPPostgresDocument *> *replacementDocuments;
/// Returned by -postgresGroupForNewFavorite (nil: the adapter uses the section).
@property (strong) id groupForNewFavorite;
/// Returned by -postgresSelectedOutlineItem.
@property (strong) id selectedItem;
/// Saved MySQL favorites (-postgresItemIsSavedMySQLFavorite:) and the one just added with "+".
@property (strong) NSMutableArray *mysqlFavoriteItems;
@property (strong) id justAddedMySQLItem;
/// What -postgresRemoveMySQLFavorite: and -selectQuickConnectItem were asked to do.
@property (strong) NSMutableArray *removedMySQLItems;
@property (assign) NSUInteger quickConnectSelections;
@end

@implementation SPPGFakeConnectionScreen
- (id)postgresSelectedOutlineItem { return self.selectedItem; }
- (BOOL)postgresItemIsSavedMySQLFavorite:(id)item { return item && [self.mysqlFavoriteItems containsObject:item]; }
- (BOOL)postgresItemIsNewMySQLFavorite:(id)item { return item && item == self.justAddedMySQLItem && item == self.selectedItem; }
- (void)postgresRemoveMySQLFavorite:(id)item
{
	if (!self.removedMySQLItems) self.removedMySQLItems = [NSMutableArray array];
	[self.removedMySQLItems addObject:item];
	[self.mysqlFavoriteItems removeObject:item];
	if (self.selectedItem == item) self.selectedItem = nil;
}
- (void)selectQuickConnectItem { self.quickConnectSelections++; self.selectedItem = nil; }
- (id)postgresGroupForNewFavorite { return self.groupForNewFavorite; }
- (void)postgresFavoritesDidChange
{
	self.favoritesChangedCount++;
	if (self.onFavoritesDidChange) self.onFavoritesDidChange();
	SPPostgresConnectionScreenAdapter *adapter = self.reselectingAdapter;
	if (adapter && self.selectedFavoriteID) {
		id node = [adapter nodeForFavoriteID:self.selectedFavoriteID];
		if (node) {
			self.formReloads++;
			[adapter loadFavoriteIntoForm:[adapter favoriteForNode:node]];
		}
	}
}
- (void)postgresSelectOutlineItem:(id)item
{
	SPPostgresConnectionScreenAdapter *adapter = self.reselectingAdapter;
	SPPostgresFavorite *favorite = [adapter favoriteForNode:item];
	if (!adapter || !favorite || [favorite.favoriteID isEqualToString:self.selectedFavoriteID]) return;
	self.selectedFavoriteID = favorite.favoriteID;
	self.formReloads++;
	[adapter loadFavoriteIntoForm:favorite];
}
- (void)postgresSetConnecting:(BOOL)connecting { self.connecting = connecting; self.connectingCalls++; }
- (NSWindow *)postgresSheetWindow { return self.sheetWindow; }
- (void)postgresReplaceConnectionTabWithDocument:(SPPostgresDocument *)document
{
	if (!self.replacementDocuments) self.replacementDocuments = [NSMutableArray array];
	[self.replacementDocuments addObject:document];
}
@end

/// A tab of another engine standing next to the MySQL connection tab.
@interface SPPGFakeTabPlaceholder : NSObject <SPWindowTabDocument>
@property (readwrite) BOOL isProcessing;
@end

@implementation SPPGFakeTabPlaceholder
{
	NSView *_view;
}
- (instancetype)init { if ((self = [super init])) _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)]; return self; }
- (NSView *)databaseView { return _view; }
- (void)setParentWindowController:(SPWindowController *)controller {}
- (void)setParentWindow:(NSWindow *)window {}
// No tab colour (as tab documents set it; NSTabViewItem's default colour can't be drawn by the tab style)
- (void)setParentTabViewItem:(NSTabViewItem *)item { [item setValue:nil forKey:@"color"]; }
- (void)didBecomeActiveTabInWindow {}
- (void)willResignActiveTabInWindow {}
- (void)updateWindowTitle:(id)sender {}
- (BOOL)parentTabShouldClose { return YES; }
- (void)parentTabDidClose {}
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
	self.store = [[SPPostgresFavoritesStore alloc] initInMemory]; // a tree of its own, never SPFavoritesController's
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

- (void)testSavingPostgresFavoriteAddsItToTheTree
{
	// R4: read-only snapshot of the real favorites file (the test's store has its own tree)
	NSString *mysqlFavorites = [@"~/Library/Application Support/Sequel Plus/Data/Favorites.plist" stringByExpandingTildeInPath];
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
	XCTAssertTrue([[favorite keychainName] hasPrefix:@"Sequel Plus (PostgreSQL)"]);

	// The new favorite has an outline node
	XCTAssertTrue([self.adapter hasPostgresFavorites]);
	id node = [self.adapter nodeForFavoriteID:favorite.favoriteID];
	XCTAssertNotNil(node);
	XCTAssertTrue([self.adapter isPostgresNode:node]);
	XCTAssertEqualObjects([[self.adapter favoriteForNode:node] favoriteID], favorite.favoriteID);
	XCTAssertEqual((id)[node parentNode], (id)[self.store section], @"a leaf of the FAVORITES section");
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

/// Postgres favorite rows get their own icon: the PostgreSQL elephant, at the MySQL favorites' icon size.
- (void)testPostgresFavoriteIconIsTheElephant
{
	NSImage *mysqlIcon = [NSImage imageNamed:@"database-small"];
	NSImage *elephant = [NSImage imageNamed:@"postgres-elephant"];
	NSImage *postgresIcon = [SPPostgresConnectionScreenAdapter favoriteImage];
	XCTAssertNotNil(mysqlIcon);
	XCTAssertNotNil(elephant, @"postgres-elephant.png is in the app's resources");
	XCTAssertNotNil(postgresIcon);
	XCTAssertTrue(NSEqualSizes([postgresIcon size], [mysqlIcon size]));
	XCTAssertEqualObjects([postgresIcon TIFFRepresentation], [elephant TIFFRepresentation]);
	XCTAssertNotEqualObjects([postgresIcon TIFFRepresentation], [mysqlIcon TIFFRepresentation]);
}

/// The SSH tab's "MySQL Host:" label reads "PostgreSQL Host:" for PostgreSQL, fully visible from the same
/// right edge, and returns to the nib text and frame for MySQL.
- (void)testHostLabelNamesTheEngine
{
	static NSMutableArray *keepAlive; // see -testEngineControlFitsTheRealConnectionForm
	if (!keepAlive) keepAlive = [NSMutableArray array];

	id controller = [[NSClassFromString(@"SPConnectionController") alloc] init];
	[keepAlive addObject:controller];
	[controller performSelector:@selector(loadNib)];

	NSView *container = [controller valueForKey:@"connectionResizeContainer"];
	NSTabView *tabView = nil;
	for (NSView *subview in [container subviews]) if ([subview isKindOfClass:[NSTabView class]]) tabView = (NSTabView *)subview;
	XCTAssertNotNil(tabView);

	NSMutableArray *labels = [NSMutableArray array];
	NSMutableArray *stack = [NSMutableArray array];
	for (NSTabViewItem *item in [tabView tabViewItems]) [stack addObject:[item view]];
	while ([stack count]) {
		NSView *view = [stack lastObject];
		[stack removeLastObject];
		[stack addObjectsFromArray:[view subviews]];
		if ([view isKindOfClass:[NSTextField class]] && [[(NSTextField *)view stringValue] isEqualToString:@"MySQL Host:"]) [labels addObject:view];
	}
	XCTAssertEqual([labels count], 1u, @"the SSH tab's host label");
	NSTextField *label = [labels firstObject];
	NSRect nibFrame = [label frame];
	NSFont *nibFont = [label font];

	SPPostgresConnectionScreenAdapter *adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:controller store:self.store];
	adapter.keychain = self.keychain;
	[adapter installEngineControlInContainer:container];
	[controller setValue:adapter forKey:@"postgresAdapter"];

	XCTAssertEqualObjects([label stringValue], @"MySQL Host:");
	XCTAssertTrue(NSEqualRects([label frame], nibFrame));

	[adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	XCTAssertEqualObjects([label stringValue], @"PostgreSQL Host:");
	XCTAssertEqualWithAccuracy(NSMaxX([label frame]), NSMaxX(nibFrame), 0.5, @"same right edge, next to the field");
	XCTAssertGreaterThanOrEqual(NSWidth([label frame]), ceil([[label cell] cellSize].width), @"whole text visible");
	XCTAssertGreaterThanOrEqual(NSMinX([label frame]), 0.0);

	[adapter setSelectedEngine:SPConnectionEngineMySQL];
	XCTAssertEqualObjects([label stringValue], @"MySQL Host:");
	XCTAssertTrue(NSEqualRects([label frame], nibFrame), @"nib frame restored");
	XCTAssertEqualObjects([label font], nibFont, @"nib font restored");

	[controller setValue:nil forKey:@"postgresAdapter"];
	[adapter invalidate];
}

/// Live: a saved favorite whose password is only in the (Postgres-named) keychain connects and hands
/// a PostgreSQL tab document to the host; no window is opened (test server PG 18 on 55418,
/// Scripts/pg-test-servers.sh).
- (void)testConnectFromFormHandsDocumentToHost
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

	NSArray *windowsBefore = [NSApp windows];
	PGPostgresConnection *connection = nil;
	__weak SPPostgresDocument *weakDocument = nil;

	// The pool lets go of whatever the connect autoreleased (this test's own pool isn't drained by the run loop)
	@autoreleasepool {
		[self.adapter connectFromForm];
		XCTAssertTrue([self.adapter isConnecting]);
		XCTAssertTrue(self.screen.connecting);

		XCTAssertTrue([self spinUntil:^BOOL{ return ![self.adapter isConnecting]; } timeout:20]);
		XCTAssertFalse(self.screen.connecting);
		XCTAssertEqual(self.screen.connectingCalls, 2u);

		XCTAssertEqual([self.screen.replacementDocuments count], 1u, @"one PostgreSQL tab document handed to the host");
		SPPostgresDocument *document = [self.screen.replacementDocuments firstObject];
		weakDocument = document;
		XCTAssertTrue([[document windowTitleString] containsString:@"adapter connect test"], @"%@", [document windowTitleString]);
		connection = [document connection];
		XCTAssertTrue([connection isConnected]);

		NSArray *opened = [self newVisibleWindowsSince:windowsBefore];
		XCTAssertEqual([opened count], 0u, @"no window opened: %@", opened);

		// Not hosted anywhere: releasing the document closes its connection
		document = nil;
		self.screen.replacementDocuments = nil;
	}
	XCTAssertNil(weakDocument, @"only the host kept the document");
	XCTAssertTrue([self spinUntil:^BOOL{ return ![connection isConnected]; } timeout:2]);
}

#pragma mark - Connecting from a MySQL window's connection tab

/// Visible document-level windows that weren't in `windowsBefore`: not sheets, and not AppKit's private
/// helper windows (e.g. the glass effect window behind an alert).
- (NSArray *)newVisibleWindowsSince:(NSArray *)windowsBefore
{
	NSMutableArray *opened = [NSMutableArray array];
	for (NSWindow *window in [NSApp windows]) {
		if ([windowsBefore containsObject:window] || ![window isVisible] || [window sheetParent]) continue;
		NSString *className = NSStringFromClass([window class]);
		if ([className hasPrefix:@"_"] || [className containsString:@"._"]) continue;
		[opened addObject:window];
	}
	return opened;
}

/// A window (as -[SPAppController newWindow] makes it) with one MySQL tab on its connection screen,
/// whose form is set up for PG 18 on 55418 with `password`. The adapter's keychain is the in-memory one.
- (SPWindowController *)windowWithConnectionTabForPassword:(NSString *)password document:(id __autoreleasing *)outDocument
{
	SPWindowController *controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([controller window]);
	[controller showWindow:nil];
	id mysql = [controller addNewConnection];
	XCTAssertNotNil(mysql);
	// A MySQL tab's filter editor resizes itself 0.2 s after it is built and messages freed objects if
	// the document is gone by then (pre-existing; see SPPostgresDocumentTests). A successful connect
	// closes this tab: let that happen first.
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

	[self addTeardownBlock:^{
		NSWindow *window = [controller window];
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		NSTabView *tabView = [controller valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
		// Removing the tabs starts the tab bar's hide animation (a timer on the tab bar, whose delegate is the
		// window controller): let it finish while the controller is alive, or the next test's run loop fires it
		// at a freed delegate
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
	}];

	id connectionController = [mysql connectionController];
	SPPostgresConnectionScreenAdapter *adapter = [connectionController valueForKey:@"postgresAdapter"];
	XCTAssertNotNil(adapter);
	adapter.keychain = self.keychain;
	[adapter setSelectedEngine:SPConnectionEnginePostgreSQL];

	id <SPPostgresConnectionScreenHost> form = connectionController;
	form.type = SPPostgresTCPIPConnection;
	form.name = @"adapter tab test";
	form.host = @"127.0.0.1";
	form.port = @"55418";
	form.user = @"pgkit_test";
	form.password = password;
	form.database = @"pgkit_test";
	form.sshPassword = nil;

	*outDocument = mysql;
	return controller;
}

- (void)testConnectReplacesConnectionTab
{
	id mysql = nil;
	SPWindowController *controller = [self windowWithConnectionTabForPassword:@"pgkit" document:&mysql];
	// The MySQL tab is the second of two
	[controller addTabDocument:[[SPPGFakeTabPlaceholder alloc] init] atIndex:0 select:NO];
	[controller selectTabAtIndex:1];
	XCTAssertEqual((id)[controller selectedDocument], mysql);
	id connectionController = [mysql connectionController];
	SPPostgresConnectionScreenAdapter *adapter = [connectionController valueForKey:@"postgresAdapter"];

	NSArray *windowsBefore = [NSApp windows];

	[connectionController initiateConnection:nil];
	XCTAssertTrue([adapter isConnecting]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [[controller tabDocuments] count] == 2 && [[[controller tabDocuments] objectAtIndex:1] isKindOfClass:[SPPostgresDocument class]]; } timeout:20],
				  @"%@ (sheet: %@)", [controller tabDocuments], [[controller window] attachedSheet]);

	SPPostgresDocument *document = [[controller tabDocuments] objectAtIndex:1];
	// The tab's first loads run on its runner
	XCTAssertTrue([SPPostgresTestServers waitForRunner:document.taskRunner timeout:30]);
	XCTAssertEqual((id)[controller selectedDocument], document);
	XCTAssertNil([controller selectedTableDocument]);
	XCTAssertEqual(document.parentWindowController, controller);
	XCTAssertEqual(document.parentWindow, [controller window]);
	XCTAssertEqualObjects([document.parentTabViewItem label], @"adapter tab test");
	XCTAssertTrue([[document connection] isConnected]);
	XCTAssertNotNil([[document connection] execute:@"SELECT 1"]);
	XCTAssertFalse([[controller documents] containsObject:mysql], @"the MySQL tab is gone");
	XCTAssertNil([mysql valueForKey:@"parentWindow"], @"the MySQL document was told its tab closed");

	NSArray *opened = [self newVisibleWindowsSince:windowsBefore];
	XCTAssertEqual([opened count], 0u, @"no window opened: %@", opened);

	// Closing the tab disconnects
	PGPostgresConnection *connection = [document connection];
	NSTabView *tabView = [controller valueForKey:@"tabView"];
	[tabView removeTabViewItem:document.parentTabViewItem];
	document = nil;
	XCTAssertTrue([self spinUntil:^BOOL{ return ![connection isConnected]; } timeout:2]);
}

- (void)testFailedConnectLeavesTab
{
	id mysql = nil;
	SPWindowController *controller = [self windowWithConnectionTabForPassword:@"wrong password" document:&mysql];
	id connectionController = [mysql connectionController];
	SPPostgresConnectionScreenAdapter *adapter = [connectionController valueForKey:@"postgresAdapter"];
	NSArray *windowsBefore = [NSApp windows];

	[connectionController initiateConnection:nil];
	XCTAssertTrue([adapter isConnecting]);
	XCTAssertTrue([self spinUntil:^BOOL{ return ![adapter isConnecting]; } timeout:20]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [[controller window] attachedSheet] != nil; } timeout:5], @"the error is shown on the tab's window");

	XCTAssertEqual([[controller tabDocuments] count], 1u);
	XCTAssertEqual([[controller tabDocuments] firstObject], mysql, @"the same MySQL document is still in its tab");
	XCTAssertEqual((id)[controller selectedDocument], mysql);
	XCTAssertEqual([controller selectedTableDocument], mysql);
	XCTAssertEqual([mysql valueForKey:@"parentWindow"], [controller window]);
	XCTAssertEqual([connectionController valueForKey:@"postgresAdapter"], adapter, @"the connection screen keeps its adapter");
	XCTAssertTrue([[adapter engineControl] isEnabled], @"the connection screen is usable again");

	NSArray *opened = [self newVisibleWindowsSince:windowsBefore];
	XCTAssertEqual([opened count], 0u, @"no window opened: %@", opened);
}

/// Renaming the loaded favorite so that it sorts to another row re-selects it during the store's
/// change notification; the form must keep its passwords and a second save must keep the keychain items.
- (void)testRenameThatReSortsKeepsPasswords
{
	self.screen.reselectingAdapter = self.adapter;
	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];

	// Two favorites: "AAA" (sorts first, with passwords) and "MMM"
	self.screen.type = SPPostgresSSHConnection;
	self.screen.host = @"db.internal";
	self.screen.sshHost = @"bastion";
	self.screen.user = @"alice";
	self.screen.name = @"MMM adapter test";
	self.screen.password = nil;
	NSError *error = nil;
	XCTAssertTrue([self.adapter saveFormAsNewFavorite:&error], @"%@", error);

	self.screen.name = @"AAA adapter test";
	self.screen.password = @"pw";
	self.screen.sshPassword = @"sshpw";
	XCTAssertTrue([self.adapter saveFormAsNewFavorite:&error], @"%@", error);
	NSString *favoriteID = [[self.adapter loadedFavorite] favoriteID];
	XCTAssertEqualObjects(self.screen.selectedFavoriteID, favoriteID);
	XCTAssertEqualObjects(self.screen.password, @"pw");

	// Form rename to a name that sorts last. When the store announces the change, the keychain items
	// must already be under the new names (any host may read them then).
	__block NSString *passwordSeenDuringNotification = nil;
	__weak SPPostgresConnectionScreenAdapterTests *weakSelf = self;
	self.screen.onFavoritesDidChange = ^{
		SPPostgresFavorite *current = [weakSelf.adapter favoriteForNode:[weakSelf.adapter nodeForFavoriteID:favoriteID]];
		passwordSeenDuringNotification = [weakSelf.keychain getPasswordForName:[current keychainName] account:[current keychainAccount]];
	};
	NSUInteger reloadsBefore = self.screen.formReloads;
	self.screen.name = @"ZZZ adapter test";
	XCTAssertTrue([self.adapter saveFormAsFavorite:&error], @"%@", error);
	self.screen.onFavoritesDidChange = nil;
	XCTAssertEqualObjects(passwordSeenDuringNotification, @"pw", @"keychain items moved before the store notified");
	XCTAssertGreaterThan(self.screen.formReloads, reloadsBefore, @"the host re-selected the node");
	XCTAssertEqualObjects(self.screen.password, @"pw");
	XCTAssertEqualObjects(self.screen.sshPassword, @"sshpw");

	SPPostgresFavorite *renamed = [self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:favoriteID]];
	XCTAssertEqualObjects(renamed.name, @"ZZZ adapter test");
	XCTAssertEqualObjects([[self.store favorites].lastObject favoriteID], favoriteID, @"re-sorted last");
	XCTAssertEqualObjects([self.keychain getPasswordForName:[renamed keychainName] account:[renamed keychainAccount]], @"pw");

	// A second save keeps the items
	self.screen.database = @"appdb";
	XCTAssertTrue([self.adapter saveFormAsFavorite:&error], @"%@", error);
	renamed = [self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:favoriteID]];
	XCTAssertEqualObjects([self.keychain getPasswordForName:[renamed keychainName] account:[renamed keychainAccount]], @"pw");
	XCTAssertEqualObjects([self.keychain getPasswordForName:[renamed sshKeychainName] account:[renamed sshKeychainAccount]], @"sshpw");

	// Outline rename back to the front: same guarantees
	[self.adapter renameFavoriteNode:[self.adapter nodeForFavoriteID:favoriteID] to:@"AAB adapter test"];
	XCTAssertEqualObjects(self.screen.password, @"pw");
	XCTAssertEqualObjects(self.screen.name, @"AAB adapter test");
	renamed = [self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:favoriteID]];
	XCTAssertEqualObjects([self.keychain getPasswordForName:[renamed keychainName] account:[renamed keychainAccount]], @"pw");
	XCTAssertTrue([self.adapter saveFormAsFavorite:&error], @"%@", error);
	XCTAssertEqualObjects([self.keychain getPasswordForName:[renamed keychainName] account:[renamed keychainAccount]], @"pw");
	XCTAssertEqual([self.keychain.items count], 2u, @"no stale items under old names");
}

/// The engine control is disabled while either engine connects (switching engine mid-connect would
/// re-run the favorite selection) and enabled again when the connection interface is restored.
/// Uses a bare SPConnectionController on the real nib; the MySQL attempt is cancelled before the run
/// loop can start it (and its host is an unroutable TEST-NET address).
- (void)testEngineControlDisabledWhileConnecting
{
	static NSMutableArray *keepAlive;
	if (!keepAlive) keepAlive = [NSMutableArray array];

	id controller = [[NSClassFromString(@"SPConnectionController") alloc] init];
	[keepAlive addObject:controller];
	[controller performSelector:@selector(loadNib)];

	SPPostgresConnectionScreenAdapter *adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:controller store:self.store];
	adapter.keychain = self.keychain;
	[adapter installEngineControlInContainer:[controller valueForKey:@"connectionResizeContainer"]];
	[controller setValue:adapter forKey:@"postgresAdapter"];
	XCTAssertTrue([[adapter engineControl] isEnabled]);

	// MySQL connect: disabled from the start of the attempt
	[controller setValue:@0 forKey:@"type"];
	[controller setValue:@"192.0.2.1" forKey:@"host"];
	[controller performSelector:@selector(initiateConnection:) withObject:nil];
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	XCTAssertFalse([[adapter engineControl] isEnabled]);

	// ...until the interface is restored (failure, cancel, test result)
	[controller performSelector:NSSelectorFromString(@"_restoreConnectionInterface")];
	XCTAssertTrue([[adapter engineControl] isEnabled]);

	// PostgreSQL connect
	[(id <SPPostgresConnectionScreenHost>)controller postgresSetConnecting:YES];
	XCTAssertFalse([[adapter engineControl] isEnabled]);
	[(id <SPPostgresConnectionScreenHost>)controller postgresSetConnecting:NO];
	XCTAssertTrue([[adapter engineControl] isEnabled]);

	[controller setValue:nil forKey:@"postgresAdapter"];
	[adapter invalidate];
}

#pragma mark - Engine switch and the port

/// A port field holding the previous engine's default (or nothing) is cleared on an engine switch, so the
/// new engine's default applies; any other port is kept.
- (void)testEngineSwitchClearsThePreviousEnginesDefaultPort
{
	NSSegmentedControl *control = [self.adapter engineControl];
	SPPostgresFavorite *favorite = [self fullFavorite];
	favorite.type = SPPostgresTCPIPConnection;
	favorite.port = 5432;
	[self.adapter loadFavoriteIntoForm:favorite];
	XCTAssertEqualObjects(self.screen.port, @"5432");

	[control setSelectedSegment:SPConnectionEngineMySQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEngineMySQL);
	XCTAssertEqual(self.screen.port.length, 0u, @"5432 is PostgreSQL's default: cleared for MySQL (placeholder 3306), got %@", self.screen.port);

	// MySQL's default is cleared the other way
	self.screen.port = @"3306";
	[control setSelectedSegment:SPConnectionEnginePostgreSQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqual(self.screen.port.length, 0u, @"got %@", self.screen.port);
	XCTAssertEqual([[self.adapter favoriteFromForm] port], 5432u);

	// A custom port is kept both ways
	self.screen.port = @"6543";
	[control setSelectedSegment:SPConnectionEngineMySQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqualObjects(self.screen.port, @"6543");
	[control setSelectedSegment:SPConnectionEnginePostgreSQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqualObjects(self.screen.port, @"6543");

	// The other engine's default is a custom port for this one
	self.screen.port = @"3306";
	[control setSelectedSegment:SPConnectionEngineMySQL];
	[control sendAction:[control action] to:[control target]];
	XCTAssertEqualObjects(self.screen.port, @"3306");
}

#pragma mark - Switching a MySQL favorite to PostgreSQL

/// The MySQL favorite just added with "+" and filled in, selected, with the MySQL engine.
- (id)selectNewMySQLFavoriteInForm
{
	id item = [NSClassFromString(@"SPFavoriteNode") favoriteNodeWithDictionary:[@{@"name": @"New Favorite"} mutableCopy]];
	self.screen.mysqlFavoriteItems = [NSMutableArray arrayWithObject:item];
	self.screen.justAddedMySQLItem = item;
	self.screen.selectedItem = item;
	self.screen.reselectingAdapter = self.adapter;
	[self.adapter setSelectedEngine:SPConnectionEngineMySQL];
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.name = @"Staging";
	self.screen.host = @"";
	self.screen.user = @"carol";
	self.screen.password = @"s3cret";
	self.screen.port = @"3306";
	return item;
}

- (void)switchEngineTo:(SPConnectionEngine)newEngine
{
	NSSegmentedControl *control = [self.adapter engineControl];
	[control setSelectedSegment:newEngine];
	[control sendAction:[control action] to:[control target]];
}

- (void)testNewMySQLFavoriteSwitchedToPostgreSQLBecomesPostgresFavorite
{
	id item = [self selectNewMySQLFavoriteInForm];

	[self switchEngineTo:SPConnectionEnginePostgreSQL];

	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEnginePostgreSQL);
	XCTAssertEqual(self.screen.quickConnectSelections, 0u, @"not moved to Quick Connect");
	XCTAssertEqualObjects(self.screen.removedMySQLItems, @[item], @"the MySQL favorite is replaced");

	// Saved without validation (no host yet), with the form's details and PostgreSQL's default port
	XCTAssertEqual([[self.store favorites] count], 1u);
	SPPostgresFavorite *saved = [[self.store favorites] firstObject];
	XCTAssertEqualObjects(saved.name, @"Staging");
	XCTAssertEqualObjects(saved.user, @"carol");
	XCTAssertNil(saved.host);
	XCTAssertEqual(saved.port, 5432u);
	XCTAssertEqualObjects([self.keychain getPasswordForName:[saved keychainName] account:[saved keychainAccount]], @"s3cret");

	// It is the selected favorite, loaded in the form for editing
	XCTAssertEqualObjects(self.screen.selectedFavoriteID, saved.favoriteID);
	XCTAssertEqualObjects([[self.adapter loadedFavorite] favoriteID], saved.favoriteID);
	XCTAssertEqualObjects(self.screen.name, @"Staging");
	XCTAssertEqualObjects(self.screen.password, @"s3cret");

	// Editing then saves to the same favorite
	self.screen.host = @"db.staging";
	NSError *error = nil;
	XCTAssertTrue([self.adapter saveFormAsFavorite:&error], @"%@", error);
	XCTAssertEqual([[self.store favorites] count], 1u);
	XCTAssertEqualObjects([[[self.store favorites] firstObject] host], @"db.staging");
}

- (void)testOtherSavedMySQLFavoriteSwitchedToPostgreSQLGoesToQuickConnect
{
	id item = [self selectNewMySQLFavoriteInForm];
	self.screen.justAddedMySQLItem = nil; // an older favorite, not the one just added

	[self switchEngineTo:SPConnectionEnginePostgreSQL];

	XCTAssertEqual(self.screen.quickConnectSelections, 1u);
	XCTAssertNil(self.screen.removedMySQLItems);
	XCTAssertEqualObjects(self.screen.mysqlFavoriteItems, @[item]);
	XCTAssertEqual([[self.store favorites] count], 0u);
	XCTAssertEqual([self.adapter selectedEngine], SPConnectionEnginePostgreSQL);
	XCTAssertEqualObjects(self.screen.name, @"Staging", @"the details stay in the form");
}

#pragma mark - Unreadable favorites file

- (NSWindow *)visibleSheetWindow
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window orderBack:nil];
	[self addTeardownBlock:^{
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		[window close];
	}];
	return window;
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

/// A PostgresFavorites.plist (of the RC builds) that couldn't be imported is reported once per distinct problem.
- (void)testFavoritesImportErrorIsReportedOnce
{
	__block NSError *loadError = [NSError errorWithDomain:@"test" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"Cannot use PostgreSQL favorites file. It is corrupt." }];
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithSectionProvider:^SPTreeNode *{ return [self.store section]; }
	                                                                                saveHandler:^BOOL{ return YES; }
	                                                                          loadErrorProvider:^NSError *{ return loadError; }];

	NSWindow *window = [self visibleSheetWindow];
	SPPGFakeConnectionScreen *screen = [[SPPGFakeConnectionScreen alloc] init];
	screen.sheetWindow = window;
	SPPostgresConnectionScreenAdapter *adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:screen store:store];
	adapter.keychain = self.keychain;
	[self addTeardownBlock:^{ [adapter invalidate]; }];

	XCTAssertFalse([adapter hasPostgresFavorites]);
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:5], @"the error is shown");
	[window endSheet:window.attachedSheet];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);

	// The favorites change (e.g. another window saved): the same problem is not shown again
	[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritesDidChangeNotification object:store];
	[self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:1];
	XCTAssertNil(window.attachedSheet, @"the same error is shown once");

	// A different problem is shown
	loadError = [NSError errorWithDomain:@"test" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"Cannot use PostgreSQL favorites file. It is newer." }];
	[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritesDidChangeNotification object:store];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:5]);
	[window endSheet:window.attachedSheet];
}

#pragma mark - Store changes from elsewhere

/// A change made by another store client (another connection tab, or the store directly) reloads the
/// loaded favorite's form; only the adapter's own saves keep the form as it is.
- (void)testStoreChangeFromAnotherClientReloadsTheForm
{
	self.screen.reselectingAdapter = self.adapter;
	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.host = @"db.internal";
	self.screen.name = @"Shared favorite";
	NSError *error = nil;
	XCTAssertTrue([self.adapter saveFormAsNewFavorite:&error], @"%@", error);
	NSString *favoriteID = [[self.adapter loadedFavorite] favoriteID];
	XCTAssertEqualObjects(self.screen.selectedFavoriteID, favoriteID);

	// Direct save on the same store
	SPPostgresFavorite *changed = [[self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:favoriteID]] copy];
	changed.name = @"Renamed elsewhere";
	changed.host = @"db2.internal";
	XCTAssertTrue([self.store saveFavorite:changed error:&error], @"%@", error);
	XCTAssertEqualObjects(self.screen.name, @"Renamed elsewhere");
	XCTAssertEqualObjects(self.screen.host, @"db2.internal");

	// Another adapter (another connection tab) on the same store
	SPPGFakeConnectionScreen *otherScreen = [[SPPGFakeConnectionScreen alloc] init];
	SPPostgresConnectionScreenAdapter *other = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:otherScreen store:self.store];
	other.keychain = self.keychain;
	[self addTeardownBlock:^{ [other invalidate]; }];
	[other renameFavoriteNode:[other nodeForFavoriteID:favoriteID] to:@"Renamed in another tab"];
	XCTAssertEqualObjects(self.screen.name, @"Renamed in another tab");
}

#pragma mark - Bindings made by the adapter

/// -invalidate removes the port bindings the adapter re-made (they point at the controller), and only those.
- (void)testInvalidateUnbindsThePortBindingsItMade
{
	NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 446, 472)];
	NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(3, 61, 440, 417)];
	NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"1"];
	NSView *itemView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 371)];
	NSTextField *portField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 100, 22)];
	[portField bind:NSValueBinding toObject:self.screen withKeyPath:@"port" options:@{ NSNullPlaceholderBindingOption: @"3306" }];
	[itemView addSubview:portField];
	[item setView:itemView];
	[tabView addTabViewItem:item];
	[container addSubview:tabView];
	[self addTeardownBlock:^{ [portField unbind:NSValueBinding]; }];

	// Never switched to PostgreSQL: the binding is the host's own and stays
	SPPostgresConnectionScreenAdapter *untouched = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:self.screen store:self.store];
	[untouched installEngineControlInContainer:container];
	[untouched invalidate];
	XCTAssertNotNil([portField infoForBinding:NSValueBinding], @"a binding the adapter didn't make is left alone");
	[[untouched engineControl] removeFromSuperview];

	// Switched: the adapter re-made the binding, and removes it
	[self.adapter installEngineControlInContainer:container];
	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	XCTAssertEqualObjects([[[portField infoForBinding:NSValueBinding] objectForKey:NSOptionsKey] objectForKey:NSNullPlaceholderBindingOption], @"5432");
	[self.adapter invalidate];
	XCTAssertNil([portField infoForBinding:NSValueBinding]);

	// Also after switching back to MySQL (the restored binding is made by the adapter too)
	SPPostgresConnectionScreenAdapter *third = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:self.screen store:self.store];
	[portField bind:NSValueBinding toObject:self.screen withKeyPath:@"port" options:@{ NSNullPlaceholderBindingOption: @"3306" }];
	[[self.adapter engineControl] removeFromSuperview];
	[third installEngineControlInContainer:container];
	[third setSelectedEngine:SPConnectionEnginePostgreSQL];
	[third setSelectedEngine:SPConnectionEngineMySQL];
	XCTAssertEqualObjects([[portField infoForBinding:NSValueBinding] objectForKey:NSObservedKeyPathKey], @"port");
	[third invalidate];
	XCTAssertNil([portField infoForBinding:NSValueBinding]);
}


#pragma mark - One FAVORITES list (Postgres favorites in the favorites tree)

- (id)mysqlGroup:(NSString *)name children:(NSArray *)children
{
	NSTreeNode *node = [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:[NSClassFromString(@"SPGroupNode") groupNodeWithName:name]];
	[[node mutableChildNodes] addObjectsFromArray:children];
	return node;
}

- (id)mysqlFavorite:(NSInteger)favoriteID
{
	NSMutableDictionary *dict = [@{ @"id": @(favoriteID), @"name": [NSString stringWithFormat:@"m%ld", (long)favoriteID], @"host": @"mysqlhost", @"type": @0 } mutableCopy];
	return [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:[NSClassFromString(@"SPFavoriteNode") favoriteNodeWithDictionary:dict]];
}

/// The store's FAVORITES section filled as: m1, G (m2, Sub (m3)), m4. G and Sub through the out parameters.
- (id)makeSectionWithGroup:(id *)groupOut subgroup:(id *)subOut
{
	id sub = [self mysqlGroup:@"Sub" children:@[[self mysqlFavorite:3]]];
	id group = [self mysqlGroup:@"G" children:@[[self mysqlFavorite:2], sub]];
	NSTreeNode *section = (NSTreeNode *)[self.store section];
	[[section mutableChildNodes] addObjectsFromArray:@[[self mysqlFavorite:1], group, [self mysqlFavorite:4]]];
	if (groupOut) *groupOut = group;
	if (subOut) *subOut = sub;
	return section;
}

- (NSString *)savedFavoriteNamed:(NSString *)name inGroup:(id)group
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = name;
	favorite.host = @"db";
	NSError *error = nil;
	XCTAssertNotNil([self.store addFavorite:favorite toGroup:group atIndex:NSNotFound error:&error], @"%@", error);
	return favorite.favoriteID;
}

- (NSArray *)namesIn:(NSArray *)nodes
{
	NSMutableArray *names = [NSMutableArray array];
	for (NSTreeNode *node in nodes) [names addObject:[[node representedObject] nodeName] ?: @"?"];
	return names;
}

- (void)testAddNewFavoriteGoesToEndOfGroupForNewFavorite
{
	id group = nil;
	[self makeSectionWithGroup:&group subgroup:NULL];
	self.screen.groupForNewFavorite = group;

	id node = [self.adapter addNewFavorite];
	XCTAssertNotNil(node);
	XCTAssertEqual([[group childNodes] lastObject], node);
	XCTAssertEqualObjects([self namesIn:[group childNodes]], (@[@"m2", @"Sub", @"New Favorite"]));
	XCTAssertTrue([self.adapter isPostgresNode:node]);
	XCTAssertEqual([self.adapter nodeForFavoriteID:[[self.adapter favoriteForNode:node] favoriteID]], node);
}

- (void)testAddNewFavoriteWithoutGroupGoesToEndOfSection
{
	id section = [self makeSectionWithGroup:NULL subgroup:NULL];
	id node = [self.adapter addNewFavorite];
	XCTAssertEqual([[section childNodes] lastObject], node);

	// Something that isn't a MySQL group (a Postgres favorite, a MySQL favorite) means the section too
	self.screen.groupForNewFavorite = node;
	id second = [self.adapter addNewFavorite];
	XCTAssertEqual([[section childNodes] lastObject], second);
	XCTAssertEqual([[section childNodes] count], 5u);
}

- (void)testSaveFormAsNewFavoriteGoesToEndOfGroupForNewFavorite
{
	id group = nil, sub = nil;
	[self makeSectionWithGroup:&group subgroup:&sub];
	self.screen.groupForNewFavorite = sub;

	[self.adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.host = @"db.internal";
	self.screen.name = @"From form";
	NSError *error = nil;
	XCTAssertTrue([self.adapter saveFormAsNewFavorite:&error], @"%@", error);
	NSString *newID = [[self.adapter loadedFavorite] favoriteID];
	id node = [self.adapter nodeForFavoriteID:newID];
	XCTAssertNotNil(node);
	XCTAssertEqualObjects([self namesIn:[sub childNodes]], (@[@"m3", @"From form"]));

	// Saving it again (not as new) keeps it where it is, even with another group for new favorites
	self.screen.groupForNewFavorite = group;
	self.screen.database = @"appdb";
	XCTAssertTrue([self.adapter saveFormAsFavorite:&error], @"%@", error);
	XCTAssertEqual([self.adapter nodeForFavoriteID:newID], node);
	XCTAssertEqual((id)[node parentNode], sub);
	XCTAssertEqualObjects([[self.adapter favoriteForNode:node] database], @"appdb");
	XCTAssertEqual([[self.store favorites] count], 1u);
}

- (void)testDuplicateIsRightAfterOriginal
{
	id group = nil;
	[self makeSectionWithGroup:&group subgroup:NULL];
	NSString *pid = [self savedFavoriteNamed:@"p" inGroup:nil];
	id original = [self.adapter nodeForFavoriteID:pid];
	// Move it into G first, as a drag does (MySQL's drop moves the node in the tree)
	[[[original parentNode] mutableChildNodes] removeObject:original];
	[[group mutableChildNodes] insertObject:original atIndex:0];
	SPPostgresFavorite *favorite = [self.adapter favoriteForNode:original];
	[self.keychain addPassword:@"pw" forName:[favorite keychainName] account:[favorite keychainAccount]];

	id duplicate = [self.adapter duplicateFavoriteNode:original];
	XCTAssertNotNil(duplicate);
	XCTAssertEqualObjects([self namesIn:[group childNodes]], (@[@"p", @"p Copy", @"m2", @"Sub"]));
	XCTAssertEqual([group childNodes][1], duplicate);
	SPPostgresFavorite *copy = [self.adapter favoriteForNode:duplicate];
	XCTAssertNotEqualObjects(copy.favoriteID, pid);
	XCTAssertEqualObjects([self.keychain getPasswordForName:[copy keychainName] account:[copy keychainAccount]], @"pw");
}

- (void)testRenameInTheOutlineMovesKeychainItems
{
	NSString *pid = [self savedFavoriteNamed:@"old name" inGroup:nil];
	SPPostgresFavorite *before = [[self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:pid]] copy];
	[self.keychain addPassword:@"pw" forName:[before keychainName] account:[before keychainAccount]];

	id node = [self.adapter nodeForFavoriteID:pid];
	[self.adapter renameFavoriteNode:node to:@"new name"];
	SPPostgresFavorite *after = [self.adapter favoriteForNode:node];
	XCTAssertEqualObjects(after.name, @"new name");
	XCTAssertEqual([self.adapter nodeForFavoriteID:pid], node, @"same node");
	XCTAssertNil([self.keychain getPasswordForName:[before keychainName] account:[before keychainAccount]]);
	XCTAssertEqualObjects([self.keychain getPasswordForName:[after keychainName] account:[after keychainAccount]], @"pw");
}

/// Deleting a group (SPConnectionController's -_removeNode:) removes the keychain items of the Postgres favorites
/// in it, at any depth, through the adapter; MySQL favorites' items are the controller's own.
- (void)testRemoveKeychainItemsOfPostgresFavoritesWithinGroup
{
	id group = nil, sub = nil;
	[self makeSectionWithGroup:&group subgroup:&sub];
	NSString *p1 = [self savedFavoriteNamed:@"p1" inGroup:group];
	NSString *p2 = [self savedFavoriteNamed:@"p2" inGroup:sub];
	NSString *p3 = [self savedFavoriteNamed:@"p3" inGroup:nil];
	for (NSString *favoriteID in @[p1, p2, p3]) {
		SPPostgresFavorite *favorite = [self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:favoriteID]];
		favorite.sshHost = @"bastion";
		[self.keychain addPassword:@"pw" forName:[favorite keychainName] account:[favorite keychainAccount]];
		[self.keychain addPassword:@"sshpw" forName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
	}
	[self.keychain addPassword:@"mysql" forName:@"Sequel Plus : m2 (2)" account:@"u@mysqlhost/"];

	[self.adapter removeKeychainItemsOfPostgresFavoritesWithinNode:group];

	XCTAssertEqual([self.keychain.items count], 3u, @"p1's and p2's items are gone; p3's and the MySQL one stay");
	SPPostgresFavorite *third = [self.adapter favoriteForNode:[self.adapter nodeForFavoriteID:p3]];
	XCTAssertEqualObjects([self.keychain getPasswordForName:[third keychainName] account:[third keychainAccount]], @"pw");
	XCTAssertEqualObjects([self.keychain getPasswordForName:@"Sequel Plus : m2 (2)" account:@"u@mysqlhost/"], @"mysql");

	// A single Postgres favorite node; MySQL nodes and other objects are ignored
	[self.adapter removeKeychainItemsOfPostgresFavoritesWithinNode:[self.adapter nodeForFavoriteID:p3]];
	[self.adapter removeKeychainItemsOfPostgresFavoritesWithinNode:[self mysqlFavorite:9]];
	[self.adapter removeKeychainItemsOfPostgresFavoritesWithinNode:@"not a node"];
	XCTAssertEqual([self.keychain.items count], 1u);
}

/// The MySQL favorite just added with "+" (a node of the tree) switched to PostgreSQL: the Postgres favorite takes
/// its place, in the same group at the same position.
- (void)testNewMySQLFavoriteConvertedInItsPlace
{
	id group = nil;
	[self makeSectionWithGroup:&group subgroup:NULL];
	id item = [self mysqlFavorite:7];
	[[group mutableChildNodes] insertObject:item atIndex:1]; // m2, m7, Sub
	self.screen.mysqlFavoriteItems = [NSMutableArray arrayWithObject:item];
	self.screen.justAddedMySQLItem = item;
	self.screen.selectedItem = item;
	self.screen.reselectingAdapter = self.adapter;
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.name = @"Converted";

	[self switchEngineTo:SPConnectionEnginePostgreSQL];

	XCTAssertEqualObjects(self.screen.removedMySQLItems, @[item]);
	[[group mutableChildNodes] removeObject:item]; // as the host's removal does
	XCTAssertEqualObjects([self namesIn:[group childNodes]], (@[@"m2", @"Converted", @"Sub"]));
	XCTAssertEqualObjects(self.screen.selectedFavoriteID, [[self.adapter loadedFavorite] favoriteID]);
}

@end
