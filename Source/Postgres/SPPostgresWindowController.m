#import "SPPostgresWindowController.h"
#import "SPPostgresSidebarController.h"
#import "SPPostgresConsoleLogger.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresConnector.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresErrors.h"
#import "SPSplitView.h"
#import "SPQueryController.h"
#import "SPFavoriteColorSupport.h"
#import "NSWindow+SPCompactChrome.h"
#import "PSMTabBarControl.h"
#import <PostgresKit/PostgresKit.h>

NSString * const SPPostgresToolbarDatabase   = @"SPPostgresToolbarDatabase";
NSString * const SPPostgresToolbarStructure  = @"SPPostgresToolbarStructure";
NSString * const SPPostgresToolbarContent    = @"SPPostgresToolbarContent";
NSString * const SPPostgresToolbarRelations  = @"SPPostgresToolbarRelations";
NSString * const SPPostgresToolbarTriggers   = @"SPPostgresToolbarTriggers";
NSString * const SPPostgresToolbarTableInfo  = @"SPPostgresToolbarTableInfo";
NSString * const SPPostgresToolbarQuery      = @"SPPostgresToolbarQuery";
NSString * const SPPostgresToolbarUsers      = @"SPPostgresToolbarUsers";
NSString * const SPPostgresToolbarTransfer   = @"SPPostgresToolbarTransfer";
NSString * const SPPostgresToolbarHistory    = @"SPPostgresToolbarHistory";
NSString * const SPPostgresToolbarConsole    = @"SPPostgresToolbarConsole";

static NSString * const SPPostgresWindowFrameName = @"SPPostgresWindow";
static NSString * const SPPostgresSplitterName = @"PGViewSplitter";
static NSString * const SPPostgresConnectionTabIdentifier = @"SPPostgresConnectionTab";

static const CGFloat SPPostgresSidebarDefaultWidth = 250;
static const CGFloat SPPostgresTabBarHeight = 25;

@interface SPPostgresWindowController () <SPPostgresSidebarControllerDelegate>

- (void)_attachCurrentConnection;
- (void)_buildContent;
- (void)_buildToolbar;
- (void)_reloadDatabasePopup;
- (void)_updateWindowTitle;
- (void)_updateDatabaseToolbarItemWidth;
- (void)_tearDown;
- (NSString *)_connectionName;
- (void)_reportCatalogError:(NSError *)error;
- (void)_presentAlert:(NSAlert *)alert;
- (void)_databaseSwitchBy:(SPPostgresConnector *)theConnector favorite:(SPPostgresFavorite *)theFavorite finishedWithConnection:(PGPostgresConnection *)newConnection error:(NSError *)error;

@end

@implementation SPPostgresWindowController
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

	PSMTabBarControl *tabBar;
	NSTabView *tabView;
	SPSplitView *splitView;
	NSPopUpButton *databasePopup;
	NSSegmentedControl *historyControl;
	NSToolbarItem *databaseToolbarItem; // not retained; owned by the toolbar

	/// An alert that came up before the window was shown (presented by -showWindow:)
	NSAlert *pendingAlert;

	BOOL keepingSelfAlive;
	BOOL tornDown;
}

@synthesize sidebar;
@synthesize connection;
@synthesize alertPresenter;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection connector:(SPPostgresConnector *)theConnector favorite:(SPPostgresFavorite *)theFavorite
{
	NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 948, 555)
	                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	                                                  backing:NSBackingStoreBuffered
	                                                    defer:YES] autorelease];

	if ((self = [super initWithWindow:window])) {
		connection = [theConnection retain];
		connector = [theConnector retain];
		favorite = [theFavorite copy];

		[window setReleasedWhenClosed:NO];
		[window setRestorable:NO];
		[window setMinSize:NSMakeSize(640, 400)];
		[window setCollectionBehavior:[window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];
		[window setDelegate:self];
		if (![window setFrameUsingName:SPPostgresWindowFrameName]) [window center];
		[window setFrameAutosaveName:SPPostgresWindowFrameName];

		[self _attachCurrentConnection];

		sidebar = [[SPPostgresSidebarController alloc] initWithCatalog:catalog];
		[sidebar setDelegate:self];
		if ([sidebar lastError]) [self _reportCatalogError:[sidebar lastError]];

		[self _buildContent];
		[self _buildToolbar];
		[self _updateWindowTitle];
	}

	return self;
}

- (void)dealloc
{
	[self _tearDown];

	// The tab view outlives neither its tab bar nor this controller in practice; don't leave it a stale delegate
	[tabView setDelegate:nil];

	[connection release];
	[connector release];
	[favorite release];
	[catalog release];
	[logger release];
	[sidebar release];
	[serverVersion release];
	[currentDatabase release];
	[tabBar release];
	[tabView release];
	[splitView release];
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

- (void)_buildContent
{
	NSView *contentView = [[self window] contentView];
	NSRect bounds = [contentView bounds];

	// One tab for the connection, in the MySQL window's tab bar style (see -[SPWindowController _setUpTabBar])
	tabBar = [[PSMTabBarControl alloc] initWithFrame:NSMakeRect(0, NSHeight(bounds) - SPPostgresTabBarHeight, NSWidth(bounds), SPPostgresTabBarHeight)];
	[tabBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];

	tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds) - SPPostgresTabBarHeight)];
	[tabView setTabViewType:NSNoTabsNoBorder];
	[tabView setDrawsBackground:NO];
	[tabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	[tabBar setTabView:tabView];
	[tabBar setPartnerView:tabView];
	[tabView setDelegate:(id<NSTabViewDelegate>)tabBar];
	[tabBar setDelegate:self];

	[tabBar setStyleNamed:@"SequelPro"];
	[tabBar setCanCloseOnlyTab:NO];
	[tabBar setDisableTabClose:YES];
	[tabBar setHideForSingleTab:NO];   // one connection per Postgres window, its tab always shown
	[tabBar setShowAddTabButton:NO];
	[tabBar setSizeCellsToFit:NO];
	[tabBar setCellMinWidth:100];
	[tabBar setCellMaxWidth:250];
	[tabBar setCellOptimumWidth:250];
	[tabBar setSelectsTabsOnMouseDown:YES];
	[tabBar setCreatesTabOnDoubleClick:NO];
	[tabBar setUsesSafariStyleDragging:YES];

	[contentView addSubview:tabView];
	[contentView addSubview:tabBar];

	// Left panel | content, as MySQL's DBViewSplitter
	NSRect splitFrame = [tabView bounds];
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

	NSTabViewItem *item = [[[NSTabViewItem alloc] initWithIdentifier:SPPostgresConnectionTabIdentifier] autorelease];
	[item setLabel:[self _connectionName]];
	[item setColor:[[SPFavoriteColorSupport sharedInstance] colorForIndex:[favorite colorIndex]]];
	[item setView:splitView];
	[tabView addTabViewItem:item];
	[tabView selectTabViewItem:item];
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

	NSToolbar *toolbar = [[[NSToolbar alloc] initWithIdentifier:@"SPPostgresWindowToolbar"] autorelease];
	// Fixed layout in stage 1 (no saved configuration can reorder it)
	[toolbar setAllowsUserCustomization:NO];
	[toolbar setAutosavesConfiguration:NO];
	[toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
	[toolbar setDelegate:self];

	[[self window] setToolbar:toolbar];
	[[self window] sp_useExpandedCompactToolbar];
}

#pragma mark - Window

- (void)showWindow:(id)sender
{
	// Stay alive while the window is open (released in -windowWillClose:)
	if (!keepingSelfAlive && !tornDown) {
		keepingSelfAlive = YES;
		[self retain];
	}
	[super showWindow:sender];

	if (pendingAlert && [[self window] isVisible]) {
		NSAlert *alert = pendingAlert;
		pendingAlert = nil;
		[self _presentAlert:alert];
		[alert release];
	}
}

#pragma mark - Alerts

- (void)_presentAlert:(NSAlert *)alert
{
	if (tornDown) return;

	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}

	// Not shown yet (e.g. a failure while the window is being built): show it with the window
	if (![[self window] isVisible]) {
		if (!pendingAlert) pendingAlert = [alert retain];
		return;
	}

	[alert beginSheetModalForWindow:[self window] completionHandler:nil];
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
		advice = NSLocalizedString(@"The lists show what was loaded before the connection was lost. Close this window and connect again.", @"PostgreSQL window: connection lost advice");
	}
	else {
		[alert setMessageText:NSLocalizedString(@"Could not load the database objects", @"PostgreSQL window: catalog query failed title")];
		advice = NSLocalizedString(@"The lists show what was loaded before.", @"PostgreSQL window: catalog query failed advice");
	}
	[alert setInformativeText:[detail length] ? [NSString stringWithFormat:@"%@\n\n%@", detail, advice] : advice];

	[self _presentAlert:alert];
}

- (NSString *)windowTitleString
{
	NSMutableString *title = [NSMutableString stringWithFormat:@"(PostgreSQL %@) %@/%@", serverVersion, [self _connectionName], currentDatabase ?: @""];

	NSString *table = [sidebar selectedTableName];
	if ([table length]) [title appendFormat:@"/%@.%@", [sidebar selectedSchema], table];

	return title;
}

- (void)_updateWindowTitle
{
	[[self window] setTitle:[self windowTitleString]];
	[[self window] sp_applyCompactTitle];
}

- (void)windowWillClose:(NSNotification *)notification
{
	[self _tearDown];
}

/// Sheets slide out below the tab bar, as in the MySQL window.
- (NSRect)window:(NSWindow *)window willPositionSheet:(NSWindow *)sheet usingRect:(NSRect)rect
{
	rect.origin.y -= NSHeight([tabBar frame]) - 1;
	return rect;
}

/// Closes the connection and detaches everything that points back at this controller. Idempotent.
- (void)_tearDown
{
	if (tornDown) return;
	tornDown = YES;

	// A pending database switch completes (cancelled) and lets go of its block, which retains self
	SPPostgresConnector *pending = pendingConnector;
	pendingConnector = nil;
	[pending cancel];
	[pending release];

	[connector disconnect];

	[sidebar invalidate];
	[splitView setDelegate:nil];
	[tabBar setDelegate:nil];
	[databasePopup setTarget:nil];

	NSWindow *window = [self window];
	NSToolbar *toolbar = [window toolbar];
	for (NSToolbarItem *item in [toolbar items]) [item setTarget:nil];
	[toolbar setDelegate:nil];
	databaseToolbarItem = nil;

	[window sp_stopCompactTitleTracking];
	[window setDelegate:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	if (keepingSelfAlive) {
		keepingSelfAlive = NO;
		[self autorelease];
	}
}

#pragma mark - Sidebar

- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)theSidebar
{
	[self _updateWindowTitle];
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
	SPPostgresConnector *newConnector = [[SPPostgresConnector alloc] initWithFavorite:target password:thePassword sshPassword:[connector sshPassword] parentWindow:[self window]];

	// Only the latest request counts: an earlier pending one is abandoned (its completion is then ignored)
	SPPostgresConnector *previous = pendingConnector;
	pendingConnector = newConnector;
	[previous cancel];
	[previous release];

	[databasePopup setEnabled:NO];

	// The connector keeps the completion until it is called (always exactly once), which also keeps self
	// alive meanwhile; the connector itself is captured unretained to avoid a connector -> block -> connector cycle.
	__block SPPostgresConnector *blockConnector = newConnector;
	[newConnector connectWithCompletion:^(PGPostgresConnection *newConnection, NSError *error) {
		[self _databaseSwitchBy:blockConnector favorite:target finishedWithConnection:newConnection error:error];
	}];
}

- (void)_databaseSwitchBy:(SPPostgresConnector *)theConnector favorite:(SPPostgresFavorite *)theFavorite finishedWithConnection:(PGPostgresConnection *)newConnection error:(NSError *)error
{
	// Superseded or cancelled by the window closing
	if (theConnector != pendingConnector) return;

	SPPostgresConnector *newConnector = pendingConnector; // takes over our reference
	pendingConnector = nil;
	[databasePopup setEnabled:YES];

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
	[self _updateWindowTitle];

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

#pragma mark - Tab bar

- (BOOL)tabView:(NSTabView *)aTabView shouldDragTabViewItem:(NSTabViewItem *)tabViewItem fromTabBar:(PSMTabBarControl *)tabBarControl
{
	return NO;
}

- (BOOL)tabView:(NSTabView *)aTabView shouldCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
	return NO;
}

#pragma mark - Toolbar

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
	return @[
		SPPostgresToolbarDatabase,
		SPPostgresToolbarStructure,
		SPPostgresToolbarContent,
		SPPostgresToolbarRelations,
		SPPostgresToolbarTriggers,
		SPPostgresToolbarTableInfo,
		SPPostgresToolbarQuery,
		NSToolbarFlexibleSpaceItemIdentifier,
		SPPostgresToolbarUsers,
		SPPostgresToolbarTransfer,
		SPPostgresToolbarHistory,
		SPPostgresToolbarConsole
	];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
	return [self toolbarDefaultItemIdentifiers:toolbar];
}

/// Present but not available until later stages
- (NSArray *)_unavailableToolbarItemIdentifiers
{
	return @[SPPostgresToolbarStructure, SPPostgresToolbarContent, SPPostgresToolbarRelations, SPPostgresToolbarTriggers,
	         SPPostgresToolbarTableInfo, SPPostgresToolbarQuery, SPPostgresToolbarUsers, SPPostgresToolbarTransfer, SPPostgresToolbarHistory];
}

/// The Transfer icon: SF Symbol "arrow.left.arrow.right", centred on a 24pt canvas like the other compact toolbar images.
- (NSImage *)_transferToolbarImage
{
	NSImage *symbol = [NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right" accessibilityDescription:NSLocalizedString(@"Transfer", @"PostgreSQL toolbar: Transfer")];
	symbol = [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:17 weight:NSFontWeightRegular]];
	if (!symbol) return nil;

	NSSize symbolSize = [symbol size];
	NSImage *image = [NSImage imageWithSize:NSMakeSize(24, 24) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
		NSRect target = NSMakeRect(round((24 - symbolSize.width) / 2), round((24 - symbolSize.height) / 2), symbolSize.width, symbolSize.height);
		[symbol drawInRect:target];
		return YES;
	}];
	[image setTemplate:YES];
	return image;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
	NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
	NSString *imageName = nil;
	NSImage *image = nil;
	SEL action = @selector(unavailableInThisVersion:);

	if ([identifier isEqualToString:SPPostgresToolbarDatabase]) {
		[item setLabel:NSLocalizedString(@"Select Database", @"toolbar item for selecting a db")];
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
	else if ([identifier isEqualToString:SPPostgresToolbarStructure]) {
		[item setLabel:NSLocalizedString(@"Structure", @"toolbar item label for switching to the Table Structure tab")];
		imageName = @"toolbar-switch-to-structure";
	}
	else if ([identifier isEqualToString:SPPostgresToolbarContent]) {
		[item setLabel:NSLocalizedString(@"Content", @"toolbar item label for switching to the Table Content tab")];
		imageName = @"toolbar-switch-to-browse";
	}
	else if ([identifier isEqualToString:SPPostgresToolbarRelations]) {
		[item setLabel:NSLocalizedString(@"Relations", @"toolbar item label for switching to the Table Relations tab")];
		imageName = @"toolbar-switch-to-table-relations";
	}
	else if ([identifier isEqualToString:SPPostgresToolbarTriggers]) {
		[item setLabel:NSLocalizedString(@"Triggers", @"toolbar item label for switching to the Table Triggers tab")];
		imageName = @"toolbar-switch-to-table-triggers";
	}
	else if ([identifier isEqualToString:SPPostgresToolbarTableInfo]) {
		[item setLabel:NSLocalizedString(@"Table Info", @"toolbar item label for switching to the Table Info tab")];
		imageName = @"toolbar-switch-to-table-info";
	}
	else if ([identifier isEqualToString:SPPostgresToolbarQuery]) {
		[item setLabel:NSLocalizedString(@"Query", @"toolbar item label for switching to the Run Query tab")];
		imageName = @"toolbar-switch-to-sql";
	}
	else if ([identifier isEqualToString:SPPostgresToolbarUsers]) {
		[item setLabel:NSLocalizedString(@"Users", @"toolbar item label for switching to the User Manager tab")];
		image = [NSImage imageNamed:NSImageNameEveryone];
	}
	else if ([identifier isEqualToString:SPPostgresToolbarTransfer]) {
		[item setLabel:NSLocalizedString(@"Transfer", @"PostgreSQL toolbar: Transfer")];
		[item setImage:[self _transferToolbarImage]];
	}
	else if ([identifier isEqualToString:SPPostgresToolbarHistory]) {
		[item setLabel:NSLocalizedString(@"Table History", @"toolbar item for navigation history")];
		[item setView:historyControl];
		[item setEnabled:NO];
		action = NULL;
	}
	else if ([identifier isEqualToString:SPPostgresToolbarConsole]) {
		[item setLabel:NSLocalizedString(@"Console", @"Console")];
		[item setToolTip:NSLocalizedString(@"Show the console which shows all PostgreSQL commands performed by Sequel Pro", @"PostgreSQL toolbar: console tooltip")];
		imageName = @"hideconsole";
		action = @selector(toggleConsole:);
	}
	else {
		return nil;
	}

	if (imageName) image = [NSImage imageNamed:imageName];
	if (image) [item setImage:SPCompactToolbarImage(image)];
	[item setPaletteLabel:[item label]];

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

	if ([[self _unavailableToolbarItemIdentifiers] containsObject:identifier]) return NO;

	if ([identifier isEqualToString:SPPostgresToolbarConsole]) {
		NSWindow *consoleWindow = [[SPQueryController sharedQueryController] window];
		[item setImage:SPCompactToolbarImage([NSImage imageNamed:[consoleWindow isVisible] ? @"showconsole" : @"hideconsole"])];
		return ![consoleWindow isKeyWindow];
	}

	return !tornDown;
}

- (void)unavailableInThisVersion:(id)sender
{
	// Never enabled in stage 1 (see -validateToolbarItem:)
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
