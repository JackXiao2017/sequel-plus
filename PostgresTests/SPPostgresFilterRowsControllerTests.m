//
//  SPPostgresFilterRowsControllerTests.m
//  Sequel Plus
//
//  The PostgreSQL Content view's filter rows (an NSRuleEditor in list mode) and their Reset / Add Filter / Filter bar,
//  as MySQL's: rows read back as SPPostgresFilter conditions; no database needed.
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresTableData.h"
#import "../Source/Postgres/SPPostgresFilterRowsController.h"

@interface SPPostgresFilterRowsControllerTests : XCTestCase
@property (strong) SPPostgresFilterRowsController *rows;
@property (strong) NSWindow *window;
@end

@implementation SPPostgresFilterRowsControllerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.rows = [[SPPostgresFilterRowsController alloc] init];
	[self.rows.view setFrame:NSMakeRect(0, 0, 700, 200)];
	self.rows.columnNames = @[@"id", @"name", @"note"];
}

- (void)tearDown
{
	[self.window orderOut:nil];
	self.window = nil;
	self.rows = nil;
}

- (void)putInWindow
{
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 700, 200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	[self.window setReleasedWhenClosed:NO];
	[[self.window contentView] addSubview:self.rows.view];
	[self.window makeKeyAndOrderFront:nil];
}

- (void)assertFilters:(NSArray<SPPostgresFilter *> *)filters equal:(NSArray<NSArray<NSString *> *> *)expected
{
	XCTAssertEqual(filters.count, expected.count);
	for (NSUInteger i = 0; i < MIN(filters.count, expected.count); i++) {
		XCTAssertEqualObjects(filters[i].column, expected[i][0], @"row %lu", (unsigned long)i);
		XCTAssertEqualObjects(filters[i].comparison, expected[i][1], @"row %lu", (unsigned long)i);
		XCTAssertEqualObjects(filters[i].value ?: @"", expected[i][2], @"row %lu", (unsigned long)i);
	}
}

- (void)testListModeWithPostgresComparisons
{
	XCTAssertEqual([self.rows.ruleEditor nestingMode], NSRuleEditorNestingModeList);
	XCTAssertEqual([self.rows.ruleEditor rowHeight], 29.0);
	XCTAssertEqualObjects([SPPostgresFilterRowsController comparisons],
						  (@[@"=", @"≠", @">", @"<", @">=", @"<=", @"LIKE", @"NOT LIKE", @"ILIKE", @"IS NULL", @"IS NOT NULL", @"IN"]));
	for (NSString *comparison in [SPPostgresFilterRowsController comparisons]) {
		[self.rows addRowAfter:-1 column:@"id" comparison:comparison value:@"1"];
	}
	NSArray *filters = [self.rows typedFilters];
	XCTAssertEqual(filters.count, 12u);
	for (NSUInteger i = 0; i < filters.count; i++) {
		XCTAssertEqualObjects([filters[i] comparison], [SPPostgresFilterRowsController comparisons][i]);
	}
}

- (void)testAddRowsAndReadThemBack
{
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"42"];
	[self.rows addRowAfter:-1 column:@"name" comparison:@"IN" value:@"a, b"];
	[self.rows addRowAfter:-1 column:@"note" comparison:@"IS NULL" value:nil];
	XCTAssertEqual([self.rows numberOfRows], 3u);
	[self assertFilters:[self.rows typedFilters] equal:@[@[@"id", @"=", @"42"], @[@"name", @"IN", @"a, b"], @[@"note", @"IS NULL", @""]]];
}

- (void)testCompleteFiltersSkipEmptyValues
{
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@""];
	[self.rows addRowAfter:-1 column:@"note" comparison:@"IS NULL" value:nil];
	[self.rows addRowAfter:-1 column:@"name" comparison:@"LIKE" value:@"x%"];
	[self assertFilters:[self.rows completeFilters] equal:@[@[@"note", @"IS NULL", @""], @[@"name", @"LIKE", @"x%"]]];
}

- (void)testPlusInsertsBelowWithSameColumn
{
	[self.rows addRowAfter:-1 column:@"name" comparison:@"LIKE" value:@"a%"];
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"1"];
	[self.rows addRowAfter:0 column:nil comparison:nil value:nil];
	[self assertFilters:[self.rows typedFilters] equal:@[@[@"name", @"LIKE", @"a%"], @[@"name", @"=", @""], @[@"id", @"=", @"1"]]];
}

- (void)testAppendWithoutColumnUsesTheFirstColumn
{
	[self.rows addRowAfter:-1 column:nil comparison:nil value:nil];
	[self assertFilters:[self.rows typedFilters] equal:@[@[@"id", @"=", @""]]];
}

- (void)testSetFiltersReplacesRowsAndSkipsUnknownColumns
{
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"1"];
	[self.rows setFilters:@[[SPPostgresFilter filterWithColumn:@"note" comparison:@"≠" value:@"x"],
							[SPPostgresFilter filterWithColumn:@"nope" comparison:@"=" value:@"1"],
							[SPPostgresFilter filterWithColumn:@"name" comparison:@"IN" value:@"a,b"]]];
	[self assertFilters:[self.rows typedFilters] equal:@[@[@"note", @"≠", @"x"], @[@"name", @"IN", @"a,b"]]];
}

- (void)testSettingColumnNamesEmptiesRows
{
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"1"];
	self.rows.columnNames = @[@"a", @"b"];
	XCTAssertEqual([self.rows numberOfRows], 0u);
	XCTAssertTrue([self.rows.addFilterButton isEnabled]);
	XCTAssertFalse([self.rows.addFilterButton isHidden]);

	self.rows.columnNames = @[];
	XCTAssertFalse([self.rows.filterButton isEnabled]);
	XCTAssertFalse([self.rows.addFilterButton isEnabled]);
	XCTAssertFalse([self.rows.resetButton isEnabled]);
	XCTAssertFalse([self.rows.ruleEditor isEditable]);
	[self.rows addRowAfter:-1 column:nil comparison:nil value:nil];
	XCTAssertEqual([self.rows numberOfRows], 0u, @"no columns, no rows");
}

- (void)testColumnNamesRoundTripVerbatim
{
	NSString *odd = @"we ird \"col\" ü";
	self.rows.columnNames = @[@"id", odd];
	[self.rows addRowAfter:-1 column:odd comparison:@"=" value:@"v'1"];
	[self assertFilters:[self.rows typedFilters] equal:@[@[odd, @"=", @"v'1"]]];
}

- (void)testComparisonWithoutValueHasNoValueField
{
	[self.rows addRowAfter:-1 column:@"note" comparison:@"=" value:@"x"];
	XCTAssertNotNil([self.rows valueFieldInRow:0]);
	XCTAssertEqualObjects([[self.rows valueFieldInRow:0] stringValue], @"x");
	[self.rows setFilters:@[[SPPostgresFilter filterWithColumn:@"note" comparison:@"IS NOT NULL" value:@"x"]]];
	XCTAssertNil([self.rows valueFieldInRow:0]);
	[self assertFilters:[self.rows typedFilters] equal:@[@[@"note", @"IS NOT NULL", @""]]];
}

- (void)testButtonsAndTooltipsMatchMySQL
{
	SPPostgresFilterRowsController *rows = self.rows;
	XCTAssertEqualObjects([rows.filterButton title], @"Filter");
	XCTAssertEqualObjects([rows.filterButton toolTip], @"Query the current table using the filter conditions defined above");
	XCTAssertEqualObjects([rows.addFilterButton title], @"Add Filter");
	XCTAssertEqualObjects([rows.addFilterButton toolTip], @"Adds a new filter condition which can be used to limit the results displayed below");
	XCTAssertEqualObjects([rows.resetButton toolTip], @"Delete any defined filter conditions and reload the table (⌘⎋)");
	XCTAssertEqualObjects([[rows.resetButton image] name], @"button_clear");
	XCTAssertEqual([rows.resetButton imagePosition], NSImageOnly);
	XCTAssertEqualObjects([rows.resetButton keyEquivalent], @"\e");
	XCTAssertEqual([rows.resetButton keyEquivalentModifierMask], NSEventModifierFlagCommand);

	NSView *bar = [rows.filterButton superview];
	XCTAssertTrue([bar isKindOfClass:NSClassFromString(@"SPButtonBar")]);
	XCTAssertEqual(NSMinY([bar frame]), 0);
	XCTAssertEqual(NSHeight([bar frame]), 23);
	XCTAssertEqual([rows.resetButton superview], bar);
	XCTAssertEqual([rows.addFilterButton superview], bar);
	XCTAssertEqual(NSMinX([rows.resetButton frame]), 0);
	XCTAssertEqual(NSMaxX([rows.filterButton frame]), NSWidth([bar frame]) - 10, @"Filter 10 pt from the right, as DBView.xib");
	XCTAssertEqual(NSMaxX([rows.addFilterButton frame]), NSMaxX([rows.filterButton frame]), @"Add Filter in Filter's place (only one shows), as MySQL's");
	XCTAssertEqual(NSMinY([rows.addFilterButton frame]), NSMinY([rows.filterButton frame]));
	NSScrollView *scroll = [rows.ruleEditor enclosingScrollView];
	XCTAssertEqual([scroll superview], rows.view);
	XCTAssertEqual(NSMinY([scroll frame]), 31, @"the rows start 8 pt above the bar");
}

- (void)testPreferredHeight
{
	self.rows.columnNames = @[@"id"];
	XCTAssertEqual(self.rows.preferredHeight, 31);
	__block NSUInteger changes = 0;
	self.rows.onHeightChanged = ^{ changes++; };
	[self.rows addRowAfter:-1 column:nil comparison:nil value:nil];
	[self.rows addRowAfter:-1 column:nil comparison:nil value:nil];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
	XCTAssertEqual(self.rows.preferredHeight, 89);
	XCTAssertGreaterThanOrEqual(changes, 2u);
	XCTAssertGreaterThanOrEqual(NSHeight([self.rows.ruleEditor frame]), 58, @"both rows fit (AppKit may stretch it to the visible area)");
}

- (void)testCallbacks
{
	[self putInWindow];
	__block NSUInteger applied = 0, reset = 0, emptied = 0;
	self.rows.onApply = ^{ applied++; };
	self.rows.onReset = ^{ reset++; };
	self.rows.onLastRowRemoved = ^{ emptied++; };

	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"1"];
	[self.rows.filterButton performClick:nil];
	XCTAssertEqual(applied, 1u);
	XCTAssertTrue([self.window makeFirstResponder:[self.rows valueFieldInRow:0]]);
	[(NSText *)[self.window firstResponder] doCommandBySelector:@selector(insertNewline:)];
	XCTAssertEqual(applied, 2u, @"Return in a value field applies");

	[self.rows.resetButton performClick:nil];
	XCTAssertEqual(reset, 1u);
	XCTAssertEqual(emptied, 0u);
	XCTAssertEqual([self.rows numberOfRows], 0u, @"Reset empties the rows, as MySQL's");

	// The row's − (as the rule editor's own button does): the last row gone
	[self.rows setFilters:@[[SPPostgresFilter filterWithColumn:@"id" comparison:@"=" value:@"1"]]];
	[self.rows.ruleEditor removeRowAtIndex:0];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	XCTAssertEqual(emptied, 1u);

	// Programmatic emptying doesn't count
	[self.rows addRowAfter:-1 column:nil comparison:nil value:nil];
	[self.rows removeAllRows];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	XCTAssertEqual(emptied, 1u);
}

- (void)testAddFilterButtonAddsAFocusedRow
{
	[self putInWindow];
	[self.rows.addFilterButton performClick:nil];
	XCTAssertEqual([self.rows numberOfRows], 1u);
	[self assertFilters:[self.rows typedFilters] equal:@[@[@"id", @"=", @""]]];
	id responder = [self.window firstResponder];
	if ([responder isKindOfClass:[NSText class]]) responder = [(NSText *)responder delegate];
	XCTAssertEqual(responder, [self.rows valueFieldInRow:0]);
}

/// As MySQL's: with no rows only Add Filter shows (Reset disabled); with rows only Filter shows (Reset enabled).
- (void)testOnlyAddFilterWithoutRowsOnlyFilterWithRows
{
	SPPostgresFilterRowsController *rows = self.rows;
	XCTAssertEqual([rows numberOfRows], 0u);
	XCTAssertFalse([rows.addFilterButton isHidden]);
	XCTAssertTrue([rows.addFilterButton isEnabled]);
	XCTAssertTrue([rows.filterButton isHidden]);
	XCTAssertFalse([rows.filterButton isEnabled]);
	XCTAssertFalse([rows.resetButton isEnabled]);

	[rows.addFilterButton performClick:nil];
	XCTAssertEqual([rows numberOfRows], 1u);
	XCTAssertTrue([rows.addFilterButton isHidden]);
	XCTAssertFalse([rows.addFilterButton isEnabled]);
	XCTAssertFalse([rows.filterButton isHidden]);
	XCTAssertTrue([rows.filterButton isEnabled]);
	XCTAssertTrue([rows.resetButton isEnabled]);

	// The row's − on the last row: Add Filter again
	[rows.ruleEditor removeRowAtIndex:0];
	XCTAssertFalse([rows.addFilterButton isHidden]);
	XCTAssertTrue([rows.filterButton isHidden]);
	XCTAssertFalse([rows.resetButton isEnabled]);

	[rows setFilters:@[[SPPostgresFilter filterWithColumn:@"id" comparison:@"=" value:@"1"]]];
	XCTAssertFalse([rows.filterButton isHidden]);
	[rows.resetButton performClick:nil];
	XCTAssertEqual([rows numberOfRows], 0u);
	XCTAssertFalse([rows.addFilterButton isHidden]);
	XCTAssertTrue([rows.filterButton isHidden]);

	// No columns: nothing enabled
	[rows addRowAfter:-1 column:nil comparison:nil value:nil];
	rows.columnNames = @[];
	XCTAssertFalse([rows.addFilterButton isEnabled]);
	XCTAssertFalse([rows.filterButton isEnabled]);
	XCTAssertFalse([rows.resetButton isEnabled]);
}

- (void)testEndingEditingWithoutReturnDoesNotApply
{
	[self putInWindow];
	NSTextField *elsewhere = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 50, 20)];
	[[self.window contentView] addSubview:elsewhere];
	__block NSUInteger applied = 0;
	self.rows.onApply = ^{ applied++; };
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"3"];
	NSTextField *field = [self.rows valueFieldInRow:0];

	// Typing, then clicking elsewhere: editing ends, nothing applies
	XCTAssertTrue([self.window makeFirstResponder:field]);
	NSText *editor = (NSText *)[self.window firstResponder];
	[editor insertText:@"5"];
	XCTAssertTrue([self.window makeFirstResponder:elsewhere]);
	XCTAssertEqual(applied, 0u, @"ending the edit must not apply the typed rows");
	XCTAssertEqualObjects([field stringValue], @"5", @"focusing selects the value, so typing replaces it");

	// Return (and keypad Enter, which the field editor also turns into insertNewline:) applies, once
	XCTAssertTrue([self.window makeFirstResponder:field]);
	editor = (NSText *)[self.window firstResponder];
	[editor doCommandBySelector:@selector(insertNewline:)];
	XCTAssertEqual(applied, 1u);
}

- (void)testInvalidateDropsTargets
{
	[self.rows addRowAfter:-1 column:@"id" comparison:@"=" value:@"3"];
	NSTextField *field = [self.rows valueFieldInRow:0];
	[self.rows invalidate];
	XCTAssertNil([self.rows.filterButton target]);
	XCTAssertNil([self.rows.addFilterButton target]);
	XCTAssertNil([self.rows.resetButton target]);
	XCTAssertNil([self.rows.ruleEditor delegate]);
	XCTAssertNil([field target]);
	XCTAssertNil([field delegate]);
	XCTAssertNil(self.rows.onApply);
}

@end
