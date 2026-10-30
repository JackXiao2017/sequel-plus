#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresQueryStore.h"

/// The Postgres Query tab's history and favorites store (Stage 11 Task 7), on temporary files only.
@interface SPPostgresQueryStoreTests : XCTestCase
@property (copy) NSString *directory;
@end

/// "History.unreadable-<yyyyMMdd-HHmmss>[-n].plist"
static BOOL SPMatchesAsideName(NSString *name)
{
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^History\\.unreadable-\\d{8}-\\d{6}(-\\d+)?\\.plist$" options:0 error:NULL];
	return [regex firstMatchInString:name options:0 range:NSMakeRange(0, [name length])] != nil;
}

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

/// The guard empties the redirected shared stores after every test: whichever of these two runs second sees nothing
/// the first wrote.
- (void)assertSharedStoresStartEmptyThenWrite
{
	for (SPPostgresQueryStore *store in @[[SPPostgresQueryStore sharedHistoryStore], [SPPostgresQueryStore sharedFavoritesStore]]) {
		XCTAssertEqualObjects(store.items, @[], @"%@", [store fileURL]);
		NSError *error = nil;
		XCTAssertTrue([store setItems:@[@"left by a test"] error:&error], @"%@", error);
	}
}

- (void)testSharedStoresStartEmpty
{
	[self assertSharedStoresStartEmptyThenWrite];
}

- (void)testSharedStoresStartEmptyAgain
{
	[self assertSharedStoresStartEmptyThenWrite];
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

	// A file written by a newer build is not overwritten either; its readable items are shown (read-only)
	NSURL *newer = [self urlNamed:@"Newer.plist"];
	XCTAssertTrue(([@{@"version": @2, @"items": @[@"SELECT 1"]} writeToURL:newer atomically:YES]));
	NSData *newerData = [NSData dataWithContentsOfURL:newer];
	SPPostgresQueryStore *newerStore = [[SPPostgresQueryStore alloc] initWithFileURL:newer];
	XCTAssertEqualObjects(newerStore.items, @[@"SELECT 1"], @"the menus show what can be read");
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

/// The files beside url whose names start with "<basename>.unreadable-".
- (NSArray<NSString *> *)asideFilesFor:(NSURL *)url
{
	NSString *prefix = [[[url lastPathComponent] stringByDeletingPathExtension] stringByAppendingString:@".unreadable-"];
	NSMutableArray *found = [NSMutableArray array];
	for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL]) {
		if ([name hasPrefix:prefix] && [name hasSuffix:@".plist"]) [found addObject:[self.directory stringByAppendingPathComponent:name]];
	}
	return found;
}

- (void)testReplaceItemsMovesUnreadableFileAside
{
	NSURL *url = [self urlNamed:@"History.plist"];
	NSData *garbage = [@"garbage, not a plist" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertTrue([garbage writeToURL:url atomically:YES]);
	SPPostgresQueryStore *store = [[SPPostgresQueryStore alloc] initWithFileURL:url];
	XCTAssertNotNil(store.lastLoadError);

	__block NSUInteger posted = 0;
	id token = [[NSNotificationCenter defaultCenter] addObserverForName:SPPostgresQueryStoreDidChangeNotification object:store queue:nil usingBlock:^(NSNotification *note) { posted++; }];

	NSError *error = nil;
	XCTAssertTrue([store replaceItems:@[@"SELECT 9"] error:&error], @"%@", error);
	XCTAssertEqual(posted, 1u);
	XCTAssertEqualObjects(store.items, @[@"SELECT 9"]);
	XCTAssertNil(store.lastLoadError);
	NSArray *aside = [self asideFilesFor:url];
	XCTAssertEqual([aside count], 1u, @"moved aside, never deleted");
	XCTAssertEqualObjects([NSData dataWithContentsOfFile:aside[0]], garbage);
	NSString *name = [aside[0] lastPathComponent];
	XCTAssertTrue(SPMatchesAsideName(name), @"%@", name);

	// A newer build's file is moved aside the same way (a second one gets its own name)
	XCTAssertTrue(([@{@"version": @7, @"items": @[@"x"]} writeToURL:url atomically:YES]));
	XCTAssertTrue([store replaceItems:@[] error:&error], @"%@", error);
	XCTAssertEqualObjects(store.items, @[]);
	XCTAssertEqual([[self asideFilesFor:url] count], 2u);

	// A readable file is simply replaced (nothing moved aside)
	XCTAssertTrue([store replaceItems:@[@"SELECT 1"] error:&error], @"%@", error);
	XCTAssertEqual([[self asideFilesFor:url] count], 2u);
	XCTAssertEqualObjects([[SPPostgresQueryStore alloc] initWithFileURL:url].items, @[@"SELECT 1"]);
	[[NSNotificationCenter defaultCenter] removeObserver:token];
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
