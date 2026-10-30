#import "SPPostgresSidebarController.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresTaskRunner.h"
#import "SPButtonBar.h"
#import "SPSplitView.h"
#import "SPConstants.h"

static NSString * const SPPostgresSidebarTables = @"TABLES";
static NSString * const SPPostgresSidebarViews = @"VIEWS";
static NSString * const SPPostgresSidebarSequences = @"SEQUENCES";
static NSString * const SPPostgresSidebarExtensions = @"EXTENSIONS";

static NSString * const SPPostgresSidebarGroupCell = @"SPPostgresSidebarGroupCell";
static NSString * const SPPostgresSidebarItemCell = @"SPPostgresSidebarItemCell";

static const CGFloat SPPostgresSidebarSchemaBarHeight = 32;
/// MySQL's table list bar and information pane (DBView.xib)
static const CGFloat SPPostgresSidebarButtonBarHeight = 23;
static const CGFloat SPPostgresSidebarInfoPaneHeight = 166;
static const NSInteger SPPostgresSidebarDetailTag = 1;

/// What a reload reads (on the runner's thread) before it is applied (on the main thread).
typedef NS_ENUM(NSInteger, SPPostgresSidebarReloadKind) {
	SPPostgresSidebarReloadCatalog,  // schemas, extensions, then the default schema's lists
	SPPostgresSidebarReloadKeeping,  // schemas, extensions, then the shown schema's lists (else the default schema's)
	SPPostgresSidebarReloadSchema    // one schema's lists
};

/**
 * A reload's queries, on the runner's thread, on a catalog of its own over the runner's connection: nothing here is
 * shared with the main thread (schema and knownSchemas are immutable copies). Keys: "schemas" and "extensions" (when
 * asked for and read), "schema" (the schema whose lists were read; absent for none), "tables", "views" and "sequences"
 * (when read), and "failures": each failed query's NSError (NSNull if it had none), in the order they ran.
 */
static NSDictionary *SPPostgresSidebarRead(PGPostgresConnection *connection, SPPostgresSidebarReloadKind kind, NSString *schema, NSArray *knownSchemas)
{
	SPPostgresCatalog *catalog = [[[SPPostgresCatalog alloc] initWithConnection:connection] autorelease];
	NSMutableDictionary *read = [NSMutableDictionary dictionary];
	NSMutableArray *failures = [NSMutableArray array];
	NSError *error = nil;

	if (kind != SPPostgresSidebarReloadSchema) {
		NSArray *names = [catalog schemaNames:&error];
		if (names) {
			[read setObject:names forKey:@"schemas"];
			// A catalog reload shows the default schema; a reload keeping the selection, the shown one if still there
			if (kind == SPPostgresSidebarReloadCatalog || ![names containsObject:schema]) schema = [catalog defaultSchemaFromSchemas:names];
		}
		else {
			[failures addObject:error ?: (id)[NSNull null]];
			if (kind == SPPostgresSidebarReloadCatalog) schema = [catalog defaultSchemaFromSchemas:knownSchemas];
		}

		error = nil;
		NSArray *installed = [catalog installedExtensions:&error];
		if (installed) [read setObject:installed forKey:@"extensions"];
		else [failures addObject:error ?: (id)[NSNull null]];
	}

	if (schema) {
		[read setObject:schema forKey:@"schema"];

		error = nil;
		NSArray *tables = [catalog tableNamesInSchema:schema error:&error];
		if (tables) [read setObject:tables forKey:@"tables"];
		else [failures addObject:error ?: (id)[NSNull null]];

		error = nil;
		NSArray *views = [catalog viewNamesInSchema:schema error:&error];
		if (views) [read setObject:views forKey:@"views"];
		else [failures addObject:error ?: (id)[NSNull null]];

		error = nil;
		NSArray *sequences = [catalog sequenceNamesInSchema:schema error:&error];
		if (sequences) [read setObject:sequences forKey:@"sequences"];
		else [failures addObject:error ?: (id)[NSNull null]];
	}

	[read setObject:failures forKey:@"failures"];
	return read;
}

/// Tags of the relation menus' separators that are hidden with the items next to them (see -_updateRelationItemsOfMenu:)
typedef NS_ENUM(NSInteger, SPPostgresSidebarMenuSeparatorTag) {
	/// After Rename… and Duplicate…
	SPPostgresSidebarRenameSeparatorTag = 1,
	/// Before the Open items
	SPPostgresSidebarOpenSeparatorTag = 2
};

typedef NS_ENUM(NSInteger, SPPostgresSidebarItemKind) {
	SPPostgresSidebarSection,
	SPPostgresSidebarTable,
	SPPostgresSidebarView,
	SPPostgresSidebarSequence,
	SPPostgresSidebarExtension
};

/// One outline row: a section header, or a table, view, sequence or extension. Rows are distinct objects, so a
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

@class SPPostgresSidebarController;

/// The outline, whose right-click menu depends on the row (see -[SPPostgresSidebarController menuForRow:]).
@interface SPPostgresSidebarOutlineView : NSOutlineView
@property (assign) SPPostgresSidebarController *menuSource;
@end

#pragma mark -

@interface SPPostgresSidebarController () <NSMenuItemValidation, NSSplitViewDelegate>

- (void)_buildView;
- (void)_buildButtonBarInView:(NSView *)container;
- (void)_updateBarButtons;
- (void)_applyStoredInfoPaneState;
- (void)_reloadSchemaPopup;
- (void)_runReload:(SPPostgresSidebarReloadKind)kind schema:(NSString *)schema cancelTitle:(NSString *)cancelTitle apply:(BOOL (^)(NSDictionary *read))apply completion:(void (^)(BOOL loaded))completion;
- (void)_reloadWithCatalog:(SPPostgresCatalog *)theCatalog emptyingFailedLists:(BOOL)emptying completion:(void (^)(BOOL loaded))completion;
- (void)_reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence holding:(BOOL)holding completion:(void (^)(BOOL loaded))completion;
- (BOOL)_applySchemaRead:(NSDictionary *)read;
- (void)_applyExtensionsRead:(NSDictionary *)read;
- (void)_rememberFailuresOfRead:(NSDictionary *)read;
- (void)_reloadOutline;
- (void)_updateSelectionFromOutline;
- (BOOL)_selectItemNamed:(NSString *)name inSection:(NSString *)sectionTitle;
- (NSInteger)_rowOfRelationNamed:(NSString *)name;
- (BOOL)_delegateAllowsSelectionChange;
- (void)_rememberError:(NSError *)error;
- (void)_beginReload;
- (void)_endReload;
- (SPPostgresSidebarItem *)_sectionNamed:(NSString *)title;
- (SPPostgresSidebarItem *)_menuTargetItem;
- (void)_addRelationItemsToMenu:(NSMenu *)menu;
- (NSMenuItem *)_addSequenceItemsToMenu:(NSMenu *)menu;
- (NSMenuItem *)_addExtensionItemsToMenu:(NSMenu *)menu;
- (NSMenu *)_newGearMenu;
- (void)_updateGearMenu;
- (BOOL)_menuItemIsInGear:(NSMenuItem *)item;
- (NSArray<NSString *> *)_relationTargetsForMenuItem:(id)sender;
- (SPPostgresSidebarItem *)_itemTargetForMenuItem:(id)sender;
- (void)_updateRelationItemsOfMenu:(NSMenu *)menu forTargets:(NSArray<NSString *> *)targets;

@end

@implementation SPPostgresSidebarController
{
	SPPostgresCatalog *catalog;
	NSArray *schemas;
	NSArray *sections; // TABLES, VIEWS, SEQUENCES, EXTENSIONS

	NSView *view;
	NSPopUpButton *schemaPopup;
	SPPostgresSidebarOutlineView *outlineView;
	NSMenu *tableMenu;
	NSMenu *sequenceMenu;
	NSMenuItem *deleteSequenceItem; // not retained; sequenceMenu's
	NSMenu *extensionMenu;
	NSMenuItem *dropExtensionItem; // not retained; extensionMenu's
	/// The gear's menus (the hidden image item, then tableMenu's, sequenceMenu's or extensionMenu's items; see
	/// -_updateGearMenu)
	NSMenu *gearRelationMenu;
	NSMenu *gearSequenceMenu;
	NSMenu *gearExtensionMenu;

	// The bottom bar and the information pane (see -_buildButtonBarInView:)
	NSButton *addButton;
	NSPopUpButton *gearButton;
	NSButton *refreshButton;
	NSButton *infoToggleButton;
	NSImageView *splitHandleView;
	SPSplitView *infoSplitView;
	NSView *infoPaneContainer;
	NSUserDefaults *defaults;
	BOOL actionsEnabled;

	BOOL reloading;

	/// Set by -invalidate: reloads still to come are dropped
	BOOL invalidated;
	/// Whether taskRunner is the default inline runner (made here, following the catalog's connection)
	BOOL ownsTaskRunner;

	/// Nesting of reloads (a catalog reload contains a schema reload): failures are reported once, at the end
	NSUInteger reloadDepth;
	BOOL reloadFailed;

	/// -reloadKeepingSelection tells the delegate once, at the end
	BOOL holdingSelectionChanges;

	/// The schema the latest schema reload asked for, until it completes (nil: none queued); see -pendingSchema
	NSString *pendingSchema;
	NSUInteger pendingSchemaToken;

	/// The selected tables and views, in display order (see -selectedRelationNames)
	NSArray *selectedRelationNames;
}

@synthesize selectedSchema;
@synthesize selectedTableName;
@synthesize selectedRelationNames;
@synthesize selectedSequenceName;
@synthesize sequenceMenu;
@synthesize selectedExtensionName;
@synthesize extensionMenu;
@synthesize lastError;
@synthesize delegate;
@synthesize tableMenu;
@synthesize taskRunner;
@synthesize addButton;
@synthesize gearButton;
@synthesize refreshButton;
@synthesize infoToggleButton;
@synthesize splitHandleView;
@synthesize infoSplitView;
@synthesize infoPaneContainer;
@synthesize defaults;
@synthesize actionsEnabled;

- (instancetype)initWithCatalog:(SPPostgresCatalog *)theCatalog
{
	if ((self = [super init])) {
		sections = [@[[SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarTables detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarViews detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarSequences detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarExtensions detail:nil kind:SPPostgresSidebarSection]] retain];
		schemas = [@[] retain];
		selectedRelationNames = [@[] retain];
		defaults = [[NSUserDefaults standardUserDefaults] retain];
		actionsEnabled = YES;

		[self _buildView];

		taskRunner = [[SPPostgresTaskRunner inlineRunnerWithConnection:[theCatalog connection]] retain];
		ownsTaskRunner = YES;
		[self reloadWithCatalog:theCatalog];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[catalog release];
	[taskRunner release];
	[schemas release];
	[sections release];
	[view release];
	[schemaPopup release];
	[outlineView release];
	[tableMenu release];
	[sequenceMenu release];
	[extensionMenu release];
	[gearRelationMenu release];
	[gearSequenceMenu release];
	[gearExtensionMenu release];
	[addButton release];
	[gearButton release];
	[refreshButton release];
	[infoToggleButton release];
	[splitHandleView release];
	[infoSplitView release];
	[infoPaneContainer release];
	[defaults release];
	[selectedSchema release];
	[pendingSchema release];
	[selectedTableName release];
	[selectedRelationNames release];
	[selectedSequenceName release];
	[selectedExtensionName release];
	[lastError release];

	[super dealloc];
}

/// Clears the targets of a menu's items and of its submenus' items.
static void SPPostgresSidebarClearMenuTargets(NSMenu *menu)
{
	for (NSMenuItem *item in [menu itemArray]) {
		[item setTarget:nil];
		if ([item submenu]) SPPostgresSidebarClearMenuTargets([item submenu]);
	}
}

- (void)invalidate
{
	invalidated = YES;
	delegate = nil;
	[outlineView setDelegate:nil];
	[outlineView setDataSource:nil];
	[outlineView setMenuSource:nil];
	[schemaPopup setTarget:nil];
	SPPostgresSidebarClearMenuTargets(tableMenu);
	SPPostgresSidebarClearMenuTargets(sequenceMenu);
	SPPostgresSidebarClearMenuTargets(extensionMenu);
	SPPostgresSidebarClearMenuTargets(gearRelationMenu);
	SPPostgresSidebarClearMenuTargets(gearSequenceMenu);
	SPPostgresSidebarClearMenuTargets(gearExtensionMenu);
	[addButton setTarget:nil];
	[gearButton setTarget:nil];
	[refreshButton setTarget:nil];
	[infoToggleButton setTarget:nil];
	[infoSplitView setDelegate:nil];
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

	// Outline below, over the information pane (infoSplitView), over the bottom bar
	CGFloat splitHeight = barY - SPPostgresSidebarButtonBarHeight;
	infoSplitView = [[SPSplitView alloc] initWithFrame:NSMakeRect(0, SPPostgresSidebarButtonBarHeight, NSWidth(frame), splitHeight)];
	[infoSplitView setVertical:NO];
	[infoSplitView setDividerStyle:NSSplitViewDividerStyleThin];
	[infoSplitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	CGFloat outlineHeight = splitHeight - SPPostgresSidebarInfoPaneHeight - [infoSplitView dividerThickness];
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), outlineHeight)] autorelease];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:NO];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setDrawsBackground:NO];

	outlineView = [[SPPostgresSidebarOutlineView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[outlineView setMenuSource:self];
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
	[column setResizingMask:NSTableColumnAutoresizingMask];
	[outlineView addTableColumn:column];
	[outlineView setOutlineTableColumn:column];
	[outlineView setHeaderView:nil];
	[outlineView setStyle:NSTableViewStyleSourceList];
	[outlineView setRowSizeStyle:NSTableViewRowSizeStyleSmall];
	[outlineView setFloatsGroupRows:NO];
	[outlineView setIndentationPerLevel:0];
	// Several tables and views at once (see -outlineView:selectionIndexesForProposedSelection:)
	[outlineView setAllowsMultipleSelection:YES];
	[outlineView setAllowsEmptySelection:YES];
	[outlineView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
	[outlineView setFocusRingType:NSFocusRingTypeNone];
	[outlineView setAutosaveExpandedItems:NO];
	[outlineView setDataSource:self];
	[outlineView setDelegate:self];
	[scrollView setDocumentView:outlineView];
	[outlineView sizeLastColumnToFit];

	// Right-click menu: MySQL's tables list menu (DBView.xib)
	tableMenu = [[NSMenu alloc] initWithTitle:@""];
	[self _addRelationItemsToMenu:tableMenu];
	[outlineView setMenu:tableMenu];

	// On a sequence, the SEQUENCES header or empty space (see -menuForRow:)
	sequenceMenu = [[NSMenu alloc] initWithTitle:@""];
	deleteSequenceItem = [self _addSequenceItemsToMenu:sequenceMenu];

	// On an extension, the EXTENSIONS header or empty space below it (see -menuForRow:)
	extensionMenu = [[NSMenu alloc] initWithTitle:@""];
	dropExtensionItem = [self _addExtensionItemsToMenu:extensionMenu];

	[infoSplitView addSubview:scrollView];

	// Not height-sizable: the pane keeps its height as the panel resizes (the outline takes the difference)
	infoPaneContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, outlineHeight + [infoSplitView dividerThickness], NSWidth(frame), SPPostgresSidebarInfoPaneHeight)];
	[infoPaneContainer setAutoresizingMask:NSViewWidthSizable];
	[infoSplitView addSubview:infoPaneContainer];
	[infoSplitView adjustSubviews];
	[container addSubview:infoSplitView];

	[self _buildButtonBarInView:container];

	// As -[SPTablesList awakeFromNib]: the pane collapses with the toggle, starting as last left
	[infoSplitView setCollapsibleSubviewIndex:1];
	[infoSplitView setToggleCollapseButton:infoToggleButton];
	[infoSplitView setDelegate:self];
	[self _applyStoredInfoPaneState];
}

/**
 * MySQL's table list bar (DBView.xib): an SPButtonBar along the bottom, with Add, the gear, Refresh and the info
 * toggle over it at the xib's frames, and the handle at its right end. The gear comes after the schema pop-up among the
 * panel's subviews.
 */
- (void)_buildButtonBarInView:(NSView *)container
{
	CGFloat width = NSWidth([container frame]);

	SPButtonBar *bar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresSidebarButtonBarHeight)] autorelease];
	[bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[container addSubview:bar];

	splitHandleView = [[NSImageView alloc] initWithFrame:NSMakeRect(width - 15, 0, 15, SPPostgresSidebarButtonBarHeight)];
	[splitHandleView setImage:[NSImage imageNamed:@"button_bar_handle"]];
	[splitHandleView setImageFrameStyle:NSImageFrameNone];
	[splitHandleView setImageAlignment:NSImageAlignLeft];
	[splitHandleView setRefusesFirstResponder:YES];
	[splitHandleView setEditable:NO];
	[splitHandleView setAutoresizingMask:NSViewMinXMargin];
	[container addSubview:splitHandleView];

	addButton = [[NSButton alloc] initWithFrame:NSMakeRect(-1, 0, 32, SPPostgresSidebarButtonBarHeight)];
	[addButton setButtonType:NSButtonTypeMomentaryChange];
	[addButton setBezelStyle:NSBezelStyleSmallSquare];
	[addButton setImage:[NSImage imageNamed:@"button_add"]];
	[addButton setAlternateImage:[NSImage imageNamed:@"button_add"]];
	[addButton setTitle:@""];
	[addButton setImagePosition:NSImageOnly];
	[addButton setToolTip:NSLocalizedString(@"Add new table", @"PostgreSQL sidebar: add table button tooltip")];
	[addButton setTarget:self];
	[addButton setAction:@selector(addTable:)];
	[addButton setAutoresizingMask:NSViewMaxXMargin];
	[container addSubview:addButton];

	gearButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(29, 0, 36, SPPostgresSidebarButtonBarHeight) pullsDown:YES];
	NSPopUpButtonCell *gearCell = [gearButton cell];
	[gearButton setBezelStyle:NSBezelStyleRegularSquare];
	[gearCell setArrowPosition:NSPopUpNoArrow];
	[gearCell setImagePosition:NSImageRight];
	[gearCell setAlignment:NSTextAlignmentCenter];
	[gearCell setUsesItemFromMenu:YES];
	[gearButton setFont:[NSFont menuFontOfSize:0]];
	// The right-click menus' items, each after the gear's own image item
	gearRelationMenu = [self _newGearMenu];
	[self _addRelationItemsToMenu:gearRelationMenu];
	gearSequenceMenu = [self _newGearMenu];
	[self _addSequenceItemsToMenu:gearSequenceMenu];
	gearExtensionMenu = [self _newGearMenu];
	[self _addExtensionItemsToMenu:gearExtensionMenu];
	[self _updateGearMenu];
	[gearButton setAutoresizingMask:NSViewMaxXMargin];
	[container addSubview:gearButton];

	refreshButton = [[NSButton alloc] initWithFrame:NSMakeRect(61, 0, 32, SPPostgresSidebarButtonBarHeight)];
	[refreshButton setButtonType:NSButtonTypeMomentaryChange];
	[refreshButton setBezelStyle:NSBezelStyleSmallSquare];
	[refreshButton setImage:[NSImage imageNamed:@"button_refresh"]];
	[refreshButton setTitle:@""];
	[refreshButton setImagePosition:NSImageOnly];
	[refreshButton setToolTip:NSLocalizedString(@"Refresh table list", @"PostgreSQL sidebar: refresh button tooltip")];
	[refreshButton setTarget:self];
	[refreshButton setAction:@selector(refreshTables:)];
	[refreshButton setAutoresizingMask:NSViewMaxXMargin];
	[container addSubview:refreshButton];

	infoToggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(92, -1, 32, 25)];
	[infoToggleButton setButtonType:NSButtonTypeToggle];
	[infoToggleButton setBezelStyle:NSBezelStyleTexturedRounded];
	[infoToggleButton setImage:[NSImage imageNamed:@"button_pane_hide"]];
	[infoToggleButton setAlternateImage:[NSImage imageNamed:@"button_pane_show"]];
	[infoToggleButton setTitle:@""];
	[infoToggleButton setImagePosition:NSImageOnly];
	[infoToggleButton setToolTip:NSLocalizedString(@"Toggle the visibility of the Information panel", @"PostgreSQL sidebar: info pane toggle tooltip")];
	[infoToggleButton setTarget:self];
	[infoToggleButton setAction:@selector(toggleInfoPane:)];
	[infoToggleButton setAutoresizingMask:NSViewMaxXMargin];
	[container addSubview:infoToggleButton];

	[self _updateBarButtons];
}

#pragma mark - Bottom bar

- (id<SPPostgresSidebarControllerDelegate>)delegate
{
	return delegate;
}

- (void)setDelegate:(id<SPPostgresSidebarControllerDelegate>)theDelegate
{
	delegate = theDelegate;
	[self _updateBarButtons];
}

- (void)setActionsEnabled:(BOOL)enabled
{
	actionsEnabled = enabled;
	[self _updateBarButtons];
}

/// Add, the gear and Refresh follow actionsEnabled (Add also needs the delegate's -sidebarAddTable:); the toggle is
/// always enabled.
- (void)_updateBarButtons
{
	[addButton setEnabled:actionsEnabled && [delegate respondsToSelector:@selector(sidebarAddTable:)]];
	[gearButton setEnabled:actionsEnabled];
	[refreshButton setEnabled:actionsEnabled];
	[infoToggleButton setEnabled:YES];
}

- (void)setDefaults:(NSUserDefaults *)theDefaults
{
	if (theDefaults == defaults) return;
	[defaults release];
	defaults = [theDefaults retain];
	[self _applyStoredInfoPaneState];
}

/// Collapses or expands the information pane (without animating) as SPTableInformationPanelCollapsed in defaults says.
- (void)_applyStoredInfoPaneState
{
	[infoSplitView setCollapsibleSubviewCollapsed:[[defaults objectForKey:SPTableInformationPanelCollapsed] boolValue] animate:NO];
}

- (IBAction)addTable:(id)sender
{
	if (!actionsEnabled) return;
	if ([delegate respondsToSelector:@selector(sidebarAddTable:)]) [delegate sidebarAddTable:self];
}

- (IBAction)refreshTables:(id)sender
{
	if (invalidated) return;
	if ([delegate respondsToSelector:@selector(sidebarRefresh:)]) [delegate sidebarRefresh:self];
	else [self reloadKeepingSelection];
}

- (IBAction)toggleInfoPane:(id)sender
{
	[infoSplitView toggleCollapse:sender];

	[defaults setObject:[NSNumber numberWithBool:[infoSplitView isCollapsibleSubviewCollapsed]] forKey:SPTableInformationPanelCollapsed];
}

/// The information pane keeps its height as the panel resizes; the outline takes the difference. While the pane is
/// collapsed or animating (wrapped by the split view), the split view lays it out itself.
- (void)splitView:(NSSplitView *)theSplitView resizeSubviewsWithOldSize:(NSSize)oldSize
{
	NSArray *subviews = [theSplitView subviews];
	if (theSplitView != infoSplitView || [infoSplitView isCollapsibleSubviewCollapsed] || [subviews count] != 2 || [subviews lastObject] != infoPaneContainer) {
		[theSplitView adjustSubviews];
		return;
	}

	NSRect bounds = [theSplitView bounds];
	CGFloat paneHeight = MIN(SPPostgresSidebarInfoPaneHeight, NSHeight(bounds));
	CGFloat outlineHeight = MAX(0, NSHeight(bounds) - paneHeight - [theSplitView dividerThickness]);
	[[subviews objectAtIndex:0] setFrame:NSMakeRect(0, 0, NSWidth(bounds), outlineHeight)];
	[infoPaneContainer setFrame:NSMakeRect(0, NSHeight(bounds) - paneHeight, NSWidth(bounds), paneHeight)];
}

/// As -[SPTablesList splitView:effectiveRect:…]: the information pane isn't resized by dragging its divider.
- (NSRect)splitView:(NSSplitView *)theSplitView effectiveRect:(NSRect)proposedEffectiveRect forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex
{
	if (theSplitView == infoSplitView) return NSZeroRect;
	return proposedEffectiveRect;
}

#pragma mark - Loading

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	if (runner == taskRunner) return;
	[taskRunner release];
	taskRunner = [runner retain];
	ownsTaskRunner = NO;
	// A schema reload queued on the previous runner never completes now
	pendingSchemaToken++;
	[pendingSchema release];
	pendingSchema = nil;
}

// Every reload follows the same steps. On the main thread: copies of what it starts from (the schema asked for or
// shown, the schemas listed). On the runner's thread: SPPostgresSidebarRead, which touches nothing of this controller.
// Back on the main thread: dropped after -invalidate; a cancelled one keeps everything (the pop-up back to the shown
// schema) and reports nothing; else what it read is applied as the synchronous reload applied it (a failed list keeps
// what it showed, the first error reported once), then the caller's completion. Reloads are applied in the order they
// were asked for, each one in full: a later one doesn't make an earlier one's result stale, as each applies what it
// read on top of the one before (as calling them one after the other did).

/// cancelTitle nil: the reload has no Cancel button (cancelAll still cancels it); a cancel changes nothing.
- (void)_runReload:(SPPostgresSidebarReloadKind)kind schema:(NSString *)schema cancelTitle:(NSString *)cancelTitle apply:(BOOL (^)(NSDictionary *read))apply completion:(void (^)(BOOL loaded))completion
{
	[self _runReload:kind schema:schema knownSchemas:schemas cancelTitle:cancelTitle apply:apply cancelApply:nil completion:completion];
}

/**
 * The reload task. knownSchemas: the schemas a catalog reload falls back on for its default schema when they can't be
 * listed. cancelApply (nil: nothing changes) is applied instead of `apply` when the reload is cancelled.
 */
- (void)_runReload:(SPPostgresSidebarReloadKind)kind schema:(NSString *)schema knownSchemas:(NSArray *)known cancelTitle:(NSString *)cancelTitle apply:(BOOL (^)(NSDictionary *read))apply cancelApply:(void (^)(void))cancelApply completion:(void (^)(BOOL loaded))completion
{
	if (invalidated) return;

	NSString *theSchema = [[schema copy] autorelease];
	NSArray *knownSchemas = [[known copy] autorelease];

	[taskRunner runTaskWithDescription:NSLocalizedString(@"Reloading...", @"Reloading table task string") cancelTitle:cancelTitle work:^id(PGPostgresConnection *connection, NSError **error) {
		return SPPostgresSidebarRead(connection, kind, theSchema, knownSchemas);
	} completion:^(id result, NSError *error, BOOL cancelled) {
		if (invalidated) return;

		BOOL loaded = NO;
		if (result) {
			loaded = apply(result);
		}
		else if (cancelled && cancelApply) {
			cancelApply();
		}
		else if (cancelled) {
			// Nothing changes: the pop-up (which may show the schema the user chose) goes back to the shown schema
			[self _reloadSchemaPopup];
		}
		else {
			// The work itself failed (it reports query failures in its result): as a failed reload
			[self _beginReload];
			[self _rememberError:error];
			[self _reloadSchemaPopup];
			[self _endReload];
		}

		if (completion) completion(loaded);
	}];
}

- (void)reloadWithCatalog:(SPPostgresCatalog *)theCatalog
{
	[self reloadWithCatalog:theCatalog completion:nil];
}

- (void)reloadWithCatalog:(SPPostgresCatalog *)theCatalog completion:(void (^)(BOOL loaded))completion
{
	[self _reloadWithCatalog:theCatalog emptyingFailedLists:NO completion:completion];
}

- (void)reloadWithNewCatalog:(SPPostgresCatalog *)theCatalog completion:(void (^)(BOOL loaded))completion
{
	[self _reloadWithCatalog:theCatalog emptyingFailedLists:YES completion:completion];
}

/// emptying: another database's lists (-reloadWithNewCatalog:completion:): not cancellable, and none of the lists shown
/// before is kept (a list that fails, or a cancel, leaves it empty).
- (void)_reloadWithCatalog:(SPPostgresCatalog *)theCatalog emptyingFailedLists:(BOOL)emptying completion:(void (^)(BOOL loaded))completion
{
	if (theCatalog != catalog) {
		[catalog release];
		catalog = [theCatalog retain];
	}
	// The default runner follows the catalog to its connection (another database's)
	if (ownsTaskRunner && [taskRunner connection] != [catalog connection]) {
		[taskRunner release];
		taskRunner = [[SPPostgresTaskRunner inlineRunnerWithConnection:[catalog connection]] retain];
	}

	BOOL (^apply)(NSDictionary *) = ^BOOL(NSDictionary *read) {
		[self _beginReload];
		[self _rememberFailuresOfRead:read];

		// Schemas that can't be listed keep the ones that were (none for another database)
		NSArray *names = [read objectForKey:@"schemas"];
		if (names || emptying) {
			[schemas release];
			schemas = [(names ?: @[]) copy];
		}

		// Extensions that can't be listed keep the ones that were (none for another database)
		if (emptying && ![read objectForKey:@"extensions"]) {
			[self _applyExtensionsRead:@{@"extensions" : @[]}];
		}
		[self _applyExtensionsRead:read];

		// Nor does a selected extension (another database's)
		[selectedExtensionName release], selectedExtensionName = nil;
		[self _updateGearMenu];

		// The default schema of this database (the previous database's schema doesn't carry over); for another
		// database, lists that can't be read are shown empty, with no schema
		BOOL listsRead = [read objectForKey:@"schema"] && [read objectForKey:@"tables"] && [read objectForKey:@"views"] && [read objectForKey:@"sequences"];
		[self _applySchemaRead:(emptying && !listsRead) ? @{} : read];

		BOOL loaded = ![[read objectForKey:@"failures"] count];
		[self _endReload];
		return loaded;
	};

	// Another database: its default schema is never one of the previous database's schemas
	[self _runReload:SPPostgresSidebarReloadCatalog schema:nil knownSchemas:(emptying ? @[] : schemas)
		 cancelTitle:(emptying ? nil : NSLocalizedString(@"Cancel", @"cancel button")) apply:apply cancelApply:(emptying ? ^{
		// Cancelled with everything queued: the previous database's lists go all the same (nothing reported)
		apply(@{@"failures" : @[]});
	} : nil) completion:completion];
}

- (void)reloadKeepingSelection
{
	[self reloadKeepingSelection:nil];
}

- (void)reloadKeepingSelection:(void (^)(BOOL loaded))completion
{
	// The schema shown now is read again (if it is still there); the selection kept is the one shown when applied. Another
	// schema shown by then (a schema reload applied in between): this result is dropped, the lists shown are fresh.
	NSString *queuedSchema = [[selectedSchema copy] autorelease];
	[self _runReload:SPPostgresSidebarReloadKeeping schema:selectedSchema cancelTitle:NSLocalizedString(@"Cancel", @"cancel button") apply:^BOOL(NSDictionary *read) {
		if (queuedSchema != selectedSchema && ![queuedSchema isEqualToString:selectedSchema]) return YES;
		NSString *previousSchema = [[selectedSchema copy] autorelease];
		NSArray *relations = [[selectedRelationNames copy] autorelease];
		NSString *sequence = [[selectedSequenceName copy] autorelease];
		NSString *extension = [[selectedExtensionName copy] autorelease];

		[self _beginReload];
		[self _rememberFailuresOfRead:read];

		NSArray *names = [read objectForKey:@"schemas"];
		if (names) {
			[schemas release];
			schemas = [names copy];
		}

		[self _applyExtensionsRead:read];

		holdingSelectionChanges = YES;
		[self _applySchemaRead:read];
		// The same schema (not the default one standing in for a schema that is gone): its tables and views (those
		// still listed) or sequence again
		if ([relations count] && [previousSchema isEqualToString:selectedSchema]) [self selectRelationsNamed:relations];
		if (sequence && [previousSchema isEqualToString:selectedSchema]) [self selectSequenceNamed:sequence];
		// An extension is the database's, whatever the schema
		if (extension) [self selectExtensionNamed:extension];
		holdingSelectionChanges = NO;

		BOOL sameSchema = (previousSchema == selectedSchema) || [previousSchema isEqualToString:selectedSchema];
		BOOL sameRelations = [relations isEqualToArray:selectedRelationNames];
		BOOL sameSequence = (sequence == selectedSequenceName) || [sequence isEqualToString:selectedSequenceName];
		BOOL sameExtension = (extension == selectedExtensionName) || [extension isEqualToString:selectedExtensionName];
		if (!sameSchema || !sameRelations || !sameSequence || !sameExtension) [delegate sidebarSelectionDidChange:self];

		BOOL loaded = ![[read objectForKey:@"failures"] count];
		[self _endReload];
		return loaded;
	} completion:completion];
}

- (void)reloadSchema:(NSString *)schema
{
	[self _reloadSchema:schema selectingSequence:nil holding:NO completion:nil];
}

- (void)reloadSchema:(NSString *)schema completion:(void (^)(BOOL loaded))completion
{
	[self _reloadSchema:schema selectingSequence:nil holding:NO completion:completion];
}

- (void)reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence
{
	[self _reloadSchema:schema selectingSequence:sequence holding:YES completion:nil];
}

- (void)reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence completion:(void (^)(BOOL loaded))completion
{
	[self _reloadSchema:schema selectingSequence:sequence holding:YES completion:completion];
}

/**
 * Shows schema's lists. holding: the delegate hears of one selection change at the end (none if the selection ends
 * up the same), after `sequence` is selected; else of the reload's selection change, as -reloadSchema: does.
 */
- (void)_reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence holding:(BOOL)holding completion:(void (^)(BOOL loaded))completion
{
	NSString *theSequence = [[sequence copy] autorelease];
	// A reload of the schema shown, to select a sequence in it (a rename, an add): dropped if another schema is shown
	// by the time it applies (that schema's lists are fresh, and the sequence isn't in it)
	NSString *queuedSchema = [[selectedSchema copy] autorelease];
	BOOL reloadingShownSchema = holding && ((queuedSchema == schema) || [queuedSchema isEqualToString:schema]);

	NSUInteger token = ++pendingSchemaToken;
	[pendingSchema release];
	pendingSchema = [schema copy];
	void (^theCompletion)(BOOL) = [[completion copy] autorelease];

	[self _runReload:SPPostgresSidebarReloadSchema schema:schema cancelTitle:NSLocalizedString(@"Cancel", @"cancel button") apply:^BOOL(NSDictionary *read) {
		if (reloadingShownSchema && queuedSchema != selectedSchema && ![queuedSchema isEqualToString:selectedSchema]) return YES;
		NSString *previousSchema = [[selectedSchema copy] autorelease];
		NSArray *previousRelations = [[selectedRelationNames copy] autorelease];
		NSString *previousSequence = [[selectedSequenceName copy] autorelease];
		NSString *previousExtension = [[selectedExtensionName copy] autorelease];

		BOOL wasHolding = holdingSelectionChanges;
		if (holding) holdingSelectionChanges = YES;

		[self _beginReload];
		[self _rememberFailuresOfRead:read];
		BOOL loaded = [self _applySchemaRead:read];
		[self _endReload];

		if (!holding) return loaded;

		if (theSequence) [self selectSequenceNamed:theSequence];
		holdingSelectionChanges = wasHolding;
		if (wasHolding) return loaded;

		BOOL sameSchema = (previousSchema == selectedSchema) || [previousSchema isEqualToString:selectedSchema];
		BOOL sameRelations = [previousRelations isEqualToArray:selectedRelationNames];
		BOOL sameSequence = (previousSequence == selectedSequenceName) || [previousSequence isEqualToString:selectedSequenceName];
		BOOL sameExtension = (previousExtension == selectedExtensionName) || [previousExtension isEqualToString:selectedExtensionName];
		if (!sameSchema || !sameRelations || !sameSequence || !sameExtension) [delegate sidebarSelectionDidChange:self];
		return loaded;
	} completion:^(BOOL loaded) {
		if (token == pendingSchemaToken) {
			[pendingSchema release];
			pendingSchema = nil;
		}
		if (theCompletion) theCompletion(loaded);
	}];
}

- (NSString *)pendingSchema
{
	return [[pendingSchema retain] autorelease];
}

/**
 * Shows the schema a reload read (none: empty lists) and selects it in the pop-up, clearing the selection of a table,
 * view or sequence (a selected extension stays if still listed). YES if its lists were read; else the schema, lists
 * and selection stay as they were (the extensions shown afresh if the reload read them).
 */
- (BOOL)_applySchemaRead:(NSDictionary *)read
{
	NSString *schema = [read objectForKey:@"schema"];
	NSArray *tableNames = [read objectForKey:@"tables"];
	NSArray *viewNames = [read objectForKey:@"views"];
	NSArray *sequenceNames = [read objectForKey:@"sequences"];
	BOOL loaded = !schema || (tableNames && viewNames && sequenceNames);

	if (loaded) {
		if (selectedSchema != schema) {
			[selectedSchema release];
			selectedSchema = [schema copy];
		}
		[selectedTableName release], selectedTableName = nil;
		[selectedRelationNames release], selectedRelationNames = [@[] retain];
		[selectedSequenceName release], selectedSequenceName = nil;
		// An extension is the database's, not the schema's: it stays selected (if still listed) below
		NSString *keptExtension = [[selectedExtensionName copy] autorelease];
		[selectedExtensionName release], selectedExtensionName = nil;

		SPPostgresSidebarItem *tables = [self _sectionNamed:SPPostgresSidebarTables];
		SPPostgresSidebarItem *views = [self _sectionNamed:SPPostgresSidebarViews];
		SPPostgresSidebarItem *sequences = [self _sectionNamed:SPPostgresSidebarSequences];
		[[tables children] removeAllObjects];
		[[views children] removeAllObjects];
		[[sequences children] removeAllObjects];

		for (NSString *name in tableNames) {
			[[tables children] addObject:[SPPostgresSidebarItem itemWithTitle:name detail:nil kind:SPPostgresSidebarTable]];
		}
		for (NSString *name in viewNames) {
			[[views children] addObject:[SPPostgresSidebarItem itemWithTitle:name detail:nil kind:SPPostgresSidebarView]];
		}
		for (NSString *name in sequenceNames) {
			[[sequences children] addObject:[SPPostgresSidebarItem itemWithTitle:name detail:nil kind:SPPostgresSidebarSequence]];
		}

		[self _reloadSchemaPopup];
		[self _reloadOutline];
		if (keptExtension) {
			BOOL wasHolding = holdingSelectionChanges;
			holdingSelectionChanges = YES;
			[self _selectItemNamed:keptExtension inSection:SPPostgresSidebarExtensions];
			holdingSelectionChanges = wasHolding;
		}
		[self _updateGearMenu];

		if (!holdingSelectionChanges) [delegate sidebarSelectionDidChange:self];
	}
	else {
		// Keep the schema, lists and selection that were shown; the popup goes back to the shown schema
		[self _reloadSchemaPopup];
		// A catalog reload may have reloaded the extensions: show them, leaving the table selection
		[outlineView reloadItem:[self _sectionNamed:SPPostgresSidebarExtensions] reloadChildren:YES];
		// Its rows are new: a selected extension still listed stays selected; one that is gone leaves nothing selected
		if (selectedExtensionName && ![self selectExtensionNamed:selectedExtensionName]) {
			[outlineView deselectAll:nil];
			[self _updateSelectionFromOutline];
		}
	}

	return loaded;
}

/// The installed extensions a reload read; if it couldn't, the ones that were listed stay.
- (void)_applyExtensionsRead:(NSDictionary *)read
{
	NSArray *installed = [read objectForKey:@"extensions"];
	if (!installed) return;

	SPPostgresSidebarItem *extensions = [self _sectionNamed:SPPostgresSidebarExtensions];
	[[extensions children] removeAllObjects];
	for (NSDictionary *extension in installed) {
		[[extensions children] addObject:[SPPostgresSidebarItem itemWithTitle:[extension objectForKey:@"name"] detail:[extension objectForKey:@"version"] kind:SPPostgresSidebarExtension]];
	}
}

/// A reload's failed queries, in the order they ran (the first one is reported).
- (void)_rememberFailuresOfRead:(NSDictionary *)read
{
	for (id failure in [read objectForKey:@"failures"]) {
		[self _rememberError:[failure isKindOfClass:[NSError class]] ? failure : nil];
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

- (BOOL)selectRelationsNamed:(NSArray<NSString *> *)names
{
	if (![names count]) return [self selectTableNamed:nil];

	NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
	for (NSString *name in names) {
		NSInteger row = [self _rowOfRelationNamed:name];
		if (row >= 0) [rows addIndex:(NSUInteger)row];
	}
	if (![rows count]) return NO;

	[outlineView selectRowIndexes:rows byExtendingSelection:NO];
	[outlineView scrollRowToVisible:(NSInteger)[rows firstIndex]];
	[self _updateSelectionFromOutline];
	return [rows count] == [names count];
}

/// The outline row of a table or view of the selected schema, or -1.
- (NSInteger)_rowOfRelationNamed:(NSString *)name
{
	for (NSString *sectionTitle in @[SPPostgresSidebarTables, SPPostgresSidebarViews]) {
		for (SPPostgresSidebarItem *item in [[self _sectionNamed:sectionTitle] children]) {
			if ([[item title] isEqualToString:name]) return [outlineView rowForItem:item];
		}
	}
	return -1;
}

- (BOOL)relationIsView:(NSString *)name
{
	return [[self itemTitlesInSection:SPPostgresSidebarViews] containsObject:name];
}

- (NSArray<NSString *> *)actionTargetRelationNames
{
	NSInteger row = [outlineView clickedRow];
	if (row >= 0 && ![[outlineView selectedRowIndexes] containsIndex:(NSUInteger)row]) {
		SPPostgresSidebarItem *item = [outlineView itemAtRow:row];
		BOOL isRelation = ([item kind] == SPPostgresSidebarTable || [item kind] == SPPostgresSidebarView);
		return isRelation ? @[[item title]] : @[];
	}
	return [self selectedRelationNames];
}

- (NSArray<NSString *> *)selectedRelationNames
{
	return [[selectedRelationNames retain] autorelease];
}

- (BOOL)selectSequenceNamed:(NSString *)name
{
	if (!name) return [self selectTableNamed:nil];
	return [self _selectItemNamed:name inSection:SPPostgresSidebarSequences];
}

- (BOOL)selectExtensionNamed:(NSString *)name
{
	if (!name) return [self selectTableNamed:nil];
	return [self _selectItemNamed:name inSection:SPPostgresSidebarExtensions];
}

/// Selects the row of a section's item; NO if it isn't listed.
- (BOOL)_selectItemNamed:(NSString *)name inSection:(NSString *)sectionTitle
{
	for (SPPostgresSidebarItem *item in [[self _sectionNamed:sectionTitle] children]) {
		if (![[item title] isEqualToString:name]) continue;

		NSInteger row = [outlineView rowForItem:item];
		if (row < 0) return NO;
		[outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[outlineView scrollRowToVisible:row];
		[self _updateSelectionFromOutline];
		return YES;
	}
	return NO;
}

/// Several rows are tables and views (see -outlineView:selectionIndexesForProposedSelection:): selectedTableName is nil
/// for them, as for no selection.
- (void)_updateSelectionFromOutline
{
	NSIndexSet *rows = [outlineView selectedRowIndexes];
	NSMutableArray *relations = [NSMutableArray arrayWithCapacity:[rows count]];
	[rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
		SPPostgresSidebarItem *selected = [outlineView itemAtRow:(NSInteger)row];
		if ([selected kind] == SPPostgresSidebarTable || [selected kind] == SPPostgresSidebarView) [relations addObject:[selected title]];
	}];

	SPPostgresSidebarItem *item = ([rows count] == 1) ? [outlineView itemAtRow:(NSInteger)[rows firstIndex]] : nil;
	NSString *name = ([item kind] == SPPostgresSidebarTable || [item kind] == SPPostgresSidebarView) ? [item title] : nil;
	NSString *sequence = ([item kind] == SPPostgresSidebarSequence) ? [item title] : nil;
	NSString *extension = ([item kind] == SPPostgresSidebarExtension) ? [item title] : nil;

	BOOL sameRelations = [relations isEqualToArray:selectedRelationNames];
	BOOL sameSequence = (sequence == selectedSequenceName || [sequence isEqualToString:selectedSequenceName]);
	BOOL sameExtension = (extension == selectedExtensionName || [extension isEqualToString:selectedExtensionName]);
	if (sameRelations && sameSequence && sameExtension) return;

	[selectedTableName release];
	selectedTableName = [name copy];
	[selectedRelationNames release];
	selectedRelationNames = [relations copy];
	[selectedSequenceName release];
	selectedSequenceName = [sequence copy];
	[selectedExtensionName release];
	selectedExtensionName = [extension copy];
	[self _updateGearMenu];

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

/// Adds an item for target, with a tooltip (none if nil).
static NSMenuItem *SPPostgresSidebarAddMenuItem(NSMenu *menu, NSString *title, SEL action, NSString *toolTip, id target)
{
	NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
	if (toolTip) [item setToolTip:toolTip];
	[item setTarget:target];
	return item;
}

/// MySQL's table list gear and right-click items, in its order (DBView.xib), titled for one table (see
/// -_updateRelationItemsOfMenu:forTargets:).
- (void)_addRelationItemsToMenu:(NSMenu *)menu
{
	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Rename Table…", @"PostgreSQL sidebar: rename table menu item"), @selector(renameTable:), NSLocalizedString(@"Rename the selected item", @"PostgreSQL sidebar: rename table menu item tooltip"), self);
	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Duplicate Table…", @"PostgreSQL sidebar: duplicate table menu item"), @selector(duplicateTable:), NSLocalizedString(@"Duplicate the selected item", @"PostgreSQL sidebar: duplicate table menu item tooltip"), self);
	NSMenuItem *separator = [NSMenuItem separatorItem];
	[separator setTag:SPPostgresSidebarRenameSeparatorTag];
	[menu addItem:separator];

	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Truncate Table", @"PostgreSQL sidebar: truncate table menu item"), @selector(truncateTables:), NSLocalizedString(@"Delete all records of selected table(s)", @"PostgreSQL sidebar: truncate table menu item tooltip"), self);
	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Delete Table", @"PostgreSQL sidebar: delete table menu item"), @selector(removeRelations:), NSLocalizedString(@"Remove the selected item(s)", @"PostgreSQL sidebar: delete table menu item tooltip"), self);
	separator = [NSMenuItem separatorItem];
	[separator setTag:SPPostgresSidebarOpenSeparatorTag];
	[menu addItem:separator];

	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Open Table in New Tab", @"PostgreSQL sidebar: open table in new tab menu item"), @selector(openRelationInNewTab:), nil, self);
	NSMenuItem *newWindow = SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Open Table in New Window", @"PostgreSQL sidebar: open table in new window menu item"), @selector(openRelationInNewWindow:), nil, self);
	[newWindow setKeyEquivalentModifierMask:NSEventModifierFlagOption];
	[newWindow setAlternate:YES];
	[menu addItem:[NSMenuItem separatorItem]];

	NSMenuItem *export = [menu addItemWithTitle:NSLocalizedString(@"Export", @"PostgreSQL sidebar: export menu item") action:NULL keyEquivalent:@""];
	NSMenu *exportMenu = [[[NSMenu alloc] initWithTitle:NSLocalizedString(@"Export", @"PostgreSQL sidebar: export menu item")] autorelease];
	NSMenuItem *sqlDump = SPPostgresSidebarAddMenuItem(exportMenu, NSLocalizedString(@"As SQL dump…", @"PostgreSQL sidebar: export as SQL dump menu item"), @selector(exportRelations:), nil, self);
	[sqlDump setTag:0];
	NSMenuItem *csv = SPPostgresSidebarAddMenuItem(exportMenu, NSLocalizedString(@"As CSV file…", @"PostgreSQL sidebar: export as CSV menu item"), @selector(exportRelations:), nil, self);
	[csv setTag:1];
	[menu setSubmenu:exportMenu forItem:export];
	[menu addItem:[NSMenuItem separatorItem]];

	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Show Create Table Syntax…", @"PostgreSQL sidebar: show create table syntax menu item"), @selector(showCreateSyntax:), nil, self);
	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Copy Create Table Syntax", @"PostgreSQL sidebar: copy create table syntax menu item"), @selector(copyCreateSyntax:), nil, self);
}

/// "Add Sequence…" and "Delete Sequence…" (returned).
- (NSMenuItem *)_addSequenceItemsToMenu:(NSMenu *)menu
{
	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Add Sequence…", @"PostgreSQL sidebar: add sequence menu item"), @selector(addSequence:), NSLocalizedString(@"Add a sequence to the selected schema", @"PostgreSQL sidebar: add sequence menu item tooltip"), self);
	return SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Delete Sequence…", @"PostgreSQL sidebar: delete sequence menu item"), @selector(deleteSequence:), NSLocalizedString(@"Delete the selected sequence", @"PostgreSQL sidebar: delete sequence menu item tooltip"), self);
}

/// "Install Extension…" and "Drop Extension…" (returned).
- (NSMenuItem *)_addExtensionItemsToMenu:(NSMenu *)menu
{
	SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Install Extension…", @"PostgreSQL sidebar: install extension menu item"), @selector(installExtension:), NSLocalizedString(@"Install an extension the server offers into this database", @"PostgreSQL sidebar: install extension menu item tooltip"), self);
	return SPPostgresSidebarAddMenuItem(menu, NSLocalizedString(@"Drop Extension…", @"PostgreSQL sidebar: drop extension menu item"), @selector(dropExtension:), NSLocalizedString(@"Drop the selected extension", @"PostgreSQL sidebar: drop extension menu item tooltip"), self);
}

/// A menu for the gear (retained): its item 0, the hidden button_action image item the pull-down shows (DBView.xib).
- (NSMenu *)_newGearMenu
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
	NSMenuItem *imageItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
	[imageItem setImage:[NSImage imageNamed:@"button_action"]];
	[imageItem setState:NSControlStateValueOn];
	[imageItem setHidden:YES];
	return menu;
}

/// The gear has the menu -menuForRow: gives the selection: the sequence items for a sequence, the extension items for
/// an extension, else the table items.
- (void)_updateGearMenu
{
	NSMenu *menu = gearRelationMenu;
	if (selectedSequenceName) menu = gearSequenceMenu;
	else if (selectedExtensionName) menu = gearExtensionMenu;
	if (menu && [gearButton menu] != menu) [gearButton setMenu:menu];
}

/// Whether item is one of the gear's (or of its Export submenu).
- (BOOL)_menuItemIsInGear:(NSMenuItem *)item
{
	if (![item isKindOfClass:[NSMenuItem class]]) return NO;
	NSMenu *menu = [item menu];
	while ([menu supermenu]) menu = [menu supermenu];
	return menu && (menu == gearRelationMenu || menu == gearSequenceMenu || menu == gearExtensionMenu);
}

/// The tables and views a relation item acts on: the gear's, the selection (a row clicked earlier doesn't count); the
/// right-click menu's, actionTargetRelationNames.
- (NSArray<NSString *> *)_relationTargetsForMenuItem:(id)sender
{
	return [self _menuItemIsInGear:sender] ? [self selectedRelationNames] : [self actionTargetRelationNames];
}

/// The sequence or extension an item acts on: the gear's, the selected row's; the right-click menu's, -_menuTargetItem.
- (SPPostgresSidebarItem *)_itemTargetForMenuItem:(id)sender
{
	if (![self _menuItemIsInGear:sender]) return [self _menuTargetItem];
	NSIndexSet *rows = [outlineView selectedRowIndexes];
	return ([rows count] == 1) ? [outlineView itemAtRow:(NSInteger)[rows firstIndex]] : nil;
}

/**
 * Titles and shows the relation items of menu for targets, as -[SPTablesList setSelectionState:]: one table or view
 * names its kind; several hide Rename, Duplicate and the Open items (and the separators that go with them) and use
 * the plural titles. Truncate is hidden unless every target is a table.
 */
- (void)_updateRelationItemsOfMenu:(NSMenu *)menu forTargets:(NSArray<NSString *> *)targets
{
	NSUInteger count = [targets count];
	NSUInteger views = 0;
	for (NSString *name in targets) {
		if ([self relationIsView:name]) views++;
	}
	BOOL one = (count == 1);
	BOOL several = (count > 1);
	BOOL oneView = one && views == 1;

	for (NSMenuItem *item in [menu itemArray]) {
		SEL action = [item action];
		if ([item isSeparatorItem]) {
			if ([item tag] == SPPostgresSidebarRenameSeparatorTag || [item tag] == SPPostgresSidebarOpenSeparatorTag) [item setHidden:!one];
		}
		else if (action == @selector(renameTable:)) {
			[item setTitle:oneView ? NSLocalizedString(@"Rename View…", @"PostgreSQL sidebar: rename view menu item") : NSLocalizedString(@"Rename Table…", @"PostgreSQL sidebar: rename table menu item")];
			[item setHidden:!one];
		}
		else if (action == @selector(duplicateTable:)) {
			[item setTitle:oneView ? NSLocalizedString(@"Duplicate View…", @"PostgreSQL sidebar: duplicate view menu item") : NSLocalizedString(@"Duplicate Table…", @"PostgreSQL sidebar: duplicate table menu item")];
			[item setHidden:!one];
		}
		else if (action == @selector(truncateTables:)) {
			[item setTitle:several ? NSLocalizedString(@"Truncate Tables", @"PostgreSQL sidebar: truncate tables menu item") : NSLocalizedString(@"Truncate Table", @"PostgreSQL sidebar: truncate table menu item")];
			[item setHidden:(views > 0)];
		}
		else if (action == @selector(removeRelations:)) {
			NSString *title;
			if (several) {
				if (!views) title = NSLocalizedString(@"Delete Tables", @"PostgreSQL sidebar: delete tables menu item");
				else if (views == count) title = NSLocalizedString(@"Delete Views", @"PostgreSQL sidebar: delete views menu item");
				else title = NSLocalizedString(@"Delete Items", @"PostgreSQL sidebar: delete items menu item");
			}
			else {
				title = oneView ? NSLocalizedString(@"Delete View", @"PostgreSQL sidebar: delete view menu item") : NSLocalizedString(@"Delete Table", @"PostgreSQL sidebar: delete table menu item");
			}
			[item setTitle:title];
		}
		else if (action == @selector(openRelationInNewTab:)) {
			[item setTitle:oneView ? NSLocalizedString(@"Open View in New Tab", @"PostgreSQL sidebar: open view in new tab menu item") : NSLocalizedString(@"Open Table in New Tab", @"PostgreSQL sidebar: open table in new tab menu item")];
			[item setHidden:!one];
		}
		else if (action == @selector(openRelationInNewWindow:)) {
			[item setTitle:oneView ? NSLocalizedString(@"Open View in New Window", @"PostgreSQL sidebar: open view in new window menu item") : NSLocalizedString(@"Open Table in New Window", @"PostgreSQL sidebar: open table in new window menu item")];
			[item setHidden:!one];
		}
		else if (action == @selector(showCreateSyntax:)) {
			NSString *title;
			if (several) title = NSLocalizedString(@"Show Create Syntaxes…", @"PostgreSQL sidebar: show create syntaxes menu item");
			else if (oneView) title = NSLocalizedString(@"Show Create View Syntax…", @"PostgreSQL sidebar: show create view syntax menu item");
			else title = NSLocalizedString(@"Show Create Table Syntax…", @"PostgreSQL sidebar: show create table syntax menu item");
			[item setTitle:title];
		}
		else if (action == @selector(copyCreateSyntax:)) {
			NSString *title;
			if (several) title = NSLocalizedString(@"Copy Create Syntaxes", @"PostgreSQL sidebar: copy create syntaxes menu item");
			else if (oneView) title = NSLocalizedString(@"Copy Create View Syntax", @"PostgreSQL sidebar: copy create view syntax menu item");
			else title = NSLocalizedString(@"Copy Create Table Syntax", @"PostgreSQL sidebar: copy create table syntax menu item");
			[item setTitle:title];
		}
	}
}

- (NSMenu *)menuForRow:(NSInteger)row
{
	SPPostgresSidebarItem *item = (row >= 0 && row < [outlineView numberOfRows]) ? [outlineView itemAtRow:row] : nil;
	BOOL onSequence = ([item kind] == SPPostgresSidebarSequence);
	BOOL onSequencesHeader = ([item kind] == SPPostgresSidebarSection && [[self _sectionNamed:SPPostgresSidebarSequences] isEqual:item]);
	BOOL onExtension = ([item kind] == SPPostgresSidebarExtension);
	BOOL onExtensionsHeader = ([item kind] == SPPostgresSidebarSection && [[self _sectionNamed:SPPostgresSidebarExtensions] isEqual:item]);

	if (onSequence || onSequencesHeader) {
		// Delete acts on a sequence only
		[deleteSequenceItem setHidden:!onSequence];
		return sequenceMenu;
	}

	// Empty space is below EXTENSIONS, the last section
	if (!item || onExtension || onExtensionsHeader) {
		// Drop acts on an extension only
		[dropExtensionItem setHidden:!onExtension];
		return extensionMenu;
	}

	return tableMenu;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	SEL action = [item action];
	if (!actionsEnabled || invalidated) return NO;

	if (action == @selector(addSequence:)) {
		return [selectedSchema length] && [delegate respondsToSelector:@selector(sidebar:addSequenceInSchema:)];
	}
	if (action == @selector(deleteSequence:)) {
		return [[self _itemTargetForMenuItem:item] kind] == SPPostgresSidebarSequence && [delegate respondsToSelector:@selector(sidebar:deleteSequenceNamed:)];
	}
	if (action == @selector(installExtension:)) {
		return [delegate respondsToSelector:@selector(sidebarInstallExtension:)];
	}
	if (action == @selector(dropExtension:)) {
		return [[self _itemTargetForMenuItem:item] kind] == SPPostgresSidebarExtension && [delegate respondsToSelector:@selector(sidebar:dropExtensionNamed:)];
	}

	BOOL relationAction = (action == @selector(renameTable:) || action == @selector(duplicateTable:) || action == @selector(truncateTables:) || action == @selector(removeRelations:) || action == @selector(openRelationInNewTab:) || action == @selector(openRelationInNewWindow:) || action == @selector(exportRelations:) || action == @selector(showCreateSyntax:) || action == @selector(copyCreateSyntax:));
	if (!relationAction) return YES;

	NSArray<NSString *> *targets = [self _relationTargetsForMenuItem:item];
	// The titles follow the targets each time the menu is validated (not the Export submenu's)
	if (![[item menu] supermenu]) [self _updateRelationItemsOfMenu:[item menu] forTargets:targets];

	NSUInteger count = [targets count];
	BOOL oneTable = (count == 1 && ![self relationIsView:[targets firstObject]]);
	BOOL allTables = (count > 0);
	for (NSString *name in targets) {
		if ([self relationIsView:name]) allTables = NO;
	}

	if (action == @selector(renameTable:)) return oneTable && [delegate respondsToSelector:@selector(sidebar:renameTableNamed:)];
	if (action == @selector(duplicateTable:)) return oneTable && [delegate respondsToSelector:@selector(sidebar:duplicateTableNamed:)];
	if (action == @selector(truncateTables:)) return allTables && [delegate respondsToSelector:@selector(sidebar:truncateTables:)];
	if (action == @selector(removeRelations:)) return count && [delegate respondsToSelector:@selector(sidebar:removeRelations:)];
	if (action == @selector(openRelationInNewTab:) || action == @selector(openRelationInNewWindow:)) return count == 1 && [delegate respondsToSelector:@selector(sidebar:openRelation:inNewWindow:)];
	if (action == @selector(exportRelations:)) return count && [delegate respondsToSelector:@selector(sidebar:exportRelations:format:)];
	return count && [delegate respondsToSelector:@selector(sidebar:showCreateSyntaxForRelations:copy:)];
}

/// The one table a Rename or Duplicate acts on, or nil (not exactly one target, a view, or actions disabled).
- (NSString *)_singleTableTargetForMenuItem:(id)sender
{
	if (!actionsEnabled) return nil;
	NSArray<NSString *> *targets = [self _relationTargetsForMenuItem:sender];
	if ([targets count] != 1 || [self relationIsView:[targets firstObject]]) return nil;
	return [targets firstObject];
}

/// The tables and views an action acts on (empty while actions are disabled).
- (NSArray<NSString *> *)_enabledRelationTargetsForMenuItem:(id)sender
{
	return actionsEnabled ? [self _relationTargetsForMenuItem:sender] : @[];
}

- (void)renameTable:(id)sender
{
	NSString *table = [self _singleTableTargetForMenuItem:sender];
	if (table && [delegate respondsToSelector:@selector(sidebar:renameTableNamed:)]) [delegate sidebar:self renameTableNamed:table];
}

- (void)duplicateTable:(id)sender
{
	NSString *table = [self _singleTableTargetForMenuItem:sender];
	if (table && [delegate respondsToSelector:@selector(sidebar:duplicateTableNamed:)]) [delegate sidebar:self duplicateTableNamed:table];
}

- (void)truncateTables:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if (![targets count]) return;
	for (NSString *name in targets) {
		if ([self relationIsView:name]) return;
	}
	if ([delegate respondsToSelector:@selector(sidebar:truncateTables:)]) [delegate sidebar:self truncateTables:targets];
}

- (void)removeRelations:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if ([targets count] && [delegate respondsToSelector:@selector(sidebar:removeRelations:)]) [delegate sidebar:self removeRelations:targets];
}

- (void)openRelationInNewTab:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if ([targets count] == 1 && [delegate respondsToSelector:@selector(sidebar:openRelation:inNewWindow:)]) [delegate sidebar:self openRelation:[targets firstObject] inNewWindow:NO];
}

- (void)openRelationInNewWindow:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if ([targets count] == 1 && [delegate respondsToSelector:@selector(sidebar:openRelation:inNewWindow:)]) [delegate sidebar:self openRelation:[targets firstObject] inNewWindow:YES];
}

/// Export ▸ As SQL dump… (tag 0) or As CSV file… (tag 1).
- (void)exportRelations:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if ([targets count] && [delegate respondsToSelector:@selector(sidebar:exportRelations:format:)]) [delegate sidebar:self exportRelations:targets format:[sender tag]];
}

- (void)showCreateSyntax:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if ([targets count] && [delegate respondsToSelector:@selector(sidebar:showCreateSyntaxForRelations:copy:)]) [delegate sidebar:self showCreateSyntaxForRelations:targets copy:NO];
}

- (void)copyCreateSyntax:(id)sender
{
	NSArray<NSString *> *targets = [self _enabledRelationTargetsForMenuItem:sender];
	if ([targets count] && [delegate respondsToSelector:@selector(sidebar:showCreateSyntaxForRelations:copy:)]) [delegate sidebar:self showCreateSyntaxForRelations:targets copy:YES];
}

- (void)addSequence:(id)sender
{
	if (![selectedSchema length]) return;
	if ([delegate respondsToSelector:@selector(sidebar:addSequenceInSchema:)]) [delegate sidebar:self addSequenceInSchema:selectedSchema];
}

- (void)deleteSequence:(id)sender
{
	SPPostgresSidebarItem *item = [self _itemTargetForMenuItem:sender];
	if ([item kind] != SPPostgresSidebarSequence) return;
	if ([delegate respondsToSelector:@selector(sidebar:deleteSequenceNamed:)]) [delegate sidebar:self deleteSequenceNamed:[item title]];
}

- (void)installExtension:(id)sender
{
	if ([delegate respondsToSelector:@selector(sidebarInstallExtension:)]) [delegate sidebarInstallExtension:self];
}

- (void)dropExtension:(id)sender
{
	SPPostgresSidebarItem *item = [self _itemTargetForMenuItem:sender];
	if ([item kind] != SPPostgresSidebarExtension) return;
	if ([delegate respondsToSelector:@selector(sidebar:dropExtensionNamed:)]) [delegate sidebar:self dropExtensionNamed:[item title]];
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
			case SPPostgresSidebarSequence: image = [NSImage imageWithSystemSymbolName:@"number" accessibilityDescription:NSLocalizedString(@"Sequence", @"PostgreSQL sidebar: sequence icon description")]; break;
			default: image = [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:NSLocalizedString(@"Extension", @"PostgreSQL sidebar: extension icon description")]; break;
		}
		[[cell imageView] setImage:image];
		BOOL symbol = ([item kind] == SPPostgresSidebarExtension || [item kind] == SPPostgresSidebarSequence);
		[[cell imageView] setContentTintColor:symbol ? [NSColor secondaryLabelColor] : nil];

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

/**
 * Which rows are selected (in place of -outlineView:shouldSelectItem:, which the outline doesn't ask once this is
 * implemented): section headers never; several rows only when every one is a table or view. A mix with a sequence or
 * extension keeps the row the user clicked; with no click in it (Select All, Shift-arrow), its tables and views, or
 * else (none among them) the row the change adds.
 */
- (NSIndexSet *)outlineView:(NSOutlineView *)theOutlineView selectionIndexesForProposedSelection:(NSIndexSet *)proposed
{
	NSMutableIndexSet *rows = [[proposed mutableCopy] autorelease];
	__block BOOL allRelations = YES;
	[proposed enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
		SPPostgresSidebarItem *item = [theOutlineView itemAtRow:(NSInteger)row];
		if ([item kind] == SPPostgresSidebarSection) [rows removeIndex:row];
		else if ([item kind] != SPPostgresSidebarTable && [item kind] != SPPostgresSidebarView) allRelations = NO;
	}];

	// Only headers: the selection stays
	if (![rows count] && [proposed count]) return [theOutlineView selectedRowIndexes];
	if ([rows count] <= 1 || allRelations) return rows;

	NSInteger clicked = [theOutlineView clickedRow];
	if (clicked >= 0 && [rows containsIndex:(NSUInteger)clicked]) return [NSIndexSet indexSetWithIndex:(NSUInteger)clicked];

	NSIndexSet *relations = [rows indexesPassingTest:^BOOL(NSUInteger row, BOOL *stop) {
		SPPostgresSidebarItem *item = [theOutlineView itemAtRow:(NSInteger)row];
		return [item kind] == SPPostgresSidebarTable || [item kind] == SPPostgresSidebarView;
	}];
	if ([relations count]) return relations;

	NSMutableIndexSet *added = [[rows mutableCopy] autorelease];
	[added removeIndexes:[theOutlineView selectedRowIndexes]];
	return [NSIndexSet indexSetWithIndex:([added count] ? [added lastIndex] : [rows lastIndex])];
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

#pragma mark -

@implementation SPPostgresSidebarOutlineView

@synthesize menuSource;

/// The menu for the row under the pointer (a sequence's, an extension's, or a table's), as the menu source picks it.
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	if (menuSource) {
		NSInteger row = [self rowAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
		NSMenu *menu = [menuSource menuForRow:row];
		if (menu && menu != [self menu]) [self setMenu:menu];
	}
	return [super menuForEvent:event];
}

@end
