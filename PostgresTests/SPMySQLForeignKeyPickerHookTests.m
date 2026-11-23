#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "../Source/SPWindowController.h"
#import "../Source/SPForeignKeyPicker.h"
#import "../Source/SPTextAndLinkCell.h"

@interface NSObject (SPMySQLForeignKeyPickerHookTests)
- (id)connectionController;
- (void)closeEditSheet:(id)sender;
- (void)initiateConnection:(id)sender;
- (id)getConnection;
- (BOOL)isConnected;
- (BOOL)isWorking;
- (id)queryString:(NSString *)query;
- (NSArray *)getRowAsArray;
- (BOOL)queryErrored;
- (NSString *)lastErrorMessage;
- (void)loadTable:(NSString *)table ofType:(NSInteger)type;
- (void)viewContent:(id)sender;
- (id)tableContentInstance;
- (void)updateTables:(id)sender;
- (void)reloadTable:(id)sender;
- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (void)setForeignKeyPickerPresenter:(void (^)(SPForeignKeyPicker *picker, NSView *view, NSRect rect))presenter;
- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (void)pickValueAtRow:(NSInteger)row column:(NSUInteger)column;
@end

/**
 * MySQL's Content view opening the foreign key picker on a single-column, non-binary foreign key cell, on the
 * throwaway docker container sp-mysql8 (127.0.0.1:55438, user sp_test, database sp_test; see
 * SPMySQLFieldEditorSheetTests), skipped when it isn't running. InnoDB tables fkp_*, made and dropped one by one here.
 * Preferences go in the volatile argument domain (never saved).
 */
@interface SPMySQLForeignKeyPickerHookTests : XCTestCase
@property (strong) id document;
@property (strong) id content;
@property (strong) NSTableView *grid;
@property (strong) SPForeignKeyPicker *picker;
@property (strong) NSMutableArray *presented;
@end

@implementation SPMySQLForeignKeyPickerHookTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition()) {
		if ([end timeIntervalSinceNow] < 0) return NO;
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	return YES;
}

- (void)spin:(NSTimeInterval)seconds
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

/// Sets preferences in the volatile argument domain for this test only.
- (void)setPreferences:(NSDictionary *)values
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *domain = [([prefs volatileDomainForName:NSArgumentDomain] ?: @{}) mutableCopy];
	[domain addEntriesFromDictionary:values];
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
}

- (void)run:(NSString *)sql
{
	id connection = [self.document getConnection];
	[connection queryString:sql];
	XCTAssertFalse([connection queryErrored], @"%@: %@", sql, [connection lastErrorMessage]);
}

- (id)value:(NSString *)sql
{
	return [[[[self.document getConnection] queryString:sql] getRowAsArray] firstObject];
}

- (void)dropFixture:(id)connection
{
	for (NSString *table in @[@"fkp_orders", @"fkp_customers", @"fkp_pairs", @"fkp_pairs_ref", @"fkp_blobrefs", @"fkp_blobs", @"fkp_employees"]) {
		[connection queryString:[NSString stringWithFormat:@"DROP TABLE IF EXISTS %@", table]];
	}
}

- (void)setUp
{
	[super setUp];
	self.continueAfterFailure = NO;
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	[self setPreferences:@{@"EditInSheetEnabled": @NO, @"ForeignKeyPickerEnabled": @YES}];

	SPWindowController *controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	[controller showWindow:nil];
	id mysql = [controller addNewConnection];
	self.document = mysql;
	[self spin:0.3];
	__weak SPMySQLForeignKeyPickerHookTests *weakSelf = self;
	[self addTeardownBlock:^{
		[weakSelf.picker cancel];
		weakSelf.picker = nil;
		NSWindow *window = [controller window];
		while (window.attachedSheet) [window endSheet:window.attachedSheet];
		if ([[mysql getConnection] isConnected]) [weakSelf dropFixture:[mysql getConnection]];
		NSTabView *tabView = [controller valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
		[weakSelf spin:0.5];
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];

	id form = [mysql connectionController];
	[form setValue:@0 forKey:@"type"]; // SPTCPIPConnection
	[form setValue:@"127.0.0.1" forKey:@"host"];
	[form setValue:@"55438" forKey:@"port"];
	[form setValue:@"sp_test" forKey:@"user"];
	[form setValue:@"sptest" forKey:@"password"];
	[form setValue:@"sp_test" forKey:@"database"];
	[form initiateConnection:nil];
	if (![self spinUntil:^BOOL{ return [[mysql getConnection] isConnected] && ![mysql isWorking]; } timeout:20]) {
		for (NSWindow *window in [NSApp windows]) if ([window attachedSheet]) [window endSheet:[window attachedSheet]];
		return;
	}

	[self dropFixture:[mysql getConnection]];
	[self run:@"CREATE TABLE fkp_customers (id INT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_customers VALUES (1, 'Ann'), (2, 'Bob'), (3, 'Cy')"];
	[self run:@"CREATE TABLE fkp_orders (id INT PRIMARY KEY, customer_id INT NULL, note VARCHAR(50), status ENUM('new', 'done') NOT NULL DEFAULT 'new', "
			   "tags SET('a', 'b'), FOREIGN KEY (customer_id) REFERENCES fkp_customers (id)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_orders VALUES (10, 1, 'a', 'new', 'a'), (11, NULL, 'b', 'done', NULL)"];
	[self run:@"CREATE TABLE fkp_pairs_ref (a INT, b INT, PRIMARY KEY (a, b)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_pairs_ref VALUES (1, 1)"];
	[self run:@"CREATE TABLE fkp_pairs (id INT PRIMARY KEY, a INT, b INT, FOREIGN KEY (a, b) REFERENCES fkp_pairs_ref (a, b)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_pairs VALUES (1, 1, 1)"];
	[self run:@"CREATE TABLE fkp_blobs (k VARBINARY(16) PRIMARY KEY) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_blobs VALUES ('ab')"];
	[self run:@"CREATE TABLE fkp_blobrefs (id INT PRIMARY KEY, k VARBINARY(16), FOREIGN KEY (k) REFERENCES fkp_blobs (k)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_blobrefs VALUES (1, 'ab')"];
	[self run:@"CREATE TABLE fkp_employees (id INT PRIMARY KEY, manager_id INT NULL, name VARCHAR(50), FOREIGN KEY (manager_id) REFERENCES fkp_employees (id)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO fkp_employees VALUES (1, NULL, 'Boss'), (2, 1, 'Ann'), (3, 1, 'Bob')"];
	[[mysql valueForKey:@"tablesListInstance"] updateTables:nil];
	[[controller window] makeKeyAndOrderFront:nil];

	self.content = [mysql tableContentInstance];
	self.grid = [self.content valueForKey:@"tableContentView"];
	NSMutableArray *presented = [NSMutableArray array];
	self.presented = presented;
	[self.content setForeignKeyPickerPresenter:^(SPForeignKeyPicker *picker, NSView *view, NSRect rect) {
		weakSelf.picker = picker;
		[presented addObject:picker];
	}];
}

- (BOOL)connected
{
	return [[self.document getConnection] isConnected] && self.grid;
}

- (void)showTable:(NSString *)table rows:(NSInteger)rows
{
	[self.document loadTable:table ofType:0]; // SPTableTypeTable
	[self.document viewContent:nil];
	__weak SPMySQLForeignKeyPickerHookTests *weakSelf = self;
	XCTAssertTrue([self spinUntil:^BOOL{ return ![weakSelf.document isWorking] && [weakSelf.grid numberOfRows] == rows && [weakSelf column:@"id"]; } timeout:20], @"%@", table);
}

- (NSTableColumn *)column:(NSString *)name
{
	for (NSTableColumn *column in [self.grid tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:name]) return column;
	}
	return nil;
}

- (NSInteger)rowWithId:(NSString *)value
{
	for (NSInteger row = 0; row < [self.grid numberOfRows]; row++) {
		if ([[self.content tableView:self.grid objectValueForTableColumn:[self column:@"id"] row:row] isEqual:value]) return row;
	}
	XCTFail(@"no row %@", value);
	return -1;
}

- (BOOL)shouldEdit:(NSString *)column row:(NSInteger)row
{
	[self.grid selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	[[self.grid window] makeFirstResponder:self.grid];
	return [self.content tableView:self.grid shouldEditTableColumn:[self column:column] row:row];
}

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

- (NSString *)editorText
{
	return [[self.grid currentEditor] string];
}

/// Ends the in-place edit as clicking elsewhere does, which saves it.
- (void)endEditing
{
	XCTAssertNotNil([self.grid currentEditor]);
	[[self.grid window] makeFirstResponder:self.grid];
	[self.grid deselectAll:nil];
	[self spin:0.3];
	XCTAssertTrue([self spinUntil:^BOOL{ return ![self.document isWorking]; } timeout:10]);
}

#define SKIP_WITHOUT_SERVER if (![self connected]) { XCTSkip(@"no MySQL test server on 127.0.0.1:55438 (docker sp-mysql8)"); }

#pragma mark - Opening

- (void)testEditingForeignKeyCellOpensPicker
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	XCTAssertEqualObjects([[picker.resultsTable tableColumns] valueForKey:@"identifier"], (@[@"id", @"name"]));
	XCTAssertEqualObjects(picker.rows, (@[@[@"1", @"Ann"], @[@"2", @"Bob"], @[@"3", @"Cy"]]));
	XCTAssertEqual(picker.currentValueRow, 0);
	XCTAssertEqualObjects(picker.titleField.stringValue, @"Choose fkp_customers.id · sp_test.fkp_customers");
	XCTAssertFalse(picker.nullButton.hidden);
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row], @"no second picker while one is open");
	XCTAssertEqual(self.presented.count, 1u);
}

- (SPTextAndLinkCell *)drawnCell:(NSString *)name row:(NSInteger)row
{
	NSTableColumn *column = [self column:name];
	SPTextAndLinkCell *cell = [column dataCellForRow:row];
	XCTAssertTrue([cell isKindOfClass:[SPTextAndLinkCell class]], @"%@ is a %@", name, [cell class]);
	[self.content tableView:self.grid willDisplayCell:cell forTableColumn:column row:row];
	return cell;
}

- (void)testPickerIconOnForeignKeyCellsNullToo
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	XCTAssertTrue([self drawnCell:@"customer_id" row:[self rowWithId:@"10"]].pickerIconActive);
	XCTAssertTrue([self drawnCell:@"customer_id" row:[self rowWithId:@"11"]].pickerIconActive, @"NULL: pick a value");
	XCTAssertFalse([self drawnCell:@"note" row:0].pickerIconActive, @"not a foreign key");
}

- (void)testNoPickerIconOnCompositeOrBinaryKeysOrWithThePreferenceOff
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_pairs" rows:1];
	XCTAssertFalse([self drawnCell:@"a" row:0].pickerIconActive, @"a key over two columns");
	[self showTable:@"fkp_blobrefs" rows:1];
	XCTAssertFalse([self drawnCell:@"k" row:0].pickerIconActive, @"a binary key");
	[self setPreferences:@{@"ForeignKeyPickerEnabled": @NO}];
	[self showTable:@"fkp_orders" rows:2];
	XCTAssertFalse([self drawnCell:@"customer_id" row:0].pickerIconActive, @"the picker preference off");
}

- (void)testPickerIconOpensThePickerAndChooseEditsTheCell
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	[self.content pickValueAtRow:row column:(NSUInteger)[[[self column:@"customer_id"] identifier] integerValue]];
	XCTAssertEqual(self.presented.count, 1u, @"the picker opened");
	SPForeignKeyPicker *picker = [self loadedPicker];
	[self selectKey:@"3" inPicker:picker];
	[picker choose];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self.grid currentEditor] != nil; } timeout:5]);
	XCTAssertEqualObjects([[self.grid currentEditor] string], @"3", @"the key is in the cell's editor, Return saves it");
	[self.grid abortEditing];
}

- (void)testNonForeignKeyCellEditsInPlace
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	XCTAssertTrue([self shouldEdit:@"note" row:0]);
	XCTAssertTrue([self shouldEdit:@"id" row:0]);
	XCTAssertNil(self.picker);
}

- (void)testEnumAndSetCellsStillUseComboBox
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	XCTAssertTrue([[[self column:@"status"] dataCell] isKindOfClass:[NSComboBoxCell class]]);
	XCTAssertTrue([[[self column:@"tags"] dataCell] isKindOfClass:[NSComboBoxCell class]]);
	XCTAssertTrue([self shouldEdit:@"status" row:0]);
	XCTAssertTrue([self shouldEdit:@"tags" row:0]);
	XCTAssertNil(self.picker);
}

- (void)testMultiColumnAndBinaryKeysEditInPlace
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_pairs" rows:1];
	XCTAssertTrue([self shouldEdit:@"a" row:0]);
	XCTAssertTrue([self shouldEdit:@"b" row:0]);
	[self showTable:@"fkp_blobrefs" rows:1];
	[self shouldEdit:@"k" row:0]; // in place, or the sheet for a value shown as hex: never the picker
	XCTAssertNil(self.picker);
	NSWindow *window = [self.grid window];
	while (window.attachedSheet) {
		id sheet = [self.content valueForKey:@"fieldEditor"];
		if (sheet) [sheet closeEditSheet:[sheet valueForKey:@"editSheetCancelButton"]];
		else [window endSheet:window.attachedSheet];
		[self spin:0.2];
	}
}

- (void)testPreferenceOffEditsInPlace
{
	SKIP_WITHOUT_SERVER
	[self setPreferences:@{@"ForeignKeyPickerEnabled": @NO}];
	[self showTable:@"fkp_orders" rows:2];
	XCTAssertTrue([self shouldEdit:@"customer_id" row:0]);
	XCTAssertNil(self.picker);

	// The sheet has no Choose… either
	[self setPreferences:@{@"EditInSheetEnabled": @YES}];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:0]);
	id sheet = [self.content valueForKey:@"fieldEditor"];
	XCTAssertNotNil(sheet);
	NSButton *choose = [sheet valueForKey:@"editSheetChooseButton"];
	XCTAssertTrue(choose == nil || choose.hidden);
	[sheet closeEditSheet:[sheet valueForKey:@"editSheetCancelButton"]];
}

#pragma mark - Outcomes

- (void)testChoosePutsKeyInEditorAndReturnSaves
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	[self selectKey:@"3" inPicker:picker];
	[picker choose];
	XCTAssertNotNil([self.grid currentEditor], @"the cell is being edited");
	XCTAssertEqual(self.grid.editedRow, row);
	XCTAssertEqual(self.grid.editedColumn, (NSInteger)[[self.grid tableColumns] indexOfObject:[self column:@"customer_id"]]);
	XCTAssertEqualObjects([self editorText], @"3");
	XCTAssertEqualObjects([self value:@"SELECT CAST(customer_id AS CHAR) FROM fkp_orders WHERE id = 10"], @"1", @"not saved yet");
	[self endEditing];
	XCTAssertEqualObjects([self value:@"SELECT CAST(customer_id AS CHAR) FROM fkp_orders WHERE id = 10"], @"3");
}

- (void)testNullPutsPlaceholderInEditor
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	[[self loadedPicker] chooseNull];
	NSString *nullText = [[NSUserDefaults standardUserDefaults] stringForKey:@"NullValue"] ?: @"NULL";
	XCTAssertEqualObjects([self editorText], nullText);
	[self endEditing];
	XCTAssertEqualObjects([self value:@"SELECT customer_id IS NULL FROM fkp_orders WHERE id = 10"], @"1");
}

- (void)testTypeValueOpensEditorOnCurrentValue
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	[[self loadedPicker] typeValue];
	XCTAssertNotNil([self.grid currentEditor]);
	XCTAssertEqual(self.grid.editedRow, row);
	XCTAssertEqualObjects([self editorText], @"1");
	[self.grid abortEditing];
}

- (void)testCancelLeavesCellNotEditing
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	[[self loadedPicker] cancel];
	XCTAssertNil([self.grid currentEditor]);
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row], @"a new picker opens");
	XCTAssertEqual(self.presented.count, 2u);
	XCTAssertEqualObjects([self value:@"SELECT CAST(customer_id AS CHAR) FROM fkp_orders WHERE id = 10"], @"1");
}

- (void)testSelfReferencingKey
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_employees" rows:3];
	NSInteger row = [self rowWithId:@"3"];
	XCTAssertFalse([self shouldEdit:@"manager_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	XCTAssertEqualObjects([[picker.resultsTable tableColumns] valueForKey:@"identifier"], (@[@"id", @"manager_id", @"name"]));
	[self selectKey:@"2" inPicker:picker];
	[picker choose];
	XCTAssertEqual(self.grid.editedRow, row);
	[self endEditing];
	XCTAssertEqualObjects([self value:@"SELECT CAST(manager_id AS CHAR) FROM fkp_employees WHERE id = 3"], @"2");
	XCTAssertEqualObjects([self value:@"SELECT CAST(manager_id AS CHAR) FROM fkp_employees WHERE id = 2"], @"1");
}

- (void)testChoiceAfterTableSwitchIsDropped
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:[self rowWithId:@"10"]]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	[self showTable:@"fkp_employees" rows:3];
	[self selectKey:@"2" inPicker:picker];
	[picker choose];
	XCTAssertNil([self.grid currentEditor]);
	[self spin:0.3];
	XCTAssertEqualObjects([self value:@"SELECT CAST(customer_id AS CHAR) FROM fkp_orders WHERE id = 10"], @"1");
	XCTAssertEqualObjects([self value:@"SELECT GROUP_CONCAT(IFNULL(manager_id, '-') ORDER BY id) FROM fkp_employees"], @"-,1,1");
}

- (void)testChoiceAfterReloadPuttingAnotherRowThereIsDropped
{
	SKIP_WITHOUT_SERVER
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertEqual(row, 0);
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	SPForeignKeyPicker *picker = [self loadedPicker];
	// Another order of the same customer now sorts first: row 0 holds the same customer_id, but another order
	[self run:@"INSERT INTO fkp_orders VALUES (9, 1, 'z', 'new', NULL)"];
	[self.content reloadTable:nil];
	__weak SPMySQLForeignKeyPickerHookTests *weakSelf = self;
	XCTAssertTrue([self spinUntil:^BOOL{ return ![weakSelf.document isWorking] && [weakSelf.grid numberOfRows] == 3; } timeout:20]);
	XCTAssertEqualObjects([self.content tableView:self.grid objectValueForTableColumn:[self column:@"id"] row:0], @"9");
	[self selectKey:@"3" inPicker:picker];
	[picker choose];
	XCTAssertNil([self.grid currentEditor]);
	[self spin:0.3];
	XCTAssertEqualObjects([self value:@"SELECT GROUP_CONCAT(CONCAT(id, ':', IFNULL(customer_id, '-')) ORDER BY id) FROM fkp_orders"], @"9:1,10:1,11:-");
}

/// Choose… covers none of the sheet's visible controls.
- (void)assertChooseButtonClear:(NSButton *)choose
{
	for (NSView *sibling in [[choose superview] subviews]) {
		if (sibling == choose || [sibling isHidden] || ![sibling isKindOfClass:[NSControl class]]) continue;
		XCTAssertFalse(NSIntersectsRect([sibling frame], [choose frame]), @"Choose… overlaps %@ %@", sibling, [sibling respondsToSelector:@selector(title)] ? [(id)sibling title] : @"");
	}
	XCTAssertTrue(NSContainsRect([[choose superview] bounds], [choose frame]));
}

- (void)testSheetChooseReplacesSheetText
{
	SKIP_WITHOUT_SERVER
	[self setPreferences:@{@"EditInSheetEnabled": @YES}];
	[self showTable:@"fkp_orders" rows:2];
	NSInteger row = [self rowWithId:@"10"];
	XCTAssertFalse([self shouldEdit:@"customer_id" row:row]);
	id sheet = [self.content valueForKey:@"fieldEditor"];
	XCTAssertNotNil(sheet);
	NSButton *choose = [sheet valueForKey:@"editSheetChooseButton"];
	XCTAssertNotNil(choose);
	XCTAssertFalse(choose.hidden);
	[self assertChooseButtonClear:choose];
	[choose performClick:nil];
	SPForeignKeyPicker *picker = [self loadedPicker];
	XCTAssertEqual(picker.currentValueRow, 0);
	[self selectKey:@"2" inPicker:picker];
	[picker choose];
	NSTextView *text = [sheet valueForKey:@"editTextView"];
	XCTAssertEqualObjects(text.string, @"2");
	XCTAssertEqualObjects([self value:@"SELECT CAST(customer_id AS CHAR) FROM fkp_orders WHERE id = 10"], @"1", @"not saved until OK");
	[sheet closeEditSheet:[sheet valueForKey:@"editSheetOkButton"]];
	[self spin:0.3];
	XCTAssertEqualObjects([self.content tableView:self.grid objectValueForTableColumn:[self column:@"customer_id"] row:row], @"2");
	// As any sheet edit, saved when the row is left
	[[self.grid window] makeFirstResponder:self.grid];
	[self.grid deselectAll:nil];
	[self spin:0.3];
	XCTAssertTrue([self spinUntil:^BOOL{ return ![self.document isWorking]; } timeout:10]);
	XCTAssertEqualObjects([self value:@"SELECT CAST(customer_id AS CHAR) FROM fkp_orders WHERE id = 10"], @"2");

	// A cell that isn't a foreign key: no Choose…
	XCTAssertFalse([self shouldEdit:@"note" row:row]);
	sheet = [self.content valueForKey:@"fieldEditor"];
	XCTAssertNotNil(sheet);
	choose = [sheet valueForKey:@"editSheetChooseButton"];
	XCTAssertTrue(choose == nil || choose.hidden);
	[sheet closeEditSheet:[sheet valueForKey:@"editSheetCancelButton"]];
}

@end
