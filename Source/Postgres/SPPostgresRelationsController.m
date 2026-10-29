#import "SPPostgresRelationsController.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresConstraintSheet.h"
#import "SPPostgresPaneLoader.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPConstants.h"

// MySQL's Relations tab (DBView.xib): a 23 pt button bar, 32 x 25 textured buttons
static const CGFloat SPPostgresRelationsBarHeight = 23;
static const CGFloat SPPostgresRelationsButtonWidth = 32;

@interface SPPostgresRelationsController ()

@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *table;
@property (readwrite, copy) NSString *noticeText;

@end

@implementation SPPostgresRelationsController
{
	PGPostgresConnection *connection;
	SPPostgresTableStructure *structure;
	NSArray *columnNames;   // the table's, for the + sheet
	NSArray *foreignKeys;   // SPPostgresConstraint (FOREIGN KEY)
	BOOL loaded;

	SPPostgresPaneLoader *loader; // the runner, the load generation, staleness, and refusing changes while busy

	NSView *view;
	NSView *section;        // the grid and its bar (hidden under an empty state)
	SPTableView *relationsView;
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
@synthesize constraintSheetPresenter;
@synthesize relationsDidChange;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		loader = [[SPPostgresPaneLoader alloc] initWithConnection:theConnection];
		columnNames = [@[] retain];
		foreignKeys = [@[] retain];
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
	[loader release];
	[structure release];
	[columnNames release];
	[foreignKeys release];
	[schema release];
	[table release];
	[noticeText release];
	[emptyStateText release];

	[view release];
	[section release];
	[relationsView release];
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
	[loader invalidate];

	[relationsView setDataSource:nil];
	[relationsView setDelegate:nil];
	for (NSControl *control in @[addButton, removeButton, refreshButton]) [control setTarget:nil];

	// A sheet still up ends (cancelled); its completion sees `invalidated`
	NSWindow *sheet = [activeSheet autorelease];
	activeSheet = nil;
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet returnCode:NSModalResponseCancel];

	// The presenters may capture the tab
	[alertPresenter release], alertPresenter = nil;
	[confirmationPresenter release], confirmationPresenter = nil;
	[constraintSheetPresenter release], constraintSheetPresenter = nil;
	[relationsDidChange release], relationsDidChange = nil;
}

#pragma mark - View

- (NSButton *)_newBarButtonWithImage:(NSString *)imageName toolTip:(NSString *)toolTip action:(SEL)action x:(CGFloat)x
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, -1, SPPostgresRelationsButtonWidth, 25)];
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

- (void)_addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width
{
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:identifier] autorelease];
	[[column headerCell] setStringValue:title];
	[column setWidth:width];
	[column setMinWidth:30];
	[column setResizingMask:NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask];
	NSTextFieldCell *cell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
	[cell setLineBreakMode:NSLineBreakByTruncatingTail];
	[cell setFont:[self _tableFont]];
	[column setDataCell:cell];
	[column setEditable:NO];
	[relationsView addTableColumn:column];
}

/// The grid with its bar below (+, −, refresh, the table's name), as MySQL's Relations tab; an empty-state text over it.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	section = [[NSView alloc] initWithFrame:frame];
	[section setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[view addSubview:section];

	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, SPPostgresRelationsBarHeight, NSWidth(frame), NSHeight(frame) - SPPostgresRelationsBarHeight)] autorelease];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	relationsView = [[SPTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[relationsView setUsesAlternatingRowBackgroundColors:YES];
	[relationsView setAllowsMultipleSelection:NO];
	[relationsView setAllowsColumnReordering:NO];
	[relationsView setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
	[relationsView setFocusRingType:NSFocusRingTypeNone];
	[relationsView setGridStyleMask:[[NSUserDefaults standardUserDefaults] boolForKey:SPDisplayTableViewVerticalGridlines] ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	[relationsView setRowHeight:MAX(17.0f, 2.0f + ceil([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : [self _tableFont]}].height))];
	[self _addColumn:@"name" title:NSLocalizedString(@"Name", @"Postgres relations: name column") width:160];
	[self _addColumn:@"columns" title:NSLocalizedString(@"Columns", @"Postgres relations: columns column") width:120];
	[self _addColumn:@"references" title:NSLocalizedString(@"References", @"Postgres relations: referenced table column") width:150];
	[self _addColumn:@"referencedColumns" title:NSLocalizedString(@"Referenced Columns", @"Postgres relations: referenced columns column") width:120];
	[self _addColumn:@"onUpdate" title:NSLocalizedString(@"On Update", @"Postgres relations: on update column") width:80];
	[self _addColumn:@"onDelete" title:NSLocalizedString(@"On Delete", @"Postgres relations: on delete column") width:80];
	[relationsView setDataSource:self];
	[relationsView setDelegate:self];
	[scrollView setDocumentView:relationsView];
	[section addSubview:scrollView];

	SPButtonBar *bar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), SPPostgresRelationsBarHeight)] autorelease];
	[bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	addButton = [self _newBarButtonWithImage:@"button_add" toolTip:NSLocalizedString(@"Add a new foreign key", @"Postgres relations: add tooltip") action:@selector(addRelation:) x:-1];
	removeButton = [self _newBarButtonWithImage:@"button_remove" toolTip:NSLocalizedString(@"Delete the selected foreign key", @"Postgres relations: delete tooltip") action:@selector(removeRelation:) x:30];
	refreshButton = [self _newBarButtonWithImage:@"button_refresh" toolTip:NSLocalizedString(@"Refresh the relations", @"Postgres relations: refresh tooltip") action:@selector(refresh:) x:61];
	noticeField = [[NSTextField labelWithString:@""] retain];
	[noticeField setFrame:NSMakeRect(100, 4, NSWidth(frame) - 108, 14)];
	[noticeField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[[noticeField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[noticeField setAutoresizingMask:NSViewWidthSizable];
	for (NSView *subview in @[addButton, removeButton, refreshButton, noticeField]) [bar addSubview:subview];
	[section addSubview:bar];

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

- (NSTableView *)relationsView
{
	return relationsView;
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
	[section setHidden:[emptyStateText length] > 0];
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

/// The runner's thread: the table's columns and constraints, read through structure alone (nil, with *error, if they
/// can't be read).
static NSDictionary *SPPostgresRelationsRead(SPPostgresTableStructure *structure, NSError **error)
{
	NSArray *theColumns = [structure columns:error];
	if (!theColumns) return nil;
	NSArray *theConstraints = [structure constraints:error];
	if (!theConstraints) return nil;
	return @{@"columns" : theColumns, @"constraints" : theConstraints};
}

// A load (a switch, -reload, Refresh) goes through the pane loader (SPPostgresPaneLoader); on the runner's thread the
// work uses only the structure object (made on the main thread, where nothing uses it while the runner is busy: + and
// − are refused then). A change reads the keys again at once, on the main thread, as part of the change (-_load).

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

	[self setTable:theTable];
	[self setSchema:theSchema];
	[structure release];
	structure = nil;
	if ([theTable length] && [theSchema length]) {
		structure = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:theSchema table:theTable];
	}
	[relationsView deselectAll:nil];

	// The previous table's keys go at once
	[self _clearRelations];
	[self _loadSwitching:YES];
}

- (void)reload
{
	if (invalidated) return;
	[self _loadSwitching:NO];
}

- (IBAction)refresh:(id)sender
{
	[self reload];
}

/// Reads the keys through the runner and shows them (see -_showRelations:error:).
- (void)_loadSwitching:(BOOL)switching
{
	if (!structure) {
		[loader loadNothing];
		[self _clearRelations];
		return;
	}
	SPPostgresTableStructure *target = structure;
	[loader loadSwitching:switching work:^id(PGPostgresConnection *theConnection, NSError **error) {
		return SPPostgresRelationsRead(target, error);
	} apply:^(id result, NSError *error) {
		[self _showRelations:result error:error];
	}];
}

/// Reads the keys on the main thread and shows them: part of a change, which runs only while the runner is idle.
- (void)_load
{
	if (!structure) {
		[self _clearRelations];
		return;
	}
	NSError *error = nil;
	NSDictionary *result = SPPostgresRelationsRead(structure, &error);
	[self _showRelations:result error:error];
}

/// An empty grid, no notice (no table, or before a switch's table has loaded).
- (void)_clearRelations
{
	[self _showRelations:@{} error:nil];
}

/// Shows what was read (SPPostgresRelationsRead; an empty dictionary: nothing). nil means it couldn't be read: the
/// grid empties and the error is shown.
- (void)_showRelations:(NSDictionary *)result error:(NSError *)error
{
	NSArray *newColumns = [result objectForKey:@"columns"];
	NSArray *constraints = [result objectForKey:@"constraints"];
	BOOL failed = (result == nil);
	loaded = (constraints != nil);

	// The selection is kept by constraint name, not row: a key added or dropped elsewhere shifts the rows
	NSInteger selectedRow = [relationsView selectedRow];
	NSString *selectedName = (selectedRow >= 0 && selectedRow < (NSInteger)[foreignKeys count]) ? [[[[foreignKeys objectAtIndex:(NSUInteger)selectedRow] name] retain] autorelease] : nil;

	NSMutableArray *keys = [NSMutableArray array];
	for (SPPostgresConstraint *constraint in constraints) {
		if ([[constraint kind] isEqualToString:@"FOREIGN KEY"]) [keys addObject:constraint];
	}
	[foreignKeys release];
	foreignKeys = [keys copy];
	[columnNames release];
	columnNames = [([newColumns valueForKey:@"name"] ?: @[]) copy];

	NSString *notice = @"";
	if (failed) {
		NSString *detail = [[[[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"] firstObject];
		notice = [NSString stringWithFormat:NSLocalizedString(@"Could not load the relations: %@", @"Postgres relations: load failed notice"), [detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];
	}
	else if (loaded) {
		notice = [NSString stringWithFormat:NSLocalizedString(@"Relations for table: %@", @"Relations tab subtitle showing table name"), table];
	}
	[self setNoticeText:notice];
	[noticeField setStringValue:notice];

	[relationsView reloadData];
	NSUInteger row = selectedName ? [[foreignKeys valueForKey:@"name"] indexOfObject:selectedName] : NSNotFound;
	if (row != NSNotFound) [relationsView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	else [relationsView deselectAll:nil];
	[self _updateButtons];

	if (failed) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the relations of “%@”", @"Postgres relations: load failed"), table]];
	}
}

- (void)_updateButtons
{
	BOOL canChange = !invalidated && structure && loaded;
	[addButton setEnabled:canChange];
	[removeButton setEnabled:canChange && [relationsView selectedRow] >= 0];
	[refreshButton setEnabled:!invalidated && structure != nil];
}

/// A change succeeded: the grid shows the server's keys, and the tab hears of it.
/// + and − run on the main thread, so never while a load is using the connection (see SPPostgresPaneLoader).
- (BOOL)_refuseChangeWhileBusy
{
	return [loader refuseChangeWhileBusy];
}

- (void)_didChange
{
	[self _load];
	if (relationsDidChange && !invalidated) relationsDidChange();
}

#pragma mark - Changes

- (IBAction)addRelation:(id)sender
{
	if (invalidated || !structure || !loaded || [self _refuseChangeWhileBusy]) return;

	SPPostgresTableStructure *target = [structure retain];
	[self retain];

	// A heap block, so a presenter may keep it until the answer comes; runs once
	__block BOOL done = NO;
	void (^finish)(SPPostgresConstraintDefinition *) = [[^(SPPostgresConstraintDefinition *definition) {
		if (done) return;
		done = YES;
		if (!invalidated) {
			[activeSheet autorelease];
			activeSheet = nil;
		}
		if (definition && !invalidated && target == structure && ![self _refuseChangeWhileBusy]) {
			NSError *error = nil;
			if ([structure addConstraint:definition error:&error]) {
				[self _didChange];
			}
			else {
				[self _presentError:error title:NSLocalizedString(@"Could not add the foreign key", @"Postgres relations: add failed")];
				[self _load];
			}
		}
		[target release];
		[self release];
	} copy] autorelease];

	if (constraintSheetPresenter) {
		constraintSheetPresenter(columnNames, finish);
		return;
	}
	NSWindow *window = [view window];
	if (!window || [window attachedSheet]) {
		finish(nil);
		return;
	}
	[SPPostgresConstraintSheet beginForKind:@"FOREIGN KEY" columns:columnNames schema:schema connection:connection window:window completion:finish];
	if (!done) {
		[activeSheet release];
		activeSheet = [[window attachedSheet] retain];
	}
}

- (IBAction)removeRelation:(id)sender
{
	if (invalidated || !structure || !loaded || [self _refuseChangeWhileBusy]) return;
	NSInteger row = [relationsView selectedRow];
	if (row < 0 || row >= (NSInteger)[foreignKeys count]) return;

	NSString *name = [[[foreignKeys objectAtIndex:(NSUInteger)row] name] copy];
	SPPostgresTableStructure *target = [structure retain];

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
	[[[alert buttons] objectAtIndex:1] setKeyEquivalent:@"\033"];
	[alert setAlertStyle:NSAlertStyleCritical];
	NSString *kind = NSLocalizedString(@"foreign key", @"Postgres relations: foreign key (delete confirmation)");
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Delete %@ \"%@\"?", @"Postgres structure: delete confirmation (kind, name)"), kind, name]];
	[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the %@ \"%@\"? This action cannot be undone.", @"Postgres structure: delete confirmation detail (kind, name)"), kind, name]];

	[self retain];
	[self _confirm:alert completion:^(BOOL confirmed) {
		if (confirmed && !invalidated && target == structure && ![self _refuseChangeWhileBusy]) {
			NSError *error = nil;
			if ([structure dropConstraintNamed:name error:&error]) {
				[relationsView deselectAll:nil];
				[self _didChange];
			}
			else {
				[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not delete the foreign key “%@”", @"Postgres relations: drop failed"), name]];
				[self _load];
			}
		}
		[name release];
		[target release];
		[self release];
	}];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)grid
{
	return (NSInteger)[foreignKeys count];
}

- (id)tableView:(NSTableView *)grid objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[foreignKeys count]) return nil;
	SPPostgresConstraint *key = [foreignKeys objectAtIndex:(NSUInteger)row];
	NSString *identifier = [tableColumn identifier];
	if ([identifier isEqualToString:@"name"]) return [key name];
	if ([identifier isEqualToString:@"columns"]) return [[key columns] componentsJoinedByString:@", "];
	if ([identifier isEqualToString:@"references"]) return [NSString stringWithFormat:@"%@.%@", [key referencedSchema] ?: @"", [key referencedTable] ?: @""];
	if ([identifier isEqualToString:@"referencedColumns"]) return [[key referencedColumns] componentsJoinedByString:@", "];
	if ([identifier isEqualToString:@"onUpdate"]) return [key onUpdate];
	if ([identifier isEqualToString:@"onDelete"]) return [key onDelete];
	return nil;
}

- (BOOL)tableView:(NSTableView *)grid shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _updateButtons];
}

@end
