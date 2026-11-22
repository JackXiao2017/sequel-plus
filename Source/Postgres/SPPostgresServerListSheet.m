#import "SPPostgresServerListSheet.h"

static SPPostgresServerListSheet *SPPostgresCurrentServerListSheet = nil;
/// The open windows (+openWindowWithTitle:…), each retained until it closes.
static NSMutableSet<SPPostgresServerListSheet *> *SPPostgresOpenServerListWindows = nil;

static NSString * const SPPostgresProcessListAutoRefresh = @"PostgresProcessListAutoRefresh";
static NSString * const SPPostgresProcessListAutoRefreshInterval = @"PostgresProcessListAutoRefreshInterval";
static const NSInteger SPPostgresProcessListDefaultInterval = 10;

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

@interface SPPostgresServerListSheet () <NSWindowDelegate>
@end

@implementation SPPostgresServerListSheet
{
	BOOL open;
	BOOL isWindow;
	BOOL refreshing;            // a refresh hasn't called its done yet
	NSUserDefaults *defaults;   // Auto Refresh's settings (windows only)
	NSButton *autoRefreshCheckbox;
	NSPopUpButton *autoRefreshIntervalPopUp;
	NSTimer *autoRefreshTimer;
	NSWindow *sheet;
	NSArray *columns;
	NSArray *rows;
	NSArray *displayedRows;
	SPPostgresServerListTableView *tableView;
	NSSearchField *filterField;
	NSTextField *countLabel;
	NSTextField *summaryLabel;
	NSButton *refreshButton;
	NSButton *cancelQueryButton;
	NSButton *killButton;
	NSButton *closeButton;
	void (^refreshBlock)(void (^done)(void));
	void (^processAction)(NSDictionary *, BOOL);
	void (^completion)(void);
}

@synthesize sheet, rows, displayedRows, tableView, filterField, countLabel, summaryLabel, refreshButton, cancelQueryButton, killButton, closeButton;
@synthesize open, autoRefreshCheckbox, autoRefreshIntervalPopUp;

+ (SPPostgresServerListSheet *)currentSheet
{
	return SPPostgresCurrentServerListSheet;
}

+ (SPPostgresServerListSheet *)beginOnWindow:(NSWindow *)window title:(NSString *)title columns:(NSArray *)theColumns rows:(NSArray *)theRows refresh:(void (^)(void (^)(void)))refresh processAction:(void (^)(NSDictionary *, BOOL))action completion:(void (^)(void))theCompletion
{
	if (!window || [window attachedSheet] || SPPostgresCurrentServerListSheet) return nil;
	SPPostgresServerListSheet *list = [[self alloc] initWithTitle:title columns:theColumns refresh:refresh processAction:action defaults:nil window:NO completion:theCompletion];
	SPPostgresCurrentServerListSheet = list; // released when it closes
	list->open = YES;
	[list setRows:theRows];
	[window beginSheet:list->sheet completionHandler:nil];
	[list->sheet makeFirstResponder:list->filterField];
	return list;
}

+ (SPPostgresServerListSheet *)openWindowWithTitle:(NSString *)title columns:(NSArray *)theColumns rows:(NSArray *)theRows refresh:(void (^)(void (^)(void)))refresh processAction:(void (^)(NSDictionary *, BOOL))action defaults:(NSUserDefaults *)theDefaults completion:(void (^)(void))theCompletion
{
	SPPostgresServerListSheet *list = [[[self alloc] initWithTitle:title columns:theColumns refresh:refresh processAction:action defaults:theDefaults window:YES completion:theCompletion] autorelease];
	if (!SPPostgresOpenServerListWindows) SPPostgresOpenServerListWindows = [[NSMutableSet alloc] init];
	[SPPostgresOpenServerListWindows addObject:list]; // until it closes
	list->open = YES;
	[list setRows:theRows];
	[list->sheet center];
	[list->sheet makeKeyAndOrderFront:nil];
	[list->sheet makeFirstResponder:list->filterField];
	[list _updateAutoRefresh];
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

- (instancetype)initWithTitle:(NSString *)title columns:(NSArray *)theColumns refresh:(void (^)(void (^)(void)))refresh processAction:(void (^)(NSDictionary *, BOOL))action defaults:(NSUserDefaults *)theDefaults window:(BOOL)asWindow completion:(void (^)(void))theCompletion
{
	if (!(self = [super init])) return nil;
	isWindow = asWindow;
	defaults = [(theDefaults ?: [NSUserDefaults standardUserDefaults]) retain];
	columns = [theColumns copy];
	refreshBlock = [refresh copy];
	processAction = [action copy];
	completion = [theCompletion copy];
	rows = [@[] retain];
	displayedRows = [@[] retain];

	NSRect frame = NSMakeRect(0, 0, isWindow ? 900 : 760, 460);
	NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable;
	if (isWindow) mask |= NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
	sheet = [[NSWindow alloc] initWithContentRect:frame styleMask:mask backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	if (isWindow) [sheet setDelegate:self];
	[sheet setTitle:title ?: @""];
	[sheet setContentMinSize:NSMakeSize(520, 300)];
	NSView *content = [sheet contentView];
	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

	NSTextField *titleLabel = [NSTextField labelWithString:title ?: @""];
	[titleLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[titleLabel sizeToFit];
	[titleLabel setFrame:NSMakeRect(20, NSHeight(frame) - 34, NSWidth([titleLabel frame]), 18)];
	[titleLabel setAutoresizingMask:NSViewMinYMargin];
	// A window has its title in its title bar
	if (!isWindow) [content addSubview:titleLabel];

	// Between the title and the filter field (it narrows with the sheet)
	CGFloat summaryX = isWindow ? 20 : NSMaxX([titleLabel frame]) + 12;
	summaryLabel = [[NSTextField labelWithString:@""] retain];
	[summaryLabel setFont:smallFont];
	[summaryLabel setTextColor:[NSColor secondaryLabelColor]];
	[summaryLabel setLineBreakMode:NSLineBreakByTruncatingTail];
	[summaryLabel setFrame:NSMakeRect(summaryX, NSHeight(frame) - 32, NSWidth(frame) - 252 - summaryX, 14)];
	[summaryLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[summaryLabel setHidden:YES];
	[content addSubview:summaryLabel];

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
	[countLabel setFrame:NSMakeRect(20, 20, (isWindow && refreshBlock) ? 110 : 200, 14)];
	[countLabel setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[content addSubview:countLabel];
	CGFloat leftEdge = NSMaxX([countLabel frame]);

	// A window's Auto Refresh: the checkbox, then how often
	if (isWindow && refreshBlock) {
		autoRefreshCheckbox = [[NSButton checkboxWithTitle:NSLocalizedString(@"Auto Refresh", @"Postgres process list: auto refresh checkbox") target:self action:@selector(toggleAutoRefresh:)] retain];
		[autoRefreshCheckbox setControlSize:NSControlSizeSmall];
		[autoRefreshCheckbox setFont:smallFont];
		[autoRefreshCheckbox sizeToFit];
		[autoRefreshCheckbox setFrameOrigin:NSMakePoint(leftEdge + 12, 18)];
		[autoRefreshCheckbox setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
		[content addSubview:autoRefreshCheckbox];

		autoRefreshIntervalPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		[autoRefreshIntervalPopUp setControlSize:NSControlSizeSmall];
		[autoRefreshIntervalPopUp setFont:smallFont];
		for (NSNumber *seconds in @[@1, @2, @5, @10, @30, @60]) {
			NSString *itemTitle = [seconds integerValue] == 1
				? NSLocalizedString(@"Every second", @"Postgres process list: auto refresh interval of one second")
				: [NSString stringWithFormat:NSLocalizedString(@"Every %ld seconds", @"Postgres process list: auto refresh interval in seconds"), (long)[seconds integerValue]];
			[autoRefreshIntervalPopUp addItemWithTitle:itemTitle];
			[[autoRefreshIntervalPopUp lastItem] setTag:[seconds integerValue]];
		}
		[autoRefreshIntervalPopUp setTarget:self];
		[autoRefreshIntervalPopUp setAction:@selector(setAutoRefreshInterval:)];
		[autoRefreshIntervalPopUp sizeToFit];
		[autoRefreshIntervalPopUp setFrameOrigin:NSMakePoint(NSMaxX([autoRefreshCheckbox frame]) + 6, 14)];
		[autoRefreshIntervalPopUp setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
		[content addSubview:autoRefreshIntervalPopUp];
		leftEdge = NSMaxX([autoRefreshIntervalPopUp frame]);

		NSInteger interval = [defaults integerForKey:SPPostgresProcessListAutoRefreshInterval];
		if (![autoRefreshIntervalPopUp selectItemWithTag:interval]) [autoRefreshIntervalPopUp selectItemWithTag:SPPostgresProcessListDefaultInterval];
		[autoRefreshCheckbox setState:[defaults boolForKey:SPPostgresProcessListAutoRefresh] ? NSControlStateValueOn : NSControlStateValueOff];
	}

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
		x -= 12; // room before the next button
	}
	// Narrowest: the buttons still clear of the row count (and Auto Refresh)
	CGFloat buttonsWidth = NSWidth(frame) - 14 - (x + 12);
	[sheet setContentMinSize:NSMakeSize(MAX(520, leftEdge + 12 + buttonsWidth + 14), 300)];

	return self;
}

- (void)dealloc
{
	[autoRefreshTimer invalidate];
	[autoRefreshTimer release];
	[autoRefreshCheckbox release];
	[autoRefreshIntervalPopUp release];
	[defaults release];
	[sheet setDelegate:nil];
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
	[summaryLabel release];
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

- (void)setSummary:(NSString *)text warning:(BOOL)warning
{
	[summaryLabel setStringValue:text ?: @""];
	[summaryLabel setTextColor:warning ? [NSColor systemRedColor] : [NSColor secondaryLabelColor]];
	[summaryLabel setHidden:![text length]];
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

/// Reads the rows again, unless the last read hasn't finished.
- (IBAction)refresh:(id)sender
{
	if (!open || !refreshBlock || refreshing) return;
	refreshing = YES;
	refreshBlock(^{ refreshing = NO; });
}

#pragma mark - Auto Refresh

- (IBAction)toggleAutoRefresh:(id)sender
{
	[defaults setBool:[autoRefreshCheckbox state] == NSControlStateValueOn forKey:SPPostgresProcessListAutoRefresh];
	[self _updateAutoRefresh];
}

- (IBAction)setAutoRefreshInterval:(id)sender
{
	[defaults setInteger:[autoRefreshIntervalPopUp selectedTag] forKey:SPPostgresProcessListAutoRefreshInterval];
	[self _updateAutoRefresh];
}

/// Starts, restarts or stops the timer as the checkbox and interval say.
- (void)_updateAutoRefresh
{
	[autoRefreshTimer invalidate];
	[autoRefreshTimer release], autoRefreshTimer = nil;
	BOOL on = open && autoRefreshCheckbox && [autoRefreshCheckbox state] == NSControlStateValueOn;
	[autoRefreshIntervalPopUp setEnabled:on];
	if (!on) return;
	NSTimeInterval interval = (NSTimeInterval)MAX([autoRefreshIntervalPopUp selectedTag], 1);
	autoRefreshTimer = [[NSTimer timerWithTimeInterval:interval target:self selector:@selector(_autoRefresh:) userInfo:nil repeats:YES] retain];
	[[NSRunLoop currentRunLoop] addTimer:autoRefreshTimer forMode:NSRunLoopCommonModes];
}

- (void)_autoRefresh:(NSTimer *)timer
{
	[self refresh:nil];
}

/// The title bar's close button.
- (void)windowWillClose:(NSNotification *)notification
{
	[self close:nil];
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
	if (!open) return;
	open = NO;
	[self _updateAutoRefresh]; // stops it
	[sheet setDelegate:nil];
	if (SPPostgresCurrentServerListSheet == self) SPPostgresCurrentServerListSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];

	void (^handler)(void) = [completion autorelease];
	completion = nil;
	[refreshBlock release], refreshBlock = nil;
	[processAction release], processAction = nil;
	if (handler) handler();
	// Let go of it: a sheet was retained by +beginOnWindow:…, a window by the open windows' set
	[[self retain] autorelease];
	if (isWindow) [SPPostgresOpenServerListWindows removeObject:self];
	else [self release];
}

@end
