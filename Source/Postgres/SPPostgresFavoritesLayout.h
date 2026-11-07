#import <Foundation/Foundation.h>

@class SPTreeNode;

/**
 * Where the 2.0.0-RC builds displayed PostgreSQL favorites among the MySQL favorites and groups of the FAVORITES
 * list, from their PostgresFavoritePlacements.plist records. Used only by SPPostgresFavoritesImport, to put those
 * favorites into the favorites tree where they were displayed. Resolving never changes the tree.
 * A placement record: Group = @[@{Name, Nth}...] from the section down (@[] = top level); After = absent (first),
 * @{FavoriteID} or @{GroupName, Nth}; Index = MySQL siblings before it, counting the After anchor (when the
 * anchor is gone: before the MySQL child at min(max(Index - 1, 0), count));
 * Order = its position among Postgres favorites with the same Group and After.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoritesLayout : NSObject

/// `section`: the MySQL FAVORITES section node (first child of favoritesTree). `postgresNodes`: every
/// Postgres favorite node, in name order. Replaces the whole arrangement. Malformed placement
/// records are treated as no placement (end of the top level).
- (void)resolveWithMySQLSection:(SPTreeNode *)section postgresNodes:(NSArray *)postgresNodes placements:(NSDictionary *)placements;
/// The displayed children of a MySQL group (or of the section): its childNodes with Postgres nodes inserted.
/// Exactly [group childNodes] when no Postgres node is there.
- (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group;
/// The MySQL group a Postgres node is displayed in (the section for the top level); for a MySQL node, its parentNode.
- (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node;
- (BOOL)hasPostgresNodes;

@end
