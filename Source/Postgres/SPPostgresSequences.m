#import "SPPostgresSequences.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTableDuplicator.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

#pragma mark - Helpers

/// Fails with message (SPPostgresErrorQueryFailed) for something refused before it is sent.
static BOOL SPPostgresSequenceRefuse(NSString *message, NSError **error)
{
	if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil);
	return NO;
}

/// The value as an NSString, or nil for NULL.
static NSString *SPPostgresSequenceText(id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// A bigint's text as an NSNumber (long long), nil for NULL.
static NSNumber *SPPostgresSequenceNumber(id value)
{
	NSString *text = SPPostgresSequenceText(value);
	return text ? [NSNumber numberWithLongLong:[text longLongValue]] : nil;
}

/// The number as SQL text, from its long long value (never from typed text).
static NSString *SPPostgresSequenceSQLNumber(NSNumber *number)
{
	return [NSString stringWithFormat:@"%lld", [number longLongValue]];
}

/// Every row of the query as arrays of NSString / NSNull (the query selects text), or nil on failure.
static NSArray *SPPostgresSequenceRows(PGPostgresConnection *connection, NSString *sql, NSArray *values, NSError **error)
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

/// The first column of every row, as strings.
static NSArray *SPPostgresSequenceFirstColumn(NSArray *rows)
{
	NSMutableArray *values = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *text = SPPostgresSequenceText([row firstObject]);
		if (text) [values addObject:text];
	}
	return values;
}

static BOOL SPPostgresSequenceSame(id a, id b)
{
	return a == b || [a isEqual:b];
}

/// nil for an empty string.
static NSString *SPPostgresSequenceNonEmpty(NSString *text)
{
	return [text length] ? text : nil;
}

/// The integer types a sequence can have, with their bounds.
static NSDictionary *SPPostgresSequenceTypeBounds(void)
{
	return @{@"smallint": @[@(INT16_MIN), @(INT16_MAX)],
			 @"integer": @[@(INT32_MIN), @(INT32_MAX)],
			 @"bigint": @[@(LLONG_MIN), @(LLONG_MAX)]};
}

/// The sequence ($1 schema, $2 name) as a CTE `seq` (oid); no row when there is none.
static NSString * const SPPostgresSequenceCTE =
	@"WITH seq AS (SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
	"WHERE n.nspname = $1::text AND c.relname = $2::text AND c.relkind = 'S') ";

#pragma mark - SPPostgresSequence

@interface SPPostgresSequence ()
@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *name;
@property (readwrite, copy) NSString *dataType;
@property (readwrite, copy) NSNumber *start;
@property (readwrite, copy) NSNumber *increment;
@property (readwrite, copy) NSNumber *minValue;
@property (readwrite, copy) NSNumber *maxValue;
@property (readwrite, copy) NSNumber *cache;
@property (readwrite) BOOL cycle;
@property (readwrite, copy) NSNumber *lastValue;
@property (readwrite, copy) NSNumber *pendingValue;
@property (readwrite) BOOL isCalled;
@property (readwrite, copy) NSString *ownedBy;
@property (readwrite) BOOL isIdentity;
@property (readwrite, copy) NSString *identityColumn;
@property (readwrite, copy) NSString *owner;
@property (readwrite, copy) NSString *comment;
/// The identity column's parts, for ALTER TABLE "schema"."table" ALTER COLUMN "column"
@property (readwrite, copy) NSArray *identityParts;
@end

@implementation SPPostgresSequence
{
	NSArray *_identityParts;
}

@synthesize schema = _schema, name = _name, dataType = _dataType, start = _start, increment = _increment, minValue = _minValue;
@synthesize maxValue = _maxValue, cache = _cache, cycle = _cycle, lastValue = _lastValue, pendingValue = _pendingValue, isCalled = _isCalled, ownedBy = _ownedBy;
@synthesize isIdentity = _isIdentity, identityColumn = _identityColumn, owner = _owner, comment = _comment, identityParts = _identityParts;

- (void)dealloc
{
	[_schema release];
	[_name release];
	[_dataType release];
	[_start release];
	[_increment release];
	[_minValue release];
	[_maxValue release];
	[_cache release];
	[_lastValue release];
	[_pendingValue release];
	[_ownedBy release];
	[_identityColumn release];
	[_owner release];
	[_comment release];
	[_identityParts release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@.%@ %@ start %@ increment %@ min %@ max %@ cache %@%@>", [self class], _schema, _name, _dataType,
			_start, _increment, _minValue, _maxValue, _cache, _cycle ? @" cycle" : @""];
}

@end

#pragma mark - SPPostgresSequenceDefinition

@implementation SPPostgresSequenceDefinition

@synthesize name = _name, dataType = _dataType, start = _start, increment = _increment, minValue = _minValue, maxValue = _maxValue;
@synthesize cache = _cache, cycle = _cycle, ownedBy = _ownedBy, comment = _comment;

+ (instancetype)definitionWithSequence:(SPPostgresSequence *)sequence
{
	SPPostgresSequenceDefinition *definition = [[[self alloc] init] autorelease];
	[definition setName:[sequence name]];
	[definition setDataType:[sequence dataType]];
	[definition setStart:[sequence start]];
	[definition setIncrement:[sequence increment]];
	[definition setMinValue:[sequence minValue]];
	[definition setMaxValue:[sequence maxValue]];
	[definition setCache:[sequence cache]];
	[definition setCycle:[sequence cycle]];
	[definition setOwnedBy:[sequence ownedBy]];
	[definition setComment:[sequence comment]];
	return definition;
}

- (void)dealloc
{
	[_name release];
	[_dataType release];
	[_start release];
	[_increment release];
	[_minValue release];
	[_maxValue release];
	[_cache release];
	[_ownedBy release];
	[_comment release];
	[super dealloc];
}

@end

#pragma mark - SPPostgresSequences

@implementation SPPostgresSequences

@synthesize schema = _schema;
@synthesize lockTimeout = _lockTimeout;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema
{
	if ((self = [super init])) {
		_connection = [connection retain];
		_schema = [schema copy];
		_lockTimeout = 5;
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[_schema release];
	[super dealloc];
}

#pragma mark Helpers

/// "schema"."name"
- (NSString *)qualified:(NSString *)name
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(_schema ?: @""), SPPostgresQuoteIdentifier(name ?: @"")];
}

- (BOOL)noSuchSequence:(NSString *)name error:(NSError **)error
{
	return SPPostgresSequenceRefuse([NSString stringWithFormat:NSLocalizedString(@"There is no sequence “%@” in schema “%@”.", @"Postgres sequences: no such sequence"), name, _schema], error);
}

- (BOOL)run:(NSString *)sql error:(NSError **)error
{
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

/// NO (with an error) for a name PostgreSQL wouldn't keep as given: empty, or over 63 bytes.
- (BOOL)checkName:(NSString *)name error:(NSError **)error
{
	if (![name length]) {
		return SPPostgresSequenceRefuse(NSLocalizedString(@"The name must not be empty.", @"Postgres structure: empty name"), error);
	}
	if (![SPPostgresTableDuplicator isValidTableName:name]) {
		return SPPostgresSequenceRefuse([NSString stringWithFormat:NSLocalizedString(@"The name “%@” is too long: PostgreSQL names can be at most 63 bytes.", @"Postgres structure: name too long"), name], error);
	}
	return YES;
}

/// NO (with an error) for a type that isn't smallint, integer or bigint (nil is fine: the default).
- (BOOL)checkType:(NSString *)type error:(NSError **)error
{
	if (!type || [SPPostgresSequenceTypeBounds() objectForKey:type]) return YES;
	return SPPostgresSequenceRefuse([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a sequence type: choose smallint, integer or bigint.", @"Postgres sequences: bad type"), type], error);
}

/// NO (with an error) when a number isn't an NSNumber.
- (BOOL)checkNumbers:(NSArray *)numbers error:(NSError **)error
{
	for (id number in numbers) {
		if (number != [NSNull null] && ![number isKindOfClass:[NSNumber class]]) {
			return SPPostgresSequenceRefuse(NSLocalizedString(@"The sequence's values must be whole numbers.", @"Postgres sequences: not a number"), error);
		}
	}
	return YES;
}

/// "schema"."table"."column" for an @"schema.table.column" OWNED BY names (looked up on the server, so names with
/// dots work), or nil (with an error) when it names no column, or more than one.
- (NSString *)quotedColumn:(NSString *)dotted error:(NSError **)error
{
	NSArray *rows = SPPostgresSequenceRows(_connection,
		@"SELECT n.nspname::text, c.relname::text, a.attname::text FROM pg_catalog.pg_attribute a "
		"JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
		"WHERE c.relkind IN ('r', 'p', 'f') AND a.attnum > 0 AND NOT a.attisdropped "
		"AND n.nspname || '.' || c.relname || '.' || a.attname = $1::text", @[dotted ?: @""], error);
	if (!rows) return nil;
	if ([rows count] != 1) {
		NSString *message = [rows count] ? NSLocalizedString(@"“%@” names more than one column.", @"Postgres sequences: OWNED BY ambiguous")
										 : NSLocalizedString(@"There is no column “%@”.", @"Postgres sequences: OWNED BY no such column");
		SPPostgresSequenceRefuse([NSString stringWithFormat:message, dotted], error);
		return nil;
	}
	NSArray *row = rows[0];
	return [NSString stringWithFormat:@"%@.%@.%@", SPPostgresQuoteIdentifier(row[0]), SPPostgresQuoteIdentifier(row[1]), SPPostgresQuoteIdentifier(row[2])];
}

#pragma mark Reading

- (SPPostgresSequence *)sequenceNamed:(NSString *)name error:(NSError **)error
{
	NSArray *rows = SPPostgresSequenceRows(_connection, [SPPostgresSequenceCTE stringByAppendingString:
		@"SELECT pg_catalog.format_type(s.seqtypid, NULL)::text, s.seqstart::text, s.seqincrement::text, s.seqmin::text, s.seqmax::text,"
		" s.seqcache::text, s.seqcycle::text, pg_catalog.pg_get_userbyid(c.relowner)::text, pg_catalog.obj_description(c.oid, 'pg_class')::text,"
		" pg_catalog.has_sequence_privilege(c.oid, 'SELECT')::text,"
		" (SELECT tn.nspname || '.' || t.relname || '.' || a.attname FROM pg_catalog.pg_depend d"
		"   JOIN pg_catalog.pg_class t ON t.oid = d.refobjid JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace"
		"   JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid"
		"   WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.deptype = 'a' LIMIT 1)::text,"
		" i.nspname::text, i.relname::text, i.attname::text"
		" FROM seq JOIN pg_catalog.pg_class c ON c.oid = seq.oid JOIN pg_catalog.pg_sequence s ON s.seqrelid = c.oid"
		" LEFT JOIN LATERAL (SELECT tn.nspname, t.relname, a.attname FROM pg_catalog.pg_depend d"
		"   JOIN pg_catalog.pg_class t ON t.oid = d.refobjid JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace"
		"   JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid"
		"   WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.deptype = 'i' LIMIT 1) i ON true"]
		, @[_schema ?: @"", name ?: @""], error);
	if (!rows) return nil;
	if (![rows count]) {
		[self noSuchSequence:name error:error];
		return nil;
	}

	NSArray *row = rows[0];
	SPPostgresSequence *sequence = [[[SPPostgresSequence alloc] init] autorelease];
	[sequence setSchema:_schema];
	[sequence setName:name];
	[sequence setDataType:SPPostgresSequenceText(row[0])];
	[sequence setStart:SPPostgresSequenceNumber(row[1])];
	[sequence setIncrement:SPPostgresSequenceNumber(row[2])];
	[sequence setMinValue:SPPostgresSequenceNumber(row[3])];
	[sequence setMaxValue:SPPostgresSequenceNumber(row[4])];
	[sequence setCache:SPPostgresSequenceNumber(row[5])];
	[sequence setCycle:[SPPostgresSequenceText(row[6]) isEqualToString:@"true"]];
	[sequence setOwner:SPPostgresSequenceText(row[7])];
	[sequence setComment:SPPostgresSequenceText(row[8])];
	[sequence setOwnedBy:SPPostgresSequenceText(row[10])];

	NSString *identitySchema = SPPostgresSequenceText(row[11]);
	if (identitySchema) {
		NSArray *parts = @[identitySchema, SPPostgresSequenceText(row[12]) ?: @"", SPPostgresSequenceText(row[13]) ?: @""];
		[sequence setIsIdentity:YES];
		[sequence setIdentityParts:parts];
		[sequence setIdentityColumn:[parts componentsJoinedByString:@"."]];
	}

	// Its state needs SELECT on it (reading it without would fail, aborting the user's transaction)
	if ([SPPostgresSequenceText(row[9]) isEqualToString:@"true"]) {
		NSString *sql = [NSString stringWithFormat:@"SELECT last_value::text, is_called::text FROM %@", [self qualified:name]];
		NSArray *state = SPPostgresSequenceRows(_connection, sql, nil, error);
		if (!state) return nil;
		if ([state count]) {
			BOOL called = [SPPostgresSequenceText(state[0][1]) isEqualToString:@"true"];
			[sequence setIsCalled:called];
			if (called) [sequence setLastValue:SPPostgresSequenceNumber(state[0][0])];
			else [sequence setPendingValue:SPPostgresSequenceNumber(state[0][0])];
		}
	}
	return sequence;
}

- (NSArray *)ownerColumnCandidates:(NSError **)error
{
	NSArray *rows = SPPostgresSequenceRows(_connection,
		@"SELECT (n.nspname || '.' || c.relname || '.' || a.attname)::text FROM pg_catalog.pg_attribute a "
		"JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
		"WHERE n.nspname = $1::text AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped "
		"AND a.atttypid IN ('pg_catalog.int2'::regtype, 'pg_catalog.int4'::regtype, 'pg_catalog.int8'::regtype) "
		"ORDER BY (n.nspname || '.' || c.relname || '.' || a.attname) COLLATE \"C\"", @[_schema ?: @""], error);
	if (!rows) return nil;
	return SPPostgresSequenceFirstColumn(rows);
}

- (NSArray *)columnsUsingSequence:(NSString *)name error:(NSError **)error
{
	NSArray *rows = SPPostgresSequenceRows(_connection, [SPPostgresSequenceCTE stringByAppendingString:
		@"SELECT u.n::text FROM ("
		"  SELECT tn.nspname || '.' || t.relname || '.' || a.attname AS n FROM seq"
		"  JOIN pg_catalog.pg_depend d ON d.refclassid = 'pg_catalog.pg_class'::regclass AND d.refobjid = seq.oid AND d.classid = 'pg_catalog.pg_attrdef'::regclass"
		"  JOIN pg_catalog.pg_attrdef ad ON ad.oid = d.objid"
		"  JOIN pg_catalog.pg_class t ON t.oid = ad.adrelid JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace"
		"  JOIN pg_catalog.pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum"
		"  UNION"
		"  SELECT tn.nspname || '.' || t.relname || '.' || a.attname FROM seq"
		"  JOIN pg_catalog.pg_depend d ON d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = seq.oid AND d.deptype = 'i' AND d.refclassid = 'pg_catalog.pg_class'::regclass"
		"  JOIN pg_catalog.pg_class t ON t.oid = d.refobjid JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace"
		"  JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid"
		" ) u ORDER BY u.n COLLATE \"C\""], @[_schema ?: @"", name ?: @""], error);
	if (!rows) return nil;

	if (![rows count]) {
		// None, or no such sequence
		NSArray *exists = SPPostgresSequenceRows(_connection, [SPPostgresSequenceCTE stringByAppendingString:@"SELECT 1::text FROM seq"], @[_schema ?: @"", name ?: @""], error);
		if (!exists) return nil;
		if (![exists count]) {
			[self noSuchSequence:name error:error];
			return nil;
		}
	}
	return SPPostgresSequenceFirstColumn(rows);
}

#pragma mark Changes

- (BOOL)createSequence:(SPPostgresSequenceDefinition *)definition error:(NSError **)error
{
	NSString *name = [definition name];
	if (![self checkName:name error:error] || ![self checkType:[definition dataType] error:error]) return NO;
	if (![self checkNumbers:@[[definition increment] ?: [NSNull null], [definition minValue] ?: [NSNull null], [definition maxValue] ?: [NSNull null],
							  [definition start] ?: [NSNull null], [definition cache] ?: [NSNull null]] error:error]) return NO;

	NSMutableString *sql = [NSMutableString stringWithFormat:@"CREATE SEQUENCE %@", [self qualified:name]];
	if ([definition dataType]) [sql appendFormat:@" AS %@", [definition dataType]];
	if ([definition increment]) [sql appendFormat:@" INCREMENT BY %@", SPPostgresSequenceSQLNumber([definition increment])];
	if ([definition minValue]) [sql appendFormat:@" MINVALUE %@", SPPostgresSequenceSQLNumber([definition minValue])];
	if ([definition maxValue]) [sql appendFormat:@" MAXVALUE %@", SPPostgresSequenceSQLNumber([definition maxValue])];
	if ([definition start]) [sql appendFormat:@" START WITH %@", SPPostgresSequenceSQLNumber([definition start])];
	if ([definition cache]) [sql appendFormat:@" CACHE %@", SPPostgresSequenceSQLNumber([definition cache])];
	[sql appendString:[definition cycle] ? @" CYCLE" : @" NO CYCLE"];
	NSString *ownedBy = SPPostgresSequenceNonEmpty([definition ownedBy]);
	NSString *comment = SPPostgresSequenceNonEmpty([definition comment]);

	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		NSString *statement = sql;
		if (ownedBy) {
			NSString *column = [self quotedColumn:ownedBy error:bodyError];
			if (!column) return NO;
			statement = [sql stringByAppendingFormat:@" OWNED BY %@", column];
		}
		if (![self run:statement error:bodyError]) return NO;
		if (comment && ![self run:[NSString stringWithFormat:@"COMMENT ON SEQUENCE %@ IS %@", [self qualified:name], SPPostgresQuoteLiteral(comment)] error:bodyError]) return NO;
		return YES;
	}, error);
}

- (BOOL)alterSequence:(NSString *)name to:(SPPostgresSequenceDefinition *)definition error:(NSError **)error
{
	// Refused before anything is sent
	NSString *newName = [definition name] ?: name;
	if (![self checkName:newName error:error] || ![self checkType:[definition dataType] error:error]) return NO;
	if (![self checkNumbers:@[[definition increment] ?: [NSNull null], [definition minValue] ?: [NSNull null], [definition maxValue] ?: [NSNull null],
							  [definition start] ?: [NSNull null], [definition cache] ?: [NSNull null]] error:error]) return NO;

	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		// What the server has now, in this transaction
		SPPostgresSequence *current = [self sequenceNamed:name error:bodyError];
		if (!current) return NO;

		NSString *type = [definition dataType] ?: [current dataType];
		NSNumber *increment = [definition increment] ?: [current increment];
		BOOL ascending = [increment longLongValue] > 0;
		NSArray *bounds = [SPPostgresSequenceTypeBounds() objectForKey:type] ?: [SPPostgresSequenceTypeBounds() objectForKey:@"bigint"];
		NSNumber *defaultMin = ascending ? @1 : bounds[0];
		NSNumber *defaultMax = ascending ? bounds[1] : @-1;

		// The options that differ, in the order ALTER SEQUENCE documents them (each one clause)
		NSMutableArray *options = [NSMutableArray array];
		BOOL typeChanged = !SPPostgresSequenceSame(type, [current dataType]);
		if (typeChanged) [options addObject:[NSString stringWithFormat:@"AS %@", type]];
		if ([definition increment] && !SPPostgresSequenceSame([definition increment], [current increment])) {
			[options addObject:[NSString stringWithFormat:@"INCREMENT BY %@", SPPostgresSequenceSQLNumber([definition increment])]];
		}
		if ([definition minValue]) {
			if (!SPPostgresSequenceSame([definition minValue], [current minValue])) [options addObject:[NSString stringWithFormat:@"MINVALUE %@", SPPostgresSequenceSQLNumber([definition minValue])]];
		}
		else if (!SPPostgresSequenceSame([current minValue], defaultMin)) [options addObject:@"NO MINVALUE"];
		if ([definition maxValue]) {
			if (!SPPostgresSequenceSame([definition maxValue], [current maxValue])) [options addObject:[NSString stringWithFormat:@"MAXVALUE %@", SPPostgresSequenceSQLNumber([definition maxValue])]];
		}
		else if (!SPPostgresSequenceSame([current maxValue], defaultMax)) [options addObject:@"NO MAXVALUE"];
		if ([definition start] && !SPPostgresSequenceSame([definition start], [current start])) {
			[options addObject:[NSString stringWithFormat:@"START WITH %@", SPPostgresSequenceSQLNumber([definition start])]];
		}
		if ([definition cache] && !SPPostgresSequenceSame([definition cache], [current cache])) {
			[options addObject:[NSString stringWithFormat:@"CACHE %@", SPPostgresSequenceSQLNumber([definition cache])]];
		}
		if ([definition cycle] != [current cycle]) [options addObject:[definition cycle] ? @"CYCLE" : @"NO CYCLE"];

		NSString *ownedBy = SPPostgresSequenceNonEmpty([definition ownedBy]);
		BOOL ownedByChanged = !SPPostgresSequenceSame(ownedBy, SPPostgresSequenceNonEmpty([current ownedBy]));
		BOOL renamed = ![newName isEqualToString:name];
		NSString *comment = [definition comment] ?: @"";
		BOOL commentChanged = ![comment isEqualToString:[current comment] ?: @""];

		NSMutableArray *statements = [NSMutableArray array];
		if ([current isIdentity]) {
			// Its options go through the column; its name, owner and type are the column's
			NSArray *parts = [current identityParts];
			if (renamed || ownedByChanged) {
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"This sequence belongs to identity column %@.%@; rename or detach it from the column.", @"Postgres sequences: identity sequence rename or OWNED BY refused (table.column)"), parts[1], parts[2]];
				return SPPostgresSequenceRefuse(message, bodyError);
			}
			if (typeChanged) {
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"This sequence belongs to identity column %@.%@; its type is the column's type.", @"Postgres sequences: identity sequence type change refused (table.column)"), parts[1], parts[2]];
				return SPPostgresSequenceRefuse(message, bodyError);
			}
			if ([options count]) {
				NSMutableArray *sets = [NSMutableArray arrayWithCapacity:[options count]];
				for (NSString *option in options) [sets addObject:[@"SET " stringByAppendingString:option]];
				[statements addObject:[NSString stringWithFormat:@"ALTER TABLE %@.%@ ALTER COLUMN %@ %@", SPPostgresQuoteIdentifier(parts[0]), SPPostgresQuoteIdentifier(parts[1]),
									   SPPostgresQuoteIdentifier(parts[2]), [sets componentsJoinedByString:@" "]]];
			}
		}
		else {
			if (ownedByChanged) {
				if (ownedBy) {
					NSString *column = [self quotedColumn:ownedBy error:bodyError];
					if (!column) return NO;
					[options addObject:[@"OWNED BY " stringByAppendingString:column]];
				}
				else [options addObject:@"OWNED BY NONE"];
			}
			if ([options count]) [statements addObject:[NSString stringWithFormat:@"ALTER SEQUENCE %@ %@", [self qualified:name], [options componentsJoinedByString:@" "]]];
			if (renamed) [statements addObject:[NSString stringWithFormat:@"ALTER SEQUENCE %@ RENAME TO %@", [self qualified:name], SPPostgresQuoteIdentifier(newName)]];
		}

		if (commentChanged) {
			NSString *value = [comment length] ? SPPostgresQuoteLiteral(comment) : @"NULL";
			[statements addObject:[NSString stringWithFormat:@"COMMENT ON SEQUENCE %@ IS %@", [self qualified:newName], value]];
		}

		for (NSString *sql in statements) {
			if (![self run:sql error:bodyError]) return NO;
		}
		return YES;
	}, error);
}

- (BOOL)setValue:(NSNumber *)value isCalled:(BOOL)isCalled ofSequence:(NSString *)name error:(NSError **)error
{
	if (![value isKindOfClass:[NSNumber class]]) {
		return SPPostgresSequenceRefuse(NSLocalizedString(@"Enter the value to set.", @"Postgres sequences: setval without a value"), error);
	}
	NSArray *values = @[[self qualified:name], SPPostgresSequenceSQLNumber(value), isCalled ? @"true" : @"false"];
	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		return SPPostgresExecuteWithDetails(_connection, @"SELECT pg_catalog.setval($1::text::regclass, $2::bigint, $3::boolean)", values, bodyError) != nil;
	}, error);
}

- (BOOL)dropSequence:(NSString *)name error:(NSError **)error
{
	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		// PostgreSQL itself refuses (without CASCADE) when a default uses it: checked first to name the columns
		NSArray *columns = [self columnsUsingSequence:name error:bodyError];
		if (!columns) return NO;
		if ([columns count]) {
			if (bodyError) {
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"\"%@\" can't be deleted because these columns use it.", @"Postgres sequences: sequence in use"), name];
				*bodyError = SPPostgresMakeError(SPPostgresErrorHasDependents, message, @{SPPostgresDependentsErrorKey: columns});
			}
			return NO;
		}
		return [self run:[NSString stringWithFormat:@"DROP SEQUENCE %@", [self qualified:name]] error:bodyError];
	}, error);
}

@end
