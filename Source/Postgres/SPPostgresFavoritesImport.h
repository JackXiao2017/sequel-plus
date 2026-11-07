#import <Foundation/Foundation.h>

@class SPTreeNode;

/// The PostgreSQL favorites file of Sequel Plus 2.0.0-RC builds, in the data folder.
extern NSString * const SPPostgresLegacyFavoritesFileName __attribute__((visibility("default")));
/// Where those builds kept each PostgreSQL favorite's place in the FAVORITES list, beside it.
extern NSString * const SPPostgresLegacyPlacementsFileName __attribute__((visibility("default")));
/// Appended to both files' names once imported (kept as a backup, never read again).
extern NSString * const SPPostgresLegacyImportedSuffix __attribute__((visibility("default")));

/**
 * One-time import of the PostgreSQL favorites of the 2.0.0-RC builds (PostgresFavorites.plist, with their places
 * in PostgresFavoritePlacements.plist) into the favorites tree that Favorites.plist holds.
 *
 * Each favorite goes where those builds displayed it (SPPostgresFavoritesLayout resolves the placements against the
 * tree, as they did), so nothing moves. Favorites whose ID is already in the tree are skipped (a second run adds
 * nothing). After the tree is saved both files are renamed with SPPostgresLegacyImportedSuffix. A favorites file that
 * can't be read is left as it is (not renamed) and reported; an unreadable placements file puts every favorite at
 * the end of the top level, as those builds did.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoritesImport : NSObject

/**
 * Imports `<dataFolder>/PostgresFavorites.plist` into `section` (the FAVORITES section node, the first child of
 * SPFavoritesController's tree). `save` writes the tree (Favorites.plist) and returns whether it was written; it is
 * called only when favorites were added. Returns NO (with `error`) when the file can't be read or `save` fails, and
 * the files are then left in place. `importedCount` (optional) is the number of favorites added.
 */
+ (BOOL)importFavoritesInDataFolder:(NSURL *)dataFolder
                        intoSection:(SPTreeNode *)section
                               save:(BOOL (^)(void))save
                      importedCount:(NSUInteger *)importedCount
                              error:(NSError **)error;

/// The favorite dictionaries of a PostgresFavorites.plist (empty when it is missing); nil with `error` when it
/// exists but is unreadable, malformed or of a newer version.
+ (NSArray *)favoriteDictionariesInFileAtURL:(NSURL *)fileURL error:(NSError **)error;

@end
