#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

NSString *SPPostgresQuoteIdentifier(NSString *identifier)
{
	return [NSString stringWithFormat:@"\"%@\"", [identifier ?: @"" stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

static NSError *SPPostgresTableDataError(NSInteger code, NSString *message)
{
	return [NSError errorWithDomain:SPPostgresErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - SPPostgresColumn

@interface SPPostgresColumn ()
- (instancetype)initWithName:(NSString *)name typeName:(NSString *)typeName castTypeName:(NSString *)castTypeName
					nullable:(BOOL)nullable defaultExpression:(NSString *)defaultExpression
		  primaryKeyPosition:(NSInteger)primaryKeyPosition isGenerated:(BOOL)isGenerated;
@end

@implementation SPPostgresColumn

@synthesize name = _name;
@synthesize typeName = _typeName;
@synthesize castTypeName = _castTypeName;
@synthesize nullable = _nullable;
@synthesize defaultExpression = _defaultExpression;
@synthesize primaryKeyPosition = _primaryKeyPosition;
@synthesize isGenerated = _isGenerated;

- (instancetype)initWithName:(NSString *)name typeName:(NSString *)typeName castTypeName:(NSString *)castTypeName
					nullable:(BOOL)nullable defaultExpression:(NSString *)defaultExpression
		  primaryKeyPosition:(NSInteger)primaryKeyPosition isGenerated:(BOOL)isGenerated
{
	if ((self = [super init])) {
		_name = [name copy];
		_typeName = [typeName copy];
		_castTypeName = [castTypeName copy];
		_nullable = nullable;
		_defaultExpression = [defaultExpression copy];
		_primaryKeyPosition = primaryKeyPosition;
		_isGenerated = isGenerated;
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_typeName release];
	[_castTypeName release];
	[_defaultExpression release];
	[super dealloc];
}

- (BOOL)isPrimaryKey
{
	return _primaryKeyPosition > 0;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@%@>", [self class], _name, _typeName, _primaryKeyPosition ? @" PK" : @""];
}

@end

#pragma mark - SPPostgresFilter

@implementation SPPostgresFilter

@synthesize column = _column;
@synthesize operator = _operator;
@synthesize value = _value;

+ (instancetype)filterWithColumn:(NSString *)column operator:(NSString *)op value:(NSString *)value
{
	SPPostgresFilter *filter = [[[self alloc] init] autorelease];
	filter.column = column;
	filter.operator = op;
	filter.value = value;
	return filter;
}

- (void)dealloc
{
	[_column release];
	[_operator release];
	[_value release];
	[super dealloc];
}

@end

#pragma mark - SPPostgresTableData

@implementation SPPostgresTableData

@synthesize schema = _schema;
@synthesize table = _table;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table
{
	if ((self = [super init])) {
		_connection = [connection retain];
		_schema = [schema copy];
		_table = [table copy];
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[_schema release];
	[_table release];
	[_columns release];
	[_relationKind release];
	[super dealloc];
}

#pragma mark - Helpers

- (PGPostgresResult *)run:(NSString *)sql values:(NSArray *)values error:(NSError **)error
{
	PGPostgresResult *result = [_connection execute:sql values:values ?: @[]];
	if (!result && error) {
		NSString *message = nil;
		if ([_connection isConnected]) {
			message = [[_connection lastError] errorPrimaryMessage];
			if (![message length]) message = NSLocalizedString(@"The query failed.", @"Postgres content query failure");
		}
		else {
			// The connection is gone: libpq's message says why. The last query error may be older than that.
			message = [_connection libpqErrorMessage];
			if (![message length]) message = NSLocalizedString(@"There is no connection to the server.", @"Postgres content query without a connection");
		}
		*error = SPPostgresTableDataError(SPPostgresErrorQueryFailed, message);
	}
	return result;
}

/// Runs a statement whose failure must not leave an error behind (e.g. ROLLBACK after an earlier error).
- (void)runQuietly:(NSString *)sql
{
	[_connection execute:sql values:@[]];
}

- (NSString *)qualifiedName
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(_schema), SPPostgresQuoteIdentifier(_table)];
}

/// "schema"."table"."column": always the table's column, never an output column of the same name.
- (NSString *)qualifiedColumn:(SPPostgresColumn *)column
{
	return [NSString stringWithFormat:@"%@.%@", [self qualifiedName], SPPostgresQuoteIdentifier([column name])];
}

- (BOOL)loadMetadata:(NSError **)error
{
	if (_columns) return YES;

	// One row per column (LEFT JOIN, so a relation without columns still yields its relkind).
	PGPostgresResult *result = [self run:
		@"SELECT c.relkind::text AS kind, a.attname::text AS name, "
		 "format_type(a.atttypid, a.atttypmod) AS type, format_type(a.atttypid, NULL) AS casttype, "
		 "(NOT a.attnotnull)::text AS nullable, "
		 "CASE WHEN a.attgenerated = '' THEN pg_get_expr(d.adbin, d.adrelid) END AS def, "
		 // indkey is an int2vector, whose subscripts start at 0, so the 1-based position comes from WITH ORDINALITY.
		 "COALESCE((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) WHERE k.attnum = a.attnum), 0)::text AS pkpos, "
		 "(a.attidentity = 'a' OR a.attgenerated <> '')::text AS generated "
		 "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
		 "LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped "
		 "LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
		 "LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary "
		 "WHERE n.nspname = $1::text AND c.relname = $2::text "
		 "ORDER BY a.attnum"
								  values:@[_schema ?: @"", _table ?: @""] error:error];
	if (!result) return NO;

	if ([result numberOfRows] == 0) {
		if (error) {
			*error = SPPostgresTableDataError(SPPostgresErrorQueryFailed,
				[NSString stringWithFormat:NSLocalizedString(@"The table %@ was not found.", @"Postgres content: table missing"), [self qualifiedName]]);
		}
		return NO;
	}

	NSMutableArray *columns = [NSMutableArray array];
	NSString *kind = nil;
	for (NSDictionary *row in result) {
		id value = [row objectForKey:@"kind"];
		if ([value isKindOfClass:[NSString class]]) kind = value;

		NSString *name = [row objectForKey:@"name"];
		if (![name isKindOfClass:[NSString class]]) continue;

		id def = [row objectForKey:@"def"];
		SPPostgresColumn *column = [[SPPostgresColumn alloc] initWithName:name
																 typeName:[row objectForKey:@"type"]
															 castTypeName:[row objectForKey:@"casttype"]
																 nullable:[[row objectForKey:@"nullable"] isEqual:@"true"]
														defaultExpression:[def isKindOfClass:[NSString class]] ? def : nil
													   primaryKeyPosition:[[row objectForKey:@"pkpos"] integerValue]
															  isGenerated:[[row objectForKey:@"generated"] isEqual:@"true"]];
		[columns addObject:column];
		[column release];
	}

	_columns = [columns copy];
	_relationKind = [kind copy];
	return YES;
}

- (SPPostgresColumn *)columnNamed:(NSString *)name error:(NSError **)error
{
	for (SPPostgresColumn *column in _columns) {
		if ([[column name] isEqualToString:name]) return column;
	}
	if (error) {
		*error = SPPostgresTableDataError(SPPostgresErrorQueryFailed,
			[NSString stringWithFormat:NSLocalizedString(@"There is no column named %@.", @"Postgres content: unknown column"), SPPostgresQuoteIdentifier(name)]);
	}
	return nil;
}

/// Primary-key columns in key order.
- (NSArray *)primaryKeyColumns
{
	NSMutableArray *keys = [NSMutableArray array];
	for (SPPostgresColumn *column in _columns) {
		if ([column isPrimaryKey]) [keys addObject:column];
	}
	[keys sortUsingComparator:^NSComparisonResult(SPPostgresColumn *a, SPPostgresColumn *b) {
		return [@([a primaryKeyPosition]) compare:@([b primaryKeyPosition])];
	}];
	return keys;
}

/// "c1"::text, "c2"::text, … in column order.
- (NSString *)textSelectList
{
	NSMutableArray *items = [NSMutableArray arrayWithCapacity:[_columns count]];
	for (SPPostgresColumn *column in _columns) {
		[items addObject:[NSString stringWithFormat:@"%@::text", SPPostgresQuoteIdentifier([column name])]];
	}
	return [items componentsJoinedByString:@", "];
}

/// Converts a result to rows of NSString / NSNull.
- (NSArray *)rowsFromResult:(PGPostgresResult *)result
{
	NSMutableArray *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)[result numberOfRows]];
	NSArray *row;
	while ((row = [result rowAsArray])) [rows addObject:row];
	return rows;
}

/// " WHERE …" for the filter (or @"" for none), appending its parameters to values. Nil with *error if invalid.
- (NSString *)whereClauseForFilter:(SPPostgresFilter *)filter values:(NSMutableArray *)values error:(NSError **)error
{
	if (!filter) return @"";

	SPPostgresColumn *column = [self columnNamed:[filter column] error:error];
	if (!column) return nil;

	NSString *quoted = SPPostgresQuoteIdentifier([column name]);
	NSString *op = [filter operator];
	NSString *value = [filter value] ?: @"";

	if ([op isEqualToString:@"IS NULL"] || [op isEqualToString:@"IS NOT NULL"]) {
		return [NSString stringWithFormat:@" WHERE %@ %@", quoted, op];
	}

	if ([op isEqualToString:@"LIKE"] || [op isEqualToString:@"NOT LIKE"] || [op isEqualToString:@"ILIKE"]) {
		[values addObject:value];
		return [NSString stringWithFormat:@" WHERE %@::text %@ $%lu::text", quoted, op, (unsigned long)[values count]];
	}

	if ([op isEqualToString:@"IN"]) {
		NSMutableArray *placeholders = [NSMutableArray array];
		for (NSString *item in [value componentsSeparatedByString:@","]) {
			[values addObject:[item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
			[placeholders addObject:[NSString stringWithFormat:@"$%lu::%@", (unsigned long)[values count], [column castTypeName]]];
		}
		return [NSString stringWithFormat:@" WHERE %@ IN (%@)", quoted, [placeholders componentsJoinedByString:@", "]];
	}

	// Only these fixed operators are ever placed in the SQL; ≠ is sent as <>.
	NSDictionary *comparisons = @{@"=": @"=", @"≠": @"<>", @">": @">", @"<": @"<", @">=": @">=", @"<=": @"<="};
	NSString *sqlOperator = [comparisons objectForKey:op ?: @""];
	if (!sqlOperator) {
		if (error) {
			*error = SPPostgresTableDataError(SPPostgresErrorQueryFailed,
				[NSString stringWithFormat:NSLocalizedString(@"The filter operator “%@” is not supported.", @"Postgres content: unknown filter operator"), op]);
		}
		return nil;
	}
	[values addObject:value];
	return [NSString stringWithFormat:@" WHERE %@ %@ $%lu::%@", quoted, sqlOperator, (unsigned long)[values count], [column castTypeName]];
}

/// "pk1" = $n::type AND … (without a leading WHERE): identifies row by its full primary key.
- (NSString *)keyConditionForRow:(NSArray *)row values:(NSMutableArray *)values error:(NSError **)error
{
	NSArray *keys = [self primaryKeyColumns];
	if (![keys count] || [row count] != [_columns count]) {
		if (error) {
			*error = SPPostgresTableDataError(SPPostgresErrorQueryFailed,
				NSLocalizedString(@"The row doesn't match the table's columns, so it can't be identified.", @"Postgres content: row shape mismatch"));
		}
		return nil;
	}

	NSMutableArray *conditions = [NSMutableArray arrayWithCapacity:[keys count]];
	for (SPPostgresColumn *key in keys) {
		[values addObject:[row objectAtIndex:[_columns indexOfObjectIdenticalTo:key]]];
		[conditions addObject:[NSString stringWithFormat:@"%@ = $%lu::%@", SPPostgresQuoteIdentifier([key name]), (unsigned long)[values count], [key castTypeName]]];
	}
	return [conditions componentsJoinedByString:@" AND "];
}

/// Loads metadata and refuses (without sending any SQL beyond the cached catalog query) when not editable.
- (BOOL)checkEditable:(NSError **)error
{
	if (![self loadMetadata:error]) return NO;
	if ([self isEditable]) return YES;
	if (error) *error = SPPostgresTableDataError(SPPostgresErrorNotEditable, [self readOnlyReason]);
	return NO;
}

- (NSError *)rowChangedError
{
	return SPPostgresTableDataError(SPPostgresErrorRowChanged,
		NSLocalizedString(@"The row was changed or deleted by someone else since it was loaded, so it wasn't changed. Reload the table to see its current contents.",
						  @"Postgres content: edit affected no rows"));
}

#pragma mark - Public API

- (NSArray *)columns:(NSError **)error
{
	if (![self loadMetadata:error]) return nil;
	return [[_columns retain] autorelease];
}

- (BOOL)isEditable
{
	if (![self loadMetadata:NULL]) return NO;
	BOOL isTable = [_relationKind isEqualToString:@"r"] || [_relationKind isEqualToString:@"p"];
	return isTable && [[self primaryKeyColumns] count] > 0;
}

- (NSString *)readOnlyReason
{
	if ([self isEditable]) return nil;
	if (!_columns) return NSLocalizedString(@"The table's columns couldn't be read, so its rows can't be edited.", @"Postgres content: metadata failed");
	if ([_relationKind isEqualToString:@"v"] || [_relationKind isEqualToString:@"m"]) {
		return NSLocalizedString(@"This is a view, so its rows can't be edited.", @"Postgres content: view is read-only");
	}
	if (![_relationKind isEqualToString:@"r"] && ![_relationKind isEqualToString:@"p"]) {
		return NSLocalizedString(@"This is not a table, so its rows can't be edited.", @"Postgres content: non-table is read-only");
	}
	return NSLocalizedString(@"This table has no primary key, so its rows can't be edited.", @"Postgres content: no primary key");
}

- (NSArray *)rowsWithFilter:(SPPostgresFilter *)filter sortColumn:(NSString *)column ascending:(BOOL)ascending
					 offset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError **)error
{
	if (![self loadMetadata:error]) return nil;

	NSMutableArray *values = [NSMutableArray array];
	NSString *where = [self whereClauseForFilter:filter values:values error:error];
	if (!where) return nil;

	// Order by the sort column, then the primary key, so pages are stable. The names are qualified: a bare
	// ORDER BY "id" would sort by the output column "id" (the ::text value) rather than the table column.
	NSMutableArray *order = [NSMutableArray array];
	SPPostgresColumn *sortColumn = nil;
	if (column) {
		sortColumn = [self columnNamed:column error:error];
		if (!sortColumn) return nil;
		[order addObject:[NSString stringWithFormat:@"%@ %@", [self qualifiedColumn:sortColumn], ascending ? @"ASC" : @"DESC"]];
	}
	for (SPPostgresColumn *key in [self primaryKeyColumns]) {
		if (key != sortColumn) [order addObject:[self qualifiedColumn:key]];
	}
	NSString *orderBy = [order count] ? [@" ORDER BY " stringByAppendingString:[order componentsJoinedByString:@", "]] : @"";

	unsigned long long maxBigint = (unsigned long long)LLONG_MAX;
	[values addObject:[NSString stringWithFormat:@"%llu", MIN((unsigned long long)limit, maxBigint)]];
	[values addObject:[NSString stringWithFormat:@"%llu", MIN((unsigned long long)offset, maxBigint)]];
	NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM %@%@%@ LIMIT $%lu::bigint OFFSET $%lu::bigint",
					 [self textSelectList], [self qualifiedName], where, orderBy,
					 (unsigned long)[values count] - 1, (unsigned long)[values count]];

	PGPostgresResult *result = [self run:sql values:values error:error];
	if (!result) return nil;
	return [self rowsFromResult:result];
}

- (NSInteger)countRowsWithFilter:(SPPostgresFilter *)filter error:(NSError **)error
{
	if (![self loadMetadata:error]) return -1;

	NSMutableArray *values = [NSMutableArray array];
	NSString *where = [self whereClauseForFilter:filter values:values error:error];
	if (!where) return -1;

	PGPostgresResult *result = [self run:[NSString stringWithFormat:@"SELECT count(*)::text AS n FROM %@%@", [self qualifiedName], where]
								  values:values error:error];
	if (!result) return -1;
	return [[[result rowAsArray] firstObject] integerValue];
}

- (BOOL)updateRow:(NSArray *)originalRow column:(NSString *)column value:(id)value error:(NSError **)error
{
	if (![self checkEditable:error]) return NO;

	SPPostgresColumn *target = [self columnNamed:column error:error];
	if (!target) return NO;
	if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNull class]]) {
		if (error) *error = SPPostgresTableDataError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The value must be text or NULL.", @"Postgres content: bad value class"));
		return NO;
	}

	NSMutableArray *values = [NSMutableArray arrayWithObject:value];
	NSString *key = [self keyConditionForRow:originalRow values:values error:error];
	if (!key) return NO;

	NSString *sql = [NSString stringWithFormat:@"UPDATE %@ SET %@ = $1::%@ WHERE %@",
					 [self qualifiedName], SPPostgresQuoteIdentifier([target name]), [target castTypeName], key];
	PGPostgresResult *result = [self run:sql values:values error:error];
	if (!result) return NO;

	// The WHERE clause is the full primary key, so at most one row can match.
	if ([_connection lastQueryAffectedRowCount] == 0) {
		if (error) *error = [self rowChangedError];
		return NO;
	}
	return YES;
}

- (NSArray *)insertRowWithValues:(NSDictionary *)valuesByColumn error:(NSError **)error
{
	if (![self checkEditable:error]) return nil;

	for (NSString *name in valuesByColumn) {
		if (![self columnNamed:name error:error]) return nil;
	}

	NSMutableArray *names = [NSMutableArray array];
	NSMutableArray *placeholders = [NSMutableArray array];
	NSMutableArray *values = [NSMutableArray array];
	for (SPPostgresColumn *column in _columns) { // column order, so the SQL doesn't depend on dictionary order
		id value = [valuesByColumn objectForKey:[column name]];
		if (!value) continue;
		if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNull class]]) {
			if (error) *error = SPPostgresTableDataError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The value must be text or NULL.", @"Postgres content: bad value class"));
			return nil;
		}
		[values addObject:value];
		[names addObject:SPPostgresQuoteIdentifier([column name])];
		[placeholders addObject:[NSString stringWithFormat:@"$%lu::%@", (unsigned long)[values count], [column castTypeName]]];
	}

	NSString *sql = [names count]
		? [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@) RETURNING %@", [self qualifiedName],
		   [names componentsJoinedByString:@", "], [placeholders componentsJoinedByString:@", "], [self textSelectList]]
		: [NSString stringWithFormat:@"INSERT INTO %@ DEFAULT VALUES RETURNING %@", [self qualifiedName], [self textSelectList]];

	PGPostgresResult *result = [self run:sql values:values error:error];
	if (!result) return nil;
	return [[self rowsFromResult:result] firstObject];
}

- (BOOL)deleteRows:(NSArray *)rows error:(NSError **)error
{
	if (![self checkEditable:error]) return NO;
	if (![rows count]) return YES;

	// Build every statement first, so a malformed row is refused before the transaction starts.
	NSMutableArray *statements = [NSMutableArray arrayWithCapacity:[rows count]];
	NSMutableArray *parameters = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSMutableArray *values = [NSMutableArray array];
		NSString *key = [self keyConditionForRow:row values:values error:error];
		if (!key) return NO;
		[statements addObject:[NSString stringWithFormat:@"DELETE FROM %@ WHERE %@", [self qualifiedName], key]];
		[parameters addObject:values];
	}

	if (![self run:@"BEGIN" values:nil error:error]) return NO;

	for (NSUInteger i = 0; i < [statements count]; i++) {
		if (![self run:[statements objectAtIndex:i] values:[parameters objectAtIndex:i] error:error]) {
			[self runQuietly:@"ROLLBACK"];
			return NO;
		}
		if ([_connection lastQueryAffectedRowCount] == 0) {
			[self runQuietly:@"ROLLBACK"];
			if (error) *error = [self rowChangedError];
			return NO;
		}
	}

	if (![self run:@"COMMIT" values:nil error:error]) {
		[self runQuietly:@"ROLLBACK"];
		return NO;
	}
	return YES;
}

@end
