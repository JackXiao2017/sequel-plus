#import "SPPostgresNameSheet.h"

static SPPostgresNameSheet *SPPostgresCurrentNameSheet = nil;

@implementation SPPostgresNameSheet
{
	NSWindow *sheet;
	NSWindow *parentWindow;
	NSTextField *messageLabel;
	NSTextField *nameField;
	NSButton *actionButton;
	NSButton *cancelButton;
	NSString *initialName;
	NSString *requiredText;
	void (^completion)(NSString *);
}

@synthesize sheet, messageLabel, nameField, actionButton, cancelButton;

+ (SPPostgresNameSheet *)currentSheet
{
	return SPPostgresCurrentNameSheet;
}

+ (SPPostgresNameSheet *)beginOnWindow:(NSWindow *)window title:(NSString *)title message:(NSString *)message initialName:(NSString *)initialName buttonTitle:(NSString *)buttonTitle requiredText:(NSString *)requiredText completion:(void (^)(NSString *))completion
{
	if (!window || [window attachedSheet] || SPPostgresCurrentNameSheet) {
		if (completion) completion(nil);
		return nil;
	}
	SPPostgresNameSheet *nameSheet = [[self alloc] initWithTitle:title message:message initialName:initialName buttonTitle:buttonTitle requiredText:requiredText completion:completion];
	SPPostgresCurrentNameSheet = nameSheet; // released when it ends
	nameSheet->parentWindow = window;
	[window beginSheet:nameSheet->sheet completionHandler:nil];
	[nameSheet->sheet makeFirstResponder:nameSheet->nameField];
	return nameSheet;
}

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message initialName:(NSString *)theInitialName buttonTitle:(NSString *)buttonTitle requiredText:(NSString *)theRequiredText completion:(void (^)(NSString *))theCompletion
{
	if (!(self = [super init])) return nil;
	initialName = [theInitialName copy];
	requiredText = [theRequiredText copy];
	completion = [theCompletion copy];

	CGFloat width = 380;
	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

	messageLabel = [[NSTextField wrappingLabelWithString:message ?: @""] retain];
	[messageLabel setFont:smallFont];
	[messageLabel setPreferredMaxLayoutWidth:width - 40];
	CGFloat messageHeight = ceil([[messageLabel cell] cellSizeForBounds:NSMakeRect(0, 0, width - 40, 1000)].height);
	CGFloat height = 98 + messageHeight;

	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setTitle:title ?: @""];
	NSView *content = [sheet contentView];

	[messageLabel setFrame:NSMakeRect(20, height - 16 - messageHeight, width - 40, messageHeight)];
	[content addSubview:messageLabel];

	nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 52, width - 40, 22)];
	[nameField setStringValue:initialName ?: @""];
	[nameField setDelegate:self];
	[[nameField cell] setScrollable:YES];
	[content addSubview:nameField];

	actionButton = [[NSButton buttonWithTitle:buttonTitle ?: @"OK" target:self action:@selector(performAction:)] retain];
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

	[self _validate];
	return self;
}

- (void)dealloc
{
	[sheet release];
	[messageLabel release];
	[nameField release];
	[actionButton release];
	[cancelButton release];
	[initialName release];
	[requiredText release];
	[completion release];
	[super dealloc];
}

- (NSString *)_trimmedName
{
	return [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)_validate
{
	NSString *name = [self _trimmedName];
	BOOL valid = requiredText ? [[nameField stringValue] isEqualToString:requiredText] : ([name length] && ![name isEqualToString:initialName ?: @""]);
	[actionButton setEnabled:valid];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self _validate];
}

- (void)_endWithName:(NSString *)name
{
	if (SPPostgresCurrentNameSheet != self) return;
	SPPostgresCurrentNameSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];

	void (^handler)(NSString *) = [completion autorelease];
	completion = nil;
	if (handler) handler(name);
	[self autorelease];
}

- (IBAction)performAction:(id)sender
{
	[self _validate];
	if (![actionButton isEnabled]) {
		NSBeep();
		return;
	}
	[self _endWithName:requiredText ? [nameField stringValue] : [self _trimmedName]];
}

- (IBAction)cancel:(id)sender
{
	[self _endWithName:nil];
}

@end
