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
#import "../Source/Postgres/SPPostgresPaginationView.h"
#import "../Source/Postgres/SPPostgresFieldEditorSheet.h"

static const NSUInteger SPContentBarTestPort = 55418;
// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPLimitResults = @"LimitResults";
static NSString * const SPLimitResultsValue = @"LimitResultsValue";
static NSString * const SPEditInSheetEnabled = @"EditInSheetEnabled";
static NSString * const SPRuleFilterEditorLastVisibilityChoice = @"RuleFilterEditorLastVisibilityChoice";
static NSString * const SPContentBarScratchSuite = @"SPPostgresStage10Tests";

/// Records the statements a connection is about to send (PostgresKit reports willExecute only to a delegate passed at init).
@interface SPContentBarStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPContentBarStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	@synchronized (self) { [self.statements addObject:[query description]]; }
}
/// Statements that change data.
- (NSArray *)writes
{
	NSMutableArray *writes = [NSMutableArray array];
	@synchronized (self) {
		for (NSString *statement in self.statements) {
			NSString *upper = [[statement stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
			if ([upper hasPrefix:@"UPDATE"] || [upper hasPrefix:@"INSERT"] || [upper hasPrefix:@"DELETE"]) [writes addObject:statement];
		}
	}
	return writes;
}
@end

/// One call of the field editor presenter.
@interface SPContentBarSheetCall : NSObject
@property (copy) NSString *value, *columnName, *typeName;
@property BOOL editable, allowNull;
@property (copy) void (^completion)(id newValue);
@end

@implementation SPContentBarSheetCall
@end

/// The Content tab's bottom bar (Stage 10): MySQL's layout, images, tooltips and keys, ⌫ in the grid, the busy state.
@interface SPPostgresContentBarTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSUserDefaults *scratch;
@property BOOL fieldEditorPrefsGuarded;
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
	// Edit mode off (in place), whatever the saved preference; the sheet mode tests unpin it for their scratch suite
	[self overridePrefs:@{SPLimitResults: @YES, SPLimitResultsValue: @1000, SPEditInSheetEnabled: @NO}];

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
	if (self.scratch) {
		[self.scratch removePersistentDomainForName:SPContentBarScratchSuite];
		self.scratch = nil;
	}
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

#pragma mark - Duplicate

- (id)serverValue:(NSString *)sql
{
	return [[[self.other execute:sql] rowAsArray] firstObject];
}

- (void)testDuplicateRowAppendsCopyAndSelectsIt
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	NSTableView *grid = [self grid];
	XCTAssertEqual([grid numberOfRows], 30);
	XCTAssertEqualObjects(content.countText, @"30 rows in table");
	XCTAssertEqual([content.duplicateButton target], content);
	XCTAssertEqual([content.duplicateButton action], @selector(duplicateRow:));

	[grid selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[content duplicateRow:nil];

	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqual([grid numberOfRows], 31);
	XCTAssertEqualObjects([grid selectedRowIndexes], [NSIndexSet indexSetWithIndex:30], @"the copy, last, is selected");
	XCTAssertTrue([content.countText hasPrefix:@"31 rows in table"], @"%@", content.countText);
	XCTAssertNil([grid currentEditor], @"no cell editor is opened");

	// The copy: a new id, the other values as row 1's
	NSTableColumn *idColumn = [grid tableColumns][0];
	NSTableColumn *nameColumn = [grid tableColumns][1];
	XCTAssertEqualObjects([[content tableView:grid objectValueForTableColumn:idColumn row:30] description], @"31");
	XCTAssertEqualObjects([[content tableView:grid objectValueForTableColumn:nameColumn row:30] description], @"item 1");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'item 1'"], @2);
}

- (void)testDuplicateEnabledOnlyForOneSelectedRow
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	NSTableView *grid = [self grid];

	[grid deselectAll:nil];
	XCTAssertFalse([content.duplicateButton isEnabled], @"no row selected");
	[grid selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	XCTAssertTrue([content.duplicateButton isEnabled], @"one row selected");
	[grid selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
	XCTAssertFalse([content.duplicateButton isEnabled], @"two rows selected");

	for (NSString *table in @[@"items_view", @"no_pk"]) {
		[self selectTable:table];
		[grid selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		XCTAssertEqual([grid numberOfSelectedRows], 1, @"%@", table);
		XCTAssertFalse([content.duplicateButton isEnabled], @"%@ can't be edited", table);
	}
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testDuplicateWithSeveralRowsShowsMySQLError
{
	[self selectTable:@"items"];
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
	[self.content duplicateRow:nil];

	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self.alerts.firstObject messageText], @"Error");
	XCTAssertEqualObjects([self.alerts.firstObject informativeText], @"You can only copy single rows.");
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @30);
}

- (void)testDuplicateWithPlainKeyShowsServerErrorAndAddsNothing
{
	[self selectTable:@"text_key"];
	SPPostgresContentController *content = self.content;
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	NSString *countBefore = content.countText;
	XCTAssertTrue([content.duplicateButton isEnabled]);

	[content duplicateRow:nil];

	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self.alerts.firstObject messageText], @"Could not duplicate the row");
	XCTAssertTrue([[self.alerts.firstObject informativeText] containsString:@"duplicate key"], @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqual([[self grid] numberOfRows], 2);
	XCTAssertEqualObjects(content.countText, countBefore);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.text_key"], @2);
}

- (void)testDuplicateRefusedWhileBusy
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

	[SPPostgresTestServers queueSleep:1 onRunner:content.taskRunner];
	XCTAssertTrue(content.taskRunner.isBusy);
	XCTAssertFalse([content.duplicateButton isEnabled]);
	[content duplicateRow:nil];

	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @30);
	XCTAssertTrue([content.duplicateButton isEnabled], @"enabled again once idle");
	XCTAssertEqual(self.alerts.count, 0u);
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

#pragma mark - Edit mode (field editor sheet)

/// Scratch preferences (never the saved ones), with the edit mode preference set; removed in tearDown. The edit mode
/// pinned in the argument domain by setUp (which shadows every defaults instance) is unpinned for this test.
- (NSUserDefaults *)scratchDefaultsInSheetMode:(BOOL)sheetMode
{
	[self unpinPrefs:@[SPEditInSheetEnabled]];
	if (!self.scratch) {
		self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPContentBarScratchSuite];
		[self.scratch removePersistentDomainForName:SPContentBarScratchSuite];
	}
	[self.scratch setBool:sheetMode forKey:SPEditInSheetEnabled];
	return self.scratch;
}

/// A Content view of its own on a connection whose writes are recorded, showing content_test.<table>.
- (SPPostgresContentController *)recordedContentShowing:(NSString *)table recorder:(SPContentBarStatementRecorder *)recorder sheetMode:(BOOL)sheetMode
{
	PGPostgresConnection *recorded = [SPPostgresTestServers connectedConnectionOnPort:SPContentBarTestPort database:@"pgkit_test" delegate:recorder];
	SPPostgresContentController *content = [[SPPostgresContentController alloc] initWithConnection:recorded];
	[self addTeardownBlock:^{
		[content invalidate];
		[recorded disconnect];
		(void)recorder; // the connection's delegate (not retained by it) outlives the disconnect
	}];
	content.defaults = [self scratchDefaultsInSheetMode:sheetMode];
	NSMutableArray *alerts = self.alerts;
	content.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[content showTable:table inSchema:@"content_test"];
	return content;
}

- (NSMutableArray<SPContentBarSheetCall *> *)recordSheetsOf:(SPPostgresContentController *)content
{
	NSMutableArray<SPContentBarSheetCall *> *calls = [NSMutableArray array];
	content.fieldEditorPresenter = ^(NSString *value, NSString *columnName, NSString *typeName, BOOL editable, BOOL allowNull, void (^completion)(id)) {
		SPContentBarSheetCall *call = [[SPContentBarSheetCall alloc] init];
		call.value = value;
		call.columnName = columnName;
		call.typeName = typeName;
		call.editable = editable;
		call.allowNull = allowNull;
		call.completion = completion;
		[calls addObject:call];
	};
	return calls;
}

- (NSTableColumn *)columnNamed:(NSString *)name of:(SPPostgresContentController *)content
{
	for (NSTableColumn *column in [content.tableView tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:name]) return column;
	}
	XCTFail(@"no column %@", name);
	return nil;
}

- (BOOL)content:(SPPostgresContentController *)content shouldEditRow:(NSInteger)row column:(NSString *)name
{
	return [content tableView:content.tableView shouldEditTableColumn:[self columnNamed:name of:content] row:row];
}

- (void)testEditModeButtonReflectsAndWritesSharedPreference
{
	[self unpinPrefs:@[SPEditInSheetEnabled]]; // the saved value is read below, not setUp's pin
	NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
	id standardBefore = [standard objectForKey:SPEditInSheetEnabled];

	for (NSNumber *initial in @[@NO, @YES]) {
		SPPostgresContentController *content = [self standaloneContent];
		content.defaults = [self scratchDefaultsInSheetMode:[initial boolValue]];
		XCTAssertEqual([content.editModeButton state], [initial boolValue] ? NSControlStateValueOn : NSControlStateValueOff);
		XCTAssertEqual([content.editModeButton target], content);
		XCTAssertEqual([content.editModeButton action], @selector(toggleEditMode:));
		XCTAssertTrue([content.editModeButton isEnabled]);

		[content.editModeButton performClick:nil];
		XCTAssertEqual([self.scratch boolForKey:SPEditInSheetEnabled], ![initial boolValue]);
		XCTAssertEqual([content.editModeButton state], [initial boolValue] ? NSControlStateValueOff : NSControlStateValueOn);
	}
	XCTAssertEqualObjects([standard objectForKey:SPEditInSheetEnabled], standardBefore, @"the saved preferences are untouched");
}

- (void)testEditModeButtonFollowsPreferenceChangedElsewhere
{
	SPPostgresContentController *content = [self standaloneContent];
	NSUserDefaults *scratch = [self scratchDefaultsInSheetMode:NO];
	content.defaults = scratch;
	XCTAssertEqual([content.editModeButton state], NSControlStateValueOff);

	[scratch setBool:YES forKey:SPEditInSheetEnabled];
	XCTAssertEqual([content.editModeButton state], NSControlStateValueOn);
	[scratch setBool:NO forKey:SPEditInSheetEnabled];
	XCTAssertEqual([content.editModeButton state], NSControlStateValueOff);

	// Once replaced, the old preferences are no longer followed
	NSUserDefaults *other = [[NSUserDefaults alloc] initWithSuiteName:@"SPPostgresStage10TestsOther"];
	[other removePersistentDomainForName:@"SPPostgresStage10TestsOther"];
	[self addTeardownBlock:^{ [other removePersistentDomainForName:@"SPPostgresStage10TestsOther"]; }];
	content.defaults = other;
	[scratch setBool:YES forKey:SPEditInSheetEnabled];
	XCTAssertEqual([content.editModeButton state], NSControlStateValueOff);
	[other setBool:YES forKey:SPEditInSheetEnabled];
	XCTAssertEqual([content.editModeButton state], NSControlStateValueOn);
	[content invalidate];
	[other setBool:NO forKey:SPEditInSheetEnabled]; // no observer left to call back
}

- (void)testSheetModeOpensFieldEditorInsteadOfInlineEdit
{
	SPContentBarStatementRecorder *recorder = [[SPContentBarStatementRecorder alloc] init];
	SPPostgresContentController *content = [self recordedContentShowing:@"items" recorder:recorder sheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];
	XCTAssertEqual([content.tableView numberOfRows], 30);

	XCTAssertFalse([self content:content shouldEditRow:0 column:@"name"]);
	XCTAssertEqual(calls.count, 1u);
	XCTAssertEqualObjects(calls[0].value, @"item 1");
	XCTAssertEqualObjects(calls[0].columnName, @"name");
	XCTAssertEqualObjects(calls[0].typeName, @"text");
	XCTAssertTrue(calls[0].editable);
	XCTAssertTrue(calls[0].allowNull);

	// One sheet at a time
	XCTAssertFalse([self content:content shouldEditRow:1 column:@"name"]);
	XCTAssertEqual(calls.count, 1u);
	calls[0].completion(nil);

	// NULL is shown as the placeholder; a NOT NULL column doesn't allow it
	XCTAssertFalse([self content:content shouldEditRow:0 column:@"note"]);
	XCTAssertEqual(calls.count, 2u);
	XCTAssertEqualObjects(calls[1].value, @"NULL");
	XCTAssertTrue(calls[1].allowNull);
	calls[1].completion(nil);

	XCTAssertFalse([self content:content shouldEditRow:0 column:@"id"]);
	XCTAssertEqual(calls.count, 3u);
	XCTAssertEqualObjects(calls[2].value, @"1");
	XCTAssertEqualObjects(calls[2].typeName, @"integer");
	XCTAssertFalse(calls[2].allowNull);
	calls[2].completion(nil);

	XCTAssertEqualObjects([recorder writes], (@[]));
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testSheetResultUpdatesServer
{
	SPContentBarStatementRecorder *recorder = [[SPContentBarStatementRecorder alloc] init];
	SPPostgresContentController *content = [self recordedContentShowing:@"items" recorder:recorder sheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];

	// Cancelled: nothing sent
	XCTAssertFalse([self content:content shouldEditRow:1 column:@"name"]);
	calls[0].completion(nil);
	XCTAssertEqualObjects([recorder writes], (@[]));

	XCTAssertFalse([self content:content shouldEditRow:1 column:@"name"]);
	XCTAssertEqual(calls.count, 2u);
	calls[1].completion(@"changed");
	XCTAssertEqual([recorder writes].count, 1u, @"%@", [recorder writes]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 2"], @"changed");
	XCTAssertEqualObjects([content tableView:content.tableView objectValueForTableColumn:[self columnNamed:@"name" of:content] row:1], @"changed");

	// A completion called again sends nothing more
	calls[1].completion(@"again");
	XCTAssertEqual([recorder writes].count, 1u);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testSheetNullPlaceholderWritesNull
{
	SPContentBarStatementRecorder *recorder = [[SPContentBarStatementRecorder alloc] init];
	SPPostgresContentController *content = [self recordedContentShowing:@"items" recorder:recorder sheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];

	XCTAssertFalse([self content:content shouldEditRow:2 column:@"note"]);
	XCTAssertEqualObjects(calls[0].value, @"note 3");
	calls[0].completion(@"NULL");
	XCTAssertEqual([recorder writes].count, 1u);
	XCTAssertEqualObjects([self serverValue:@"SELECT note IS NULL FROM content_test.items WHERE id = 3"], @YES);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testSheetModeOnReadOnlyRelationOpensReadOnly
{
	SPContentBarStatementRecorder *recorder = [[SPContentBarStatementRecorder alloc] init];
	SPPostgresContentController *content = [self recordedContentShowing:@"items_view" recorder:recorder sheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];
	XCTAssertEqual([content.tableView numberOfRows], 30);

	XCTAssertFalse([self content:content shouldEditRow:0 column:@"name"]);
	XCTAssertEqual(calls.count, 1u);
	XCTAssertEqualObjects(calls[0].value, @"item 1");
	XCTAssertFalse(calls[0].editable);
	calls[0].completion(@"x");
	XCTAssertEqualObjects([recorder writes], (@[]));
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 1"], @"item 1");
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testSheetResultAfterTableSwitchOrInvalidateSendsNothing
{
	SPContentBarStatementRecorder *recorder = [[SPContentBarStatementRecorder alloc] init];
	SPPostgresContentController *content = [self recordedContentShowing:@"items" recorder:recorder sheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];

	XCTAssertFalse([self content:content shouldEditRow:0 column:@"name"]);
	[content showTable:@"items" inSchema:@"content_test"];
	XCTAssertEqual([content.tableView numberOfRows], 30);
	calls[0].completion(@"after switch");
	XCTAssertEqualObjects([recorder writes], (@[]));

	XCTAssertFalse([self content:content shouldEditRow:0 column:@"name"]);
	XCTAssertEqual(calls.count, 2u, @"the late completion ended the pending sheet");
	SPPostgresContentController *invalidated = content;
	void (^completion)(id) = calls[1].completion;
	[invalidated invalidate];
	completion(@"after invalidate");
	XCTAssertEqualObjects([recorder writes], (@[]));
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 1"], @"item 1");
}

- (void)testAddRowInSheetModeOpensOneSheet
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	content.defaults = [self scratchDefaultsInSheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];
	XCTAssertNotNil([[self grid] window]);

	[content addRow:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);

	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqual([[self grid] numberOfRows], 31);
	XCTAssertEqual(calls.count, 1u);
	XCTAssertEqualObjects(calls[0].columnName, @"id", @"the first editable column");
	XCTAssertTrue(calls[0].editable);
	XCTAssertNil([[self grid] currentEditor], @"no inline editor");
	calls[0].completion(nil);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);
}

/**
 * MySQL's field editor uses the saved preferences: its sheet saves its frame ("NSWindow Frame SPFieldEditorTextSheet",
 * or ...BlobSheet) and its end saves the spell checking choice. Their saved values (or their absence) are put back
 * after this test, once, whatever the sheets wrote.
 */
- (void)guardFieldEditorPrefs
{
	if (self.fieldEditorPrefsGuarded) return;
	self.fieldEditorPrefsGuarded = YES;

	NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
	NSString *domainName = [[NSBundle mainBundle] bundleIdentifier];
	NSArray<NSString *> *keys = @[@"NSWindow Frame SPFieldEditorTextSheet", @"NSWindow Frame SPFieldEditorBlobSheet", @"BlobTextEditorSpellCheckingEnabled"];
	NSDictionary *saved = [standard persistentDomainForName:domainName] ?: @{};
	NSDictionary *before = [saved dictionaryWithValuesForKeys:keys]; // NSNull where absent
	[self addTeardownBlock:^{
		for (NSString *key in keys) {
			id value = [before objectForKey:key];
			if (value == [NSNull null]) [standard removeObjectForKey:key];
			else [standard setObject:value forKey:key];
		}
		NSDictionary *after = [[standard persistentDomainForName:domainName] ?: @{} dictionaryWithValuesForKeys:keys];
		XCTAssertEqualObjects(after, before, @"the saved preferences are as they were");
	}];
}

/// Opens MySQL's field editor sheet (no presenter) on a cell, then ends it as its OK button would, before its result.
- (void)openAndEndDefaultSheetOn:(SPPostgresContentController *)content row:(NSInteger)row column:(NSString *)name
{
	[self guardFieldEditorPrefs];
	NSWindow *window = [content.tableView window];
	[window orderFront:nil]; // sheets attach to a window on screen (tearDown orders it out)
	XCTAssertNil(window.attachedSheet);
	XCTAssertFalse([self content:content shouldEditRow:row column:name]);
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet != nil; } timeout:5], @"the field editor sheet is shown");
	NSWindow *sheet = window.attachedSheet;
	[NSApp endSheet:sheet];
	[sheet orderOut:nil];
}

- (void)testSheetFileDataIsSentAsUTF8TextOrRefused
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	content.defaults = [self scratchDefaultsInSheetMode:YES];
	XCTAssertNil(content.fieldEditorPresenter);

	// A file loaded into the sheet (NSData) that is UTF-8: its text is sent
	[self openAndEndDefaultSheetOn:content row:1 column:@"name"];
	[[SPPostgresFieldEditorSheet openSheetOnWindow:content.tableView.window] processFieldEditorResult:[@"from a file ✓" dataUsingEncoding:NSUTF8StringEncoding] contextInfo:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 2"], @"from a file ✓");
	XCTAssertEqualObjects([content tableView:content.tableView objectValueForTableColumn:[self columnNamed:@"name" of:content] row:1], @"from a file ✓");

	// Not UTF-8: refused, nothing sent (not NULL)
	[self openAndEndDefaultSheetOn:content row:2 column:@"name"];
	const unsigned char bytes[] = {0xff, 0xfe, 0x00, 0x80};
	[[SPPostgresFieldEditorSheet openSheetOnWindow:content.tableView.window] processFieldEditorResult:[NSData dataWithBytes:bytes length:sizeof(bytes)] contextInfo:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 3"], [@"" stringByPaddingToLength:10000 withString:@"x" startingAtIndex:0]);

	// The sheet is no longer pending: another opens
	[self openAndEndDefaultSheetOn:content row:0 column:@"name"];
	[[SPPostgresFieldEditorSheet openSheetOnWindow:content.tableView.window] processFieldEditorResult:nil contextInfo:nil];
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 1"], @"item 1");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

- (void)testSheetModeOpensNothingWhileBusy
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	content.defaults = [self scratchDefaultsInSheetMode:YES];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];
	SPPostgresTaskRunner *runner = content.taskRunner;
	XCTAssertFalse(runner.isInline);

	// MySQL edits nothing (and opens no sheet) while the document is working: not even a read-only sheet here
	[SPPostgresTestServers queueSleep:2 onRunner:runner];
	XCTAssertTrue(runner.isBusy);
	XCTAssertFalse([self content:content shouldEditRow:0 column:@"name"]);
	XCTAssertFalse([self content:content shouldEditRow:1 column:@"id"]);
	XCTAssertTrue(runner.isBusy);
	XCTAssertEqual(calls.count, 0u, @"no sheet while busy");
	XCTAssertNil([[[content view] window] attachedSheet]);

	// Once idle the sheet opens
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertFalse([self content:content shouldEditRow:0 column:@"name"]);
	XCTAssertEqual(calls.count, 1u);
	XCTAssertEqualObjects(calls[0].value, @"item 1");
	XCTAssertTrue(calls[0].editable);
	calls[0].completion(nil);
	XCTAssertFalse(runner.isBusy);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testInlineEditUnchangedWhenSheetModeOff
{
	SPContentBarStatementRecorder *recorder = [[SPContentBarStatementRecorder alloc] init];
	SPPostgresContentController *content = [self recordedContentShowing:@"items" recorder:recorder sheetMode:NO];
	NSMutableArray<SPContentBarSheetCall *> *calls = [self recordSheetsOf:content];

	XCTAssertTrue([self content:content shouldEditRow:0 column:@"name"]);
	XCTAssertEqual(calls.count, 0u);
}

#pragma mark - Filter bar show/hide

/// Scratch preferences (never the saved ones) with the filter bar visibility unset; removed in tearDown.
- (NSUserDefaults *)scratchDefaultsWithFilterBarChoiceUnset
{
	NSUserDefaults *scratch = [self scratchDefaultsInSheetMode:NO];
	[scratch removeObjectForKey:SPRuleFilterEditorLastVisibilityChoice];
	return scratch;
}

/// A Content view of its own with scratch preferences (filter bar visibility unset), showing content_test.<table>.
- (SPPostgresContentController *)scratchContentShowing:(NSString *)table
{
	SPPostgresContentController *content = [self standaloneContent];
	content.defaults = [self scratchDefaultsWithFilterBarChoiceUnset];
	NSMutableArray *alerts = self.alerts;
	content.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[content showTable:table inSchema:@"content_test"];
	return content;
}

- (NSView *)filterBarOf:(SPPostgresContentController *)content
{
	return [(NSView *)[content valueForKey:@"filterValueField"] superview];
}

/// The grid's scroll view's top, in the Content view.
- (CGFloat)gridTopOf:(SPPostgresContentController *)content
{
	return NSMaxY([content.tableView.enclosingScrollView frame]);
}

- (void)testFilterBarHiddenByDefault
{
	SPPostgresContentController *content = [self scratchContentShowing:@"items"];
	XCTAssertNil([self.scratch objectForKey:SPRuleFilterEditorLastVisibilityChoice]);
	XCTAssertEqual([content.tableView numberOfRows], 30);

	XCTAssertTrue([[self filterBarOf:content] isHidden]);
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOff);
	XCTAssertEqual([self gridTopOf:content], NSHeight([[content view] frame]), @"the grid takes the filter bar's 30 pt");
	XCTAssertEqual(NSMinY([content.tableView.enclosingScrollView frame]), 23, @"above the bottom bar");
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testToggleShowsBarAndStoresChoice
{
	SPPostgresContentController *content = [self scratchContentShowing:@"items"];
	NSView *view = [content view];
	NSView *filterBar = [self filterBarOf:content];
	XCTAssertEqual([content.filterToggleButton target], content);
	XCTAssertEqual([content.filterToggleButton action], @selector(toggleFilterBar:));

	[content toggleFilterBar:nil];
	XCTAssertTrue(content.filterBarVisible);
	XCTAssertFalse([filterBar isHidden]);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOn);
	XCTAssertEqual([self gridTopOf:content], NSHeight([view frame]) - 30);
	XCTAssertEqual(NSMaxY([filterBar frame]), NSHeight([view frame]));
	XCTAssertTrue([self.scratch objectForKey:SPRuleFilterEditorLastVisibilityChoice] != nil);
	XCTAssertTrue([self.scratch boolForKey:SPRuleFilterEditorLastVisibilityChoice]);

	// Shown, the grid keeps below the bar as the view resizes
	[view setFrameSize:NSMakeSize(900, 650)];
	XCTAssertEqual([self gridTopOf:content], 650 - 30);
	XCTAssertEqual(NSMinY([filterBar frame]), 650 - 30);

	[content toggleFilterBar:nil];
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertTrue([filterBar isHidden]);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOff);
	XCTAssertEqual([self gridTopOf:content], 650);
	XCTAssertTrue([self.scratch objectForKey:SPRuleFilterEditorLastVisibilityChoice] != nil);
	XCTAssertFalse([self.scratch boolForKey:SPRuleFilterEditorLastVisibilityChoice]);

	// Hidden, the grid keeps to the top as the view resizes
	[view setFrameSize:NSMakeSize(700, 500)];
	XCTAssertEqual([self gridTopOf:content], 500);
	XCTAssertEqual(NSMinY([content.tableView.enclosingScrollView frame]), 23);

	// A click (which turns the toggle on before its action) shows it too
	[content.filterToggleButton performClick:nil];
	XCTAssertTrue(content.filterBarVisible);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOn);
	XCTAssertEqual([self gridTopOf:content], 500 - 30);
	XCTAssertTrue([self.scratch boolForKey:SPRuleFilterEditorLastVisibilityChoice]);
	[content.filterToggleButton performClick:nil];
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOff);
	XCTAssertFalse([self.scratch boolForKey:SPRuleFilterEditorLastVisibilityChoice]);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testVisibilityReadAtEachTableLoad
{
	SPPostgresContentController *content = [self scratchContentShowing:@"items"];
	XCTAssertFalse(content.filterBarVisible);

	[self.scratch setBool:YES forKey:SPRuleFilterEditorLastVisibilityChoice];
	XCTAssertFalse(content.filterBarVisible, @"read at a table load");
	[content showTable:@"composite_pk" inSchema:@"content_test"];
	XCTAssertTrue(content.filterBarVisible);
	XCTAssertFalse([[self filterBarOf:content] isHidden]);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOn);
	XCTAssertEqual([self gridTopOf:content], NSHeight([[content view] frame]) - 30);

	[self.scratch setBool:NO forKey:SPRuleFilterEditorLastVisibilityChoice];
	[content showTable:@"items" inSchema:@"content_test"];
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertTrue([[self filterBarOf:content] isHidden]);
	XCTAssertEqual([content.filterToggleButton state], NSControlStateValueOff);
	XCTAssertEqual([self gridTopOf:content], NSHeight([[content view] frame]));
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testHidingBarWithFilterAppliedReloadsUnfiltered
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	content.defaults = [self scratchDefaultsWithFilterBarChoiceUnset];
	SPPostgresTaskRunner *runner = content.taskRunner;
	NSWindow *window = [[content view] window];
	XCTAssertNotNil(window);
	NSTextField *valueField = [content valueForKey:@"filterValueField"];
	if (content.filterBarVisible) [content toggleFilterBar:nil]; // shown as the saved preferences say (read at the table load)
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertFalse(runner.isBusy);

	// Shown by a click: the value field takes the focus
	[content.filterToggleButton performClick:nil];
	XCTAssertTrue(content.filterBarVisible);
	id responder = [window firstResponder];
	XCTAssertTrue(responder == valueField || ([responder respondsToSelector:@selector(isFieldEditor)] && [responder isFieldEditor] && [responder delegate] == valueField), @"%@", responder);

	// Hidden with no filter applied: nothing is loaded; the focus leaves the bar for the grid
	[content toggleFilterBar:nil];
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertFalse(runner.isBusy);
	XCTAssertEqual([window firstResponder], [self grid]);

	// Sorted by price, descending (id 4 first), and filtered to one row
	NSTableColumn *price = [self columnNamed:@"price" of:content];
	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:price];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:price];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqualObjects([content tableView:[self grid] objectValueForTableColumn:[self columnNamed:@"id" of:content] row:0], @"4");

	[content toggleFilterBar:nil];
	[(NSPopUpButton *)[content valueForKey:@"filterColumnPopup"] selectItemWithTitle:@"name"];
	[(NSPopUpButton *)[content valueForKey:@"filterComparisonPopup"] selectItemWithTitle:@"="];
	[valueField setStringValue:@"item 1"];
	[content applyFilter:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual([[self grid] numberOfRows], 1);
	XCTAssertEqualObjects(content.countText, @"1 row of 30 matches filter");

	[content toggleFilterBar:nil];
	XCTAssertFalse(content.filterBarVisible);
	XCTAssertEqualObjects(runner.currentDescription, @"Filtering table...");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects(content.countText, @"30 rows in table");
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertNotNil([[self grid] indicatorImageInTableColumn:price], @"the sort column is kept");
	XCTAssertEqualObjects([content tableView:[self grid] objectValueForTableColumn:[self columnNamed:@"id" of:content] row:0], @"4", @"still descending by price");
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testFilterToggleDisabledWithoutTable
{
	SPPostgresContentController *content = [self standaloneContent];
	content.defaults = [self scratchDefaultsWithFilterBarChoiceUnset];
	XCTAssertFalse([content.filterToggleButton isEnabled], @"no table");
	[content showTable:nil inSchema:nil];
	XCTAssertFalse([content.filterToggleButton isEnabled], @"no table");
	[content showTable:@"items" inSchema:@"content_test"];
	XCTAssertTrue([content.filterToggleButton isEnabled]);
	[content showTable:nil inSchema:nil];
	XCTAssertFalse([content.filterToggleButton isEnabled], @"no table");

	// While the runner is busy
	[self selectTable:@"items"];
	XCTAssertTrue([self.content.filterToggleButton isEnabled]);
	[SPPostgresTestServers queueSleep:1 onRunner:self.content.taskRunner];
	XCTAssertTrue(self.content.taskRunner.isBusy);
	XCTAssertFalse([self.content.filterToggleButton isEnabled]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.content.taskRunner timeout:30]);
	XCTAssertTrue([self.content.filterToggleButton isEnabled]);
	XCTAssertEqual(self.alerts.count, 0u);
}

#pragma mark - Jump to page popover

/// Removes preference keys from the volatile argument domain for this test (it shadows every defaults instance's own values).
- (void)unpinPrefs:(NSArray<NSString *> *)keys
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	[domain removeObjectsForKeys:keys];
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];
}

/// A Content view of its own with scratch preferences (7 rows per page), showing content_test.items (30 rows) on page 1.
- (SPPostgresContentController *)pagedContentLimited:(BOOL)limited
{
	[self unpinPrefs:@[SPLimitResults, SPLimitResultsValue]];
	NSUserDefaults *scratch = [self scratchDefaultsWithFilterBarChoiceUnset];
	[scratch setBool:limited forKey:SPLimitResults];
	[scratch setInteger:7 forKey:SPLimitResultsValue];
	SPPostgresContentController *content = [self scratchContentShowing:@"items"];
	XCTAssertEqualObjects(content.countText, limited ? @"Rows 1 - 7 of 30 from table" : @"30 rows in table");
	return content;
}

/// A window holding the content's view (for the popover and the field editor).
- (NSWindow *)windowHolding:(NSView *)view
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:[view frame] styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[[window contentView] addSubview:view];
	[window orderFront:nil];
	[self addTeardownBlock:^{ [window orderOut:nil]; }];
	return window;
}

- (NSArray<NSView *> *)subviewsOf:(NSView *)view
{
	NSMutableArray *all = [NSMutableArray array];
	for (NSView *subview in [view subviews]) {
		[all addObject:subview];
		[all addObjectsFromArray:[self subviewsOf:subview]];
	}
	return all;
}

- (void)testPaginationViewLayout
{
	SPPostgresContentController *content = [self pagedContentLimited:YES];
	SPPostgresPaginationView *pagination = content.paginationView;
	NSView *view = [pagination view];
	XCTAssertTrue(NSEqualSizes([view frame].size, NSMakeSize(330, 64)), @"%@", NSStringFromRect([view frame]));

	NSMutableArray *labels = [NSMutableArray array], *titles = [NSMutableArray array];
	for (NSView *subview in [self subviewsOf:view]) {
		if ([subview isKindOfClass:[NSButton class]]) [titles addObject:[(NSButton *)subview title]];
		else if ([subview isKindOfClass:[NSTextField class]] && ![(NSTextField *)subview isEditable]) [labels addObject:[(NSTextField *)subview stringValue]];
	}
	XCTAssertTrue([labels containsObject:@"Jump to page:"], @"%@", labels);
	XCTAssertTrue([labels containsObject:@"rows"], @"%@", labels);
	XCTAssertEqualObjects([pagination.goButton title], @"Go");
	XCTAssertEqualObjects([pagination.limitCheckbox title], @"Limit result to:");
	XCTAssertTrue([titles containsObject:@"Go"]);
	XCTAssertTrue([titles containsObject:@"Limit result to:"]);
	XCTAssertFalse([titles containsObject:@"Defer loading of blobs and texts"], @"%@", titles);

	// MySQL's frames, the "Defer loading" row dropped (everything 25 pt lower)
	XCTAssertTrue(NSEqualRects([pagination.goButton frame], NSMakeRect(225, 37, 91, 17)), @"%@", NSStringFromRect([pagination.goButton frame]));
	XCTAssertTrue(NSEqualRects([pagination.pageField frame], NSMakeRect(150, 36, 52, 19)));
	XCTAssertTrue(NSEqualRects([pagination.limitCheckbox frame], NSMakeRect(15, 6, 166, 18)));
	XCTAssertTrue(NSEqualRects([pagination.limitField frame], NSMakeRect(187, 6, 52, 19)));
}

- (void)testGoLoadsTypedPage
{
	SPPostgresContentController *content = [self pagedContentLimited:YES];
	SPPostgresPaginationView *pagination = content.paginationView;
	XCTAssertEqual([pagination.goButton target], pagination);
	XCTAssertTrue([pagination.goButton isEnabled]);

	[pagination.pageField setStringValue:@"3"];
	[pagination.goButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqual(content.currentPage, 3u);
	XCTAssertEqualObjects(content.countText, @"Rows 15 - 21 of 30 from table");
	XCTAssertEqual([content.tableView numberOfRows], 7);

	// An empty field goes to page 1
	[pagination.pageField setStringValue:@""];
	[pagination.goButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testGoToPageClampsOutOfRangePages
{
	SPPostgresContentController *content = [self pagedContentLimited:YES];
	[content goToPage:3];
	XCTAssertEqual(content.currentPage, 3u);

	[content goToPage:0];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqualObjects(content.countText, @"Rows 1 - 7 of 30 from table");

	[content goToPage:99];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqual(content.currentPage, 5u);
	XCTAssertEqual(content.pageCount, 5u);
	XCTAssertEqualObjects(content.countText, @"Rows 29 - 30 of 30 from table");
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testLimitControlsWriteSharedKeysInInjectedDefaults
{
	SPPostgresContentController *content = [self pagedContentLimited:YES];
	NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
	id savedLimit = [standard objectForKey:SPLimitResults], savedValue = [standard objectForKey:SPLimitResultsValue];
	SPPostgresPaginationView *pagination = content.paginationView;
	NSWindow *window = [self windowHolding:[pagination view]];

	XCTAssertEqual([pagination.limitCheckbox state], NSControlStateValueOn);
	XCTAssertEqualObjects([pagination.limitField stringValue], @"7");
	XCTAssertTrue([pagination.pageField isEnabled]);
	XCTAssertTrue([pagination.limitField isEnabled]);

	// Typing a page size and ending the edit writes it
	XCTAssertTrue([window makeFirstResponder:pagination.limitField]);
	NSText *editor = [pagination.limitField currentEditor];
	[editor selectAll:nil];
	[editor insertText:@"3"];
	XCTAssertTrue([window makeFirstResponder:nil]);
	XCTAssertEqual([self.scratch integerForKey:SPLimitResultsValue], 3);

	// Unchecking writes NO and disables the page and limit controls
	[pagination.limitCheckbox performClick:nil];
	XCTAssertNotNil([self.scratch objectForKey:SPLimitResults]);
	XCTAssertFalse([self.scratch boolForKey:SPLimitResults]);
	XCTAssertFalse([pagination.pageField isEnabled]);
	XCTAssertFalse([pagination.goButton isEnabled]);
	XCTAssertFalse([pagination.limitField isEnabled]);

	[pagination.limitCheckbox performClick:nil];
	XCTAssertTrue([self.scratch boolForKey:SPLimitResults]);
	XCTAssertTrue([pagination.goButton isEnabled]);

	XCTAssertEqualObjects([standard objectForKey:SPLimitResults], savedLimit);
	XCTAssertEqualObjects([standard objectForKey:SPLimitResultsValue], savedValue);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testCountTextUsesLoadedPageSize
{
	SPPostgresContentController *content = [self pagedContentLimited:YES];
	[self.scratch setInteger:3 forKey:SPLimitResultsValue];
	[[content.tableView delegate] tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:content.tableView]];
	XCTAssertEqualObjects(content.countText, @"Rows 1 - 7 of 30 from table", @"the page size the rows were loaded with");

	// Past the first page the first row number shows it too
	[self.scratch setInteger:7 forKey:SPLimitResultsValue];
	[content goToPage:2];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqualObjects(content.countText, @"Rows 8 - 14 of 30 from table");
	[self.scratch setInteger:3 forKey:SPLimitResultsValue];
	[[content.tableView delegate] tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:content.tableView]];
	XCTAssertEqualObjects(content.countText, @"Rows 8 - 14 of 30 from table");

	[content goToPage:1];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertEqualObjects(content.countText, @"Rows 1 - 3 of 30 from table");
	XCTAssertEqual(content.pageCount, 10u);
}

- (void)testPaginationButtonStateFollowsPopover
{
	SPPostgresContentController *content = [self pagedContentLimited:YES];
	[self windowHolding:[content view]];
	[content goToPage:2];
	XCTAssertTrue([content.paginationButton isEnabled]);
	XCTAssertEqual([content.paginationButton target], content);
	XCTAssertEqual([content.paginationButton action], @selector(togglePagination:));
	XCTAssertEqual([content.paginationButton state], NSControlStateValueOff);

	[content togglePagination:content.paginationButton];
	NSPopover *popover = content.paginationPopover;
	XCTAssertNotNil(popover);
	XCTAssertTrue([popover isShown]);
	XCTAssertEqual([popover behavior], NSPopoverBehaviorTransient);
	XCTAssertEqual([popover delegate], (id)content);
	XCTAssertEqual([popover contentViewController], content.paginationView);
	XCTAssertEqual([content.paginationButton state], NSControlStateValueOn);
	XCTAssertEqual([content.paginationButton image], [NSImage imageNamed:@"button_action"]);
	XCTAssertEqual(content.paginationView.page, 2u);
	XCTAssertEqual(content.paginationView.maxPage, 5u);
	XCTAssertEqualObjects([content.paginationView.pageField stringValue], @"2");

	[content togglePagination:content.paginationButton];
	XCTAssertTrue([self spinUntil:^BOOL{ return ![popover isShown]; } timeout:5]);
	XCTAssertEqual([content.paginationButton state], NSControlStateValueOff);
	XCTAssertEqual([content.paginationButton image], [NSImage imageNamed:@"button_pagination"]);

	// Go closes it
	[content togglePagination:content.paginationButton];
	XCTAssertTrue([popover isShown]);
	[content.paginationView.pageField setStringValue:@"4"];
	[content.paginationView.goButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:content.taskRunner timeout:30]);
	XCTAssertTrue([self spinUntil:^BOOL{ return ![popover isShown]; } timeout:5]);
	XCTAssertEqual(content.currentPage, 4u);
	XCTAssertEqual([content.paginationButton state], NSControlStateValueOff);
	XCTAssertEqual([content.paginationButton image], [NSImage imageNamed:@"button_pagination"]);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testPaginationButtonEnabledWithLimitOff
{
	SPPostgresContentController *content = [self pagedContentLimited:NO];
	XCTAssertEqual(content.pageCount, 1u);
	XCTAssertFalse([content.previousPageButton isEnabled]);
	XCTAssertFalse([content.nextPageButton isEnabled]);
	XCTAssertTrue([content.paginationButton isEnabled]);

	// Not without a table
	[content showTable:nil inSchema:nil];
	XCTAssertFalse([content.paginationButton isEnabled]);
}

- (void)testPaginationClosesAndLoadsNothingWhileBusy
{
	[self unpinPrefs:@[SPLimitResults, SPLimitResultsValue]];
	NSUserDefaults *scratch = [self scratchDefaultsWithFilterBarChoiceUnset];
	[scratch setBool:YES forKey:SPLimitResults];
	[scratch setInteger:7 forKey:SPLimitResultsValue];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	SPPostgresTaskRunner *runner = content.taskRunner;
	XCTAssertFalse(runner.isInline, @"the tab's runner");
	content.defaults = scratch;
	[content refresh:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual(content.pageCount, 5u);
	XCTAssertEqual(content.currentPage, 1u);
	[[[content view] window] orderFront:nil]; // the popover shows on a window on screen (tearDown orders it out)

	[content togglePagination:content.paginationButton];
	NSPopover *popover = content.paginationPopover;
	XCTAssertTrue([popover isShown]);
	XCTAssertTrue([content.paginationView.goButton isEnabled]);

	// A task starts on the tab's runner while it is open: it closes
	[SPPostgresTestServers queueSleep:3 onRunner:runner];
	XCTAssertTrue(runner.isBusy);
	XCTAssertTrue([self spinUntil:^BOOL{ return ![popover isShown]; } timeout:2]);
	XCTAssertEqual([content.paginationButton state], NSControlStateValueOff);
	XCTAssertEqual([content.paginationButton image], [NSImage imageNamed:@"button_pagination"]);

	// Still busy: it doesn't open again, and Go's page (goToPage:) queues no load
	XCTAssertTrue(runner.isBusy);
	[content togglePagination:content.paginationButton];
	XCTAssertFalse([popover isShown]);
	[content.paginationView setPage:3];
	[content goToPage:3];
	XCTAssertTrue(runner.isBusy);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual(content.currentPage, 1u, @"no page loaded after the task");
	XCTAssertEqualObjects(content.countText, @"Rows 1 - 7 of 30 from table");

	// Idle: Go works again
	[content goToPage:3];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual(content.currentPage, 3u);
	XCTAssertEqual(self.alerts.count, 0u);
}

@end
