#import "SPPostgresQueryStore.h"

NSString * const SPPostgresQueryStoreDidChangeNotification = @"SPPostgresQueryStoreDidChangeNotification";

// The file's format: @{@"version": @1, @"items": @[…]}
static const NSInteger SPPostgresQueryStoreVersion = 1;

@implementation SPPostgresQueryStore {
	NSURL *fileURL;
	NSError *lastLoadError;
	NSArray *items;               // the last items read or written
	NSDictionary *loadedSignature; // the file's modification date and size when items was read (nil: no file)
	BOOL loaded;
}

@synthesize fileURL;

- (instancetype)initWithFileURL:(NSURL *)url
{
	if ((self = [super init])) {
		fileURL = [url copy];
		items = [@[] retain];
	}
	return self;
}

+ (NSURL *)_dataFileURLNamed:(NSString *)name
{
	NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
															inDomain:NSUserDomainMask
												   appropriateForURL:nil
															  create:NO
															   error:NULL];
	if (!support) support = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] isDirectory:YES];
	return [[[support URLByAppendingPathComponent:@"Sequel Pro" isDirectory:YES]
		URLByAppendingPathComponent:@"Data" isDirectory:YES] URLByAppendingPathComponent:name];
}

+ (instancetype)sharedHistoryStore
{
	static SPPostgresQueryStore *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[SPPostgresQueryStore alloc] initWithFileURL:[self _dataFileURLNamed:@"PostgresQueryHistory.plist"]];
	});
	return shared;
}

+ (instancetype)sharedFavoritesStore
{
	static SPPostgresQueryStore *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[SPPostgresQueryStore alloc] initWithFileURL:[self _dataFileURLNamed:@"PostgresQueryFavorites.plist"]];
	});
	return shared;
}

- (void)dealloc
{
	[fileURL release];
	[lastLoadError release];
	[items release];
	[loadedSignature release];
	[super dealloc];
}

/// The file's modification date and size, or nil when there is no file.
- (NSDictionary *)_fileSignature
{
	NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[fileURL path] error:NULL];
	if (!attributes) return nil;
	return @{@"date": [attributes fileModificationDate] ?: [NSDate distantPast], @"size": @([attributes fileSize])};
}

/// The stored items, or nil (with *error set) when the file exists but is unreadable, corrupt, not the expected
/// structure, or of a newer version. A missing file gives no items.
- (NSArray *)_readItemsError:(NSError **)error
{
	if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) return @[];

	NSString *problem = nil;
	NSArray *result = nil;
	NSData *data = [NSData dataWithContentsOfURL:fileURL];
	id root = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
	if (![root isKindOfClass:[NSDictionary class]]) {
		problem = NSLocalizedString(@"The file could not be read or is not a valid property list.", @"Postgres query store: unreadable file");
	}
	else {
		id version = [root objectForKey:@"version"];
		id list = [root objectForKey:@"items"];
		if (![version isKindOfClass:[NSNumber class]] || ![list isKindOfClass:[NSArray class]]) {
			problem = NSLocalizedString(@"The file does not have the expected structure.", @"Postgres query store: bad structure");
		}
		else if ([version integerValue] > SPPostgresQueryStoreVersion) {
			problem = [NSString stringWithFormat:NSLocalizedString(@"The file uses version %@, which is newer than this version of the application supports.", @"Postgres query store: newer version"), version];
		}
		else {
			result = list;
		}
	}
	if (problem) {
		if (error) {
			*error = [NSError errorWithDomain:@"SPPostgresQueryStoreErrorDomain" code:1 userInfo:@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Cannot use the file \"%@\". %@ It was left untouched.", @"Postgres query store: load error"), [fileURL path], problem]
			}];
		}
		return nil;
	}
	return result;
}

/// Reads the file when it changed since it was last read (or written).
- (void)_reloadIfNeeded
{
	NSDictionary *signature = [self _fileSignature];
	if (loaded && (signature == loadedSignature || [signature isEqual:loadedSignature])) return;

	NSError *error = nil;
	NSArray *read = [self _readItemsError:&error];
	[lastLoadError release];
	lastLoadError = read ? nil : [error retain];
	[items release];
	items = [(read ?: @[]) copy];
	[loadedSignature release];
	loadedSignature = [signature retain];
	loaded = YES;
}

- (NSArray *)items
{
	[self _reloadIfNeeded];
	return [[items retain] autorelease];
}

- (NSError *)lastLoadError
{
	[self _reloadIfNeeded];
	return [[lastLoadError retain] autorelease];
}

- (BOOL)setItems:(NSArray *)newItems error:(NSError **)error
{
	// Never overwrite a file this code could not read (corrupt, or written by a newer version)
	NSError *readError = nil;
	if (![self _readItemsError:&readError]) {
		if (error) *error = readError;
		return NO;
	}

	NSError *dirError = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtURL:[fileURL URLByDeletingLastPathComponent]
								  withIntermediateDirectories:YES
												   attributes:nil
														error:&dirError]) {
		if (error) *error = dirError;
		return NO;
	}

	NSDictionary *root = @{@"version": @(SPPostgresQueryStoreVersion), @"items": newItems ?: @[]};
	NSError *writeError = nil;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListXMLFormat_v1_0 options:0 error:&writeError];
	if (!data || ![data writeToURL:fileURL options:NSDataWritingAtomic error:&writeError]) {
		if (error) *error = writeError;
		return NO;
	}

	[items release];
	items = [(newItems ?: @[]) copy];
	[lastLoadError release];
	lastLoadError = nil;
	[loadedSignature release];
	loadedSignature = [[self _fileSignature] retain];
	loaded = YES;

	[[NSNotificationCenter defaultCenter] postNotificationName:SPPostgresQueryStoreDidChangeNotification object:self];
	return YES;
}

@end
