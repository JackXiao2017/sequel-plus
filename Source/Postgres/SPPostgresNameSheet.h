#import <Cocoa/Cocoa.h>

/**
 * A small sheet that asks for one name, built in code (the Database menu's Add, Rename and Duplicate Database…, and
 * Delete Database…'s confirmation): a message, a text field and Cancel / the action button.
 *
 * The action button is enabled when the trimmed text is not empty and differs from initialName; with requiredText,
 * only when the text is exactly requiredText (a destructive action confirmed by typing a name). Return presses it,
 * Escape cancels. Use on the main thread. completion is called exactly once, after the sheet closes: with the trimmed
 * text (the action), or nil (Cancel, or when the sheet can't be shown).
 */
__attribute__((visibility("default")))
@interface SPPostgresNameSheet : NSObject <NSTextFieldDelegate>

+ (SPPostgresNameSheet *)beginOnWindow:(NSWindow *)window
								 title:(NSString *)title
							   message:(NSString *)message
						   initialName:(NSString *)initialName
						   buttonTitle:(NSString *)buttonTitle
						  requiredText:(NSString *)requiredText
							completion:(void (^)(NSString *nameOrNil))completion;

/// The sheet that is open, nil when none is.
+ (SPPostgresNameSheet *)currentSheet;

@property (readonly) NSWindow *sheet;
@property (readonly) NSTextField *messageLabel;
@property (readonly) NSTextField *nameField;
@property (readonly) NSButton *actionButton;
@property (readonly) NSButton *cancelButton;

- (IBAction)performAction:(id)sender;
- (IBAction)cancel:(id)sender;

@end
