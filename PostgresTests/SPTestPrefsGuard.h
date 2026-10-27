#import <Cocoa/Cocoa.h>

/// The preference SPInsertTransferToolbarItemIfNeeded records itself in (forced to YES for the test run).
extern NSString * const SPTestTransferAddedKey;

/// MySQL's SPSelectLastFavoriteUsed / SPDefaultFavorite (forced to NO / 0 for the test run, so MySQL
/// connection tabs preselect no saved favorite and never read its password from the keychain).
extern NSString * const SPTestSelectLastFavoriteUsedKey;
extern NSString * const SPTestDefaultFavoriteKey;

@interface NSToolbar (SPTestPrefsGuard)
/// The value last passed to -setAutosavesConfiguration: (which, in tests, always stores NO).
- (BOOL)sp_requestedAutosave;
@end

@interface NSSplitView (SPTestPrefsGuard)
/// The name last passed to -setAutosaveName: (which, in tests, always stores nil).
- (NSString *)sp_requestedAutosaveName;
@end
