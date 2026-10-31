#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresCheckList.h"
#import "../Source/Postgres/SPPostgresCatalog.h"

/// The checkbox list shared by Export and Transfer.
@interface SPPostgresCheckListTests : XCTestCase
@property (strong) NSView *host;
@property (strong) SPPostgresCheckList *list;
@end

@implementation SPPostgresCheckListTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
	self.list = [[SPPostgresCheckList alloc] initWithFrame:NSMakeRect(0, 0, 300, 200) inView:self.host];
	self.list.groupsByFirstElement = YES;
	self.list.rows = @[@"public", @[@"public", @"a"], @[@"public", @"b"], @"other", @[@"other", @"c"]];
}

- (id)value:(NSString *)column row:(NSInteger)row
{
	NSTableView *table = self.list.tableView;
	return [self.list tableView:table objectValueForTableColumn:[table tableColumnWithIdentifier:column] row:row];
}

- (void)testGroupRowsHaveNoCheckbox
{
	NSTableView *table = self.list.tableView;
	XCTAssertEqual([table numberOfRows], 5);
	XCTAssertTrue([self.list tableView:table isGroupRow:0]);
	XCTAssertFalse([self.list tableView:table isGroupRow:1]);
	XCTAssertNil([self value:@"check" row:0]);
	XCTAssertEqualObjects([self value:@"name" row:0], @"public");
	XCTAssertEqualObjects([self value:@"name" row:1], @"a");
	XCTAssertEqualObjects([self value:@"check" row:1], @NO);
	XCTAssertFalse([self.list tableView:table shouldTrackCell:[[NSCell alloc] init] forTableColumn:[table tableColumnWithIdentifier:@"check"] row:0]);
	XCTAssertTrue([self.list tableView:table shouldTrackCell:[[NSCell alloc] init] forTableColumn:[table tableColumnWithIdentifier:@"check"] row:1]);
	// A group row can't be checked
	[self.list tableView:table setObjectValue:@YES forTableColumn:[table tableColumnWithIdentifier:@"check"] row:0];
	XCTAssertEqual([self.list.checkedItems count], 0u);
}

- (void)testPlainStringItemsWithoutGroups
{
	self.list.groupsByFirstElement = NO;
	self.list.rows = @[@"x", @"y"];
	[self.list setChecked:YES item:@"y"];
	XCTAssertFalse([self.list tableView:self.list.tableView isGroupRow:0]);
	XCTAssertEqualObjects([self value:@"name" row:1], @"y");
	XCTAssertEqualObjects([self value:@"check" row:1], @YES);
	XCTAssertEqualObjects(self.list.checkedItems, @[@"y"]);
}

- (void)testCheckedItemsInRowOrder
{
	[self.list setChecked:YES item:@[@"other", @"c"]];
	[self.list setChecked:YES item:@[@"public", @"b"]];
	[self.list setChecked:YES item:@[@"public", @"a"]];
	XCTAssertEqualObjects(self.list.checkedItems, (@[@[@"public", @"a"], @[@"public", @"b"], @[@"other", @"c"]]));
	[self.list setChecked:NO item:@[@"public", @"b"]];
	XCTAssertEqualObjects(self.list.checkedItems, (@[@[@"public", @"a"], @[@"other", @"c"]]));
}

- (void)testSettingRowsKeepsChecksOfItemsStillPresent
{
	[self.list setChecked:YES item:@[@"public", @"a"]];
	[self.list setChecked:YES item:@[@"other", @"c"]];
	self.list.rows = @[@"public", @[@"public", @"a"]];
	XCTAssertEqualObjects(self.list.checkedItems, (@[@[@"public", @"a"]]));
	self.list.rows = @[@"other", @[@"other", @"c"], @"public", @[@"public", @"a"]];
	XCTAssertEqualObjects(self.list.checkedItems, (@[@[@"public", @"a"]]), @"a dropped item is not checked when it returns");
}

- (void)testChecksChangedCalledOnToggle
{
	__block int calls = 0;
	self.list.checksChanged = ^{ calls++; };
	NSTableView *table = self.list.tableView;
	[self.list tableView:table setObjectValue:@YES forTableColumn:[table tableColumnWithIdentifier:@"check"] row:2];
	XCTAssertEqual(calls, 1);
	XCTAssertEqualObjects(self.list.checkedItems, (@[@[@"public", @"b"]]));
	[self.list tableView:table setObjectValue:@YES forTableColumn:[table tableColumnWithIdentifier:@"name"] row:1];
	XCTAssertEqual(calls, 1, @"only the check column toggles");
}

- (void)testGroupedRowsForCatalog
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers ioConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_io_src"];
		XCTAssertNotNil(connection);
		[SPPostgresTestServers loadFixtureNamed:@"io_source" onPort:port.unsignedIntegerValue];
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];
		NSError *error = nil;
		NSArray *rows = [SPPostgresCheckList groupedRowsForCatalog:catalog error:&error];
		XCTAssertNil(error);
		XCTAssertTrue([rows containsObject:@"public"], @"port %@", port);
		XCTAssertTrue([rows containsObject:@"Sales Data"], @"port %@", port);
		XCTAssertTrue([rows containsObject:(@[@"Sales Data", @"Orders 2026"])], @"port %@", port);
		NSUInteger group = [rows indexOfObject:@"Sales Data"];
		XCTAssertTrue([rows[group + 1] isKindOfClass:[NSArray class]]);
		XCTAssertEqualObjects(rows[group + 1][0], @"Sales Data");
		[connection disconnect];
	}
}

@end
