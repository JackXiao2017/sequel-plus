#import "SPPostgresFavoritesLayout.h"
#import "SPPostgresFavoriteNode.h"
#import "SPPostgresFavorite.h"
#import "SPTreeNode.h"
#import "SPFavoriteNode.h"
#import "SPConstants.h"

static NSString * const SPPGPlacementGroupKey = @"Group";
static NSString * const SPPGPlacementAfterKey = @"After";
static NSString * const SPPGPlacementIndexKey = @"Index";
static NSString * const SPPGPlacementOrderKey = @"Order";
static NSString * const SPPGPlacementNameKey = @"Name";
static NSString * const SPPGPlacementNthKey = @"Nth";
static NSString * const SPPGPlacementFavoriteIDKey = @"FavoriteID";
static NSString * const SPPGPlacementGroupNameKey = @"GroupName";

static BOOL SPPGIsPostgresNode(id node)
{
	return [node isKindOfClass:[NSTreeNode class]] && [[node representedObject] isKindOfClass:[SPPostgresFavoriteNode class]];
}

static BOOL SPPGIsMySQLGroup(SPTreeNode *node)
{
	return !SPPGIsPostgresNode(node) && [node isGroup];
}

static NSString *SPPGNodeName(SPTreeNode *node)
{
	id represented = [node representedObject];
	return [represented respondsToSelector:@selector(nodeName)] ? [represented nodeName] : nil;
}

static NSString *SPPGFavoriteID(SPTreeNode *node)
{
	NSString *favoriteID = [[(SPPostgresFavoriteNode *)[node representedObject] favorite] favoriteID];
	return [favoriteID isKindOfClass:[NSString class]] ? favoriteID : nil;
}

static id SPPGValue(id dict, NSString *key, Class class)
{
	if (![dict isKindOfClass:[NSDictionary class]]) return nil;
	id value = [dict objectForKey:key];
	return [value isKindOfClass:class] ? value : nil;
}

/// Index in `siblings` of the `nth` group named `name`, or NSNotFound.
static NSUInteger SPPGIndexOfGroup(NSArray *siblings, NSString *name, NSInteger nth)
{
	if (!name || nth < 0) return NSNotFound;
	NSInteger seen = 0;
	for (NSUInteger idx = 0; idx < [siblings count]; idx++) {
		SPTreeNode *sibling = [siblings objectAtIndex:idx];
		if (!SPPGIsMySQLGroup(sibling) || ![SPPGNodeName(sibling) isEqualToString:name]) continue;
		if (seen++ == nth) return idx;
	}
	return NSNotFound;
}

@interface SPPostgresFavoritesLayout ()
- (SPTreeNode *)_groupForPath:(id)path;
@end

@implementation SPPostgresFavoritesLayout {
	SPTreeNode *section;
	NSMapTable *displayedByGroup; // MySQL group -> displayed children; only groups holding Postgres nodes
	NSMapTable *parentByNode;     // Postgres node -> MySQL group it is displayed in
}

- (instancetype)init
{
	if ((self = [super init])) {
		NSPointerFunctionsOptions keys = NSMapTableStrongMemory | NSMapTableObjectPointerPersonality;
		displayedByGroup = [[NSMapTable alloc] initWithKeyOptions:keys valueOptions:NSMapTableStrongMemory capacity:0];
		parentByNode = [[NSMapTable alloc] initWithKeyOptions:keys valueOptions:NSMapTableStrongMemory capacity:0];
	}
	return self;
}

- (void)dealloc
{
	[section release];
	[displayedByGroup release];
	[parentByNode release];
	[super dealloc];
}

#pragma mark - Resolve

- (void)resolveWithMySQLSection:(SPTreeNode *)theSection postgresNodes:(NSArray *)postgresNodes placements:(NSDictionary *)placements
{
	[theSection retain];
	[section release];
	section = theSection;
	[displayedByGroup removeAllObjects];
	[parentByNode removeAllObjects];
	if (!section) return;
	if (![placements isKindOfClass:[NSDictionary class]]) placements = nil;

	// group -> entries { node, slot, unplaced, order, seq }; slot = how many MySQL children come before it
	NSMapTable *entriesByGroup = [NSMapTable mapTableWithKeyOptions:(NSMapTableStrongMemory | NSMapTableObjectPointerPersonality) valueOptions:NSMapTableStrongMemory];
	NSUInteger seq = 0;

	for (SPTreeNode *node in postgresNodes) {
		if (!SPPGIsPostgresNode(node) || [parentByNode objectForKey:node]) continue;

		NSString *favoriteID = SPPGFavoriteID(node);
		NSDictionary *record = favoriteID ? [placements objectForKey:favoriteID] : nil;
		if (![record isKindOfClass:[NSDictionary class]]) record = nil;

		SPTreeNode *group = record ? [self _groupForPath:[record objectForKey:SPPGPlacementGroupKey]] : nil;
		NSArray *children = [group childNodes];
		NSUInteger slot;
		NSInteger order = 0;
		BOOL unplaced = (group == nil);

		if (unplaced) {
			// No placement, or its group is gone: end of the top level
			group = section;
			children = [section childNodes];
			slot = [children count];
			// A record whose group is gone keeps its Order among others at the end; a missing record follows them
			if (record) {
				unplaced = NO;
				order = [SPPGValue(record, SPPGPlacementOrderKey, [NSNumber class]) integerValue];
			}
		}
		else {
			order = [SPPGValue(record, SPPGPlacementOrderKey, [NSNumber class]) integerValue];
			id after = [record objectForKey:SPPGPlacementAfterKey];
			NSUInteger anchor = NSNotFound;

			if (!after) {
				slot = 0;
			}
			else {
				NSNumber *anchorID = SPPGValue(after, SPPGPlacementFavoriteIDKey, [NSNumber class]);
				NSString *anchorGroup = SPPGValue(after, SPPGPlacementGroupNameKey, [NSString class]);
				if (anchorID) {
					for (NSUInteger idx = 0; idx < [children count]; idx++) {
						SPTreeNode *child = [children objectAtIndex:idx];
						if ([child isGroup]) continue;
						id represented = [child representedObject];
						if (![represented respondsToSelector:@selector(nodeFavorite)]) continue;
						if ([[[represented nodeFavorite] objectForKey:SPFavoriteIDKey] isEqual:anchorID]) {
							anchor = idx;
							break;
						}
					}
				}
				else if (anchorGroup) {
					NSNumber *nth = SPPGValue(after, SPPGPlacementNthKey, [NSNumber class]);
					anchor = SPPGIndexOfGroup(children, anchorGroup, nth ? [nth integerValue] : 0);
				}

				if (anchor != NSNotFound) {
					slot = anchor + 1;
				}
				else {
					// The anchor is gone: before the MySQL child at min(max(Index - 1, 0), count), as Index
					// counted the anchor itself. An After naming no anchor (a MySQL favorite without an id)
					// uses Index as it is: that anchor may still be there.
					NSNumber *index = SPPGValue(record, SPPGPlacementIndexKey, [NSNumber class]);
					NSInteger wanted = index ? [index integerValue] : (NSInteger)[children count];
					if (index && (anchorID || anchorGroup)) wanted--;
					slot = (NSUInteger)MIN(MAX(wanted, 0), (NSInteger)[children count]);
				}
			}
		}

		NSMutableArray *entries = [entriesByGroup objectForKey:group];
		if (!entries) {
			entries = [NSMutableArray array];
			[entriesByGroup setObject:entries forKey:group];
		}
		[entries addObject:@{ @"node": node, @"slot": @(slot), @"unplaced": @(unplaced), @"order": @(order), @"seq": @(seq++) }];
		[parentByNode setObject:group forKey:node];
	}

	for (SPTreeNode *group in entriesByGroup) {
		NSMutableArray *entries = [entriesByGroup objectForKey:group];
		[entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
			NSComparisonResult result = [[a objectForKey:@"slot"] compare:[b objectForKey:@"slot"]];
			if (result == NSOrderedSame) result = [[a objectForKey:@"unplaced"] compare:[b objectForKey:@"unplaced"]];
			if (result == NSOrderedSame && ![[a objectForKey:@"unplaced"] boolValue]) {
				result = [[a objectForKey:@"order"] compare:[b objectForKey:@"order"]];
				if (result == NSOrderedSame) {
					NSString *nameA = SPPGNodeName([a objectForKey:@"node"]), *nameB = SPPGNodeName([b objectForKey:@"node"]);
					result = [(nameA ? nameA : @"") caseInsensitiveCompare:(nameB ? nameB : @"")];
				}
			}
			if (result == NSOrderedSame) result = [[a objectForKey:@"seq"] compare:[b objectForKey:@"seq"]];
			return result;
		}];

		NSArray *children = [group childNodes];
		NSMutableArray *displayed = [NSMutableArray arrayWithCapacity:[children count] + [entries count]];
		NSUInteger next = 0;
		for (NSUInteger idx = 0; idx <= [children count]; idx++) {
			while (next < [entries count] && [[[entries objectAtIndex:next] objectForKey:@"slot"] unsignedIntegerValue] == idx) {
				[displayed addObject:[[entries objectAtIndex:next++] objectForKey:@"node"]];
			}
			if (idx < [children count]) [displayed addObject:[children objectAtIndex:idx]];
		}
		[displayedByGroup setObject:[NSArray arrayWithArray:displayed] forKey:group];
	}
}

/// The group a placement's Group path names, walking from the section; nil when any step is missing or malformed.
- (SPTreeNode *)_groupForPath:(id)path
{
	if (![path isKindOfClass:[NSArray class]]) return nil;
	SPTreeNode *group = section;
	for (id step in path) {
		NSString *name = SPPGValue(step, SPPGPlacementNameKey, [NSString class]);
		NSNumber *nth = SPPGValue(step, SPPGPlacementNthKey, [NSNumber class]);
		if (!name || !nth) return nil;
		NSArray *children = [group childNodes];
		NSUInteger idx = SPPGIndexOfGroup(children, name, [nth integerValue]);
		if (idx == NSNotFound) return nil;
		group = [children objectAtIndex:idx];
	}
	return group;
}

#pragma mark - Queries

- (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group
{
	NSArray *displayed = group ? [displayedByGroup objectForKey:group] : nil;
	return displayed ? displayed : [group childNodes];
}

- (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node
{
	if (SPPGIsPostgresNode(node)) return [parentByNode objectForKey:node];
	return (SPTreeNode *)[node parentNode];
}

- (BOOL)hasPostgresNodes
{
	return [parentByNode count] > 0;
}

@end
