#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableData.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPPostgresStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPPostgresStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	[self.statements addObject:[query description]];
}
@end

@interface SPPostgresTableDataTests : XCTestCase
@end

@implementation SPPostgresTableDataTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	for (NSNumber *port in [SPPostgresTestServers ports]) [SPPostgresTestServers loadFixtureNamed:@"content" onPort:port.unsignedIntegerValue];
}

#pragma mark - Helpers

- (SPPostgresTableData *)dataOnPort:(NSNumber *)port table:(NSString *)table
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	return [[SPPostgresTableData alloc] initWithConnection:connection schema:@"content_test" table:table];
}

- (NSUInteger)indexOfColumn:(NSString *)name in:(SPPostgresTableData *)data
{
	NSArray *columns = [data columns:NULL];
	for (NSUInteger i = 0; i < columns.count; i++) {
		if ([[columns[i] name] isEqualToString:name]) return i;
	}
	XCTFail(@"No column %@", name);
	return NSNotFound;
}

/// All rows of items ordered by id.
- (NSArray *)allRowsOf:(SPPostgresTableData *)data
{
	NSError *error = nil;
	NSArray *rows = [data rowsWithFilter:nil sortColumn:@"id" ascending:YES offset:0 limit:1000 error:&error];
	XCTAssertNotNil(rows, @"%@", error);
	return rows;
}

- (NSArray *)rowWithId:(NSString *)rowId in:(SPPostgresTableData *)data
{
	NSError *error = nil;
	NSArray *rows = [data rowsWithFilter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"=" value:rowId]
							  sortColumn:nil ascending:YES offset:0 limit:10 error:&error];
	XCTAssertEqual(rows.count, 1u, @"%@", error);
	return rows.firstObject;
}

- (NSArray *)firstColumnOf:(NSArray *)rows
{
	NSMutableArray *values = [NSMutableArray array];
	for (NSArray *row in rows) [values addObject:row.firstObject];
	return values;
}

- (NSArray *)idsOf:(SPPostgresTableData *)data filter:(SPPostgresFilter *)filter
{
	NSError *error = nil;
	NSArray *rows = [data rowsWithFilter:filter sortColumn:@"id" ascending:YES offset:0 limit:1000 error:&error];
	XCTAssertNotNil(rows, @"%@ %@: %@", filter.column, filter.comparison, error);
	NSMutableArray *ids = [NSMutableArray array];
	for (NSArray *row in rows) [ids addObject:@([row[0] integerValue])];
	return ids;
}

#pragma mark - Tests

- (void)testColumnsInOrderWithTypesAndKeys
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSError *error = nil;
		NSArray *columns = [[self dataOnPort:port table:@"items"] columns:&error];
		XCTAssertNotNil(columns, @"%@", error);
		XCTAssertEqualObjects([columns valueForKey:@"name"],
							  (@[@"id", @"name", @"note", @"price", @"flags", @"tags", @"doc", @"blob", @"ts", @"Mixed Case"]));

		SPPostgresColumn *idColumn = columns[0];
		XCTAssertTrue(idColumn.isPrimaryKey);
		XCTAssertEqual(idColumn.primaryKeyPosition, 1);
		XCTAssertFalse(idColumn.nullable);
		XCTAssertTrue([idColumn.defaultExpression hasPrefix:@"nextval("], @"%@", idColumn.defaultExpression);
		XCTAssertFalse(idColumn.isGenerated);

		SPPostgresColumn *price = columns[3];
		XCTAssertEqualObjects(price.typeName, @"numeric(20,6)");
		XCTAssertEqualObjects(price.castTypeName, @"numeric");
		XCTAssertFalse(price.isPrimaryKey);
		XCTAssertEqual(price.primaryKeyPosition, 0);
		XCTAssertTrue(price.nullable);
		XCTAssertNil(price.defaultExpression);
		XCTAssertEqualObjects([columns[5] typeName], @"text[]");

		NSArray *generated = [[self dataOnPort:port table:@"generated_cols"] columns:&error];
		XCTAssertNotNil(generated, @"%@", error);
		XCTAssertTrue([generated[0] isGenerated]);   // identity ALWAYS
		XCTAssertFalse([generated[1] isGenerated]);  // identity BY DEFAULT
		XCTAssertFalse([generated[2] isGenerated]);
		XCTAssertTrue([generated[3] isGenerated]);   // GENERATED ALWAYS AS (…) STORED
		XCTAssertNil([generated[3] defaultExpression]);
		XCTAssertEqualObjects([generated[2] defaultExpression], @"7");

		NSArray *composite = [[self dataOnPort:port table:@"composite_pk"] columns:&error];
		XCTAssertEqual([composite[0] primaryKeyPosition], 1);
		XCTAssertEqual([composite[1] primaryKeyPosition], 2);
		XCTAssertFalse([composite[2] isPrimaryKey]);
	}
}

- (void)testRowsAreTextAndNullIsNSNull
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSArray *rows = [self allRowsOf:data];
		XCTAssertEqual(rows.count, 30u);
		NSUInteger note = [self indexOfColumn:@"note" in:data];
		XCTAssertEqualObjects(rows[0][note], [NSNull null]);
		XCTAssertEqualObjects(rows[1][note], @"");
		XCTAssertEqual([rows[2][1] length], 10000u);

		NSArray *odd = rows[3];
		XCTAssertEqualObjects(odd[0], @"4");
		XCTAssertEqualObjects(odd[[self indexOfColumn:@"price" in:data]], @"12345678901234.123456");
		XCTAssertEqualObjects(odd[[self indexOfColumn:@"flags" in:data]], @"true");
		XCTAssertEqualObjects(odd[[self indexOfColumn:@"tags" in:data]], @"{a,\"b c\"}");
		XCTAssertEqualObjects(odd[[self indexOfColumn:@"blob" in:data]], @"\\x00ff");
		XCTAssertEqualObjects(odd[[self indexOfColumn:@"Mixed Case" in:data]], @"mixed 4");
		for (id value in odd) XCTAssertTrue([value isKindOfClass:[NSString class]]);
	}
}

- (void)testOddValuesRoundTripThroughUnrelatedEdit
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSArray *before = [self rowWithId:@"4" in:data];
		NSError *error = nil;
		XCTAssertTrue([data updateRow:before column:@"name" value:@"renamed" error:&error], @"%@", error);

		NSArray *after = [self rowWithId:@"4" in:data];
		NSUInteger name = [self indexOfColumn:@"name" in:data];
		XCTAssertEqualObjects(after[name], @"renamed");
		for (NSUInteger i = 0; i < before.count; i++) {
			if (i == name) continue;
			XCTAssertEqualObjects(after[i], before[i], @"column %lu changed", (unsigned long)i);
		}

		// Editing an odd value itself with its own text also round-trips, and NULL is written as NULL.
		NSUInteger doc = [self indexOfColumn:@"doc" in:data];
		XCTAssertTrue([data updateRow:after column:@"doc" value:after[doc] error:&error], @"%@", error);
		XCTAssertEqualObjects([self rowWithId:@"4" in:data][doc], after[doc]);
		XCTAssertTrue([data updateRow:after column:@"note" value:[NSNull null] error:&error], @"%@", error);
		XCTAssertEqualObjects([self rowWithId:@"4" in:data][[self indexOfColumn:@"note" in:data]], [NSNull null]);
	}
}

- (void)testSortAndPaging
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSError *error = nil;
		NSArray *rows = [[self dataOnPort:port table:@"items"] rowsWithFilter:nil sortColumn:@"id" ascending:NO offset:10 limit:5 error:&error];
		XCTAssertNotNil(rows, @"%@", error);
		XCTAssertEqualObjects([self firstColumnOf:rows], (@[@"20", @"19", @"18", @"17", @"16"]));

		// Numeric sort is by value, not text.
		rows = [[self dataOnPort:port table:@"items"] rowsWithFilter:nil sortColumn:@"price" ascending:YES offset:0 limit:3 error:&error];
		XCTAssertEqualObjects([self firstColumnOf:rows], (@[@"1", @"2", @"3"]));

		// limit 0 means unlimited.
		rows = [[self dataOnPort:port table:@"items"] rowsWithFilter:nil sortColumn:@"id" ascending:YES offset:25 limit:0 error:&error];
		XCTAssertEqualObjects([self firstColumnOf:rows], (@[@"26", @"27", @"28", @"29", @"30"]), @"%@", error);
		XCTAssertEqual([[[self dataOnPort:port table:@"items"] rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:0 error:&error] count], 30u);

		XCTAssertNil([[self dataOnPort:port table:@"items"] rowsWithFilter:nil sortColumn:@"nope" ascending:YES offset:0 limit:3 error:&error]);
		XCTAssertNotNil(error);
	}
}

- (void)testFilterOperators
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"name" comparison:@"=" value:@"item 5"]], (@[@5]));
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"name" comparison:@"ILIKE" value:@"ITEM 2_"]],
							  (@[@20, @21, @22, @23, @24, @25, @26, @27, @28, @29]));
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"note" comparison:@"IS NULL" value:nil]], (@[@1]));
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"IN" value:@"1,2,3"]], (@[@1, @2, @3]));
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"IN" value:@" 7 , 9"]], (@[@7, @9]));
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"price" comparison:@">" value:@"40"]],
							  (@[@4, @27, @28, @29, @30]));
		XCTAssertEqual([[self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"≠" value:@"1"]] count], 29u);
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"tags" comparison:@"LIKE" value:@"%b c%"]], (@[@4]));
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"Mixed Case" comparison:@"<=" value:@"mixed 10"]],
							  (@[@1, @10]));

		NSError *error = nil;
		XCTAssertEqual([data countRowsWithFilter:[SPPostgresFilter filterWithColumn:@"note" comparison:@"IS NOT NULL" value:nil] error:&error], 29, @"%@", error);
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 30, @"%@", error);

		// Hostile text is only ever a parameter.
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"name" comparison:@"=" value:@"x'; DROP TABLE content_test.items; --"]], (@[]));
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 30);

		XCTAssertNil([data rowsWithFilter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"; DROP" value:@"1"] sortColumn:nil ascending:YES offset:0 limit:5 error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, @"The filter operator “; DROP” is not supported.");
		error = nil;
		XCTAssertNil([data rowsWithFilter:[SPPostgresFilter filterWithColumn:@"id" comparison:nil value:@"1"] sortColumn:nil ascending:YES offset:0 limit:5 error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, @"No filter operator was chosen.");

		// IN drops empty items (a trailing comma); a list with no items at all is refused.
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"IN" value:@"1,2,"]], (@[@1, @2]));
		error = nil;
		XCTAssertNil([data rowsWithFilter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"IN" value:@" , "] sortColumn:nil ascending:YES offset:0 limit:5 error:&error]);
		XCTAssertNotNil(error);
	}
}

- (void)testCompositeKeyUpdateTouchesOneRow
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"composite_pk"];
		NSError *error = nil;
		NSArray *rows = [data rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:10 error:&error];
		XCTAssertEqualObjects(rows, (@[@[@"1", @"a", @"v1"], @[@"1", @"b", @"v2"], @[@"2", @"a", @"v3"]]), @"%@", error);
		XCTAssertTrue([data updateRow:rows[0] column:@"v" value:@"changed" error:&error], @"%@", error);
		XCTAssertEqualObjects([data rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:10 error:&error],
							  (@[@[@"1", @"a", @"changed"], @[@"1", @"b", @"v2"], @[@"2", @"a", @"v3"]]));
	}
}

- (void)testNoPrimaryKeyIsReadOnly
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresStatementRecorder *recorder = [[SPPostgresStatementRecorder alloc] init];
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:recorder];
		XCTAssertNotNil(connection);
		SPPostgresTableData *data = [[SPPostgresTableData alloc] initWithConnection:connection schema:@"content_test" table:@"no_pk"];

		XCTAssertFalse([data isEditable]);
		XCTAssertEqualObjects([data readOnlyReason], @"This table has no primary key, so its rows can't be edited.");
		NSError *error = nil;
		NSArray *rows = [data rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:10 error:&error];
		XCTAssertEqual(rows.count, 2u, @"%@", error);

		XCTAssertTrue(recorder.statements.count > 0, @"the recorder must see the connection's statements");
		[recorder.statements removeAllObjects];
		XCTAssertFalse([data updateRow:rows[0] column:@"y" value:@"changed" error:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorNotEditable);
		XCTAssertFalse([data deleteRows:@[rows[0]] error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorNotEditable);
		XCTAssertNil([data insertRowWithValues:@{@"y": @"new"} error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorNotEditable);
		XCTAssertEqualObjects(recorder.statements, (@[]), @"no SQL may be sent for a read-only table");

		XCTAssertEqualObjects([data rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:10 error:&error],
							  (@[@[@"1", @"same"], @[@"1", @"same"]]));
		[connection disconnect];
	}
}

- (void)testUpdateOfVanishedRowReportsRowChanged
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSArray *row = [self rowWithId:@"7" in:data];

		PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		XCTAssertNotNil([other execute:@"DELETE FROM content_test.items WHERE id = 7"]);
		[other disconnect];

		NSError *error = nil;
		XCTAssertFalse([data updateRow:row column:@"name" value:@"too late" error:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorRowChanged);
		XCTAssertTrue(error.localizedDescription.length > 0);
	}
}

- (void)testInsertUsesDefaultsAndReturnsRow
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSError *error = nil;
		NSArray *row = [data insertRowWithValues:@{@"name": @"inserted"} error:&error];
		XCTAssertNotNil(row, @"%@", error);
		XCTAssertEqual(row.count, 10u);
		XCTAssertTrue([row[0] isKindOfClass:[NSString class]] && [row[0] length] > 0);
		XCTAssertEqualObjects(row[0], @"31");
		XCTAssertEqualObjects(row[1], @"inserted");
		XCTAssertEqualObjects(row[2], [NSNull null]);
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 31);

		NSDictionary *values = @{@"name": [NSNull null], @"tags": @"{x,y}", @"Mixed Case": @"m"};
		row = [data insertRowWithValues:values error:&error];
		XCTAssertNotNil(row, @"%@", error);
		XCTAssertEqualObjects(row[1], [NSNull null]);
		XCTAssertEqualObjects(row[5], @"{x,y}");
		XCTAssertEqualObjects(row[9], @"m");

		XCTAssertNil([data insertRowWithValues:@{@"nope": @"1"} error:&error]);
		XCTAssertNotNil(error);
		XCTAssertNil([data insertRowWithValues:@{@"price": @"not a number"} error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
	}
}

- (void)testDeleteRowsByKey
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSError *error = nil;
		NSArray *doomed = @[[self rowWithId:@"5" in:data], [self rowWithId:@"6" in:data]];
		XCTAssertTrue([data deleteRows:doomed error:&error], @"%@", error);
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 28);
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"IN" value:@"4,5,6,7"]], (@[@4, @7]));

		// One row already gone: nothing is deleted (the transaction is rolled back) and the caller is told.
		NSArray *eight = [self rowWithId:@"8" in:data];
		NSArray *nine = [self rowWithId:@"9" in:data];
		PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		XCTAssertNotNil([other execute:@"DELETE FROM content_test.items WHERE id = 9"]);
		[other disconnect];
		NSArray *both = @[eight, nine];
		XCTAssertFalse([data deleteRows:both error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorRowChanged);
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"=" value:@"8"]], (@[@8]));
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 27, @"%@", error); // connection usable, not left in a transaction

		// Composite keys: only the named row goes.
		SPPostgresTableData *composite = [self dataOnPort:port table:@"composite_pk"];
		NSArray *middle = @[@[@"1", @"b", @"v2"]];
		XCTAssertTrue([composite deleteRows:middle error:&error], @"%@", error);
		XCTAssertEqualObjects([composite rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:10 error:&error],
							  (@[@[@"1", @"a", @"v1"], @[@"2", @"a", @"v3"]]));
	}
}

- (void)testFixedWidthCharAndBitRoundTripAndRejectTooLong
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"fixed_width"];
		NSError *error = nil;
		NSArray *columns = [data columns:&error];
		XCTAssertEqualObjects([columns[0] typeName], @"character(3)");
		XCTAssertEqualObjects([columns[0] castTypeName], @"bpchar");
		XCTAssertEqualObjects([columns[2] typeName], @"bit(3)");
		XCTAssertEqualObjects([columns[2] castTypeName], @"\"bit\"");

		NSArray *rows = [data rowsWithFilter:nil sortColumn:@"k" ascending:YES offset:0 limit:0 error:&error];
		XCTAssertEqualObjects(rows, (@[@[@"a", @"abc", @"101"], @[@"abc", @"xyz", @"010"]]), @"%@", error);

		// Full-width writes round-trip (a cast to "character" would keep 1 char, to "bit" 1 bit).
		XCTAssertTrue([data updateRow:rows[1] column:@"c" value:@"qrs" error:&error], @"%@", error);
		XCTAssertTrue([data updateRow:rows[1] column:@"b" value:@"111" error:&error], @"%@", error);
		NSArray *inserted = [data insertRowWithValues:@{@"k": @"bcd", @"c": @"def", @"b": @"110"} error:&error];
		XCTAssertEqualObjects(inserted, (@[@"bcd", @"def", @"110"]), @"%@", error);

		// The char(3) key "abc" must not be truncated to "a" and hit the other row.
		XCTAssertEqualObjects([data rowsWithFilter:nil sortColumn:@"k" ascending:YES offset:0 limit:0 error:&error],
							  (@[@[@"a", @"abc", @"101"], @[@"abc", @"qrs", @"111"], @[@"bcd", @"def", @"110"]]));

		// Filters compare full values.
		XCTAssertEqual([data countRowsWithFilter:[SPPostgresFilter filterWithColumn:@"c" comparison:@"=" value:@"qrs"] error:&error], 1);
		XCTAssertEqual([data countRowsWithFilter:[SPPostgresFilter filterWithColumn:@"c" comparison:@"=" value:@"q"] error:&error], 0);
		XCTAssertEqual([data countRowsWithFilter:[SPPostgresFilter filterWithColumn:@"b" comparison:@"=" value:@"111"] error:&error], 1);

		// Too long: an error, not silent truncation.
		error = nil;
		XCTAssertFalse([data updateRow:rows[0] column:@"c" value:@"abcd" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		error = nil;
		XCTAssertFalse([data updateRow:rows[0] column:@"b" value:@"1111" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertEqualObjects([data rowsWithFilter:[SPPostgresFilter filterWithColumn:@"k" comparison:@"=" value:@"a"] sortColumn:nil ascending:YES offset:0 limit:0 error:&error],
							  (@[@[@"a", @"abc", @"101"]]));
	}
}

- (void)testEditingThePrimaryKeyItself
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSArray *row = [self rowWithId:@"10" in:data];
		NSError *error = nil;
		XCTAssertTrue([data updateRow:row column:@"id" value:@"100" error:&error], @"%@", error);
		XCTAssertEqualObjects([self idsOf:data filter:[SPPostgresFilter filterWithColumn:@"id" comparison:@"IN" value:@"10,100"]], (@[@100]));
		XCTAssertEqualObjects([self rowWithId:@"100" in:data][1], @"item 10");
		// The stale row (old key) is now gone.
		XCTAssertFalse([data updateRow:row column:@"name" value:@"x" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorRowChanged);

		// Composite key: change one part of the key.
		SPPostgresTableData *composite = [self dataOnPort:port table:@"composite_pk"];
		NSArray *first = @[@"1", @"a", @"v1"];
		XCTAssertTrue([composite updateRow:first column:@"b" value:@"z" error:&error], @"%@", error);
		XCTAssertEqualObjects([composite rowsWithFilter:nil sortColumn:nil ascending:YES offset:0 limit:0 error:&error],
							  (@[@[@"1", @"b", @"v2"], @[@"1", @"z", @"v1"], @[@"2", @"a", @"v3"]]));
	}
}

- (void)testDeleteDropsDuplicateKeys
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSArray *row = [self rowWithId:@"12" in:data];
		NSError *error = nil;
		NSArray *twice = @[row, row];
		XCTAssertTrue([data deleteRows:twice error:&error], @"%@", error);
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 29);
	}
}

- (void)testSuccessiveServerErrorsOnOneConnection
{
	// PGPostgresError used to over-release its strings, crashing once a second error replaced the first.
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items"];
		NSArray *row = [self rowWithId:@"1" in:data];
		for (int i = 0; i < 3; i++) {
			@autoreleasepool {
				NSError *error = nil;
				XCTAssertFalse([data updateRow:row column:@"price" value:@"not a number" error:&error]);
				XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
				XCTAssertTrue(error.localizedDescription.length > 0);
			}
		}
	}
}

- (void)testTransactionStatusAccessor
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle);
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInError);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle);
		[connection disconnect];
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionUnknown);
	}
}

- (void)testDeleteInsideUserTransactionUsesSavepoint
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		SPPostgresTableData *data = [[SPPostgresTableData alloc] initWithConnection:connection schema:@"content_test" table:@"items"];
		NSArray *row = [self rowWithId:@"15" in:data];
		NSArray *other = [self rowWithId:@"16" in:data];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		NSArray *one = @[row];
		XCTAssertTrue([data deleteRows:one error:&error], @"%@", error);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction, @"the user's transaction stays open");
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 29);

		// A failed delete inside the transaction undoes only its own work, and the transaction stays usable.
		NSArray *ghost = @[@"999", @"g", [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null]];
		NSArray *mixed = @[other, ghost];
		XCTAssertFalse([data deleteRows:mixed error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorRowChanged);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction);
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 29, @"%@", error);

		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqual([data countRowsWithFilter:nil error:&error], 30, @"the rolled-back delete is undone");
		XCTAssertEqualObjects([self rowWithId:@"15" in:data], row);

		// Inside an aborted transaction: refused, nothing sent that would end the transaction.
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		error = nil;
		XCTAssertFalse([data deleteRows:one error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"aborted"], @"%@", error);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInError);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		[connection disconnect];
	}
}

- (void)testViewIsReadOnly
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"items_view"];
		XCTAssertFalse([data isEditable]);
		XCTAssertNotNil([data readOnlyReason]);
		NSError *error = nil;
		XCTAssertEqual([[data rowsWithFilter:nil sortColumn:@"id" ascending:YES offset:0 limit:100 error:&error] count], 30u, @"%@", error);
		NSArray *viewRow = @[@"1", @"item 1"];
		XCTAssertFalse([data updateRow:viewRow column:@"name" value:@"x" error:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorNotEditable);

		SPPostgresTableData *items = [self dataOnPort:port table:@"items"];
		XCTAssertTrue([items isEditable]);
		XCTAssertNil([items readOnlyReason]);
	}
}

- (void)testMissingTableIsAnError
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableData *data = [self dataOnPort:port table:@"does_not_exist"];
		NSError *error = nil;
		XCTAssertNil([data columns:&error]);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertFalse([data isEditable]);
	}
}

@end
