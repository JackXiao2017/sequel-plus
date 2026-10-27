#import "SPPostgresDocument.h"
#import "SPPostgresSidebarController.h"
#import "SPPostgresContentController.h"
#import "SPPostgresQueryController.h"
#import "SPPostgresHistory.h"
#import "SPPostgresTableDuplicator.h"
#import "SPPostgresConsoleLogger.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresConnector.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresErrors.h"
#import "SPWindowController.h"
#import "SPSplitView.h"
#import "SPQueryController.h"
#import "SPFavoriteColorSupport.h"
#import "NSWindow+SPCompactChrome.h"
#import "SPToolbarTransferItem.h"
#import "SPMainToolbar.h"
#import "SPConstants.h"
#import <PostgresKit/PostgresKit.h>

// MySQL's left pane name (DBView.xib): one left pane width for both engines, so the database pickers match
static NSString * const SPPostgresSplitterName = @"DBViewSplitter";
// Shared with MySQL tabs, and so is the saved layout (see -[SPDatabaseDocument setupToolbar])
static NSString * const SPPostgresDocumentToolbarIdentifier = @"TableWindowToolbar";

// The MySQL split view's size in DBView.xib, so both panes start (and grow with the window) alike
static const CGFloat SPPostgresSidebarDefaultWidth = 214;
static const NSSize SPPostgresSplitViewSize = {943, 549};

@interface SPPostgresDocument () <SPPostgresSidebarControllerDelegate>

@property (readwrite) BOOL isProcessing;
@property (readwrite, assign) SPWindowController *parentWindowController;
@property (readwrite, assign) NSWindow *parentWindow;
@property (readwrite, assign) NSTabViewItem *parentTabViewItem;

- (void)_attachCurrentConnection;
- (void)_buildContent;
- (void)_installContentController;
- (void)_installQueryController;
- (void)_showQueryPane:(BOOL)query;
- (NSView *)_rightPane;
- (void)_showSelectedTable;
- (void)_buildToolbar;
- (void)_reloadDatabasePopup;
- (void)_applyWindowTitle;
- (void)_updateDatabaseToolbarItemWidth;
- (void)_tearDown;
- (BOOL)_isSelectedTab;
- (NSString *)_connectionName;
- (void)_reportCatalogError:(NSError *)error;
- (void)_presentAlert:(NSAlert *)alert;
- (void)_presentPendingAlert;
- (void)_databaseSwitchBy:(SPPostgresConnector *)theConnector favorite:(SPPostgresFavorite *)theFavorite finishedWithConnection:(PGPostgresConnection *)newConnection error:(NSError *)error;
- (void)_switchToDatabase:(NSString *)database forHistory:(BOOL)forHistory;
- (void)_recordHistory;
- (void)_updateHistoryControl;
- (void)_goBackInHistory:(BOOL)back;
- (void)_applyHistoryEntry:(NSDictionary *)entry;
- (void)_abandonHistoryRestore;
- (BOOL)_endContentEditing;
- (void)_confirmLeavingSession:(void (^)(BOOL proceed))completion;
- (void)_showDuplicateTableSheetForTable:(NSString *)table;
- (void)_duplicateTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName withContent:(BOOL)withContent;

@end

@implementation SPPostgresDocument
{
	PGPostgresConnection *connection;
	SPPostgresConnector *connector;
	SPPostgresFavorite *favorite;
	SPPostgresCatalog *catalog;
	SPPostgresConsoleLogger *logger;
	SPPostgresSidebarController *sidebar;
	SPPostgresContentController *contentController;
	SPPostgresQueryController *queryController;
	SPPostgresHistory *history;
	/// The right pane shows the Query view (else the Content view)
	BOOL showingQuery;

	NSString *serverVersion;
	NSString *currentDatabase;

	/// A database switch in progress (see -switchToDatabase:)
	SPPostgresConnector *pendingConnector;

	/// The history entry to show once the database switch in progress is done (a back/forward to another database)
	NSDictionary *pendingHistoryEntry;
	/// That move was back (else forward): undone if the switch fails
	BOOL pendingHistoryWentBack;
	/// Showing a history entry: the changes it makes aren't recorded
	BOOL restoringHistory;
	/// Waiting for the user to confirm a database switch that rolls back their transaction
	BOOL confirmingSwitch;

	/// The Duplicate Table sheet while it is shown, and its controls
	NSWindow *duplicateSheet;
	NSTextField *duplicateNameField;
	NSButton *duplicateContentSwitch;
	NSButton *duplicateButton;

	SPSplitView *splitView;
	NSToolbar *toolbar;
	NSPopUpButton *databasePopup;
	NSSegmentedControl *historyControl;
	NSToolbarItem *databaseToolbarItem; // not retained; owned by the toolbar

	/// An alert that came up while the tab couldn't show it (presented once the tab is active in a visible window)
	NSAlert *pendingAlert;

	BOOL tornDown;
}

@synthesize sidebar;
@synthesize contentController;
@synthesize queryController;
@synthesize history;
@synthesize connection;
@synthesize favorite;
@synthesize alertPresenter;
@synthesize confirmationPresenter;
@synthesize isProcessing;
@synthesize parentWindowController;
@synthesize parentWindow;
@synthesize parentTabViewItem;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection connector:(SPPostgresConnector *)theConnector favorite:(SPPostgresFavorite *)theFavorite
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		connector = [theConnector retain];
		favorite = [theFavorite copy];
		history = [[SPPostgresHistory alloc] init];

		[self _attachCurrentConnection];

		sidebar = [[SPPostgresSidebarController alloc] initWithCatalog:catalog];
		[sidebar setDelegate:self];
		if ([sidebar lastError]) [self _reportCatalogError:[sidebar lastError]];

		[self _buildContent];
		[self _buildToolbar];

		// Where the tab starts is the first history entry
		[self _recordHistory];
	}

	return self;
}

- (void)dealloc
{
	// Normally torn down by -parentTabDidClose already. If not, the (unretained) window may be gone:
	// don't touch it, just close the connection.
	parentWindowController = nil;
	parentWindow = nil;
	parentTabViewItem = nil;
	[self _tearDown];

	[connection release];
	[connector release];
	[favorite release];
	[catalog release];
	[logger release];
	[sidebar release];
	[contentController release];
	[queryController release];
	[history release];
	[pendingHistoryEntry release];
	[duplicateSheet release];
	[duplicateNameField release];
	[duplicateContentSwitch release];
	[duplicateButton release];
	[serverVersion release];
	[currentDatabase release];
	[splitView release];
	[toolbar release];
	[databasePopup release];
	[historyControl release];
	[pendingAlert release];
	[alertPresenter release];
	[confirmationPresenter release];

	[super dealloc];
}

/// Catalog, console logger, database name and server version for the current connection.
- (void)_attachCurrentConnection
{
	[currentDatabase release];
	currentDatabase = nil;

	if ([[favorite database] length]) {
		currentDatabase = [[favorite database] copy];
	}
	else {
		// No database in the favorite: the server picked the default one
		PGPostgresResult *result = [connection execute:@"SELECT current_database()"];
		if ([result numberOfRows]) currentDatabase = [[[result rowAsArray] firstObject] copy];
		if (![currentDatabase isKindOfClass:[NSString class]]) [currentDatabase release], currentDatabase = nil;
		if (!currentDatabase) currentDatabase = [([connection database] ?: @"") copy];
	}

	[logger release];
	logger = [[SPPostgresConsoleLogger alloc] initWithConnectionName:[self _connectionName] database:currentDatabase];
	[logger attachToConnection:connection];

	[catalog release];
	catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];

	// server_version may carry a build suffix ("18.6 (Debian 18.6-1.pgdg13+2)"): the title shows the number
	NSString *version = [[[catalog serverVersionString] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] firstObject];
	if (![version length] && [connection isConnected]) {
		// The query failed: libpq knows the version from the connection (e.g. 180006, or 90624 before 10)
		NSInteger number = (NSInteger)[connection serverVersion];
		if (number >= 100000) version = [NSString stringWithFormat:@"%ld.%ld", (long)(number / 10000), (long)(number % 10000)];
		else if (number > 0) version = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)(number / 10000), (long)(number / 100 % 100), (long)(number % 100)];
	}
	[serverVersion release];
	serverVersion = [([version length] ? version : @"unknown") copy];
}

- (NSString *)_connectionName
{
	if ([[favorite name] length]) return [favorite name];
	if ([[favorite user] length] && [[favorite host] length]) return [NSString stringWithFormat:@"%@@%@", [favorite user], [favorite host]];
	return [favorite host] ?: @"PostgreSQL";
}

/// Left panel | content, as MySQL's DBViewSplitter. The window's tab bar is used; the tab has none of its own.
- (void)_buildContent
{
	NSRect splitFrame = NSMakeRect(0, 0, SPPostgresSplitViewSize.width, SPPostgresSplitViewSize.height);
	splitView = [[SPSplitView alloc] initWithFrame:splitFrame];
	[splitView setVertical:YES];
	[splitView setDividerStyle:NSSplitViewDividerStyleThin];
	[splitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSView *sidebarView = [sidebar view];
	[sidebarView setFrame:NSMakeRect(0, 0, SPPostgresSidebarDefaultWidth, NSHeight(splitFrame))];
	[sidebarView setAutoresizingMask:NSViewHeightSizable]; // keeps its width as the window resizes
	[splitView addSubview:sidebarView];

	// The right pane: the Content view of the selected table
	CGFloat contentX = SPPostgresSidebarDefaultWidth + [splitView dividerThickness];
	NSView *mainView = [[[NSView alloc] initWithFrame:NSMakeRect(contentX, 0, NSWidth(splitFrame) - contentX, NSHeight(splitFrame))] autorelease];
	[mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[splitView addSubview:mainView];
	[self _installQueryController];
	[self _installContentController];

	// Constrained, and resized with the window, as MySQL's left pane (see -[SPDatabaseDocument splitView:constrain...])
	[splitView setCollapsibleSubviewIndex:0];
	[splitView setDelegate:self];
	[splitView adjustSubviews];
	[splitView setAutosaveName:SPPostgresSplitterName];
}

/// The right pane (Content or Query view), or nil before it is built.
- (NSView *)_rightPane
{
	if ([[splitView subviews] count] < 2) return nil;
	return [[splitView subviews] lastObject];
}

/**
 * A Content controller on the current connection (replacing the previous one, which is on the previous
 * connection), in the right pane while the Content view is showing, showing the selected table.
 */
- (void)_installContentController
{
	NSView *pane = [self _rightPane];
	if (!pane) return;

	if (contentController) {
		[[contentController view] removeFromSuperview];
		[contentController invalidate];
		[contentController release];
	}

	contentController = [[SPPostgresContentController alloc] initWithConnection:connection];

	// Through the tab's own presenter (a test's, or a sheet once the tab is visible). Unretained: the
	// controller is this document's, and -_tearDown drops the block.
	__block SPPostgresDocument *document = self;
	[contentController setAlertPresenter:^(NSAlert *alert) {
		[document _presentAlert:alert];
	}];

	NSView *contentView = [contentController view];
	[contentView setFrame:[pane bounds]];
	[contentView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	if (!showingQuery) [pane addSubview:contentView];

	[self _showSelectedTable];
}

/**
 * A Query controller on the current connection (replacing the previous one, which is on the previous
 * connection), keeping the editor's text; in the right pane while the Query view is showing.
 */
- (void)_installQueryController
{
	NSView *pane = [self _rightPane];
	if (!pane) return;

	NSString *text = [[[[queryController editor] string] copy] autorelease];

	if (queryController) {
		[[queryController view] removeFromSuperview];
		[queryController invalidate];
		[queryController release];
	}

	queryController = [[SPPostgresQueryController alloc] initWithConnection:connection];
	if ([text length]) [[queryController editor] setString:text];

	NSView *queryView = [queryController view];
	[queryView setFrame:[pane bounds]];
	[queryView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	if (showingQuery) [pane addSubview:queryView];
}

/**
 * Shows the Query view or the Content view in the right pane, as MySQL's tab view does. The other view is
 * taken out of the window (keeping its state), so its key equivalents don't apply meanwhile. An edit in
 * progress in the Content grid is ended (saved) first; if it can't end, nothing changes.
 */
- (void)_showQueryPane:(BOOL)query
{
	NSView *pane = [self _rightPane];
	if (!pane) return;

	NSView *showing = query ? [queryController view] : [contentController view];
	NSView *hiding = query ? [contentController view] : [queryController view];

	if ([hiding superview] && [pane window]) {
		NSResponder *responder = [[pane window] firstResponder];
		BOOL editingInHiding = [responder isKindOfClass:[NSView class]] && [(NSView *)responder isDescendantOf:hiding];
		if (editingInHiding && ![[pane window] makeFirstResponder:nil]) return;
	}

	showingQuery = query;

	[hiding removeFromSuperview];
	if ([showing superview] != pane) {
		[showing setFrame:[pane bounds]];
		[pane addSubview:showing];
	}

	[toolbar setSelectedItemIdentifier:query ? SPMainToolbarCustomQuery : ([[sidebar selectedTableName] length] ? SPMainToolbarTableContent : nil)];
	[toolbar validateVisibleItems];

	[self _recordHistory];
}

/// The Content view shows the table or view selected in the sidebar (or nothing), and the Content toolbar item is selected with it.
- (void)_showSelectedTable
{
	NSString *table = [sidebar selectedTableName];
	NSString *schema = [sidebar selectedSchema];

	if (![table isEqualToString:[contentController table]] || ![schema isEqualToString:[contentController schema]] || !table) {
		[contentController showTable:table inSchema:schema];
	}

	// The Query view stays when the selection changes (as MySQL's)
	[toolbar setSelectedItemIdentifier:showingQuery ? SPMainToolbarCustomQuery : ([table length] ? SPMainToolbarTableContent : nil)];
	[toolbar validateVisibleItems];
}

- (void)_buildToolbar
{
	// As MySQL's picker and history control (DBView.xib), see SPMainToolbar.m
	databasePopup = [SPCreateDatabaseToolbarPopUpButton() retain];
	[databasePopup setToolTip:NSLocalizedString(@"Select a database to view", @"PostgreSQL window: database picker tooltip")];
	[databasePopup setTarget:self];
	[databasePopup setAction:@selector(chooseDatabase:)];
	[self _reloadDatabasePopup];

	// Back and forward through the tab's history, as MySQL's control (SPHistoryController)
	historyControl = [SPCreateHistoryToolbarControl() retain];
	[historyControl setTarget:self];
	[historyControl setAction:@selector(historyControlClicked:)];

	// Installed in the window while this tab is active (see -didBecomeActiveTabInWindow). Set up as
	// MySQL's toolbar, so the user's saved layout and customizing it apply to both engines.
	toolbar = [[NSToolbar alloc] initWithIdentifier:SPPostgresDocumentToolbarIdentifier];
	[toolbar setAllowsUserCustomization:YES];
	[toolbar setAutosavesConfiguration:YES];
	[toolbar setShowsBaselineSeparator:NO];
	[toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
	[toolbar setDelegate:self];
}

- (NSToolbar *)toolbar
{
	return toolbar;
}

- (NSView *)databaseView
{
	return splitView;
}

#pragma mark - Tab document

- (BOOL)_isSelectedTab
{
	return parentWindowController && (id)[parentWindowController selectedDocument] == self;
}

/**
 * Installs this tab's toolbar (keeping the window's toolbar visibility, as MySQL tabs do), the
 * compact chrome and the window title.
 */
- (void)didBecomeActiveTabInWindow
{
	if (tornDown) return;

	BOOL toolbarVisible = ![parentWindow toolbar] || [[parentWindow toolbar] isVisible];
	[parentWindow setToolbar:toolbar];
	[[parentWindow toolbar] setVisible:toolbarVisible];

	// A layout saved before Transfer existed gets it once (the toolbar has its items once in a window)
	SPInsertTransferToolbarItemIfNeeded(toolbar, [NSUserDefaults standardUserDefaults]);

	// Compact title and toolbar layout, kept centered as the window resizes
	[parentWindow sp_useExpandedCompactToolbar];

	// A MySQL tab shows its .spf file as the window's proxy icon; this tab has none
	[parentWindow setRepresentedURL:nil];

	[self _applyWindowTitle];
	[self _updateDatabaseToolbarItemWidth];
	[self _updateHistoryControl];

	[self _presentPendingAlert];
}

- (void)willResignActiveTabInWindow
{
	// Nothing to take down: the next tab installs its own toolbar and title
}

- (void)tabDidBecomeKey
{
	[self _presentPendingAlert];
}

- (NSString *)tabToolTip
{
	return [self windowTitleString];
}

/// The other open Postgres tabs of this window with the same connection name.
- (NSArray *)_namesakeTabs
{
	NSMutableArray *namesakes = [NSMutableArray array];
	NSString *name = [self _connectionName];

	for (id document in [parentWindowController tabDocuments]) {
		if (document == self || ![document isKindOfClass:[SPPostgresDocument class]]) continue;
		SPPostgresDocument *other = document;
		if (other->tornDown) continue;
		if ([[other _connectionName] isEqualToString:name]) [namesakes addObject:other];
	}

	return namesakes;
}

/**
 * The favorite name, plus @"/<database>" while another Postgres tab of the window has the same name
 * (as MySQL tabs add the database to tell connections to the same server apart).
 */
- (NSString *)tabLabel
{
	NSString *name = [self _connectionName];
	if ([currentDatabase length] && [[self _namesakeTabs] count]) return [NSString stringWithFormat:@"%@/%@", name, currentDatabase];
	return name;
}

/// Tab label (see -tabLabel) and colour (favorite colour); the window title too when this tab is selected.
- (void)updateWindowTitle:(id)sender
{
	if (tornDown) return;

	[parentTabViewItem setLabel:[self tabLabel]];
	[parentTabViewItem setColor:[[SPFavoriteColorSupport sharedInstance] colorForIndex:[favorite colorIndex]]];

	// Namesakes need the database in their labels too, also when this tab was added without being
	// selected (the window controller then only asks this tab to update)
	for (SPPostgresDocument *other in [self _namesakeTabs]) {
		if (![[[other parentTabViewItem] label] isEqualToString:[other tabLabel]]) [other updateWindowTitle:parentWindowController];
	}

	[parentWindowController updateTabBar];

	if ([self _isSelectedTab]) [self _applyWindowTitle];

	// As MySQL tabs: a change of our own may change other tabs' titles
	if (![sender isKindOfClass:[SPWindowController class]]) [parentWindowController updateAllTabTitles:self];
}

- (BOOL)parentTabShouldClose
{
	return YES;
}

/// The tab was closed: disconnects (closing the SSH tunnel too) and detaches from the window.
- (void)parentTabDidClose
{
	NSArray *namesakes = [[[self _namesakeTabs] retain] autorelease];

	[self _tearDown];

	// A namesake left alone no longer needs the database in its label (this tab is out of the window's tabs by now)
	for (SPPostgresDocument *other in namesakes) [other updateWindowTitle:[other parentWindowController]];
}

#pragma mark - Title

- (NSString *)windowTitleString
{
	NSMutableString *title = [NSMutableString stringWithFormat:@"(PostgreSQL %@) %@/%@", serverVersion, [self _connectionName], currentDatabase ?: @""];

	NSString *table = [sidebar selectedTableName];
	if ([table length]) [title appendFormat:@"/%@.%@", [sidebar selectedSchema], table];

	return title;
}

- (void)_applyWindowTitle
{
	if (!parentWindow) return;
	[parentWindow setTitle:[self windowTitleString]];
	[parentWindow sp_applyCompactTitle];
}

#pragma mark - Alerts

- (void)_presentAlert:(NSAlert *)alert
{
	if (tornDown) return;

	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}

	// Not shown yet, or another tab is in front: show it when this tab is active again
	if (![self _isSelectedTab] || ![parentWindow isVisible]) {
		if (!pendingAlert) pendingAlert = [alert retain];
		return;
	}

	[alert beginSheetModalForWindow:parentWindow completionHandler:nil];
}

- (void)_presentPendingAlert
{
	if (!pendingAlert || ![self _isSelectedTab] || ![parentWindow isVisible]) return;

	NSAlert *alert = pendingAlert;
	pendingAlert = nil;
	[self _presentAlert:alert];
	[alert release];
}

/// Asks alert's question (first button: proceed); completion runs exactly once.
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
	if (!parentWindow) {
		once([alert runModal] == NSAlertFirstButtonReturn);
		return;
	}
	[alert beginSheetModalForWindow:parentWindow completionHandler:^(NSModalResponse response) {
		once(response == NSAlertFirstButtonReturn);
	}];
}

/**
 * A catalog query failed (the lists keep what they showed). Shown once per failed reload; when the
 * connection is gone, says so (reconnecting is not offered in this version).
 */
- (void)_reportCatalogError:(NSError *)error
{
	NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];

	NSString *advice;
	if (![connection isConnected]) {
		[alert setMessageText:NSLocalizedString(@"The connection to the PostgreSQL server was lost", @"PostgreSQL window: connection lost title")];
		advice = NSLocalizedString(@"The lists show what was loaded before the connection was lost. Close this tab and connect again.", @"PostgreSQL tab: connection lost advice");
	}
	else {
		[alert setMessageText:NSLocalizedString(@"Could not load the database objects", @"PostgreSQL window: catalog query failed title")];
		advice = NSLocalizedString(@"The lists show what was loaded before.", @"PostgreSQL window: catalog query failed advice");
	}
	[alert setInformativeText:[detail length] ? [NSString stringWithFormat:@"%@\n\n%@", detail, advice] : advice];

	[self _presentAlert:alert];
}

#pragma mark - Teardown

/// Closes the connection and detaches everything that points back at this document. Idempotent.
- (void)_tearDown
{
	if (tornDown) return;
	tornDown = YES;

	// A pending database switch completes (cancelled) and lets go of its block, which retains self
	SPPostgresConnector *pending = pendingConnector;
	pendingConnector = nil;
	[pending cancel];
	[pending release];
	if (isProcessing) [self setIsProcessing:NO];
	[pendingHistoryEntry release];
	pendingHistoryEntry = nil;

	// A Duplicate Table sheet still up (its completion sees tornDown)
	if (duplicateSheet) [[duplicateSheet sheetParent] endSheet:duplicateSheet returnCode:NSModalResponseCancel];

	[connector disconnect];

	[sidebar invalidate];
	[sidebar setDelegate:nil];
	[contentController invalidate];
	[queryController invalidate];
	[splitView setDelegate:nil];
	[databasePopup setTarget:nil];
	[historyControl setTarget:nil];
	[self _updateHistoryControl];

	for (NSToolbarItem *item in [toolbar items]) [item setTarget:nil];
	[toolbar setDelegate:nil];
	databaseToolbarItem = nil;
	if ([parentWindow toolbar] == toolbar) [parentWindow setToolbar:nil];

	// A presenter block may capture this document
	[alertPresenter release];
	alertPresenter = nil;
	[confirmationPresenter release];
	confirmationPresenter = nil;
	[pendingAlert release];
	pendingAlert = nil;

	// The window, its controller and the tab item may go away before this document does
	parentWindowController = nil;
	parentWindow = nil;
	parentTabViewItem = nil;
}

#pragma mark - Sidebar

- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)theSidebar
{
	if (tornDown) return;
	[self _showSelectedTable];
	[self updateWindowTitle:self];
	[self _recordHistory];
}

- (void)sidebar:(SPPostgresSidebarController *)theSidebar didFailToLoadWithError:(NSError *)error
{
	[self _reportCatalogError:error];
}

- (void)sidebar:(SPPostgresSidebarController *)theSidebar duplicateTableNamed:(NSString *)table
{
	[self _showDuplicateTableSheetForTable:table];
}

#pragma mark - Databases

- (void)_reloadDatabasePopup
{
	NSError *error = nil;
	NSArray *names = [catalog databaseNames:&error];

	if (!names) {
		// Keep the databases that were listed (the separator and "Refresh Databases" follow them)
		NSInteger listed = [databasePopup numberOfItems] - 2;
		names = (listed > 0) ? [[databasePopup itemTitles] subarrayWithRange:NSMakeRange(0, (NSUInteger)listed)] : @[];
		[self _reportCatalogError:error];
	}

	[databasePopup removeAllItems];
	[databasePopup addItemsWithTitles:names];
	if ([currentDatabase length] && ![names containsObject:currentDatabase]) [databasePopup addItemWithTitle:currentDatabase];

	[[databasePopup menu] addItem:[NSMenuItem separatorItem]];
	NSMenuItem *refresh = [[databasePopup menu] addItemWithTitle:NSLocalizedString(@"Refresh Databases", @"menu item to refresh databases") action:@selector(refreshDatabases:) keyEquivalent:@""];
	[refresh setTarget:self];

	if ([currentDatabase length]) [databasePopup selectItemWithTitle:currentDatabase];
}

- (void)refreshDatabases:(id)sender
{
	if (tornDown) return;
	[self _reloadDatabasePopup];
}

- (void)chooseDatabase:(id)sender
{
	NSString *database = [databasePopup titleOfSelectedItem];
	if ([database isEqualToString:currentDatabase]) return;
	[self switchToDatabase:database];
}

/// The pop-up shows the database the tab is in (after a switch that didn't start).
- (void)_selectCurrentDatabaseInPopup
{
	if ([currentDatabase length] && [databasePopup indexOfItemWithTitle:currentDatabase] >= 0) [databasePopup selectItemWithTitle:currentDatabase];
}

- (void)switchToDatabase:(NSString *)database
{
	if (tornDown || confirmingSwitch || ![database length]) {
		[self _selectCurrentDatabaseInPopup];
		return;
	}

	// As MySQL's (couldCommitCurrentViewActions): an edit in progress in the Content grid is saved first
	if (![self _endContentEditing]) {
		[self _selectCurrentDatabaseInPopup];
		return;
	}

	[self _confirmLeavingSession:^(BOOL proceed) {
		if (proceed) [self _switchToDatabase:database forHistory:NO];
		else [self _selectCurrentDatabaseInPopup];
	}];
}

/// Ends an edit in progress in the Content grid (saving it); NO if it couldn't end (e.g. the value was refused).
- (BOOL)_endContentEditing
{
	NSResponder *responder = [parentWindow firstResponder];
	if ([responder isKindOfClass:[NSView class]] && [(NSView *)responder isDescendantOf:[contentController view]]) {
		return [parentWindow makeFirstResponder:nil];
	}
	return YES;
}

/**
 * Closing this session (a database switch) rolls back a transaction the user opened in the Query view:
 * when one is open (or aborted) they are asked first. completion(YES) when the switch may go ahead.
 */
- (void)_confirmLeavingSession:(void (^)(BOOL proceed))completion
{
	PGPostgresTransactionStatus status = [connection transactionStatus];
	if (status != PGPostgresTransactionInTransaction && status != PGPostgresTransactionInError) {
		completion(YES);
		return;
	}

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:NSLocalizedString(@"Switch", @"PostgreSQL database switch with open transaction: switch button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
	[[[alert buttons] objectAtIndex:1] setKeyEquivalent:@"\033"];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:NSLocalizedString(@"You have an open transaction.", @"PostgreSQL database switch with open transaction: title")];
	[alert setInformativeText:NSLocalizedString(@"Switching database will roll it back. Are you sure you want to continue?", @"PostgreSQL database switch with open transaction: message")];

	confirmingSwitch = YES;
	[self _updateHistoryControl];

	// The document stays alive until the answer comes (a sheet's or a presenter's)
	[self retain];
	void (^after)(BOOL) = [[completion copy] autorelease];
	[after retain];
	[self _confirm:alert completion:^(BOOL confirmed) {
		confirmingSwitch = NO;
		[self _updateHistoryControl];
		after(confirmed && !tornDown);
		[after release];
		[self release];
	}];
}

/// forHistory: to show pendingHistoryEntry; else (the user's choice) a history move waiting for a switch is given up.
- (void)_switchToDatabase:(NSString *)database forHistory:(BOOL)forHistory
{
	if (tornDown || ![database length]) return;
	if (!forHistory && pendingHistoryEntry) [self _abandonHistoryRestore];
	if ([database isEqualToString:currentDatabase] && !pendingConnector) return;

	SPPostgresFavorite *target = [[favorite copy] autorelease];
	[target setDatabase:database];

	// Same favorite and the passwords the current session was opened with, so an SSH favorite isn't asked
	// again (without one, SSH passwords come from the Keychain or the tunnel's prompt on this window)
	NSString *thePassword = [connector password] ?: [connection password];
	SPPostgresConnector *newConnector = [[SPPostgresConnector alloc] initWithFavorite:target password:thePassword sshPassword:[connector sshPassword] parentWindow:parentWindow];

	// Only the latest request counts: an earlier pending one is abandoned (its completion is then ignored)
	SPPostgresConnector *previous = pendingConnector;
	pendingConnector = newConnector;
	[previous cancel];
	[previous release];

	[databasePopup setEnabled:NO];
	if (!isProcessing) [self setIsProcessing:YES];
	[self _updateHistoryControl];

	// The connector keeps the completion until it is called (always exactly once), which also keeps self
	// alive meanwhile; the connector itself is captured unretained to avoid a connector -> block -> connector cycle.
	__block SPPostgresConnector *blockConnector = newConnector;
	[newConnector connectWithCompletion:^(PGPostgresConnection *newConnection, NSError *error) {
		[self _databaseSwitchBy:blockConnector favorite:target finishedWithConnection:newConnection error:error];
	}];
}

- (void)_databaseSwitchBy:(SPPostgresConnector *)theConnector favorite:(SPPostgresFavorite *)theFavorite finishedWithConnection:(PGPostgresConnection *)newConnection error:(NSError *)error
{
	// Superseded, or cancelled by the tab closing
	if (theConnector != pendingConnector) return;

	SPPostgresConnector *newConnector = pendingConnector; // takes over our reference
	pendingConnector = nil;
	[databasePopup setEnabled:YES];
	[self setIsProcessing:NO];

	if (!newConnection) {
		[newConnector release];
		if ([databasePopup indexOfItemWithTitle:currentDatabase] >= 0) [databasePopup selectItemWithTitle:currentDatabase];

		// A history move to that database didn't happen: back where it was, so it can be tried again
		if (pendingHistoryEntry) [self _abandonHistoryRestore];
		[self _updateHistoryControl];

		if ([error code] != SPPostgresErrorCancelled || ![[error domain] isEqualToString:SPPostgresErrorDomain]) {
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setAlertStyle:NSAlertStyleWarning];
			[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Could not open database “%@”", @"PostgreSQL window: database switch failed (database)"), [theFavorite database]]];
			[alert setInformativeText:[error localizedDescription] ?: @""];
			[self _presentAlert:alert];
		}
		return;
	}

	SPPostgresConnector *oldConnector = connector;

	connector = newConnector;
	[connection release];
	connection = [newConnection retain];
	[favorite release];
	favorite = [theFavorite retain];

	[self _attachCurrentConnection];

	// A history move: the reload's default schema is not a place the user went to
	NSDictionary *historyEntry = [[pendingHistoryEntry retain] autorelease];
	[pendingHistoryEntry release];
	pendingHistoryEntry = nil;
	if (historyEntry) restoringHistory = YES;

	[sidebar reloadWithCatalog:catalog];
	[self _installQueryController];
	[self _installContentController];
	[self _reloadDatabasePopup];

	if (historyEntry) [self _applyHistoryEntry:historyEntry];
	restoringHistory = NO;

	[self updateWindowTitle:self];
	[self _updateHistoryControl];

	// Only now let the previous session go
	[oldConnector disconnect];
	[oldConnector release];
}

#pragma mark - History

/// Records where the tab is now (database, schema, table, Content or Query view), unless a history entry is being shown.
- (void)_recordHistory
{
	if (tornDown || restoringHistory || pendingHistoryEntry || ![currentDatabase length]) return;
	[history recordDatabase:currentDatabase schema:[sidebar selectedSchema] table:[sidebar selectedTableName] pane:showingQuery ? @"query" : @"content"];
	[self _updateHistoryControl];
}

/// The History control's segments follow canGoBack/canGoForward (both off while a database switch connects).
- (void)_updateHistoryControl
{
	BOOL enabled = !tornDown && !isProcessing && !confirmingSwitch;
	[historyControl setEnabled:enabled && [history canGoBack] forSegment:0];
	[historyControl setEnabled:enabled && [history canGoForward] forSegment:1];
}

/// The History toolbar control: segment 0 goes back, 1 forward.
- (IBAction)historyControlClicked:(NSSegmentedControl *)sender
{
	switch ([sender selectedSegment]) {
		case 0: [self _goBackInHistory:YES]; break;
		case 1: [self _goBackInHistory:NO]; break;
	}
}

/// View > Back In History (tag 0) and Forward In History (tag 1), as on MySQL tabs.
- (IBAction)backForwardInHistory:(id)sender
{
	switch ([sender tag]) {
		case 0: [self _goBackInHistory:YES]; break;
		case 1: [self _goBackInHistory:NO]; break;
	}
}

/// Shows the previous (back) or next history entry, switching database first if it is in another one.
- (void)_goBackInHistory:(BOOL)back
{
	if (tornDown || isProcessing || confirmingSwitch) return;

	// As MySQL's (couldCommitCurrentViewActions): an edit in progress in the Content grid is ended (saved) first
	if (![self _endContentEditing]) return;

	NSDictionary *entry = back ? [history goBack] : [history goForward];
	if (!entry) return;

	NSString *database = [entry objectForKey:@"database"];
	if ([database length] && ![database isEqualToString:currentDatabase]) {
		// Shown once the switch is done (see -_databaseSwitchBy:…), or undone if it fails or isn't confirmed
		[pendingHistoryEntry release];
		pendingHistoryEntry = [entry retain];
		pendingHistoryWentBack = back;
		[self _confirmLeavingSession:^(BOOL proceed) {
			if (proceed) [self _switchToDatabase:database forHistory:YES];

			// No switch was started (cancelled, or torn down): the entry mustn't stay pending, which would stop
			// recording for good
			if (!pendingConnector) [self _abandonHistoryRestore];
			[self _updateHistoryControl];
		}];
	}
	else {
		[self _applyHistoryEntry:entry];
	}
	[self _updateHistoryControl];
}

/// Selects the entry's schema, table (none if it had none) and view, without recording that as a new entry.
- (void)_applyHistoryEntry:(NSDictionary *)entry
{
	restoringHistory = YES;

	NSString *schema = [entry objectForKey:@"schema"];
	if ([schema length] && ![schema isEqualToString:[sidebar selectedSchema]]) [sidebar reloadSchema:schema];

	// A table of the entry's schema only (a schema that can't be loaded any more leaves the table unselected)
	NSString *table = [entry objectForKey:@"table"];
	if (![table length] || ([schema length] && ![schema isEqualToString:[sidebar selectedSchema]]) || ![sidebar selectTableNamed:table]) {
		[sidebar selectTableNamed:nil];
	}

	[self _showQueryPane:[[entry objectForKey:@"pane"] isEqualToString:@"query"]];

	restoringHistory = NO;
}

/// A history move waiting for a database switch is given up: the history goes back to where it was.
- (void)_abandonHistoryRestore
{
	if (!pendingHistoryEntry) return;
	[pendingHistoryEntry release];
	pendingHistoryEntry = nil;
	if (pendingHistoryWentBack) [history goForward];
	else [history goBack];
	[self _updateHistoryControl];
}

#pragma mark - Duplicate Table

/// A sheet as MySQL's Duplicate Table sheet (DBView.xib): the new name (<table>_copy), "Duplicate table content", Cancel/Duplicate.
- (void)_showDuplicateTableSheetForTable:(NSString *)table
{
	if (tornDown || duplicateSheet || ![table length] || !parentWindow || isProcessing) return;

	// An edit in progress in the Content grid is ended (saved) first, as MySQL's
	if (![parentWindow makeFirstResponder:nil]) return;

	NSString *schema = [[[sidebar selectedSchema] copy] autorelease];
	if (![schema length]) return;

	NSRect frame = NSMakeRect(0, 0, 260, 127);
	duplicateSheet = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[duplicateSheet setReleasedWhenClosed:NO];
	[duplicateSheet setTitle:NSLocalizedString(@"Duplicate Table", @"PostgreSQL duplicate table sheet title")];
	[duplicateSheet setContentMinSize:NSMakeSize(260, 127)];
	[duplicateSheet setContentMaxSize:NSMakeSize(600, 127)];
	NSView *content = [duplicateSheet contentView];
	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

	NSTextField *message = [NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Duplicate %@ '%@' to:", @"duplicate object message"), NSLocalizedString(@"table", @"table"), table]];
	[message setFrame:NSMakeRect(17, 93, 226, 14)];
	[message setFont:smallFont];
	[message setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[message setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:message];

	duplicateNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 66, 222, 19)];
	[duplicateNameField setIdentifier:@"duplicateTableName"];
	[[duplicateNameField cell] setControlSize:NSControlSizeSmall];
	[duplicateNameField setFont:smallFont];
	[[duplicateNameField cell] setUsesSingleLineMode:YES];
	[[duplicateNameField cell] setScrollable:YES];
	[duplicateNameField setStringValue:[table stringByAppendingString:@"_copy"]];
	[duplicateNameField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[duplicateNameField setDelegate:(id<NSTextFieldDelegate>)self];
	[content addSubview:duplicateNameField];

	duplicateContentSwitch = [[NSButton checkboxWithTitle:NSLocalizedString(@"Duplicate table content", @"PostgreSQL duplicate table sheet: copy content checkbox") target:nil action:NULL] retain];
	[duplicateContentSwitch setIdentifier:@"duplicateTableContent"];
	[duplicateContentSwitch setFrame:NSMakeRect(17, 43, 227, 18)];
	[duplicateContentSwitch setControlSize:NSControlSizeSmall];
	[duplicateContentSwitch setFont:smallFont];
	// MySQL's preference for this checkbox (read only: the sheet doesn't change it)
	[duplicateContentSwitch setState:[[NSUserDefaults standardUserDefaults] boolForKey:SPCopyContentOnTableCopy] ? NSControlStateValueOn : NSControlStateValueOff];
	[duplicateContentSwitch setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[content addSubview:duplicateContentSwitch];

	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(closeDuplicateTableSheet:)];
	[cancel setFrame:NSMakeRect(61, 13, 91, 28)];
	[cancel setControlSize:NSControlSizeSmall];
	[cancel setFont:smallFont];
	[cancel setTag:NSModalResponseCancel];
	[cancel setKeyEquivalent:@"\e"];
	[cancel setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancel];

	duplicateButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Duplicate", @"PostgreSQL duplicate table sheet: duplicate button") target:self action:@selector(closeDuplicateTableSheet:)] retain];
	[duplicateButton setIdentifier:@"duplicateTableButton"];
	[duplicateButton setFrame:NSMakeRect(150, 13, 97, 28)];
	[duplicateButton setControlSize:NSControlSizeSmall];
	[duplicateButton setFont:smallFont];
	[duplicateButton setTag:NSModalResponseOK];
	[duplicateButton setKeyEquivalent:@"\r"];
	[duplicateButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:duplicateButton];

	[duplicateSheet setInitialFirstResponder:duplicateNameField];
	[self controlTextDidChange:nil];

	[parentWindow beginSheet:duplicateSheet completionHandler:^(NSModalResponse returnCode) {
		NSString *newName = [[[duplicateNameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
		BOOL withContent = ([duplicateContentSwitch state] == NSControlStateValueOn);

		[duplicateNameField setDelegate:nil];
		[duplicateSheet orderOut:nil];
		[duplicateSheet release], duplicateSheet = nil;
		[duplicateNameField release], duplicateNameField = nil;
		[duplicateContentSwitch release], duplicateContentSwitch = nil;
		[duplicateButton release], duplicateButton = nil;

		if (returnCode == NSModalResponseOK && !tornDown && [newName length]) {
			[self _duplicateTable:table inSchema:schema toName:newName withContent:withContent];
		}
		[newName release];
	}];
}

/// The sheet's name, trimmed.
- (NSString *)_duplicateTableName
{
	return [[duplicateNameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// Duplicate is enabled while the name is one PostgreSQL keeps as given (not empty, at most 63 bytes).
- (void)controlTextDidChange:(NSNotification *)notification
{
	[duplicateButton setEnabled:[SPPostgresTableDuplicator isValidTableName:[self _duplicateTableName]]];
}

- (void)closeDuplicateTableSheet:(id)sender
{
	if (!duplicateSheet) return;
	if ([sender tag] == NSModalResponseOK && ![SPPostgresTableDuplicator isValidTableName:[self _duplicateTableName]]) {
		NSBeep();
		return;
	}
	[parentWindow endSheet:duplicateSheet returnCode:[sender tag]];
}

/// Duplicates the table; on success lists and selects the copy, else shows the server's message.
- (void)_duplicateTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName withContent:(BOOL)withContent
{
	NSError *error = nil;
	if (![SPPostgresTableDuplicator duplicateTable:table inSchema:schema toName:newName withContent:withContent connection:connection error:&error]) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:NSLocalizedString(@"Error", @"error")];
		[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Couldn't duplicate '%@'.\nPostgreSQL said: %@", @"PostgreSQL duplicate table failed"), table, [error localizedDescription] ?: @""]];
		[self _presentAlert:alert];
		return;
	}

	// The copy is in the schema the sidebar shows (the sheet was modal)
	if (![schema isEqualToString:[sidebar selectedSchema]]) return;

	// The reload's empty selection on the way is not a place the user went to (history)
	restoringHistory = YES;
	[sidebar reloadSchema:schema];
	restoringHistory = NO;
	[sidebar selectTableNamed:newName];
}

#pragma mark - Split view

- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
	[self _updateDatabaseToolbarItemWidth];
}

/// The database picker is as wide as the left panel, as in the MySQL window.
- (void)_updateDatabaseToolbarItemWidth
{
	if (!databaseToolbarItem || [[splitView subviews] count] < 1) return;

	CGFloat width = NSWidth([[[splitView subviews] objectAtIndex:0] frame]) - 9;
	width = MIN(MAX(width, 130), 360);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	[databaseToolbarItem setMinSize:NSMakeSize(width, 26)];
	[databaseToolbarItem setMaxSize:NSMakeSize(width, 32)];
#pragma clang diagnostic pop
}

// The left pane width is shared with MySQL tabs (same autosave name): constrained as theirs

- (CGFloat)splitView:(NSSplitView *)theSplitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex
{
	return (dividerIndex == 0 && proposedMinimumPosition < 40) ? 40 : proposedMinimumPosition;
}

- (CGFloat)splitView:(NSSplitView *)theSplitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex
{
	return (dividerIndex == 0) ? proposedMaximumPosition - 505 : proposedMaximumPosition;
}

#pragma mark - Menus

/**
 * Asked by the window controller for every item it would send to this tab, and for the window's own
 * items: those (tabs, New Tab, Close Tab) stay enabled, and so do this tab's own actions. Everything
 * else (the MySQL-only items) is disabled.
 */
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	SEL action = [item action];

	// Show/hide console, worded as for MySQL tabs
	if (action == @selector(toggleConsole:)) {
		[item setTitle:([[[SPQueryController sharedQueryController] window] isVisible] && [[[NSApp keyWindow] windowController] isKindOfClass:[SPQueryController class]]) ? NSLocalizedString(@"Hide Console", @"hide console") : NSLocalizedString(@"Show Console", @"show console")];
	}

	if (!action || action == @selector(unavailableInThisVersion:)) return NO;

	if ([SPWindowController instancesRespondToSelector:action]) return YES;

	if (tornDown) return NO;

	// As the Content toolbar item
	if (action == @selector(viewContent:)) return [[sidebar selectedTableName] length] > 0;

	// View > Back/Forward In History (tags 0 and 1), as MySQL's
	if (action == @selector(backForwardInHistory:)) {
		if (isProcessing) return NO;
		return ([item tag] == 0) ? [history canGoBack] : [history canGoForward];
	}

	return [self respondsToSelector:action];
}

#pragma mark - Toolbar

/**
 * The same identifiers as the MySQL document's toolbar (SPMainToolbar.m): both use the toolbar
 * identifier TableWindowToolbar and share its saved layout, and toolbars with one identifier sync
 * their items, so this tab must serve every item a MySQL tab can show.
 */
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)theToolbar
{
	return SPMainToolbarAllowedItemIdentifiers();
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)theToolbar
{
	return SPMainToolbarDefaultItemIdentifiers();
}

/// As MySQL's: these items are drawn without a button bezel (and are a few points taller)
- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)theToolbar
{
	return SPMainToolbarSelectableItemIdentifiers();
}

/// The database picker, Table History, the console, Content and Query work on Postgres tabs so far
- (NSArray *)_availableToolbarItemIdentifiers
{
	return @[SPMainToolbarDatabaseSelection, SPMainToolbarHistoryNavigation, SPMainToolbarShowConsole, SPMainToolbarTableContent, SPMainToolbarCustomQuery];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)theToolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
	// The items MySQL tabs show (SPMainToolbar.m): same images, labels, sizes and item kinds
	NSToolbarItem *item = SPCreateMainToolbarItem(identifier);
	if (!item) return nil;

	// The items of features Postgres tabs don't have yet keep an action (as MySQL's do, which is what
	// sizes them), validated off; Transfer has none, as on MySQL tabs
	SEL action = [identifier isEqualToString:SPMainToolbarTransfer] ? NULL : @selector(unavailableInThisVersion:);

	if ([identifier isEqualToString:SPMainToolbarDatabaseSelection]) {
		[item setView:databasePopup];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		// As MySQL's picker: an explicit width that follows the left panel (see -_updateDatabaseToolbarItemWidth)
		[item setMinSize:NSMakeSize(200, 26)];
		[item setMaxSize:NSMakeSize(200, 32)];
#pragma clang diagnostic pop
		if (flag) {
			databaseToolbarItem = item;
			[self _updateDatabaseToolbarItemWidth];
		}
		action = NULL;
	}
	else if ([identifier isEqualToString:SPMainToolbarHistoryNavigation]) {
		[historyControl sizeToFit];
		[item setView:historyControl];
		action = NULL;
	}
	else if ([identifier isEqualToString:SPMainToolbarShowConsole]) {
		[item setToolTip:NSLocalizedString(@"Show the console which shows all PostgreSQL commands performed by Sequel Pro", @"PostgreSQL toolbar: console tooltip")];
		action = @selector(toggleConsole:);
	}
	else if ([identifier isEqualToString:SPMainToolbarTableContent]) {
		action = @selector(viewContent:);
	}
	else if ([identifier isEqualToString:SPMainToolbarCustomQuery]) {
		action = @selector(viewQuery:);
	}
	else if ([identifier isEqualToString:SPMainToolbarClearConsole]) {
		[item setToolTip:NSLocalizedString(@"Clear the console which shows all PostgreSQL commands performed by Sequel Pro", @"PostgreSQL toolbar: clear console tooltip")];
	}

	if (action) {
		[item setTarget:self];
		[item setAction:action];
	}

	return item;
}

- (void)toolbarDidRemoveItem:(NSNotification *)notification
{
	if ([[notification userInfo] objectForKey:@"item"] == databaseToolbarItem) databaseToolbarItem = nil;
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item
{
	NSString *identifier = [item itemIdentifier];

	if (![[self _availableToolbarItemIdentifiers] containsObject:identifier]) return NO;

	if ([identifier isEqualToString:SPMainToolbarShowConsole]) {
		NSWindow *consoleWindow = [[SPQueryController sharedQueryController] window];
		[item setImage:SPCompactToolbarImage([NSImage imageNamed:[consoleWindow isVisible] ? @"showconsole" : @"hideconsole"])];
		return ![consoleWindow isKeyWindow];
	}

	// As MySQL's: Content needs a table (or view)
	if ([identifier isEqualToString:SPMainToolbarTableContent]) {
		return !tornDown && [[sidebar selectedTableName] length] > 0;
	}

	return !tornDown;
}

/// Shows the Content view of the selected table.
- (IBAction)viewContent:(id)sender
{
	if (tornDown || ![[sidebar selectedTableName] length]) return;
	[self _showQueryPane:NO];
	if (showingQuery) return;
	[self _showSelectedTable];
	[[[contentController view] window] makeFirstResponder:[contentController tableView]];
}

/// Shows the Query view, the editor focused.
- (IBAction)viewQuery:(id)sender
{
	if (tornDown) return;
	[self _showQueryPane:YES];
	if (!showingQuery) return;
	[[[queryController view] window] makeFirstResponder:[queryController editor]];
}

- (void)unavailableInThisVersion:(id)sender
{
	// Never enabled (see -validateToolbarItem:): the items of features Postgres tabs don't have yet
}

/// Shows the shared console, or hides it when it is the key window (as MySQL's Toggle Console).
- (void)toggleConsole:(id)sender
{
	SPQueryController *console = [SPQueryController sharedQueryController];
	NSWindow *consoleWindow = [console window];

	if ([consoleWindow isVisible] && [consoleWindow isKeyWindow]) {
		[consoleWindow setIsVisible:NO];
		return;
	}

	// Entries aren't reloaded while the console is hidden
	if (![consoleWindow isVisible]) [console updateEntries];
	[consoleWindow makeKeyAndOrderFront:self];
}

@end
