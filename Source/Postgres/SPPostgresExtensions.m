#import "SPPostgresExtensions.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

#pragma mark - Helpers

/// The value as an NSString, or nil for NULL.
static NSString *SPPostgresExtensionText(id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Every row of the query as arrays of NSString / NSNull (the query selects text), or nil on failure.
static NSArray *SPPostgresExtensionRows(PGPostgresConnection *connection, NSString *sql, NSArray *values, NSError **error)
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

/// The installed extensions with their available-extension details. $1 (optional): only that name.
static NSString * const SPPostgresInstalledExtensionsSQL =
	@"SELECT e.extname::text, e.extversion::text, n.nspname::text, a.comment::text,"
	@" CASE WHEN e.extrelocatable THEN 'true' ELSE 'false' END, a.default_version::text"
	@" FROM pg_catalog.pg_extension e"
	@" JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace"
	@" LEFT JOIN pg_catalog.pg_available_extensions a ON a.name = e.extname";

/// (required, requiring) name pairs of installed extensions, sorted by the requiring name.
static NSString * const SPPostgresExtensionRequirementsSQL =
	@"SELECT r.extname::text, e.extname::text"
	@" FROM pg_catalog.pg_depend d"
	@" JOIN pg_catalog.pg_extension e ON e.oid = d.objid"
	@" JOIN pg_catalog.pg_extension r ON r.oid = d.refobjid"
	@" WHERE d.classid = 'pg_catalog.pg_extension'::pg_catalog.regclass"
	@" AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass"
	@" ORDER BY e.extname";

#pragma mark - SPPostgresExtension

@implementation SPPostgresExtension

@synthesize name = _name;
@synthesize version = _version;
@synthesize schema = _schema;
@synthesize comment = _comment;
@synthesize relocatable = _relocatable;
@synthesize defaultVersion = _defaultVersion;
@synthesize requiredBy = _requiredBy;

- (instancetype)initWithRow:(NSArray *)row requiredBy:(NSArray *)requiredBy
{
	if ((self = [super init])) {
		_name = [SPPostgresExtensionText(row[0]) copy];
		_version = [SPPostgresExtensionText(row[1]) copy];
		_schema = [SPPostgresExtensionText(row[2]) copy];
		_comment = [SPPostgresExtensionText(row[3]) copy];
		_relocatable = [SPPostgresExtensionText(row[4]) isEqualToString:@"true"];
		_defaultVersion = [SPPostgresExtensionText(row[5]) copy];
		_requiredBy = [requiredBy ?: @[] copy];
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_version release];
	[_schema release];
	[_comment release];
	[_defaultVersion release];
	[_requiredBy release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@ in %@>", [self className], _name, _version, _schema];
}

@end

#pragma mark - SPPostgresAvailableExtension

@implementation SPPostgresAvailableExtension

@synthesize name = _name;
@synthesize defaultVersion = _defaultVersion;
@synthesize comment = _comment;
@synthesize versions = _versions;
@synthesize fixedSchema = _fixedSchema;

- (instancetype)initWithName:(NSString *)name defaultVersion:(NSString *)defaultVersion comment:(NSString *)comment
					versions:(NSArray *)versions fixedSchema:(NSString *)fixedSchema
{
	if ((self = [super init])) {
		_name = [name copy];
		_defaultVersion = [defaultVersion copy];
		_comment = [comment copy];
		_versions = [versions ?: @[] copy];
		_fixedSchema = [fixedSchema copy];
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_defaultVersion release];
	[_comment release];
	[_versions release];
	[_fixedSchema release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@>", [self className], _name, _defaultVersion];
}

@end

#pragma mark - SPPostgresExtensions

@implementation SPPostgresExtensions

@synthesize lockTimeout = _lockTimeout;

- (instancetype)initWithConnection:(PGPostgresConnection *)connection
{
	if ((self = [super init])) {
		_connection = [connection retain];
		_lockTimeout = 5;
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[super dealloc];
}

#pragma mark Reading

/// The installed extensions, optionally only the one named (name non-nil).
- (NSArray *)installedExtensionsNamed:(NSString *)name error:(NSError **)error
{
	NSString *sql = name ? [SPPostgresInstalledExtensionsSQL stringByAppendingString:@" WHERE e.extname = $1::text"] : SPPostgresInstalledExtensionsSQL;
	NSArray *rows = SPPostgresExtensionRows(_connection, [sql stringByAppendingString:@" ORDER BY e.extname"], name ? @[name] : nil, error);
	if (!rows) return nil;
	if (![rows count]) return @[];

	NSArray *pairs = SPPostgresExtensionRows(_connection, SPPostgresExtensionRequirementsSQL, nil, error);
	if (!pairs) return nil;
	NSMutableDictionary *requiredBy = [NSMutableDictionary dictionary];
	for (NSArray *pair in pairs) {
		NSString *required = SPPostgresExtensionText(pair[0]), *requiring = SPPostgresExtensionText(pair[1]);
		if (!required || !requiring) continue;
		NSMutableArray *names = requiredBy[required];
		if (!names) requiredBy[required] = names = [NSMutableArray array];
		if (![names containsObject:requiring]) [names addObject:requiring];
	}

	NSMutableArray *extensions = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		SPPostgresExtension *extension = [[SPPostgresExtension alloc] initWithRow:row requiredBy:requiredBy[SPPostgresExtensionText(row[0]) ?: @""]];
		[extensions addObject:extension];
		[extension release];
	}
	return extensions;
}

- (NSArray *)installedExtensions:(NSError **)error
{
	return [self installedExtensionsNamed:nil error:error];
}

- (SPPostgresExtension *)extensionNamed:(NSString *)name error:(NSError **)error
{
	NSError *readError = nil;
	NSArray *extensions = [self installedExtensionsNamed:name ?: @"" error:&readError];
	if (error) *error = extensions ? nil : readError;
	return [extensions firstObject];
}

- (NSArray *)availableExtensions:(NSError **)error
{
	NSArray *rows = SPPostgresExtensionRows(_connection, (@"SELECT name::text, default_version::text, comment::text"
														  @" FROM pg_catalog.pg_available_extensions"
														  @" WHERE installed_version IS NULL ORDER BY name"), nil, error);
	if (!rows) return nil;
	// The versions in the view's own order; schema is the control file's, per version
	NSArray *versionRows = SPPostgresExtensionRows(_connection, (@"SELECT v.name::text, v.version::text, v.schema::text"
																 @" FROM pg_catalog.pg_available_extension_versions v"
																 @" WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = v.name)"), nil, error);
	if (!versionRows) return nil;

	NSMutableDictionary *versions = [NSMutableDictionary dictionary];
	NSMutableDictionary *schemas = [NSMutableDictionary dictionary];
	for (NSArray *row in versionRows) {
		NSString *name = SPPostgresExtensionText(row[0]), *version = SPPostgresExtensionText(row[1]), *schema = SPPostgresExtensionText(row[2]);
		if (!name || !version) continue;
		NSMutableArray *list = versions[name];
		if (!list) versions[name] = list = [NSMutableArray array];
		[list addObject:version];
		if (schema) schemas[@[name, version]] = schema;
	}

	NSMutableArray *available = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *name = SPPostgresExtensionText(row[0]), *defaultVersion = SPPostgresExtensionText(row[1]);
		if (!name) continue;
		NSString *fixedSchema = defaultVersion ? schemas[@[name, defaultVersion]] : nil;
		SPPostgresAvailableExtension *extension = [[SPPostgresAvailableExtension alloc] initWithName:name defaultVersion:defaultVersion
																							 comment:SPPostgresExtensionText(row[2])
																							versions:versions[name] fixedSchema:fixedSchema];
		[available addObject:extension];
		[extension release];
	}
	return available;
}

- (NSArray *)updateTargetsForExtension:(NSString *)name error:(NSError **)error
{
	NSError *readError = nil;
	SPPostgresExtension *extension = [self extensionNamed:name error:&readError];
	if (!extension) {
		if (error) *error = readError;
		return readError ? nil : @[];
	}
	NSArray *rows = SPPostgresExtensionRows(_connection, (@"SELECT p.target::text"
														  @" FROM pg_catalog.pg_extension_update_paths($1::text::pg_catalog.name) WITH ORDINALITY p(source, target, path, ord)"
														  @" WHERE p.source = $2::text AND p.path IS NOT NULL ORDER BY p.ord"),
											@[[extension name], [extension version] ?: @""], error);
	if (!rows) return nil;
	NSMutableArray *targets = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *target = SPPostgresExtensionText([row firstObject]);
		if (target) [targets addObject:target];
	}
	return targets;
}

/// The names of the installed extensions, nil on failure.
- (NSSet *)installedNames:(NSError **)error
{
	NSArray *rows = SPPostgresExtensionRows(_connection, @"SELECT extname::text FROM pg_catalog.pg_extension", nil, error);
	if (!rows) return nil;
	NSMutableSet *names = [NSMutableSet setWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *name = SPPostgresExtensionText([row firstObject]);
		if (name) [names addObject:name];
	}
	return names;
}

/// The extensions version (nil: the default) of name requires directly, in the control file's order; nil on failure.
- (NSArray *)requirementsOf:(NSString *)name version:(NSString *)version error:(NSError **)error
{
	NSString *sql = (@"SELECT r.required::text FROM pg_catalog.pg_available_extension_versions v,"
					 @" LATERAL pg_catalog.unnest(v.requires) WITH ORDINALITY r(required, ord)"
					 @" WHERE v.name = $1::text AND v.version = COALESCE($2::text,"
					 @" (SELECT a.default_version FROM pg_catalog.pg_available_extensions a WHERE a.name = $1::text))"
					 @" ORDER BY r.ord");
	NSArray *rows = SPPostgresExtensionRows(_connection, sql, @[name ?: @"", version ?: [NSNull null]], error);
	if (!rows) return nil;
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *required = SPPostgresExtensionText([row firstObject]);
		if (required) [names addObject:required];
	}
	return names;
}

/// Depth first: each missing requirement's own missing requirements before it. visited holds every name seen.
- (BOOL)addMissingRequirementsOf:(NSString *)name version:(NSString *)version installed:(NSSet *)installed
						 visited:(NSMutableSet *)visited into:(NSMutableArray *)missing error:(NSError **)error
{
	NSArray *requirements = [self requirementsOf:name version:version error:error];
	if (!requirements) return NO;
	for (NSString *required in requirements) {
		if ([installed containsObject:required] || [visited containsObject:required]) continue;
		[visited addObject:required];
		if (![self addMissingRequirementsOf:required version:nil installed:installed visited:visited into:missing error:error]) return NO;
		[missing addObject:required];
	}
	return YES;
}

- (NSArray *)missingRequirementsForExtension:(NSString *)name version:(NSString *)version error:(NSError **)error
{
	NSSet *installed = [self installedNames:error];
	if (!installed) return nil;
	NSMutableArray *missing = [NSMutableArray array];
	NSMutableSet *visited = [NSMutableSet setWithObject:name ?: @""];
	if (![self addMissingRequirementsOf:name version:version installed:installed visited:visited into:missing error:error]) return nil;
	return missing;
}

#pragma mark Changing

/// The available extension's default version and the control file's schema for version (nil: the default), each
/// nil when there is none; NO on failure.
- (BOOL)defaultVersion:(NSString **)defaultVersion fixedSchema:(NSString **)fixedSchema of:(NSString *)name version:(NSString *)version
				 error:(NSError **)error
{
	NSString *sql = (@"SELECT a.default_version::text, (SELECT v.schema::text FROM pg_catalog.pg_available_extension_versions v"
					 @" WHERE v.name = a.name AND v.version = COALESCE($2::text, a.default_version))"
					 @" FROM pg_catalog.pg_available_extensions a WHERE a.name = $1::text");
	NSArray *rows = SPPostgresExtensionRows(_connection, sql, @[name ?: @"", version ?: [NSNull null]], error);
	if (!rows) return NO;
	NSArray *row = [rows firstObject];
	*defaultVersion = row ? SPPostgresExtensionText(row[0]) : nil;
	*fixedSchema = row ? SPPostgresExtensionText(row[1]) : nil;
	return YES;
}

/// CREATE EXTENSION "name" [WITH SCHEMA "schema"] [VERSION 'version'], leaving out what the server would do anyway.
- (BOOL)create:(NSString *)name version:(NSString *)version schema:(NSString *)schema error:(NSError **)error
{
	NSString *defaultVersion = nil, *fixedSchema = nil;
	if (![self defaultVersion:&defaultVersion fixedSchema:&fixedSchema of:name version:version error:error]) return NO;

	NSMutableString *sql = [NSMutableString stringWithFormat:@"CREATE EXTENSION %@", SPPostgresQuoteIdentifier(name)];
	if ([schema length] && !fixedSchema) [sql appendFormat:@" WITH SCHEMA %@", SPPostgresQuoteIdentifier(schema)];
	if ([version length] && ![version isEqualToString:defaultVersion]) [sql appendFormat:@" VERSION %@", SPPostgresQuoteLiteral(version)];
	return SPPostgresExecuteWithDetails(_connection, sql, nil, error) != nil;
}

- (BOOL)installExtension:(NSString *)name version:(NSString *)version schema:(NSString *)schema error:(NSError **)error
{
	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		// Required extensions explicitly, dependencies first, never through CASCADE
		NSArray *missing = [self missingRequirementsForExtension:name version:version error:bodyError];
		if (!missing) return NO;
		for (NSString *required in missing) {
			if (![self create:required version:nil schema:schema error:bodyError]) return NO;
		}
		return [self create:name version:version schema:schema error:bodyError];
	}, error);
}

- (BOOL)updateExtension:(NSString *)name toVersion:(NSString *)version error:(NSError **)error
{
	NSString *sql = [NSString stringWithFormat:@"ALTER EXTENSION %@ UPDATE TO %@", SPPostgresQuoteIdentifier(name ?: @""), SPPostgresQuoteLiteral(version)];
	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		return SPPostgresExecuteWithDetails(_connection, sql, nil, bodyError) != nil;
	}, error);
}

- (BOOL)dropExtension:(NSString *)name error:(NSError **)error
{
	NSString *sql = [NSString stringWithFormat:@"DROP EXTENSION %@", SPPostgresQuoteIdentifier(name ?: @"")];
	return SPPostgresRunStructureChange(_connection, _lockTimeout, ^BOOL(NSError **bodyError) {
		NSError *dropError = nil;
		if (SPPostgresExecuteWithDetails(_connection, sql, nil, &dropError)) return YES;

		if ([[dropError userInfo][SPPostgresSQLStateErrorKey] isEqualToString:@"2BP01"]) {
			// Read the DETAIL now, before the savepoint or transaction is rolled back
			NSString *detail = [[[_connection lastError] errorDetailMessage] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			NSMutableArray *dependents = [NSMutableArray array];
			for (NSString *line in [detail ?: @"" componentsSeparatedByString:@"\n"]) {
				NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
				if ([trimmed length]) [dependents addObject:trimmed];
			}
			NSString *message = [NSString stringWithFormat:NSLocalizedString(@"\"%@\" can't be dropped because other objects depend on it.", @"Postgres extensions: extension has dependents"), name];
			dropError = SPPostgresMakeError(SPPostgresErrorHasDependents, message, @{SPPostgresDependentsErrorKey: dependents, SPPostgresSQLStateErrorKey: @"2BP01"});
		}
		if (bodyError) *bodyError = dropError;
		return NO;
	}, error);
}

@end
