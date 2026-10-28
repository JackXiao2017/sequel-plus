#import "SPPostgresInstallExtensionSheet.h"
#import "SPPostgresExtensions.h"
#import "SPPostgresCatalog.h"
#import <PostgresKit/PostgresKit.h>

static const CGFloat SPPostgresInstallExtensionSheetWidth = 560;
static const CGFloat SPPostgresInstallExtensionSheetHeight = 420;
static const CGFloat SPPostgresInstallExtensionSheetMargin = 20;
static const CGFloat SPPostgresInstallExtensionSheetLabelWidth = 100;

/// The sheet that is open (the last one begun), for tests.
static SPPostgresInstallExtensionSheet *SPPostgresCurrentInstallExtensionSheet = nil;

@implementation SPPostgresInstallExtensionSheet
{
	PGPostgresConnection *connection;
	SPPostgresExtensions *extensions;
	NSString *chosenSchema;          // the schema the user chose (or the given default), for relocatable extensions
	NSArray *schemas;
	NSArray *available;              // SPPostgresAvailableExtension, sorted by name
	NSArray *filtered;               // those the filter leaves
	NSString *installedName;
	NSString *shownName;             // the extension whose versions, schema and requirements are shown, nil for none
	BOOL shown;                      // shownName is set (the controls were filled at least once)
	BOOL filtering;                  // in -_applyFilter: the table's passing selection changes are ignored
	NSString *loadErrorMessage;
	void (^completion)(NSString *);

	NSTextField *titleLabel;
	NSScrollView *tableScroll;
}

@synthesize sheet;
@synthesize extensionsTable;
@synthesize filterField;
@synthesize versionPopup;
@synthesize schemaPopup;
@synthesize alsoInstallsLabel;
@synthesize installButton;
@synthesize cancelButton;
@synthesize lastErrorMessage;
@synthesize alertPresenter;

#pragma mark - Begin

+ (void)beginWithConnection:(PGPostgresConnection *)theConnection schema:(NSString *)defaultSchema window:(NSWindow *)window completion:(void (^)(NSString *))theCompletion
{
	if (!theCompletion) return;
	if (!theConnection || !window || [window attachedSheet]) {
		theCompletion(nil);
		return;
	}

	SPPostgresInstallExtensionSheet *controller = [[self alloc] initWithConnection:theConnection schema:defaultSchema completion:theCompletion];
	[controller _beginOn:window]; // keeps itself until the sheet ends
	[controller release];
}

+ (SPPostgresInstallExtensionSheet *)currentSheet
{
	return SPPostgresCurrentInstallExtensionSheet;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection schema:(NSString *)defaultSchema completion:(void (^)(NSString *))theCompletion
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		extensions = [[SPPostgresExtensions alloc] initWithConnection:connection];
		chosenSchema = [defaultSchema copy];
		completion = [theCompletion copy];
		schemas = [@[] retain];
		available = [@[] retain];
		filtered = [@[] retain];
	}
	return self;
}

- (void)dealloc
{
	[extensionsTable setDataSource:nil];
	[extensionsTable setDelegate:nil];
	[extensionsTable setTarget:nil];
	[filterField setDelegate:nil];
	[filterField setTarget:nil];
	[versionPopup setTarget:nil];
	[schemaPopup setTarget:nil];
	[installButton setTarget:nil];
	[cancelButton setTarget:nil];

	[connection release];
	[extensions release];
	[chosenSchema release];
	[schemas release];
	[available release];
	[filtered release];
	[installedName release];
	[shownName release];
	[loadErrorMessage release];
	[lastErrorMessage release];
	[completion release];
	[alertPresenter release];

	[sheet release];
	[titleLabel release];
	[tableScroll release];
	[extensionsTable release];
	[filterField release];
	[versionPopup release];
	[schemaPopup release];
	[alsoInstallsLabel release];
	[installButton release];
	[cancelButton release];

	[super dealloc];
}

#pragma mark - Building

- (NSTextField *)_label:(NSString *)text frame:(NSRect)frame
{
	NSTextField *label = [NSTextField labelWithString:text];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[label setAlignment:NSTextAlignmentRight];
	[label setFrame:frame];
	[label setAutoresizingMask:NSViewMaxYMargin];
	return label;
}

- (NSPopUpButton *)_popupWithFrame:(NSRect)frame identifier:(NSString *)identifier action:(SEL)action
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
	[popup setIdentifier:identifier];
	[[popup cell] setControlSize:NSControlSizeSmall];
	[popup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[popup setTarget:self];
	[popup setAction:action];
	[popup setAutoresizingMask:NSViewMaxYMargin];
	return popup;
}

- (void)_addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width
{
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:identifier] autorelease];
	[[column headerCell] setStringValue:title];
	[[column dataCell] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[column dataCell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[column setEditable:NO];
	[column setWidth:width];
	[column setMinWidth:40];
	[extensionsTable addTableColumn:column];
}

- (void)_build
{
	CGFloat width = SPPostgresInstallExtensionSheetWidth;
	CGFloat height = SPPostgresInstallExtensionSheetHeight;
	CGFloat margin = SPPostgresInstallExtensionSheetMargin;
	CGFloat labelWidth = SPPostgresInstallExtensionSheetLabelWidth;
	CGFloat controlX = margin + labelWidth + 8;

	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setContentMinSize:NSMakeSize(460, 340)];
	NSString *title = NSLocalizedString(@"Install Extension", @"Postgres install extension sheet: title");
	[sheet setTitle:title];
	NSView *content = [sheet contentView];

	titleLabel = [[NSTextField labelWithString:title] retain];
	[titleLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[titleLabel setFrame:NSMakeRect(margin, height - 14 - 18, width - 2 * margin, 18)];
	[titleLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:titleLabel];

	// The filter
	filterField = [[NSSearchField alloc] initWithFrame:NSMakeRect(margin, height - 40 - 22, width - 2 * margin, 22)];
	[filterField setIdentifier:@"extensionFilter"];
	[[filterField cell] setPlaceholderString:NSLocalizedString(@"Filter", @"Postgres install extension sheet: filter placeholder")];
	[filterField setSendsSearchStringImmediately:YES];
	[filterField setTarget:self];
	[filterField setAction:@selector(_filterChanged:)];
	[filterField setDelegate:self];
	[filterField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:filterField];

	// The extensions on offer
	CGFloat tableBottom = 144;
	NSRect tableFrame = NSMakeRect(margin, tableBottom, width - 2 * margin, height - 70 - tableBottom);
	tableScroll = [[NSScrollView alloc] initWithFrame:tableFrame];
	[tableScroll setHasVerticalScroller:YES];
	[tableScroll setAutohidesScrollers:YES];
	[tableScroll setBorderType:NSBezelBorder];
	[tableScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	extensionsTable = [[NSTableView alloc] initWithFrame:[[tableScroll contentView] bounds]];
	[extensionsTable setIdentifier:@"extensionsTable"];
	[extensionsTable setRowHeight:17];
	[extensionsTable setAllowsEmptySelection:YES];
	[extensionsTable setAllowsMultipleSelection:NO];
	[extensionsTable setUsesAlternatingRowBackgroundColors:YES];
	[extensionsTable setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
	[self _addColumn:@"name" title:NSLocalizedString(@"Name", @"Postgres install extension sheet: name column") width:140];
	[self _addColumn:@"defaultVersion" title:NSLocalizedString(@"Default version", @"Postgres install extension sheet: default version column") width:100];
	[self _addColumn:@"comment" title:NSLocalizedString(@"Description", @"Postgres install extension sheet: description column") width:240];
	[extensionsTable setDataSource:self];
	[extensionsTable setDelegate:self];
	[extensionsTable setTarget:self];
	[extensionsTable setDoubleAction:@selector(_doubleClicked:)];
	[tableScroll setDocumentView:extensionsTable];
	[content addSubview:tableScroll];

	// Version and schema
	[content addSubview:[self _label:NSLocalizedString(@"Version:", @"Postgres install extension sheet: version label") frame:NSMakeRect(margin, 113, labelWidth, 16)]];
	versionPopup = [self _popupWithFrame:NSMakeRect(controlX, 110, 200, 22) identifier:@"extensionVersion" action:@selector(_versionChanged:)];
	[content addSubview:versionPopup];
	[content addSubview:[self _label:NSLocalizedString(@"Schema:", @"Postgres install extension sheet: schema label") frame:NSMakeRect(margin, 83, labelWidth, 16)]];
	schemaPopup = [self _popupWithFrame:NSMakeRect(controlX, 80, 200, 22) identifier:@"extensionSchema" action:@selector(_schemaChanged:)];
	[content addSubview:schemaPopup];

	// The missing requirements installed with it
	alsoInstallsLabel = [[NSTextField labelWithString:@""] retain];
	[alsoInstallsLabel setIdentifier:@"extensionAlsoInstalls"];
	[alsoInstallsLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[alsoInstallsLabel setTextColor:[NSColor secondaryLabelColor]];
	[alsoInstallsLabel setLineBreakMode:NSLineBreakByTruncatingTail];
	[alsoInstallsLabel setFrame:NSMakeRect(controlX, 54, width - controlX - margin, 16)];
	[alsoInstallsLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[alsoInstallsLabel setHidden:YES];
	[content addSubview:alsoInstallsLabel];

	// Buttons
	cancelButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(cancel:)] retain];
	[cancelButton setIdentifier:@"extensionCancelButton"];
	[cancelButton setKeyEquivalent:@"\e"];
	[cancelButton setFrame:NSMakeRect(width - 200, 12, 91, 28)];
	[cancelButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancelButton];
	installButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Install", @"Postgres install extension sheet: install button") target:self action:@selector(install:)] retain];
	[installButton setIdentifier:@"extensionInstallButton"];
	[installButton setKeyEquivalent:@"\r"];
	[installButton setFrame:NSMakeRect(width - 110, 12, 91, 28)];
	[installButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:installButton];

	[self _load];
	[sheet setInitialFirstResponder:filterField];
}

#pragma mark - Loading

- (void)_load
{
	NSError *error = nil;
	NSArray *offered = [extensions availableExtensions:&error];
	if (!offered) {
		[loadErrorMessage release];
		loadErrorMessage = [[error localizedDescription] copy];
		[lastErrorMessage release];
		lastErrorMessage = [loadErrorMessage copy];
	}
	[available release];
	available = [(offered ?: @[]) copy];

	SPPostgresCatalog *catalog = [[[SPPostgresCatalog alloc] initWithConnection:connection] autorelease];
	NSArray *names = [catalog schemaNames:NULL] ?: @[];
	[schemas release];
	schemas = [names copy];
	if (![schemas containsObject:chosenSchema]) {
		[chosenSchema release];
		chosenSchema = [[catalog defaultSchemaFromSchemas:schemas] copy];
	}

	[self _applyFilter];
}

/// The extensions the filter leaves (case-insensitive substring of the name or the description), keeping the
/// selection when it is still listed.
- (void)_applyFilter
{
	NSString *selected = [[[[self _selectedExtension] name] copy] autorelease];
	NSString *text = [[filterField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	NSMutableArray *matching = [NSMutableArray array];
	for (SPPostgresAvailableExtension *extension in available) {
		if (![text length]
			|| [[extension name] rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound
			|| ([extension comment] && [[extension comment] rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound)) {
			[matching addObject:extension];
		}
	}
	// The reload may drop the selection before it is restored: only where it ends up counts
	filtering = YES;
	[filtered release];
	filtered = [matching copy];
	[extensionsTable reloadData];

	NSInteger row = [self _rowOf:selected];
	if (row >= 0) [extensionsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	else [extensionsTable deselectAll:nil];
	filtering = NO;
	[self _selectionChanged];
}

- (NSInteger)_rowOf:(NSString *)name
{
	if (!name) return -1;
	for (NSUInteger row = 0; row < [filtered count]; row++) {
		if ([[[filtered objectAtIndex:row] name] isEqualToString:name]) return (NSInteger)row;
	}
	return -1;
}

- (SPPostgresAvailableExtension *)_selectedExtension
{
	NSInteger row = [extensionsTable selectedRow];
	if (row < 0 || row >= (NSInteger)[filtered count]) return nil;
	return [filtered objectAtIndex:(NSUInteger)row];
}

#pragma mark - The selection

- (BOOL)selectExtensionNamed:(NSString *)name
{
	if ([self _rowOf:name] < 0) {
		// Hidden by the filter: show everything
		BOOL offered = NO;
		for (SPPostgresAvailableExtension *extension in available) {
			if ([[extension name] isEqualToString:name]) offered = YES;
		}
		if (!offered) return NO;
		[filterField setStringValue:@""];
		[self _applyFilter];
	}

	NSInteger row = [self _rowOf:name];
	if (row < 0) return NO;
	[extensionsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	[extensionsTable scrollRowToVisible:row];
	[self _selectionChanged];
	return YES;
}

/// The selected extension's versions (its default preselected), its schema and its missing requirements; nothing
/// changes while the same extension stays selected (as when the filter is edited), so the chosen version stays.
- (void)_selectionChanged
{
	SPPostgresAvailableExtension *extension = [self _selectedExtension];
	NSString *name = [extension name];
	if (shown && (name == shownName || [name isEqualToString:shownName])) return;
	shown = YES;
	[shownName release];
	shownName = [name copy];

	[versionPopup removeAllItems];
	if (extension) {
		[versionPopup addItemsWithTitles:[extension versions] ?: @[]];
		if ([extension defaultVersion] && [versionPopup indexOfItemWithTitle:[extension defaultVersion]] >= 0) {
			[versionPopup selectItemWithTitle:[extension defaultVersion]];
		}
	}
	[versionPopup setEnabled:extension != nil];

	[self _updateSchemaPopup];
	[self _updateAlsoInstalls];
	[installButton setEnabled:extension != nil];
}

/// The database's schemas with the chosen one selected; a schema the control file fixes is shown instead, disabled.
- (void)_updateSchemaPopup
{
	SPPostgresAvailableExtension *extension = [self _selectedExtension];
	NSString *fixed = [extension fixedSchema];

	[schemaPopup removeAllItems];
	[schemaPopup addItemsWithTitles:schemas];
	if ([fixed length]) {
		if ([schemaPopup indexOfItemWithTitle:fixed] < 0) [schemaPopup addItemWithTitle:fixed];
		[schemaPopup selectItemWithTitle:fixed];
		[schemaPopup setEnabled:NO];
		return;
	}
	if (chosenSchema && [schemaPopup indexOfItemWithTitle:chosenSchema] >= 0) [schemaPopup selectItemWithTitle:chosenSchema];
	[schemaPopup setEnabled:extension != nil];
}

/// "Also installs: a, b" for the chosen version's missing requirements, hidden when there are none.
- (void)_updateAlsoInstalls
{
	SPPostgresAvailableExtension *extension = [self _selectedExtension];
	NSArray *missing = extension ? [extensions missingRequirementsForExtension:[extension name] version:[versionPopup titleOfSelectedItem] error:NULL] : nil;
	if ([missing count]) {
		[alsoInstallsLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Also installs: %@", @"Postgres install extension sheet: missing requirements"), [missing componentsJoinedByString:@", "]]];
		[alsoInstallsLabel setHidden:NO];
	}
	else {
		[alsoInstallsLabel setStringValue:@""];
		[alsoInstallsLabel setHidden:YES];
	}
}

- (void)_filterChanged:(id)sender
{
	[self _applyFilter];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	if ([notification object] == filterField) [self _applyFilter];
}

- (void)_versionChanged:(id)sender
{
	[self _updateAlsoInstalls];
}

- (void)_schemaChanged:(id)sender
{
	if (![schemaPopup isEnabled] || ![schemaPopup titleOfSelectedItem]) return;
	[chosenSchema release];
	chosenSchema = [[schemaPopup titleOfSelectedItem] copy];
}

- (void)_doubleClicked:(id)sender
{
	if ([extensionsTable clickedRow] >= 0) [self install:sender];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)[filtered count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[filtered count]) return nil;
	SPPostgresAvailableExtension *extension = [filtered objectAtIndex:(NSUInteger)row];
	NSString *identifier = [tableColumn identifier];
	if ([identifier isEqualToString:@"name"]) return [extension name];
	if ([identifier isEqualToString:@"defaultVersion"]) return [extension defaultVersion] ?: @"";
	return [extension comment] ?: @"";
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	if (filtering) return;
	[self _selectionChanged];
}

#pragma mark - Ending

- (void)_beginOn:(NSWindow *)window
{
	[self _build];

	[self retain]; // until the sheet ends
	SPPostgresCurrentInstallExtensionSheet = self;
	[window beginSheet:sheet completionHandler:^(NSModalResponse returnCode) {
		NSString *name = (returnCode == NSModalResponseOK) ? [[installedName copy] autorelease] : nil;
		[sheet orderOut:nil];
		if (SPPostgresCurrentInstallExtensionSheet == self) SPPostgresCurrentInstallExtensionSheet = nil;
		void (^done)(NSString *) = [[completion retain] autorelease];
		[completion release];
		completion = nil;
		if (done) done(name);
		[self release];
	}];

	// The list couldn't be read: say so (the sheet stays, empty)
	if (loadErrorMessage) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:NSLocalizedString(@"Could not read the available extensions", @"Postgres install extension sheet: list failed")];
		[alert setInformativeText:loadErrorMessage];
		[self _presentAlert:alert];
	}
}

- (void)_presentAlert:(NSAlert *)alert
{
	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}
	[alert beginSheetModalForWindow:sheet completionHandler:nil];
}

- (void)_endWithCode:(NSModalResponse)code
{
	if (!completion) return; // ended already
	// An alert still on the sheet goes first
	if ([sheet attachedSheet]) [sheet endSheet:[sheet attachedSheet]];
	NSWindow *parent = [sheet sheetParent];
	if (parent) [parent endSheet:sheet returnCode:code];
}

- (IBAction)install:(id)sender
{
	SPPostgresAvailableExtension *extension = [self _selectedExtension];
	if (!completion || !extension) {
		NSBeep();
		return;
	}

	NSString *name = [extension name];
	NSString *version = [versionPopup titleOfSelectedItem];
	NSString *schema = [[extension fixedSchema] length] ? nil : [schemaPopup titleOfSelectedItem];

	NSError *error = nil;
	if (![extensions installExtension:name version:version schema:schema error:&error]) {
		NSString *message = [error localizedDescription] ?: @"";
		[lastErrorMessage release];
		lastErrorMessage = [message copy];

		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Could not install the extension “%@”", @"Postgres install extension sheet: install failed"), name]];
		[alert setInformativeText:message];
		[self _presentAlert:alert];
		// What was missing may have changed meanwhile
		[self _updateAlsoInstalls];
		return;
	}

	[installedName release];
	installedName = [name copy];
	[self _endWithCode:NSModalResponseOK];
}

- (IBAction)cancel:(id)sender
{
	[self _endWithCode:NSModalResponseCancel];
}

@end
