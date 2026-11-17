#import <XCTest/XCTest.h>
#import "../Source/SPForeignKeyPicker.h"
#import "../Source/SPForeignKeyPickerSettings.h"

static NSString * const SPFKPickerTestSuite = @"SPForeignKeyPickerTests";

/// One fetch the picker asked for.
@interface SPFKFakeFetch : NSObject
@property (copy) NSString *search;
@property (copy) NSArray *searchColumns;
@property (copy) NSArray<SPForeignKeyCondition *> *conditions;
@property (copy) NSArray *columns;
@property NSUInteger offset, limit;
@end
@implementation SPFKFakeFetch
@end

/// A data source answering from memory, on the main queue after an optional per-call delay.
@interface SPFKFakeSource : NSObject <SPForeignKeyPickerDataSource>
@property (strong) NSMutableArray<SPFKFakeFetch *> *fetches;
@property (strong) NSMutableArray<NSNumber *> *delays;          // seconds for the next fetches, in order
@property (copy) NSArray<NSArray *> *(^rowsProvider)(SPFKFakeFetch *fetch); // nil: the 255-row table
@property (copy) NSString *errorMessage;
@end

@implementation SPFKFakeSource
- (instancetype)init
{
	if ((self = [super init])) { _fetches = [NSMutableArray array]; _delays = [NSMutableArray array]; }
	return self;
}
- (NSString *)keyColumn { return @"id"; }
+ (NSArray *)allColumns
{
	return @[[SPForeignKeyPickerColumn columnWithName:@"id" kind:SPForeignKeyColumnNumber],
			 [SPForeignKeyPickerColumn columnWithName:@"name" kind:SPForeignKeyColumnText],
			 [SPForeignKeyPickerColumn columnWithName:@"email" kind:SPForeignKeyColumnText],
			 [SPForeignKeyPickerColumn columnWithName:@"city" kind:SPForeignKeyColumnText],
			 [SPForeignKeyPickerColumn columnWithName:@"created_at" kind:SPForeignKeyColumnDateTime]];
}
- (void)loadColumnsWithCompletion:(void (^)(NSArray *, NSString *))completion
{
	dispatch_async(dispatch_get_main_queue(), ^{ completion([[self class] allColumns], nil); });
}
/// Rows 1…255: name "Person i", email "pi@x", city Leeds (odd) or York (even), created_at 2025-01-01.
- (NSArray *)tableRowsFor:(SPFKFakeFetch *)fetch
{
	NSMutableArray *rows = [NSMutableArray array];
	for (NSUInteger i = 1; i <= 255; i++) {
		NSDictionary *row = @{@"id": [NSString stringWithFormat:@"%lu", (unsigned long)i], @"name": [NSString stringWithFormat:@"Person %lu", (unsigned long)i],
							  @"email": [NSString stringWithFormat:@"p%lu@x", (unsigned long)i], @"city": (i % 2) ? @"Leeds" : @"York", @"created_at": @"2025-01-01"};
		if ([fetch.search length]) {
			BOOL match = NO;
			for (NSString *column in fetch.searchColumns) match |= [row[column] rangeOfString:fetch.search options:NSCaseInsensitiveSearch].location != NSNotFound;
			if (!match) continue;
		}
		NSMutableArray *values = [NSMutableArray array];
		for (NSString *column in fetch.columns) [values addObject:row[column]];
		[rows addObject:values];
	}
	return rows;
}
- (void)fetchRowsWithSearch:(NSString *)search inColumns:(NSArray *)searchColumns conditions:(NSArray *)conditions columns:(NSArray *)columns offset:(NSUInteger)offset limit:(NSUInteger)limit completion:(void (^)(NSArray *, NSString *))completion
{
	SPFKFakeFetch *fetch = [[SPFKFakeFetch alloc] init];
	fetch.search = search; fetch.searchColumns = searchColumns; fetch.conditions = conditions; fetch.columns = columns; fetch.offset = offset; fetch.limit = limit;
	[self.fetches addObject:fetch];
	NSTimeInterval delay = 0;
	if (self.delays.count) { delay = [self.delays[0] doubleValue]; [self.delays removeObjectAtIndex:0]; }
	NSArray *all = self.rowsProvider ? self.rowsProvider(fetch) : [self tableRowsFor:fetch];
	NSArray *page = offset < all.count ? [all subarrayWithRange:NSMakeRange(offset, MIN(limit, all.count - offset))] : @[];
	NSString *error = self.errorMessage;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		completion(error ? nil : page, error);
	});
}
@end

@interface SPForeignKeyPickerTests : XCTestCase
@property (strong) NSUserDefaults *defaults;
@property (strong) SPForeignKeyPickerSettings *settings;
@property (strong) SPFKFakeSource *source;
@property (strong) SPForeignKeyPicker *picker;
@property (strong) NSMutableArray *outcomes; // @[@(outcome), value or NSNull]
@end

@implementation SPForeignKeyPickerTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPFKPickerTestSuite];
	self.defaults = [[NSUserDefaults alloc] initWithSuiteName:SPFKPickerTestSuite];
	self.settings = [[SPForeignKeyPickerSettings alloc] initWithDefaults:self.defaults];
	self.source = [[SPFKFakeSource alloc] init];
	self.outcomes = [NSMutableArray array];
}

- (void)tearDown
{
	[self.picker cancel];
	self.picker = nil;
	[self.defaults removePersistentDomainForName:SPFKPickerTestSuite];
	[super tearDown];
}

- (void)spin:(NSTimeInterval)seconds
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

- (void)spinUntil:(BOOL (^)(void))condition
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) [self spin:0.01];
	XCTAssertTrue(condition());
}

- (SPForeignKeyPicker *)openWithCurrent:(id)current allowNull:(BOOL)allowNull
{
	NSMutableArray *outcomes = self.outcomes;
	self.picker = [[SPForeignKeyPicker alloc] initWithDataSource:self.source settings:self.settings tableKey:@"k" title:@"orders.customer_id · public.customers"
												   currentValue:current allowNull:allowNull completion:^(SPForeignKeyPickerOutcome outcome, NSString *value) {
		XCTAssertTrue([NSThread isMainThread]);
		[outcomes addObject:@[@(outcome), value ?: [NSNull null]]];
	}];
	self.picker.searchDelay = 0;
	SPForeignKeyPicker *picker = self.picker;
	[self spinUntil:^BOOL{ return picker.rows.count > 0 || picker.errorMessage != nil; }];
	return self.picker;
}

- (SPForeignKeyPicker *)open
{
	return [self openWithCurrent:@"23" allowNull:YES];
}

- (void)type:(NSString *)text
{
	[self.picker.searchField setStringValue:text];
	[self.picker controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:self.picker.searchField]];
}

- (void)key:(SEL)command
{
	[self.picker control:self.picker.searchField textView:(NSTextView *)[NSTextView new] doCommandBySelector:command];
}

- (NSMenuItem *)menuItemTitled:(NSString *)title
{
	NSMenu *menu = [self.picker columnsMenu];
	NSInteger index = [menu indexOfItemWithTitle:title];
	XCTAssertNotEqual(index, -1, @"%@", title);
	return [menu itemAtIndex:index];
}

- (void)pickMenuItem:(NSString *)title
{
	NSMenu *menu = [self.picker columnsMenu];
	[menu performActionForItemAtIndex:[menu indexOfItemWithTitle:title]];
}

- (void)choose:(NSString *)title inPopUp:(NSPopUpButton *)popUp
{
	[popUp selectItemWithTitle:title];
	XCTAssertEqualObjects([popUp titleOfSelectedItem], title);
	[NSApp sendAction:[popUp action] to:[popUp target] from:popUp];
}

- (void)setText:(NSString *)text inField:(NSTextField *)field
{
	[field setStringValue:text];
	[self.picker controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
}

#pragma mark - Opening

- (void)testOpensWithAllShownColumnsKeyFirstAndBold
{
	[self open];
	NSArray *expected = @[@"id", @"name", @"email", @"city", @"created_at"];
	XCTAssertEqualObjects([[self.picker.resultsTable tableColumns] valueForKey:@"identifier"], expected);
	XCTAssertEqualObjects(self.source.fetches[0].columns, expected);
	XCTAssertEqualObjects(self.source.fetches[0].offset == 0 ? @"first" : @"", @"first");
	NSCell *keyCell = [self.picker.resultsTable preparedCellAtColumn:0 row:0];
	NSCell *nameCell = [self.picker.resultsTable preparedCellAtColumn:1 row:0];
	XCTAssertTrue([[NSFontManager sharedFontManager] traitsOfFont:[keyCell font]] & NSBoldFontMask);
	XCTAssertFalse([[NSFontManager sharedFontManager] traitsOfFont:[nameCell font]] & NSBoldFontMask);
	XCTAssertEqualObjects(self.picker.titleField.stringValue, @"Choose orders.customer_id · public.customers");
}

- (void)testPlaceholderNamesSearchedColumns
{
	[self.settings setShownColumns:@[@"name", @"email"] forTableKey:@"k"];
	[self open];
	XCTAssertEqualObjects([[self.picker.searchField cell] placeholderString], @"Search name, email");
	XCTAssertEqualObjects(self.source.fetches[0].columns, (@[@"id", @"name", @"email"]));
}

#pragma mark - Search

- (void)testSearchFetchesAfterDebounceOverShownColumns
{
	[self open];
	self.picker.searchDelay = 0.2;
	NSUInteger before = self.source.fetches.count;
	[self type:@"Person 25"];
	[self type:@"Person 255"];
	XCTAssertEqual(self.source.fetches.count, before, @"no fetch before the debounce");
	[self spin:0.4];
	XCTAssertEqual(self.source.fetches.count, before + 1, @"one fetch for the last text");
	SPFKFakeFetch *fetch = self.source.fetches.lastObject;
	XCTAssertEqualObjects(fetch.search, @"Person 255");
	XCTAssertEqualObjects(fetch.searchColumns, (@[@"id", @"name", @"email", @"city", @"created_at"]));
	XCTAssertEqual(fetch.offset, 0u);
	[self spinUntil:^BOOL{ return self.picker.rows.count == 1; }];
	XCTAssertEqualObjects(self.picker.statusText, @"1 matches");
}

- (void)testStaleFetchResultIsIgnored
{
	[self open];
	[self.source.delays addObjectsFromArray:@[@0.3, @0]];
	[self type:@"Person 1"];   // slow: many rows
	[self type:@"Person 255"]; // fast: one row
	[self spin:0.6];
	XCTAssertEqual(self.picker.rows.count, 1u);
	XCTAssertEqualObjects(self.picker.rows[0][0], @"255");
}

- (void)testMatchesAreHighlighted
{
	[self open];
	[self type:@"son 25"];
	[self spinUntil:^BOOL{ return self.picker.rows.count == 7; }];
	id value = [[self.picker.resultsTable dataSource] tableView:self.picker.resultsTable objectValueForTableColumn:[self.picker.resultsTable tableColumns][1] row:0];
	XCTAssertTrue([value isKindOfClass:[NSAttributedString class]]);
	NSRange range;
	XCTAssertNotNil([value attribute:NSBackgroundColorAttributeName atIndex:3 effectiveRange:&range]);
	XCTAssertEqual(range.location, 3u);
	XCTAssertEqual(range.length, 6u);
}

#pragma mark - Conditions

- (void)testConditionRowOperatorsFollowKind
{
	[self open];
	[self.picker addCondition];
	XCTAssertEqual(self.picker.conditionsView.arrangedSubviews.count, 1u);
	SPForeignKeyConditionRow *row = (SPForeignKeyConditionRow *)self.picker.conditionsView.arrangedSubviews[0];
	[self choose:@"name" inPopUp:row.columnPopUp];
	XCTAssertEqualObjects([row.operatorPopUp itemTitles], [SPForeignKeyPickerColumn operatorsForKind:SPForeignKeyColumnText]);
	[self choose:@"id" inPopUp:row.columnPopUp];
	XCTAssertEqualObjects([row.operatorPopUp itemTitles], [SPForeignKeyPickerColumn operatorsForKind:SPForeignKeyColumnNumber]);
	XCTAssertTrue(row.secondValueField.hidden);
	[self choose:@"between" inPopUp:row.operatorPopUp];
	XCTAssertFalse(row.secondValueField.hidden);
	[self choose:@"is NULL" inPopUp:row.operatorPopUp];
	XCTAssertTrue(row.valueField.hidden);
	// Removing it
	[NSApp sendAction:row.removeButton.action to:row.removeButton.target from:row.removeButton];
	XCTAssertEqual(self.picker.conditionsView.arrangedSubviews.count, 0u);
}

- (void)testConditionsSentAnded
{
	[self open];
	[self.picker addCondition];
	[self.picker addCondition];
	SPForeignKeyConditionRow *first = (SPForeignKeyConditionRow *)self.picker.conditionsView.arrangedSubviews[0];
	SPForeignKeyConditionRow *second = (SPForeignKeyConditionRow *)self.picker.conditionsView.arrangedSubviews[1];
	[self choose:@"city" inPopUp:first.columnPopUp];
	[self choose:@"=" inPopUp:first.operatorPopUp];
	[self setText:@"Leeds" inField:first.valueField];
	[self choose:@"id" inPopUp:second.columnPopUp];
	[self choose:@"between" inPopUp:second.operatorPopUp];
	[self setText:@"10" inField:second.valueField];
	[self setText:@"20" inField:second.secondValueField];
	[self type:@"Person"];
	[self spin:0.1];
	SPFKFakeFetch *fetch = self.source.fetches.lastObject;
	XCTAssertEqualObjects(fetch.search, @"Person");
	XCTAssertEqual(fetch.conditions.count, 2u);
	XCTAssertEqualObjects(fetch.conditions[0].column, @"city");
	XCTAssertEqualObjects(fetch.conditions[0].op, @"=");
	XCTAssertEqualObjects(fetch.conditions[0].value, @"Leeds");
	XCTAssertEqualObjects(fetch.conditions[1].column, @"id");
	XCTAssertEqualObjects(fetch.conditions[1].op, @"between");
	XCTAssertEqualObjects(fetch.conditions[1].value, @"10");
	XCTAssertEqualObjects(fetch.conditions[1].secondValue, @"20");
}

- (void)testIncompleteConditionIsNotSent
{
	[self open];
	[self.picker addCondition];
	SPForeignKeyConditionRow *row = (SPForeignKeyConditionRow *)self.picker.conditionsView.arrangedSubviews[0];
	[self choose:@"name" inPopUp:row.columnPopUp];
	[self type:@"x"];
	[self spin:0.1];
	XCTAssertEqual(self.source.fetches.lastObject.conditions.count, 0u);
	[self choose:@"is NULL" inPopUp:row.operatorPopUp];
	[self spin:0.1];
	XCTAssertEqual(self.source.fetches.lastObject.conditions.count, 1u);
}

#pragma mark - Columns menu

- (void)testColumnsMenuKeyColumnDisabledAndTicked
{
	[self open];
	NSMenuItem *key = [self menuItemTitled:@"id"];
	XCTAssertEqual(key.state, NSControlStateValueOn);
	XCTAssertFalse(key.enabled);
	NSMenuItem *city = [self menuItemTitled:@"city"];
	XCTAssertEqual(city.state, NSControlStateValueOn);
	XCTAssertTrue(city.enabled);
	XCTAssertNotNil([self menuItemTitled:@"Show columns"]);
	XCTAssertNotNil([self menuItemTitled:@"Show All Columns"]);
	XCTAssertNotNil([self menuItemTitled:@"Reset to Default"]);
}

- (void)testUntickSavesAndRefetches
{
	[self open];
	NSUInteger before = self.source.fetches.count;
	[self pickMenuItem:@"city"];
	NSArray *expected = @[@"id", @"name", @"email", @"created_at"];
	XCTAssertEqualObjects(([self.settings shownColumnsForTableKey:@"k" available:@[@"id", @"name", @"email", @"city", @"created_at"] keyColumn:@"id"]), expected);
	XCTAssertEqual([self menuItemTitled:@"city"].state, NSControlStateValueOff);
	[self spin:0.1];
	XCTAssertEqual(self.source.fetches.count, before + 1);
	XCTAssertEqualObjects(self.source.fetches.lastObject.columns, expected);
	XCTAssertEqualObjects([[self.picker.resultsTable tableColumns] valueForKey:@"identifier"], expected);
	XCTAssertEqualObjects([[self.picker.searchField cell] placeholderString], @"Search name, email, created_at");
	// Ticking it again
	[self pickMenuItem:@"city"];
	XCTAssertEqual([self menuItemTitled:@"city"].state, NSControlStateValueOn);
}

- (void)testShowAllAndResetToDefault
{
	[self open];
	[self pickMenuItem:@"city"];
	[self pickMenuItem:@"email"];
	[self pickMenuItem:@"Show All Columns"];
	NSArray *all = @[@"id", @"name", @"email", @"city", @"created_at"];
	XCTAssertEqualObjects([[self.picker.resultsTable tableColumns] valueForKey:@"identifier"], all);
	XCTAssertNotNil([[self.defaults dictionaryForKey:@"ForeignKeyPickerShownColumns"] objectForKey:@"k"]);
	[self pickMenuItem:@"name"];
	[self pickMenuItem:@"Reset to Default"];
	XCTAssertNil([[self.defaults dictionaryForKey:@"ForeignKeyPickerShownColumns"] objectForKey:@"k"]);
	XCTAssertEqualObjects([[self.picker.resultsTable tableColumns] valueForKey:@"identifier"], all);
}

#pragma mark - Outcomes

- (void)testNullOnlyWhenAllowed
{
	[self openWithCurrent:nil allowNull:NO];
	XCTAssertTrue(self.picker.nullButton == nil || self.picker.nullButton.hidden);
	[self.picker chooseNull];
	XCTAssertEqual(self.outcomes.count, 0u);
	[self.picker cancel];
	self.picker = nil;
	[self.outcomes removeAllObjects];
	[self openWithCurrent:nil allowNull:YES];
	XCTAssertFalse(self.picker.nullButton.hidden);
	[self.picker chooseNull];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerChoseNull), [NSNull null]]]));
}

- (void)testChooseReturnsKeyText
{
	[self open];
	[self.picker.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
	[self.picker choose];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerChose), @"3"]]));
}

- (void)testChooseWithoutSelectionDoesNothing
{
	[self open];
	[self.picker.resultsTable deselectAll:nil];
	[self.picker choose];
	XCTAssertEqual(self.outcomes.count, 0u);
}

- (void)testDoubleClickAndReturnChoose
{
	[self open];
	NSTableView *table = self.picker.resultsTable;
	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:4] byExtendingSelection:NO];
	XCTAssertTrue([NSApp sendAction:[table doubleAction] to:[table target] from:table]);
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerChose), @"5"]]));

	[self.outcomes removeAllObjects];
	self.picker = nil;
	[self open];
	[self.picker.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:6] byExtendingSelection:NO];
	[self key:@selector(insertNewline:)];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerChose), @"7"]]));
}

- (void)testArrowKeysMoveSelectionFromSearchField
{
	[self open];
	[self.picker.resultsTable deselectAll:nil];
	[self key:@selector(moveDown:)];
	XCTAssertEqual(self.picker.resultsTable.selectedRow, 0);
	[self key:@selector(moveDown:)];
	XCTAssertEqual(self.picker.resultsTable.selectedRow, 1);
	[self key:@selector(moveUp:)];
	XCTAssertEqual(self.picker.resultsTable.selectedRow, 0);
	[self key:@selector(moveUp:)];
	XCTAssertEqual(self.picker.resultsTable.selectedRow, 0);
}

- (void)testEscapeCancels
{
	[self open];
	[self key:@selector(cancelOperation:)];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerCancelled), [NSNull null]]]));
}

- (void)testNullRowKeyCannotBeChosen
{
	self.source.rowsProvider = ^NSArray *(SPFKFakeFetch *fetch) {
		return @[@[[NSNull null], @"nobody", @"", @"", @""], @[@"1", @"one", @"", @"", @""]];
	};
	[self open];
	[self.picker.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[self.picker choose];
	XCTAssertEqual(self.outcomes.count, 0u);
	[self.picker.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
	[self.picker choose];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerChose), @"1"]]));
}

- (void)testTypeValueAndCancelOutcomes
{
	[self open];
	[self.picker typeValue];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerTypeValue), [NSNull null]]]));
	[self.outcomes removeAllObjects];
	self.picker = nil;
	[self open];
	[self.picker cancel];
	XCTAssertEqualObjects(self.outcomes, (@[@[@(SPForeignKeyPickerCancelled), [NSNull null]]]));
}

- (void)testCompletionCalledOnce
{
	[self open];
	[self.picker.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[self.picker choose];
	[self.picker cancel];
	[self.picker typeValue];
	[self.picker chooseNull];
	XCTAssertEqual(self.outcomes.count, 1u);
}

- (void)testResultsAfterFinishingAreDropped
{
	[self open];
	[self.source.delays addObject:@0.2];
	[self type:@"Person 9"];
	[self.picker cancel];
	[self spin:0.4];
	XCTAssertEqual(self.outcomes.count, 1u);
}

#pragma mark - List

- (void)testCurrentValueRowIsTinted
{
	[self openWithCurrent:@"23" allowNull:YES];
	XCTAssertEqual(self.picker.currentValueRow, 22);
	[self type:@"Person 1"];
	[self spinUntil:^BOOL{ return self.picker.rows.count < 200; }];
	XCTAssertEqual(self.picker.currentValueRow, -1);
}

- (void)testLoadMoreAppendsNextPageAndFooterCounts
{
	[self open];
	XCTAssertEqual(self.picker.rows.count, 200u);
	XCTAssertEqualObjects(self.picker.statusText, @"200 shown, more…");
	XCTAssertFalse(self.picker.loadMoreButton.hidden);
	[self.picker loadMore];
	[self spinUntil:^BOOL{ return self.picker.rows.count == 255; }];
	XCTAssertEqual(self.source.fetches.lastObject.offset, 200u);
	XCTAssertEqualObjects(self.picker.statusText, @"255 matches");
	XCTAssertTrue(self.picker.loadMoreButton.hidden);
	XCTAssertEqualObjects(self.picker.rows[200][0], @"201");
}

- (void)testErrorMessageReplacesList
{
	self.source.errorMessage = @"permission denied for table customers";
	[self open];
	XCTAssertEqualObjects(self.picker.errorMessage, @"permission denied for table customers");
	XCTAssertEqual(self.picker.rows.count, 0u);
	XCTAssertTrue(self.picker.resultsTable.enclosingScrollView.hidden);
	// Still usable
	[self.picker typeValue];
	XCTAssertEqual(self.outcomes.count, 1u);
}

@end
