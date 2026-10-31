#import <Foundation/Foundation.h>

@class SPPostgresFavoritesStore;

/// Posted (on the calling thread) after each successful write of the placements file. The object is the store.
extern NSString * const SPPostgresFavoritePlacementsDidChangeNotification __attribute__((visibility("default")));

/**
 * Remembers where each PostgreSQL favorite sits inside the MySQL FAVORITES list, in
 * PostgresFavoritePlacements.plist. File format: { Version: 1, Placements: { favoriteID: record } }.
 * This store never reads or writes the MySQL Favorites.plist.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoritePlacementsStore : NSObject

- (instancetype)initWithFileURL:(NSURL *)fileURL;
/// The store beside `favoritesStore`'s file: same directory, "PostgresFavoritePlacements.plist".
+ (instancetype)storeBesideFavoritesStore:(SPPostgresFavoritesStore *)favoritesStore;

/// favoriteID -> placement record; reread from disk on each call; empty when missing/unreadable/newer.
- (NSDictionary *)placements;
/// Replaces all placements (atomic write). Refuses (NO, error) when the file on disk is unreadable or newer.
- (BOOL)setPlacements:(NSDictionary *)placements error:(NSError **)error;

@end
