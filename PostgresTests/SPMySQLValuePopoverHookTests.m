//
//  SPMySQLValuePopoverHookTests.m
//  Sequel Plus
//
//  The MySQL grids' value icon and popover: Content, then Query results. On the throwaway docker container sp-mysql8
//  (127.0.0.1:55438, user sp_test, database sp_test; see SPMySQLFieldEditorSheetTests), skipped when it isn't running.
//  Tables vp_*, made and dropped here. Preferences go in the volatile argument domain (never saved).
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../Source/SPWindowController.h"
#import "../Source/SPTextAndLinkCell.h"
#import "../Source/SPValuePopover.h"

@interface NSObject (SPMySQLValuePopoverHookTests)
- (id)connectionController;
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
- (void)viewQuery:(id)sender;
- (id)tableContentInstance;
- (NSTabViewItem *)parentTabViewItem;
- (id)addNewConnection;
- (id)customQueryInstance;
- (void)updateTables:(id)sender;
- (void)reloadTable:(id)sender;
- (void)performQueries:(NSArray *)queries withCallback:(SEL)callback;
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (id)cellDataAtRow:(NSUInteger)row column:(NSUInteger)column;
- (void)setValuePopoverPresenter:(void (^)(SPValuePopover *popover, NSView *view, NSRect rect))presenter;
- (void)showValueAtRow:(NSInteger)row column:(NSUInteger)column;
@end

@interface SPMySQLValuePopoverHookTests : XCTestCase
@property (strong) id document;
@property (strong) SPWindowController *controller;
@property (strong) id content;
@property (strong) NSTableView *grid;
@property (strong) NSMutableArray<SPValuePopover *> *presented;
@property (copy) NSString *longText;
@end

static NSUInteger SPVPCellDataCalls = 0;

@implementation NSObject (SPMySQLValuePopoverCount)
- (id)sp_vp_cellDataAtRow:(NSUInteger)row column:(NSUInteger)column
{
	SPVPCellDataCalls++;
	return [self sp_vp_cellDataAtRow:row column:column]; // the original (swapped)
}
@end

@implementation SPMySQLValuePopoverHookTests

/// How many whole cell values (SPDataStorage -cellDataAtRow:column:) block builds.
- (NSUInteger)wholeValuesBuiltDuring:(void (^)(void))block
{
	Class storage = NSClassFromString(@"SPDataStorage");
	Method counting = class_getInstanceMethod([NSObject class], @selector(sp_vp_cellDataAtRow:column:));
	class_addMethod(storage, @selector(sp_vp_cellDataAtRow:column:), method_getImplementation(counting), method_getTypeEncoding(counting));
	Method original = class_getInstanceMethod(storage, @selector(cellDataAtRow:column:));
	Method replacement = class_getInstanceMethod(storage, @selector(sp_vp_cellDataAtRow:column:));
	method_exchangeImplementations(original, replacement);
	SPVPCellDataCalls = 0;
	block();
	NSUInteger calls = SPVPCellDataCalls;
	method_exchangeImplementations(original, replacement);
	return calls;
}

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
	[connection queryString:@"DROP VIEW IF EXISTS vp_view"];
	for (NSString *table in @[@"vp_notes", @"vp_lazy", @"vp_keys"]) {
		[connection queryString:[NSString stringWithFormat:@"DROP TABLE IF EXISTS %@", table]];
	}
}

static NSString *SPRepeated(NSString *unit, NSUInteger length)
{
	return [@"" stringByPaddingToLength:length withString:unit startingAtIndex:0];
}

- (void)setUp
{
	[super setUp];
	self.continueAfterFailure = NO;
	self.longText = [NSString stringWithFormat:@"{\"k\": \"%@\"}", SPRepeated(@"a", 200)]; // 209 characters, valid JSON
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	[self setPreferences:@{@"EditInSheetEnabled": @NO, @"LoadBlobsAsNeeded": @NO, @"ReloadAfterEditingRow": @YES}];

	SPWindowController *controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	[controller showWindow:nil];
	id mysql = [controller addNewConnection];
	self.document = mysql;
	self.controller = controller;
	[self spin:0.3];
	__weak SPMySQLValuePopoverHookTests *weakSelf = self;
	[self addTeardownBlock:^{
		for (SPValuePopover *popover in weakSelf.presented) [popover closeDiscarding];
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
	[self run:@"CREATE TABLE vp_notes (id INT PRIMARY KEY, body TEXT NULL, doc JSON NULL, data BLOB NULL, bin VARBINARY(300) NULL, "
			   "CONSTRAINT vp_body_ok CHECK (body IS NULL OR body <> 'forbidden')) ENGINE=InnoDB"];
	[self run:[NSString stringWithFormat:@"INSERT INTO vp_notes VALUES (1, '%@', '%@', REPEAT('x', 300), REPEAT('y', 250))", self.longText, self.longText]];
	[self run:[NSString stringWithFormat:@"INSERT INTO vp_notes VALUES (2, '%@', NULL, NULL, NULL)", SPRepeated(@"c", 200)]];
	[self run:@"INSERT INTO vp_notes VALUES (3, NULL, NULL, NULL, NULL)"];
	[self run:@"CREATE VIEW vp_view AS SELECT id, body FROM vp_notes"];
	[self run:@"CREATE TABLE vp_keys (code VARCHAR(40) PRIMARY KEY, label VARCHAR(40)) ENGINE=InnoDB"];
	[self run:@"INSERT INTO vp_keys VALUES ('abc-123', 'Ann')"];
	[[mysql valueForKey:@"tablesListInstance"] updateTables:nil];
	[[controller window] makeKeyAndOrderFront:nil];

	self.content = [mysql tableContentInstance];
	self.grid = [self.content valueForKey:@"tableContentView"];
	NSMutableArray *presented = [NSMutableArray array];
	self.presented = presented;
	void (^presenter)(SPValuePopover *, NSView *, NSRect) = ^(SPValuePopover *popover, NSView *view, NSRect rect) {
		popover.discardConfirmer = ^BOOL(NSString *column) { return YES; };
		[presented addObject:popover];
	};
	[self.content setValuePopoverPresenter:presenter];
	[[mysql customQueryInstance] setValuePopoverPresenter:presenter];
}

- (BOOL)connected
{
	return [[self.document getConnection] isConnected] && self.grid;
}

- (void)showTable:(NSString *)table ofType:(NSInteger)type rows:(NSInteger)rows
{
	[self showTable:table ofType:type rows:rows withColumn:@"id"];
}

- (void)showTable:(NSString *)table ofType:(NSInteger)type rows:(NSInteger)rows withColumn:(NSString *)columnName
{
	[self.document loadTable:table ofType:type];
	[self.document viewContent:nil];
	__weak SPMySQLValuePopoverHookTests *weakSelf = self;
	XCTAssertTrue([self spinUntil:^BOOL{ return ![weakSelf.document isWorking] && [weakSelf.grid numberOfRows] == rows && [weakSelf column:columnName]; } timeout:20], @"%@", table);
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

/// The grid's stored value (its display text is cut short).
- (id)stored:(NSString *)name row:(NSInteger)row
{
	return [[self.content valueForKey:@"tableValues"] cellDataAtRow:(NSUInteger)row column:(NSUInteger)[[[self column:name] identifier] integerValue]];
}

- (SPTextAndLinkCell *)cell:(NSString *)name row:(NSInteger)row
{
	NSTableColumn *column = [self column:name];
	id cell = [column dataCellForRow:row];
	XCTAssertTrue([cell isKindOfClass:[SPTextAndLinkCell class]], @"%@ is a %@", name, [cell class]);
	[self.content tableView:self.grid willDisplayCell:cell forTableColumn:column row:row];
	return cell;
}

- (SPValuePopover *)open:(NSString *)name row:(NSInteger)row
{
	NSUInteger before = self.presented.count;
	[self.content showValueAtRow:row column:(NSUInteger)[[[self column:name] identifier] integerValue]];
	XCTAssertEqual(self.presented.count, before + 1, @"a popover was presented");
	return self.presented.lastObject;
}

- (void)replaceText:(NSString *)text in:(SPValuePopover *)popover
{
	NSTextView *textView = popover.textView;
	[textView setSelectedRange:NSMakeRange(0, [[textView string] length])];
	[textView insertText:text replacementRange:[textView selectedRange]];
}

/// Save, waiting for the tab; YES when the popover closed (saved).
- (BOOL)save:(SPValuePopover *)popover
{
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[popover save];
	__weak SPMySQLValuePopoverHookTests *weakSelf = self;
	[self spinUntil:^BOOL{ return ![weakSelf.document isWorking]; } timeout:20];
	[self spin:0.2];
	return closed;
}

#pragma mark - Content

- (void)testMySQLIconOnEveryTextValue
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	XCTAssertTrue([self cell:@"body" row:[self rowWithId:@"1"]].valueIconActive, @"TEXT, 209 characters");
	XCTAssertTrue([self cell:@"doc" row:[self rowWithId:@"1"]].valueIconActive, @"JSON");
	XCTAssertTrue([self cell:@"body" row:[self rowWithId:@"2"]].valueIconActive, @"200 characters: any length");
	XCTAssertTrue([self cell:@"body" row:[self rowWithId:@"3"]].valueIconActive, @"NULL: it can be edited into a value");
	XCTAssertFalse([self cell:@"data" row:[self rowWithId:@"1"]].valueIconActive, @"BLOB");
	XCTAssertFalse([self cell:@"bin" row:[self rowWithId:@"1"]].valueIconActive, @"VARBINARY");
	XCTAssertFalse([self cell:@"id" row:[self rowWithId:@"1"]].valueIconActive, @"not a text column");
}

- (void)testMySQLNoIconOnPrimaryKeyValues
{
	if (![self connected]) return;
	[self showTable:@"vp_keys" ofType:0 rows:1 withColumn:@"code"];
	NSTableColumn *code = [self column:@"code"], *label = [self column:@"label"];
	XCTAssertNotNil(code);
	SPTextAndLinkCell *codeCell = [code dataCellForRow:0];
	[self.content tableView:self.grid willDisplayCell:codeCell forTableColumn:code row:0];
	XCTAssertFalse(codeCell.valueIconActive, @"a VARCHAR primary key");
	SPTextAndLinkCell *labelCell = [label dataCellForRow:0];
	[self.content tableView:self.grid willDisplayCell:labelCell forTableColumn:label row:0];
	XCTAssertTrue(labelCell.valueIconActive, @"another text column still shows it");
}

- (void)testMySQLLoadWhenNeededShowsIconAndLoadsOnClick
{
	if (![self connected]) return;
	[self setPreferences:@{@"LoadBlobsAsNeeded": @YES}];
	[self showTable:@"vp_notes" ofType:0 rows:3];
	XCTAssertTrue([self cell:@"body" row:[self rowWithId:@"1"]].valueIconActive, @"not loaded yet: the icon still shows");
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	XCTAssertEqualObjects([popover.textView string], self.longText, @"clicking loads the value");
}

- (void)testMySQLNullOpensEmptyAndSavesText
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"3"]];
	XCTAssertEqualObjects([popover.textView string], @"");
	XCTAssertEqualObjects([popover.titleField stringValue], @"body — NULL");
	XCTAssertFalse([popover.saveButton isEnabled]);
	[self replaceText:@"now a value" in:popover];
	XCTAssertTrue([self save:popover]);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 3"], @"now a value");
}

- (void)testMySQLIconOpensRawValue
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	XCTAssertEqualObjects([popover.textView string], self.longText);
	XCTAssertTrue([popover.textView isEditable]);
	XCTAssertEqualObjects([popover.titleField stringValue], @"body — 209 characters");
}

- (void)testMySQLSaveWritesRow
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	[popover formatJSON];
	NSString *pretty = [popover.textView string];
	XCTAssertNotEqualObjects(pretty, self.longText);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], self.longText, @"formatting wrote nothing");
	XCTAssertTrue([self save:popover]);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], pretty);
	XCTAssertEqualObjects([self stored:@"body" row:[self rowWithId:@"1"]], pretty);
	XCTAssertNil([[self.grid window] attachedSheet]);
}

- (void)testSaveFailureKeepsPopoverOpen
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	[self replaceText:@"forbidden" in:popover];
	XCTAssertFalse([self save:popover]);
	XCTAssertTrue([[popover.errorField stringValue] containsString:@"vp_body_ok"], @"%@", [popover.errorField stringValue]);
	XCTAssertEqualObjects([popover.textView string], @"forbidden");
	XCTAssertTrue([popover.saveButton isEnabled]);
	XCTAssertNil([[self.grid window] attachedSheet], @"no alert sheet over the popover");
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], self.longText);
	XCTAssertEqualObjects([self stored:@"body" row:[self rowWithId:@"1"]], self.longText, @"the grid shows the row as stored");

	[self replaceText:@"allowed now" in:popover];
	XCTAssertTrue([self save:popover]);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], @"allowed now");
}

- (void)testMySQLViewTableSavesThroughViewPath
{
	if (![self connected]) return;
	[self showTable:@"vp_view" ofType:1 rows:3]; // SPTableTypeView
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	XCTAssertTrue([popover.textView isEditable]);
	[self replaceText:@"through the view" in:popover];
	XCTAssertTrue([self save:popover]);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], @"through the view");
}

- (void)testMySQLFormatWithoutSaveWritesNothing
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	[popover formatJSON];
	[popover compact];
	[popover cancel];
	[self spin:0.2];
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], self.longText);
	XCTAssertEqualObjects([self stored:@"body" row:[self rowWithId:@"1"]], self.longText);
}

- (void)testMySQLReloadClosesPopover
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[self.content reloadTable:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return closed; } timeout:20]);
}

- (void)testMySQLDrawingDoesNotBuildWholeValues
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	__block BOOL active = NO;
	NSUInteger built = [self wholeValuesBuiltDuring:^{
		active = [self cell:@"body" row:[self rowWithId:@"1"]].valueIconActive;
		(void)[self cell:@"data" row:[self rowWithId:@"1"]];
		(void)[self cell:@"doc" row:[self rowWithId:@"1"]];
	}];
	XCTAssertTrue(active);
	XCTAssertEqual(built, 0u, @"drawing reads previews, never a whole (multi-MB) value");
}

- (void)testMySQLIconAfterSaveWithoutReload
{
	if (![self connected]) return;
	[self setPreferences:@{@"ReloadAfterEditingRow": @NO}];
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	[popover formatJSON];
	XCTAssertTrue([self save:popover]);
	XCTAssertTrue([self cell:@"body" row:[self rowWithId:@"1"]].valueIconActive, @"the edited row's long value still shows it");
}

- (void)testMySQLClosingTheTabClosesPopover
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[[self.controller valueForKey:@"tabView"] removeTabViewItem:[self.document parentTabViewItem]];
	XCTAssertTrue([self spinUntil:^BOOL{ return closed; } timeout:5]);
}

- (void)testMySQLSwitchingTabClosesPopover
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[self.controller addNewConnection];
	XCTAssertTrue([self spinUntil:^BOOL{ return closed; } timeout:5]);
}

- (void)testMySQLSaveOfADeletedRowKeepsPopoverOpen
{
	if (![self connected]) return;
	[self showTable:@"vp_notes" ofType:0 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	[self run:@"DELETE FROM vp_notes WHERE id = 1"]; // by someone else, meanwhile
	[self replaceText:@"edited" in:popover];
	XCTAssertFalse([self save:popover]);
	XCTAssertTrue([[popover.errorField stringValue] hasPrefix:@"No row was changed"], @"%@", [popover.errorField stringValue]);
	XCTAssertEqualObjects([popover.textView string], @"edited", @"text kept");
	XCTAssertNil([[self.grid window] attachedSheet]);
}

- (void)testMySQLViewSaveOfADeletedRowKeepsPopoverOpen
{
	if (![self connected]) return;
	[self showTable:@"vp_view" ofType:1 rows:3];
	SPValuePopover *popover = [self open:@"body" row:[self rowWithId:@"1"]];
	[self run:@"DELETE FROM vp_notes WHERE id = 1"];
	[self replaceText:@"edited" in:popover];
	XCTAssertFalse([self save:popover]);
	XCTAssertGreaterThan([[popover.errorField stringValue] length], 0u);
	XCTAssertNil([[self.grid window] attachedSheet], @"no alert sheet over the popover");
}

#pragma mark - Query results

- (id)query
{
	return [self.document customQueryInstance];
}

- (NSTableView *)queryGrid
{
	return [[self query] valueForKey:@"customQueryView"];
}

- (void)runQuery:(NSString *)sql rows:(NSInteger)rows
{
	[self.document viewQuery:nil];
	[[self query] performQueries:@[sql] withCallback:NULL];
	__weak SPMySQLValuePopoverHookTests *weakSelf = self;
	XCTAssertTrue([self spinUntil:^BOOL{ return ![weakSelf.document isWorking] && [[weakSelf queryGrid] numberOfRows] == rows; } timeout:20], @"%@", sql);
}

- (SPTextAndLinkCell *)queryCell:(NSUInteger)column row:(NSInteger)row
{
	NSTableView *grid = [self queryGrid];
	NSTableColumn *tableColumn = [[grid tableColumns] objectAtIndex:column];
	id cell = [tableColumn dataCellForRow:row];
	XCTAssertTrue([cell isKindOfClass:[SPTextAndLinkCell class]], @"a %@", [cell class]);
	[[self query] tableView:grid willDisplayCell:cell forTableColumn:tableColumn row:row];
	return cell;
}

- (SPValuePopover *)openQueryRow:(NSInteger)row column:(NSUInteger)column
{
	NSUInteger before = self.presented.count;
	[[self query] showValueAtRow:row column:column];
	XCTAssertEqual(self.presented.count, before + 1, @"a popover was presented");
	return self.presented.lastObject;
}

- (void)testMySQLQueryIconOnEveryTextValue
{
	if (![self connected]) return;
	[self runQuery:@"SELECT id, body, data FROM vp_notes ORDER BY id" rows:3];
	XCTAssertTrue([self queryCell:1 row:0].valueIconActive, @"209 characters");
	XCTAssertTrue([self queryCell:1 row:1].valueIconActive, @"200 characters: any length");
	XCTAssertFalse([self queryCell:0 row:0].valueIconActive, @"INT: not a text column");
	XCTAssertTrue([self queryCell:1 row:2].valueIconActive, @"NULL");
	XCTAssertFalse([self queryCell:2 row:0].valueIconActive, @"BLOB");
	SPValuePopover *popover = [self openQueryRow:0 column:1];
	XCTAssertEqualObjects([popover.textView string], self.longText);
}

- (void)testMySQLQueryNoIconOnPrimaryKeyValues
{
	if (![self connected]) return;
	[self runQuery:@"SELECT code, label FROM vp_keys" rows:1];
	XCTAssertFalse([self queryCell:0 row:0].valueIconActive, @"a VARCHAR primary key");
	XCTAssertTrue([self queryCell:1 row:0].valueIconActive);
}

- (void)testMySQLQueryReadOnlyCloseOnly
{
	if (![self connected]) return;
	[self runQuery:@"SELECT CONCAT(body, '') AS b FROM vp_notes WHERE id = 1" rows:1];
	SPValuePopover *popover = [self openQueryRow:0 column:0];
	XCTAssertFalse([popover.textView isEditable]);
	XCTAssertTrue([popover.saveButton isHidden]);
}

- (void)testMySQLQueryEditableSaves
{
	if (![self connected]) return;
	[self runQuery:@"SELECT id, body FROM vp_notes WHERE id = 1" rows:1];
	SPValuePopover *popover = [self openQueryRow:0 column:1];
	XCTAssertTrue([popover.textView isEditable]);
	[popover formatJSON];
	NSString *pretty = [popover.textView string];
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], self.longText, @"formatting wrote nothing");
	XCTAssertTrue([self save:popover]);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], pretty);
	XCTAssertNil([[[self queryGrid] window] attachedSheet]);
}

- (void)testMySQLQuerySaveFailureKeepsPopoverOpen
{
	if (![self connected]) return;
	[self runQuery:@"SELECT id, body FROM vp_notes WHERE id = 1" rows:1];
	SPValuePopover *popover = [self openQueryRow:0 column:1];
	[self replaceText:@"forbidden" in:popover];
	XCTAssertFalse([self save:popover]);
	XCTAssertTrue([[popover.errorField stringValue] containsString:@"vp_body_ok"], @"%@", [popover.errorField stringValue]);
	XCTAssertNil([[[self queryGrid] window] attachedSheet], @"no alert sheet over the popover");
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], self.longText);
}

- (void)testMySQLQueryRerunClosesPopover
{
	if (![self connected]) return;
	[self runQuery:@"SELECT id, body FROM vp_notes WHERE id = 1" rows:1];
	SPValuePopover *popover = [self openQueryRow:0 column:1];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[self runQuery:@"SELECT id, body FROM vp_notes WHERE id = 1" rows:1];
	XCTAssertTrue(closed);
	XCTAssertEqualObjects([self value:@"SELECT body FROM vp_notes WHERE id = 1"], self.longText);
}

- (void)testMySQLQueryDrawingDoesNotBuildWholeValues
{
	if (![self connected]) return;
	[self runQuery:@"SELECT id, body, data FROM vp_notes ORDER BY id" rows:3];
	__block BOOL active = NO;
	NSUInteger built = [self wholeValuesBuiltDuring:^{
		active = [self queryCell:1 row:0].valueIconActive;
		(void)[self queryCell:2 row:0];
	}];
	XCTAssertTrue(active);
	XCTAssertEqual(built, 0u);
}

- (void)testMySQLQuerySaveOfADeletedRowKeepsPopoverOpen
{
	if (![self connected]) return;
	[self runQuery:@"SELECT id, body FROM vp_notes WHERE id = 1" rows:1];
	SPValuePopover *popover = [self openQueryRow:0 column:1];
	[self run:@"DELETE FROM vp_notes WHERE id = 1"];
	[self replaceText:@"edited" in:popover];
	XCTAssertFalse([self save:popover]);
	XCTAssertGreaterThan([[popover.errorField stringValue] length], 0u);
	XCTAssertNil([[[self queryGrid] window] attachedSheet]);
}

@end
