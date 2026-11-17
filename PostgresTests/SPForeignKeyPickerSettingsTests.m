#import <XCTest/XCTest.h>
#import "../Source/SPForeignKeyPickerSettings.h"

static NSString * const SPFKSettingsSuite = @"SPForeignKeyPickerSettingsTests";

@interface SPForeignKeyPickerSettingsTests : XCTestCase
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) SPForeignKeyPickerSettings *settings;
@property (nonatomic, copy) NSString *key;
@end

@implementation SPForeignKeyPickerSettingsTests

- (void)setUp
{
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPFKSettingsSuite];
	self.defaults = [[NSUserDefaults alloc] initWithSuiteName:SPFKSettingsSuite];
	self.settings = [[SPForeignKeyPickerSettings alloc] initWithDefaults:self.defaults];
	self.key = [SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"127.0.0.1" port:5432 database:@"db" schema:@"public" table:@"customers"];
}

- (void)tearDown
{
	[self.defaults removePersistentDomainForName:SPFKSettingsSuite];
	self.defaults = nil;
}

- (void)testDefaultIsAllColumnsKeyFirst
{
	XCTAssertEqualObjects(([self.settings shownColumnsForTableKey:self.key available:@[@"name", @"id", @"email"] keyColumn:@"id"]), (@[@"id", @"name", @"email"]));
}

- (void)testRememberedColumnsInTableOrder
{
	[self.settings setShownColumns:@[@"email", @"name"] forTableKey:self.key];
	XCTAssertEqualObjects(([self.settings shownColumnsForTableKey:self.key available:@[@"id", @"name", @"email", @"city"] keyColumn:@"id"]), (@[@"id", @"name", @"email"]));
}

- (void)testDroppedColumnIsSkipped
{
	[self.settings setShownColumns:@[@"name", @"phone"] forTableKey:self.key];
	XCTAssertEqualObjects(([self.settings shownColumnsForTableKey:self.key available:@[@"id", @"name", @"email"] keyColumn:@"id"]), (@[@"id", @"name"]));
}

- (void)testRememberedSurvivesANewStoreOnTheSameDefaults
{
	[self.settings setShownColumns:@[@"name"] forTableKey:self.key];
	SPForeignKeyPickerSettings *other = [[SPForeignKeyPickerSettings alloc] initWithDefaults:self.defaults];
	XCTAssertEqualObjects(([other shownColumnsForTableKey:self.key available:@[@"id", @"name", @"email"] keyColumn:@"id"]), (@[@"id", @"name"]));
	XCTAssertNotNil([self.defaults dictionaryForKey:@"ForeignKeyPickerShownColumns"]);
}

- (void)testResetRemovesEntry
{
	[self.settings setShownColumns:@[@"name"] forTableKey:self.key];
	[self.settings setShownColumns:nil forTableKey:self.key];
	XCTAssertEqualObjects(([self.settings shownColumnsForTableKey:self.key available:@[@"id", @"name", @"email"] keyColumn:@"id"]), (@[@"id", @"name", @"email"]));
}

- (void)testKeysDifferPerKindServerDatabaseSchemaTable
{
	NSString *base = [SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:1 database:@"d" schema:@"s" table:@"t"];
	NSArray *others = @[
		[SPForeignKeyPickerSettings tableKeyWithKind:@"mysql" host:@"h" port:1 database:@"d" schema:@"s" table:@"t"],
		[SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h2" port:1 database:@"d" schema:@"s" table:@"t"],
		[SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:2 database:@"d" schema:@"s" table:@"t"],
		[SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:1 database:@"d2" schema:@"s" table:@"t"],
		[SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:1 database:@"d" schema:@"s2" table:@"t"],
		[SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:1 database:@"d" schema:nil table:@"t"],
		[SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:1 database:@"d" schema:@"s" table:@"t2"],
	];
	for (NSString *other in others) XCTAssertNotEqualObjects(base, other);
	XCTAssertEqualObjects(base, [SPForeignKeyPickerSettings tableKeyWithKind:@"postgres" host:@"h" port:1 database:@"d" schema:@"s" table:@"t"]);
	XCTAssertNotEqualObjects([SPForeignKeyPickerSettings tableKeyWithKind:@"mysql" host:@"h" port:1 database:@"a.b" schema:nil table:@"c"],
	                         [SPForeignKeyPickerSettings tableKeyWithKind:@"mysql" host:@"h" port:1 database:@"a" schema:nil table:@"b.c"]);
}

- (void)testPickerEnabledDefaultsToYesAndFollowsDefaults
{
	NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"PreferenceDefaults" ofType:@"plist"]];
	XCTAssertEqualObjects(plist[@"ForeignKeyPickerEnabled"], @YES);
	XCTAssertTrue([self.settings pickerEnabled]);
	[self.defaults setBool:NO forKey:@"ForeignKeyPickerEnabled"];
	XCTAssertFalse([self.settings pickerEnabled]);
	[self.defaults setBool:YES forKey:@"ForeignKeyPickerEnabled"];
	XCTAssertTrue([self.settings pickerEnabled]);
}

@end
