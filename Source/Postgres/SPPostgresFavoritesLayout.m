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

/// How many groups before `group` in `siblings` have its name.
static NSUInteger SPPGNthOfGroup(SPTreeNode *group, NSArray *siblings)
{
	NSString *name = SPPGNodeName(group);
	NSUInteger nth = 0;
	for (SPTreeNode *sibling in siblings) {
		if (sibling == group) break;
		if (SPPGIsMySQLGroup(sibling) && [SPPGNodeName(sibling) isEqualToString:name]) nth++;
	}
	return nth;
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
- (NSArray *)_pathOfGroup:(SPTreeNode *)group;
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
					// The anchor is gone: before the MySQL child at min(Index, count)
					NSNumber *index = SPPGValue(record, SPPGPlacementIndexKey, [NSNumber class]);
					NSInteger wanted = index ? [index integerValue] : (NSInteger)[children count];
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

- (NSArray *)postgresNodesWithinGroup:(SPTreeNode *)group
{
	NSMutableArray *nodes = [NSMutableArray array];
	for (SPTreeNode *child in [self displayedChildrenOfGroup:group]) {
		if (SPPGIsPostgresNode(child)) [nodes addObject:child];
		else if ([child isGroup]) [nodes addObjectsFromArray:[self postgresNodesWithinGroup:child]];
	}
	return nodes;
}

- (BOOL)hasPostgresNodes
{
	return [parentByNode count] > 0;
}

#pragma mark - Snapshot

/// Name/Nth steps from the section down to `group` (@[] for the section); nil when it is no longer in the section.
- (NSArray *)_pathOfGroup:(SPTreeNode *)group
{
	NSMutableArray *path = [NSMutableArray array];
	SPTreeNode *node = group;
	while (node != section) {
		SPTreeNode *parent = (SPTreeNode *)[node parentNode];
		NSArray *siblings = [parent childNodes];
		if (!parent || [siblings indexOfObjectIdenticalTo:node] == NSNotFound) return nil;
		NSString *name = SPPGNodeName(node);
		[path insertObject:@{ SPPGPlacementNameKey: (name ? name : @""), SPPGPlacementNthKey: @(SPPGNthOfGroup(node, siblings)) } atIndex:0];
		node = parent;
	}
	return path;
}

/// The After value for `anchor` (nil: first in the group). A MySQL favorite without an id gets an empty
/// After, so a resolve falls back to Index.
static NSDictionary *SPPGAfterForAnchor(SPTreeNode *anchor, NSArray *siblings)
{
	if (!anchor) return nil;
	if ([anchor isGroup]) {
		NSString *name = SPPGNodeName(anchor);
		return @{ SPPGPlacementGroupNameKey: (name ? name : @""), SPPGPlacementNthKey: @(SPPGNthOfGroup(anchor, siblings)) };
	}
	id represented = [anchor representedObject];
	id favoriteID = [represented respondsToSelector:@selector(nodeFavorite)] ? [[represented nodeFavorite] objectForKey:SPFavoriteIDKey] : nil;
	return favoriteID ? @{ SPPGPlacementFavoriteIDKey: favoriteID } : @{};
}

- (NSDictionary *)placements
{
	NSMutableDictionary *placements = [NSMutableDictionary dictionary];
	if (!section) return placements;

	NSMutableArray *groups = [NSMutableArray array];
	if ([displayedByGroup objectForKey:section]) [groups addObject:section];
	for (SPTreeNode *group in displayedByGroup) {
		if (group != section) [groups addObject:group];
	}

	NSUInteger trailingAtTopLevel = 0; // Postgres nodes after the section's last MySQL child
	NSMutableArray *orphans = [NSMutableArray array];

	for (SPTreeNode *group in groups) {
		NSArray *path = [self _pathOfGroup:group];
		NSArray *displayed = [displayedByGroup objectForKey:group];
		if (!path) {
			// The group left the FAVORITES list: its Postgres favorites go to the end of the top level
			for (SPTreeNode *node in displayed) if (SPPGIsPostgresNode(node)) [orphans addObject:node];
			continue;
		}

		NSArray *current = [group childNodes];
		SPTreeNode *anchor = nil;
		NSUInteger index = 0;
		NSUInteger order = 0;
		for (SPTreeNode *node in displayed) {
			if (SPPGIsPostgresNode(node)) {
				NSString *favoriteID = SPPGFavoriteID(node);
				if (!favoriteID) continue;
				NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
					path, SPPGPlacementGroupKey, @(index), SPPGPlacementIndexKey, @(order++), SPPGPlacementOrderKey, nil];
				NSDictionary *after = SPPGAfterForAnchor(anchor, current);
				if (after) [record setObject:after forKey:SPPGPlacementAfterKey];
				[placements setObject:record forKey:favoriteID];
				continue;
			}
			NSUInteger position = [current indexOfObjectIdenticalTo:node];
			if (position == NSNotFound) continue; // removed since the resolve: keep counting from the earlier anchor
			anchor = node;
			index = position + 1;
			order = 0;
		}
		if (group == section && index == [current count]) trailingAtTopLevel = order;
	}

	if ([orphans count]) {
		NSArray *current = [section childNodes];
		NSDictionary *after = SPPGAfterForAnchor([current lastObject], current);
		NSUInteger order = trailingAtTopLevel;
		for (SPTreeNode *node in orphans) {
			NSString *favoriteID = SPPGFavoriteID(node);
			if (!favoriteID) continue;
			NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
				@[], SPPGPlacementGroupKey, @([current count]), SPPGPlacementIndexKey, @(order++), SPPGPlacementOrderKey, nil];
			if (after) [record setObject:after forKey:SPPGPlacementAfterKey];
			[placements setObject:record forKey:favoriteID];
		}
	}

	return placements;
}

#pragma mark - Changes

/// Stores `displayed` for `group`, or drops the group from the arrangement when no Postgres node is in it.
- (void)_storeDisplayed:(NSArray *)displayed forGroup:(SPTreeNode *)group
{
	for (id child in displayed) {
		if (SPPGIsPostgresNode(child)) {
			[displayedByGroup setObject:[NSArray arrayWithArray:displayed] forKey:group];
			return;
		}
	}
	[displayedByGroup removeObjectForKey:group];
}

/// Takes `node` out of the stored displayed children of `group`, if it has any.
- (void)_removeNode:(SPTreeNode *)node fromDisplayedOfGroup:(SPTreeNode *)group
{
	NSArray *displayed = group ? [displayedByGroup objectForKey:group] : nil;
	NSUInteger idx = [displayed indexOfObjectIdenticalTo:node];
	if (idx == NSNotFound) return;
	NSMutableArray *remaining = [[displayed mutableCopy] autorelease];
	[remaining removeObjectAtIndex:idx];
	[self _storeDisplayed:remaining forGroup:group];
}

- (void)setDisplayedChildren:(NSArray *)children ofGroup:(SPTreeNode *)group
{
	if (!group) return;
	children = [[children copy] autorelease]; // the caller's array may be one of ours

	// Postgres nodes shown here before but not in `children` are no longer displayed anywhere
	for (SPTreeNode *old in [self displayedChildrenOfGroup:group]) {
		if (SPPGIsPostgresNode(old) && [children indexOfObjectIdenticalTo:old] == NSNotFound) {
			[parentByNode removeObjectForKey:old];
		}
	}

	NSMutableArray *mysqlChildren = [NSMutableArray arrayWithCapacity:[children count]];
	for (SPTreeNode *node in children) {
		if (SPPGIsPostgresNode(node)) {
			SPTreeNode *oldGroup = [parentByNode objectForKey:node];
			if (oldGroup && oldGroup != group) [self _removeNode:node fromDisplayedOfGroup:oldGroup];
			[parentByNode setObject:group forKey:node];
		}
		else {
			SPTreeNode *oldParent = (SPTreeNode *)[node parentNode];
			if (oldParent && oldParent != group) {
				[self _removeNode:node fromDisplayedOfGroup:oldParent];
				[[oldParent mutableChildNodes] removeObjectIdenticalTo:node];
			}
			[mysqlChildren addObject:node];
		}
	}

	NSMutableArray *groupChildren = [group mutableChildNodes];
	if (![groupChildren isEqualToArray:mysqlChildren]) {
		[groupChildren removeAllObjects];
		[groupChildren addObjectsFromArray:mysqlChildren];
	}
	[self _storeDisplayed:children forGroup:group];
}

- (void)moveNodes:(NSArray *)nodes toGroup:(SPTreeNode *)group displayedIndex:(NSInteger)index
{
	if (!group) return;
	NSMutableArray *displayed = [NSMutableArray arrayWithArray:[self displayedChildrenOfGroup:group]];
	if (index < 0) index = 0;

	for (SPTreeNode *node in nodes) {
		NSUInteger oldIndex = [displayed indexOfObjectIdenticalTo:node];
		if (oldIndex != NSNotFound) {
			[displayed removeObjectAtIndex:oldIndex];
			if (index > (NSInteger)oldIndex) index--;
		}
		index = MIN(index, (NSInteger)[displayed count]);
		[displayed insertObject:node atIndex:(NSUInteger)index];
		index++;
	}

	[self setDisplayedChildren:displayed ofGroup:group];
}

- (void)appendPostgresNode:(SPTreeNode *)node toGroup:(SPTreeNode *)group
{
	if (!group || !SPPGIsPostgresNode(node)) return;
	[self setDisplayedChildren:[[self displayedChildrenOfGroup:group] arrayByAddingObject:node] ofGroup:group];
}

- (void)insertPostgresNode:(SPTreeNode *)node afterNode:(SPTreeNode *)existing
{
	if (!SPPGIsPostgresNode(node)) return;
	SPTreeNode *group = existing ? [parentByNode objectForKey:existing] : nil;
	NSUInteger idx = [[self displayedChildrenOfGroup:group] indexOfObjectIdenticalTo:existing];
	if (!group || idx == NSNotFound) {
		[self appendPostgresNode:node toGroup:section];
		return;
	}
	NSMutableArray *displayed = [NSMutableArray arrayWithArray:[self displayedChildrenOfGroup:group]];
	[displayed insertObject:node atIndex:idx + 1];
	[self setDisplayedChildren:displayed ofGroup:group];
}

@end
