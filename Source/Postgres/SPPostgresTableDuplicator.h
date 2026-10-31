#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * Duplicate Table… for PostgreSQL: copies a table's structure, and optionally its rows, to a new table in
 * the same schema.
 */
__attribute__((visibility("default")))
@interface SPPostgresTableDuplicator : NSObject

/// YES for a name PostgreSQL keeps as given: not empty and at most 63 bytes in UTF-8 (NAMEDATALEN - 1); longer
/// names would be silently truncated by the server.
+ (BOOL)isValidTableName:(NSString *)name;

/**
 * Creates "schema"."newName" as a copy of "schema"."table", all or nothing:
 *
 * - CREATE TABLE … (LIKE … INCLUDING ALL): columns, defaults, NOT NULL and CHECK constraints, indexes
 *   (with the primary key and unique constraints), identity columns (with new sequences), generated
 *   columns, comments, storage and statistics, and then the table's own comment. Foreign keys, triggers,
 *   policies, grants, inheritance and UNLOGGED are not copied (LIKE doesn't).
 * - serial columns (a default of nextval() on a sequence the column owns) get a sequence of their own,
 *   named <newName>_<column>_seq (or with a number added if that name is taken), owned by the new column.
 * - withContent: the table's own rows are copied, not those of tables inheriting from it (generated columns are computed again; identity ALWAYS values are
 *   kept with OVERRIDING SYSTEM VALUE), and the copy's serial and identity sequences continue from the
 *   original's.
 *
 * The connection may be in the user's open transaction (it is shared with the Query view): then a savepoint
 * is used and the transaction stays open; in an aborted transaction nothing is done. Views and partitioned
 * tables are refused, and so is a newName longer than 63 bytes (see +isValidTableName:). On failure everything is undone and NO is returned with the server's message
 * (SPPostgresErrorDomain, SPPostgresErrorQueryFailed).
 */
+ (BOOL)duplicateTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName withContent:(BOOL)withContent
			connection:(PGPostgresConnection *)connection error:(NSError **)error;

@end
