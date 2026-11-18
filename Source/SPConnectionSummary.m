//
//  SPConnectionSummary.m
//  Sequel Plus
//

#import "SPConnectionSummary.h"
#import <SPMySQL/SPMySQL.h>

@implementation SPConnectionSummary

@synthesize current = _current;
@synthesize max = _max;
@synthesize reserved = _reserved;

+ (instancetype)summaryWithCurrent:(NSUInteger)current max:(NSUInteger)max reserved:(NSUInteger)reserved
{
	SPConnectionSummary *summary = [[[self alloc] init] autorelease];
	summary->_current = current;
	summary->_max = max;
	summary->_reserved = reserved;
	return summary;
}

/// The first row's field at index of query's result, nil on an error or no row.
+ (NSString *)_field:(NSUInteger)index ofQuery:(NSString *)query onConnection:(SPMySQLConnection *)connection
{
	SPMySQLResult *result = [connection queryString:query];
	if ([connection queryErrored] || !result) return nil;
	[result setReturnDataAsStrings:YES];
	NSArray *row = [result getRowAsArray];
	id value = [row count] > index ? [row objectAtIndex:index] : nil;
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (instancetype)summaryForMySQLConnection:(id)connection
{
	NSString *max = [self _field:0 ofQuery:@"SELECT @@GLOBAL.max_connections" onConnection:connection];
	NSString *current = [self _field:1 ofQuery:@"SHOW GLOBAL STATUS LIKE 'Threads_connected'" onConnection:connection];
	if (!max || !current) return nil;
	return [self summaryWithCurrent:(NSUInteger)MAX([current longLongValue], 0) max:(NSUInteger)MAX([max longLongValue], 0) reserved:0];
}

- (NSString *)text
{
	NSString *text = (_max == 1)
		? [NSString stringWithFormat:NSLocalizedString(@"%lu of %lu connection", @"server processes: open connections against the limit of one"), (unsigned long)_current, (unsigned long)_max]
		: [NSString stringWithFormat:NSLocalizedString(@"%lu of %lu connections", @"server processes: open connections against the limit, e.g. 12 of 151 connections"), (unsigned long)_current, (unsigned long)_max];
	if (_reserved) {
		text = [text stringByAppendingFormat:NSLocalizedString(@" (%lu reserved for superusers)", @"server processes: PostgreSQL's superuser_reserved_connections, after the connection count"), (unsigned long)_reserved];
	}
	return text;
}

- (BOOL)isFull
{
	return _max > 0 && _current + _reserved >= _max;
}

@end
