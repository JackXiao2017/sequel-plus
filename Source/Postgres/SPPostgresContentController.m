#import "SPPostgresContentController.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
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

	SPPostgresFilter *filter;       // nil: no filter
	NSString *sortColumn;           // nil: primary-key order
	BOOL sortAscending;
	NSUInteger currentPage;
	NSUInteger pageCount;
	NSInteger matchingRowCount;     // rows matching the filter
	NSInteger tableRowCount;        // rows in the table

	NSView *view;
	SPTableView *tableView;
	NSScrollView *scrollView;

	NSPopUpButton *filterColumnPopup;
	NSPopUpButton *filterComparisonPopup;
	NSTextField *filterValueField;
	NSButton *filterButton;

	NSButton *addButton;
	NSButton *removeButton;
	NSButton *refreshButton;
	NSButton *previousPageButton;
	NSButton *nextPageButton;
	NSTextField *countField;
	NSTextField *noticeField;

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

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		rows = [[NSMutableArray alloc] init];
		columns = [@[] retain];
		currentPage = 1;
		pageCount = 1;
		sortAscending = YES;
		countText = [@"" copy];
		noticeText = [@"" copy];
		[self _buildView];
		[self _updateBottomBar];
	}

	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
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
	[refreshButton release];
	[previousPageButton release];
	[nextPageButton release];
	[countField release];
	[noticeField release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;

	// An edit in progress must not call back into a controller that is going away
	if ([tableView currentEditor]) [tableView abortEditing];
	[tableView setDataSource:nil];
	[tableView setDelegate:nil];

	for (NSControl *control in @[filterColumnPopup, filterComparisonPopup, filterValueField, filterButton,
								 addButton, removeButton, refreshButton, previousPageButton, nextPageButton]) {
		[control setTarget:nil];
	}

	// The presenters may capture the tab
	[alertPresenter release];
	alertPresenter = nil;
	[confirmationPresenter release];
	confirmationPresenter = nil;
}

- (NSButton *)_newBarButtonWithImage:(NSString *)imageName toolTip:(NSString *)toolTip action:(SEL)action x:(CGFloat)x
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, -1, SPPostgresContentButtonWidth, 25)];
	[button setBezelStyle:NSBezelStyleTexturedRounded];
	[button setImage:[NSImage imageNamed:imageName]];
	[button setImagePosition:NSImageOnly];
	[button setToolTip:toolTip];
	[button setTarget:self];
	[button setAction:action];
	return button;
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

	tableView = [[SPTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[tableView setUsesAlternatingRowBackgroundColors:YES];
	[tableView setAllowsMultipleSelection:YES];
	[tableView setAllowsColumnReordering:YES];
	[tableView setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];
	[tableView setFocusRingType:NSFocusRingTypeNone];
	[tableView setGridStyleMask:[[NSUserDefaults standardUserDefaults] boolForKey:SPDisplayTableViewVerticalGridlines] ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	[tableView setDataSource:self];
	[tableView setDelegate:self];
	[scrollView setDocumentView:tableView];
	[view addSubview:scrollView];

	// Bottom bar: + − refresh | count, notice | previous, next
	SPButtonBar *bottomBar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresContentBottomBarHeight)] autorelease];
	[bottomBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];

	addButton = [self _newBarButtonWithImage:@"button_add" toolTip:NSLocalizedString(@"Add row", @"Postgres content: add row tooltip") action:@selector(addRow:) x:-1];
	removeButton = [self _newBarButtonWithImage:@"button_remove" toolTip:NSLocalizedString(@"Delete selected row(s)", @"Postgres content: delete rows tooltip") action:@selector(removeRows:) x:30];
	refreshButton = [self _newBarButtonWithImage:@"button_refresh" toolTip:NSLocalizedString(@"Refresh table contents", @"Postgres content: refresh tooltip") action:@selector(refresh:) x:61];
	nextPageButton = [self _newBarButtonWithImage:@"button_right" toolTip:NSLocalizedString(@"View next page of results", @"Postgres content: next page tooltip") action:@selector(nextPage:) x:width - 48];
	previousPageButton = [self _newBarButtonWithImage:@"button_left" toolTip:NSLocalizedString(@"View previous page of results", @"Postgres content: previous page tooltip") action:@selector(previousPage:) x:width - 79];
	[nextPageButton setAutoresizingMask:NSViewMinXMargin];
	[previousPageButton setAutoresizingMask:NSViewMinXMargin];

	CGFloat textX = 100;
	CGFloat textWidth = (width - 79 - 8) - textX;
	countField = [self _newLabelWithFrame:NSMakeRect(textX, 4, floor(textWidth * 0.45), 14)];
	[countField setAutoresizingMask:NSViewWidthSizable];
	noticeField = [self _newLabelWithFrame:NSMakeRect(textX + floor(textWidth * 0.45) + 8, 4, textWidth - floor(textWidth * 0.45) - 8, 14)];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[noticeField setAlignment:NSTextAlignmentRight];
	[noticeField setAutoresizingMask:NSViewWidthSizable | NSViewMinXMargin];

	for (NSView *subview in @[addButton, removeButton, refreshButton, countField, noticeField, previousPageButton, nextPageButton]) {
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
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	if (![prefs boolForKey:SPLimitResults]) return 0;
	NSInteger size = [prefs integerForKey:SPLimitResultsValue];
	return size > 0 ? (NSUInteger)size : 0;
}

- (NSString *)_nullPlaceholder
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:SPNullValue] ?: @"NULL";
}

/// MySQL's result table font, or the small system font.
- (NSFont *)_tableFont
{
	NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:SPGlobalResultTableFont];
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
	if (confirmationPresenter) {
		confirmationPresenter(alert, completion);
		return;
	}

	NSWindow *window = [view window];
	if (!window) {
		completion([alert runModal] == NSAlertFirstButtonReturn);
		return;
	}
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		completion(response == NSAlertFirstButtonReturn);
	}];
}

#pragma mark - Loading

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

	if ([theTable length] && [theSchema length]) {
		tableData = [[SPPostgresTableData alloc] initWithConnection:connection schema:theSchema table:theTable];

		NSError *error = nil;
		NSArray *theColumns = [tableData columns:&error];
		if (theColumns) {
			[columns release];
			columns = [theColumns copy];
			editable = [tableData isEditable];
		}
		else {
			[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the columns of “%@”", @"Postgres content: columns failed"), theTable]];
		}
	}

	[self _rebuildColumns];
	[self _rebuildFilterBar];
	[self setNoticeText:(tableData && !editable) ? ([tableData readOnlyReason] ?: @"") : @""];
	[noticeField setStringValue:noticeText];

	if ([columns count]) {
		[self _loadWithFilter:nil sortColumn:nil ascending:YES page:1];
		[self _fitColumnWidths];
	}
	else {
		[tableView reloadData];
		[self _updateBottomBar];
	}
}

- (void)reload
{
	if (invalidated || ![columns count]) return;
	[self _loadWithFilter:filter sortColumn:sortColumn ascending:sortAscending page:currentPage];
}

/**
 * Loads a page with the given state; only on success does that state become the current one. On failure
 * the error is shown and the grid keeps its rows (and the previous filter, sort and page).
 */
- (BOOL)_loadWithFilter:(SPPostgresFilter *)theFilter sortColumn:(NSString *)theSortColumn ascending:(BOOL)ascending page:(NSUInteger)page
{
	if (!tableData || ![columns count]) return NO;

	NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Could not load the rows of “%@”", @"Postgres content: load failed"), table];
	NSError *error = nil;

	NSInteger matching = [tableData countRowsWithFilter:theFilter error:&error];
	if (matching < 0) {
		[self _presentError:error title:title];
		return NO;
	}

	NSInteger total = matching;
	if (theFilter) {
		total = [tableData countRowsWithFilter:nil error:&error];
		if (total < 0) {
			[self _presentError:error title:title];
			return NO;
		}
	}

	NSUInteger pageSize = [self _pageSize];
	NSUInteger pages = 1;
	if (pageSize && matching > 0) pages = ((NSUInteger)matching + pageSize - 1) / pageSize;
	page = MAX(1u, MIN(page, pages));

	NSArray *newRows = [tableData rowsWithFilter:theFilter sortColumn:theSortColumn ascending:ascending
										  offset:(page - 1) * pageSize limit:pageSize error:&error];
	if (!newRows) {
		[self _presentError:error title:title];
		return NO;
	}

	if (theFilter != filter) {
		[filter release];
		filter = [theFilter retain];
	}
	if (theSortColumn != sortColumn) {
		[sortColumn release];
		sortColumn = [theSortColumn copy];
	}
	sortAscending = ascending;
	currentPage = page;
	pageCount = pages;
	matchingRowCount = matching;
	tableRowCount = total;

	[rows setArray:newRows];

	// Keep the selection where it still fits
	NSIndexSet *selection = [[[tableView selectedRowIndexes] copy] autorelease];
	[tableView reloadData];
	NSMutableIndexSet *kept = [NSMutableIndexSet indexSet];
	[selection enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < [rows count]) [kept addIndex:index];
	}];
	[tableView selectRowIndexes:kept byExtendingSelection:NO];

	[self _updateSortIndicators];
	[self _updateBottomBar];
	return YES;
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

	[self _loadWithFilter:newFilter sortColumn:sortColumn ascending:sortAscending page:1];
}

#pragma mark - Bottom bar

- (void)_updateBottomBar
{
	NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
	[formatter setNumberStyle:NSNumberFormatterDecimalStyle];
	NSString *(^format)(NSInteger) = ^(NSInteger n) { return [formatter stringFromNumber:@(n)]; };

	NSMutableString *text = [NSMutableString string];
	if (tableData && [columns count]) {
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

	BOOL hasTable = tableData && [columns count];
	[addButton setEnabled:hasTable && editable];
	[removeButton setEnabled:hasTable && editable && [tableView numberOfSelectedRows] > 0];
	[refreshButton setEnabled:hasTable];
	[previousPageButton setEnabled:hasTable && currentPage > 1];
	[nextPageButton setEnabled:hasTable && currentPage < pageCount];
}

/// Commits a cell edit in progress (before an action that reloads the grid).
- (void)_endEditing
{
	if (![tableView currentEditor]) return;
	if (![[tableView window] makeFirstResponder:tableView]) [tableView abortEditing];
}

- (IBAction)refresh:(id)sender
{
	[self _endEditing];
	[self reload];
}

- (IBAction)nextPage:(id)sender
{
	if (invalidated || currentPage >= pageCount) return;
	[self _endEditing];
	[self _loadWithFilter:filter sortColumn:sortColumn ascending:sortAscending page:currentPage + 1];
}

- (IBAction)previousPage:(id)sender
{
	if (invalidated || currentPage <= 1) return;
	[self _endEditing];
	[self _loadWithFilter:filter sortColumn:sortColumn ascending:sortAscending page:currentPage - 1];
}

#pragma mark - Rows

- (IBAction)addRow:(id)sender
{
	if (invalidated || !tableData || !editable) return;
	[self _endEditing];

	// Every column gets its default (as MySQL's new row), then the user edits it in place
	NSError *error = nil;
	NSArray *row = [tableData insertRowWithValues:@{} error:&error];
	if (!row) {
		[self _presentError:error title:NSLocalizedString(@"Could not add a row", @"Postgres content: insert failed")];
		return;
	}

	[rows addObject:row];
	matchingRowCount++;
	tableRowCount++;
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
}

- (IBAction)removeRows:(id)sender
{
	if (invalidated || !tableData || !editable) return;
	[self _endEditing];

	NSIndexSet *selection = [tableView selectedRowIndexes];
	NSMutableArray *selectedRows = [NSMutableArray array];
	[selection enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
		if (index < [rows count]) [selectedRows addObject:[rows objectAtIndex:index]];
	}];
	if (![selectedRows count]) return;

	// MySQL's confirmation (-[SPTableContent removeRow:])
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
	[[[alert buttons] objectAtIndex:1] setKeyEquivalent:@"\033"];
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
		[toDelete release];
		[self release];
	}];
}

- (void)_deleteRows:(NSArray *)toDelete
{
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
	if (invalidated || !tableData || !editable) return;
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

	NSError *error = nil;
	if (![tableData updateRow:originalRow column:[column name] value:newValue error:&error]) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change “%@”", @"Postgres content: update failed"), [column name]]];
	}

	// Reload either way: after success Postgres's own format of the value (and of generated columns),
	// after a failure the row's current values
	[self reload];
}

#pragma mark - Table view delegate

- (BOOL)tableView:(NSTableView *)theTableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (invalidated || !tableData || !editable) return NO;
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

/// Ascending on the first click, then toggles.
- (void)tableView:(NSTableView *)theTableView didClickTableColumn:(NSTableColumn *)tableColumn
{
	if (invalidated || !tableData) return;
	[self _endEditing];

	NSString *name = [[self _columnForTableColumn:tableColumn] name];
	if (!name) return;

	BOOL ascending = [name isEqualToString:sortColumn] ? !sortAscending : YES;
	[self _loadWithFilter:filter sortColumn:name ascending:ascending page:currentPage];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _updateBottomBar];
}

@end
