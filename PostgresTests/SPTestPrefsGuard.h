#import <Cocoa/Cocoa.h>

/// The preference SPInsertTransferToolbarItemIfNeeded records itself in (forced to YES for the test run).
extern NSString * const SPTestTransferAddedKey;

@interface NSToolbar (SPTestPrefsGuard)
/// The value last passed to -setAutosavesConfiguration: (which, in tests, always stores NO).
- (BOOL)sp_requestedAutosave;
@end

@interface NSSplitView (SPTestPrefsGuard)
/// The name last passed to -setAutosaveName: (which, in tests, always stores nil).
- (NSString *)sp_requestedAutosaveName;
@end
