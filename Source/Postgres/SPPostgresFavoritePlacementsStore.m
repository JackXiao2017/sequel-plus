#import "SPPostgresFavoritePlacementsStore.h"
#import "SPPostgresFavoritesStore.h"

NSString * const SPPostgresFavoritePlacementsDidChangeNotification = @"SPPostgresFavoritePlacementsDidChangeNotification";

@implementation SPPostgresFavoritePlacementsStore {
	NSURL *fileURL;
}

- (instancetype)initWithFileURL:(NSURL *)url
{
	if ((self = [super init])) {
		fileURL = [url copy];
	}
	return self;
}

+ (instancetype)storeBesideFavoritesStore:(SPPostgresFavoritesStore *)favoritesStore
{
	NSURL *url = [[[favoritesStore fileURL] URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"PostgresFavoritePlacements.plist"];
	return [[[self alloc] initWithFileURL:url] autorelease];
}

- (void)dealloc
{
	[fileURL release];
	[super dealloc];
}

// Returns the stored placements (empty when the file is missing). Returns nil (with *error set) when the
// file exists but is unreadable, malformed or newer than this code understands.
- (NSDictionary *)loadPlacementsError:(NSError **)error
{
	if (![fileURL checkResourceIsReachableAndReturnError:NULL]) return [NSDictionary dictionary];

	NSString *problem = nil;
	NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:fileURL];
	if (![root isKindOfClass:[NSDictionary class]]) {
		problem = @"The file could not be read or is not a valid placements property list.";
	} else {
		id version = [root objectForKey:@"Version"];
		id items = [root objectForKey:@"Placements"];
		if (![version isKindOfClass:[NSNumber class]] || ![items isKindOfClass:[NSDictionary class]]) {
			problem = @"The file does not have the expected structure.";
		} else if ([version integerValue] > 1) {
			problem = [NSString stringWithFormat:@"The file uses version %@, which is newer than this version of the application supports.", version];
		} else {
			return items;
		}
	}
	if (error) {
		*error = [NSError errorWithDomain:@"SPPostgresFavoritePlacementsStoreErrorDomain" code:1 userInfo:
			[NSDictionary dictionaryWithObjectsAndKeys:
				[NSString stringWithFormat:@"Cannot use PostgreSQL favorite placements file \"%@\". %@ It was left untouched.", [fileURL path], problem], NSLocalizedDescriptionKey, nil]];
	}
	return nil;
}

- (NSDictionary *)placements
{
	return [self loadPlacementsError:NULL] ?: [NSDictionary dictionary];
}

- (BOOL)setPlacements:(NSDictionary *)placements error:(NSError **)error
{
	if (![self loadPlacementsError:error]) return NO;

	NSError *dirError = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtURL:[fileURL URLByDeletingLastPathComponent]
									withIntermediateDirectories:YES
													 attributes:nil
														  error:&dirError]) {
		if (error) *error = dirError;
		return NO;
	}

	NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:@1, @"Version", placements ?: @{}, @"Placements", nil];
	BOOL ok;
	if (@available(macOS 10.13, *)) {
		ok = [root writeToURL:fileURL error:error];  // atomic
	} else {
		ok = [root writeToURL:fileURL atomically:YES];
		if (!ok && error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
	}
	if (ok) {
		[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresFavoritePlacementsDidChangeNotification object:self];
	}
	return ok;
}

@end
