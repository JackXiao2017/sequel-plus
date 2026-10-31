//
//  PGPostgresTypeDecodingTests.m
//  PostgresKit
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not 
//  use this file except in compliance with the License. You may obtain a copy of 
//  the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software 
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
//  License for the specific language governing permissions and limitations under
//  the License.

#import "PGPostgresTypeDecodingTests.h"

@interface PGPostgresTypeDecodingTests ()

- (id)_valueForSQL:(NSString *)sql;

@end

@implementation PGPostgresTypeDecodingTests

- (void)testNullIsNSNull
{
	XCTAssertEqualObjects([self _valueForSQL:@"NULL::int"], [NSNull null]);
}

- (void)testIntegerWidths
{
	XCTAssertEqualObjects([self _valueForSQL:@"(-32768)::int2"], [NSNumber numberWithShort:-32768]);
	XCTAssertEqualObjects([self _valueForSQL:@"(-2147483648)::int4"], [NSNumber numberWithInt:-2147483648]);
	XCTAssertEqualObjects([self _valueForSQL:@"9223372036854775807::int8"], [NSNumber numberWithLongLong:9223372036854775807LL]);
}

- (void)testBooleans
{
	XCTAssertEqualObjects([self _valueForSQL:@"true"], [NSNumber numberWithInt:1]);
	XCTAssertEqualObjects([self _valueForSQL:@"false"], [NSNumber numberWithInt:0]);
}

- (void)testFloats
{
	XCTAssertEqualObjects([self _valueForSQL:@"0.1::float8"], [NSNumber numberWithDouble:0.1]);
	XCTAssertEqualObjects([self _valueForSQL:@"'-Infinity'::float8"], [NSNumber numberWithDouble:-INFINITY]);
}

- (void)testByteaIncludingEmbeddedZeroAndEmpty
{
	const unsigned char bytes[] = { 0x00, 0xff, 0x41, 0x00, 0x5c };
	
	XCTAssertEqualObjects([self _valueForSQL:@"'\\x00ff41005c'::bytea"], [NSData dataWithBytes:bytes length:5]);
	XCTAssertEqualObjects([self _valueForSQL:@"''::bytea"], [NSData data]);
}

- (void)testEmptyStringIsNotNull
{
	XCTAssertEqualObjects([self _valueForSQL:@"''::text"], @"");
}

- (void)testUTF8String
{
	XCTAssertEqualObjects([self _valueForSQL:@"'héllo €'::text"], @"héllo €");
}

- (void)testNetworkTypesAreStrings
{
	XCTAssertEqualObjects([self _valueForSQL:@"'08:00:2b:01:02:03'::macaddr"], @"08:00:2b:01:02:03");
	XCTAssertEqualObjects([self _valueForSQL:@"'192.168.1.5'::inet"], @"192.168.1.5");
	XCTAssertEqualObjects([self _valueForSQL:@"'10.0.0.0/8'::cidr"], @"10.0.0.0/8");
}

- (void)testInterval
{
	PGPostgresTimeInterval *interval = [self _valueForSQL:@"'1 year 14 months 3 days 04:05:06.5'::interval"];
	
	XCTAssertTrue([interval isKindOfClass:[PGPostgresTimeInterval class]]);
	XCTAssertEqual([interval years], (NSUInteger)2);
	XCTAssertEqual([interval months], (NSUInteger)2);
	XCTAssertEqual([interval days], (NSUInteger)3);
	XCTAssertEqual([interval hours], (NSUInteger)4);
	XCTAssertEqual([interval minutes], (NSUInteger)5);
	XCTAssertEqual([interval seconds], (NSUInteger)6);
	XCTAssertEqual([interval microseconds], (NSUInteger)500000);
}

- (void)testTimestampTZOffset
{
	[[self connection] execute:@"SET TIME ZONE INTERVAL '-05:30' HOUR TO MINUTE"];
	
	PGPostgresTimeTZ *value = [self _valueForSQL:@"'2000-01-01 12:00:00+00'::timestamptz"];
	
	XCTAssertTrue([value isKindOfClass:[PGPostgresTimeTZ class]]);
	XCTAssertEqualObjects([value date], [NSDate dateWithTimeIntervalSince1970:946728000]);
	XCTAssertEqual([[value timeZone] secondsFromGMT], (NSInteger)-(5 * 3600 + 30 * 60));
}

- (void)testInfinityTimestamp
{
	XCTAssertEqualObjects([self _valueForSQL:@"'infinity'::timestamp"], [NSDate distantFuture]);
	XCTAssertEqualObjects([self _valueForSQL:@"'-infinity'::timestamp"], [NSDate distantPast]);
}

#pragma mark -
#pragma mark Private API

- (id)_valueForSQL:(NSString *)sql
{
	PGPostgresResult *result = [[self connection] execute:[NSString stringWithFormat:@"SELECT %@ AS v", sql]];
	
	XCTAssertNotNil(result, @"Query failed: %@", sql);
	
	return [[result row] objectForKey:@"v"];
}

@end
