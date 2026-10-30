#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

static const NSUInteger SPContentBarTestPort = 55418;
// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPLimitResults = @"LimitResults";
static NSString * const SPLimitResultsValue = @"LimitResultsValue";

/// The Content tab's bottom bar (Stage 10): MySQL's layout, images, tooltips and keys, ⌫ in the grid, the busy state.
@interface SPPostgresContentBarTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@end

@implementation SPPostgresContentBarTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

/// Overrides preferences for this test in the volatile argument domain (never the saved preferences).
- (void)overridePrefs:(NSDictionary *)values
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	[domain addEntriesFromDictionary:values];
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	[SPPostgresTestServers loadFixtureNamed:@"content" onPort:SPContentBarTestPort];
	[self overridePrefs:@{SPLimitResults: @YES, SPLimitResultsValue: @1000}];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 content bar";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPContentBarTestPort;
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

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPContentBarTestPort];
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	[self.content.taskRunner cancelAll];
	[SPPostgresTestServers waitForRunner:self.content.taskRunner timeout:30];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[self.other disconnect];
	self.other = nil;
	self.alerts = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresContentController *)content
{
	return self.document.contentController;
}

- (NSTableView *)grid
{
	return self.content.tableView;
}

/// Selects content_test.<table> in the sidebar and waits for its rows.
- (void)selectTable:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

/// A Content view of its own (700 pt wide as built), for the layout.
- (SPPostgresContentController *)standaloneContent
{
	SPPostgresContentController *content = [[SPPostgresContentController alloc] initWithConnection:self.other];
	[self addTeardownBlock:^{ [content invalidate]; }];
	return content;
}

- (NSArray<NSButton *> *)barButtonsOf:(SPPostgresContentController *)content
{
	return @[content.addButton, content.removeButton, content.duplicateButton, content.refreshButton, content.editModeButton,
			 content.filterToggleButton, content.previousPageButton, content.paginationButton, content.nextPageButton];
}

- (NSEvent *)keyDownWithKeyCode:(unsigned short)keyCode characters:(NSString *)characters
{
	return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
						windowNumber:[[[self grid] window] windowNumber] context:nil characters:characters
		 charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
}

/// Counts the confirmations asked for (each answered No, so nothing is deleted).
- (NSMutableArray<NSAlert *> *)recordConfirmations
{
	NSMutableArray<NSAlert *> *asked = [NSMutableArray array];
	self.content.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) {
		[asked addObject:alert];
		completion(NO);
	};
	return asked;
}

#pragma mark - Layout

- (void)testBarButtonsAtMySQLFrames
{
	SPPostgresContentController *content = [self standaloneContent];
	NSView *view = [content view];
	CGFloat width = NSWidth([view frame]);
	XCTAssertEqual(width, 700);

	NSArray<NSButton *> *buttons = [self barButtonsOf:content];
	NSArray<NSNumber *> *xs = @[@(-1), @30, @61, @93, @124, @155, @(width - 110), @(width - 79), @(width - 48)];
	for (NSUInteger i = 0; i < [buttons count]; i++) {
		XCTAssertTrue(NSEqualRects([buttons[i] frame], NSMakeRect([xs[i] doubleValue], -1, 32, 25)), @"button %lu at %@", (unsigned long)i, NSStringFromRect([buttons[i] frame]));
		XCTAssertEqual([buttons[i] bezelStyle], NSBezelStyleTexturedRounded, @"button %lu", (unsigned long)i);
	}

	// The right three keep their distance from the right edge
	[view setFrameSize:NSMakeSize(900, NSHeight([view frame]))];
	XCTAssertEqual(NSMinX([content.previousPageButton frame]), 900 - 110);
	XCTAssertEqual(NSMinX([content.paginationButton frame]), 900 - 79);
	XCTAssertEqual(NSMinX([content.nextPageButton frame]), 900 - 48);
	XCTAssertEqual(NSMinX([content.filterToggleButton frame]), 155, @"the left ones stay");
}

- (void)testBarImagesTooltipsAndKeys
{
	SPPostgresContentController *content = [self standaloneContent];
	NSArray<NSButton *> *buttons = [self barButtonsOf:content];

	NSArray *images = @[@"button_add", @"button_remove", @"button_duplicate", @"button_refresh", @"button_edit_mode",
						@"button_filter", @"button_left", @"button_pagination", @"button_right"];
	NSDictionary *alternates = @{@4: @"button_edit_mode_selected", @5: @"button_filter_active"};
	NSArray *toolTips = @[@"Add row (⌥⌘A)", @"Delete selected row(s) (⌫)", @"Duplicate selected row (⌘D)", @"Refresh table contents (⌘R)",
						  @"Toggle between editing simple text cells as a spreadsheet or in pop-up sheets", @"Show/Hide table content filters",
						  @"View previous page of results", @"Jump to page (⌘J) or view pagination options", @"View next page of results"];
	for (NSUInteger i = 0; i < [buttons count]; i++) {
		XCTAssertNotNil([buttons[i] image], @"button %lu", (unsigned long)i);
		XCTAssertEqual([buttons[i] image], [NSImage imageNamed:images[i]], @"button %lu", (unsigned long)i);
		if (alternates[@(i)]) XCTAssertEqual([buttons[i] alternateImage], [NSImage imageNamed:alternates[@(i)]], @"button %lu", (unsigned long)i);
		XCTAssertEqualObjects([buttons[i] toolTip], toolTips[i]);
	}

	// The two toggles are Toggle buttons (MySQL's pushIn + changeContents + lightByContents): when on they show the alternate image
	NSButton *reference = [[NSButton alloc] initWithFrame:NSZeroRect];
	[reference setButtonType:NSButtonTypeToggle];
	for (NSButton *toggle in @[content.editModeButton, content.filterToggleButton]) {
		XCTAssertEqual([[toggle cell] showsStateBy], [[reference cell] showsStateBy], @"%@", [toggle toolTip]);
		XCTAssertEqual([[toggle cell] highlightsBy], [[reference cell] highlightsBy], @"%@", [toggle toolTip]);
		XCTAssertTrue([[toggle cell] showsStateBy] & NSContentsCellMask, @"%@ shows its alternate image when on", [toggle toolTip]);
	}

	XCTAssertEqualObjects([content.addButton keyEquivalent], @"a");
	XCTAssertEqual([content.addButton keyEquivalentModifierMask], NSEventModifierFlagOption | NSEventModifierFlagCommand);
	XCTAssertEqualObjects([content.duplicateButton keyEquivalent], @"d");
	XCTAssertEqual([content.duplicateButton keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqualObjects([content.refreshButton keyEquivalent], @"r");
	XCTAssertEqual([content.refreshButton keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqualObjects([content.paginationButton keyEquivalent], @"j");
	XCTAssertEqual([content.paginationButton keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqualObjects([content.removeButton keyEquivalent], @"");
}

- (void)testCountFieldBetweenFilterAndPrevious
{
	SPPostgresContentController *content = [self standaloneContent];
	CGFloat width = NSWidth([[content view] frame]);
	XCTAssertEqual(NSMinX([content.countField frame]), 193);
	XCTAssertLessThanOrEqual(NSMaxX([content.countField frame]), width - 140);
	NSTextField *notice = [content valueForKey:@"noticeField"];
	XCTAssertLessThanOrEqual(NSMaxX([notice frame]), width - 140);
	XCTAssertGreaterThanOrEqual(NSMinX([notice frame]), NSMaxX([content.countField frame]));

	// Both stay between the filter toggle and Previous when the view widens
	[[content view] setFrameSize:NSMakeSize(900, NSHeight([[content view] frame]))];
	XCTAssertEqual(NSMinX([content.countField frame]), 193);
	XCTAssertLessThanOrEqual(NSMaxX([notice frame]), 900 - 140);
	XCTAssertGreaterThan(NSMaxX([notice frame]), 700 - 140, @"the notice widens with the view");
}

#pragma mark - ⌫ in the grid

- (void)testDeleteKeyInGridAsksToDeleteSelectedRows
{
	[self selectTable:@"items"];
	NSMutableArray<NSAlert *> *asked = [self recordConfirmations];

	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[[self grid] keyDown:[self keyDownWithKeyCode:51 characters:@"\x7f"]];
	XCTAssertEqual(asked.count, 1u);
	XCTAssertEqualObjects([asked.firstObject messageText], @"Delete selected row?");

	// ⌦ (forward delete) too
	unichar forwardDelete = NSDeleteFunctionKey;
	[[self grid] keyDown:[self keyDownWithKeyCode:117 characters:[NSString stringWithCharacters:&forwardDelete length:1]]];
	XCTAssertEqual(asked.count, 2u);
	XCTAssertEqualObjects([asked.lastObject messageText], @"Delete selected row?");

	// No selection: not asked
	[[self grid] deselectAll:nil];
	[[self grid] keyDown:[self keyDownWithKeyCode:51 characters:@"\x7f"]];
	XCTAssertEqual(asked.count, 2u);

	[SPPostgresTestServers waitForRunner:self.content.taskRunner timeout:30];
	XCTAssertEqualObjects([[[self.other execute:@"SELECT count(*) FROM content_test.items"] rowAsArray] firstObject], @30);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testDeleteKeyWhileEditingDoesNotDeleteRows
{
	[self selectTable:@"items"];
	NSMutableArray<NSAlert *> *asked = [self recordConfirmations];
	NSTableView *grid = [self grid];
	XCTAssertNotNil([grid window]);

	[grid selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[grid editColumn:1 row:0 withEvent:nil select:YES];
	XCTAssertNotNil([grid currentEditor], @"the cell is being edited");
	[grid keyDown:[self keyDownWithKeyCode:51 characters:@"\x7f"]];
	XCTAssertEqual(asked.count, 0u, @"⌫ while editing deletes characters, not rows");

	[grid abortEditing];
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testDeleteRowAlertUsesMySQLKeys
{
	[self selectTable:@"items"];
	NSMutableArray<NSAlert *> *asked = [self recordConfirmations];
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[self.content removeRows:nil];
	XCTAssertEqual(asked.count, 1u);

	NSArray<NSButton *> *buttons = [asked.firstObject buttons];
	XCTAssertEqual(buttons.count, 2u);
	XCTAssertEqualObjects([buttons[0] title], @"Delete");
	XCTAssertEqualObjects([buttons[0] keyEquivalent], @"d");
	XCTAssertEqual([buttons[0] keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqualObjects([buttons[1] title], @"Cancel");
	XCTAssertEqualObjects([buttons[1] keyEquivalent], @"\r");
}

#pragma mark - Busy

- (void)testBarDisabledWhileBusy
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	XCTAssertFalse(content.taskRunner.isInline);
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	XCTAssertTrue([content.addButton isEnabled]);
	XCTAssertTrue([content.removeButton isEnabled]);
	XCTAssertTrue([content.refreshButton isEnabled]);

	[SPPostgresTestServers queueSleep:1 onRunner:content.taskRunner];
	XCTAssertTrue(content.taskRunner.isBusy);
	for (NSButton *button in [self barButtonsOf:content]) {
		if (button == content.editModeButton) continue;
		XCTAssertFalse([button isEnabled], @"%@ while busy", [button toolTip]);
	}

	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertTrue([content.addButton isEnabled]);
	XCTAssertTrue([content.refreshButton isEnabled]);
	XCTAssertTrue([content.removeButton isEnabled], @"a row is selected");

	[[self grid] deselectAll:nil];
	XCTAssertFalse([content.removeButton isEnabled]);
	XCTAssertEqual(self.alerts.count, 0u);
}

@end
