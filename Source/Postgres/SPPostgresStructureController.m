#import "SPPostgresStructureController.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresTableData.h"
#import "SPPostgresConstraintSheet.h"
#import "SPPostgresErrors.h"
#import "SPPostgresPaneLoader.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPConstants.h"

// MySQL's Structure tab (DBView.xib): 23 pt button bars, 32 x 25 textured buttons
static const CGFloat SPPostgresStructureBarHeight = 23;
static const CGFloat SPPostgresStructureButtonWidth = 32;

static NSString * const SPPostgresStructureName = @"name";
static NSString * const SPPostgresStructureType = @"type";
static NSString * const SPPostgresStructureNullable = @"nullable";
static NSString * const SPPostgresStructureDefault = @"default";
static NSString * const SPPostgresStructureAuto = @"auto";
static NSString * const SPPostgresStructureComment = @"comment";

@interface SPPostgresStructureController ()

@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *table;
@property (readwrite, copy) NSString *noticeText;

@end

@implementation SPPostgresStructureController
{
	PGPostgresConnection *connection;
	SPPostgresTableStructure *structure;
	NSArray *columns;       // SPPostgresStructureColumn
	NSArray *indexes;       // SPPostgresIndex
	NSArray *constraints;   // SPPostgresConstraint
	BOOL loaded;            // the current relation's structure was read
	BOOL editable;

	SPPostgresPaneLoader *loader; // the runner, the load generation, staleness, and refusing changes while busy

	/// The + column not saved yet: the last row of the columns grid
	SPPostgresColumnDefinition *draft;
	/// Saving the draft (its reload changes the selection)
	BOOL savingDraft;

	NSView *view;
	SPTableView *columnsView;
	SPTableView *indexesView;
	SPTableView *constraintsView;
	NSPopUpButtonCell *autoPopupCell;

	NSButton *addColumnButton;
	NSButton *removeColumnButton;
	NSButton *refreshButton;
	NSButton *addIndexButton;
	NSButton *removeIndexButton;
	NSButton *addConstraintButton;
	NSButton *removeConstraintButton;
	NSTextField *noticeField;

	/// A sheet this controller put on the window (USING, add index or constraint), ended by -invalidate
	NSWindow *activeSheet;
	/// The default USING sheet's field, and its completion until it is answered
	NSTextField *usingField;
	void (^usingCompletion)(NSString *);

	BOOL invalidated;
}

@synthesize schema;
@synthesize table;
@synthesize noticeText;
@synthesize editable;
@synthesize alertPresenter;
@synthesize confirmationPresenter;
@synthesize usingPresenter;
@synthesize constraintSheetPresenter;
@synthesize structureDidChange;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		loader = [[SPPostgresPaneLoader alloc] initWithConnection:theConnection];
		columns = [@[] retain];
		indexes = [@[] retain];
		constraints = [@[] retain];
		noticeText = [@"" copy];
		[self _buildView];
		[self _updateButtons];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[loader release];
	[structure release];
	[columns release];
	[indexes release];
	[constraints release];
	[draft release];
	[schema release];
	[table release];
	[noticeText release];

	[view release];
	[columnsView release];
	[indexesView release];
	[constraintsView release];
	[autoPopupCell release];
	[addColumnButton release];
	[removeColumnButton release];
	[refreshButton release];
	[addIndexButton release];
	[removeIndexButton release];
	[addConstraintButton release];
	[removeConstraintButton release];
	[noticeField release];
	[activeSheet release];
	[usingField release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;
	[loader invalidate];

	// An edit in progress must not call back into a controller that is going away
	for (NSTableView *grid in @[columnsView, indexesView, constraintsView]) {
		if ([grid currentEditor]) [grid abortEditing];
		[grid setDataSource:nil];
		[grid setDelegate:nil];
	}

	for (NSControl *control in @[addColumnButton, removeColumnButton, refreshButton, addIndexButton, removeIndexButton,
								 addConstraintButton, removeConstraintButton]) {
		[control setTarget:nil];
	}

	// A sheet still up ends (cancelled); its completion sees `invalidated`
	if ([activeSheet sheetParent]) [[activeSheet sheetParent] endSheet:activeSheet returnCode:NSModalResponseCancel];
	[activeSheet release];
	activeSheet = nil;

	// The presenters may capture the tab
	[alertPresenter release], alertPresenter = nil;
	[confirmationPresenter release], confirmationPresenter = nil;
	[usingPresenter release], usingPresenter = nil;
	[constraintSheetPresenter release], constraintSheetPresenter = nil;
	[structureDidChange release], structureDidChange = nil;
}

#pragma mark - View

- (NSButton *)_newBarButtonWithImage:(NSString *)imageName toolTip:(NSString *)toolTip action:(SEL)action x:(CGFloat)x
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, -1, SPPostgresStructureButtonWidth, 25)];
	[button setBezelStyle:NSBezelStyleTexturedRounded];
	[button setImage:[NSImage imageNamed:imageName]];
	[button setImagePosition:NSImageOnly];
	[button setToolTip:toolTip];
	[button setTarget:self];
	[button setAction:action];
	return button;
}

- (NSTextField *)_labelWithFrame:(NSRect)frame
{
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setDrawsBackground:NO];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	return label;
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

- (SPTableView *)_newGridInView:(NSView *)container frame:(NSRect)frame
{
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	SPTableView *grid = [[SPTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[grid setUsesAlternatingRowBackgroundColors:YES];
	[grid setAllowsMultipleSelection:NO];
	[grid setAllowsColumnReordering:NO];
	[grid setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
	[grid setFocusRingType:NSFocusRingTypeNone];
	[grid setGridStyleMask:[[NSUserDefaults standardUserDefaults] boolForKey:SPDisplayTableViewVerticalGridlines] ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	NSFont *font = [self _tableFont];
	[grid setRowHeight:MAX(17.0f, 2.0f + ceil([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : font}].height))];
	[grid setDataSource:self];
	[grid setDelegate:self];
	[scrollView setDocumentView:grid];
	[container addSubview:scrollView];
	return grid;
}

- (NSTableColumn *)_addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width cell:(NSCell *)cell to:(NSTableView *)grid
{
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:identifier] autorelease];
	[[column headerCell] setStringValue:title];
	[column setWidth:width];
	[column setMinWidth:30];
	[column setResizingMask:NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask];

	if (!cell) {
		NSTextFieldCell *textCell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[textCell setEditable:YES];
		[textCell setScrollable:YES];
		[textCell setLineBreakMode:NSLineBreakByTruncatingTail];
		cell = textCell;
	}
	[cell setFont:[self _tableFont]];
	[column setDataCell:cell];
	[column setEditable:YES];
	[grid addTableColumn:column];
	return column;
}

- (NSButtonCell *)_checkboxCell
{
	NSButtonCell *cell = [[[NSButtonCell alloc] initTextCell:@""] autorelease];
	[cell setButtonType:NSButtonTypeSwitch];
	[cell setControlSize:NSControlSizeSmall];
	[cell setImagePosition:NSImageOnly];
	[cell setAlignment:NSTextAlignmentCenter];
	return cell;
}

/// A grid with a bar below it (+, −, and more), as one part of the split view.
- (NSView *)_sectionWithFrame:(NSRect)frame grid:(SPTableView **)grid bar:(SPButtonBar **)bar
{
	NSView *section = [[[NSView alloc] initWithFrame:frame] autorelease];
	[section setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	*grid = [self _newGridInView:section frame:NSMakeRect(0, SPPostgresStructureBarHeight, NSWidth(frame), NSHeight(frame) - SPPostgresStructureBarHeight)];
	*bar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), SPPostgresStructureBarHeight)] autorelease];
	[*bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[section addSubview:*bar];
	return section;
}

/// The columns grid and its bar on top; Indexes and Constraints below, as MySQL's Structure tab.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	CGFloat width = NSWidth(frame);

	NSSplitView *split = [[[NSSplitView alloc] initWithFrame:frame] autorelease];
	[split setVertical:NO];
	[split setDividerStyle:NSSplitViewDividerStyleThin];
	[split setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// Columns
	SPButtonBar *bar = nil;
	NSView *columnsSection = [self _sectionWithFrame:NSMakeRect(0, 0, width, 280) grid:&columnsView bar:&bar];
	[self _addColumn:SPPostgresStructureName title:NSLocalizedString(@"Name", @"Postgres structure: name column") width:150 cell:nil to:columnsView];

	NSComboBoxCell *typeCell = [[[NSComboBoxCell alloc] initTextCell:@""] autorelease];
	[typeCell setEditable:YES];
	[typeCell setCompletes:YES];
	[typeCell setBordered:NO];
	[typeCell setButtonBordered:NO];
	[typeCell setControlSize:NSControlSizeSmall];
	[typeCell setNumberOfVisibleItems:12];
	[typeCell addItemsWithObjectValues:@[@"integer", @"bigint", @"smallint", @"numeric(10,2)", @"real", @"double precision", @"text",
										  @"varchar(255)", @"char(1)", @"boolean", @"date", @"time", @"timestamp", @"timestamptz",
										  @"interval", @"uuid", @"json", @"jsonb", @"bytea", @"inet"]];
	[self _addColumn:SPPostgresStructureType title:NSLocalizedString(@"Type", @"Postgres structure: type column") width:140 cell:typeCell to:columnsView];
	[self _addColumn:SPPostgresStructureNullable title:NSLocalizedString(@"Nullable", @"Postgres structure: nullable column") width:60 cell:[self _checkboxCell] to:columnsView];
	[self _addColumn:SPPostgresStructureDefault title:NSLocalizedString(@"Default", @"Postgres structure: default column") width:140 cell:nil to:columnsView];
	[self _addColumn:SPPostgresStructureAuto title:NSLocalizedString(@"Auto", @"Postgres structure: auto column") width:100 cell:nil to:columnsView];
	[self _addColumn:SPPostgresStructureComment title:NSLocalizedString(@"Comment", @"Postgres structure: comment column") width:150 cell:nil to:columnsView];

	// Auto is chosen on a new column only, from a pop-up
	autoPopupCell = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:NO];
	[autoPopupCell setBordered:NO];
	[autoPopupCell setControlSize:NSControlSizeSmall];
	[autoPopupCell setFont:[self _tableFont]];
	[autoPopupCell addItemsWithTitles:[self _autoKinds]];

	addColumnButton = [self _newBarButtonWithImage:@"button_add" toolTip:NSLocalizedString(@"Add a new column", @"Postgres structure: add column tooltip") action:@selector(addColumn:) x:-1];
	removeColumnButton = [self _newBarButtonWithImage:@"button_remove" toolTip:NSLocalizedString(@"Delete the selected column", @"Postgres structure: delete column tooltip") action:@selector(removeColumn:) x:30];
	refreshButton = [self _newBarButtonWithImage:@"button_refresh" toolTip:NSLocalizedString(@"Refresh the structure", @"Postgres structure: refresh tooltip") action:@selector(refresh:) x:61];
	noticeField = [[self _labelWithFrame:NSMakeRect(100, 4, width - 108, 14)] retain];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[noticeField setAutoresizingMask:NSViewWidthSizable];
	for (NSView *subview in @[addColumnButton, removeColumnButton, refreshButton, noticeField]) [bar addSubview:subview];
	[split addSubview:columnsSection];

	// Indexes
	NSView *indexesSection = [self _sectionWithFrame:NSMakeRect(0, 0, width, 110) grid:&indexesView bar:&bar];
	[self _addColumn:@"name" title:NSLocalizedString(@"Name", @"Postgres structure: index name column") width:180 cell:nil to:indexesView];
	[self _addColumn:@"columns" title:NSLocalizedString(@"Columns", @"Postgres structure: index columns column") width:220 cell:nil to:indexesView];
	[self _addColumn:@"unique" title:NSLocalizedString(@"Unique", @"Postgres structure: index unique column") width:60 cell:[self _checkboxCell] to:indexesView];
	[self _addColumn:@"method" title:NSLocalizedString(@"Method", @"Postgres structure: index method column") width:80 cell:nil to:indexesView];
	addIndexButton = [self _newBarButtonWithImage:@"button_add" toolTip:NSLocalizedString(@"Add a new index", @"Postgres structure: add index tooltip") action:@selector(addIndex:) x:-1];
	removeIndexButton = [self _newBarButtonWithImage:@"button_remove" toolTip:NSLocalizedString(@"Delete the selected index", @"Postgres structure: delete index tooltip") action:@selector(removeIndex:) x:30];
	NSTextField *indexesLabel = [self _labelWithFrame:NSMakeRect(70, 4, 200, 14)];
	[indexesLabel setStringValue:NSLocalizedString(@"Indexes", @"Postgres structure: indexes section")];
	for (NSView *subview in @[addIndexButton, removeIndexButton, indexesLabel]) [bar addSubview:subview];
	[split addSubview:indexesSection];

	// Constraints
	NSView *constraintsSection = [self _sectionWithFrame:NSMakeRect(0, 0, width, 110) grid:&constraintsView bar:&bar];
	[self _addColumn:@"name" title:NSLocalizedString(@"Name", @"Postgres structure: constraint name column") width:180 cell:nil to:constraintsView];
	[self _addColumn:@"type" title:NSLocalizedString(@"Type", @"Postgres structure: constraint type column") width:100 cell:nil to:constraintsView];
	[self _addColumn:@"definition" title:NSLocalizedString(@"Definition", @"Postgres structure: constraint definition column") width:400 cell:nil to:constraintsView];
	addConstraintButton = [self _newBarButtonWithImage:@"button_add" toolTip:NSLocalizedString(@"Add a new constraint", @"Postgres structure: add constraint tooltip") action:@selector(addConstraint:) x:-1];
	removeConstraintButton = [self _newBarButtonWithImage:@"button_remove" toolTip:NSLocalizedString(@"Delete the selected constraint", @"Postgres structure: delete constraint tooltip") action:@selector(removeConstraint:) x:30];
	NSTextField *constraintsLabel = [self _labelWithFrame:NSMakeRect(70, 4, 200, 14)];
	[constraintsLabel setStringValue:NSLocalizedString(@"Constraints", @"Postgres structure: constraints section")];
	for (NSView *subview in @[addConstraintButton, removeConstraintButton, constraintsLabel]) [bar addSubview:subview];
	[split addSubview:constraintsSection];

	[split adjustSubviews];
	[split setPosition:280 ofDividerAtIndex:0];
	[split setPosition:390 ofDividerAtIndex:1];
	[view addSubview:split];
}

- (NSView *)view
{
	return view;
}

- (NSTableView *)columnsView
{
	return columnsView;
}

- (NSTableView *)indexesView
{
	return indexesView;
}

- (NSTableView *)constraintsView
{
	return constraintsView;
}

- (BOOL)hasDraftColumn
{
	return draft != nil;
}

/// The Auto choices of a new column, in pop-up order.
- (NSArray *)_autoKinds
{
	return @[@"", @"serial", @"identity", @"identity always"];
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

- (void)_confirm:(NSAlert *)alert completion:(void (^)(BOOL confirmed))completion
{
	// A heap copy that runs once, then balances its own Block_copy (see -[SPPostgresContentController _confirm:…])
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

/// "Delete <what> "<name>"?" with Delete / Cancel, as MySQL's.
- (NSAlert *)_deleteAlertForKind:(NSString *)kind name:(NSString *)name
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
	[[[alert buttons] objectAtIndex:1] setKeyEquivalent:@"\033"];
	[alert setAlertStyle:NSAlertStyleCritical];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Delete %@ \"%@\"?", @"Postgres structure: delete confirmation (kind, name)"), kind, name]];
	[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the %@ \"%@\"? This action cannot be undone.", @"Postgres structure: delete confirmation detail (kind, name)"), kind, name]];
	return alert;
}

#pragma mark - Loading

/// The runner's thread: the relation's kind, columns, indexes and constraints, read through structure alone (nil,
/// with *error, if any of them can't be read).
static NSDictionary *SPPostgresStructureRead(SPPostgresTableStructure *structure, NSError **error)
{
	NSString *kind = [structure relationKind:error];
	if (!kind) return nil;
	NSArray *theColumns = [structure columns:error];
	if (!theColumns) return nil;
	NSArray *theIndexes = [structure indexes:error];
	if (!theIndexes) return nil;
	NSArray *theConstraints = [structure constraints:error];
	if (!theConstraints) return nil;
	return @{@"kind" : kind, @"columns" : theColumns, @"indexes" : theIndexes, @"constraints" : theConstraints};
}

// A load (a switch, -reload, Refresh) ends the cell edit first (so a change it commits is sent while the runner is
// idle) and goes through the pane loader (SPPostgresPaneLoader). On the runner's thread the work uses only the
// structure object (made on the main thread, where nothing uses it while the runner is busy: the changes are refused
// then). A change reads the structure again at once, on the main thread, as part of the change (-_load).

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

- (void)showTable:(NSString *)theTable inSchema:(NSString *)theSchema
{
	if (invalidated) return;

	// The tab saves a cell edit and a draft column before it changes the selection (and refuses to change it
	// if they can't be saved: see -commitPendingEdits). Anything still pending here can't follow to another
	// table: a draft is saved if it can be, and is otherwise dropped after the alert says it wasn't added.
	if (![self _endEditing]) [columnsView abortEditing];
	if (draft && ![self _saveDraftSelectingRow:-1]) [self _discardDraft];

	[self setTable:theTable];
	[self setSchema:theSchema];

	[structure release];
	structure = nil;
	if ([theTable length] && [theSchema length]) {
		structure = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:theSchema table:theTable];
	}

	[columnsView deselectAll:nil];
	[indexesView deselectAll:nil];
	[constraintsView deselectAll:nil];

	// The previous table's structure goes at once
	[self _clearStructure];
	[self _loadSwitching:YES];
}

/// As Refresh: not while a cell edit can't end (its text stays).
- (void)reload
{
	if (invalidated || ![self _endEditing]) return;
	[self _loadSwitching:NO];
}

/// Reads the structure through the runner and shows it (see -_showStructure:error:).
- (void)_loadSwitching:(BOOL)switching
{
	if (!structure) {
		[loader loadNothing];
		[self _clearStructure];
		return;
	}
	SPPostgresTableStructure *target = structure;
	[loader loadSwitching:switching work:^id(PGPostgresConnection *theConnection, NSError **error) {
		return SPPostgresStructureRead(target, error);
	} apply:^(id result, NSError *error) {
		[self _showStructure:result error:error];
	}];
}

/// Reads the structure on the main thread and shows it: part of a change, which runs only while the runner is idle.
- (void)_load
{
	if (!structure) {
		[self _clearStructure];
		return;
	}
	NSError *error = nil;
	NSDictionary *result = SPPostgresStructureRead(structure, &error);
	[self _showStructure:result error:error];
}

/// Empty grids, no notice (no table, or before a switch's table has loaded).
- (void)_clearStructure
{
	[self _showStructure:@{} error:nil];
}

/**
 * Shows what was read (SPPostgresStructureRead; an empty dictionary: nothing). nil means it couldn't be read (the
 * relation is gone, the connection lost, the transaction aborted): the grids are emptied, and the error shown as an
 * alert and in the bottom bar.
 */
- (void)_showStructure:(NSDictionary *)result error:(NSError *)error
{
	NSString *kind = [result objectForKey:@"kind"];
	NSArray *newColumns = [result objectForKey:@"columns"];
	NSArray *newIndexes = [result objectForKey:@"indexes"];
	NSArray *newConstraints = [result objectForKey:@"constraints"];
	BOOL failed = (result == nil);

	loaded = (kind != nil);
	editable = loaded && ([kind isEqualToString:@"table"] || [kind isEqualToString:@"partitioned table"]);

	[columns release];
	columns = [(newColumns ?: @[]) copy];
	[indexes release];
	indexes = [(newIndexes ?: @[]) copy];
	[constraints release];
	constraints = [(newConstraints ?: @[]) copy];

	if (!editable && draft) {
		[draft release];
		draft = nil;
	}

	NSString *notice = @"";
	if (failed) {
		NSString *detail = [[[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"].firstObject;
		notice = [NSString stringWithFormat:NSLocalizedString(@"Could not load the structure: %@", @"Postgres structure: load failed notice"), [detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];
	}
	else if (loaded && !editable) {
		notice = NSLocalizedString(@"Views can't be edited here.", @"Postgres structure: read-only notice");
	}
	[self setNoticeText:notice];
	[noticeField setStringValue:notice];

	for (NSTableView *grid in @[columnsView, indexesView, constraintsView]) [self _reloadGridKeepingSelection:grid];
	[self _updateButtons];

	if (failed) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the structure of “%@”", @"Postgres structure: load failed"), table]];
	}
}

- (void)_reloadGridKeepingSelection:(NSTableView *)grid
{
	NSInteger selected = [grid selectedRow];
	BOOL wasSaving = savingDraft;
	savingDraft = YES; // no draft save from the selection changes of a reload
	[grid reloadData];
	if (selected >= 0 && selected < [grid numberOfRows]) [grid selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selected] byExtendingSelection:NO];
	else [grid deselectAll:nil];
	savingDraft = wasSaving;
}

- (void)_updateButtons
{
	BOOL canChange = !invalidated && structure && loaded && editable;
	NSInteger column = [columnsView selectedRow];
	[addColumnButton setEnabled:canChange];
	[removeColumnButton setEnabled:canChange && column >= 0 && column < [self numberOfRowsInTableView:columnsView]];
	[refreshButton setEnabled:!invalidated && structure != nil];
	[addIndexButton setEnabled:canChange];
	[removeIndexButton setEnabled:canChange && [indexesView selectedRow] >= 0];
	[addConstraintButton setEnabled:canChange];
	[removeConstraintButton setEnabled:canChange && [constraintsView selectedRow] >= 0];
}

/// A change succeeded: the grids show the server's structure, and the tab hears of it.
- (void)_didChange:(BOOL)columnsChanged
{
	[self _load];
	if (structureDidChange && !invalidated) structureDidChange(columnsChanged);
}

/// The changes run on the main thread, so never while a load is using the connection (see SPPostgresPaneLoader).
- (BOOL)_refuseChangeWhileBusy
{
	return [loader refuseChangeWhileBusy];
}

/// Commits a cell edit in progress (before an action that reloads the grids). NO if the editor can't end: the
/// edit stays, and the action shouldn't go ahead. While the runner is busy it doesn't end (NSBeep): its change would
/// be refused, so the text stays, as Table Info's comment does.
- (BOOL)_endEditing
{
	if (![columnsView currentEditor]) return YES;
	if ([self _refuseChangeWhileBusy]) return NO;
	return [[columnsView window] makeFirstResponder:columnsView];
}

- (BOOL)commitPendingEdits
{
	if (invalidated) return YES;
	if (![self _endEditing]) return NO;
	if (draft) return [self _saveDraftSelectingRow:-1];
	return YES;
}

- (IBAction)refresh:(id)sender
{
	if (invalidated || ![self _endEditing]) return;
	[self _loadSwitching:NO];
}

#pragma mark - Columns

- (NSString *)_nextFreeColumnName
{
	NSSet *names = [NSSet setWithArray:[columns valueForKey:@"name"]];
	for (NSUInteger n = 1; ; n++) {
		NSString *name = [NSString stringWithFormat:@"column_%lu", (unsigned long)n];
		if (![names containsObject:name]) return name;
	}
}

- (IBAction)addColumn:(id)sender
{
	if (invalidated || !structure || !loaded || !editable || [self _refuseChangeWhileBusy] || ![self _endEditing]) return;

	// One draft at a time: the one there is saved first (if it can't be, it stays for correction)
	if (draft && ![self _saveDraftSelectingRow:-1]) return;

	draft = [[SPPostgresColumnDefinition alloc] init];
	[draft setName:[self _nextFreeColumnName]];
	[draft setTypeName:@"text"];
	[draft setNotNull:NO];
	[draft setAutoKind:@""];

	NSInteger row = (NSInteger)[columns count];
	savingDraft = YES;
	[columnsView reloadData];
	[columnsView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	savingDraft = NO;
	[columnsView scrollRowToVisible:row];
	[self _updateButtons];

	if ([columnsView window]) {
		[[columnsView window] makeFirstResponder:columnsView];
		[columnsView editColumn:[columnsView columnWithIdentifier:SPPostgresStructureName] row:row withEvent:nil select:YES];
	}
}

/**
 * ADD COLUMN for the draft. On failure the draft stays (selected, for correction) and the error is shown. On
 * success row is selected (the row the user clicked, which saved it), or the new column when row is -1.
 */
- (BOOL)_saveDraftSelectingRow:(NSInteger)selectRow
{
	if (!draft) return YES;
	if (invalidated || !structure) return NO;
	if ([self _refuseChangeWhileBusy]) {
		// As a failed save, without the alert: the draft stays selected
		savingDraft = YES;
		[columnsView selectRowIndexes:[NSIndexSet indexSetWithIndex:[columns count]] byExtendingSelection:NO];
		savingDraft = NO;
		return NO;
	}

	SPPostgresColumnDefinition *definition = [[draft retain] autorelease];
	NSError *error = nil;
	savingDraft = YES;
	BOOL saved = [structure addColumn:definition error:&error];
	if (saved) {
		[draft release];
		draft = nil;
		[self _didChange:YES];
		// The row the user clicked (the new column is added after the others, so its index holds), else the new column
		NSInteger row = (selectRow >= 0) ? selectRow : (NSInteger)[[columns valueForKey:@"name"] indexOfObject:[definition name]];
		if (row >= 0 && row < [columnsView numberOfRows]) [columnsView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	}
	else {
		NSInteger row = (NSInteger)[columns count];
		[columnsView reloadData];
		[columnsView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not add the column “%@”", @"Postgres structure: add column failed"), [definition name]]];
	}
	savingDraft = NO;
	[self _updateButtons];
	return saved;
}

- (void)_discardDraft
{
	if (!draft) return;
	BOOL wasEditing = ([columnsView currentEditor] != nil);
	if (wasEditing) [columnsView abortEditing];
	[draft release];
	draft = nil;
	savingDraft = YES;
	[columnsView reloadData];
	[columnsView deselectAll:nil];
	savingDraft = NO;
	// Esc in the cell: the grid keeps the keyboard focus
	if (wasEditing && [columnsView window]) [[columnsView window] makeFirstResponder:columnsView];
	[self _updateButtons];
}

- (IBAction)removeColumn:(id)sender
{
	if (invalidated || !structure || !loaded || !editable || [self _refuseChangeWhileBusy] || ![self _endEditing]) return;

	NSInteger row = [columnsView selectedRow];
	if (draft && row == (NSInteger)[columns count]) {
		[self _discardDraft];
		return;
	}
	if (row < 0 || row >= (NSInteger)[columns count]) return;

	NSString *name = [[[columns objectAtIndex:(NSUInteger)row] name] copy];
	SPPostgresTableStructure *target = [structure retain];
	[self retain];
	[self _confirm:[self _deleteAlertForKind:NSLocalizedString(@"column", @"Postgres structure: column (delete confirmation)") name:name] completion:^(BOOL confirmed) {
		if (confirmed && !invalidated && target == structure) [self _dropColumn:name];
		[name release];
		[target release];
		[self release];
	}];
}

/// Drops the column; when something depends on it, nothing is dropped and the dependents are listed.
- (void)_dropColumn:(NSString *)name
{
	if ([self _refuseChangeWhileBusy]) return;
	NSError *error = nil;
	if ([structure dropColumn:name error:&error]) {
		[columnsView deselectAll:nil];
		[self _didChange:YES];
		return;
	}

	if ([[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorHasDependents) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:[error localizedDescription]];
		[alert setInformativeText:[[[error userInfo] objectForKey:SPPostgresDependentsErrorKey] componentsJoinedByString:@"\n"] ?: @""];
		[self _presentAlert:alert];
	}
	else {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not delete the column “%@”", @"Postgres structure: drop column failed"), name]];
	}
	[self _load];
}

/// One change to an existing column, from an edited cell.
- (void)_changeColumn:(SPPostgresStructureColumn *)column identifier:(NSString *)identifier value:(id)object
{
	NSString *name = [column name];
	NSString *text = [object isKindOfClass:[NSString class]] ? object : ([object respondsToSelector:@selector(stringValue)] ? [object stringValue] : @"");
	NSError *error = nil;
	BOOL changed = NO;

	if ([identifier isEqualToString:SPPostgresStructureName]) {
		NSString *newName = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (![newName length] || [newName isEqualToString:name]) return;
		changed = [structure renameColumn:name to:newName error:&error];
	}
	else if ([identifier isEqualToString:SPPostgresStructureType]) {
		NSString *type = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (![type length] || [type isEqualToString:[column typeName]]) return;
		[self _changeColumn:name toType:type using:nil structure:structure];
		return;
	}
	else if ([identifier isEqualToString:SPPostgresStructureNullable]) {
		BOOL nullable = [object boolValue];
		if (nullable == [column nullable]) return;
		changed = [structure setNullable:nullable forColumn:name error:&error];
	}
	else if ([identifier isEqualToString:SPPostgresStructureDefault]) {
		if ([text isEqualToString:[column defaultExpression] ?: @""]) return;
		changed = [structure setDefault:text forColumn:name error:&error];
	}
	else if ([identifier isEqualToString:SPPostgresStructureComment]) {
		if ([text isEqualToString:[column comment] ?: @""]) return;
		changed = [structure setComment:text forColumn:name error:&error];
	}
	else {
		return;
	}

	if (changed) {
		[self _didChange:![identifier isEqualToString:SPPostgresStructureComment]];
		return;
	}
	[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change the column “%@”", @"Postgres structure: change column failed"), name]];
	[self _load];
}

/**
 * ALTER COLUMN … TYPE. When the server refuses, usingPresenter is offered its message and a USING expression
 * (@"\"col\"::type", or the one just tried); the change is retried with what it answers until it succeeds or the
 * answer is nil. Meanwhile the grid shows the column as the server has it.
 */
- (void)_changeColumn:(NSString *)name toType:(NSString *)type using:(NSString *)usingExpression structure:(SPPostgresTableStructure *)target
{
	if (invalidated || target != structure || [self _refuseChangeWhileBusy]) return;

	NSError *error = nil;
	if ([target changeColumn:name toType:type using:usingExpression error:&error]) {
		[self _didChange:YES];
		return;
	}

	[self _load];

	// USING only helps when the data can't take the type: datatype_mismatch (42804) or a data exception (class 22,
	// e.g. a value the expression can't convert). A retry also asks again after an error in the expression itself
	// (class 42: a typo, an unknown function). Anything else (an unknown type, a lock timeout, an aborted
	// transaction, a lost connection) is a plain alert.
	NSString *state = [[error userInfo] objectForKey:SPPostgresSQLStateErrorKey];
	BOOL offerUsing = [state isEqualToString:@"42804"] || [state hasPrefix:@"22"] || (usingExpression && [state hasPrefix:@"42"]);
	if (!offerUsing) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change the column “%@”", @"Postgres structure: change column failed"), name]];
		return;
	}

	NSString *message = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
	NSString *prefilled = [usingExpression length] ? usingExpression : [NSString stringWithFormat:@"%@::%@", SPPostgresQuoteIdentifier(name), type];

	NSString *theName = [name copy];
	NSString *theType = [type copy];
	[target retain];
	[self retain];
	[self _askForUsing:message prefilled:prefilled completion:^(NSString *usingOrNil) {
		if ([usingOrNil length]) [self _changeColumn:theName toType:theType using:usingOrNil structure:target];
		[theName release];
		[theType release];
		[target release];
		[self release];
	}];
}

/// usingPresenter, or the default sheet; completion runs exactly once.
- (void)_askForUsing:(NSString *)message prefilled:(NSString *)prefilled completion:(void (^)(NSString *usingOrNil))completion
{
	void (^original)(NSString *) = completion;
	__block BOOL done = NO;
	__block void (^once)(NSString *) = nil;
	once = Block_copy(^(NSString *answer) {
		if (done) return;
		done = YES;
		original(invalidated ? nil : answer);
		[(id)once autorelease];
	});

	if (usingPresenter) {
		usingPresenter(message, prefilled, once);
		return;
	}

	NSWindow *window = [view window];
	if (!window || [window attachedSheet] || invalidated) {
		once(nil);
		return;
	}
	[self _showUsingSheetOn:window message:message prefilled:prefilled completion:once];
}

/// The default USING sheet: the server's message, the expression (prefilled), Cancel / Retry.
- (void)_showUsingSheetOn:(NSWindow *)window message:(NSString *)message prefilled:(NSString *)prefilled completion:(void (^)(NSString *))completion
{
	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	NSWindow *sheet = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 190) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES] autorelease];
	[sheet setReleasedWhenClosed:NO];
	[sheet setContentMinSize:NSMakeSize(360, 190)];
	[sheet setContentMaxSize:NSMakeSize(900, 190)];
	NSView *content = [sheet contentView];

	NSTextField *title = [NSTextField labelWithString:NSLocalizedString(@"The column's values can't be converted to the new type automatically.", @"Postgres structure: USING sheet title")];
	[title setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
	[title setFrame:NSMakeRect(17, 160, 406, 16)];
	[title setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:title];

	NSTextField *detail = [NSTextField wrappingLabelWithString:message ?: @""];
	[detail setIdentifier:@"usingMessage"];
	[detail setFont:smallFont];
	[detail setSelectable:YES];
	[detail setFrame:NSMakeRect(17, 86, 406, 70)];
	[detail setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:detail];

	NSTextField *label = [NSTextField labelWithString:NSLocalizedString(@"Convert with USING:", @"Postgres structure: USING field label")];
	[label setFont:smallFont];
	[label setFrame:NSMakeRect(17, 62, 406, 16)];
	[label setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:label];

	[usingField release];
	usingField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 40, 400, 19)];
	[usingField setIdentifier:@"usingExpression"];
	[[usingField cell] setControlSize:NSControlSizeSmall];
	[usingField setFont:[NSFont monospacedSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightRegular]];
	[[usingField cell] setScrollable:YES];
	[[usingField cell] setUsesSingleLineMode:YES];
	[usingField setStringValue:prefilled ?: @""];
	[usingField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:usingField];

	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(_closeUsingSheet:)];
	[cancel setFrame:NSMakeRect(246, 6, 91, 28)];
	[cancel setTag:NSModalResponseCancel];
	[cancel setKeyEquivalent:@"\e"];
	[cancel setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancel];

	NSButton *retry = [NSButton buttonWithTitle:NSLocalizedString(@"Retry", @"Postgres structure: USING sheet retry button") target:self action:@selector(_closeUsingSheet:)];
	[retry setIdentifier:@"usingRetryButton"];
	[retry setFrame:NSMakeRect(335, 6, 91, 28)];
	[retry setTag:NSModalResponseOK];
	[retry setKeyEquivalent:@"\r"];
	[retry setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:retry];

	[sheet setInitialFirstResponder:usingField];

	[activeSheet release];
	activeSheet = [sheet retain];
	void (^answer)(NSString *) = [[completion copy] autorelease];
	[answer retain];
	[self retain];
	[window beginSheet:sheet completionHandler:^(NSModalResponse returnCode) {
		NSString *expression = (returnCode == NSModalResponseOK) ? [[[usingField stringValue] copy] autorelease] : nil;
		[sheet orderOut:nil];
		if (activeSheet == sheet) {
			[activeSheet release];
			activeSheet = nil;
		}
		answer(invalidated ? nil : expression);
		[answer release];
		[self release];
	}];
}

- (void)_closeUsingSheet:(id)sender
{
	if (!activeSheet) return;
	[[activeSheet sheetParent] endSheet:activeSheet returnCode:[sender tag]];
}

#pragma mark - Indexes and constraints

/// constraintSheetPresenter, or SPPostgresConstraintSheet on the view's window; completion runs once (nil: cancelled).
- (void)_showSheetForKind:(NSString *)kind completion:(void (^)(SPPostgresConstraintDefinition *definition))completion
{
	NSArray *names = [columns valueForKey:@"name"];
	SPPostgresTableStructure *target = [structure retain];
	void (^body)(SPPostgresConstraintDefinition *) = [[completion copy] autorelease];
	[body retain];
	[self retain];

	// A heap block, so a presenter may keep it until the answer comes
	__block BOOL done = NO;
	void (^finish)(SPPostgresConstraintDefinition *) = [[^(SPPostgresConstraintDefinition *definition) {
		if (done) return;
		done = YES;
		// The sheet has ended
		if (!invalidated) {
			[activeSheet autorelease];
			activeSheet = nil;
		}
		if (definition && !invalidated && target == structure && ![self _refuseChangeWhileBusy]) body(definition);
		[body release];
		[target release];
		[self release];
	} copy] autorelease];

	if (constraintSheetPresenter) {
		constraintSheetPresenter(kind, names, finish);
		return;
	}

	NSWindow *window = [view window];
	if (!window || [window attachedSheet]) {
		finish(nil);
		return;
	}
	[SPPostgresConstraintSheet beginForKind:kind columns:names schema:schema connection:connection taskRunner:[self taskRunner] window:window completion:finish];
	[activeSheet release];
	activeSheet = [[window attachedSheet] retain];
}

- (IBAction)addIndex:(id)sender
{
	if (invalidated || !structure || !loaded || !editable || [self _refuseChangeWhileBusy] || ![self _endEditing]) return;

	[self _showSheetForKind:SPPostgresConstraintSheetIndexKind completion:^(SPPostgresConstraintDefinition *definition) {
		BOOL unique = NO;
		NSString *method = nil;
		if ([definition isKindOfClass:[SPPostgresIndexDefinition class]]) {
			unique = [(SPPostgresIndexDefinition *)definition unique];
			method = [(SPPostgresIndexDefinition *)definition method];
		}
		NSString *name = [[definition name] length] ? [definition name] : nil;
		NSError *error = nil;
		if ([structure addIndexNamed:name columns:[definition columns] unique:unique method:method error:&error]) {
			[self _didChange:YES];
		}
		else {
			[self _presentError:error title:NSLocalizedString(@"Could not add the index", @"Postgres structure: add index failed")];
			[self _load];
		}
	}];
}

- (IBAction)removeIndex:(id)sender
{
	if (invalidated || !structure || !loaded || !editable || [self _refuseChangeWhileBusy]) return;
	NSInteger row = [indexesView selectedRow];
	if (row < 0 || row >= (NSInteger)[indexes count]) return;

	NSString *name = [[[indexes objectAtIndex:(NSUInteger)row] name] copy];
	SPPostgresTableStructure *target = [structure retain];
	[self retain];
	[self _confirm:[self _deleteAlertForKind:NSLocalizedString(@"index", @"Postgres structure: index (delete confirmation)") name:name] completion:^(BOOL confirmed) {
		if (confirmed && !invalidated && target == structure && ![self _refuseChangeWhileBusy]) {
			NSError *error = nil;
			if ([structure dropIndexNamed:name error:&error]) {
				[indexesView deselectAll:nil];
				[self _didChange:YES];
			}
			else {
				[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not delete the index “%@”", @"Postgres structure: drop index failed"), name]];
				[self _load];
			}
		}
		[name release];
		[target release];
		[self release];
	}];
}

- (IBAction)addConstraint:(id)sender
{
	if (invalidated || !structure || !loaded || !editable || [self _refuseChangeWhileBusy] || ![self _endEditing]) return;

	// A primary key first when the table has none
	BOOL hasPrimaryKey = [[constraints valueForKey:@"kind"] containsObject:@"PRIMARY KEY"];
	[self _showSheetForKind:hasPrimaryKey ? @"UNIQUE" : @"PRIMARY KEY" completion:^(SPPostgresConstraintDefinition *definition) {
		NSError *error = nil;
		if ([structure addConstraint:definition error:&error]) {
			[self _didChange:YES];
		}
		else {
			[self _presentError:error title:NSLocalizedString(@"Could not add the constraint", @"Postgres structure: add constraint failed")];
			[self _load];
		}
	}];
}

- (IBAction)removeConstraint:(id)sender
{
	if (invalidated || !structure || !loaded || !editable || [self _refuseChangeWhileBusy]) return;
	NSInteger row = [constraintsView selectedRow];
	if (row < 0 || row >= (NSInteger)[constraints count]) return;

	NSString *name = [[[constraints objectAtIndex:(NSUInteger)row] name] copy];
	SPPostgresTableStructure *target = [structure retain];
	[self retain];
	[self _confirm:[self _deleteAlertForKind:NSLocalizedString(@"constraint", @"Postgres structure: constraint (delete confirmation)") name:name] completion:^(BOOL confirmed) {
		if (confirmed && !invalidated && target == structure && ![self _refuseChangeWhileBusy]) {
			NSError *error = nil;
			if ([structure dropConstraintNamed:name error:&error]) {
				[constraintsView deselectAll:nil];
				[self _didChange:YES];
			}
			else {
				[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not delete the constraint “%@”", @"Postgres structure: drop constraint failed"), name]];
				[self _load];
			}
		}
		[name release];
		[target release];
		[self release];
	}];
}

#pragma mark - Table view data source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)grid
{
	if (grid == columnsView) return (NSInteger)[columns count] + (draft ? 1 : 0);
	if (grid == indexesView) return (NSInteger)[indexes count];
	if (grid == constraintsView) return (NSInteger)[constraints count];
	return 0;
}

- (BOOL)_isDraftRow:(NSInteger)row
{
	return draft && row == (NSInteger)[columns count];
}

- (id)tableView:(NSTableView *)grid objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSString *identifier = [tableColumn identifier];
	if (row < 0) return nil;

	if (grid == columnsView) {
		if ([self _isDraftRow:row]) {
			if ([identifier isEqualToString:SPPostgresStructureName]) return [draft name] ?: @"";
			if ([identifier isEqualToString:SPPostgresStructureType]) return [draft typeName] ?: @"";
			if ([identifier isEqualToString:SPPostgresStructureNullable]) return @(![draft notNull]);
			if ([identifier isEqualToString:SPPostgresStructureDefault]) return [draft defaultExpression] ?: @"";
			if ([identifier isEqualToString:SPPostgresStructureComment]) return [draft comment] ?: @"";
			if ([identifier isEqualToString:SPPostgresStructureAuto]) {
				NSUInteger index = [[self _autoKinds] indexOfObject:[draft autoKind] ?: @""];
				return @(index == NSNotFound ? 0 : index);
			}
			return nil;
		}
		if (row >= (NSInteger)[columns count]) return nil;
		SPPostgresStructureColumn *column = [columns objectAtIndex:(NSUInteger)row];
		if ([identifier isEqualToString:SPPostgresStructureName]) return [column name];
		if ([identifier isEqualToString:SPPostgresStructureType]) return [column typeName];
		if ([identifier isEqualToString:SPPostgresStructureNullable]) return @([column nullable]);
		// A generated column shows its expression (read-only)
		if ([identifier isEqualToString:SPPostgresStructureDefault]) return [column defaultExpression] ?: ([column generationExpression] ?: @"");
		if ([identifier isEqualToString:SPPostgresStructureAuto]) return [column autoKind] ?: @"";
		if ([identifier isEqualToString:SPPostgresStructureComment]) return [column comment] ?: @"";
		return nil;
	}

	if (grid == indexesView) {
		if (row >= (NSInteger)[indexes count]) return nil;
		SPPostgresIndex *index = [indexes objectAtIndex:(NSUInteger)row];
		if ([identifier isEqualToString:@"name"]) return [index name];
		if ([identifier isEqualToString:@"columns"]) return [[index columns] componentsJoinedByString:@", "];
		if ([identifier isEqualToString:@"unique"]) return @([index isUnique]);
		if ([identifier isEqualToString:@"method"]) return [index method];
		return nil;
	}

	if (grid == constraintsView) {
		if (row >= (NSInteger)[constraints count]) return nil;
		SPPostgresConstraint *constraint = [constraints objectAtIndex:(NSUInteger)row];
		if ([identifier isEqualToString:@"name"]) return [constraint name];
		if ([identifier isEqualToString:@"type"]) return [constraint kind];
		if ([identifier isEqualToString:@"definition"]) return [constraint definition];
		return nil;
	}

	return nil;
}

/// The end of a cell edit: a draft keeps the value; a column runs its one change at once.
- (void)tableView:(NSTableView *)grid setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (invalidated || grid != columnsView || !structure || !loaded || !editable || row < 0) return;
	NSString *identifier = [tableColumn identifier];

	if ([self _isDraftRow:row]) {
		NSString *text = [object isKindOfClass:[NSString class]] ? object : ([object respondsToSelector:@selector(stringValue)] ? [object stringValue] : @"");
		if ([identifier isEqualToString:SPPostgresStructureName]) [draft setName:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
		else if ([identifier isEqualToString:SPPostgresStructureType]) [draft setTypeName:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
		else if ([identifier isEqualToString:SPPostgresStructureNullable]) [draft setNotNull:![object boolValue]];
		else if ([identifier isEqualToString:SPPostgresStructureDefault]) [draft setDefaultExpression:text];
		else if ([identifier isEqualToString:SPPostgresStructureComment]) [draft setComment:text];
		else if ([identifier isEqualToString:SPPostgresStructureAuto]) {
			NSInteger index = [object integerValue];
			NSArray *kinds = [self _autoKinds];
			[draft setAutoKind:(index >= 0 && index < (NSInteger)[kinds count]) ? [kinds objectAtIndex:(NSUInteger)index] : @""];
		}
		return;
	}

	if (row >= (NSInteger)[columns count]) return;
	SPPostgresStructureColumn *column = [[[columns objectAtIndex:(NSUInteger)row] retain] autorelease];
	if (![self _canEditColumn:column identifier:identifier] || [self _refuseChangeWhileBusy]) return;
	[self _changeColumn:column identifier:identifier value:object];
}

#pragma mark - Table view delegate

- (BOOL)_canEditColumn:(SPPostgresStructureColumn *)column identifier:(NSString *)identifier
{
	if ([identifier isEqualToString:SPPostgresStructureAuto]) return NO;
	if ([[column autoKind] isEqualToString:@"generated"] &&
		([identifier isEqualToString:SPPostgresStructureType] || [identifier isEqualToString:SPPostgresStructureDefault])) return NO;
	return YES;
}

- (BOOL)tableView:(NSTableView *)grid shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (invalidated || grid != columnsView || !structure || !loaded || !editable || row < 0 || [[loader taskRunner] isBusy]) return NO;
	if ([self _isDraftRow:row]) return YES;
	if (row >= (NSInteger)[columns count]) return NO;
	return [self _canEditColumn:[columns objectAtIndex:(NSUInteger)row] identifier:[tableColumn identifier]];
}

/// Checkboxes and the Auto pop-up follow the same rules as text cells.
- (BOOL)tableView:(NSTableView *)grid shouldTrackCell:(NSCell *)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (![cell isKindOfClass:[NSButtonCell class]] && ![cell isKindOfClass:[NSPopUpButtonCell class]]) return YES;
	return [self tableView:grid shouldEditTableColumn:tableColumn row:row];
}

- (NSCell *)tableView:(NSTableView *)grid dataCellForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (!tableColumn) return nil;
	if (grid == columnsView && [self _isDraftRow:row] && [[tableColumn identifier] isEqualToString:SPPostgresStructureAuto]) return autoPopupCell;
	return [tableColumn dataCellForRow:row];
}

- (void)tableView:(NSTableView *)grid willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if ([cell isKindOfClass:[NSButtonCell class]]) {
		[cell setEnabled:[self tableView:grid shouldEditTableColumn:tableColumn row:row]];
		return;
	}
	if (![cell respondsToSelector:@selector(setTextColor:)]) return;
	BOOL readOnly = (grid == columnsView) && ![self tableView:grid shouldEditTableColumn:tableColumn row:row] && ![grid isRowSelected:row];
	[cell setTextColor:readOnly && editable ? [NSColor secondaryLabelColor] : [NSColor controlTextColor]];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	NSTableView *grid = [notification object];

	// The selection left the draft: it is saved (or stays selected, for correction)
	if (grid == columnsView && draft && !savingDraft && [columnsView selectedRow] != (NSInteger)[columns count]) {
		[self _saveDraftSelectingRow:[columnsView selectedRow]];
	}
	[self _updateButtons];
}

/// Return in a draft's cell saves the draft; Esc discards it (as MySQL's Structure tab).
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
	if (control != columnsView || !draft || ![self _isDraftRow:[columnsView editedRow]]) return NO;

	if (command == @selector(insertNewline:)) {
		if ([[columnsView window] makeFirstResponder:columnsView]) [self _saveDraftSelectingRow:-1];
		return YES;
	}
	if (command == @selector(cancelOperation:)) {
		[self _discardDraft];
		return YES;
	}
	return NO;
}

/// Esc in the grid outside a cell edit (SPTableView): discards a draft.
- (BOOL)cancelRowEditing
{
	if (!draft) return NO;
	[self _discardDraft];
	return YES;
}

@end
