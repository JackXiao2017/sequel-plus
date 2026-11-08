#import <XCTest/XCTest.h>

// App classes without exported symbols: looked up at run time
@interface NSObject (SPFavoritesFilterTests)
+ (id)treeNodeWithRepresentedObject:(id)object;
+ (id)groupNodeWithName:(NSString *)name;
+ (id)favoriteNodeWithDictionary:(NSMutableDictionary *)dictionary;
- (void)setIsGroup:(BOOL)isGroup;
- (void)setNodeIsExpanded:(BOOL)expanded;
- (BOOL)nodeIsExpanded;
- (NSMutableArray *)mutableChildNodes;
- (void)loadNib;
- (void)setUpFavoritesOutlineView;
- (void)_reloadFavoritesViewData;
- (void)_restoreOutlineViewStateNode:(id)node;
- (void)_selectNode:(id)node;
- (id)selectedFavoriteNode;
- (NSOutlineView *)favoritesOutlineView;
- (NSSearchField *)favoritesFilterField;
- (IBAction)filterFavorites:(id)sender;
@end

/// The filter above the connection screen's favorites list (SPConnectionController on the real nib, with a
/// favorites tree of its own: never SPFavoritesController's).
@interface SPFavoritesFilterTests : XCTestCase
@property (strong) id controller;
@property (strong) id root;
@property (strong) id staging;
@property (strong) id alpha;
@property (strong) id beta;
@property (strong) id gamma;
@end

@implementation SPFavoritesFilterTests

- (id)groupNamed:(NSString *)name expanded:(BOOL)expanded
{
	id group = [NSClassFromString(@"SPGroupNode") groupNodeWithName:name];
	[group setNodeIsExpanded:expanded];
	id node = [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:group];
	[node setIsGroup:YES];
	return node;
}

- (id)favoriteNamed:(NSString *)name host:(NSString *)host
{
	NSMutableDictionary *favorite = [@{@"name": name, @"host": host, @"type": @0, @"id": @(arc4random())} mutableCopy];
	return [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:[NSClassFromString(@"SPFavoriteNode") favoriteNodeWithDictionary:favorite]];
}

- (void)setUp
{
	// FAVORITES: Alpha prod (alpha.example.com), Beta (db.beta.internal), Staging (collapsed): Gamma (gamma.example.com)
	self.root = [self groupNamed:@"root" expanded:YES];
	id section = [self groupNamed:@"FAVORITES" expanded:YES];
	[[self.root mutableChildNodes] addObject:section];
	self.alpha = [self favoriteNamed:@"Alpha prod" host:@"alpha.example.com"];
	self.beta = [self favoriteNamed:@"Beta" host:@"db.beta.internal"];
	self.staging = [self groupNamed:@"Staging" expanded:NO];
	self.gamma = [self favoriteNamed:@"Gamma" host:@"gamma.example.com"];
	[[self.staging mutableChildNodes] addObject:self.gamma];
	[[section mutableChildNodes] addObjectsFromArray:@[self.alpha, self.beta, self.staging]];

	// Controllers are kept alive (as in the adapter tests: the nib's objects outlive a test)
	static NSMutableArray *keepAlive;
	if (!keepAlive) keepAlive = [NSMutableArray array];
	self.controller = [[NSClassFromString(@"SPConnectionController") alloc] init];
	[keepAlive addObject:self.controller];
	[self.controller loadNib];
	[self.controller setValue:self.root forKey:@"favoritesRoot"];
	[self.controller setValue:[self groupNamed:@"QUICK CONNECT" expanded:NO] forKey:@"quickConnectItem"];
	[self.controller _reloadFavoritesViewData];
	[self.controller setUpFavoritesOutlineView];
	[self.controller _restoreOutlineViewStateNode:self.root];
}

- (NSArray<NSString *> *)rowTitles
{
	NSOutlineView *outline = [self.controller favoritesOutlineView];
	NSMutableArray *titles = [NSMutableArray array];
	for (NSInteger row = 0; row < [outline numberOfRows]; row++) {
		[titles addObject:[[outline dataSource] outlineView:outline objectValueForTableColumn:nil byItem:[outline itemAtRow:row]]];
	}
	return titles;
}

- (void)filter:(NSString *)text
{
	NSSearchField *field = [self.controller favoritesFilterField];
	[field setStringValue:text];
	[self.controller filterFavorites:field];
}

- (void)testFilterFieldIsAboveTheList
{
	NSSearchField *field = [self.controller favoritesFilterField];
	XCTAssertNotNil(field);
	NSScrollView *scrollView = [[self.controller favoritesOutlineView] enclosingScrollView];
	XCTAssertEqual([field superview], [scrollView superview]);
	XCTAssertFalse([[field superview] isFlipped]);
	XCTAssertGreaterThanOrEqual(NSMinY([field frame]), NSMaxY([scrollView frame]), @"above the list");
	XCTAssertLessThanOrEqual(NSMaxY([field frame]), NSHeight([[field superview] bounds]), @"inside the pane");
	XCTAssertEqualObjects([[field cell] placeholderString], @"Filter");
}

- (void)testFilterShowsMatchingFavoritesAndTheirGroups
{
	NSArray *all = @[@"QUICK CONNECT", @"FAVORITES", @"Alpha prod", @"Beta", @"Staging"];
	XCTAssertEqualObjects([self rowTitles], all, @"Staging collapsed");

	[self filter:@"gamma"];
	XCTAssertEqualObjects([self rowTitles], (@[@"QUICK CONNECT", @"FAVORITES", @"Staging", @"Gamma"]), @"its group expanded");
	XCTAssertFalse([[self.staging representedObject] nodeIsExpanded], @"the group's own state is kept");

	[self filter:@"EXAMPLE.com"];
	XCTAssertEqualObjects([self rowTitles], (@[@"QUICK CONNECT", @"FAVORITES", @"Alpha prod", @"Staging", @"Gamma"]), @"by host, any case");

	[self filter:@"stag"];
	XCTAssertEqualObjects([self rowTitles], (@[@"QUICK CONNECT", @"FAVORITES", @"Staging", @"Gamma"]), @"a group's name shows all it holds");

	[self filter:@"  beta "];
	XCTAssertEqualObjects([self rowTitles], (@[@"QUICK CONNECT", @"FAVORITES", @"Beta"]), @"spaces around ignored");

	[self filter:@"no such favorite"];
	XCTAssertEqualObjects([self rowTitles], (@[@"QUICK CONNECT", @"FAVORITES"]));

	[self filter:@""];
	XCTAssertEqualObjects([self rowTitles], all, @"cleared: as before, Staging collapsed again");
	XCTAssertFalse([[self.staging representedObject] nodeIsExpanded]);
}

- (void)testSelectedFavoriteStaysShownAndSelected
{
	[self.controller _selectNode:self.beta];
	XCTAssertEqual([self.controller selectedFavoriteNode], self.beta);
	[self.controller setValue:@"edited in the form" forKey:@"name"];

	[self filter:@"gamma"];
	XCTAssertEqualObjects([self rowTitles], (@[@"QUICK CONNECT", @"FAVORITES", @"Beta", @"Staging", @"Gamma"]));
	XCTAssertEqual([self.controller selectedFavoriteNode], self.beta);
	XCTAssertEqualObjects([self.controller valueForKey:@"name"], @"edited in the form", @"the form isn't reloaded");

	[self filter:@""];
	XCTAssertEqual([self.controller selectedFavoriteNode], self.beta);
	XCTAssertEqualObjects([self.controller valueForKey:@"name"], @"edited in the form");
}

- (void)testSelectingAHiddenFavoriteClearsTheFilter
{
	[self filter:@"gamma"];
	[self.controller _selectNode:self.alpha];
	XCTAssertEqualObjects([[self.controller favoritesFilterField] stringValue], @"");
	XCTAssertEqual([self.controller selectedFavoriteNode], self.alpha);
	XCTAssertTrue([[self rowTitles] containsObject:@"Beta"]);
}

- (void)testNoDropWhileFiltering
{
	NSOutlineView *outline = [self.controller favoritesOutlineView];
	[self filter:@"a"];
	id <NSOutlineViewDataSource> dataSource = [outline dataSource];
	XCTAssertEqual([dataSource outlineView:outline validateDrop:(id <NSDraggingInfo>)outline proposedItem:self.staging proposedChildIndex:0], NSDragOperationNone);
}

@end
