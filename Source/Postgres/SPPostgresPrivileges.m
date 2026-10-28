#import "SPPostgresPrivileges.h"
#import "SPPostgresRoles.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

#pragma mark - Helpers

static NSString * const SPPostgresPrivilegeKindDatabase = @"database";
static NSString * const SPPostgresPrivilegeKindSchema = @"schema";
static NSString * const SPPostgresPrivilegeKindTable = @"table";
static NSString * const SPPostgresPrivilegeKindView = @"view";
static NSString * const SPPostgresPrivilegeKindMaterializedView = @"materialized view";
static NSString * const SPPostgresPrivilegeKindForeignTable = @"foreign table";
static NSString * const SPPostgresPrivilegeKindSequence = @"sequence";
static NSString * const SPPostgresPrivilegeKindFunction = @"function";
static NSString * const SPPostgresPrivilegeKindDefaultTables = @"default tables";
static NSString * const SPPostgresPrivilegeKindDefaultSequences = @"default sequences";
static NSString * const SPPostgresPrivilegeKindDefaultFunctions = @"default functions";

/// The value as an NSString, or nil for NULL.
static NSString *SPPostgresPrivilegesText(id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Every row of the query (which selects text) as arrays of NSString / NSNull, or nil on failure.
static NSArray *SPPostgresPrivilegesRows(PGPostgresConnection *connection, NSString *sql, NSArray *values, NSError **error)
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

/// A comma-separated privilege_type list (string_agg of aclexplode) as a set; TEMPORARY is spelt TEMP.
static NSSet *SPPostgresPrivilegesSet(id value)
{
	NSString *text = SPPostgresPrivilegesText(value);
	if (![text length]) return [NSSet set];
	NSMutableSet *set = [NSMutableSet set];
	for (NSString *privilege in [text componentsSeparatedByString:@","]) {
		[set addObject:[privilege isEqualToString:@"TEMPORARY"] ? @"TEMP" : privilege];
	}
	return set;
}

static id SPPostgresPrivilegesFail(NSString *message, NSError **error)
{
	if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil);
	return nil;
}

/// The SQL for the privileges role holds directly in acl (an aclitem[] expression), as a comma-separated list;
/// grantableOnly limits it to those WITH GRANT OPTION. roleOid is an SQL expression for the role's oid (NULL for
/// a role that doesn't exist, which matches nothing).
static NSString *SPPostgresPrivilegesAggregate(NSString *acl, NSString *roleOid, BOOL grantableOnly)
{
	return [NSString stringWithFormat:@"(SELECT string_agg(a.privilege_type, ',') FROM pg_catalog.aclexplode(%@) a WHERE a.grantee = %@%@)",
			acl, roleOid, grantableOnly ? @" AND a.is_grantable" : @""];
}

#pragma mark - SPPostgresPrivilegeObject

@interface SPPostgresPrivilegeObject ()
- (NSArray *)matchKey;
- (NSString *)functionName;
@end

@implementation SPPostgresPrivilegeObject

@synthesize kind = _kind, schema = _schema, name = _name, signature = _signature, availablePrivileges = _availablePrivileges;
@synthesize granted = _granted, grantable = _grantable;

+ (NSArray *)availablePrivilegesForKind:(NSString *)kind
{
	static NSDictionary *privilegesByKind = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSArray *table = @[@"SELECT", @"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE", @"REFERENCES", @"TRIGGER"];
		NSArray *sequence = @[@"USAGE", @"SELECT"];
		NSArray *function = @[@"EXECUTE"];
		privilegesByKind = [@{
			SPPostgresPrivilegeKindDatabase: @[@"CONNECT", @"CREATE", @"TEMP"],
			SPPostgresPrivilegeKindSchema: @[@"USAGE", @"CREATE"],
			SPPostgresPrivilegeKindTable: table,
			SPPostgresPrivilegeKindView: table,
			SPPostgresPrivilegeKindMaterializedView: table,
			SPPostgresPrivilegeKindForeignTable: table,
			SPPostgresPrivilegeKindSequence: sequence,
			SPPostgresPrivilegeKindFunction: function,
			SPPostgresPrivilegeKindDefaultTables: table,
			SPPostgresPrivilegeKindDefaultSequences: sequence,
			SPPostgresPrivilegeKindDefaultFunctions: function,
		} retain];
	});
	return [privilegesByKind objectForKey:kind] ?: @[];
}

- (instancetype)initWithKind:(NSString *)kind schema:(NSString *)schema name:(NSString *)name signature:(NSString *)signature
					 granted:(NSSet *)granted grantable:(NSSet *)grantable
{
	if ((self = [super init])) {
		_kind = [kind copy];
		_schema = [schema copy];
		_name = [name copy];
		_signature = [signature copy];
		_availablePrivileges = [[[self class] availablePrivilegesForKind:kind] copy];
		NSSet *available = [NSSet setWithArray:_availablePrivileges];
		NSMutableSet *held = [NSMutableSet setWithSet:granted ?: [NSSet set]];
		[held intersectSet:available];
		_granted = [held copy];
		NSMutableSet *withGrantOption = [NSMutableSet setWithSet:grantable ?: [NSSet set]];
		[withGrantOption intersectSet:available];
		_grantable = [withGrantOption copy];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	return [[[self class] allocWithZone:zone] initWithKind:_kind schema:_schema name:_name signature:_signature granted:_granted grantable:_grantable];
}

- (void)dealloc
{
	[_kind release];
	[_schema release];
	[_name release];
	[_signature release];
	[_availablePrivileges release];
	[_granted release];
	[_grantable release];
	[super dealloc];
}

/// What identifies the object across a read and its draft.
- (NSArray *)matchKey
{
	return [NSArray arrayWithObjects:_kind ?: @"", _schema ?: @"", _name ?: @"", nil];
}

/// A function's own name: name without its "(<signature>)" suffix.
- (NSString *)functionName
{
	NSString *suffix = [NSString stringWithFormat:@"(%@)", _signature ?: @""];
	return [_name hasSuffix:suffix] ? [_name substringToIndex:[_name length] - [suffix length]] : _name;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@.%@ granted %@ grantable %@>", [self class], _kind, _schema, _name,
			[[_granted allObjects] componentsJoinedByString:@","], [[_grantable allObjects] componentsJoinedByString:@","]];
}

@end

#pragma mark - SPPostgresPrivileges

@implementation SPPostgresPrivileges

- (instancetype)initWithConnection:(PGPostgresConnection *)connection
{
	if ((self = [super init])) {
		_connection = [connection retain];
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[super dealloc];
}

#pragma mark Reading

- (NSArray *)databasePrivilegesForRole:(NSString *)role database:(NSString *)database error:(NSError **)error
{
	NSString *acl = @"coalesce(d.datacl, pg_catalog.acldefault('d', d.datdba))";
	NSString *roleOid = @"(SELECT oid FROM pg_catalog.pg_roles WHERE rolname = $1)";
	NSString *sql = [NSString stringWithFormat:@"SELECT d.datname::text, %@, %@ FROM pg_catalog.pg_database d WHERE d.datname = $2",
					 SPPostgresPrivilegesAggregate(acl, roleOid, NO), SPPostgresPrivilegesAggregate(acl, roleOid, YES)];
	NSArray *rows = SPPostgresPrivilegesRows(_connection, sql, @[role ?: @"", database ?: @""], error);
	if (!rows) return nil;
	if (![rows count]) {
		return SPPostgresPrivilegesFail([NSString stringWithFormat:NSLocalizedString(@"The database “%@” doesn’t exist.", @"Postgres privileges: no such database"), database], error);
	}

	NSArray *row = [rows firstObject];
	SPPostgresPrivilegeObject *object = [[[SPPostgresPrivilegeObject alloc] initWithKind:SPPostgresPrivilegeKindDatabase schema:nil
		name:SPPostgresPrivilegesText([row objectAtIndex:0]) signature:nil
		granted:SPPostgresPrivilegesSet([row objectAtIndex:1]) grantable:SPPostgresPrivilegesSet([row objectAtIndex:2])] autorelease];
	return @[object];
}

- (NSArray *)privilegesForRole:(NSString *)role schema:(NSString *)schema defaultsCreator:(NSString *)creator error:(NSError **)error
{
	// $1 role, $2 schema, $3 creator (NULL when none). Columns: kind, schema, name, signature, granted, grantable.
	NSString *roleOid = @"(SELECT oid FROM pg_catalog.pg_roles WHERE rolname = $1)";

	NSString *schemaACL = @"coalesce(n.nspacl, pg_catalog.acldefault('n', n.nspowner))";
	NSString *schemaSQL = [NSString stringWithFormat:
		@"SELECT 0 AS rank, 'schema' AS kind, n.nspname::text AS name, NULL::text AS signature, %@ AS granted, %@ AS grantable "
		"FROM pg_catalog.pg_namespace n WHERE n.nspname = $2",
		SPPostgresPrivilegesAggregate(schemaACL, roleOid, NO), SPPostgresPrivilegesAggregate(schemaACL, roleOid, YES)];

	// Sequences use the 's' default; every other relation 'r'.
	NSString *relationACL = @"coalesce(c.relacl, pg_catalog.acldefault(CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END::\"char\", c.relowner))";
	NSString *relationSQL = [NSString stringWithFormat:
		@"SELECT CASE c.relkind WHEN 'r' THEN 1 WHEN 'p' THEN 1 WHEN 'v' THEN 2 WHEN 'm' THEN 3 WHEN 'f' THEN 4 ELSE 5 END, "
		"CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' "
		"WHEN 'f' THEN 'foreign table' ELSE 'sequence' END, c.relname::text, NULL::text, %@, %@ "
		"FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
		"WHERE n.nspname = $2 AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')",
		SPPostgresPrivilegesAggregate(relationACL, roleOid, NO), SPPostgresPrivilegesAggregate(relationACL, roleOid, YES)];

	// Functions and procedures (prokind, PostgreSQL 11+); aggregates and window functions are left out.
	NSString *functionACL = @"coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))";
	NSString *functionSQL = [NSString stringWithFormat:
		@"SELECT 6, 'function', p.proname::text, pg_catalog.pg_get_function_identity_arguments(p.oid)::text, %@, %@ "
		"FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace "
		"WHERE n.nspname = $2 AND p.prokind IN ('f', 'p')",
		SPPostgresPrivilegesAggregate(functionACL, roleOid, NO), SPPostgresPrivilegesAggregate(functionACL, roleOid, YES)];

	// Default privileges: pg_default_acl only (no acldefault fallback), for objects creator makes in the schema.
	NSString *defaultACL = @"(SELECT d.defaclacl FROM pg_catalog.pg_default_acl d "
		"WHERE d.defaclrole = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = $3) AND d.defaclnamespace = n.oid AND d.defaclobjtype = t.objtype)";
	NSString *defaultSQL = [NSString stringWithFormat:
		@"SELECT 7 + t.ord, t.kind, t.label, NULL::text, %@, %@ "
		"FROM pg_catalog.pg_namespace n, (VALUES (0, 'default tables', 'r'::\"char\", '1'), (1, 'default sequences', 'S'::\"char\", '2'), "
		"(2, 'default functions', 'f'::\"char\", '3')) AS t(ord, kind, objtype, label) WHERE n.nspname = $2",
		SPPostgresPrivilegesAggregate(defaultACL, roleOid, NO), SPPostgresPrivilegesAggregate(defaultACL, roleOid, YES)];

	NSString *sql = [NSString stringWithFormat:@"SELECT kind, name, signature, granted, grantable FROM (%@ UNION ALL %@ UNION ALL %@ UNION ALL %@) o "
					 "ORDER BY rank, name, signature", schemaSQL, relationSQL, functionSQL, defaultSQL];
	NSArray *rows = SPPostgresPrivilegesRows(_connection, sql, @[role ?: @"", schema ?: @"", creator ?: [NSNull null]], error);
	if (!rows) return nil;
	if (![rows count]) {
		return SPPostgresPrivilegesFail([NSString stringWithFormat:NSLocalizedString(@"The schema “%@” doesn’t exist.", @"Postgres privileges: no such schema"), schema], error);
	}

	NSDictionary *defaultLabels = @{
		SPPostgresPrivilegeKindDefaultTables: NSLocalizedString(@"Tables created later", @"Postgres privileges: default privileges row for tables"),
		SPPostgresPrivilegeKindDefaultSequences: NSLocalizedString(@"Sequences created later", @"Postgres privileges: default privileges row for sequences"),
		SPPostgresPrivilegeKindDefaultFunctions: NSLocalizedString(@"Functions created later", @"Postgres privileges: default privileges row for functions"),
	};

	NSMutableArray *objects = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *kind = SPPostgresPrivilegesText([row objectAtIndex:0]);
		NSString *name = SPPostgresPrivilegesText([row objectAtIndex:1]);
		NSString *signature = SPPostgresPrivilegesText([row objectAtIndex:2]);
		if ([kind isEqualToString:SPPostgresPrivilegeKindFunction]) name = [NSString stringWithFormat:@"%@(%@)", name, signature ?: @""];
		else if ([defaultLabels objectForKey:kind]) name = [defaultLabels objectForKey:kind];

		// Without a creator there are no default privileges to show.
		BOOL emptyDefault = !creator && [defaultLabels objectForKey:kind];
		SPPostgresPrivilegeObject *object = [[SPPostgresPrivilegeObject alloc] initWithKind:kind schema:schema name:name signature:signature
			granted:emptyDefault ? nil : SPPostgresPrivilegesSet([row objectAtIndex:3])
			grantable:emptyDefault ? nil : SPPostgresPrivilegesSet([row objectAtIndex:4])];
		[objects addObject:object];
		[object release];
	}
	return objects;
}

- (NSString *)ownerOfSchema:(NSString *)schema error:(NSError **)error
{
	NSArray *rows = SPPostgresPrivilegesRows(_connection,
		@"SELECT pg_catalog.pg_get_userbyid(nspowner)::text FROM pg_catalog.pg_namespace WHERE nspname = $1", @[schema ?: @""], error);
	if (!rows) return nil;
	NSString *owner = [rows count] ? SPPostgresPrivilegesText([[rows firstObject] firstObject]) : nil;
	if (!owner) {
		return SPPostgresPrivilegesFail([NSString stringWithFormat:NSLocalizedString(@"The schema “%@” doesn’t exist.", @"Postgres privileges: no such schema"), schema], error);
	}
	return owner;
}

#pragma mark Statements

/// "ON <kind> <object>" for a GRANT / REVOKE on object, or nil for a default kind.
+ (NSString *)objectClauseFor:(SPPostgresPrivilegeObject *)object
{
	NSString *kind = [object kind];
	NSString *qualified = [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier([object schema] ?: @""), SPPostgresQuoteIdentifier([object name] ?: @"")];
	if ([kind isEqualToString:SPPostgresPrivilegeKindDatabase]) return [@"DATABASE " stringByAppendingString:SPPostgresQuoteIdentifier([object name] ?: @"")];
	if ([kind isEqualToString:SPPostgresPrivilegeKindSchema]) return [@"SCHEMA " stringByAppendingString:SPPostgresQuoteIdentifier([object name] ?: @"")];
	if ([kind isEqualToString:SPPostgresPrivilegeKindSequence]) return [@"SEQUENCE " stringByAppendingString:qualified];
	if ([kind isEqualToString:SPPostgresPrivilegeKindFunction]) {
		// Identity arguments are server-formatted SQL (types, with modes and names): written as they are.
		return [NSString stringWithFormat:@"ROUTINE %@.%@(%@)", SPPostgresQuoteIdentifier([object schema] ?: @""),
				SPPostgresQuoteIdentifier([object functionName] ?: @""), [object signature] ?: @""];
	}
	if ([kind isEqualToString:SPPostgresPrivilegeKindTable] || [kind isEqualToString:SPPostgresPrivilegeKindView]
		|| [kind isEqualToString:SPPostgresPrivilegeKindMaterializedView] || [kind isEqualToString:SPPostgresPrivilegeKindForeignTable]) {
		return [@"TABLE " stringByAppendingString:qualified];
	}
	return nil;
}

/// TABLES, SEQUENCES or FUNCTIONS for a default kind, else nil.
+ (NSString *)defaultObjectTypeFor:(NSString *)kind
{
	if ([kind isEqualToString:SPPostgresPrivilegeKindDefaultTables]) return @"TABLES";
	if ([kind isEqualToString:SPPostgresPrivilegeKindDefaultSequences]) return @"SEQUENCES";
	if ([kind isEqualToString:SPPostgresPrivilegeKindDefaultFunctions]) return @"FUNCTIONS"; // ROUTINES needs PostgreSQL 14
	return nil;
}

+ (NSArray *)statementsForRole:(NSString *)role original:(NSArray *)originals edited:(NSArray *)edited defaultsCreator:(NSString *)creator
{
	NSMutableDictionary *originalsByKey = [NSMutableDictionary dictionaryWithCapacity:[originals count]];
	for (SPPostgresPrivilegeObject *object in originals) [originalsByKey setObject:object forKey:[object matchKey]];

	NSString *quotedRole = SPPostgresQuoteIdentifier(role ?: @"");
	NSMutableArray *statements = [NSMutableArray array];
	for (SPPostgresPrivilegeObject *object in edited) {
		NSSet *before = [[originalsByKey objectForKey:[object matchKey]] granted] ?: [NSSet set];
		NSSet *after = [object granted] ?: [NSSet set];

		NSMutableArray *added = [NSMutableArray array];
		NSMutableArray *removed = [NSMutableArray array];
		for (NSString *privilege in [object availablePrivileges]) {
			BOOL had = [before containsObject:privilege], has = [after containsObject:privilege];
			if (has && !had) [added addObject:privilege];
			else if (had && !has) [removed addObject:privilege];
		}
		if (![added count] && ![removed count]) continue;

		NSString *defaultType = [self defaultObjectTypeFor:[object kind]];
		if (defaultType) {
			if (!creator) continue;
			NSString *prefix = [NSString stringWithFormat:@"ALTER DEFAULT PRIVILEGES FOR ROLE %@ IN SCHEMA %@",
								SPPostgresQuoteIdentifier(creator), SPPostgresQuoteIdentifier([object schema] ?: @"")];
			if ([added count]) [statements addObject:[NSString stringWithFormat:@"%@ GRANT %@ ON %@ TO %@", prefix, [added componentsJoinedByString:@", "], defaultType, quotedRole]];
			if ([removed count]) [statements addObject:[NSString stringWithFormat:@"%@ REVOKE %@ ON %@ FROM %@", prefix, [removed componentsJoinedByString:@", "], defaultType, quotedRole]];
			continue;
		}

		NSString *clause = [self objectClauseFor:object];
		if (!clause) continue;
		if ([added count]) [statements addObject:[NSString stringWithFormat:@"GRANT %@ ON %@ TO %@", [added componentsJoinedByString:@", "], clause, quotedRole]];
		if ([removed count]) [statements addObject:[NSString stringWithFormat:@"REVOKE %@ ON %@ FROM %@", [removed componentsJoinedByString:@", "], clause, quotedRole]];
	}
	return statements;
}

- (BOOL)applyStatements:(NSArray *)statements error:(NSError **)error
{
	return SPPostgresApplyInTransaction(_connection, statements, error);
}

@end
