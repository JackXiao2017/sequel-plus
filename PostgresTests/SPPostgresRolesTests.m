#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresRoles.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPRolesStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPRolesStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	[self.statements addObject:[query description]];
}
@end

static NSString * const SPRolesTestPassword = @"Pw-sp_t4!";

/// SPPostgresRoles: roles, memberships and hashed passwords, on PG 12 and 18.
@interface SPPostgresRolesTests : XCTestCase
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray *recorders;
@end

@implementation SPPostgresRolesTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.recorders = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) [SPPostgresTestServers dropTestRolesOnPort:port.unsignedIntegerValue];
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	self.recorders = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		[connection execute:@"DROP TABLE IF EXISTS public.sp_t4_owned"];
		[connection disconnect];
		[SPPostgresTestServers dropTestRolesOnPort:port.unsignedIntegerValue];
	}
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

- (PGPostgresConnection *)connectOn:(NSNumber *)port recorder:(SPRolesStatementRecorder **)recorder
{
	SPRolesStatementRecorder *newRecorder = [[SPRolesStatementRecorder alloc] init];
	[self.recorders addObject:newRecorder]; // the connection doesn't retain its delegate
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:newRecorder];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	*recorder = newRecorder;
	return connection;
}

/// A connection as user/password, or nil when the login fails (no test failure).
- (PGPostgresConnection *)loginOn:(NSNumber *)port user:(NSString *)user password:(NSString *)password
{
	PGPostgresConnection *connection = [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = port.unsignedIntegerValue;
	connection.user = user;
	connection.password = password;
	connection.database = @"pgkit_test";
	[connection connect];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
	while (!connection.isConnected && !connection.connectionError && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	if (!connection.isConnected) { [connection disconnect]; return nil; }
	[self.openConnections addObject:connection];
	return connection;
}

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	if (!result.numberOfRows) return nil;
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (NSArray<SPPostgresRole *> *)rolesOf:(SPPostgresRoles *)roles
{
	NSError *error = nil;
	NSArray *list = [roles roles:&error];
	XCTAssertNotNil(list, @"%@", error);
	return list;
}

- (SPPostgresRole *)role:(NSString *)name in:(NSArray<SPPostgresRole *> *)roles
{
	for (SPPostgresRole *role in roles) if ([role.name isEqualToString:name]) return role;
	return nil;
}

/// Deep copies of roles, as the sheet's draft.
- (NSArray<SPPostgresRole *> *)draftOf:(NSArray<SPPostgresRole *> *)roles
{
	NSMutableArray *draft = [NSMutableArray array];
	for (SPPostgresRole *role in roles) [draft addObject:[role copy]];
	return draft;
}

/// statementsFor… then apply; fails the test on failure. Returns the statements.
- (NSArray<NSString *> *)apply:(SPPostgresRoles *)roles originals:(NSArray *)originals edited:(NSArray *)edited
{
	NSError *error = nil;
	NSArray *statements = [roles statementsForOriginalRoles:originals edited:edited error:&error];
	XCTAssertNotNil(statements, @"%@", error);
	XCTAssertTrue([roles applyStatements:statements error:&error], @"%@: %@", statements, error);
	return statements;
}

#pragma mark - Reading

- (void)testRolesListsAttributesAndHidesPredefined
{
	NSDate *expiry = [[[NSISO8601DateFormatter alloc] init] dateFromString:@"2030-01-02T03:04:05Z"];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_group NOLOGIN" on:connection];
		[self run:@"CREATE ROLE sp_t4_login LOGIN CREATEDB CONNECTION LIMIT 3 VALID UNTIL '2030-01-02 03:04:05+00'" on:connection];
		[self run:@"GRANT sp_t4_group TO sp_t4_login WITH ADMIN OPTION" on:connection];

		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];
		NSArray<SPPostgresRole *> *list = [self rolesOf:roles];
		SPPostgresRole *login = [self role:@"sp_t4_login" in:list];
		SPPostgresRole *group = [self role:@"sp_t4_group" in:list];
		XCTAssertNotNil(login, @"%@", port);
		XCTAssertNotNil(group, @"%@", port);

		XCTAssertEqualObjects(login.originalName, @"sp_t4_login");
		XCTAssertTrue(login.canLogin);
		XCTAssertFalse(login.isGroup);
		XCTAssertTrue(login.inherit);
		XCTAssertTrue(login.createDB);
		XCTAssertFalse(login.superuser);
		XCTAssertFalse(login.createRole);
		XCTAssertFalse(login.replication);
		XCTAssertFalse(login.bypassRLS);
		XCTAssertEqual(login.connectionLimit, 3);
		XCTAssertEqualObjects(login.validUntil, expiry, @"%@", port);
		XCTAssertNil(login.newPassword);
		XCTAssertEqualObjects(login.memberOf, @{@"sp_t4_group": @YES});
		XCTAssertEqualObjects(login.members, @{});

		XCTAssertTrue(group.isGroup);
		XCTAssertFalse(group.canLogin);
		XCTAssertEqual(group.connectionLimit, -1);
		XCTAssertNil(group.validUntil);
		XCTAssertEqualObjects(group.members, @{@"sp_t4_login": @YES});
		XCTAssertEqualObjects(group.memberOf, @{});

		NSMutableArray *names = [NSMutableArray array];
		for (SPPostgresRole *role in list) {
			XCTAssertFalse([role.name hasPrefix:@"pg_"], @"%@", role.name);
			[names addObject:role.name];
		}
		XCTAssertEqualObjects(names, [names sortedArrayUsingSelector:@selector(compare:)]);

		NSError *error = nil;
		NSArray *all = [roles allRoleNames:&error];
		XCTAssertTrue([all containsObject:@"pg_read_all_stats"], @"%@", error);
		XCTAssertTrue([all containsObject:@"sp_t4_login"]);
		XCTAssertEqualObjects([roles sessionRoleName], @"pgkit_test");
	}
}

#pragma mark - Statements

- (void)testStatementsForNewAndChangedRoles
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_login LOGIN" on:connection];
		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];
		NSArray *originals = [self rolesOf:roles];
		NSError *error = nil;

		// Unchanged: nothing
		XCTAssertEqualObjects([roles statementsForOriginalRoles:originals edited:[self draftOf:originals] error:&error], @[], @"%@", error);

		NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
		[self role:@"sp_t4_login" in:draft].createDB = YES;
		[draft addObject:[SPPostgresRole roleWithName:@"sp_t4_g"]];
		NSArray *statements = [roles statementsForOriginalRoles:originals edited:draft error:&error];
		XCTAssertEqualObjects(statements, (@[
			@"CREATE ROLE \"sp_t4_g\" WITH NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 VALID UNTIL 'infinity'",
			@"ALTER ROLE \"sp_t4_login\" WITH CREATEDB",
		]), @"%@: %@", port, error);

		// Every changeable item at once, in order
		draft = [[self draftOf:originals] mutableCopy];
		SPPostgresRole *login = [self role:@"sp_t4_login" in:draft];
		login.canLogin = NO;
		login.inherit = NO;
		login.connectionLimit = 5;
		login.validUntil = [[[NSISO8601DateFormatter alloc] init] dateFromString:@"2031-02-03T04:05:06Z"];
		login.clearPassword = YES;
		XCTAssertEqualObjects([roles statementsForOriginalRoles:originals edited:draft error:&error],
							  (@[@"ALTER ROLE \"sp_t4_login\" WITH NOLOGIN NOINHERIT CONNECTION LIMIT 5 VALID UNTIL '2031-02-03T04:05:06+00:00' PASSWORD NULL"]), @"%@", error);

		// Refused: duplicate and invalid names
		draft = [[self draftOf:originals] mutableCopy];
		[draft addObject:[SPPostgresRole roleWithName:@"sp_t4_login"]];
		XCTAssertNil([roles statementsForOriginalRoles:originals edited:draft error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"sp_t4_login"], @"%@", error);
		draft = [[self draftOf:originals] mutableCopy];
		[draft addObject:[SPPostgresRole roleWithName:@""]];
		error = nil;
		XCTAssertNil([roles statementsForOriginalRoles:originals edited:draft error:&error]);
		XCTAssertNotNil(error);
	}
}

#pragma mark - Applying

- (void)testApplyCreatesRenamesAltersAndDrops
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_old" on:connection];
		[self run:@"CREATE ROLE sp_t4_gone" on:connection];
		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];
		NSArray *originals = [self rolesOf:roles];

		NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
		SPPostgresRole *created = [SPPostgresRole roleWithName:@"sp_t4_new"];
		created.canLogin = YES;
		[draft addObject:created];
		SPPostgresRole *old = [self role:@"sp_t4_old" in:draft];
		old.name = @"sp_t4_renamed";
		old.connectionLimit = 7;
		[self role:@"sp_t4_gone" in:draft].markedForDeletion = YES;
		NSArray *statements = [self apply:roles originals:originals edited:draft];
		XCTAssertEqualObjects(statements, (@[
			@"DROP ROLE \"sp_t4_gone\"",
			@"ALTER ROLE \"sp_t4_old\" RENAME TO \"sp_t4_renamed\"",
			@"CREATE ROLE \"sp_t4_new\" WITH LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 VALID UNTIL 'infinity'",
			@"ALTER ROLE \"sp_t4_renamed\" WITH CONNECTION LIMIT 7",
		]));
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);

		NSArray *reread = [self rolesOf:roles];
		NSMutableArray *testNames = [NSMutableArray array];
		for (SPPostgresRole *role in reread) if ([role.name hasPrefix:@"sp_t4_"]) [testNames addObject:role.name];
		XCTAssertEqualObjects(testNames, (@[@"sp_t4_new", @"sp_t4_renamed"]), @"%@", port);
		XCTAssertTrue([self role:@"sp_t4_new" in:reread].canLogin);
		XCTAssertEqual([self role:@"sp_t4_new" in:reread].connectionLimit, -1);
		XCTAssertEqual([self role:@"sp_t4_renamed" in:reread].connectionLimit, 7);
		XCTAssertFalse([self role:@"sp_t4_renamed" in:reread].canLogin);

		// Valid until round-trips
		draft = [[self draftOf:reread] mutableCopy];
		NSDate *expiry = [NSDate dateWithTimeIntervalSince1970:1900000000.25];
		[self role:@"sp_t4_new" in:draft].validUntil = expiry;
		[self apply:roles originals:reread edited:draft];
		XCTAssertEqualWithAccuracy([[self role:@"sp_t4_new" in:[self rolesOf:roles]].validUntil timeIntervalSince1970], 1900000000.25, 0.000001);
		reread = [self rolesOf:roles];
		draft = [[self draftOf:reread] mutableCopy];
		[self role:@"sp_t4_new" in:draft].validUntil = nil;
		[self apply:roles originals:reread edited:draft];
		XCTAssertNil([self role:@"sp_t4_new" in:[self rolesOf:roles]].validUntil);

		// Empty list: a no-op that sends nothing
		NSError *error = nil;
		XCTAssertTrue([roles applyStatements:@[] error:&error], @"%@", error);
	}
}

- (void)testApplyRefusesInsideATransaction
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPRolesStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		[self run:@"BEGIN" on:connection];
		NSUInteger sent = recorder.statements.count;
		NSError *error = nil;
		XCTAssertFalse(SPPostgresApplyInTransaction(connection, @[@"CREATE ROLE sp_t4_never"], &error));
		XCTAssertNotNil(error);
		XCTAssertEqual(recorder.statements.count, sent, @"nothing sent");
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);
		[self run:@"ROLLBACK" on:connection];
	}
}

- (void)testPasswordIsSentHashed
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPRolesStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];
		NSArray *originals = [self rolesOf:roles];

		NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
		SPPostgresRole *role = [SPPostgresRole roleWithName:@"sp_t4_pw"];
		role.canLogin = YES;
		role.newPassword = SPRolesTestPassword;
		for (int i = 0; i < 3; i++) XCTAssertEqualObjects(role.newPassword, SPRolesTestPassword); // an unowned getter under ARC
		XCTAssertEqualObjects(((SPPostgresRole *)[role copy]).newPassword, SPRolesTestPassword);
		[draft addObject:role];
		NSArray *statements = [self apply:roles originals:originals edited:draft];
		XCTAssertFalse([[role description] containsString:SPRolesTestPassword]);

		NSString *literal = nil;
		for (NSString *sql in recorder.statements) {
			XCTAssertFalse([sql containsString:SPRolesTestPassword], @"plain password sent: %@", sql);
			NSRange range = [sql rangeOfString:@"PASSWORD '"];
			if (range.location != NSNotFound) literal = [sql substringFromIndex:NSMaxRange(range)];
		}
		for (NSString *sql in statements) XCTAssertFalse([sql containsString:SPRolesTestPassword]);
		XCTAssertNotNil(literal, @"%@", recorder.statements);
		XCTAssertTrue([literal hasPrefix:@"SCRAM-SHA-256$"] || [literal hasPrefix:@"md5"], @"%@", literal);

		XCTAssertNotNil([self loginOn:port user:@"sp_t4_pw" password:SPRolesTestPassword], @"%@: login with the new password", port);
		XCTAssertNil([self loginOn:port user:@"sp_t4_pw" password:@"wrong"], @"%@: the server checks the password", port);
		XCTAssertEqualObjects([self value:@"SELECT (rolpassword IS NULL)::text FROM pg_authid WHERE rolname = 'sp_t4_pw'" on:connection], @"false");

		// Clear password
		NSArray *reread = [self rolesOf:roles];
		draft = [[self draftOf:reread] mutableCopy];
		[self role:@"sp_t4_pw" in:draft].clearPassword = YES;
		XCTAssertEqualObjects([self apply:roles originals:reread edited:draft], (@[@"ALTER ROLE \"sp_t4_pw\" WITH PASSWORD NULL"]));
		XCTAssertEqualObjects([self value:@"SELECT (rolpassword IS NULL)::text FROM pg_authid WHERE rolname = 'sp_t4_pw'" on:connection], @"true");
	}
}

- (void)testMembershipGrantRevokeAndAdminOption
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_group NOLOGIN" on:connection];
		[self run:@"CREATE ROLE sp_t4_member LOGIN" on:connection];
		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];

		// Add (from the member's side), with admin
		NSArray *originals = [self rolesOf:roles];
		NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
		[self role:@"sp_t4_member" in:draft].memberOf = @{@"sp_t4_group": @YES};
		XCTAssertEqualObjects([self apply:roles originals:originals edited:draft], (@[@"GRANT \"sp_t4_group\" TO \"sp_t4_member\" WITH ADMIN OPTION"]));
		NSArray *reread = [self rolesOf:roles];
		XCTAssertEqualObjects([self role:@"sp_t4_member" in:reread].memberOf, @{@"sp_t4_group": @YES}, @"%@", port);
		XCTAssertEqualObjects([self role:@"sp_t4_group" in:reread].members, @{@"sp_t4_member": @YES});

		// Flip only the admin option (from the group's side)
		draft = [[self draftOf:reread] mutableCopy];
		[self role:@"sp_t4_group" in:draft].members = @{@"sp_t4_member": @NO};
		NSArray *statements = [self apply:roles originals:reread edited:draft];
		XCTAssertEqual(statements.count, 1u, @"%@", statements);
		XCTAssertTrue([statements.firstObject hasPrefix:@"REVOKE ADMIN OPTION FOR \"sp_t4_group\" FROM \"sp_t4_member\""], @"%@", statements);
		reread = [self rolesOf:roles];
		XCTAssertEqualObjects([self role:@"sp_t4_member" in:reread].memberOf, @{@"sp_t4_group": @NO}, @"%@", port);

		// And back
		draft = [[self draftOf:reread] mutableCopy];
		[self role:@"sp_t4_member" in:draft].memberOf = @{@"sp_t4_group": @YES};
		[self apply:roles originals:reread edited:draft];
		reread = [self rolesOf:roles];
		XCTAssertEqualObjects([self role:@"sp_t4_member" in:reread].memberOf, @{@"sp_t4_group": @YES}, @"%@", port);

		// Remove
		draft = [[self draftOf:reread] mutableCopy];
		[self role:@"sp_t4_member" in:draft].memberOf = @{};
		statements = [self apply:roles originals:reread edited:draft];
		XCTAssertTrue([statements.firstObject hasPrefix:@"REVOKE \"sp_t4_group\" FROM \"sp_t4_member\""], @"%@", statements);
		reread = [self rolesOf:roles];
		XCTAssertEqualObjects([self role:@"sp_t4_member" in:reread].memberOf, @{}, @"%@", port);
		XCTAssertEqualObjects([self role:@"sp_t4_group" in:reread].members, @{});
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_auth_members WHERE member = 'sp_t4_member'::regrole" on:connection], @"0");
	}
}

- (void)testRevokeMembershipWithAnotherGrantorOnPG16Plus
{
	NSNumber *port = @55418;
	PGPostgresConnection *connection = [self connectOn:port];
	XCTAssertGreaterThanOrEqual(connection.serverVersion, 160000u);
	[self run:@"CREATE ROLE sp_t4_grantor CREATEROLE" on:connection];
	[self run:@"CREATE ROLE sp_t4_group NOLOGIN" on:connection];
	[self run:@"CREATE ROLE sp_t4_member LOGIN" on:connection];
	[self run:@"GRANT sp_t4_group TO sp_t4_grantor WITH ADMIN OPTION" on:connection];
	[self run:@"SET ROLE sp_t4_grantor" on:connection];
	[self run:@"GRANT sp_t4_group TO sp_t4_member" on:connection];
	[self run:@"RESET ROLE" on:connection];
	XCTAssertEqualObjects([self value:@"SELECT grantor::regrole::text FROM pg_auth_members WHERE member = 'sp_t4_member'::regrole" on:connection], @"sp_t4_grantor");

	SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];
	NSArray *originals = [self rolesOf:roles];
	XCTAssertEqualObjects([self role:@"sp_t4_member" in:originals].memberOf, @{@"sp_t4_group": @NO});
	NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
	[self role:@"sp_t4_member" in:draft].memberOf = @{};
	NSArray *statements = [self apply:roles originals:originals edited:draft];
	XCTAssertEqualObjects(statements, (@[@"REVOKE \"sp_t4_group\" FROM \"sp_t4_member\" GRANTED BY \"sp_t4_grantor\""]));
	XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_auth_members WHERE member = 'sp_t4_member'::regrole" on:connection], @"0");
}

- (void)testDropRoleThatOwnsObjectsIsRefusedAndRollsBack
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE ROLE sp_t4_owner" on:connection];
		[self run:@"CREATE TABLE public.sp_t4_owned (id int)" on:connection];
		[self run:@"ALTER TABLE public.sp_t4_owned OWNER TO sp_t4_owner" on:connection];
		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];
		NSArray *originals = [self rolesOf:roles];

		NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
		[self role:@"sp_t4_owner" in:draft].markedForDeletion = YES;
		[draft addObject:[SPPostgresRole roleWithName:@"sp_t4_side"]];
		NSError *error = nil;
		NSArray *statements = [roles statementsForOriginalRoles:originals edited:draft error:&error];
		XCTAssertEqual(statements.count, 2u, @"%@", error);
		for (NSString *sql in statements) XCTAssertFalse([sql containsString:@"CASCADE"] || [sql containsString:@"OWNED"]);
		XCTAssertFalse([roles applyStatements:statements error:&error]);
		NSString *message = error.localizedDescription;
		XCTAssertTrue([message containsString:@"sp_t4_owner"], @"%@", message);
		NSRange detail = [message rangeOfString:@"DETAIL:"];
		XCTAssertNotEqual(detail.location, (NSUInteger)NSNotFound, @"%@", message);
		XCTAssertTrue([[message substringFromIndex:detail.location] containsString:@"sp_t4_owned"], @"%@", message);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle, @"rolled back");

		NSArray *reread = [self rolesOf:roles];
		XCTAssertNotNil([self role:@"sp_t4_owner" in:reread], @"%@", port);
		XCTAssertNil([self role:@"sp_t4_side" in:reread], @"%@", port);
	}
}

- (void)testOddRoleNames
{
	NSString *sales = @"sp_t4_Sales Rep", *quote = @"sp_t4_a\"b";
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPRolesStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		[self run:@"CREATE ROLE sp_t4_tmp" on:connection];
		SPPostgresRoles *roles = [[SPPostgresRoles alloc] initWithConnection:connection];

		// Create one, rename the other to an odd name, a password and a membership between them
		NSArray *originals = [self rolesOf:roles];
		NSMutableArray *draft = [[self draftOf:originals] mutableCopy];
		[self role:@"sp_t4_tmp" in:draft].name = quote;
		SPPostgresRole *rep = [SPPostgresRole roleWithName:sales];
		rep.canLogin = YES;
		rep.newPassword = SPRolesTestPassword;
		rep.memberOf = @{quote: @YES};
		[draft addObject:rep];
		NSArray *statements = [self apply:roles originals:originals edited:draft];
		XCTAssertEqualObjects(statements.firstObject, @"ALTER ROLE \"sp_t4_tmp\" RENAME TO \"sp_t4_a\"\"b\"");
		XCTAssertEqualObjects(statements.lastObject, @"GRANT \"sp_t4_a\"\"b\" TO \"sp_t4_Sales Rep\" WITH ADMIN OPTION");
		for (NSString *sql in recorder.statements) XCTAssertFalse([sql containsString:SPRolesTestPassword]);

		NSArray *reread = [self rolesOf:roles];
		XCTAssertTrue([self role:sales in:reread].canLogin, @"%@", port);
		XCTAssertEqualObjects([self role:sales in:reread].memberOf, @{quote: @YES});
		XCTAssertEqualObjects([self role:quote in:reread].members, @{sales: @YES});
		XCTAssertNil([self role:@"sp_t4_tmp" in:reread]);
		XCTAssertNotNil([self loginOn:port user:sales password:SPRolesTestPassword], @"%@", port);

		// Rename the group: the membership follows, though the member's draft still names the old group
		draft = [[self draftOf:reread] mutableCopy];
		[self role:quote in:draft].name = @"sp_t4_user";
		XCTAssertEqualObjects([self apply:roles originals:reread edited:draft], (@[@"ALTER ROLE \"sp_t4_a\"\"b\" RENAME TO \"sp_t4_user\""]));
		reread = [self rolesOf:roles];
		XCTAssertEqualObjects([self role:sales in:reread].memberOf, @{@"sp_t4_user": @YES}, @"%@", port);
		XCTAssertNil([self role:quote in:reread]);

		// Rename the member and set its password again (hashed for the new name)
		draft = [[self draftOf:reread] mutableCopy];
		[self role:sales in:draft].name = @"sp_t4_Rep 2";
		[self role:@"sp_t4_Rep 2" in:draft].newPassword = SPRolesTestPassword;
		[self apply:roles originals:reread edited:draft];
		XCTAssertNotNil([self loginOn:port user:@"sp_t4_Rep 2" password:SPRolesTestPassword], @"%@", port);
		reread = [self rolesOf:roles];
		XCTAssertEqualObjects([self role:@"sp_t4_user" in:reread].members, @{@"sp_t4_Rep 2": @YES});

		// 64 bytes: refused before anything is sent
		NSString *tooLong = [@"sp_t4_" stringByPaddingToLength:64 withString:@"x" startingAtIndex:0];
		XCTAssertEqual([tooLong lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 64u);
		draft = [[self draftOf:reread] mutableCopy];
		[draft addObject:[SPPostgresRole roleWithName:tooLong]];
		NSUInteger sent = recorder.statements.count;
		NSError *error = nil;
		XCTAssertNil([roles statementsForOriginalRoles:reread edited:draft error:&error]);
		XCTAssertNotNil(error);
		draft = [[self draftOf:reread] mutableCopy];
		[self role:@"sp_t4_user" in:draft].name = tooLong;
		XCTAssertNil([roles statementsForOriginalRoles:reread edited:draft error:&error]);
		XCTAssertEqual(recorder.statements.count, sent, @"nothing sent");
	}
}

@end
