#import "SPTestPrefsGuard.h"
#import <objc/runtime.h>

NSString * const SPTestTransferAddedKey = @"SPToolbarTransferItemAdded";

static const void *SPRequestedAutosaveKey = &SPRequestedAutosaveKey;

#pragma mark - Keeping the test run out of the real preferences

/**
 * The test bundle runs inside the app, so [NSUserDefaults standardUserDefaults] is the owner's real
 * preferences, where the "TableWindowToolbar" layout is saved. For the whole test run (every test
 * class):
 *
 * - Toolbars never autosave: -setAutosavesConfiguration: always stores NO (the requested value is
 *   kept on the toolbar for assertions, see -sp_requestedAutosave). So toolbars in tests use their
 *   delegate's default layout and nothing a test does to them (insert, remove, hide) is saved.
 * - SPToolbarTransferItemAdded reads YES from the volatile argument domain, so documents created by
 *   tests never try the one-time Transfer insertion, which records itself in the given defaults.
 *
 * Both are in place before any test runs (+load runs when the bundle is loaded).
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

@interface SPTestPrefsGuard : NSObject
@end

@implementation SPTestPrefsGuard

+ (void)load
{
	Method original = class_getInstanceMethod([NSToolbar class], @selector(setAutosavesConfiguration:));
	Method replacement = class_getInstanceMethod([NSToolbar class], @selector(sp_test_setAutosavesConfiguration:));
	method_exchangeImplementations(original, replacement);

	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *domain = [([prefs volatileDomainForName:NSArgumentDomain] ?: @{}) mutableCopy];
	domain[SPTestTransferAddedKey] = @YES;
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
}

@end
