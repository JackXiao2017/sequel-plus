#import <Foundation/Foundation.h>

@class SPTreeNode;

/**
 * Where PostgreSQL favorites are displayed among the MySQL favorites and groups of the FAVORITES list.
 * The layout never changes the MySQL tree: Postgres nodes keep their own parent (the adapter's holder node)
 * and the MySQL groups' childNodes are left alone; the displayed arrangement lives only here.
 * A placement record: Group = @[@{Name, Nth}...] from the section down (@[] = top level); After = absent (first),
 * @{FavoriteID} or @{GroupName, Nth}; Index = MySQL siblings before it (fallback when After is gone);
 * Order = its position among Postgres favorites with the same Group and After.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoritesLayout : NSObject

/// `section`: the MySQL FAVORITES section node (first child of favoritesTree). `postgresNodes`: every
/// Postgres favorite node, in the store's name order. Replaces the whole arrangement. Malformed placement
/// records are treated as no placement (end of the top level).
- (void)resolveWithMySQLSection:(SPTreeNode *)section postgresNodes:(NSArray *)postgresNodes placements:(NSDictionary *)placements;
/// The displayed children of a MySQL group (or of the section): its childNodes with Postgres nodes inserted.
/// Exactly [group childNodes] when no Postgres node is there.
- (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group;
/// The MySQL group a Postgres node is displayed in (the section for the top level); for a MySQL node, its parentNode.
- (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node;
/// Postgres nodes displayed in `group` and all its subgroups.
- (NSArray *)postgresNodesWithinGroup:(SPTreeNode *)group;
- (BOOL)hasPostgresNodes;
/// favoriteID -> placement for every Postgres node in the arrangement, computed from where each is displayed now.
/// MySQL items are matched against the groups' *current* childNodes, so an anchor removed since the last
/// resolve is skipped: the nearest earlier MySQL sibling still there is used.
- (NSDictionary *)placements;

/// Makes `children` (a mix of MySQL and Postgres nodes, each already displayed somewhere or new Postgres
/// nodes) the displayed children of `group`. The MySQL subset, in that order, becomes [group mutableChildNodes]
/// (removing each MySQL node from its old parent first). The Postgres ones move here from wherever they were.
/// Postgres nodes no longer displayed anywhere leave the arrangement.
- (void)setDisplayedChildren:(NSArray *)children ofGroup:(SPTreeNode *)group;
/// Drag and drop: moves `nodes` (in order) to `group` at displayed index `index`, as SPConnectionController's
/// MySQL drop does with childNodes (an index past a node removed from the same group is shifted down by one).
/// A negative index (NSOutlineViewDropOnItemIndex) means 0.
- (void)moveNodes:(NSArray *)nodes toGroup:(SPTreeNode *)group displayedIndex:(NSInteger)index;
/// A new Postgres node: displayed at the end of `group`.
- (void)appendPostgresNode:(SPTreeNode *)node toGroup:(SPTreeNode *)group;
/// A new Postgres node: displayed right after `existing` (a displayed Postgres node). When `existing` is not
/// displayed, the new node goes to the end of the top level.
- (void)insertPostgresNode:(SPTreeNode *)node afterNode:(SPTreeNode *)existing;

@end
