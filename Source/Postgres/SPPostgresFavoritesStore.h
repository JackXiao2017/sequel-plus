#import <Foundation/Foundation.h>

@class SPPostgresFavorite;

/// Posted (on the calling thread) after each successful write of the favorites file.
extern NSString * const SPPostgresFavoritesDidChangeNotification __attribute__((visibility("default")));

/**
 * Persists PostgreSQL favorites to PostgresFavorites.plist. This store never reads or
 * writes the MySQL Favorites.plist, which belongs to the original Sequel Pro.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoritesStore : NSObject

- (instancetype)initWithFileURL:(NSURL *)fileURL;
+ (instancetype)sharedStore;

/// Favorites sorted by name, case-insensitive. Reloaded from disk on each call.
- (NSArray *)favorites;
- (BOOL)saveFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error;
- (BOOL)removeFavoriteWithID:(NSString *)favoriteID error:(NSError **)error;

@end
