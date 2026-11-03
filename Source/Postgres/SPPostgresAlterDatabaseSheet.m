#import "SPPostgresAlterDatabaseSheet.h"

static SPPostgresAlterDatabaseSheet *SPPostgresCurrentAlterDatabaseSheet = nil;

@implementation SPPostgresAlterDatabaseSheet
{
	NSWindow *sheet;
	NSTextField *nameField;
	NSPopUpButton *ownerPopup;
	NSTextView *commentView;
	NSButton *alterButton;
	NSButton *cancelButton;
	NSString *originalName;
	NSString *originalOwner;
	NSString *originalComment;
	void (^completion)(NSDictionary *);
}

@synthesize sheet, nameField, ownerPopup, commentView, alterButton, cancelButton;

+ (SPPostgresAlterDatabaseSheet *)currentSheet
{
	return SPPostgresCurrentAlterDatabaseSheet;
}

+ (SPPostgresAlterDatabaseSheet *)beginOnWindow:(NSWindow *)window database:(NSString *)database owner:(NSString *)owner comment:(NSString *)comment roles:(NSArray<NSString *> *)roles completion:(void (^)(NSDictionary<NSString *, NSString *> *))theCompletion
{
	if (!window || [window attachedSheet] || SPPostgresCurrentAlterDatabaseSheet) {
		if (theCompletion) theCompletion(nil);
		return nil;
	}
	SPPostgresAlterDatabaseSheet *alter = [[self alloc] initWithDatabase:database owner:owner comment:comment roles:roles completion:theCompletion];
	SPPostgresCurrentAlterDatabaseSheet = alter; // released when it ends
	[window beginSheet:alter->sheet completionHandler:nil];
	[alter->sheet makeFirstResponder:alter->nameField];
	return alter;
}

/// A right-aligned label for a row of the form.
static NSTextField *SPAlterDatabaseLabel(NSString *title, NSRect frame)
{
	NSTextField *label = [NSTextField labelWithString:title];
	[label setAlignment:NSTextAlignmentRight];
	[label setFrame:frame];
	return label;
}

- (instancetype)initWithDatabase:(NSString *)database owner:(NSString *)owner comment:(NSString *)comment roles:(NSArray<NSString *> *)roles completion:(void (^)(NSDictionary<NSString *, NSString *> *))theCompletion
{
	if (!(self = [super init])) return nil;
	originalName = [(database ?: @"") copy];
	originalOwner = [(owner ?: @"") copy];
	originalComment = [(comment ?: @"") copy];
	completion = [theCompletion copy];

	CGFloat width = 460, height = 300, labelWidth = 80, fieldX = 20 + labelWidth + 8, fieldWidth = width - fieldX - 20;
	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setTitle:NSLocalizedString(@"Alter Database", @"PostgreSQL alter database sheet title")];
	[sheet setContentMinSize:NSMakeSize(width, height)];
	[sheet setContentMaxSize:NSMakeSize(900, 700)];
	NSView *content = [sheet contentView];

	NSTextField *heading = [NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Alter database “%@”", @"PostgreSQL alter database sheet heading"), originalName]];
	[heading setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[heading setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[heading setFrame:NSMakeRect(20, height - 36, width - 40, 18)];
	[heading setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:heading];

	// Name
	NSTextField *nameLabel = SPAlterDatabaseLabel(NSLocalizedString(@"Name:", @"PostgreSQL alter database: name label"), NSMakeRect(20, height - 72, labelWidth, 17));
	[nameLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:nameLabel];
	nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, height - 75, fieldWidth, 22)];
	[nameField setStringValue:originalName];
	[nameField setDelegate:self];
	[nameField setTarget:self];
	[nameField setAction:@selector(alter:)];
	[[nameField cell] setScrollable:YES];
	[nameField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:nameField];

	// Owner
	NSTextField *ownerLabel = SPAlterDatabaseLabel(NSLocalizedString(@"Owner:", @"PostgreSQL alter database: owner label"), NSMakeRect(20, height - 106, labelWidth, 17));
	[ownerLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:ownerLabel];
	ownerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX - 3, height - 111, fieldWidth + 6, 26) pullsDown:NO];
	NSMutableArray *names = [NSMutableArray arrayWithArray:roles ?: @[]];
	if ([originalOwner length] && ![names containsObject:originalOwner]) [names insertObject:originalOwner atIndex:0];
	[ownerPopup addItemsWithTitles:names];
	if ([originalOwner length]) [ownerPopup selectItemWithTitle:originalOwner];
	[ownerPopup setTarget:self];
	[ownerPopup setAction:@selector(_controlChanged:)];
	[ownerPopup setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:ownerPopup];

	// Comment
	NSTextField *commentLabel = SPAlterDatabaseLabel(NSLocalizedString(@"Comment:", @"PostgreSQL alter database: comment label"), NSMakeRect(20, height - 140, labelWidth, 17));
	[commentLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:commentLabel];
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(fieldX, 56, fieldWidth, height - 56 - 122)] autorelease];
	[scrollView setBorderType:NSBezelBorder];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	commentView = [[NSTextView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[commentView setRichText:NO];
	[commentView setAllowsUndo:YES];
	[commentView setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	[commentView setAutoresizingMask:NSViewWidthSizable];
	[[commentView textContainer] setWidthTracksTextView:YES];
	[commentView setString:originalComment];
	[commentView setDelegate:self];
	[scrollView setDocumentView:commentView];
	[content addSubview:scrollView];

	// Buttons
	alterButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Alter", @"PostgreSQL alter database: alter button") target:self action:@selector(alter:)] retain];
	[alterButton setKeyEquivalent:@"\r"];
	[alterButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[alterButton sizeToFit];
	NSRect frame = [alterButton frame];
	frame.size.width = MAX(frame.size.width + 12, 90);
	frame.origin = NSMakePoint(width - 14 - frame.size.width, 12);
	[alterButton setFrame:frame];
	[alterButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:alterButton];

	cancelButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(cancel:)] retain];
	[cancelButton setKeyEquivalent:@"\033"];
	[cancelButton sizeToFit];
	NSRect cancelFrame = [cancelButton frame];
	cancelFrame.size.width = MAX(cancelFrame.size.width + 12, 90);
	cancelFrame.origin = NSMakePoint(NSMinX(frame) - cancelFrame.size.width, 12);
	[cancelButton setFrame:cancelFrame];
	[cancelButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancelButton];

	NSTextField *hint = [NSTextField labelWithString:NSLocalizedString(@"⌘↩ to alter", @"PostgreSQL alter database: shortcut hint")];
	[hint setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[hint setTextColor:[NSColor secondaryLabelColor]];
	[hint setFrame:NSMakeRect(20, 20, 160, 14)];
	[hint setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[content addSubview:hint];

	[self validate];
	return self;
}

- (void)dealloc
{
	[sheet release];
	[nameField release];
	[ownerPopup release];
	[commentView release];
	[alterButton release];
	[cancelButton release];
	[originalName release];
	[originalOwner release];
	[originalComment release];
	[completion release];
	[super dealloc];
}

- (NSDictionary *)_values
{
	NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return @{@"name": name, @"owner": [ownerPopup titleOfSelectedItem] ?: @"", @"comment": [[[commentView string] copy] autorelease] ?: @""};
}

- (void)validate
{
	NSDictionary *values = [self _values];
	BOOL changed = ![values[@"name"] isEqualToString:originalName] || ![values[@"owner"] isEqualToString:originalOwner] || ![values[@"comment"] isEqualToString:originalComment];
	[alterButton setEnabled:changed && [values[@"name"] length] > 0];
}

- (void)_controlChanged:(id)sender
{
	[self validate];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self validate];
}

- (void)textDidChange:(NSNotification *)notification
{
	[self validate];
}

- (void)_endWithValues:(NSDictionary *)values
{
	if (SPPostgresCurrentAlterDatabaseSheet != self) return;
	SPPostgresCurrentAlterDatabaseSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];

	void (^handler)(NSDictionary *) = [completion autorelease];
	completion = nil;
	if (handler) handler(values);
	[self autorelease];
}

- (IBAction)alter:(id)sender
{
	[self validate];
	if (![alterButton isEnabled]) {
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
