#import "SPPostgresFavoriteNode.h"
#import "SPPostgresFavorite.h"
#import "SPTreeNode.h"
#import "SPConstants.h"

static const NSInteger SPPostgresFavoriteSortTypeOffset = 100; // after MySQL's connection types

@implementation SPPostgresFavoriteNode
@synthesize favorite;
- (NSString *)nodeName { return [favorite name]; }
- (NSMutableDictionary *)nodeFavorite { return nil; }
- (void)dealloc { [favorite release]; [super dealloc]; }

- (id)postgresSortValueForKey:(NSString *)key
{
	if ([key isEqualToString:SPFavoriteNameKey]) return [favorite name];
	if ([key isEqualToString:SPFavoriteHostKey]) return ([favorite type] == SPPostgresSocketConnection) ? @"localhost" : [favorite host];
	if ([key isEqualToString:SPFavoriteTypeKey]) return @(SPPostgresFavoriteSortTypeOffset + [favorite type]);
	if ([key isEqualToString:SPFavoriteColorIndexKey]) return @([favorite colorIndex]);
	return nil;
}

@end

id SPFavoritesSortValueForNode(SPTreeNode *node, NSString *key)
{
	id represented = [node representedObject];
	if ([represented isKindOfClass:[SPPostgresFavoriteNode class]]) return [(SPPostgresFavoriteNode *)represented postgresSortValueForKey:key];
	if (![represented respondsToSelector:@selector(nodeFavorite)]) return nil;
	return [[represented nodeFavorite] objectForKey:key];
}
