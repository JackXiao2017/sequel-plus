#import "SPPostgresSidebarController.h"
#import "SPPostgresCatalog.h"

static NSString * const SPPostgresSidebarTables = @"TABLES";
static NSString * const SPPostgresSidebarViews = @"VIEWS";
static NSString * const SPPostgresSidebarExtensions = @"EXTENSIONS";

static NSString * const SPPostgresSidebarGroupCell = @"SPPostgresSidebarGroupCell";
static NSString * const SPPostgresSidebarItemCell = @"SPPostgresSidebarItemCell";

static const CGFloat SPPostgresSidebarSchemaBarHeight = 32;
static const NSInteger SPPostgresSidebarDetailTag = 1;

typedef NS_ENUM(NSInteger, SPPostgresSidebarItemKind) {
	SPPostgresSidebarSection,
	SPPostgresSidebarTable,
	SPPostgresSidebarView,
	SPPostgresSidebarExtension
};

/// One outline row: a section header, or a table, view or extension. Rows are distinct objects, so a
/// table called "TABLES" is still a table.
@interface SPPostgresSidebarItem : NSObject
@property (copy) NSString *title;
@property (copy) NSString *detail;
@property (assign) SPPostgresSidebarItemKind kind;
@property (retain) NSMutableArray *children;
+ (instancetype)itemWithTitle:(NSString *)title detail:(NSString *)detail kind:(SPPostgresSidebarItemKind)kind;
@end

@implementation SPPostgresSidebarItem

@synthesize title, detail, kind, children;

+ (instancetype)itemWithTitle:(NSString *)theTitle detail:(NSString *)theDetail kind:(SPPostgresSidebarItemKind)theKind
{
	SPPostgresSidebarItem *item = [[[self alloc] init] autorelease];
	[item setTitle:theTitle];
	[item setDetail:theDetail];
	[item setKind:theKind];
	if (theKind == SPPostgresSidebarSection) [item setChildren:[NSMutableArray array]];
	return item;
}

- (void)dealloc
{
	[title release];
	[detail release];
	[children release];
	[super dealloc];
}

@end

#pragma mark -

@interface SPPostgresSidebarController () <NSMenuItemValidation>

- (void)_buildView;
- (void)_reloadSchemaPopup;
- (void)_reloadExtensions;
- (void)_reloadOutline;
- (void)_updateSelectionFromOutline;
- (BOOL)_delegateAllowsSelectionChange;
- (void)_rememberError:(NSError *)error;
- (void)_beginReload;
- (void)_endReload;
- (SPPostgresSidebarItem *)_sectionNamed:(NSString *)title;
- (SPPostgresSidebarItem *)_menuTargetItem;

@end

@implementation SPPostgresSidebarController
{
	SPPostgresCatalog *catalog;
	NSArray *schemas;
	NSArray *sections; // TABLES, VIEWS, EXTENSIONS

	NSView *view;
	NSPopUpButton *schemaPopup;
	NSOutlineView *outlineView;
	NSMenu *tableMenu;

	BOOL reloading;

	/// Nesting of reloads (a catalog reload contains a schema reload): failures are reported once, at the end
	NSUInteger reloadDepth;
	BOOL reloadFailed;

	/// -reloadKeepingSelection tells the delegate once, at the end
	BOOL holdingSelectionChanges;
}

@synthesize selectedSchema;
@synthesize selectedTableName;
@synthesize lastError;
@synthesize delegate;
@synthesize tableMenu;

- (instancetype)initWithCatalog:(SPPostgresCatalog *)theCatalog
{
	if ((self = [super init])) {
		sections = [@[[SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarTables detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarViews detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarExtensions detail:nil kind:SPPostgresSidebarSection]] retain];
		schemas = [@[] retain];

		[self _buildView];
		[self reloadWithCatalog:theCatalog];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[catalog release];
	[schemas release];
	[sections release];
	[view release];
	[schemaPopup release];
	[outlineView release];
	[tableMenu release];
	[selectedSchema release];
	[selectedTableName release];
	[lastError release];

	[super dealloc];
}

- (void)invalidate
{
	delegate = nil;
	[outlineView setDelegate:nil];
	[outlineView setDataSource:nil];
	[schemaPopup setTarget:nil];
	for (NSMenuItem *item in [tableMenu itemArray]) [item setTarget:nil];
}

#pragma mark - View

- (NSView *)view
{
	return view;
}

- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 250, 500);

	// Same backdrop as a source list, so the schema bar and the outline read as one panel
	NSVisualEffectView *container = [[NSVisualEffectView alloc] initWithFrame:frame];
	[container setMaterial:NSVisualEffectMaterialSidebar];
	[container setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
	[container setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	view = container;

	// Schema bar on top
	NSTextField *schemaLabel = [NSTextField labelWithString:NSLocalizedString(@"SCHEMA", @"PostgreSQL sidebar: schema picker label")];
	[schemaLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightSemibold]];
	[schemaLabel setTextColor:[NSColor secondaryLabelColor]];
	[schemaLabel sizeToFit];
	CGFloat barY = NSMaxY(frame) - SPPostgresSidebarSchemaBarHeight;
	[schemaLabel setFrameOrigin:NSMakePoint(10, barY + round((SPPostgresSidebarSchemaBarHeight - NSHeight([schemaLabel frame])) / 2))];
	[schemaLabel setAutoresizingMask:NSViewMinYMargin];
	[container addSubview:schemaLabel];

	CGFloat popupX = NSMaxX([schemaLabel frame]) + 6;
	schemaPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(popupX, barY + 5, NSWidth(frame) - popupX - 8, 22) pullsDown:NO];
	[schemaPopup setControlSize:NSControlSizeSmall];
	[schemaPopup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[schemaPopup setBezelStyle:NSBezelStyleRounded];
	[[schemaPopup cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[schemaPopup setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[schemaPopup setTarget:self];
	[schemaPopup setAction:@selector(chooseSchema:)];
	[schemaPopup setToolTip:NSLocalizedString(@"Choose the schema whose tables and views are listed", @"PostgreSQL sidebar: schema picker tooltip")];
	[container addSubview:schemaPopup];

	// Outline below
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), barY)] autorelease];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:NO];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setDrawsBackground:NO];

	outlineView = [[NSOutlineView alloc] initWithFrame:[[scrollView contentView] bounds]];
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
	[column setResizingMask:NSTableColumnAutoresizingMask];
	[outlineView addTableColumn:column];
	[outlineView setOutlineTableColumn:column];
	[outlineView setHeaderView:nil];
	[outlineView setStyle:NSTableViewStyleSourceList];
	[outlineView setRowSizeStyle:NSTableViewRowSizeStyleSmall];
	[outlineView setFloatsGroupRows:NO];
	[outlineView setIndentationPerLevel:0];
	[outlineView setAllowsMultipleSelection:NO];
	[outlineView setAllowsEmptySelection:YES];
	[outlineView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
	[outlineView setFocusRingType:NSFocusRingTypeNone];
	[outlineView setAutosaveExpandedItems:NO];
	[outlineView setDataSource:self];
	[outlineView setDelegate:self];
	[scrollView setDocumentView:outlineView];
	[outlineView sizeLastColumnToFit];

	// Right-click menu, worded as MySQL's tables list menu (DBView.xib)
	tableMenu = [[NSMenu alloc] initWithTitle:@""];
	NSMenuItem *duplicate = [tableMenu addItemWithTitle:NSLocalizedString(@"Duplicate Table…", @"PostgreSQL sidebar: duplicate table menu item") action:@selector(duplicateTable:) keyEquivalent:@""];
	[duplicate setToolTip:NSLocalizedString(@"Duplicate the selected item", @"PostgreSQL sidebar: duplicate table menu item tooltip")];
	[duplicate setTarget:self];
	NSMenuItem *rename = [tableMenu addItemWithTitle:NSLocalizedString(@"Rename Table…", @"PostgreSQL sidebar: rename table menu item") action:@selector(renameTable:) keyEquivalent:@""];
	[rename setToolTip:NSLocalizedString(@"Rename the selected item", @"PostgreSQL sidebar: rename table menu item tooltip")];
	[rename setTarget:self];
	[outlineView setMenu:tableMenu];

	[container addSubview:scrollView];
}

#pragma mark - Loading

- (void)reloadWithCatalog:(SPPostgresCatalog *)theCatalog
{
	if (theCatalog != catalog) {
		[catalog release];
		catalog = [theCatalog retain];
	}

	[self _beginReload];

	NSError *error = nil;
	NSArray *names = [catalog schemaNames:&error];
	if (names) {
		[schemas release];
		schemas = [names copy];
	}
	else {
		// Keep the schemas that were listed
		[self _rememberError:error];
	}

	[self _reloadExtensions];

	// The default schema of this database (the previous database's schema doesn't carry over)
	[self reloadSchema:[catalog defaultSchemaFromSchemas:schemas]];

	[self _endReload];
}

- (void)reloadKeepingSelection
{
	NSString *previousSchema = [[selectedSchema copy] autorelease];
	NSString *table = [[selectedTableName copy] autorelease];
	NSString *schema = previousSchema;

	[self _beginReload];

	NSError *error = nil;
	NSArray *names = [catalog schemaNames:&error];
	if (names) {
		[schemas release];
		schemas = [names copy];
		if (![names containsObject:schema]) schema = [catalog defaultSchemaFromSchemas:schemas];
	}
	else {
		[self _rememberError:error];
	}

	[self _reloadExtensions];

	holdingSelectionChanges = YES;
	[self reloadSchema:schema];
	// The same schema (not the default one standing in for a schema that is gone): its table again
	if (table && [previousSchema isEqualToString:selectedSchema]) [self selectTableNamed:table];
	holdingSelectionChanges = NO;

	BOOL sameSchema = (previousSchema == selectedSchema) || [previousSchema isEqualToString:selectedSchema];
	BOOL sameTable = (table == selectedTableName) || [table isEqualToString:selectedTableName];
	if (!sameSchema || !sameTable) [delegate sidebarSelectionDidChange:self];

	[self _endReload];
}

- (void)reloadSchema:(NSString *)schema
{
	[self _beginReload];

	NSArray *tableNames = nil;
	NSArray *viewNames = nil;
	BOOL loaded = YES;

	if (schema) {
		NSError *error = nil;
		tableNames = [catalog tableNamesInSchema:schema error:&error];
		if (!tableNames) {
			[self _rememberError:error];
			loaded = NO;
		}

		error = nil;
		viewNames = [catalog viewNamesInSchema:schema error:&error];
		if (!viewNames) {
			[self _rememberError:error];
			loaded = NO;
		}
	}

	if (loaded) {
		if (selectedSchema != schema) {
			[selectedSchema release];
			selectedSchema = [schema copy];
		}
		[selectedTableName release], selectedTableName = nil;

		SPPostgresSidebarItem *tables = [self _sectionNamed:SPPostgresSidebarTables];
		SPPostgresSidebarItem *views = [self _sectionNamed:SPPostgresSidebarViews];
		[[tables children] removeAllObjects];
		[[views children] removeAllObjects];

		for (NSString *name in tableNames) {
			[[tables children] addObject:[SPPostgresSidebarItem itemWithTitle:name detail:nil kind:SPPostgresSidebarTable]];
		}
		for (NSString *name in viewNames) {
			[[views children] addObject:[SPPostgresSidebarItem itemWithTitle:name detail:nil kind:SPPostgresSidebarView]];
		}

		[self _reloadSchemaPopup];
		[self _reloadOutline];

		if (!holdingSelectionChanges) [delegate sidebarSelectionDidChange:self];
	}
	else {
		// Keep the schema, lists and selection that were shown; the popup goes back to the shown schema
		[self _reloadSchemaPopup];
		// An enclosing catalog reload may have reloaded the extensions: show them, leaving the table selection
		[outlineView reloadItem:[self _sectionNamed:SPPostgresSidebarExtensions] reloadChildren:YES];
	}

	[self _endReload];
}

- (void)_reloadExtensions
{
	NSError *error = nil;
	NSArray *installed = [catalog installedExtensions:&error];
	if (!installed) {
		// Keep the extensions that were listed
		[self _rememberError:error];
		return;
	}

	SPPostgresSidebarItem *extensions = [self _sectionNamed:SPPostgresSidebarExtensions];
	[[extensions children] removeAllObjects];
	for (NSDictionary *extension in installed) {
		[[extensions children] addObject:[SPPostgresSidebarItem itemWithTitle:[extension objectForKey:@"name"] detail:[extension objectForKey:@"version"] kind:SPPostgresSidebarExtension]];
	}
}

- (void)_reloadSchemaPopup
{
	[schemaPopup removeAllItems];
	[schemaPopup addItemsWithTitles:schemas];

	// A schema that isn't listed (e.g. hidden from the catalog query) is still shown as selected
	if (selectedSchema && ![schemas containsObject:selectedSchema]) [schemaPopup addItemWithTitle:selectedSchema];
	if (selectedSchema) [schemaPopup selectItemWithTitle:selectedSchema];

	[schemaPopup setEnabled:([schemaPopup numberOfItems] > 0)];
}

- (void)_reloadOutline
{
	reloading = YES;
	[outlineView deselectAll:nil];
	[outlineView reloadData];
	for (SPPostgresSidebarItem *section in sections) [outlineView expandItem:section];
	reloading = NO;
}

/// Records the first failure of the current reload (a failed query without an NSError still counts).
- (void)_rememberError:(NSError *)error
{
	if (reloadFailed && lastError) return;
	reloadFailed = YES;
	if (!error) return;
	[lastError release];
	lastError = [error retain];
}

- (void)_beginReload
{
	if (reloadDepth++ == 0) {
		reloadFailed = NO;
		[lastError release], lastError = nil;
	}
}

- (void)_endReload
{
	if (--reloadDepth > 0 || !reloadFailed) return;

	if ([delegate respondsToSelector:@selector(sidebar:didFailToLoadWithError:)]) {
		[delegate sidebar:self didFailToLoadWithError:lastError];
	}
}

- (SPPostgresSidebarItem *)_sectionNamed:(NSString *)title
{
	for (SPPostgresSidebarItem *section in sections) {
		if ([[section title] isEqualToString:title]) return section;
	}
	return nil;
}

#pragma mark - Queries

- (NSArray *)sectionTitles
{
	return [sections valueForKey:@"title"];
}

- (NSArray *)itemTitlesInSection:(NSString *)sectionTitle
{
	SPPostgresSidebarItem *section = [self _sectionNamed:sectionTitle];
	return section ? [[section children] valueForKey:@"title"] : nil;
}

#pragma mark - Selection

- (BOOL)selectTableNamed:(NSString *)name
{
	if (!name) {
		[outlineView deselectAll:nil];
		[self _updateSelectionFromOutline];
		return YES;
	}

	for (NSString *sectionTitle in @[SPPostgresSidebarTables, SPPostgresSidebarViews]) {
		for (SPPostgresSidebarItem *item in [[self _sectionNamed:sectionTitle] children]) {
			if (![[item title] isEqualToString:name]) continue;

			NSInteger row = [outlineView rowForItem:item];
			if (row < 0) return NO;
			[outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
			[outlineView scrollRowToVisible:row];
			[self _updateSelectionFromOutline];
			return YES;
		}
	}
	return NO;
}

- (void)_updateSelectionFromOutline
{
	SPPostgresSidebarItem *item = [outlineView selectedRow] >= 0 ? [outlineView itemAtRow:[outlineView selectedRow]] : nil;
	NSString *name = ([item kind] == SPPostgresSidebarTable || [item kind] == SPPostgresSidebarView) ? [item title] : nil;

	if (name == selectedTableName || [name isEqualToString:selectedTableName]) return;

	[selectedTableName release];
	selectedTableName = [name copy];

	if (!holdingSelectionChanges) [delegate sidebarSelectionDidChange:self];
}

- (void)chooseSchema:(id)sender
{
	NSString *schema = [schemaPopup titleOfSelectedItem];
	if (!schema || [schema isEqualToString:selectedSchema]) return;

	// Refused (e.g. an edit that can't be saved): the pop-up shows the schema that stays
	if (![self _delegateAllowsSelectionChange]) {
		if (selectedSchema && [schemaPopup indexOfItemWithTitle:selectedSchema] >= 0) [schemaPopup selectItemWithTitle:selectedSchema];
		return;
	}
	[self reloadSchema:schema];
}

- (BOOL)selectionIsTable
{
	if (![selectedTableName length]) return NO;
	for (SPPostgresSidebarItem *item in [[self _sectionNamed:SPPostgresSidebarTables] children]) {
		if ([[item title] isEqualToString:selectedTableName]) return YES;
	}
	return NO;
}

#pragma mark - Menu

/// The right-clicked row's item, or else the selected row's (nil if neither).
- (SPPostgresSidebarItem *)_menuTargetItem
{
	NSInteger row = [outlineView clickedRow];
	if (row < 0) row = [outlineView selectedRow];
	return (row >= 0) ? [outlineView itemAtRow:row] : nil;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	if ([item action] == @selector(duplicateTable:)) {
		return [[self _menuTargetItem] kind] == SPPostgresSidebarTable && [delegate respondsToSelector:@selector(sidebar:duplicateTableNamed:)];
	}
	if ([item action] == @selector(renameTable:)) {
		return [[self _menuTargetItem] kind] == SPPostgresSidebarTable && [delegate respondsToSelector:@selector(sidebar:renameTableNamed:)];
	}
	return YES;
}

- (void)renameTable:(id)sender
{
	SPPostgresSidebarItem *item = [self _menuTargetItem];
	if ([item kind] != SPPostgresSidebarTable) return;
	if ([delegate respondsToSelector:@selector(sidebar:renameTableNamed:)]) [delegate sidebar:self renameTableNamed:[item title]];
}

- (void)duplicateTable:(id)sender
{
	SPPostgresSidebarItem *item = [self _menuTargetItem];
	if ([item kind] != SPPostgresSidebarTable) return;
	if ([delegate respondsToSelector:@selector(sidebar:duplicateTableNamed:)]) [delegate sidebar:self duplicateTableNamed:[item title]];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)theOutlineView numberOfChildrenOfItem:(id)item
{
	return item ? (NSInteger)[[(SPPostgresSidebarItem *)item children] count] : (NSInteger)[sections count];
}

- (id)outlineView:(NSOutlineView *)theOutlineView child:(NSInteger)index ofItem:(id)item
{
	NSArray *children = item ? [(SPPostgresSidebarItem *)item children] : sections;
	return [children objectAtIndex:(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)theOutlineView isItemExpandable:(id)item
{
	return [(SPPostgresSidebarItem *)item kind] == SPPostgresSidebarSection;
}

- (id)outlineView:(NSOutlineView *)theOutlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	return [(SPPostgresSidebarItem *)item title];
}

#pragma mark - NSOutlineViewDelegate

- (BOOL)outlineView:(NSOutlineView *)theOutlineView isGroupItem:(id)item
{
	return [(SPPostgresSidebarItem *)item kind] == SPPostgresSidebarSection;
}

- (BOOL)outlineView:(NSOutlineView *)theOutlineView shouldSelectItem:(id)item
{
	return [(SPPostgresSidebarItem *)item kind] != SPPostgresSidebarSection;
}

- (BOOL)outlineView:(NSOutlineView *)theOutlineView shouldShowOutlineCellForItem:(id)item
{
	// Sections are always expanded, as in the MySQL table list
	return NO;
}

- (BOOL)outlineView:(NSOutlineView *)theOutlineView shouldCollapseItem:(id)item
{
	return NO;
}

- (NSView *)outlineView:(NSOutlineView *)theOutlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)theItem
{
	SPPostgresSidebarItem *item = theItem;
	BOOL isSection = ([item kind] == SPPostgresSidebarSection);
	NSString *identifier = isSection ? SPPostgresSidebarGroupCell : SPPostgresSidebarItemCell;

	NSTableCellView *cell = [theOutlineView makeViewWithIdentifier:identifier owner:self];
	if (!cell) {
		CGFloat width = [tableColumn width];
		cell = [[[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, width, 18)] autorelease];
		[cell setIdentifier:identifier];

		NSTextField *textField = [NSTextField labelWithString:@""];
		[textField setLineBreakMode:NSLineBreakByTruncatingTail];
		[textField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin];
		[cell addSubview:textField];
		[cell setTextField:textField];

		if (isSection) {
			[textField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightSemibold]];
			[textField setTextColor:[NSColor secondaryLabelColor]];
			[textField setFrame:NSMakeRect(2, 1, width - 4, 16)];
		}
		else {
			NSImageView *imageView = [[[NSImageView alloc] initWithFrame:NSMakeRect(4, 1, 16, 16)] autorelease];
			[imageView setImageScaling:NSImageScaleProportionallyDown];
			[imageView setAutoresizingMask:NSViewMinYMargin | NSViewMaxYMargin];
			[cell addSubview:imageView];
			[cell setImageView:imageView];

			[textField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
			[textField setFrame:NSMakeRect(24, 1, width - 28, 16)];

			// Extension version, right-aligned
			NSTextField *detailField = [NSTextField labelWithString:@""];
			[detailField setTag:SPPostgresSidebarDetailTag];
			[detailField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
			[detailField setTextColor:[NSColor secondaryLabelColor]];
			[detailField setAlignment:NSTextAlignmentRight];
			[detailField setFrame:NSMakeRect(width - 64, 1, 60, 16)];
			[detailField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin | NSViewMaxYMargin];
			[cell addSubview:detailField];
		}
	}

	[[cell textField] setStringValue:[item title] ?: @""];

	if (!isSection) {
		NSImage *image = nil;
		switch ([item kind]) {
			case SPPostgresSidebarTable: image = [NSImage imageNamed:@"table-small"]; break;
			case SPPostgresSidebarView: image = [NSImage imageNamed:@"table-view-small"]; break;
			default: image = [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:NSLocalizedString(@"Extension", @"PostgreSQL sidebar: extension icon description")]; break;
		}
		[[cell imageView] setImage:image];
		[[cell imageView] setContentTintColor:([item kind] == SPPostgresSidebarExtension) ? [NSColor secondaryLabelColor] : nil];

		NSTextField *detailField = [cell viewWithTag:SPPostgresSidebarDetailTag];
		NSString *detail = [item detail] ?: @"";
		[detailField setStringValue:detail];
		[detailField setHidden:![detail length]];

		// Leave room for the version so long extension names truncate before it
		NSRect textFrame = [[cell textField] frame];
		CGFloat detailWidth = [detail length] ? ceil([detailField fittingSize].width) + 6 : 0;
		textFrame.size.width = MAX(20, NSWidth([cell bounds]) - NSMinX(textFrame) - 4 - detailWidth);
		[[cell textField] setFrame:textFrame];
	}

	return cell;
}

/// The user's selection change (not the API's) asks the delegate first.
- (BOOL)selectionShouldChangeInOutlineView:(NSOutlineView *)theOutlineView
{
	if (reloading) return YES;
	return [self _delegateAllowsSelectionChange];
}

- (BOOL)_delegateAllowsSelectionChange
{
	if (![delegate respondsToSelector:@selector(sidebarShouldChangeSelection:)]) return YES;
	return [delegate sidebarShouldChangeSelection:self];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	if (reloading) return;
	[self _updateSelectionFromOutline];
}

@end
