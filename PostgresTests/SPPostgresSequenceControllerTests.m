#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestPrefsGuard.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresSequenceController.h"
#import "../Source/Postgres/SPPostgresSequences.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresStructureController.h"
#import "../Source/Postgres/SPPostgresHistory.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static const NSUInteger SPSequenceTestPort = 55418;

// MySQL's identifiers (the app's constants aren't exported to the test bundle)
static NSString * const SPSequenceTestToolbarStructure = @"SwitchToTableStructureToolbarItemIdentifier";
static NSString * const SPSequenceTestToolbarContent = @"SwitchToTableContentToolbarItemIdentifier";
static NSString * const SPSequenceTestToolbarRelations = @"SwitchToTableRelationsToolbarItemIdentifier";
static NSString * const SPSequenceTestToolbarTriggers = @"SwitchToTableTriggersToolbarItemIdentifier";
static NSString * const SPSequenceTestToolbarInfo = @"SwitchToTableInfoToolbarItemIdentifier";
static NSString * const SPSequenceTestToolbarQuery = @"SwitchToRunQueryToolbarItemIdentifier";

@interface SPPostgresDocument (SPPostgresSequenceControllerTests)
- (IBAction)backForwardInHistory:(id)sender;
- (BOOL)parentTabShouldClose;
- (BOOL)sidebarShouldChangeSelection:(SPPostgresSidebarController *)sidebar;
- (void)sidebar:(SPPostgresSidebarController *)sidebar addSequenceInSchema:(NSString *)schema;
- (void)sidebar:(SPPostgresSidebarController *)sidebar deleteSequenceNamed:(NSString *)sequence;
- (void)_renameTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName;
@end

@interface SPWindowController (SPPostgresSequenceControllerTests)
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

/// Every -showPane: and Structure -showTable:inSchema: call while recording (see -recordPaneChanges).
static NSMutableArray *SPSequenceTestPaneLog = nil;

@implementation SPPostgresDocument (SPSequenceTestRecording)
- (void)sp_seqtest_showPane:(NSString *)pane
{
	[SPSequenceTestPaneLog addObject:[@"showPane:" stringByAppendingString:pane ?: @"nil"]];
	[self sp_seqtest_showPane:pane]; // the original (exchanged)
}
@end

@implementation SPPostgresStructureController (SPSequenceTestRecording)
- (void)sp_seqtest_showTable:(NSString *)table inSchema:(NSString *)schema
{
	[SPSequenceTestPaneLog addObject:[@"structure:" stringByAppendingString:table ?: @"nil"]];
	[self sp_seqtest_showTable:table inSchema:schema];
}
@end

/// The SEQUENCES section and the Sequence pane of a Postgres tab hosted in a window (port 55418).
@interface SPPostgresSequenceControllerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<NSAlert *> *confirmations;
@property (assign) BOOL confirmAnswer;
@end

@implementation SPPostgresSequenceControllerTests

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
	[SPPostgresTestServers loadStructureFixtureOnPort:SPSequenceTestPort];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 sequences";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPSequenceTestPort;
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
	NSMutableArray *confirmations = [NSMutableArray array];
	self.alerts = alerts;
	self.confirmations = confirmations;
	self.confirmAnswer = YES;
	__weak SPPostgresSequenceControllerTests *weakSelf = self;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	self.document.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) {
		[confirmations addObject:alert];
		completion(weakSelf.confirmAnswer);
	};
	[self.controller addTabDocument:self.document atIndex:0 select:YES];

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPSequenceTestPort];
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[self.other execute:@"ROLLBACK"];
	[self.other disconnect];
	self.other = nil;
	self.alerts = nil;
	self.confirmations = nil;
	[SPPostgresTestServers dropStructureFixtureOnPort:SPSequenceTestPort];
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresSequenceController *)pane
{
	return self.document.sequenceController;
}

- (NSWindow *)window
{
	return [self.controller window];
}

- (void)showSchema
{
	if (![self.document.sidebar.selectedSchema isEqualToString:@"structure_test"]) [self.document.sidebar reloadSchema:@"structure_test"];
}

/// Selects a sequence of structure_test as a click would (asking the tab first).
- (void)selectSequence:(NSString *)name
{
	[self showSchema];
	XCTAssertTrue([self.document sidebarShouldChangeSelection:self.document.sidebar]);
	XCTAssertTrue([self.document.sidebar selectSequenceNamed:name], @"%@", name);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.pane.sequenceName, name);
}

/// Selects a table of structure_test as a click would: NO when the tab refused to move.
- (BOOL)clickTable:(NSString *)name
{
	[self showSchema];
	if (![self.document sidebarShouldChangeSelection:self.document.sidebar]) return NO;
	XCTAssertTrue([self.document.sidebar selectTableNamed:name], @"%@", name);
	return YES;
}

- (id)serverValue:(NSString *)sql
{
	PGPostgresResult *result = [self.other execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, [[self.other lastError] errorPrimaryMessage]);
	return [[result rowAsArray] firstObject];
}

- (void)serverRun:(NSString *)sql
{
	XCTAssertNotNil([self.other execute:sql], @"%@: %@", sql, [[self.other lastError] errorPrimaryMessage]);
}

- (NSMenuItem *)menuItem:(SEL)action key:(NSString *)key
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSStringFromSelector(action) action:action keyEquivalent:key];
	[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	return item;
}

- (NSToolbarItem *)toolbarItem:(NSString *)identifier
{
	for (NSToolbarItem *item in [[self.document toolbar] items]) {
		if ([[item itemIdentifier] isEqualToString:identifier]) return item;
	}
	XCTFail(@"No toolbar item %@", identifier);
	return nil;
}

- (id)viewWithIdentifier:(NSString *)identifier in:(NSView *)root
{
	NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
	while (queue.count) {
		NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
		if ([v.identifier isEqualToString:identifier]) return v;
		[queue addObjectsFromArray:v.subviews];
	}
	return nil;
}

/// Types into a field as the user would (the delegate hears of the change).
- (void)type:(NSString *)text into:(NSTextField *)field
{
	field.stringValue = text;
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
}

- (void)choose:(NSString *)title in:(NSPopUpButton *)popup
{
	XCTAssertNotNil([popup itemWithTitle:title], @"%@ in %@", title, [popup itemTitles]);
	[popup selectItemWithTitle:title];
	[NSApp sendAction:[popup action] to:[popup target] from:popup];
}

- (void)runQuery:(NSString *)sql
{
	[self.document viewQuery:nil];
	[[self.document.queryController editor] setString:sql];
	[self.document.queryController runAllQueries:nil];
}

- (NSArray *)loggedMessagesContaining:(NSString *)text
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	id console = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSMutableArray *found = [NSMutableArray array];
	for (id message in [[console valueForKey:@"messagesFullSet"] copy]) {
		NSString *logged = [message valueForKey:@"message"];
		if ([logged containsString:text]) [found addObject:logged];
	}
	return found;
}

- (NSMenuItem *)item:(NSString *)title in:(NSMenu *)menu
{
	NSMenuItem *item = [menu itemWithTitle:title];
	XCTAssertNotNil(item, @"%@ in %@", title, [menu.itemArray valueForKey:@"title"]);
	return item;
}

- (void)goBack:(BOOL)back
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"History" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	item.tag = back ? 0 : 1;
	[self.document backForwardInHistory:item];
}

/// Records -showPane: and Structure loads into SPSequenceTestPaneLog until the test ends.
- (void)recordPaneChanges
{
	SPSequenceTestPaneLog = [NSMutableArray array];
	Method showPane = class_getInstanceMethod([SPPostgresDocument class], @selector(showPane:));
	Method recordPane = class_getInstanceMethod([SPPostgresDocument class], @selector(sp_seqtest_showPane:));
	Method showTable = class_getInstanceMethod([SPPostgresStructureController class], @selector(showTable:inSchema:));
	Method recordTable = class_getInstanceMethod([SPPostgresStructureController class], @selector(sp_seqtest_showTable:inSchema:));
	method_exchangeImplementations(showPane, recordPane);
	method_exchangeImplementations(showTable, recordTable);
	[self addTeardownBlock:^{
		method_exchangeImplementations(showPane, recordPane);
		method_exchangeImplementations(showTable, recordTable);
		SPSequenceTestPaneLog = nil;
	}];
}

#pragma mark - Sidebar

- (void)testSidebarShowsSequencesSectionBeforeExtensions
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	XCTAssertEqualObjects([sidebar sectionTitles], (@[@"TABLES", @"VIEWS", @"SEQUENCES", @"EXTENSIONS"]));
	[self showSchema];
	XCTAssertEqualObjects([sidebar itemTitlesInSection:@"SEQUENCES"], (@[@"seq_free", @"seq_used", @"t_id_seq", @"t_ident_seq"]));
	XCTAssertFalse([[sidebar itemTitlesInSection:@"TABLES"] containsObject:@"seq_free"]);

	// The outline's group rows, in order, and the rows under SEQUENCES
	NSOutlineView *outline = [self viewWithIdentifier:@"sidebarOutline" in:[sidebar view]];
	if (!outline) {
		NSMutableArray *queue = [NSMutableArray arrayWithObject:[sidebar view]];
		while (queue.count) {
			NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
			if ([v isKindOfClass:[NSOutlineView class]]) outline = (NSOutlineView *)v;
			[queue addObjectsFromArray:v.subviews];
		}
	}
	XCTAssertNotNil(outline);
	NSMutableArray *groupTitles = [NSMutableArray array];
	NSInteger sequencesRow = -1, firstSequenceRow = -1, tableRow = -1;
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		NSString *title = [item valueForKey:@"title"];
		if ([outline.delegate outlineView:outline isGroupItem:item]) {
			[groupTitles addObject:title];
			if ([title isEqualToString:@"SEQUENCES"]) sequencesRow = row;
		}
		else if ([title isEqualToString:@"seq_free"]) firstSequenceRow = row;
		else if ([title isEqualToString:@"t"]) tableRow = row;
	}
	XCTAssertEqualObjects(groupTitles, (@[@"TABLES", @"VIEWS", @"SEQUENCES", @"EXTENSIONS"]));
	XCTAssertEqual(firstSequenceRow, sequencesRow + 1);

	// The right-click menus: a sequence has Add and Delete; the header and empty space Add only; a table its own
	NSMenu *onSequence = [sidebar menuForRow:firstSequenceRow];
	XCTAssertEqual(onSequence, sidebar.sequenceMenu);
	XCTAssertFalse([self item:@"Add Sequence…" in:onSequence].hidden);
	XCTAssertFalse([self item:@"Delete Sequence…" in:onSequence].hidden);
	NSMenu *onHeader = [sidebar menuForRow:sequencesRow];
	XCTAssertEqual(onHeader, sidebar.sequenceMenu);
	XCTAssertFalse([self item:@"Add Sequence…" in:onHeader].hidden);
	XCTAssertTrue([self item:@"Delete Sequence…" in:onHeader].hidden);
	XCTAssertEqual([sidebar menuForRow:-1], sidebar.sequenceMenu);
	XCTAssertTrue([self item:@"Delete Sequence…" in:sidebar.sequenceMenu].hidden);
	XCTAssertEqual([sidebar menuForRow:tableRow], sidebar.tableMenu);
	XCTAssertEqualObjects([sidebar.tableMenu.itemArray valueForKey:@"title"], (@[@"Duplicate Table…", @"Rename Table…"]));

	// Delete validates on a selected sequence only
	NSMenuItem *delete = [self item:@"Delete Sequence…" in:sidebar.sequenceMenu];
	XCTAssertTrue([sidebar selectTableNamed:@"t"]);
	XCTAssertFalse([(id<NSMenuItemValidation>)delete.target validateMenuItem:delete]);
	XCTAssertTrue([sidebar selectSequenceNamed:@"seq_free"]);
	XCTAssertTrue([(id<NSMenuItemValidation>)delete.target validateMenuItem:delete]);
	NSMenuItem *add = [self item:@"Add Sequence…" in:sidebar.sequenceMenu];
	XCTAssertTrue([(id<NSMenuItemValidation>)add.target validateMenuItem:add]);

	// A selected sequence is not a table; selecting a table clears it
	XCTAssertEqualObjects(sidebar.selectedSequenceName, @"seq_free");
	XCTAssertNil(sidebar.selectedTableName);
	XCTAssertFalse(sidebar.selectionIsTable);
	XCTAssertTrue([sidebar selectTableNamed:@"t"]);
	XCTAssertNil(sidebar.selectedSequenceName);
	XCTAssertFalse([sidebar selectSequenceNamed:@"t"], @"a table is not a sequence");
	XCTAssertFalse([sidebar selectTableNamed:@"seq_free"], @"a sequence is not a table");

	// Another schema: its own sequences
	[sidebar reloadSchema:@"Sales Data"];
	XCTAssertTrue([[sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"Odd \"Seq\""]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - Pane

- (void)testSelectingSequenceShowsPaneAndDisablesTableItems
{
	[self clickTable:@"t"];
	[self.document viewStructure:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);

	[self selectSequence:@"seq_free"];
	SPPostgresSequenceController *pane = self.pane;
	XCTAssertNil(self.document.sidebar.selectedTableName);
	XCTAssertNotNil([[pane view] window], @"in the window");
	XCTAssertTrue([[self.document windowTitleString] hasSuffix:@"/structure_test.seq_free"], @"%@", [self.document windowTitleString]);

	// The fields
	XCTAssertEqualObjects(pane.nameField.stringValue, @"seq_free");
	XCTAssertEqualObjects(pane.typePopup.titleOfSelectedItem, @"bigint");
	XCTAssertEqualObjects(pane.typePopup.itemTitles, (@[@"smallint", @"integer", @"bigint"]));
	XCTAssertEqualObjects(pane.startField.stringValue, @"100");
	XCTAssertEqualObjects(pane.incrementField.stringValue, @"5");
	XCTAssertEqualObjects(pane.minValueField.stringValue, @"1");
	XCTAssertEqualObjects(pane.maxValueField.stringValue, @"9223372036854775807");
	XCTAssertEqualObjects(pane.cacheField.stringValue, @"1");
	XCTAssertEqual(pane.cycleSwitch.state, NSControlStateValueOff);
	XCTAssertEqualObjects(pane.ownedByPopup.titleOfSelectedItem, @"None");
	XCTAssertEqualObjects(pane.ownedByPopup.itemTitles.firstObject, @"None");
	XCTAssertTrue([pane.ownedByPopup.itemTitles containsObject:@"structure_test.used_t.n"]);
	XCTAssertFalse([pane.ownedByPopup.itemTitles containsObject:@"structure_test.t.code"], @"integer columns only");
	XCTAssertEqualObjects(pane.commentField.stringValue, @"free");
	XCTAssertEqualObjects(pane.ownerField.stringValue, @"pgkit_test");
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"100 (next call returns this)");
	XCTAssertEqualObjects(pane.identityNoteField.stringValue, @"");
	XCTAssertTrue(pane.nameField.isEditable);
	XCTAssertTrue(pane.ownedByPopup.isEnabled);
	XCTAssertFalse(pane.hasPendingEdits);

	// Integers only, over the whole bigint range and negatives
	NSFormatter *formatter = pane.startField.formatter;
	XCTAssertNotNil(formatter);
	for (NSTextField *field in @[pane.startField, pane.incrementField, pane.minValueField, pane.maxValueField, pane.cacheField]) XCTAssertNotNil(field.formatter);
	id value = nil;
	XCTAssertTrue([formatter getObjectValue:&value forString:@"-9223372036854775808" errorDescription:NULL]);
	XCTAssertEqual([value longLongValue], LLONG_MIN);
	XCTAssertTrue([formatter getObjectValue:&value forString:@"9223372036854775807" errorDescription:NULL]);
	XCTAssertEqual([value longLongValue], LLONG_MAX);
	XCTAssertEqualObjects([formatter stringForObjectValue:@(LLONG_MAX)], @"9223372036854775807");
	XCTAssertFalse([formatter getObjectValue:&value forString:@"9223372036854775808" errorDescription:NULL]);
	XCTAssertFalse([formatter getObjectValue:&value forString:@"1.5" errorDescription:NULL]);
	XCTAssertFalse([formatter getObjectValue:&value forString:@"abc" errorDescription:NULL]);

	// Only Structure (which is the Sequence pane here), Query and the document's own items are enabled
	for (NSString *identifier in @[SPSequenceTestToolbarContent, SPSequenceTestToolbarRelations, SPSequenceTestToolbarTriggers, SPSequenceTestToolbarInfo]) {
		XCTAssertFalse([self.document validateToolbarItem:[self toolbarItem:identifier]], @"%@", identifier);
	}
	XCTAssertTrue([self.document validateToolbarItem:[self toolbarItem:SPSequenceTestToolbarStructure]]);
	XCTAssertTrue([self.document validateToolbarItem:[self toolbarItem:SPSequenceTestToolbarQuery]]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPSequenceTestToolbarStructure, @"the Sequence pane highlights Structure");
	for (NSValue *selector in @[[NSValue valueWithPointer:@selector(viewContent:)], [NSValue valueWithPointer:@selector(viewRelations:)],
								[NSValue valueWithPointer:@selector(viewTriggers:)], [NSValue valueWithPointer:@selector(viewStatus:)]]) {
		NSMenuItem *item = [self menuItem:(SEL)[selector pointerValue] key:@""];
		XCTAssertFalse([self.controller validateMenuItem:item], @"%@", item.title);
	}
	XCTAssertTrue([self.controller validateMenuItem:[self menuItem:@selector(viewStructure:) key:@"1"]]);
	XCTAssertTrue([self.controller validateMenuItem:[self menuItem:@selector(viewQuery:) key:@"6"]]);

	// The table panes' actions do nothing without a table (nil selectedTableName everywhere)
	[self.document viewStructure:nil];
	[self.document viewContent:nil];
	[self.document viewRelations:nil];
	[self.document viewTriggers:nil];
	[self.document viewStatus:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	[self.document showPane:SPPostgresPaneContent];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence, @"no table pane while a sequence is selected");
	XCTAssertNil(self.document.contentController.table);

	// Query works; the sequence stays selected
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	[self.document showPane:SPPostgresPaneSequence];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);

	// The current value follows the server when the pane reads again
	[self serverRun:@"SELECT nextval('structure_test.seq_free')"];
	[pane revert:nil];
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"100");

	// A serial's sequence: owned by its column
	[self selectSequence:@"t_id_seq"];
	XCTAssertEqualObjects(pane.ownedByPopup.titleOfSelectedItem, @"structure_test.t.id");
	XCTAssertEqualObjects(pane.typePopup.titleOfSelectedItem, @"integer");

	// An identity column's: the note, Name, Type and Owned by read-only
	[self selectSequence:@"t_ident_seq"];
	XCTAssertEqualObjects(pane.identityNoteField.stringValue, @"This sequence belongs to identity column t.ident; rename or detach it from the column.");
	XCTAssertFalse(pane.nameField.isEditable);
	XCTAssertFalse(pane.ownedByPopup.isEnabled);
	XCTAssertFalse(pane.typePopup.isEnabled);
	XCTAssertEqualObjects(pane.ownedByPopup.titleOfSelectedItem, @"structure_test.t.ident");
	XCTAssertTrue(pane.incrementField.isEditable);

	// Back to a table: the pane it was in before the sequence (Structure), its items enabled again
	XCTAssertTrue([self clickTable:@"t"]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertNil([[pane view] window]);
	XCTAssertTrue([self.document validateToolbarItem:[self toolbarItem:SPSequenceTestToolbarStructure]]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPSequenceTestToolbarStructure);

	// Nothing selected (the schema reloads) while the sequence pane shows: back to that pane too
	[self selectSequence:@"seq_free"];
	[self.document.sidebar selectTableNamed:nil];
	XCTAssertNil(self.document.sidebar.selectedSequenceName);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertNil(self.pane.sequenceName);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// Ruling R9: only what the user typed is pending. Viewing a sequence (even with a padded comment) and leaving
/// sends no ALTER or COMMENT; a real edit that fails keeps the user there; Escape gives it up.
- (void)testViewingSequenceAndLeavingSendsNothing
{
	[self overridePrefs:@{@"ConsoleEnableLogging": @YES, @"ConsoleEnableInterfaceLogging": @YES, @"ConsoleEnableCustomQueryLogging": @YES, @"ConsoleEnableErrorLogging": @YES}];
	NSString *marker = [NSString stringWithFormat:@"viewed_%u", arc4random()];
	[self serverRun:[NSString stringWithFormat:@"CREATE SEQUENCE structure_test.%@ AS integer", marker]];
	[self serverRun:[NSString stringWithFormat:@"COMMENT ON SEQUENCE structure_test.%@ IS E' padded\\n'", marker]];
	[self.document.sidebar reloadSchema:@"structure_test"];

	[self selectSequence:marker];
	SPPostgresSequenceController *pane = self.pane;
	XCTAssertEqualObjects(pane.commentField.stringValue, @" padded\n");
	XCTAssertTrue([[pane.nameField window] makeFirstResponder:pane.nameField], @"focused, not edited");
	XCTAssertFalse(pane.hasPendingEdits);
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	[self.document showPane:SPPostgresPaneSequence];
	XCTAssertTrue([[pane.commentField window] makeFirstResponder:pane.commentField]);
	XCTAssertTrue([self clickTable:@"t"]);
	XCTAssertTrue([self.document parentTabShouldClose]);
	NSPredicate *changes = [NSPredicate predicateWithFormat:@"SELF CONTAINS 'ALTER' OR SELF CONTAINS 'COMMENT ON' OR SELF CONTAINS 'setval'"];
	XCTAssertEqualObjects([[self loggedMessagesContaining:marker] filteredArrayUsingPredicate:changes], @[], @"nothing was sent");
	NSString *commentSQL = [NSString stringWithFormat:@"SELECT obj_description('structure_test.%@'::regclass, 'pg_class')", marker];
	XCTAssertEqualObjects([self serverValue:commentSQL], @" padded\n");

	// A real edit that fails (increment 0) vetoes leaving, keeps the text; Escape reverts, then leaving works
	[self selectSequence:marker];
	XCTAssertTrue([[pane.incrementField window] makeFirstResponder:pane.incrementField]);
	[self type:@"0" into:pane.incrementField];
	XCTAssertTrue(pane.hasPendingEdits);
	XCTAssertFalse([self clickTable:@"t"], @"vetoed");
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, marker);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([self.alerts.lastObject.informativeText containsString:@"INCREMENT must not be zero"], @"%@", self.alerts.lastObject.informativeText);
	XCTAssertEqualObjects(pane.incrementField.stringValue, @"0");
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence, @"vetoed");
	XCTAssertFalse([self.document parentTabShouldClose]);
	XCTAssertEqual(self.alerts.count, 3u);

	NSText *editor = [pane.incrementField currentEditor];
	if (!editor) {
		XCTAssertTrue([[pane.incrementField window] makeFirstResponder:pane.incrementField]);
		editor = [pane.incrementField currentEditor];
	}
	XCTAssertNotNil(editor);
	[editor doCommandBySelector:@selector(cancelOperation:)];
	XCTAssertFalse(pane.hasPendingEdits);
	XCTAssertEqualObjects(pane.incrementField.stringValue, @"1");
	XCTAssertTrue([self clickTable:@"t"]);
	XCTAssertEqual(self.alerts.count, 3u);

	// A real edit is applied on leaving (and logged once)
	[self selectSequence:marker];
	[self type:@"4" into:pane.incrementField];
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	NSString *incrementSQL = [NSString stringWithFormat:@"SELECT seqincrement::text FROM pg_sequence WHERE seqrelid = 'structure_test.%@'::regclass", marker];
	XCTAssertEqualObjects([self serverValue:incrementSQL], @"4");
	NSPredicate *applied = [NSPredicate predicateWithFormat:@"SELF CONTAINS 'ALTER SEQUENCE' AND SELF CONTAINS 'INCREMENT BY 4'"];
	XCTAssertEqual([[[self loggedMessagesContaining:marker] filteredArrayUsingPredicate:applied] count], 1u, @"%@", [self loggedMessagesContaining:marker]);
}

- (void)testApplyEditsSequence
{
	[self selectSequence:@"seq_free"];
	SPPostgresSequenceController *pane = self.pane;

	// Several fields, then Apply
	[self type:@"7" into:pane.incrementField];
	[self type:@"" into:pane.maxValueField];
	[self type:@"-50" into:pane.minValueField];
	[pane.cycleSwitch performClick:nil];
	[self choose:@"structure_test.used_t.n" in:pane.ownedByPopup];
	[self type:@"edited" into:pane.commentField];
	XCTAssertTrue(pane.hasPendingEdits);
	[pane.applyButton performClick:nil];
	XCTAssertFalse(pane.hasPendingEdits);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	NSArray *row = [[self.other execute:@"SELECT seqincrement::text, seqmin::text, seqmax::text, seqcycle::text FROM pg_sequence WHERE seqrelid = 'structure_test.seq_free'::regclass"] rowAsArray];
	XCTAssertEqualObjects(row, (@[@"7", @"-50", @"9223372036854775807", @"true"]));
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.seq_free'::regclass, 'pg_class')"], @"edited");
	XCTAssertEqualObjects(pane.ownedByPopup.titleOfSelectedItem, @"structure_test.used_t.n");
	XCTAssertEqualObjects(pane.maxValueField.stringValue, @"9223372036854775807", @"read again");

	// The type
	[self choose:@"integer" in:pane.typePopup];
	[pane apply:nil];
	XCTAssertEqualObjects([self serverValue:@"SELECT seqtypid::regtype::text FROM pg_sequence WHERE seqrelid = 'structure_test.seq_free'::regclass"], @"integer");
	XCTAssertEqualObjects(pane.maxValueField.stringValue, @"2147483647");

	// Revert gives an edit up
	[self type:@"99" into:pane.cacheField];
	[pane.revertButton performClick:nil];
	XCTAssertFalse(pane.hasPendingEdits);
	XCTAssertEqualObjects(pane.cacheField.stringValue, @"1");

	// A rename: the sidebar lists and selects the new name, the pane follows it
	[self type:@"  seq renamed \n" into:pane.nameField]; // trimmed
	[pane apply:nil];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq renamed");
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"seq renamed"]);
	XCTAssertFalse([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"seq_free"]);
	XCTAssertEqualObjects(pane.sequenceName, @"seq renamed");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);

	// A failed Apply: the alert, the typed text stays
	[self type:@"0" into:pane.incrementField];
	[pane apply:nil];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(pane.incrementField.stringValue, @"0");
	XCTAssertTrue(pane.hasPendingEdits);
	[pane revert:nil];

	// Set Value…: "next call returns this value"
	[self.controller showWindow:nil];
	[pane.setValueButton performClick:nil];
	NSWindow *sheet = pane.setValueSheet;
	XCTAssertNotNil(sheet);
	XCTAssertEqual([self window].attachedSheet, sheet);
	NSTextField *valueField = [self viewWithIdentifier:@"setValueField" in:sheet.contentView];
	NSButton *nextCall = [self viewWithIdentifier:@"setValueNextCall" in:sheet.contentView];
	NSButton *setButton = [self viewWithIdentifier:@"setValueButton" in:sheet.contentView];
	XCTAssertNotNil(valueField.formatter);
	XCTAssertEqualObjects(nextCall.title, @"Next call returns this value");
	valueField.stringValue = @"77";
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:valueField];
	nextCall.state = NSControlStateValueOn;
	XCTAssertTrue(setButton.isEnabled);
	[setButton performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertEqual(self.alerts.count, 1u, @"%@", self.alerts.lastObject.informativeText);
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"77 (next call returns this)");
	XCTAssertEqualObjects([self serverValue:@"SELECT nextval('structure_test.\"seq renamed\"')::text"], @"77");

	// …and as the last value
	[pane revert:nil];
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"77");
	[pane setValue:nil];
	sheet = pane.setValueSheet;
	valueField = [self viewWithIdentifier:@"setValueField" in:sheet.contentView];
	valueField.stringValue = @"-5";
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:valueField];
	[(NSButton *)[self viewWithIdentifier:@"setValueButton" in:sheet.contentView] performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"-5");

	// Cancel sets nothing
	[pane setValue:nil];
	sheet = pane.setValueSheet;
	[[self window] endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertNil(pane.setValueSheet);
	XCTAssertEqualObjects([self serverValue:@"SELECT last_value::text FROM structure_test.\"seq renamed\""], @"-5");

	// The tab closing while the sheet is up ends it
	[pane setValue:nil];
	XCTAssertNotNil([self window].attachedSheet);
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[self.document parentTabDidClose];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertNil(pane.setValueSheet);
}

#pragma mark - Add and delete

- (void)testAddSequenceSheetCreatesAndSelects
{
	[self.controller showWindow:nil];
	[self clickTable:@"t"];
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSMenu *menu = sidebar.sequenceMenu;
	NSMenuItem *add = [self item:@"Add Sequence…" in:menu];

	// The sheet, prefilled with the defaults; Cancel does nothing
	[menu performActionForItemAtIndex:[menu indexOfItem:add]];
	NSWindow *sheet = [self window].attachedSheet;
	XCTAssertNotNil(sheet);
	NSTextField *name = [self viewWithIdentifier:@"sequenceName" in:sheet.contentView];
	NSPopUpButton *type = [self viewWithIdentifier:@"sequenceType" in:sheet.contentView];
	NSTextField *start = [self viewWithIdentifier:@"sequenceStart" in:sheet.contentView];
	NSTextField *increment = [self viewWithIdentifier:@"sequenceIncrement" in:sheet.contentView];
	NSTextField *minValue = [self viewWithIdentifier:@"sequenceMinValue" in:sheet.contentView];
	NSTextField *maxValue = [self viewWithIdentifier:@"sequenceMaxValue" in:sheet.contentView];
	NSTextField *cache = [self viewWithIdentifier:@"sequenceCache" in:sheet.contentView];
	NSButton *cycle = [self viewWithIdentifier:@"sequenceCycle" in:sheet.contentView];
	NSPopUpButton *ownedBy = [self viewWithIdentifier:@"sequenceOwnedBy" in:sheet.contentView];
	NSTextField *comment = [self viewWithIdentifier:@"sequenceComment" in:sheet.contentView];
	NSButton *addButton = [self viewWithIdentifier:@"sequenceAddButton" in:sheet.contentView];
	XCTAssertEqualObjects(name.stringValue, @"");
	XCTAssertEqualObjects(type.titleOfSelectedItem, @"bigint");
	XCTAssertEqualObjects(start.stringValue, @"1");
	XCTAssertEqualObjects(increment.stringValue, @"1");
	XCTAssertEqualObjects(minValue.stringValue, @"");
	XCTAssertEqualObjects(maxValue.stringValue, @"");
	XCTAssertEqualObjects(cache.stringValue, @"1");
	XCTAssertEqual(cycle.state, NSControlStateValueOff);
	XCTAssertEqualObjects(ownedBy.titleOfSelectedItem, @"None");
	XCTAssertTrue([ownedBy.itemTitles containsObject:@"structure_test.t.id"]);
	XCTAssertEqualObjects(comment.stringValue, @"");
	XCTAssertNotNil(increment.formatter);
	XCTAssertFalse(addButton.isEnabled, @"no name yet");
	[[self window] endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertFalse([[sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"added"]);

	// Add: created with what was typed, listed and selected, in its pane
	[self.document sidebar:sidebar addSequenceInSchema:@"structure_test"];
	sheet = [self window].attachedSheet;
	name = [self viewWithIdentifier:@"sequenceName" in:sheet.contentView];
	increment = [self viewWithIdentifier:@"sequenceIncrement" in:sheet.contentView];
	type = [self viewWithIdentifier:@"sequenceType" in:sheet.contentView];
	ownedBy = [self viewWithIdentifier:@"sequenceOwnedBy" in:sheet.contentView];
	comment = [self viewWithIdentifier:@"sequenceComment" in:sheet.contentView];
	addButton = [self viewWithIdentifier:@"sequenceAddButton" in:sheet.contentView];
	[self type:[@"" stringByPaddingToLength:64 withString:@"z" startingAtIndex:0] into:name];
	XCTAssertFalse(addButton.isEnabled, @"over 63 bytes");
	[self type:@"added" into:name];
	XCTAssertTrue(addButton.isEnabled);
	[self type:@"3" into:increment];
	[type selectItemWithTitle:@"integer"];
	[ownedBy selectItemWithTitle:@"structure_test.used_t.n"];
	comment.stringValue = @"new one";
	[addButton performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [sidebar.selectedSequenceName isEqualToString:@"added"]; } timeout:5], @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.pane.sequenceName, @"added");
	XCTAssertEqualObjects(self.pane.incrementField.stringValue, @"3");
	NSArray *row = [[self.other execute:@"SELECT seqtypid::regtype::text, seqincrement::text, obj_description(seqrelid, 'pg_class') FROM pg_sequence WHERE seqrelid = 'structure_test.added'::regclass"] rowAsArray];
	XCTAssertEqualObjects(row, (@[@"integer", @"3", @"new one"]));
	XCTAssertEqualObjects(self.pane.ownedByPopup.titleOfSelectedItem, @"structure_test.used_t.n");

	// A name that is taken: the server's message, nothing selected changes
	[self.document sidebar:sidebar addSequenceInSchema:@"structure_test"];
	sheet = [self window].attachedSheet;
	[self type:@"seq_free" into:[self viewWithIdentifier:@"sequenceName" in:sheet.contentView]];
	[(NSButton *)[self viewWithIdentifier:@"sequenceAddButton" in:sheet.contentView] performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.alerts.count == 1; } timeout:5]);
	XCTAssertTrue([self.alerts.firstObject.informativeText containsString:@"already exists"], @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects(sidebar.selectedSequenceName, @"added");

	// The tab closing while the sheet is up ends it, and nothing is created
	[self.document sidebar:sidebar addSequenceInSchema:@"structure_test"];
	sheet = [self window].attachedSheet;
	XCTAssertNotNil(sheet);
	[self type:@"never" into:[self viewWithIdentifier:@"sequenceName" in:sheet.contentView]];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[self.document parentTabDidClose];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertEqualObjects([self serverValue:@"SELECT (to_regclass('structure_test.never') IS NULL)::text"], @"true");
}

- (void)testDeleteInUseSequenceShowsColumns
{
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	[self clickTable:@"t"];
	[self selectSequence:@"seq_used"];
	NSMenu *menu = sidebar.sequenceMenu;
	NSMenuItem *delete = [self item:@"Delete Sequence…" in:menu];

	// In use: asked, then refused with the columns, one per line
	[menu performActionForItemAtIndex:[menu indexOfItem:delete]];
	XCTAssertEqual(self.confirmations.count, 1u);
	XCTAssertEqualObjects(self.confirmations.lastObject.messageText, @"Delete sequence \"seq_used\"?");
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(self.alerts.lastObject.messageText, @"\"seq_used\" can't be deleted because these columns use it.");
	XCTAssertEqualObjects(self.alerts.lastObject.informativeText, @"structure_test.used_t.n");
	XCTAssertNotNil([self serverValue:@"SELECT to_regclass('structure_test.seq_used')::text"]);
	XCTAssertEqualObjects(sidebar.selectedSequenceName, @"seq_used");

	// Two columns
	[self serverRun:@"CREATE TABLE structure_test.used_too (m bigint DEFAULT nextval('structure_test.seq_used'))"];
	[self.document sidebar:sidebar deleteSequenceNamed:@"seq_used"];
	XCTAssertEqualObjects(self.alerts.lastObject.informativeText, @"structure_test.used_t.n\nstructure_test.used_too.m");

	// Answered No: nothing happens
	self.confirmAnswer = NO;
	[self selectSequence:@"seq_free"];
	[self.document sidebar:sidebar deleteSequenceNamed:@"seq_free"];
	XCTAssertEqual(self.alerts.count, 2u);
	XCTAssertTrue([[sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"seq_free"]);

	// A free one: dropped, unlisted, the selection gone and the table pane back
	self.confirmAnswer = YES;
	[menu performActionForItemAtIndex:[menu indexOfItem:delete]];
	XCTAssertEqual(self.alerts.count, 2u, @"%@", self.alerts.lastObject.informativeText);
	XCTAssertFalse([[sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"seq_free"]);
	XCTAssertNil(sidebar.selectedSequenceName);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	XCTAssertEqualObjects([self serverValue:@"SELECT (to_regclass('structure_test.seq_free') IS NULL)::text"], @"true");
}

/// A table renamed (from the sidebar's menu) while a sequence is selected: the sequence stays selected, in its pane.
- (void)testRenameTableKeepsSelectedSequence
{
	[self selectSequence:@"seq_free"];
	[self.document _renameTable:@"child" inSchema:@"structure_test" toName:@"child2"];
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"child2"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	XCTAssertNil(self.document.sidebar.selectedTableName);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.pane.sequenceName, @"seq_free");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - History and Query

- (void)testHistoryRestoresSequenceSelection
{
	[self clickTable:@"t"];
	[self.document viewContent:nil];
	[self selectSequence:@"seq_free"];
	NSDictionary *entry = self.document.history.currentEntry;
	XCTAssertEqualObjects(entry[@"pane"], @"sequence");
	XCTAssertEqualObjects(entry[@"table"], @"seq_free");
	XCTAssertEqualObjects(entry[@"schema"], @"structure_test");
	[self selectSequence:@"t_id_seq"];
	XCTAssertTrue([self clickTable:@"child"]);

	[self goBack:YES];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"t_id_seq");
	XCTAssertNil(self.document.sidebar.selectedTableName);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.pane.sequenceName, @"t_id_seq");
	[self goBack:YES];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	XCTAssertEqualObjects(self.pane.sequenceName, @"seq_free");
	[self goBack:YES];
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"t");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	[self goBack:NO];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);

	// An edit is applied before History moves on
	[self type:@"6" into:self.pane.incrementField];
	[self goBack:NO];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"t_id_seq");
	XCTAssertEqualObjects([self serverValue:@"SELECT seqincrement::text FROM pg_sequence WHERE seqrelid = 'structure_test.seq_free'::regclass"], @"6");

	// The Query view with a sequence selected is recorded with it, and comes back to it
	[self.document viewQuery:nil];
	XCTAssertTrue([self clickTable:@"t"]);
	[self goBack:YES];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"t_id_seq");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testQueryCreateSequenceAppearsInSidebar
{
	[self selectSequence:@"seq_free"];
	[self runQuery:@"CREATE SEQUENCE structure_test.from_query"];
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"from_query"], @"%@", [self.document.sidebar itemTitlesInSection:@"SEQUENCES"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free", @"the selection is kept");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);

	// A change made in SQL shows when the pane is next shown
	[self runQuery:@"ALTER SEQUENCE structure_test.seq_free INCREMENT BY 9"];
	XCTAssertTrue([[self.document valueForKey:@"sequenceNeedsReset"] boolValue]);
	[self.document showPane:SPPostgresPaneSequence];
	XCTAssertEqualObjects(self.pane.incrementField.stringValue, @"9");

	// Dropped in SQL: the selection goes, and the pane with it
	[self runQuery:@"DROP SEQUENCE structure_test.seq_free"];
	XCTAssertFalse([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"seq_free"]);
	XCTAssertNil(self.document.sidebar.selectedSequenceName);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testDatabaseSwitchRebuildsSequencePane
{
	[self selectSequence:@"seq_free"];
	SPPostgresSequenceController *old = self.pane;
	PGPostgresConnection *oldConnection = self.document.connection;
	[self.document switchToDatabase:@"postgres"];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.connection != oldConnection && !self.document.isProcessing; } timeout:20]);
	XCTAssertNotEqual(self.pane, old);
	XCTAssertNil([[old view] window]);
	XCTAssertNil(self.document.sidebar.selectedSequenceName);
	XCTAssertNotEqualObjects(self.document.currentPane, SPPostgresPaneSequence);

	[self.document switchToDatabase:@"pgkit_test"];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.document windowTitleString] containsString:@"/pgkit_test"] && !self.document.isProcessing; } timeout:20]);
	[self selectSequence:@"seq_free"];
	XCTAssertEqualObjects(self.pane.incrementField.stringValue, @"5");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - Fix round 1

/// Values past 2^53 show exactly (not through a double), in the fields, Current value and the Set Value prefill.
- (void)testBigintValuesDisplayExactly
{
	[self serverRun:@"CREATE SEQUENCE structure_test.big MINVALUE 9007199254740993 MAXVALUE 9223372036854775806 START 9007199254740993"];
	[self selectSequence:@"big"];
	SPPostgresSequenceController *pane = self.pane;
	XCTAssertEqualObjects(pane.startField.stringValue, @"9007199254740993");
	XCTAssertEqualObjects(pane.minValueField.stringValue, @"9007199254740993");
	XCTAssertEqualObjects(pane.maxValueField.stringValue, @"9223372036854775806");
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"9007199254740993 (next call returns this)");
	NSFormatter *formatter = pane.startField.formatter;
	XCTAssertEqualObjects([formatter stringForObjectValue:@(1234567890123456789LL)], @"1234567890123456789");
	XCTAssertEqualObjects([formatter editingStringForObjectValue:@(LLONG_MAX - 1)], @"9223372036854775806");
	id value = nil;
	XCTAssertTrue([formatter getObjectValue:&value forString:@"9007199254740993" errorDescription:NULL]);
	XCTAssertEqual([value longLongValue], 9007199254740993LL);

	// The Set Value prefill: the pending value, then the last value
	[self.controller showWindow:nil];
	[pane setValue:nil];
	NSTextField *field = [self viewWithIdentifier:@"setValueField" in:pane.setValueSheet.contentView];
	XCTAssertEqualObjects(field.stringValue, @"9007199254740993");
	[[self window] endSheet:pane.setValueSheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);

	[self serverRun:@"SELECT setval('structure_test.big', 9223372036854775806)"];
	[pane revert:nil];
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"9223372036854775806");
	[pane setValue:nil];
	field = [self viewWithIdentifier:@"setValueField" in:pane.setValueSheet.contentView];
	XCTAssertEqualObjects(field.stringValue, @"9223372036854775806");
	NSButton *set = [self viewWithIdentifier:@"setValueButton" in:pane.setValueSheet.contentView];
	[set performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);
	XCTAssertEqualObjects([self serverValue:@"SELECT last_value::text FROM structure_test.big"], @"9223372036854775806", @"set exactly what was shown");

	// An edit elsewhere leaves the big values exact on the server
	[self type:@"3" into:pane.cacheField];
	[pane apply:nil];
	XCTAssertEqualObjects([self serverValue:@"SELECT seqmin::text || ' ' || seqstart::text FROM pg_sequence WHERE seqrelid = 'structure_test.big'::regclass"], @"9007199254740993 9007199254740993");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// After setval(…, false) the pane says what the next call returns, and Set Value offers it.
- (void)testPendingValueShownAfterSetValueNextCall
{
	[self serverRun:@"CREATE SEQUENCE structure_test.fresh"];
	[self selectSequence:@"fresh"];
	SPPostgresSequenceController *pane = self.pane;
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"1 (next call returns this)");
	XCTAssertNil(pane.sequence.lastValue);
	XCTAssertEqualObjects(pane.sequence.pendingValue, @1);

	[self serverRun:@"SELECT setval('structure_test.fresh', 40, false)"];
	[pane revert:nil];
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"40 (next call returns this)");
	[self.controller showWindow:nil];
	[pane setValue:nil];
	NSWindow *sheet = pane.setValueSheet;
	NSTextField *field = [self viewWithIdentifier:@"setValueField" in:sheet.contentView];
	NSButton *set = [self viewWithIdentifier:@"setValueButton" in:sheet.contentView];
	XCTAssertEqualObjects(field.stringValue, @"40");
	XCTAssertTrue(set.isEnabled);

	// Set is revalidated as the value is typed
	field.stringValue = @"";
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
	XCTAssertFalse(set.isEnabled, @"no value");
	field.stringValue = @"12a";
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
	XCTAssertFalse(set.isEnabled, @"not a number");
	field.stringValue = @"12";
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
	XCTAssertTrue(set.isEnabled);
	[[self window] endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self window].attachedSheet == nil; } timeout:5]);

	[self serverRun:@"SELECT nextval('structure_test.fresh')"];
	[pane revert:nil];
	XCTAssertEqualObjects(pane.currentValueField.stringValue, @"40");
	XCTAssertNil(pane.sequence.pendingValue);
}

/// ⌘1 (and the Structure toolbar item) bring the Sequence pane back from Query while a sequence is selected.
- (void)testStructureItemReturnsToSequencePaneFromQuery
{
	[self selectSequence:@"seq_free"];
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPSequenceTestToolbarQuery);

	NSMenuItem *structureItem = [self menuItem:@selector(viewStructure:) key:@"1"];
	XCTAssertTrue([self.controller validateMenuItem:structureItem]);
	[self.controller performSelector:@selector(viewStructure:) withObject:structureItem];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertNotNil([[self.pane view] window]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPSequenceTestToolbarStructure);

	[self.document viewQuery:nil];
	NSToolbarItem *toolbarItem = [self toolbarItem:SPSequenceTestToolbarStructure];
	XCTAssertTrue([self.document validateToolbarItem:toolbarItem]);
	[NSApp sendAction:toolbarItem.action to:toolbarItem.target from:toolbarItem];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// A rename in the pane, and Add Sequence, go from one sequence to the other: no other pane shows on the way.
- (void)testRenameAndAddDoNotFlashAnotherPane
{
	[self clickTable:@"t"];
	[self.document viewStructure:nil];
	[self selectSequence:@"seq_free"];
	SPPostgresSequenceController *pane = self.pane;
	[self recordPaneChanges];

	[self type:@"seq_free2" into:pane.nameField];
	[pane apply:nil];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free2");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(pane.sequenceName, @"seq_free2");
	XCTAssertEqualObjects(SPSequenceTestPaneLog, @[], @"no pane change, no Structure load");

	[self.controller showWindow:nil];
	[self.document sidebar:self.document.sidebar addSequenceInSchema:@"structure_test"];
	NSWindow *sheet = [self window].attachedSheet;
	XCTAssertNotNil(sheet);
	[self type:@"added_quietly" into:[self viewWithIdentifier:@"sequenceName" in:sheet.contentView]];
	[(NSButton *)[self viewWithIdentifier:@"sequenceAddButton" in:sheet.contentView] performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self.document.sidebar.selectedSequenceName isEqualToString:@"added_quietly"]; } timeout:5], @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(pane.sequenceName, @"added_quietly");
	XCTAssertEqualObjects(SPSequenceTestPaneLog, @[], @"no pane change, no Structure load");

	// The pane before the sequences is still where a table goes back to
	XCTAssertTrue([self clickTable:@"t"]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// History goes back to a sequence of another database: the switch, then the sequence and its pane.
- (void)testHistoryRestoresSequenceAcrossDatabaseSwitch
{
	[self selectSequence:@"seq_free"];
	PGPostgresConnection *oldConnection = self.document.connection;
	[self.document switchToDatabase:@"postgres"];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.connection != oldConnection && !self.document.isProcessing; } timeout:20]);
	XCTAssertNil(self.document.sidebar.selectedSequenceName);

	PGPostgresConnection *postgresConnection = self.document.connection;
	[self goBack:YES];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.connection != postgresConnection && !self.document.isProcessing; } timeout:20]);
	XCTAssertTrue([[self.document windowTitleString] containsString:@"/pgkit_test/structure_test.seq_free"], @"%@", [self.document windowTitleString]);
	XCTAssertEqualObjects(self.document.sidebar.selectedSchema, @"structure_test");
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.pane.sequenceName, @"seq_free");
	XCTAssertEqualObjects(self.pane.incrementField.stringValue, @"5");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - Final fix wave

/// The sidebar's outline view, its window shown and the outline the first responder (as for a user's click or key).
- (NSOutlineView *)liveOutline
{
	[self.controller showWindow:nil];
	NSOutlineView *outline = [self.document.sidebar valueForKey:@"outlineView"];
	XCTAssertNotNil(outline);
	XCTAssertNotNil(outline.window);
	[outline.window makeFirstResponder:outline];
	return outline;
}

- (NSInteger)rowOfSequence:(NSString *)name in:(NSOutlineView *)outline
{
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		if ([[item valueForKey:@"title"] isEqualToString:name] && ![outline.delegate outlineView:outline isGroupItem:item]) return row;
	}
	XCTFail(@"no row %@", name);
	return -1;
}

/**
 * A mouse click on the row, as NSOutlineView handles one: the row is taken from the click's point first, then the
 * delegate is asked (selectionShouldChangeInOutlineView:), then that row is selected. (The test host app is not
 * active, so AppKit's own mouse tracking ignores a synthesized click; the down-arrow test drives AppKit's key path.)
 */
- (void)clickRow:(NSInteger)row in:(NSOutlineView *)outline
{
	NSRect rect = [outline rectOfRow:row];
	NSInteger clicked = [outline rowAtPoint:NSMakePoint(NSMidX(rect), NSMidY(rect))];
	XCTAssertEqual(clicked, row);
	if (![(id<NSOutlineViewDelegate>)outline.delegate selectionShouldChangeInOutlineView:outline]) return;
	[outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)clicked] byExtendingSelection:NO];
}

/// The down arrow key, through NSOutlineView's own key handling.
- (void)pressDownArrowIn:(NSOutlineView *)outline
{
	NSString *arrow = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
	NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:outline.window.windowNumber context:nil characters:arrow charactersIgnoringModifiers:arrow isARepeat:NO keyCode:125];
	[outline keyDown:key];
}

- (NSUInteger)historyCount
{
	return [[self.document.history valueForKey:@"entries"] count];
}

/// Leaving a sequence with a rename not applied yet: the rename is applied, and the row the user clicked is the one
/// selected (the sidebar isn't reloaded under the outline's feet while it changes the selection).
- (void)testUnappliedRenameThenClickSelectsClickedSequence
{
	[self selectSequence:@"seq_free"];
	NSOutlineView *outline = [self liveOutline];
	[self type:@"zz_seq" into:self.pane.nameField];
	XCTAssertTrue(self.pane.hasPendingEdits);

	[self clickRow:[self rowOfSequence:@"seq_used" in:outline] in:outline];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_used");
	XCTAssertEqualObjects([[outline itemAtRow:outline.selectedRow] valueForKey:@"title"], @"seq_used");
	XCTAssertEqualObjects(self.pane.sequenceName, @"seq_used");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects([self.document.sidebar itemTitlesInSection:@"SEQUENCES"], (@[@"seq_used", @"t_id_seq", @"t_ident_seq", @"zz_seq"]));
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*)::text FROM pg_class WHERE oid = to_regclass('structure_test.zz_seq')"], @"1");

	// History: the renamed sequence under its new name, then the one clicked
	XCTAssertEqualObjects(self.document.history.currentEntry[@"table"], @"seq_used");
	[self goBack:YES];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"zz_seq");
	XCTAssertEqualObjects(self.pane.sequenceName, @"zz_seq");
}

/// The same with the down arrow key.
- (void)testUnappliedRenameThenDownArrowSelectsNextSequence
{
	[self selectSequence:@"seq_free"];
	NSOutlineView *outline = [self liveOutline];
	[self type:@"zz_seq" into:self.pane.nameField];

	[self pressDownArrowIn:outline];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_used");
	XCTAssertEqualObjects([[outline itemAtRow:outline.selectedRow] valueForKey:@"title"], @"seq_used");
	XCTAssertEqualObjects(self.pane.sequenceName, @"seq_used");
	XCTAssertEqualObjects([self.document.sidebar itemTitlesInSection:@"SEQUENCES"], (@[@"seq_used", @"t_id_seq", @"t_ident_seq", @"zz_seq"]));
}

/// A serial column added (or dropped) in Structure lists (or unlists) its sequence, the table and pane staying put
/// and History unchanged.
- (void)testSerialColumnAddAndDropUpdatesSequences
{
	XCTAssertTrue([self clickTable:@"t"]);
	[self.document viewStructure:nil];
	SPPostgresStructureController *structure = self.document.structureController;
	NSTableView *columns = structure.columnsView;
	NSDictionary *entry = self.document.history.currentEntry;
	NSUInteger entries = [self historyCount];
	[self recordPaneChanges];

	[structure addColumn:nil];
	[[columns currentEditor] setString:@"counter"];
	[[columns window] makeFirstResponder:columns];
	NSInteger draft = [columns numberOfRows] - 1;
	id<NSTableViewDataSource> source = (id<NSTableViewDataSource>)columns.dataSource;
	[source tableView:columns setObjectValue:@"integer" forTableColumn:[columns tableColumnWithIdentifier:@"type"] row:draft];
	[source tableView:columns setObjectValue:@1 forTableColumn:[columns tableColumnWithIdentifier:@"auto"] row:draft]; // serial
	XCTAssertTrue([structure commitPendingEdits]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"t_counter_seq"], @"%@", [self.document.sidebar itemTitlesInSection:@"SEQUENCES"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"t");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertEqualObjects(self.document.history.currentEntry, entry);
	XCTAssertEqual([self historyCount], entries);

	// Dropped: its owned sequence goes with it, and from the list
	NSInteger row = -1;
	for (NSInteger r = 0; r < columns.numberOfRows; r++) {
		if ([[source tableView:columns objectValueForTableColumn:[columns tableColumnWithIdentifier:@"name"] row:r] isEqual:@"counter"]) row = r;
	}
	XCTAssertGreaterThanOrEqual(row, 0);
	[columns selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	[structure removeColumn:nil];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects([self serverValue:@"SELECT (to_regclass('structure_test.t_counter_seq') IS NULL)::text"], @"true");
	XCTAssertFalse([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"t_counter_seq"], @"%@", [self.document.sidebar itemTitlesInSection:@"SEQUENCES"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"t");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertEqualObjects(self.document.history.currentEntry, entry);
	XCTAssertEqual([self historyCount], entries);
	XCTAssertEqualObjects(SPSequenceTestPaneLog, @[], @"no pane change, no Structure reload from the sidebar");
}

/// Renaming a table while a sequence is selected: no other pane on the way, no History entry.
- (void)testRenameTableWithSequenceSelectedDoesNotFlashOrRecord
{
	[self selectSequence:@"seq_free"];
	NSDictionary *entry = self.document.history.currentEntry;
	NSUInteger entries = [self historyCount];
	[self recordPaneChanges];

	[self.document _renameTable:@"child" inSchema:@"structure_test" toName:@"child2"];
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"child2"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_free");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(SPSequenceTestPaneLog, @[], @"no pane change");
	XCTAssertEqualObjects(self.document.history.currentEntry, entry);
	XCTAssertEqual([self historyCount], entries);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// A rename typed but not applied, then Back: the rename is applied, and History goes to the place before the sequence.
- (void)testPendingRenameThenHistoryBack
{
	XCTAssertTrue([self clickTable:@"t"]);
	[self.document viewContent:nil];
	[self selectSequence:@"seq_free"];
	[self type:@"seq_back" into:self.pane.nameField];

	[self goBack:YES];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	XCTAssertEqualObjects([self serverValue:@"SELECT to_regclass('structure_test.seq_back')::text"], @"structure_test.seq_back");
	XCTAssertEqualObjects([self serverValue:@"SELECT (to_regclass('structure_test.seq_free') IS NULL)::text"], @"true");
	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"SEQUENCES"] containsObject:@"seq_back"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"t");
	XCTAssertNil(self.document.sidebar.selectedSequenceName);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);

	// Forward: the sequence, under its new name
	[self goBack:NO];
	XCTAssertEqualObjects(self.document.sidebar.selectedSequenceName, @"seq_back");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneSequence);
	XCTAssertEqualObjects(self.pane.sequenceName, @"seq_back");
	XCTAssertFalse(self.document.history.canGoForward);
}

@end
