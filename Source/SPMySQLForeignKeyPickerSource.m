//
//  SPMySQLForeignKeyPickerSource.m
//  Sequel Plus
//

#import "SPMySQLForeignKeyPickerSource.h"
#import "SPStringAdditions.h"
#import <SPMySQL/SPMySQL.h>

@implementation SPMySQLForeignKeyPickerSource
{
	SPMySQLConnection *_connection;
	NSString *_database;
	NSString *_table;
	NSString *_keyColumn;
	dispatch_queue_t _queue;
	NSArray<NSString *> *_primaryKey; // read on the first fetch (queue only)
}

@synthesize keyColumn = _keyColumn;

- (instancetype)initWithConnection:(SPMySQLConnection *)connection database:(NSString *)database table:(NSString *)table keyColumn:(NSString *)keyColumn
{
	if ((self = [super init])) {
		_connection = [connection retain];
		_database = [database copy];
		_table = [table copy];
		_keyColumn = [keyColumn copy];
		_queue = dispatch_queue_create("com.sequelplus.fkpicker.mysql", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[_database release];
	[_table release];
	[_keyColumn release];
	[_primaryKey release];
	dispatch_release(_queue);
	[super dealloc];
}

+ (SPForeignKeyColumnKind)kindForType:(NSString *)type
{
	NSString *base = [[[type lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"( "]] firstObject];
	if ([@[@"char", @"varchar", @"tinytext", @"text", @"mediumtext", @"longtext", @"enum", @"set"] containsObject:base]) return SPForeignKeyColumnText;
	if ([@[@"tinyint", @"smallint", @"mediumint", @"int", @"integer", @"bigint", @"decimal", @"numeric", @"float", @"double", @"real", @"bit"] containsObject:base]) return SPForeignKeyColumnNumber;
	if ([@[@"date", @"time", @"datetime", @"timestamp", @"year"] containsObject:base]) return SPForeignKeyColumnDateTime;
	return SPForeignKeyColumnOther;
}

- (NSString *)qualifiedTable
{
	return [NSString stringWithFormat:@"%@.%@", [_database backtickQuotedString], [_table backtickQuotedString]];
}

/// Runs sql, returning its rows as arrays of NSString / NSNull, or nil with the server's message.
- (NSArray *)rowsForQuery:(NSString *)sql error:(NSString **)error
{
	SPMySQLResult *result = [_connection queryString:sql];
	if ([_connection queryErrored] || !result) {
		if (error) *error = [_connection lastErrorMessage] ?: NSLocalizedString(@"The rows couldn't be read.", @"foreign key picker: unknown error");
		return nil;
	}
	[result setReturnDataAsStrings:YES];
	NSMutableArray *rows = [NSMutableArray array];
	NSArray *row = nil;
	while ((row = [result getRowAsArray])) [rows addObject:row];
	return rows;
}

/// Runs work on the queue; its result and message come back on main.
- (void)perform:(id (^)(NSString **error))work completion:(void (^)(id result, NSString *errorMessage))completion
{
	void (^done)(id, NSString *) = [[completion copy] autorelease];
	id (^body)(NSString **) = [[work copy] autorelease];
	[self retain];
	dispatch_async(_queue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *message = nil;
		id result = [body(&message) retain];
		[message retain];
		[pool drain];
		dispatch_async(dispatch_get_main_queue(), ^{
			done(result, result ? nil : (message ?: NSLocalizedString(@"The rows couldn't be read.", @"foreign key picker: unknown error")));
			[result release];
			[message release];
			[self release];
		});
	});
}

- (void)loadColumnsWithCompletion:(void (^)(NSArray<SPForeignKeyPickerColumn *> *, NSString *))completion
{
	[self perform:^id(NSString **error) {
		NSArray *rows = [self rowsForQuery:[NSString stringWithFormat:@"SHOW COLUMNS FROM %@", [self qualifiedTable]] error:error];
		if (!rows) return nil;
		NSMutableArray *columns = [NSMutableArray array];
		for (NSArray *row in rows) {
			if ([row count] < 2 || ![row[0] isKindOfClass:[NSString class]]) continue;
			NSString *type = [row[1] isKindOfClass:[NSString class]] ? row[1] : @"";
			[columns addObject:[SPForeignKeyPickerColumn columnWithName:row[0] kind:[[self class] kindForType:type]]];
		}
		return columns;
	} completion:completion];
}

/// The condition as SQL, its values escaped and quoted for MySQL.
- (NSString *)sqlForCondition:(SPForeignKeyCondition *)condition
{
	NSString *column = [[condition column] backtickQuotedString];
	NSString *op = [condition op];
	NSString *value = [condition value] ?: @"";
	if ([op isEqualToString:SPForeignKeyOpIsNull]) return [NSString stringWithFormat:@"%@ IS NULL", column];
	if ([op isEqualToString:SPForeignKeyOpIsNotNull]) return [NSString stringWithFormat:@"%@ IS NOT NULL", column];
	if ([op isEqualToString:SPForeignKeyOpContains] || [op isEqualToString:SPForeignKeyOpStartsWith]) {
		NSString *pattern = SPForeignKeyEscapeLikePattern(value);
		pattern = [op isEqualToString:SPForeignKeyOpContains] ? [NSString stringWithFormat:@"%%%@%%", pattern] : [pattern stringByAppendingString:@"%"];
		// LIKE's default escape character is \ (in every sql_mode)
		return [NSString stringWithFormat:@"CAST(%@ AS CHAR) LIKE %@", column, [_connection escapeAndQuoteString:pattern]];
	}
	if ([op isEqualToString:SPForeignKeyOpBetween]) {
		return [NSString stringWithFormat:@"%@ BETWEEN %@ AND %@", column, [_connection escapeAndQuoteString:value], [_connection escapeAndQuoteString:[condition secondValue] ?: @""]];
	}
	NSDictionary *symbols = @{SPForeignKeyOpEquals: @"=", SPForeignKeyOpNotEquals: @"<>", SPForeignKeyOpLess: @"<",
							  SPForeignKeyOpLessOrEqual: @"<=", SPForeignKeyOpGreater: @">", SPForeignKeyOpGreaterOrEqual: @">="};
	return [NSString stringWithFormat:@"%@ %@ %@", column, [symbols objectForKey:op] ?: @"=", [_connection escapeAndQuoteString:value]];
}

- (void)fetchRowsWithSearch:(NSString *)search inColumns:(NSArray<NSString *> *)searchColumns
				 conditions:(NSArray<SPForeignKeyCondition *> *)conditions columns:(NSArray<NSString *> *)columns
					 offset:(NSUInteger)offset limit:(NSUInteger)limit
				 completion:(void (^)(NSArray<NSArray *> *, NSString *))completion
{
	NSMutableArray *where = [NSMutableArray array];
	if ([search length] && [searchColumns count]) {
		NSString *pattern = [_connection escapeAndQuoteString:[NSString stringWithFormat:@"%%%@%%", SPForeignKeyEscapeLikePattern(search)]];
		NSMutableArray *matches = [NSMutableArray array];
		for (NSString *column in searchColumns) [matches addObject:[NSString stringWithFormat:@"CAST(%@ AS CHAR) LIKE %@", [column backtickQuotedString], pattern]];
		[where addObject:[NSString stringWithFormat:@"(%@)", [matches componentsJoinedByString:@" OR "]]];
	}
	for (SPForeignKeyCondition *condition in conditions) [where addObject:[self sqlForCondition:condition]];
	NSMutableArray *selected = [NSMutableArray array];
	for (NSString *column in columns) [selected addObject:[column backtickQuotedString]];
	NSString *whereClause = [where count] ? [@" WHERE " stringByAppendingString:[where componentsJoinedByString:@" AND "]] : @"";
	NSString *selectList = [selected componentsJoinedByString:@", "];

	[self perform:^id(NSString **error) {
		if (!_primaryKey) {
			NSArray *keys = [self rowsForQuery:[NSString stringWithFormat:@"SHOW KEYS FROM %@ WHERE Key_name = 'PRIMARY'", [self qualifiedTable]] error:error];
			if (!keys) return nil;
			// Column_name is the 5th field; rows come in Seq_in_index order
			NSMutableArray *names = [NSMutableArray array];
			for (NSArray *row in keys) if ([row count] > 4 && [row[4] isKindOfClass:[NSString class]]) [names addObject:row[4]];
			_primaryKey = [names copy];
		}
		NSMutableArray *order = [NSMutableArray arrayWithObject:[_keyColumn backtickQuotedString]];
		for (NSString *column in _primaryKey) if (![column isEqualToString:_keyColumn]) [order addObject:[column backtickQuotedString]];
		NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM %@%@ ORDER BY %@ LIMIT %lu OFFSET %lu", selectList, [self qualifiedTable],
						 whereClause, [order componentsJoinedByString:@", "], (unsigned long)limit, (unsigned long)offset];
		return [self rowsForQuery:sql error:error];
	} completion:completion];
}

@end
