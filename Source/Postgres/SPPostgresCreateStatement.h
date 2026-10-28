#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * The SQL that creates a table or view as it is now, as the Table Info view's "Create syntax" shows it (MySQL's
 * SHOW CREATE TABLE has no PostgreSQL counterpart). Statements end with `;` and are separated by blank lines.
 * Every name the statement writes itself is quoted (SPPostgresQuoteIdentifier); the server's own parts
 * (pg_get_constraintdef, pg_get_indexdef, pg_get_triggerdef, pg_get_viewdef, pg_get_expr, format_type) are read
 * with an empty search_path, so they qualify every name outside pg_catalog and the result runs from any
 * search_path.
 *
 * A table (also unlogged, partitioned, a partition, an inheritance child, or a foreign table):
 *   CREATE TABLE "s"."t" (
 *       one line per column, in attnum order: the quoted name, format_type, COLLATE when the collation isn't the
 *       type's default, then GENERATED ALWAYS AS (expr) STORED (VIRTUAL on PostgreSQL 18), GENERATED ALWAYS | BY
 *       DEFAULT AS IDENTITY, or DEFAULT expr, then NOT NULL;
 *       one CONSTRAINT "n" <pg_get_constraintdef> line per primary key, unique, check, foreign key and exclusion
 *       constraint (PostgreSQL 18's NOT NULL constraints, contype 'n', are the columns' NOT NULL);
 *   )
 *   then INHERITS ("s"."parent", …) for an inheritance child (whose inherited columns and constraints come from
 *   its parents and are left out), PARTITION BY <pg_get_partkeydef> for a partitioned table, WITH (reloptions).
 *   A partition is not written as an inheritance child but as CREATE TABLE "s"."p" PARTITION OF "s"."parent"
 *   [(its own constraints)] <pg_get_expr(relpartbound)> (FOR VALUES … or DEFAULT): its columns, constraints,
 *   indexes and triggers that come from the parent are left out.
 * Then:
 *   - a constraint that isn't validated, as ALTER TABLE … ADD CONSTRAINT … NOT VALID;
 *   - one pg_get_indexdef statement per index that backs no constraint (and isn't a partition's copy of its
 *     parent's index);
 *   - COMMENT ON TABLE and COMMENT ON COLUMN;
 *   - one pg_get_triggerdef statement per trigger that isn't internal (nor a partition's copy of its parent's),
 *     followed by ALTER TABLE … DISABLE TRIGGER (or ENABLE REPLICA / ALWAYS TRIGGER) when it isn't enabled as
 *     the default.
 *
 * A serial column appears as its DEFAULT nextval('…'::regclass): no sequence DDL is written (nor an identity
 * column's sequence options), so the statement runs as is only while that sequence exists.
 *
 * A view: CREATE VIEW "s"."v" AS <pg_get_viewdef(oid, true)> (with its options and CHECK OPTION); a materialized
 * view: CREATE MATERIALIZED VIEW "s"."m" AS <definition> (WITH NO DATA when it isn't populated) and its
 * indexes. Either is followed by its comments and triggers.
 *
 * Reads run as SPPostgresRunAtomically does (a savepoint inside the user's transaction), so the session is left as
 * it was; inside an aborted transaction it fails without sending anything. Use on the connection's thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresCreateStatement : NSObject

/// The statement, or nil on failure (SPPostgresErrorDomain; e.g. no such table, or not a table or view).
+ (NSString *)createStatementForTable:(NSString *)table inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error;

@end
