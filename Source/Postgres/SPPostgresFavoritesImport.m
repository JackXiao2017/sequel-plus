#import "SPPostgresFavoritesImport.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresFavoriteNode.h"
#import "SPPostgresFavoritesLayout.h"
#import "SPTreeNode.h"

NSString * const SPPostgresLegacyFavoritesFileName = @"PostgresFavorites.plist";
NSString * const SPPostgresLegacyPlacementsFileName = @"PostgresFavoritePlacements.plist";
NSString * const SPPostgresLegacyImportedSuffix = @".imported";

static NSString * const SPPostgresFavoritesImportErrorDomain = @"SPPostgresFavoritesStoreErrorDomain";

@implementation SPPostgresFavoritesImport

+ (NSArray *)favoriteDictionariesInFileAtURL:(NSURL *)fileURL error:(NSError **)error
{
	NSMutableArray *result = [NSMutableArray array];
	if (![fileURL checkResourceIsReachableAndReturnError:NULL]) return result;

	NSString *problem = nil;
	NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:fileURL];
	if (![root isKindOfClass:[NSDictionary class]]) {
		problem = @"The file could not be read or is not a valid favorites property list.";
	}
	else {
		id version = [root objectForKey:@"version"];
		id items = [root objectForKey:@"favorites"];
		if (![version isKindOfClass:[NSNumber class]] || ![items isKindOfClass:[NSArray class]]) {
			problem = @"The file does not have the expected structure.";
		}
		else if ([version integerValue] > 1) {
			problem = [NSString stringWithFormat:@"The file uses version %@, which is newer than this version of the application supports.", version];
		}
		else {
			for (id item in items) {
				if ([item isKindOfClass:[NSDictionary class]]) [result addObject:item];
			}
		}
	}

	if (!problem) return result;

	if (error) {
		*error = [NSError errorWithDomain:SPPostgresFavoritesImportErrorDomain code:1 userInfo:@{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot use PostgreSQL favorites file \"%@\". %@ It was left untouched.", [fileURL path], problem]
		}];
	}
	return nil;
}

/// favoriteID -> placement record of a PostgresFavoritePlacements.plist; empty when it is missing, unreadable,
/// malformed or newer (those builds then showed every favorite at the end of the top level).
+ (NSDictionary *)_placementsInFileAtURL:(NSURL *)fileURL
{
	if (![fileURL checkResourceIsReachableAndReturnError:NULL]) return @{};
	NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:fileURL];
	if (![root isKindOfClass:[NSDictionary class]]) return @{};
	id version = [root objectForKey:@"Version"];
	id placements = [root objectForKey:@"Placements"];
	if (![version isKindOfClass:[NSNumber class]] || ![placements isKindOfClass:[NSDictionary class]] || [version integerValue] > 1) return @{};
	return placements;
}

/// Renames `fileURL` with the imported suffix (a free name: an older backup is never replaced).
+ (void)_retireFileAtURL:(NSURL *)fileURL
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if (![fileManager fileExistsAtPath:[fileURL path]]) return;

	NSString *base = [[fileURL path] stringByAppendingString:SPPostgresLegacyImportedSuffix];
	NSString *destination = base;
	for (NSUInteger attempt = 2; [fileManager fileExistsAtPath:destination]; attempt++) {
		destination = [NSString stringWithFormat:@"%@-%lu", base, (unsigned long)attempt];
	}

	NSError *error = nil;
	if (![fileManager moveItemAtPath:[fileURL path] toPath:destination error:&error]) {
		NSLog(@"PostgreSQL favorites: imported \"%@\" could not be renamed: %@", [fileURL path], [error localizedDescription]);
	}
}

+ (BOOL)importFavoritesInDataFolder:(NSURL *)dataFolder
                        intoSection:(SPTreeNode *)section
                               save:(BOOL (^)(void))save
                      importedCount:(NSUInteger *)importedCount
                              error:(NSError **)error
{
	if (importedCount) *importedCount = 0;
	if (!dataFolder) return YES;

	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSURL *favoritesURL = [dataFolder URLByAppendingPathComponent:SPPostgresLegacyFavoritesFileName];
	NSURL *placementsURL = [dataFolder URLByAppendingPathComponent:SPPostgresLegacyPlacementsFileName];
	BOOL hasFavoritesFile = [fileManager fileExistsAtPath:[favoritesURL path]];
	if (!hasFavoritesFile && ![fileManager fileExistsAtPath:[placementsURL path]]) return YES;
	if (!section) return YES; // no tree to import into (Favorites.plist unreadable): try again next time

	NSArray *dictionaries = [self favoriteDictionariesInFileAtURL:favoritesURL error:error];
	if (!dictionaries) return NO;

	// The favorites not in the tree yet, in the name order the old favorites store gave the layout
	NSMutableSet *knownIDs = [NSMutableSet set];
	for (SPTreeNode *node in [section descendants]) {
		NSString *favoriteID = [SPPostgresFavoriteForNode(node) favoriteID];
		if (favoriteID) [knownIDs addObject:favoriteID];
	}
	NSMutableArray *favorites = [NSMutableArray array];
	for (NSDictionary *dictionary in dictionaries) {
		SPPostgresFavorite *favorite = [SPPostgresFavorite favoriteWithDictionary:dictionary];
		if (!favorite || ![[favorite favoriteID] length] || [knownIDs containsObject:[favorite favoriteID]]) continue;
		[knownIDs addObject:[favorite favoriteID]];
		[favorites addObject:favorite];
	}
	[favorites sortUsingComparator:^NSComparisonResult(SPPostgresFavorite *a, SPPostgresFavorite *b) {
		return [([a name] ? [a name] : @"") caseInsensitiveCompare:([b name] ? [b name] : @"")];
	}];

	if ([favorites count]) {
		NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:[favorites count]];
		for (SPPostgresFavorite *favorite in favorites) [nodes addObject:[SPPostgresFavoriteNode treeNodeWithFavorite:favorite]];

		// Where the RC builds displayed them, worked out as they did
		SPPostgresFavoritesLayout *layout = [[[SPPostgresFavoritesLayout alloc] init] autorelease];
		[layout resolveWithMySQLSection:section postgresNodes:nodes placements:[self _placementsInFileAtURL:placementsURL]];

		NSMutableArray *groups = [NSMutableArray arrayWithObject:section];
		for (SPTreeNode *node in [section descendants]) {
			if ([node isGroup]) [groups addObject:node];
		}

		// Every group's displayed children first, then the tree is changed
		NSMutableArray *changes = [NSMutableArray array];
		for (SPTreeNode *group in groups) {
			NSArray *displayed = [layout displayedChildrenOfGroup:group];
			if ([displayed count] != [[group childNodes] count]) [changes addObject:@[group, [[displayed copy] autorelease]]];
		}
		for (NSArray *change in changes) {
			NSMutableArray *children = [[change objectAtIndex:0] mutableChildNodes];
			[children removeAllObjects];
			[children addObjectsFromArray:[change objectAtIndex:1]];
		}

		if (importedCount) *importedCount = [nodes count];

		// The files stay until the tree with the favorites is on disk. The favorites stay in the tree: the next
		// save writes them, and the next import then skips them.
		if (!save || !save()) {
			if (error) {
				*error = [NSError errorWithDomain:SPPostgresFavoritesImportErrorDomain code:2 userInfo:@{
					NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The PostgreSQL favorites of \"%@\" could not be saved to the favorites file. The file was left untouched.", [favoritesURL path]]
				}];
			}
			return NO;
		}
	}

	[self _retireFileAtURL:favoritesURL];
	[self _retireFileAtURL:placementsURL];
	return YES;
}

@end
