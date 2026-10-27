//
//  PGPostgresTypeStringHandler.m
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

#import "PGPostgresTypeStringHandler.h"
#import "PGPostgresConnection.h"

#import <netdb.h>

static PGPostgresOid PGPostgresTypeStringTypes[] = 
{ 
	PGPostgresOidText,
	PGPostgresOidChar,
	PGPostgresOidName,
	PGPostgresOidVarChar,
	PGPostgresOidJSON,
	PGPostgresOidXML,
	PGPostgresOidUUID,
	PGPostgresOidBit,
	PGPostgresOidVarBit,
	PGPostgresOidInetAddr,
	PGPostgresOidCidrAddr,
	PGPostgresOidMacAddr,
	PGPostgresOidUnknown,
	0 
};

@interface PGPostgresTypeStringHandler ()

- (id)_stringFromResult;

@end

@implementation PGPostgresTypeStringHandler

@synthesize row = _row;
@synthesize type = _type;
@synthesize column = _column;
@synthesize result = _result;

#pragma mark -
#pragma mark Protocol Implementation

- (PGPostgresOid *)remoteTypes 
{
	return PGPostgresTypeStringTypes;
}

- (Class)nativeClass 
{
	return [NSString class];
}

- (NSArray *)classAliases
{
	return [NSArray arrayWithObject:@"NSCFString"];
}

- (id)objectFromResult
{	
	if (!_result || !_type) return [NSNull null];
	
	switch (_type)
	{
		case PGPostgresOidText:
		case PGPostgresOidChar:
		case PGPostgresOidName:
		case PGPostgresOidVarChar:
		case PGPostgresOidXML:
		case PGPostgresOidJSON:
		case PGPostgresOidUUID:
		case PGPostgresOidBit:
		case PGPostgresOidVarBit:
		case PGPostgresOidUnknown:
		case PGPostgresOidMacAddr:
		case PGPostgresOidInetAddr:
		case PGPostgresOidCidrAddr:
			return [self _stringFromResult];
	}
	
	return [NSNull null];
}

#pragma mark -
#pragma mark Private API

/**
 * Converts a char value to a string.
 *
 * @return A string representation of the value.
 */
- (id)_stringFromResult
{
	const void *bytes = PQgetvalue(_result, (int)_row, (int)_column);
	NSUInteger length = PQgetlength(_result, (int)_row, (int)_column);
		
	if (!bytes) return [NSNull null];
	
	// A genuine NULL is handled by the result before we get here, so zero length means an empty string
	if (!length) return @"";
	
	return [[[NSString alloc] initWithBytes:bytes length:length encoding:[_connection stringEncoding]] autorelease];
}

@end
