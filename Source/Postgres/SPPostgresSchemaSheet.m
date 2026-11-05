#import "SPPostgresSchemaSheet.h"

static SPPostgresSchemaSheet *SPPostgresCurrentSchemaSheet = nil;

@implementation SPPostgresSchemaSheet
{
	NSWindow *sheet;
	BOOL editing;
	NSTextField *nameField;
	NSPopUpButton *ownerPopup;
	NSButton *actionButton;
	NSButton *cancelButton;
	NSString *originalName;
	NSString *originalOwner;
	void (^completion)(NSDictionary *);
}

@synthesize sheet, editing, nameField, ownerPopup, actionButton, cancelButton;

+ (SPPostgresSchemaSheet *)currentSheet
{
	return SPPostgresCurrentSchemaSheet;
}

+ (SPPostgresSchemaSheet *)_beginOnWindow:(NSWindow *)window editing:(BOOL)isEditing name:(NSString *)name heading:(NSString *)heading owner:(NSString *)owner roles:(NSArray *)roles completion:(void (^)(NSDictionary *))theCompletion
{
	if (!window || [window attachedSheet] || SPPostgresCurrentSchemaSheet) {
		if (theCompletion) theCompletion(nil);
		return nil;
	}
	SPPostgresSchemaSheet *schemaSheet = [[self alloc] initEditing:isEditing name:name heading:heading owner:owner roles:roles completion:theCompletion];
	SPPostgresCurrentSchemaSheet = schemaSheet; // released when it ends
	[window beginSheet:schemaSheet->sheet completionHandler:nil];
	[schemaSheet->sheet makeFirstResponder:(isEditing ? (NSView *)schemaSheet->ownerPopup : (NSView *)schemaSheet->nameField)];
	return schemaSheet;
}

+ (SPPostgresSchemaSheet *)beginAddOnWindow:(NSWindow *)window database:(NSString *)database owner:(NSString *)owner roles:(NSArray<NSString *> *)roles completion:(void (^)(NSDictionary<NSString *, NSString *> *))theCompletion
{
	NSString *heading = [NSString stringWithFormat:NSLocalizedString(@"Add a schema to database “%@”", @"PostgreSQL add schema sheet heading"), database ?: @""];
	return [self _beginOnWindow:window editing:NO name:@"" heading:heading owner:owner roles:roles completion:theCompletion];
}

+ (SPPostgresSchemaSheet *)beginEditOnWindow:(NSWindow *)window schema:(NSString *)schema owner:(NSString *)owner roles:(NSArray<NSString *> *)roles completion:(void (^)(NSDictionary<NSString *, NSString *> *))theCompletion
{
	NSString *heading = [NSString stringWithFormat:NSLocalizedString(@"Edit schema “%@”", @"PostgreSQL edit schema sheet heading"), schema ?: @""];
	return [self _beginOnWindow:window editing:YES name:schema heading:heading owner:owner roles:roles completion:theCompletion];
}

/// A right-aligned label for a row of the form.
static NSTextField *SPSchemaSheetLabel(NSString *title, NSRect frame)
{
	NSTextField *label = [NSTextField labelWithString:title];
	[label setAlignment:NSTextAlignmentRight];
	[label setFrame:frame];
	return label;
}

- (instancetype)initEditing:(BOOL)isEditing name:(NSString *)name heading:(NSString *)headingText owner:(NSString *)owner roles:(NSArray *)roles completion:(void (^)(NSDictionary *))theCompletion
{
	if (!(self = [super init])) return nil;
	editing = isEditing;
	originalName = [(name ?: @"") copy];
	originalOwner = [(owner ?: @"") copy];
	completion = [theCompletion copy];

	CGFloat width = 420, height = 160, labelWidth = 60, fieldX = 20 + labelWidth + 8, fieldWidth = width - fieldX - 20;
	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setTitle:(editing ? NSLocalizedString(@"Edit Schema", @"PostgreSQL edit schema sheet title") : NSLocalizedString(@"Add Schema", @"PostgreSQL add schema sheet title"))];
	NSView *content = [sheet contentView];

	NSTextField *heading = [NSTextField labelWithString:headingText];
	[heading setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[heading setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[heading setFrame:NSMakeRect(20, height - 36, width - 40, 18)];
	[content addSubview:heading];

	// Name: typed for a new schema, shown for an existing one
	[content addSubview:SPSchemaSheetLabel(NSLocalizedString(@"Name:", @"PostgreSQL schema sheet: name label"), NSMakeRect(20, height - 72, labelWidth, 17))];
	nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, height - 75, fieldWidth, 22)];
	[nameField setStringValue:originalName];
	[[nameField cell] setScrollable:YES];
	if (editing) {
		[nameField setEditable:NO];
		[nameField setSelectable:YES];
		[nameField setBordered:NO];
		[nameField setDrawsBackground:NO];
	}
	else {
		[nameField setDelegate:self];
		[nameField setPlaceholderString:NSLocalizedString(@"schema name", @"PostgreSQL add schema: name placeholder")];
	}
	[content addSubview:nameField];

	// Owner
	[content addSubview:SPSchemaSheetLabel(NSLocalizedString(@"Owner:", @"PostgreSQL schema sheet: owner label"), NSMakeRect(20, height - 106, labelWidth, 17))];
	ownerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX - 3, height - 111, fieldWidth + 6, 26) pullsDown:NO];
	NSMutableArray *names = [NSMutableArray arrayWithArray:roles ?: @[]];
	if ([originalOwner length] && ![names containsObject:originalOwner]) [names insertObject:originalOwner atIndex:0];
	[ownerPopup addItemsWithTitles:names];
	if ([originalOwner length]) [ownerPopup selectItemWithTitle:originalOwner];
	[ownerPopup setTarget:self];
	[ownerPopup setAction:@selector(_controlChanged:)];
	[content addSubview:ownerPopup];

	// Buttons
	NSString *actionTitle = editing ? NSLocalizedString(@"Save", @"PostgreSQL edit schema: save button") : NSLocalizedString(@"Add", @"PostgreSQL add schema: add button");
	actionButton = [[NSButton buttonWithTitle:actionTitle target:self action:@selector(performAction:)] retain];
	[actionButton setKeyEquivalent:@"\r"];
	[actionButton sizeToFit];
	NSRect frame = [actionButton frame];
	frame.size.width = MAX(frame.size.width + 12, 90);
	frame.origin = NSMakePoint(width - 14 - frame.size.width, 12);
	[actionButton setFrame:frame];
	[content addSubview:actionButton];

	cancelButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(cancel:)] retain];
	[cancelButton setKeyEquivalent:@"\033"];
	[cancelButton sizeToFit];
	NSRect cancelFrame = [cancelButton frame];
	cancelFrame.size.width = MAX(cancelFrame.size.width + 12, 90);
	cancelFrame.origin = NSMakePoint(NSMinX(frame) - cancelFrame.size.width, 12);
	[cancelButton setFrame:cancelFrame];
	[content addSubview:cancelButton];

	[self validate];
	return self;
}

- (void)dealloc
{
	[sheet release];
	[nameField release];
	[ownerPopup release];
	[actionButton release];
	[cancelButton release];
	[originalName release];
	[originalOwner release];
	[completion release];
	[super dealloc];
}

- (NSDictionary *)_values
{
	NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return @{@"name": name, @"owner": [ownerPopup titleOfSelectedItem] ?: @""};
}

- (void)validate
{
	NSDictionary *values = [self _values];
	if (editing) [actionButton setEnabled:[values[@"owner"] length] > 0 && ![values[@"owner"] isEqualToString:originalOwner]];
	else [actionButton setEnabled:[values[@"name"] length] > 0];
}

- (void)_controlChanged:(id)sender
{
	[self validate];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self validate];
}

- (void)_endWithValues:(NSDictionary *)values
{
	if (SPPostgresCurrentSchemaSheet != self) return;
	SPPostgresCurrentSchemaSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];

	void (^handler)(NSDictionary *) = [completion autorelease];
	completion = nil;
	if (handler) handler(values);
	[self autorelease];
}

- (IBAction)performAction:(id)sender
{
	[self validate];
	if (![actionButton isEnabled]) {
		NSBeep();
		return;
	}
	[self _endWithValues:[self _values]];
}

- (IBAction)cancel:(id)sender
{
	[self _endWithValues:nil];
}

@end
