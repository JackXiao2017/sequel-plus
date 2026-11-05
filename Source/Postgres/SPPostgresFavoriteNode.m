#import "SPPostgresFavoriteNode.h"
#import "SPPostgresFavorite.h"
#import "SPTreeNode.h"
#import "SPConstants.h"

NSString * const SPFavoriteEngineKey = @"engine";
NSString * const SPFavoriteEnginePostgreSQL = @"postgresql";
NSString * const SPPostgresFavoriteUUIDKey = @"postgresFavoriteID";

static const NSInteger SPPostgresFavoriteSortTypeOffset = 100; // after MySQL's connection types

// The key -[SPPostgresFavorite dictionaryRepresentation] / +favoriteWithDictionary: use for the UUID
static NSString * const SPPostgresFavoriteRepresentationIDKey = @"id";

@implementation SPPostgresFavoriteNode
@synthesize favorite;

+ (BOOL)isPostgresFavoriteDictionary:(id)dictionary
{
	if (![dictionary isKindOfClass:[NSDictionary class]]) return NO;
	id engine = [dictionary objectForKey:SPFavoriteEngineKey];
	return [engine isKindOfClass:[NSString class]] && [engine isEqualToString:SPFavoriteEnginePostgreSQL];
}

+ (SPTreeNode *)treeNodeWithFavorite:(SPPostgresFavorite *)theFavorite
{
	SPPostgresFavoriteNode *represented = [[[SPPostgresFavoriteNode alloc] init] autorelease];
	[represented setFavorite:theFavorite];
	return [SPTreeNode treeNodeWithRepresentedObject:represented];
}

+ (SPTreeNode *)treeNodeWithFavoritesDictionary:(NSDictionary *)dictionary
{
	if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;

	NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:dictionary];
	[fields removeObjectForKey:SPPostgresFavoriteRepresentationIDKey];
	id uuid = [dictionary objectForKey:SPPostgresFavoriteUUIDKey];
	if ([uuid isKindOfClass:[NSString class]]) [fields setObject:uuid forKey:SPPostgresFavoriteRepresentationIDKey];
	SPPostgresFavorite *theFavorite = [SPPostgresFavorite favoriteWithDictionary:fields];
	if (!theFavorite) return nil;

	SPTreeNode *node = [self treeNodeWithFavorite:theFavorite];

	// Keys this version doesn't know (written by a later one) are kept
	NSMutableDictionary *others = [NSMutableDictionary dictionaryWithDictionary:dictionary];
	[others removeObjectsForKeys:@[SPPostgresFavoriteRepresentationIDKey, SPPostgresFavoriteUUIDKey, SPFavoriteEngineKey,
		@"name", @"colorIndex", @"type", @"host", @"port", @"user", @"database", @"socketPath", @"useSSL",
		@"sslCACertPath", @"sslCertPath", @"sslKeyPath", @"sshHost", @"sshUser", @"sshPort", @"sshKeyPath"]];
	SPPostgresFavoriteNode *represented = [node representedObject];
	represented->otherEntries = [others count] ? [others copy] : nil;

	return node;
}

- (NSDictionary *)favoritesDictionary
{
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
	if (otherEntries) [dictionary addEntriesFromDictionary:otherEntries];
	[dictionary addEntriesFromDictionary:[favorite dictionaryRepresentation]];
	[dictionary removeObjectForKey:SPPostgresFavoriteRepresentationIDKey];
	if ([favorite favoriteID]) [dictionary setObject:[favorite favoriteID] forKey:SPPostgresFavoriteUUIDKey];
	[dictionary setObject:SPFavoriteEnginePostgreSQL forKey:SPFavoriteEngineKey];
	return dictionary;
}

- (NSString *)nodeName { return [favorite name]; }
- (NSMutableDictionary *)nodeFavorite { return nil; }

- (void)dealloc
{
	[favorite release];
	[otherEntries release];
	[super dealloc];
}

- (id)postgresSortValueForKey:(NSString *)key
{
	if ([key isEqualToString:SPFavoriteNameKey]) return [favorite name];
	if ([key isEqualToString:SPFavoriteHostKey]) return ([favorite type] == SPPostgresSocketConnection) ? @"localhost" : [favorite host];
	if ([key isEqualToString:SPFavoriteTypeKey]) return @(SPPostgresFavoriteSortTypeOffset + [favorite type]);
	if ([key isEqualToString:SPFavoriteColorIndexKey]) return @([favorite colorIndex]);
	return nil;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %p: %@ (PostgreSQL, %@)>", [self class], self, [favorite name], [favorite favoriteID]];
}

@end

id SPFavoritesSortValueForNode(SPTreeNode *node, NSString *key)
{
	id represented = [node representedObject];
	if ([represented isKindOfClass:[SPPostgresFavoriteNode class]]) return [(SPPostgresFavoriteNode *)represented postgresSortValueForKey:key];
	if (![represented respondsToSelector:@selector(nodeFavorite)]) return nil;
	return [[represented nodeFavorite] objectForKey:key];
}

SPPostgresFavorite *SPPostgresFavoriteForNode(id node)
{
	if (![node isKindOfClass:[NSTreeNode class]]) return nil;
	id represented = [(NSTreeNode *)node representedObject];
	if (![represented isKindOfClass:[SPPostgresFavoriteNode class]]) return nil;
	return [(SPPostgresFavoriteNode *)represented favorite];
}
