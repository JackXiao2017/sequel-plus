#import "SPPostgresRoles.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTableDuplicator.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

#pragma mark - Helpers

/// Fails with message (SPPostgresErrorQueryFailed) for something refused before anything is sent.
static id SPPostgresRolesRefuse(NSString *message, NSError **error)
{
	if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil);
	return nil;
}

/// The value as an NSString, or nil for NULL.
static NSString *SPPostgresRolesText(id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Every row of the query as arrays of NSString / NSNull (the query selects text), or nil on failure.
static NSArray *SPPostgresRolesRows(PGPostgresConnection *connection, NSString *sql, NSError **error)
{
	PGPostgresResult *result = SPPostgresExecuteWithDetails(connection, sql, nil, error);
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

static BOOL SPPostgresRolesSameDate(NSDate *a, NSDate *b)
{
	return a == b || (a && b && [a isEqualToDate:b]);
}

/// 'infinity' for nil, else an ISO 8601 timestamp in UTC with its offset, e.g. '2030-01-02T03:04:05+00:00'
/// (microseconds added when there are any).
static NSString *SPPostgresRolesValidUntilLiteral(NSDate *date)
{
	if (!date) return @"'infinity'";

	NSTimeInterval interval = [date timeIntervalSince1970];
	NSTimeInterval seconds = floor(interval);
	long micros = lround((interval - seconds) * 1000000.0);
	if (micros >= 1000000) { seconds += 1; micros = 0; }

	NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
	[formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
	[formatter setCalendar:[[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease]];
	[formatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
	[formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss"];
	NSString *text = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds]];
	if (micros) text = [text stringByAppendingFormat:@".%06ld", micros];
	return SPPostgresQuoteLiteral([text stringByAppendingString:@"+00:00"]);
}

/// The (member, group) key of one membership.
static NSArray *SPPostgresRolesPair(NSString *member, NSString *group)
{
	return [NSArray arrayWithObjects:member, group, nil];
}

#pragma mark - SPPostgresRole

@implementation SPPostgresRole

@synthesize name = _name, originalName = _originalName, canLogin = _canLogin, inherit = _inherit, superuser = _superuser;
@synthesize createDB = _createDB, createRole = _createRole, replication = _replication, bypassRLS = _bypassRLS;
@synthesize connectionLimit = _connectionLimit, validUntil = _validUntil, newPassword = _newPassword, clearPassword = _clearPassword;
@synthesize memberOf = _memberOf, members = _members, markedForDeletion = _markedForDeletion;

+ (instancetype)roleWithName:(NSString *)name
{
	SPPostgresRole *role = [[[self alloc] init] autorelease];
	[role setName:name];
	return role;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_inherit = YES;
		_connectionLimit = -1;
		_memberOf = [[NSDictionary alloc] init];
		_members = [[NSDictionary alloc] init];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	SPPostgresRole *copy = [[[self class] allocWithZone:zone] init];
	[copy setName:_name];
	[copy setOriginalName:_originalName];
	[copy setCanLogin:_canLogin];
	[copy setInherit:_inherit];
	[copy setSuperuser:_superuser];
	[copy setCreateDB:_createDB];
	[copy setCreateRole:_createRole];
	[copy setReplication:_replication];
	[copy setBypassRLS:_bypassRLS];
	[copy setConnectionLimit:_connectionLimit];
	[copy setValidUntil:_validUntil];
	[copy setNewPassword:_newPassword];
	[copy setClearPassword:_clearPassword];
	[copy setMemberOf:_memberOf];
	[copy setMembers:_members];
	[copy setMarkedForDeletion:_markedForDeletion];
	return copy;
}

- (BOOL)isGroup
{
	return !_canLogin;
}

- (void)dealloc
{
	[_name release];
	[_originalName release];
	[_validUntil release];
	[_newPassword release];
	[_memberOf release];
	[_members release];
	[super dealloc];
}

- (NSString *)description
{
	// Never the password: only whether one is pending.
	return [NSString stringWithFormat:@"<%@ %@ (was %@)%@%@ limit %ld until %@ memberOf %@ members %@%@%@>", [self class], _name, _originalName,
			_canLogin ? @" login" : @"", _superuser ? @" superuser" : @"", (long)_connectionLimit, _validUntil, _memberOf, _members,
			[_newPassword length] ? @" new password" : @"", _markedForDeletion ? @" deleted" : @""];
}

@end

#pragma mark - Applying

BOOL SPPostgresApplyInTransaction(PGPostgresConnection *connection, NSArray *statements, NSError **error)
{
	if (![statements count]) return YES;

	switch ([connection transactionStatus]) {
		case PGPostgresTransactionInTransaction:
		case PGPostgresTransactionInError:
		case PGPostgresTransactionActive:
			SPPostgresRolesRefuse(NSLocalizedString(@"Nothing was applied: the connection is already inside a transaction.", @"Postgres users: apply refused inside a transaction"), error);
			return NO;
		default:
			break;
	}

	if (!SPPostgresExecute(connection, @"BEGIN", nil, error)) return NO;
	for (NSString *sql in statements) {
		if (!SPPostgresExecuteWithDetails(connection, sql, nil, error)) {
			[connection execute:@"ROLLBACK" values:@[]]; // quietly: the statement's error is the one to report
			return NO;
		}
	}
	if (!SPPostgresExecuteWithDetails(connection, @"COMMIT", nil, error)) {
		[connection execute:@"ROLLBACK" values:@[]];
		return NO;
	}
	return YES;
}

#pragma mark - SPPostgresRoles

@implementation SPPostgresRoles

- (instancetype)initWithConnection:(PGPostgresConnection *)connection
{
	if ((self = [super init])) {
		_connection = [connection retain];
		_grantorsByPair = [[NSDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_connection release];
	[_grantorsByPair release];
	[super dealloc];
}

#pragma mark Reading

- (NSArray *)roles:(NSError **)error
{
	NSArray *roleRows = SPPostgresRolesRows(_connection,
		@"SELECT rolname::text, rolcanlogin::text, rolinherit::text, rolsuper::text, rolcreatedb::text, rolcreaterole::text, "
		"rolreplication::text, rolbypassrls::text, rolconnlimit::text, "
		"CASE WHEN rolvaliduntil IS NULL OR rolvaliduntil = 'infinity' THEN NULL WHEN rolvaliduntil = '-infinity' THEN '-infinity' "
		"ELSE extract(epoch FROM rolvaliduntil)::text END "
		"FROM pg_catalog.pg_roles WHERE left(rolname, 3) <> 'pg_' ORDER BY rolname", error);
	if (!roleRows) return nil;

	// One row per grant: on PostgreSQL 16+ a membership may have several grantors.
	NSArray *memberRows = SPPostgresRolesRows(_connection,
		@"SELECT m.rolname::text, g.rolname::text, a.admin_option::text, gr.rolname::text "
		"FROM pg_catalog.pg_auth_members a JOIN pg_catalog.pg_roles m ON m.oid = a.member "
		"JOIN pg_catalog.pg_roles g ON g.oid = a.roleid LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = a.grantor "
		"ORDER BY 1, 2, 4", error);
	if (!memberRows) return nil;

	NSMutableDictionary *memberOf = [NSMutableDictionary dictionary]; // member → {group: admin}
	NSMutableDictionary *members = [NSMutableDictionary dictionary];  // group → {member: admin}
	NSMutableDictionary *grantors = [NSMutableDictionary dictionary]; // pair → [[grantor, admin], …]
	for (NSArray *row in memberRows) {
		NSString *member = SPPostgresRolesText([row objectAtIndex:0]);
		NSString *group = SPPostgresRolesText([row objectAtIndex:1]);
		BOOL admin = [SPPostgresRolesText([row objectAtIndex:2]) isEqualToString:@"true"];
		NSString *grantor = SPPostgresRolesText([row objectAtIndex:3]);
		if (!member || !group) continue;

		NSMutableDictionary *groups = [memberOf objectForKey:member];
		if (!groups) [memberOf setObject:(groups = [NSMutableDictionary dictionary]) forKey:member];
		[groups setObject:@([[groups objectForKey:group] boolValue] || admin) forKey:group];

		NSMutableDictionary *groupMembers = [members objectForKey:group];
		if (!groupMembers) [members setObject:(groupMembers = [NSMutableDictionary dictionary]) forKey:group];
		[groupMembers setObject:@([[groupMembers objectForKey:member] boolValue] || admin) forKey:member];

		if (grantor) {
			NSArray *pair = SPPostgresRolesPair(member, group);
			NSMutableArray *list = [grantors objectForKey:pair];
			if (!list) [grantors setObject:(list = [NSMutableArray array]) forKey:pair];
			[list addObject:@[grantor, @(admin)]];
		}
	}
	[_grantorsByPair release];
	_grantorsByPair = [grantors copy];

	NSMutableArray *roles = [NSMutableArray arrayWithCapacity:[roleRows count]];
	for (NSArray *row in roleRows) {
		NSString *name = SPPostgresRolesText([row objectAtIndex:0]);
		if (!name) continue;
		SPPostgresRole *role = [[[SPPostgresRole alloc] init] autorelease];
		[role setName:name];
		[role setOriginalName:name];
		[role setCanLogin:[[row objectAtIndex:1] isEqual:@"true"]];
		[role setInherit:[[row objectAtIndex:2] isEqual:@"true"]];
		[role setSuperuser:[[row objectAtIndex:3] isEqual:@"true"]];
		[role setCreateDB:[[row objectAtIndex:4] isEqual:@"true"]];
		[role setCreateRole:[[row objectAtIndex:5] isEqual:@"true"]];
		[role setReplication:[[row objectAtIndex:6] isEqual:@"true"]];
		[role setBypassRLS:[[row objectAtIndex:7] isEqual:@"true"]];
		[role setConnectionLimit:[SPPostgresRolesText([row objectAtIndex:8]) integerValue]];
		NSString *validUntil = SPPostgresRolesText([row objectAtIndex:9]);
		if ([validUntil isEqualToString:@"-infinity"]) [role setValidUntil:[NSDate distantPast]];
		else if (validUntil) [role setValidUntil:[NSDate dateWithTimeIntervalSince1970:[validUntil doubleValue]]];
		[role setMemberOf:[memberOf objectForKey:name] ?: @{}];
		[role setMembers:[members objectForKey:name] ?: @{}];
		[roles addObject:role];
	}
	return roles;
}

- (NSArray *)allRoleNames:(NSError **)error
{
	NSArray *rows = SPPostgresRolesRows(_connection, @"SELECT rolname::text FROM pg_catalog.pg_roles ORDER BY rolname", error);
	if (!rows) return nil;
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSString *name = SPPostgresRolesText([row firstObject]);
		if (name) [names addObject:name];
	}
	return names;
}

- (NSString *)sessionRoleName
{
	PGPostgresResult *result = SPPostgresExecute(_connection, @"SELECT session_user::text", nil, NULL);
	if (![result numberOfRows]) return nil;
	return SPPostgresRolesText([result textValueAtRow:0 column:0]);
}

#pragma mark Statements

/// The attribute keywords whose value differs between original and role (all of them when original is nil), in
/// CREATE ROLE's order.
static NSArray *SPPostgresRolesAttributeChanges(SPPostgresRole *original, SPPostgresRole *role)
{
	NSMutableArray *items = [NSMutableArray array];
	struct { BOOL now; BOOL was; NSString *keyword; } attributes[] = {
		{ [role canLogin], [original canLogin], @"LOGIN" },
		{ [role inherit], [original inherit], @"INHERIT" },
		{ [role superuser], [original superuser], @"SUPERUSER" },
		{ [role createDB], [original createDB], @"CREATEDB" },
		{ [role createRole], [original createRole], @"CREATEROLE" },
		{ [role replication], [original replication], @"REPLICATION" },
		{ [role bypassRLS], [original bypassRLS], @"BYPASSRLS" },
	};
	for (size_t i = 0; i < sizeof(attributes) / sizeof(attributes[0]); i++) {
		if (original && attributes[i].now == attributes[i].was) continue;
		[items addObject:attributes[i].now ? attributes[i].keyword : [@"NO" stringByAppendingString:attributes[i].keyword]];
	}
	return items;
}

- (NSArray *)statementsForOriginalRoles:(NSArray *)originals edited:(NSArray *)edited error:(NSError **)error
{
	NSMutableDictionary *originalsByName = [NSMutableDictionary dictionary];
	for (SPPostgresRole *role in originals) {
		if ([role originalName]) [originalsByName setObject:role forKey:[role originalName]];
	}

	// Sort out the draft: roles to drop, to rename, to create and to keep, and the names they end up with.
	NSMutableArray *drops = [NSMutableArray array];   // originals
	NSMutableArray *kept = [NSMutableArray array];    // edited roles that exist and stay
	NSMutableArray *created = [NSMutableArray array]; // edited roles to create
	NSMutableSet *deletedNames = [NSMutableSet set];  // original names
	NSMutableDictionary *renames = [NSMutableDictionary dictionary]; // original name → new name
	NSMutableSet *editedOriginals = [NSMutableSet set];
	for (SPPostgresRole *role in edited) {
		NSString *originalName = [role originalName];
		SPPostgresRole *original = originalName ? [originalsByName objectForKey:originalName] : nil;
		if (originalName && !original) {
			return SPPostgresRolesRefuse([NSString stringWithFormat:NSLocalizedString(@"The role \"%@\" is no longer known; reload the roles and try again.", @"Postgres users: edited role missing from originals"), originalName], error);
		}
		if (originalName) {
			if ([editedOriginals containsObject:originalName]) {
				return SPPostgresRolesRefuse([NSString stringWithFormat:NSLocalizedString(@"The role \"%@\" was edited twice.", @"Postgres users: same original twice"), originalName], error);
			}
			[editedOriginals addObject:originalName];
		}
		if ([role markedForDeletion]) {
			if (original) {
				[drops addObject:original];
				[deletedNames addObject:originalName];
			}
			continue;
		}
		if (original) {
			[kept addObject:role];
			if (![[role name] isEqualToString:originalName]) [renames setObject:([role name] ?: @"") forKey:originalName];
		}
		else {
			[created addObject:role];
		}
	}

	// Names: valid and unique among the roles that remain.
	NSMutableSet *finalNames = [NSMutableSet set];
	for (SPPostgresRole *role in originals) {
		if ([role originalName] && ![editedOriginals containsObject:[role originalName]]) [finalNames addObject:[role name]];
	}
	for (SPPostgresRole *role in [kept arrayByAddingObjectsFromArray:created]) {
		NSString *name = [role name];
		if (![SPPostgresTableDuplicator isValidTableName:name]) {
			return SPPostgresRolesRefuse([NSString stringWithFormat:NSLocalizedString(@"\"%@\" isn't a valid role name: it must be 1 to 63 bytes long.", @"Postgres users: invalid role name"), name ?: @""], error);
		}
		if ([finalNames containsObject:name]) {
			return SPPostgresRolesRefuse([NSString stringWithFormat:NSLocalizedString(@"There is more than one role named \"%@\".", @"Postgres users: duplicate role name"), name], error);
		}
		[finalNames addObject:name];
	}

	NSMutableArray *statements = [NSMutableArray array];

	// 1. Drops
	for (SPPostgresRole *role in drops) {
		[statements addObject:[NSString stringWithFormat:@"DROP ROLE %@", SPPostgresQuoteIdentifier([role originalName])]];
	}

	// 2. Renames
	for (SPPostgresRole *role in kept) {
		NSString *newName = [renames objectForKey:[role originalName]];
		if (newName) {
			[statements addObject:[NSString stringWithFormat:@"ALTER ROLE %@ RENAME TO %@", SPPostgresQuoteIdentifier([role originalName]), SPPostgresQuoteIdentifier(newName)]];
		}
	}

	// 3. Creates
	for (SPPostgresRole *role in created) {
		NSMutableArray *items = [NSMutableArray arrayWithArray:SPPostgresRolesAttributeChanges(nil, role)];
		[items addObject:[NSString stringWithFormat:@"CONNECTION LIMIT %ld", (long)[role connectionLimit]]];
		[items addObject:[@"VALID UNTIL " stringByAppendingString:SPPostgresRolesValidUntilLiteral([role validUntil])]];
		if (![role clearPassword] && [[role newPassword] length]) {
			NSString *password = [self passwordClauseForRole:role error:error];
			if (!password) return nil;
			[items addObject:password];
		}
		[statements addObject:[NSString stringWithFormat:@"CREATE ROLE %@ WITH %@", SPPostgresQuoteIdentifier([role name]), [items componentsJoinedByString:@" "]]];
	}

	// 4. Attribute, limit, valid-until and password changes
	for (SPPostgresRole *role in kept) {
		SPPostgresRole *original = [originalsByName objectForKey:[role originalName]];
		NSMutableArray *items = [NSMutableArray arrayWithArray:SPPostgresRolesAttributeChanges(original, role)];
		if ([role connectionLimit] != [original connectionLimit]) {
			[items addObject:[NSString stringWithFormat:@"CONNECTION LIMIT %ld", (long)[role connectionLimit]]];
		}
		if (!SPPostgresRolesSameDate([role validUntil], [original validUntil])) {
			[items addObject:[@"VALID UNTIL " stringByAppendingString:SPPostgresRolesValidUntilLiteral([role validUntil])]];
		}
		if ([role clearPassword]) {
			[items addObject:@"PASSWORD NULL"];
		}
		else if ([[role newPassword] length]) {
			NSString *password = [self passwordClauseForRole:role error:error];
			if (!password) return nil;
			[items addObject:password];
		}
		if ([items count]) {
			[statements addObject:[NSString stringWithFormat:@"ALTER ROLE %@ WITH %@", SPPostgresQuoteIdentifier([role name]), [items componentsJoinedByString:@" "]]];
		}
	}

	// 5 and 6. Memberships
	NSArray *membershipStatements = [self membershipStatementsForOriginals:originals kept:kept created:created
																   renames:renames deletedNames:deletedNames error:error];
	if (!membershipStatements) return nil;
	[statements addObjectsFromArray:membershipStatements];

	return statements;
}

/// PASSWORD '<hash>' for the role's newPassword, hashed for its (new) name; nil (with an error that doesn't
/// contain the password) when hashing fails.
- (NSString *)passwordClauseForRole:(SPPostgresRole *)role error:(NSError **)error
{
	NSString *hashed = [_connection encryptedPassword:[role newPassword] forRole:[role name]];
	if (![hashed length]) {
		NSString *reason = [_connection isConnected] ? [_connection libpqErrorMessage] : nil;
		NSString *message = [NSString stringWithFormat:NSLocalizedString(@"The password for role \"%@\" couldn't be encrypted.", @"Postgres users: password hashing failed"), [role name]];
		if ([reason length]) message = [message stringByAppendingFormat:@" %@", reason];
		return SPPostgresRolesRefuse(message, error);
	}
	return [@"PASSWORD " stringByAppendingString:SPPostgresQuoteLiteral(hashed)];
}

/**
 * REVOKE then GRANT statements for the memberships that differ. Pairs are compared by the names roles have after
 * the renames. A name in an edited dictionary means the role currently so named in the draft, or else a renamed
 * role's original name (a draft not updated after a rename); pairs with a deleted role are left to DROP ROLE.
 */
- (NSArray *)membershipStatementsForOriginals:(NSArray *)originals kept:(NSArray *)kept created:(NSArray *)created
									  renames:(NSDictionary *)renames deletedNames:(NSSet *)deletedNames error:(NSError **)error
{
	NSMutableSet *currentNames = [NSMutableSet set];
	for (SPPostgresRole *role in [kept arrayByAddingObjectsFromArray:created]) [currentNames addObject:[role name]];

	// Original names → names after the renames; nil for a deleted role
	NSString *(^mapOriginal)(NSString *) = ^NSString *(NSString *name) {
		if ([deletedNames containsObject:name]) return nil;
		return [renames objectForKey:name] ?: name;
	};
	// Draft names → names after the renames; nil for a deleted role
	NSString *(^mapDraft)(NSString *) = ^NSString *(NSString *name) {
		if ([currentNames containsObject:name]) return name;
		return mapOriginal(name);
	};

	// The memberships as they are (keyed by final names), and the original pair each comes from (for its grantors)
	NSMutableDictionary *before = [NSMutableDictionary dictionary];
	NSMutableDictionary *originalPairs = [NSMutableDictionary dictionary];
	void (^addBefore)(NSString *, NSString *, NSNumber *) = ^(NSString *member, NSString *group, NSNumber *admin) {
		NSString *finalMember = mapOriginal(member), *finalGroup = mapOriginal(group);
		if (!finalMember || !finalGroup) return;
		NSArray *pair = SPPostgresRolesPair(finalMember, finalGroup);
		[before setObject:@([[before objectForKey:pair] boolValue] || [admin boolValue]) forKey:pair];
		[originalPairs setObject:SPPostgresRolesPair(member, group) forKey:pair];
	};
	NSMutableDictionary *originalsByName = [NSMutableDictionary dictionary];
	for (SPPostgresRole *role in originals) {
		if (![role originalName]) continue;
		[originalsByName setObject:role forKey:[role originalName]];
		for (NSString *group in [role memberOf]) addBefore([role originalName], group, [[role memberOf] objectForKey:group]);
		for (NSString *member in [role members]) addBefore(member, [role originalName], [[role members] objectForKey:member]);
	}

	// The edits, side by side: pair → @(admin) to have it, NSNull to remove it
	NSMutableDictionary *changes = [NSMutableDictionary dictionary];
	__block NSString *conflict = nil;
	void (^change)(NSString *, NSString *, id) = ^(NSString *member, NSString *group, id value) {
		if (!member || !group) return;
		NSArray *pair = SPPostgresRolesPair(member, group);
		id existing = [changes objectForKey:pair];
		if (existing && ![existing isEqual:value]) { if (!conflict) conflict = [NSString stringWithFormat:@"%@ / %@", member, group]; return; }
		[changes setObject:value forKey:pair];
	};
	for (SPPostgresRole *role in [kept arrayByAddingObjectsFromArray:created]) {
		SPPostgresRole *original = [role originalName] ? [originalsByName objectForKey:[role originalName]] : nil;
		NSString *name = [role name];

		// Member of: this role is the member
		NSMutableDictionary *was = [NSMutableDictionary dictionary], *now = [NSMutableDictionary dictionary];
		for (NSString *group in [original memberOf]) { NSString *g = mapOriginal(group); if (g) [was setObject:[[original memberOf] objectForKey:group] forKey:g]; }
		for (NSString *group in [role memberOf]) { NSString *g = mapDraft(group); if (g) [now setObject:@([[[role memberOf] objectForKey:group] boolValue]) forKey:g]; }
		for (NSString *group in was) if (![now objectForKey:group]) change(name, group, [NSNull null]);
		for (NSString *group in now) if (![[was objectForKey:group] isEqual:[now objectForKey:group]]) change(name, group, [now objectForKey:group]);

		// Members: this role is the group
		was = [NSMutableDictionary dictionary]; now = [NSMutableDictionary dictionary];
		for (NSString *member in [original members]) { NSString *m = mapOriginal(member); if (m) [was setObject:[[original members] objectForKey:member] forKey:m]; }
		for (NSString *member in [role members]) { NSString *m = mapDraft(member); if (m) [now setObject:@([[[role members] objectForKey:member] boolValue]) forKey:m]; }
		for (NSString *member in was) if (![now objectForKey:member]) change(member, name, [NSNull null]);
		for (NSString *member in now) if (![[was objectForKey:member] isEqual:[now objectForKey:member]]) change(member, name, [now objectForKey:member]);
	}
	if (conflict) {
		return SPPostgresRolesRefuse([NSString stringWithFormat:NSLocalizedString(@"The membership %@ was changed in two different ways.", @"Postgres users: conflicting membership edits"), conflict], error);
	}

	BOOL grantedBy = [_connection isConnected] && [_connection serverVersion] >= 160000;
	NSMutableArray *revokes = [NSMutableArray array], *grants = [NSMutableArray array];
	NSArray *pairs = [[changes allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
		NSComparisonResult result = [[a objectAtIndex:0] compare:[b objectAtIndex:0]];
		return result != NSOrderedSame ? result : [[a objectAtIndex:1] compare:[b objectAtIndex:1]];
	}];
	for (NSArray *pair in pairs) {
		NSNumber *was = [before objectForKey:pair];
		id now = [changes objectForKey:pair];
		NSString *member = SPPostgresQuoteIdentifier([pair objectAtIndex:0]), *group = SPPostgresQuoteIdentifier([pair objectAtIndex:1]);
		NSArray *grantors = grantedBy ? [_grantorsByPair objectForKey:[originalPairs objectForKey:pair]] : nil;

		if (now == [NSNull null]) {
			if (!was) continue;
			// On 16+ a plain REVOKE only removes the current user's grant: revoke every grantor's
			if ([grantors count]) {
				for (NSArray *grantor in grantors) {
					[revokes addObject:[NSString stringWithFormat:@"REVOKE %@ FROM %@ GRANTED BY %@", group, member, SPPostgresQuoteIdentifier(mapOriginal([grantor objectAtIndex:0]) ?: [grantor objectAtIndex:0])]];
				}
			}
			else {
				[revokes addObject:[NSString stringWithFormat:@"REVOKE %@ FROM %@", group, member]];
			}
		}
		else if (!was || (![was boolValue] && [now boolValue])) {
			[grants addObject:[NSString stringWithFormat:@"GRANT %@ TO %@%@", group, member, [now boolValue] ? @" WITH ADMIN OPTION" : @""]];
		}
		else if ([was boolValue] && ![now boolValue]) {
			NSMutableArray *adminGrantors = [NSMutableArray array];
			for (NSArray *grantor in grantors) if ([[grantor objectAtIndex:1] boolValue]) [adminGrantors addObject:[grantor objectAtIndex:0]];
			if ([adminGrantors count]) {
				for (NSString *grantor in adminGrantors) {
					[revokes addObject:[NSString stringWithFormat:@"REVOKE ADMIN OPTION FOR %@ FROM %@ GRANTED BY %@", group, member, SPPostgresQuoteIdentifier(mapOriginal(grantor) ?: grantor)]];
				}
			}
			else {
				[revokes addObject:[NSString stringWithFormat:@"REVOKE ADMIN OPTION FOR %@ FROM %@", group, member]];
			}
		}
	}
	return [revokes arrayByAddingObjectsFromArray:grants];
}

- (BOOL)applyStatements:(NSArray *)statements error:(NSError **)error
{
	return SPPostgresApplyInTransaction(_connection, statements, error);
}

@end
