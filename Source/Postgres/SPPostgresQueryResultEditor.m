#import "SPPostgresQueryResultEditor.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

// Keys of an origin table's info (see -loadTables:) and of each of its columns.
static NSString * const SPQueryEditSchemaKey = @"schema";
static NSString * const SPQueryEditNameKey = @"name";
static NSString * const SPQueryEditKindKey = @"kind";
static NSString * const SPQueryEditColumnsKey = @"columns";     // attnum (NSNumber) -> column info
static NSString * const SPQueryEditTypeKey = @"type";
static NSString * const SPQueryEditNullableKey = @"nullable";
static NSString * const SPQueryEditGeneratedKey = @"generated";
static NSString * const SPQueryEditKeyPositionKey = @"pkpos";

/// Why a check failed inside an aborted transaction.
static NSString *SPQueryEditAbortedMessage(void)
{
	return NSLocalizedString(@"The current transaction is aborted, so the cell can't be checked for editing. Roll it back first.", @"Postgres query result: edit check inside an aborted transaction");
}

/**
 * Adds to scans each relation scan of a plan node (EXPLAIN (VERBOSE, FORMAT JSON)) and its descendants (Plans, which
 * include InitPlans and SubPlans), as @[schema, relation, group]. group identifies the read: the topmost of the
 * Append / Merge Append nodes directly above the scan (a partitioned or inheritance parent's children are one read),
 * else the scan itself. A ModifyTable's own relation is the statement's target, not a read, so it isn't added.
 */
static void SPQueryEditCollectScans(id node, NSDictionary *appendAbove, NSMutableArray *scans)
{
	if (![node isKindOfClass:[NSDictionary class]]) return;
	NSString *type = [node objectForKey:@"Node Type"];
	id schema = [node objectForKey:@"Schema"], relation = [node objectForKey:@"Relation Name"];
	if ([schema isKindOfClass:[NSString class]] && [relation isKindOfClass:[NSString class]] && ![type isEqual:@"ModifyTable"]) {
		[scans addObject:@[schema, relation, [NSValue valueWithNonretainedObject:(appendAbove ?: node)]]];
	}
	BOOL append = [type isEqual:@"Append"] || [type isEqual:@"Merge Append"];
	id children = [node objectForKey:@"Plans"];
	if (![children isKindOfClass:[NSArray class]]) return;
	for (id child in children) SPQueryEditCollectScans(child, append ? (appendAbove ?: node) : nil, scans);
}

@implementation SPPostgresQueryResultEditor

@synthesize result = _result;

- (instancetype)initWithResult:(PGPostgresResult *)result connection:(PGPostgresConnection *)connection statement:(NSString *)statement
{
	if ((self = [super init])) {
		_result = [result retain];
		_connection = [connection retain];
		_statement = [statement copy];
		_edits = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_result release];
	[_connection release];
	[_statement release];
	[_tables release];
	[_repeatedOrigins release];
	[_edits release];
	[super dealloc];
}

#pragma mark - Values

- (NSUInteger)rowCount
{
	return [_result returnsRows] ? (NSUInteger)[_result numberOfRows] : 0;
}

- (NSUInteger)columnCount
{
	return [_result numberOfFields];
}

- (NSIndexPath *)keyForRow:(NSUInteger)row column:(NSUInteger)column
{
	NSUInteger indexes[2] = {row, column};
	return [NSIndexPath indexPathWithIndexes:indexes length:2];
}

- (id)valueAtRow:(NSUInteger)row column:(NSUInteger)column
{
	id edited = [_edits objectForKey:[self keyForRow:row column:column]];
	if (edited) return edited;
	id value = [_result textValueAtRow:row column:column];
	return [value isKindOfClass:[NSString class]] ? value : [NSNull null];
}

#pragma mark - Catalog

/// The origin table OID of a result column, or 0 when it is not a plain table column.
- (unsigned int)originOfColumn:(NSUInteger)column
{
	if (column >= [_result numberOfFields] || [_result tableColumnForField:column] <= 0) return 0;
	return [_result tableOIDForField:column];
}

/**
 * Reads, once per editor:
 * - every live column of every origin table of the result, in one query: per table its schema, name and relkind; per
 *   column its name, type, nullability, whether it is generated and its primary-key position;
 * - each origin's family: itself and its partitions / inheritance children, recursively;
 * - the statement's plan (EXPLAIN without ANALYZE doesn't run it), to find the origins read more than once: those
 *   whose family's scans form more than one group (see SPQueryEditCollectScans).
 * A failure (no statement, one that can't be explained, an aborted transaction) is not cached, so the next check
 * retries.
 */
- (BOOL)loadTables:(NSError **)error
{
	if (_tables) return YES;

	NSMutableOrderedSet *oids = [NSMutableOrderedSet orderedSet];
	for (NSUInteger column = 0; column < [self columnCount]; column++) {
		unsigned int oid = [self originOfColumn:column];
		if (oid) [oids addObject:[NSString stringWithFormat:@"%u", oid]];
	}
	if ([oids count] == 0) {
		_tables = [[NSDictionary alloc] init];
		return YES;
	}

	if (![[_statement stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The statement that produced this result isn't known, so its rows can't be identified.", @"Postgres query result: edit check without the result's statement"), nil);
		return NO;
	}

	NSString *array = [NSString stringWithFormat:@"{%@}", [[oids array] componentsJoinedByString:@","]];
	__block PGPostgresResult *catalog = nil, *family = nil, *plan = nil;
	BOOL read = SPPostgresRunGuardedRead(_connection, @"sp_query_edit_read", SPQueryEditAbortedMessage(), ^BOOL(NSError **bodyError) {
		catalog = SPPostgresExecute(_connection,
			@"SELECT c.oid::text AS oid, n.nspname::text AS schema, c.relname::text AS name, c.relkind::text AS kind, "
			 "a.attnum::text AS attnum, a.attname::text AS attname, format_type(a.atttypid, -1) AS type, "
			 "(NOT a.attnotnull)::text AS nullable, "
			 "(a.attidentity = 'a' OR a.attgenerated <> '')::text AS generated, "
			 // indkey is an int2vector, whose subscripts start at 0, so the 1-based position comes from WITH ORDINALITY.
			 "COALESCE((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) WHERE k.attnum = a.attnum), 0)::text AS pkpos "
			 "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
			 "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped "
			 "LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary "
			 "WHERE c.oid = ANY($1::oid[])",
			@[array], bodyError);
		if (!catalog) return NO;
		family = SPPostgresExecute(_connection,
			@"WITH RECURSIVE family(origin, rel) AS ("
			 "SELECT o, o FROM unnest($1::oid[]) AS o "
			 "UNION SELECT f.origin, i.inhrelid FROM family f JOIN pg_inherits i ON i.inhparent = f.rel) "
			 "SELECT f.origin::text, n.nspname::text, c.relname::text "
			 "FROM family f JOIN pg_class c ON c.oid = f.rel JOIN pg_namespace n ON n.oid = c.relnamespace",
			@[array], bodyError);
		if (!family) return NO;
		plan = SPPostgresExecute(_connection, [@"EXPLAIN (VERBOSE, FORMAT JSON) " stringByAppendingString:_statement], nil, bodyError);
		return plan != nil;
	}, error);
	if (!read) return NO;

	// The plan's scans, grouped into reads
	id planText = [plan textValueAtRow:0 column:0];
	id explained = [planText isKindOfClass:[NSString class]]
		? [NSJSONSerialization JSONObjectWithData:[planText dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
	if (![explained isKindOfClass:[NSArray class]]) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The statement's plan couldn't be read, so its rows can't be identified.", @"Postgres query result: edit check couldn't parse EXPLAIN output"), nil);
		return NO;
	}
	NSMutableArray *scans = [NSMutableArray array];
	for (id statementPlan in explained) {
		if ([statementPlan isKindOfClass:[NSDictionary class]]) SPQueryEditCollectScans([statementPlan objectForKey:@"Plan"], nil, scans);
	}

	// Each origin's reads: the groups of the scans of its family
	NSMutableDictionary *originsByRelation = [NSMutableDictionary dictionary]; // @[schema, name] -> origin OIDs
	for (unsigned long long row = 0; row < [family numberOfRows]; row++) {
		NSArray *relation = @[[family textValueAtRow:row column:1], [family textValueAtRow:row column:2]];
		NSMutableSet *origins = [originsByRelation objectForKey:relation];
		if (!origins) [originsByRelation setObject:(origins = [NSMutableSet set]) forKey:relation];
		[origins addObject:@([[family textValueAtRow:row column:0] longLongValue])];
	}
	NSMutableDictionary *readsByOrigin = [NSMutableDictionary dictionary]; // origin OID -> groups
	for (NSArray *scan in scans) {
		for (NSNumber *origin in [originsByRelation objectForKey:[scan subarrayWithRange:NSMakeRange(0, 2)]]) {
			NSMutableSet *reads = [readsByOrigin objectForKey:origin];
			if (!reads) [readsByOrigin setObject:(reads = [NSMutableSet set]) forKey:origin];
			[reads addObject:[scan objectAtIndex:2]];
		}
	}
	NSMutableSet *repeated = [NSMutableSet set];
	for (NSNumber *origin in readsByOrigin) {
		if ([[readsByOrigin objectForKey:origin] count] > 1) [repeated addObject:origin];
	}

	NSMutableDictionary *tables = [NSMutableDictionary dictionary];
	for (unsigned long long row = 0; row < [catalog numberOfRows]; row++) {
		NSNumber *oid = @([[catalog textValueAtRow:row column:0] longLongValue]);
		NSMutableDictionary *table = [tables objectForKey:oid];
		if (!table) {
			table = [NSMutableDictionary dictionaryWithObjectsAndKeys:
				[catalog textValueAtRow:row column:1], SPQueryEditSchemaKey,
				[catalog textValueAtRow:row column:2], SPQueryEditNameKey,
				[catalog textValueAtRow:row column:3], SPQueryEditKindKey,
				[NSMutableDictionary dictionary], SPQueryEditColumnsKey, nil];
			[tables setObject:table forKey:oid];
		}
		NSDictionary *column = @{
			SPQueryEditNameKey: [catalog textValueAtRow:row column:5],
			SPQueryEditTypeKey: [catalog textValueAtRow:row column:6],
			SPQueryEditNullableKey: @([[catalog textValueAtRow:row column:7] isEqual:@"true"]),
			SPQueryEditGeneratedKey: @([[catalog textValueAtRow:row column:8] isEqual:@"true"]),
			SPQueryEditKeyPositionKey: @([[catalog textValueAtRow:row column:9] integerValue])
		};
		[[table objectForKey:SPQueryEditColumnsKey] setObject:column forKey:@([[catalog textValueAtRow:row column:4] integerValue])];
	}
	_tables = [tables copy];
	_repeatedOrigins = [repeated copy];
	return YES;
}

/// The origin table of a result column (nil when it has none, or the catalog can't be read or doesn't know it).
- (NSDictionary *)tableOfColumn:(NSUInteger)column
{
	unsigned int oid = [self originOfColumn:column];
	if (!oid || ![self loadTables:NULL]) return nil;
	return [_tables objectForKey:@((long long)oid)];
}

/// The origin column's info, or nil (see -tableOfColumn:).
- (NSDictionary *)originColumnOfColumn:(NSUInteger)column
{
	NSDictionary *table = [self tableOfColumn:column];
	return [[table objectForKey:SPQueryEditColumnsKey] objectForKey:@([_result tableColumnForField:column])];
}

- (NSString *)typeNameOfColumn:(NSUInteger)column
{
	return [[self originColumnOfColumn:column] objectForKey:SPQueryEditTypeKey];
}

- (BOOL)columnIsNullable:(NSUInteger)column
{
	NSNumber *nullable = [[self originColumnOfColumn:column] objectForKey:SPQueryEditNullableKey];
	return nullable ? [nullable boolValue] : YES;
}

- (NSString *)qualifiedName:(NSDictionary *)table
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier([table objectForKey:SPQueryEditSchemaKey]),
			SPPostgresQuoteIdentifier([table objectForKey:SPQueryEditNameKey])];
}

- (NSString *)qualifiedTableNameOfColumn:(NSUInteger)column
{
	NSDictionary *table = [self tableOfColumn:column];
	return table ? [self qualifiedName:table] : nil;
}

#pragma mark - Editability

/// The result columns that identify a row of the origin table oid: every one of its columns in the result, every
/// occurrence (MySQL uses only the primary-key columns when any is present). Self-joins are refused before this, by
/// the plan (SPPostgresCellOriginRepeated), since PostgreSQL doesn't report a field's alias and the values of one
/// alias can identify another row; comparing every occurrence is defence in depth: aliases that disagree match no
/// row, and agreeing repeats (SELECT id, name, name) are merely redundant. A consequence: an edit is also refused once
/// another shown column of its row has changed since the run.
- (NSArray *)identifyingColumnsForOrigin:(unsigned int)oid
{
	NSMutableArray *columns = [NSMutableArray array];
	for (NSUInteger column = 0; column < [self columnCount]; column++) {
		if ([self originOfColumn:column] == oid && [self originColumnOfColumn:column]) [columns addObject:@(column)];
	}
	return columns;
}

/**
 * The WHERE condition (without the keyword) that identifies row of the origin table oid by every result column of
 * that table (see -identifyingColumnsForOrigin:), with this editor's saved edits applied. Its $n parameters are
 * appended to values, numbered from [values count] + 1. Key columns are compared in their own type ("c" = $n::<type>); other
 * columns as text, with both sides through the column's type ("c"::text = ($n::<type>)::text), so types without =
 * (point, json) still identify their row and types whose output text differs from ::text (boolean, char(n), inet)
 * still match; NULL as "c" IS NULL.
 */
- (NSString *)whereClauseForRow:(NSUInteger)row origin:(unsigned int)oid values:(NSMutableArray *)values
{
	NSMutableArray *conditions = [NSMutableArray array];
	for (NSNumber *identifying in [self identifyingColumnsForOrigin:oid]) {
		NSUInteger index = [identifying unsignedIntegerValue];
		NSDictionary *info = [self originColumnOfColumn:index];
		NSString *name = SPPostgresQuoteIdentifier([info objectForKey:SPQueryEditNameKey]);
		NSString *type = [info objectForKey:SPQueryEditTypeKey];
		id value = [self valueAtRow:row column:index];
		if (![value isKindOfClass:[NSString class]]) {
			[conditions addObject:[NSString stringWithFormat:@"%@ IS NULL", name]];
			continue;
		}
		[values addObject:value];
		unsigned long parameter = (unsigned long)[values count];
		if ([[info objectForKey:SPQueryEditKeyPositionKey] integerValue] > 0) {
			[conditions addObject:[NSString stringWithFormat:@"%@ = $%lu::%@", name, parameter, type]];
		} else {
			[conditions addObject:[NSString stringWithFormat:@"%@::text = ($%lu::%@)::text", name, parameter, type]];
		}
	}
	return [conditions componentsJoinedByString:@" AND "];
}

/**
 * Steps 1–4 of the rule, which need no count: SPPostgresCellEditable when column is a plain, non-generated column of a
 * table the statement reads once (tableOut set to that table's info), else why not, with the message to show.
 */
- (SPPostgresCellEditability)originCheckOfColumn:(NSUInteger)column table:(NSDictionary **)tableOut message:(NSString **)message
{
	if (tableOut) *tableOut = nil;
	if (message) *message = nil;

	unsigned int oid = [self originOfColumn:column];
	NSDictionary *table = nil, *originColumn = nil;
	if (oid) {
		NSError *error = nil;
		if (![self loadTables:&error]) {
			if (message) *message = [error localizedDescription];
			return SPPostgresCellCheckFailed;
		}
		table = [_tables objectForKey:@((long long)oid)];
		originColumn = [[table objectForKey:SPQueryEditColumnsKey] objectForKey:@([_result tableColumnForField:column])];
	}

	// 1. No single origin table
	if (!originColumn) {
		if (message) *message = NSLocalizedString(@"Field is not editable. Field has no or multiple table or database origin(s).",@"field is not editable due to no table/database");
		return SPPostgresCellNoOrigin;
	}

	// 2. Not a table (or partitioned table)
	NSString *kind = [table objectForKey:SPQueryEditKindKey];
	if (![kind isEqualToString:@"r"] && ![kind isEqualToString:@"p"]) {
		if (message) {
			*message = ([kind isEqualToString:@"v"] || [kind isEqualToString:@"m"])
				? NSLocalizedString(@"This is a view, so its rows can't be edited.", @"Postgres content: view is read-only")
				: NSLocalizedString(@"This is not a table, so its rows can't be edited.", @"Postgres content: non-table is read-only");
		}
		return SPPostgresCellNotATable;
	}

	// 3. Generated
	if ([[originColumn objectForKey:SPQueryEditGeneratedKey] boolValue]) {
		if (message) *message = NSLocalizedString(@"This column is generated, so it can't be edited.", @"Postgres query result: generated column is read-only");
		return SPPostgresCellGeneratedColumn;
	}

	// 4. Read more than once by the statement (a self-join): the values can't tell its occurrences apart
	if ([_repeatedOrigins containsObject:@((long long)oid)]) {
		if (message) *message = NSLocalizedString(@"This table appears more than once in the query, so its rows can't be identified.", @"Postgres query result: origin table read more than once (self-join)");
		return SPPostgresCellOriginRepeated;
	}

	if (tableOut) *tableOut = table;
	return SPPostgresCellEditable;
}

- (SPPostgresCellEditability)editabilityOfRow:(NSUInteger)row column:(NSUInteger)column
								   matchCount:(NSInteger *)matchCount message:(NSString **)message
{
	if (matchCount) *matchCount = -1;
	if (message) *message = nil;

	NSDictionary *table = nil;
	SPPostgresCellEditability origin = [self originCheckOfColumn:column table:&table message:message];
	if (origin != SPPostgresCellEditable) return origin;
	unsigned int oid = [self originOfColumn:column];

	// 5–6. Count the rows the identifying values match
	NSMutableArray *values = [NSMutableArray array];
	NSString *sql = [NSString stringWithFormat:@"SELECT count(*) FROM %@ WHERE %@", [self qualifiedName:table],
					 [self whereClauseForRow:row origin:oid values:values]];

	__block NSInteger count = -1;
	NSError *error = nil;
	BOOL counted = SPPostgresRunGuardedRead(_connection, @"sp_query_edit_read", SPQueryEditAbortedMessage(), ^BOOL(NSError **bodyError) {
		PGPostgresResult *result = SPPostgresExecute(_connection, sql, values, bodyError);
		if (!result) return NO;
		count = [[result textValueAtRow:0 column:0] integerValue];
		return YES;
	}, &error);
	if (!counted) {
		if (message) *message = [error localizedDescription];
		return SPPostgresCellCheckFailed;
	}

	// 7. Exactly one row
	if (matchCount) *matchCount = count;
	if (count == 1) return SPPostgresCellEditable;
	if (count == 0) {
		if (message) *message = [NSString stringWithFormat:NSLocalizedString(@"Field is not editable. No matching record found.\nReload data, check encoding, or try to add\na primary key field or more fields\nin your SELECT statement for table '%@'\nto identify field origin unambiguously.", @"Custom Query result editing error - could not identify original row"), [table objectForKey:SPQueryEditNameKey]];
		return SPPostgresCellNoMatch;
	}
	if (message) *message = [NSString stringWithFormat:NSLocalizedString(@"Field is not editable. Couldn't identify field origin unambiguously (%ld matches).", @"Query result editing error - could not match row being edited uniquely"), (long)count];
	return SPPostgresCellTooManyMatches;
}

#pragma mark - Saving

- (id)saveValue:(id)value row:(NSUInteger)row column:(NSUInteger)column matchCount:(NSInteger *)matchCount error:(NSError **)error
{
	if (matchCount) *matchCount = -1;

	if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNull class]]) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The value must be text or NULL.", @"Postgres content: bad value class"), nil);
		return nil;
	}
	// Past the last row every value reads as NULL, which could identify some other row
	if (row >= [self rowCount]) {
		[NSException raise:NSRangeException format:@"%s: row %lu beyond %lu", __PRETTY_FUNCTION__, (unsigned long)row, (unsigned long)[self rowCount]];
	}

	// Refused before anything is sent (as SPPostgresRunAtomically would), also when the catalog isn't read yet
	NSString *aborted = NSLocalizedString(@"The current transaction is aborted, so the row was not changed. Roll it back first.", @"Postgres content: edit inside an aborted transaction");
	if ([_connection transactionStatus] == PGPostgresTransactionInError) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, aborted, nil);
		return nil;
	}

	NSDictionary *table = nil;
	NSString *message = nil;
	if ([self originCheckOfColumn:column table:&table message:&message] != SPPostgresCellEditable) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorNotEditable, message, nil);
		return nil;
	}

	unsigned int oid = [self originOfColumn:column];
	NSInteger attnum = [_result tableColumnForField:column];
	NSDictionary *originColumn = [self originColumnOfColumn:column];
	NSString *name = SPPostgresQuoteIdentifier([originColumn objectForKey:SPQueryEditNameKey]);
	NSString *qualifiedName = [self qualifiedName:table];

	// $1 is the new value; the identifying values follow it
	NSMutableArray *values = [NSMutableArray arrayWithObject:value];
	NSString *where = [self whereClauseForRow:row origin:oid values:values];
	if (![where length]) { // can't happen: the cell's own column is among the identifying ones
		if (error) *error = SPPostgresMakeError(SPPostgresErrorNotEditable, NSLocalizedString(@"Field is not editable. Field has no or multiple table or database origin(s).",@"field is not editable due to no table/database"), nil);
		return nil;
	}
	// RETURNING the column itself (not ::text): its output text, as the result shows it (t, padded char(n), inet)
	NSString *sql = [NSString stringWithFormat:@"UPDATE %@ SET %@ = $1::%@ WHERE %@ RETURNING %@",
					 qualifiedName, name, [originColumn objectForKey:SPQueryEditTypeKey], where, name];

	__block id saved = nil;
	__block NSInteger matched = -1;
	BOOL ok = SPPostgresRunAtomically(_connection, @"sp_query_edit", aborted, ^BOOL(NSError **bodyError) {
		PGPostgresResult *result = SPPostgresExecute(_connection, sql, values, bodyError);
		if (!result) return NO;

		// No LIMIT in a PostgreSQL UPDATE: one that didn't change exactly one row is undone
		unsigned long long rows = [result numberOfRows];
		if (rows != 1) {
			matched = (NSInteger)rows;
			if (bodyError) *bodyError = SPPostgresMakeError(SPPostgresErrorRowChanged, [NSString stringWithFormat:NSLocalizedString(@"Updating field content failed. Couldn't identify field origin unambiguously (%1$ld matches). It's very likely that while editing this field of table %2$@ was changed.", @"message of panel when error while updating field of a PostgreSQL query result"), (long)matched, qualifiedName], nil);
			return NO;
		}
		[saved release];
		saved = [[result textValueAtRow:0 column:0] retain];
		return YES;
	}, error);

	if (!ok) {
		if (matchCount && matched >= 0) *matchCount = matched;
		[saved release];
		return nil;
	}

	if (![saved isKindOfClass:[NSString class]]) {
		[saved release];
		saved = [[NSNull null] retain];
	}
	// Every result column showing this origin column, in this row, now shows the saved value
	for (NSUInteger other = 0; other < [self columnCount]; other++) {
		if ([self originOfColumn:other] == oid && [_result tableColumnForField:other] == attnum) {
			[_edits setObject:saved forKey:[self keyForRow:row column:other]];
		}
	}
	return [saved autorelease];
}

@end
