//
//  PGPostgresTypeDateTimeHandler.m
//  PostgresKit
//
//  Copyright (c) 2008-2009 David Thorpe, djt@mutablelogic.com
//
//  Forked by the Sequel Pro Team on July 22, 2012.
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

#import "PGPostgresTypeDateTimeHandler.h"
#import "PGPostgresTypeNumberHandler.h"
#import "PGPostgresConnectionParameters.h"
#import "PGPostgresConnection.h"
#import "PGPostgresConnectionTypeHandling.h"
#import "PGPostgresTimeTZ.h"
#import "PGPostgresTimeInterval.h"
#import "PGPostgresKitPrivateAPI.h"

static PGPostgresOid PGPostgresTypeDateTimeTypes[] = 
{
	PGPostgresOidDate,
	PGPostgresOidTime,
	PGPostgresOidTimeTZ,
	PGPostgresOidAbsTime,
	PGPostgresOidTimestamp,
	PGPostgresOidTimestampTZ,
	PGPostgresOidInterval,
	0 
};

// Parsed representations of PostgreSQL's ISO text output for the date/time types
typedef struct 
{
	long year, month, day;
	long hour, minute, second, microsecond;
	BOOL hasDate, hasTime, hasOffset;
	long gmtOffset; // Seconds east of UTC
} PGPostgresParsedTime;

static BOOL _PGParseNumber(const char **cursor, long *number, int minDigits);
static BOOL _PGParseDate(const char **cursor, PGPostgresParsedTime *parsed);
static BOOL _PGParseTime(const char **cursor, PGPostgresParsedTime *parsed);
static BOOL _PGParseTimestampString(const char *string, PGPostgresParsedTime *parsed);
static long long _PGDaysFromCivil(long year, long month, long day);

@interface PGPostgresTypeDateTimeHandler ()

- (id)_timeFromResult;
- (id)_timestmpFromResult;
- (id)_timeIntervalFromResult;

- (NSDate *)_dateFromResult;
- (NSDate *)_dateFromComponents:(NSDateComponents *)components;

@end

@implementation PGPostgresTypeDateTimeHandler

@synthesize row = _row;
@synthesize type = _type;
@synthesize column = _column;
@synthesize result = _result;

#pragma mark -
#pragma mark Protocol Implementation

- (PGPostgresOid *)remoteTypes 
{
	return PGPostgresTypeDateTimeTypes;
}

- (Class)nativeClass 
{
	return [NSDate class];
}

- (NSArray *)classAliases
{
	return nil;
}

- (id)objectFromResult
{	
	if (!_result || !_type) return [NSNull null];
	
	switch (_type) 
	{
		case PGPostgresOidDate:
			return [self _dateFromResult];
		case PGPostgresOidTime:
		case PGPostgresOidTimeTZ:
		case PGPostgresOidAbsTime:
			return [self _timeFromResult];
		case PGPostgresOidTimestamp:
		case PGPostgresOidTimestampTZ:
			return [self _timestmpFromResult];
		case PGPostgresOidInterval:
			return [self _timeIntervalFromResult];
	}
	
	return [NSNull null];
}

#pragma mark -
#pragma mark Private API

/**
 * Returns an NSDate created from a date value.
 * 
 * @return The NSDate representation.
 */
- (id)_dateFromResult
{	
	PGPostgresParsedTime parsed;
	
	if (!_PGParseTimestampString(PQgetvalue(_result, (int)_row, (int)_column), &parsed) || !parsed.hasDate) return [NSNull null];
		
	NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
	
	[components setDay:parsed.day];
	[components setMonth:parsed.month];
	[components setYear:parsed.year];
	
	return [self _dateFromComponents:components];
}

/**
 * Converts a time interval value to a PGPostgresTimeInterval instance.
 *
 * Intervals are requested using PostgreSQL's 'postgres' interval style, for example:
 * "1 year 2 mons -3 days +04:05:06.789".
 * 
 * @return The PGPostgresTimeInterval representation.
 */
- (id)_timeIntervalFromResult
{
	const char *cursor = PQgetvalue(_result, (int)_row, (int)_column);
	
	if (!cursor || !*cursor) return [NSNull null];
	
	long long months = 0, days = 0, timeMicroseconds = 0;
	
	while (*cursor)
	{
		while (*cursor == ' ') cursor++;
		
		if (!*cursor) break;
		
		BOOL negative = NO;
		
		if (*cursor == '+' || *cursor == '-') {
			negative = (*cursor == '-');
			cursor++;
		}
		
		long number = 0;
		
		if (!_PGParseNumber(&cursor, &number, 1)) return [NSNull null];
		
		if (*cursor == ':') {
			
			// Time portion: [H]H:MM:SS[.ffffff]
			long minutes = 0, seconds = 0, microseconds = 0;
			
			cursor++;
			
			if (!_PGParseNumber(&cursor, &minutes, 1)) return [NSNull null];
			
			if (*cursor == ':') {
				cursor++;
				
				if (!_PGParseNumber(&cursor, &seconds, 1)) return [NSNull null];
				
				if (*cursor == '.') {
					int digits = 0;
					
					cursor++;
					
					while (*cursor >= '0' && *cursor <= '9') 
					{
						if (digits < 6) { microseconds = microseconds * 10 + (*cursor - '0'); digits++; }
						
						cursor++;
					}
					
					while (digits++ < 6) microseconds *= 10;
				}
			}
			
			long long total = ((long long)number * 3600 + minutes * 60 + seconds) * 1000000LL + microseconds;
			
			timeMicroseconds += negative ? -total : total;
			
			continue;
		}
		
		// Unit portion: "year(s)", "mon(s)" or "day(s)"
		while (*cursor == ' ') cursor++;
		
		long long signedNumber = negative ? -(long long)number : number;
		
		if (*cursor == 'y') months += signedNumber * 12;
		else if (*cursor == 'm') months += signedNumber;
		else if (*cursor == 'd') days += signedNumber;
		else return [NSNull null];
		
		while (*cursor && *cursor != ' ') cursor++;
	}
	
	return [PGPostgresTimeInterval intervalWithYears:(NSInteger)(months / 12)
											  months:(NSInteger)(months % 12)
												days:(NSInteger)days
											   hours:(NSInteger)(timeMicroseconds / 3600000000LL)
											 minutes:(NSInteger)((timeMicroseconds / 60000000LL) % 60)
											 seconds:(NSInteger)((timeMicroseconds / 1000000LL) % 60)
										microseconds:(NSInteger)(timeMicroseconds % 1000000LL)];
}

/**
 * Returns a native object created from a time value.
 *
 * @note The date part should be ignored as it's set to a default value.
 *
 * @return The object representation.
 */
- (id)_timeFromResult
{
	PGPostgresParsedTime parsed;
	
	BOOL hasTimeZone = _type == PGPostgresOidTimeTZ;
	
	if (!_PGParseTimestampString(PQgetvalue(_result, (int)_row, (int)_column), &parsed) || !parsed.hasTime) return [NSNull null];
	
	NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
	
	// Default date values; should be ignored
	[components setDay:1];
	[components setMonth:1];
	[components setYear:2000];
	
	[components setHour:parsed.hour];
	[components setMinute:parsed.minute];
	[components setSecond:parsed.second];
	
	NSDate *date = [self _dateFromComponents:components];

	return hasTimeZone ? (id)[PGPostgresTimeTZ timeWithDate:date timeZoneGMTOffset:(NSUInteger)parsed.gmtOffset] : date;
}

/**
 * Returns a native object created from a timestamp value.
 *
 * @note Timestamps without a time zone are interpreted as UTC.
 *
 * @return The object representation.
 */
- (id)_timestmpFromResult
{
	PGPostgresParsedTime parsed;
	
	BOOL hasTimeZone = _type == PGPostgresOidTimestampTZ;
	
	const char *value = PQgetvalue(_result, (int)_row, (int)_column);
	
	if (!value) return [NSNull null];
	
	if (!strcmp(value, "infinity")) return [NSDate distantFuture];
	if (!strcmp(value, "-infinity")) return [NSDate distantPast];
	
	if (!_PGParseTimestampString(value, &parsed) || !parsed.hasDate || !parsed.hasTime) return [NSNull null];
	
	long long epoch = _PGDaysFromCivil(parsed.year, parsed.month, parsed.day) * 86400LL + parsed.hour * 3600 + parsed.minute * 60 + parsed.second;
	
	if (parsed.hasOffset) epoch -= parsed.gmtOffset;
	
	PGPostgresTimeTZ *timestampTZ = nil;
	NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)epoch];
	
	if (hasTimeZone) {
		timestampTZ = [PGPostgresTimeTZ timeWithDate:date timeZoneGMTOffset:(NSUInteger)parsed.gmtOffset];
		
		[timestampTZ setHasDate:YES];
	}
	
	return hasTimeZone ? (id)timestampTZ : date;
}

/**
 * Returns an NSDate created from the supplied components.
 *
 * @param The components to create the date from.
 *
 * @return The NSDate created.
 */
- (NSDate *)_dateFromComponents:(NSDateComponents *)components
{
	NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
	
	NSDate *date = [gregorian dateFromComponents:components];
	
	[gregorian release];
	
	return date;
}

@end

#pragma mark -
#pragma mark Text parsing helpers

/**
 * Parses an unsigned decimal number at the cursor, advancing it.
 */
static BOOL _PGParseNumber(const char **cursor, long *number, int minDigits)
{
	const char *p = *cursor;
	long value = 0;
	int digits = 0;
	
	while (*p >= '0' && *p <= '9') 
	{
		value = value * 10 + (*p - '0');
		
		digits++, p++;
	}
	
	if (digits < minDigits) return NO;
	
	*number = value;
	*cursor = p;
	
	return YES;
}

/**
 * Parses an ISO date ("YYYY-MM-DD", years may be longer than 4 digits) at the cursor.
 */
static BOOL _PGParseDate(const char **cursor, PGPostgresParsedTime *parsed)
{
	const char *p = *cursor;
	
	if (!_PGParseNumber(&p, &parsed->year, 1) || *p++ != '-') return NO;
	if (!_PGParseNumber(&p, &parsed->month, 1) || *p++ != '-') return NO;
	if (!_PGParseNumber(&p, &parsed->day, 1)) return NO;
	
	parsed->hasDate = YES;
	*cursor = p;
	
	return YES;
}

/**
 * Parses an ISO time ("HH:MM:SS[.ffffff][+-HH[:MM[:SS]]]") at the cursor.
 */
static BOOL _PGParseTime(const char **cursor, PGPostgresParsedTime *parsed)
{
	const char *p = *cursor;
	
	if (!_PGParseNumber(&p, &parsed->hour, 1) || *p++ != ':') return NO;
	if (!_PGParseNumber(&p, &parsed->minute, 1) || *p++ != ':') return NO;
	if (!_PGParseNumber(&p, &parsed->second, 1)) return NO;
	
	if (*p == '.') {
		int digits = 0;
		
		p++;
		
		while (*p >= '0' && *p <= '9') 
		{
			if (digits < 6) { parsed->microsecond = parsed->microsecond * 10 + (*p - '0'); digits++; }
			
			p++;
		}
		
		while (digits++ < 6) parsed->microsecond *= 10;
	}
	
	parsed->hasTime = YES;
	
	if (*p == '+' || *p == '-') {
		long sign = (*p == '-') ? -1 : 1;
		long hours = 0, minutes = 0, seconds = 0;
		
		p++;
		
		if (!_PGParseNumber(&p, &hours, 1)) return NO;
		
		if (*p == ':') { p++; if (!_PGParseNumber(&p, &minutes, 1)) return NO; }
		if (*p == ':') { p++; if (!_PGParseNumber(&p, &seconds, 1)) return NO; }
		
		parsed->hasOffset = YES;
		parsed->gmtOffset = sign * (hours * 3600 + minutes * 60 + seconds);
	}
	
	*cursor = p;
	
	return YES;
}

/**
 * Parses any of PostgreSQL's ISO date, time, timetz, timestamp or timestamptz text forms, 
 * including the optional " BC" suffix.
 */
static BOOL _PGParseTimestampString(const char *string, PGPostgresParsedTime *parsed)
{
	memset(parsed, 0, sizeof(*parsed));
	
	if (!string || !*string) return NO;
	
	const char *p = string;
	
	// Distinguish a leading date ("YYYY-") from a leading time ("HH:")
	const char *probe = p;
	
	while (*probe >= '0' && *probe <= '9') probe++;
	
	if (*probe == '-') {
		if (!_PGParseDate(&p, parsed)) return NO;
		
		if (*p == ' ' && p[1] >= '0' && p[1] <= '9') {
			p++;
			
			if (!_PGParseTime(&p, parsed)) return NO;
		}
		
		if (!strncmp(p, " BC", 3)) parsed->year = 1 - parsed->year;
	}
	else {
		if (!_PGParseTime(&p, parsed)) return NO;
	}
	
	return YES;
}

/**
 * Days since 1970-01-01 for the given proleptic Gregorian date.
 */
static long long _PGDaysFromCivil(long year, long month, long day)
{
	year -= month <= 2;
	
	long long era = (year >= 0 ? year : year - 399) / 400;
	long long yoe = year - era * 400;
	long long doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
	long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	
	return era * 146097 + doe - 719468;
}
