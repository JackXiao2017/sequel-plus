#import "SPPostgresDocument.h"
#import "SPPostgresSidebarController.h"
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
#import "SPConstants.h"
#import <PostgresKit/PostgresKit.h>

static NSString * const SPPostgresSplitterName = @"PGViewSplitter";
// Shared with MySQL tabs, and so is the saved layout (see -[SPDatabaseDocument setupToolbar])
static NSString * const SPPostgresDocumentToolbarIdentifier = @"TableWindowToolbar";

static const CGFloat SPPostgresSidebarDefaultWidth = 250;

@interface SPPostgresDocument () <SPPostgresSidebarControllerDelegate>

@property (readwrite) BOOL isProcessing;
@property (readwrite, assign) SPWindowController *parentWindowController;
@property (readwrite, assign) NSWindow *parentWindow;
@property (readwrite, assign) NSTabViewItem *parentTabViewItem;

- (void)_attachCurrentConnection;
- (void)_buildContent;
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

@end

@implementation SPPostgresDocument
{
	PGPostgresConnection *connection;
	SPPostgresConnector *connector;
	SPPostgresFavorite *favorite;
	SPPostgresCatalog *catalog;
	SPPostgresConsoleLogger *logger;
	SPPostgresSidebarController *sidebar;

	NSString *serverVersion;
	NSString *currentDatabase;

	/// A database switch in progress (see -switchToDatabase:)
	SPPostgresConnector *pendingConnector;

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
@synthesize connection;
@synthesize favorite;
@synthesize alertPresenter;
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

		[self _attachCurrentConnection];

		sidebar = [[SPPostgresSidebarController alloc] initWithCatalog:catalog];
		[sidebar setDelegate:self];
		if ([sidebar lastError]) [self _reportCatalogError:[sidebar lastError]];

		[self _buildContent];
		[self _buildToolbar];
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
	[serverVersion release];
	[currentDatabase release];
	[splitView release];
	[toolbar release];
	[databasePopup release];
	[historyControl release];
	[pendingAlert release];
	[alertPresenter release];

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
	NSRect splitFrame = NSMakeRect(0, 0, 948, 530);
	splitView = [[SPSplitView alloc] initWithFrame:splitFrame];
	[splitView setVertical:YES];
	[splitView setDividerStyle:NSSplitViewDividerStyleThin];
	[splitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSView *sidebarView = [sidebar view];
	[sidebarView setFrame:NSMakeRect(0, 0, SPPostgresSidebarDefaultWidth, NSHeight(splitFrame))];
	[sidebarView setAutoresizingMask:NSViewHeightSizable]; // keeps its width as the window resizes
	[splitView addSubview:sidebarView];

	// Stage 1 has no table views yet: an empty content pane
	CGFloat contentX = SPPostgresSidebarDefaultWidth + [splitView dividerThickness];
	NSView *mainView = [[[NSView alloc] initWithFrame:NSMakeRect(contentX, 0, NSWidth(splitFrame) - contentX, NSHeight(splitFrame))] autorelease];
	[mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[splitView addSubview:mainView];

	[splitView setMinSize:120 ofSubviewAtIndex:0];
	[splitView setDelegate:self];
	[splitView adjustSubviews];
	[splitView setAutosaveName:SPPostgresSplitterName];
}

- (void)_buildToolbar
{
	databasePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 26) pullsDown:NO];
	[databasePopup setBezelStyle:NSBezelStyleTexturedRounded];
	[databasePopup setFont:[NSFont titleBarFontOfSize:12]];
	[[databasePopup cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[databasePopup setToolTip:NSLocalizedString(@"Select a database to view", @"PostgreSQL window: database picker tooltip")];
	[databasePopup setTarget:self];
	[databasePopup setAction:@selector(chooseDatabase:)];
	[self _reloadDatabasePopup];

	// Same control as MySQL's history navigation (DBView.xib); stage 1 has no history yet
	historyControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 57, 25)];
	[historyControl setSegmentCount:2];
	[historyControl setSegmentStyle:NSSegmentStyleTexturedSquare];
	[historyControl setTrackingMode:NSSegmentSwitchTrackingMomentary];
	[historyControl setImage:[NSImage imageNamed:NSImageNameGoLeftTemplate] forSegment:0];
	[historyControl setImage:[NSImage imageNamed:NSImageNameGoRightTemplate] forSegment:1];
	[historyControl setWidth:27 forSegment:0];
	[historyControl setWidth:27 forSegment:1];
	[historyControl setToolTip:NSLocalizedString(@"Back", @"history back") forSegment:0];
	[historyControl setToolTip:NSLocalizedString(@"Forward", @"history forward") forSegment:1];
	[historyControl setEnabled:NO];
	[historyControl sizeToFit];

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

	[connector disconnect];

	[sidebar invalidate];
	[sidebar setDelegate:nil];
	[splitView setDelegate:nil];
	[databasePopup setTarget:nil];

	for (NSToolbarItem *item in [toolbar items]) [item setTarget:nil];
	[toolbar setDelegate:nil];
	databaseToolbarItem = nil;
	if ([parentWindow toolbar] == toolbar) [parentWindow setToolbar:nil];

	// A presenter block may capture this document
	[alertPresenter release];
	alertPresenter = nil;
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
	[self updateWindowTitle:self];
}

- (void)sidebar:(SPPostgresSidebarController *)theSidebar didFailToLoadWithError:(NSError *)error
{
	[self _reportCatalogError:error];
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

- (void)switchToDatabase:(NSString *)database
{
	if (tornDown || ![database length]) return;
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
	[sidebar reloadWithCatalog:catalog];
	[self _reloadDatabasePopup];
	[self updateWindowTitle:self];

	// Only now let the previous session go
	[oldConnector disconnect];
	[oldConnector release];
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

- (CGFloat)splitView:(NSSplitView *)theSplitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex
{
	// Keep a usable content pane
	return (dividerIndex == 0) ? MAX(proposedMaximumPosition - 400, 120) : proposedMaximumPosition;
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

	return [self respondsToSelector:action];
}

#pragma mark - Toolbar

/**
 * The same identifiers as the MySQL document's toolbar (-[SPDatabaseDocument toolbarAllowedItemIdentifiers:]):
 * both use the toolbar identifier TableWindowToolbar and share its saved layout, and toolbars with one
 * identifier sync their items, so this tab must serve every item a MySQL tab can show.
 */
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)theToolbar
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return @[
		SPMainToolbarDatabaseSelection,
		SPMainToolbarHistoryNavigation,
		SPMainToolbarShowConsole,
		SPMainToolbarClearConsole,
		SPMainToolbarTableStructure,
		SPMainToolbarTableContent,
		SPMainToolbarCustomQuery,
		SPMainToolbarTableInfo,
		SPMainToolbarTableRelations,
		SPMainToolbarTableTriggers,
		SPMainToolbarUserManager,
		SPMainToolbarTransfer,
		NSToolbarCustomizeToolbarItemIdentifier,
		NSToolbarFlexibleSpaceItemIdentifier,
		NSToolbarSpaceItemIdentifier,
		NSToolbarSeparatorItemIdentifier
	];
#pragma clang diagnostic pop
}

/// As -[SPDatabaseDocument toolbarDefaultItemIdentifiers:].
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)theToolbar
{
	return @[
		SPMainToolbarDatabaseSelection,
		SPMainToolbarTableStructure,
		SPMainToolbarTableContent,
		SPMainToolbarTableRelations,
		SPMainToolbarTableTriggers,
		SPMainToolbarTableInfo,
		SPMainToolbarCustomQuery,
		NSToolbarFlexibleSpaceItemIdentifier,
		SPMainToolbarHistoryNavigation,
		SPMainToolbarUserManager,
		SPMainToolbarTransfer,
		SPMainToolbarShowConsole
	];
}

/// Only the database picker and the console work on Postgres tabs so far
- (NSArray *)_availableToolbarItemIdentifiers
{
	return @[SPMainToolbarDatabaseSelection, SPMainToolbarShowConsole];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)theToolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
	NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
	NSString *imageName = nil;
	NSImage *image = nil;
	SEL action = @selector(unavailableInThisVersion:);

	// Labels, palette labels, tooltips and images as MySQL's (-[SPDatabaseDocument toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:])
	if ([identifier isEqualToString:SPMainToolbarDatabaseSelection]) {
		[item setLabel:NSLocalizedString(@"Select Database", @"toolbar item for selecting a db")];
		[item setPaletteLabel:[item label]];
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
		[item setLabel:NSLocalizedString(@"Table History", @"toolbar item for navigation history")];
		[item setPaletteLabel:[item label]];
		[item setView:historyControl];
		[item setEnabled:NO];
		action = NULL;
	}
	else if ([identifier isEqualToString:SPMainToolbarShowConsole]) {
		[item setLabel:NSLocalizedString(@"Console", @"Console")];
		[item setPaletteLabel:NSLocalizedString(@"Show Console", @"show console")];
		[item setToolTip:NSLocalizedString(@"Show the console which shows all PostgreSQL commands performed by Sequel Pro", @"PostgreSQL toolbar: console tooltip")];
		imageName = @"hideconsole";
		action = @selector(toggleConsole:);
	}
	else if ([identifier isEqualToString:SPMainToolbarClearConsole]) {
		[item setLabel:NSLocalizedString(@"Clear Console", @"toolbar item for clear console")];
		[item setPaletteLabel:[item label]];
		imageName = @"clearconsole";
	}
	else if ([identifier isEqualToString:SPMainToolbarTableStructure]) {
		[item setLabel:NSLocalizedString(@"Structure", @"toolbar item label for switching to the Table Structure tab")];
		[item setPaletteLabel:NSLocalizedString(@"Edit Table Structure", @"toolbar item label for switching to the Table Structure tab")];
		imageName = @"toolbar-switch-to-structure";
	}
	else if ([identifier isEqualToString:SPMainToolbarTableContent]) {
		[item setLabel:NSLocalizedString(@"Content", @"toolbar item label for switching to the Table Content tab")];
		[item setPaletteLabel:NSLocalizedString(@"Browse & Edit Table Content", @"toolbar item label for switching to the Table Content tab")];
		imageName = @"toolbar-switch-to-browse";
	}
	else if ([identifier isEqualToString:SPMainToolbarCustomQuery]) {
		[item setLabel:NSLocalizedString(@"Query", @"toolbar item label for switching to the Run Query tab")];
		[item setPaletteLabel:NSLocalizedString(@"Run Custom Query", @"toolbar item label for switching to the Run Query tab")];
		imageName = @"toolbar-switch-to-sql";
	}
	else if ([identifier isEqualToString:SPMainToolbarTableInfo]) {
		[item setLabel:NSLocalizedString(@"Table Info", @"toolbar item label for switching to the Table Info tab")];
		[item setPaletteLabel:[item label]];
		imageName = @"toolbar-switch-to-table-info";
	}
	else if ([identifier isEqualToString:SPMainToolbarTableRelations]) {
		[item setLabel:NSLocalizedString(@"Relations", @"toolbar item label for switching to the Table Relations tab")];
		[item setPaletteLabel:NSLocalizedString(@"Table Relations", @"toolbar item label for switching to the Table Relations tab")];
		imageName = @"toolbar-switch-to-table-relations";
	}
	else if ([identifier isEqualToString:SPMainToolbarTableTriggers]) {
		[item setLabel:NSLocalizedString(@"Triggers", @"toolbar item label for switching to the Table Triggers tab")];
		[item setPaletteLabel:NSLocalizedString(@"Table Triggers", @"toolbar item label for switching to the Table Triggers tab")];
		imageName = @"toolbar-switch-to-table-triggers";
	}
	else if ([identifier isEqualToString:SPMainToolbarUserManager]) {
		[item setLabel:NSLocalizedString(@"Users", @"toolbar item label for switching to the User Manager tab")];
		[item setPaletteLabel:[item label]];
		image = [NSImage imageNamed:NSImageNameEveryone];
	}
	else if ([identifier isEqualToString:SPMainToolbarTransfer]) {
		SPConfigureTransferToolbarItem(item);
	}
	else {
		return nil;
	}

	if (imageName) image = [NSImage imageNamed:imageName];
	if (image) [item setImage:SPCompactToolbarImage(image)];

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

	return !tornDown;
}

- (void)unavailableInThisVersion:(id)sender
{
	// Never enabled (see -validateToolbarItem:): the items of features Postgres tabs don't have yet
}

/// Shows the shared console, or hides it when it is the key window (as MySQL's Toggle Console).
- (void)toggleConsole:(id)sender
{
	SPQueryController *queryController = [SPQueryController sharedQueryController];
	NSWindow *consoleWindow = [queryController window];

	if ([consoleWindow isVisible] && [consoleWindow isKeyWindow]) {
		[consoleWindow setIsVisible:NO];
		return;
	}

	// Entries aren't reloaded while the console is hidden
	if (![consoleWindow isVisible]) [queryController updateEntries];
	[consoleWindow makeKeyAndOrderFront:self];
}

@end
