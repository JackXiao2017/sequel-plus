#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestPrefsGuard.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresStructureController.h"
#import "../Source/Postgres/SPPostgresRelationsController.h"
#import "../Source/Postgres/SPPostgresTriggersController.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresConstraintSheet.h"
#import "../Source/Postgres/SPPostgresTableStructure.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static const NSUInteger SPRelationsTestPort = 55418;

// MySQL's identifiers (the app's constants aren't exported to the test bundle)
static NSString * const SPRelationsTestToolbarRelations = @"SwitchToTableRelationsToolbarItemIdentifier";
static NSString * const SPRelationsTestToolbarTriggers = @"SwitchToTableTriggersToolbarItemIdentifier";

@interface SPPostgresDocument (SPPostgresRelationsControllerTests)
- (BOOL)parentTabShouldClose;
- (IBAction)backForwardInHistory:(id)sender;
@end

@interface SPWindowController (SPPostgresRelationsControllerTests)
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

/// The Relations and Triggers panes of a Postgres tab hosted in a window (port 55418).
@interface SPPostgresRelationsControllerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<NSAlert *> *confirmations;
@property (assign) BOOL confirmAnswer;
@end

@implementation SPPostgresRelationsControllerTests

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
	[SPPostgresTestServers loadStructureFixtureOnPort:SPRelationsTestPort];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 relations";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPRelationsTestPort;
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
	__weak SPPostgresRelationsControllerTests *weakSelf = self;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	self.document.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) {
		[confirmations addObject:alert];
		completion(weakSelf.confirmAnswer);
	};
	[self.controller addTabDocument:self.document atIndex:0 select:YES];

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPRelationsTestPort];
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
	[SPPostgresTestServers dropStructureFixtureOnPort:SPRelationsTestPort];
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresRelationsController *)relations
{
	return self.document.relationsController;
}

- (SPPostgresTriggersController *)triggers
{
	return self.document.triggersController;
}

- (void)select:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"structure_test"];
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
}

- (void)showRelationsOf:(NSString *)table
{
	[self select:table];
	[self.document viewRelations:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneRelations);
	XCTAssertEqualObjects(self.relations.table, table);
}

- (void)showTriggersOf:(NSString *)table
{
	[self select:table];
	[self.document viewTriggers:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneTriggers);
	XCTAssertEqualObjects(self.triggers.table, table);
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

- (NSString *)tgenabled:(NSString *)trigger
{
	return [self serverValue:[NSString stringWithFormat:@"SELECT tgenabled::text FROM pg_trigger WHERE tgrelid = 'structure_test.t'::regclass AND tgname = '%@'", trigger]];
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

- (void)runQuery:(NSString *)sql
{
	[self.document viewQuery:nil];
	[[self.document.queryController editor] setString:sql];
	[self.document.queryController runAllQueries:nil];
}

#pragma mark - Relations

- (void)testRelationsGridListsChildForeignKey
{
	[self showRelationsOf:@"child"];
	NSTableView *grid = self.relations.relationsView;

	XCTAssertEqualObjects([[grid tableColumns] valueForKeyPath:@"headerCell.stringValue"],
						  (@[@"Name", @"Columns", @"References", @"Referenced Columns", @"On Update", @"On Delete"]));
	XCTAssertEqual([grid numberOfRows], 1);
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"name"], @"child_t_id_fkey");
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"columns"], @"t_id");
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"references"], @"structure_test.t");
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"referencedColumns"], @"id");
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"onUpdate"], @"NO ACTION");
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"onDelete"], @"CASCADE");
	XCTAssertEqualObjects(self.relations.noticeText, @"Relations for table: child");
	XCTAssertNotNil([grid window], @"in the window");
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPRelationsTestToolbarRelations);

	// t has none of its own (child's key references it, which is child's relation, as MySQL's tab shows)
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertEqualObjects(self.relations.table, @"t");
	XCTAssertEqual([grid numberOfRows], 0);
	XCTAssertFalse([[self.relations valueForKey:@"removeButton"] isEnabled]);
	XCTAssertTrue([[self.relations valueForKey:@"addButton"] isEnabled]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testAddForeignKeyViaSheetCompletionAndDrop
{
	[self showRelationsOf:@"child"];
	SPPostgresRelationsController *relations = self.relations;
	NSTableView *grid = relations.relationsView;
	__block NSArray *offeredColumns = nil;
	__block SPPostgresConstraintDefinition *answer = nil;
	relations.constraintSheetPresenter = ^(NSArray *columnNames, void (^completion)(SPPostgresConstraintDefinition *)) {
		offeredColumns = columnNames;
		completion(answer);
	};

	// Cancelled: nothing
	[relations addRelation:nil];
	XCTAssertEqualObjects(offeredColumns, (@[@"id", @"t_id"]));
	XCTAssertEqual([grid numberOfRows], 1);

	// Refused by the server (t.qty is not unique): the message, nothing added
	SPPostgresConstraintDefinition *bad = [[SPPostgresConstraintDefinition alloc] init];
	bad.kind = @"FOREIGN KEY";
	bad.columns = @[@"t_id"];
	bad.referencedTable = @"t";
	bad.referencedColumns = @[@"qty"];
	answer = bad;
	[relations addRelation:nil];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(self.alerts[0].messageText, @"Could not add the foreign key");
	XCTAssertTrue([self.alerts[0].informativeText length] > 0);
	XCTAssertEqual([grid numberOfRows], 1);

	// Added
	SPPostgresConstraintDefinition *key = [[SPPostgresConstraintDefinition alloc] init];
	key.kind = @"FOREIGN KEY";
	key.name = @"child_id_fkey";
	key.columns = @[@"id"];
	key.referencedSchema = @"structure_test";
	key.referencedTable = @"t";
	key.onDelete = @"RESTRICT";
	answer = key;
	[relations addRelation:nil];
	XCTAssertEqual(self.alerts.count, 1u, @"%@", self.alerts.lastObject.informativeText);
	XCTAssertEqualObjects([self valuesIn:grid column:@"name"], (@[@"child_id_fkey", @"child_t_id_fkey"]));
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"onDelete"], @"RESTRICT");
	XCTAssertEqualObjects([self valueIn:grid row:0 column:@"referencedColumns"], @"id");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*)::text FROM pg_constraint WHERE conname = 'child_id_fkey'"], @"1");

	// The Structure view shows it when next shown
	[self.document viewStructure:nil];
	NSTableView *constraints = self.document.structureController.constraintsView;
	XCTAssertTrue([[self valuesIn:constraints column:@"name"] containsObject:@"child_id_fkey"]);
	[self.document viewRelations:nil];

	// −: asks; Cancel keeps it, Delete drops it
	[self selectRow:[self rowNamed:@"child_id_fkey" in:grid] in:grid];
	self.confirmAnswer = NO;
	[relations removeRelation:nil];
	XCTAssertEqual(self.confirmations.count, 1u);
	XCTAssertEqualObjects(self.confirmations[0].messageText, @"Delete foreign key \"child_id_fkey\"?");
	XCTAssertEqual([grid numberOfRows], 2);
	self.confirmAnswer = YES;
	[relations removeRelation:nil];
	XCTAssertEqualObjects([self valuesIn:grid column:@"name"], @[@"child_t_id_fkey"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*)::text FROM pg_constraint WHERE conname = 'child_id_fkey'"], @"0");
	XCTAssertEqual(self.alerts.count, 1u, @"%@", self.alerts.lastObject.informativeText);
}

/// The default + sheet is the constraint sheet in FOREIGN KEY mode, starting at the table's own schema.
- (void)testAddRelationDefaultSheetIsForeignKeyMode
{
	[self.controller showWindow:nil];
	[self showRelationsOf:@"child"];
	[self.relations addRelation:nil];
	NSWindow *window = [self.controller window];
	NSWindow *sheet = window.attachedSheet;
	XCTAssertNotNil(sheet);
	XCTAssertEqual([self.relations valueForKey:@"activeSheet"], sheet);
	NSPopUpButton *schemas = [self viewWithIdentifier:@"referencedSchema" in:sheet.contentView];
	XCTAssertFalse(schemas.isHidden);
	XCTAssertEqualObjects([schemas titleOfSelectedItem], @"structure_test");
	NSView *kind = [self viewWithIdentifier:@"constraintKind" in:sheet.contentView];
	XCTAssertTrue(kind.isHidden, @"FK mode has no kind pop-up");
	[window endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);
	XCTAssertNil([self.relations valueForKey:@"activeSheet"]);
	XCTAssertEqual([self.relations.relationsView numberOfRows], 1);
}

#pragma mark - Triggers

- (void)testTriggersGridAndFunctionSource
{
	[self showTriggersOf:@"t"];
	SPPostgresTriggersController *triggers = self.triggers;
	NSTableView *grid = triggers.triggersView;

	XCTAssertEqualObjects([[grid tableColumns] valueForKeyPath:@"headerCell.stringValue"],
						  (@[@"Name", @"Timing", @"Event", @"Level", @"Function", @"Enabled"]));
	XCTAssertEqualObjects([self valuesIn:grid column:@"name"], (@[@"t_audit", @"t_touch"]));
	XCTAssertEqualObjects([self valuesIn:grid column:@"timing"], (@[@"AFTER", @"BEFORE"]));
	XCTAssertEqualObjects([self valuesIn:grid column:@"event"], (@[@"INSERT OR DELETE", @"UPDATE OF code"]));
	XCTAssertEqualObjects([self valuesIn:grid column:@"level"], (@[@"STATEMENT", @"ROW"]));
	XCTAssertEqualObjects([self valuesIn:grid column:@"function"], (@[@"structure_test.touch", @"structure_test.touch"]));
	XCTAssertEqualObjects([self valuesIn:grid column:@"enabled"], (@[@NO, @YES]));
	XCTAssertEqualObjects(triggers.noticeText, @"Triggers for table: t");

	// Only Enabled is editable
	for (NSString *identifier in @[@"name", @"timing", @"event", @"level", @"function"]) {
		XCTAssertFalse([(id<NSTableViewDelegate>)[grid delegate] tableView:grid shouldEditTableColumn:[self column:identifier of:grid] row:0], @"%@", identifier);
	}

	// The selected trigger's function source, read-only and monospaced
	NSTextView *source = triggers.functionSourceView;
	XCTAssertFalse([source isEditable]);
	XCTAssertTrue([[source font] isFixedPitch] || [[[source font] fontDescriptor] symbolicTraits] & NSFontDescriptorTraitMonoSpace, @"%@", [source font]);
	XCTAssertEqualObjects([source string], @"");
	[self selectRow:1 in:grid];
	XCTAssertTrue([[source string] containsString:@"RETURN NEW"], @"%@", [source string]);
	XCTAssertTrue([[source string] containsString:@"structure_test.touch()"], @"%@", [source string]);
	[grid deselectAll:nil];
	XCTAssertEqualObjects([source string], @"");

	// + through the sheet presenter: the table's columns and the trigger functions are offered
	__block NSArray *offeredColumns = nil, *offeredFunctions = nil;
	SPPostgresTriggerDefinition *definition = [[SPPostgresTriggerDefinition alloc] init];
	definition.name = @"t_new";
	definition.timing = @"AFTER";
	definition.events = @[@"UPDATE"];
	definition.updateColumns = @[@"qty", @"Order"];
	definition.level = @"ROW";
	definition.function = @"structure_test.touch";
	triggers.triggerSheetPresenter = ^(NSArray *columnNames, NSArray *functions, void (^completion)(SPPostgresTriggerDefinition *)) {
		offeredColumns = columnNames;
		offeredFunctions = functions;
		completion(definition);
	};
	[triggers addTrigger:nil];
	XCTAssertEqualObjects(offeredColumns, (@[@"id", @"code", @"qty", @"amount", @"Order", @"a \"q\" b", @"gen", @"ident"]));
	XCTAssertTrue([offeredFunctions containsObject:@"structure_test.touch"], @"%@", offeredFunctions);
	XCTAssertEqualObjects([self valuesIn:grid column:@"name"], (@[@"t_audit", @"t_new", @"t_touch"]));
	XCTAssertEqualObjects([self valueIn:grid row:1 column:@"event"], @"UPDATE OF qty, \"Order\"");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// A failing add: the server's message
	definition.name = @"t_bad";
	definition.level = @"STATEMENT";
	definition.condition = @"NEW.qty IS NULL";
	[triggers addTrigger:nil];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(self.alerts[0].messageText, @"Could not add the trigger");
	XCTAssertEqual([grid numberOfRows], 3);

	// − asks, then drops
	[self selectRow:[self rowNamed:@"t_new" in:grid] in:grid];
	[triggers removeTrigger:nil];
	XCTAssertEqual(self.confirmations.count, 1u);
	XCTAssertEqualObjects(self.confirmations[0].messageText, @"Delete trigger \"t_new\"?");
	XCTAssertEqualObjects([self valuesIn:grid column:@"name"], (@[@"t_audit", @"t_touch"]));
	XCTAssertNil([self tgenabled:@"t_new"]);
}

- (void)testEnabledCheckboxTogglesTrigger
{
	[self showTriggersOf:@"t"];
	NSTableView *grid = self.triggers.triggersView;
	NSInteger audit = [self rowNamed:@"t_audit" in:grid];
	NSInteger touch = [self rowNamed:@"t_touch" in:grid];
	XCTAssertTrue([(id<NSTableViewDelegate>)[grid delegate] tableView:grid shouldEditTableColumn:[self column:@"enabled" of:grid] row:audit]);

	[self setValue:@YES in:grid row:audit column:@"enabled"];
	XCTAssertEqualObjects([self tgenabled:@"t_audit"], @"O");
	XCTAssertEqualObjects([self valueIn:grid row:audit column:@"enabled"], @YES);
	[self setValue:@NO in:grid row:touch column:@"enabled"];
	XCTAssertEqualObjects([self tgenabled:@"t_touch"], @"D");
	XCTAssertEqualObjects([self valueIn:grid row:touch column:@"enabled"], @NO);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// Another session holds a lock on t: the change times out, the alert says so, the checkbox shows the server's state
	XCTAssertNotNil([self.other execute:@"BEGIN"]);
	XCTAssertNotNil([self.other execute:@"UPDATE structure_test.t SET qty = qty"]);
	[self setValue:@YES in:grid row:touch column:@"enabled"];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(self.alerts[0].messageText, @"Could not change the trigger “t_touch”");
	XCTAssertTrue([self.alerts[0].informativeText containsString:@"lock"], @"%@", self.alerts[0].informativeText);
	XCTAssertEqualObjects([self valueIn:grid row:touch column:@"enabled"], @NO);
	XCTAssertNotNil([self.other execute:@"ROLLBACK"]);
	XCTAssertEqualObjects([self tgenabled:@"t_touch"], @"D");

	// The trigger is gone (dropped elsewhere): the alert, and the grid shows what is there
	XCTAssertNotNil([self.other execute:@"DROP TRIGGER t_touch ON structure_test.t"]);
	[self setValue:@YES in:grid row:touch column:@"enabled"];
	XCTAssertEqual(self.alerts.count, 2u);
	XCTAssertEqualObjects([self valuesIn:grid column:@"name"], @[@"t_audit"]);
}

/// The add-trigger sheet enables Add only for what PostgreSQL could take, and returns what was chosen.
- (void)testTriggerSheetValidation
{
	[self.controller showWindow:nil];
	NSWindow *window = [self.controller window];
	__block SPPostgresTriggerDefinition *result = (id)@"not called";
	__block NSUInteger calls = 0;
	[SPPostgresTriggerSheet beginWithColumns:@[@"id", @"code", @"a \"q\" b"] functions:@[@"\"Sales Data\".\"Odd fn\"", @"structure_test.touch"] window:window completion:^(SPPostgresTriggerDefinition *definition) {
		result = definition;
		calls++;
	}];
	NSWindow *sheet = window.attachedSheet;
	XCTAssertNotNil(sheet);
	NSView *content = sheet.contentView;
	NSTextField *name = [self viewWithIdentifier:@"triggerName" in:content];
	NSPopUpButton *timing = [self viewWithIdentifier:@"triggerTiming" in:content];
	NSButton *insert = [self viewWithIdentifier:@"triggerEventINSERT" in:content];
	NSButton *update = [self viewWithIdentifier:@"triggerEventUPDATE" in:content];
	NSButton *truncate = [self viewWithIdentifier:@"triggerEventTRUNCATE" in:content];
	NSTableView *columns = [self viewWithIdentifier:@"triggerUpdateColumns" in:content];
	NSPopUpButton *level = [self viewWithIdentifier:@"triggerLevel" in:content];
	NSPopUpButton *function = [self viewWithIdentifier:@"triggerFunction" in:content];
	NSTextField *when = [self viewWithIdentifier:@"triggerCondition" in:content];
	NSButton *add = [self viewWithIdentifier:@"triggerAddButton" in:content];
	for (id control in @[name, timing, insert, update, truncate, columns, level, function, when, add]) XCTAssertNotNil(control);

	XCTAssertEqualObjects([timing itemTitles], (@[@"BEFORE", @"AFTER"]));
	XCTAssertEqualObjects([level itemTitles], (@[@"FOR EACH ROW", @"FOR EACH STATEMENT"]));
	XCTAssertEqualObjects([function itemTitles], (@[@"\"Sales Data\".\"Odd fn\"", @"structure_test.touch"]));
	XCTAssertFalse([add isEnabled], @"no name, no event");
	XCTAssertFalse([columns isEnabled], @"UPDATE OF only with UPDATE");

	void (^changed)(NSTextField *) = ^(NSTextField *field) {
		[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
	};
	void (^click)(NSControl *) = ^(NSControl *control) {
		[NSApp sendAction:[control action] to:[control target] from:control];
	};

	name.stringValue = @"t_sheet";
	changed(name);
	XCTAssertFalse([add isEnabled], @"no event");
	update.state = NSControlStateValueOn;
	click(update);
	XCTAssertTrue([add isEnabled]);
	XCTAssertTrue([columns isEnabled]);

	// A name PostgreSQL would cut
	name.stringValue = [@"" stringByPaddingToLength:64 withString:@"n" startingAtIndex:0];
	changed(name);
	XCTAssertFalse([add isEnabled]);
	name.stringValue = @"t_sheet";
	changed(name);

	// TRUNCATE needs statement level; WHEN needs row level
	truncate.state = NSControlStateValueOn;
	click(truncate);
	XCTAssertFalse([add isEnabled]);
	[level selectItemAtIndex:1];
	click(level);
	XCTAssertTrue([add isEnabled]);
	when.stringValue = @"NEW.code IS NOT NULL";
	changed(when);
	XCTAssertFalse([add isEnabled]);
	truncate.state = NSControlStateValueOff;
	click(truncate);
	[level selectItemAtIndex:0];
	click(level);
	XCTAssertTrue([add isEnabled]);

	// Columns for UPDATE OF; unchecking UPDATE disables the list (and drops the choice)
	[(id<NSTableViewDataSource>)[columns dataSource] tableView:columns setObjectValue:@YES forTableColumn:[columns tableColumnWithIdentifier:@"use"] row:2];
	insert.state = NSControlStateValueOn;
	click(insert);
	[timing selectItemWithTitle:@"AFTER"];
	[function selectItemAtIndex:1];
	[add performClick:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return calls == 1; } timeout:5]);
	XCTAssertEqualObjects(result.name, @"t_sheet");
	XCTAssertEqualObjects(result.timing, @"AFTER");
	XCTAssertEqualObjects(result.events, (@[@"INSERT", @"UPDATE"]));
	XCTAssertEqualObjects(result.updateColumns, @[@"a \"q\" b"]);
	XCTAssertEqualObjects(result.level, @"ROW");
	XCTAssertEqualObjects(result.function, @"structure_test.touch");
	XCTAssertEqualObjects(result.condition, @"NEW.code IS NOT NULL");
	XCTAssertNil(window.attachedSheet);

	// No trigger functions: Add stays off, and a hint says where to make one
	calls = 0;
	[SPPostgresTriggerSheet beginWithColumns:@[@"id"] functions:@[] window:window completion:^(SPPostgresTriggerDefinition *definition) {
		result = definition;
		calls++;
	}];
	sheet = window.attachedSheet;
	name = [self viewWithIdentifier:@"triggerName" in:sheet.contentView];
	name.stringValue = @"x";
	changed(name);
	insert = [self viewWithIdentifier:@"triggerEventINSERT" in:sheet.contentView];
	insert.state = NSControlStateValueOn;
	click(insert);
	XCTAssertFalse([(NSButton *)[self viewWithIdentifier:@"triggerAddButton" in:sheet.contentView] isEnabled]);
	NSTextField *hint = [self viewWithIdentifier:@"triggerFunctionHint" in:sheet.contentView];
	XCTAssertFalse(hint.isHidden);
	XCTAssertTrue([hint.stringValue containsString:@"Query"], @"%@", hint.stringValue);
	[window endSheet:sheet returnCode:NSModalResponseCancel];
	XCTAssertTrue([self spinUntil:^BOOL{ return calls == 1; } timeout:5]);
	XCTAssertNil(result);
}

#pragma mark - Panes

- (void)testRelationsAndTriggersPanesFromMenuItems
{
	NSMenuItem *relationsItem = [self menuItem:@selector(viewRelations:) key:@"3"];
	NSMenuItem *triggersItem = [self menuItem:@selector(viewTriggers:) key:@"4"];
	XCTAssertFalse([self.controller validateMenuItem:relationsItem], @"nothing selected");
	XCTAssertFalse([self.controller validateMenuItem:triggersItem]);

	[self select:@"child"];
	XCTAssertTrue([self.controller validateMenuItem:relationsItem]);
	[self.controller performSelector:@selector(viewRelations:) withObject:relationsItem];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneRelations);
	XCTAssertNotNil([self.relations.relationsView window]);
	XCTAssertEqual([[self.relations.relationsView window] firstResponder], self.relations.relationsView);
	XCTAssertEqual([self.relations.relationsView numberOfRows], 1);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPRelationsTestToolbarRelations);

	XCTAssertTrue([self.controller validateMenuItem:triggersItem]);
	[self.controller performSelector:@selector(viewTriggers:) withObject:triggersItem];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneTriggers);
	XCTAssertNil([self.relations.relationsView window], @"Relations is out of the window");
	XCTAssertNotNil([self.triggers.triggersView window]);
	XCTAssertEqualObjects(self.triggers.table, @"child");
	XCTAssertEqual([self.triggers.triggersView numberOfRows], 0, @"the FK's internal triggers aren't listed");
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPRelationsTestToolbarTriggers);

	// The selection follows while the pane is shown
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertEqual([self.triggers.triggersView numberOfRows], 2);

	// History: back to child's Relations
	NSMenuItem *back = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	back.tag = 0;
	[self.document backForwardInHistory:back];
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"child");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneTriggers);
	[self.document backForwardInHistory:back];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneRelations);
	XCTAssertEqual([self.relations.relationsView numberOfRows], 1);

	// A view: the empty state, with the grid hidden
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t_view"]);
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneRelations);
	XCTAssertEqualObjects(self.relations.emptyStateText, @"Relations aren't available for views.");
	XCTAssertTrue([self.relations.relationsView isHiddenOrHasHiddenAncestor]);
	XCTAssertEqual([self.relations.relationsView numberOfRows], 0);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertEqualObjects(self.relations.emptyStateText, @"");
	XCTAssertFalse([self.relations.relationsView isHiddenOrHasHiddenAncestor]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// After Query DDL, or a change in the Structure or Relations view, a pane shows the server's state when next shown.
- (void)testPanesReloadAfterQueryAndStructureChanges
{
	[self showTriggersOf:@"t"];
	[self runQuery:@"CREATE TRIGGER t_q AFTER INSERT ON structure_test.t FOR EACH ROW EXECUTE FUNCTION structure_test.touch()"];
	[self.document viewTriggers:nil];
	XCTAssertEqualObjects([self valuesIn:self.triggers.triggersView column:@"name"], (@[@"t_audit", @"t_q", @"t_touch"]));

	[self showRelationsOf:@"child"];
	[self runQuery:@"ALTER TABLE structure_test.child DROP CONSTRAINT child_t_id_fkey"];
	[self.document viewRelations:nil];
	XCTAssertEqual([self.relations.relationsView numberOfRows], 0);
	[self runQuery:@"ALTER TABLE structure_test.child ADD CONSTRAINT child_t_id_fkey FOREIGN KEY (t_id) REFERENCES structure_test.t (id)"];
	[self.document viewRelations:nil];
	XCTAssertEqual([self.relations.relationsView numberOfRows], 1);

	// A column renamed in the Structure view
	[self.document viewStructure:nil];
	NSTableView *columns = self.document.structureController.columnsView;
	[self setValue:@"tid" in:columns row:[self rowNamed:@"t_id" in:columns] column:@"name"];
	[self.document viewRelations:nil];
	XCTAssertEqualObjects([self valueIn:self.relations.relationsView row:0 column:@"columns"], @"tid");

	// Same for the trigger's UPDATE OF column
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	[self.document viewTriggers:nil];
	[self.document viewStructure:nil];
	columns = self.document.structureController.columnsView;
	[self setValue:@"the code" in:columns row:[self rowNamed:@"code" in:columns] column:@"name"];
	[self.document viewTriggers:nil];
	NSTableView *grid = self.triggers.triggersView;
	XCTAssertEqualObjects([self valueIn:grid row:[self rowNamed:@"t_touch" in:grid] column:@"event"], @"UPDATE OF \"the code\"");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// Closing the tab (or a database switch replacing the controllers) ends a sheet still up, safely.
- (void)testTeardownEndsSheets
{
	[self.controller showWindow:nil];
	NSWindow *window = [self.controller window];

	[self showTriggersOf:@"t"];
	[self.triggers addTrigger:nil];
	XCTAssertNotNil(window.attachedSheet);
	SPPostgresTriggersController *triggers = self.triggers;
	[triggers invalidate];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);
	XCTAssertNil([triggers.triggersView dataSource]);

	[self.document viewRelations:nil];
	[self.relations addRelation:nil];
	XCTAssertNotNil(window.attachedSheet);
	XCTAssertTrue([self.document parentTabShouldClose]);
	[self.document parentTabDidClose];
	XCTAssertTrue([self spinUntil:^BOOL{ return window.attachedSheet == nil; } timeout:5]);
	XCTAssertNil([self.relations.relationsView dataSource]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - Ruling R6

/// A lost connection doesn't keep the tab open over a Structure draft that can't be saved.
- (void)testTabClosesWhenDisconnectedDespiteDraft
{
	[self select:@"t"];
	[self.document viewStructure:nil];
	SPPostgresStructureController *structure = self.document.structureController;
	[structure addColumn:nil];
	NSTableView *columns = structure.columnsView;
	[[columns currentEditor] setString:@"id"]; // taken
	[[columns window] makeFirstResponder:columns];
	XCTAssertFalse([self.document parentTabShouldClose], @"connected: the failed draft keeps the tab");
	XCTAssertTrue(structure.hasDraftColumn);
	NSUInteger alerts = self.alerts.count;

	[self.document.connection disconnect];
	XCTAssertTrue([self spinUntil:^BOOL{ return !self.document.connection.isConnected; } timeout:5]);
	XCTAssertTrue([self.document parentTabShouldClose]);
	XCTAssertEqual(self.alerts.count, alerts, @"no attempt to save");
}

@end
