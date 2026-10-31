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

/// Every displayed array of `group` and its subgroups, keyed by the group's path of names.
- (NSDictionary *)displayedArraysOf:(SPPostgresFavoritesLayout *)layout group:(NSTreeNode *)group path:(NSString *)path
{
	NSMutableDictionary *all = [NSMutableDictionary dictionary];
	NSArray *children = [layout displayedChildrenOfGroup:(id)group];
	[all setObject:children forKey:path];
	for (NSTreeNode *child in children) {
		if (![[child representedObject] isKindOfClass:[SPPostgresFavoriteNode class]] && [(id)child isGroup]) {
			[all addEntriesFromDictionary:[self displayedArraysOf:layout group:child path:[path stringByAppendingFormat:@"/%@", [[child representedObject] nodeName]]]];
		}
	}
	return all;
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

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @99}, @"Index": @1, @"Order": @0 } }];
	NSArray *expected = @[a, p, b, c];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);

	layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @99}, @"Index": @10, @"Order": @0 } }];
	expected = @[a, b, c, p];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
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
	XCTAssertEqual([[layout placements] count], 5u);
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
	XCTAssertEqual([[layout postgresNodesWithinGroup:section] count], 3u);
	NSArray *after = @[[section childNodes], [g childNodes], [h childNodes]];
	XCTAssertEqualObjects(after, before);
	for (NSTreeNode *p in @[p1, p2, p3]) {
		XCTAssertEqual([p parentNode], self.holder);
		XCTAssertNotNil([[p parentNode] parentNode]);
	}
}

#pragma mark - Snapshot

- (void)assertSnapshotRoundTripsForSection:(id)section nodes:(NSArray *)nodes placements:(NSDictionary *)placements
{
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:nodes placements:placements];
	NSDictionary *first = [self displayedArraysOf:layout group:section path:@""];
	NSDictionary *snapshot = [layout placements];
	XCTAssertEqual([snapshot count], [nodes count]);

	SPPostgresFavoritesLayout *again = [self resolve:section nodes:nodes placements:snapshot];
	XCTAssertEqualObjects([self displayedArraysOf:again group:section path:@""], first);
	XCTAssertEqualObjects([again placements], snapshot);
}

- (void)testSnapshotRoundTrips
{
	// Nested
	id h = [self groupNamed:@"H" children:@[[self mysqlFavorite:21], [self mysqlFavorite:22], [self mysqlFavorite:23]]];
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:11], h]];
	id section = [self section:@[[self mysqlFavorite:1], g, [self mysqlFavorite:2]]];
	id p1 = [self pg:@"p1"], p2 = [self pg:@"p2"], p3 = [self pg:@"p3"], p4 = [self pg:@"p4"];
	[self assertSnapshotRoundTripsForSection:section nodes:@[p1, p2, p3, p4] placements:@{
		[self pgID:p1]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}, @{@"Name": @"H", @"Nth": @0}], @"After": @{@"FavoriteID": @22}, @"Index": @2, @"Order": @0 },
		[self pgID:p2]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"After": @{@"GroupName": @"H", @"Nth": @0}, @"Index": @2, @"Order": @0 },
		[self pgID:p3]: @{ @"Group": @[], @"Index": @0, @"Order": @0 },
	}];

	// Missing anchor
	id a = [self mysqlFavorite:31], b = [self mysqlFavorite:32], c = [self mysqlFavorite:33];
	id section2 = [self section:@[a, b, c]];
	id q = [self pg:@"q"];
	[self assertSnapshotRoundTripsForSection:section2 nodes:@[q] placements:@{
		[self pgID:q]: @{ @"Group": @[], @"After": @{@"FavoriteID": @99}, @"Index": @1, @"Order": @0 },
	}];

	// Two in one slot, plus same-name groups
	id x1 = [self groupNamed:@"X" children:@[]], x2 = [self groupNamed:@"X" children:@[[self mysqlFavorite:41]]];
	id section3 = [self section:@[x1, x2, [self mysqlFavorite:42]]];
	id r1 = [self pg:@"r1"], r2 = [self pg:@"r2"], r3 = [self pg:@"r3"];
	[self assertSnapshotRoundTripsForSection:section3 nodes:@[r1, r2, r3] placements:@{
		[self pgID:r1]: @{ @"Group": @[], @"After": @{@"GroupName": @"X", @"Nth": @1}, @"Index": @2, @"Order": @1 },
		[self pgID:r2]: @{ @"Group": @[], @"After": @{@"GroupName": @"X", @"Nth": @1}, @"Index": @2, @"Order": @0 },
		[self pgID:r3]: @{ @"Group": @[@{@"Name": @"X", @"Nth": @1}], @"Index": @0, @"Order": @0 },
	}];
}

- (void)testSnapshotSkipsRemovedAnchor
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2], m3 = [self mysqlFavorite:3];
	id section = [self section:@[m1, m2, m3]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"After": @{@"FavoriteID": @2}, @"Index": @2, @"Order": @0 } }];
	[[section mutableChildNodes] removeObject:m2];

	NSDictionary *record = [[layout placements] objectForKey:[self pgID:p]];
	XCTAssertEqualObjects([record objectForKey:@"Group"], @[]);
	XCTAssertEqualObjects([record objectForKey:@"After"], @{@"FavoriteID": @1});
	XCTAssertEqualObjects([record objectForKey:@"Index"], @1);
	XCTAssertEqualObjects([record objectForKey:@"Order"], @0);
}

- (void)testSnapshotFollowsRenamedGroup
{
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:1]]];
	id section = [self section:@[g]];
	id p = [self pg:@"p"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"Index": @0, @"Order": @0 } }];
	[[g representedObject] setNodeName:@"G2"];

	NSDictionary *record = [[layout placements] objectForKey:[self pgID:p]];
	XCTAssertEqualObjects([record objectForKey:@"Group"], (@[@{@"Name": @"G2", @"Nth": @0}]));
	XCTAssertNil([record objectForKey:@"After"]);
	XCTAssertEqualObjects([record objectForKey:@"Index"], @0);
}

#pragma mark - Changes

- (void)testMovePostgresBetweenMySQLFavorites
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id section = [self section:@[m1, m2]];
	id p = [self pg:@"p"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{}];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], (@[m1, m2, p]));

	[layout moveNodes:@[p] toGroup:section displayedIndex:1];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], (@[m1, p, m2]));
	XCTAssertEqualObjects([section childNodes], (@[m1, m2]));
	XCTAssertEqualObjects([[[layout placements] objectForKey:[self pgID:p]] objectForKey:@"After"], @{@"FavoriteID": @1});
	XCTAssertEqual([p parentNode], self.holder);
}

- (void)testMovePostgresIntoGroup
{
	id g1 = [self mysqlFavorite:11];
	id g = [self groupNamed:@"G" children:@[g1]];
	id section = [self section:@[[self mysqlFavorite:1], g]];
	id p = [self pg:@"p"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{}];

	[layout moveNodes:@[p] toGroup:g displayedIndex:0];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:g], (@[p, g1]));
	XCTAssertEqual([layout displayedParentOfNode:p], g);
	// The section no longer holds Postgres nodes: it shows its live childNodes again
	XCTAssertEqual([layout displayedChildrenOfGroup:section], [section childNodes]);
	XCTAssertEqualObjects([g childNodes], @[g1]);

	NSDictionary *record = [[layout placements] objectForKey:[self pgID:p]];
	XCTAssertEqualObjects([record objectForKey:@"Group"], (@[@{@"Name": @"G", @"Nth": @0}]));
	XCTAssertNil([record objectForKey:@"After"]);
}

- (void)testMoveMySQLAcrossDisplayedPostgres
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id section = [self section:@[m1, m2]];
	id p = [self pg:@"p"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[], @"Index": @0, @"Order": @0 } }];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], (@[p, m1, m2]));

	[layout moveNodes:@[m2] toGroup:section displayedIndex:0];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], (@[m2, p, m1]));
	XCTAssertEqualObjects([section childNodes], (@[m2, m1]));
	XCTAssertEqual([m2 parentNode], section);
}

- (void)testMoveMixedSelection
{
	id m1 = [self mysqlFavorite:1];
	id g1 = [self mysqlFavorite:11], g2 = [self mysqlFavorite:12];
	id g = [self groupNamed:@"G" children:@[g1, g2]];
	id section = [self section:@[m1, g]];
	id p = [self pg:@"p"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{}];

	[layout moveNodes:@[m1, p] toGroup:g displayedIndex:1];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:g], (@[g1, m1, p, g2]));
	XCTAssertEqualObjects([g childNodes], (@[g1, m1, g2]));
	XCTAssertEqualObjects([section childNodes], @[g]);
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], @[g]);
	XCTAssertEqual([m1 parentNode], g);
	XCTAssertEqual([layout displayedParentOfNode:p], g);

	// Within the same group, an index past a moved node shifts down by one
	[layout moveNodes:@[g1, m1] toGroup:g displayedIndex:3];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:g], (@[p, g1, m1, g2]));
	XCTAssertEqualObjects([g childNodes], (@[g1, m1, g2]));
}

- (void)testMoveGroupCarriesItsPostgresNodes
{
	id g1 = [self mysqlFavorite:11];
	id g = [self groupNamed:@"G" children:@[g1]];
	id h = [self groupNamed:@"H" children:@[[self mysqlFavorite:21]]];
	id section = [self section:@[g, h]];
	id p = [self pg:@"p"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p] placements:@{ [self pgID:p]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"After": @{@"FavoriteID": @11}, @"Index": @1, @"Order": @0 } }];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:g], (@[g1, p]));

	[layout moveNodes:@[g] toGroup:h displayedIndex:0];
	XCTAssertEqualObjects([section childNodes], @[h]);
	XCTAssertEqual([g parentNode], h);
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:g], (@[g1, p]));
	XCTAssertEqual([layout displayedParentOfNode:p], g);
	NSDictionary *record = [[layout placements] objectForKey:[self pgID:p]];
	XCTAssertEqualObjects([record objectForKey:@"Group"], (@[@{@"Name": @"H", @"Nth": @0}, @{@"Name": @"G", @"Nth": @0}]));
}

- (void)testSetDisplayedChildrenSortsTogether
{
	id mb = [self mysqlFavorite:2];
	id section = [self section:@[mb]];
	id pc = [self pg:@"c"], pa = [self pg:@"a"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[pa, pc] placements:@{}];

	NSArray *sorted = @[pa, mb, pc];
	[layout setDisplayedChildren:sorted ofGroup:section];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], sorted);
	XCTAssertEqualObjects([section childNodes], @[mb]);

	SPPostgresFavoritesLayout *again = [self resolve:section nodes:@[pa, pc] placements:[layout placements]];
	XCTAssertEqualObjects([again displayedChildrenOfGroup:section], sorted);
}

- (void)testAppendAndInsertAfter
{
	id m1 = [self mysqlFavorite:1];
	id e = [self groupNamed:@"E" children:@[]];
	id section = [self section:@[m1, e]];
	id p1 = [self pg:@"p1"], p2 = [self pg:@"p2"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p1, p2] placements:@{}];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], (@[m1, e, p1, p2]));

	id appended = [self pg:@"appended"];
	[layout appendPostgresNode:appended toGroup:e];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:e], @[appended]);
	XCTAssertEqual([layout displayedParentOfNode:appended], e);
	XCTAssertEqualObjects([e childNodes], @[]);

	// "zz" sorts after p2 by name, so only its Order can place it between p1 and p2
	id inserted = [self pg:@"zz"];
	[layout insertPostgresNode:inserted afterNode:p1];
	NSArray *expected = @[m1, e, p1, inserted, p2];
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], expected);
	XCTAssertEqual([layout displayedParentOfNode:inserted], section);

	NSDictionary *snapshot = [layout placements];
	XCTAssertEqualObjects([[snapshot objectForKey:[self pgID:inserted]] objectForKey:@"Order"], @1);
	SPPostgresFavoritesLayout *again = [self resolve:section nodes:@[appended, inserted, p1, p2] placements:snapshot];
	XCTAssertEqualObjects([again displayedChildrenOfGroup:section], expected);
	XCTAssertEqualObjects([again displayedChildrenOfGroup:e], @[appended]);
}

- (void)assertNoPostgresNodeUnder:(NSTreeNode *)node
{
	for (NSTreeNode *child in [node childNodes]) {
		XCTAssertFalse([[child representedObject] isKindOfClass:[SPPostgresFavoriteNode class]]);
		[self assertNoPostgresNodeUnder:child];
	}
}

- (void)testNoPostgresNodeEverEntersMySQLTree
{
	id m1 = [self mysqlFavorite:1], m2 = [self mysqlFavorite:2];
	id h = [self groupNamed:@"H" children:@[[self mysqlFavorite:21]]];
	id g = [self groupNamed:@"G" children:@[[self mysqlFavorite:11]]];
	id section = [self section:@[m1, m2, g, h]];
	id p = [self pg:@"p"], q = [self pg:@"q"];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p, q] placements:@{}];

	[layout moveNodes:@[p] toGroup:section displayedIndex:1];
	[layout moveNodes:@[m2] toGroup:section displayedIndex:0];
	[layout moveNodes:@[q] toGroup:g displayedIndex:0];
	[layout moveNodes:@[m1, p] toGroup:g displayedIndex:1];
	[layout moveNodes:@[g] toGroup:h displayedIndex:0];
	[layout setDisplayedChildren:[[[layout displayedChildrenOfGroup:g] reverseObjectEnumerator] allObjects] ofGroup:g];
	id r = [self pg:@"r"], s = [self pg:@"s"];
	[layout appendPostgresNode:r toGroup:h];
	[layout insertPostgresNode:s afterNode:q];

	[self assertNoPostgresNodeUnder:section];
	XCTAssertEqual([[layout postgresNodesWithinGroup:section] count], 4u);
	for (NSTreeNode *node in @[p, q, r, s]) XCTAssertEqual([node parentNode], self.holder);
}

#pragma mark - Queries

- (void)testPostgresNodesWithinGroupIsRecursive
{
	id h = [self groupNamed:@"H" children:@[[self mysqlFavorite:21]]];
	id g = [self groupNamed:@"G" children:@[h]];
	id other = [self groupNamed:@"O" children:@[]];
	id section = [self section:@[g, other]];
	id p1 = [self pg:@"p1"], p2 = [self pg:@"p2"], p3 = [self pg:@"p3"];

	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[p1, p2, p3] placements:@{
		[self pgID:p1]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}, @{@"Name": @"H", @"Nth": @0}], @"Index": @0, @"Order": @0 },
		[self pgID:p2]: @{ @"Group": @[@{@"Name": @"G", @"Nth": @0}], @"Index": @0, @"Order": @0 },
	}];
	NSSet *withinG = [NSSet setWithArray:[layout postgresNodesWithinGroup:g]];
	XCTAssertEqualObjects(withinG, ([NSSet setWithObjects:p1, p2, nil]));
	XCTAssertEqualObjects([layout postgresNodesWithinGroup:h], @[p1]);
	XCTAssertEqualObjects([layout postgresNodesWithinGroup:other], @[]);
	XCTAssertEqual([[layout postgresNodesWithinGroup:section] count], 3u);
}

- (void)testEmptyLayout
{
	id section = [self section:@[[self mysqlFavorite:1]]];
	SPPostgresFavoritesLayout *layout = [self resolve:section nodes:@[] placements:@{}];
	XCTAssertFalse([layout hasPostgresNodes]);
	XCTAssertEqualObjects([layout displayedChildrenOfGroup:section], [section childNodes]);
	XCTAssertEqualObjects([layout placements], @{});
}

- (void)testSortValues
{
	id p = [self pg:@"Local"];
	SPPostgresFavorite *favorite = [(SPPostgresFavoriteNode *)[p representedObject] favorite];
	[favorite setType:SPPostgresSocketConnection];
	[favorite setHost:@"ignored"];
	[favorite setColorIndex:3];
	SPPostgresFavoriteNode *represented = [p representedObject];
	XCTAssertEqualObjects([represented postgresSortValueForKey:@"name"], @"Local");
	XCTAssertEqualObjects([represented postgresSortValueForKey:@"host"], @"localhost");
	XCTAssertEqualObjects([represented postgresSortValueForKey:@"type"], @(100 + SPPostgresSocketConnection));
	XCTAssertEqualObjects([represented postgresSortValueForKey:@"colorIndex"], @3);
	XCTAssertNil([represented postgresSortValueForKey:@"user"]);

	[favorite setType:SPPostgresTCPIPConnection];
	XCTAssertEqualObjects(SPFavoritesSortValueForNode(p, @"host"), @"ignored");

	id m = [self mysqlFavorite:5];
	XCTAssertEqualObjects(SPFavoritesSortValueForNode(m, @"name"), @"m5");
	XCTAssertEqualObjects(SPFavoritesSortValueForNode(m, @"host"), @"mysqlhost");
	XCTAssertNil(SPFavoritesSortValueForNode([self groupNamed:@"G" children:@[]], @"host"));
}

@end
