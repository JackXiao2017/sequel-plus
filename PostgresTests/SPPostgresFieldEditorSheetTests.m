#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFieldEditorSheet.h"

/// The shared field editor sheet. No test opens a real sheet.
@interface SPPostgresFieldEditorSheetTests : XCTestCase
@end

@implementation SPPostgresFieldEditorSheetTests

- (void)testMySQLOnlyTypesBlanked
{
	for (NSString *type in @[@"json", @"JSON", @"bit", @"float", @"Geometry", @"varbinary"]) {
		XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:type], @"", @"%@", type);
	}
	XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:nil], @"");
	XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:@"integer"], @"integer");
	XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:@"text"], @"text");
}

- (void)testNoWindowCompletesWithNil
{
	__block BOOL called = NO;
	__block id result = @"unset";
	[SPPostgresFieldEditorSheet editValue:@"v" columnName:@"c" typeName:@"text" editable:YES allowNull:YES window:nil
							   completion:^(id newValue) { called = YES; result = newValue; }];
	XCTAssertTrue(called, @"completes synchronously");
	XCTAssertNil(result);
}

@end
