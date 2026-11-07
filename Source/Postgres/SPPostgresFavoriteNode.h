#import <Foundation/Foundation.h>
#import "../SPNamedNode.h"

@class SPPostgresFavorite;
@class SPTreeNode;

/// Key of a Favorites.plist favorite dictionary naming its engine. MySQL favorites have none.
extern NSString * const SPFavoriteEngineKey __attribute__((visibility("default")));
/// SPFavoriteEngineKey's value for a PostgreSQL favorite.
extern NSString * const SPFavoriteEnginePostgreSQL __attribute__((visibility("default")));
/// Key of a PostgreSQL favorite dictionary in Favorites.plist holding its UUID (-[SPPostgresFavorite favoriteID]).
/// A PostgreSQL favorite has no MySQL "id" (SPFavoriteIDKey), so no MySQL lookup by numeric ID ever matches it.
extern NSString * const SPPostgresFavoriteUUIDKey __attribute__((visibility("default")));

/**
 * Represented object of a PostgreSQL favorite's node in the favorites tree (SPFavoritesController's tree, saved
 * to Favorites.plist with the MySQL favorites and groups). -nodeFavorite returns nil so that any MySQL code reading
 * a favorite dictionary from a node sees "no MySQL favorite" rather than a Postgres one.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoriteNode : NSObject <SPNamedNode>
{
	SPPostgresFavorite *favorite;
	NSDictionary *otherEntries;
}
@property (nonatomic, retain) SPPostgresFavorite *favorite;

/// YES for a Favorites.plist favorite dictionary of a PostgreSQL favorite (SPFavoriteEngineKey is SPFavoriteEnginePostgreSQL).
+ (BOOL)isPostgresFavoriteDictionary:(id)dictionary;
/// A favorites-tree node (an SPTreeNode) for `favorite`.
+ (SPTreeNode *)treeNodeWithFavorite:(SPPostgresFavorite *)favorite;
/// A favorites-tree node for a Favorites.plist PostgreSQL favorite dictionary. Keys this version doesn't know are kept
/// and written back by -favoritesDictionary.
+ (SPTreeNode *)treeNodeWithFavoritesDictionary:(NSDictionary *)dictionary;
/// The favorite's dictionary in Favorites.plist: its fields (as -[SPPostgresFavorite dictionaryRepresentation], the
/// UUID under SPPostgresFavoriteUUIDKey instead of "id") and SPFavoriteEngineKey.
- (NSDictionary *)favoritesDictionary;

/// Value for MySQL's favorites sort keys: SPFavoriteNameKey -> name; SPFavoriteHostKey -> host
/// ("localhost" for a socket favorite); SPFavoriteTypeKey -> @(100 + type), so Postgres sorts after
/// MySQL's types; SPFavoriteColorIndexKey -> @(colorIndex); any other key -> nil.
- (id)postgresSortValueForKey:(NSString *)key;
@end

/// The sort value of any favorites-tree node: a Postgres node's -postgresSortValueForKey:, else
/// [[[node representedObject] nodeFavorite] objectForKey:key] (MySQL's existing lookup; nil for a group).
extern id SPFavoritesSortValueForNode(SPTreeNode *node, NSString *key) __attribute__((visibility("default")));
/// The PostgreSQL favorite of a favorites-tree node, or nil (a MySQL favorite, a group, anything else).
extern SPPostgresFavorite *SPPostgresFavoriteForNode(id node) __attribute__((visibility("default")));
