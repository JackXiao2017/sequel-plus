#import "SPQueryScriptStore.h"
#import <CommonCrypto/CommonDigest.h>

NSString * const SPQueryScriptEngineMySQL = @"mysql";
NSString * const SPQueryScriptEnginePostgreSQL = @"postgresql";

static NSString *SPQueryScriptPart(NSString *value)
{
	NSString *trimmed = [value isKindOfClass:[NSString class]] ? [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
	// "|" separates the parts: escaped so two different detail sets can't make the same key
	return [[trimmed stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"|" withString:@"\\|"];
}

@implementation SPQueryScriptStore

@synthesize directoryURL;

+ (instancetype)sharedStore
{
	static SPQueryScriptStore *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:NULL];
		if (!support) support = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] isDirectory:YES];
		NSURL *directory = [[[support URLByAppendingPathComponent:@"Sequel Pro" isDirectory:YES]
			URLByAppendingPathComponent:@"Data" isDirectory:YES] URLByAppendingPathComponent:@"Query Scripts" isDirectory:YES];
		shared = [[SPQueryScriptStore alloc] initWithDirectoryURL:directory];
	});
	return shared;
}

- (instancetype)initWithDirectoryURL:(NSURL *)url
{
	if ((self = [super init])) {
		directoryURL = [url copy];
	}
	return self;
}

- (void)dealloc
{
	[directoryURL release];
	[super dealloc];
}

- (NSURL *)fileURLForKey:(NSString *)key
{
	NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256([data bytes], (CC_LONG)[data length], digest);
	NSMutableString *name = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2 + 4];
	for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [name appendFormat:@"%02x", digest[i]];
	[name appendString:@".sql"];
	return [directoryURL URLByAppendingPathComponent:name isDirectory:NO];
}

- (NSString *)scriptForKey:(NSString *)key
{
	if (![key length]) return nil;
	NSData *data = [NSData dataWithContentsOfURL:[self fileURLForKey:key]];
	if (!data) return nil;
	NSString *script = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	return [script length] ? script : nil;
}

- (BOOL)saveScript:(NSString *)script forKey:(NSString *)key error:(NSError **)error
{
	if (![key length]) return NO;
	NSURL *fileURL = [self fileURLForKey:key];
	NSFileManager *manager = [NSFileManager defaultManager];

	if (![script length]) {
		if (![manager fileExistsAtPath:[fileURL path]]) return YES;
		return [manager removeItemAtURL:fileURL error:error];
	}

	if (![manager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:error]) return NO;
	return [[script dataUsingEncoding:NSUTF8StringEncoding] writeToURL:fileURL options:NSDataWritingAtomic error:error];
}

+ (NSString *)keyForEngine:(NSString *)engine favoriteID:(NSString *)favoriteID
{
	if (![favoriteID length]) return nil;
	return [NSString stringWithFormat:@"%@|favorite|%@", SPQueryScriptPart(engine), SPQueryScriptPart(favoriteID)];
}

+ (NSString *)keyForEngine:(NSString *)engine type:(NSInteger)type host:(NSString *)host port:(NSString *)port user:(NSString *)user socket:(NSString *)socket sshHost:(NSString *)sshHost sshUser:(NSString *)sshUser
{
	return [@[SPQueryScriptPart(engine), @"server", [NSString stringWithFormat:@"%ld", (long)type],
	          [SPQueryScriptPart(host) lowercaseString], SPQueryScriptPart(port), SPQueryScriptPart(user),
	          SPQueryScriptPart(socket), [SPQueryScriptPart(sshHost) lowercaseString], SPQueryScriptPart(sshUser)]
	        componentsJoinedByString:@"|"];
}

@end

@implementation SPQueryScriptAutosaver {
	SPQueryScriptStore *store;
	BOOL edited;
	BOOL loading;
}

@synthesize key, textView, delay;

- (instancetype)initWithTextView:(NSTextView *)theTextView store:(SPQueryScriptStore *)theStore key:(NSString *)theKey
{
	if ((self = [super init])) {
		textView = theTextView; // not retained: the owner invalidates this before the editor goes
		store = [theStore retain];
		key = [theKey copy];
		delay = 1.0;
		if (textView && [key length]) {
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_textDidChange:) name:NSTextDidChangeNotification object:textView];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
		}
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];
	[store release];
	[key release];
	[super dealloc];
}

- (void)_textDidChange:(NSNotification *)notification
{
	if (loading) return;
	edited = YES;
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveIfEdited) object:nil];
	[self performSelector:@selector(saveIfEdited) withObject:nil afterDelay:delay inModes:@[NSRunLoopCommonModes]];
}

- (void)_applicationWillTerminate:(NSNotification *)notification
{
	[self saveIfEdited];
}

- (BOOL)loadIntoEmptyEditorUsing:(void (^)(NSString *script))insert
{
	if (!textView || [[textView string] length]) return NO;
	NSString *script = [store scriptForKey:key];
	if (![script length]) return NO;

	loading = YES;
	if (insert) insert(script);
	else [textView setString:script];
	loading = NO;
	return YES;
}

- (void)saveIfEdited
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveIfEdited) object:nil];
	if (!edited || !textView) return;
	edited = NO;

	NSError *error = nil;
	if (![store saveScript:[[[textView string] copy] autorelease] forKey:key error:&error]) {
		NSLog(@"The Query editor's text could not be saved: %@", error ? [error localizedDescription] : @"no key");
	}
}

- (void)invalidate
{
	if (!textView) return;
	[self saveIfEdited];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	textView = nil;
}

@end
