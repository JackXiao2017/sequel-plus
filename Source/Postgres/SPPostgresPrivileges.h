#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * One object's privileges for one role, as the Users sheet's Privileges tab shows them: a snapshot as read
 * (-[SPPostgresPrivileges privilegesForRole:…]) and, once copied, the sheet's draft (only granted changes).
 *
 * kind is one of @"database", @"schema", @"table", @"view", @"materialized view", @"foreign table", @"sequence",
 * @"function" (functions and procedures), @"default tables", @"default sequences", @"default functions".
 * For a database, name is the database (schema nil); for a schema, schema and name are both the schema. For a
 * function, name is "f(<identity args>)" for display and signature holds the identity args. For the three default
 * kinds, name is the display text ("Tables created later", "Sequences created later", "Functions created later").
 */
__attribute__((visibility("default")))
@interface SPPostgresPrivilegeObject : NSObject <NSCopying>
{
	NSString *_kind;
	NSString *_schema;
	NSString *_name;
	NSString *_signature;
	NSArray *_availablePrivileges;
	NSSet *_granted;
	NSSet *_grantable;
}

/// The privileges a kind offers, in the order the sheet shows and statements write them: database CONNECT, CREATE,
/// TEMP; schema USAGE, CREATE; every table-like kind SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER;
/// sequence USAGE, SELECT; function EXECUTE; the default kinds as their object kinds. Empty for an unknown kind.
+ (NSArray *)availablePrivilegesForKind:(NSString *)kind;

/// granted and grantable are limited to the kind's available privileges (nil means none).
- (instancetype)initWithKind:(NSString *)kind schema:(NSString *)schema name:(NSString *)name signature:(NSString *)signature
					 granted:(NSSet *)granted grantable:(NSSet *)grantable;

@property (readonly, copy) NSString *kind;
@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *name;
/// A function's identity arguments (pg_get_function_identity_arguments); nil for other kinds.
@property (readonly, copy) NSString *signature;
@property (readonly, copy) NSArray *availablePrivileges;
/// The privileges held directly (an owner's implicit ones included); editable in a draft.
@property (readwrite, copy) NSSet *granted;
/// The privileges held WITH GRANT OPTION (shown, not edited).
@property (readonly, copy) NSSet *grantable;

@end

/**
 * Reads one role's direct privileges in one database (the connection's) and turns a draft of them into GRANT /
 * REVOKE / ALTER DEFAULT PRIVILEGES statements. Only grants made to the role itself are shown, read with
 * aclexplode(coalesce(acl, acldefault(kind, owner))) so an owner shows its implicit privileges; inherited and
 * superuser rights are not. A role that doesn't exist yet reads as holding nothing. Identifiers are quoted with
 * SPPostgresQuoteIdentifier. Never cascades. Use on the main thread, on a connection of its own.
 */
__attribute__((visibility("default")))
@interface SPPostgresPrivileges : NSObject
{
	PGPostgresConnection *_connection;
}

/// connection is to the database being edited.
- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// One object of kind @"database" for the named database; nil on failure (or when there is no such database).
- (NSArray *)databasePrivilegesForRole:(NSString *)role database:(NSString *)database error:(NSError **)error;

/**
 * The schema's row, then its tables (partitioned ones included), views, materialized views and foreign tables, then
 * its sequences, then its functions and procedures (aggregates and window functions excluded), each kind sorted by
 * name, then the three default rows (pg_default_acl, no acldefault fallback) for objects creator makes later in the
 * schema. A nil creator gives empty default rows. nil on failure (or when there is no such schema).
 */
- (NSArray *)privilegesForRole:(NSString *)role schema:(NSString *)schema defaultsCreator:(NSString *)creator error:(NSError **)error;

/// The schema's owner (the default creator for default privileges); nil on failure.
- (NSString *)ownerOfSchema:(NSString *)schema error:(NSError **)error;

/**
 * The SQL that turns originals into edited, matched by kind, schema and name (an edited object missing from
 * originals counts as holding nothing; originals missing from edited are unchanged). Per object, in edited's order:
 * one GRANT of what was added, then one REVOKE of what was removed, privileges in the kind's order:
 *   GRANT p, … ON DATABASE|SCHEMA|TABLE|SEQUENCE|ROUTINE <object> TO <role>   (TABLE for every table-like kind;
 *     ROUTINE "s"."f"(<identity args>));
 *   ALTER DEFAULT PRIVILEGES FOR ROLE <creator> IN SCHEMA <s> GRANT p, … ON TABLES|SEQUENCES|FUNCTIONS TO <role>
 *     (REVOKE … FROM <role>); skipped when creator is nil.
 * Pure.
 */
+ (NSArray *)statementsForRole:(NSString *)role original:(NSArray *)originals edited:(NSArray *)edited defaultsCreator:(NSString *)creator;

/// SPPostgresApplyInTransaction on this object's connection.
- (BOOL)applyStatements:(NSArray *)statements error:(NSError **)error;

@end
