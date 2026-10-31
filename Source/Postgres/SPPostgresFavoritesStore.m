#import "SPPostgresFavoritesStore.h"
#import "SPPostgresFavorite.h"

NSString * const SPPostgresFavoritesDidChangeNotification = @"SPPostgresFavoritesDidChangeNotification";

@implementation SPPostgresFavoritesStore {
	NSURL *fileURL;
	NSError *lastLoadError;
}

- (instancetype)initWithFileURL:(NSURL *)url
{
	if ((self = [super init])) {
		fileURL = [url copy];
	}
	return self;
}

- (NSURL *)fileURL
{
	return fileURL;
}

+ (instancetype)sharedStore
{
	static SPPostgresFavoritesStore *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
																inDomain:NSUserDomainMask
													   appropriateForURL:nil
																  create:NO
																   error:NULL];
		if (!support) support = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] isDirectory:YES];
		NSURL *url = [[[support URLByAppendingPathComponent:@"Sequel Pro" isDirectory:YES]
			URLByAppendingPathComponent:@"Data" isDirectory:YES] URLByAppendingPathComponent:@"PostgresFavorites.plist"];
		shared = [[SPPostgresFavoritesStore alloc] initWithFileURL:url];
	});
	return shared;
}

- (void)dealloc
{
	[fileURL release];
	[lastLoadError release];
	[super dealloc];
}

// Returns the raw stored dictionaries (unsorted). A missing file yields an empty array.
// Returns nil (with *error set) if the file exists but is unreadable, corrupt, not the expected
// structure, or has a newer version than this code understands.
- (NSMutableArray *)loadRawFavoritesError:(NSError **)error
{
	NSMutableArray *result = [NSMutableArray array];
	if (![fileURL checkResourceIsReachableAndReturnError:NULL]) return result;

	NSString *problem = nil;
	NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:fileURL];
	if (![root isKindOfClass:[NSDictionary class]]) {
		problem = @"The file could not be read or is not a valid favorites property list.";
	} else {
		id version = [root objectForKey:@"version"];
		id items = [root objectForKey:@"favorites"];
		if (![version isKindOfClass:[NSNumber class]] || ![items isKindOfClass:[NSArray class]]) {
			problem = @"The file does not have the expected structure.";
		} else if ([version integerValue] > 1) {
			problem = [NSString stringWithFormat:@"The file uses version %@, which is newer than this version of the application supports.", version];
		} else {
			for (id item in items) {
				if ([item isKindOfClass:[NSDictionary class]]) [result addObject:item];
			}
		}
	}
	if (problem) {
		if (error) {
			*error = [NSError errorWithDomain:@"SPPostgresFavoritesStoreErrorDomain" code:1 userInfo:
				[NSDictionary dictionaryWithObjectsAndKeys:
					[NSString stringWithFormat:@"Cannot use PostgreSQL favorites file \"%@\". %@ It was left untouched.", [fileURL path], problem], NSLocalizedDescriptionKey, nil]];
		}
		return nil;
	}
	return result;
}

- (NSError *)lastLoadError
{
	return [[lastLoadError retain] autorelease];
}

- (NSArray *)favorites
{
	NSError *error = nil;
	NSArray *raw = [self loadRawFavoritesError:&error];
	[lastLoadError release];
	lastLoadError = raw ? nil : [error retain];

	NSMutableArray *list = [NSMutableArray array];
	for (NSDictionary *d in raw ?: @[]) {
		SPPostgresFavorite *f = [SPPostgresFavorite favoriteWithDictionary:d];
		if (f) [list addObject:f];
	}
	[list sortUsingComparator:^NSComparisonResult(SPPostgresFavorite *a, SPPostgresFavorite *b) {
		return [(a.name ? a.name : @"") caseInsensitiveCompare:(b.name ? b.name : @"")];
	}];
	return list;
}

- (BOOL)writeRawFavorites:(NSArray *)raw error:(NSError **)error
{
	NSError *dirError = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtURL:[fileURL URLByDeletingLastPathComponent]
									withIntermediateDirectories:YES
													 attributes:nil
														  error:&dirError]) {
		if (error) *error = dirError;
		return NO;
	}

	NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:@1, @"version", raw, @"favorites", nil];
	BOOL ok;
	if (@available(macOS 10.13, *)) {
		ok = [root writeToURL:fileURL error:error];  // atomic
	} else {
		ok = [root writeToURL:fileURL atomically:YES];
		if (!ok && error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
	}
	if (ok) {
		[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritesDidChangeNotification object:self];
	}
	return ok;
}

- (BOOL)saveFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error
{
	NSMutableArray *raw = [self loadRawFavoritesError:error];
	if (!raw) return NO;
	NSDictionary *dict = [favorite dictionaryRepresentation];
	NSUInteger index = NSNotFound;
	for (NSUInteger i = 0; i < [raw count]; i++) {
		if ([[[raw objectAtIndex:i] objectForKey:@"id"] isEqual:favorite.favoriteID]) { index = i; break; }
	}
	if (index == NSNotFound) [raw addObject:dict];
	else [raw replaceObjectAtIndex:index withObject:dict];
	return [self writeRawFavorites:raw error:error];
}

- (BOOL)removeFavoriteWithID:(NSString *)favoriteID error:(NSError **)error
{
	NSMutableArray *raw = [self loadRawFavoritesError:error];
	if (!raw) return NO;
	NSIndexSet *matches = [raw indexesOfObjectsPassingTest:^BOOL(NSDictionary *d, NSUInteger idx, BOOL *stop) {
		return [[d objectForKey:@"id"] isEqual:favoriteID];
	}];
	[raw removeObjectsAtIndexes:matches];
	return [self writeRawFavorites:raw error:error];
}

@end
