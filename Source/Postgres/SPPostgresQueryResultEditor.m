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

#pragma mark - Plan reads

/*
 * The plan (EXPLAIN (VERBOSE, FORMAT JSON)) is a tree of nodes with "Plans" children, which include InitPlans and
 * SubPlans. A relation is read by a scan node with "Schema" and "Relation Name", or through a CTE: the CTE's plan is
 * a child named "CTE <name>" ("Subplan Name") somewhere in the tree, run once, and every "CTE Scan" node (or
 * "WorkTable Scan", a recursive CTE's reference to itself) with that "CTE Name" reads its output. Function, Values and
 * Table Function scans read no relation (their columns report no origin). A ModifyTable's own relation is the
 * statement's target, not a read. An extension's "Custom Scan" without "Relation Name" may stand for any number of
 * reads (Citus plans a multi-shard self-join as one), so such a plan can't be trusted.
 */

static NSString * const SPQueryEditCTEPlanPrefix = @"CTE ";

/// Plan nodes the walk visits at most (every CTE Scan expands its WITH query's plan again, so a chain of WITH queries
/// each scanning the previous one twice grows as 2^n); beyond it the walk gives up and the check fails.
static const NSUInteger SPQueryEditWalkBudget = 10000;

typedef struct {
	NSDictionary *plans;             // "CTE <name>" -> its plan node (NSNull when two CTEs share the name)
	NSMutableDictionary *relations;  // "CTE <name>" -> NSSet of the relations its plan reads
	NSUInteger visits;               // nodes visited so far (see SPQueryEditWalkBudget)
	BOOL overBudget;                 // set when visits passed SPQueryEditWalkBudget
} SPQueryEditPlanContext;

/// Counts a visit of a plan node; NO (and overBudget set) once the walk has visited more than its budget.
static BOOL SPQueryEditVisit(SPQueryEditPlanContext *context)
{
	if (++context->visits <= SPQueryEditWalkBudget) return YES;
	context->overBudget = YES;
	return NO;
}

/// Whether node is a CTE's plan (an InitPlan / SubPlan named "CTE <name>").
static BOOL SPQueryEditIsCTEPlan(NSDictionary *node)
{
	id name = [node objectForKey:@"Subplan Name"];
	return [name isKindOfClass:[NSString class]] && [name hasPrefix:SPQueryEditCTEPlanPrefix];
}

/// The CTE a CTE Scan / WorkTable Scan node reads, as its plan's name ("CTE <name>"), else nil.
static NSString *SPQueryEditCTEReadBy(NSDictionary *node)
{
	NSString *type = [node objectForKey:@"Node Type"];
	if (![type isEqual:@"CTE Scan"] && ![type isEqual:@"WorkTable Scan"]) return nil;
	id name = [node objectForKey:@"CTE Name"];
	return [name isKindOfClass:[NSString class]] ? [SPQueryEditCTEPlanPrefix stringByAppendingString:name] : nil;
}

/// The relation (@[schema, name]) node scans, or nil (no relation, or a ModifyTable's target).
static NSArray *SPQueryEditRelationOf(NSDictionary *node)
{
	id schema = [node objectForKey:@"Schema"], relation = [node objectForKey:@"Relation Name"];
	if (![schema isKindOfClass:[NSString class]] || ![relation isKindOfClass:[NSString class]]) return nil;
	return [[node objectForKey:@"Node Type"] isEqual:@"ModifyTable"] ? nil : @[schema, relation];
}

/// The children of a plan node.
static NSArray *SPQueryEditChildren(NSDictionary *node)
{
	id children = [node objectForKey:@"Plans"];
	return [children isKindOfClass:[NSArray class]] ? children : nil;
}

/// Adds every CTE plan of node's subtree to plans by name (a name used twice, CTEs of the same name in nested scopes,
/// maps to NSNull, since its scans can't be told apart). NO when the subtree has a Custom Scan without a relation.
static BOOL SPQueryEditIndexPlan(id node, NSMutableDictionary *plans)
{
	if (![node isKindOfClass:[NSDictionary class]]) return YES;
	if ([[node objectForKey:@"Node Type"] isEqual:@"Custom Scan"] && !SPQueryEditRelationOf(node)) return NO;
	if (SPQueryEditIsCTEPlan(node)) {
		NSString *name = [node objectForKey:@"Subplan Name"];
		[plans setObject:([plans objectForKey:name] ? (id)[NSNull null] : node) forKey:name];
	}
	for (id child in SPQueryEditChildren(node)) {
		if (!SPQueryEditIndexPlan(child, plans)) return NO;
	}
	return YES;
}

/**
 * Adds to relations each relation read anywhere in node's subtree, through CTEs too (stack holds the CTE plans
 * being expanded; a reference to one of them, the WorkTable Scan of a recursive CTE, adds nothing new). isRoot is
 * YES for a CTE plan being expanded; otherwise a CTE plan met in the tree is skipped, as it is read through its
 * scans. NO when a CTE Scan names a CTE whose plan isn't in the context (or is ambiguous), or the walk is over its
 * budget.
 */
static BOOL SPQueryEditCollectRelations(id node, SPQueryEditPlanContext *context, NSArray *stack, BOOL isRoot, NSMutableSet *relations)
{
	if (![node isKindOfClass:[NSDictionary class]]) return YES;
	if (!isRoot && SPQueryEditIsCTEPlan(node)) return YES;
	if (!SPQueryEditVisit(context)) return NO;

	NSString *cte = SPQueryEditCTEReadBy(node);
	if (cte) {
		id plan = [context->plans objectForKey:cte];
		if (![plan isKindOfClass:[NSDictionary class]]) return NO;
		if (![stack containsObject:cte]) {
			NSSet *known = [context->relations objectForKey:cte];
			if (!known) {
				NSMutableSet *found = [NSMutableSet set];
				if (!SPQueryEditCollectRelations(plan, context, [stack arrayByAddingObject:cte], YES, found)) return NO;
				[context->relations setObject:found forKey:cte];
				known = found;
			}
			[relations unionSet:known];
		}
	} else {
		NSArray *relation = SPQueryEditRelationOf(node);
		if (relation) [relations addObject:relation];
	}
	for (id child in SPQueryEditChildren(node)) {
		if (!SPQueryEditCollectRelations(child, context, stack, NO, relations)) return NO;
	}
	return YES;
}

/**
 * Adds to reads each read of a relation in node's subtree, as @[schema, relation, group]. group identifies the read
 * (an NSArray, equal for scans of one read):
 * - a scan's group is the topmost of the Append / Merge Append nodes directly above it (a partitioned or inheritance
 *   parent's children are one read), else the scan itself, each under prefix;
 * - a CTE Scan (or WorkTable Scan) is one separate read of every relation its CTE's plan reads: the CTE's plan is
 *   expanded again for each scan, under a prefix that includes the scan node, so each scan inside it keeps its own
 *   group (two scans of different partitions of one table inside the CTE are two reads, as outside it). A reference
 *   to a CTE being expanded (stack; the WorkTable Scan of a recursive CTE) is one more read of every relation of that
 *   CTE's plan.
 * A CTE's plan met in the tree (isRoot NO) is skipped: it is read only through its scans. NO when a CTE Scan names a
 * CTE whose plan isn't in the context (or is ambiguous), or the walk is over its budget, so the caller refuses
 * everything.
 */
static BOOL SPQueryEditCollectReads(id node, NSArray *appendGroup, NSArray *prefix, SPQueryEditPlanContext *context, NSArray *stack, BOOL isRoot, NSMutableArray *reads)
{
	if (![node isKindOfClass:[NSDictionary class]]) return YES;
	if (!isRoot && SPQueryEditIsCTEPlan(node)) return YES;
	if (!SPQueryEditVisit(context)) return NO;

	NSString *type = [node objectForKey:@"Node Type"];
	NSArray *own = [prefix arrayByAddingObject:[NSValue valueWithNonretainedObject:node]];
	NSString *cte = SPQueryEditCTEReadBy(node);
	if (cte) {
		id plan = [context->plans objectForKey:cte];
		if (![plan isKindOfClass:[NSDictionary class]]) return NO;
		if ([stack containsObject:cte]) {
			NSMutableSet *relations = [NSMutableSet set];
			if (!SPQueryEditCollectRelations(plan, context, stack, YES, relations)) return NO;
			for (NSArray *relation in relations) [reads addObject:[relation arrayByAddingObject:own]];
		} else if (!SPQueryEditCollectReads(plan, nil, own, context, [stack arrayByAddingObject:cte], YES, reads)) {
			return NO;
		}
	} else {
		NSArray *relation = SPQueryEditRelationOf(node);
		if (relation) [reads addObject:[relation arrayByAddingObject:(appendGroup ?: own)]];
	}
	BOOL append = [type isEqual:@"Append"] || [type isEqual:@"Merge Append"];
	for (id child in SPQueryEditChildren(node)) {
		if (!SPQueryEditCollectReads(child, append ? (appendGroup ?: own) : nil, prefix, context, stack, NO, reads)) return NO;
	}
	return YES;
}

/// Whether node's subtree (every node of it once: WITH queries' plans and SubPlans are in the tree) has a join whose
/// "Join Type" is Left, Right or Full: one that NULL-extends rows (Semi and Anti joins, and PostgreSQL 16's Right Anti,
/// don't).
static BOOL SPQueryEditHasOuterJoin(id node)
{
	if (![node isKindOfClass:[NSDictionary class]]) return NO;
	id type = [node objectForKey:@"Join Type"];
	if ([type isEqual:@"Left"] || [type isEqual:@"Right"] || [type isEqual:@"Full"]) return YES;
	for (id child in SPQueryEditChildren(node)) {
		if (SPQueryEditHasOuterJoin(child)) return YES;
	}
	return NO;
}

@implementation SPPostgresQueryResultEditor

@synthesize result = _result;

+ (NSArray *)readsInPlan:(id)explained error:(NSError **)error
{
	NSMutableDictionary *plans = [NSMutableDictionary dictionary];
	NSMutableArray *reads = [NSMutableArray array];
	if (![explained isKindOfClass:[NSArray class]]) return reads;
	for (id statementPlan in explained) {
		if (![statementPlan isKindOfClass:[NSDictionary class]]) continue;
		if (!SPQueryEditIndexPlan([statementPlan objectForKey:@"Plan"], plans)) {
			if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The query's plan uses an extension's scan, so its rows can't be identified.", @"Postgres query result: edit check found a Custom Scan without a relation"), nil);
			return nil;
		}
	}
	SPQueryEditPlanContext context = { plans, [NSMutableDictionary dictionary], 0, NO };
	for (id statementPlan in explained) {
		if (![statementPlan isKindOfClass:[NSDictionary class]]) continue;
		if (!SPQueryEditCollectReads([statementPlan objectForKey:@"Plan"], nil, @[], &context, @[], NO, reads)) {
			if (context.overBudget) {
				if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"This query is too complex to check which rows it shows.", @"Postgres query result: edit check gave up on a plan too large to walk"), nil);
				return nil;
			}
			if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The statement's plan reads a WITH query whose plan couldn't be found, so its rows can't be identified.", @"Postgres query result: edit check found a CTE Scan without its CTE's plan"), nil);
			return nil;
		}
	}
	return reads;
}

+ (BOOL)planHasOuterJoin:(id)explained
{
	if (![explained isKindOfClass:[NSArray class]]) return NO;
	for (id statementPlan in explained) {
		if ([statementPlan isKindOfClass:[NSDictionary class]] && SPQueryEditHasOuterJoin([statementPlan objectForKey:@"Plan"])) return YES;
	}
	return NO;
}

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
 * - the statement's plan (EXPLAIN without ANALYZE: planned, not executed, but locks are taken and immutable / stable
 *   functions may be evaluated while planning), to find the origins read more than once: those whose family's reads
 *   form more than one group (see +readsInPlan:error:), counting a read through a CTE once per scan of the CTE,
 *   and whether it has an outer join (see +planHasOuterJoin:).
 * A failure (no statement, one that can't be explained, a plan reading a CTE it doesn't contain, using an extension's
 * Custom Scan without a relation or too large to walk, an aborted transaction) is not cached, so the next check retries.
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
	NSArray *scans = [[self class] readsInPlan:explained error:error];
	if (!scans) return NO;
	BOOL outerJoin = [[self class] planHasOuterJoin:explained];

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
	_hasOuterJoin = outerJoin;
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

/**
 * Step 5, before the count: with an outer join in the plan, a row whose values of the origin table oid (every
 * identifying column, with saved edits applied) are all NULL may be a NULL-extended row, standing for no row of that
 * table, while "c" IS NULL … would identify a real one. Such a row can't be told from a real row whose shown columns
 * are all NULL, so both are refused (SPPostgresCellOuterJoinMissingRow, with the message to show).
 */
- (SPPostgresCellEditability)rowCheckOfRow:(NSUInteger)row origin:(unsigned int)oid message:(NSString **)message
{
	if (!_hasOuterJoin) return SPPostgresCellEditable;
	for (NSNumber *identifying in [self identifyingColumnsForOrigin:oid]) {
		if ([[self valueAtRow:row column:[identifying unsignedIntegerValue]] isKindOfClass:[NSString class]]) return SPPostgresCellEditable;
	}
	if (message) *message = NSLocalizedString(@"This cell may come from an outer join's missing row, so its row can't be identified.", @"Postgres query result: a NULL-extended row of an outer join");
	return SPPostgresCellOuterJoinMissingRow;
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

	// 5. Maybe an outer join's missing row
	SPPostgresCellEditability missing = [self rowCheckOfRow:row origin:oid message:message];
	if (missing != SPPostgresCellEditable) return missing;

	// 6. Count the rows the identifying values match
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
	if ([self rowCheckOfRow:row origin:oid message:&message] != SPPostgresCellEditable) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorNotEditable, message, nil);
		return nil;
	}
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
