#import <Cocoa/Cocoa.h>

/**
 * The PostgreSQL table list's schema sheet, built in code, for the buttons after the schema pop-up:
 *
 * - Add Schema (+): a Name field and an Owner pop-up (the server's roles, `owner` selected: the connected user).
 *   Add is enabled when the name isn't empty.
 * - Edit Schema (pencil): the schema's name (not editable) and its Owner pop-up, the current owner selected.
 *   Save is enabled when another owner is chosen.
 *
 * An owner not among the roles is added to the pop-up. Return presses the default button, Escape cancels. Use on the
 * main thread. completion is called exactly once, after the sheet closes: with @{@"name", @"owner"} (name trimmed),
 * or nil (Cancel, or when the sheet can't be shown).
 */
__attribute__((visibility("default")))
@interface SPPostgresSchemaSheet : NSObject <NSTextFieldDelegate>

+ (SPPostgresSchemaSheet *)beginAddOnWindow:(NSWindow *)window
								   database:(NSString *)database
									  owner:(NSString *)owner
									  roles:(NSArray<NSString *> *)roles
								 completion:(void (^)(NSDictionary<NSString *, NSString *> *valuesOrNil))completion;

+ (SPPostgresSchemaSheet *)beginEditOnWindow:(NSWindow *)window
									  schema:(NSString *)schema
									   owner:(NSString *)owner
									   roles:(NSArray<NSString *> *)roles
								  completion:(void (^)(NSDictionary<NSString *, NSString *> *valuesOrNil))completion;

/// The sheet that is open, nil when none is.
+ (SPPostgresSchemaSheet *)currentSheet;

@property (readonly) NSWindow *sheet;
@property (readonly) BOOL editing;
@property (readonly) NSTextField *nameField;
@property (readonly) NSPopUpButton *ownerPopup;
@property (readonly) NSButton *actionButton;
@property (readonly) NSButton *cancelButton;

/// Re-checks whether the default button is enabled (after changing the controls in code).
- (void)validate;
- (IBAction)performAction:(id)sender;
- (IBAction)cancel:(id)sender;

@end
