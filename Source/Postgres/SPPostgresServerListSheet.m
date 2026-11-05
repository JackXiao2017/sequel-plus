#import "SPPostgresServerListSheet.h"

static SPPostgresServerListSheet *SPPostgresCurrentServerListSheet = nil;

/// The list's table: ⌘C (Edit ▸ Copy) goes to the sheet.
@interface SPPostgresServerListTableView : NSTableView
@property (assign) SPPostgresServerListSheet *owner;
@end

@implementation SPPostgresServerListTableView

@synthesize owner;

- (IBAction)copy:(id)sender
{
	[owner copy:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	if ([item action] == @selector(copy:)) return [self numberOfSelectedRows] > 0;
	return [super validateMenuItem:item];
}

@end

@implementation SPPostgresServerListSheet
{
	NSWindow *sheet;
	NSArray *columns;
	NSArray *rows;
	NSArray *displayedRows;
	SPPostgresServerListTableView *tableView;
	NSSearchField *filterField;
	NSTextField *countLabel;
	NSButton *refreshButton;
	NSButton *cancelQueryButton;
	NSButton *killButton;
	NSButton *closeButton;
	void (^refreshBlock)(void);
	void (^processAction)(NSDictionary *, BOOL);
	void (^completion)(void);
}

@synthesize sheet, rows, displayedRows, tableView, filterField, countLabel, refreshButton, cancelQueryButton, killButton, closeButton;

+ (SPPostgresServerListSheet *)currentSheet
{
	return SPPostgresCurrentServerListSheet;
}

+ (SPPostgresServerListSheet *)beginOnWindow:(NSWindow *)window title:(NSString *)title columns:(NSArray *)theColumns rows:(NSArray *)theRows refresh:(void (^)(void))refresh processAction:(void (^)(NSDictionary *, BOOL))action completion:(void (^)(void))theCompletion
{
	if (!window || [window attachedSheet] || SPPostgresCurrentServerListSheet) return nil;
	SPPostgresServerListSheet *list = [[self alloc] initWithTitle:title columns:theColumns refresh:refresh processAction:action completion:theCompletion];
	SPPostgresCurrentServerListSheet = list; // released when it closes
	[list setRows:theRows];
	[window beginSheet:list->sheet completionHandler:nil];
	[list->sheet makeFirstResponder:list->filterField];
	return list;
}

- (NSButton *)_buttonWithTitle:(NSString *)title action:(SEL)action
{
	NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
	[button sizeToFit];
	NSRect frame = [button frame];
	frame.size.width = MAX(frame.size.width + 12, 90);
	[button setFrame:frame];
	return [button retain];
}

- (instancetype)initWithTitle:(NSString *)title columns:(NSArray *)theColumns refresh:(void (^)(void))refresh processAction:(void (^)(NSDictionary *, BOOL))action completion:(void (^)(void))theCompletion
{
	if (!(self = [super init])) return nil;
	columns = [theColumns copy];
	refreshBlock = [refresh copy];
	processAction = [action copy];
	completion = [theCompletion copy];
	rows = [@[] retain];
	displayedRows = [@[] retain];

	NSRect frame = NSMakeRect(0, 0, 760, 460);
	sheet = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setTitle:title ?: @""];
	[sheet setContentMinSize:NSMakeSize(520, 300)];
	NSView *content = [sheet contentView];
	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

	NSTextField *titleLabel = [NSTextField labelWithString:title ?: @""];
	[titleLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[titleLabel setFrame:NSMakeRect(20, NSHeight(frame) - 34, 400, 18)];
	[titleLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:titleLabel];

	filterField = [[NSSearchField alloc] initWithFrame:NSMakeRect(NSWidth(frame) - 240, NSHeight(frame) - 38, 220, 22)];
	[[filterField cell] setPlaceholderString:NSLocalizedString(@"Filter", @"filter label")];
	[filterField setTarget:self];
	[filterField setAction:@selector(updateFilter:)];
	[filterField setDelegate:self];
	[filterField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
	[content addSubview:filterField];

	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 52, NSWidth(frame) - 40, NSHeight(frame) - 100)] autorelease];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setBorderType:NSBezelBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	tableView = [[SPPostgresServerListTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[tableView setOwner:self];
	[tableView setAllowsMultipleSelection:YES];
	[tableView setUsesAlternatingRowBackgroundColors:YES];
	[tableView setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
	for (NSDictionary *column in columns) {
		NSTableColumn *tableColumn = [[[NSTableColumn alloc] initWithIdentifier:[column objectForKey:@"key"]] autorelease];
		[[tableColumn headerCell] setStringValue:[column objectForKey:@"title"] ?: @""];
		[tableColumn setWidth:[[column objectForKey:@"width"] doubleValue] ?: 120];
		[[tableColumn dataCell] setFont:smallFont];
		[[tableColumn dataCell] setLineBreakMode:NSLineBreakByTruncatingTail];
		[tableColumn setEditable:NO];
		[tableView addTableColumn:tableColumn];
	}
	[tableView setRowHeight:16];
	[tableView setDataSource:self];
	[tableView setDelegate:self];
	[scrollView setDocumentView:tableView];
	[content addSubview:scrollView];

	countLabel = [[NSTextField labelWithString:@""] retain];
	[countLabel setFont:smallFont];
	[countLabel setTextColor:[NSColor secondaryLabelColor]];
	[countLabel setFrame:NSMakeRect(20, 20, 200, 14)];
	[countLabel setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[content addSubview:countLabel];

	// Right to left: Close, then (processes) Kill Connection, Cancel Query, then Refresh
	closeButton = [self _buttonWithTitle:NSLocalizedString(@"Close", @"close button") action:@selector(close:)];
	[closeButton setKeyEquivalent:@"\033"];
	CGFloat x = NSWidth(frame) - 14;
	NSMutableArray *buttons = [NSMutableArray arrayWithObject:closeButton];
	if (processAction) {
		killButton = [self _buttonWithTitle:NSLocalizedString(@"Kill Connection", @"Postgres process list: kill connection button") action:@selector(killConnection:)];
		cancelQueryButton = [self _buttonWithTitle:NSLocalizedString(@"Cancel Query", @"Postgres process list: cancel query button") action:@selector(cancelQuery:)];
		[buttons addObject:killButton];
		[buttons addObject:cancelQueryButton];
	}
	if (refreshBlock) {
		refreshButton = [self _buttonWithTitle:NSLocalizedString(@"Refresh", @"refresh button") action:@selector(refresh:)];
		[refreshButton setKeyEquivalent:@"r"];
		[refreshButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
		[buttons addObject:refreshButton];
	}
	for (NSButton *button in buttons) {
		NSRect buttonFrame = [button frame];
		x -= NSWidth(buttonFrame);
		buttonFrame.origin = NSMakePoint(x, 12);
		[button setFrame:buttonFrame];
		[button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
		[content addSubview:button];
	}

	return self;
}

- (void)dealloc
{
	[tableView setOwner:nil];
	[tableView setDataSource:nil];
	[tableView setDelegate:nil];
	[sheet release];
	[columns release];
	[rows release];
	[displayedRows release];
	[tableView release];
	[filterField release];
	[countLabel release];
	[refreshButton release];
	[cancelQueryButton release];
	[killButton release];
	[closeButton release];
	[refreshBlock release];
	[processAction release];
	[completion release];
	[super dealloc];
}

#pragma mark - Rows

- (NSArray *)_selectedRows
{
	NSMutableArray *selected = [NSMutableArray array];
	[[tableView selectedRowIndexes] enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < [displayedRows count]) [selected addObject:[displayedRows objectAtIndex:index]];
	}];
	return selected;
}

- (void)setRows:(NSArray *)newRows
{
	// The selection follows the processes (by pid)
	NSMutableSet *selectedPids = [NSMutableSet set];
	for (NSDictionary *row in [self _selectedRows]) {
		if ([row objectForKey:@"pid"]) [selectedPids addObject:[row objectForKey:@"pid"]];
	}
	NSIndexSet *selectedIndexes = [[[tableView selectedRowIndexes] copy] autorelease];

	[rows release];
	rows = [(newRows ?: @[]) copy];
	[self _applyFilter];

	NSMutableIndexSet *selection = [NSMutableIndexSet indexSet];
	if ([selectedPids count]) {
		[displayedRows enumerateObjectsUsingBlock:^(NSDictionary *row, NSUInteger index, BOOL *stop) {
			if ([selectedPids containsObject:[row objectForKey:@"pid"] ?: @""]) [selection addIndex:index];
		}];
	}
	else {
		[selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
			if (index < [displayedRows count]) [selection addIndex:index];
		}];
	}
	[tableView selectRowIndexes:selection byExtendingSelection:NO];
	[self _updateButtons];
}

- (void)_applyFilter
{
	NSString *filter = [[filterField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	NSMutableArray *shown = [NSMutableArray array];
	for (NSDictionary *row in rows) {
		if (![filter length]) {
			[shown addObject:row];
			continue;
		}
		for (NSDictionary *column in columns) {
			NSString *value = [row objectForKey:[column objectForKey:@"key"]];
			if ([value isKindOfClass:[NSString class]] && [value rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound) {
				[shown addObject:row];
				break;
			}
		}
	}
	[displayedRows release];
	displayedRows = [shown copy];
	[tableView reloadData];

	NSString *count = ([displayedRows count] == [rows count])
		? [NSString stringWithFormat:NSLocalizedString(@"%lu rows", @"Postgres server list: row count"), (unsigned long)[rows count]]
		: [NSString stringWithFormat:NSLocalizedString(@"%lu of %lu rows", @"Postgres server list: filtered row count"), (unsigned long)[displayedRows count], (unsigned long)[rows count]];
	[countLabel setStringValue:count];
}

- (IBAction)updateFilter:(id)sender
{
	[tableView deselectAll:nil];
	[self _applyFilter];
	[self _updateButtons];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	if ([notification object] == filterField) [self updateFilter:filterField];
}

- (void)_updateButtons
{
	NSArray *selected = [self _selectedRows];
	BOOL other = [selected count] == 1 && ![[[selected firstObject] objectForKey:@"own"] isEqualToString:@"true"];
	[cancelQueryButton setEnabled:other];
	[killButton setEnabled:other];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return (NSInteger)[displayedRows count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[displayedRows count]) return nil;
	NSString *value = [[displayedRows objectAtIndex:(NSUInteger)row] objectForKey:[tableColumn identifier]];
	// One line per row (a query's newlines)
	return [[value componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
}

- (NSString *)tableView:(NSTableView *)aTableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation
{
	if (row < 0 || row >= (NSInteger)[displayedRows count]) return nil;
	return [[displayedRows objectAtIndex:(NSUInteger)row] objectForKey:[tableColumn identifier]];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _updateButtons];
}

#pragma mark - Actions

- (NSString *)selectedRowsText
{
	NSArray *selected = [self _selectedRows];
	if (![selected count]) return nil;
	NSMutableArray *lines = [NSMutableArray array];
	for (NSDictionary *row in selected) {
		NSMutableArray *values = [NSMutableArray array];
		for (NSDictionary *column in columns) [values addObject:[row objectForKey:[column objectForKey:@"key"]] ?: @""];
		[lines addObject:[values componentsJoinedByString:@"\t"]];
	}
	return [lines componentsJoinedByString:@"\n"];
}

- (IBAction)copy:(id)sender
{
	NSString *text = [self selectedRowsText];
	if (!text) {
		NSBeep();
		return;
	}
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString:text forType:NSPasteboardTypeString];
}

- (IBAction)refresh:(id)sender
{
	if (refreshBlock) refreshBlock();
}

- (void)_signalTerminating:(BOOL)terminate
{
	NSArray *selected = [self _selectedRows];
	if ([selected count] != 1 || !processAction || ![cancelQueryButton isEnabled]) {
		NSBeep();
		return;
	}
	processAction([selected firstObject], terminate);
}

- (IBAction)cancelQuery:(id)sender
{
	[self _signalTerminating:NO];
}

- (IBAction)killConnection:(id)sender
{
	[self _signalTerminating:YES];
}

- (IBAction)close:(id)sender
{
	if (SPPostgresCurrentServerListSheet != self) return;
	SPPostgresCurrentServerListSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];

	void (^handler)(void) = [completion autorelease];
	completion = nil;
	[refreshBlock release], refreshBlock = nil;
	[processAction release], processAction = nil;
	if (handler) handler();
	[self autorelease];
}

@end
