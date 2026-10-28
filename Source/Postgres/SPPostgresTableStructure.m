#import "SPPostgresTableStructure.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTableDuplicator.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

/// Fails with message (SPPostgresErrorQueryFailed) for a value refused before anything is sent.
static BOOL SPPostgresStructureRefuse(NSString *message, NSError **error)
{
	if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil);
	return NO;
}

/// The value as an NSString, or nil for NULL.
static NSString *SPPostgresStructureText(id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// A json_agg of strings as an NSArray (empty for NULL).
static NSArray *SPPostgresStructureJSONArray(id value)
{
	NSString *text = SPPostgresStructureText(value);
	if (!text) return @[];
	id array = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
	return [array isKindOfClass:[NSArray class]] ? array : @[];
}

static BOOL SPPostgresStructureIsTrue(id value)
{
	return [SPPostgresStructureText(value) isEqualToString:@"true"];
}

/// Every row of the query as arrays of NSString / NSNull (the query selects text), or nil on failure.
static NSArray *SPPostgresStructureRows(PGPostgresConnection *connection, NSString *sql, NSArray *values, NSError **error)
{
	PGPostgresResult *result = SPPostgresExecuteWithDetails(connection, sql, values, error);
	if (!result) return nil;

	NSMutableArray *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)[result numberOfRows]];
	for (unsigned long long row = 0; row < [result numberOfRows]; row++) {
		NSMutableArray *fields = [NSMutableArray arrayWithCapacity:[result numberOfFields]];
		for (NSUInteger column = 0; column < [result numberOfFields]; column++) {
			id value = [result textValueAtRow:row column:column];
			[fields addObject:[value isKindOfClass:[NSString class]] ? value : [NSNull null]];
		}
		[rows addObject:fields];
	}
	return rows;
}

/// The relation ($1 schema, $2 name) as a CTE `rel` (oid, relkind); no row when there is no such relation.
static NSString * const SPPostgresStructureRelation =
	@"WITH rel AS (SELECT c.oid, c.relkind FROM pg_catalog.pg_class c "
	"JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1::text AND c.relname = $2::text) ";

BOOL SPPostgresRunStructureChange(PGPostgresConnection *connection, NSTimeInterval lockTimeout, BOOL (^body)(NSError **error), NSError **error)
{
	NSString *aborted = NSLocalizedString(@"The current transaction is aborted, so the change was not made. Roll it back first (ROLLBACK in the Query view).", @"Postgres structure: change inside an aborted transaction");

	// Milliseconds; 0 means no limit
	double milliseconds = lockTimeout > 0 ? MIN(ceil(lockTimeout * 1000.0), (double)INT32_MAX) : 0;
	NSString *timeout = [NSString stringWithFormat:@"%.0f", milliseconds];

	return SPPostgresRunAtomically(connection, @"sp_structure", aborted, ^BOOL(NSError **bodyError) {
		// set_config(…, true) is SET LOCAL: inside our own transaction it ends with it; inside the user's it would
		// last to the end of theirs, so it is set back to the previous value (which may itself be the user's SET
		// LOCAL) before a successful finish. On failure the rollback (to the savepoint) undoes it. Either way the
		// session value is never touched.
		PGPostgresResult *previous = SPPostgresExecute(connection, @"SELECT pg_catalog.current_setting('lock_timeout')::text", nil, bodyError);
		if (!previous) return NO;
		NSString *previousValue = SPPostgresStructureText([previous textValueAtRow:0 column:0]) ?: @"0";

		NSString *set = @"SELECT pg_catalog.set_config('lock_timeout', $1::text, true)";
		if (!SPPostgresExecute(connection, set, @[timeout], bodyError)) return NO;
		if (!body(bodyError)) return NO;
		return SPPostgresExecute(connection, set, @[previousValue], bodyError) != nil;
	}, error);
}

#pragma mark - Model objects

@interface SPPostgresStructureColumn ()
@property (readwrite, copy) NSString *name;
@property (readwrite, copy) NSString *typeName;
@property (readwrite) BOOL nullable;
@property (readwrite, copy) NSString *defaultExpression;
@property (readwrite, copy) NSString *autoKind;
@property (readwrite, copy) NSString *generationExpression;
@property (readwrite, copy) NSString *comment;
@property (readwrite) NSInteger attnum;
@end

@implementation SPPostgresStructureColumn

@synthesize name = _name;
@synthesize typeName = _typeName;
@synthesize nullable = _nullable;
@synthesize defaultExpression = _defaultExpression;
@synthesize autoKind = _autoKind;
@synthesize generationExpression = _generationExpression;
@synthesize comment = _comment;
@synthesize attnum = _attnum;

- (void)dealloc
{
	[_name release];
	[_typeName release];
	[_defaultExpression release];
	[_autoKind release];
	[_generationExpression release];
	[_comment release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@%@>", [self class], _name, _typeName, [_autoKind length] ? [@" " stringByAppendingString:_autoKind] : @""];
}

@end

@interface SPPostgresIndex ()
@property (readwrite, copy) NSString *name;
@property (readwrite, copy) NSString *definition;
@property (readwrite, copy) NSArray *columns;
@property (readwrite, copy) NSString *method;
@property (readwrite) BOOL isUnique;
@property (readwrite) BOOL isPrimary;
@property (readwrite, copy) NSString *constraintName;
@end

@implementation SPPostgresIndex

@synthesize name = _name;
@synthesize definition = _definition;
@synthesize columns = _columns;
@synthesize method = _method;
@synthesize isUnique = _isUnique;
@synthesize isPrimary = _isPrimary;
@synthesize constraintName = _constraintName;

- (void)dealloc
{
	[_name release];
	[_definition release];
	[_columns release];
	[_method release];
	[_constraintName release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@>", [self class], _definition];
}

@end

@interface SPPostgresConstraint ()
@property (readwrite, copy) NSString *name;
@property (readwrite, copy) NSString *kind;
@property (readwrite, copy) NSString *definition;
@property (readwrite, copy) NSArray *columns;
@property (readwrite, copy) NSString *referencedSchema;
@property (readwrite, copy) NSString *referencedTable;
@property (readwrite, copy) NSArray *referencedColumns;
@property (readwrite, copy) NSString *onUpdate;
@property (readwrite, copy) NSString *onDelete;
@end

@implementation SPPostgresConstraint

@synthesize name = _name;
@synthesize kind = _kind;
@synthesize definition = _definition;
@synthesize columns = _columns;
@synthesize referencedSchema = _referencedSchema;
@synthesize referencedTable = _referencedTable;
@synthesize referencedColumns = _referencedColumns;
@synthesize onUpdate = _onUpdate;
@synthesize onDelete = _onDelete;

- (void)dealloc
{
	[_name release];
	[_kind release];
	[_definition release];
	[_columns release];
	[_referencedSchema release];
	[_referencedTable release];
	[_referencedColumns release];
	[_onUpdate release];
	[_onDelete release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@>", [self class], _name, _definition];
}

@end

@interface SPPostgresTrigger ()
@property (readwrite, copy) NSString *name;
@property (readwrite, copy) NSString *timing;
@property (readwrite, copy) NSString *events;
@property (readwrite, copy) NSString *level;
@property (readwrite, copy) NSString *functionSchema;
@property (readwrite, copy) NSString *functionName;
@property (readwrite, copy) NSString *condition;
@property (readwrite) BOOL enabled;
@property (readwrite, copy) NSString *definition;
@property (readwrite, copy) NSString *functionDefinition;
@end

@implementation SPPostgresTrigger

@synthesize name = _name;
@synthesize timing = _timing;
@synthesize events = _events;
@synthesize level = _level;
@synthesize functionSchema = _functionSchema;
@synthesize functionName = _functionName;
@synthesize condition = _condition;
@synthesize enabled = _enabled;
@synthesize definition = _definition;
@synthesize functionDefinition = _functionDefinition;

- (void)dealloc
{
	[_name release];
	[_timing release];
	[_events release];
	[_level release];
	[_functionSchema release];
	[_functionName release];
	[_condition release];
	[_definition release];
	[_functionDefinition release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@>", [self class], _definition];
}

@end

#pragma mark - Trigger definition text

/**
 * The index of the first occurrence of keyword in text at or after start that is outside double-quoted identifiers
 * and single-quoted literals (pg_get_triggerdef quotes both, doubling an embedded quote), or NSNotFound.
 */
static NSUInteger SPPostgresTriggerFind(NSString *text, NSString *keyword, NSUInteger start)
{
	unichar quote = 0;
	NSUInteger length = [text length];
	for (NSUInteger i = start; i < length; i++) {
		unichar c = [text characterAtIndex:i];
		if (quote) {
			if (c == quote) quote = 0; // a doubled quote closes and reopens: the same in the end
			continue;
		}
		if (c == '"' || c == '\'') {
			quote = c;
			continue;
		}
		if ([text compare:keyword options:NSLiteralSearch range:NSMakeRange(i, MIN([keyword length], length - i))] == NSOrderedSame) return i;
	}
	return NSNotFound;
}

/// The index of the parenthesis closing the one at open (quote-aware), or NSNotFound.
static NSUInteger SPPostgresTriggerClosingParenthesis(NSString *text, NSUInteger open)
{
	unichar quote = 0;
	NSInteger depth = 0;
	for (NSUInteger i = open; i < [text length]; i++) {
		unichar c = [text characterAtIndex:i];
		if (quote) {
			if (c == quote) quote = 0;
			continue;
		}
		if (c == '"' || c == '\'') quote = c;
		else if (c == '(') depth++;
		else if (c == ')' && --depth == 0) return i;
	}
	return NSNotFound;
}

/**
 * The events and WHEN condition of pg_get_triggerdef's text (`CREATE [CONSTRAINT] TRIGGER <quotedName> <timing>
 * <events> ON …[ WHEN (<condition>)] EXECUTE …`): the events are what lies between the timing and the first ON
 * outside quotes; the condition is the WHEN's parenthesised text, without the parentheses that enclose all of it.
 */
static void SPPostgresTriggerParse(NSString *definition, NSString *quotedName, NSString **events, NSString **condition)
{
	*events = nil;
	*condition = nil;
	NSRange nameRange = [definition rangeOfString:[NSString stringWithFormat:@"TRIGGER %@ ", quotedName]];
	if (nameRange.location == NSNotFound) return;

	NSUInteger start = NSMaxRange(nameRange);
	for (NSString *timing in @[@"BEFORE ", @"AFTER ", @"INSTEAD OF "]) {
		if ([definition length] >= start + [timing length] && [[definition substringWithRange:NSMakeRange(start, [timing length])] isEqualToString:timing]) {
			start += [timing length];
			break;
		}
	}
	NSUInteger on = SPPostgresTriggerFind(definition, @" ON ", start);
	if (on == NSNotFound) return;
	*events = [definition substringWithRange:NSMakeRange(start, on - start)];

	NSUInteger when = SPPostgresTriggerFind(definition, @" WHEN (", on);
	if (when == NSNotFound) return;
	NSUInteger open = when + [@" WHEN " length];
	NSUInteger close = SPPostgresTriggerClosingParenthesis(definition, open);
	if (close == NSNotFound) return;
	NSString *text = [definition substringWithRange:NSMakeRange(open + 1, close - open - 1)];

	// pg_get_triggerdef wraps the expression in parentheses of its own: drop those that enclose all of it
	while ([text hasPrefix:@"("] && SPPostgresTriggerClosingParenthesis(text, 0) == [text length] - 1) {
		text = [text substringWithRange:NSMakeRange(1, [text length] - 2)];
	}
	*condition = text;
}

@implementation SPPostgresColumnDefinition

@synthesize name = _name;
@synthesize typeName = _typeName;
@synthesize defaultExpression = _defaultExpression;
@synthesize notNull = _notNull;
@synthesize autoKind = _autoKind;
@synthesize comment = _comment;

- (void)dealloc
{
	[_name release];
	[_typeName release];
	[_defaultExpression release];
	[_autoKind release];
	[_comment release];
	[super dealloc];
}

@end

@implementation SPPostgresConstraintDefinition

@synthesize kind = _kind;
@synthesize name = _name;
@synthesize columns = _columns;
@synthesize checkExpression = _checkExpression;
@synthesize referencedSchema = _referencedSchema;
@synthesize referencedTable = _referencedTable;
@synthesize referencedColumns = _referencedColumns;
@synthesize onUpdate = _onUpdate;
@synthesize onDelete = _onDelete;

- (void)dealloc
{
	[_kind release];
	[_name release];
	[_columns release];
	[_checkExpression release];
	[_referencedSchema release];
	[_referencedTable release];
	[_referencedColumns release];
	[_onUpdate release];
	[_onDelete release];
	[super dealloc];
}

@end

#pragma mark - SPPostgresTableStructure

@implementation SPPostgresTableStructure

@synthesize schema = _schema;
@synthesize table = _table;
@synthesize lockTimeout = _lockTimeout;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table
{
	if ((self = [super init])) {
		_connection = [connection retain];
		_schema = [schema copy];
		_table = [table copy];
		_lockTimeout = 5;
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[_schema release];
	[_table release];
	[super dealloc];
}

#pragma mark - Helpers

/// "schema"."table"
- (NSString *)qualifiedName
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(_schema), SPPostgresQuoteIdentifier(_table)];
}

/// Fails with "There is no table …": the relation is gone (dropped, renamed elsewhere, or a rename rolled back).
- (void)noSuchRelation:(NSError **)error
{
	SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"There is no table “%@” in schema “%@”.", @"Postgres structure: no such relation"), _table, _schema], error);
}

/// The rows of sql, run after the CTE `rel` ($1 schema, $2 table; values are $3…), or nil on failure. Every read
/// goes through here: an empty result is checked against the relation's existence, so a missing relation fails
/// with -noSuchRelation: instead of reading as an empty one.
- (NSArray *)rows:(NSString *)sql values:(NSArray *)values error:(NSError **)error
{
	NSMutableArray *all = [NSMutableArray arrayWithObjects:_schema ?: @"", _table ?: @"", nil];
	[all addObjectsFromArray:values ?: @[]];
	NSArray *rows = SPPostgresStructureRows(_connection, [SPPostgresStructureRelation stringByAppendingString:sql], all, error);
	if (!rows || [rows count]) return rows;

	NSArray *exists = SPPostgresStructureRows(_connection, [SPPostgresStructureRelation stringByAppendingString:@"SELECT 1::text FROM rel"],
											  [all subarrayWithRange:NSMakeRange(0, 2)], error);
	if (!exists) return nil;
	if (![exists count]) {
		[self noSuchRelation:error];
		return nil;
	}
	return rows;
}

/// Runs one DDL statement, reporting the server's message with its DETAIL and HINT.
- (BOOL)run:(NSString *)sql error:(NSError **)error
{
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

/// Runs body as one structure change (see SPPostgresRunStructureChange).
- (BOOL)change:(BOOL (^)(NSError **error))body error:(NSError **)error
{
	return SPPostgresRunStructureChange(_connection, _lockTimeout, body, error);
}

/// Runs the statements, in order, as one structure change.
- (BOOL)changeWith:(NSArray *)statements error:(NSError **)error
{
	return [self change:^BOOL(NSError **bodyError) {
		for (NSString *sql in statements) {
			if (![self run:sql error:bodyError]) return NO;
		}
		return YES;
	} error:error];
}

/// NO (with an error) for a name PostgreSQL wouldn't keep as given: empty, or over 63 bytes.
- (BOOL)checkName:(NSString *)name error:(NSError **)error
{
	if (![name length]) {
		return SPPostgresStructureRefuse(NSLocalizedString(@"The name must not be empty.", @"Postgres structure: empty name"), error);
	}
	if (![SPPostgresTableDuplicator isValidTableName:name]) {
		return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"The name “%@” is too long: PostgreSQL names can be at most 63 bytes.", @"Postgres structure: name too long"), name], error);
	}
	return YES;
}

/// ("a", "b"), or nil (with an error) when columns is empty or holds an empty name.
- (NSString *)columnList:(NSArray *)columns error:(NSError **)error
{
	NSMutableArray *quoted = [NSMutableArray arrayWithCapacity:[columns count]];
	for (id column in columns) {
		if (![column isKindOfClass:[NSString class]] || ![column length]) {
			SPPostgresStructureRefuse(NSLocalizedString(@"A column name must not be empty.", @"Postgres structure: empty column name"), error);
			return nil;
		}
		[quoted addObject:SPPostgresQuoteIdentifier(column)];
	}
	if (![quoted count]) {
		SPPostgresStructureRefuse(NSLocalizedString(@"Choose at least one column.", @"Postgres structure: no columns"), error);
		return nil;
	}
	return [NSString stringWithFormat:@"(%@)", [quoted componentsJoinedByString:@", "]];
}

/// The keyword for COMMENT ON / ALTER … RENAME: TABLE, VIEW, MATERIALIZED VIEW or FOREIGN TABLE; nil on failure.
- (NSString *)objectKeyword:(NSError **)error
{
	NSString *kind = [self relationKind:error];
	if (!kind) return nil;
	if ([kind isEqualToString:@"view"]) return @"VIEW";
	if ([kind isEqualToString:@"materialized view"]) return @"MATERIALIZED VIEW";
	if ([kind isEqualToString:@"foreign table"]) return @"FOREIGN TABLE";
	return @"TABLE";
}

#pragma mark - Reading

/// The kind's name for a relkind (see -relationKind:), or nil (with an error) for one that isn't a table or view.
- (NSString *)kindForRelkind:(id)relkind error:(NSError **)error
{
	NSDictionary *kinds = @{@"r": @"table", @"p": @"partitioned table", @"v": @"view", @"m": @"materialized view", @"f": @"foreign table"};
	NSString *kind = kinds[SPPostgresStructureText(relkind) ?: @""];
	if (!kind) {
		SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a table or view.", @"Postgres structure: unsupported relation kind"), _table], error);
	}
	return kind;
}

- (NSString *)relationKind:(NSError **)error
{
	NSArray *rows = [self rows:@"SELECT relkind::text FROM rel" values:nil error:error];
	if (!rows) return nil; // a missing relation fails in -rows:…
	return [self kindForRelkind:rows[0][0] error:error];
}

- (NSDictionary *)tableInfo:(NSError **)error
{
	// reltuples is -1 for "never vacuumed or analyzed" from PostgreSQL 14; before, it is 0 then (as for an empty
	// table that was), so 0 with no pages and nothing on record counts as no estimate too
	NSArray *rows = [self rows:
		@"SELECT rel.relkind::text, pg_catalog.pg_get_userbyid(c.relowner)::text,"
		" CASE WHEN rel.relkind = 'v' OR c.reltuples < 0 THEN NULL"
		"  WHEN c.reltuples = 0 AND c.relpages = 0 AND s.last_vacuum IS NULL AND s.last_autovacuum IS NULL"
		"   AND s.last_analyze IS NULL AND s.last_autoanalyze IS NULL THEN NULL"
		"  ELSE pg_catalog.round(c.reltuples::numeric) END::text,"
		" pg_catalog.pg_size_pretty(pg_catalog.pg_table_size(c.oid))::text,"
		" pg_catalog.pg_size_pretty(pg_catalog.pg_indexes_size(c.oid))::text,"
		" pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(c.oid))::text,"
		" pg_catalog.obj_description(c.oid, 'pg_class')::text"
		" FROM rel JOIN pg_catalog.pg_class c ON c.oid = rel.oid"
		" LEFT JOIN pg_catalog.pg_stat_all_tables s ON s.relid = c.oid" values:nil error:error];
	if (!rows) return nil; // a missing relation fails in -rows:…

	NSArray *row = rows[0];
	NSString *kind = [self kindForRelkind:row[0] error:error];
	if (!kind) return nil;

	NSString *estimate = SPPostgresStructureText(row[2]);
	NSNull *none = [NSNull null];
	return @{
		@"kind": kind,
		@"owner": SPPostgresStructureText(row[1]) ?: @"",
		@"rowEstimate": estimate ? (id)@([estimate longLongValue]) : none,
		@"tableSize": SPPostgresStructureText(row[3]) ?: @"",
		@"indexSize": SPPostgresStructureText(row[4]) ?: @"",
		@"totalSize": SPPostgresStructureText(row[5]) ?: @"",
		@"comment": SPPostgresStructureText(row[6]) ?: (id)none,
	};
}

- (NSArray *)columns:(NSError **)error
{
	// serial: the default depends on a sequence that the column owns (deptype 'a', as CREATE … serial makes it)
	NSArray *rows = [self rows:
		@"SELECT a.attname::text, pg_catalog.format_type(a.atttypid, a.atttypmod)::text, (NOT a.attnotnull)::text,"
		" pg_catalog.pg_get_expr(d.adbin, d.adrelid)::text, a.attidentity::text, a.attgenerated::text,"
		" pg_catalog.col_description(a.attrelid, a.attnum)::text, a.attnum::text,"
		" EXISTS (SELECT 1 FROM pg_catalog.pg_depend dd"
		"   JOIN pg_catalog.pg_class s ON s.oid = dd.refobjid AND s.relkind = 'S'"
		"   JOIN pg_catalog.pg_depend od ON od.classid = 'pg_catalog.pg_class'::regclass AND od.objid = s.oid"
		"     AND od.refclassid = 'pg_catalog.pg_class'::regclass AND od.refobjid = a.attrelid AND od.refobjsubid = a.attnum AND od.deptype = 'a'"
		"   WHERE dd.classid = 'pg_catalog.pg_attrdef'::regclass AND dd.objid = d.oid AND dd.refclassid = 'pg_catalog.pg_class'::regclass)::text"
		" FROM rel JOIN pg_catalog.pg_attribute a ON a.attrelid = rel.oid"
		" LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum"
		" WHERE a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum" values:nil error:error];
	if (!rows) return nil;

	NSMutableArray *columns = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		SPPostgresStructureColumn *column = [[[SPPostgresStructureColumn alloc] init] autorelease];
		column.name = SPPostgresStructureText(row[0]);
		column.typeName = SPPostgresStructureText(row[1]);
		column.nullable = SPPostgresStructureIsTrue(row[2]);
		NSString *expression = SPPostgresStructureText(row[3]);
		NSString *identity = SPPostgresStructureText(row[4]) ?: @"";
		NSString *generated = SPPostgresStructureText(row[5]) ?: @"";
		column.comment = SPPostgresStructureText(row[6]);
		column.attnum = [SPPostgresStructureText(row[7]) integerValue];

		if ([generated length]) { // 's' stored, or (PG 18) 'v' virtual
			column.autoKind = @"generated";
			column.generationExpression = expression;
		}
		else {
			column.defaultExpression = expression;
			if ([identity isEqualToString:@"a"]) column.autoKind = @"identity always";
			else if ([identity isEqualToString:@"d"]) column.autoKind = @"identity";
			else if (SPPostgresStructureIsTrue(row[8]) && [expression hasPrefix:@"nextval("]) column.autoKind = @"serial";
			else column.autoKind = @"";
		}
		[columns addObject:column];
	}
	return columns;
}

- (NSArray *)indexes:(NSError **)error
{
	NSArray *rows = [self rows:
		@"SELECT ic.relname::text, pg_catalog.pg_get_indexdef(i.indexrelid)::text, am.amname::text,"
		" i.indisunique::text, i.indisprimary::text, con.conname::text,"
		" (SELECT pg_catalog.json_agg(CASE WHEN k.attnum <> 0 THEN att.attname::text"
		"     ELSE pg_catalog.pg_get_indexdef(i.indexrelid, k.n::int, true) END ORDER BY k.n)"
		"   FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, n)"
		"   LEFT JOIN pg_catalog.pg_attribute att ON att.attrelid = i.indrelid AND att.attnum = k.attnum"
		"   WHERE k.n <= i.indnkeyatts)::text"
		" FROM rel JOIN pg_catalog.pg_index i ON i.indrelid = rel.oid"
		" JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid"
		" JOIN pg_catalog.pg_am am ON am.oid = ic.relam"
		" LEFT JOIN pg_catalog.pg_constraint con ON con.conindid = i.indexrelid AND con.conrelid = i.indrelid AND con.contype IN ('p', 'u', 'x')"
		" WHERE rel.relkind NOT IN ('v', 'm')"
		" ORDER BY ic.relname COLLATE \"C\"" values:nil error:error];
	if (!rows) return nil;

	NSMutableArray *indexes = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		SPPostgresIndex *index = [[[SPPostgresIndex alloc] init] autorelease];
		index.name = SPPostgresStructureText(row[0]);
		index.definition = SPPostgresStructureText(row[1]);
		index.method = SPPostgresStructureText(row[2]);
		index.isUnique = SPPostgresStructureIsTrue(row[3]);
		index.isPrimary = SPPostgresStructureIsTrue(row[4]);
		index.constraintName = SPPostgresStructureText(row[5]);
		index.columns = SPPostgresStructureJSONArray(row[6]);
		[indexes addObject:index];
	}
	return indexes;
}

- (NSArray *)constraints:(NSError **)error
{
	// contype 'n' (PG 18's NOT NULL) and 't' (constraint triggers) are left out
	NSArray *rows = [self rows:
		@"SELECT con.conname::text, con.contype::text, pg_catalog.pg_get_constraintdef(con.oid)::text,"
		" (SELECT pg_catalog.json_agg(att.attname::text ORDER BY k.n) FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, n)"
		"   JOIN pg_catalog.pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = k.attnum)::text,"
		" fn.nspname::text, fc.relname::text,"
		" (SELECT pg_catalog.json_agg(att.attname::text ORDER BY k.n) FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, n)"
		"   JOIN pg_catalog.pg_attribute att ON att.attrelid = con.confrelid AND att.attnum = k.attnum)::text,"
		" con.confupdtype::text, con.confdeltype::text"
		" FROM rel JOIN pg_catalog.pg_constraint con ON con.conrelid = rel.oid"
		" LEFT JOIN pg_catalog.pg_class fc ON con.contype = 'f' AND fc.oid = con.confrelid"
		" LEFT JOIN pg_catalog.pg_namespace fn ON fn.oid = fc.relnamespace"
		" WHERE con.contype IN ('p', 'u', 'c', 'f', 'x') AND rel.relkind NOT IN ('v', 'm')"
		" ORDER BY con.conname COLLATE \"C\"" values:nil error:error];
	if (!rows) return nil;

	NSDictionary *kinds = @{@"p": @"PRIMARY KEY", @"u": @"UNIQUE", @"c": @"CHECK", @"f": @"FOREIGN KEY", @"x": @"EXCLUDE"};
	NSDictionary *actions = @{@"a": @"NO ACTION", @"r": @"RESTRICT", @"c": @"CASCADE", @"n": @"SET NULL", @"d": @"SET DEFAULT"};
	NSMutableArray *constraints = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		SPPostgresConstraint *constraint = [[[SPPostgresConstraint alloc] init] autorelease];
		NSString *type = SPPostgresStructureText(row[1]) ?: @"";
		constraint.name = SPPostgresStructureText(row[0]);
		constraint.kind = kinds[type];
		constraint.definition = SPPostgresStructureText(row[2]);
		constraint.columns = SPPostgresStructureJSONArray(row[3]);
		if ([type isEqualToString:@"f"]) {
			constraint.referencedSchema = SPPostgresStructureText(row[4]);
			constraint.referencedTable = SPPostgresStructureText(row[5]);
			constraint.referencedColumns = SPPostgresStructureJSONArray(row[6]);
			constraint.onUpdate = actions[SPPostgresStructureText(row[7]) ?: @""];
			constraint.onDelete = actions[SPPostgresStructureText(row[8]) ?: @""];
		}
		[constraints addObject:constraint];
	}
	return constraints;
}

- (NSString *)tableComment:(NSError **)error
{
	NSArray *rows = [self rows:@"SELECT pg_catalog.obj_description(rel.oid, 'pg_class')::text FROM rel" values:nil error:error];
	if (!rows) return nil; // a missing relation fails in -rows:…
	return SPPostgresStructureText(rows[0][0]);
}

#pragma mark - Columns

- (BOOL)addColumn:(SPPostgresColumnDefinition *)definition error:(NSError **)error
{
	NSString *name = [definition name];
	if (![self checkName:name error:error]) return NO;

	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *type = [[definition typeName] stringByTrimmingCharactersInSet:whitespace];
	if (![type length]) return SPPostgresStructureRefuse(NSLocalizedString(@"The column type must not be empty.", @"Postgres structure: empty column type"), error);

	NSString *autoKind = [definition autoKind] ?: @"";
	NSString *identity = @"";
	if ([autoKind isEqualToString:@"serial"]) {
		NSDictionary *serials = @{@"integer": @"serial", @"int": @"serial", @"int4": @"serial",
								  @"bigint": @"bigserial", @"int8": @"bigserial",
								  @"smallint": @"smallserial", @"int2": @"smallserial"};
		NSString *serial = serials[[type lowercaseString]];
		if (!serial) return SPPostgresStructureRefuse(NSLocalizedString(@"Only integer columns can be serial.", @"Postgres structure: serial on a non-integer type"), error);
		type = serial;
	}
	else if ([autoKind isEqualToString:@"identity"]) identity = @" GENERATED BY DEFAULT AS IDENTITY";
	else if ([autoKind isEqualToString:@"identity always"]) identity = @" GENERATED ALWAYS AS IDENTITY";
	else if ([autoKind length]) {
		return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a kind of column that can be added.", @"Postgres structure: unknown auto kind"), autoKind], error);
	}

	NSString *column = SPPostgresQuoteIdentifier(name);
	NSMutableString *sql = [NSMutableString stringWithFormat:@"ALTER TABLE %@ ADD COLUMN %@ %@", [self qualifiedName], column, type];
	NSString *defaultExpression = [[definition defaultExpression] stringByTrimmingCharactersInSet:whitespace];
	if ([defaultExpression length]) [sql appendFormat:@" DEFAULT %@", defaultExpression];
	if ([definition notNull]) [sql appendString:@" NOT NULL"];
	[sql appendString:identity];

	NSMutableArray *statements = [NSMutableArray arrayWithObject:sql];
	if ([[definition comment] length]) {
		[statements addObject:[NSString stringWithFormat:@"COMMENT ON COLUMN %@.%@ IS %@", [self qualifiedName], column, SPPostgresQuoteLiteral([definition comment])]];
	}
	return [self changeWith:statements error:error];
}

- (BOOL)renameColumn:(NSString *)column to:(NSString *)newName error:(NSError **)error
{
	if (![self checkName:newName error:error]) return NO;
	return [self changeWith:@[[NSString stringWithFormat:@"ALTER TABLE %@ RENAME COLUMN %@ TO %@", [self qualifiedName],
							   SPPostgresQuoteIdentifier(column), SPPostgresQuoteIdentifier(newName)]] error:error];
}

- (BOOL)changeColumn:(NSString *)column toType:(NSString *)typeName using:(NSString *)usingExpression error:(NSError **)error
{
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *type = [typeName stringByTrimmingCharactersInSet:whitespace];
	if (![type length]) return SPPostgresStructureRefuse(NSLocalizedString(@"The column type must not be empty.", @"Postgres structure: empty column type"), error);

	NSMutableString *sql = [NSMutableString stringWithFormat:@"ALTER TABLE %@ ALTER COLUMN %@ TYPE %@", [self qualifiedName], SPPostgresQuoteIdentifier(column), type];
	NSString *usingText = [usingExpression stringByTrimmingCharactersInSet:whitespace];
	if ([usingText length]) [sql appendFormat:@" USING %@", usingText];
	return [self changeWith:@[sql] error:error];
}

- (BOOL)setDefault:(NSString *)expression forColumn:(NSString *)column error:(NSError **)error
{
	NSString *trimmed = [expression stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *action = [trimmed length] ? [NSString stringWithFormat:@"SET DEFAULT %@", trimmed] : @"DROP DEFAULT";
	return [self changeWith:@[[NSString stringWithFormat:@"ALTER TABLE %@ ALTER COLUMN %@ %@", [self qualifiedName], SPPostgresQuoteIdentifier(column), action]] error:error];
}

- (BOOL)setNullable:(BOOL)nullable forColumn:(NSString *)column error:(NSError **)error
{
	return [self changeWith:@[[NSString stringWithFormat:@"ALTER TABLE %@ ALTER COLUMN %@ %@", [self qualifiedName], SPPostgresQuoteIdentifier(column),
							   nullable ? @"DROP NOT NULL" : @"SET NOT NULL"]] error:error];
}

- (BOOL)setComment:(NSString *)comment forColumn:(NSString *)column error:(NSError **)error
{
	NSString *value = [comment length] ? SPPostgresQuoteLiteral(comment) : @"NULL";
	return [self changeWith:@[[NSString stringWithFormat:@"COMMENT ON COLUMN %@.%@ IS %@", [self qualifiedName], SPPostgresQuoteIdentifier(column), value]] error:error];
}

- (NSArray *)dependentsOfColumn:(NSString *)column error:(NSError **)error
{
	// Everything pg_depend has on the column, but its own default and the sequence it owns (serial, identity),
	// which go with it, and PG 18's NOT NULL constraint, which is the column's own. A view's rule is described
	// as the view; another column's default (a generation expression on PG 18) as that column. Foreign keys of
	// other tables are added from confkey too.
	NSArray *rows = [self rows:
		@", col AS (SELECT a.attrelid AS relid, a.attnum FROM rel JOIN pg_catalog.pg_attribute a ON a.attrelid = rel.oid"
		"   WHERE a.attname = $3::text AND a.attnum > 0 AND NOT a.attisdropped)"
		" SELECT s.description::text FROM ("
		"  SELECT CASE"
		"    WHEN r.oid IS NOT NULL AND vc.relkind IN ('v', 'm') THEN pg_catalog.pg_describe_object('pg_catalog.pg_class'::regclass, r.ev_class, 0)"
		"    WHEN ad.oid IS NOT NULL THEN pg_catalog.pg_describe_object('pg_catalog.pg_class'::regclass, ad.adrelid, ad.adnum)"
		"    ELSE pg_catalog.pg_describe_object(d.classid, d.objid, d.objsubid) END AS description"
		"  FROM col JOIN pg_catalog.pg_depend d ON d.refclassid = 'pg_catalog.pg_class'::regclass AND d.refobjid = col.relid AND d.refobjsubid = col.attnum"
		"  LEFT JOIN pg_catalog.pg_rewrite r ON d.classid = 'pg_catalog.pg_rewrite'::regclass AND r.oid = d.objid"
		"  LEFT JOIN pg_catalog.pg_class vc ON vc.oid = r.ev_class"
		"  LEFT JOIN pg_catalog.pg_attrdef ad ON d.classid = 'pg_catalog.pg_attrdef'::regclass AND ad.oid = d.objid"
		"  LEFT JOIN pg_catalog.pg_class sq ON d.classid = 'pg_catalog.pg_class'::regclass AND sq.oid = d.objid"
		"  LEFT JOIN pg_catalog.pg_constraint nn ON d.classid = 'pg_catalog.pg_constraint'::regclass AND nn.oid = d.objid"
		"  WHERE NOT (ad.oid IS NOT NULL AND ad.adrelid = col.relid AND ad.adnum = col.attnum)"
		"    AND NOT (sq.oid IS NOT NULL AND sq.relkind = 'S' AND d.deptype IN ('a', 'i'))"
		"    AND NOT (nn.oid IS NOT NULL AND nn.contype = 'n')"
		"    AND NOT (d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = col.relid AND d.objsubid = col.attnum)"
		"  UNION"
		"  SELECT pg_catalog.pg_describe_object('pg_catalog.pg_constraint'::regclass, fk.oid, 0)"
		"  FROM col JOIN pg_catalog.pg_constraint fk ON fk.contype = 'f' AND fk.confrelid = col.relid AND col.attnum = ANY (fk.confkey)"
		" ) s WHERE s.description IS NOT NULL GROUP BY s.description ORDER BY s.description COLLATE \"C\"" values:@[column ?: @""] error:error];
	if (!rows) return nil;

	NSMutableArray *dependents = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *description = SPPostgresStructureText(row[0]);
		if (description) [dependents addObject:description];
	}
	return dependents;
}

- (BOOL)dropColumn:(NSString *)column error:(NSError **)error
{
	// PostgreSQL would drop the column's indexes and constraints with it, unasked: check first, in the same
	// transaction as the drop.
	// ACCESS EXCLUSIVE first (under lock_timeout): no other session can add an index, view or constraint on the
	// column between the check and the drop, which PostgreSQL would otherwise drop with it unasked.
	return [self change:^BOOL(NSError **bodyError) {
		if (![self run:[NSString stringWithFormat:@"LOCK TABLE %@ IN ACCESS EXCLUSIVE MODE", [self qualifiedName]] error:bodyError]) return NO;
		NSArray *dependents = [self dependentsOfColumn:column error:bodyError];
		if (!dependents) return NO;
		if ([dependents count]) {
			if (bodyError) {
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"\"%@\" can't be deleted because other objects depend on it.", @"Postgres structure: column has dependents"), column];
				*bodyError = SPPostgresMakeError(SPPostgresErrorHasDependents, message, @{SPPostgresDependentsErrorKey: dependents});
			}
			return NO;
		}
		return [self run:[NSString stringWithFormat:@"ALTER TABLE %@ DROP COLUMN %@", [self qualifiedName], SPPostgresQuoteIdentifier(column)] error:bodyError];
	} error:error];
}

#pragma mark - Indexes and constraints

- (BOOL)addIndexNamed:(NSString *)name columns:(NSArray *)columns unique:(BOOL)unique method:(NSString *)method error:(NSError **)error
{
	if (name && ![self checkName:name error:error]) return NO;

	NSString *accessMethod = [method length] ? [method lowercaseString] : @"btree";
	if (![@[@"btree", @"hash", @"gist", @"gin", @"brin"] containsObject:accessMethod]) {
		return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not an index method (btree, hash, gist, gin or brin).", @"Postgres structure: unknown index method"), method], error);
	}
	NSString *list = [self columnList:columns error:error];
	if (!list) return NO;

	// Not CONCURRENTLY: that can't run inside a transaction
	NSString *sql = [NSString stringWithFormat:@"CREATE %@INDEX %@ON %@ USING %@ %@", unique ? @"UNIQUE " : @"",
					 name ? [SPPostgresQuoteIdentifier(name) stringByAppendingString:@" "] : @"", [self qualifiedName], accessMethod, list];
	return [self changeWith:@[sql] error:error];
}

- (BOOL)dropIndexNamed:(NSString *)name error:(NSError **)error
{
	return [self change:^BOOL(NSError **bodyError) {
		NSArray *rows = [self rows:
			@"SELECT con.conname::text FROM rel JOIN pg_catalog.pg_index i ON i.indrelid = rel.oid"
			" JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid"
			" LEFT JOIN pg_catalog.pg_constraint con ON con.conindid = i.indexrelid AND con.conrelid = i.indrelid AND con.contype IN ('p', 'u', 'x')"
			" WHERE ic.relname = $3::text" values:@[name ?: @""] error:bodyError];
		if (!rows) return NO;
		if (![rows count]) {
			return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"There is no index “%@” on this table.", @"Postgres structure: no such index"), name], bodyError);
		}
		NSString *constraint = SPPostgresStructureText(rows[0][0]);
		NSString *sql = constraint
			? [NSString stringWithFormat:@"ALTER TABLE %@ DROP CONSTRAINT %@", [self qualifiedName], SPPostgresQuoteIdentifier(constraint)]
			: [NSString stringWithFormat:@"DROP INDEX %@.%@", SPPostgresQuoteIdentifier(self->_schema), SPPostgresQuoteIdentifier(name)];
		return [self run:sql error:bodyError];
	} error:error];
}

- (BOOL)addConstraint:(SPPostgresConstraintDefinition *)definition error:(NSError **)error
{
	NSString *kind = [definition kind] ?: @"";
	if (![@[@"PRIMARY KEY", @"UNIQUE", @"CHECK", @"FOREIGN KEY"] containsObject:kind]) {
		return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a kind of constraint that can be added.", @"Postgres structure: unknown constraint kind"), kind], error);
	}
	NSString *name = [definition name];
	if (name && ![self checkName:name error:error]) return NO;

	NSMutableString *sql = [NSMutableString stringWithFormat:@"ALTER TABLE %@ ADD ", [self qualifiedName]];
	if (name) [sql appendFormat:@"CONSTRAINT %@ ", SPPostgresQuoteIdentifier(name)];

	if ([kind isEqualToString:@"CHECK"]) {
		NSString *expression = [[definition checkExpression] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (![expression length]) return SPPostgresStructureRefuse(NSLocalizedString(@"The check expression must not be empty.", @"Postgres structure: empty check"), error);
		[sql appendFormat:@"CHECK (%@)", expression];
	}
	else {
		NSString *list = [self columnList:[definition columns] error:error];
		if (!list) return NO;
		[sql appendFormat:@"%@ %@", kind, list];

		if ([kind isEqualToString:@"FOREIGN KEY"]) {
			if (![[definition referencedTable] length]) {
				return SPPostgresStructureRefuse(NSLocalizedString(@"Choose the table the foreign key references.", @"Postgres structure: no referenced table"), error);
			}
			NSString *schema = [[definition referencedSchema] length] ? [definition referencedSchema] : _schema;
			[sql appendFormat:@" REFERENCES %@.%@", SPPostgresQuoteIdentifier(schema), SPPostgresQuoteIdentifier([definition referencedTable])];
			if ([[definition referencedColumns] count]) {
				NSString *referenced = [self columnList:[definition referencedColumns] error:error];
				if (!referenced) return NO;
				[sql appendFormat:@" %@", referenced];
			}
			NSArray *actions = @[@"NO ACTION", @"RESTRICT", @"CASCADE", @"SET NULL", @"SET DEFAULT"];
			for (NSString *clause in @[@"UPDATE", @"DELETE"]) {
				NSString *action = [clause isEqualToString:@"UPDATE"] ? [definition onUpdate] : [definition onDelete];
				if (![action length]) continue;
				NSString *upper = [action uppercaseString];
				if (![actions containsObject:upper]) {
					return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a foreign key action.", @"Postgres structure: unknown foreign key action"), action], error);
				}
				[sql appendFormat:@" ON %@ %@", clause, upper];
			}
		}
	}
	return [self changeWith:@[sql] error:error];
}

- (BOOL)dropConstraintNamed:(NSString *)name error:(NSError **)error
{
	return [self changeWith:@[[NSString stringWithFormat:@"ALTER TABLE %@ DROP CONSTRAINT %@", [self qualifiedName], SPPostgresQuoteIdentifier(name)]] error:error];
}

#pragma mark - Triggers

- (NSArray *)triggers:(NSError **)error
{
	NSArray *rows = [self rows:
		@"SELECT t.tgname::text, pg_catalog.quote_ident(t.tgname)::text, pg_catalog.pg_get_triggerdef(t.oid)::text, t.tgtype::text,"
		" (t.tgenabled <> 'D')::text, fn.nspname::text, p.proname::text, pg_catalog.pg_get_functiondef(p.oid)::text"
		" FROM rel JOIN pg_catalog.pg_trigger t ON t.tgrelid = rel.oid"
		" JOIN pg_catalog.pg_proc p ON p.oid = t.tgfoid"
		" JOIN pg_catalog.pg_namespace fn ON fn.oid = p.pronamespace"
		" WHERE NOT t.tgisinternal"
		" ORDER BY t.tgname COLLATE \"C\"" values:nil error:error];
	if (!rows) return nil;

	NSMutableArray *triggers = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		SPPostgresTrigger *trigger = [[[SPPostgresTrigger alloc] init] autorelease];
		trigger.name = SPPostgresStructureText(row[0]);
		trigger.definition = SPPostgresStructureText(row[2]);

		// tgtype (pg_trigger.h): ROW 1, BEFORE 2, INSTEAD 64
		NSInteger type = [SPPostgresStructureText(row[3]) integerValue];
		trigger.level = (type & 1) ? @"ROW" : @"STATEMENT";
		trigger.timing = (type & 64) ? @"INSTEAD OF" : ((type & 2) ? @"BEFORE" : @"AFTER");

		NSString *events = nil, *condition = nil;
		SPPostgresTriggerParse(trigger.definition ?: @"", SPPostgresStructureText(row[1]) ?: @"", &events, &condition);
		trigger.events = events ?: @"";
		trigger.condition = condition;

		trigger.enabled = SPPostgresStructureIsTrue(row[4]);
		trigger.functionSchema = SPPostgresStructureText(row[5]);
		trigger.functionName = SPPostgresStructureText(row[6]);
		trigger.functionDefinition = SPPostgresStructureText(row[7]);
		[triggers addObject:trigger];
	}
	return triggers;
}

- (NSArray *)triggerFunctions:(NSError **)error
{
	NSArray *rows = SPPostgresStructureRows(_connection,
		@"SELECT pg_catalog.quote_ident(n.nspname)::text || '.' || pg_catalog.quote_ident(p.proname)::text"
		" FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace"
		" WHERE p.prorettype = 'pg_catalog.trigger'::pg_catalog.regtype AND p.pronargs = 0"
		" AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
		" ORDER BY n.nspname COLLATE \"C\", p.proname COLLATE \"C\"", nil, error);
	if (!rows) return nil;

	NSMutableArray *functions = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *function = SPPostgresStructureText(row[0]);
		if (function) [functions addObject:function];
	}
	return functions;
}

- (BOOL)addTriggerNamed:(NSString *)name timing:(NSString *)timing events:(NSArray *)events updateColumns:(NSArray *)columns level:(NSString *)level function:(NSString *)qualifiedFunction condition:(NSString *)condition error:(NSError **)error
{
	if (![self checkName:name error:error]) return NO;

	NSString *theTiming = [timing uppercaseString] ?: @"";
	if (![@[@"BEFORE", @"AFTER", @"INSTEAD OF"] containsObject:theTiming]) {
		return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a trigger timing (BEFORE, AFTER or INSTEAD OF).", @"Postgres structure: unknown trigger timing"), timing], error);
	}
	NSString *theLevel = [level uppercaseString] ?: @"";
	if (![@[@"ROW", @"STATEMENT"] containsObject:theLevel]) {
		return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a trigger level (ROW or STATEMENT).", @"Postgres structure: unknown trigger level"), level], error);
	}

	// The events in the server's own order
	NSMutableSet *chosen = [NSMutableSet set];
	for (id event in events) {
		NSString *upper = [event isKindOfClass:[NSString class]] ? [event uppercaseString] : @"";
		if (![@[@"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE"] containsObject:upper]) {
			return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a trigger event (INSERT, UPDATE, DELETE or TRUNCATE).", @"Postgres structure: unknown trigger event"), event], error);
		}
		[chosen addObject:upper];
	}
	if (![chosen count]) return SPPostgresStructureRefuse(NSLocalizedString(@"Choose at least one event.", @"Postgres structure: no trigger event"), error);

	NSMutableArray *clauses = [NSMutableArray array];
	for (NSString *event in @[@"INSERT", @"DELETE", @"UPDATE", @"TRUNCATE"]) {
		if (![chosen containsObject:event]) continue;
		if ([event isEqualToString:@"UPDATE"] && [columns count]) {
			NSString *list = [self columnList:columns error:error];
			if (!list) return NO;
			[clauses addObject:[NSString stringWithFormat:@"UPDATE OF %@", [list substringWithRange:NSMakeRange(1, [list length] - 2)]]];
		}
		else {
			[clauses addObject:event];
		}
	}
	if ([columns count] && ![chosen containsObject:@"UPDATE"]) {
		return SPPostgresStructureRefuse(NSLocalizedString(@"Columns can only be chosen for an UPDATE trigger.", @"Postgres structure: trigger columns without UPDATE"), error);
	}

	NSString *when = [condition stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *function = qualifiedFunction ?: @"";

	return [self change:^BOOL(NSError **bodyError) {
		// The function is sent as given only when it is one the server lists (each part quoted by quote_ident)
		NSArray *functions = [self triggerFunctions:bodyError];
		if (!functions) return NO;
		if (![functions containsObject:function]) {
			return SPPostgresStructureRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a trigger function (a function returning trigger, outside pg_catalog).", @"Postgres structure: unknown trigger function"), function], bodyError);
		}
		NSMutableString *sql = [NSMutableString stringWithFormat:@"CREATE TRIGGER %@ %@ %@ ON %@ FOR EACH %@", SPPostgresQuoteIdentifier(name), theTiming,
								[clauses componentsJoinedByString:@" OR "], [self qualifiedName], theLevel];
		if ([when length]) [sql appendFormat:@" WHEN (%@)", when];
		[sql appendFormat:@" EXECUTE FUNCTION %@()", function];
		return [self run:sql error:bodyError];
	} error:error];
}

- (BOOL)dropTriggerNamed:(NSString *)name error:(NSError **)error
{
	return [self changeWith:@[[NSString stringWithFormat:@"DROP TRIGGER %@ ON %@", SPPostgresQuoteIdentifier(name ?: @""), [self qualifiedName]]] error:error];
}

- (BOOL)setTrigger:(NSString *)name enabled:(BOOL)enabled error:(NSError **)error
{
	return [self changeWith:@[[NSString stringWithFormat:@"ALTER TABLE %@ %@ TRIGGER %@", [self qualifiedName], enabled ? @"ENABLE" : @"DISABLE",
							   SPPostgresQuoteIdentifier(name ?: @"")]] error:error];
}

#pragma mark - Table

- (BOOL)renameTableTo:(NSString *)newName error:(NSError **)error
{
	if (![self checkName:newName error:error]) return NO;
	BOOL renamed = [self change:^BOOL(NSError **bodyError) {
		NSString *keyword = [self objectKeyword:bodyError];
		if (!keyword) return NO;
		return [self run:[NSString stringWithFormat:@"ALTER %@ %@ RENAME TO %@", keyword, [self qualifiedName], SPPostgresQuoteIdentifier(newName)] error:bodyError];
	} error:error];
	if (renamed) {
		NSString *table = [newName copy];
		[self willChangeValueForKey:@"table"];
		[_table release];
		_table = table;
		[self didChangeValueForKey:@"table"];
	}
	return renamed;
}

- (BOOL)setTableComment:(NSString *)comment error:(NSError **)error
{
	return [self change:^BOOL(NSError **bodyError) {
		NSString *keyword = [self objectKeyword:bodyError];
		if (!keyword) return NO;
		NSString *value = [comment length] ? SPPostgresQuoteLiteral(comment) : @"NULL";
		return [self run:[NSString stringWithFormat:@"COMMENT ON %@ %@ IS %@", keyword, [self qualifiedName], value] error:bodyError];
	} error:error];
}

@end
