//
//  PGPostgresTypeNumberHandler.m
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

#import "PGPostgresTypeNumberHandler.h"

static PGPostgresOid PGPostgresTypeNumberTypes[] = 
{ 
	PGPostgresOidInt8,
	PGPostgresOidInt2,
	PGPostgresOidInt4,
	PGPostgresOidFloat4,
	PGPostgresOidFloat8,
	PGPostgresOidBool,
	PGPostgresOidOid,
	PGPostgresOidMoney,
	PGPostgresOidNumeric,
	0 
};

@interface PGPostgresTypeNumberHandler ()

- (id)_integerObjectFromResult;
- (id)_floatObjectFromResult;
- (id)_booleanObjectFromResult;
- (id)_numericFromResult;

@end

@implementation PGPostgresTypeNumberHandler

@synthesize row = _row;
@synthesize type = _type;
@synthesize column = _column;
@synthesize result = _result;

#pragma mark -
#pragma mark Protocol Implementation

- (PGPostgresOid *)remoteTypes 
{
	return PGPostgresTypeNumberTypes;
}

- (Class)nativeClass 
{
	return [NSNumber class];
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
		case PGPostgresOidInt8:
		case PGPostgresOidInt2:
		case PGPostgresOidInt4:
			return [self _integerObjectFromResult];
		case PGPostgresOidFloat4:
		case PGPostgresOidFloat8:
			return [self _floatObjectFromResult];
		case PGPostgresOidBool:
			return [self _booleanObjectFromResult];
		case PGPostgresOidNumeric:
			return [self _numericFromResult];
	}
	
	return [NSNull null];
}

#pragma mark -
#pragma mark Integer

/**
 * Converts a (text format) integer value to an NSNumber instance.
 *
 * @return An NSNumber representation of the the value.
 */
- (id)_integerObjectFromResult
{
	const char *value = PQgetvalue(_result, (int)_row, (int)_column);
	
	if (!value || !*value) return [NSNull null];
	
	long long number = strtoll(value, NULL, 10);
	
	switch (_type) 
	{
		case PGPostgresOidInt2:
			return [NSNumber numberWithShort:(short)number];
		case PGPostgresOidInt4:
			return [NSNumber numberWithInteger:(int)number];
		case PGPostgresOidInt8:
			return [NSNumber numberWithLongLong:number];
	}
	
	return [NSNull null];
}

#pragma mark -
#pragma mark Floating Point

/**
 * Converts a (text format) float value to an NSNumber instance.
 *
 * @return An NSNumber representation of the the value.
 */
- (id)_floatObjectFromResult
{
	const char *value = PQgetvalue(_result, (int)_row, (int)_column);
	
	if (!value || !*value) return [NSNull null];
	
	// strtof/strtod also understand the 'NaN', 'Infinity' and '-Infinity' spellings PostgreSQL uses
	if (_type == PGPostgresOidFloat4) return [NSNumber numberWithFloat:strtof(value, NULL)];
	
	return [NSNumber numberWithDouble:strtod(value, NULL)];
}

#pragma mark -
#pragma mark Boolean

/**
 * Converts a (text format) boolean value to an NSNumber instance.
 *
 * @return An NSNumber representation of the the value.
 */
- (id)_booleanObjectFromResult
{
	const char *value = PQgetvalue(_result, (int)_row, (int)_column);
	
	if (!value || !*value) return [NSNull null];
	
	return [NSNumber numberWithInt:(*value == 't' || *value == 'T') ? 1 : 0];
}

#pragma mark -
#pragma mark Numeric

/**
 * Converts a (text format) numeric value to a native NSNumber instance.
 *
 * @return An NSNumber representation of the the value.
 */
- (id)_numericFromResult
{
	const char *numeric = PQgetvalue(_result, (int)_row, (int)_column);
	
	if (!numeric || !*numeric) return [NSNull null];
	
	NSString *stringValue = [[NSString alloc] initWithUTF8String:numeric];
	
	double value = [stringValue doubleValue];
	
	[stringValue release];
	
	if (value == HUGE_VAL || value == -HUGE_VAL) return [NSNull null];
	
	return [NSNumber numberWithDouble:value];
}

@end
