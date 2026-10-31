#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFavoritesStore.h"
#import "../Source/Postgres/SPPostgresFavoritePlacementsStore.h"

@interface SPPostgresFavoritePlacementsStoreTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, strong) NSURL *fileURL;
@end

@implementation SPPostgresFavoritePlacementsStoreTests

- (void)setUp
{
	NSString *name = [@"SPPGPlacementTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
	self.fileURL = [self.dir URLByAppendingPathComponent:@"PostgresFavoritePlacements.plist"];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
}

- (void)testMissingFileHasNoPlacements
{
	SPPostgresFavoritePlacementsStore *store = [[SPPostgresFavoritePlacementsStore alloc] initWithFileURL:self.fileURL];
	XCTAssertEqualObjects([store placements], @{});
}

- (void)testRoundTrip
{
	NSDictionary *rec1 = @{
		@"Group": @[@{@"Name": @"Work", @"Nth": @0}, @{@"Name": @"Prod", @"Nth": @1}],
		@"After": @{@"FavoriteID": @7},
		@"Index": @2,
		@"Order": @0,
	};
	NSDictionary *rec2 = @{@"Group": @[], @"Index": @0, @"Order": @1};
	NSDictionary *all = @{@"A": rec1, @"B": rec2};

	SPPostgresFavoritePlacementsStore *store = [[SPPostgresFavoritePlacementsStore alloc] initWithFileURL:self.fileURL];
	NSError *error = nil;
	XCTAssertTrue([store setPlacements:all error:&error], @"%@", error);

	SPPostgresFavoritePlacementsStore *reloaded = [[SPPostgresFavoritePlacementsStore alloc] initWithFileURL:self.fileURL];
	XCTAssertEqualObjects([reloaded placements], all);
	XCTAssertNil([[[reloaded placements] objectForKey:@"B"] objectForKey:@"After"]);
}

- (void)testWritePostsNotification
{
	SPPostgresFavoritePlacementsStore *store = [[SPPostgresFavoritePlacementsStore alloc] initWithFileURL:self.fileURL];
	XCTNSNotificationExpectation *expectation = [[XCTNSNotificationExpectation alloc]
		initWithName:SPPostgresFavoritePlacementsDidChangeNotification object:store];
	XCTAssertTrue([store setPlacements:@{} error:NULL]);
	[self waitForExpectations:@[expectation] timeout:2];
}

- (void)testNewerVersionIsNotOverwritten
{
	NSDictionary *future = @{@"Version": @2, @"Placements": @{}};
	XCTAssertTrue([future writeToURL:self.fileURL error:NULL]);
	NSData *before = [NSData dataWithContentsOfURL:self.fileURL];

	SPPostgresFavoritePlacementsStore *store = [[SPPostgresFavoritePlacementsStore alloc] initWithFileURL:self.fileURL];
	XCTAssertEqualObjects([store placements], @{});
	NSError *error = nil;
	XCTAssertFalse([store setPlacements:@{@"A": @{@"Group": @[]}} error:&error]);
	XCTAssertNotNil(error);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.fileURL], before);
}

- (void)testBesideFavoritesStore
{
	NSURL *favURL = [self.dir URLByAppendingPathComponent:@"PostgresFavorites.plist"];
	SPPostgresFavoritesStore *favs = [[SPPostgresFavoritesStore alloc] initWithFileURL:favURL];
	SPPostgresFavoritePlacementsStore *store = [SPPostgresFavoritePlacementsStore storeBesideFavoritesStore:favs];
	XCTAssertTrue([store setPlacements:@{@"A": @{@"Group": @[]}} error:NULL]);
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[[self.dir URLByAppendingPathComponent:@"PostgresFavoritePlacements.plist"] path]]);
}

@end
