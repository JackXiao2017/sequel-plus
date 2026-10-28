#import "SPPostgresTriggersController.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresTableDuplicator.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPConstants.h"

// MySQL's Triggers tab (DBView.xib): a 23 pt button bar, 32 x 25 textured buttons
static const CGFloat SPPostgresTriggersBarHeight = 23;
static const CGFloat SPPostgresTriggersButtonWidth = 32;

static const CGFloat SPPostgresTriggerSheetWidth = 440;
static const CGFloat SPPostgresTriggerSheetLabelWidth = 110;
static const CGFloat SPPostgresTriggerSheetMargin = 20;

#pragma mark - SPPostgresTriggerDefinition

@implementation SPPostgresTriggerDefinition

@synthesize name = _name;
@synthesize timing = _timing;
@synthesize events = _events;
@synthesize updateColumns = _updateColumns;
@synthesize level = _level;
@synthesize function = _function;
@synthesize condition = _condition;

- (void)dealloc
{
	[_name release];
	[_timing release];
	[_events release];
	[_updateColumns release];
	[_level release];
	[_function release];
	[_condition release];
	[super dealloc];
}

@end

#pragma mark - SPPostgresTriggerSheet

@implementation SPPostgresTriggerSheet
{
	NSArray *columnNames;
	NSArray *functions;
	void (^completion)(SPPostgresTriggerDefinition *);
	NSMutableArray *chosenColumns;   // UPDATE OF, in the order they were checked

	NSWindow *sheet;
	NSTextField *nameField;
	NSPopUpButton *timingPopup;
	NSArray *eventSwitches;          // INSERT, UPDATE, DELETE, TRUNCATE
	NSTableView *columnsTable;
	NSPopUpButton *levelPopup;
	NSPopUpButton *functionPopup;
	NSTextField *functionHint;
	NSTextField *conditionField;
	NSButton *addButton;
}

+ (void)beginWithColumns:(NSArray *)theColumns functions:(NSArray *)theFunctions window:(NSWindow *)window completion:(void (^)(SPPostgresTriggerDefinition *))theCompletion
{
	if (!theCompletion) return;
	if (!window || [window attachedSheet]) {
		theCompletion(nil);
		return;
	}
	SPPostgresTriggerSheet *controller = [[self alloc] init];
	controller->columnNames = [(theColumns ?: @[]) copy];
	controller->functions = [(theFunctions ?: @[]) copy];
	controller->completion = [theCompletion copy];
	controller->chosenColumns = [[NSMutableArray alloc] init];
	[controller _beginOn:window]; // keeps itself until the sheet ends
	[controller release];
}

- (void)dealloc
{
	[columnsTable setDataSource:nil];
	[columnsTable setDelegate:nil];
	[nameField setDelegate:nil];
	[conditionField setDelegate:nil];

	[columnNames release];
	[functions release];
	[completion release];
	[chosenColumns release];
	[sheet release];
	[nameField release];
	[timingPopup release];
	[eventSwitches release];
	[columnsTable release];
	[levelPopup release];
	[functionPopup release];
	[functionHint release];
	[conditionField release];
	[addButton release];
	[super dealloc];
}

- (NSTextField *)_label:(NSString *)text frame:(NSRect)frame
{
	NSTextField *label = [NSTextField labelWithString:text];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[label setAlignment:NSTextAlignmentRight];
	[label setFrame:frame];
	[[sheet contentView] addSubview:label];
	return label;
}

- (NSPopUpButton *)_popupWithTitles:(NSArray *)titles identifier:(NSString *)identifier frame:(NSRect)frame
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
	[popup setIdentifier:identifier];
	[[popup cell] setControlSize:NSControlSizeSmall];
	[popup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[popup addItemsWithTitles:titles];
	[popup setTarget:self];
	[popup setAction:@selector(_changed:)];
	[[sheet contentView] addSubview:popup];
	return popup;
}

- (NSTextField *)_fieldWithIdentifier:(NSString *)identifier placeholder:(NSString *)placeholder frame:(NSRect)frame
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
	[field setIdentifier:identifier];
	[[field cell] setControlSize:NSControlSizeSmall];
	[field setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[field cell] setScrollable:YES];
	[[field cell] setUsesSingleLineMode:YES];
	[[field cell] setPlaceholderString:placeholder];
	[field setDelegate:self];
	[[sheet contentView] addSubview:field];
	return field;
}

/// Name, timing, events (with the UPDATE OF columns), level, function, WHEN; Cancel / Add. Laid out top-down.
- (void)_build
{
	CGFloat height = 470;
	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, SPPostgresTriggerSheetWidth, height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	NSString *title = NSLocalizedString(@"Add Trigger", @"Postgres trigger sheet: title");
	[sheet setTitle:title];
	NSView *content = [sheet contentView];

	CGFloat labelX = SPPostgresTriggerSheetMargin;
	CGFloat controlX = labelX + SPPostgresTriggerSheetLabelWidth + 8;
	CGFloat controlWidth = SPPostgresTriggerSheetWidth - controlX - SPPostgresTriggerSheetMargin;
	CGFloat y = height - 32;

	NSTextField *titleLabel = [NSTextField labelWithString:title];
	[titleLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[titleLabel setFrame:NSMakeRect(labelX, y, SPPostgresTriggerSheetWidth - 2 * SPPostgresTriggerSheetMargin, 18)];
	[content addSubview:titleLabel];

	y -= 30;
	[self _label:NSLocalizedString(@"Name:", @"Postgres trigger sheet: name label") frame:NSMakeRect(labelX, y + 2, SPPostgresTriggerSheetLabelWidth, 16)];
	nameField = [self _fieldWithIdentifier:@"triggerName" placeholder:@"" frame:NSMakeRect(controlX, y, controlWidth, 19)];

	y -= 30;
	[self _label:NSLocalizedString(@"Timing:", @"Postgres trigger sheet: timing label") frame:NSMakeRect(labelX, y + 4, SPPostgresTriggerSheetLabelWidth, 16)];
	// INSTEAD OF is for views, which have no Triggers view
	timingPopup = [self _popupWithTitles:@[@"BEFORE", @"AFTER"] identifier:@"triggerTiming" frame:NSMakeRect(controlX, y, controlWidth, 22)];

	y -= 28;
	[self _label:NSLocalizedString(@"Events:", @"Postgres trigger sheet: events label") frame:NSMakeRect(labelX, y + 2, SPPostgresTriggerSheetLabelWidth, 16)];
	NSMutableArray *switches = [NSMutableArray array];
	CGFloat x = controlX;
	for (NSString *event in @[@"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE"]) {
		NSButton *check = [NSButton checkboxWithTitle:event target:self action:@selector(_changed:)];
		[check setIdentifier:[@"triggerEvent" stringByAppendingString:event]];
		[check setControlSize:NSControlSizeSmall];
		[check setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[check sizeToFit];
		[check setFrameOrigin:NSMakePoint(x, y)];
		x += NSWidth([check frame]) + 6;
		[content addSubview:check];
		[switches addObject:check];
	}
	eventSwitches = [switches copy];

	y -= 100;
	[self _label:NSLocalizedString(@"Update of:", @"Postgres trigger sheet: update columns label") frame:NSMakeRect(labelX, y + 80, SPPostgresTriggerSheetLabelWidth, 16)];
	NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(controlX, y, controlWidth, 92)] autorelease];
	[scroll setHasVerticalScroller:YES];
	[scroll setAutohidesScrollers:YES];
	[scroll setBorderType:NSBezelBorder];
	[scroll setToolTip:NSLocalizedString(@"None checked: an update of any column", @"Postgres trigger sheet: update columns tooltip")];
	columnsTable = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
	[columnsTable setIdentifier:@"triggerUpdateColumns"];
	[columnsTable setHeaderView:nil];
	[columnsTable setRowHeight:17];
	[columnsTable setFocusRingType:NSFocusRingTypeNone];
	[columnsTable setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
	NSTableColumn *use = [[[NSTableColumn alloc] initWithIdentifier:@"use"] autorelease];
	NSButtonCell *check = [[[NSButtonCell alloc] initTextCell:@""] autorelease];
	[check setButtonType:NSButtonTypeSwitch];
	[check setControlSize:NSControlSizeSmall];
	[check setImagePosition:NSImageOnly];
	[use setDataCell:check];
	[use setWidth:20];
	[columnsTable addTableColumn:use];
	NSTableColumn *name = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
	[[name dataCell] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[name setEditable:NO];
	[name setWidth:170];
	[columnsTable addTableColumn:name];
	[columnsTable setDataSource:self];
	[columnsTable setDelegate:self];
	[scroll setDocumentView:columnsTable];
	[content addSubview:scroll];

	y -= 30;
	[self _label:NSLocalizedString(@"Level:", @"Postgres trigger sheet: level label") frame:NSMakeRect(labelX, y + 4, SPPostgresTriggerSheetLabelWidth, 16)];
	levelPopup = [self _popupWithTitles:@[@"FOR EACH ROW", @"FOR EACH STATEMENT"] identifier:@"triggerLevel" frame:NSMakeRect(controlX, y, controlWidth, 22)];

	y -= 30;
	[self _label:NSLocalizedString(@"Function:", @"Postgres trigger sheet: function label") frame:NSMakeRect(labelX, y + 4, SPPostgresTriggerSheetLabelWidth, 16)];
	functionPopup = [self _popupWithTitles:functions identifier:@"triggerFunction" frame:NSMakeRect(controlX, y, controlWidth, 22)];
	y -= 18;
	functionHint = [[NSTextField labelWithString:NSLocalizedString(@"There are no trigger functions. Create one (RETURNS trigger) in the Query view.", @"Postgres trigger sheet: no trigger functions")] retain];
	[functionHint setIdentifier:@"triggerFunctionHint"];
	[functionHint setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[functionHint setTextColor:[NSColor secondaryLabelColor]];
	[[functionHint cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[functionHint setFrame:NSMakeRect(controlX, y, controlWidth, 14)];
	[functionHint setHidden:[functions count] > 0];
	[content addSubview:functionHint];

	y -= 30;
	[self _label:NSLocalizedString(@"When:", @"Postgres trigger sheet: condition label") frame:NSMakeRect(labelX, y + 2, SPPostgresTriggerSheetLabelWidth, 16)];
	conditionField = [self _fieldWithIdentifier:@"triggerCondition" placeholder:NSLocalizedString(@"Optional, e.g. OLD.price IS DISTINCT FROM NEW.price", @"Postgres trigger sheet: condition placeholder") frame:NSMakeRect(controlX, y, controlWidth, 19)];
	[conditionField setFont:[NSFont monospacedSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightRegular]];

	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(_close:)];
	[cancel setTag:NSModalResponseCancel];
	[cancel setKeyEquivalent:@"\e"];
	[cancel setFrame:NSMakeRect(SPPostgresTriggerSheetWidth - 200, 12, 91, 28)];
	[content addSubview:cancel];
	addButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Add", @"Postgres trigger sheet: add button") target:self action:@selector(_close:)] retain];
	[addButton setIdentifier:@"triggerAddButton"];
	[addButton setTag:NSModalResponseOK];
	[addButton setKeyEquivalent:@"\r"];
	[addButton setFrame:NSMakeRect(SPPostgresTriggerSheetWidth - 110, 12, 91, 28)];
	[content addSubview:addButton];

	[sheet setInitialFirstResponder:nameField];
	[self _validate];
}

#pragma mark - Validation

- (NSArray *)_chosenEvents
{
	NSMutableArray *events = [NSMutableArray array];
	for (NSButton *check in eventSwitches) {
		if ([check state] == NSControlStateValueOn) [events addObject:[check title]];
	}
	return events;
}

- (BOOL)_isRowLevel
{
	return [levelPopup indexOfSelectedItem] == 0;
}

/// Add only for what PostgreSQL could take; the UPDATE OF list only with UPDATE.
- (void)_validate
{
	NSArray *events = [self _chosenEvents];
	BOOL updates = [events containsObject:@"UPDATE"];
	[columnsTable setEnabled:updates];
	if (!updates && [chosenColumns count]) {
		[chosenColumns removeAllObjects];
		[columnsTable reloadData];
	}

	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:whitespace];
	BOOL hasCondition = [[[conditionField stringValue] stringByTrimmingCharactersInSet:whitespace] length] > 0;
	BOOL valid = [name length] && [SPPostgresTableDuplicator isValidTableName:name]
		&& [events count] > 0
		&& [[functionPopup titleOfSelectedItem] length] > 0
		&& !([events containsObject:@"TRUNCATE"] && [self _isRowLevel])  // TRUNCATE: statement level only
		&& !(hasCondition && ![self _isRowLevel]);                       // WHEN: row level only
	[addButton setEnabled:valid];
}

- (void)_changed:(id)sender
{
	[self _validate];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self _validate];
}

#pragma mark - Column list

- (NSInteger)numberOfRowsInTableView:(NSTableView *)list
{
	return (NSInteger)[columnNames count];
}

- (id)tableView:(NSTableView *)list objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[columnNames count]) return nil;
	NSString *name = [columnNames objectAtIndex:(NSUInteger)row];
	if ([[tableColumn identifier] isEqualToString:@"use"]) return @([chosenColumns containsObject:name]);
	return name;
}

- (void)tableView:(NSTableView *)list setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[columnNames count] || ![[tableColumn identifier] isEqualToString:@"use"]) return;
	NSString *name = [columnNames objectAtIndex:(NSUInteger)row];
	[chosenColumns removeObject:name];
	if ([object boolValue]) [chosenColumns addObject:name];
	[list reloadData];
	[self _validate];
}

- (BOOL)tableView:(NSTableView *)list shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return [[tableColumn identifier] isEqualToString:@"use"] && [list isEnabled];
}

#pragma mark - Ending

- (void)_beginOn:(NSWindow *)window
{
	[self _build];
	[self retain]; // until the sheet ends
	[window beginSheet:sheet completionHandler:^(NSModalResponse returnCode) {
		SPPostgresTriggerDefinition *definition = (returnCode == NSModalResponseOK) ? [self _definition] : nil;
		[sheet orderOut:nil];
		void (^done)(SPPostgresTriggerDefinition *) = [[completion retain] autorelease];
		[completion release];
		completion = nil;
		if (done) done(definition);
		[self release];
	}];
}

- (void)_close:(id)sender
{
	if ([sender tag] == NSModalResponseOK && ![addButton isEnabled]) {
		NSBeep();
		return;
	}
	[[sheet sheetParent] endSheet:sheet returnCode:[sender tag]];
}

- (SPPostgresTriggerDefinition *)_definition
{
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	SPPostgresTriggerDefinition *definition = [[[SPPostgresTriggerDefinition alloc] init] autorelease];
	[definition setName:[[nameField stringValue] stringByTrimmingCharactersInSet:whitespace]];
	[definition setTiming:[timingPopup titleOfSelectedItem]];
	NSArray *events = [self _chosenEvents];
	[definition setEvents:events];
	[definition setUpdateColumns:([events containsObject:@"UPDATE"] && [chosenColumns count]) ? [[chosenColumns copy] autorelease] : nil];
	[definition setLevel:[self _isRowLevel] ? @"ROW" : @"STATEMENT"];
	[definition setFunction:[functionPopup titleOfSelectedItem]];
	NSString *condition = [[conditionField stringValue] stringByTrimmingCharactersInSet:whitespace];
	[definition setCondition:[condition length] ? condition : nil];
	return definition;
}

@end

#pragma mark - SPPostgresTriggersController

@interface SPPostgresTriggersController ()

@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *table;
@property (readwrite, copy) NSString *noticeText;

@end

@implementation SPPostgresTriggersController
{
	PGPostgresConnection *connection;
	SPPostgresTableStructure *structure;
	NSArray *triggers;      // SPPostgresTrigger
	BOOL loaded;

	NSView *view;
	NSSplitView *split;     // the grid and its bar over the function source (hidden under an empty state)
	SPTableView *triggersView;
	NSTextView *functionSourceView;
	NSButton *addButton;
	NSButton *removeButton;
	NSButton *refreshButton;
	NSTextField *noticeField;
	NSTextField *emptyStateField;

	/// The + sheet while it is up, ended by -invalidate
	NSWindow *activeSheet;

	BOOL invalidated;
}

@synthesize schema;
@synthesize table;
@synthesize noticeText;
@synthesize emptyStateText;
@synthesize alertPresenter;
@synthesize confirmationPresenter;
@synthesize triggerSheetPresenter;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		triggers = [@[] retain];
		noticeText = [@"" copy];
		emptyStateText = [@"" copy];
		[self _buildView];
		[self _updateButtons];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[structure release];
	[triggers release];
	[schema release];
	[table release];
	[noticeText release];
	[emptyStateText release];

	[view release];
	[split release];
	[triggersView release];
	[functionSourceView release];
	[addButton release];
	[removeButton release];
	[refreshButton release];
	[noticeField release];
	[emptyStateField release];
	[activeSheet release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;

	[triggersView setDataSource:nil];
	[triggersView setDelegate:nil];
	for (NSControl *control in @[addButton, removeButton, refreshButton]) [control setTarget:nil];

	// A sheet still up ends (cancelled); its completion sees `invalidated`
	NSWindow *sheet = [activeSheet autorelease];
	activeSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet returnCode:NSModalResponseCancel];

	// The presenters may capture the tab
	[alertPresenter release], alertPresenter = nil;
	[confirmationPresenter release], confirmationPresenter = nil;
	[triggerSheetPresenter release], triggerSheetPresenter = nil;
}

#pragma mark - View

- (NSButton *)_newBarButtonWithImage:(NSString *)imageName toolTip:(NSString *)toolTip action:(SEL)action x:(CGFloat)x
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, -1, SPPostgresTriggersButtonWidth, 25)];
	[button setBezelStyle:NSBezelStyleTexturedRounded];
	[button setImage:[NSImage imageNamed:imageName]];
	[button setImagePosition:NSImageOnly];
	[button setToolTip:toolTip];
	[button setTarget:self];
	[button setAction:action];
	return button;
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

- (void)_addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width checkbox:(BOOL)checkbox
{
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:identifier] autorelease];
	[[column headerCell] setStringValue:title];
	[column setWidth:width];
	[column setMinWidth:30];
	[column setResizingMask:NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask];
	NSCell *cell = nil;
	if (checkbox) {
		NSButtonCell *check = [[[NSButtonCell alloc] initTextCell:@""] autorelease];
		[check setButtonType:NSButtonTypeSwitch];
		[check setControlSize:NSControlSizeSmall];
		[check setImagePosition:NSImageOnly];
		[check setAlignment:NSTextAlignmentCenter];
		cell = check;
	}
	else {
		NSTextFieldCell *text = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[text setLineBreakMode:NSLineBreakByTruncatingTail];
		cell = text;
	}
	[cell setFont:[self _tableFont]];
	[column setDataCell:cell];
	[column setEditable:checkbox];
	[triggersView addTableColumn:column];
}

/// The grid and its bar on top, the selected trigger's function source below, as MySQL's Triggers tab (which
/// shows the statement); an empty-state text over both.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	CGFloat width = NSWidth(frame);
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	split = [[NSSplitView alloc] initWithFrame:frame];
	[split setVertical:NO];
	[split setDividerStyle:NSSplitViewDividerStyleThin];
	[split setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// Grid and bar
	NSView *gridSection = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 300)] autorelease];
	[gridSection setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, SPPostgresTriggersBarHeight, width, 300 - SPPostgresTriggersBarHeight)] autorelease];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	triggersView = [[SPTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[triggersView setUsesAlternatingRowBackgroundColors:YES];
	[triggersView setAllowsMultipleSelection:NO];
	[triggersView setAllowsColumnReordering:NO];
	[triggersView setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
	[triggersView setFocusRingType:NSFocusRingTypeNone];
	[triggersView setGridStyleMask:[[NSUserDefaults standardUserDefaults] boolForKey:SPDisplayTableViewVerticalGridlines] ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	[triggersView setRowHeight:MAX(17.0f, 2.0f + ceil([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : [self _tableFont]}].height))];
	[self _addColumn:@"name" title:NSLocalizedString(@"Name", @"Postgres triggers: name column") width:150 checkbox:NO];
	[self _addColumn:@"timing" title:NSLocalizedString(@"Timing", @"Postgres triggers: timing column") width:80 checkbox:NO];
	[self _addColumn:@"event" title:NSLocalizedString(@"Event", @"Postgres triggers: event column") width:180 checkbox:NO];
	[self _addColumn:@"level" title:NSLocalizedString(@"Level", @"Postgres triggers: level column") width:80 checkbox:NO];
	[self _addColumn:@"function" title:NSLocalizedString(@"Function", @"Postgres triggers: function column") width:150 checkbox:NO];
	[self _addColumn:@"enabled" title:NSLocalizedString(@"Enabled", @"Postgres triggers: enabled column") width:60 checkbox:YES];
	[triggersView setDataSource:self];
	[triggersView setDelegate:self];
	[scrollView setDocumentView:triggersView];
	[gridSection addSubview:scrollView];

	SPButtonBar *bar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresTriggersBarHeight)] autorelease];
	[bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	addButton = [self _newBarButtonWithImage:@"button_add" toolTip:NSLocalizedString(@"Add a new trigger", @"Postgres triggers: add tooltip") action:@selector(addTrigger:) x:-1];
	removeButton = [self _newBarButtonWithImage:@"button_remove" toolTip:NSLocalizedString(@"Delete the selected trigger", @"Postgres triggers: delete tooltip") action:@selector(removeTrigger:) x:30];
	refreshButton = [self _newBarButtonWithImage:@"button_refresh" toolTip:NSLocalizedString(@"Refresh the triggers", @"Postgres triggers: refresh tooltip") action:@selector(refresh:) x:61];
	noticeField = [[NSTextField labelWithString:@""] retain];
	[noticeField setFrame:NSMakeRect(100, 4, width - 108, 14)];
	[noticeField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[[noticeField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[noticeField setAutoresizingMask:NSViewWidthSizable];
	for (NSView *subview in @[addButton, removeButton, refreshButton, noticeField]) [bar addSubview:subview];
	[gridSection addSubview:bar];
	[split addSubview:gridSection];

	// The function source: read-only, monospaced (editing it is the Query view's job)
	NSScrollView *sourceScroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, 200)] autorelease];
	[sourceScroll setHasVerticalScroller:YES];
	[sourceScroll setHasHorizontalScroller:YES];
	[sourceScroll setAutohidesScrollers:YES];
	[sourceScroll setBorderType:NSNoBorder];
	[sourceScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	functionSourceView = [[NSTextView alloc] initWithFrame:[[sourceScroll contentView] bounds]];
	[functionSourceView setIdentifier:@"triggerFunctionSource"];
	[functionSourceView setEditable:NO];
	[functionSourceView setSelectable:YES];
	[functionSourceView setRichText:NO];
	[functionSourceView setFont:[NSFont monospacedSystemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightRegular]];
	[functionSourceView setTextContainerInset:NSMakeSize(4, 4)];
	[functionSourceView setAutoresizingMask:NSViewWidthSizable];
	[functionSourceView setHorizontallyResizable:YES];
	[[functionSourceView textContainer] setWidthTracksTextView:NO];
	[[functionSourceView textContainer] setContainerSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[functionSourceView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[sourceScroll setDocumentView:functionSourceView];
	[split addSubview:sourceScroll];

	[split adjustSubviews];
	[split setPosition:300 ofDividerAtIndex:0];
	[view addSubview:split];

	// As the tab's placeholder panes (identifier paneEmptyState)
	emptyStateField = [[NSTextField labelWithString:@""] retain];
	[emptyStateField setIdentifier:@"paneEmptyState"];
	[emptyStateField setTextColor:[NSColor secondaryLabelColor]];
	[emptyStateField setAlignment:NSTextAlignmentCenter];
	[emptyStateField setFrame:NSMakeRect(20, 240, 660, 20)];
	[emptyStateField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin];
	[emptyStateField setHidden:YES];
	[view addSubview:emptyStateField];
}

- (NSView *)view
{
	return view;
}

- (NSTableView *)triggersView
{
	return triggersView;
}

- (NSTextView *)functionSourceView
{
	return functionSourceView;
}

- (void)setEmptyStateText:(NSString *)text
{
	NSString *value = [text length] ? text : @"";
	if (emptyStateText != value) {
		[emptyStateText release];
		emptyStateText = [value copy];
	}
	[emptyStateField setStringValue:emptyStateText];
	[emptyStateField setHidden:![emptyStateText length]];
	[split setHidden:[emptyStateText length] > 0];
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

- (void)_presentError:(NSError *)error title:(NSString *)title
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:title];
	NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];
	[self _presentAlert:alert];
}

/// Asks alert's question (first button: delete); completion runs exactly once.
- (void)_confirm:(NSAlert *)alert completion:(void (^)(BOOL confirmed))completion
{
	// A heap copy that runs once, then balances its own Block_copy (see -[SPPostgresStructureController _confirm:…])
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

- (void)showTable:(NSString *)theTable inSchema:(NSString *)theSchema
{
	if (invalidated) return;

	[self setTable:theTable];
	[self setSchema:theSchema];
	[structure release];
	structure = nil;
	if ([theTable length] && [theSchema length]) {
		structure = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:theSchema table:theTable];
	}
	[triggersView deselectAll:nil];
	[self _load];
}

- (void)reload
{
	if (invalidated) return;
	[self _load];
}

- (IBAction)refresh:(id)sender
{
	[self reload];
}

/// Reads the triggers, keeping the selected one selected; on failure the grid empties and the error is shown.
- (void)_load
{
	NSArray *newTriggers = nil;
	NSError *error = nil;
	if (structure) newTriggers = [structure triggers:&error];
	loaded = (newTriggers != nil);

	NSInteger selectedRow = [triggersView selectedRow];
	NSString *selectedName = (selectedRow >= 0 && selectedRow < (NSInteger)[triggers count]) ? [[[[triggers objectAtIndex:(NSUInteger)selectedRow] name] retain] autorelease] : nil;

	[triggers release];
	triggers = [(newTriggers ?: @[]) copy];

	NSString *notice = @"";
	if (structure && !loaded) {
		NSString *detail = [[[[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"] firstObject];
		notice = [NSString stringWithFormat:NSLocalizedString(@"Could not load the triggers: %@", @"Postgres triggers: load failed notice"), [detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];
	}
	else if (structure) {
		notice = [NSString stringWithFormat:NSLocalizedString(@"Triggers for table: %@", @"Postgres triggers: subtitle showing table name"), table];
	}
	[self setNoticeText:notice];
	[noticeField setStringValue:notice];

	[triggersView reloadData];
	NSUInteger row = selectedName ? [[triggers valueForKey:@"name"] indexOfObject:selectedName] : NSNotFound;
	if (row != NSNotFound) [triggersView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	else [triggersView deselectAll:nil];
	[self _showSelectedSource];
	[self _updateButtons];

	if (structure && !loaded) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the triggers of “%@”", @"Postgres triggers: load failed"), table]];
	}
}

- (void)_showSelectedSource
{
	NSInteger row = [triggersView selectedRow];
	NSString *source = (row >= 0 && row < (NSInteger)[triggers count]) ? [[triggers objectAtIndex:(NSUInteger)row] functionDefinition] : nil;
	[functionSourceView setString:source ?: @""];
}

- (void)_updateButtons
{
	BOOL canChange = !invalidated && structure && loaded;
	[addButton setEnabled:canChange];
	[removeButton setEnabled:canChange && [triggersView selectedRow] >= 0];
	[refreshButton setEnabled:!invalidated && structure != nil];
}

#pragma mark - Changes

- (IBAction)addTrigger:(id)sender
{
	if (invalidated || !structure || !loaded) return;

	NSError *error = nil;
	NSArray *functions = [structure triggerFunctions:&error];
	NSArray *columns = functions ? [[structure columns:&error] valueForKey:@"name"] : nil;
	if (!columns) {
		[self _presentError:error title:NSLocalizedString(@"Could not add the trigger", @"Postgres triggers: add failed")];
		return;
	}

	SPPostgresTableStructure *target = [structure retain];
	[self retain];

	// A heap block, so a presenter may keep it until the answer comes; runs once
	__block BOOL done = NO;
	void (^finish)(SPPostgresTriggerDefinition *) = [[^(SPPostgresTriggerDefinition *definition) {
		if (done) return;
		done = YES;
		if (!invalidated) {
			[activeSheet autorelease];
			activeSheet = nil;
		}
		if (definition && !invalidated && target == structure) {
			NSError *addError = nil;
			if ([structure addTriggerNamed:[definition name] timing:[definition timing] events:[definition events] updateColumns:[definition updateColumns]
									 level:[definition level] function:[definition function] condition:[definition condition] error:&addError]) {
				[self _load];
				NSUInteger row = [[triggers valueForKey:@"name"] indexOfObject:[definition name]];
				if (row != NSNotFound) [triggersView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
			}
			else {
				[self _presentError:addError title:NSLocalizedString(@"Could not add the trigger", @"Postgres triggers: add failed")];
				[self _load];
			}
		}
		[target release];
		[self release];
	} copy] autorelease];

	if (triggerSheetPresenter) {
		triggerSheetPresenter(columns, functions, finish);
		return;
	}
	NSWindow *window = [view window];
	if (!window || [window attachedSheet]) {
		finish(nil);
		return;
	}
	[SPPostgresTriggerSheet beginWithColumns:columns functions:functions window:window completion:finish];
	if (!done) {
		[activeSheet release];
		activeSheet = [[window attachedSheet] retain];
	}
}

- (IBAction)removeTrigger:(id)sender
{
	if (invalidated || !structure || !loaded) return;
	NSInteger row = [triggersView selectedRow];
	if (row < 0 || row >= (NSInteger)[triggers count]) return;

	NSString *name = [[[triggers objectAtIndex:(NSUInteger)row] name] copy];
	SPPostgresTableStructure *target = [structure retain];

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
	[[[alert buttons] objectAtIndex:1] setKeyEquivalent:@"\033"];
	[alert setAlertStyle:NSAlertStyleCritical];
	NSString *kind = NSLocalizedString(@"trigger", @"Postgres triggers: trigger (delete confirmation)");
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Delete %@ \"%@\"?", @"Postgres structure: delete confirmation (kind, name)"), kind, name]];
	[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the %@ \"%@\"? This action cannot be undone.", @"Postgres structure: delete confirmation detail (kind, name)"), kind, name]];

	[self retain];
	[self _confirm:alert completion:^(BOOL confirmed) {
		if (confirmed && !invalidated && target == structure) {
			NSError *error = nil;
			if ([structure dropTriggerNamed:name error:&error]) {
				[triggersView deselectAll:nil];
				[self _load];
			}
			else {
				[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not delete the trigger “%@”", @"Postgres triggers: drop failed"), name]];
				[self _load];
			}
		}
		[name release];
		[target release];
		[self release];
	}];
}

/// The Enabled checkbox: ENABLE / DISABLE TRIGGER at once. On failure the alert, and the grid shows the server's state.
- (void)_setTriggerAtRow:(NSInteger)row enabled:(BOOL)enabled
{
	SPPostgresTrigger *trigger = [[[triggers objectAtIndex:(NSUInteger)row] retain] autorelease];
	if ([trigger enabled] == enabled) return;

	NSError *error = nil;
	if (![structure setTrigger:[trigger name] enabled:enabled error:&error]) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change the trigger “%@”", @"Postgres triggers: enable/disable failed"), [trigger name]]];
	}
	[self _load];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)grid
{
	return (NSInteger)[triggers count];
}

- (id)tableView:(NSTableView *)grid objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[triggers count]) return nil;
	SPPostgresTrigger *trigger = [triggers objectAtIndex:(NSUInteger)row];
	NSString *identifier = [tableColumn identifier];
	if ([identifier isEqualToString:@"name"]) return [trigger name];
	if ([identifier isEqualToString:@"timing"]) return [trigger timing];
	if ([identifier isEqualToString:@"event"]) return [trigger events];
	if ([identifier isEqualToString:@"level"]) return [trigger level];
	if ([identifier isEqualToString:@"function"]) return [NSString stringWithFormat:@"%@.%@", [trigger functionSchema] ?: @"", [trigger functionName] ?: @""];
	if ([identifier isEqualToString:@"enabled"]) return @([trigger enabled]);
	return nil;
}

- (void)tableView:(NSTableView *)grid setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (invalidated || !structure || !loaded || row < 0 || row >= (NSInteger)[triggers count]) return;
	if (![[tableColumn identifier] isEqualToString:@"enabled"]) return;
	[self _setTriggerAtRow:row enabled:[object boolValue]];
}

- (BOOL)tableView:(NSTableView *)grid shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return !invalidated && structure && loaded && row >= 0 && row < (NSInteger)[triggers count] && [[tableColumn identifier] isEqualToString:@"enabled"];
}

/// The checkbox follows the same rule as text cells.
- (BOOL)tableView:(NSTableView *)grid shouldTrackCell:(NSCell *)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (![cell isKindOfClass:[NSButtonCell class]]) return YES;
	return [self tableView:grid shouldEditTableColumn:tableColumn row:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _showSelectedSource];
	[self _updateButtons];
}

@end
