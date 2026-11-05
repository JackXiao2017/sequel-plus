#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoriteNode.h"
#import "../Source/Postgres/SPPostgresFavoritesLayout.h"

// SPTreeNode / SPGroupNode / SPFavoriteNode are app classes without exported symbols: look them up at run time
@interface NSObject (SPPGLayoutTestsMySQLNodes)
+ (id)groupNodeWithName:(NSString *)name;
+ (id)favoriteNodeWithDictionary:(NSMutableDictionary *)dictionary;
- (void)setNodeName:(NSString *)name;
- (BOOL)isGroup;
@end

@interface SPPostgresFavoritesLayoutTests : XCTestCase
@property (nonatomic, strong) NSTreeNode *pgRoot;
@property (nonatomic, strong) NSTreeNode *holder;
@end

@implementation SPPostgresFavoritesLayoutTests

- (void)setUp
{
	Class treeNodeClass = NSClassFromString(@"SPTreeNode");
	self.pgRoot = [treeNodeClass treeNodeWithRepresentedObject:nil];
	self.holder = [treeNodeClass treeNodeWithRepresentedObject:nil];
	[[self.pgRoot mutableChildNodes] addObject:self.holder];
}

#pragma mark - Fixtures

- (id)groupNamed:(NSString *)name children:(NSArray *)children
{
	id group = [NSClassFromString(@"SPGroupNode") groupNodeWithName:name];
	NSTreeNode *node = [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:group];
	XCTAssertTrue([(id)node isGroup]);
	[[node mutableChildNodes] addObjectsFromArray:children];
	return node;
}

- (id)section:(NSArray *)children
{
	return [self groupNamed:@"FAVORITES" children:children];
}

- (id)mysqlFavorite:(NSInteger)favoriteID
{
	NSMutableDictionary *dict = [@{ @"id": @(favoriteID), @"name": [NSString stringWithFormat:@"m%ld", (long)favoriteID], @"host": @"mysqlhost", @"type": @0 } mutableCopy];
	id favorite = [NSClassFromString(@"SPFavoriteNode") favoriteNodeWithDictionary:dict];
	return [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:favorite];
}

- (id)pg:(NSString *)name
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	[favorite setFavoriteID:[@"pg-" stringByAppendingString:name]];
	[favorite setName:name];
	SPPostgresFavoriteNode *represented = [[SPPostgresFavoriteNode alloc] init];
	[represented setFavorite:favorite];
	NSTreeNode *node = [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:represented];
	[[self.holder mutableChildNodes] addObject:node];
	return node;
}

- (NSString *)pgID:(NSTreeNode *)node
{
	return [[(SPPostgresFavoriteNode *)[node representedObject] favorite] favoriteID];
}

- (SPPostgresFavoritesLayout *)resolve:(id)section nodes:(NSArray *)nodes placements:(NSDictionary *)placements
{
	SPPostgresFavoritesLayout *layout = [[SPPostgresFavoritesLayout alloc] init];
	[layout resolveWithMySQLSection:section postgresNodes:nodes placements:placements];
	return layout;
}

#pragma mark - Resolve

- (void)testNoPlacementsAppendsAtTopLevelEndInGivenOrder
{
	id m1 = [self mysqlFavorite:1];
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:2]]];
	id section = [self section:@[m1, g]];
	id pa = [self pg:@"a"], pb = [self pg:@"b"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[pa, pb] placements:@{}];
	NSArray *expected = @[m1, g, pa, pb];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:g], [g childNodes]);
	XCTAssertEqual([layout displayedParentOfNode:pa], section);
	XCTAssertEqual([layout displayedParentOfNode:g], section);
	XCTAssertTrue([layout hasPostgresNodes]);
}

- (void)testAfterFavoriteInNestedGroup
{
	id h1 = [self mysqlFavorite:21], h2 = [self mysqlFavorite:22], h3 = [self mysqlFavorite:23];
	id h = [self groupNamed:@"H" children:@[h1, h2, h3]];
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:11], h]];
	id section = [self section:@[g]];
	id p = [self pg:@"p"];

	NSDictionary *placements = @{ [self pgID:p]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}, @{@"Name": @"H", @"Nth": @0}],
	                                                @"After": @{@"FavoriteID": @22}, @"Index": @0, @"Order": @0 } };
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:placements];
	NSArray *expected = @[h1, h2, p, h3];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:h], expected);
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], [section childNodes]);
	XCTAssertEqual([layout displayedParentOfNode:p], h);
}

- (void)testAfterAbsentIsFirst
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id section = [self section:@[m1, m2]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"Index": @2, @"Order": @0 } }];
	NSArray *expected = @[p, m1, m2];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
}

- (void)testAfterGroupAnchor
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id g = [self groupNamed:@"G" children:@[]];
	id section = [self section:@[m1, g, m2]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"GroupName": @"G", @"Nth": @0}, @"Index": @0, @"Order": @0 } }];
	NSArray *expected = @[m1, g, p, m2];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
}

- (void)testSameNameGroupsUseNth
{
	id x1 = [self groupNamed:@"X" children:@[[self mysqlFavorite:1]]];
	id x2 = [self groupNamed:@"X" children:@[[self mysqlFavorite:2]]];
	id section = [self section:@[x1, x2]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[@{@"Name": @"X", @"Nth": @1}], @"After": @{@"FavoriteID": @2}, @"Index": @1, @"Order": @0 } }];
	XCTAssertEqual([layout displayedParentOfNode:p], x2);
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:x1], [x1 childNodes]);
	XCTAssertEqual([[layout displayedChildrenOfGroup:x2] lastObject], p);
}

- (void)testMissingAnchorFallsBackToIndex
{
	id a = [self mysqlFavorite:1], b = [self mysqlFavorite:2], c = [self mysqlFavorite:3];
	id section = [self section:@[a, b, c]];
	id p = [self pg:@"p"];

	// Index counted the anchor itself: with it gone, before the MySQL child at min(max(Index - 1, 0), count)
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @99}, @"Index": @2, @"Order": @0 } }];
	NSArray *expected = @[a, p, b, c];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);

	layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"GroupName": @"Gone", @"Nth": @0}, @"Index": @1, @"Order": @0 } }];
	expected = @[p, a, b, c];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);

	layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @99}, @"Index": @0, @"Order": @0 } }];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);

	layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @99}, @"Index": @10, @"Order": @0 } }];
	expected = @[a, b, c, p];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
}

/// An After naming nothing (a MySQL favorite without an id was the anchor) keeps Index as the slot: the
/// anchor may still be there, Index - 1 would put it before it.
- (void)testEmptyAfterUsesIndex
{
	id a = [self mysqlFavorite:1], b = [self mysqlFavorite:2], c = [self mysqlFavorite:3];
	id section = [self section:@[a, b, c]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{}, @"Index": @1, @"Order": @0 } }];
	NSArray *expected = @[a, p, b, c];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
}

/// The MySQL favorite a Postgres favorite followed was deleted: it stays between the neighbours.
- (void)testDeletedAnchorKeepsPlaceBetweenNeighbours
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2], m3 = [self mysqlFavorite:3];
	id section = [self section:@[m1, m2, m3]];
	id p = [self pg:@"p"];
	NSDictionary *placements = @{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @2}, @"Index": @2, @"Order": @0 } };

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:placements];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], (@[m1, m2, p, m3]));
	[[section mutableChildNodes] removeObject:m2];

	NSArray *expected = @[m1, p, m3];
	SPPostgresFavoritesLayout *fromFile = [self resolve:section nodes:@[p] placements:placements];
	XCTAssertEqualObjects([fromFile displayedChildrenOfGroup:section], expected);
}

- (void)testMissingGroupFallsBackToTopLevelEnd
{
	id m1 = [self mysqlFavorite:1];
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:2]]];
	id section = [self section:@[m1, g]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[@{@"Name": @"Gone", @"Nth": @0}], @"Index": @0, @"Order": @0 } }];
	NSArray *expected = @[m1, g, p];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
	XCTAssertEqual([layout displayedParentOfNode:p], section);
}

- (void)testMalformedPlacementsAreTolerated
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id section = [self section:@[m1, m2]];
	id p1 = [self pg:@"p1"], p2 = [self pg:@"p2"], p3 = [self pg:@"p3"], p4 = [self pg:@"p4"], p5 = [self pg:@"p5"];

	NSDictionary *placements = @{
		[self pgID:p1]: @"not a record",
		[self pgID:p2]: @{ @"Group": @"not an array", @"After": @7, @"Index": @"x", @"Order": @[] },
		[self pgID:p3]: @{ @"Group": @[@"not a step", @{@"Name": @5}], @"Order": @0 },
		[self pgID:p4]: @{ @"Group": @[], @"After": @{@"FavoriteID": @"1"}, @"Index": @-3, @"Order": @"y" },
		[self pgID:p5]: @{ @"Group": @[], @"After": @{@"GroupName": @[], @"Nth": @"z"} },
	};
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p1, p2, p3, p4, p5] placements:placements];
	NSArray *displayed = [layout displayedChildrenOfGroup:section];
	XCTAssertEqual([displayed count], 7u);
	for (id p in @[p1, p2, p3, p4, p5]) XCTAssertEqual([layout displayedParentOfNode:p], section);
	XCTAssertEqualObjects([section childNodes], (@[m1, m2]));
}

- (void)testOrderThenNameWithinSlot
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id section = [self section:@[m1, m2]];
	id pb = [self pg:@"b"], pz = [self pg:@"Z"], pa = [self pg:@"a"];

	NSDictionary *(^after1)(NSInteger) = ^(NSInteger order) {
		return @{ @"Group": @[], @"After": @{@"FavoriteID": @1}, @"Index": @1, @"Order": @(order) };
	};
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[pb, pz, pa]
	                                       placements:@{ [self pgID:pb]: after1(1), [self pgID:pz]: after1(0), [self pgID:pa]: after1(0) }];
	NSArray *expected = @[m1, pa, pz, pb, m2];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
}

- (void)testMySQLChildrenNeverChange
{
	id h = [self groupNamed:@"H" children:@[[self mysqlFavorite:21], [self mysqlFavorite:22]]];
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:11], h]];
	id section = [self section:@[[self mysqlFavorite:1], g]];
	NSArray *before = @[[[section childNodes] copy], [[g childNodes] copy], [[h childNodes] copy]];
	id p1 = [self pg:@"p1"], p2 = [self pg:@"p2"], p3 = [self pg:@"p3"];

	NSDictionary *placements = @{
		[self pgID:p1]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}, @{@"Name": @"H", @"Nth": @0}], @"After": @{@"FavoriteID": @21}, @"Index": @1, @"Order": @0 },
		[self pgID:p2]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"Index": @0, @"Order": @0 },
	};
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p1, p2, p3] placements:placements];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:h], (@[[h childNodes][0], p1, [h childNodes][1]]));
	XCTAssertEqual([[layout displayedChildrenOfGroup:g] firstObject], p2);
	XCTAssertEqual([[layout displayedChildrenOfGroup:section] lastObject], p3);
	NSArray *after = @[[section childNodes], [g childNodes], [h childNodes]];
	XCTAssertEqualObjects(after, before);
	for (NSTreeNode *p in @[p1, p2, p3]) {
		XCTAssertEqual([p parentNode], self.holder);
		XCTAssertNotNil([[p parentNode] parentNode]);
	}
}

@end
