#import "SPPostgresCSVMappingSheet.h"

static const CGFloat SPMappingRowHeight = 28;

@implementation SPPostgresCSVMappingSheet
{
	NSArray *tables;
	NSArray *csvColumnNames;
	NSArray *previewRows;
	NSArray *(^columnsProvider)(NSString *, NSString *, NSError **);

	NSArray *tableColumns;          // @{name, generated} of the target
	NSMutableArray *columnPopupList;

	NSPanel *sheet;
	NSPopUpButton *tablePopup;
	NSTableView *previewTable;
	NSScrollView *columnsScrollView;
	NSTextField *columnsNote;
	NSButton *importButton;
	NSButton *cancelButton;

	void (^completion)(BOOL);
	NSString *lastErrorMessage;
}

@synthesize sheet;
@synthesize tablePopup;
@synthesize previewTable;
@synthesize importButton;
@synthesize cancelButton;
@synthesize lastErrorMessage;

- (instancetype)initWithTables:(NSArray *)theTables
				 selectedTable:(NSArray *)selectedTable
				csvColumnNames:(NSArray *)theNames
				   previewRows:(NSArray *)theRows
			   columnsProvider:(NSArray *(^)(NSString *, NSString *, NSError **))theProvider
{
	if ((self = [super init])) {
		tables = [(theTables ?: @[]) copy];
		csvColumnNames = [(theNames ?: @[]) copy];
		previewRows = [(theRows ?: @[]) copy];
		columnsProvider = [theProvider copy];
		columnPopupList = [[NSMutableArray alloc] init];
		[self _buildSheet];
		NSUInteger index = selectedTable ? [tables indexOfObject:selectedTable] : NSNotFound;
		if (index != NSNotFound) [tablePopup selectItemAtIndex:(NSInteger)index];
		[self _loadColumns];
	}
	return self;
}

- (void)dealloc
{
	[previewTable setDataSource:nil];
	[previewTable setDelegate:nil];
	for (NSControl *control in [NSArray arrayWithObjects:tablePopup, importButton, cancelButton, nil]) [control setTarget:nil];
	for (NSPopUpButton *popup in columnPopupList) [popup setTarget:nil];
	[tables release];
	[csvColumnNames release];
	[previewRows release];
	[columnsProvider release];
	[tableColumns release];
	[columnPopupList release];
	[sheet release];
	[tablePopup release];
	[previewTable release];
	[columnsScrollView release];
	[columnsNote release];
	[importButton release];
	[cancelButton release];
	[completion release];
	[lastErrorMessage release];
	[super dealloc];
}

#pragma mark - Building

- (NSTextField *)_labelWithFrame:(NSRect)frame text:(NSString *)text
{
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setStringValue:text];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	[label setLineBreakMode:NSLineBreakByTruncatingTail];
	return label;
}

- (void)_buildSheet
{
	CGFloat width = 640, height = 560;
	sheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setContentMinSize:NSMakeSize(width, height)];
	NSView *content = [sheet contentView];

	NSTextField *heading = [self _labelWithFrame:NSMakeRect(20, height - 36, width - 40, 18) text:NSLocalizedString(@"Import CSV", @"Postgres CSV mapping sheet: heading")];
	[heading setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[heading setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:heading];

	// The target table
	NSTextField *tableLabel = [self _labelWithFrame:NSMakeRect(20, height - 70, 90, 18) text:NSLocalizedString(@"Import into:", @"Postgres CSV mapping sheet: target table label")];
	[tableLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:tableLabel];
	tablePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(112, height - 75, width - 132, 26) pullsDown:NO];
	for (NSArray *pair in tables) {
		[tablePopup addItemWithTitle:@""]; // titles may repeat; set after adding
		NSMenuItem *item = [tablePopup lastItem];
		[item setTitle:[NSString stringWithFormat:@"%@.%@", [pair objectAtIndex:0], [pair objectAtIndex:1]]];
		[item setRepresentedObject:pair];
	}
	[tablePopup setTarget:self];
	[tablePopup setAction:@selector(_tableChanged:)];
	[tablePopup setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:tablePopup];

	// The preview
	NSTextField *previewLabel = [self _labelWithFrame:NSMakeRect(20, height - 104, width - 40, 18) text:NSLocalizedString(@"Preview (the first rows of the file):", @"Postgres CSV mapping sheet: preview label")];
	[previewLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:previewLabel];
	NSScrollView *previewScroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, height - 290, width - 40, 180)] autorelease];
	[previewScroll setHasVerticalScroller:YES];
	[previewScroll setHasHorizontalScroller:YES];
	[previewScroll setAutohidesScrollers:YES];
	[previewScroll setBorderType:NSBezelBorder];
	[previewScroll setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	previewTable = [[NSTableView alloc] initWithFrame:[[previewScroll contentView] bounds]];
	[previewTable setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];
	[previewTable setAllowsColumnReordering:NO];
	[previewTable setUsesAlternatingRowBackgroundColors:YES];
	for (NSUInteger index = 0; index < [csvColumnNames count]; index++) {
		NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)index]] autorelease];
		[[column headerCell] setStringValue:[csvColumnNames objectAtIndex:index]];
		[column setEditable:NO];
		[column setWidth:120];
		[[column dataCell] setLineBreakMode:NSLineBreakByTruncatingTail];
		[previewTable addTableColumn:column];
	}
	[previewTable setDataSource:self];
	[previewTable setDelegate:self];
	[previewScroll setDocumentView:previewTable];
	[content addSubview:previewScroll];

	// The column mapping
	NSTextField *columnsLabel = [self _labelWithFrame:NSMakeRect(20, height - 318, width - 40, 18) text:NSLocalizedString(@"Fill each column of the table from:", @"Postgres CSV mapping sheet: columns label")];
	[columnsLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:columnsLabel];
	columnsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 56, width - 40, height - 380)];
	[columnsScrollView setHasVerticalScroller:YES];
	[columnsScrollView setAutohidesScrollers:YES];
	[columnsScrollView setBorderType:NSBezelBorder];
	[columnsScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[content addSubview:columnsScrollView];
	columnsNote = [[self _labelWithFrame:NSMakeRect(20, 34, width - 40, 18) text:@""] retain];
	[columnsNote setTextColor:[NSColor secondaryLabelColor]];
	[columnsNote setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[content addSubview:columnsNote];

	importButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 120, 4, 100, 32)];
	[importButton setBezelStyle:NSBezelStyleRounded];
	[importButton setTitle:NSLocalizedString(@"Import", @"Postgres CSV mapping sheet: import button")];
	[importButton setKeyEquivalent:@"\r"];
	[importButton setTarget:self];
	[importButton setAction:@selector(import:)];
	[importButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:importButton];

	cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 220, 4, 100, 32)];
	[cancelButton setBezelStyle:NSBezelStyleRounded];
	[cancelButton setTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[cancelButton setKeyEquivalent:@"\e"];
	[cancelButton setTarget:self];
	[cancelButton setAction:@selector(cancel:)];
	[cancelButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancelButton];
}

/// The target's columns, read again, and a pop-up per column preset by name, else by position.
- (void)_loadColumns
{
	for (NSPopUpButton *popup in columnPopupList) [popup setTarget:nil];
	[columnPopupList removeAllObjects];
	[tableColumns release];
	tableColumns = nil;

	NSArray *pair = [[tablePopup selectedItem] representedObject];
	NSError *error = nil;
	NSArray *columns = (pair && columnsProvider) ? columnsProvider([pair objectAtIndex:0], [pair objectAtIndex:1], &error) : @[];
	[lastErrorMessage release];
	lastErrorMessage = (columns || !error) ? nil : [[error localizedDescription] copy];
	tableColumns = [(columns ?: @[]) copy];

	// Preset: by name (case-insensitive); when no name matches, by position
	NSUInteger count = [tableColumns count];
	NSMutableArray *chosen = [NSMutableArray arrayWithCapacity:count];
	NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
	BOOL anyByName = NO;
	for (NSDictionary *column in tableColumns) {
		NSInteger match = -1;
		if (![[column objectForKey:@"generated"] boolValue]) {
			NSString *name = [column objectForKey:@"name"];
			for (NSUInteger index = 0; index < [csvColumnNames count]; index++) {
				if ([used containsIndex:index]) continue;
				if ([[csvColumnNames objectAtIndex:index] caseInsensitiveCompare:name] == NSOrderedSame) {
					match = (NSInteger)index;
					[used addIndex:index];
					anyByName = YES;
					break;
				}
			}
		}
		[chosen addObject:@(match)];
	}
	if (!anyByName) {
		for (NSUInteger index = 0; index < count; index++) {
			BOOL generated = [[[tableColumns objectAtIndex:index] objectForKey:@"generated"] boolValue];
			[chosen replaceObjectAtIndex:index withObject:@((!generated && index < [csvColumnNames count]) ? (NSInteger)index : -1)];
		}
	}

	CGFloat width = NSWidth([columnsScrollView frame]) - 20;
	NSView *list = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, MAX(count * SPMappingRowHeight + 8, NSHeight([[columnsScrollView contentView] bounds])))] autorelease];
	[list setAutoresizingMask:NSViewWidthSizable];
	CGFloat top = NSHeight([list frame]) - 4;
	for (NSUInteger index = 0; index < count; index++) {
		NSDictionary *column = [tableColumns objectAtIndex:index];
		BOOL generated = [[column objectForKey:@"generated"] boolValue];
		CGFloat y = top - (index + 1) * SPMappingRowHeight;
		NSString *title = generated ? [NSString stringWithFormat:NSLocalizedString(@"%@ (generated)", @"Postgres CSV mapping sheet: generated column"), [column objectForKey:@"name"]] : [column objectForKey:@"name"];
		NSTextField *label = [self _labelWithFrame:NSMakeRect(8, y + 5, 200, 18) text:title];
		[label setAlignment:NSTextAlignmentRight];
		[list addSubview:label];

		NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(216, y, width - 224, 26) pullsDown:NO] autorelease];
		[popup addItemWithTitle:NSLocalizedString(@"— Not imported —", @"Postgres CSV mapping sheet: column not imported")];
		for (NSString *name in csvColumnNames) {
			[popup addItemWithTitle:@""];
			[[popup lastItem] setTitle:name];
		}
		[popup selectItemAtIndex:[[chosen objectAtIndex:index] integerValue] + 1];
		[popup setEnabled:!generated];
		[popup setTarget:self];
		[popup setAction:@selector(_mappingChanged:)];
		[popup setAutoresizingMask:NSViewWidthSizable];
		[list addSubview:popup];
		[columnPopupList addObject:popup];
	}
	[columnsScrollView setDocumentView:list];
	[list scrollPoint:NSMakePoint(0, NSHeight([list frame]))];

	[self _updateControls];
}

- (void)_updateControls
{
	NSString *note = lastErrorMessage ?: @"";
	if (![note length] && ![csvColumnNames count]) note = NSLocalizedString(@"The file has no rows.", @"Postgres CSV mapping sheet: empty file");
	[columnsNote setStringValue:note];
	BOOL anyMapped = NO;
	for (id entry in [self mapping]) if (entry != [NSNull null]) anyMapped = YES;
	[importButton setEnabled:anyMapped];
}

- (void)_tableChanged:(id)sender
{
	[self _loadColumns];
}

- (void)_mappingChanged:(id)sender
{
	[self _updateControls];
}

#pragma mark - Values

- (NSArray *)columnPopups
{
	return [[columnPopupList copy] autorelease];
}

- (NSArray *)tableColumnNames
{
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[tableColumns count]];
	for (NSDictionary *column in tableColumns) [names addObject:[column objectForKey:@"name"]];
	return names;
}

- (NSString *)selectedSchema
{
	return [[[tablePopup selectedItem] representedObject] objectAtIndex:0];
}

- (NSString *)selectedTable
{
	NSArray *pair = [[tablePopup selectedItem] representedObject];
	return [pair count] > 1 ? [pair objectAtIndex:1] : nil;
}

- (NSArray *)mapping
{
	NSMutableArray *mapping = [NSMutableArray arrayWithCapacity:[columnPopupList count]];
	for (NSUInteger index = 0; index < [columnPopupList count]; index++) {
		NSPopUpButton *popup = [columnPopupList objectAtIndex:index];
		BOOL generated = [[[tableColumns objectAtIndex:index] objectForKey:@"generated"] boolValue];
		NSInteger selected = [popup indexOfSelectedItem];
		if (generated || selected <= 0) [mapping addObject:[NSNull null]];
		else [mapping addObject:@(selected - 1)];
	}
	return mapping;
}

#pragma mark - Preview

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)[previewRows count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[previewRows count]) return nil;
	NSArray *fields = [previewRows objectAtIndex:(NSUInteger)row];
	NSUInteger column = (NSUInteger)[[tableColumn identifier] integerValue];
	if (column >= [fields count]) return @"";
	id value = [fields objectAtIndex:column];
	return value == [NSNull null] ? @"NULL" : value;
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[previewRows count]) return;
	NSArray *fields = [previewRows objectAtIndex:(NSUInteger)row];
	NSUInteger column = (NSUInteger)[[tableColumn identifier] integerValue];
	BOOL isNull = column < [fields count] && [fields objectAtIndex:column] == [NSNull null];
	if ([cell respondsToSelector:@selector(setTextColor:)]) [cell setTextColor:isNull ? [NSColor secondaryLabelColor] : [NSColor labelColor]];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

#pragma mark - Sheet

- (void)beginSheetForWindow:(NSWindow *)window completion:(void (^)(BOOL))theCompletion
{
	[completion release];
	completion = [theCompletion copy];
	[window beginSheet:sheet completionHandler:nil];
}

- (void)_endWithImport:(BOOL)import
{
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];
	void (^done)(BOOL) = [completion autorelease];
	completion = nil;
	if (done) done(import);
}

- (IBAction)import:(id)sender
{
	if (![importButton isEnabled]) return;
	[self _endWithImport:YES];
}

- (IBAction)cancel:(id)sender
{
	[self _endWithImport:NO];
}

- (void)cancelSheet
{
	[self _endWithImport:NO];
}

@end
