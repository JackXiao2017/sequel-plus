#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../Source/Postgres/SPPostgresDateTimePicker.h"

/**
 * The date / time picker on MySQL's Content and Custom Query grids. No MySQL server is used: the controllers get a
 * stand-in result store and column definitions, and the row checks that would query the server are stubbed.
 */

/// A stand-in for SPDataStorage: rows of values (NSString or NSNull).
@interface SPMySQLPickerStore : NSObject
@property (strong) NSMutableArray<NSMutableArray *> *rows;
@end

@implementation SPMySQLPickerStore
- (NSUInteger)count { return [self.rows count]; }
- (NSUInteger)columnCount { return [[self.rows firstObject] count]; }
- (id)cellDataAtRow:(NSUInteger)row column:(NSUInteger)column { return self.rows[row][column]; }
- (id)cellPreviewAtRow:(NSUInteger)row column:(NSUInteger)column previewLength:(NSUInteger)length { return self.rows[row][column]; }
- (BOOL)cellIsNullOrUnloadedAtRow:(NSUInteger)row column:(NSUInteger)column { return [self.rows[row][column] isKindOfClass:[NSNull class]]; }
- (BOOL)dataDownloaded { return YES; }
@end

/// The grid's data source: the store's values as text.
@interface SPMySQLPickerSource : NSObject <NSTableViewDataSource>
@property (strong) SPMySQLPickerStore *store;
@end

@implementation SPMySQLPickerSource
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)[self.store count]; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	id value = [self.store cellDataAtRow:(NSUInteger)row column:(NSUInteger)[[tableColumn identifier] integerValue]];
	return [value isKindOfClass:[NSString class]] ? value : @"NULL";
}
@end

/*
 * The app's MySQL classes aren't exported to the test bundle, so their test subclasses are made at runtime:
 * - the grid (SPCopyTable): the field editor sheet is never wanted (edit-in-sheet off, short values);
 * - Custom Query: the row check (a COUNT query) answered by the test (editStatus), counting its calls;
 * - Content: the row's WHERE clause given (it is built from the table's keys).
 */
static NSInteger SPMySQLPickerEditStatus = 1;
static NSUInteger SPMySQLPickerEditStatusChecks = 0;

static BOOL SPMySQLPickerNoSheet(id self, SEL _cmd, NSUInteger row, NSUInteger column, void *lock) { return NO; }
static NSArray *SPMySQLPickerEditStatusFor(id self, SEL _cmd, NSInteger row, NSInteger column)
{
	SPMySQLPickerEditStatusChecks++;
	return @[@(SPMySQLPickerEditStatus), @""];
}
static NSString *SPMySQLPickerArgumentForRow(id self, SEL _cmd, NSInteger row) { return @"WHERE `id` = 1"; }

static Class SPMySQLPickerSubclass(NSString *superName, NSString *name, SEL selector, IMP imp, const char *types)
{
	Class existing = NSClassFromString(name);
	if (existing) return existing;
	Class subclass = objc_allocateClassPair(NSClassFromString(superName), [name UTF8String], 0);
	class_addMethod(subclass, selector, imp, types);
	objc_registerClassPair(subclass);
	return subclass;
}

@interface SPMySQLDateTimePickerTests : XCTestCase
@property (strong) NSWindow *window;
@property (strong) NSTableView *grid;
@property (strong) SPMySQLPickerStore *store;
@property (strong) SPMySQLPickerSource *source;
@property (strong) id controller;
@end

@implementation SPMySQLDateTimePickerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.store = [[SPMySQLPickerStore alloc] init];
	self.store.rows = [@[[@[@"1", @"2026-11-03", @"14:05:09", @"2026-11-03 14:05:09", @"2026-11-03 14:05:09", @"2026"] mutableCopy]] mutableCopy];
	self.source = [[SPMySQLPickerSource alloc] init];
	self.source.store = self.store;

	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
	NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:[[self.window contentView] bounds]];
	Class gridClass = SPMySQLPickerSubclass(@"SPCopyTable", @"SPMySQLPickerGrid", @selector(shouldUseFieldEditorForRow:column:checkWithLock:), (IMP)SPMySQLPickerNoSheet, "c@:QQ^v");
	self.grid = [[gridClass alloc] initWithFrame:[scrollView bounds]];
	NSArray *names = @[@"id", @"d", @"t", @"dt", @"ts", @"y"];
	for (NSUInteger index = 0; index < [names count]; index++) {
		NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)index]];
		[[column headerCell] setStringValue:names[index]];
		[column setWidth:120];
		[column setEditable:YES];
		[self.grid addTableColumn:column];
	}
	[scrollView setDocumentView:self.grid];
	[[self.window contentView] addSubview:scrollView];
	[self.grid setDataSource:self.source];
}

- (void)tearDown
{
	if ([SPPostgresDateTimePicker currentPicker]) [[SPPostgresDateTimePicker currentPicker] cancel:nil];
	if ([self.grid currentEditor]) [self.grid abortEditing];
	[self.grid setDelegate:nil];
	[self.grid setDataSource:nil];
	[self.window close];
	self.window = nil;
	self.grid = nil;
	self.controller = nil;
	[super tearDown];
}

/// MySQL's column definitions (type as SPMySQL names it; null: 1 for NOT NULL) for the grid's columns.
- (NSArray *)columnDefinitions
{
	return @[@{@"name": @"id", @"type": @"INT", @"typegrouping": @"integer", @"null": @1, @"org_table": @"events", @"db": @"test"},
			 @{@"name": @"d", @"type": @"DATE", @"typegrouping": @"date", @"null": @0, @"org_table": @"events", @"db": @"test"},
			 @{@"name": @"t", @"type": @"TIME", @"typegrouping": @"date", @"null": @0, @"org_table": @"events", @"db": @"test"},
			 @{@"name": @"dt", @"type": @"DATETIME", @"typegrouping": @"date", @"null": @1, @"org_table": @"events", @"db": @"test"},
			 @{@"name": @"ts", @"type": @"TIMESTAMP", @"typegrouping": @"date", @"null": @0, @"org_table": @"events", @"db": @"test"},
			 @{@"name": @"y", @"type": @"YEAR", @"typegrouping": @"date", @"null": @0, @"org_table": @"events", @"db": @"test"}];
}

- (BOOL)shouldEditColumn:(NSUInteger)column
{
	[self.window makeFirstResponder:self.grid];
	return [(id<NSTableViewDelegate>)self.controller tableView:self.grid shouldEditTableColumn:self.grid.tableColumns[column] row:0];
}

- (NSString *)nullText
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:@"NullValue"] ?: @"NULL";
}

/// What both grids do: the picker on DATE, TIME, DATETIME and TIMESTAMP cells, its value into the cell's in-place
/// editor (nothing saved), NULL as the NULL placeholder, Cancel leaving the cell alone.
- (void)checkPickerHandsValuesToTheCellEditor
{
	XCTAssertTrue([self shouldEditColumn:0], @"INT: the in-cell editor");
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);
	XCTAssertTrue([self shouldEditColumn:5], @"YEAR: the in-cell editor");
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);

	NSDictionary *kinds = @{@1: @(SPPostgresTemporalDate), @2: @(SPPostgresTemporalTime), @3: @(SPPostgresTemporalTimestamp), @4: @(SPPostgresTemporalTimestamp)};
	for (NSNumber *column in kinds) {
		XCTAssertFalse([self shouldEditColumn:[column unsignedIntegerValue]], @"%@", column);
		SPPostgresDateTimePicker *picker = [SPPostgresDateTimePicker currentPicker];
		XCTAssertNotNil(picker, @"%@", column);
		XCTAssertEqual(picker.kind, [kinds[column] integerValue], @"%@", column);
		XCTAssertEqualObjects(picker.textField.stringValue, self.store.rows[0][[column unsignedIntegerValue]]);
		XCTAssertFalse([self shouldEditColumn:1], @"no second picker while one is open");
		[picker cancel:nil];
		XCTAssertNil([SPPostgresDateTimePicker currentPicker]);
		XCTAssertNil([self.grid currentEditor], @"Cancel: the cell isn't being edited");
	}

	// Set: the value goes into the cell's in-place editor, which stays open; the store is unchanged
	XCTAssertFalse([self shouldEditColumn:3]);
	SPPostgresDateTimePicker *picker = [SPPostgresDateTimePicker currentPicker];
	XCTAssertNotNil(picker.calendarPicker);
	XCTAssertNotNil(picker.timePicker);
	XCTAssertNil(picker.nullButton, @"dt is NOT NULL");
	picker.textField.stringValue = @"2027-01-15 08:30:00";
	[picker set:nil];
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);
	XCTAssertNotNil([self.grid currentEditor], @"the cell is being edited");
	XCTAssertEqual(self.grid.editedColumn, 3);
	XCTAssertEqual(self.grid.editedRow, 0);
	XCTAssertEqualObjects([[self.grid currentEditor] string], @"2027-01-15 08:30:00");
	XCTAssertEqualObjects(self.store.rows[0][3], @"2026-11-03 14:05:09", @"not saved");
	[self.grid abortEditing];

	// NULL on a nullable column: the NULL placeholder in the editor
	XCTAssertFalse([self shouldEditColumn:4]);
	picker = [SPPostgresDateTimePicker currentPicker];
	XCTAssertNotNil(picker.nullButton, @"ts takes NULL");
	[picker setNull:nil];
	XCTAssertEqual(self.grid.editedColumn, 4);
	XCTAssertEqualObjects([[self.grid currentEditor] string], [self nullText]);
	[self.grid abortEditing];

	// A NULL value: the picker starts with an empty text field
	self.store.rows[0][4] = [NSNull null];
	XCTAssertFalse([self shouldEditColumn:4]);
	XCTAssertEqualObjects([SPPostgresDateTimePicker currentPicker].textField.stringValue, @"");
	[[SPPostgresDateTimePicker currentPicker] cancel:nil];

	// The value changed while the picker was open (a reload): nothing goes into the cell
	XCTAssertFalse([self shouldEditColumn:1]);
	picker = [SPPostgresDateTimePicker currentPicker];
	self.store.rows[0][1] = @"2030-01-01";
	picker.textField.stringValue = @"2027-01-15";
	[picker set:nil];
	XCTAssertNil([self.grid currentEditor]);
}

- (void)testKindsOfMySQLTypeNames
{
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"DATE"], SPPostgresTemporalDate);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"date"], SPPostgresTemporalDate);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"TIME"], SPPostgresTemporalTime);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"TIME(3)"], SPPostgresTemporalTime);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"DATETIME"], SPPostgresTemporalTimestamp);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"DATETIME(6)"], SPPostgresTemporalTimestamp);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"TIMESTAMP"], SPPostgresTemporalTimestamp);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"YEAR"], SPPostgresTemporalNone);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:@"VARCHAR"], SPPostgresTemporalNone);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfMySQLTypeName:nil], SPPostgresTemporalNone);

	// MySQL's own forms read as the unzoned kinds; zero dates and out-of-day times can't be read (kept as typed)
	XCTAssertNotNil([SPPostgresDateTimePicker dateFromText:@"2026-11-03 14:05:09.123456" kind:SPPostgresTemporalTimestamp timeZone:NULL]);
	XCTAssertNil([SPPostgresDateTimePicker dateFromText:@"0000-00-00 00:00:00" kind:SPPostgresTemporalTimestamp timeZone:NULL]);
	XCTAssertNil([SPPostgresDateTimePicker dateFromText:@"838:59:59" kind:SPPostgresTemporalTime timeZone:NULL]);
	SPPostgresDateTimePicker *zero = [[SPPostgresDateTimePicker alloc] initWithValue:@"0000-00-00" kind:SPPostgresTemporalDate allowNull:NO completion:nil];
	XCTAssertEqualObjects(zero.textField.stringValue, @"0000-00-00");
}

- (void)testCustomQueryOpensThePickerOnDateCells
{
	Class queryClass = SPMySQLPickerSubclass(@"SPCustomQuery", @"SPMySQLPickerCustomQuery", @selector(fieldEditStatusForRow:andColumn:), (IMP)SPMySQLPickerEditStatusFor, "@@:qq");
	id query = [[queryClass alloc] init];
	self.controller = query;
	// Its -dealloc removes the font observer its nib's -awakeFromNib adds (observing only; nothing is written)
	[[NSUserDefaults standardUserDefaults] addObserver:query forKeyPath:@"GlobalResultTableFont" options:0 context:NULL];
	SPMySQLPickerEditStatus = 1;
	[query setValue:self.grid forKey:@"customQueryView"];
	[query setValue:[self columnDefinitions] forKey:@"cqColumnDefinition"];
	[query setValue:self.store forKey:@"resultData"];
	[self.grid setDelegate:query];

	[self checkPickerHandsValuesToTheCellEditor];

	// The in-cell editor's own check ran on the picker's value as on typing
	SPMySQLPickerEditStatusChecks = 0;
	XCTAssertFalse([self shouldEditColumn:2]);
	[SPPostgresDateTimePicker currentPicker].textField.stringValue = @"09:15:00";
	[[SPPostgresDateTimePicker currentPicker] set:nil];
	XCTAssertEqualObjects([[self.grid currentEditor] string], @"09:15:00");
	XCTAssertEqual(SPMySQLPickerEditStatusChecks, 2u, @"once before the picker, once as the value went in");
	[self.grid abortEditing];

	// A cell that can't be edited (no single matching row): no picker; the in-cell editor shows why, as before
	SPMySQLPickerEditStatus = 0;
	XCTAssertTrue([self shouldEditColumn:3]);
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);
}

- (void)testContentOpensThePickerOnDateCells
{
	Class contentClass = SPMySQLPickerSubclass(@"SPTableContent", @"SPMySQLPickerTableContent", @selector(argumentForRow:), (IMP)SPMySQLPickerArgumentForRow, "@@:q");
	id content = [[contentClass alloc] init];
	self.controller = content;
	[content setValue:self.grid forKey:@"tableContentView"];
	[content setValue:[self columnDefinitions] forKey:@"cqColumnDefinition"];
	[content setValue:self.store forKey:@"tableValues"];
	[content setValue:@"events" forKey:@"selectedTable"];
	[self.grid setDelegate:content];

	[self checkPickerHandsValuesToTheCellEditor];

	// Another table shown while the picker was open: nothing goes into the cell
	XCTAssertFalse([self shouldEditColumn:2]);
	SPPostgresDateTimePicker *picker = [SPPostgresDateTimePicker currentPicker];
	[content setValue:@"other" forKey:@"selectedTable"];
	[picker set:nil];
	XCTAssertNil([self.grid currentEditor]);
}

@end
