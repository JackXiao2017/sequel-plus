#import "SPPostgresQueryFavoriteManager.h"
#import "SPPostgresQueryStore.h"
#import "SPPostgresTextView.h"
#import "SPButtonBar.h"

// MySQL's QueryFavoriteManager.xib: the window, the list's width and the bar's height
static const CGFloat SPPostgresFavoriteManagerWidth = 563;
static const CGFloat SPPostgresFavoriteManagerHeight = 369;
static const CGFloat SPPostgresFavoriteManagerMinWidth = 529;
static const CGFloat SPPostgresFavoriteManagerListWidth = 177;
static const CGFloat SPPostgresFavoriteManagerBarHeight = 23;

static NSString * const SPPostgresFavoriteNameKey = @"name";
static NSString * const SPPostgresFavoriteQueryKey = @"query";

@implementation SPPostgresQueryFavoriteManager
{
	SPPostgresQueryStore *store;
	NSMutableArray<NSMutableDictionary *> *favorites;
	NSInteger shownIndex;              // the favorite whose name and query the fields show (-1: none)
	BOOL showing;                      // the fields are being filled (their changes are not edits)
	void (^completion)(BOOL saved);

	NSPanel *sheet;
	NSTableView *favoritesTable;
	NSTextField *nameField;
	NSTextView *queryView;
	NSButton *addButton;
	NSButton *removeButton;
	NSButton *duplicateButton;
	NSButton *saveButton;
	NSButton *cancelButton;
	void (^alertPresenter)(NSAlert *alert);
	void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));
}

@synthesize sheet;
@synthesize favoritesTable;
@synthesize nameField;
@synthesize queryView;
@synthesize addButton;
@synthesize removeButton;
@synthesize duplicateButton;
@synthesize saveButton;
@synthesize cancelButton;
@synthesize alertPresenter;
@synthesize confirmationPresenter;

#pragma mark - Writing

+ (void)writeFavorites:(NSArray *)theFavorites
			   toStore:(SPPostgresQueryStore *)theStore
			   confirm:(void (^)(NSAlert *alert, void (^completion)(BOOL confirmed)))confirm
				report:(void (^)(NSAlert *alert))report
			completion:(void (^)(BOOL written))done
{
	NSArray *items = [[theFavorites copy] autorelease];
	void (^reportError)(NSError *) = ^(NSError *error) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:NSLocalizedString(@"The query favorites could not be saved.", @"Postgres query favorites: save failed")];
		NSString *detail = [error localizedDescription];
		[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres content: unknown error")];
		if (report) report(alert);
	};

	NSError *loadError = [theStore lastLoadError];
	if (!loadError) {
		NSError *error = nil;
		BOOL written = [theStore setItems:items error:&error];
		if (!written) reportError(error);
		if (done) done(written);
		return;
	}

	// The existing file can't be read (Ruling 8): say so, and only on Continue move it aside and write
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:NSLocalizedString(@"The query favorites file can't be read.", @"Postgres query favorites: unreadable file message")];
	[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"%@\n\nIf you continue, the file is renamed and kept in the same folder, and the favorites you save replace it.", @"Postgres query favorites: unreadable file informative text"), [loadError localizedDescription] ?: @""]];
	[alert addButtonWithTitle:NSLocalizedString(@"Continue", @"continue button")];
	NSButton *cancel = [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[cancel setKeyEquivalent:@"\e"];
	void (^answered)(BOOL) = ^(BOOL confirmed) {
		if (!confirmed) {
			if (done) done(NO);
			return;
		}
		NSError *error = nil;
		BOOL written = [theStore replaceItems:items error:&error];
		if (!written) reportError(error);
		if (done) done(written);
	};
	if (confirm) confirm(alert, answered);
	else answered([alert runModal] == NSAlertFirstButtonReturn);
}

#pragma mark - Setup

- (instancetype)initWithStore:(SPPostgresQueryStore *)theStore
{
	if ((self = [super init])) {
		store = [theStore retain];
		favorites = [[NSMutableArray alloc] init];
		for (id item in [store items] ?: @[]) {
			// As MySQL's menu: a favorite is a dictionary with a name
			if (![item isKindOfClass:[NSDictionary class]] || ![[item objectForKey:SPPostgresFavoriteNameKey] isKindOfClass:[NSString class]]) continue;
			NSMutableDictionary *favorite = [[item mutableCopy] autorelease];
			if (![[favorite objectForKey:SPPostgresFavoriteQueryKey] isKindOfClass:[NSString class]]) [favorite setObject:@"" forKey:SPPostgresFavoriteQueryKey];
			[favorites addObject:favorite];
		}
		shownIndex = -1;
		[self _buildSheet];
		[favoritesTable reloadData];
		if ([favorites count]) [favoritesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		[self _showSelection];
	}
	return self;
}

- (void)dealloc
{
	[favoritesTable setDataSource:nil];
	[favoritesTable setDelegate:nil];
	[nameField setDelegate:nil];
	[queryView setDelegate:nil];
	[store release];
	[favorites release];
	[completion release];
	[sheet release];
	[favoritesTable release];
	[nameField release];
	[queryView release];
	[addButton release];
	[removeButton release];
	[duplicateButton release];
	[saveButton release];
	[cancelButton release];
	[alertPresenter release];
	[confirmationPresenter release];
	[super dealloc];
}

/// A button of the list's bar (MySQL's: textured, image only, 32 × 23).
- (NSButton *)_newBarButtonWithImage:(NSString *)imageName x:(CGFloat)x toolTip:(NSString *)toolTip action:(SEL)action
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, 0, 32, SPPostgresFavoriteManagerBarHeight)];
	[button setBezelStyle:NSBezelStyleTexturedRounded];
	[button setImage:[NSImage imageNamed:imageName]];
	[button setTitle:@""];
	[button setImagePosition:NSImageOnly];
	[button setToolTip:toolTip];
	[button setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[button setTarget:self];
	[button setAction:action];
	return button;
}

/// A small push button of the sheet's bottom row (MySQL's Cancel / Save).
- (NSButton *)_newPushButtonWithTitle:(NSString *)title frame:(NSRect)frame key:(NSString *)key action:(SEL)action
{
	NSButton *button = [[NSButton alloc] initWithFrame:frame];
	[button setBezelStyle:NSBezelStyleRounded];
	[[button cell] setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[button setTitle:title];
	[button setKeyEquivalent:key];
	[button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[button setTarget:self];
	[button setAction:action];
	return button;
}

/// MySQL's QueryFavoriteManager.xib, without its tab trigger row, placeholder menu, help button and .spf import/export.
- (void)_buildSheet
{
	CGFloat width = SPPostgresFavoriteManagerWidth, height = SPPostgresFavoriteManagerHeight;
	sheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
									   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
										 backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setTitle:NSLocalizedString(@"Query Favorite Manager", @"Postgres query favorite manager title")];
	[sheet setContentMinSize:NSMakeSize(SPPostgresFavoriteManagerMinWidth, height)];
	NSView *content = [sheet contentView];

	NSSplitView *split = [[[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, width, height)] autorelease];
	[split setVertical:YES];
	[split setDividerStyle:NSSplitViewDividerStyleThin];
	[split setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// The list, over the bar with add, remove and duplicate
	CGFloat listWidth = SPPostgresFavoriteManagerListWidth, barHeight = SPPostgresFavoriteManagerBarHeight;
	NSView *left = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, listWidth, height)] autorelease];
	NSScrollView *listScroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, barHeight, listWidth, height - barHeight)] autorelease];
	[listScroll setHasVerticalScroller:YES];
	[listScroll setAutohidesScrollers:YES];
	[listScroll setBorderType:NSNoBorder];
	[listScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	favoritesTable = [[NSTableView alloc] initWithFrame:[[listScroll contentView] bounds]];
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresFavoriteNameKey] autorelease];
	[[column headerCell] setStringValue:NSLocalizedString(@"Favorites", @"Postgres query favorite manager: list header")];
	[[column dataCell] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[column dataCell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[column setEditable:NO];
	[column setWidth:listWidth - 3];
	[favoritesTable addTableColumn:column];
	[favoritesTable setColumnAutoresizingStyle:NSTableViewFirstColumnOnlyAutoresizingStyle];
	[favoritesTable setRowHeight:16];
	[favoritesTable setAllowsMultipleSelection:YES];
	[favoritesTable setAllowsEmptySelection:YES];
	[favoritesTable setAllowsColumnReordering:NO];
	[favoritesTable setFocusRingType:NSFocusRingTypeNone];
	[favoritesTable setDataSource:self];
	[favoritesTable setDelegate:self];
	[listScroll setDocumentView:favoritesTable];
	[left addSubview:listScroll];

	SPButtonBar *bar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, listWidth, barHeight)] autorelease];
	[bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	addButton = [self _newBarButtonWithImage:@"button_add" x:0 toolTip:NSLocalizedString(@"Add favorite (⌥⌘A)", @"Postgres query favorite manager: add tooltip") action:@selector(addQueryFavorite:)];
	[addButton setKeyEquivalent:@"a"];
	[addButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
	removeButton = [self _newBarButtonWithImage:@"button_remove" x:32 toolTip:NSLocalizedString(@"Delete selected favorite (⌫)", @"Postgres query favorite manager: remove tooltip") action:@selector(removeQueryFavorite:)];
	duplicateButton = [self _newBarButtonWithImage:@"button_duplicate" x:64 toolTip:NSLocalizedString(@"Duplicate selected favorite (⌘D)", @"Postgres query favorite manager: duplicate tooltip") action:@selector(duplicateQueryFavorite:)];
	[duplicateButton setKeyEquivalent:@"d"];
	[duplicateButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[bar addSubview:addButton];
	[bar addSubview:removeButton];
	[bar addSubview:duplicateButton];
	[left addSubview:bar];
	[split addSubview:left];

	// The selected favorite: its name and query, then Cancel and Save
	CGFloat rightWidth = width - listWidth - 1;
	NSView *right = [[[NSView alloc] initWithFrame:NSMakeRect(listWidth + 1, 0, rightWidth, height)] autorelease];

	NSTextField *nameLabel = [NSTextField labelWithString:NSLocalizedString(@"Name:", @"Postgres query favorite manager: name label")];
	[nameLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[nameLabel setFrame:NSMakeRect(17, 329, 60, 14)];
	[nameLabel setAutoresizingMask:NSViewMinYMargin | NSViewMaxXMargin];
	[right addSubview:nameLabel];

	nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(77, 326, rightWidth - 77 - 20, 19)];
	[[nameField cell] setControlSize:NSControlSizeSmall];
	[nameField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[nameField cell] setScrollable:YES];
	[[nameField cell] setUsesSingleLineMode:YES];
	[nameField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[nameField setDelegate:self];
	[right addSubview:nameField];

	NSScrollView *queryScroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 54, rightWidth - 40, 264)] autorelease];
	[queryScroll setHasVerticalScroller:YES];
	[queryScroll setHasHorizontalScroller:NO];
	[queryScroll setAutohidesScrollers:YES];
	[queryScroll setBorderType:NSBezelBorder];
	[queryScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	NSSize contentSize = [queryScroll contentSize];
	SPPostgresTextView *textView = [[SPPostgresTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height) scrollView:queryScroll];
	queryView = textView;
	[textView setAutohelp:NO];
	[queryView setMinSize:NSMakeSize(0, contentSize.height)];
	[queryView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[queryView setVerticallyResizable:YES];
	[queryView setHorizontallyResizable:NO];
	[queryView setAutoresizingMask:NSViewWidthSizable];
	[[queryView textContainer] setContainerSize:NSMakeSize(contentSize.width, CGFLOAT_MAX)];
	[[queryView textContainer] setWidthTracksTextView:YES];
	[queryView setRichText:NO];
	[queryView setImportsGraphics:NO];
	[queryView setAllowsUndo:YES];
	[queryView setAutomaticQuoteSubstitutionEnabled:NO];
	[queryView setAutomaticDashSubstitutionEnabled:NO];
	[queryView setAutomaticTextReplacementEnabled:NO];
	[queryView setAutomaticSpellingCorrectionEnabled:NO];
	[queryView setAutomaticLinkDetectionEnabled:NO];
	[queryView setContinuousSpellCheckingEnabled:NO];
	[queryView setDelegate:self];
	[queryScroll setDocumentView:queryView];
	[right addSubview:queryScroll];

	cancelButton = [self _newPushButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") frame:NSMakeRect(rightWidth - 189, 13, 88, 28) key:@"\e" action:@selector(cancel:)];
	saveButton = [self _newPushButtonWithTitle:NSLocalizedString(@"Save", @"save button") frame:NSMakeRect(rightWidth - 103, 13, 88, 28) key:@"\r" action:@selector(save:)];
	[right addSubview:cancelButton];
	[right addSubview:saveButton];

	[split addSubview:right];
	[split adjustSubviews];
	[split setFrame:[content bounds]];
	[content addSubview:split];
	[sheet setInitialFirstResponder:nameField];
}

#pragma mark - Sheet

- (void)beginSheetForWindow:(NSWindow *)window completion:(void (^)(BOOL))theCompletion
{
	[completion release];
	completion = [theCompletion copy];
	[window beginSheet:sheet completionHandler:nil];
}

- (void)_endWithSaved:(BOOL)saved
{
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];
	void (^done)(BOOL) = [completion autorelease];
	completion = nil;
	if (done) done(saved);
}

- (IBAction)save:(id)sender
{
	[self _commitFields];
	[self retain];
	[[self class] writeFavorites:[self favorites] toStore:store confirm:[self _confirmer] report:[self _reporter] completion:^(BOOL written) {
		// Not written (asked and cancelled, or failed and reported): the sheet stays open
		if (written) [self _endWithSaved:YES];
		[self autorelease];
	}];
}

- (IBAction)cancel:(id)sender
{
	[self _endWithSaved:NO];
}

#pragma mark - Alerts

- (void (^)(NSAlert *))_reporter
{
	if (alertPresenter) return alertPresenter;
	return [[^(NSAlert *alert) {
		if ([sheet isVisible] && ![sheet attachedSheet]) [alert beginSheetModalForWindow:sheet completionHandler:nil];
		else [alert runModal];
	} copy] autorelease];
}

- (void (^)(NSAlert *, void (^)(BOOL)))_confirmer
{
	if (confirmationPresenter) return confirmationPresenter;
	return [[^(NSAlert *alert, void (^answered)(BOOL)) {
		if ([sheet isVisible] && ![sheet attachedSheet]) {
			void (^copied)(BOOL) = [[answered copy] autorelease];
			[alert beginSheetModalForWindow:sheet completionHandler:^(NSModalResponse response) {
				copied(response == NSAlertFirstButtonReturn);
			}];
		}
		else answered([alert runModal] == NSAlertFirstButtonReturn);
	} copy] autorelease];
}

#pragma mark - Editing

- (NSArray *)favorites
{
	[self _commitFields];
	NSMutableArray *result = [NSMutableArray arrayWithCapacity:[favorites count]];
	for (NSDictionary *favorite in favorites) [result addObject:[[favorite copy] autorelease]];
	return result;
}

/// The fields' name and query, into the favorite they show.
- (void)_commitFields
{
	if (showing || shownIndex < 0 || shownIndex >= (NSInteger)[favorites count]) return;
	NSMutableDictionary *favorite = [favorites objectAtIndex:shownIndex];
	NSString *name = [[[nameField stringValue] copy] autorelease] ?: @"";
	// A copy: the text view's string is its live, mutable storage (MySQL's #2938)
	NSString *query = [NSString stringWithString:[queryView string] ?: @""];
	BOOL renamed = ![name isEqualToString:[favorite objectForKey:SPPostgresFavoriteNameKey]];
	[favorite setObject:name forKey:SPPostgresFavoriteNameKey];
	[favorite setObject:query forKey:SPPostgresFavoriteQueryKey];
	if (renamed) [favoritesTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:shownIndex] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

/// The fields show the selected favorite (one selected), or are empty and disabled; the buttons follow, as MySQL's.
- (void)_showSelection
{
	NSIndexSet *selection = [favoritesTable selectedRowIndexes];
	showing = YES;
	if ([selection count] == 1) {
		shownIndex = (NSInteger)[selection firstIndex];
		NSDictionary *favorite = [favorites objectAtIndex:shownIndex];
		[nameField setStringValue:[favorite objectForKey:SPPostgresFavoriteNameKey]];
		[queryView setString:[favorite objectForKey:SPPostgresFavoriteQueryKey]];
		[[nameField cell] setPlaceholderString:@""];
	}
	else {
		shownIndex = -1;
		[nameField setStringValue:@""];
		[queryView setString:@""];
		[[nameField cell] setPlaceholderString:[selection count] ? NSLocalizedString(@"[multiple selection]", @"[multiple selection]") : NSLocalizedString(@"[no selection]", @"[no selection]")];
	}
	[[queryView undoManager] removeAllActions];
	showing = NO;
	BOOL one = shownIndex >= 0;
	[nameField setEnabled:one];
	[queryView setEditable:one];
	[removeButton setEnabled:[selection count] > 0];
	[duplicateButton setEnabled:one];
}

/// Inserts favorite after the last selected one (or at the end), selects it and puts the caret in its name.
- (void)_insertFavorite:(NSMutableDictionary *)favorite
{
	NSIndexSet *selection = [favoritesTable selectedRowIndexes];
	NSUInteger index = [selection count] ? [selection lastIndex] + 1 : [favorites count];
	[favorites insertObject:favorite atIndex:index];
	[favoritesTable reloadData];
	[favoritesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
	[favoritesTable scrollRowToVisible:index];
	[self _showSelection];
	[sheet makeFirstResponder:nameField];
}

- (IBAction)addQueryFavorite:(id)sender
{
	[self _commitFields];
	[self _insertFavorite:[NSMutableDictionary dictionaryWithDictionary:@{
		SPPostgresFavoriteNameKey: NSLocalizedString(@"New Favorite", @"query favorite manager : new favorite : name"),
		SPPostgresFavoriteQueryKey: @""
	}]];
}

- (IBAction)duplicateQueryFavorite:(id)sender
{
	if ([favoritesTable numberOfSelectedRows] != 1) {
		NSBeep();
		return;
	}
	[self _commitFields];
	NSMutableDictionary *copy = [[[favorites objectAtIndex:[favoritesTable selectedRow]] mutableCopy] autorelease];
	[copy setObject:[NSString stringWithFormat:NSLocalizedString(@"%@ Copy", @"query favorite manager : duplicate favorite : new favorite name"), [copy objectForKey:SPPostgresFavoriteNameKey]]
			 forKey:SPPostgresFavoriteNameKey];
	[self _insertFavorite:copy];
}

- (IBAction)removeQueryFavorite:(id)sender
{
	if (![favoritesTable numberOfSelectedRows]) {
		NSBeep();
		return;
	}
	[self _commitFields];

	// As MySQL's
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Remove selected query favorites?", @"remove selected query favorites message")];
	[alert setInformativeText:NSLocalizedString(@"Are you sure you want to remove all selected query favorites? This action cannot be undone.", @"remove all selected query favorites informative message")];
	[alert setAlertStyle:NSAlertStyleCritical];
	NSButton *remove = [alert addButtonWithTitle:NSLocalizedString(@"Remove", @"remove button")];
	NSButton *cancel = [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[remove setKeyEquivalent:@"r"];
	[remove setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[cancel setKeyEquivalent:@"\r"];

	NSIndexSet *rows = [[[favoritesTable selectedRowIndexes] copy] autorelease];
	[self retain];
	[self _confirmer](alert, ^(BOOL confirmed) {
		if (confirmed) {
			shownIndex = -1;
			[favorites removeObjectsAtIndexes:rows];
			[favoritesTable reloadData];
			NSInteger next = MIN((NSInteger)[rows firstIndex], (NSInteger)[favorites count] - 1);
			if (next >= 0) [favoritesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
			else [favoritesTable deselectAll:nil];
			[self _showSelection];
		}
		[self autorelease];
	});
}

#pragma mark - Table and fields

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)[favorites count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[favorites count]) return nil;
	return [[favorites objectAtIndex:row] objectForKey:SPPostgresFavoriteNameKey];
}

- (BOOL)selectionShouldChangeInTableView:(NSTableView *)tableView
{
	[self _commitFields];
	return YES;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	// A selection made in code skips -selectionShouldChangeInTableView:
	[self _commitFields];
	[self _showSelection];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	if ([notification object] == nameField) [self _commitFields];
}

- (void)textDidChange:(NSNotification *)notification
{
	if ([notification object] == queryView) [self _commitFields];
}

@end
