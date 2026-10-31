#import <Foundation/Foundation.h>
#import "../SPNamedNode.h"

@class SPPostgresFavorite;
@class SPTreeNode;

/**
 * Represented object of a Postgres favorite's outline node. -nodeFavorite returns nil so that any MySQL
 * code reading a favorite dictionary from the selected node sees "no MySQL favorite" rather than crashing.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoriteNode : NSObject <SPNamedNode>
{
	SPPostgresFavorite *favorite;
}
@property (nonatomic, retain) SPPostgresFavorite *favorite;

/// Value for MySQL's favorites sort keys: SPFavoriteNameKey -> name; SPFavoriteHostKey -> host
/// ("localhost" for a socket favorite); SPFavoriteTypeKey -> @(100 + type), so Postgres sorts after
/// MySQL's types; SPFavoriteColorIndexKey -> @(colorIndex); any other key -> nil.
- (id)postgresSortValueForKey:(NSString *)key;
@end

/// The sort value of any favorites-tree node: a Postgres node's -postgresSortValueForKey:, else
/// [[[node representedObject] nodeFavorite] objectForKey:key] (MySQL's existing lookup; nil for a group).
extern id SPFavoritesSortValueForNode(SPTreeNode *node, NSString *key) __attribute__((visibility("default")));
