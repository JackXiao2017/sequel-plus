//
//  PGPostgresTimeInterval.m
//  PostgresKit
//
//  Created by Stuart Connolly (stuconnolly.com) on September 9, 2012.
//  Copyright (c) 2012 Stuart Connolly. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.

#import "PGPostgresTimeInterval.h"
#import "PGPostgresKitPrivateAPI.h"

@implementation PGPostgresTimeInterval

@synthesize microseconds = _microseconds;
@synthesize seconds = _seconds;
@synthesize minutes = _minutes;
@synthesize hours = _hours;
@synthesize days = _days;
@synthesize months = _months;
@synthesize years = _years;

#pragma mark -

+ (id)intervalWithYears:(NSInteger)years months:(NSInteger)months days:(NSInteger)days hours:(NSInteger)hours minutes:(NSInteger)minutes seconds:(NSInteger)seconds microseconds:(NSInteger)microseconds
{
	return [[[PGPostgresTimeInterval alloc] initWithYears:years months:months days:days hours:hours minutes:minutes seconds:seconds microseconds:microseconds] autorelease];
}

- (id)initWithYears:(NSInteger)years months:(NSInteger)months days:(NSInteger)days hours:(NSInteger)hours minutes:(NSInteger)minutes seconds:(NSInteger)seconds microseconds:(NSInteger)microseconds
{
	if ((self = [super init])) {
		_microseconds = microseconds;
		_seconds = seconds;
		_minutes = minutes;
		_hours = hours;
		_days = days;
		_months = months;
		_years = years;
	}
	
	return self;
}

#pragma mark -

- (NSString *)description
{
	return [NSString stringWithFormat:@"%lu years, %lu months, %lu days, %lu hours, %lu minutes, %lu seconds and %lu microseconds",
			(unsigned long)_years, (unsigned long)_months, (unsigned long)_days, (unsigned long)_hours, (unsigned long)_minutes, (unsigned long)_seconds, (unsigned long)_microseconds];
}

@end
