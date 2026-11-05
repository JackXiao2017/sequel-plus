#import "SPPostgresFavoritesStore.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresFavoriteNode.h"
#import "SPFavoritesController.h"
#import "SPTreeNode.h"
#import "SPGroupNode.h"
#import "SPConstants.h"

NSString * const SPPostgresFavoritesDidChangeNotification = @"SPPostgresFavoritesDidChangeNotification";

static NSString * const SPPostgresFavoritesStoreErrorDomain = @"SPPostgresFavoritesStoreErrorDomain";

@implementation SPPostgresFavoritesStore {
	SPTreeNode *(^sectionProvider)(void);
	BOOL (^saveHandler)(void);
	NSError *(^loadErrorProvider)(void);
	SPTreeNode *inMemoryRoot; // -initInMemory only
}

- (instancetype)initWithSectionProvider:(SPTreeNode *(^)(void))theSectionProvider
                            saveHandler:(BOOL (^)(void))theSaveHandler
                      loadErrorProvider:(NSError *(^)(void))theLoadErrorProvider
{
	if ((self = [super init])) {
		sectionProvider = [theSectionProvider copy];
		saveHandler = [theSaveHandler copy];
		loadErrorProvider = [theLoadErrorProvider copy];
	}
	return self;
}

- (instancetype)initInMemory
{
	// As SPFavoritesController's tree: an invisible root whose first child is the FAVORITES section
	SPTreeNode *root = [SPTreeNode treeNodeWithRepresentedObject:[SPGroupNode groupNodeWithName:nil]];
	SPTreeNode *section = [SPTreeNode treeNodeWithRepresentedObject:[SPGroupNode groupNodeWithName:@"FAVORITES"]];
	[root setIsGroup:YES];
	[section setIsGroup:YES];
	[[root mutableChildNodes] addObject:section];

	if ((self = [self initWithSectionProvider:^SPTreeNode *{ return section; } saveHandler:^BOOL{ return YES; } loadErrorProvider:nil])) {
		inMemoryRoot = [root retain];
	}
	return self;
}

+ (instancetype)sharedStore
{
	static SPPostgresFavoritesStore *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[SPPostgresFavoritesStore alloc] initWithSectionProvider:^SPTreeNode *{
			NSArray *sections = [[[SPFavoritesController sharedFavoritesController] favoritesTree] childNodes];
			return [sections count] ? [sections objectAtIndex:0] : nil;
		} saveHandler:^BOOL{
			SPFavoritesController *controller = [SPFavoritesController sharedFavoritesController];
			[controller saveFavorites];
			// Every connection screen shows the same tree: they reload (as for a MySQL favorite added or removed)
			[[NSNotificationCenter defaultCenter] postNotificationName:SPConnectionFavoritesChangedNotification object:controller];
			return YES;
		} loadErrorProvider:^NSError *{
			return [[SPFavoritesController sharedFavoritesController] postgresFavoritesImportError];
		}];
	});
	return shared;
}

- (void)dealloc
{
	[sectionProvider release];
	[saveHandler release];
	[loadErrorProvider release];
	[inMemoryRoot release];
	[super dealloc];
}

#pragma mark - Reading

- (SPTreeNode *)section
{
	return sectionProvider ? sectionProvider() : nil;
}

- (NSArray *)favoriteNodes
{
	NSMutableArray *nodes = [NSMutableArray array];
	for (SPTreeNode *node in [[self section] descendants]) {
		if (SPPostgresFavoriteForNode(node)) [nodes addObject:node];
	}
	return nodes;
}

- (NSArray *)favorites
{
	NSMutableArray *list = [NSMutableArray array];
	for (SPTreeNode *node in [self favoriteNodes]) [list addObject:[[SPPostgresFavoriteForNode(node) copy] autorelease]];
	[list sortUsingComparator:^NSComparisonResult(SPPostgresFavorite *a, SPPostgresFavorite *b) {
		return [(a.name ? a.name : @"") caseInsensitiveCompare:(b.name ? b.name : @"")];
	}];
	return list;
}

- (SPTreeNode *)nodeForFavoriteID:(NSString *)favoriteID
{
	if (![favoriteID length]) return nil;
	for (SPTreeNode *node in [[self section] descendants]) {
		if ([[SPPostgresFavoriteForNode(node) favoriteID] isEqualToString:favoriteID]) return node;
	}
	return nil;
}

- (NSError *)lastLoadError
{
	return loadErrorProvider ? loadErrorProvider() : nil;
}

#pragma mark - Changes

/// Saves the tree; on success tells observers.
- (BOOL)_saveError:(NSError **)error
{
	if (saveHandler && !saveHandler()) {
		if (error) {
			*error = [NSError errorWithDomain:SPPostgresFavoritesStoreErrorDomain code:2 userInfo:@{
				NSLocalizedDescriptionKey: NSLocalizedString(@"The favorites could not be saved", @"PostgreSQL favorites save failed title"),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The favorites file could not be written.", @"PostgreSQL favorites save failed message")
			}];
		}
		return NO;
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritesDidChangeNotification object:self];
	return YES;
}

- (NSError *)_noTreeError
{
	return [NSError errorWithDomain:SPPostgresFavoritesStoreErrorDomain code:3 userInfo:@{
		NSLocalizedDescriptionKey: NSLocalizedString(@"The favorites could not be saved", @"PostgreSQL favorites save failed title"),
		NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The favorites could not be loaded.", @"PostgreSQL favorites: no favorites tree")
	}];
}

- (SPTreeNode *)addFavorite:(SPPostgresFavorite *)favorite toGroup:(SPTreeNode *)group atIndex:(NSUInteger)index error:(NSError **)error
{
	SPTreeNode *section = [self section];
	if (!favorite || !section) {
		if (error) *error = [self _noTreeError];
		return nil;
	}
	if (![group isKindOfClass:[SPTreeNode class]] || ![group isGroup] || SPPostgresFavoriteForNode(group)
		|| (group != section && ![[section descendants] containsObject:group])) {
		group = section;
		index = NSNotFound; // (an index in another group)
	}

	SPTreeNode *node = [SPPostgresFavoriteNode treeNodeWithFavorite:[[favorite copy] autorelease]];
	NSMutableArray *children = [group mutableChildNodes];
	[children insertObject:node atIndex:MIN(index, [children count])];

	if (![self _saveError:error]) {
		[children removeObjectIdenticalTo:node];
		return nil;
	}
	return node;
}

- (BOOL)saveFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error
{
	SPTreeNode *node = [self nodeForFavoriteID:[favorite favoriteID]];
	if (!node) return [self addFavorite:favorite toGroup:nil atIndex:NSNotFound error:error] != nil;

	SPPostgresFavoriteNode *represented = [node representedObject];
	SPPostgresFavorite *previous = [[[represented favorite] retain] autorelease];
	[represented setFavorite:[[favorite copy] autorelease]];

	if (![self _saveError:error]) {
		[represented setFavorite:previous];
		return NO;
	}
	return YES;
}

- (BOOL)removeFavoriteWithID:(NSString *)favoriteID error:(NSError **)error
{
	SPTreeNode *node = [[[self nodeForFavoriteID:favoriteID] retain] autorelease];
	if (!node) return YES;

	SPTreeNode *parent = (SPTreeNode *)[node parentNode];
	NSMutableArray *siblings = [parent mutableChildNodes];
	NSUInteger index = [siblings indexOfObjectIdenticalTo:node];
	[siblings removeObjectAtIndex:index];

	if (![self _saveError:error]) {
		[siblings insertObject:node atIndex:index];
		return NO;
	}
	return YES;
}

@end
