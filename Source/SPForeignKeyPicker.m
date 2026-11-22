//
//  SPForeignKeyPicker.m
//  Sequel Plus
//

#import "SPForeignKeyPicker.h"
#import "SPForeignKeyPickerSettings.h"

static const NSUInteger SPForeignKeyPickerPageSize = 200;
static const CGFloat SPForeignKeyPickerWidth = 560;
static const CGFloat SPForeignKeyPickerListHeight = 240;

/// The picker that is shown, retained until it finishes.
static SPForeignKeyPicker *SPCurrentForeignKeyPicker = nil;

#pragma mark - Condition row

@interface SPForeignKeyConditionRow ()
- (instancetype)initWithColumns:(NSArray<SPForeignKeyPickerColumn *> *)columns picker:(SPForeignKeyPicker *)picker;
- (nullable SPForeignKeyCondition *)condition;
- (void)columnChanged;
- (void)operatorChanged;
@end

@implementation SPForeignKeyConditionRow
{
	NSDictionary<NSString *, NSNumber *> *_kinds;
}

@synthesize columnPopUp = _columnPopUp;
@synthesize operatorPopUp = _operatorPopUp;
@synthesize valueField = _valueField;
@synthesize secondValueField = _secondValueField;
@synthesize removeButton = _removeButton;

- (instancetype)initWithColumns:(NSArray<SPForeignKeyPickerColumn *> *)columns picker:(SPForeignKeyPicker *)picker
{
	if ((self = [super initWithFrame:NSMakeRect(0, 0, SPForeignKeyPickerWidth - 20, 24)])) {
		[self setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
		[self setSpacing:6];
		[self setDetachesHiddenViews:YES];

		NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
		for (SPForeignKeyPickerColumn *column in columns) [kinds setObject:@([column kind]) forKey:[column name]];
		_kinds = [kinds copy];

		NSTextField *andLabel = [NSTextField labelWithString:NSLocalizedString(@"and", @"foreign key picker: the word before each condition row (all conditions must match)")];
		[andLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[andLabel setTextColor:[NSColor secondaryLabelColor]];

		_columnPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		[_columnPopUp setControlSize:NSControlSizeSmall];
		[_columnPopUp setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		for (SPForeignKeyPickerColumn *column in columns) [_columnPopUp addItemWithTitle:[column name]];
		[_columnPopUp setTarget:picker];
		[_columnPopUp setAction:@selector(conditionColumnChanged:)];

		_operatorPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
		[_operatorPopUp setControlSize:NSControlSizeSmall];
		[_operatorPopUp setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[_operatorPopUp setTarget:picker];
		[_operatorPopUp setAction:@selector(conditionOperatorChanged:)];

		_valueField = [[NSTextField alloc] initWithFrame:NSZeroRect];
		[_valueField setControlSize:NSControlSizeSmall];
		[_valueField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[_valueField setPlaceholderString:NSLocalizedString(@"value", @"foreign key picker: placeholder of a condition's value")];
		[_valueField setDelegate:picker];
		[_valueField setContentHuggingPriority:NSLayoutPriorityDefaultLow - 10 forOrientation:NSLayoutConstraintOrientationHorizontal];

		_secondValueField = [[NSTextField alloc] initWithFrame:NSZeroRect];
		[_secondValueField setControlSize:NSControlSizeSmall];
		[_secondValueField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[_secondValueField setPlaceholderString:NSLocalizedString(@"and value", @"foreign key picker: placeholder of a between condition's second value")];
		[_secondValueField setDelegate:picker];
		[_secondValueField setContentHuggingPriority:NSLayoutPriorityDefaultLow - 10 forOrientation:NSLayoutConstraintOrientationHorizontal];

		_removeButton = [[NSButton buttonWithTitle:@"−" target:picker action:@selector(removeCondition:)] retain];
		[_removeButton setBezelStyle:NSBezelStyleCircular];
		[_removeButton setControlSize:NSControlSizeSmall];
		[_removeButton setToolTip:NSLocalizedString(@"Remove this condition", @"foreign key picker: tooltip of a condition's remove button")];

		for (NSView *view in @[andLabel, _columnPopUp, _operatorPopUp, _valueField, _secondValueField, _removeButton]) [self addArrangedSubview:view];
		[self columnChanged];
	}
	return self;
}

- (void)dealloc
{
	[_kinds release];
	[_columnPopUp release];
	[_operatorPopUp release];
	[_valueField release];
	[_secondValueField release];
	[_removeButton release];
	[super dealloc];
}

/// Offers the selected column's operators, keeping the chosen one when it still applies.
- (void)columnChanged
{
	NSString *previous = [_operatorPopUp titleOfSelectedItem];
	SPForeignKeyColumnKind kind = (SPForeignKeyColumnKind)[[_kinds objectForKey:[_columnPopUp titleOfSelectedItem]] integerValue];
	[_operatorPopUp removeAllItems];
	[_operatorPopUp addItemsWithTitles:[SPForeignKeyPickerColumn operatorsForKind:kind]];
	if (previous && [_operatorPopUp itemWithTitle:previous]) [_operatorPopUp selectItemWithTitle:previous];
	[self operatorChanged];
}

- (void)operatorChanged
{
	NSString *op = [_operatorPopUp titleOfSelectedItem];
	BOOL takesNoValue = [op isEqualToString:SPForeignKeyOpIsNull] || [op isEqualToString:SPForeignKeyOpIsNotNull];
	[_valueField setHidden:takesNoValue];
	[_secondValueField setHidden:![op isEqualToString:SPForeignKeyOpBetween]];
}

/// The condition the row stands for, or nil while it's incomplete (a value still to type).
- (SPForeignKeyCondition *)condition
{
	NSString *column = [_columnPopUp titleOfSelectedItem];
	NSString *op = [_operatorPopUp titleOfSelectedItem];
	if (!column || !op) return nil;
	if ([op isEqualToString:SPForeignKeyOpIsNull] || [op isEqualToString:SPForeignKeyOpIsNotNull]) {
		return [SPForeignKeyCondition conditionWithColumn:column op:op value:nil secondValue:nil];
	}
	NSString *value = [_valueField stringValue];
	if (![value length]) return nil;
	if ([op isEqualToString:SPForeignKeyOpBetween]) {
		NSString *second = [_secondValueField stringValue];
		if (![second length]) return nil;
		return [SPForeignKeyCondition conditionWithColumn:column op:op value:value secondValue:second];
	}
	return [SPForeignKeyCondition conditionWithColumn:column op:op value:value secondValue:nil];
}

@end

#pragma mark - Picker

@implementation SPForeignKeyPicker
{
	id<SPForeignKeyPickerDataSource> _source;
	SPForeignKeyPickerSettings *_settings;
	NSString *_tableKey;
	NSString *_title;
	id _currentValue;
	BOOL _allowNull;
	void (^_completion)(SPForeignKeyPickerOutcome, NSString *);

	NSArray<SPForeignKeyPickerColumn *> *_allColumns; // nil until loaded
	NSArray<NSString *> *_shown;
	NSMutableArray<NSArray *> *_rows;
	NSString *_highlight;        // the search the rows were fetched for
	BOOL _hasMore;
	BOOL _loadingMore;
	NSUInteger _generation;      // bumped by every new search: older results are dropped
	BOOL _debouncing;            // a new search waits for typing to pause
	BOOL _pendingFetch;          // a new search is debounced or on its way: the list is about to be replaced
	BOOL _chooseAfterFetch;      // Choose / Return came while a search was pending: choose from its first row
	BOOL _done;
	NSInteger _currentRow;        // the row holding the current value, or -1
	NSString *_statusText;
	NSString *_errorMessage;

	NSPopover *_popover;
	NSViewController *_contentController;
	NSStackView *_contentView;
	NSTextField *_titleField;
	NSButton *_gearButton;
	NSSearchField *_searchField;
	NSButton *_addConditionButton;
	NSStackView *_conditionsView;
	NSScrollView *_scrollView;
	NSTableView *_resultsTable;
	NSTextField *_errorField;
	NSTextField *_statusField;
	NSButton *_nullButton;
	NSButton *_typeValueButton;
	NSButton *_loadMoreButton;
	NSButton *_cancelButton;
	NSButton *_chooseButton;
}

@synthesize contentView = _contentView;
@synthesize titleField = _titleField;
@synthesize searchField = _searchField;
@synthesize resultsTable = _resultsTable;
@synthesize conditionsView = _conditionsView;
@synthesize nullButton = _nullButton;
@synthesize loadMoreButton = _loadMoreButton;
@synthesize statusText = _statusText;
@synthesize errorMessage = _errorMessage;
@synthesize searchDelay = _searchDelay;

- (instancetype)initWithDataSource:(id<SPForeignKeyPickerDataSource>)source settings:(SPForeignKeyPickerSettings *)settings
						  tableKey:(NSString *)tableKey title:(NSString *)title currentValue:(id)value allowNull:(BOOL)allowNull
						completion:(void (^)(SPForeignKeyPickerOutcome, NSString *))completion
{
	if ((self = [super init])) {
		_source = [source retain];
		_settings = [settings retain];
		_tableKey = [tableKey copy];
		_title = [title copy];
		_currentValue = [value retain];
		_allowNull = allowNull;
		_completion = [completion copy];
		_rows = [[NSMutableArray alloc] init];
		_statusText = [@"" copy];
		_searchDelay = 0.25;
		_currentRow = -1;
		[self buildView];
		[self loadColumns];
	}
	return self;
}

- (void)dealloc
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[_popover setDelegate:nil];
	[_resultsTable setDataSource:nil];
	[_resultsTable setDelegate:nil];
	[_searchField setDelegate:nil];
	[_source release];
	[_settings release];
	[_tableKey release];
	[_title release];
	[_currentValue release];
	[_completion release];
	[_allColumns release];
	[_shown release];
	[_rows release];
	[_highlight release];
	[_statusText release];
	[_errorMessage release];
	[_popover release];
	[_contentController release];
	[_contentView release];
	[_titleField release];
	[_gearButton release];
	[_searchField release];
	[_addConditionButton release];
	[_conditionsView release];
	[_scrollView release];
	[_resultsTable release];
	[_errorField release];
	[_statusField release];
	[_nullButton release];
	[_typeValueButton release];
	[_loadMoreButton release];
	[_cancelButton release];
	[_chooseButton release];
	[super dealloc];
}

#pragma mark - View

- (NSButton *)newLinkButtonWithTitle:(NSString *)title action:(SEL)action
{
	NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
	[button setBordered:NO];
	[button setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[button setContentTintColor:[NSColor linkColor]];
	return [button retain];
}

- (void)buildView
{
	CGFloat inner = SPForeignKeyPickerWidth - 20;

	_titleField = [[NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Choose %@", @"foreign key picker: title, e.g. Choose orders.customer_id · public.customers"), _title]] retain];
	[_titleField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[_titleField setTextColor:[NSColor secondaryLabelColor]];
	[_titleField setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[_titleField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	_gearButton = [[NSButton buttonWithImage:[NSImage imageNamed:NSImageNameActionTemplate] target:self action:@selector(showColumnsMenu:)] retain];
	[_gearButton setBezelStyle:NSBezelStyleRecessed];
	[_gearButton setControlSize:NSControlSizeSmall];
	[_gearButton setToolTip:NSLocalizedString(@"Show columns", @"foreign key picker: the column menu's heading and the gear button's tooltip")];
	[_gearButton setEnabled:NO];
	NSView *topSpacer = [[[NSView alloc] init] autorelease];
	[topSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView *top = [NSStackView stackViewWithViews:@[_titleField, topSpacer, _gearButton]];

	_searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	[_searchField setDelegate:self];
	[_searchField setControlSize:NSControlSizeSmall];
	[_searchField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[_searchField cell] setSendsSearchStringImmediately:NO];
	[[_searchField cell] setPlaceholderString:NSLocalizedString(@"Search", @"foreign key picker: search placeholder before the columns are known")];
	_addConditionButton = [self newLinkButtonWithTitle:NSLocalizedString(@"+ Condition", @"foreign key picker: adds a column condition row") action:@selector(addConditionButtonClicked:)];
	[_addConditionButton setEnabled:NO];
	NSStackView *search = [NSStackView stackViewWithViews:@[_searchField, _addConditionButton]];

	_conditionsView = [[NSStackView alloc] init];
	[_conditionsView setOrientation:NSUserInterfaceLayoutOrientationVertical];
	[_conditionsView setAlignment:NSLayoutAttributeLeading];
	[_conditionsView setSpacing:4];

	_resultsTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, inner, SPForeignKeyPickerListHeight)];
	[_resultsTable setDataSource:self];
	[_resultsTable setDelegate:self];
	[_resultsTable setTarget:self];
	[_resultsTable setDoubleAction:@selector(tableDoubleClicked:)];
	[_resultsTable setAllowsMultipleSelection:NO];
	[_resultsTable setAllowsEmptySelection:YES];
	[_resultsTable setUsesAlternatingRowBackgroundColors:YES];
	[_resultsTable setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];
	[_resultsTable setRowHeight:17];
	if (@available(macOS 11.0, *)) [_resultsTable setStyle:NSTableViewStylePlain];
	_scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, inner, SPForeignKeyPickerListHeight)];
	[_scrollView setDocumentView:_resultsTable];
	[_scrollView setHasVerticalScroller:YES];
	[_scrollView setHasHorizontalScroller:YES];
	[_scrollView setAutohidesScrollers:YES];
	[_scrollView setBorderType:NSBezelBorder];

	_errorField = [[NSTextField wrappingLabelWithString:@""] retain];
	[_errorField setTextColor:[NSColor systemRedColor]];
	[_errorField setSelectable:YES];
	[_errorField setHidden:YES];

	_statusField = [[NSTextField labelWithString:@""] retain];
	[_statusField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[_statusField setTextColor:[NSColor secondaryLabelColor]];
	_nullButton = [self newLinkButtonWithTitle:NSLocalizedString(@"NULL", @"foreign key picker: sets the cell to NULL") action:@selector(nullClicked:)];
	[_nullButton setHidden:!_allowNull];
	_typeValueButton = [self newLinkButtonWithTitle:NSLocalizedString(@"Type a value…", @"foreign key picker: closes it and edits the cell as text") action:@selector(typeValueClicked:)];
	_loadMoreButton = [self newLinkButtonWithTitle:NSLocalizedString(@"Load more", @"foreign key picker: loads the next 200 rows") action:@selector(loadMoreClicked:)];
	[_loadMoreButton setHidden:YES];
	NSView *footSpacer = [[[NSView alloc] init] autorelease];
	[footSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	_cancelButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"foreign key picker: cancel button") target:self action:@selector(cancelClicked:)] retain];
	[_cancelButton setKeyEquivalent:@"\e"];
	[_cancelButton setControlSize:NSControlSizeSmall];
	_chooseButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Choose", @"foreign key picker: choose button") target:self action:@selector(chooseClicked:)] retain];
	[_chooseButton setKeyEquivalent:@"\r"];
	[_chooseButton setControlSize:NSControlSizeSmall];
	NSStackView *foot = [NSStackView stackViewWithViews:@[_statusField, _nullButton, _typeValueButton, _loadMoreButton, footSpacer, _cancelButton, _chooseButton]];
	[foot setDetachesHiddenViews:YES];

	_contentView = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, SPForeignKeyPickerWidth, 360)];
	[_contentView setOrientation:NSUserInterfaceLayoutOrientationVertical];
	[_contentView setAlignment:NSLayoutAttributeLeading];
	[_contentView setSpacing:6];
	[_contentView setEdgeInsets:NSEdgeInsetsMake(10, 10, 10, 10)];
	[_contentView setDetachesHiddenViews:YES];
	for (NSView *view in @[top, search, _conditionsView, _scrollView, _errorField, foot]) {
		[_contentView addArrangedSubview:view];
		[[[view widthAnchor] constraintEqualToConstant:inner] setActive:YES];
	}
	[[[_scrollView heightAnchor] constraintEqualToConstant:SPForeignKeyPickerListHeight] setActive:YES];
	[[[_errorField heightAnchor] constraintGreaterThanOrEqualToConstant:SPForeignKeyPickerListHeight] setActive:YES];
	[_contentView setFrameSize:[_contentView fittingSize]];
}

- (void)fitPopover
{
	NSSize size = [_contentView fittingSize];
	[_contentView setFrameSize:size];
	if (_popover) [_popover setContentSize:size];
}

#pragma mark - Showing

- (BOOL)showRelativeToRect:(NSRect)rect ofView:(NSView *)view
{
	if (![view window] || SPCurrentForeignKeyPicker) {
		[self finishWith:SPForeignKeyPickerCancelled value:nil];
		return NO;
	}
	if (_done) return NO;
	SPCurrentForeignKeyPicker = [self retain]; // until it finishes

	_contentController = [[NSViewController alloc] init];
	[_contentController setView:_contentView];
	_popover = [[NSPopover alloc] init];
	[_popover setContentViewController:_contentController];
	[_popover setContentSize:[_contentView fittingSize]];
	[_popover setBehavior:NSPopoverBehaviorTransient];
	[_popover setDelegate:self];
	[_popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMaxY];
	[[_contentView window] makeFirstResponder:_searchField];
	return YES;
}

/// Calls completion once, closes the popover and lets go of the picker; results still on their way are dropped.
- (void)finishWith:(SPForeignKeyPickerOutcome)outcome value:(NSString *)value
{
	if (_done) return;
	_done = YES;
	_generation++;
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchFromStart) object:nil];
	[_source cancelPendingFetches];
	void (^handler)(SPForeignKeyPickerOutcome, NSString *) = [[_completion retain] autorelease];
	[_completion release];
	_completion = nil;

	[_popover setDelegate:nil];
	if ([_popover isShown]) [_popover close];
	if (handler) handler(outcome, value);
	if (SPCurrentForeignKeyPicker == self) {
		SPCurrentForeignKeyPicker = nil;
		[self autorelease];
	}
}

/// Escape or a click outside closes it: cancelled.
- (void)popoverDidClose:(NSNotification *)notification
{
	[self finishWith:SPForeignKeyPickerCancelled value:nil];
}

#pragma mark - Loading

- (void)loadColumns
{
	[_source loadColumnsWithCompletion:^(NSArray<SPForeignKeyPickerColumn *> *columns, NSString *errorMessage) {
		if (_done) return;
		if (!columns) {
			[self showError:errorMessage];
			return;
		}
		[_allColumns release];
		_allColumns = [columns copy];
		[_gearButton setEnabled:YES];
		[_addConditionButton setEnabled:YES];
		[self applyShownColumns];
		[self fetchFromStart];
	}];
}

- (NSArray<NSString *> *)availableColumnNames
{
	return [_allColumns valueForKey:@"name"];
}

/// Reads the shown columns from the settings, and rebuilds the list's columns and the search placeholder.
- (void)applyShownColumns
{
	NSString *key = [_source keyColumn];
	[_shown release];
	_shown = [[_settings shownColumnsForTableKey:_tableKey available:[self availableColumnNames] keyColumn:key] copy];

	for (NSTableColumn *column in [[[_resultsTable tableColumns] copy] autorelease]) [_resultsTable removeTableColumn:column];
	for (NSString *name in _shown) {
		NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:name] autorelease];
		[[column headerCell] setStringValue:name];
		[column setEditable:NO];
		[column setWidth:[name isEqualToString:key] ? 80 : 130];
		[[column dataCell] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[[column dataCell] setLineBreakMode:NSLineBreakByTruncatingTail];
		[_resultsTable addTableColumn:column];
	}

	NSMutableArray *searched = [NSMutableArray array];
	for (NSString *name in _shown) if (![name isEqualToString:key]) [searched addObject:name];
	if (![searched count]) [searched addObject:key];
	[[_searchField cell] setPlaceholderString:[NSString stringWithFormat:NSLocalizedString(@"Search %@", @"foreign key picker: search placeholder naming the shown columns, e.g. Search name, email"), [searched componentsJoinedByString:@", "]]];
}

- (NSArray<SPForeignKeyCondition *> *)conditions
{
	NSMutableArray *conditions = [NSMutableArray array];
	for (SPForeignKeyConditionRow *row in [_conditionsView arrangedSubviews]) {
		SPForeignKeyCondition *condition = [row condition];
		if (condition) [conditions addObject:condition];
	}
	return conditions;
}

- (void)scheduleFetch
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchFromStart) object:nil];
	if (_searchDelay <= 0) [self fetchFromStart];
	else {
		_debouncing = YES;
		_pendingFetch = YES;
		[self performSelector:@selector(fetchFromStart) withObject:nil afterDelay:_searchDelay];
	}
}

/// A new search: the first page for the current text, conditions and columns.
- (void)fetchFromStart
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchFromStart) object:nil];
	_debouncing = NO;
	if (_done || !_allColumns) return;
	_generation++;
	_loadingMore = NO;
	_pendingFetch = YES;
	[self fetchFromOffset:0];
}

- (void)fetchFromOffset:(NSUInteger)offset
{
	NSUInteger generation = _generation;
	NSString *search = [[[_searchField stringValue] copy] autorelease];
	[_source fetchRowsWithSearch:search inColumns:_shown conditions:[self conditions] columns:_shown
						  offset:offset limit:SPForeignKeyPickerPageSize + 1 completion:^(NSArray<NSArray *> *rows, NSString *errorMessage) {
		if (_done || generation != _generation) return;
		if (!rows && !errorMessage) return; // skipped by the source: superseded before it ran
		_loadingMore = NO;
		BOOL chooseNow = NO;
		if (offset == 0) {
			_pendingFetch = NO;
			chooseNow = _chooseAfterFetch;
			_chooseAfterFetch = NO;
		}
		if (!rows) {
			[self showError:errorMessage];
			return;
		}
		[self hideError];
		if (offset == 0) {
			[_rows removeAllObjects];
			[_highlight release];
			_highlight = [search copy];
		}
		_hasMore = [rows count] > SPForeignKeyPickerPageSize;
		[_rows addObjectsFromArray:_hasMore ? [rows subarrayWithRange:NSMakeRange(0, SPForeignKeyPickerPageSize)] : rows];
		[self updateCurrentRow];
		[_resultsTable reloadData];
		if (offset == 0) {
			NSInteger current = [self currentValueRow];
			if (current >= 0) {
				[_resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)current] byExtendingSelection:NO];
				[_resultsTable scrollRowToVisible:current];
			}
			else if ([_rows count]) {
				[_resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
				[_resultsTable scrollRowToVisible:0];
			}
		}
		[self updateStatus];
		// Choose / Return while this search was pending: its first row, if it found any
		if (chooseNow && [_rows count]) [self chooseRow:0];
	}];
}

- (void)loadMore
{
	// While a new search is pending, the next page of the list it replaces would be the wrong rows
	if (_done || !_hasMore || _loadingMore || _pendingFetch) return;
	_loadingMore = YES;
	[self fetchFromOffset:[_rows count]];
}

- (void)updateStatus
{
	NSString *status = _hasMore
		? [NSString stringWithFormat:NSLocalizedString(@"%lu shown, more…", @"foreign key picker: footer when more rows can be loaded"), (unsigned long)[_rows count]]
		: [NSString stringWithFormat:NSLocalizedString(@"%lu matches", @"foreign key picker: footer when every match is loaded"), (unsigned long)[_rows count]];
	[_statusText release];
	_statusText = [status copy];
	[_statusField setStringValue:status];
	[_loadMoreButton setHidden:!_hasMore];
}

- (void)showError:(NSString *)message
{
	[_errorMessage release];
	_errorMessage = [(message ?: @"") copy];
	[_rows removeAllObjects];
	_currentRow = -1;
	_hasMore = NO;
	[_resultsTable reloadData];
	[_errorField setStringValue:_errorMessage];
	[_errorField setHidden:NO];
	[_scrollView setHidden:YES];
	[_loadMoreButton setHidden:YES];
	[_statusText release];
	_statusText = [@"" copy];
	[_statusField setStringValue:@""];
	[self fitPopover];
}

- (void)hideError
{
	if (!_errorMessage) return;
	[_errorMessage release];
	_errorMessage = nil;
	[_errorField setHidden:YES];
	[_scrollView setHidden:NO];
	[self fitPopover];
}

- (NSArray<NSArray *> *)rows
{
	return [[_rows copy] autorelease];
}

- (NSInteger)currentValueRow
{
	return _currentRow;
}

- (void)updateCurrentRow
{
	_currentRow = -1;
	if (![_currentValue isKindOfClass:[NSString class]]) return;
	for (NSUInteger i = 0; i < [_rows count]; i++) {
		if ([[[_rows objectAtIndex:i] firstObject] isEqual:_currentValue]) { _currentRow = (NSInteger)i; return; }
	}
}

#pragma mark - Conditions

- (void)addCondition
{
	if (_done || !_allColumns) return;
	SPForeignKeyConditionRow *row = [[[SPForeignKeyConditionRow alloc] initWithColumns:_allColumns picker:self] autorelease];
	[_conditionsView addArrangedSubview:row];
	[self fitPopover];
	[[_contentView window] makeFirstResponder:[row valueField]];
}

- (SPForeignKeyConditionRow *)conditionRowOf:(NSView *)control
{
	NSView *view = control;
	while (view && ![view isKindOfClass:[SPForeignKeyConditionRow class]]) view = [view superview];
	return (SPForeignKeyConditionRow *)view;
}

- (IBAction)addConditionButtonClicked:(id)sender
{
	[self addCondition];
}

- (IBAction)conditionColumnChanged:(id)sender
{
	[[self conditionRowOf:sender] columnChanged];
	[self fitPopover];
	[self fetchFromStart];
}

- (IBAction)conditionOperatorChanged:(id)sender
{
	[[self conditionRowOf:sender] operatorChanged];
	[self fitPopover];
	[self fetchFromStart];
}

- (IBAction)removeCondition:(id)sender
{
	SPForeignKeyConditionRow *row = [self conditionRowOf:sender];
	if (!row) return;
	BOOL counted = [row condition] != nil;
	[_conditionsView removeArrangedSubview:row];
	[row removeFromSuperview];
	[self fitPopover];
	[[_contentView window] makeFirstResponder:_searchField];
	if (counted) [self fetchFromStart];
}

#pragma mark - Columns menu

- (NSMenu *)columnsMenu
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	[menu setAutoenablesItems:NO];
	NSMenuItem *heading = [menu addItemWithTitle:NSLocalizedString(@"Show columns", @"foreign key picker: the column menu's heading and the gear button's tooltip") action:NULL keyEquivalent:@""];
	[heading setEnabled:NO];

	NSString *key = [_source keyColumn];
	for (NSString *name in [self availableColumnNames]) {
		BOOL isKey = [name isEqualToString:key];
		BOOL shown = [_shown containsObject:name];
		NSMenuItem *item = [menu addItemWithTitle:name action:@selector(toggleShownColumn:) keyEquivalent:@""];
		[item setTarget:self];
		[item setRepresentedObject:name];
		[item setState:shown ? NSControlStateValueOn : NSControlStateValueOff];
		[item setEnabled:!isKey];

		// A checkbox view, so that ticking keeps the menu open
		NSButton *checkbox = [NSButton checkboxWithTitle:isKey ? [NSString stringWithFormat:NSLocalizedString(@"%@ (the key, always shown)", @"foreign key picker: the key column's item in the column menu"), name] : name
												   target:self action:@selector(toggleShownColumnCheckbox:)];
		[checkbox setIdentifier:name];
		[checkbox setState:[item state]];
		[checkbox setEnabled:!isKey];
		[checkbox setFrameOrigin:NSMakePoint(14, 1)];
		NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, MAX(180, NSWidth([checkbox frame]) + 28), NSHeight([checkbox frame]) + 2)] autorelease];
		[view addSubview:checkbox];
		[item setView:view];
	}
	[menu addItem:[NSMenuItem separatorItem]];
	[[menu addItemWithTitle:NSLocalizedString(@"Show All Columns", @"foreign key picker: column menu item") action:@selector(showAllColumns:) keyEquivalent:@""] setTarget:self];
	[[menu addItemWithTitle:NSLocalizedString(@"Reset to Default", @"foreign key picker: column menu item") action:@selector(resetShownColumns:) keyEquivalent:@""] setTarget:self];
	return menu;
}

- (IBAction)showColumnsMenu:(id)sender
{
	[[self columnsMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight([_gearButton bounds]) + 2) inView:_gearButton];
}

- (void)setColumnShown:(NSString *)name shown:(BOOL)shown
{
	if (!name || [name isEqualToString:[_source keyColumn]]) return;
	NSMutableArray *columns = [NSMutableArray array];
	for (NSString *column in [self availableColumnNames]) {
		BOOL isShown = [column isEqualToString:name] ? shown : [_shown containsObject:column];
		if (isShown) [columns addObject:column];
	}
	[_settings setShownColumns:columns forTableKey:_tableKey];
	[self columnsChanged];
}

- (IBAction)toggleShownColumn:(NSMenuItem *)sender
{
	NSString *name = [sender representedObject];
	[self setColumnShown:name shown:![_shown containsObject:name]];
}

- (IBAction)toggleShownColumnCheckbox:(NSButton *)sender
{
	[self setColumnShown:[sender identifier] shown:[sender state] == NSControlStateValueOn];
}

- (IBAction)showAllColumns:(id)sender
{
	[_settings setShownColumns:[self availableColumnNames] forTableKey:_tableKey];
	[self columnsChanged];
}

- (IBAction)resetShownColumns:(id)sender
{
	[_settings setShownColumns:nil forTableKey:_tableKey];
	[self columnsChanged];
}

- (void)columnsChanged
{
	[self applyShownColumns];
	[_resultsTable reloadData];
	[self fetchFromStart];
}

#pragma mark - Outcomes

/// Chooses the selected row; while a new search is pending, the first row it finds instead (at once, not after the pause).
- (void)choose
{
	if (_done) return;
	if (_pendingFetch) {
		_chooseAfterFetch = YES;
		if (_debouncing) [self fetchFromStart];
		return;
	}
	[self chooseRow:[_resultsTable selectedRow]];
}

- (void)chooseRow:(NSInteger)row
{
	if (_done || row < 0 || (NSUInteger)row >= [_rows count]) return;
	id key = [[_rows objectAtIndex:(NSUInteger)row] firstObject];
	if (![key isKindOfClass:[NSString class]]) {
		NSBeep(); // a NULL key can't be chosen
		return;
	}
	[self finishWith:SPForeignKeyPickerChose value:key];
}

- (void)chooseNull
{
	if (_done) return;
	if (!_allowNull) {
		NSBeep();
		return;
	}
	[self finishWith:SPForeignKeyPickerChoseNull value:nil];
}

- (void)typeValue
{
	[self finishWith:SPForeignKeyPickerTypeValue value:nil];
}

- (void)cancel
{
	[self finishWith:SPForeignKeyPickerCancelled value:nil];
}

- (IBAction)chooseClicked:(id)sender { [self choose]; }
- (IBAction)nullClicked:(id)sender { [self chooseNull]; }
- (IBAction)typeValueClicked:(id)sender { [self typeValue]; }
- (IBAction)cancelClicked:(id)sender { [self cancel]; }
- (IBAction)loadMoreClicked:(id)sender { [self loadMore]; }

- (IBAction)tableDoubleClicked:(id)sender
{
	// The row double-clicked is one on screen: chosen as it is, even while a search is pending
	NSInteger clicked = [_resultsTable clickedRow];
	if (clicked >= 0) [_resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)clicked] byExtendingSelection:NO];
	[self chooseRow:[_resultsTable selectedRow]];
}

#pragma mark - Search field and condition fields

- (void)controlTextDidChange:(NSNotification *)notification
{
	if (_done) return;
	[self scheduleFetch];
}

/// ↑/↓ move the list's selection, Return chooses and Escape cancels, while typing in the search field.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
	if (command == @selector(cancelOperation:)) {
		[self cancel];
		return YES;
	}
	if (control != _searchField) return NO;
	NSInteger count = (NSInteger)[_rows count];
	NSInteger selected = [_resultsTable selectedRow];
	if (command == @selector(moveDown:) || command == @selector(moveUp:)) {
		if (!count) return YES;
		NSInteger row = (command == @selector(moveDown:)) ? (selected < 0 ? 0 : MIN(selected + 1, count - 1)) : MAX(selected - 1, 0);
		[_resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[_resultsTable scrollRowToVisible:row];
		if (row == count - 1) [self loadMore];
		return YES;
	}
	if (command == @selector(insertNewline:)) {
		[self choose];
		return YES;
	}
	return NO;
}

#pragma mark - Results table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)[_rows count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || (NSUInteger)row >= [_rows count]) return nil;
	NSArray *values = [_rows objectAtIndex:(NSUInteger)row];
	NSUInteger index = [_shown indexOfObject:[tableColumn identifier]];
	if (index == NSNotFound || index >= [values count]) return nil;
	id value = [values objectAtIndex:index];
	CGFloat size = [NSFont smallSystemFontSize];
	NSFont *font = index == 0 ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
	if (![value isKindOfClass:[NSString class]]) {
		return [[[NSAttributedString alloc] initWithString:@"NULL" attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]}] autorelease];
	}
	if (![_highlight length] || [value rangeOfString:_highlight options:NSCaseInsensitiveSearch].location == NSNotFound) return value;

	// The search's matches highlighted
	NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:value attributes:@{NSFontAttributeName: font}] autorelease];
	NSRange searchRange = NSMakeRange(0, [value length]);
	while (searchRange.length) {
		NSRange match = [value rangeOfString:_highlight options:NSCaseInsensitiveSearch range:searchRange];
		if (match.location == NSNotFound) break;
		[text addAttribute:NSBackgroundColorAttributeName value:[[NSColor systemYellowColor] colorWithAlphaComponent:0.5] range:match];
		searchRange = NSMakeRange(NSMaxRange(match), [value length] - NSMaxRange(match));
	}
	return text;
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (![cell isKindOfClass:[NSTextFieldCell class]]) return;
	CGFloat size = [NSFont smallSystemFontSize];
	BOOL isKey = [[tableColumn identifier] isEqual:[_shown firstObject]];
	[cell setFont:isKey ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size]];
	// The cell's current value tinted
	BOOL tinted = row == [self currentValueRow] && ![tableView isRowSelected:row];
	[cell setDrawsBackground:tinted];
	if (tinted) [cell setBackgroundColor:[[NSColor controlAccentColor] colorWithAlphaComponent:0.15]];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

@end
