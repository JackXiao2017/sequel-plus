#import <Foundation/Foundation.h>

/// Posted (on the calling thread) after each successful write of a store's file, with the store as the object.
extern NSString * const SPPostgresQueryStoreDidChangeNotification __attribute__((visibility("default")));

/**
 * A list of the PostgreSQL Query tab's items kept in a property list file: the query history (each item an NSString,
 * most recent first) or the query favorites (each item @{@"name": …, @"query": …}). Postgres history and favorites
 * are global (Postgres tabs have no documents) and are stored apart from MySQL's: this class never reads or writes
 * MySQL's queryHistory / queryFavorites preferences or its Favorites.plist.
 *
 * A file that can't be read (corrupt, not the expected structure, or written by a newer version) gives a lastLoadError
 * and the items that could be read (a newer version's items, read-only; otherwise none), and is never overwritten:
 * -setItems:error: refuses with an error until the file is readable again (or removed). Only a user-confirmed
 * -replaceItems:error: replaces it, after moving it aside. A missing file is fine (no items) and is created, with its folder, on the first save. Use on the main
 * thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryStore : NSObject

- (instancetype)initWithFileURL:(NSURL *)url;

/// …/Application Support/Sequel Pro/Data/PostgresQueryHistory.plist
+ (instancetype)sharedHistoryStore;
/// …/Application Support/Sequel Pro/Data/PostgresQueryFavorites.plist
+ (instancetype)sharedFavoritesStore;

@property (readonly, copy) NSURL *fileURL;

/// The stored items, reloaded from the file when it changed (another tab or build may write it). Empty when the file
/// is missing or can't be read at all (see lastLoadError).
@property (readonly) NSArray *items;

/// Writes items atomically and posts SPPostgresQueryStoreDidChangeNotification. Refused (NO, error set, the file left
/// untouched) when the existing file can't be read.
- (BOOL)setItems:(NSArray *)items error:(NSError **)error;

/**
 * User-confirmed replacement (Clear History, the favorites manager's Save): as -setItems:error:, but when the existing
 * file can't be read it is first moved aside, in the same folder, to "<basename>.unreadable-<yyyyMMdd-HHmmss>.plist"
 * (never deleted), then items are written. Automatic writes (recording a run) use -setItems:error:, which refuses.
 */
- (BOOL)replaceItems:(NSArray *)items error:(NSError **)error;

/// Why the last read of the file failed (the description names the file), or nil when it was missing or valid.
@property (readonly) NSError *lastLoadError;

@end
