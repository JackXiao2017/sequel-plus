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
/// Returned by -postgresMySQLSection (the FAVORITES section node).
@property (strong) id mysqlSection;
/// Returned by -postgresGroupForNewFavorite (nil: the section).
@property (strong) id groupForNewFavorite;
/// When set, -postgresFavoritesDidChange reloads like the controller: prepare the outline, saving the layout.
@property (weak) SPPostgresConnectionScreenAdapter *outlineAdapter;
@end

@implementation SPPGFakeConnectionScreen
- (id)postgresMySQLSection { return self.mysqlSection; }
- (id)postgresGroupForNewFavorite { return self.groupForNewFavorite ? self.groupForNewFavorite : self.mysqlSection; }
- (void)postgresFavoritesDidChange
{
	self.favoritesChangedCount++;
	[self.outlineAdapter prepareOutlineWithMySQLSection:self.mysqlSection savingLayout:YES];
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

	// The new favorite has an outline node
	XCTAssertTrue([self.adapter hasPostgresFavorites]);
	id node = [self.adapter nodeForFavoriteID:favorite.favoriteID];
	XCTAssertNotNil(node);
	XCTAssertTrue([self.adapter isPostgresNode:node]);
	XCTAssertEqualObjects([[self.adapter favoriteForNode:node] favoriteID], favorite.favoriteID);
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

/// Postgres favorite rows get their own icon: the MySQL favorites' database icon, the same size, tinted.
- (void)testPostgresFavoriteIconDiffersFromMySQL
{
	NSImage *mysqlIcon = [NSImage imageNamed:@"database-small"];
	NSImage *postgresIcon = [SPPostgresConnectionScreenAdapter favoriteImage];
	XCTAssertNotNil(mysqlIcon);
	XCTAssertNotNil(postgresIcon);
	XCTAssertTrue(NSEqualSizes([postgresIcon size], [mysqlIcon size]));
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

/// A PostgresFavorites.plist that can't be read is reported once per distinct problem, and never rewritten.
- (void)testUnreadableFavoritesFileIsReportedOnce
{
	NSURL *fileURL = [self.dir URLByAppendingPathComponent:@"PostgresFavorites.plist"];
	NSData *garbage = [@"this is not a plist" dataUsingEncoding:NSUTF8StringEncoding];
	[garbage writeToURL:fileURL atomically:YES];

	NSWindow *window = [self visibleSheetWindow];
	SPPGFakeConnectionScreen *screen = [[SPPGFakeConnectionScreen alloc] init];
	screen.sheetWindow = window;
	SPPostgresConnectionScreenAdapter *adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:screen store:self.store];
	adapter.keychain = self.keychain;
	[self addTeardownBlock:^{ [adapter invalidate]; }];

	XCTAssertFalse([adapter hasPostgresFavorites]);
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:5], @"the load error is shown");
	[window endSheet:window.attachedSheet];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);

	// The section is rebuilt (e.g. another window saved): the same problem is not shown again
	[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritesDidChangeNotification object:self.store];
	[self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:1];
	XCTAssertNil(window.attachedSheet, @"the same error is shown once");

	// A different problem is shown
	NSDictionary *newer = @{@"version": @2, @"favorites": @[]};
	XCTAssertTrue([newer writeToURL:fileURL atomically:YES]);
	NSData *newerData = [NSData dataWithContentsOfURL:fileURL];
	[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritesDidChangeNotification object:self.store];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:5]);
	[window endSheet:window.attachedSheet];

	XCTAssertEqualObjects([NSData dataWithContentsOfURL:fileURL], newerData, @"the file is never rewritten");
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


#pragma mark - One FAVORITES list

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

/// FAVORITES: m1, G (m2, Sub (m3)), m4. Returns the section; G and Sub through the out parameters.
- (id)makeSectionWithGroup:(id *)groupOut subgroup:(id *)subOut
{
	id sub = [self mysqlGroup:@"Sub" children:@[[self mysqlFavorite:3]]];
	id group = [self mysqlGroup:@"G" children:@[[self mysqlFavorite:2], sub]];
	id section = [self mysqlGroup:@"FAVORITES" children:@[[self mysqlFavorite:1], group, [self mysqlFavorite:4]]];
	if (groupOut) *groupOut = group;
	if (subOut) *subOut = sub;
	return section;
}

- (NSString *)savedFavoriteNamed:(NSString *)name
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = name;
	favorite.host = @"db";
	NSError *error = nil;
	XCTAssertTrue([self.store saveFavorite:favorite error:&error], @"%@", error);
	return favorite.favoriteID;
}

- (NSURL *)placementsURL
{
	return [self.dir URLByAppendingPathComponent:@"PostgresFavoritePlacements.plist"];
}

- (NSDictionary *)placementsOnDisk
{
	return [NSDictionary dictionaryWithContentsOfURL:[self placementsURL]][@"Placements"];
}

- (SPPostgresConnectionScreenAdapter *)adapterWithScreen:(SPPGFakeConnectionScreen *)screen
{
	// setUp's adapter shares self.screen: retire it so only adapters made here talk to the screens
	[self.adapter invalidate];
	SPPostgresConnectionScreenAdapter *adapter = [[SPPostgresConnectionScreenAdapter alloc] initWithConnectionController:screen store:self.store];
	adapter.keychain = self.keychain;
	screen.outlineAdapter = adapter;
	[self addTeardownBlock:^{ [adapter invalidate]; }];
	return adapter;
}

- (NSArray *)namesIn:(NSArray *)nodes
{
	NSMutableArray *names = [NSMutableArray array];
	for (NSTreeNode *node in nodes) [names addObject:[[node representedObject] nodeName] ?: @"?"];
	return names;
}

- (void)testFirstLoadPutsExistingFavoritesAtTopLevelEndByName
{
	[self savedFavoriteNamed:@"b"];
	[self savedFavoriteNamed:@"a"];
	id section = [self makeSectionWithGroup:NULL subgroup:NULL];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];

	XCTAssertTrue([adapter hasPostgresFavorites]);
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:section]], (@[@"m1", @"G", @"m4", @"a", @"b"]));
	XCTAssertEqual([adapter displayedParentOfNode:[adapter displayedChildrenOfGroup:section].lastObject], section);
	// The next saving load records where they are
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	XCTAssertEqual([[self placementsOnDisk] count], 2u);
	XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:section]], (@[@"m1", @"G", @"m4", @"a", @"b"]));
}

- (void)testMoveIsSavedAndRestoredByANewAdapter
{
	NSString *pid = [self savedFavoriteNamed:@"p"];
	id group = nil;
	id section = [self makeSectionWithGroup:&group subgroup:NULL];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];

	NSUInteger reloads = self.screen.favoritesChangedCount;
	[adapter moveNodes:@[[adapter nodeForFavoriteID:pid]] toGroup:group displayedIndex:1];
	XCTAssertEqual(self.screen.favoritesChangedCount, reloads, @"the adapter's own placements write doesn't reload the host");
	XCTAssertEqualObjects([self placementsOnDisk][pid][@"Group"], (@[@{@"Name": @"G", @"Nth": @0}]));

	SPPGFakeConnectionScreen *otherScreen = [[SPPGFakeConnectionScreen alloc] init];
	otherScreen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *other = [self adapterWithScreen:otherScreen];
	[other prepareOutlineWithMySQLSection:section savingLayout:NO];
	XCTAssertEqual([other displayedParentOfNode:[other nodeForFavoriteID:pid]], group);
	XCTAssertEqualObjects([self namesIn:[other displayedChildrenOfGroup:group]], (@[@"m2", @"p", @"Sub"]));
}

- (void)testAddNewFavoriteGoesToEndOfGroupForNewFavorite
{
	[self savedFavoriteNamed:@"zzz"];
	id group = nil;
	id section = [self makeSectionWithGroup:&group subgroup:NULL];
	self.screen.mysqlSection = section;
	self.screen.groupForNewFavorite = group;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];

	id node = [adapter addNewFavorite];
	XCTAssertNotNil(node);
	XCTAssertEqual([adapter displayedChildrenOfGroup:group].lastObject, node);
	XCTAssertEqual([adapter displayedParentOfNode:node], group);
	NSString *newID = [[adapter favoriteForNode:node] favoriteID];
	XCTAssertEqualObjects([self placementsOnDisk][newID][@"Group"], (@[@{@"Name": @"G", @"Nth": @0}]));

	// Still there for a new adapter on the same files
	SPPGFakeConnectionScreen *otherScreen = [[SPPGFakeConnectionScreen alloc] init];
	otherScreen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *other = [self adapterWithScreen:otherScreen];
	[other prepareOutlineWithMySQLSection:section savingLayout:NO];
	XCTAssertEqual([other displayedChildrenOfGroup:group].lastObject, [other nodeForFavoriteID:newID]);
}

- (void)testAddNewFavoriteBeforeAnyOutlineGoesToTopLevelEnd
{
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	id node = [adapter addNewFavorite];
	XCTAssertNotNil(node, @"no layout yet: saved without a placement");
	XCTAssertEqual([[self.store favorites] count], 1u);
	XCTAssertNil([self placementsOnDisk]);

	id section = [self makeSectionWithGroup:NULL subgroup:NULL];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:NO];
	XCTAssertEqual([adapter displayedChildrenOfGroup:section].lastObject, node);
}

- (void)testSaveFormAsNewFavoriteGoesToEndOfGroupForNewFavorite
{
	id group = nil, sub = nil;
	id section = [self makeSectionWithGroup:&group subgroup:&sub];
	self.screen.mysqlSection = section;
	self.screen.groupForNewFavorite = sub;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];

	[adapter setSelectedEngine:SPConnectionEnginePostgreSQL];
	self.screen.type = SPPostgresTCPIPConnection;
	self.screen.host = @"db.internal";
	self.screen.name = @"From form";
	NSError *error = nil;
	XCTAssertTrue([adapter saveFormAsNewFavorite:&error], @"%@", error);
	NSString *newID = [[adapter loadedFavorite] favoriteID];
	id node = [adapter nodeForFavoriteID:newID];
	XCTAssertNotNil(node);
	XCTAssertEqual([adapter displayedChildrenOfGroup:sub].lastObject, node);
	XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:sub]], (@[@"m3", @"From form"]));

	// Saving it again (not as new) keeps it where it is
	self.screen.database = @"appdb";
	XCTAssertTrue([adapter saveFormAsFavorite:&error], @"%@", error);
	XCTAssertEqual([adapter displayedParentOfNode:[adapter nodeForFavoriteID:newID]], sub);
	XCTAssertEqual([[self.store favorites] count], 1u);
}

- (void)testDuplicateIsDisplayedRightAfterOriginal
{
	NSString *pid = [self savedFavoriteNamed:@"p"];
	[self savedFavoriteNamed:@"q"];
	id group = nil;
	id section = [self makeSectionWithGroup:&group subgroup:NULL];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapter moveNodes:@[[adapter nodeForFavoriteID:pid]] toGroup:group displayedIndex:0];

	id duplicate = [adapter duplicateFavoriteNode:[adapter nodeForFavoriteID:pid]];
	XCTAssertNotNil(duplicate);
	XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:group]], (@[@"p", @"p Copy", @"m2", @"Sub"]));
	XCTAssertEqual([adapter displayedChildrenOfGroup:group][1], duplicate);
}

- (void)testRemovePostgresFavoritesWithinGroup
{
	NSString *p1 = [self savedFavoriteNamed:@"p1"];
	NSString *p2 = [self savedFavoriteNamed:@"p2"];
	NSString *p3 = [self savedFavoriteNamed:@"p3"];
	for (NSString *favoriteID in @[p1, p2, p3]) {
		for (SPPostgresFavorite *favorite in [self.store favorites]) {
			if ([favorite.favoriteID isEqualToString:favoriteID]) [self.keychain addPassword:@"pw" forName:[favorite keychainName] account:[favorite keychainAccount]];
		}
	}
	id group = nil, sub = nil;
	id section = [self makeSectionWithGroup:&group subgroup:&sub];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapter moveNodes:@[[adapter nodeForFavoriteID:p1]] toGroup:group displayedIndex:0];
	[adapter moveNodes:@[[adapter nodeForFavoriteID:p2]] toGroup:sub displayedIndex:0];

	[adapter removePostgresFavoritesWithinGroup:group];

	NSArray *remaining = [[self.store favorites] valueForKey:@"favoriteID"];
	XCTAssertEqualObjects(remaining, @[p3]);
	XCTAssertEqual([self.keychain.items count], 1u, @"p1's and p2's keychain items are gone");
	XCTAssertNotNil([adapter nodeForFavoriteID:p3]);
	XCTAssertEqual([adapter displayedParentOfNode:[adapter nodeForFavoriteID:p3]], section);
	XCTAssertEqualObjects([[self placementsOnDisk] allKeys], @[p3], @"the removed favorites' placements are pruned");
}

- (void)testOutsideChangeDoesNotSaveStaleLayout
{
	NSString *pid = [self savedFavoriteNamed:@"p"];
	id group = nil;
	id section = [self makeSectionWithGroup:&group subgroup:NULL];

	SPPGFakeConnectionScreen *screenB = [[SPPGFakeConnectionScreen alloc] init];
	screenB.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapterB = [self adapterWithScreen:screenB];
	[adapterB prepareOutlineWithMySQLSection:section savingLayout:YES];
	XCTAssertEqual([adapterB displayedParentOfNode:[adapterB nodeForFavoriteID:pid]], section);

	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapterA = [self adapterWithScreen:self.screen];
	[adapterA prepareOutlineWithMySQLSection:section savingLayout:YES];
	NSUInteger reloadsB = screenB.favoritesChangedCount;
	[adapterA moveNodes:@[[adapterA nodeForFavoriteID:pid]] toGroup:group displayedIndex:0];

	XCTAssertGreaterThan(screenB.favoritesChangedCount, reloadsB, @"B heard of the change and reloaded (saving its layout)");
	XCTAssertEqual([adapterB displayedParentOfNode:[adapterB nodeForFavoriteID:pid]], group);
	[adapterB prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapterB prepareOutlineWithMySQLSection:section savingLayout:NO];
	XCTAssertEqual([adapterB displayedParentOfNode:[adapterB nodeForFavoriteID:pid]], group);
	XCTAssertEqualObjects([self placementsOnDisk][pid][@"Group"], (@[@{@"Name": @"G", @"Nth": @0}]), @"the file still says G");
}

- (void)testDeletedFavoritePlacementIsPruned
{
	NSString *keep = [self savedFavoriteNamed:@"keep"];
	NSString *gone = [self savedFavoriteNamed:@"gone"];
	id section = [self makeSectionWithGroup:NULL subgroup:NULL];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	XCTAssertEqual([[self placementsOnDisk] count], 2u);

	// Removed elsewhere (another store client): the host's reload saves the layout without it
	NSError *error = nil;
	XCTAssertTrue([self.store removeFavoriteWithID:gone error:&error], @"%@", error);
	XCTAssertNil([adapter nodeForFavoriteID:gone]);
	XCTAssertEqualObjects([[self placementsOnDisk] allKeys], @[keep]);
}

- (void)testNothingWrittenWithoutChange
{
	[self savedFavoriteNamed:@"p"];
	id section = [self makeSectionWithGroup:NULL subgroup:NULL];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	XCTAssertNotNil([self placementsOnDisk]);

	NSDate *past = [NSDate dateWithTimeIntervalSinceNow:-3600];
	NSError *error = nil;
	XCTAssertTrue([[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: past} ofItemAtPath:[[self placementsURL] path] error:&error], @"%@", error);
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:[[self placementsURL] path] error:NULL][NSFileModificationDate];
	XCTAssertEqualWithAccuracy([modified timeIntervalSinceReferenceDate], [past timeIntervalSinceReferenceDate], 1.0, @"not rewritten");
}

/// Placements other favorites' arrangement doesn't hold (e.g. written by another window for a favorite this
/// window doesn't show yet) are kept when saving; the snapshot wins for the favorites it holds.
- (void)testSavingMergesOverStoredPlacements
{
	NSString *pid = [self savedFavoriteNamed:@"p"];
	id group = nil;
	id section = [self makeSectionWithGroup:&group subgroup:NULL];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];

	// A favorite saved by another client after its placement was written: not yet in this adapter's arrangement
	SPPostgresFavorite *later = [[SPPostgresFavorite alloc] init];
	later.name = @"later";
	NSDictionary *laterPlacement = @{@"Group": @[@{@"Name": @"G", @"Nth": @0}], @"Index": @2, @"Order": @0, @"After": @{@"GroupName": @"Sub", @"Nth": @0}};
	NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:([self placementsOnDisk] ?: @{})];
	all[later.favoriteID] = laterPlacement;
	NSDictionary *file = @{@"Version": @1, @"Placements": all};
	XCTAssertTrue([file writeToURL:[self placementsURL] atomically:YES]);
	NSError *error = nil;
	XCTAssertTrue([self.store saveFavorite:later error:&error], @"%@", error);

	XCTAssertEqual([adapter displayedChildrenOfGroup:group].lastObject, [adapter nodeForFavoriteID:later.favoriteID]);
	[adapter moveNodes:@[[adapter nodeForFavoriteID:pid]] toGroup:group displayedIndex:0];
	XCTAssertEqualObjects([self placementsOnDisk][later.favoriteID], laterPlacement);
	XCTAssertEqualObjects([self placementsOnDisk][pid][@"Group"], (@[@{@"Name": @"G", @"Nth": @0}]));
}


/// Two windows show P in the second of two groups named X; the first X is deleted (the shared MySQL tree
/// changes under both). Each window's reload saves its layout snapshot against the changed tree: P stays in
/// its group, and the file says so for later windows. A reload from the file alone would lose the group.
- (void)testDeletingAMySQLGroupKeepsPostgresPlaceWhenSavingLayout
{
	NSString *pid = [self savedFavoriteNamed:@"p"];
	id x1 = [self mysqlGroup:@"X" children:@[[self mysqlFavorite:1]]];
	id x2 = [self mysqlGroup:@"X" children:@[[self mysqlFavorite:2], [self mysqlFavorite:3]]];
	id section = [self mysqlGroup:@"FAVORITES" children:@[x1, x2, [self mysqlFavorite:4]]];

	SPPGFakeConnectionScreen *screenB = [[SPPGFakeConnectionScreen alloc] init];
	screenB.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapterB = [self adapterWithScreen:screenB];
	[adapterB prepareOutlineWithMySQLSection:section savingLayout:YES];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapterA = [self adapterWithScreen:self.screen];
	[adapterA prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapterA moveNodes:@[[adapterA nodeForFavoriteID:pid]] toGroup:x2 displayedIndex:1];
	XCTAssertEqualObjects([self namesIn:[adapterB displayedChildrenOfGroup:x2]], (@[@"m2", @"p", @"m3"]));

	[[section mutableChildNodes] removeObject:x1];
	[adapterA prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapterB prepareOutlineWithMySQLSection:section savingLayout:YES];

	for (SPPostgresConnectionScreenAdapter *adapter in @[adapterA, adapterB]) {
		XCTAssertEqual([adapter displayedParentOfNode:[adapter nodeForFavoriteID:pid]], x2);
		XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:x2]], (@[@"m2", @"p", @"m3"]));
	}
	XCTAssertEqualObjects([self placementsOnDisk][pid][@"Group"], (@[@{@"Name": @"X", @"Nth": @0}]));
	XCTAssertEqualObjects([self placementsOnDisk][pid][@"After"], (@{@"FavoriteID": @2}));
}

/// A MySQL favorite P followed is deleted: P stays between the neighbours, and the file says so.
- (void)testDeletingAnchorMySQLFavoriteKeepsPostgresBetweenNeighbours
{
	NSString *pid = [self savedFavoriteNamed:@"p"];
	id m2 = [self mysqlFavorite:2];
	id section = [self mysqlGroup:@"FAVORITES" children:@[[self mysqlFavorite:1], m2, [self mysqlFavorite:3]]];
	self.screen.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapter = [self adapterWithScreen:self.screen];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	[adapter moveNodes:@[[adapter nodeForFavoriteID:pid]] toGroup:section displayedIndex:2];
	XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:section]], (@[@"m1", @"m2", @"p", @"m3"]));

	[[section mutableChildNodes] removeObject:m2];
	[adapter prepareOutlineWithMySQLSection:section savingLayout:YES];
	XCTAssertEqualObjects([self namesIn:[adapter displayedChildrenOfGroup:section]], (@[@"m1", @"p", @"m3"]));
	XCTAssertEqualObjects([self placementsOnDisk][pid][@"After"], (@{@"FavoriteID": @1}));
}

/// Another window adds a favorite into G: its placement is written before the favorite is saved, and this
/// window's reload in between must not prune it.
- (void)testNewFavoriteFromAnotherWindowKeepsItsPlacement
{
	[self savedFavoriteNamed:@"p"];
	id group = nil;
	id section = [self makeSectionWithGroup:&group subgroup:NULL];

	SPPGFakeConnectionScreen *screenB = [[SPPGFakeConnectionScreen alloc] init];
	screenB.mysqlSection = section;
	SPPostgresConnectionScreenAdapter *adapterB = [self adapterWithScreen:screenB];
	[adapterB prepareOutlineWithMySQLSection:section savingLayout:YES];

	self.screen.mysqlSection = section;
	self.screen.groupForNewFavorite = group;
	SPPostgresConnectionScreenAdapter *adapterA = [self adapterWithScreen:self.screen];
	[adapterA prepareOutlineWithMySQLSection:section savingLayout:YES];
	id node = [adapterA addNewFavorite];
	NSString *newID = [[adapterA favoriteForNode:node] favoriteID];

	XCTAssertEqualObjects([self placementsOnDisk][newID][@"Group"], (@[@{@"Name": @"G", @"Nth": @0}]));
	XCTAssertEqual([adapterB displayedChildrenOfGroup:group].lastObject, [adapterB nodeForFavoriteID:newID]);
}

@end
