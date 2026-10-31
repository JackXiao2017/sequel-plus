#import "SPPostgresExtensionController.h"
#import "SPPostgresExtensions.h"
#import "SPPostgresPaneLoader.h"
#import <PostgresKit/PostgresKit.h>

// As the Sequence pane: right-aligned labels at x 20, values from x 128
static const CGFloat SPPostgresExtensionMargin = 20;
static const CGFloat SPPostgresExtensionValueX = 128;
static const CGFloat SPPostgresExtensionRowHeight = 22;
static const CGFloat SPPostgresExtensionPopupWidth = 220;

@interface SPPostgresExtensionController ()

@property (readwrite, copy) NSString *extensionName;
@property (readwrite, retain) SPPostgresExtension *extension;

- (void)_buildView;
- (void)_loadSwitching:(BOOL)switching;
- (void)_load;

@end

@implementation SPPostgresExtensionController
{
	PGPostgresConnection *connection;
	SPPostgresExtensions *extensions;
	SPPostgresPaneLoader *loader; // the runner, the load generation, staleness, and refusing changes while busy

	NSView *view;
	NSTextField *nameField;
	NSTextField *versionField;
	NSTextField *schemaField;
	NSTextField *commentField;
	NSTextField *requiredByField;
	NSPopUpButton *updatePopup;
	NSButton *updateButton;
	NSButton *dropButton;
	NSTextField *noUpdateLabel;

	BOOL invalidated;
}

@synthesize extensionName;
@synthesize extension;
@synthesize nameField, versionField, schemaField, commentField, requiredByField, updatePopup, updateButton, dropButton, noUpdateLabel;
@synthesize alertPresenter;
@synthesize delegate;

#pragma mark Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		loader = [[SPPostgresPaneLoader alloc] initWithConnection:theConnection];
		extensions = [self newExtensionsWithConnection:connection];
		[extensions setLockTimeout:5];
		[self _buildView];
		[self _applyExtension:nil targets:nil targetsError:nil];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[loader release];
	[extensions release];
	[extensionName release];
	[extension release];

	[view release];
	[nameField release];
	[versionField release];
	[schemaField release];
	[commentField release];
	[requiredByField release];
	[updatePopup release];
	[updateButton release];
	[dropButton release];
	[noUpdateLabel release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;
	[loader invalidate];
	delegate = nil;
	for (NSControl *control in @[updatePopup, updateButton, dropButton]) [control setTarget:nil];

	// The block may capture the tab
	[alertPresenter release], alertPresenter = nil;
}

- (NSTimeInterval)lockTimeout
{
	return [extensions lockTimeout];
}

- (void)setLockTimeout:(NSTimeInterval)timeout
{
	[extensions setLockTimeout:timeout];
}

/// The pane's data layer (retained: the caller releases it). A test seam: a subclass can return one that fails.
- (SPPostgresExtensions *)newExtensionsWithConnection:(PGPostgresConnection *)theConnection
{
	return [[SPPostgresExtensions alloc] initWithConnection:theConnection];
}

#pragma mark View

- (NSView *)view
{
	return view;
}

/// A read-only value next to its label (retained: the caller releases it).
- (NSTextField *)_newValueAtY:(CGFloat)y label:(NSString *)label width:(CGFloat)width
{
	NSFont *font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	NSTextField *title = [NSTextField labelWithString:label];
	[title setFont:font];
	[title setAlignment:NSTextAlignmentRight];
	[title setFrame:NSMakeRect(SPPostgresExtensionMargin, y, SPPostgresExtensionValueX - SPPostgresExtensionMargin - 8, 17)];
	[title setAutoresizingMask:NSViewMinYMargin];
	[view addSubview:title];

	NSTextField *field = [[NSTextField labelWithString:@""] retain];
	[field setFont:font];
	[field setSelectable:YES];
	[[field cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[field setFrame:NSMakeRect(SPPostgresExtensionValueX, y, width - SPPostgresExtensionValueX - SPPostgresExtensionMargin, 17)];
	[field setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[view addSubview:field];
	return field;
}

/// Name, Version, Schema, Comment and "Required by", then "Update to:" with the pop-up (or the note) and Update;
/// Drop… at the bottom right.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	CGFloat width = NSWidth(frame);
	NSFont *font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	CGFloat y = NSHeight(frame) - SPPostgresExtensionMargin - 17;
	nameField = [self _newValueAtY:y label:NSLocalizedString(@"Name:", @"Postgres extension: name label") width:width];
	[nameField setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
	y -= SPPostgresExtensionRowHeight;
	versionField = [self _newValueAtY:y label:NSLocalizedString(@"Version:", @"Postgres extension: installed version label") width:width];
	y -= SPPostgresExtensionRowHeight;
	schemaField = [self _newValueAtY:y label:NSLocalizedString(@"Schema:", @"Postgres extension: schema label") width:width];
	y -= SPPostgresExtensionRowHeight;
	commentField = [self _newValueAtY:y label:NSLocalizedString(@"Comment:", @"Postgres extension: comment label") width:width];
	y -= SPPostgresExtensionRowHeight;

	requiredByField = [[NSTextField labelWithString:@""] retain];
	[requiredByField setFont:font];
	[requiredByField setTextColor:[NSColor secondaryLabelColor]];
	[requiredByField setSelectable:YES];
	[[requiredByField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[requiredByField setFrame:NSMakeRect(SPPostgresExtensionValueX, y, width - SPPostgresExtensionValueX - SPPostgresExtensionMargin, 17)];
	[requiredByField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[view addSubview:requiredByField];
	y -= SPPostgresExtensionRowHeight + 12;

	// Update to: [pop-up] [Update], or the note in the pop-up's place
	NSTextField *updateTitle = [NSTextField labelWithString:NSLocalizedString(@"Update to:", @"Postgres extension: update target label")];
	[updateTitle setFont:font];
	[updateTitle setAlignment:NSTextAlignmentRight];
	[updateTitle setFrame:NSMakeRect(SPPostgresExtensionMargin, y + 3, SPPostgresExtensionValueX - SPPostgresExtensionMargin - 8, 17)];
	[updateTitle setAutoresizingMask:NSViewMinYMargin];
	[view addSubview:updateTitle];

	updatePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(SPPostgresExtensionValueX - 3, y - 1, SPPostgresExtensionPopupWidth + 6, 26) pullsDown:NO];
	[updatePopup setIdentifier:@"extensionUpdatePopup"];
	[updatePopup setFont:font];
	[updatePopup setAutoresizingMask:NSViewMinYMargin];
	[view addSubview:updatePopup];

	noUpdateLabel = [[NSTextField labelWithString:NSLocalizedString(@"No other version available", @"Postgres extension: no update target")] retain];
	[noUpdateLabel setFont:font];
	[noUpdateLabel setTextColor:[NSColor secondaryLabelColor]];
	[noUpdateLabel setFrame:NSMakeRect(SPPostgresExtensionValueX, y + 3, SPPostgresExtensionPopupWidth, 17)];
	[noUpdateLabel setAutoresizingMask:NSViewMinYMargin];
	[view addSubview:noUpdateLabel];

	updateButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Update", @"Postgres extension: update button") target:self action:@selector(update:)] retain];
	[updateButton setIdentifier:@"extensionUpdateButton"];
	NSSize size = [updateButton fittingSize];
	[updateButton setFrame:NSMakeRect(SPPostgresExtensionValueX + SPPostgresExtensionPopupWidth + 12, y - 4, MAX(size.width, 90), size.height)];
	[updateButton setAutoresizingMask:NSViewMinYMargin];
	[view addSubview:updateButton];

	// Drop…, bottom right
	dropButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Drop…", @"Postgres extension: drop button") target:self action:@selector(drop:)] retain];
	[dropButton setIdentifier:@"extensionDropButton"];
	[dropButton setHasDestructiveAction:YES];
	size = [dropButton fittingSize];
	size.width = MAX(size.width, 90);
	[dropButton setFrame:NSMakeRect(width - SPPostgresExtensionMargin - size.width, 12, size.width, size.height)];
	[dropButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[view addSubview:dropButton];
}

#pragma mark Alerts

- (void)_presentError:(NSError *)error title:(NSString *)title
{
	if (invalidated) return;

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:title];
	NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];

	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}
	NSWindow *window = [view window];
	if (window && ![window attachedSheet]) [alert beginSheetModalForWindow:window completionHandler:nil];
	else NSLog(@"%@: %@", [alert messageText], [alert informativeText]);
}

#pragma mark Loading

/// The runner's thread: the extension and its update targets, read through extensions alone. nil (with *error) when
/// the extension can't be read; otherwise "extension" (absent when it isn't installed) and "targets" (absent, with
/// "targetsError", when they can't be read).
static NSDictionary *SPPostgresExtensionRead(SPPostgresExtensions *extensions, NSString *name, NSError **error)
{
	NSError *readError = nil, *targetsError = nil;
	SPPostgresExtension *loaded = [extensions extensionNamed:name error:&readError];
	if (!loaded) {
		if (readError) {
			if (error) *error = readError;
			return nil;
		}
		return @{};
	}
	NSArray *targets = [extensions updateTargetsForExtension:name error:&targetsError];
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:loaded forKey:@"extension"];
	if (targets) [result setObject:targets forKey:@"targets"];
	else if (targetsError) [result setObject:targetsError forKey:@"targetsError"];
	return result;
}

// A load (a switch, -reload) goes through the pane loader (SPPostgresPaneLoader). On the runner's thread the work uses
// only the extensions object (made on the main thread, where nothing uses it while the runner is busy: changes are
// refused then) and a copy of the name. Update reads the extension again at once, on the main thread, as part of the
// change (-_load).

- (SPPostgresTaskRunner *)taskRunner
{
	return [loader taskRunner];
}

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	[loader setTaskRunner:runner];
}

- (BOOL)isStale
{
	return [loader isStale];
}

- (void)showExtension:(NSString *)name
{
	if (invalidated) return;
	[self setExtensionName:name];

	// The previous extension goes at once
	[self _applyExtension:nil targets:nil targetsError:nil];
	[self _loadSwitching:YES];
}

- (void)reload
{
	if (invalidated) return;
	[self _loadSwitching:NO];
}

/// Reads the extension through the runner (see -_applyResult:error:).
- (void)_loadSwitching:(BOOL)switching
{
	if (![extensionName length]) {
		[loader loadNothing];
		[self _applyExtension:nil targets:nil targetsError:nil];
		return;
	}

	SPPostgresExtensions *target = extensions;
	NSString *name = [[extensionName copy] autorelease];
	[loader loadSwitching:switching work:^id(PGPostgresConnection *theConnection, NSError **error) {
		return SPPostgresExtensionRead(target, name, error);
	} apply:^(id result, NSError *error) {
		[self _applyResult:result error:error];
	}];
}

/// Reads the extension on the main thread and shows it: part of a change, which runs only while the runner is idle.
- (void)_load
{
	if (![extensionName length]) {
		[self _applyExtension:nil targets:nil targetsError:nil];
		return;
	}
	NSError *error = nil;
	NSDictionary *result = SPPostgresExtensionRead(extensions, extensionName, &error);
	[self _applyResult:result error:error];
}

/// Shows what was read (SPPostgresExtensionRead); nil: it couldn't be read.
- (void)_applyResult:(NSDictionary *)result error:(NSError *)error
{
	if (!result) {
		// Always an alert for a failed read ("An unknown error occurred." without a message)
		[self _applyExtension:nil targets:nil targetsError:nil];
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the extension “%@”", @"Postgres extension: load failed"), extensionName]];
		return;
	}
	[self _applyExtension:[result objectForKey:@"extension"] targets:[result objectForKey:@"targets"] targetsError:[result objectForKey:@"targetsError"]];
}

/// Shows loaded (nil: empty: no extension, one that isn't installed (any more), or a failed read) and its update
/// targets. When only the update targets couldn't be read (loaded, no targets), the details
/// and Drop stay (Drop doesn't need them), Update is off, and targetsError is shown.
- (void)_applyExtension:(SPPostgresExtension *)loaded targets:(NSArray *)targets targetsError:(NSError *)targetsError
{
	[self setExtension:loaded];

	[nameField setStringValue:[loaded name] ?: @""];
	[versionField setStringValue:[loaded version] ?: @""];
	[schemaField setStringValue:[loaded schema] ?: @""];
	[commentField setStringValue:[loaded comment] ?: @""];
	[commentField setToolTip:[loaded comment]];

	NSArray *requiredBy = [loaded requiredBy];
	[requiredByField setStringValue:[requiredBy count] ? [NSString stringWithFormat:NSLocalizedString(@"Required by: %@", @"Postgres extension: the installed extensions that require it (comma-separated)"), [requiredBy componentsJoinedByString:@", "]] : @""];
	[requiredByField setHidden:![requiredBy count]];

	// The targets as the server names them (a version may look like a menu separator), the default marked and
	// preselected
	[updatePopup removeAllItems];
	NSString *defaultVersion = [loaded defaultVersion];
	NSMenuItem *selected = nil;
	for (NSString *target in targets) {
		BOOL isDefault = [target isEqualToString:defaultVersion];
		NSString *title = isDefault ? [NSString stringWithFormat:NSLocalizedString(@"%@ (default)", @"Postgres extension: the server's default version in the update pop-up"), target] : target;
		NSMenuItem *item = [[updatePopup menu] addItemWithTitle:title action:NULL keyEquivalent:@""];
		[item setRepresentedObject:target];
		if (isDefault) selected = item;
	}
	if (selected) [updatePopup selectItem:selected];

	BOOL hasTargets = [targets count] > 0;
	[updatePopup setHidden:!hasTargets];
	[updatePopup setEnabled:hasTargets];
	[noUpdateLabel setHidden:(hasTargets || !loaded)];
	[updateButton setEnabled:hasTargets];
	[dropButton setEnabled:(loaded != nil)];

	if (loaded && !targets) {
		[self _presentError:targetsError title:[NSString stringWithFormat:NSLocalizedString(@"Could not read the versions “%@” can be updated to", @"Postgres extension: update targets read failed"), extensionName]];
	}
}

#pragma mark Actions

/// YES (after NSBeep) while the runner is busy: a change runs on the main thread, so never while a load uses the
/// connection.
- (BOOL)_refuseChangeWhileBusy
{
	return [loader refuseChangeWhileBusy];
}

- (IBAction)update:(id)sender
{
	if (invalidated || !extension || [self _refuseChangeWhileBusy]) return;
	NSString *version = [[updatePopup selectedItem] representedObject];
	if (![version length]) return;

	NSString *name = [[extensionName copy] autorelease];
	NSError *error = nil;
	BOOL updated = [extensions updateExtension:name toVersion:version error:&error];
	if (!updated) [self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not update the extension “%@”", @"Postgres extension: update failed"), name]];

	// Inside an aborted transaction nothing was sent and nothing can be read: keep what is shown
	if (updated || [connection transactionStatus] != PGPostgresTransactionInError) [self _load];

	// Last: the tab reloads its lists
	[[self retain] autorelease];
	if (updated && !invalidated) [delegate extensionController:self didChangeExtension:name];
}

- (IBAction)drop:(id)sender
{
	if (invalidated || !extension || [self _refuseChangeWhileBusy]) return;
	[[self retain] autorelease];
	[delegate extensionController:self wantsToDropExtension:[[extensionName copy] autorelease]];
}

@end
