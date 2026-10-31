#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * One login or group role, as pg_roles describes it: a snapshot as read (-[SPPostgresRoles roles:]) and, once
 * copied, the Users sheet's draft of what it should become. originalName is nil for a role not yet created.
 *
 * memberOf and members map role names to @(adminOption). In a draft they use the roles' current (draft) names;
 * a role renamed in the same draft is referred to by its new name.
 */
__attribute__((visibility("default")))
@interface SPPostgresRole : NSObject <NSCopying>
{
	NSString *_name;
	NSString *_originalName;
	BOOL _canLogin;
	BOOL _inherit;
	BOOL _superuser;
	BOOL _createDB;
	BOOL _createRole;
	BOOL _replication;
	BOOL _bypassRLS;
	NSInteger _connectionLimit;
	NSDate *_validUntil;
	NSString *_newPassword;
	BOOL _clearPassword;
	NSDictionary *_memberOf;
	NSDictionary *_members;
	BOOL _markedForDeletion;
	BOOL _hasMD5Password;
}

/// A new role (originalName nil) with the server's CREATE ROLE defaults: NOLOGIN INHERIT, every other attribute
/// off, no connection limit, valid forever.
+ (instancetype)roleWithName:(NSString *)name;

@property (readwrite, copy) NSString *name;
/// The name on the server; nil for a role not yet created.
@property (readwrite, copy) NSString *originalName;
@property (readwrite) BOOL canLogin;
@property (readwrite) BOOL inherit;
@property (readwrite) BOOL superuser;
@property (readwrite) BOOL createDB;
@property (readwrite) BOOL createRole;
@property (readwrite) BOOL replication;
@property (readwrite) BOOL bypassRLS;
/// -1 means unlimited.
@property (readwrite) NSInteger connectionLimit;
/// nil means never expires (the server's 'infinity').
@property (readwrite, copy) NSDate *validUntil;
/// The password to set; nil or empty means unchanged. Never read from the server.
@property (readwrite, copy) NSString *newPassword;
/// Declared so the getter isn't taken for a "new" method returning an owned object (by ARC callers too).
- (NSString *)newPassword __attribute__((objc_method_family(none)));
/// YES sends PASSWORD NULL (and newPassword is ignored).
@property (readwrite) BOOL clearPassword;
/// Group name → @(BOOL adminOption): the roles this role is a member of.
@property (readwrite, copy) NSDictionary *memberOf;
/// Member name → @(BOOL adminOption): the roles that are members of this role.
@property (readwrite, copy) NSDictionary *members;
@property (readwrite) BOOL markedForDeletion;
/// YES when -[SPPostgresRoles roles:] found an MD5 password stored for the role (pg_authid.rolpassword). The server
/// clears such a password when the role is renamed. NO when pg_authid can't be read, and for a new role.
@property (readonly) BOOL hasMD5Password;

/// YES for a role that can't log in.
- (BOOL)isGroup;

@end

/**
 * Runs statements in a transaction of their own on connection: BEGIN, each statement (in order), COMMIT; on the
 * first failure ROLLBACK, and NO with the server's message followed by its DETAIL and HINT lines
 * (SPPostgresExecuteWithDetails). An empty list sends nothing and succeeds. Meant for a dedicated connection: when
 * it is already inside a transaction nothing is sent and it fails.
 */
extern BOOL SPPostgresApplyInTransaction(PGPostgresConnection *connection, NSArray *statements, NSError **error) __attribute__((visibility("default")));

/**
 * Reads the cluster's roles and memberships and turns a draft of them into SQL, for the Users sheet. Runs on a
 * connection of its own (never the document's). Identifiers are quoted with SPPostgresQuoteIdentifier; passwords
 * are hashed client-side (-[PGPostgresConnection encryptedPassword:forRole:]) and never sent in plain text. Never
 * cascades. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresRoles : NSObject
{
	PGPostgresConnection *_connection;
	NSDictionary *_grantorsByPair;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// Every role but the predefined pg_* ones, sorted by name, with memberOf and members filled in (pg_auth_members),
/// as SPPostgresRole objects; nil on failure. Also records each membership's grantors, used by
/// -statementsForOriginalRoles:edited:error: to revoke memberships on PostgreSQL 16+.
- (NSArray *)roles:(NSError **)error;

/// Every role name, pg_* included (what "Member of" can offer), sorted; nil on failure.
- (NSArray *)allRoleNames:(NSError **)error;

/// session_user, or nil when it can't be read.
- (NSString *)sessionRoleName;

/**
 * The SQL that turns originals (as -roles: returned them) into edited (copies, possibly changed, plus new roles
 * with a nil originalName), in run order:
 *   1. DROP ROLE for each role markedForDeletion;
 *   2. ALTER ROLE … RENAME TO … for each renamed role;
 *   3. CREATE ROLE … WITH <every attribute> CONNECTION LIMIT n VALID UNTIL '…' [PASSWORD '<hash>'] for new roles;
 *   4. one ALTER ROLE … WITH <only what changed> per changed role (attributes, connection limit, valid until,
 *      PASSWORD '<hash>' or PASSWORD NULL);
 *   5. membership revokes: REVOKE g FROM m (on 16+, one per grantor: … GRANTED BY grantor), or REVOKE ADMIN
 *      OPTION FOR g FROM m when only the admin option is dropped;
 *   6. membership grants: GRANT g TO m [WITH ADMIN OPTION].
 * Memberships are diffed per (member, group) pair from both memberOf and members; pairs with a deleted role are
 * left to DROP ROLE. Roles missing from edited are unchanged. Valid until is written as 'infinity' or an ISO 8601
 * timestamp with its UTC offset. Fails (nil) on an invalid name (empty or over 63 bytes), a duplicate name, an
 * edited role whose original is unknown, conflicting edits of one membership, or a password that couldn't be
 * hashed. Pure apart from hashing.
 */
- (NSArray *)statementsForOriginalRoles:(NSArray *)originals edited:(NSArray *)edited error:(NSError **)error;

/// SPPostgresApplyInTransaction on this object's connection.
- (BOOL)applyStatements:(NSArray *)statements error:(NSError **)error;

@end
