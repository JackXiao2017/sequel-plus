#import "SPPostgresFieldEditorSheet.h"
#import "SPFieldEditorController.h"

/// The sheets open now, by window (a window takes one at a time)
static NSMutableDictionary *SPPostgresOpenFieldEditorSheets(void)
{
	static NSMutableDictionary *open = nil;
	if (!open) open = [[NSMutableDictionary alloc] init];
	return open;
}

static NSValue *SPPostgresWindowKey(NSWindow *window)
{
	return [NSValue valueWithNonretainedObject:window];
}

@interface SPPostgresFieldEditorSheet () <SPFieldEditorControllerDelegate>
@end

@implementation SPPostgresFieldEditorSheet
{
	SPFieldEditorController *fieldEditor;
	void (^completion)(id);
	NSString *fieldEditorType;    // SPFieldEditorController doesn't retain it
	NSWindow *window;             // not retained
}

+ (NSString *)fieldEditorTypeForTypeName:(NSString *)typeName
{
	// These types trigger MySQL-only handling (JSON reformatting, the bit sheet...) that would rewrite unchanged values
	NSArray *mySQLOnlyTypes = @[@"BIT", @"JSON", @"GEOMETRY", @"BINARY", @"VARBINARY", @"FLOAT"];
	return [mySQLOnlyTypes containsObject:[typeName uppercaseString]] ? @"" : (typeName ?: @"");
}

+ (SPPostgresFieldEditorSheet *)openSheetOnWindow:(NSWindow *)aWindow
{
	return aWindow ? [SPPostgresOpenFieldEditorSheets() objectForKey:SPPostgresWindowKey(aWindow)] : nil;
}

+ (void)editValue:(NSString *)value columnName:(NSString *)columnName typeName:(NSString *)typeName
		 editable:(BOOL)editable allowNull:(BOOL)allowNull window:(NSWindow *)aWindow completion:(void (^)(id newValue))aCompletion
{
	if (!aWindow || [aWindow attachedSheet] || [self openSheetOnWindow:aWindow]) {
		if (aCompletion) aCompletion(nil);
		return;
	}

	SPPostgresFieldEditorSheet *sheet = [[SPPostgresFieldEditorSheet alloc] init];   // released by its result
	sheet->window = aWindow;
	sheet->fieldEditorType = [[self fieldEditorTypeForTypeName:typeName] copy];
	sheet->completion = [aCompletion copy];
	[SPPostgresOpenFieldEditorSheets() setObject:sheet forKey:SPPostgresWindowKey(aWindow)];
	sheet->fieldEditor = [[SPFieldEditorController alloc] init];
	[sheet->fieldEditor setTextMaxLength:0];
	[sheet->fieldEditor setFieldType:sheet->fieldEditorType];
	[sheet->fieldEditor setAllowNULL:allowNull];
	[sheet->fieldEditor editWithObject:value fieldName:columnName usingEncoding:NSUTF8StringEncoding isObjectBlob:NO
							isEditable:editable withWindow:aWindow sender:sheet contextInfo:nil];
}

- (void)dealloc
{
	[fieldEditor release];
	[fieldEditorType release];
	[completion release];
	[super dealloc];
}

/// Asked by the field editor (as of MySQL's content and query views) for the caret to restore from an in-cell edit; a
/// sheet here never follows one, so the caret starts at the beginning.
- (NSRange)fieldEditorSelectedRange
{
	return NSMakeRange(0, 0);
}

- (void)setFieldEditorSelectedRange:(NSRange)range
{
}

/// The field editor's result: the new value, or nil when cancelled or not editable. A file loaded into the sheet comes
/// as NSData: given as UTF-8 text, or refused (NSBeep, nil) when it isn't UTF-8.
- (void)processFieldEditorResult:(id)data contextInfo:(NSDictionary *)contextInfo
{
	if ([data isKindOfClass:[NSData class]]) {
		NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
		if (!text) NSBeep();
		data = text;
	}

	// Called by the field editor: released once it has returned (as MySQL's)
	[fieldEditor autorelease];
	fieldEditor = nil;
	[fieldEditorType autorelease];
	fieldEditorType = nil;
	void (^done)(id) = [completion autorelease];
	completion = nil;
	if (window) [SPPostgresOpenFieldEditorSheets() removeObjectForKey:SPPostgresWindowKey(window)];
	window = nil;
	[self autorelease];   // the sheet's own retain (it stays valid until the pool drains)

	if (done) done(data);
}

@end
