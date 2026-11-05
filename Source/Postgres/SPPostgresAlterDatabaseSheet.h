#import <Cocoa/Cocoa.h>

/**
 * Database ▸ Alter Database… for PostgreSQL, built in code: the database's name, its owner (a pop-up of the server's
 * roles, the current owner selected; an owner not listed is added) and its comment (several lines).
 *
 * Alter is enabled when something changed and the name is not empty. Return in the name field presses it, Escape
 * cancels. Use on the main thread. completion is called exactly once, after the sheet closes: with the values (Alter)
 * as @{@"name", @"owner", @"comment"} (name trimmed), or nil (Cancel, or when the sheet can't be shown).
 */
__attribute__((visibility("default")))
@interface SPPostgresAlterDatabaseSheet : NSObject <NSTextFieldDelegate, NSTextViewDelegate>

+ (SPPostgresAlterDatabaseSheet *)beginOnWindow:(NSWindow *)window
										database:(NSString *)database
										   owner:(NSString *)owner
										 comment:(NSString *)comment
										   roles:(NSArray<NSString *> *)roles
									  completion:(void (^)(NSDictionary<NSString *, NSString *> *valuesOrNil))completion;

/// The sheet that is open, nil when none is.
+ (SPPostgresAlterDatabaseSheet *)currentSheet;

@property (readonly) NSWindow *sheet;
@property (readonly) NSTextField *nameField;
@property (readonly) NSPopUpButton *ownerPopup;
@property (readonly) NSTextView *commentView;
@property (readonly) NSButton *alterButton;
@property (readonly) NSButton *cancelButton;

/// Re-checks whether Alter is enabled (after changing the controls in code).
- (void)validate;
- (IBAction)alter:(id)sender;
- (IBAction)cancel:(id)sender;

@end
