#import <Foundation/Foundation.h>

@class SPPostgresFavorite;
@class SPTreeNode;

/// Posted (on the calling thread) after each successful change made through a store. The object is the store.
extern NSString * const SPPostgresFavoritesDidChangeNotification __attribute__((visibility("default")));

/**
 * The PostgreSQL favorites, which are favorites of the one favorites tree (SPFavoritesController's, saved to
 * Favorites.plist with the MySQL favorites and groups): each is a leaf whose represented object is an
 * SPPostgresFavoriteNode, at the top level or in any group. This store finds, adds, changes and removes them in
 * that tree and saves it. It never touches MySQL favorites or groups.
 */
__attribute__((visibility("default")))
@interface SPPostgresFavoritesStore : NSObject

/**
 * A store over the FAVORITES section that `sectionProvider` returns (asked on every call: the tree can be rebuilt).
 * `saveHandler` writes the tree after a change and returns whether it was written; on NO the change is undone in
 * the tree. `loadErrorProvider` (optional) gives -lastLoadError.
 */
- (instancetype)initWithSectionProvider:(SPTreeNode *(^)(void))sectionProvider
                            saveHandler:(BOOL (^)(void))saveHandler
                      loadErrorProvider:(NSError *(^)(void))loadErrorProvider;
/// A store over a new, empty, in-memory FAVORITES section whose saves always succeed (tests).
- (instancetype)initInMemory;
/// The store over SPFavoritesController's tree. Its saves write Favorites.plist and tell every connection screen.
+ (instancetype)sharedStore;

/// The FAVORITES section node (an SPTreeNode), or nil.
- (SPTreeNode *)section;
/// Copies of every PostgreSQL favorite of the tree, sorted by name, case-insensitive.
- (NSArray *)favorites;
/// The favorite nodes of the tree, in tree order (depth first).
- (NSArray *)favoriteNodes;
/// The node of the favorite with `favoriteID`, or nil.
- (SPTreeNode *)nodeForFavoriteID:(NSString *)favoriteID;
/// Why the PostgreSQL favorites of the 2.0.0-RC builds could not be imported into the tree (the file is then left
/// as it is), or nil.
- (NSError *)lastLoadError;

/// Adds `favorite` as a child of `group` (a group node of the tree) at `index` (NSNotFound or past the end: at the
/// end); for nil or anything else, at the end of the section. Saves, and returns the new node; nil with `error`
/// when not saved.
- (SPTreeNode *)addFavorite:(SPPostgresFavorite *)favorite toGroup:(SPTreeNode *)group atIndex:(NSUInteger)index error:(NSError **)error;
/// Replaces the favorite with `favorite`'s ID by `favorite` (in place), or adds it at the end of the section, and saves.
- (BOOL)saveFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error;
/// Removes the favorite with `favoriteID` from the tree and saves. YES when it isn't there.
- (BOOL)removeFavoriteWithID:(NSString *)favoriteID error:(NSError **)error;

@end
