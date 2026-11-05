#import "SPSequelPlusMigration.h"
#import "SPKeychain.h"
#import <Security/Security.h>

NSString * const SPSequelPlusSupportFolderName = @"Sequel Plus";
NSString * const SPSequelProSupportFolderName = @"Sequel Pro";
NSString * const SPSequelProBundleIdentifier = @"com.sequelpro.SequelPro";
NSString * const SPSequelPlusMigratedFromSequelProKey = @"SequelPlusMigratedFromSequelPro";

BOOL SPSequelPlusIsRunningTests(void)
{
	return [[[NSProcessInfo processInfo] environment] objectForKey:@"XCTestConfigurationFilePath"] != nil || NSClassFromString(@"XCTestCase") != nil;
}

NSURL *SPSequelPlusApplicationSupportURL(void)
{
	if (SPSequelPlusIsRunningTests()) {
		static NSURL *testSupport = nil;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"SequelPlusTestSupport-%d", [[NSProcessInfo processInfo] processIdentifier]]];
			testSupport = [[NSURL fileURLWithPath:path isDirectory:YES] retain];
		});
		return testSupport;
	}
	NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:NULL];
	if (!support) support = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] isDirectory:YES];
	return support;
}

NSURL *SPSequelPlusSupportDirectoryURL(void)
{
	return [SPSequelPlusApplicationSupportURL() URLByAppendingPathComponent:SPSequelPlusSupportFolderName isDirectory:YES];
}

/// The four kinds of keychain item names the app writes: Sequel Pro's prefix and Sequel Plus's, in matching order
/// (longest first, so "Sequel Pro (PostgreSQL) SSHTunnel : " isn't taken for "Sequel Pro (PostgreSQL) : ").
static NSArray *SPSequelProKeychainPrefixes(void)
{
	return @[@"Sequel Pro (PostgreSQL) SSHTunnel : ", @"Sequel Pro (PostgreSQL) : ", @"Sequel Pro SSHTunnel : ", @"Sequel Pro : "];
}

#pragma mark - The real keychain

@interface SPSequelPlusSystemKeychain : NSObject <SPSequelPlusMigrationKeychain>
@end

@implementation SPSequelPlusSystemKeychain {
	SPKeychain *keychain;
}

- (instancetype)init
{
	if ((self = [super init])) keychain = [[SPKeychain alloc] init];
	return self;
}

- (void)dealloc
{
	[keychain release];
	[super dealloc];
}

- (NSArray *)itemsWithNamePrefixes:(NSArray *)prefixes
{
	// Attributes only: listing doesn't read any password, so it doesn't prompt
	NSDictionary *query = @{(id)kSecClass: (id)kSecClassGenericPassword,
	                        (id)kSecMatchLimit: (id)kSecMatchLimitAll,
	                        (id)kSecReturnAttributes: @YES};
	CFTypeRef result = NULL;
	if (SecItemCopyMatching((CFDictionaryRef)query, &result) != errSecSuccess || !result) return @[];

	NSMutableArray *items = [NSMutableArray array];
	for (NSDictionary *attributes in (NSArray *)result) {
		NSString *name = [attributes objectForKey:(id)kSecAttrService];
		NSString *account = [attributes objectForKey:(id)kSecAttrAccount];
		if (![name isKindOfClass:[NSString class]] || ![account isKindOfClass:[NSString class]]) continue;
		for (NSString *prefix in prefixes) {
			if ([name hasPrefix:prefix]) {
				[items addObject:@{@"name": name, @"account": account}];
				break;
			}
		}
	}
	CFRelease(result);
	return items;
}

- (NSString *)getPasswordForName:(NSString *)name account:(NSString *)account
{
	return [keychain getPasswordForName:name account:account];
}

- (BOOL)passwordExistsForName:(NSString *)name account:(NSString *)account
{
	return [keychain passwordExistsForName:name account:account];
}

- (void)addPassword:(NSString *)password forName:(NSString *)name account:(NSString *)account
{
	[keychain addPassword:password forName:name account:account];
}

@end

#pragma mark - Migration

@implementation SPSequelPlusMigration {
	NSURL *supportDirectory;
	NSUserDefaults *preferences;
	NSDictionary *oldPreferences;
	id<SPSequelPlusMigrationKeychain> keychain;
}

- (instancetype)initWithSupportDirectory:(NSURL *)theSupportDirectory preferences:(NSUserDefaults *)thePreferences oldPreferences:(NSDictionary *)theOldPreferences keychain:(id<SPSequelPlusMigrationKeychain>)theKeychain
{
	if ((self = [super init])) {
		supportDirectory = [theSupportDirectory copy];
		preferences = [thePreferences retain];
		oldPreferences = [theOldPreferences copy];
		keychain = [theKeychain retain];
	}
	return self;
}

- (void)dealloc
{
	[supportDirectory release];
	[preferences release];
	[oldPreferences release];
	[keychain release];
	[super dealloc];
}

- (NSURL *)_folderNamed:(NSString *)name
{
	return [supportDirectory URLByAppendingPathComponent:name isDirectory:YES];
}

- (BOOL)isNeeded
{
	if ([preferences boolForKey:SPSequelPlusMigratedFromSequelProKey]) return NO;
	return ![[NSFileManager defaultManager] fileExistsAtPath:[[self _folderNamed:SPSequelPlusSupportFolderName] path]];
}

+ (NSString *)sequelPlusNameForSequelProName:(NSString *)name
{
	for (NSString *prefix in SPSequelProKeychainPrefixes()) {
		if ([name hasPrefix:prefix]) {
			NSString *newPrefix = [prefix stringByReplacingOccurrencesOfString:@"Sequel Pro" withString:@"Sequel Plus" options:NSAnchoredSearch range:NSMakeRange(0, [prefix length])];
			return [newPrefix stringByAppendingString:[name substringFromIndex:[prefix length]]];
		}
	}
	return nil;
}

- (void)_copyPreferences
{
	for (NSString *key in oldPreferences) {
		// Sequel Pro's value wins: before the first run Sequel Plus's domain holds nothing the owner chose (at most
		// what a test run left)
		if ([key isEqualToString:SPSequelPlusMigratedFromSequelProKey]) continue;
		[preferences setObject:[oldPreferences objectForKey:key] forKey:key];
	}
}

- (void)_copyFolder
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSURL *source = [self _folderNamed:SPSequelProSupportFolderName];
	NSURL *target = [self _folderNamed:SPSequelPlusSupportFolderName];
	if (![manager fileExistsAtPath:[source path]] || [manager fileExistsAtPath:[target path]]) return;

	NSError *error = nil;
	if (![manager copyItemAtURL:source toURL:target error:&error]) {
		NSLog(@"Sequel Plus: could not copy %@ to %@: %@", [source path], [target path], [error localizedDescription]);
	}
}

- (void)_copyKeychainItems
{
	for (NSDictionary *item in [keychain itemsWithNamePrefixes:SPSequelProKeychainPrefixes()]) {
		NSString *name = item[@"name"];
		NSString *account = item[@"account"];
		NSString *newName = [[self class] sequelPlusNameForSequelProName:name];
		if (!newName || [keychain passwordExistsForName:newName account:account]) continue;

		NSString *password = [keychain getPasswordForName:name account:account];
		if (![password length]) continue; // not allowed, or empty
		[keychain addPassword:password forName:newName account:account];
	}
}

- (BOOL)migrateIfNeeded
{
	if (![self isNeeded]) return NO;

	[self _copyPreferences];
	[self _copyFolder];
	[self _copyKeychainItems];

	[preferences setBool:YES forKey:SPSequelPlusMigratedFromSequelProKey];
	[preferences synchronize];
	return YES;
}

+ (void)migrateAtLaunch
{
	// The test bundle runs inside the app: never on the real data then
	if (SPSequelPlusIsRunningTests()) return;

	NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
	NSURL *support = [SPSequelPlusSupportDirectoryURL() URLByDeletingLastPathComponent];
	NSDictionary *old = [preferences persistentDomainForName:SPSequelProBundleIdentifier];
	SPSequelPlusSystemKeychain *systemKeychain = [[[SPSequelPlusSystemKeychain alloc] init] autorelease];
	SPSequelPlusMigration *migration = [[[SPSequelPlusMigration alloc] initWithSupportDirectory:support preferences:preferences oldPreferences:old keychain:systemKeychain] autorelease];
	[migration migrateIfNeeded];
}

@end
