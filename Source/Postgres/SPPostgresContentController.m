#import "SPPostgresContentController.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import "SPPostgresTaskRunner.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPConstants.h"

// MySQL's Content tab (DBView.xib): 23 pt button bar, 32 x 25 textured buttons
static const CGFloat SPPostgresContentBottomBarHeight = 23;
static const CGFloat SPPostgresContentFilterBarHeight = 30;
static const CGFloat SPPostgresContentButtonWidth = 32;

// Column widths fitted to the header and the first rows, as MySQL's
static const CGFloat SPPostgresContentMinColumnWidth = 40;
static const CGFloat SPPostgresContentMaxColumnWidth = 300;
static const NSUInteger SPPostgresContentWidthSampleRows = 100;

static void *SPPostgresContentRunnerContext = &SPPostgresContentRunnerContext;

/// One page as a load fetched it (on the runner's thread), with the state it was asked for; applied on the main thread.
@interface SPPostgresContentPage : NSObject
@property (retain) SPPostgresFilter *filter;
@property (copy) NSString *sortColumn;
@property BOOL ascending;
@property NSUInteger page;
@property NSUInteger pageCount;
@property NSInteger matchingRowCount;
@property NSInteger tableRowCount;
@property (retain) NSArray *rows;
@end

@implementation SPPostgresContentPage

- (void)dealloc
{
	[_filter release];
	[_sortColumn release];
	[_rows release];
	[super dealloc];
}

@end

/// The grid: ⌫ / ⌦ (no ⌘, ⌥ or ⌃, no cell being edited) delete the selected rows, as the Delete button's tooltip says.
@interface SPPostgresContentGrid : SPTableView
@end

@implementation SPPostgresContentGrid

- (void)keyDown:(NSEvent *)event
{
	unsigned short keyCode = [event keyCode];
	NSEventModifierFlags modifiers = [event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl);
	if ((keyCode == 51 || keyCode == 117) && !modifiers && ![self currentEditor] && [self numberOfSelectedRows] > 0) {
		[(SPPostgresContentController *)[self delegate] removeRows:self];
		return;
	}
	[super keyDown:event];
}

@end

@interface SPPostgresContentController ()

@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *table;
@property (readwrite, copy) NSString *countText;
@property (readwrite, copy) NSString *noticeText;

@end

@implementation SPPostgresContentController
{
	PGPostgresConnection *connection;
	SPPostgresTableData *tableData;
	NSArray *columns;               // SPPostgresColumn, in grid order (identifier = index)
	NSMutableArray *rows;           // NSArray of NSString / NSNull
	BOOL editable;
	BOOL loaded;                    // the current table's rows loaded at least once (the grid and counts are its own)
	BOOL loadingTable;              // a table switch hasn't loaded its first rows yet ("Loading table data...")
	BOOL needsShow;                 // a table switch was cancelled before its columns came: Refresh shows the table again
	BOOL switchPending;             // -showTable:inSchema: asked for a table whose rows haven't loaded yet
	BOOL stale;                     // a table switch was cancelled (see -isStale)
	NSUInteger loadGeneration;      // taken by each load (and by -invalidate): only the latest one's completion is applied
	BOOL endingEdit;                // inside -_endEditing (a commit then leaves the reload to its caller)
	BOOL reloadOwed;                // a commit inside -_endEditing wants the rows reloaded
	BOOL committingInGrid;          // reloading from inside the grid's own commit (which must not be ended again)
	BOOL reloadPending;             // a grid commit's reload waits for the grid's editing to end (background runner)

	SPPostgresFilter *filter;       // nil: no filter
	NSString *sortColumn;           // nil: primary-key order
	BOOL sortAscending;
	NSUInteger currentPage;
	NSUInteger pageCount;
	NSInteger matchingRowCount;     // rows matching the filter
	NSInteger tableRowCount;        // rows in the table

	NSView *view;
	SPPostgresContentGrid *tableView;
	NSScrollView *scrollView;

	NSPopUpButton *filterColumnPopup;
	NSPopUpButton *filterComparisonPopup;
	NSTextField *filterValueField;
	NSButton *filterButton;

	NSButton *addButton;
	NSButton *removeButton;
	NSButton *duplicateButton;
	NSButton *refreshButton;
	NSButton *editModeButton;
	NSButton *filterToggleButton;
	NSButton *previousPageButton;
	NSButton *paginationButton;
	NSButton *nextPageButton;
	NSTextField *countField;
	NSTextField *noticeField;

	NSUserDefaults *defaults;
	BOOL observingRunner;           // observing taskRunner's busy (the bar is disabled while it is)
	BOOL invalidated;
}

@synthesize schema;
@synthesize table;
@synthesize countText;
@synthesize noticeText;
@synthesize currentPage;
@synthesize pageCount;
@synthesize alertPresenter;
@synthesize confirmationPresenter;
@synthesize taskRunner;
@synthesize stale;
@synthesize addButton;
@synthesize removeButton;
@synthesize duplicateButton;
@synthesize refreshButton;
@synthesize editModeButton;
@synthesize filterToggleButton;
@synthesize previousPageButton;
@synthesize paginationButton;
@synthesize nextPageButton;
@synthesize countField;
@synthesize defaults;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		defaults = [[NSUserDefaults standardUserDefaults] retain];
		rows = [[NSMutableArray alloc] init];
		columns = [@[] retain];
		currentPage = 1;
		pageCount = 1;
		sortAscending = YES;
		countText = [@"" copy];
		noticeText = [@"" copy];
		[self _buildView];
		[self setTaskRunner:[SPPostgresTaskRunner inlineRunnerWithConnection:theConnection]]; // updates the bar
	}

	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[taskRunner release];
	[defaults release];
	[tableData release];
	[columns release];
	[rows release];
	[filter release];
	[sortColumn release];
	[schema release];
	[table release];
	[countText release];
	[noticeText release];

	[view release];
	[tableView release];
	[scrollView release];
	[filterColumnPopup release];
	[filterComparisonPopup release];
	[filterValueField release];
	[filterButton release];
	[addButton release];
	[removeButton release];
	[duplicateButton release];
	[refreshButton release];
	[editModeButton release];
	[filterToggleButton release];
	[previousPageButton release];
	[paginationButton release];
	[nextPageButton release];
	[countField release];
	[noticeField release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;
	loadGeneration++;
	[self _stopObservingRunner];

	// An edit in progress must not call back into a controller that is going away
	if ([tableView currentEditor]) [tableView abortEditing];
	[tableView setDataSource:nil];
	[tableView setDelegate:nil];

	for (NSControl *control in @[filterColumnPopup, filterComparisonPopup, filterValueField, filterButton,
								 addButton, removeButton, duplicateButton, refreshButton, editModeButton, filterToggleButton,
								 previousPageButton, paginationButton, nextPageButton]) {
		[control setTarget:nil];
	}

	// The presenters may capture the tab
	[alertPresenter release];
	alertPresenter = nil;
	[confirmationPresenter release];
	confirmationPresenter = nil;
}

#pragma mark - The runner

- (SPPostgresTaskRunner *)taskRunner
{
	return [[taskRunner retain] autorelease];
}

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	if (runner == taskRunner) return;
	[self _stopObservingRunner];
	[taskRunner release];
	taskRunner = [runner retain];
	if (taskRunner && !invalidated) {
		[taskRunner addObserver:self forKeyPath:@"busy" options:0 context:SPPostgresContentRunnerContext];
		observingRunner = YES;
	}
	[self _updateBottomBar];
}

- (void)_stopObservingRunner
{
	if (!observingRunner) return;
	[taskRunner removeObserver:self forKeyPath:@"busy" context:SPPostgresContentRunnerContext];
	observingRunner = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context != SPPostgresContentRunnerContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	if (invalidated) return;

	// The runner changes busy on the main thread
	[self _updateBottomBar];
}

#pragma mark - Building the view

/// A 32 x 25 textured button of MySQL's bar. A nil action leaves it without a target (and disabled).
- (NSButton *)_newBarButtonWithImage:(NSString *)imageName alternateImage:(NSString *)alternateImageName toolTip:(NSString *)toolTip action:(SEL)action x:(CGFloat)x
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, -1, SPPostgresContentButtonWidth, 25)];
	[button setBezelStyle:NSBezelStyleTexturedRounded];
	[button setImage:[NSImage imageNamed:imageName]];
	if (alternateImageName) [button setAlternateImage:[NSImage imageNamed:alternateImageName]];
	[button setImagePosition:NSImageOnly];
	[button setToolTip:toolTip];
	[button setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	if (action) {
		[button setTarget:self];
		[button setAction:action];
	}
	else {
		[button setEnabled:NO];
	}
	return button;
}

- (NSButton *)_newBarButtonWithImage:(NSString *)imageName toolTip:(NSString *)toolTip action:(SEL)action x:(CGFloat)x
{
	return [self _newBarButtonWithImage:imageName alternateImage:nil toolTip:toolTip action:action x:x];
}

- (NSTextField *)_newLabelWithFrame:(NSRect)frame
{
	NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setDrawsBackground:NO];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	return label;
}

/// Filter bar (top), grid, bottom bar, as MySQL's Content tab.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	CGFloat width = NSWidth(frame);
	CGFloat height = NSHeight(frame);

	// Filter bar: column, comparison, value, Filter
	NSView *filterBar = [[[NSView alloc] initWithFrame:NSMakeRect(0, height - SPPostgresContentFilterBarHeight, width, SPPostgresContentFilterBarHeight)] autorelease];
	[filterBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];

	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

	filterColumnPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(8, 4, 150, 22) pullsDown:NO];
	[[filterColumnPopup cell] setControlSize:NSControlSizeSmall];
	[filterColumnPopup setFont:smallFont];
	[filterColumnPopup setToolTip:NSLocalizedString(@"The column to filter on", @"Postgres content: filter column tooltip")];
	[filterBar addSubview:filterColumnPopup];

	filterComparisonPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(162, 4, 110, 22) pullsDown:NO];
	[[filterComparisonPopup cell] setControlSize:NSControlSizeSmall];
	[filterComparisonPopup setFont:smallFont];
	[filterComparisonPopup addItemsWithTitles:@[@"=", @"≠", @">", @"<", @">=", @"<=", @"LIKE", @"NOT LIKE", @"ILIKE", @"IS NULL", @"IS NOT NULL", @"IN"]];
	[filterComparisonPopup setTarget:self];
	[filterComparisonPopup setAction:@selector(_filterComparisonChanged:)];
	[filterBar addSubview:filterComparisonPopup];

	filterButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 63, 6, 55, 19)];
	[filterButton setBezelStyle:NSBezelStyleRoundRect];
	[[filterButton cell] setControlSize:NSControlSizeSmall];
	[filterButton setFont:smallFont];
	[filterButton setTitle:NSLocalizedString(@"Filter", @"filter button title")];
	[filterButton setToolTip:NSLocalizedString(@"Query the current table using the filter conditions defined above", @"Postgres content: filter button tooltip")];
	[filterButton setAutoresizingMask:NSViewMinXMargin];
	[filterButton setTarget:self];
	[filterButton setAction:@selector(applyFilter:)];
	[filterBar addSubview:filterButton];

	filterValueField = [[NSTextField alloc] initWithFrame:NSMakeRect(278, 6, width - 63 - 8 - 278, 19)];
	[[filterValueField cell] setControlSize:NSControlSizeSmall];
	[filterValueField setFont:smallFont];
	[[filterValueField cell] setScrollable:YES];
	[[filterValueField cell] setPlaceholderString:NSLocalizedString(@"Value", @"Postgres content: filter value placeholder")];
	[filterValueField setAutoresizingMask:NSViewWidthSizable];
	[filterValueField setTarget:self];
	[filterValueField setAction:@selector(applyFilter:)];
	[filterBar addSubview:filterValueField];

	[view addSubview:filterBar];

	// Grid
	scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, SPPostgresContentBottomBarHeight, width, height - SPPostgresContentBottomBarHeight - SPPostgresContentFilterBarHeight)];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	tableView = [[SPPostgresContentGrid alloc] initWithFrame:[[scrollView contentView] bounds]];
	[tableView setUsesAlternatingRowBackgroundColors:YES];
	[tableView setAllowsMultipleSelection:YES];
	[tableView setAllowsColumnReordering:YES];
	[tableView setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];
	[tableView setFocusRingType:NSFocusRingTypeNone];
	[tableView setGridStyleMask:[defaults boolForKey:SPDisplayTableViewVerticalGridlines] ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	[tableView setDataSource:self];
	[tableView setDelegate:self];
	[scrollView setDocumentView:tableView];
	[view addSubview:scrollView];

	// Bottom bar, at DBView.xib's frames: + − duplicate refresh edit-mode filter | count, notice | previous, jump, next.
	// Duplicate, edit mode, the filter toggle and Jump to page are not wired yet (disabled, no action).
	SPButtonBar *bottomBar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresContentBottomBarHeight)] autorelease];
	[bottomBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];

	addButton = [self _newBarButtonWithImage:@"button_add" alternateImage:@"button_add" toolTip:NSLocalizedString(@"Add row (⌥⌘A)", @"add row button tooltip") action:@selector(addRow:) x:-1];
	[addButton setKeyEquivalent:@"a"];
	[addButton setKeyEquivalentModifierMask:NSEventModifierFlagOption | NSEventModifierFlagCommand];
	removeButton = [self _newBarButtonWithImage:@"button_remove" alternateImage:@"button_remove" toolTip:NSLocalizedString(@"Delete selected row(s) (⌫)", @"delete selected rows button tooltip") action:@selector(removeRows:) x:30];
	[removeButton setKeyEquivalent:@""];
	duplicateButton = [self _newBarButtonWithImage:@"button_duplicate" alternateImage:@"button_duplicate" toolTip:NSLocalizedString(@"Duplicate selected row (⌘D)", @"duplicate row button tooltip") action:NULL x:61];
	[duplicateButton setKeyEquivalent:@"d"];
	[duplicateButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	refreshButton = [self _newBarButtonWithImage:@"button_refresh" alternateImage:@"button_refresh" toolTip:NSLocalizedString(@"Refresh table contents (⌘R)", @"refresh table contents button tooltip") action:@selector(refresh:) x:93];
	[refreshButton setKeyEquivalent:@"r"];
	[refreshButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	editModeButton = [self _newBarButtonWithImage:@"button_edit_mode" alternateImage:@"button_edit_mode_selected" toolTip:NSLocalizedString(@"Toggle between editing simple text cells as a spreadsheet or in pop-up sheets", @"edit mode toggle button tooltip") action:NULL x:124];
	[editModeButton setButtonType:NSButtonTypeToggle];
	filterToggleButton = [self _newBarButtonWithImage:@"button_filter" alternateImage:@"button_filter_active" toolTip:NSLocalizedString(@"Show/Hide table content filters", @"show hide content filters button tooltip") action:NULL x:155];
	[filterToggleButton setButtonType:NSButtonTypeToggle];

	previousPageButton = [self _newBarButtonWithImage:@"button_left" alternateImage:@"button_left" toolTip:NSLocalizedString(@"View previous page of results", @"Postgres content: previous page tooltip") action:@selector(previousPage:) x:width - 110];
	paginationButton = [self _newBarButtonWithImage:@"button_pagination" toolTip:NSLocalizedString(@"Jump to page (⌘J) or view pagination options", @"jump to page button tooltip") action:NULL x:width - 79];
	[paginationButton setKeyEquivalent:@"j"];
	[paginationButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	nextPageButton = [self _newBarButtonWithImage:@"button_right" alternateImage:@"button_right" toolTip:NSLocalizedString(@"View next page of results", @"Postgres content: next page tooltip") action:@selector(nextPage:) x:width - 48];
	for (NSButton *button in @[previousPageButton, paginationButton, nextPageButton]) {
		[button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	}

	// The count (from MySQL's x 193) and the notice, up to 30 pt before Previous
	CGFloat textX = 193;
	CGFloat textWidth = (width - 140) - textX;
	CGFloat countWidth = floor(textWidth * 0.45);
	countField = [self _newLabelWithFrame:NSMakeRect(textX, 4, countWidth, 14)];
	[countField setAutoresizingMask:NSViewWidthSizable];
	noticeField = [self _newLabelWithFrame:NSMakeRect(textX + countWidth + 8, 4, textWidth - countWidth - 8, 14)];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[noticeField setAlignment:NSTextAlignmentRight];
	[noticeField setAutoresizingMask:NSViewWidthSizable | NSViewMinXMargin];

	for (NSView *subview in @[addButton, removeButton, duplicateButton, refreshButton, editModeButton, filterToggleButton,
							  countField, noticeField, previousPageButton, paginationButton, nextPageButton]) {
		[bottomBar addSubview:subview];
	}
	[view addSubview:bottomBar];

	[self _filterComparisonChanged:nil];
}

- (NSView *)view
{
	return view;
}

- (NSTableView *)tableView
{
	return tableView;
}

#pragma mark - Preferences

/// Rows per page, 0 for no limit (MySQL's "Limit results" preference).
- (NSUInteger)_pageSize
{
	if (![defaults boolForKey:SPLimitResults]) return 0;
	NSInteger size = [defaults integerForKey:SPLimitResultsValue];
	return size > 0 ? (NSUInteger)size : 0;
}

- (NSString *)_nullPlaceholder
{
	return [defaults stringForKey:SPNullValue] ?: @"NULL";
}

/// MySQL's result table font, or the small system font.
- (NSFont *)_tableFont
{
	NSData *data = [defaults dataForKey:SPGlobalResultTableFont];
	NSFont *font = nil;
	if (data) {
		@try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			font = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
		}
		@catch (NSException *exception) {
			font = nil;
		}
	}
	if (![font isKindOfClass:[NSFont class]]) font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	return font;
}

#pragma mark - Alerts

- (void)_presentAlert:(NSAlert *)alert
{
	if (invalidated) return;

	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}

	NSWindow *window = [view window];
	if (window && ![window attachedSheet]) [alert beginSheetModalForWindow:window completionHandler:nil];
	else NSLog(@"%@: %@", [alert messageText], [alert informativeText]);
}

/// A data-layer error as an alert: the server's message, or the row-changed message.
- (void)_presentError:(NSError *)error title:(NSString *)title
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];

	NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorRowChanged) {
		[alert setMessageText:NSLocalizedString(@"This row was changed or deleted by someone else.", @"Postgres content: row changed title")];
		[alert setInformativeText:NSLocalizedString(@"Nothing was changed. The rows have been reloaded to show their current contents.", @"Postgres content: row changed detail")];
	}
	else {
		[alert setMessageText:title];
		[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres content: unknown error")];
	}

	[self _presentAlert:alert];
}

- (void)_confirm:(NSAlert *)alert completion:(void (^)(BOOL confirmed))completion
{
	// A heap copy, so a presenter may keep it (even without copying it) until the answer comes. It runs once
	// and then balances its own Block_copy (deferred to the autorelease pool, as it is still running).
	void (^original)(BOOL) = completion;
	__block BOOL done = NO;
	__block void (^once)(BOOL) = nil;
	once = Block_copy(^(BOOL confirmed) {
		if (done) return;
		done = YES;
		original(confirmed);
		[(id)once autorelease];
	});

	if (confirmationPresenter) {
		confirmationPresenter(alert, once);
		return;
	}

	NSWindow *window = [view window];
	if (!window) {
		once([alert runModal] == NSAlertFirstButtonReturn);
		return;
	}
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		once(response == NSAlertFirstButtonReturn);
	}];
}

#pragma mark - Loading

// Every load follows the same steps. On the main thread: end the cell edit (so a commit is sent while the runner is
// idle) and take a new load generation. On the runner's thread: the work uses only the data layer (tableData, made on
// the main thread and used by the runner's thread only while its tasks run) and copies of the state asked for, never
// this controller. Back on the main thread: the completion is dropped if the controller was invalidated or a newer
// load was asked for; a cancelled load shows no alert and keeps what is shown; a failed one shows the error.

- (void)showTable:(NSString *)theTable inSchema:(NSString *)theSchema
{
	if (invalidated) return;
	if ([tableView currentEditor]) [tableView abortEditing];

	[self setTable:theTable];
	[self setSchema:theSchema];

	[tableData release];
	tableData = nil;
	[columns release];
	columns = [@[] retain];
	[rows removeAllObjects];
	[filter release];
	filter = nil;
	[sortColumn release];
	sortColumn = nil;
	sortAscending = YES;
	currentPage = 1;
	pageCount = 1;
	matchingRowCount = 0;
	tableRowCount = 0;
	editable = NO;
	loaded = NO;
	needsShow = NO;
	loadingTable = NO;
	stale = NO;
	NSUInteger generation = ++loadGeneration;

	if ([theTable length] && [theSchema length]) {
		tableData = [[SPPostgresTableData alloc] initWithConnection:connection schema:theSchema table:theTable];
		loadingTable = YES;
	}
	switchPending = (tableData != nil);

	// The previous table's columns, rows and counts go at once
	[self _showColumns];
	[tableView reloadData];
	[self _updateBottomBar];
	if (!tableData) return;

	// First the columns (shown as soon as they come, so a cancel leaves them), then the first page
	SPPostgresTableData *data = tableData;
	NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Loading %@...", @"Loading table task string"), theTable];
	[taskRunner runTaskWithDescription:description cancelTitle:NSLocalizedString(@"Stop", @"stop button") work:^id(PGPostgresConnection *theConnection, NSError **error) {
		NSArray *theColumns = [data columns:error];
		if (!theColumns) return nil;
		BOOL isEditable = [data isEditable];
		return @{@"columns" : theColumns, @"editable" : @(isEditable), @"readOnlyReason" : (isEditable ? nil : [data readOnlyReason]) ?: @""};
	} completion:^(id result, NSError *error, BOOL cancelled) {
		if (invalidated || generation != loadGeneration) return;

		if (!result) {
			loadingTable = NO;
			if (cancelled) needsShow = stale = YES;
			else {
				switchPending = NO;
				[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the columns of “%@”", @"Postgres content: columns failed"), theTable]];
			}
			[self _updateBottomBar];
			return;
		}

		[columns release];
		columns = [[result objectForKey:@"columns"] copy];
		editable = [[result objectForKey:@"editable"] boolValue];
		[self setNoticeText:[result objectForKey:@"readOnlyReason"]];
		[self _showColumns];
		[self _updateBottomBar];
		[self _loadWithFilter:nil sortColumn:nil ascending:YES page:1 description:description];
	}];
}

- (void)reload
{
	if (invalidated) return;
	if (needsShow) {
		[self showTable:table inSchema:schema];
		return;
	}
	if (![columns count]) return;
	[self _loadWithFilter:filter sortColumn:sortColumn ascending:sortAscending page:currentPage
			  description:NSLocalizedString(@"Reloading data...", @"Reloading data task description")];
}

/// The current columns in the grid, the filter bar and the notice.
- (void)_showColumns
{
	[self _rebuildColumns];
	[self _rebuildFilterBar];
	if (!editable && [columns count]) [noticeField setStringValue:noticeText];
	else {
		[self setNoticeText:@""];
		[noticeField setStringValue:@""];
	}
}

/**
 * Loads a page with the given state; only once it has loaded does that state become the current one. On failure
 * the error is shown and the grid keeps its rows (and the previous filter, sort and page); cancelled, it keeps them
 * without an alert.
 */
- (void)_loadWithFilter:(SPPostgresFilter *)theFilter sortColumn:(NSString *)theSortColumn ascending:(BOOL)ascending page:(NSUInteger)page
			description:(NSString *)description
{
	if (!tableData || ![columns count]) return;
	if (!committingInGrid) [self _endEditing];
	reloadPending = NO; // this load shows the rows as they are now
	stale = NO;
	NSUInteger generation = ++loadGeneration;

	// Everything the work needs, so it never reads this controller (the filter is never changed once made)
	SPPostgresTableData *data = tableData;
	NSString *theSort = [[theSortColumn copy] autorelease];
	NSUInteger pageSize = [self _pageSize];
	NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Could not load the rows of “%@”", @"Postgres content: load failed"), table];

	[taskRunner runTaskWithDescription:description cancelTitle:NSLocalizedString(@"Stop", @"stop button") work:^id(PGPostgresConnection *theConnection, NSError **error) {
		NSInteger matching = [data countRowsWithFilter:theFilter error:error];
		if (matching < 0) return nil;

		NSInteger total = matching;
		if (theFilter) {
			total = [data countRowsWithFilter:nil error:error];
			if (total < 0) return nil;
		}

		NSUInteger pages = 1;
		if (pageSize && matching > 0) pages = ((NSUInteger)matching + pageSize - 1) / pageSize;
		NSUInteger shownPage = MAX(1u, MIN(page, pages));

		NSArray *pageRows = [data rowsWithFilter:theFilter sortColumn:theSort ascending:ascending
										  offset:(shownPage - 1) * pageSize limit:pageSize error:error];
		if (!pageRows) return nil;

		SPPostgresContentPage *result = [[[SPPostgresContentPage alloc] init] autorelease];
		result.filter = theFilter;
		result.sortColumn = theSort;
		result.ascending = ascending;
		result.page = shownPage;
		result.pageCount = pages;
		result.matchingRowCount = matching;
		result.tableRowCount = total;
		result.rows = pageRows;
		return result;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		if (invalidated || generation != loadGeneration) return;
		BOOL firstRows = loadingTable;
		loadingTable = NO;
		if (cancelled) stale = switchPending;
		else switchPending = NO;

		if (result) [self _showPage:result];
		else if (!cancelled) [self _presentError:error title:title];
		[self _updateBottomBar];

		if (result && firstRows) [self _fitColumnWidths];
	}];
}

/// Makes a loaded page the current one.
- (void)_showPage:(SPPostgresContentPage *)page
{
	if ([page filter] != filter) {
		[filter release];
		filter = [[page filter] retain];
	}
	if ([page sortColumn] != sortColumn) {
		[sortColumn release];
		sortColumn = [[page sortColumn] copy];
	}
	sortAscending = [page ascending];
	currentPage = [page page];
	pageCount = [page pageCount];
	matchingRowCount = [page matchingRowCount];
	tableRowCount = [page tableRowCount];
	loaded = YES;

	[rows setArray:[page rows]];

	// Keep the selection where it still fits
	NSIndexSet *selection = [[[tableView selectedRowIndexes] copy] autorelease];
	[tableView reloadData];
	NSMutableIndexSet *kept = [NSMutableIndexSet indexSet];
	[selection enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < [rows count]) [kept addIndex:index];
	}];
	[tableView selectRowIndexes:kept byExtendingSelection:NO];

	[self _updateSortIndicators];
}

#pragma mark - Columns

- (SPPostgresColumn *)_columnForTableColumn:(NSTableColumn *)tableColumn
{
	NSInteger index = [[tableColumn identifier] integerValue];
	if (index < 0 || (NSUInteger)index >= [columns count]) return nil;
	return [columns objectAtIndex:(NSUInteger)index];
}

- (void)_rebuildColumns
{
	while ([[tableView tableColumns] count]) [tableView removeTableColumn:[[tableView tableColumns] lastObject]];

	NSFont *font = [self _tableFont];
	[tableView setRowHeight:2.0f + ceil([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : font}].height)];

	NSUInteger index = 0;
	for (SPPostgresColumn *column in columns) {
		NSTableColumn *tableColumn = [[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)index]] autorelease];
		[[tableColumn headerCell] setStringValue:[column name]];
		[tableColumn setHeaderToolTip:[NSString stringWithFormat:@"%@ – %@", [column name], [column typeName]]];
		[tableColumn setEditable:YES];
		[tableColumn setResizingMask:NSTableColumnUserResizingMask];
		[tableColumn setMinWidth:SPPostgresContentMinColumnWidth];

		NSTextFieldCell *cell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[cell setEditable:YES];
		[cell setScrollable:YES];
		[cell setLineBreakMode:NSLineBreakByClipping];
		[cell setFont:font];
		[tableColumn setDataCell:cell];

		[tableView addTableColumn:tableColumn];
		index++;
	}
}

/// Each column as wide as its header and its first rows, within limits.
- (void)_fitColumnWidths
{
	NSFont *font = [self _tableFont];
	NSDictionary *attributes = @{NSFontAttributeName : font};
	NSDictionary *headerAttributes = @{NSFontAttributeName : [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]};
	NSString *nullPlaceholder = [self _nullPlaceholder];
	NSUInteger sampleCount = MIN([rows count], SPPostgresContentWidthSampleRows);

	for (NSTableColumn *tableColumn in [tableView tableColumns]) {
		NSInteger index = [[tableColumn identifier] integerValue];
		CGFloat width = [[[tableColumn headerCell] stringValue] sizeWithAttributes:headerAttributes].width + 16;

		for (NSUInteger i = 0; i < sampleCount && width < SPPostgresContentMaxColumnWidth; i++) {
			id value = [[rows objectAtIndex:i] objectAtIndex:(NSUInteger)index];
			NSString *string = [value isKindOfClass:[NSString class]] ? value : nullPlaceholder;
			if ([string length] > 200) string = [string substringToIndex:200];
			width = MAX(width, [string sizeWithAttributes:attributes].width + 8);
		}

		[tableColumn setWidth:MIN(MAX(ceil(width), SPPostgresContentMinColumnWidth), SPPostgresContentMaxColumnWidth)];
	}
}

- (void)_updateSortIndicators
{
	NSTableColumn *sorted = nil;
	for (NSTableColumn *tableColumn in [tableView tableColumns]) {
		BOOL isSorted = sortColumn && [[[self _columnForTableColumn:tableColumn] name] isEqualToString:sortColumn];
		[tableView setIndicatorImage:isSorted ? [NSImage imageNamed:sortAscending ? @"NSAscendingSortIndicator" : @"NSDescendingSortIndicator"] : nil inTableColumn:tableColumn];
		if (isSorted) sorted = tableColumn;
	}
	[tableView setHighlightedTableColumn:sorted];
}

#pragma mark - Filter bar

- (void)_rebuildFilterBar
{
	NSString *previous = [filterColumnPopup titleOfSelectedItem];
	[filterColumnPopup removeAllItems];
	for (SPPostgresColumn *column in columns) [filterColumnPopup addItemWithTitle:[column name]];
	if (previous && [filterColumnPopup indexOfItemWithTitle:previous] >= 0) [filterColumnPopup selectItemWithTitle:previous];

	[filterValueField setStringValue:@""];
	BOOL hasColumns = [columns count] > 0;
	[filterColumnPopup setEnabled:hasColumns];
	[filterComparisonPopup setEnabled:hasColumns];
	[filterButton setEnabled:hasColumns];
	[self _filterComparisonChanged:nil];
}

- (BOOL)_comparisonTakesValue:(NSString *)comparison
{
	return ![comparison isEqualToString:@"IS NULL"] && ![comparison isEqualToString:@"IS NOT NULL"];
}

- (void)_filterComparisonChanged:(id)sender
{
	[filterValueField setEnabled:[columns count] && [self _comparisonTakesValue:[filterComparisonPopup titleOfSelectedItem]]];
}

- (IBAction)applyFilter:(id)sender
{
	if (invalidated || ![columns count]) return;
	[self _endEditing];

	NSString *column = [filterColumnPopup titleOfSelectedItem];
	NSString *comparison = [filterComparisonPopup titleOfSelectedItem];
	NSString *value = [filterValueField stringValue] ?: @"";

	// As MySQL's filter: an empty value means no filter
	SPPostgresFilter *newFilter = nil;
	if ([column length] && [comparison length] && (![self _comparisonTakesValue:comparison] || [value length])) {
		newFilter = [SPPostgresFilter filterWithColumn:column comparison:comparison value:value];
	}

	[self _loadWithFilter:newFilter sortColumn:sortColumn ascending:sortAscending page:1
			  description:NSLocalizedString(@"Filtering table...", @"Filtering table task description")];
}

#pragma mark - Bottom bar

- (void)_updateBottomBar
{
	NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
	[formatter setNumberStyle:NSNumberFormatterDecimalStyle];
	NSString *(^format)(NSInteger) = ^(NSInteger n) { return [formatter stringFromNumber:@(n)]; };

	NSMutableString *text = [NSMutableString string];
	if (loadingTable) {
		[text appendString:NSLocalizedString(@"Loading table data...", @"Loading table data string")];
	}
	else if (tableData && [columns count] && loaded) {
		NSUInteger pageSize = [self _pageSize];
		NSInteger shown = (NSInteger)[rows count];
		BOOL isLimited = pageSize && (NSUInteger)matchingRowCount > pageSize;
		NSInteger first = (NSInteger)((currentPage - 1) * pageSize) + 1;

		// MySQL's wording (-[SPTableContent updateCountText])
		if (!filter && !isLimited) {
			[text appendFormat:(shown == 1) ? NSLocalizedString(@"%@ row in table", @"text showing a single row in the result") : NSLocalizedString(@"%@ rows in table", @"text showing how many rows are in the result"), format(shown)];
		}
		else if (!filter) {
			[text appendFormat:NSLocalizedString(@"Rows %@ - %@ of %@%@ from table", @"text showing how many rows are in the limited result"), format(first), format(first + shown - 1), @"", format(tableRowCount)];
		}
		else if (!isLimited) {
			[text appendFormat:(shown == 1) ? NSLocalizedString(@"%@ row of %@%@ matches filter", @"text showing how a single rows matched filter") : NSLocalizedString(@"%@ rows of %@%@ match filter", @"text showing how many rows matched filter"), format(shown), @"", format(tableRowCount)];
		}
		else {
			[text appendFormat:NSLocalizedString(@"Rows %@ - %@ from filtered matches", @"text showing how many rows are in the limited filter match"), format(first), format(first + shown - 1)];
		}

		NSInteger selected = [tableView numberOfSelectedRows];
		if (selected > 0) {
			[text appendString:@"; "];
			[text appendFormat:NSLocalizedString(@"%@ %@ selected", @"text showing how many rows are selected"), format(selected), (selected == 1) ? NSLocalizedString(@"row", @"singular word for row") : NSLocalizedString(@"rows", @"plural word for rows")];
		}
	}

	[self setCountText:text];
	[countField setStringValue:text];
	[countField setToolTip:(pageCount > 1) ? [NSString stringWithFormat:NSLocalizedString(@"Page %lu of %lu", @"Postgres content: page tooltip"), (unsigned long)currentPage, (unsigned long)pageCount] : nil];

	// Before the table's rows have loaded only Refresh (to retry) is available; while the runner is busy nothing is
	// (MySQL: the bar follows the document's isWorking; the edit mode toggle, a preference, stays as it is)
	BOOL idle = ![taskRunner isBusy];
	BOOL hasTable = tableData && [columns count] && loaded;
	[refreshButton setEnabled:idle && ((tableData && [columns count]) || needsShow)];
	[addButton setEnabled:idle && hasTable && editable];
	[removeButton setEnabled:idle && hasTable && editable && [tableView numberOfSelectedRows] > 0];
	[previousPageButton setEnabled:idle && hasTable && currentPage > 1];
	[nextPageButton setEnabled:idle && hasTable && currentPage < pageCount];
}

/**
 * Commits a cell edit in progress, before an action that loads or writes (so the commit is sent while the runner is
 * idle, never from the busy state's focus change). Returns YES when the commit wants the rows reloaded: the caller
 * does it (a load does anyway).
 */
- (BOOL)_endEditing
{
	reloadOwed = NO;
	if (![tableView currentEditor]) return NO;
	endingEdit = YES;
	if (![[tableView window] makeFirstResponder:tableView]) [tableView abortEditing];
	endingEdit = NO;
	return reloadOwed;
}

- (IBAction)refresh:(id)sender
{
	[self reload];
}

- (IBAction)nextPage:(id)sender
{
	if (invalidated || currentPage >= pageCount) return;
	[self _loadPage:currentPage + 1];
}

- (IBAction)previousPage:(id)sender
{
	if (invalidated || currentPage <= 1) return;
	[self _loadPage:currentPage - 1];
}

- (void)_loadPage:(NSUInteger)page
{
	[self _loadWithFilter:filter sortColumn:sortColumn ascending:sortAscending page:page
			  description:[NSString stringWithFormat:NSLocalizedString(@"Loading page %lu...", @"Loading table page task string"), (unsigned long)page]];
}

#pragma mark - Rows

/// The short writes (add, delete, a cell edit) run on the main thread, so never while a load is using the connection.
- (BOOL)_refuseWriteWhileBusy
{
	// Also once the runner is invalidated (a database switch dropped it with its connection)
	if (![taskRunner isBusy] && ![taskRunner isInvalidated]) return NO;
	NSBeep();
	return YES;
}

- (IBAction)addRow:(id)sender
{
	if (invalidated || !tableData || !editable || !loaded) return;
	if ([self _refuseWriteWhileBusy]) return;

	// A cell being edited is saved first, and the rows reloaded (as Postgres has them, also after a failed save).
	// Inline: now, before the add. On a background runner the insert runs first, in this same idle moment (nothing is
	// queued yet, and a write never runs while busy), and the reload waits until the new row's edit ends (as after Tab).
	if ([self _endEditing]) {
		if ([taskRunner isInline]) [self reload];
		else reloadPending = YES;
	}

	// Every column gets its default (as MySQL's new row), then the user edits it in place
	NSError *error = nil;
	NSArray *row = [tableData insertRowWithValues:@{} error:&error];
	if (!row) {
		[self _presentError:error title:NSLocalizedString(@"Could not add a row", @"Postgres content: insert failed")];
		[self _reloadIfPending];
		return;
	}

	// Shown at the end of this page (to be edited in place), and counted: the pages to come are recomputed
	[rows addObject:row];
	matchingRowCount++;
	tableRowCount++;
	NSUInteger pageSize = [self _pageSize];
	if (pageSize) pageCount = MAX(currentPage, ((NSUInteger)matchingRowCount + pageSize - 1) / pageSize);
	[tableView reloadData];

	NSInteger newRow = (NSInteger)[rows count] - 1;
	[tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)newRow] byExtendingSelection:NO];
	[tableView scrollRowToVisible:newRow];
	[self _updateBottomBar];

	// Start editing the first column that can be edited
	if ([tableView window]) {
		for (NSTableColumn *tableColumn in [tableView tableColumns]) {
			if ([self tableView:tableView shouldEditTableColumn:tableColumn row:newRow]) {
				[[tableView window] makeFirstResponder:tableView];
				[tableView editColumn:[tableView columnWithIdentifier:[tableColumn identifier]] row:newRow withEvent:nil select:YES];
				break;
			}
		}
	}

	// No edit started: the saved cell's reload runs now
	[self _reloadIfPending];
}

- (IBAction)removeRows:(id)sender
{
	if (invalidated || !tableData || !editable || !loaded) return;
	if ([self _refuseWriteWhileBusy]) return;
	BOOL editWantsReload = [self _endEditing];

	NSIndexSet *selection = [tableView selectedRowIndexes];
	NSMutableArray *selectedRows = [NSMutableArray array];
	[selection enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < [rows count]) [selectedRows addObject:[rows objectAtIndex:index]];
	}];
	if (![selectedRows count]) {
		if (editWantsReload) [self reload];
		return;
	}

	// MySQL's confirmation (-[SPTableContent removeRow:]): ⌘D deletes, Return cancels
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"d"];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[[[alert buttons] objectAtIndex:1] setKeyEquivalent:@"\r"];
	[alert setAlertStyle:NSAlertStyleCritical];
	if ([selectedRows count] == 1) {
		[alert setMessageText:NSLocalizedString(@"Delete selected row?", @"delete selected row message")];
		[alert setInformativeText:NSLocalizedString(@"Are you sure you want to delete the selected row from this table? This action cannot be undone.", @"delete selected row informative message")];
	}
	else {
		[alert setMessageText:NSLocalizedString(@"Delete rows?", @"delete rows message")];
		[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the selected %ld rows from this table? This action cannot be undone.", @"delete rows informative message"), (long)[selectedRows count]]];
	}

	// The controller and the rows stay alive until the answer comes
	[self retain];
	NSArray *toDelete = [selectedRows copy];
	[self _confirm:alert completion:^(BOOL confirmed) {
		if (confirmed && !invalidated) [self _deleteRows:toDelete];
		else if (editWantsReload) [self reload];
		[toDelete release];
		[self release];
	}];
}

- (void)_deleteRows:(NSArray *)toDelete
{
	// A load may have started while the confirmation was up
	if ([self _refuseWriteWhileBusy]) return;

	NSError *error = nil;
	if (![tableData deleteRows:toDelete error:&error]) {
		[self _presentError:error title:NSLocalizedString(@"Could not delete the rows", @"Postgres content: delete failed")];
	}
	else {
		[tableView deselectAll:nil];
	}

	// Either way the grid shows what is on the server now
	[self reload];
}

#pragma mark - Table view data source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)theTableView
{
	return (NSInteger)[rows count];
}

- (id)tableView:(NSTableView *)theTableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return nil;
	NSArray *row = [rows objectAtIndex:(NSUInteger)rowIndex];
	NSInteger index = [[tableColumn identifier] integerValue];
	if (index < 0 || (NSUInteger)index >= [row count]) return nil;

	id value = [row objectAtIndex:(NSUInteger)index];
	return [value isKindOfClass:[NSString class]] ? value : [self _nullPlaceholder];
}

/// The end of a cell edit: updates that column of the row on the server, then shows the row as the server has it.
- (void)tableView:(NSTableView *)theTableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || !tableData || !editable || !loaded) return;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return;

	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	if (!column || [column isGenerated]) return;

	NSArray *originalRow = [[[rows objectAtIndex:(NSUInteger)rowIndex] retain] autorelease];
	id oldValue = [originalRow objectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue]];

	id newValue = [object isKindOfClass:[NSString class]] ? object : ([object respondsToSelector:@selector(stringValue)] ? [object stringValue] : nil);
	if (!newValue) newValue = [NSNull null];

	// As MySQL: the NULL placeholder means NULL where the column takes it
	if ([newValue isKindOfClass:[NSString class]] && [column nullable] && [newValue isEqualToString:[self _nullPlaceholder]]) newValue = [NSNull null];

	// Unchanged: nothing to send
	if ([newValue isEqual:oldValue]) return;

	// An edit ending while a load runs (something outside this view started one, as edits end before every load
	// here) is not sent: the grid goes on showing the row's loaded value
	if ([self _refuseWriteWhileBusy]) return;

	NSError *error = nil;
	if ([tableData updateRow:originalRow column:[column name] value:newValue error:&error]) {
		// Shown as sent until the reload brings Postgres's own format
		NSMutableArray *changedRow = [[originalRow mutableCopy] autorelease];
		[changedRow replaceObjectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue] withObject:newValue];
		[rows replaceObjectAtIndex:(NSUInteger)rowIndex withObject:changedRow];
	}
	else {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change “%@”", @"Postgres content: update failed"), [column name]]];
	}

	// Reload either way: after success Postgres's own format of the value (and of generated columns),
	// after a failure the row's current values. Committed by -_endEditing: its caller reloads.
	if (endingEdit) {
		reloadOwed = YES;
		return;
	}

	// Committed by the grid's own editing ending (Return, Tab, a click elsewhere) or called directly. Inline: now,
	// inside the commit, as before (the grid's next edit, after Tab, starts once this returns).
	BOOL gridEditing = [theTableView currentEditor] || [theTableView editedRow] >= 0;
	if (!gridEditing || [taskRunner isInline]) {
		committingInGrid = gridEditing;
		[self reload];
		committingInGrid = NO;
		return;
	}

	// Background: a load queued inside the commit would make the busy state take the focus and end this same edit
	// again, so the reload waits for the commit to finish, and for any edit started meanwhile (Tab) to end
	reloadPending = YES;
	dispatch_async(dispatch_get_main_queue(), ^{
		[self _reloadIfPending];
	});
}

/// The pending reload of a grid commit, unless a cell is being edited (it then runs when that edit ends).
- (void)_reloadIfPending
{
	if (invalidated || !reloadPending || [tableView currentEditor]) return;
	reloadPending = NO;
	[self reload];
}

/// The grid's editing ended (NSTableView, as an NSControl, tells its delegate).
- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	if (!reloadPending || [notification object] != tableView) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		[self _reloadIfPending];
	});
}

#pragma mark - Table view delegate

- (BOOL)tableView:(NSTableView *)theTableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || !tableData || !editable || !loaded || [taskRunner isBusy]) return NO;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return NO;

	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	return column && ![column isGenerated];
}

- (void)tableView:(NSTableView *)theTableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (![cell respondsToSelector:@selector(setTextColor:)]) return;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return;

	id value = [[rows objectAtIndex:(NSUInteger)rowIndex] objectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue]];

	// As MySQL's grid: NULL in grey, except in the selected rows
	BOOL isNull = ![value isKindOfClass:[NSString class]];
	[cell setTextColor:(isNull && ![theTableView isRowSelected:rowIndex]) ? [NSColor lightGrayColor] : [NSColor controlTextColor]];
}

/// Ascending on the first click, then toggles; from the first page.
- (void)tableView:(NSTableView *)theTableView didClickTableColumn:(NSTableColumn *)tableColumn
{
	if (invalidated || !tableData) return;
	[self _endEditing];

	NSString *name = [[self _columnForTableColumn:tableColumn] name];
	if (!name) return;

	// From the first page (MySQL keeps the page; the first rows of the new order are what's wanted)
	BOOL ascending = [name isEqualToString:sortColumn] ? !sortAscending : YES;
	[self _loadWithFilter:filter sortColumn:name ascending:ascending page:1
			  description:NSLocalizedString(@"Sorting table...", @"Sorting table task description")];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _updateBottomBar];
}

@end
