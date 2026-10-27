#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoritesStore.h"

@interface SPPostgresFavoritesStoreTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, strong) NSURL *fileURL;
@end

@implementation SPPostgresFavoritesStoreTests

- (void)setUp
{
	NSString *name = [@"SPPGFavTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
	self.fileURL = [self.dir URLByAppendingPathComponent:@"PostgresFavorites.plist"];
}

- (void)tearDown
{
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

- (void)testRoundTripPreservesEveryField
{
	SPPostgresFavorite *f = [self fullFavorite];
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	NSError *error = nil;
	XCTAssertTrue([store saveFavorite:f error:&error], @"%@", error);

	SPPostgresFavoritesStore *reloaded = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	XCTAssertEqual(reloaded.favorites.count, 1u);
	SPPostgresFavorite *g = reloaded.favorites.firstObject;
	XCTAssertEqualObjects(g.favoriteID, f.favoriteID);
	XCTAssertEqualObjects(g.name, @"Prod");
	XCTAssertEqual(g.colorIndex, 3);
	XCTAssertEqual(g.type, SPPostgresSSHConnection);
	XCTAssertEqualObjects(g.host, @"db.example.com");
	XCTAssertEqual(g.port, 6543u);
	XCTAssertEqualObjects(g.user, @"alice");
	XCTAssertEqualObjects(g.database, @"appdb");
	XCTAssertEqualObjects(g.socketPath, @"/tmp/.s.PGSQL.5432");
	XCTAssertTrue(g.useSSL);
	XCTAssertEqualObjects(g.sslCACertPath, @"/ca.pem");
	XCTAssertEqualObjects(g.sslCertPath, @"/cert.pem");
	XCTAssertEqualObjects(g.sslKeyPath, @"/key.pem");
	XCTAssertEqualObjects(g.sshHost, @"bastion");
	XCTAssertEqualObjects(g.sshUser, @"bob");
	XCTAssertEqual(g.sshPort, 2222u);
	XCTAssertEqualObjects(g.sshKeyPath, @"/id_rsa");

	// Defaults and nil strings
	SPPostgresFavorite *d = [[SPPostgresFavorite alloc] init];
	XCTAssertEqual(d.port, 5432u);
	XCTAssertEqual(d.type, SPPostgresTCPIPConnection);
	XCTAssertEqual(d.colorIndex, -1);
	XCTAssertNotNil(d.favoriteID);
	SPPostgresFavorite *e = [SPPostgresFavorite favoriteWithDictionary:[d dictionaryRepresentation]];
	XCTAssertEqualObjects(e.favoriteID, d.favoriteID);
	XCTAssertNil(e.host);
	XCTAssertEqual(e.colorIndex, -1);
	XCTAssertEqual(e.port, 5432u);
	XCTAssertFalse(e.useSSL);

	SPPostgresFavorite *c = [f copy];
	XCTAssertEqualObjects(c.favoriteID, f.favoriteID);
	XCTAssertEqualObjects(c.sshKeyPath, f.sshKeyPath);
}

- (void)testSaveReplacesFavoriteWithSameID
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	SPPostgresFavorite *f = [self fullFavorite];
	XCTAssertTrue([store saveFavorite:f error:nil]);
	SPPostgresFavorite *g = [f copy];
	g.name = @"Renamed";
	XCTAssertTrue([store saveFavorite:g error:nil]);
	XCTAssertEqual(store.favorites.count, 1u);
	XCTAssertEqualObjects([store.favorites.firstObject name], @"Renamed");
}

- (void)testRemoveDeletesOnlyThatFavorite
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	SPPostgresFavorite *a = [self fullFavorite]; a.name = @"beta";
	SPPostgresFavorite *b = [self fullFavorite]; b.name = @"Alpha";
	XCTAssertTrue([store saveFavorite:a error:nil]);
	XCTAssertTrue([store saveFavorite:b error:nil]);
	XCTAssertEqualObjects([store.favorites.firstObject name], @"Alpha", @"sorted case-insensitively");
	XCTAssertTrue([store removeFavoriteWithID:b.favoriteID error:nil]);
	XCTAssertEqual(store.favorites.count, 1u);
	XCTAssertEqualObjects([store.favorites.firstObject favoriteID], a.favoriteID);
}

- (void)testMissingFileMeansNoFavorites
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	XCTAssertEqual(store.favorites.count, 0u);
}

- (void)testNeverTouchesMySQLFavoritesFile
{
	NSURL *mysql = [self.dir URLByAppendingPathComponent:@"Favorites.plist"];
	NSData *bytes = [@"original-bytes" dataUsingEncoding:NSUTF8StringEncoding];
	[bytes writeToURL:mysql atomically:YES];
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	SPPostgresFavorite *f = [self fullFavorite];
	XCTAssertTrue([store saveFavorite:f error:nil]);
	XCTAssertTrue([store removeFavoriteWithID:f.favoriteID error:nil]);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:mysql], bytes);
}

- (void)testKeychainNamesUsePostgresPrefix
{
	SPPostgresFavorite *f = [self fullFavorite];
	XCTAssertTrue([f.keychainName hasPrefix:@"Sequel Pro (PostgreSQL) : "]);
	XCTAssertEqualObjects(f.keychainName, ([NSString stringWithFormat:@"Sequel Pro (PostgreSQL) : Prod (%@)", f.favoriteID]));
	XCTAssertEqualObjects(f.keychainAccount, @"alice@db.example.com/appdb");
	XCTAssertEqualObjects(f.sshKeychainName, ([NSString stringWithFormat:@"Sequel Pro (PostgreSQL) SSHTunnel : Prod (%@)", f.favoriteID]));
	XCTAssertEqualObjects(f.sshKeychainAccount, @"bob@bastion");
}

- (void)testNotificationPostedOnSaveAndRemoveButNotOnRefusal
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	__block NSInteger count = 0;
	id token = [[NSNotificationCenter defaultCenter] addObserverForName:SPPostgresFavoritesDidChangeNotification
																 object:nil queue:nil usingBlock:^(NSNotification *n) { count++; }];
	SPPostgresFavorite *f = [self fullFavorite];
	XCTAssertTrue([store saveFavorite:f error:nil]);
	XCTAssertEqual(count, 1);
	XCTAssertTrue([store removeFavoriteWithID:f.favoriteID error:nil]);
	XCTAssertEqual(count, 2);

	[[@"garbage" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:self.fileURL atomically:YES];
	XCTAssertFalse([store saveFavorite:f error:nil]);
	XCTAssertFalse([store removeFavoriteWithID:f.favoriteID error:nil]);
	XCTAssertEqual(count, 2, @"refused writes must not notify");
	[[NSNotificationCenter defaultCenter] removeObserver:token];
}

- (void)testWritesVersionOne
{
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	XCTAssertTrue([store saveFavorite:[self fullFavorite] error:nil]);
	NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:self.fileURL];
	XCTAssertEqualObjects(root[@"version"], @1);
	XCTAssertEqual([root[@"favorites"] count], 1u);
}

- (void)testCorruptFileIsRefusedAndLeftUntouched
{
	NSData *garbage = [@"this is not a plist" dataUsingEncoding:NSUTF8StringEncoding];
	[garbage writeToURL:self.fileURL atomically:YES];
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	XCTAssertEqual(store.favorites.count, 0u);
	NSError *error = nil;
	XCTAssertFalse([store saveFavorite:[self fullFavorite] error:&error]);
	XCTAssertNotNil(error);
	XCTAssertTrue(error.localizedDescription.length > 0);
	error = nil;
	XCTAssertFalse([store removeFavoriteWithID:@"x" error:&error]);
	XCTAssertNotNil(error);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.fileURL], garbage);
}

- (void)testNewerVersionFileIsRefusedAndLeftUntouched
{
	NSDictionary *root = @{@"version": @2, @"favorites": @[[[self fullFavorite] dictionaryRepresentation]]};
	XCTAssertTrue([root writeToURL:self.fileURL atomically:YES]);
	NSData *before = [NSData dataWithContentsOfURL:self.fileURL];
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:self.fileURL];
	NSError *error = nil;
	XCTAssertFalse([store saveFavorite:[self fullFavorite] error:&error]);
	XCTAssertNotNil(error);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.fileURL], before);
}

- (void)testWriteFailurePopulatesError
{
	NSURL *ro = [self.dir URLByAppendingPathComponent:@"readonly" isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:ro withIntermediateDirectories:YES attributes:nil error:nil];
	[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0500} ofItemAtPath:ro.path error:nil];
	SPPostgresFavoritesStore *store = [[SPPostgresFavoritesStore alloc] initWithFileURL:[ro URLByAppendingPathComponent:@"PostgresFavorites.plist"]];
	NSError *error = nil;
	BOOL ok = [store saveFavorite:[self fullFavorite] error:&error];
	[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:ro.path error:nil];
	XCTAssertFalse(ok);
	XCTAssertNotNil(error);
}

@end
