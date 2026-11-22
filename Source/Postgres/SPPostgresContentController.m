#import "SPPostgresContentController.h"
#import "SPPostgresTableData.h"
#import "SPPostgresFilterRowsController.h"
#import "SPPostgresErrors.h"
#import "SPPostgresTaskRunner.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPConstants.h"
#import "SPPostgresFieldEditorSheet.h"
#import "SPPostgresDateTimePicker.h"
#import "SPPostgresPaginationView.h"
#import "SPPostgresRowsGrid.h"
#import "SPTextAndLinkCell.h"
#import "SPValuePopover.h"
#import "SPValueFormatter.h"
#import "SPForeignKeyPicker.h"
#import "SPForeignKeyPickerSettings.h"
#import "SPPostgresForeignKeyPickerSource.h"
#import <PostgresKit/PostgresKit.h>

// MySQL's Content tab (DBView.xib): 23 pt button bar, 32 x 25 textured buttons
static const CGFloat SPPostgresContentBottomBarHeight = 23;
static const CGFloat SPPostgresContentButtonWidth = 32;

// Column widths fitted to the header and the first rows, as MySQL's
static const CGFloat SPPostgresContentMinColumnWidth = 40;
static const CGFloat SPPostgresContentMaxColumnWidth = 300;
static const NSUInteger SPPostgresContentWidthSampleRows = 100;
/// Longer string values open in the field editor sheet rather than the in-cell editor (SPPostgresQueryDisplayLimit too).
static const NSUInteger SPPostgresContentInCellEditLimit = 10000;

static void *SPPostgresContentRunnerContext = &SPPostgresContentRunnerContext;
static void *SPPostgresContentDefaultsContext = &SPPostgresContentDefaultsContext;

/// One page as a load fetched it (on the runner's thread), with the state it was asked for; applied on the main thread.
@interface SPPostgresContentPage : NSObject
@property (copy) NSArray<SPPostgresFilter *> *filters;
@property (copy) NSString *sortColumn;
@property BOOL ascending;
@property NSUInteger page;
@property NSUInteger pageCount;
@property NSUInteger pageSize;          // the rows per page the load used (0: no limit)
@property NSInteger matchingRowCount;
@property NSInteger tableRowCount;
@property (retain) NSArray *rows;
@end

@implementation SPPostgresContentPage

- (void)dealloc
{
	[_filters release];
	[_sortColumn release];
	[_rows release];
	[super dealloc];
}

@end

/// The grid: ⌫ / ⌦ (no ⌘, ⌥ or ⌃, no cell being edited) delete the selected rows, as the Delete button's tooltip says.
@interface SPPostgresContentGrid : SPPostgresRowsGrid
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

@interface SPPostgresContentController () <SPPostgresRowsGridDelegate>

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
	NSDictionary *foreignKeys;      // column name → the referenced schema, table and column (-foreignKeyReferences)
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
	BOOL hasPendingRow;             // the last row is a new row not yet on the server (see -addRow:)
	NSMutableIndexSet *pendingEditedColumns; // the pending row's columns given a value (sent with the insert)

	NSArray *filters;               // the applied conditions (AND); empty: no filter
	NSString *sortColumn;           // nil: primary-key order
	BOOL sortAscending;
	NSUInteger currentPage;
	NSUInteger pageCount;
	NSUInteger shownPageSize;       // the rows per page the shown rows were loaded with (0: no limit)
	NSInteger matchingRowCount;     // rows matching the filter
	NSInteger tableRowCount;        // rows in the table

	NSView *view;
	SPPostgresContentGrid *tableView;
	NSScrollView *scrollView;

	SPPostgresFilterRowsController *filterRows; // the filter area (rows and their button bar)
	BOOL filterBarVisible;

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
	SPPostgresPaginationView *paginationView;   // made on defaults when first asked for
	NSPopover *paginationPopover;               // made when first shown

	NSUserDefaults *defaults;
	BOOL observingRunner;           // observing taskRunner's busy (the bar is disabled while it is)
	BOOL observingDefaults;         // observing defaults' SPEditInSheetEnabled (editModeButton follows it)
	BOOL fieldEditorPending;        // a field editor sheet is open (one at a time)
	BOOL pickerHandoff;             // the picker's value is going into the cell's in-place editor
	BOOL invalidated;
	SPValuePopover *valuePopover;   // the value popover this view opened (closed by loads and -invalidate)
	BOOL valuePopoverSaving;        // the value popover's Save is committing (its reload keeps the popover)
}

@synthesize schema;
@synthesize table;
@synthesize countText;
@synthesize noticeText;
@synthesize currentPage;
@synthesize pageCount;
@synthesize alertPresenter;
@synthesize confirmationPresenter;
@synthesize fieldEditorPresenter;
@synthesize foreignKeyFollower;
@synthesize foreignKeyPickerPresenter;
@synthesize valuePopoverPresenter;
@synthesize taskRunner;
@synthesize pasteboard;
@synthesize stale;
@synthesize addButton;
@synthesize removeButton;
@synthesize duplicateButton;
@synthesize refreshButton;
@synthesize editModeButton;
@synthesize filterToggleButton;
@synthesize filterBarVisible, filterRows;

- (NSArray<SPPostgresFilter *> *)appliedFilters
{
	return [[(filters ?: @[]) copy] autorelease];
}
@synthesize previousPageButton;
@synthesize paginationButton;
@synthesize nextPageButton;
@synthesize paginationPopover;
@synthesize countField;
@synthesize defaults;

#pragma mark - Columns

- (NSArray<NSString *> *)columnNames
{
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[columns count]];
	for (SPPostgresColumn *column in columns) [names addObject:[column name]];
	return names;
}

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		defaults = [[NSUserDefaults standardUserDefaults] retain];
		rows = [[NSMutableArray alloc] init];
		pendingEditedColumns = [[NSMutableIndexSet alloc] init];
		columns = [@[] retain];
		currentPage = 1;
		pageCount = 1;
		sortAscending = YES;
		countText = [@"" copy];
		noticeText = [@"" copy];
		[self _buildView];
		[self _startObservingDefaults];
		[self _updateEditModeButton];
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
	[foreignKeys release];
	[rows release];
	[pendingEditedColumns release];
	[filters release];
	[sortColumn release];
	[schema release];
	[table release];
	[countText release];
	[noticeText release];

	[view release];
	[tableView release];
	[scrollView release];
	[filterRows release];
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
	[paginationView release];
	[paginationPopover release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;
	loadGeneration++;
	[self _stopObservingRunner];
	[self _stopObservingDefaults];

	// An edit in progress must not call back into a controller that is going away
	if ([tableView currentEditor]) [tableView abortEditing];
	[tableView setDataSource:nil];
	[tableView setDelegate:nil];

	// The filter rows must not call back
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewFrameDidChangeNotification object:view];
	[filterRows invalidate];
	for (NSControl *control in @[addButton, removeButton, duplicateButton, refreshButton, editModeButton, filterToggleButton,
								 previousPageButton, paginationButton, nextPageButton]) {
		[control setTarget:nil];
	}

	// The popover and its content must not call back
	[paginationView setTarget:nil];
	[paginationPopover setDelegate:nil];
	[paginationPopover close];

	// The presenters may capture the tab
	[alertPresenter release];
	alertPresenter = nil;
	[confirmationPresenter release];
	[pasteboard release];
	confirmationPresenter = nil;
	[fieldEditorPresenter release];
	fieldEditorPresenter = nil;
	[foreignKeyFollower release];
	foreignKeyFollower = nil;
	[foreignKeyPickerPresenter release];
	foreignKeyPickerPresenter = nil;
	[self _closeValuePopover];
	[valuePopoverPresenter release];
	valuePopoverPresenter = nil;
	// The link arrows' and value icons' cells keep a plain pointer to this controller
	for (NSTableColumn *tableColumn in [tableView tableColumns]) {
		id cell = [tableColumn dataCell];
		if ([cell isKindOfClass:[SPTextAndLinkCell class]]) {
			[cell setTarget:nil action:NULL];
			[cell setValueTarget:nil action:NULL];
		}
	}
	// A date / time picker this view opened (its completion sees invalidated)
	if (fieldEditorPending) [[SPPostgresDateTimePicker currentPicker] cancel:nil];
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

#pragma mark - Preferences observed

- (void)setDefaults:(NSUserDefaults *)newDefaults
{
	if (newDefaults == defaults) return;
	[self _stopObservingDefaults];
	[defaults release];
	defaults = [newDefaults retain];
	[self _dropPaginationView];
	[self _startObservingDefaults];
	[self _updateEditModeButton];
}

- (void)_startObservingDefaults
{
	if (observingDefaults || !defaults || invalidated) return;
	[defaults addObserver:self forKeyPath:SPEditInSheetEnabled options:0 context:SPPostgresContentDefaultsContext];
	observingDefaults = YES;
}

- (void)_stopObservingDefaults
{
	if (!observingDefaults) return;
	[defaults removeObserver:self forKeyPath:SPEditInSheetEnabled context:SPPostgresContentDefaultsContext];
	observingDefaults = NO;
}

- (void)_updateEditModeButton
{
	if (invalidated) return;
	[editModeButton setState:[self _editsInSheet] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context == SPPostgresContentDefaultsContext) {
		// The preference may be changed on any thread
		if ([NSThread isMainThread]) [self _updateEditModeButton];
		else dispatch_async(dispatch_get_main_queue(), ^{ [self _updateEditModeButton]; });
		return;
	}
	if (context != SPPostgresContentRunnerContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	if (invalidated) return;

	// The runner changes busy on the main thread
	[self _updateBottomBar];

	// A load started while Jump to page is open: it closes (its Go would queue another load)
	if ([taskRunner isBusy] && [paginationPopover isShown]) [self _setPaginationShown:NO];
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

	// Filter area, as MySQL's: condition rows over Reset / Add Filter / Filter (laid out by -_layOutFilterArea)
	filterRows = [[SPPostgresFilterRowsController alloc] init];
	[[filterRows view] setFrame:NSMakeRect(0, height, width, 0)];
	[[filterRows view] setHidden:YES];
	[view addSubview:[filterRows view]];
	__block SPPostgresContentController *me = self; // not retained (MRC): the callbacks are cleared in -invalidate
	filterRows.onApply = ^{ [me applyFilter:nil]; };
	filterRows.onReset = ^{ [me _clearAppliedFilters]; };
	filterRows.onLastRowRemoved = ^{ [me _clearAppliedFilters]; };
	filterRows.onHeightChanged = ^{ [me _layOutFilterArea]; };
	[view setPostsFrameChangedNotifications:YES];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_viewFrameChanged:) name:NSViewFrameDidChangeNotification object:view];

	// Grid
	scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, SPPostgresContentBottomBarHeight, width, height - SPPostgresContentBottomBarHeight)];
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
	NSMenu *gridMenu = [self _newGridMenu];
	[tableView setMenu:gridMenu];
	[gridMenu release];
	[scrollView setDocumentView:tableView];
	[view addSubview:scrollView];

	// Bottom bar, at DBView.xib's frames: + − duplicate refresh edit-mode filter | count, notice | previous, jump, next.
	// Jump to page is not wired yet (disabled, no action).
	SPButtonBar *bottomBar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresContentBottomBarHeight)] autorelease];
	[bottomBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];

	addButton = [self _newBarButtonWithImage:@"button_add" alternateImage:@"button_add" toolTip:NSLocalizedString(@"Add row (⌥⌘A)", @"add row button tooltip") action:@selector(addRow:) x:-1];
	[addButton setKeyEquivalent:@"a"];
	[addButton setKeyEquivalentModifierMask:NSEventModifierFlagOption | NSEventModifierFlagCommand];
	removeButton = [self _newBarButtonWithImage:@"button_remove" alternateImage:@"button_remove" toolTip:NSLocalizedString(@"Delete selected row(s) (⌫)", @"delete selected rows button tooltip") action:@selector(removeRows:) x:30];
	[removeButton setKeyEquivalent:@""];
	duplicateButton = [self _newBarButtonWithImage:@"button_duplicate" alternateImage:@"button_duplicate" toolTip:NSLocalizedString(@"Duplicate selected row (⌘D)", @"duplicate row button tooltip") action:@selector(duplicateRow:) x:61];
	[duplicateButton setKeyEquivalent:@"d"];
	[duplicateButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	refreshButton = [self _newBarButtonWithImage:@"button_refresh" alternateImage:@"button_refresh" toolTip:NSLocalizedString(@"Refresh table contents (⌘R)", @"refresh table contents button tooltip") action:@selector(refresh:) x:93];
	[refreshButton setKeyEquivalent:@"r"];
	[refreshButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	editModeButton = [self _newBarButtonWithImage:@"button_edit_mode" alternateImage:@"button_edit_mode_selected" toolTip:NSLocalizedString(@"Toggle between editing simple text cells as a spreadsheet or in pop-up sheets", @"edit mode toggle button tooltip") action:@selector(toggleEditMode:) x:124];
	[editModeButton setButtonType:NSButtonTypeToggle];
	filterToggleButton = [self _newBarButtonWithImage:@"button_filter" alternateImage:@"button_filter_active" toolTip:NSLocalizedString(@"Show/Hide table content filters", @"show hide content filters button tooltip") action:@selector(toggleFilterBar:) x:155];
	[filterToggleButton setButtonType:NSButtonTypeToggle];

	previousPageButton = [self _newBarButtonWithImage:@"button_left" alternateImage:@"button_left" toolTip:NSLocalizedString(@"View previous page of results", @"Postgres content: previous page tooltip") action:@selector(previousPage:) x:width - 110];
	paginationButton = [self _newBarButtonWithImage:@"button_pagination" toolTip:NSLocalizedString(@"Jump to page (⌘J) or view pagination options", @"jump to page button tooltip") action:@selector(togglePagination:) x:width - 79];
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

	[self _setFilterBarVisible:[defaults boolForKey:SPRuleFilterEditorLastVisibilityChoice]];
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

/// MySQL's "edit in sheet" preference (the edit mode toggle).
- (BOOL)_editsInSheet
{
	return [defaults boolForKey:SPEditInSheetEnabled];
}

/// A value too long for the in-cell editor (over SPPostgresContentInCellEditLimit characters, as the Query results'
/// grid): that editor lays the whole value out as one line, and a few MB of it hangs the app. It opens in the field
/// editor sheet instead.
- (BOOL)_isLongValueInTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return NO;
	NSInteger index = [[tableColumn identifier] integerValue];
	NSArray *row = [rows objectAtIndex:(NSUInteger)rowIndex];
	if (index < 0 || (NSUInteger)index >= [row count]) return NO;
	id value = [row objectAtIndex:(NSUInteger)index];
	return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > SPPostgresContentInCellEditLimit;
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
	[self showTable:theTable inSchema:theSchema filter:nil];
}

- (void)showTable:(NSString *)theTable inSchema:(NSString *)theSchema filter:(SPPostgresFilter *)startFilter
{
	if (invalidated) return;
	if ([tableView currentEditor]) [tableView abortEditing];
	[self _closeValuePopover];

	[self setTable:theTable];
	[self setSchema:theSchema];

	[tableData release];
	tableData = nil;
	[columns release];
	columns = [@[] retain];
	[foreignKeys release];
	foreignKeys = [@{} retain];
	[rows removeAllObjects];
	[self _clearPendingRow];
	[filters release];
	filters = [@[] retain];
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
	[self _setFilterBarVisible:[defaults boolForKey:SPRuleFilterEditorLastVisibilityChoice]];

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
	SPPostgresFilter *theStartFilter = [[startFilter retain] autorelease];
	NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Loading %@...", @"Loading table task string"), theTable];
	[taskRunner runTaskWithDescription:description cancelTitle:NSLocalizedString(@"Stop", @"stop button") work:^id(PGPostgresConnection *theConnection, NSError **error) {
		NSArray *theColumns = [data columns:error];
		if (!theColumns) return nil;
		BOOL isEditable = [data isEditable];
		// Without its foreign keys the table still shows (with no link arrows)
		NSDictionary *references = [data foreignKeyReferences:NULL] ?: @{};
		return @{@"columns" : theColumns, @"editable" : @(isEditable), @"readOnlyReason" : (isEditable ? nil : [data readOnlyReason]) ?: @"",
				 @"foreignKeys" : references};
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
		[foreignKeys release];
		foreignKeys = [[result objectForKey:@"foreignKeys"] copy];
		editable = [[result objectForKey:@"editable"] boolValue];
		[self setNoticeText:[result objectForKey:@"readOnlyReason"]];
		[self _showColumns];
		[self _updateBottomBar];
		SPPostgresFilter *firstFilter = [[self columnNames] containsObject:[theStartFilter column] ?: @""] ? theStartFilter : nil;
		if (firstFilter) [self _showFilterInBar:firstFilter];
		[self _loadWithFilters:firstFilter ? @[firstFilter] : @[] sortColumn:nil ascending:YES page:1 description:description];
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
	[self _loadWithFilters:filters sortColumn:sortColumn ascending:sortAscending page:currentPage
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
- (void)_loadWithFilters:(NSArray<SPPostgresFilter *> *)theFilters sortColumn:(NSString *)theSortColumn ascending:(BOOL)ascending page:(NSUInteger)page
			 description:(NSString *)description
{
	// The rows it shows are going: a value popover open on one closes (not its own Save's reload)
	if (!valuePopoverSaving) [self _closeValuePopover];
	if (!tableData || ![columns count]) return;
	if (!committingInGrid) [self _endEditing];
	reloadPending = NO; // this load shows the rows as they are now
	stale = NO;
	NSUInteger generation = ++loadGeneration;

	// Everything the work needs, so it never reads this controller (the filters are never changed once made)
	SPPostgresTableData *data = tableData;
	NSArray *workFilters = [[(theFilters ?: @[]) copy] autorelease];
	NSString *theSort = [[theSortColumn copy] autorelease];
	NSUInteger pageSize = [self _pageSize];
	NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Could not load the rows of “%@”", @"Postgres content: load failed"), table];

	[taskRunner runTaskWithDescription:description cancelTitle:NSLocalizedString(@"Stop", @"stop button") work:^id(PGPostgresConnection *theConnection, NSError **error) {
		NSInteger matching = [data countRowsWithFilters:workFilters error:error];
		if (matching < 0) return nil;

		NSInteger total = matching;
		if ([workFilters count]) {
			total = [data countRowsWithFilters:@[] error:error];
			if (total < 0) return nil;
		}

		NSUInteger pages = 1;
		if (pageSize && matching > 0) pages = ((NSUInteger)matching + pageSize - 1) / pageSize;
		NSUInteger shownPage = MAX(1u, MIN(page, pages));

		NSArray *pageRows = [data rowsWithFilters:workFilters sortColumn:theSort ascending:ascending
										   offset:(shownPage - 1) * pageSize limit:pageSize error:error];
		if (!pageRows) return nil;

		SPPostgresContentPage *result = [[[SPPostgresContentPage alloc] init] autorelease];
		result.filters = workFilters;
		result.sortColumn = theSort;
		result.ascending = ascending;
		result.page = shownPage;
		result.pageCount = pages;
		result.pageSize = pageSize;
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
	if ([page filters] != filters) {
		[filters release];
		filters = [[page filters] retain];
	}
	if ([page sortColumn] != sortColumn) {
		[sortColumn release];
		sortColumn = [[page sortColumn] copy];
	}
	sortAscending = [page ascending];
	currentPage = [page page];
	pageCount = [page pageCount];
	shownPageSize = [page pageSize];
	matchingRowCount = [page matchingRowCount];
	tableRowCount = [page tableRowCount];
	loaded = YES;

	[rows setArray:[page rows]];
	[self _clearPendingRow]; // a pending row not inserted by now (its insert failed) is dropped with the old rows

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

		// As MySQL's grid: an arrow after a foreign key's value, to the referenced row; the value icon on a long text
		SPTextAndLinkCell *cell = [[[SPTextAndLinkCell alloc] initTextCell:@""] autorelease];
		[cell setAllowsExpansionToolTips:YES];
		if ([foreignKeys objectForKey:[column name]]) [cell setTarget:self action:@selector(_clickLinkArrow:)];
		if ([self _showsValueIconInColumn:column]) [cell setValueTarget:self action:@selector(_clickValueIcon:)];
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

		// Room for the link arrow (as MySQL's) and the value icon
		SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
		CGFloat arrowWidth = [foreignKeys objectForKey:[column name] ?: @""] ? 18 : 0;
		if ([self _showsValueIconInColumn:column]) arrowWidth += 20;
		[tableColumn setWidth:MIN(MAX(ceil(width + arrowWidth), SPPostgresContentMinColumnWidth), SPPostgresContentMaxColumnWidth + arrowWidth)];
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
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[columns count]];
	for (SPPostgresColumn *column in columns) [names addObject:[column name]];
	[filterRows setColumnNames:names]; // empties the rows: as MySQL's, a table starts with only Add Filter
}

/// The filter area as tall as its rows (capped at a third of the view above the bottom bar, the rows then scroll) at
/// the top, the grid below it; hidden, the grid takes its place. The rows always start above the area's button bar.
- (void)_layOutFilterArea
{
	NSRect bounds = [view bounds];
	CGFloat available = MAX(0, NSHeight(bounds) - SPPostgresContentBottomBarHeight);
	CGFloat areaHeight = filterBarVisible ? MIN([filterRows preferredHeight], floor(available / 3)) : 0;

	NSView *area = [filterRows view];
	[area setFrame:NSMakeRect(0, NSHeight(bounds) - areaHeight, NSWidth(bounds), areaHeight)];
	NSScrollView *rulesScroll = [[filterRows ruleEditor] enclosingScrollView];
	CGFloat rowsBottom = NSMinY([rulesScroll frame]);
	[rulesScroll setFrame:NSMakeRect(0, rowsBottom, NSWidth(bounds), MAX(0, areaHeight - rowsBottom))];

	NSRect gridFrame = [scrollView frame];
	gridFrame.origin.y = SPPostgresContentBottomBarHeight;
	gridFrame.size.width = NSWidth(bounds);
	gridFrame.size.height = MAX(0, NSHeight(bounds) - SPPostgresContentBottomBarHeight - areaHeight);
	[scrollView setFrame:gridFrame];
}

- (void)_viewFrameChanged:(NSNotification *)notification
{
	[self _layOutFilterArea];
}

/// Shows or hides the filter area (the grid takes its place when it is hidden) and sets the toggle to match. Hiding it
/// moves the focus out of it, to the grid.
- (void)_setFilterBarVisible:(BOOL)visible
{
	filterBarVisible = visible;
	[filterToggleButton setState:visible ? NSControlStateValueOn : NSControlStateValueOff];

	if (!visible) {
		NSWindow *window = [view window];
		id responder = [window firstResponder];
		// A text field being edited has the window's field editor as first responder, with the field as its delegate
		if ([responder isKindOfClass:[NSText class]] && [responder isFieldEditor]) responder = [(NSText *)responder delegate];
		if ([responder isKindOfClass:[NSView class]] && [responder isDescendantOf:[filterRows view]]) [window makeFirstResponder:tableView];
	}
	[[filterRows view] setHidden:!visible];
	[self _layOutFilterArea];
}

- (IBAction)toggleFilterBar:(id)sender
{
	if (invalidated) return;
	BOOL show = !filterBarVisible;
	[defaults setBool:show forKey:SPRuleFilterEditorLastVisibilityChoice];
	[self _setFilterBarVisible:show];

	if (show) {
		// Shown by the user with no rows: one empty row, as MySQL's (-setRuleEditorVisible:animate:)
		if (![filterRows numberOfRows]) [filterRows addRowAfter:-1 column:nil comparison:nil value:nil];
		// Shown by a click: ready to type a value (the rows are shown as typed, not applied)
		if (sender && [view window] && [filterRows numberOfRows]) [filterRows focusValueInRow:0];
		return;
	}

	// Hidden, the filter can't be seen or changed: it no longer applies (as MySQL's); the rows stay as typed
	[self _clearAppliedFilters];
}

/// With a filter applied, loads the first page unfiltered (keeping the sort).
- (void)_clearAppliedFilters
{
	if (invalidated || ![filters count]) return;
	[self _loadWithFilters:@[] sortColumn:sortColumn ascending:sortAscending page:1
			   description:NSLocalizedString(@"Filtering table...", @"Filtering table task description")];
}

/// The filter area shown (its preference unchanged) holding just theFilter, as if typed.
- (void)_showFilterInBar:(SPPostgresFilter *)theFilter
{
	[filterRows setFilters:@[theFilter]];
	if (!filterBarVisible) [self _setFilterBarVisible:YES];
	else [self _layOutFilterArea];
}

- (IBAction)applyFilter:(id)sender
{
	if (invalidated || ![columns count]) return;
	[self _endEditing];

	// As MySQL's filter: a row with an empty value is no condition; with none, the table loads unfiltered
	[self _loadWithFilters:[filterRows completeFilters] sortColumn:sortColumn ascending:sortAscending page:1
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
		NSUInteger pageSize = shownPageSize;
		NSInteger shown = (NSInteger)[rows count];
		BOOL isLimited = pageSize && (NSUInteger)matchingRowCount > pageSize;
		NSInteger first = (NSInteger)((currentPage - 1) * pageSize) + 1;

		// MySQL's wording (-[SPTableContent updateCountText])
		if (![filters count] && !isLimited) {
			[text appendFormat:(shown == 1) ? NSLocalizedString(@"%@ row in table", @"text showing a single row in the result") : NSLocalizedString(@"%@ rows in table", @"text showing how many rows are in the result"), format(shown)];
		}
		else if (![filters count]) {
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
	[duplicateButton setEnabled:idle && hasTable && editable && [tableView numberOfSelectedRows] == 1];
	[filterToggleButton setEnabled:idle && hasTable];
	[previousPageButton setEnabled:idle && hasTable && currentPage > 1];
	[nextPageButton setEnabled:idle && hasTable && currentPage < pageCount];
	[paginationButton setEnabled:idle && hasTable];
}

/**
 * Commits a cell edit in progress, before an action that loads or writes (so the commit is sent while the runner is
 * idle, never from the busy state's focus change). Returns YES when the commit wants the rows reloaded: the caller
 * does it (a load does anyway).
 */
- (BOOL)_endEditing
{
	reloadOwed = NO;
	if ([tableView currentEditor]) {
		endingEdit = YES;
		if (![[tableView window] makeFirstResponder:tableView]) [tableView abortEditing];
		endingEdit = NO;
	}

	// A new row not on the server yet is inserted now (on failure the error is shown and it stays pending)
	[self _insertPendingRow];
	return reloadOwed;
}

- (IBAction)toggleEditMode:(id)sender
{
	if (invalidated) return;
	[defaults setBool:([editModeButton state] == NSControlStateValueOn) forKey:SPEditInSheetEnabled];
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

#pragma mark - Jump to page

- (SPPostgresPaginationView *)paginationView
{
	if (!paginationView && !invalidated) {
		paginationView = [[SPPostgresPaginationView alloc] initWithDefaults:defaults];
		[paginationView setTarget:self];
		[paginationView setAction:@selector(_paginationGo:)];
	}
	return paginationView;
}

/// The defaults changed: the popover's content is made again, on the new ones, when next shown.
- (void)_dropPaginationView
{
	if ([paginationPopover isShown]) [self _setPaginationShown:NO];
	[paginationPopover setDelegate:nil];
	[paginationPopover release];
	paginationPopover = nil;
	[paginationView setTarget:nil];
	[paginationView release];
	paginationView = nil;
}

- (IBAction)togglePagination:(id)sender
{
	if (invalidated) return;
	// The popover needs the button on screen, and doesn't open while the runner is busy (its button is disabled)
	[self _setPaginationShown:![paginationPopover isShown] && [paginationButton window] && ![taskRunner isBusy]];
}

/// MySQL's -setPaginationViewVisibility:.
- (void)_setPaginationShown:(BOOL)shown
{
	[paginationButton setState:shown ? NSControlStateValueOn : NSControlStateValueOff];
	[paginationButton setImage:[NSImage imageNamed:shown ? @"button_action" : @"button_pagination"]];

	if (!shown) {
		if ([paginationPopover isShown]) [paginationPopover close];
		return;
	}

	SPPostgresPaginationView *content = [self paginationView];
	if (!paginationPopover) {
		paginationPopover = [[NSPopover alloc] init];
		[paginationPopover setBehavior:NSPopoverBehaviorTransient];
		[paginationPopover setDelegate:self];
		[paginationPopover setContentViewController:content];
		[paginationPopover setContentSize:[[content view] frame].size];
	}
	[content setMaxPage:pageCount];
	[content setPage:currentPage];
	[paginationPopover showRelativeToRect:[paginationButton bounds] ofView:paginationButton preferredEdge:NSMinYEdge];
	[content makeInputFirstResponder];
}

- (void)popoverDidClose:(NSNotification *)notification
{
	if (invalidated || [notification object] != paginationPopover) return;
	[self _setPaginationShown:NO];
}

- (void)_paginationGo:(SPPostgresPaginationView *)sender
{
	[self goToPage:[sender page]];
}

- (void)goToPage:(NSUInteger)page
{
	// Nothing is loaded while the runner is busy (the popover closes when it turns busy)
	if (invalidated || [taskRunner isBusy]) return;
	if ([paginationPopover isShown]) [self _setPaginationShown:NO];
	[self _loadPage:MAX(page, 1u)];
}

- (void)_loadPage:(NSUInteger)page
{
	[self _loadWithFilters:filters sortColumn:sortColumn ascending:sortAscending page:page
			   description:[NSString stringWithFormat:NSLocalizedString(@"Loading page %lu...", @"Loading table page task string"), (unsigned long)page]];
}

#pragma mark - Rows

/// The short writes (add, duplicate, delete, a cell edit) run on the main thread, so never while a load is using the connection.
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
	// A previous new row that couldn't be inserted is still being filled in
	if (hasPendingRow) {
		[self _reloadIfPending];
		return;
	}

	// A table with a required column (NOT NULL, no default): the row is added in the grid only, as MySQL's new row,
	// and inserted with the values given when the user leaves it (-_insertPendingRow). Otherwise every column gets its
	// default now, and the user edits the row in place.
	BOOL required = NO;
	for (SPPostgresColumn *column in columns) required = required || [self _columnIsRequired:column];

	NSInteger newRow;
	if (required) {
		NSMutableArray *row = [NSMutableArray array];
		for (NSUInteger index = 0; index < [columns count]; index++) [row addObject:[NSNull null]];
		newRow = [self _showInsertedRow:row];
		hasPendingRow = YES;
		[pendingEditedColumns removeAllIndexes];
	}
	else {
		NSError *error = nil;
		NSArray *row = [tableData insertRowWithValues:@{} error:&error];
		if (!row) {
			[self _presentError:error title:NSLocalizedString(@"Could not add a row", @"Postgres content: insert failed")];
			[self _reloadIfPending];
			return;
		}

		// Shown at the end of this page, to be edited in place (or in the sheet, in edit mode)
		newRow = [self _showInsertedRow:row];
	}

	// Start editing the first column that can be edited (of a pending row, the first required one)
	BOOL inSheet = [self _editsInSheet];
	if (inSheet || [tableView window]) {
		for (NSTableColumn *tableColumn in [tableView tableColumns]) {
			if (![self _canEditTableColumn:tableColumn row:newRow]) continue;
			if (required && ![self _columnIsRequired:[self _columnForTableColumn:tableColumn]]) continue;
			if (inSheet) {
				[self _editInSheetTableColumn:tableColumn row:newRow];
			}
			else {
				[[tableView window] makeFirstResponder:tableView];
				[tableView editColumn:[tableView columnWithIdentifier:[tableColumn identifier]] row:newRow withEvent:nil select:YES];
			}
			break;
		}
	}

	// No edit started: the saved cell's reload runs now
	[self _reloadIfPending];
}

/// Copies the selected row (MySQL's -duplicateRow:): a new row with its values, except generated and auto-numbered
/// columns, which get their defaults (a new serial or identity value). Shown as addRow:'s, without starting an edit.
- (IBAction)duplicateRow:(id)sender
{
	if (invalidated || !tableData || !editable || !loaded) return;
	if ([self _refuseWriteWhileBusy]) return;

	// A cell being edited is saved first (the copy then has its new value) and the rows reloaded, as in -addRow:
	if ([self _endEditing]) {
		if ([taskRunner isInline]) [self reload];
		else reloadPending = YES;
	}
	if (hasPendingRow) {
		[self _reloadIfPending];
		return;
	}

	NSInteger selected = [tableView numberOfSelectedRows];
	NSInteger selectedRow = [tableView selectedRow];
	if (selected != 1 || selectedRow < 0 || (NSUInteger)selectedRow >= [rows count]) {
		if (selected > 1) {
			// MySQL's message (-[SPTableContent duplicateRow:])
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setAlertStyle:NSAlertStyleWarning];
			[alert setMessageText:NSLocalizedString(@"Error", @"error")];
			[alert setInformativeText:NSLocalizedString(@"You can only copy single rows.", @"message of panel when trying to copy multiple rows")];
			[self _presentAlert:alert];
		}
		[self _reloadIfPending];
		return;
	}

	NSError *error = nil;
	NSArray *row = [tableData insertCopyOfRow:[rows objectAtIndex:(NSUInteger)selectedRow] error:&error];
	if (row) [self _showInsertedRow:row];
	else [self _presentError:error title:NSLocalizedString(@"Could not duplicate the row", @"Postgres content: duplicate failed")];

	[self _reloadIfPending];
}

/// An inserted row, shown at the end of this page, selected and scrolled to, and counted: the pages to come are
/// recomputed. Returns its index in the grid.
- (NSInteger)_showInsertedRow:(NSArray *)row
{
	[rows addObject:row];
	matchingRowCount++;
	tableRowCount++;
	NSUInteger pageSize = shownPageSize;
	if (pageSize) pageCount = MAX(currentPage, ((NSUInteger)matchingRowCount + pageSize - 1) / pageSize);
	[tableView reloadData];

	NSInteger newRow = (NSInteger)[rows count] - 1;
	[tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)newRow] byExtendingSelection:NO];
	[tableView scrollRowToVisible:newRow];
	[self _updateBottomBar];
	return newRow;
}

- (IBAction)removeRows:(id)sender
{
	if (invalidated || !tableData || !editable || !loaded) return;
	if ([self _refuseWriteWhileBusy]) return;

	// A selected new row not on the server yet is just dropped (as MySQL cancels a new row's edit)
	NSInteger pendingIndex = [self _pendingRowIndex];
	if (pendingIndex >= 0 && [[tableView selectedRowIndexes] containsIndex:(NSUInteger)pendingIndex]) {
		[self _dropPendingRow];
		if (![tableView numberOfSelectedRows]) return;
	}

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

#pragma mark - Copy as SQL INSERT

/// The selected rows' values (NSString, or NSNull for NULL), in the grid's column order (as shown), and in names the
/// columns' names. Generated columns are left out unless includingGenerated. Nil when nothing is selected.
- (NSArray<NSArray *> *)_selectedRowValuesIncludingGenerated:(BOOL)includingGenerated names:(NSMutableArray *)names
{
	NSIndexSet *selection = [tableView selectedRowIndexes];
	if (![selection count] || !tableData) return nil;

	NSMutableArray *indexes = [NSMutableArray array];
	for (NSTableColumn *tableColumn in [tableView tableColumns]) {
		SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
		if (!column || ([column isGenerated] && !includingGenerated)) continue;
		[names addObject:[column name]];
		[indexes addObject:[tableColumn identifier]];
	}
	if (![names count]) return nil;

	NSMutableArray *copied = [NSMutableArray array];
	[selection enumerateIndexesUsingBlock:^(NSUInteger rowIndex, BOOL *stop) {
		if (rowIndex >= [rows count]) return;
		NSArray *row = [rows objectAtIndex:rowIndex];
		NSMutableArray *values = [NSMutableArray arrayWithCapacity:[indexes count]];
		for (id identifier in indexes) {
			NSUInteger index = (NSUInteger)[identifier integerValue];
			[values addObject:index < [row count] ? [row objectAtIndex:index] : [NSNull null]];
		}
		[copied addObject:values];
	}];
	return copied;
}

/// Copy (and Copy with Column Names): the selected rows as tab-separated text, every shown column, NULL as the NULL
/// placeholder (MySQL's -rowsAsTabStringWithHeaders:...). Also as tabular text, as MySQL.
- (void)rowsGrid:(NSTableView *)grid copyRowsWithColumnNames:(BOOL)withColumnNames
{
	NSMutableArray *names = [NSMutableArray array];
	NSArray *copied = [self _selectedRowValuesIncludingGenerated:YES names:names];
	if (!copied) return;

	NSString *text = SPPostgresTabText(withColumnNames ? names : nil, copied, [self _nullPlaceholder]);
	NSPasteboard *board = pasteboard ?: [NSPasteboard generalPasteboard];
	[board clearContents];
	[board setString:text forType:NSPasteboardTypeString];
	[board setString:text forType:NSPasteboardTypeTabularText];
}

/// Copy as SQL INSERT: the selected rows as an INSERT into this table, the columns in the grid's order (as shown),
/// generated columns left out (PostgreSQL refuses values for them).
- (void)rowsGridCopyAsSQLInserts:(NSTableView *)grid
{
	NSMutableArray *names = [NSMutableArray array];
	NSArray *copied = [self _selectedRowValuesIncludingGenerated:NO names:names];
	if (!copied) return;

	NSString *qualified = [NSString stringWithFormat:@"\"%@\".\"%@\"", [schema stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""],
						   [table stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
	NSPasteboard *board = pasteboard ?: [NSPasteboard generalPasteboard];
	[board clearContents];
	[board setString:SPPostgresSQLInserts(qualified, names, copied) forType:NSPasteboardTypeString];
}

/// The grid's right-click menu, MySQL's (DBView.xib's Table Content Menu): Copy, Copy with Column Names, Copy as SQL
/// INSERT | Add New Row | Duplicate Row, Delete Row.
- (NSMenu *)_newGridMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
	for (NSMenuItem *item in [SPPostgresRowsGrid copyMenuItemsForGrid:tableView]) [menu addItem:item];
	[menu addItem:[NSMenuItem separatorItem]];
	[[menu addItemWithTitle:NSLocalizedString(@"Add New Row", @"add new row contextual menu item") action:@selector(addRow:) keyEquivalent:@""] setTarget:self];
	[menu addItem:[NSMenuItem separatorItem]];
	[[menu addItemWithTitle:NSLocalizedString(@"Duplicate Row", @"duplicate row contextual menu item") action:@selector(duplicateRow:) keyEquivalent:@""] setTarget:self];
	[[menu addItemWithTitle:NSLocalizedString(@"Delete Row", @"delete row contextual menu item") action:@selector(removeRows:) keyEquivalent:@""] setTarget:self];
	return menu;
}

/// The grid menu's row actions, as the bottom bar's buttons (-_updateBottomBar).
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	SEL action = [menuItem action];
	BOOL canWrite = !invalidated && ![taskRunner isBusy] && tableData && [columns count] && loaded && editable;
	if (action == @selector(addRow:)) return canWrite;
	if (action == @selector(duplicateRow:)) return canWrite && [tableView numberOfSelectedRows] == 1;
	if (action == @selector(removeRows:)) return canWrite && [tableView numberOfSelectedRows] > 0;
	return YES;
}

#pragma mark - New row not on the server yet

/// Whether a new row must be given a value for the column: NOT NULL with no default (and not generated or numbered).
- (BOOL)_columnIsRequired:(SPPostgresColumn *)column
{
	return column && ![column nullable] && ![[column defaultExpression] length] && ![column isGenerated] && ![column isAutoNumbered];
}

/// The pending new row's index in the grid (always the last row), or -1.
- (NSInteger)_pendingRowIndex
{
	return (hasPendingRow && [rows count]) ? (NSInteger)[rows count] - 1 : -1;
}

- (void)_clearPendingRow
{
	hasPendingRow = NO;
	[pendingEditedColumns removeAllIndexes];
}

/// Removes the pending new row from the grid, sending nothing.
- (void)_dropPendingRow
{
	NSInteger index = [self _pendingRowIndex];
	if (index < 0) return;
	if ([tableView currentEditor]) [tableView abortEditing];
	[self _clearPendingRow];
	[rows removeObjectAtIndex:(NSUInteger)index];
	if (matchingRowCount > 0) matchingRowCount--;
	if (tableRowCount > 0) tableRowCount--;
	[tableView deselectRow:index];
	[tableView reloadData];
	[self _updateBottomBar];
}

/**
 * Inserts the pending new row with the values given to it (the other columns get their defaults), and shows the row
 * as the server has it. On failure the error is shown and the row stays pending, with its values. YES when there is
 * no pending row any more.
 */
- (BOOL)_insertPendingRow
{
	NSInteger index = [self _pendingRowIndex];
	if (index < 0) return YES;
	if (invalidated || !tableData) return NO;
	if ([self _refuseWriteWhileBusy]) return NO;

	NSArray *row = [rows objectAtIndex:(NSUInteger)index];
	NSMutableDictionary *values = [NSMutableDictionary dictionary];
	[pendingEditedColumns enumerateIndexesUsingBlock:^(NSUInteger columnIndex, BOOL *stop) {
		if (columnIndex < [columns count] && columnIndex < [row count]) {
			[values setObject:[row objectAtIndex:columnIndex] forKey:[(SPPostgresColumn *)[columns objectAtIndex:columnIndex] name]];
		}
	}];

	NSError *error = nil;
	NSArray *inserted = [tableData insertRowWithValues:values error:&error];
	if (!inserted) {
		[self _presentError:error title:NSLocalizedString(@"Could not add a row", @"Postgres content: insert failed")];
		return NO;
	}

	[self _clearPendingRow];
	[rows replaceObjectAtIndex:(NSUInteger)index withObject:inserted];
	[tableView reloadData];
	[self _updateBottomBar];
	return YES;
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

/// The end of a cell edit.
- (void)tableView:(NSTableView *)theTableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	[self _commitValue:object forColumn:[self _columnForTableColumn:tableColumn] row:rowIndex];
}

/// A cell's new value (from the grid or the field editor sheet): updates that column of the row on the server, then
/// shows the row as the server has it.
- (void)_commitValue:(id)object forColumn:(SPPostgresColumn *)column row:(NSInteger)rowIndex
{
	[self _commitValue:object forColumn:column row:rowIndex errorMessage:NULL];
}

/// As -_commitValue:forColumn:row:; with errorMessage, a failure is given back there (the value popover shows it)
/// instead of as an alert, and a commit that can't run says why.
- (void)_commitValue:(id)object forColumn:(SPPostgresColumn *)column row:(NSInteger)rowIndex errorMessage:(NSString **)errorMessage
{
	NSString *cannot = NSLocalizedString(@"The value can't be saved now.", @"value popover: the commit can't run");
	if (invalidated || !tableData || !editable || !loaded) { if (errorMessage) *errorMessage = cannot; return; }
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) { if (errorMessage) *errorMessage = cannot; return; }
	if (!column || [column isGenerated]) { if (errorMessage) *errorMessage = cannot; return; }
	NSUInteger columnIndex = [columns indexOfObjectIdenticalTo:column];
	if (columnIndex == NSNotFound) { if (errorMessage) *errorMessage = cannot; return; }

	NSArray *originalRow = [[[rows objectAtIndex:(NSUInteger)rowIndex] retain] autorelease];
	id oldValue = [originalRow objectAtIndex:columnIndex];

	id newValue = [object isKindOfClass:[NSString class]] ? object : ([object respondsToSelector:@selector(stringValue)] ? [object stringValue] : nil);
	if (!newValue) newValue = [NSNull null];

	// As MySQL: the NULL placeholder means NULL where the column takes it
	if ([newValue isKindOfClass:[NSString class]] && [column nullable] && [newValue isEqualToString:[self _nullPlaceholder]]) newValue = [NSNull null];

	// Unchanged: nothing to send
	if ([newValue isEqual:oldValue]) return;

	// The new row not on the server yet: kept in the grid, sent with its insert (a required column passed over
	// still shows the NULL placeholder: not a value)
	if (rowIndex == [self _pendingRowIndex]) {
		if ([oldValue isKindOfClass:[NSNull class]] && [newValue isEqual:[self _nullPlaceholder]]) return;
		NSMutableArray *changedRow = [[originalRow mutableCopy] autorelease];
		[changedRow replaceObjectAtIndex:columnIndex withObject:newValue];
		[rows replaceObjectAtIndex:(NSUInteger)rowIndex withObject:changedRow];
		[pendingEditedColumns addIndex:columnIndex];
		return;
	}

	// An edit ending while a load runs (something outside this view started one, as edits end before every load
	// here) is not sent: the grid goes on showing the row's loaded value
	if ([self _refuseWriteWhileBusy]) {
		if (errorMessage) *errorMessage = NSLocalizedString(@"Sequel Plus is busy with this tab. Save again once it's done.", @"value popover: the tab is busy");
		return;
	}

	NSError *error = nil;
	if ([tableData updateRow:originalRow column:[column name] value:newValue error:&error]) {
		// Shown as sent until the reload brings Postgres's own format
		NSMutableArray *changedRow = [[originalRow mutableCopy] autorelease];
		[changedRow replaceObjectAtIndex:columnIndex withObject:newValue];
		[rows replaceObjectAtIndex:(NSUInteger)rowIndex withObject:changedRow];
	}
	else if (errorMessage) {
		NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		*errorMessage = [detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres content: unknown error");
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

	// Committed by the grid's own editing ending (Return, Tab, a click elsewhere), by the sheet, or called directly.
	// Inline: now, inside the commit, as before (the grid's next edit, after Tab, starts once this returns).
	BOOL gridEditing = [tableView currentEditor] || [tableView editedRow] >= 0;
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
	if ([notification object] != tableView) return;

	// Return on the new row (not Tab, which moves to its next cell): the row is done, so it is inserted
	if (hasPendingRow && [[[notification userInfo] objectForKey:@"NSTextMovement"] integerValue] == NSReturnTextMovement) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!invalidated && hasPendingRow && ![tableView currentEditor]) [self _insertPendingRow];
		});
	}

	if (!reloadPending) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		[self _reloadIfPending];
	});
}

#pragma mark - Table view delegate

/// In edit mode every cell opens the field editor sheet (read-only where the cell can't be edited) instead. A date or
/// time cell that can be edited opens the date / time picker on the cell instead of the in-cell editor. While the
/// runner is busy nothing is edited and no sheet opens (MySQL: NO while the document is working).
- (BOOL)tableView:(NSTableView *)theTableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || [taskRunner isBusy]) return NO;
	if ([self _editsInSheet] || [self _isLongValueInTableColumn:tableColumn row:rowIndex]) {
		[self _editInSheetTableColumn:tableColumn row:rowIndex];
		return NO;
	}
	if (![self _canEditTableColumn:tableColumn row:rowIndex]) return NO;
	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	NSDictionary *reference = pickerHandoff ? nil : [self _pickerReferenceForColumn:column];
	if (reference) {
		[self _editInForeignKeyPickerTableColumn:tableColumn row:rowIndex reference:reference];
		return NO;
	}
	if (!pickerHandoff && [SPPostgresDateTimePicker kindOfTypeName:[column typeName]] != SPPostgresTemporalNone) {
		[self _editInDatePickerTableColumn:tableColumn row:rowIndex];
		return NO;
	}
	return YES;
}

#pragma mark - Date / time picker

/**
 * Opens the date / time picker as a popover on a date or time cell (unless a picker or the field editor sheet is
 * open). Its value is not saved: Set (or NULL, as the NULL placeholder) puts it into the cell's in-place editor, on
 * this table only and on the row it was opened on where that row now is, and the cell stays being edited until Return
 * saves it (or Escape drops it), as any in-cell edit. Cancel leaves the cell as it was, not being edited.
 */
- (void)_editInDatePickerTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || fieldEditorPending || [taskRunner isBusy]) return;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return;
	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	if (!column) return;

	NSArray *row = [rows objectAtIndex:(NSUInteger)rowIndex];
	id value = [row objectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue]];
	SPPostgresTableData *data = tableData;
	fieldEditorPending = YES;
	[self retain]; // until the picker answers

	SPPostgresDateTimePicker *picker = [[[SPPostgresDateTimePicker alloc] initWithValue:value typeName:[column typeName] allowNull:[column nullable] completion:^(id newValue) {
		fieldEditorPending = NO;
		if (!invalidated) [[tableView window] makeFirstResponder:tableView];
		if (newValue && !invalidated && data == tableData && ![taskRunner isBusy]) {
			NSUInteger index = (NSUInteger)rowIndex;
			if (index >= [rows count] || ![[rows objectAtIndex:index] isEqual:row]) index = [rows indexOfObject:row];
			NSInteger gridColumn = [tableView columnWithIdentifier:[tableColumn identifier]];
			if (index != NSNotFound && gridColumn >= 0) {
				NSString *text = [newValue isKindOfClass:[NSString class]] ? newValue : [self _nullPlaceholder];
				pickerHandoff = YES;
				[tableView editColumn:gridColumn row:(NSInteger)index withEvent:nil select:YES];
				pickerHandoff = NO;
				NSText *editor = [tableView currentEditor];
				[editor setString:text];
				[editor setSelectedRange:NSMakeRange([text length], 0)];
			}
		}
		[self autorelease];
	}] autorelease];
	NSInteger columnIndex = [tableView columnWithIdentifier:[tableColumn identifier]];
	[picker showRelativeToRect:[tableView frameOfCellAtColumn:columnIndex row:rowIndex] ofView:tableView];
}

#pragma mark - Foreign key picker

/// column's foreign key when the picker opens for it (the preference on, a single-column key, not bytea), else nil.
- (NSDictionary *)_pickerReferenceForColumn:(SPPostgresColumn *)column
{
	if (!column) return nil;
	NSDictionary *reference = [foreignKeys objectForKey:[column name]];
	if (!reference || [[reference objectForKey:@"columns"] integerValue] != 1 || [[reference objectForKey:@"binary"] boolValue]) return nil;
	SPForeignKeyPickerSettings *settings = [[[SPForeignKeyPickerSettings alloc] initWithDefaults:defaults] autorelease];
	return [settings pickerEnabled] ? reference : nil;
}

- (SPForeignKeyPicker *)_pickerForReference:(NSDictionary *)reference value:(id)value allowNull:(BOOL)allowNull
								 completion:(void (^)(SPForeignKeyPickerOutcome outcome, NSString *chosen))completion
{
	NSString *refSchema = [reference objectForKey:@"schema"];
	NSString *refTable = [reference objectForKey:@"table"];
	NSString *refColumn = [reference objectForKey:@"column"];
	SPPostgresForeignKeyPickerSource *source = [[[SPPostgresForeignKeyPickerSource alloc] initWithTaskRunner:taskRunner schema:refSchema table:refTable keyColumn:refColumn] autorelease];
	SPForeignKeyPickerSettings *settings = [[[SPForeignKeyPickerSettings alloc] initWithDefaults:defaults] autorelease];
	NSString *server = [connection useSocket] ? [connection socketPath] : [connection host];
	NSString *tableKey = [SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:server port:(NSInteger)[connection port]
															  database:[connection database] schema:refSchema table:refTable];
	NSString *title = [NSString stringWithFormat:@"%@.%@ · %@.%@", refTable, refColumn, refSchema, refTable];
	return [[[SPForeignKeyPicker alloc] initWithDataSource:source settings:settings tableKey:tableKey title:title
											  currentValue:value allowNull:allowNull completion:completion] autorelease];
}

- (void)_presentForeignKeyPicker:(SPForeignKeyPicker *)picker rect:(NSRect)rect ofView:(NSView *)aView
{
	if (foreignKeyPickerPresenter) foreignKeyPickerPresenter(picker, aView, rect);
	else [picker showRelativeToRect:rect ofView:aView];
}

/// Runs block once the runner is idle (the picker's own reads may still be queued when it answers); not at all once
/// the runner is invalidated.
- (void)_whenTaskRunnerIdle:(void (^)(void))block
{
	if ([taskRunner isInvalidated]) return;
	if (![taskRunner isBusy]) {
		block();
		return;
	}
	void (^copied)(void) = [[block copy] autorelease];
	[taskRunner runTaskWithDescription:NSLocalizedString(@"Loading rows…", @"foreign key picker: loading the referenced table's rows") cancelTitle:nil
								  work:^id(PGPostgresConnection *theConnection, NSError **error) { return @YES; }
							completion:^(id result, NSError *error, BOOL cancelled) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _whenTaskRunnerIdle:copied];
		});
	}];
}

/**
 * Opens the foreign key picker as a popover on a foreign key cell (unless a picker or the field editor sheet is
 * open). Its value is not saved: Choose (or NULL, as the NULL placeholder) puts it into the cell's in-place editor,
 * and Type a value… opens that editor on the cell's value, on this table only and on the row it was opened on where
 * that row now is; the cell stays being edited until Return saves it (or Escape drops it). Cancel leaves the cell as
 * it was, not being edited.
 */
- (void)_editInForeignKeyPickerTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex reference:(NSDictionary *)reference
{
	if (invalidated || fieldEditorPending || [taskRunner isBusy]) return;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return;
	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	if (!column) return;

	NSArray *row = [rows objectAtIndex:(NSUInteger)rowIndex];
	id value = [row objectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue]];
	SPPostgresTableData *data = tableData;
	fieldEditorPending = YES;
	[self retain]; // until the picker answers

	SPForeignKeyPicker *picker = [self _pickerForReference:reference value:value allowNull:[column nullable] completion:^(SPForeignKeyPickerOutcome outcome, NSString *chosen) {
		fieldEditorPending = NO;
		if (!invalidated) [[tableView window] makeFirstResponder:tableView];
		if (outcome != SPForeignKeyPickerCancelled && !invalidated && data == tableData) {
			// nil: Type a value… (the editor keeps the cell's value)
			NSString *text = (outcome == SPForeignKeyPickerChose) ? chosen : (outcome == SPForeignKeyPickerChoseNull) ? [self _nullPlaceholder] : nil;
			[self _whenTaskRunnerIdle:^{
				if (invalidated || data != tableData || [taskRunner isBusy]) return;
				NSUInteger index = (NSUInteger)rowIndex;
				if (index >= [rows count] || ![[rows objectAtIndex:index] isEqual:row]) index = [rows indexOfObject:row];
				NSInteger gridColumn = [tableView columnWithIdentifier:[tableColumn identifier]];
				if (index == NSNotFound || gridColumn < 0) return;
				pickerHandoff = YES;
				[tableView editColumn:gridColumn row:(NSInteger)index withEvent:nil select:YES];
				pickerHandoff = NO;
				if (!text) return;
				NSText *editor = [tableView currentEditor];
				[editor setString:text];
				[editor setSelectedRange:NSMakeRange([text length], 0)];
			}];
		}
		[self autorelease];
	}];
	NSInteger columnIndex = [tableView columnWithIdentifier:[tableColumn identifier]];
	[self _presentForeignKeyPicker:picker rect:[tableView frameOfCellAtColumn:columnIndex row:rowIndex] ofView:tableView];
}

/// Whether the cell can be edited now (never opens the sheet).
- (BOOL)_canEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || !tableData || !editable || !loaded || [taskRunner isBusy]) return NO;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return NO;

	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	return column && ![column isGenerated];
}

#pragma mark - Field editor sheet

/**
 * Opens the field editor sheet on a cell (unless one is open), editable where the cell could be edited in place. Its
 * result is committed as a cell edit, to this table only, and to the row it was opened on where that row now is (a
 * reload may have moved it); after a table switch or -invalidate, or with the row gone, nothing is sent.
 */
- (void)_editInSheetTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || fieldEditorPending || [taskRunner isBusy]) return;
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) return;
	SPPostgresColumn *column = [self _columnForTableColumn:tableColumn];
	if (!column) return;

	BOOL canEdit = [self _canEditTableColumn:tableColumn row:rowIndex];
	NSArray *row = [rows objectAtIndex:(NSUInteger)rowIndex];
	id value = [row objectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue]];
	NSString *text = [value isKindOfClass:[NSString class]] ? value : [self _nullPlaceholder];
	SPPostgresTableData *data = tableData;
	fieldEditorPending = YES;

	// A heap copy that keeps this controller, the row and the table alive until it is called. It runs once and then
	// balances its own Block_copy (deferred to the autorelease pool, as it is still running).
	__block BOOL done = NO;
	__block void (^once)(id) = nil;
	once = Block_copy(^(id newValue) {
		if (done) return;
		done = YES;
		fieldEditorPending = NO;
		if (newValue && canEdit && !invalidated && data == tableData) {
			NSUInteger index = (NSUInteger)rowIndex;
			if (index >= [rows count] || ![[rows objectAtIndex:index] isEqual:row]) index = [rows indexOfObject:row];
			if (index != NSNotFound) [self _commitValue:newValue forColumn:column row:(NSInteger)index];
		}
		[(id)once autorelease];
	});

	if (fieldEditorPresenter) fieldEditorPresenter(text, [column name], [column typeName], canEdit, [column nullable], once);
	else {
		// MySQL's field editor as a sheet on the view's window (cancelled at once when there is none, or a sheet is up)
		// A foreign key cell's sheet gets Choose…, which opens the picker on the button; its value replaces the text
		NSDictionary *reference = canEdit ? [self _pickerReferenceForColumn:column] : nil;
		void (^chooser)(NSString *, NSView *, void (^)(NSString *)) = nil;
		if (reference) {
			chooser = [[^(NSString *currentText, NSView *anchor, void (^setText)(NSString *)) {
				if (invalidated) return;
				void (^replace)(NSString *) = [[setText copy] autorelease];
				SPForeignKeyPicker *picker = [self _pickerForReference:reference value:currentText allowNull:[column nullable] completion:^(SPForeignKeyPickerOutcome outcome, NSString *chosen) {
					if (outcome == SPForeignKeyPickerChose) replace(chosen);
					else if (outcome == SPForeignKeyPickerChoseNull) replace([self _nullPlaceholder]);
				}];
				[self _presentForeignKeyPicker:picker rect:[anchor bounds] ofView:anchor];
			} copy] autorelease]; // off the stack: it outlives this scope
		}
		[SPPostgresFieldEditorSheet editValue:text columnName:[column name] typeName:[column typeName] editable:canEdit
									allowNull:[column nullable] window:[view window] chooser:chooser completion:^(id newValue) {
			if (!invalidated) [[tableView window] makeFirstResponder:tableView];
			once(newValue);
		}];
	}
}

- (void)tableView:(NSTableView *)theTableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (![cell respondsToSelector:@selector(setTextColor:)]) return;
	BOOL isLinkCell = [cell isKindOfClass:[SPTextAndLinkCell class]];
	if (rowIndex < 0 || (NSUInteger)rowIndex >= [rows count]) {
		if (isLinkCell) {
			[cell setLinkActive:NO];
			[cell setValueIconActive:NO];
		}
		return;
	}

	id value = [[rows objectAtIndex:(NSUInteger)rowIndex] objectAtIndex:(NSUInteger)[[tableColumn identifier] integerValue]];

	// As MySQL's grid: NULL in grey, except in the selected rows
	BOOL isNull = ![value isKindOfClass:[NSString class]];
	[cell setTextColor:(isNull && ![theTableView isRowSelected:rowIndex]) ? [NSColor lightGrayColor] : [NSColor controlTextColor]];

	// As MySQL's: no link arrow on NULL, on the row being edited, or on a new row not inserted yet
	BOOL settled = [theTableView editedRow] != rowIndex && rowIndex != [self _pendingRowIndex];
	if (isLinkCell) [cell setLinkActive:!isNull && settled];
	// The value icon: any value of a text column (NULL too), not a primary key
	if (isLinkCell) [cell setValueIconActive:settled && SPValuePopoverOffersValue(value, [self _showsValueIconInColumn:[self _columnForTableColumn:tableColumn]])];
}

#pragma mark - Value popover

/// A text column (text, varchar, char, json, jsonb, xml, citext) that isn't part of the primary key: its values (NULL
/// too) are offered in the value popover.
- (BOOL)_showsValueIconInColumn:(SPPostgresColumn *)column
{
	if (!column || [column isPrimaryKey]) return NO;
	NSString *type = [[column typeName] lowercaseString];
	if (![type length] || [type hasSuffix:@"]"]) return NO; // arrays
	for (NSString *prefix in @[@"text", @"character", @"varchar", @"char", @"bpchar", @"json", @"xml", @"citext"]) {
		if ([type hasPrefix:prefix]) return YES;
	}
	return NO;
}

- (void)_clickValueIcon:(SPTextAndLinkCell *)cell
{
	NSInteger columnIndex = [cell getClickedColumn];
	NSInteger row = [cell getClickedRow];
	if (columnIndex < 0 || row < 0 || columnIndex >= (NSInteger)[[tableView tableColumns] count]) return;
	NSTableColumn *tableColumn = [[tableView tableColumns] objectAtIndex:(NSUInteger)columnIndex];
	[self showValueAtRow:row column:(NSUInteger)[[tableColumn identifier] integerValue]];
}

- (void)_closeValuePopover
{
	SPValuePopover *popover = valuePopover;
	valuePopover = nil;
	[popover closeDiscarding];
	[popover release];
}

- (void)showValueAtRow:(NSInteger)row column:(NSUInteger)columnIndex
{
	if (invalidated || row < 0 || (NSUInteger)row >= [rows count] || columnIndex >= [columns count] || row == [self _pendingRowIndex]) return;
	SPPostgresColumn *column = [columns objectAtIndex:columnIndex];
	id value = [[rows objectAtIndex:(NSUInteger)row] objectAtIndex:columnIndex];
	if (!SPValuePopoverOffersValue(value, [self _showsValueIconInColumn:column])) return;

	// As clicking another row: a cell being edited is saved first (which may reload the rows: the row is found again)
	NSArray *theRow = [[[rows objectAtIndex:(NSUInteger)row] retain] autorelease];
	BOOL isNull = ![value isKindOfClass:[NSString class]];
	NSString *theValue = isNull ? @"" : [[value copy] autorelease];
	[self _endEditing];
	if (invalidated) return;
	NSUInteger index = [rows indexOfObject:theRow];
	if (index == NSNotFound) return;

	NSTableColumn *tableColumn = nil;
	for (NSTableColumn *candidate in [tableView tableColumns]) {
		if ((NSUInteger)[[candidate identifier] integerValue] == columnIndex) tableColumn = candidate;
	}
	if (!tableColumn) return;
	BOOL canEdit = [self _canEditTableColumn:tableColumn row:(NSInteger)index];

	// Save commits to the row it was opened on, where it now is, in this same table
	SPPostgresTableData *data = tableData;
	void (^saver)(NSString *, void (^)(NSString *)) = nil;
	if (canEdit) {
		saver = ^(NSString *text, void (^done)(NSString *)) {
			NSString *message = nil;
			NSUInteger now = (invalidated || data != tableData) ? NSNotFound : [rows indexOfObject:theRow];
			if (now == NSNotFound) message = NSLocalizedString(@"This row was changed or reloaded. Close and open the value again.", @"value popover: its row is gone");
			else {
				valuePopoverSaving = YES;
				[self _commitValue:text forColumn:column row:(NSInteger)now errorMessage:&message];
				valuePopoverSaving = NO;
			}
			done(message);
		};
	}

	[self _closeValuePopover];
	SPValuePopover *popover = [[SPValuePopover alloc] initWithValue:theValue columnName:[column name] defaults:defaults saver:saver];
	[popover setValueIsNull:isNull];
	valuePopover = popover;
	[popover setClosed:^{
		if (valuePopover == popover) {
			valuePopover = nil;
			[popover autorelease];
		}
	}];
	NSInteger gridColumn = [tableView columnWithIdentifier:[tableColumn identifier]];
	NSRect rect = [tableView frameOfCellAtColumn:gridColumn row:(NSInteger)index];
	if (valuePopoverPresenter) valuePopoverPresenter(popover, tableView, rect);
	else if (![popover showRelativeToRect:rect ofView:tableView]) [self _closeValuePopover];
}

#pragma mark - Foreign key links

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)foreignKeyReferences
{
	return [[foreignKeys retain] autorelease];
}

- (void)_clickLinkArrow:(SPTextAndLinkCell *)cell
{
	NSInteger columnIndex = [cell getClickedColumn];
	NSInteger row = [cell getClickedRow];
	if (columnIndex < 0 || row < 0 || columnIndex >= (NSInteger)[[tableView tableColumns] count]) return;
	NSTableColumn *tableColumn = [[tableView tableColumns] objectAtIndex:(NSUInteger)columnIndex];
	[self followForeignKeyAtRow:row column:(NSUInteger)[[tableColumn identifier] integerValue]];
}

- (void)followForeignKeyAtRow:(NSInteger)row column:(NSUInteger)columnIndex
{
	if (invalidated || [self _refuseWriteWhileBusy]) return;
	if (row < 0 || (NSUInteger)row >= [rows count] || columnIndex >= [columns count] || row == [self _pendingRowIndex]) return;

	NSDictionary *reference = [foreignKeys objectForKey:[[columns objectAtIndex:columnIndex] name]];
	id value = [[rows objectAtIndex:(NSUInteger)row] objectAtIndex:columnIndex];
	if (!reference || ![value isKindOfClass:[NSString class]]) return;

	// The value is copied first: ending the edit may reload the rows
	NSString *theValue = [[value copy] autorelease];
	[self _endEditing];

	SPPostgresFilter *linkFilter = [SPPostgresFilter filterWithColumn:[reference objectForKey:@"column"] comparison:@"=" value:theValue];

	// A key into this table: filtered here
	if ([[reference objectForKey:@"schema"] isEqualToString:schema] && [[reference objectForKey:@"table"] isEqualToString:table]) {
		[self _showFilterInBar:linkFilter];
		[self _loadWithFilters:@[linkFilter] sortColumn:sortColumn ascending:sortAscending page:1
				   description:NSLocalizedString(@"Filtering table...", @"Filtering table task description")];
		return;
	}

	if (!foreignKeyFollower) {
		NSBeep();
		return;
	}
	foreignKeyFollower([reference objectForKey:@"schema"], [reference objectForKey:@"table"], [reference objectForKey:@"column"], theValue);
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
	[self _loadWithFilters:filters sortColumn:name ascending:ascending page:1
			   description:NSLocalizedString(@"Sorting table...", @"Sorting table task description")];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _updateBottomBar];

	// Leaving the new row (another row selected): it is inserted; if that fails it is selected again, to be fixed
	NSInteger pendingIndex = [self _pendingRowIndex];
	if (pendingIndex < 0 || [tableView currentEditor]) return;
	NSIndexSet *selection = [tableView selectedRowIndexes];
	if ([selection count] == 1 && [selection containsIndex:(NSUInteger)pendingIndex]) return;
	if (![self _insertPendingRow] && hasPendingRow) {
		[tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)[self _pendingRowIndex]] byExtendingSelection:NO];
	}
}

@end
