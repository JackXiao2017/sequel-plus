#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoriteNode.h"
#import "../Source/Postgres/SPPostgresFavoritesImport.h"

// SPTreeNode / SPGroupNode / SPFavoriteNode are app classes without exported symbols: look them up at run time
@interface NSObject (SPPGImportTestsMySQLNodes)
+ (id)groupNodeWithName:(NSString *)name;
+ (id)favoriteNodeWithDictionary:(NSMutableDictionary *)dictionary;
- (NSString *)nodeName;
- (NSDictionary *)dictionaryRepresentation;
@end

/// The one-time import of the RC builds' PostgresFavorites.plist (and placements) into the favorites tree. Every
/// test uses its own temporary data folder and an in-memory tree; "saving" only counts.
@interface SPPostgresFavoritesImportTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, assign) NSUInteger saves;
@property (nonatomic, assign) BOOL saveResult;
@end

@implementation SPPostgresFavoritesImportTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	NSString *name = [@"SPPGImportTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
	self.saves = 0;
	self.saveResult = YES;
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
}

#pragma mark - Fixtures

- (id)group:(NSString *)name children:(NSArray *)children
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

/// FAVORITES: m1, G (m2, Sub (m3)), m4
- (id)sectionWithGroup:(id *)groupOut subgroup:(id *)subOut
{
	id sub = [self group:@"Sub" children:@[[self mysqlFavorite:3]]];
	id g = [self group:@"G" children:@[[self mysqlFavorite:2], sub]];
	id section = [self group:@"FAVORITES" children:@[[self mysqlFavorite:1], g, [self mysqlFavorite:4]]];
	if (groupOut) *groupOut = g;
	if (subOut) *subOut = sub;
	return section;
}

- (NSDictionary *)legacyFavorite:(NSString *)name
{
	return @{ @"id": [@"pg-" stringByAppendingString:name], @"name": name, @"host": @"pghost", @"port": @5433, @"type": @0,
	          @"user": @"alice", @"database": @"appdb", @"colorIndex": @2, @"sshPort": @0, @"useSSL": @NO };
}

- (NSURL *)favoritesURL { return [self.dir URLByAppendingPathComponent:SPPostgresLegacyFavoritesFileName]; }
- (NSURL *)placementsURL { return [self.dir URLByAppendingPathComponent:SPPostgresLegacyPlacementsFileName]; }

- (void)writeLegacyFavorites:(NSArray *)favorites placements:(NSDictionary *)placements
{
	NSDictionary *favoritesRoot = @{ @"version": @1, @"favorites": favorites };
	XCTAssertTrue([favoritesRoot writeToURL:[self favoritesURL] atomically:YES]);
	if (placements) {
		NSDictionary *placementsRoot = @{ @"Version": @1, @"Placements": placements };
		XCTAssertTrue([placementsRoot writeToURL:[self placementsURL] atomically:YES]);
	}
}

- (BOOL)importInto:(id)section count:(NSUInteger *)count error:(NSError **)error
{
	__weak SPPostgresFavoritesImportTests *weakSelf = self;
	return [SPPostgresFavoritesImport importFavoritesInDataFolder:self.dir intoSection:section save:^BOOL{
		weakSelf.saves++;
		return weakSelf.saveResult;
	} importedCount:count error:error];
}

- (NSArray *)namesIn:(NSArray *)nodes
{
	NSMutableArray *names = [NSMutableArray array];
	for (NSTreeNode *node in nodes) [names addObject:[[node representedObject] nodeName] ?: @"?"];
	return names;
}

- (BOOL)exists:(NSURL *)url
{
	return [[NSFileManager defaultManager] fileExistsAtPath:[url path]];
}

- (NSURL *)importedURL:(NSURL *)url
{
	return [NSURL fileURLWithPath:[[url path] stringByAppendingString:SPPostgresLegacyImportedSuffix]];
}

#pragma mark - Tests

/// Each favorite goes where the RC builds displayed it: placed ones in their group after their anchor, the
/// others at the end of the top level by name. Then the files are kept as .imported backups.
- (void)testFavoritesGoWhereTheyWereDisplayed
{
	id g = nil, sub = nil;
	id section = [self sectionWithGroup:&g subgroup:&sub];
	[self writeLegacyFavorites:@[[self legacyFavorite:@"q"], [self legacyFavorite:@"p"], [self legacyFavorite:@"r"], [self legacyFavorite:@"b"], [self legacyFavorite:@"a"]]
	                placements:@{
		@"pg-p": @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"After": @{@"FavoriteID": @2}, @"Index": @1, @"Order": @0 },
		@"pg-r": @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}, @{@"Name": @"Sub", @"Nth": @0}], @"Index": @0, @"Order": @0 },
		@"pg-q": @{ @"Group": @[], @"After": @{@"FavoriteID": @1}, @"Index": @1, @"Order": @0 },
	}];
	NSData *favoritesData = [NSData dataWithContentsOfURL:[self favoritesURL]];
	NSData *placementsData = [NSData dataWithContentsOfURL:[self placementsURL]];

	NSUInteger count = 0;
	NSError *error = nil;
	XCTAssertTrue([self importInto:section count:&count error:&error], @"%@", error);
	XCTAssertEqual(count, 5u);
	XCTAssertEqual(self.saves, 1u);

	XCTAssertEqualObjects([self namesIn:[section childNodes]], (@[@"m1", @"q", @"G", @"m4", @"a", @"b"]));
	XCTAssertEqualObjects([self namesIn:[g childNodes]], (@[@"m2", @"p", @"Sub"]));
	XCTAssertEqualObjects([self namesIn:[sub childNodes]], (@[@"r", @"m3"]));

	// Real tree leaves, with every field
	NSTreeNode *p = [g childNodes][1];
	XCTAssertEqual([p parentNode], g);
	SPPostgresFavorite *favorite = SPPostgresFavoriteForNode(p);
	XCTAssertEqualObjects(favorite.favoriteID, @"pg-p");
	XCTAssertEqualObjects(favorite.host, @"pghost");
	XCTAssertEqual(favorite.port, 5433u);
	XCTAssertEqualObjects(favorite.user, @"alice");
	XCTAssertEqual(favorite.colorIndex, 2);

	// The files are kept, renamed, as they were
	XCTAssertFalse([self exists:[self favoritesURL]]);
	XCTAssertFalse([self exists:[self placementsURL]]);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self importedURL:[self favoritesURL]]], favoritesData);
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self importedURL:[self placementsURL]]], placementsData);

	// Nothing left to import
	XCTAssertTrue([self importInto:section count:&count error:&error], @"%@", error);
	XCTAssertEqual(count, 0u);
	XCTAssertEqual(self.saves, 1u);
}

/// A favorite whose ID is already in the tree (an earlier import whose rename failed) is not added again.
- (void)testImportIsIdempotent
{
	id g = nil;
	id section = [self sectionWithGroup:&g subgroup:NULL];
	[self writeLegacyFavorites:@[[self legacyFavorite:@"p"]] placements:@{ @"pg-p": @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"Index": @0, @"Order": @0 } }];
	XCTAssertTrue([self importInto:section count:NULL error:NULL]);
	XCTAssertEqualObjects([self namesIn:[g childNodes]], (@[@"p", @"m2", @"Sub"]));

	// The same file again (and a new favorite in it)
	XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:[self importedURL:[self favoritesURL]] error:NULL]);
	[self writeLegacyFavorites:@[[self legacyFavorite:@"p"], [self legacyFavorite:@"s"]] placements:nil];
	NSUInteger count = 0;
	NSError *error = nil;
	XCTAssertTrue([self importInto:section count:&count error:&error], @"%@", error);
	XCTAssertEqual(count, 1u, @"only the new one");
	XCTAssertEqualObjects([self namesIn:[g childNodes]], (@[@"p", @"m2", @"Sub"]), @"p not added twice");
	XCTAssertEqualObjects([self namesIn:@[[section childNodes].lastObject]], @[@"s"]);

	// Only favorites already in the tree: nothing saved, the file is still retired (with a fresh backup name)
	[self writeLegacyFavorites:@[[self legacyFavorite:@"p"], [self legacyFavorite:@"s"]] placements:nil];
	NSUInteger saves = self.saves;
	XCTAssertTrue([self importInto:section count:&count error:&error], @"%@", error);
	XCTAssertEqual(count, 0u);
	XCTAssertEqual(self.saves, saves, @"nothing to save");
	XCTAssertFalse([self exists:[self favoritesURL]]);
	XCTAssertTrue([self exists:[NSURL fileURLWithPath:[[[self importedURL:[self favoritesURL]] path] stringByAppendingString:@"-2"]]], @"an older backup is never replaced");
}

/// An unreadable, malformed or newer file is reported and left as it is; the tree doesn't change.
- (void)testUnreadableFileIsKeptAndReported
{
	NSArray *badFiles = @[
		[@"this is not a plist" dataUsingEncoding:NSUTF8StringEncoding],
		[NSPropertyListSerialization dataWithPropertyList:@{ @"version": @"x", @"favorites": @{} } format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],
		[NSPropertyListSerialization dataWithPropertyList:@{ @"version": @2, @"favorites": @[[self legacyFavorite:@"p"]] } format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],
	];
	for (NSData *bad in badFiles) {
		id section = [self sectionWithGroup:NULL subgroup:NULL];
		NSArray *before = [[section childNodes] copy];
		XCTAssertTrue([bad writeToURL:[self favoritesURL] atomically:YES]);

		NSError *error = nil;
		XCTAssertFalse([self importInto:section count:NULL error:&error]);
		XCTAssertNotNil(error);
		XCTAssertTrue([[error localizedDescription] containsString:[[self favoritesURL] path]], @"%@", error);
		XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self favoritesURL]], bad, @"left untouched");
		XCTAssertFalse([self exists:[self importedURL:[self favoritesURL]]]);
		XCTAssertEqualObjects([section childNodes], before);
		XCTAssertEqual(self.saves, 0u);
	}
}

/// The tree couldn't be saved: the files stay for the next launch (the favorites are in the tree, so whatever saves
/// it next writes them, and the next import skips them).
- (void)testFailedSaveKeepsTheFiles
{
	id section = [self sectionWithGroup:NULL subgroup:NULL];
	[self writeLegacyFavorites:@[[self legacyFavorite:@"p"]] placements:@{}];
	self.saveResult = NO;
	NSError *error = nil;
	XCTAssertFalse([self importInto:section count:NULL error:&error]);
	XCTAssertNotNil(error);
	XCTAssertTrue([self exists:[self favoritesURL]]);
	XCTAssertTrue([self exists:[self placementsURL]]);

	self.saveResult = YES;
	NSUInteger count = 0;
	XCTAssertTrue([self importInto:section count:&count error:&error], @"%@", error);
	XCTAssertEqual(count, 0u);
	XCTAssertFalse([self exists:[self favoritesURL]]);
}

/// Without placements (or with an unreadable placements file) every favorite goes to the end of the top level, by
/// name, as the RC builds showed them; a placements file alone is retired too.
- (void)testUnreadablePlacementsPutFavoritesAtTheEnd
{
	id section = [self sectionWithGroup:NULL subgroup:NULL];
	[self writeLegacyFavorites:@[[self legacyFavorite:@"b"], [self legacyFavorite:@"A"]] placements:nil];
	XCTAssertTrue([[@"garbage" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[self placementsURL] atomically:YES]);
	NSError *error = nil;
	XCTAssertTrue([self importInto:section count:NULL error:&error], @"%@", error);
	XCTAssertEqualObjects([self namesIn:[section childNodes]], (@[@"m1", @"G", @"m4", @"A", @"b"]));
	XCTAssertFalse([self exists:[self placementsURL]]);

	// Only a placements file
	NSDictionary *emptyPlacements = @{ @"Version": @1, @"Placements": @{} };
	XCTAssertTrue([emptyPlacements writeToURL:[self placementsURL] atomically:YES]);
	XCTAssertTrue([self importInto:section count:NULL error:&error], @"%@", error);
	XCTAssertFalse([self exists:[self placementsURL]]);
	XCTAssertEqual(self.saves, 1u);
}

- (void)testNothingToImport
{
	id section = [self sectionWithGroup:NULL subgroup:NULL];
	NSError *error = nil;
	XCTAssertTrue([self importInto:section count:NULL error:&error]);
	XCTAssertNil(error);
	XCTAssertEqual(self.saves, 0u);
	XCTAssertEqual([[section childNodes] count], 3u);
	NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self.dir path] error:NULL];
	XCTAssertEqual([contents count], 0u, @"no file created");
}

/// What gets saved: the imported favorites as PostgreSQL favorite dictionaries in the tree's Favorites.plist
/// representation, with their UUID and the engine key and no MySQL "id"; the MySQL favorites as they were.
- (void)testImportedTreeRepresentation
{
	id section = [self sectionWithGroup:NULL subgroup:NULL];
	NSDictionary *mysqlBefore = [[section childNodes][0] dictionaryRepresentation];
	[self writeLegacyFavorites:@[[self legacyFavorite:@"p"]] placements:@{ @"pg-p": @{ @"Group": @[], @"Index": @0, @"Order": @0 } }];
	XCTAssertTrue([self importInto:section count:NULL error:NULL]);

	NSArray *children = [[section dictionaryRepresentation] objectForKey:@"Children"];
	XCTAssertEqual([children count], 4u);
	NSDictionary *p = children[0];
	XCTAssertEqualObjects(p[SPFavoriteEngineKey], SPFavoriteEnginePostgreSQL);
	XCTAssertEqualObjects(p[SPPostgresFavoriteUUIDKey], @"pg-p");
	XCTAssertNil(p[@"id"], @"no MySQL id");
	XCTAssertEqualObjects(p[@"name"], @"p");
	XCTAssertEqualObjects(p[@"host"], @"pghost");
	XCTAssertEqualObjects(children[1], mysqlBefore);
}

@end
