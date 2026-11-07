#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoriteNode.h"
#import "../Source/Postgres/SPPostgresFavoritesStore.h"

// SPTreeNode / SPGroupNode / SPFavoriteNode are app classes without exported symbols: look them up at run time
@interface NSObject (SPPGStoreTestsMySQLNodes)
+ (id)groupNodeWithName:(NSString *)name;
+ (id)favoriteNodeWithDictionary:(NSMutableDictionary *)dictionary;
- (BOOL)isGroup;
- (NSArray *)descendants;
@end

/// The store is a view of the PostgreSQL favorites in the favorites tree: these tests use in-memory trees only
/// (never SPFavoritesController's, never a file).
@interface SPPostgresFavoritesStoreTests : XCTestCase
@end

@implementation SPPostgresFavoritesStoreTests

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
	f.socketPath = @"/tmp/.s.PGSQL.5432";
	f.useSSL = YES;
	f.sslCACertPath = @"/ca.pem";
	f.sslCertPath = @"/cert.pem";
	f.sslKeyPath = @"/key.pem";
	f.sshHost = @"bastion";
	f.sshUser = @"bob";
	f.sshPort = 2222;
	f.sshKeyPath = @"/id_rsa";
	return f;
}

- (SPPostgresFavorite *)favoriteNamed:(NSString *)name
{
	SPPostgresFavorite *f = [[SPPostgresFavorite alloc] init];
	f.name = name;
	f.host = @"db";
	return f;
}

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

- (NSArray *)namesIn:(NSArray *)nodes
{
	NSMutableArray *names = [NSMutableArray array];
	for (NSTreeNode *node in nodes) [names addObject:[[node representedObject] nodeName] ?: @"?"];
	return names;
}

/// A store over `section`, whose saves answer `saveResult` and are counted in `saves`.
- (SPPostgresFavoritesStore *)storeOverSection:(id)section saveResult:(BOOL *)saveResult saves:(NSUInteger *)saves
{
	return [[SPPostgresFavoritesStore alloc] initWithSectionProvider:^SPTreeNode *{ return section; } saveHandler:^BOOL{
		if (saves) (*saves)++;
		return saveResult ? *saveResult : YES;
	} loadErrorProvider:nil];
}

- (void)testInMemoryStoreRoundTripsEveryField
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initInMemory];
	XCTAssertNotNil([store section]);
	XCTAssertEqual([[store favorites] count], 0u);

	SPPostgresFavorite *f = [self fullFavorite];
	NSError *error = nil;
	XCTAssertTrue([store saveFavorite:f error:&error], @"%@", error);
	XCTAssertEqual([[store favorites] count], 1u);
	SPPostgresFavorite *g = [store favorites].firstObject;
	XCTAssertEqualObjects([g dictionaryRepresentation], [f dictionaryRepresentation]);
	XCTAssertFalse(g == f, @"the store keeps its own copy");

	id node = [store nodeForFavoriteID:f.favoriteID];
	XCTAssertNotNil(node);
	XCTAssertEqual((id)[node parentNode], (id)[store section], @"a new favorite without a group goes to the end of the section");
	XCTAssertFalse([node isGroup]);
	XCTAssertEqualObjects([SPPostgresFavoriteForNode(node) favoriteID], f.favoriteID);
}

- (void)testFavoritesAreSortedByNameAndNodesInTreeOrder
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initInMemory];
	id group = [self mysqlGroup:@"G" children:@[[self mysqlFavorite:1]]];
	[[(NSTreeNode *)[store section] mutableChildNodes] addObject:group];

	NSError *error = nil;
	XCTAssertNotNil([store addFavorite:[self favoriteNamed:@"b"] toGroup:nil atIndex:NSNotFound error:&error], @"%@", error);
	XCTAssertNotNil([store addFavorite:[self favoriteNamed:@"A"] toGroup:group atIndex:0 error:&error], @"%@", error);
	XCTAssertNotNil([store addFavorite:[self favoriteNamed:@"c"] toGroup:group atIndex:NSNotFound error:&error], @"%@", error);

	XCTAssertEqualObjects([[store favorites] valueForKey:@"name"], (@[@"A", @"b", @"c"]));
	XCTAssertEqualObjects([self namesIn:[store favoriteNodes]], (@[@"A", @"c", @"b"]), @"depth first, in tree order");
	XCTAssertEqualObjects([self namesIn:[group childNodes]], (@[@"A", @"m1", @"c"]));
}

- (void)testAddToNonGroupOrForeignNodeGoesToTheSection
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initInMemory];
	id mysql = [self mysqlFavorite:1];
	[[(NSTreeNode *)[store section] mutableChildNodes] addObject:mysql];
	id foreignGroup = [self mysqlGroup:@"Elsewhere" children:@[]];

	id a = [store addFavorite:[self favoriteNamed:@"a"] toGroup:mysql atIndex:0 error:NULL];
	id b = [store addFavorite:[self favoriteNamed:@"b"] toGroup:foreignGroup atIndex:0 error:NULL];
	id c = [store addFavorite:[self favoriteNamed:@"c"] toGroup:a atIndex:0 error:NULL];
	XCTAssertEqualObjects([self namesIn:[(NSTreeNode *)[store section] childNodes]], (@[@"m1", @"a", @"b", @"c"]), @"at the end (the index was for another group)");
	XCTAssertEqual([[foreignGroup childNodes] count], 0u);
	XCTAssertEqual((id)[b parentNode], (id)[store section]);
	XCTAssertEqual((id)[c parentNode], (id)[store section]);
}

- (void)testSaveReplacesFavoriteInPlace
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initInMemory];
	id group = [self mysqlGroup:@"G" children:@[[self mysqlFavorite:1], [self mysqlFavorite:2]]];
	[[(NSTreeNode *)[store section] mutableChildNodes] addObject:group];
	SPPostgresFavorite *f = [self favoriteNamed:@"Before"];
	id node = [store addFavorite:f toGroup:group atIndex:1 error:NULL];

	SPPostgresFavorite *renamed = [f copy];
	renamed.name = @"After";
	renamed.port = 6000;
	NSError *error = nil;
	XCTAssertTrue([store saveFavorite:renamed error:&error], @"%@", error);
	XCTAssertEqual((id)[store nodeForFavoriteID:f.favoriteID], node, @"same node");
	XCTAssertEqualObjects([self namesIn:[group childNodes]], (@[@"m1", @"After", @"m2"]), @"same place");
	XCTAssertEqual(((SPPostgresFavorite *)[store favorites].firstObject).port, 6000u);
	XCTAssertEqual([[store favorites] count], 1u);
}

- (void)testRemoveDeletesOnlyThatFavorite
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initInMemory];
	id group = [self mysqlGroup:@"G" children:@[[self mysqlFavorite:1]]];
	[[(NSTreeNode *)[store section] mutableChildNodes] addObject:group];
	SPPostgresFavorite *a = [self favoriteNamed:@"a"], *b = [self favoriteNamed:@"b"];
	[store addFavorite:a toGroup:group atIndex:NSNotFound error:NULL];
	[store addFavorite:b toGroup:nil atIndex:NSNotFound error:NULL];

	NSError *error = nil;
	XCTAssertTrue([store removeFavoriteWithID:a.favoriteID error:&error], @"%@", error);
	XCTAssertEqualObjects([[store favorites] valueForKey:@"favoriteID"], @[b.favoriteID]);
	XCTAssertEqualObjects([self namesIn:[group childNodes]], @[@"m1"], @"MySQL favorites untouched");
	XCTAssertTrue([store removeFavoriteWithID:@"no-such-id" error:&error], @"nothing to remove is fine");
}

- (void)testFailedSaveUndoesTheChangeAndDoesNotNotify
{
	id section = [self mysqlGroup:@"FAVORITES" children:@[[self mysqlFavorite:1]]];
	BOOL saveResult = YES;
	NSUInteger saves = 0;
	SPPostgresFavoritesStore *store = [self storeOverSection:section saveResult:&saveResult saves:&saves];
	SPPostgresFavorite *f = [self favoriteNamed:@"kept"];
	XCTAssertNotNil([store addFavorite:f toGroup:section atIndex:0 error:NULL]);
	XCTAssertEqual(saves, 1u);

	__block NSUInteger notifications = 0;
	id observer = [[NSNotificationCenter defaultCenter] addObserverForName:SPPostgresFavoritesDidChangeNotification object:store queue:nil usingBlock:^(NSNotification *n) { notifications++; }];
	[self addTeardownBlock:^{ [[NSNotificationCenter defaultCenter] removeObserver:observer]; }];

	saveResult = NO;
	NSError *error = nil;
	XCTAssertNil([store addFavorite:[self favoriteNamed:@"new"] toGroup:nil atIndex:NSNotFound error:&error]);
	XCTAssertNotNil(error);
	SPPostgresFavorite *changed = [f copy];
	changed.name = @"changed";
	error = nil;
	XCTAssertFalse([store saveFavorite:changed error:&error]);
	XCTAssertNotNil(error);
	error = nil;
	XCTAssertFalse([store removeFavoriteWithID:f.favoriteID error:&error]);
	XCTAssertNotNil(error);

	XCTAssertEqualObjects([self namesIn:[section childNodes]], (@[@"kept", @"m1"]), @"every change undone");
	XCTAssertEqual(notifications, 0u);

	saveResult = YES;
	XCTAssertTrue([store saveFavorite:changed error:&error], @"%@", error);
	XCTAssertEqual(notifications, 1u);
	XCTAssertTrue([store removeFavoriteWithID:f.favoriteID error:&error], @"%@", error);
	XCTAssertEqual(notifications, 2u);
}

- (void)testNoTreeIsAnError
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithSectionProvider:^SPTreeNode *{ return nil; } saveHandler:^BOOL{ return YES; } loadErrorProvider:nil];
	NSError *error = nil;
	XCTAssertNil([store addFavorite:[self favoriteNamed:@"a"] toGroup:nil atIndex:NSNotFound error:&error]);
	XCTAssertNotNil(error);
	XCTAssertEqual([[store favorites] count], 0u);
}

- (void)testLastLoadErrorComesFromTheProvider
{
	NSError *problem = [NSError errorWithDomain:@"test" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"cannot read" }];
	__block NSError *current = problem;
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithSectionProvider:nil saveHandler:nil loadErrorProvider:^NSError *{ return current; }];
	XCTAssertEqualObjects([store lastLoadError], problem);
	current = nil;
	XCTAssertNil([store lastLoadError]);
	XCTAssertNil([[[SPPostgresFavoritesStore alloc] initInMemory] lastLoadError]);
}

- (void)testKeychainNamesUsePostgresPrefix
{
	SPPostgresFavorite *f = [self fullFavorite];
	XCTAssertTrue([[f keychainName] hasPrefix:@"Sequel Plus (PostgreSQL) : Prod ("]);
	XCTAssertTrue([[f sshKeychainName] hasPrefix:@"Sequel Plus (PostgreSQL) SSHTunnel : Prod ("]);
	XCTAssertEqualObjects([f keychainAccount], @"alice@db.example.com/appdb");
	XCTAssertEqualObjects([f sshKeychainAccount], @"bob@bastion");
}

@end
