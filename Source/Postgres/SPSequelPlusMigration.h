#import <Foundation/Foundation.h>

/// The folder in ~/Library/Application Support that holds Sequel Plus's data (favorites, bundles, themes, …).
extern NSString * const SPSequelPlusSupportFolderName __attribute__((visibility("default")));
/// The original Sequel Pro's folder: copied once, never written.
extern NSString * const SPSequelProSupportFolderName __attribute__((visibility("default")));
/// The original Sequel Pro's preferences domain: read once, never written.
extern NSString * const SPSequelProBundleIdentifier __attribute__((visibility("default")));
/// Set in Sequel Plus's preferences once the copy from Sequel Pro has run.
extern NSString * const SPSequelPlusMigratedFromSequelProKey __attribute__((visibility("default")));

/// YES while the app hosts the test bundle.
__attribute__((visibility("default"))) BOOL SPSequelPlusIsRunningTests(void);
/// ~/Library/Application Support, or (while the app hosts tests) a folder of this run in the temporary directory, so
/// tests never create or change the real Sequel Plus folder (its absence is what starts the copy from Sequel Pro).
__attribute__((visibility("default"))) NSURL *SPSequelPlusApplicationSupportURL(void);
/// SPSequelPlusApplicationSupportURL()/Sequel Plus (not created).
__attribute__((visibility("default"))) NSURL *SPSequelPlusSupportDirectoryURL(void);

/// The keychain calls the migration makes. The real one lists items without reading them (no prompt), and reads each
/// password once (macOS may ask to allow it).
@protocol SPSequelPlusMigrationKeychain <NSObject>
/// Generic passwords whose service (the item's name) starts with one of `prefixes`: @[@{@"name", @"account"}].
- (NSArray<NSDictionary<NSString *, NSString *> *> *)itemsWithNamePrefixes:(NSArray<NSString *> *)prefixes;
- (NSString *)getPasswordForName:(NSString *)name account:(NSString *)account;
- (BOOL)passwordExistsForName:(NSString *)name account:(NSString *)account;
- (void)addPassword:(NSString *)password forName:(NSString *)name account:(NSString *)account;
@end

/**
 * Sequel Plus's own data, apart from the original Sequel Pro's. Run once, before anything reads preferences or the
 * data folder, when Sequel Plus has never run with its own data (no migration mark in its preferences and no
 * Sequel Plus folder):
 *
 * 1. Preferences: every key of Sequel Pro's domain is copied into Sequel Plus's.
 * 2. Folder: ~/Library/Application Support/Sequel Pro is copied to …/Sequel Plus (when it exists).
 * 3. Keychain: each item named "Sequel Pro : …", "Sequel Pro SSHTunnel : …", "Sequel Pro (PostgreSQL) : …" or
 *    "Sequel Pro (PostgreSQL) SSHTunnel : …" is copied to the same name with "Sequel Plus", same account, unless
 *    that item exists.
 *
 * Sequel Pro's preferences, folder and keychain items are only read. The mark is set even when a step fails (the
 * failure is logged), so it never runs twice.
 */
__attribute__((visibility("default")))
@interface SPSequelPlusMigration : NSObject

- (instancetype)initWithSupportDirectory:(NSURL *)supportDirectory
							 preferences:(NSUserDefaults *)preferences
						  oldPreferences:(NSDictionary *)oldPreferences
								keychain:(id<SPSequelPlusMigrationKeychain>)keychain;

/// Runs the migration when needed; YES when it ran.
- (BOOL)migrateIfNeeded;

/// Whether it would run.
- (BOOL)isNeeded;

/// The keychain item name with "Sequel Pro" replaced by "Sequel Plus" (nil for a name of none of the four kinds).
+ (NSString *)sequelPlusNameForSequelProName:(NSString *)name;

/// The app's run at launch: the real folder, preferences and keychain. Does nothing while the app hosts tests.
+ (void)migrateAtLaunch;

@end
