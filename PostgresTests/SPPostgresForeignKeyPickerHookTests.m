#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/SPForeignKeyPicker.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/Postgres/SPPostgresFieldEditorSheet.h"
#import "../Source/Postgres/SPPostgresDateTimePicker.h"

static const NSUInteger SPFKHookTestPort = 55418;
static NSString * const SPFKHookSuite = @"SPPostgresForeignKeyPickerHookTests";

// SPFieldEditorController (its header isn't ARC-clean)
@interface NSObject (SPFKHookFieldEditor)
- (void)closeEditSheet:(id)sender;
@end

/**
 * The PostgreSQL Content view opening the foreign key picker on a single-column, non-bytea foreign key cell, and its
 * outcome going into the cell's in-place editor (or the field editor sheet's text). Schema sp_fkp, built and dropped
 * here one object at a time; preferences in a throwaway suite.
 */
@interface SPPostgresForeignKeyPickerHookTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSUserDefaults *scratch;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) SPForeignKeyPicker *picker;
@property (strong) NSMutableArray *presented;
@end

@implementation SPPostgresForeignKeyPickerHookTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	return condition();
}

- (void)run:(NSString *)sql
{
	XCTAssertNotNil([self.other execute:sql], @"%@: %@", sql, [[self.other lastError] errorPrimaryMessage]);
}

- (void)dropFixture
{
	for (NSString *table in @[@"orders", @"customers", @"pairs", @"pairs_ref", @"blobrefs", @"blobs", @"employees"]) {
		[self.other execute:[NSString stringWithFormat:@"DROP TABLE IF EXISTS sp_fkp.%@", table]];
	}
	[self.other execute:@"DROP SCHEMA IF EXISTS sp_fkp"];
}

- (id)serverValue:(NSString *)sql
{
	id value = nil;
	for (NSDictionary *row in [self.other execute:sql]) value = [[row allValues] firstObject];
	return value;
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPFKHookSuite];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPFKHookSuite];
	[self.scratch setBool:NO forKey:@"EditInSheetEnabled"];
	[self.scratch setBool:NO forKey:@"LimitResults"];
	[self.scratch setBool:NO forKey:@"RuleFilterEditorLastVisibilityChoice"];

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPFKHookTestPort];
	XCTAssertNotNil(self.other);
	[self dropFixture];
	[self run:@"CREATE SCHEMA sp_fkp"];
	[self run:@"CREATE TABLE sp_fkp.customers (id int PRIMARY KEY, name text)"];
	[self run:@"INSERT INTO sp_fkp.customers VALUES (1, 'Ann'), (2, 'Bob'), (3, 'Cy')"];
	[self run:@"CREATE TABLE sp_fkp.orders (id int PRIMARY KEY, customer_id int REFERENCES sp_fkp.customers, note text)"];
	[self run:@"INSERT INTO sp_fkp.orders VALUES (10, 1, 'a'), (11, NULL, 'b')"];
	[self run:@"CREATE TABLE sp_fkp.pairs_ref (a int, b int, PRIMARY KEY (a, b))"];
	[self run:@"INSERT INTO sp_fkp.pairs_ref VALUES (1, 1)"];
	[self run:@"CREATE TABLE sp_fkp.pairs (id int PRIMARY KEY, a int, b int, FOREIGN KEY (a, b) REFERENCES sp_fkp.pairs_ref)"];
	[self run:@"INSERT INTO sp_fkp.pairs VALUES (1, 1, 1)"];
	[self run:@"CREATE TABLE sp_fkp.blobs (k bytea PRIMARY KEY)"];
	[self run:@"INSERT INTO sp_fkp.blobs VALUES ('\\x01')"];
	[self run:@"CREATE TABLE sp_fkp.blobrefs (id int PRIMARY KEY, k bytea REFERENCES sp_fkp.blobs)"];
	[self run:@"INSERT INTO sp_fkp.blobrefs VALUES (1, '\\x01')"];
	[self run:@"CREATE TABLE sp_fkp.employees (id int PRIMARY KEY, manager_id int REFERENCES sp_fkp.employees, name text)"];
	[self run:@"INSERT INTO sp_fkp.employees VALUES (1, NULL, 'Boss'), (2, 1, 'Ann'), (3, 1, 'Bob')"];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 fk picker";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPFKHookTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) { connection = theConnection; done = YES; }];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection);
	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	NSMutableArray *alerts = [NSMutableArray array];
	self.alerts = alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	self.content.defaults = self.scratch;
	[self.document showPane:@"SwitchToTableContentToolbarItemIdentifier"];

	NSMutableArray *presented = [NSMutableArray array];
	self.presented = presented;
	__weak SPPostgresForeignKeyPickerHookTests *weakSelf = self;
	self.content.foreignKeyPickerPresenter = ^(SPForeignKeyPicker *picker, NSView *view, NSRect rect) {
		weakSelf.picker = picker;
		[presented addObject:picker];
	};
}

- (void)tearDown
{
	[self.picker cancel];
	self.picker = nil;
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	[SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[self dropFixture];
	[self.other disconnect];
	self.other = nil;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPFKHookSuite];
	self.scratch = nil;
	[SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest];
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

- (void)waitForTab
{
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)selectTable:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"sp_fkp"];
	[self waitForTab];
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
	[self waitForTab];
	XCTAssertEqualObjects(self.content.table, table);
}

- (NSTableColumn *)tableColumnNamed:(NSString *)name
{
	for (NSTableColumn *column in [[self grid] tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:name]) return column;
	}
	XCTFail(@"No column %@", name);
	return nil;
}

- (NSInteger)rowWhereColumn:(NSString *)name is:(NSString *)value
{
	NSTableColumn *column = [self tableColumnNamed:name];
	for (NSInteger row = 0; row < [[self grid] numberOfRows]; row++) {
		if ([[[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:column row:row] isEqual:value]) return row;
	}
	XCTFail(@"No row with %@ = %@", name, value);
	return -1;
}

- (BOOL)shouldEdit:(NSString *)column row:(NSInteger)row
{
	return [(id<NSTableViewDelegate>)[self grid].delegate tableView:[self grid] shouldEditTableColumn:[self tableColumnNamed:column] row:row];
}

/// The picker presented, its first page loaded.
- (SPForeignKeyPicker *)loadedPicker
{
	XCTAssertNotNil(self.picker);
	SPForeignKeyPicker *picker = self.picker;
	XCTAssertTrue([self spinUntil:^BOOL{ return picker.rows.count > 0 || picker.errorMessage; } timeout:10]);
	XCTAssertNil(picker.errorMessage);
	return picker;
}

- (void)selectKey:(NSString *)key inPicker:(SPForeignKeyPicker *)picker
{
	for (NSUInteger i = 0; i < picker.rows.count; i++) {
		if ([picker.rows[i][0] isEqual:key]) {
			[picker.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
			return;
		}
	}
	XCTFail(@"no row %@ in the picker", key);
}

- (void)endEditing
{
	XCTAssertNotNil([[self grid] currentEditor]);
	[[[self grid] window] makeFirstResponder:[self grid]];
	XCTAssertNil([[self grid] currentEditor]);
	// The reload after a grid commit is queued for the next run loop turn: let it start before waiting
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	[self waitForTab];
}

#pragma mark - Opening

- (void)testEditingForeignKeyCellOpensPicker
{
	[self selectTable:@"orders"];
	NSInteger row = [self rowWhereColumn:@"id" is:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	XCTAssertEqualObjects([[picker.resultsTable tableColumns] valueForKey:@"identifier"], (@[@"id", @"name"]));
	XCTAssertEqualObjects(picker.rows, (@[@[@"1", @"Ann"], @[@"2", @"Bob"], @[@"3", @"Cy"]]));
	XCTAssertEqual(picker.currentValueRow, 0, @"the cell's value, 1, is tinted");
	XCTAssertEqualObjects(picker.titleField.stringValue, @"Choose customers.id · sp_fkp.customers");
	XCTAssertFalse(picker.nullButton.hidden, @"customer_id takes NULL");
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row], @"no second picker while one is open");
	XCTAssertEqual(self.presented.count, 1u);
}

- (void)testNonForeignKeyCellEditsInPlace
{
	[self selectTable:@"orders"];
	XCTAssertTrue([self shouldEdit:@"note" row:0]);
	XCTAssertTrue([self shouldEdit:@"id" row:0]);
	XCTAssertNil(self.picker);
}

- (void)testMultiColumnAndBinaryKeysEditInPlace
{
	[self selectTable:@"pairs"];
	XCTAssertTrue([self shouldEdit:@"a" row:0]);
	XCTAssertTrue([self shouldEdit:@"b" row:0]);
	[self selectTable:@"blobrefs"];
	XCTAssertTrue([self shouldEdit:@"k" row:0]);
	XCTAssertNil(self.picker);
	XCTAssertEqualObjects(self.content.foreignKeyReferences[@"k"][@"binary"], @YES);
}

- (void)testPreferenceOffEditsInPlace
{
	[self.scratch setBool:NO forKey:@"ForeignKeyPickerEnabled"];
	[self selectTable:@"orders"];
	XCTAssertTrue([self shouldEdit:@"customer_id" row:0]);
	XCTAssertNil(self.picker);

	// The sheet has no Choose… either
	[self.scratch setBool:YES forKey:@"EditInSheetEnabled"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:0]);
	SPPostgresFieldEditorSheet *sheet = [SPPostgresFieldEditorSheet openSheetOnWindow:[[self grid] window]];
	XCTAssertNotNil(sheet);
	id fieldEditor = [sheet valueForKey:@"fieldEditor"];
	NSButton *choose = [fieldEditor valueForKey:@"editSheetChooseButton"];
	XCTAssertTrue(choose == nil || choose.hidden);
	[fieldEditor closeEditSheet:[fieldEditor valueForKey:@"editSheetCancelButton"]];
	XCTAssertTrue([self spinUntil:^BOOL{ return [SPPostgresFieldEditorSheet openSheetOnWindow:[[self grid] window]] == nil; } timeout:5]);
}

#pragma mark - Outcomes

- (void)testChoosePutsKeyInEditorAndReturnSaves
{
	[self selectTable:@"orders"];
	NSInteger row = [self rowWhereColumn:@"id" is:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	[self selectKey:@"3" inPicker:picker];
	[picker choose];
	XCTAssertNotNil([[self grid] currentEditor], @"the cell is being edited");
	XCTAssertEqual([self grid].editedRow, row);
	XCTAssertEqual([self grid].editedColumn, (NSInteger)[[[self grid] tableColumns] indexOfObject:[self tableColumnNamed:@"customer_id"]]);
	XCTAssertEqualObjects([[[self grid] currentEditor] string], @"3");
	XCTAssertEqualObjects([self serverValue:@"SELECT customer_id::text FROM sp_fkp.orders WHERE id = 10"], @"1", @"not saved yet");
	[self endEditing];
	XCTAssertEqualObjects([self serverValue:@"SELECT customer_id::text FROM sp_fkp.orders WHERE id = 10"], @"3");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts valueForKey:@"informativeText"]);
}

- (void)testNullPutsPlaceholderInEditor
{
	[self selectTable:@"orders"];
	NSInteger row = [self rowWhereColumn:@"id" is:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	[[self loadedPicker] chooseNull];
	XCTAssertEqualObjects([[[self grid] currentEditor] string], @"NULL");
	[self endEditing];
	XCTAssertEqualObjects([self serverValue:@"SELECT (customer_id IS NULL)::text FROM sp_fkp.orders WHERE id = 10"], @"true");
}

- (void)testTypeValueOpensEditorOnCurrentValue
{
	[self selectTable:@"orders"];
	NSInteger row = [self rowWhereColumn:@"id" is:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	[[self loadedPicker] typeValue];
	XCTAssertNotNil([[self grid] currentEditor]);
	XCTAssertEqualObjects([[[self grid] currentEditor] string], @"1");
	XCTAssertEqual([self grid].editedRow, row);
}

- (void)testCancelLeavesCellNotEditing
{
	[self selectTable:@"orders"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:0]);
	[[self loadedPicker] cancel];
	XCTAssertNil([[self grid] currentEditor]);
	XCTAssertEqualObjects([self serverValue:@"SELECT customer_id::text FROM sp_fkp.orders WHERE id = 10"], @"1");
	// A new picker opens afterwards
	XCTAssertFalse([self shouldEdit:@"customer_id" row:0]);
	XCTAssertEqual(self.presented.count, 2u);
}

- (void)testSelfReferencingKey
{
	[self selectTable:@"employees"];
	NSInteger row = [self rowWhereColumn:@"id" is:@"3"];
	XCTAssertFalse([self shouldEdit:@"manager_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	XCTAssertEqualObjects([[picker.resultsTable tableColumns] valueForKey:@"identifier"], (@[@"id", @"manager_id", @"name"]));
	[self selectKey:@"2" inPicker:picker];
	[picker choose];
	XCTAssertEqual([self grid].editedRow, row);
	[self endEditing];
	XCTAssertEqualObjects([self serverValue:@"SELECT manager_id::text FROM sp_fkp.employees WHERE id = 3"], @"2");
	XCTAssertEqualObjects([self serverValue:@"SELECT manager_id::text FROM sp_fkp.employees WHERE id = 2"], @"1");
}

- (void)testChoiceAfterTableSwitchIsDropped
{
	[self selectTable:@"orders"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:[self rowWhereColumn:@"id" is:@"10"]]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	[self selectTable:@"employees"];
	[self selectKey:@"2" inPicker:picker];
	[picker choose];
	XCTAssertNil([[self grid] currentEditor]);
	[self waitForTab];
	XCTAssertEqualObjects([self serverValue:@"SELECT customer_id::text FROM sp_fkp.orders WHERE id = 10"], @"1");
	XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(coalesce(manager_id::text, '-'), ',' ORDER BY id) FROM sp_fkp.employees"], @"-,1,1");
}

- (void)testChoiceAfterReloadNeverLandsOnAnotherRow
{
	[self selectTable:@"orders"];
	XCTAssertEqual([self rowWhereColumn:@"id" is:@"10"], 0);
	XCTAssertFalse([self shouldEdit:@"customer_id" row:0]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	// Another order of the same customer now sorts first
	[self run:@"INSERT INTO sp_fkp.orders VALUES (9, 1, 'z')"];
	[self.content reload];
	[self waitForTab];
	XCTAssertEqual([self rowWhereColumn:@"id" is:@"9"], 0);
	[self selectKey:@"3" inPicker:picker];
	[picker choose];
	[self waitForTab];
	if ([[self grid] currentEditor]) {
		XCTAssertEqual([self grid].editedRow, [self rowWhereColumn:@"id" is:@"10"], @"only ever the row it was opened on");
		[[self grid] abortEditing];
	}
	XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(id || ':' || coalesce(customer_id::text, '-'), ',' ORDER BY id) FROM sp_fkp.orders"], @"9:1,10:1,11:-");
}

/// Choose… covers none of the sheet's visible controls.
- (void)assertChooseButtonClear:(NSButton *)choose
{
	for (NSView *sibling in [[choose superview] subviews]) {
		if (sibling == choose || [sibling isHidden] || ![sibling isKindOfClass:[NSControl class]]) continue;
		XCTAssertFalse(NSIntersectsRect([sibling frame], [choose frame]), @"Choose… overlaps %@", sibling);
	}
	XCTAssertTrue(NSContainsRect([[choose superview] bounds], [choose frame]));
}

- (void)testSheetChooseReplacesSheetText
{
	[self.scratch setBool:YES forKey:@"EditInSheetEnabled"];
	[self selectTable:@"orders"];
	NSInteger row = [self rowWhereColumn:@"id" is:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	SPPostgresFieldEditorSheet *sheet = [SPPostgresFieldEditorSheet openSheetOnWindow:[[self grid] window]];
	XCTAssertNotNil(sheet);
	id fieldEditor = [sheet valueForKey:@"fieldEditor"];
	NSButton *choose = [fieldEditor valueForKey:@"editSheetChooseButton"];
	XCTAssertNotNil(choose);
	XCTAssertFalse(choose.hidden);
	XCTAssertEqualObjects(choose.title, @"Choose…");
	[self assertChooseButtonClear:choose];
	[choose performClick:nil];
	SPForeignKeyPicker *picker = [self loadedPicker];
	XCTAssertEqual(picker.currentValueRow, 0);
	[self selectKey:@"2" inPicker:picker];
	[picker choose];
	NSTextView *text = [fieldEditor valueForKey:@"editTextView"];
	XCTAssertEqualObjects(text.string, @"2");
	XCTAssertEqualObjects([self serverValue:@"SELECT customer_id::text FROM sp_fkp.orders WHERE id = 10"], @"1", @"not saved until OK");
	[fieldEditor closeEditSheet:[fieldEditor valueForKey:@"editSheetOkButton"]];
	XCTAssertTrue([self spinUntil:^BOOL{ return [SPPostgresFieldEditorSheet openSheetOnWindow:[[self grid] window]] == nil; } timeout:5]);
	[self waitForTab];
	XCTAssertEqualObjects([self serverValue:@"SELECT customer_id::text FROM sp_fkp.orders WHERE id = 10"], @"2");

	// A cell that isn't a foreign key: no Choose…
	XCTAssertFalse([self shouldEdit:@"note" row:row]);
	sheet = [SPPostgresFieldEditorSheet openSheetOnWindow:[[self grid] window]];
	fieldEditor = [sheet valueForKey:@"fieldEditor"];
	choose = [fieldEditor valueForKey:@"editSheetChooseButton"];
	XCTAssertTrue(choose == nil || choose.hidden);
	[fieldEditor closeEditSheet:[fieldEditor valueForKey:@"editSheetCancelButton"]];
}

@end
