#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPSequelPlusMigration.h"

/// Preferences in memory only: nothing reaches a preferences file.
@interface SPMigrationTestDefaults : NSUserDefaults
@property (strong) NSMutableDictionary *values;
@property (assign) NSUInteger syncs;
@end

@implementation SPMigrationTestDefaults
- (instancetype)init
{
	if ((self = [super initWithSuiteName:@"SPMigrationTestDefaults.unused"])) _values = [NSMutableDictionary dictionary];
	return self;
}
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { if (value) self.values[key] = value; else [self.values removeObjectForKey:key]; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
- (BOOL)synchronize { self.syncs++; return YES; }
@end

/// An in-memory keychain; reads are counted (each would be a macOS prompt).
@interface SPMigrationTestKeychain : NSObject <SPSequelPlusMigrationKeychain>
@property (strong) NSMutableDictionary<NSString *, NSString *> *items; // "name|account" -> password
@property (assign) NSUInteger reads;
@end

@implementation SPMigrationTestKeychain
- (instancetype)init { if ((self = [super init])) _items = [NSMutableDictionary dictionary]; return self; }
- (NSString *)k:(NSString *)name account:(NSString *)account { return [NSString stringWithFormat:@"%@|%@", name, account]; }
- (NSArray *)itemsWithNamePrefixes:(NSArray *)prefixes
{
	NSMutableArray *found = [NSMutableArray array];
	for (NSString *key in self.items) {
		NSArray *parts = [key componentsSeparatedByString:@"|"];
		for (NSString *prefix in prefixes) {
			if ([parts[0] hasPrefix:prefix]) { [found addObject:@{@"name": parts[0], @"account": parts[1]}]; break; }
		}
	}
	return found;
}
- (NSString *)getPasswordForName:(NSString *)name account:(NSString *)account { self.reads++; return self.items[[self k:name account:account]]; }
- (BOOL)passwordExistsForName:(NSString *)name account:(NSString *)account { return self.items[[self k:name account:account]] != nil; }
- (void)addPassword:(NSString *)password forName:(NSString *)name account:(NSString *)account { self.items[[self k:name account:account]] = password; }
@end

@interface SPSequelPlusMigrationTests : XCTestCase
@property (strong) NSURL *support;
@property (strong) SPMigrationTestDefaults *defaults;
@property (strong) SPMigrationTestKeychain *keychain;
@end

@implementation SPSequelPlusMigrationTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.support = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"SPSequelPlusMigrationTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]]] isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:self.support withIntermediateDirectories:YES attributes:nil error:nil];
	self.defaults = [[SPMigrationTestDefaults alloc] init];
	self.keychain = [[SPMigrationTestKeychain alloc] init];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtURL:self.support error:nil];
}

- (NSURL *)folder:(NSString *)name { return [self.support URLByAppendingPathComponent:name isDirectory:YES]; }

- (void)write:(NSString *)text to:(NSString *)relativePath inFolder:(NSString *)folder
{
	NSURL *url = [[self folder:folder] URLByAppendingPathComponent:relativePath];
	[[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
	XCTAssertTrue([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}

- (NSString *)read:(NSString *)relativePath inFolder:(NSString *)folder
{
	return [NSString stringWithContentsOfURL:[[self folder:folder] URLByAppendingPathComponent:relativePath] encoding:NSUTF8StringEncoding error:nil];
}

- (SPSequelPlusMigration *)migrationWithOldPreferences:(NSDictionary *)old
{
	return [[SPSequelPlusMigration alloc] initWithSupportDirectory:self.support preferences:self.defaults oldPreferences:old keychain:self.keychain];
}

- (void)testNames
{
	XCTAssertEqualObjects(SPSequelPlusSupportFolderName, @"Sequel Plus");
	XCTAssertEqualObjects([SPSequelPlusSupportDirectoryURL() lastPathComponent], @"Sequel Plus");
	XCTAssertEqualObjects([[NSBundle mainBundle] bundleIdentifier], @"com.sequelplus.SequelPlus", @"the app's new ID");

	XCTAssertEqualObjects([SPSequelPlusMigration sequelPlusNameForSequelProName:@"Sequel Pro : Prod (12)"], @"Sequel Plus : Prod (12)");
	XCTAssertEqualObjects([SPSequelPlusMigration sequelPlusNameForSequelProName:@"Sequel Pro SSHTunnel : Prod (12)"], @"Sequel Plus SSHTunnel : Prod (12)");
	XCTAssertEqualObjects([SPSequelPlusMigration sequelPlusNameForSequelProName:@"Sequel Pro (PostgreSQL) : PG (A-1)"], @"Sequel Plus (PostgreSQL) : PG (A-1)");
	XCTAssertEqualObjects([SPSequelPlusMigration sequelPlusNameForSequelProName:@"Sequel Pro (PostgreSQL) SSHTunnel : Sequel Pro (A-1)"], @"Sequel Plus (PostgreSQL) SSHTunnel : Sequel Pro (A-1)", @"only the prefix changes");
	XCTAssertNil([SPSequelPlusMigration sequelPlusNameForSequelProName:@"Sequel Pro Helper"]);
	XCTAssertNil([SPSequelPlusMigration sequelPlusNameForSequelProName:@"Something else"]);
}

- (void)testFirstRunCopiesFolderPreferencesAndKeychainLeavingSequelProAlone
{
	[self write:@"<favorites/>" to:@"Data/Favorites.plist" inFolder:@"Sequel Pro"];
	[self write:@"theme" to:@"Themes/Mine.spTheme" inFolder:@"Sequel Pro"];
	self.keychain.items[@"Sequel Pro : Prod (12)|root@db/app"] = @"mysql-secret";
	self.keychain.items[@"Sequel Pro SSHTunnel : Prod (12)|me@bastion"] = @"ssh-secret";
	self.keychain.items[@"Sequel Pro (PostgreSQL) : PG (A-1)|pg@db/app"] = @"pg-secret";
	self.keychain.items[@"Other App : x|y"] = @"not ours";
	NSDictionary *keychainBefore = [self.keychain.items copy];

	SPSequelPlusMigration *migration = [self migrationWithOldPreferences:@{@"CustomQueryEditorFont": @"Menlo", @"ShowNoAffectedRowsError": @YES}];
	XCTAssertTrue([migration isNeeded]);
	XCTAssertTrue([migration migrateIfNeeded]);

	// Folder: copied; Sequel Pro's still there, unchanged
	XCTAssertEqualObjects([self read:@"Data/Favorites.plist" inFolder:@"Sequel Plus"], @"<favorites/>");
	XCTAssertEqualObjects([self read:@"Themes/Mine.spTheme" inFolder:@"Sequel Plus"], @"theme");
	XCTAssertEqualObjects([self read:@"Data/Favorites.plist" inFolder:@"Sequel Pro"], @"<favorites/>");

	// Preferences: copied, and the mark set
	XCTAssertEqualObjects([self.defaults objectForKey:@"CustomQueryEditorFont"], @"Menlo");
	XCTAssertEqualObjects([self.defaults objectForKey:@"ShowNoAffectedRowsError"], @YES);
	XCTAssertTrue([self.defaults boolForKey:SPSequelPlusMigratedFromSequelProKey]);

	// Keychain: a Sequel Plus copy of each of the app's items, same account; the originals kept, others ignored
	XCTAssertEqualObjects(self.keychain.items[@"Sequel Plus : Prod (12)|root@db/app"], @"mysql-secret");
	XCTAssertEqualObjects(self.keychain.items[@"Sequel Plus SSHTunnel : Prod (12)|me@bastion"], @"ssh-secret");
	XCTAssertEqualObjects(self.keychain.items[@"Sequel Plus (PostgreSQL) : PG (A-1)|pg@db/app"], @"pg-secret");
	XCTAssertNil(self.keychain.items[@"Other App : x|y"] ? nil : @"gone");
	for (NSString *key in keychainBefore) XCTAssertEqualObjects(self.keychain.items[key], keychainBefore[key], @"%@", key);
	XCTAssertEqual(self.keychain.items.count, keychainBefore.count + 3);
	XCTAssertEqual(self.keychain.reads, 3u, @"one read per item copied");

	// Never again
	XCTAssertFalse([migration isNeeded]);
	self.keychain.reads = 0;
	XCTAssertFalse([[self migrationWithOldPreferences:@{@"New": @1}] migrateIfNeeded]);
	XCTAssertNil([self.defaults objectForKey:@"New"]);
	XCTAssertEqual(self.keychain.reads, 0u);
}

- (void)testSequelProPreferencesWinAndExistingKeychainCopiesAreKept
{
	self.defaults.values[@"CustomQueryEditorFont"] = @"Monaco";
	self.keychain.items[@"Sequel Pro : Prod (12)|root@db/app"] = @"old";
	self.keychain.items[@"Sequel Plus : Prod (12)|root@db/app"] = @"newer";

	SPSequelPlusMigration *migration = [self migrationWithOldPreferences:@{@"CustomQueryEditorFont": @"Menlo", SPSequelPlusMigratedFromSequelProKey: @NO}];
	XCTAssertTrue([migration migrateIfNeeded]);
	XCTAssertEqualObjects([self.defaults objectForKey:@"CustomQueryEditorFont"], @"Menlo", @"the first run takes Sequel Pro's settings");
	XCTAssertEqualObjects(self.keychain.items[@"Sequel Plus : Prod (12)|root@db/app"], @"newer");
	XCTAssertEqual(self.keychain.reads, 0u, @"an item that exists isn't read again");
	XCTAssertTrue([self.defaults boolForKey:SPSequelPlusMigratedFromSequelProKey]);
	XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[[self folder:@"Sequel Plus"] path]], @"no Sequel Pro folder: nothing to copy");
}

- (void)testExistingSequelPlusFolderMeansNoMigration
{
	[self write:@"mine" to:@"Data/Favorites.plist" inFolder:@"Sequel Plus"];
	[self write:@"theirs" to:@"Data/Favorites.plist" inFolder:@"Sequel Pro"];
	self.keychain.items[@"Sequel Pro : Prod (12)|root@db/app"] = @"old";

	SPSequelPlusMigration *migration = [self migrationWithOldPreferences:@{@"A": @1}];
	XCTAssertFalse([migration isNeeded]);
	XCTAssertFalse([migration migrateIfNeeded]);
	XCTAssertEqualObjects([self read:@"Data/Favorites.plist" inFolder:@"Sequel Plus"], @"mine");
	XCTAssertNil([self.defaults objectForKey:@"A"]);
	XCTAssertEqual(self.keychain.items.count, 1u);
}

- (void)testAnItemThatCantBeReadIsSkipped
{
	self.keychain.items[@"Sequel Pro : Empty (1)|a@b/c"] = @"";
	XCTAssertTrue([[self migrationWithOldPreferences:nil] migrateIfNeeded]);
	XCTAssertNil(self.keychain.items[@"Sequel Plus : Empty (1)|a@b/c"]);
	XCTAssertTrue([self.defaults boolForKey:SPSequelPlusMigratedFromSequelProKey], @"marked anyway: never asks again");
}

@end
