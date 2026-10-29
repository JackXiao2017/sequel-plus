#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestPrefsGuard.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresStructureController.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresConstraintSheet.h"
#import "../Source/Postgres/SPPostgresTableStructure.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresErrors.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

static const NSUInteger SPStructureTestPort = 55418;

// MySQL's identifiers (the app's constants aren't exported to the test bundle)
static NSString * const SPStructureTestToolbarStructure = @"SwitchToTableStructureToolbarItemIdentifier";
static NSString * const SPStructureTestToolbarContent = @"SwitchToTableContentToolbarItemIdentifier";
static NSString * const SPStructureTestToolbarRelations = @"SwitchToTableRelationsToolbarItemIdentifier";
static NSString * const SPStructureTestToolbarTriggers = @"SwitchToTableTriggersToolbarItemIdentifier";
static NSString * const SPStructureTestToolbarInfo = @"SwitchToTableInfoToolbarItemIdentifier";
static NSString * const SPStructureTestToolbarQuery = @"SwitchToRunQueryToolbarItemIdentifier";

/// What Task 1's USING test answers with: the digits of qty.
static NSString * const SPStructureTestUsing = @"nullif(regexp_replace(\"qty\", '\\D', '', 'g'), '')::integer";

@interface NSObject (SPPostgresStructureControllerTestsDelegate)
- (BOOL)cancelRowEditing;
@end

@interface SPPostgresDocument (SPPostgresStructureControllerTests)
- (BOOL)parentTabShouldClose;
- (IBAction)backForwardInHistory:(id)sender;
@end

@interface SPWindowController (SPPostgresStructureControllerTests)
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

@interface SPPostgresStructureControllerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<NSAlert *> *confirmations;
@property (assign) BOOL confirmAnswer;
@end

@implementation SPPostgresStructureControllerTests

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
	[SPPostgresTestServers loadStructureFixtureOnPort:SPStructureTestPort];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 structure";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPStructureTestPort;
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
	__weak SPPostgresStructureControllerTests *weakSelf = self;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	self.document.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) {
		[confirmations addObject:alert];
		completion(weakSelf.confirmAnswer);
	};
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	// The first loads run on the tab's runner
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPStructureTestPort];
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
	[self.other disconnect];
	self.other = nil;
	self.alerts = nil;
	self.confirmations = nil;
	[SPPostgresTestServers dropStructureFixtureOnPort:SPStructureTestPort];
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresStructureController *)structure
{
	return self.document.structureController;
}

/// Selects structure_test.<table> in the sidebar and shows the Structure pane.
- (void)showStructureOf:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"structure_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.document viewStructure:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertEqualObjects(self.structure.table, table);
}

- (NSTableColumn *)column:(NSString *)identifier of:(NSTableView *)view
{
	NSTableColumn *column = [view tableColumnWithIdentifier:identifier];
	XCTAssertNotNil(column, @"%@", identifier);
	return column;
}

- (id)valueIn:(NSTableView *)view row:(NSInteger)row column:(NSString *)identifier
{
	return [[view dataSource] tableView:view objectValueForTableColumn:[self column:identifier of:view] row:row];
}

- (void)setValue:(id)value in:(NSTableView *)view row:(NSInteger)row column:(NSString *)identifier
{
	[(id<NSTableViewDataSource>)[view dataSource] tableView:view setObjectValue:value forTableColumn:[self column:identifier of:view] row:row];
}

- (BOOL)canEdit:(NSTableView *)view row:(NSInteger)row column:(NSString *)identifier
{
	return [(id<NSTableViewDelegate>)[view delegate] tableView:view shouldEditTableColumn:[self column:identifier of:view] row:row];
}

- (NSArray *)valuesIn:(NSTableView *)view column:(NSString *)identifier
{
	NSMutableArray *values = [NSMutableArray array];
	for (NSInteger row = 0; row < [view numberOfRows]; row++) [values addObject:[self valueIn:view row:row column:identifier] ?: [NSNull null]];
	return values;
}

- (NSInteger)rowNamed:(NSString *)name in:(NSTableView *)view
{
	NSInteger row = (NSInteger)[[self valuesIn:view column:@"name"] indexOfObject:name];
	XCTAssertNotEqual(row, (NSInteger)NSNotFound, @"%@", name);
	return row;
}

- (void)selectRow:(NSInteger)row in:(NSTableView *)view
{
	[view selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
}

- (id)serverValue:(NSString *)sql
{
	PGPostgresResult *result = [self.other execute:sql];
	XCTAssertNotNil(result, @"%@", [[self.other lastError] errorPrimaryMessage]);
	return [[result rowAsArray] firstObject];
}

- (NSString *)serverTypeOf:(NSString *)column
{
	return [self serverValue:[NSString stringWithFormat:@"SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'structure_test.t'::regclass AND attname = '%@' AND NOT attisdropped", column]];
}

- (NSToolbarItem *)toolbarItem:(NSString *)identifier
{
	for (NSToolbarItem *item in [[self.document toolbar] items]) {
		if ([[item itemIdentifier] isEqualToString:identifier]) return item;
	}
	XCTFail(@"No toolbar item %@", identifier);
	return nil;
}

- (NSMenuItem *)menuItem:(SEL)action key:(NSString *)key
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSStringFromSelector(action) action:action keyEquivalent:key];
	[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	return item;
}

/// The field editor's text command (Return: insertNewline:, Esc: cancelOperation:) as the grid's delegate gets it.
- (BOOL)sendCommand:(SEL)command toEditorOf:(NSTableView *)view
{
	NSText *editor = [view currentEditor];
	XCTAssertNotNil(editor, @"a cell is being edited");
	return [(id)[view delegate] control:view textView:(NSTextView *)editor doCommandBySelector:command];
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

#pragma mark - Panes

- (void)testViewStructureMenuAndToolbarShowStructurePane
{
	NSMenuItem *structureItem = [self menuItem:@selector(viewStructure:) key:@"1"];

	// Nothing selected: Structure is off
	XCTAssertFalse([self.controller validateMenuItem:structureItem]);
	XCTAssertFalse([self.document validateToolbarItem:[self toolbarItem:SPStructureTestToolbarStructure]]);

	[self.document.sidebar reloadSchema:@"structure_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);

	// ⌘1 validates through the window (which asks the selected Postgres tab), and is forwarded to the tab
	XCTAssertTrue([self.controller validateMenuItem:structureItem]);
	XCTAssertTrue([self.controller respondsToSelector:@selector(viewStructure:)]);
	[self.controller performSelector:@selector(viewStructure:) withObject:structureItem];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, @"structure");
	XCTAssertEqualObjects(self.structure.table, @"t");
	XCTAssertEqualObjects(self.structure.schema, @"structure_test");
	XCTAssertNotNil([self.structure.view superview], @"in the right pane");
	XCTAssertNil([self.document.contentController.tableView window], @"Content is out of the window");
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPStructureTestToolbarStructure);

	// The toolbar item does the same
	NSToolbarItem *structureToolbarItem = [self toolbarItem:SPStructureTestToolbarStructure];
	XCTAssertTrue([self.document validateToolbarItem:structureToolbarItem]);
	XCTAssertEqual([structureToolbarItem target], self.document);
	XCTAssertEqualObjects(NSStringFromSelector([structureToolbarItem action]), @"viewStructure:");
	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneQuery);
	[NSApp sendAction:[structureToolbarItem action] to:[structureToolbarItem target] from:structureToolbarItem];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);

	// Every pane item, and the names
	XCTAssertEqualObjects(SPPostgresPaneStructure, @"structure");
	XCTAssertEqualObjects(SPPostgresPaneContent, @"content");
	XCTAssertEqualObjects(SPPostgresPaneRelations, @"relations");
	XCTAssertEqualObjects(SPPostgresPaneTriggers, @"triggers");
	XCTAssertEqualObjects(SPPostgresPaneInfo, @"info");
	XCTAssertEqualObjects(SPPostgresPaneQuery, @"query");
	NSDictionary *items = @{SPStructureTestToolbarContent: SPPostgresPaneContent, SPStructureTestToolbarRelations: SPPostgresPaneRelations,
							SPStructureTestToolbarTriggers: SPPostgresPaneTriggers, SPStructureTestToolbarInfo: SPPostgresPaneInfo,
							SPStructureTestToolbarQuery: SPPostgresPaneQuery, SPStructureTestToolbarStructure: SPPostgresPaneStructure};
	for (NSString *identifier in items) {
		NSToolbarItem *item = [self toolbarItem:identifier];
		XCTAssertTrue([self.document validateToolbarItem:item], @"%@", identifier);
		[NSApp sendAction:[item action] to:[item target] from:item];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
		XCTAssertEqualObjects(self.document.currentPane, items[identifier], @"%@", identifier);
		XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], identifier);
	}

	// The View menu's items (⌘1–⌘6) on a table
	NSDictionary *menu = @{@"viewStructure:": @"1", @"viewContent:": @"2", @"viewRelations:": @"3", @"viewTriggers:": @"4", @"viewStatus:": @"5", @"viewQuery:": @"6"};
	for (NSString *selector in menu) {
		XCTAssertTrue([self.controller validateMenuItem:[self menuItem:NSSelectorFromString(selector) key:menu[selector]]], @"%@", selector);
	}
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - Columns

- (void)testColumnsGridShowsFixtureColumns
{
	[self showStructureOf:@"t"];
	NSTableView *columns = self.structure.columnsView;

	XCTAssertEqualObjects([[columns tableColumns] valueForKeyPath:@"headerCell.stringValue"], (@[@"Name", @"Type", @"Nullable", @"Default", @"Auto", @"Comment"]));
	XCTAssertEqualObjects([self valuesIn:columns column:@"name"], (@[@"id", @"code", @"qty", @"amount", @"Order", @"a \"q\" b", @"gen", @"ident"]));
	XCTAssertEqualObjects([self valueIn:columns row:0 column:@"type"], @"integer");
	XCTAssertEqualObjects([self valueIn:columns row:3 column:@"type"], @"numeric(10,2)");
	XCTAssertEqualObjects([self valueIn:columns row:0 column:@"auto"], @"serial");
	XCTAssertEqualObjects([self valueIn:columns row:7 column:@"auto"], @"identity");
	XCTAssertEqualObjects([self valueIn:columns row:6 column:@"auto"], @"generated");
	XCTAssertEqualObjects([self valueIn:columns row:1 column:@"auto"], @"");
	XCTAssertEqualObjects([self valueIn:columns row:0 column:@"nullable"], @NO);
	XCTAssertEqualObjects([self valueIn:columns row:1 column:@"nullable"], @YES);
	XCTAssertEqualObjects([self valueIn:columns row:3 column:@"default"], @"0");
	XCTAssertEqualObjects([self valueIn:columns row:1 column:@"default"], @"");
	XCTAssertEqualObjects([self valueIn:columns row:1 column:@"comment"], @"the code");
	XCTAssertEqualObjects([self valueIn:columns row:6 column:@"default"], @"(id * 2)", @"a generated column shows its expression");
	XCTAssertTrue([[[self column:@"nullable" of:columns] dataCell] isKindOfClass:[NSButtonCell class]]);
	XCTAssertTrue([[[self column:@"type" of:columns] dataCell] isKindOfClass:[NSComboBoxCell class]]);
	NSArray *suggestions = [(NSComboBoxCell *)[[self column:@"type" of:columns] dataCell] objectValues];
	XCTAssertEqualObjects(suggestions, (@[@"integer", @"bigint", @"smallint", @"numeric(10,2)", @"real", @"double precision", @"text",
										  @"varchar(255)", @"char(1)", @"boolean", @"date", @"time", @"timestamp", @"timestamptz",
										  @"interval", @"uuid", @"json", @"jsonb", @"bytea", @"inet"]));

	NSTableView *indexes = self.structure.indexesView;
	XCTAssertEqualObjects([[indexes tableColumns] valueForKeyPath:@"headerCell.stringValue"], (@[@"Name", @"Columns", @"Unique", @"Method"]));
	NSInteger pkey = [self rowNamed:@"t_pkey" in:indexes];
	XCTAssertEqualObjects([self valueIn:indexes row:pkey column:@"columns"], @"id");
	XCTAssertEqualObjects([self valueIn:indexes row:pkey column:@"unique"], @YES);
	XCTAssertEqualObjects([self valueIn:indexes row:pkey column:@"method"], @"btree");
	NSInteger pair = [self rowNamed:@"t_qty_amount_idx" in:indexes];
	XCTAssertEqualObjects([self valueIn:indexes row:pair column:@"columns"], @"qty, amount");
	XCTAssertEqualObjects([self valueIn:indexes row:pair column:@"unique"], @NO);

	NSTableView *constraints = self.structure.constraintsView;
	XCTAssertEqualObjects([[constraints tableColumns] valueForKeyPath:@"headerCell.stringValue"], (@[@"Name", @"Type", @"Definition"]));
	NSInteger check = [self rowNamed:@"t_amount_check" in:constraints];
	XCTAssertEqualObjects([self valueIn:constraints row:check column:@"type"], @"CHECK");
	XCTAssertTrue([[self valueIn:constraints row:check column:@"definition"] hasPrefix:@"CHECK"]);
	XCTAssertEqualObjects([self valueIn:constraints row:[self rowNamed:@"t_pkey" in:constraints] column:@"type"], @"PRIMARY KEY");

	// The table is editable; Auto only on a new row
	XCTAssertTrue(self.structure.editable);
	XCTAssertEqualObjects(self.structure.noticeText, @"");
	XCTAssertTrue([self canEdit:columns row:1 column:@"type"]);
	XCTAssertFalse([self canEdit:columns row:1 column:@"auto"]);
	// A generated column's Type and Default are read-only
	XCTAssertFalse([self canEdit:columns row:6 column:@"type"]);
	XCTAssertFalse([self canEdit:columns row:6 column:@"default"]);
	XCTAssertTrue([self canEdit:columns row:6 column:@"name"]);
	XCTAssertFalse([self canEdit:indexes row:pkey column:@"name"], @"the indexes grid is read-only");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testEditingTypeCellAltersColumn
{
	NSMutableArray<NSNumber *> *changes = [NSMutableArray array];
	void (^documentHandler)(BOOL) = self.structure.structureDidChange;
	XCTAssertNotNil(documentHandler, @"the tab listens");
	self.structure.structureDidChange = ^(BOOL columnsChanged) {
		[changes addObject:@(columnsChanged)];
		documentHandler(columnsChanged);
	};

	[self showStructureOf:@"t"];
	NSTableView *columns = self.structure.columnsView;
	NSInteger order = [self rowNamed:@"Order" in:columns];

	[self setValue:@"bigint" in:columns row:order column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverTypeOf:@"Order"], @"bigint");
	XCTAssertEqualObjects([self valueIn:columns row:order column:@"type"], @"bigint", @"reloaded");

	// The other cells, one change each
	// (Order's rows are NULL: amount's aren't)
	NSInteger amount = [self rowNamed:@"amount" in:columns];
	[self setValue:@NO in:columns row:amount column:@"nullable"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT attnotnull::text FROM pg_attribute WHERE attrelid = 'structure_test.t'::regclass AND attname = 'amount'"], @"true");
	XCTAssertEqualObjects([self valueIn:columns row:amount column:@"nullable"], @NO);
	[self setValue:@"42" in:columns row:order column:@"default"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self valueIn:columns row:order column:@"default"], @"42");
	[self setValue:@"the order" in:columns row:order column:@"comment"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT col_description('structure_test.t'::regclass, 5)"], @"the order");
	[self setValue:@"Order No" in:columns row:order column:@"name"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self valueIn:columns row:order column:@"name"], @"Order No");
	XCTAssertEqualObjects([self serverTypeOf:@"Order No"], @"bigint");
	XCTAssertEqualObjects(changes, (@[@YES, @YES, @YES, @NO, @YES]));

	// Unchanged: nothing sent
	[self setValue:@"bigint" in:columns row:order column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(changes.count, 5u);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// The server refuses: its message, and the grid shows what the server has
	[self setValue:@"no_such_function()" in:columns row:order column:@"default"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([self.alerts[0].informativeText containsString:@"no_such_function"], @"%@", self.alerts[0].informativeText);
	XCTAssertEqualObjects([self valueIn:columns row:order column:@"default"], @"42");
	XCTAssertEqual(changes.count, 5u);
}

- (void)testTypeChangeFailureOffersUsing
{
	[self showStructureOf:@"t"];
	NSTableView *columns = self.structure.columnsView;
	NSInteger qty = [self rowNamed:@"qty" in:columns];

	NSMutableArray<NSArray *> *offers = [NSMutableArray array];
	__block void (^pending)(NSString *) = nil;
	self.structure.usingPresenter = ^(NSString *serverMessage, NSString *prefilled, void (^completion)(NSString *)) {
		[offers addObject:@[serverMessage ?: @"", prefilled ?: @""]];
		pending = completion;
	};

	// Cancel: the column keeps its type
	[self setValue:@"integer" in:columns row:qty column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(offers.count, 1u);
	XCTAssertEqualObjects(offers[0][1], @"\"qty\"::integer");
	XCTAssertTrue([offers[0][0] containsString:@"cannot be cast automatically"], @"%@", offers[0][0]);
	pending(nil);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	pending = nil;
	XCTAssertEqualObjects([self serverTypeOf:@"qty"], @"text");
	XCTAssertEqualObjects([self valueIn:columns row:qty column:@"type"], @"text");

	// A USING that fails again is offered again (with what was tried), until one works
	[self setValue:@"integer" in:columns row:qty column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(offers.count, 2u);
	void (^answer)(NSString *) = pending;
	pending = nil;
	answer(@"\"qty\"::integer");
	XCTAssertEqual(offers.count, 3u);
	XCTAssertEqualObjects(offers[2][1], @"\"qty\"::integer");
	XCTAssertTrue([offers[2][0] containsString:@"12a"], @"the server's message: %@", offers[2][0]);
	XCTAssertEqualObjects([self serverTypeOf:@"qty"], @"text");
	answer = pending;
	pending = nil;
	answer(SPStructureTestUsing);
	XCTAssertEqual(offers.count, 3u);
	XCTAssertEqualObjects([self serverTypeOf:@"qty"], @"integer");
	XCTAssertEqualObjects([self valueIn:columns row:qty column:@"type"], @"integer");
	XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(qty::text, ',' ORDER BY id) FROM structure_test.t"], @"5,12");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testDraftRowSavedOnReturnAndDiscardedOnEscape
{
	[self showStructureOf:@"t"];
	SPPostgresStructureController *structure = self.structure;
	NSTableView *columns = structure.columnsView;
	XCTAssertEqual([columns numberOfRows], 8);

	// + appends column_1 (text, nullable), its name being edited
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue(structure.hasDraftColumn);
	XCTAssertEqual([columns numberOfRows], 9);
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"name"], @"column_1");
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"type"], @"text");
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"nullable"], @YES);
	XCTAssertEqual([columns selectedRow], 8);
	XCTAssertEqual([columns editedRow], 8);
	XCTAssertEqual([columns editedColumn], [columns columnWithIdentifier:@"name"]);
	XCTAssertTrue([self canEdit:columns row:8 column:@"auto"], @"Auto is editable on a new row");
	XCTAssertNil([self serverTypeOf:@"column_1"], @"nothing sent yet");

	// Return saves it
	[[columns currentEditor] setString:@"added_col"];
	XCTAssertTrue([self sendCommand:@selector(insertNewline:) toEditorOf:columns]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertEqualObjects([self serverTypeOf:@"added_col"], @"text");
	XCTAssertEqual([columns numberOfRows], 9);
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"name"], @"added_col");

	// Esc discards one
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual([columns numberOfRows], 10);
	XCTAssertTrue([self sendCommand:@selector(cancelOperation:) toEditorOf:columns]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertEqual([columns numberOfRows], 9);
	XCTAssertNil([columns currentEditor]);
	XCTAssertNil([self serverTypeOf:@"column_1"]);

	// The lowest free N
	[self.other execute:@"ALTER TABLE structure_test.t ADD COLUMN column_1 int"];
	[structure refresh:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self valueIn:columns row:10 column:@"name"], @"column_2");

	// A failed save keeps the draft (the alert shows why); fixed, it is saved when the selection leaves it
	[[columns currentEditor] setString:@"typed_col"];
	[[columns window] makeFirstResponder:columns]; // ends the cell edit
	XCTAssertTrue(structure.hasDraftColumn);
	[self setValue:@"no_such_type" in:columns row:10 column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self setValue:@NO in:columns row:10 column:@"nullable"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse([structure commitPendingEdits]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([self.alerts[0].informativeText containsString:@"no_such_type"], @"%@", self.alerts[0].informativeText);
	XCTAssertTrue(structure.hasDraftColumn);
	XCTAssertEqualObjects([self valueIn:columns row:10 column:@"name"], @"typed_col");
	XCTAssertEqualObjects([self valueIn:columns row:10 column:@"nullable"], @NO);

	[self setValue:@"varchar(20)" in:columns row:10 column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self setValue:@"'x'" in:columns row:10 column:@"default"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self setValue:@"a new one" in:columns row:10 column:@"comment"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self selectRow:2 in:columns];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertEqual([columns selectedRow], 2, @"the selection stays on the row that was clicked");
	XCTAssertEqualObjects([self serverTypeOf:@"typed_col"], @"character varying(20)");
	XCTAssertEqualObjects([self serverValue:@"SELECT attnotnull::text FROM pg_attribute WHERE attrelid = 'structure_test.t'::regclass AND attname = 'typed_col'"], @"true");
	XCTAssertEqualObjects([self serverValue:@"SELECT col_description('structure_test.t'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'structure_test.t'::regclass AND attname = 'typed_col'))"], @"a new one");

	// Esc without a cell being edited, and − on a draft, discard it too
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[[columns window] makeFirstResponder:columns];
	XCTAssertTrue([(id)[columns delegate] cancelRowEditing]);
	XCTAssertFalse(structure.hasDraftColumn);
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[[columns window] makeFirstResponder:columns];
	[structure removeColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertEqual(self.confirmations.count, 0u, @"a draft goes without asking");

	// A serial draft (Auto: a popup on the new row)
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[[columns currentEditor] setString:@"counter"];
	[[columns window] makeFirstResponder:columns];
	NSInteger draft = [columns numberOfRows] - 1;
	[self setValue:@"integer" in:columns row:draft column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self setValue:@1 in:columns row:draft column:@"auto"]; // "serial"
	XCTAssertTrue([structure commitPendingEdits]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self valueIn:columns row:draft column:@"auto"], @"serial");
	XCTAssertEqual(self.alerts.count, 1u, @"%@", self.alerts.lastObject.informativeText);
}

- (void)testDeleteColumnWithDependentsShowsList
{
	[self showStructureOf:@"t"];
	NSTableView *columns = self.structure.columnsView;

	[self selectRow:[self rowNamed:@"code" in:columns] in:columns];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.structure removeColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.confirmations.count, 1u);
	XCTAssertEqualObjects(self.confirmations[0].messageText, @"Delete column \"code\"?");
	XCTAssertEqual(self.alerts.count, 1u);
	NSString *list = self.alerts[0].informativeText;
	XCTAssertTrue([list containsString:@"view structure_test.t_view"], @"%@", list);
	XCTAssertTrue([list containsString:@"constraint t_code_key on table structure_test.t"], @"%@", list);
	XCTAssertTrue([list containsString:@"trigger t_touch on table structure_test.t"], @"%@", list);
	XCTAssertEqual([[list componentsSeparatedByString:@"\n"] count], 3u, @"one per line: %@", list);
	XCTAssertTrue([self.alerts[0].messageText containsString:@"depend"], @"%@", self.alerts[0].messageText);
	XCTAssertEqualObjects([self serverTypeOf:@"code"], @"text", @"nothing dropped");

	// Cancel keeps it; confirmed, a column nothing depends on goes
	self.confirmAnswer = NO;
	[self selectRow:[self rowNamed:@"Order" in:columns] in:columns];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.structure removeColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverTypeOf:@"Order"], @"integer");
	self.confirmAnswer = YES;
	[self.structure removeColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertNil([self serverTypeOf:@"Order"]);
	XCTAssertFalse([[self valuesIn:columns column:@"name"] containsObject:@"Order"]);
	XCTAssertEqual(self.alerts.count, 1u);
}

#pragma mark - Indexes and constraints

- (void)testAddIndexAndConstraintViaSheetCompletion
{
	[self showStructureOf:@"t"];
	SPPostgresStructureController *structure = self.structure;

	NSMutableArray *kinds = [NSMutableArray array];
	__block NSArray *offeredColumns = nil;
	__block void (^pending)(SPPostgresConstraintDefinition *) = nil;
	structure.constraintSheetPresenter = ^(NSString *kind, NSArray *columnNames, void (^completion)(SPPostgresConstraintDefinition *)) {
		[kinds addObject:kind];
		offeredColumns = columnNames;
		pending = completion;
	};

	// An index
	[structure addIndex:nil];
	XCTAssertEqualObjects(kinds, (@[@"INDEX"]));
	XCTAssertEqualObjects(offeredColumns, (@[@"id", @"code", @"qty", @"amount", @"Order", @"a \"q\" b", @"gen", @"ident"]));
	SPPostgresIndexDefinition *index = [[SPPostgresIndexDefinition alloc] init];
	index.kind = SPPostgresConstraintSheetIndexKind;
	index.name = @"t_code_qty_idx";
	index.columns = @[@"code", @"qty"];
	index.unique = YES;
	index.method = @"btree";
	pending(index);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	pending = nil;
	NSTableView *indexes = structure.indexesView;
	NSInteger row = [self rowNamed:@"t_code_qty_idx" in:indexes];
	XCTAssertEqualObjects([self valueIn:indexes row:row column:@"columns"], @"code, qty");
	XCTAssertEqualObjects([self valueIn:indexes row:row column:@"unique"], @YES);

	// Cancel adds nothing
	[structure addIndex:nil];
	NSInteger count = [indexes numberOfRows];
	pending(nil);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual([indexes numberOfRows], count);

	// A CHECK constraint
	[structure addConstraint:nil];
	XCTAssertEqual(kinds.count, 3u);
	XCTAssertNotEqualObjects(kinds[2], @"INDEX");
	SPPostgresConstraintDefinition *check = [[SPPostgresConstraintDefinition alloc] init];
	check.kind = @"CHECK";
	check.name = @"t_qty_check";
	check.checkExpression = @"qty <> ''";
	pending(check);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	pending = nil;
	NSTableView *constraints = structure.constraintsView;
	row = [self rowNamed:@"t_qty_check" in:constraints];
	XCTAssertEqualObjects([self valueIn:constraints row:row column:@"type"], @"CHECK");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// A refused one: the server's message
	[structure addConstraint:nil];
	SPPostgresConstraintDefinition *bad = [[SPPostgresConstraintDefinition alloc] init];
	bad.kind = @"CHECK";
	bad.checkExpression = @"qty <> 'a'::no_such_type";
	pending(bad);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 1u);

	// − asks, then drops
	[self selectRow:[self rowNamed:@"t_qty_check" in:constraints] in:constraints];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[structure removeConstraint:nil];
	XCTAssertEqualObjects(self.confirmations.lastObject.messageText, @"Delete constraint \"t_qty_check\"?");
	XCTAssertFalse([[self valuesIn:constraints column:@"name"] containsObject:@"t_qty_check"]);
	[self selectRow:[self rowNamed:@"t_code_qty_idx" in:indexes] in:indexes];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[structure removeIndex:nil];
	XCTAssertEqualObjects(self.confirmations.lastObject.messageText, @"Delete index \"t_code_qty_idx\"?");
	XCTAssertFalse([[self valuesIn:indexes column:@"name"] containsObject:@"t_code_qty_idx"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT to_regclass('structure_test.t_code_qty_idx')::text"], [NSNull null]);
	XCTAssertEqual(self.alerts.count, 1u);
}

/// The real sheet: FK mode lists the catalog's schemas and tables and the chosen table's columns.
- (void)testConstraintSheetForeignKeyModeListsCatalog
{
	[self.controller showWindow:nil];
	NSWindow *window = [self.controller window];
	__block SPPostgresConstraintDefinition *result = nil;
	__block NSUInteger calls = 0;
	[SPPostgresConstraintSheet beginForKind:@"FOREIGN KEY" columns:@[@"id", @"t_id"] schema:@"structure_test" connection:self.document.connection window:window completion:^(SPPostgresConstraintDefinition *definition) {
		result = definition;
		calls++;
	}];
	NSWindow *sheet = window.attachedSheet;
	XCTAssertNotNil(sheet);
	NSPopUpButton *schemas = [self viewWithIdentifier:@"referencedSchema" in:sheet.contentView];
	NSPopUpButton *tables = [self viewWithIdentifier:@"referencedTable" in:sheet.contentView];
	NSTableView *ownColumns = [self viewWithIdentifier:@"constraintColumns" in:sheet.contentView];
	NSTableView *referenced = [self viewWithIdentifier:@"referencedColumns" in:sheet.contentView];
	NSButton *add = [self viewWithIdentifier:@"constraintAddButton" in:sheet.contentView];
	NSView *method = [self viewWithIdentifier:@"indexMethod" in:sheet.contentView];
	XCTAssertTrue(!method || method.isHidden, @"no index options in FK mode");
	XCTAssertTrue([[schemas itemTitles] containsObject:@"structure_test"]);
	XCTAssertEqualObjects([schemas titleOfSelectedItem], @"structure_test");
	XCTAssertEqualObjects([tables itemTitles], (@[@"child", @"t", @"used_t"]));
	XCTAssertFalse([add isEnabled], @"no column chosen yet");

	[tables selectItemWithTitle:@"t"];
	[NSApp sendAction:[tables action] to:[tables target] from:tables];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual([referenced numberOfRows], 8);
	XCTAssertEqualObjects([[referenced dataSource] tableView:referenced objectValueForTableColumn:[referenced tableColumnWithIdentifier:@"name"] row:0], @"id");

	[(id<NSTableViewDataSource>)[ownColumns dataSource] tableView:ownColumns setObjectValue:@YES forTableColumn:[ownColumns tableColumnWithIdentifier:@"use"] row:1];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[(id<NSTableViewDataSource>)[referenced dataSource] tableView:referenced setObjectValue:@YES forTableColumn:[referenced tableColumnWithIdentifier:@"use"] row:0];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([add isEnabled]);
	[add performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self spinUntil:^BOOL{ return calls == 1; } timeout:5]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(result.kind, @"FOREIGN KEY");
	XCTAssertEqualObjects(result.columns, @[@"t_id"]);
	XCTAssertEqualObjects(result.referencedSchema, @"structure_test");
	XCTAssertEqualObjects(result.referencedTable, @"t");
	XCTAssertEqualObjects(result.referencedColumns, @[@"id"]);
	XCTAssertNil(window.attachedSheet);

	// An index sheet, cancelled
	calls = 0;
	result = (id)@"not called";
	[SPPostgresConstraintSheet beginForKind:@"INDEX" columns:@[@"id", @"code"] connection:self.document.connection window:window completion:^(SPPostgresConstraintDefinition *definition) {
		result = definition;
		calls++;
	}];
	sheet = window.attachedSheet;
	XCTAssertNotNil(sheet);
	XCTAssertNotNil([self viewWithIdentifier:@"indexMethod" in:sheet.contentView]);
	XCTAssertNotNil([self viewWithIdentifier:@"indexUnique" in:sheet.contentView]);
	[window endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self spinUntil:^BOOL{ return calls == 1; } timeout:5]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertNil(result);
}

#pragma mark - Views

- (void)testViewSelectedIsReadOnlyAndRelationsDisabled
{
	[self showStructureOf:@"t_view"];
	SPPostgresStructureController *structure = self.structure;
	NSTableView *columns = structure.columnsView;

	XCTAssertEqualObjects([self valuesIn:columns column:@"name"], @[@"code"]);
	XCTAssertFalse(structure.editable);
	XCTAssertEqualObjects(structure.noticeText, @"Views can't be edited here.");
	for (NSString *identifier in @[@"name", @"type", @"nullable", @"default", @"comment"]) {
		XCTAssertFalse([self canEdit:columns row:0 column:identifier], @"%@", identifier);
	}
	XCTAssertFalse([[structure valueForKey:@"addColumnButton"] isEnabled]);
	XCTAssertFalse([[structure valueForKey:@"removeColumnButton"] isEnabled]);
	XCTAssertFalse([[structure valueForKey:@"addIndexButton"] isEnabled]);
	XCTAssertFalse([[structure valueForKey:@"addConstraintButton"] isEnabled]);
	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertEqual(self.alerts.count, 0u);

	// Structure, Content and Table Info for any relation; Relations and Triggers for tables only; Query always
	NSDictionary *expected = @{SPStructureTestToolbarStructure: @YES, SPStructureTestToolbarContent: @YES, SPStructureTestToolbarInfo: @YES,
							   SPStructureTestToolbarRelations: @NO, SPStructureTestToolbarTriggers: @NO, SPStructureTestToolbarQuery: @YES};
	for (NSString *identifier in expected) {
		XCTAssertEqual([self.document validateToolbarItem:[self toolbarItem:identifier]], [expected[identifier] boolValue], @"%@", identifier);
	}
	XCTAssertFalse([self.controller validateMenuItem:[self menuItem:@selector(viewRelations:) key:@"3"]]);
	XCTAssertFalse([self.controller validateMenuItem:[self menuItem:@selector(viewTriggers:) key:@"4"]]);
	XCTAssertTrue([self.controller validateMenuItem:[self menuItem:@selector(viewStatus:) key:@"5"]]);
	[self.document viewRelations:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure, @"disabled: nothing happens");

	// On Relations or Triggers, selecting a view shows the pane's empty-state text instead of switching
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.document viewRelations:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneRelations);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t_view"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneRelations);
	NSView *pane = [[[self.document databaseView] subviews] lastObject];
	NSTextField *empty = [self viewWithIdentifier:@"paneEmptyState" in:pane];
	XCTAssertEqualObjects([empty stringValue], @"Relations aren't available for views.");
	XCTAssertFalse([empty isHiddenOrHasHiddenAncestor]);

	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.document viewTriggers:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneTriggers);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t_view"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneTriggers);
	empty = [self viewWithIdentifier:@"paneEmptyState" in:[[[self.document databaseView] subviews] lastObject]];
	XCTAssertEqualObjects([empty stringValue], @"Triggers aren't available for views.");

	// Back on a table, the text goes
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	empty = [self viewWithIdentifier:@"paneEmptyState" in:[[[self.document databaseView] subviews] lastObject]];
	XCTAssertFalse([[empty stringValue] containsString:@"aren't available"]);
}

/// A relation that is gone (e.g. a rename rolled back in the Query view) shows the error, not an empty grid.
- (void)testMissingRelationShowsError
{
	[self showStructureOf:@"child"];
	XCTAssertNotNil([self.other execute:@"DROP TABLE structure_test.child"]);
	[self.structure refresh:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([self.structure.noticeText length] > 0);
	XCTAssertNotEqualObjects(self.structure.noticeText, @"Views can't be edited here.");
	XCTAssertFalse([[self.structure valueForKey:@"addColumnButton"] isEnabled]);
}

#pragma mark - Fix round 1

/// A draft that can't be saved keeps the tab where it is: another table, another schema, closing the tab,
/// a database switch and a History move are all refused, and the draft keeps what was typed.
- (void)testFailedDraftVetoesLeaving
{
	[self showStructureOf:@"t"];
	SPPostgresStructureController *structure = self.structure;
	NSTableView *columns = structure.columnsView;
	SPPostgresSidebarController *sidebar = self.document.sidebar;
	NSOutlineView *outline = [sidebar valueForKey:@"outlineView"];

	[structure addColumn:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[[columns currentEditor] setString:@"id"]; // taken
	[[columns window] makeFirstResponder:columns];
	[self setValue:@"varchar(7)" in:columns row:8 column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// Clicking another table: the outline asks first
	XCTAssertFalse([(id<NSOutlineViewDelegate>)[outline delegate] selectionShouldChangeInOutlineView:outline]);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([self.alerts[0].informativeText containsString:@"already exists"], @"%@", self.alerts[0].informativeText);
	XCTAssertTrue(structure.hasDraftColumn);
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"name"], @"id");
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"type"], @"varchar(7)");
	XCTAssertEqualObjects(sidebar.selectedTableName, @"t");

	// Another schema from the pop-up
	NSPopUpButton *schemas = [sidebar valueForKey:@"schemaPopup"];
	[schemas selectItemWithTitle:@"public"];
	[NSApp sendAction:[schemas action] to:[schemas target] from:schemas];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedSchema, @"structure_test");
	XCTAssertEqualObjects([schemas titleOfSelectedItem], @"structure_test");
	XCTAssertEqualObjects(sidebar.selectedTableName, @"t");

	// Closing the tab, switching database, going back in history
	XCTAssertFalse([self.document parentTabShouldClose]);
	NSString *title = [self.document windowTitleString];
	[self.document switchToDatabase:@"postgres"];
	XCTAssertFalse(self.document.isProcessing);
	XCTAssertEqualObjects([self.document windowTitleString], title);
	NSMenuItem *back = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	back.tag = 0;
	[self.document backForwardInHistory:back];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(sidebar.selectedTableName, @"t");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertTrue(structure.hasDraftColumn);
	XCTAssertEqualObjects([self valueIn:columns row:8 column:@"type"], @"varchar(7)");

	// Corrected, everything goes ahead
	[self setValue:@"id_two" in:columns row:8 column:@"name"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([(id<NSOutlineViewDelegate>)[outline delegate] selectionShouldChangeInOutlineView:outline]);
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertEqualObjects([self serverTypeOf:@"id_two"], @"character varying(7)");
	XCTAssertTrue([self.document parentTabShouldClose]);
}

/// Only a failure the data can't take (datatype_mismatch, or a data exception) offers USING; others are plain alerts.
- (void)testInvalidTypeNameGivesPlainAlert
{
	[self showStructureOf:@"t"];
	NSTableView *columns = self.structure.columnsView;
	NSInteger qty = [self rowNamed:@"qty" in:columns];
	NSMutableArray *offers = [NSMutableArray array];
	__block void (^pending)(NSString *) = nil;
	self.structure.usingPresenter = ^(NSString *serverMessage, NSString *prefilled, void (^completion)(NSString *)) {
		[offers addObject:serverMessage];
		pending = completion;
	};

	[self setValue:@"no_such_type" in:columns row:qty column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(offers.count, 0u);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([self.alerts[0].informativeText containsString:@"no_such_type"], @"%@", self.alerts[0].informativeText);
	XCTAssertEqualObjects([self serverTypeOf:@"qty"], @"text");

	// The SQLSTATE travels with the error
	SPPostgresTableStructure *direct = [[SPPostgresTableStructure alloc] initWithConnection:self.other schema:@"structure_test" table:@"t"];
	NSError *error = nil;
	XCTAssertFalse([direct changeColumn:@"qty" toType:@"integer" using:nil error:&error]);
	XCTAssertEqualObjects(error.userInfo[SPPostgresSQLStateErrorKey], @"42804");
	XCTAssertFalse([direct changeColumn:@"qty" toType:@"no_such_type" using:nil error:&error]);
	XCTAssertEqualObjects(error.userInfo[SPPostgresSQLStateErrorKey], @"42704");

	// qty -> integer still asks; a USING failing on a row's value (class 22) asks again
	[self setValue:@"integer" in:columns row:qty column:@"type"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(offers.count, 1u);
	void (^answer)(NSString *) = pending;
	answer(@"\"qty\"::integer");
	XCTAssertEqual(offers.count, 2u);
	answer = pending;
	answer(nil);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self serverTypeOf:@"qty"], @"text");
}

/// The default sheet's controller forgets the sheet once it has ended.
- (void)testConstraintSheetEndClearsActiveSheet
{
	[self.controller showWindow:nil];
	[self showStructureOf:@"t"];
	[self.structure addIndex:nil];
	NSWindow *window = [self.controller window];
	NSWindow *sheet = window.attachedSheet;
	XCTAssertNotNil(sheet);
	XCTAssertEqual([self.structure valueForKey:@"activeSheet"], sheet);
	[window endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertNil([self.structure valueForKey:@"activeSheet"]);
}

#pragma mark - Background loading

/// Gives the Structure view the tab's background runner (the tab keeps it on an inline runner until Stage 8 Task 7).
/// Every test using it waits for the runner before anything else uses the connection; side SQL goes through `other`.
- (SPPostgresStructureController *)structureOnTabRunner
{
	SPPostgresStructureController *structure = self.structure;
	structure.taskRunner = self.document.taskRunner;
	XCTAssertFalse(structure.taskRunner.isInline);
	return structure;
}

- (void)testShowTableLoadsInBackground
{
	SPPostgresStructureController *structure = [self structureOnTabRunner];
	[structure showTable:@"t" inSchema:@"structure_test"];
	XCTAssertTrue(structure.taskRunner.isBusy, @"showTable: returns while the structure loads");
	XCTAssertEqualObjects(structure.taskRunner.currentDescription, @"Reloading...");
	XCTAssertEqualObjects(structure.taskRunner.currentCancelTitle, @"Cancel");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:structure.taskRunner timeout:30]);

	// What the inline (synchronous) path shows for the same table
	SPPostgresStructureController *reference = [[SPPostgresStructureController alloc] initWithConnection:self.other];
	XCTAssertTrue(reference.taskRunner.isInline);
	[reference showTable:@"t" inSchema:@"structure_test"];
	XCTAssertFalse(reference.taskRunner.isBusy);

	XCTAssertEqual([structure.columnsView numberOfRows], 8);
	XCTAssertEqualObjects([SPPostgresTestServers rowsOfTableView:structure.columnsView], [SPPostgresTestServers rowsOfTableView:reference.columnsView]);
	XCTAssertEqualObjects([SPPostgresTestServers rowsOfTableView:structure.indexesView], [SPPostgresTestServers rowsOfTableView:reference.indexesView]);
	XCTAssertEqualObjects([SPPostgresTestServers rowsOfTableView:structure.constraintsView], [SPPostgresTestServers rowsOfTableView:reference.constraintsView]);
	XCTAssertTrue([structure.indexesView numberOfRows] > 0);
	XCTAssertEqual(structure.editable, reference.editable);
	XCTAssertTrue(structure.editable);
	XCTAssertEqualObjects(structure.noticeText, reference.noticeText);
	XCTAssertFalse(structure.stale);
	XCTAssertTrue([[structure valueForKey:@"addColumnButton"] isEnabled]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	[reference invalidate];
}

/// A switch cancelled before it loaded: the pane is empty (no alert) and stale; Refresh loads it.
- (void)testCancelledSwitchShowsEmptyPaneNoAlert
{
	SPPostgresStructureController *structure = [self structureOnTabRunner];
	SPPostgresTaskRunner *runner = structure.taskRunner;
	[structure showTable:@"child" inSchema:@"structure_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual([structure.columnsView numberOfRows], 2);

	[SPPostgresTestServers queueSleep:1 onRunner:runner];
	XCTAssertTrue(runner.isBusy);
	[structure showTable:@"t" inSchema:@"structure_test"];
	XCTAssertTrue(runner.isBusy);
	[runner cancelAll];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);

	XCTAssertEqualObjects(structure.table, @"t");
	XCTAssertEqual([structure.columnsView numberOfRows], 0);
	XCTAssertEqual([structure.indexesView numberOfRows], 0);
	XCTAssertEqual([structure.constraintsView numberOfRows], 0);
	XCTAssertEqualObjects(structure.noticeText, @"");
	XCTAssertEqual(self.alerts.count, 0u, @"a cancelled load shows no alert");
	XCTAssertTrue(structure.stale, @"the next show (or Refresh) loads it");
	XCTAssertTrue([[structure valueForKey:@"refreshButton"] isEnabled]);
	XCTAssertFalse([[structure valueForKey:@"addColumnButton"] isEnabled]);

	[structure refresh:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqual([structure.columnsView numberOfRows], 8);
	XCTAssertFalse(structure.stale);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// A column change while a load runs is refused (nothing reaches the connection) and the grid keeps the server's value.
- (void)testChangeRefusedWhileBusy
{
	SPPostgresStructureController *structure = [self structureOnTabRunner];
	SPPostgresTaskRunner *runner = structure.taskRunner;
	[structure showTable:@"t" inSchema:@"structure_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	NSInteger row = [self rowNamed:@"code" in:structure.columnsView];

	[SPPostgresTestServers queueSleep:1 onRunner:runner];
	XCTAssertTrue(runner.isBusy);
	XCTAssertFalse([self canEdit:structure.columnsView row:row column:@"comment"], @"no edit starts while busy");
	[self setValue:@"while busy" in:structure.columnsView row:row column:@"comment"];
	[structure addColumn:nil];
	XCTAssertFalse(structure.hasDraftColumn);
	XCTAssertTrue(runner.isBusy);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);

	XCTAssertEqualObjects([self serverValue:@"SELECT col_description('structure_test.t'::regclass, 2)"], @"the code");
	XCTAssertEqualObjects([self valueIn:structure.columnsView row:row column:@"comment"], @"the code");
	XCTAssertTrue([self canEdit:structure.columnsView row:row column:@"comment"], @"editable again once idle");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// A cell being edited while a load runs doesn't end: its text stays and nothing is committed (Refresh, -reload and
/// -commitPendingEdits refuse); once idle it commits. (A background runner on the tab's connection that the tab's
/// task display doesn't watch: the display ends any edit when the tab's own runner turns busy, see Stage 8 Task 2.)
- (void)testCellEditKeptWhileBusy
{
	[self showStructureOf:@"t"];
	SPPostgresStructureController *structure = self.structure;
	SPPostgresTaskRunner *runner = [[SPPostgresTaskRunner alloc] initWithConnection:[structure valueForKey:@"connection"]];
	structure.taskRunner = runner;
	[self addTeardownBlock:^{
		[runner invalidateWithCompletion:nil];
	}];
	NSTableView *columns = structure.columnsView;
	NSInteger row = [self rowNamed:@"code" in:columns];
	XCTAssertTrue([[columns window] makeFirstResponder:columns]);
	[columns editColumn:[columns columnWithIdentifier:@"comment"] row:row withEvent:nil select:YES];
	XCTAssertNotNil([columns currentEditor]);
	[[columns currentEditor] setString:@"typed while busy"];

	[SPPostgresTestServers queueSleep:1 onRunner:runner];
	XCTAssertTrue(runner.isBusy);
	XCTAssertFalse([structure commitPendingEdits], @"the commit is refused while busy");
	[structure refresh:nil];
	[structure reload];
	XCTAssertNotNil([columns currentEditor], @"the edit goes on");
	XCTAssertEqualObjects([[columns currentEditor] string], @"typed while busy");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT col_description('structure_test.t'::regclass, 2)"], @"the code");

	// Once idle it commits
	XCTAssertTrue([structure commitPendingEdits]);
	XCTAssertNil([columns currentEditor]);
	XCTAssertEqualObjects([self serverValue:@"SELECT col_description('structure_test.t'::regclass, 2)"], @"typed while busy");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

@end
