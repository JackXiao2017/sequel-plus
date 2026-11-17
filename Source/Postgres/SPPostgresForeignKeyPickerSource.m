//
//  SPPostgresForeignKeyPickerSource.m
//  Sequel Plus
//

#import "SPPostgresForeignKeyPickerSource.h"
#import "SPPostgresTaskRunner.h"
#import "SPPostgresTableData.h"
#import <PostgresKit/PostgresKit.h>

static NSString * const SPFKPickerSavepoint = @"sp_fkpicker_read";

@implementation SPPostgresForeignKeyPickerSource
{
	SPPostgresTaskRunner *_runner;
	NSString *_schema;
	NSString *_table;
	NSString *_keyColumn;
	NSDictionary<NSString *, NSNumber *> *_kinds;   // column → SPForeignKeyColumnKind, once the columns are loaded
	NSArray<NSString *> *_primaryKey;               // read on the first fetch (work queue only)
}

@synthesize keyColumn = _keyColumn;

- (instancetype)initWithTaskRunner:(SPPostgresTaskRunner *)runner schema:(NSString *)schema table:(NSString *)table keyColumn:(NSString *)keyColumn
{
	if ((self = [super init])) {
		_runner = [runner retain];
		_schema = [schema copy];
		_table = [table copy];
		_keyColumn = [keyColumn copy];
	}
	return self;
}

- (void)dealloc
{
	[_runner release];
	[_schema release];
	[_table release];
	[_keyColumn release];
	[_kinds release];
	[_primaryKey release];
	[super dealloc];
}

+ (NSString *)abortedMessage
{
	return NSLocalizedString(@"The current transaction is aborted, so the rows can't be read. Roll it back first (ROLLBACK in the Query view).", @"Postgres content: load inside an aborted transaction");
}

+ (SPForeignKeyColumnKind)kindForCategory:(NSString *)category
{
	if ([category isEqualToString:@"S"]) return SPForeignKeyColumnText;
	if ([category isEqualToString:@"N"]) return SPForeignKeyColumnNumber;
	if ([category isEqualToString:@"D"]) return SPForeignKeyColumnDateTime;
	return SPForeignKeyColumnOther;
}

/// Runs body as one guarded read on the runner; completion gets body's result or the error's message, on main.
- (void)read:(NSString *)description body:(id (^)(PGPostgresConnection *connection, NSError **error))body completion:(void (^)(id result, NSString *errorMessage))completion
{
	void (^done)(id, NSString *) = [[completion copy] autorelease];
	[_runner runTaskWithDescription:description cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		__block id result = nil;
		BOOL ok = SPPostgresRunGuardedRead(connection, SPFKPickerSavepoint, [[self class] abortedMessage], ^BOOL(NSError **readError) {
			result = [body(connection, readError) retain];
			return result != nil;
		}, error);
		[result autorelease];
		return ok ? result : nil;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		if (result) done(result, nil);
		else done(nil, cancelled ? NSLocalizedString(@"Cancelled.", @"foreign key picker: load cancelled") : ([error localizedDescription] ?: NSLocalizedString(@"The rows couldn't be read.", @"foreign key picker: unknown error")));
	}];
}

- (void)loadColumnsWithCompletion:(void (^)(NSArray<SPForeignKeyPickerColumn *> *, NSString *))completion
{
	NSString *schema = _schema, *table = _table;
	void (^done)(NSArray *, NSString *) = [[completion copy] autorelease];
	[self read:NSLocalizedString(@"Loading columns…", @"foreign key picker: loading the referenced table's columns") body:^id(PGPostgresConnection *connection, NSError **error) {
		PGPostgresResult *result = SPPostgresExecute(connection,
			@"SELECT a.attname::text AS name, t.typcategory::text AS category "
			 "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
			 "JOIN pg_type t ON t.oid = a.atttypid "
			 "WHERE n.nspname = $1::text AND c.relname = $2::text AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum",
			@[schema, table], error);
		if (!result) return nil;
		NSMutableArray *columns = [NSMutableArray array];
		for (NSDictionary *row in result) {
			NSString *name = [row objectForKey:@"name"];
			if (![name isKindOfClass:[NSString class]]) continue;
			[columns addObject:[SPForeignKeyPickerColumn columnWithName:name kind:[[self class] kindForCategory:[row objectForKey:@"category"]]]];
		}
		return columns;
	} completion:^(NSArray *columns, NSString *errorMessage) {
		if (columns) {
			NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
			for (SPForeignKeyPickerColumn *column in columns) [kinds setObject:@([column kind]) forKey:[column name]];
			[_kinds release];
			_kinds = [kinds copy];
		}
		done(columns, errorMessage);
	}];
}

/// The table's primary key columns in key order (empty when it has none), or nil on error.
- (NSArray *)primaryKeyOn:(PGPostgresConnection *)connection error:(NSError **)error
{
	PGPostgresResult *result = SPPostgresExecute(connection,
		@"SELECT a.attname::text AS name FROM pg_index i "
		 "JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
		 "CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) "
		 "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum "
		 "WHERE i.indisprimary AND n.nspname = $1::text AND c.relname = $2::text ORDER BY k.ord",
		@[_schema, _table], error);
	if (!result) return nil;
	NSMutableArray *names = [NSMutableArray array];
	for (NSDictionary *row in result) {
		NSString *name = [row objectForKey:@"name"];
		if ([name isKindOfClass:[NSString class]]) [names addObject:name];
	}
	return names;
}

/// The condition as SQL, its values appended to values ($n numbered after those already there).
+ (NSString *)sqlForCondition:(SPForeignKeyCondition *)condition kind:(NSNumber *)kind values:(NSMutableArray *)values
{
	NSString *column = SPPostgresQuoteIdentifier([condition column]);
	NSString *op = [condition op];
	NSString *value = [condition value] ?: @"";
	if ([op isEqualToString:SPForeignKeyOpIsNull]) return [NSString stringWithFormat:@"%@ IS NULL", column];
	if ([op isEqualToString:SPForeignKeyOpIsNotNull]) return [NSString stringWithFormat:@"%@ IS NOT NULL", column];
	if ([op isEqualToString:SPForeignKeyOpContains] || [op isEqualToString:SPForeignKeyOpStartsWith]) {
		NSString *pattern = SPForeignKeyEscapeLikePattern(value);
		[values addObject:[op isEqualToString:SPForeignKeyOpContains] ? [NSString stringWithFormat:@"%%%@%%", pattern] : [pattern stringByAppendingString:@"%"]];
		return [NSString stringWithFormat:@"%@::text ILIKE $%lu ESCAPE E'\\\\'", column, (unsigned long)[values count]];
	}
	if ([op isEqualToString:SPForeignKeyOpBetween]) {
		[values addObject:value];
		[values addObject:[condition secondValue] ?: @""];
		return [NSString stringWithFormat:@"%@ BETWEEN $%lu AND $%lu", column, (unsigned long)[values count] - 1, (unsigned long)[values count]];
	}
	NSDictionary *symbols = @{SPForeignKeyOpEquals: @"=", SPForeignKeyOpNotEquals: @"<>", SPForeignKeyOpLess: @"<",
							  SPForeignKeyOpLessOrEqual: @"<=", SPForeignKeyOpGreater: @">", SPForeignKeyOpGreaterOrEqual: @">="};
	NSString *symbol = [symbols objectForKey:op] ?: @"=";
	// Types without their own comparison (json, arrays, geometry…) compare as text
	if (kind && [kind integerValue] == SPForeignKeyColumnOther) column = [column stringByAppendingString:@"::text"];
	[values addObject:value];
	return [NSString stringWithFormat:@"%@ %@ $%lu", column, symbol, (unsigned long)[values count]];
}

- (void)fetchRowsWithSearch:(NSString *)search inColumns:(NSArray<NSString *> *)searchColumns
				 conditions:(NSArray<SPForeignKeyCondition *> *)conditions columns:(NSArray<NSString *> *)columns
					 offset:(NSUInteger)offset limit:(NSUInteger)limit
				 completion:(void (^)(NSArray<NSArray *> *, NSString *))completion
{
	NSMutableArray *values = [NSMutableArray array];
	NSMutableArray *where = [NSMutableArray array];
	if ([search length] && [searchColumns count]) {
		[values addObject:[NSString stringWithFormat:@"%%%@%%", SPForeignKeyEscapeLikePattern(search)]];
		NSMutableArray *matches = [NSMutableArray array];
		for (NSString *column in searchColumns) [matches addObject:[NSString stringWithFormat:@"%@::text ILIKE $1 ESCAPE E'\\\\'", SPPostgresQuoteIdentifier(column)]];
		[where addObject:[NSString stringWithFormat:@"(%@)", [matches componentsJoinedByString:@" OR "]]];
	}
	for (SPForeignKeyCondition *condition in conditions) {
		[where addObject:[[self class] sqlForCondition:condition kind:[_kinds objectForKey:[condition column]] values:values]];
	}
	NSMutableArray *selected = [NSMutableArray array];
	for (NSString *column in columns) [selected addObject:[NSString stringWithFormat:@"%@::text", SPPostgresQuoteIdentifier(column)]];
	NSString *from = [NSString stringWithFormat:@"%@.%@ AS t", SPPostgresQuoteIdentifier(_schema), SPPostgresQuoteIdentifier(_table)];
	NSString *whereClause = [where count] ? [@" WHERE " stringByAppendingString:[where componentsJoinedByString:@" AND "]] : @"";
	NSString *keyColumn = _keyColumn;
	NSUInteger columnCount = [columns count];

	[self read:NSLocalizedString(@"Loading rows…", @"foreign key picker: loading the referenced table's rows") body:^id(PGPostgresConnection *connection, NSError **error) {
		if (!_primaryKey) {
			NSArray *primaryKey = [self primaryKeyOn:connection error:error];
			if (!primaryKey) return nil;
			_primaryKey = [primaryKey copy];
		}
		// Qualified, so ORDER BY never binds to the ::text output column of the same name (text order)
		NSMutableArray *order = [NSMutableArray arrayWithObject:[@"t." stringByAppendingString:SPPostgresQuoteIdentifier(keyColumn)]];
		for (NSString *column in _primaryKey) {
			if (![column isEqualToString:keyColumn]) [order addObject:[@"t." stringByAppendingString:SPPostgresQuoteIdentifier(column)]];
		}
		NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM %@%@ ORDER BY %@ LIMIT %lu OFFSET %lu",
						 [selected componentsJoinedByString:@", "], from, whereClause, [order componentsJoinedByString:@", "],
						 (unsigned long)limit, (unsigned long)offset];
		PGPostgresResult *result = SPPostgresExecute(connection, sql, values, error);
		if (!result) return nil;
		NSMutableArray *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)[result numberOfRows]];
		for (unsigned long long r = 0; r < [result numberOfRows]; r++) {
			NSMutableArray *row = [NSMutableArray arrayWithCapacity:columnCount];
			for (NSUInteger c = 0; c < columnCount; c++) [row addObject:[result textValueAtRow:r column:c] ?: [NSNull null]];
			[rows addObject:row];
		}
		return rows;
	} completion:completion];
}

@end
