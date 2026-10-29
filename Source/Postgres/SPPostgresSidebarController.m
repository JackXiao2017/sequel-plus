#import "SPPostgresSidebarController.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresTaskRunner.h"

static NSString * const SPPostgresSidebarTables = @"TABLES";
static NSString * const SPPostgresSidebarViews = @"VIEWS";
static NSString * const SPPostgresSidebarSequences = @"SEQUENCES";
static NSString * const SPPostgresSidebarExtensions = @"EXTENSIONS";

static NSString * const SPPostgresSidebarGroupCell = @"SPPostgresSidebarGroupCell";
static NSString * const SPPostgresSidebarItemCell = @"SPPostgresSidebarItemCell";

static const CGFloat SPPostgresSidebarSchemaBarHeight = 32;
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

@interface SPPostgresSidebarController () <NSMenuItemValidation>

- (void)_buildView;
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
	NSArray *sections; // TABLES, VIEWS, SEQUENCES, EXTENSIONS

	NSView *view;
	NSPopUpButton *schemaPopup;
	SPPostgresSidebarOutlineView *outlineView;
	NSMenu *tableMenu;
	NSMenu *sequenceMenu;
	NSMenuItem *deleteSequenceItem; // not retained; sequenceMenu's
	NSMenu *extensionMenu;
	NSMenuItem *dropExtensionItem; // not retained; extensionMenu's

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
}

@synthesize selectedSchema;
@synthesize selectedTableName;
@synthesize selectedSequenceName;
@synthesize sequenceMenu;
@synthesize selectedExtensionName;
@synthesize extensionMenu;
@synthesize lastError;
@synthesize delegate;
@synthesize tableMenu;
@synthesize taskRunner;

- (instancetype)initWithCatalog:(SPPostgresCatalog *)theCatalog
{
	if ((self = [super init])) {
		sections = [@[[SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarTables detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarViews detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarSequences detail:nil kind:SPPostgresSidebarSection],
		              [SPPostgresSidebarItem itemWithTitle:SPPostgresSidebarExtensions detail:nil kind:SPPostgresSidebarSection]] retain];
		schemas = [@[] retain];

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
	[selectedSchema release];
	[selectedTableName release];
	[selectedSequenceName release];
	[selectedExtensionName release];
	[lastError release];

	[super dealloc];
}

- (void)invalidate
{
	invalidated = YES;
	delegate = nil;
	[outlineView setDelegate:nil];
	[outlineView setDataSource:nil];
	[outlineView setMenuSource:nil];
	[schemaPopup setTarget:nil];
	for (NSMenuItem *item in [tableMenu itemArray]) [item setTarget:nil];
	for (NSMenuItem *item in [sequenceMenu itemArray]) [item setTarget:nil];
	for (NSMenuItem *item in [extensionMenu itemArray]) [item setTarget:nil];
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

	// On a sequence, the SEQUENCES header or empty space (see -menuForRow:)
	sequenceMenu = [[NSMenu alloc] initWithTitle:@""];
	NSMenuItem *addSequence = [sequenceMenu addItemWithTitle:NSLocalizedString(@"Add Sequence…", @"PostgreSQL sidebar: add sequence menu item") action:@selector(addSequence:) keyEquivalent:@""];
	[addSequence setToolTip:NSLocalizedString(@"Add a sequence to the selected schema", @"PostgreSQL sidebar: add sequence menu item tooltip")];
	[addSequence setTarget:self];
	deleteSequenceItem = [sequenceMenu addItemWithTitle:NSLocalizedString(@"Delete Sequence…", @"PostgreSQL sidebar: delete sequence menu item") action:@selector(deleteSequence:) keyEquivalent:@""];
	[deleteSequenceItem setToolTip:NSLocalizedString(@"Delete the selected sequence", @"PostgreSQL sidebar: delete sequence menu item tooltip")];
	[deleteSequenceItem setTarget:self];

	// On an extension, the EXTENSIONS header or empty space below it (see -menuForRow:)
	extensionMenu = [[NSMenu alloc] initWithTitle:@""];
	NSMenuItem *installExtension = [extensionMenu addItemWithTitle:NSLocalizedString(@"Install Extension…", @"PostgreSQL sidebar: install extension menu item") action:@selector(installExtension:) keyEquivalent:@""];
	[installExtension setToolTip:NSLocalizedString(@"Install an extension the server offers into this database", @"PostgreSQL sidebar: install extension menu item tooltip")];
	[installExtension setTarget:self];
	dropExtensionItem = [extensionMenu addItemWithTitle:NSLocalizedString(@"Drop Extension…", @"PostgreSQL sidebar: drop extension menu item") action:@selector(dropExtension:) keyEquivalent:@""];
	[dropExtensionItem setToolTip:NSLocalizedString(@"Drop the selected extension", @"PostgreSQL sidebar: drop extension menu item tooltip")];
	[dropExtensionItem setTarget:self];

	[container addSubview:scrollView];
}

#pragma mark - Loading

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	if (runner == taskRunner) return;
	[taskRunner release];
	taskRunner = [runner retain];
	ownsTaskRunner = NO;
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
	// The schema shown now is read again (if it is still there); the selection kept is the one shown when applied
	[self _runReload:SPPostgresSidebarReloadKeeping schema:selectedSchema cancelTitle:NSLocalizedString(@"Cancel", @"cancel button") apply:^BOOL(NSDictionary *read) {
		NSString *previousSchema = [[selectedSchema copy] autorelease];
		NSString *table = [[selectedTableName copy] autorelease];
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
		// The same schema (not the default one standing in for a schema that is gone): its table or sequence again
		if (table && [previousSchema isEqualToString:selectedSchema]) [self selectTableNamed:table];
		if (sequence && [previousSchema isEqualToString:selectedSchema]) [self selectSequenceNamed:sequence];
		// An extension is the database's, whatever the schema
		if (extension) [self selectExtensionNamed:extension];
		holdingSelectionChanges = NO;

		BOOL sameSchema = (previousSchema == selectedSchema) || [previousSchema isEqualToString:selectedSchema];
		BOOL sameTable = (table == selectedTableName) || [table isEqualToString:selectedTableName];
		BOOL sameSequence = (sequence == selectedSequenceName) || [sequence isEqualToString:selectedSequenceName];
		BOOL sameExtension = (extension == selectedExtensionName) || [extension isEqualToString:selectedExtensionName];
		if (!sameSchema || !sameTable || !sameSequence || !sameExtension) [delegate sidebarSelectionDidChange:self];

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

	[self _runReload:SPPostgresSidebarReloadSchema schema:schema cancelTitle:NSLocalizedString(@"Cancel", @"cancel button") apply:^BOOL(NSDictionary *read) {
		NSString *previousSchema = [[selectedSchema copy] autorelease];
		NSString *previousTable = [[selectedTableName copy] autorelease];
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
		BOOL sameTable = (previousTable == selectedTableName) || [previousTable isEqualToString:selectedTableName];
		BOOL sameSequence = (previousSequence == selectedSequenceName) || [previousSequence isEqualToString:selectedSequenceName];
		BOOL sameExtension = (previousExtension == selectedExtensionName) || [previousExtension isEqualToString:selectedExtensionName];
		if (!sameSchema || !sameTable || !sameSequence || !sameExtension) [delegate sidebarSelectionDidChange:self];
		return loaded;
	} completion:completion];
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

- (void)_updateSelectionFromOutline
{
	SPPostgresSidebarItem *item = [outlineView selectedRow] >= 0 ? [outlineView itemAtRow:[outlineView selectedRow]] : nil;
	NSString *name = ([item kind] == SPPostgresSidebarTable || [item kind] == SPPostgresSidebarView) ? [item title] : nil;
	NSString *sequence = ([item kind] == SPPostgresSidebarSequence) ? [item title] : nil;
	NSString *extension = ([item kind] == SPPostgresSidebarExtension) ? [item title] : nil;

	BOOL sameTable = (name == selectedTableName || [name isEqualToString:selectedTableName]);
	BOOL sameSequence = (sequence == selectedSequenceName || [sequence isEqualToString:selectedSequenceName]);
	BOOL sameExtension = (extension == selectedExtensionName || [extension isEqualToString:selectedExtensionName]);
	if (sameTable && sameSequence && sameExtension) return;

	[selectedTableName release];
	selectedTableName = [name copy];
	[selectedSequenceName release];
	selectedSequenceName = [sequence copy];
	[selectedExtensionName release];
	selectedExtensionName = [extension copy];

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
	if ([item action] == @selector(addSequence:)) {
		return [selectedSchema length] && [delegate respondsToSelector:@selector(sidebar:addSequenceInSchema:)];
	}
	if ([item action] == @selector(deleteSequence:)) {
		return [[self _menuTargetItem] kind] == SPPostgresSidebarSequence && [delegate respondsToSelector:@selector(sidebar:deleteSequenceNamed:)];
	}
	if ([item action] == @selector(installExtension:)) {
		return [delegate respondsToSelector:@selector(sidebarInstallExtension:)];
	}
	if ([item action] == @selector(dropExtension:)) {
		return [[self _menuTargetItem] kind] == SPPostgresSidebarExtension && [delegate respondsToSelector:@selector(sidebar:dropExtensionNamed:)];
	}
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

- (void)addSequence:(id)sender
{
	if (![selectedSchema length]) return;
	if ([delegate respondsToSelector:@selector(sidebar:addSequenceInSchema:)]) [delegate sidebar:self addSequenceInSchema:selectedSchema];
}

- (void)deleteSequence:(id)sender
{
	SPPostgresSidebarItem *item = [self _menuTargetItem];
	if ([item kind] != SPPostgresSidebarSequence) return;
	if ([delegate respondsToSelector:@selector(sidebar:deleteSequenceNamed:)]) [delegate sidebar:self deleteSequenceNamed:[item title]];
}

- (void)installExtension:(id)sender
{
	if ([delegate respondsToSelector:@selector(sidebarInstallExtension:)]) [delegate sidebarInstallExtension:self];
}

- (void)dropExtension:(id)sender
{
	SPPostgresSidebarItem *item = [self _menuTargetItem];
	if ([item kind] != SPPostgresSidebarExtension) return;
	if ([delegate respondsToSelector:@selector(sidebar:dropExtensionNamed:)]) [delegate sidebar:self dropExtensionNamed:[item title]];
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
