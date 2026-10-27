#import "SPTestPrefsGuard.h"
#import <objc/runtime.h>

NSString * const SPTestTransferAddedKey = @"SPToolbarTransferItemAdded";
NSString * const SPTestSelectLastFavoriteUsedKey = @"SelectLastFavoriteUsed";
NSString * const SPTestDefaultFavoriteKey = @"DefaultFavorite";

static const void *SPRequestedAutosaveKey = &SPRequestedAutosaveKey;
static const void *SPRequestedAutosaveNameKey = &SPRequestedAutosaveNameKey;

#pragma mark - Keeping the test run out of the real preferences

/**
 * The test bundle runs inside the app, so [NSUserDefaults standardUserDefaults] is the owner's real
 * preferences, where the "TableWindowToolbar" layout is saved. For the whole test run (every test
 * class):
 *
 * - Toolbars never autosave: -setAutosavesConfiguration: always stores NO (the requested value is
 *   kept on the toolbar for assertions, see -sp_requestedAutosave). So toolbars in tests use their
 *   delegate's default layout and nothing a test does to them (insert, remove, hide) is saved.
 * - Split views never autosave: -[NSSplitView setAutosaveName:] always stores nil (the requested
 *   name is kept on the split view for assertions, see -sp_requestedAutosaveName). With no name,
 *   neither AppKit ("NSSplitView Subview Frames <name>") nor SPSplitView ("SPSplitView Lengths
 *   <name>") saves or restores divider positions, so split views in tests use their built layout.
 * - SPToolbarTransferItemAdded reads YES from the volatile argument domain, so documents created by
 *   tests never try the one-time Transfer insertion, which records itself in the given defaults.
 * - MySQL connection tabs preselect no saved favorite: SelectLastFavoriteUsed reads NO and
 *   DefaultFavorite 0 (Quick Connect) from the volatile argument domain. Otherwise a new MySQL tab
 *   selects the owner's favorite and reads its password from the login keychain
 *   (-[SPConnectionController updateFavoriteSelection:]), which can block the run on a keychain
 *   access prompt (e.g. after a rebuild changes the app's signature).
 *
 * All are in place before any test runs (+load runs when the bundle is loaded).
 *
 * This file must stay in the "Postgres Tests" target for as long as any test creates a document,
 * window or toolbar: it is deliberately not part of any test class, so removing or renaming test
 * files can never switch it off. SPPostgresToolbarTests asserts that it is active.
 */
@implementation NSToolbar (SPTestPrefsGuard)

- (void)sp_test_setAutosavesConfiguration:(BOOL)flag
{
	objc_setAssociatedObject(self, SPRequestedAutosaveKey, @(flag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[self sp_test_setAutosavesConfiguration:NO]; // the original implementation (swapped)
}

- (BOOL)sp_requestedAutosave
{
	return [objc_getAssociatedObject(self, SPRequestedAutosaveKey) boolValue];
}

@end

@implementation NSSplitView (SPTestPrefsGuard)

- (void)sp_test_setAutosaveName:(NSString *)name
{
	objc_setAssociatedObject(self, SPRequestedAutosaveNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
	[self sp_test_setAutosaveName:nil]; // the original implementation (swapped)
}

- (NSString *)sp_requestedAutosaveName
{
	return objc_getAssociatedObject(self, SPRequestedAutosaveNameKey);
}

@end

@interface SPTestPrefsGuard : NSObject
@end

@implementation SPTestPrefsGuard

+ (void)load
{
	Method original = class_getInstanceMethod([NSToolbar class], @selector(setAutosavesConfiguration:));
	Method replacement = class_getInstanceMethod([NSToolbar class], @selector(sp_test_setAutosavesConfiguration:));
	method_exchangeImplementations(original, replacement);

	Method originalSplit = class_getInstanceMethod([NSSplitView class], @selector(setAutosaveName:));
	Method replacementSplit = class_getInstanceMethod([NSSplitView class], @selector(sp_test_setAutosaveName:));
	method_exchangeImplementations(originalSplit, replacementSplit);

	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *domain = [([prefs volatileDomainForName:NSArgumentDomain] ?: @{}) mutableCopy];
	domain[SPTestTransferAddedKey] = @YES;
	domain[SPTestSelectLastFavoriteUsedKey] = @NO;
	domain[SPTestDefaultFavoriteKey] = @0;
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
}

@end
