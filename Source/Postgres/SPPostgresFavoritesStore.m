#import "SPPostgresFavoritesStore.h"
#import "SPPostgresFavorite.h"

NSString * const SPPostgresFavoritesDidChangeNotification = @"SPPostgresFavoritesDidChangeNotification";

@implementation SPPostgresFavoritesStore {
	NSURL *fileURL;
}

- (instancetype)initWithFileURL:(NSURL *)url
{
	if ((self = [super init])) {
		fileURL = [url copy];
	}
	return self;
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
	[super dealloc];
}

// Returns the raw stored dictionaries (unsorted); empty if file is missing or unreadable.
- (NSMutableArray *)loadRawFavorites
{
	NSMutableArray *result = [NSMutableArray array];
	NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:fileURL];
	NSArray *items = [root isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"favorites"] : nil;
	if ([items isKindOfClass:[NSArray class]]) {
		for (id item in items) {
			if ([item isKindOfClass:[NSDictionary class]]) [result addObject:item];
		}
	}
	return result;
}

- (NSArray *)favorites
{
	NSMutableArray *list = [NSMutableArray array];
	for (NSDictionary *d in [self loadRawFavorites]) {
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
	NSMutableArray *raw = [self loadRawFavorites];
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
	NSMutableArray *raw = [self loadRawFavorites];
	NSIndexSet *matches = [raw indexesOfObjectsPassingTest:^BOOL(NSDictionary *d, NSUInteger idx, BOOL *stop) {
		return [[d objectForKey:@"id"] isEqual:favoriteID];
	}];
	[raw removeObjectsAtIndexes:matches];
	return [self writeRawFavorites:raw error:error];
}

@end
