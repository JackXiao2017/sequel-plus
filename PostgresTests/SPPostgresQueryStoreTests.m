#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresQueryStore.h"

/// The Postgres Query tab's history and favorites store (Stage 11 Task 7), on temporary files only.
@interface SPPostgresQueryStoreTests : XCTestCase
@property (copy) NSString *directory;
@end

@implementation SPPostgresQueryStoreTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[super tearDown];
}

- (NSURL *)urlNamed:(NSString *)name
{
	return [NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:name]];
}

- (void)testSharedStoresAreApartFromMySQLs
{
	// The test run's guard (SPTestPrefsGuard) points them at a temporary directory; they are two stores
	SPPostgresQueryStore *history = [SPPostgresQueryStore sharedHistoryStore];
	SPPostgresQueryStore *favorites = [SPPostgresQueryStore sharedFavoritesStore];
	XCTAssertNotNil(history);
	XCTAssertNotNil(favorites);
	XCTAssertNotEqual(history, favorites);
	XCTAssertEqual(history, [SPPostgresQueryStore sharedHistoryStore]);
	XCTAssertEqualObjects([[history fileURL] lastPathComponent], @"PostgresQueryHistory.plist");
	XCTAssertEqualObjects([[favorites fileURL] lastPathComponent], @"PostgresQueryFavorites.plist");
	XCTAssertFalse([[[history fileURL] path] containsString:@"Application Support"], @"never the real store in tests");
	XCTAssertFalse([[[favorites fileURL] path] containsString:@"Application Support"], @"never the real store in tests");
}

- (void)testRoundTrip
{
	NSURL *url = [self urlNamed:@"sub/dir/History.plist"];
	SPPostgresQueryStore *store = [[SPPostgresQueryStore alloc] initWithFileURL:url];
	XCTAssertEqualObjects(store.items, @[], @"a missing file is fine");
	XCTAssertNil(store.lastLoadError);

	NSError *error = nil;
	NSArray *items = @[@"SELECT 1;\nSELECT 2", @"SELECT 'é'"];
	XCTAssertTrue([store setItems:items error:&error], @"%@", error);
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[url path]], @"created on save");
	XCTAssertEqualObjects(store.items, items);

	// Another store on the same file reads it, and sees a change made through the first one
	SPPostgresQueryStore *other = [[SPPostgresQueryStore alloc] initWithFileURL:url];
	XCTAssertEqualObjects(other.items, items);
	NSArray *favorites = @[@{@"name": @"one", @"query": @"SELECT 1"}];
	XCTAssertTrue([store setItems:favorites error:&error], @"%@", error);
	XCTAssertEqualObjects(other.items, favorites, @"reloaded from the file when it changed");
	XCTAssertNil(other.lastLoadError);
}

- (void)testCorruptStoreIsNotOverwritten
{
	NSURL *url = [self urlNamed:@"History.plist"];
	NSData *garbage = [@"\x01\x02 not a property list {{{" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertTrue([garbage writeToURL:url atomically:YES]);

	SPPostgresQueryStore *store = [[SPPostgresQueryStore alloc] initWithFileURL:url];
	XCTAssertEqualObjects(store.items, @[]);
	XCTAssertNotNil(store.lastLoadError);
	XCTAssertTrue([[store.lastLoadError localizedDescription] containsString:[url path]], @"names the file");

	NSError *error = nil;
	XCTAssertFalse([store setItems:@[@"SELECT 1"] error:&error]);
	XCTAssertNotNil(error);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], garbage, @"left untouched");

	// A file written by a newer build is not overwritten either
	NSURL *newer = [self urlNamed:@"Newer.plist"];
	XCTAssertTrue(([@{@"version": @2, @"items": @[@"SELECT 1"]} writeToURL:newer atomically:YES]));
	NSData *newerData = [NSData dataWithContentsOfURL:newer];
	SPPostgresQueryStore *newerStore = [[SPPostgresQueryStore alloc] initWithFileURL:newer];
	XCTAssertEqualObjects(newerStore.items, @[]);
	XCTAssertNotNil(newerStore.lastLoadError);
	error = nil;
	XCTAssertFalse([newerStore setItems:@[] error:&error]);
	XCTAssertNotNil(error);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:newer], newerData);

	// Once the file is readable again, the store reads and writes it
	XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:url error:NULL]);
	XCTAssertEqualObjects(store.items, @[]);
	XCTAssertNil(store.lastLoadError);
	XCTAssertTrue([store setItems:@[@"SELECT 2"] error:&error], @"%@", error);
	XCTAssertEqualObjects(store.items, @[@"SELECT 2"]);
}

- (void)testChangeNotification
{
	SPPostgresQueryStore *store = [[SPPostgresQueryStore alloc] initWithFileURL:[self urlNamed:@"History.plist"]];
	__block NSUInteger count = 0;
	__block id sender = nil;
	id token = [[NSNotificationCenter defaultCenter] addObserverForName:SPPostgresQueryStoreDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
		count++;
		sender = note.object;
	}];
	NSError *error = nil;
	XCTAssertTrue([store setItems:@[@"SELECT 1"] error:&error], @"%@", error);
	XCTAssertEqual(count, 1u);
	XCTAssertEqual(sender, store);

	// A refused write posts nothing
	NSURL *bad = [self urlNamed:@"Bad.plist"];
	XCTAssertTrue([[@"garbage" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:bad atomically:YES]);
	SPPostgresQueryStore *badStore = [[SPPostgresQueryStore alloc] initWithFileURL:bad];
	XCTAssertFalse([badStore setItems:@[] error:NULL]);
	XCTAssertEqual(count, 1u);
	[[NSNotificationCenter defaultCenter] removeObserver:token];
}

@end
