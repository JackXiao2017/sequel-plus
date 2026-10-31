#import <Cocoa/Cocoa.h>

/**
 * MySQL's field editor (SPFieldEditorController) as a sheet, shared by the Content and Query tabs. Use on the main
 * thread. The sheet object keeps itself alive while open.
 */
__attribute__((visibility("default")))
@interface SPPostgresFieldEditorSheet : NSObject

/// MySQL's SPFieldEditorController as a sheet on window. completion gets the new value (NSString; a loaded file as
/// UTF-8 text, or nil with NSBeep when it isn't UTF-8) or nil when cancelled or not editable. Calls completion(nil) at
/// once when window is nil, already has a sheet, or another SPPostgresFieldEditorSheet is open on it.
+ (void)editValue:(NSString *)value columnName:(NSString *)columnName typeName:(NSString *)typeName
		 editable:(BOOL)editable allowNull:(BOOL)allowNull window:(NSWindow *)window completion:(void (^)(id newValue))completion;

/// The type passed to SPFieldEditorController: @"" for the MySQL-only types (BIT, JSON, GEOMETRY, BINARY, VARBINARY,
/// FLOAT, case-insensitive) and nil, else typeName.
+ (NSString *)fieldEditorTypeForTypeName:(NSString *)typeName;

/// The sheet open on window, or nil (for tests, which end it as its OK button would, with processFieldEditorResult:contextInfo:).
+ (SPPostgresFieldEditorSheet *)openSheetOnWindow:(NSWindow *)window;

/// The field editor's callback (SPFieldEditorControllerDelegate, adopted privately).
- (void)processFieldEditorResult:(id)data contextInfo:(NSDictionary *)contextInfo;

@end
