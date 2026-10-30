#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/SPButtonBar.h"
#import "../Source/SPSplitView.h"
#import "../Source/SPComboPopupButton.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresExportController.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

static const NSUInteger SPQueryBarTestPort = 55418;
// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPQueryBarPrimaryRunsAllKey = @"QueryPrimaryControlRunsAll";
static NSString * const SPQueryBarEditInSheetKey = @"EditInSheetEnabled";
static NSString * const SPQueryBarScratchSuite = @"SPPostgresStage11Tests";

@interface SPPostgresQueryController (Testing)
- (void)setStatementWillRunHook:(void (^)(NSString *statement))hook;
@end

/// The Query tab's layout (Stage 11 Task 1): MySQL's split views, the top bar with the run pop-up button, the
/// results bar (info pane toggle, results gear, edit mode toggle, status line), and the run controls' states.
@interface SPPostgresQueryBarTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSUserDefaults *scratch;
@end

@implementation SPPostgresQueryBarTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	[SPPostgresTestServers loadFixtureNamed:@"content" onPort:SPQueryBarTestPort];

	// Scratch preferences (never the saved ones), removed in tearDown
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPQueryBarScratchSuite];
	[self.scratch removePersistentDomainForName:SPQueryBarScratchSuite];
	[self.scratch setBool:NO forKey:SPQueryBarPrimaryRunsAllKey];
	[self.scratch setBool:NO forKey:SPQueryBarEditInSheetKey];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 query bar";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPQueryBarTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);

	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block NSError *error = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) {
		connection = theConnection;
		error = theError;
		done = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection, @"%@", error);

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	NSMutableArray *alerts = [NSMutableArray array];
	self.alerts = alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	self.query.defaults = self.scratch;
	self.query.infoPaneAnimates = NO; // the info pane opens and closes at once
	[self.document viewQuery:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	[self.query.taskRunner cancelAll];
	[SPPostgresTestServers waitForRunner:self.query.taskRunner timeout:30];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	self.alerts = nil;
	[self.scratch removePersistentDomainForName:SPQueryBarScratchSuite];
	self.scratch = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresQueryController *)query
{
	return self.document.queryController;
}

- (void)setSQL:(NSString *)sql
{
	[self.query.editor setString:sql];
	[self.query.editor setSelectedRange:NSMakeRange(0, 0)];
}

- (NSArray *)columnTitles
{
	NSMutableArray *titles = [NSMutableArray array];
	for (NSTableColumn *column in [self.query.resultsView tableColumns]) [titles addObject:[[column headerCell] stringValue]];
	return titles;
}

- (void)assertFrame:(NSRect)frame is:(NSRect)expected name:(NSString *)name
{
	XCTAssertTrue(NSEqualRects(frame, expected), @"%@ at %@, expected %@", name, NSStringFromRect(frame), NSStringFromRect(expected));
}

- (NSEvent *)keyDown:(NSString *)characters flags:(NSEventModifierFlags)flags
{
	return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
						windowNumber:[[self.controller window] windowNumber] context:nil characters:characters
		 charactersIgnoringModifiers:characters isARepeat:NO keyCode:15];
}

- (BOOL)pressKey:(NSString *)characters flags:(NSEventModifierFlags)flags
{
	return [[[self.controller window] contentView] performKeyEquivalent:[self keyDown:characters flags:flags]];
}

- (NSArray *)titlesOfMenu:(NSMenu *)menu
{
	NSMutableArray *titles = [NSMutableArray array];
	for (NSMenuItem *item in [menu itemArray]) [titles addObject:[item isSeparatorItem] ? @"<separator>" : [item title]];
	return titles;
}

- (NSMenuItem *)exportCSVItem
{
	NSMenuItem *export = [[self.query.resultsGearButton menu] itemWithTitle:@"Export Result"];
	XCTAssertNotNil(export);
	NSMenuItem *csv = [[export submenu] itemWithTitle:@"As CSV file…"];
	XCTAssertNotNil(csv);
	return csv;
}

/// The Query controller on a background runner of its own on the tab's connection.
- (SPPostgresTaskRunner *)useBackgroundRunner
{
	SPPostgresTaskRunner *runner = [[SPPostgresTaskRunner alloc] initWithConnection:self.document.connection];
	self.query.taskRunner = runner;
	[self addTeardownBlock:^{
		[runner cancelAll];
		[SPPostgresTestServers waitForRunner:runner timeout:10];
		[runner invalidateWithCompletion:nil];
	}];
	return runner;
}

#pragma mark - Layout

- (void)testLayoutMatchesDBView
{
	SPPostgresQueryController *query = self.query;
	NSView *root = [query view];
	XCTAssertNotNil([root window], @"the Query view is showing");
	CGFloat rootWidth = NSWidth([root frame]);

	// Top bar: 23 pt, directly above the results
	NSView *topBar = [query.gearButton superview];
	XCTAssertTrue([topBar isKindOfClass:NSClassFromString(@"SPButtonBar")]);
	XCTAssertEqual(NSHeight([topBar frame]), 23);
	NSScrollView *resultsScroll = [query.resultsView enclosingScrollView];
	XCTAssertEqual([resultsScroll superview], [topBar superview]);
	XCTAssertEqual(NSMinY([topBar frame]), NSMaxY([resultsScroll frame]));
	XCTAssertEqual(NSMaxY([topBar frame]), NSHeight([[topBar superview] frame]), @"at the top of the results pane");
	CGFloat paneWidth = NSWidth([topBar frame]);

	[self assertFrame:[query.gearButton frame] is:NSMakeRect(0, 0, 35, 23) name:@"gear"];
	[self assertFrame:[query.favoritesButton frame] is:NSMakeRect(38, 0, 129, 22) name:@"favorites"];
	[self assertFrame:[query.historyButton frame] is:NSMakeRect(177, 0, 145, 22) name:@"history"];
	[self assertFrame:[query.runButton frame] is:NSMakeRect(paneWidth - 188, 0, 180, 22) name:@"run"];
	XCTAssertEqual([query.favoritesButton superview], topBar);
	XCTAssertEqual([query.historyButton superview], topBar);
	XCTAssertEqual([query.runButton superview], topBar);
	XCTAssertTrue([query.runButton isKindOfClass:NSClassFromString(@"SPComboPopupButton")]);
	XCTAssertTrue([query.runButton pullsDown]);
	XCTAssertEqual([query.runButton lineOffset], 15u, @"SPComboPopupButton's small-control offset");

	// The menus: the hidden first item only (later tasks fill them)
	NSMenuItem *gearItem = [[query.gearButton menu] itemAtIndex:0];
	XCTAssertEqual([[query.gearButton menu] numberOfItems], 1);
	XCTAssertTrue([gearItem isHidden]);
	XCTAssertEqualObjects([[gearItem image] name], @"button_action");
	XCTAssertTrue([query.gearButton pullsDown]);
	XCTAssertEqualObjects([self titlesOfMenu:[query.favoritesButton menu]], @[@"Query Favorites"]);
	XCTAssertTrue([[[query.favoritesButton menu] itemAtIndex:0] isHidden]);
	XCTAssertEqualObjects([self titlesOfMenu:[query.historyButton menu]], @[@"Query History"]);
	XCTAssertTrue([[[query.historyButton menu] itemAtIndex:0] isHidden]);
	XCTAssertEqualObjects([query.favoritesButton toolTip], @"Choose a favorite from the menu or save queries to the favorites (⌥⌘F)");
	XCTAssertEqualObjects([query.historyButton toolTip], @"Choose a query from your recent queries (⌥⌘Y)");
	XCTAssertEqualObjects([[query.favoritesButton cell] keyEquivalent], @"f");
	XCTAssertEqual([[query.favoritesButton cell] keyEquivalentModifierMask], NSEventModifierFlagCommand | NSEventModifierFlagOption);
	XCTAssertEqualObjects([[query.historyButton cell] keyEquivalent], @"y");
	XCTAssertEqual([[query.historyButton cell] keyEquivalentModifierMask], NSEventModifierFlagCommand | NSEventModifierFlagOption);
	XCTAssertEqual([[query.favoritesButton cell] controlSize], NSControlSizeSmall);
	XCTAssertEqual([[query.runButton cell] controlSize], NSControlSizeSmall);

	// Bottom bar: full width at the root's origin, the controls at DBView.xib's frames less MySQL's bar origin
	NSView *bottomBar = [query.infoPaneButton superview];
	XCTAssertTrue([bottomBar isKindOfClass:NSClassFromString(@"SPButtonBar")]);
	XCTAssertEqual([bottomBar superview], root);
	[self assertFrame:[bottomBar frame] is:NSMakeRect(0, 0, rootWidth, 23) name:@"bottom bar"];
	[self assertFrame:[query.infoPaneButton frame] is:NSMakeRect(-1, -1, 32, 25) name:@"info toggle"];
	[self assertFrame:[query.resultsGearButton frame] is:NSMakeRect(29, 0, 36, 23) name:@"results gear"];
	[self assertFrame:[query.editModeButton frame] is:NSMakeRect(61, -1, 32, 25) name:@"edit mode toggle"];
	XCTAssertEqual([query.resultsGearButton superview], bottomBar);
	XCTAssertEqual([query.editModeButton superview], bottomBar);
	XCTAssertEqual([query.statusField superview], bottomBar);
	XCTAssertEqual(NSMinX([query.statusField frame]), 96);
	XCTAssertEqual(NSMinY([query.statusField frame]), 2);
	XCTAssertEqual(NSHeight([query.statusField frame]), 17);
	XCTAssertEqual(NSMaxX([query.statusField frame]), rootWidth - 10);
	XCTAssertEqualObjects([query.statusField font], [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]);

	// The split views sit on the bottom bar
	SPSplitView *outer = query.infoPaneSplitView;
	XCTAssertEqual([outer superview], root);
	[self assertFrame:[outer frame] is:NSMakeRect(0, 23, rootWidth, NSHeight([root frame]) - 23) name:@"outer split"];
	XCTAssertFalse([outer isVertical]);
	XCTAssertEqual([outer dividerStyle], NSSplitViewDividerStyleThin);
	XCTAssertEqual([[outer subviews] count], 2u);
	XCTAssertTrue(NSIsEmptyRect([[outer delegate] splitView:outer effectiveRect:NSMakeRect(0, 100, rootWidth, 1) forDrawnRect:NSMakeRect(0, 100, rootWidth, 1) ofDividerAtIndex:0]), @"the info pane's divider can't be dragged");

	// Images, tooltips and keys (as MySQL's)
	XCTAssertEqualObjects([[query.infoPaneButton image] name], @"button_pane_hide");
	XCTAssertEqualObjects([[query.infoPaneButton alternateImage] name], @"button_pane_show");
	XCTAssertEqualObjects([query.infoPaneButton toolTip], @"Toggle the visibility of the Query Information Pane");
	XCTAssertEqualObjects([query.infoPaneButton keyEquivalent], @"a");
	XCTAssertEqual([query.infoPaneButton keyEquivalentModifierMask], NSEventModifierFlagCommand | NSEventModifierFlagOption);
	XCTAssertEqual([query.infoPaneButton target], outer);
	XCTAssertEqual([query.infoPaneButton action], @selector(toggleCollapse:));
	XCTAssertEqualObjects([[query.editModeButton image] name], @"button_edit_mode");
	XCTAssertEqualObjects([[query.editModeButton alternateImage] name], @"button_edit_mode_selected");
	XCTAssertEqualObjects([query.editModeButton toolTip], @"Toggle between editing simple text cells as a spreadsheet or in pop-up sheets");
	NSMenuItem *resultsGearItem = [[query.resultsGearButton menu] itemAtIndex:0];
	XCTAssertTrue([resultsGearItem isHidden]);
	XCTAssertEqualObjects([[resultsGearItem image] name], @"button_action");
	XCTAssertNotNil([self exportCSVItem]);

	// The info pane is collapsed at start, the toggle showing "show"
	XCTAssertTrue([outer isCollapsibleSubviewCollapsed]);
	XCTAssertEqual([query.infoPaneButton state], NSControlStateValueOn);
	XCTAssertNotNil(query.infoPaneText);
	XCTAssertFalse([query.infoPaneText isEditable]);

	// The run button's title
	XCTAssertEqualObjects([query.runButton title], @"Run Current");

	// The run button keeps its distance from the right edge as the view widens
	[root setFrameSize:NSMakeSize(rootWidth + 200, NSHeight([root frame]))];
	XCTAssertEqual(NSMinX([query.runButton frame]), NSWidth([topBar frame]) - 188);
	XCTAssertEqual(NSMaxX([query.statusField frame]), rootWidth + 200 - 10);
	XCTAssertEqual(NSMinX([query.statusField frame]), 96);
}

#pragma mark - Run pop-up button

- (void)testRunMenuItemsAndSwitchDefault
{
	SPPostgresQueryController *query = self.query;
	id standardBefore = [[NSUserDefaults standardUserDefaults] objectForKey:SPQueryBarPrimaryRunsAllKey];
	NSMenu *menu = [query.runButton menu];
	XCTAssertEqualObjects([self titlesOfMenu:menu], (@[@"Run Current", @"Run Current Query", @"<separator>", @"Run All Queries", @"Switch Default"]));
	XCTAssertTrue([[menu itemAtIndex:0] isHidden]);

	NSMenuItem *primary = [menu itemWithTag:2];
	NSMenuItem *secondary = [menu itemWithTag:1];
	XCTAssertEqualObjects([primary keyEquivalent], @"r");
	XCTAssertEqual([primary keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqual([primary action], @selector(runPrimaryQueryAction:));
	XCTAssertEqualObjects([secondary keyEquivalent], @"r");
	XCTAssertEqual([secondary keyEquivalentModifierMask], NSEventModifierFlagCommand | NSEventModifierFlagOption);
	XCTAssertEqual([secondary action], @selector(runSecondaryQueryAction:));
	XCTAssertEqual([[menu itemWithTitle:@"Switch Default"] action], @selector(switchDefaultQueryAction:));
	XCTAssertEqual([query.runButton action], @selector(runPrimaryQueryAction:));
	XCTAssertEqual([query.runButton target], query);

	// Switch Default writes the shared preference into the controller's defaults
	[query switchDefaultQueryAction:[menu itemWithTitle:@"Switch Default"]];
	XCTAssertTrue([self.scratch boolForKey:SPQueryBarPrimaryRunsAllKey]);
	XCTAssertEqualObjects([query.runButton title], @"Run All");
	XCTAssertEqualObjects([[menu itemWithTag:2] title], @"Run All Queries");
	XCTAssertEqualObjects([[menu itemWithTag:1] title], @"Run Current Query");

	// The button runs the primary action: now Run All
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];
	XCTAssertEqualObjects([query.runButton title], @"Run All", @"the caret doesn't change Run All");
	[query.runButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);

	// The keys follow the same defaults: ⌘R runs All, ⌥⌘R runs Current (the saved preference is untouched)
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] objectForKey:SPQueryBarPrimaryRunsAllKey], standardBefore);
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand | NSEventModifierFlagOption]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"], @"⌥⌘R: Run Current");
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"], @"⌘R: Run All");

	// And back
	[query switchDefaultQueryAction:nil];
	XCTAssertFalse([self.scratch boolForKey:SPQueryBarPrimaryRunsAllKey]);
	XCTAssertEqualObjects([query.runButton title], @"Run Current");
	XCTAssertEqualObjects([[menu itemWithTag:2] title], @"Run Current Query");
	XCTAssertEqualObjects([[menu itemWithTag:1] title], @"Run All Queries");
	[query.runButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"]);
}

- (void)testRunTitleFollowsCaret
{
	SPPostgresQueryController *query = self.query;
	NSMenuItem *primary = [[query.runButton menu] itemWithTag:2];

	// In a statement
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];
	[query.editor setSelectedRange:NSMakeRange(3, 0)];
	XCTAssertEqualObjects([query.runButton title], @"Run Current");
	XCTAssertEqualObjects([primary title], @"Run Current Query");
	XCTAssertTrue(NSEqualRanges([query currentQueryRange], NSMakeRange(0, 15)), @"%@", NSStringFromRange([query currentQueryRange]));

	// After the last statement's semicolon and whitespace: the statement before
	NSString *sql = @"SELECT 1 AS one; SELECT 2 AS two;  \n";
	[self setSQL:sql];
	[query.editor setSelectedRange:NSMakeRange([sql length], 0)];
	XCTAssertEqualObjects([query.runButton title], @"Run Previous");
	XCTAssertEqualObjects([primary title], @"Run Previous Query");
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"], @"⌘R runs the statement before the caret");

	// A comment after the last statement is "after" it too
	sql = @"SELECT 1 AS one; -- note";
	[self setSQL:sql];
	[query.editor setSelectedRange:NSMakeRange([sql length], 0)];
	XCTAssertEqualObjects([query.runButton title], @"Run Previous");

	// Before the semicolon: still the current one
	sql = @"SELECT 1 AS one; SELECT 2 AS two";
	[self setSQL:sql];
	[query.editor setSelectedRange:NSMakeRange([sql length], 0)];
	XCTAssertEqualObjects([query.runButton title], @"Run Current");

	// A selection
	[query.editor setSelectedRange:NSMakeRange(0, 15)];
	XCTAssertEqualObjects([query.runButton title], @"Run Selection");
	XCTAssertEqualObjects([primary title], @"Run Selected Text");
	[query runPrimaryQueryAction:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"]);

	// Whitespace alone selected: nothing runs (a beep)
	sql = @"SELECT 2 AS two;    SELECT 3 AS three";
	[self setSQL:sql];
	[query.editor setSelectedRange:NSMakeRange(16, 4)];
	XCTAssertEqualObjects([query.runButton title], @"Run Selection");
	[query runPrimaryQueryAction:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"], @"the grid is unchanged");
}

- (void)testRunControlsDisabledWhileBusy
{
	SPPostgresQueryController *query = self.query;
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	NSMenu *menu = [query.runButton menu];
	XCTAssertTrue([query.runButton isEnabled]);
	XCTAssertTrue([[menu itemWithTag:1] isEnabled]);
	XCTAssertTrue([[menu itemWithTag:2] isEnabled]);

	[self setSQL:@"SELECT pg_sleep(2)"];
	[query runAllQueries:nil];
	XCTAssertTrue(runner.isBusy);
	XCTAssertFalse([query.runButton isEnabled]);
	XCTAssertFalse([[menu itemWithTag:1] isEnabled]);
	XCTAssertFalse([[menu itemWithTag:2] isEnabled]);

	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.runButton isEnabled]; } timeout:2]);
	XCTAssertTrue([[menu itemWithTag:1] isEnabled]);
	XCTAssertTrue([[menu itemWithTag:2] isEnabled]);
}

#pragma mark - Results bar

- (void)testInfoPaneToggle
{
	SPPostgresQueryController *query = self.query;
	NSDictionary *before = [self.scratch persistentDomainForName:SPQueryBarScratchSuite];
	NSDictionary *standardBefore = [[NSUserDefaults standardUserDefaults] persistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];

	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	[query.infoPaneButton performClick:nil];
	XCTAssertFalse([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	XCTAssertEqual([query.infoPaneButton state], NSControlStateValueOff);
	[self spinUntil:^BOOL{ return NO; } timeout:0.5];
	XCTAssertGreaterThan(NSHeight([[[query.infoPaneSplitView subviews] lastObject] frame]), 0);

	[query.infoPaneButton performClick:nil];
	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	XCTAssertEqual([query.infoPaneButton state], NSControlStateValueOn);
	[self spinUntil:^BOOL{ return NO; } timeout:0.5];

	XCTAssertEqualObjects([self.scratch persistentDomainForName:SPQueryBarScratchSuite], before, @"nothing written");
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] persistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]], standardBefore);
}

- (void)testEditModeToggleWritesSharedPreference
{
	SPPostgresQueryController *query = self.query;
	id standardBefore = [[NSUserDefaults standardUserDefaults] objectForKey:SPQueryBarEditInSheetKey];
	XCTAssertEqual([query.editModeButton state], NSControlStateValueOff);

	[query.editModeButton performClick:nil];
	XCTAssertTrue([self.scratch boolForKey:SPQueryBarEditInSheetKey]);
	XCTAssertEqual([query.editModeButton state], NSControlStateValueOn);

	// Changed elsewhere (MySQL's toggle, the Content bar): the button follows
	[self.scratch setBool:NO forKey:SPQueryBarEditInSheetKey];
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.editModeButton state] == NSControlStateValueOff; } timeout:2]);
	[self.scratch setBool:YES forKey:SPQueryBarEditInSheetKey];
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.editModeButton state] == NSControlStateValueOn; } timeout:2]);

	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] objectForKey:SPQueryBarEditInSheetKey], standardBefore, @"the saved preference is untouched");
}

- (void)testExportResultOpensCSVSheetWithQueryResult
{
	SPPostgresQueryController *query = self.query;
	NSMenuItem *csv = [self exportCSVItem];
	XCTAssertFalse([csv isEnabled], @"no result yet");

	[self setSQL:@"SELECT 1 AS one"];
	[query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:query.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"]);
	XCTAssertTrue([csv isEnabled]);

	NSMenu *submenu = [csv menu];
	[submenu performActionForItemAtIndex:[submenu indexOfItem:csv]];
	SPPostgresExportController *export = self.document.exportController;
	XCTAssertNotNil(export);
	XCTAssertNotNil([export.sheet sheetParent]);
	XCTAssertEqualObjects([export.sourcePopup titleOfSelectedItem], @"Query result");
	XCTAssertEqual([export.formatControl selectedSegment], 1, @"CSV");
	XCTAssertTrue([export.exportButton isEnabled]);

	[export cancel:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.exportController == nil; } timeout:5]);
	XCTAssertNil([self.controller window].attachedSheet);
}

#pragma mark - Status line and info pane (MySQL's SPCustomQuery.m:889–950, updateStatusInterfaceWithDetails:)

/// Runs every statement of sql on the tab's runner and waits for it.
- (void)runSQL:(NSString *)sql
{
	[self setSQL:sql];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.query.taskRunner timeout:30]);
}

/// The whole of text matches pattern, taken literally except TIME (+[NSString stringForTimeInterval:]'s output).
- (void)assertText:(NSString *)text matches:(NSString *)pattern
{
	NSString *escaped = [NSRegularExpression escapedPatternForString:pattern];
	escaped = [escaped stringByReplacingOccurrencesOfString:@"TIME" withString:@"(< )?[0-9.,]+ (ms|s)"];
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^%@$", escaped] options:0 error:NULL];
	XCTAssertNotNil(regex);
	XCTAssertEqual([regex numberOfMatchesInString:text ?: @"" options:0 range:NSMakeRange(0, [text length])], 1u, @"\"%@\" doesn't match \"%@\"", text, pattern);
}

- (void)testStatusTextSingleQuery
{
	SPPostgresQueryController *query = self.query;
	[self runSQL:@"SELECT * FROM content_test.items"];
	XCTAssertEqual([query.resultsView numberOfRows], 30);
	[self assertText:query.statusText matches:@"No errors; 30 rows affected, first row available after TIME"];
	XCTAssertEqualObjects([query.statusField stringValue], query.statusText, @"the status line shows it");

	[self runSQL:@"UPDATE content_test.items SET name = name WHERE false"];
	[self assertText:query.statusText matches:@"No errors; 0 rows affected, taking TIME"];

	[self runSQL:@"UPDATE content_test.items SET name = name WHERE id = 1"];
	[self assertText:query.statusText matches:@"No errors; 1 row affected, taking TIME"];
	XCTAssertEqualObjects(query.lastRunQueryText, @"UPDATE content_test.items SET name = name WHERE id = 1");

	// A row set without rows: no first row
	[self runSQL:@"SELECT id FROM content_test.items WHERE false"];
	[self assertText:query.statusText matches:@"No errors; 0 rows affected, taking TIME"];
	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	XCTAssertEqualObjects([query infoPaneString], @"There were no errors.");
}

- (void)testStatusTextMultipleQueries
{
	SPPostgresQueryController *query = self.query;
	[self runSQL:@"UPDATE content_test.items SET name = name WHERE id IN (1, 2); UPDATE content_test.items SET name = name WHERE id = 3"];
	[self assertText:query.statusText matches:@"No errors; 3 rows affected in total, by 2 queries taking TIME"];
	XCTAssertEqualObjects(query.lastRunQueryText, @"UPDATE content_test.items SET name = name WHERE id IN (1, 2);\nUPDATE content_test.items SET name = name WHERE id = 3", @"MySQL's usedQuery");

	[self runSQL:@"UPDATE content_test.items SET name = name WHERE id = 1; SELECT id FROM content_test.items WHERE false"];
	[self assertText:query.statusText matches:@"No errors; 1 row affected in total, by 2 queries taking TIME"];
}

- (void)testErrorOpensInfoPane
{
	SPPostgresQueryController *query = self.query;
	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Query Status");

	[self runSQL:@"SELECT 1; SELECT nope; SELECT 3"];
	XCTAssertTrue([query.statusText hasPrefix:@"Errors; "], @"%@", query.statusText);
	[self assertText:query.statusText matches:@"Errors; 1 row affected in total, by 2 queries taking TIME"];
	XCTAssertFalse([query.infoPaneSplitView isCollapsibleSubviewCollapsed], @"an error opens the info pane");
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Last Error Message");
	XCTAssertEqualObjects([query infoPaneString], @"[ERROR in query 2] column \"nope\" does not exist\nExecution stopped!");
	XCTAssertEqualObjects(query.lastRunQueryText, @"SELECT 1;\nSELECT nope", @"the statements run, the failing one too");

	// The server's DETAIL and HINT lines follow its message
	[self runSQL:@"SELECT 1; SELECT content_test.no_such_function(1); SELECT 3"];
	NSArray *lines = [[query infoPaneString] componentsSeparatedByString:@"\n"];
	XCTAssertEqual(lines.count, 3u, @"%@", [query infoPaneString]);
	XCTAssertEqualObjects(lines[0], @"[ERROR in query 2] function content_test.no_such_function(integer) does not exist");
	XCTAssertTrue([lines[1] hasPrefix:@"HINT: No function matches the given name and argument types."], @"%@", lines[1]);
	XCTAssertEqualObjects(lines[2], @"Execution stopped!");

	[self runSQL:@"INSERT INTO content_test.composite_pk (a, b, v) VALUES (1, 'a', 'dup')"];
	XCTAssertEqualObjects([query infoPaneString], @"duplicate key value violates unique constraint \"composite_pk_pkey\"\nDETAIL: Key (a, b)=(1, a) already exists.", @"one statement: the message alone, as MySQL's");
	[self assertText:query.statusText matches:@"Errors; 0 rows affected, taking TIME"];

	// The last statement failing: nothing was stopped
	[self runSQL:@"SELECT 1; SELECT nope"];
	XCTAssertEqualObjects([query infoPaneString], @"[ERROR in query 2] column \"nope\" does not exist");
	XCTAssertFalse([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);

	// The next clean run closes it
	[self runSQL:@"SELECT 1"];
	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	XCTAssertEqualObjects([query infoPaneString], @"There were no errors.");
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Query Status", @"set when the run starts, as MySQL's");
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testCancelledStatus
{
	SPPostgresQueryController *query = self.query;
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];

	[self setSQL:@"SELECT pg_sleep(30)"];
	[query runAllQueries:nil];
	XCTAssertTrue(runner.isBusy);
	// While running, as MySQL's: the info pane says so, without opening
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Query Status");
	XCTAssertEqualObjects([query infoPaneString], @"Running query...");
	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
	[self spinUntil:^BOOL{ return NO; } timeout:0.3];
	[runner cancelAll];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.statusText length] > 0; } timeout:5]);
	// As MySQL's, a cancel is an error
	[self assertText:query.statusText matches:@"Errors; Cancelled after TIME"];
	XCTAssertEqualObjects([query infoPaneString], @"Query cancelled.");
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Last Error Message");
	XCTAssertFalse([query.infoPaneSplitView isCollapsibleSubviewCollapsed], @"the pane opens");
	XCTAssertEqualObjects(query.lastRunQueryText, @"SELECT pg_sleep(30)");

	// Two statements, the first interrupted: one query sent
	[self setSQL:@"SELECT pg_sleep(30); SELECT 2"];
	[query runAllQueries:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [runner.currentDescription isEqualToString:@"Running query 1 of 2..."]; } timeout:10], @"%@", runner.currentDescription);
	XCTAssertEqualObjects([query infoPaneString], @"Running query 1 of 2...");
	[self spinUntil:^BOOL{ return NO; } timeout:0.3];
	[runner cancelAll];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.statusText length] > 0; } timeout:5]);
	[self assertText:query.statusText matches:@"Errors; Cancelled after TIME"];
	XCTAssertEqualObjects([query infoPaneString], @"[ERROR in query 1] Query cancelled.");
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Last Error Message");
	XCTAssertFalse([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);

	// The second interrupted: "in query 2"; the pane followed the statement running (MySQL's progress updater)
	[self setSQL:@"SELECT 1; SELECT pg_sleep(30)"];
	[query runAllQueries:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[query infoPaneString] isEqualToString:@"Running query 2 of 2..."]; } timeout:10], @"%@", [query infoPaneString]);
	XCTAssertEqualObjects([query.infoPaneTitle stringValue], @"Query Status");
	[self spinUntil:^BOOL{ return NO; } timeout:0.3];
	[runner cancelAll];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.statusText length] > 0; } timeout:5]);
	[self assertText:query.statusText matches:@"Errors; Cancelled in query 2, after TIME"];
	XCTAssertEqualObjects([query infoPaneString], @"[ERROR in query 2] Query cancelled.");
	XCTAssertEqualObjects(query.lastRunQueryText, @"SELECT 1;\nSELECT pg_sleep(30)");
	XCTAssertEqual(self.alerts.count, 0u);
}

/// Ruling 4: a cancel between statements (the next one never sent) counts the statements run.
- (void)testCancelBetweenStatementsCountsStatementsRun
{
	SPPostgresQueryController *query = self.query;
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	__block NSUInteger calls = 0;
	[query setStatementWillRunHook:^(NSString *statement) {
		// Before statement 2 is sent: the cancel request reaches the idle server (which ignores it) before the
		// statement, so statement 2 runs and the run stops before statement 3
		if (++calls == 2) {
			[runner cancelAll];
			usleep(300000);
		}
	}];
	[self setSQL:@"SELECT 1; SELECT 2 AS two; SELECT 3"];
	[query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertTrue([self spinUntil:^BOOL{ return [query.statusText length] > 0; } timeout:5]);
	[query setStatementWillRunHook:nil];

	[self assertText:query.statusText matches:@"Errors; Cancelled in query 2, after TIME"];
	XCTAssertEqualObjects([query infoPaneString], @"[ERROR in query 2] Query cancelled.");
	XCTAssertEqualObjects(query.lastRunQueryText, @"SELECT 1;\nSELECT 2 AS two", @"statement 3 was never sent");
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
	XCTAssertFalse([query.infoPaneSplitView isCollapsibleSubviewCollapsed]);
}

- (void)testPostgresNotesInInfoPane
{
	SPPostgresQueryController *query = self.query;

	// An aborted transaction
	[self runSQL:@"BEGIN; SELECT 1/0"];
	XCTAssertEqualObjects([query infoPaneString], @"[ERROR in query 2] division by zero\nThe current transaction is aborted; ROLLBACK to continue.");
	[self runSQL:@"ROLLBACK"];
	XCTAssertEqualObjects([query infoPaneString], @"There were no errors.");

	// The grid's rows are an earlier statement's
	[self runSQL:@"SELECT 1 AS one; UPDATE content_test.composite_pk SET v = v"];
	XCTAssertEqualObjects([query infoPaneString], @"There were no errors.\nNote: results shown from statement 1, the last one that returned rows.");
	XCTAssertTrue([query.infoPaneSplitView isCollapsibleSubviewCollapsed], @"a note doesn't open the pane");

	// COPY … TO STDOUT
	[self runSQL:@"COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT"];
	XCTAssertEqualObjects([query infoPaneString], @"There were no errors.\nCOPY 2 – output not shown");
	[self runSQL:@"SELECT 1 AS one; COPY (SELECT 1) TO STDOUT"];
	XCTAssertTrue([[query infoPaneString] containsString:@"[query 2] COPY 1 – output not shown"], @"%@", [query infoPaneString]);
	XCTAssertTrue([[query infoPaneString] containsString:@"results shown from statement 1"], @"%@", [query infoPaneString]);
}

@end
