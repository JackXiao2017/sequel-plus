#import <Foundation/Foundation.h>

@class PGPostgresConnection;
@class PGPostgresResult;

/// Whether a cell of a Query-tab result can be edited, and if not, why.
typedef NS_ENUM(NSInteger, SPPostgresCellEditability) {
	SPPostgresCellEditable = 0,            // exactly one row matches
	SPPostgresCellNoOrigin,                // MySQL's -1: expression, no single table
	SPPostgresCellNoMatch,                 // MySQL's 0
	SPPostgresCellTooManyMatches,          // MySQL's >1
	SPPostgresCellNotATable,               // view, materialized view, foreign table…
	SPPostgresCellGeneratedColumn,         // GENERATED … STORED or GENERATED ALWAYS identity
	SPPostgresCellCheckFailed,             // catalog lookup, plan or count failed (aborted transaction, lost connection)
	SPPostgresCellOriginRepeated,          // the origin table is read more than once by the statement (a self-join)
	SPPostgresCellOuterJoinMissingRow      // the plan has an outer join and the row's values of the origin are all NULL
};

/**
 * One result of the Query tab, made editable cell by cell as MySQL's rule (SPCustomQuery's
 * fieldEditStatusForRow:andColumn:) does: a cell is editable when its column is a plain column of a table, and the
 * row's values in every result column of that table (keys and non-keys, every occurrence) match exactly one row of
 * it.
 *
 * PostgreSQL reports a field's table and column but not its alias, so in a self-join the values of one alias can
 * identify a row of the other, or a row of neither. Such results are refused before any count
 * (SPPostgresCellOriginRepeated): the statement's plan (EXPLAIN (VERBOSE, FORMAT JSON): the statement is planned,
 * not executed, though planning takes its locks and may evaluate immutable or stable functions) must read the origin
 * table, counting its partitions and inheritance children, at most once. One read is one scan, or one Append of
 * scans, or one CTE Scan of a WITH query that itself reads the table once; a WITH query's columns report its table
 * as their origin, so a WITH query scanned twice (a self-join through it, at any nesting) counts as two reads, and so
 * does a recursive WITH query's reference to itself. This is conservative: a subquery on the same table (WHERE id IN
 * (SELECT … FROM the same table)) also refuses it. Comparing every column of the table is defence in depth on top of
 * that, and also refuses an edit once another shown column of its row has changed.
 *
 * An outer join NULL-extends the rows it finds no match for: every column of the missing table shows NULL, and
 * comparing them ("c" IS NULL …) would identify a real row of it. So when the plan has a Left, Right or Full join, a
 * cell whose row shows NULL in every column of its origin table is refused before any count
 * (SPPostgresCellOuterJoinMissingRow), also a real row that looks the same.
 *
 * The origin tables' columns, their partitions/children and the statement's plan (its reads and whether it has an
 * outer join) are read once per editor (a failed lookup, including a plan whose WITH query can't be found, that uses
 * an extension's Custom Scan naming no relation, which may hide reads, or that is too large to walk, is
 * SPPostgresCellCheckFailed and retried on the next check).
 * Reads run through SPPostgresRunGuardedRead, so inside the user's open transaction a failure leaves it open.
 * Identifiers are quoted and values sent as parameters.
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryResultEditor : NSObject
{
	PGPostgresResult *_result;
	PGPostgresConnection *_connection;
	NSString *_statement;
	NSDictionary *_tables;          // origin OID (NSNumber) -> table info
	NSSet *_repeatedOrigins;        // origin OIDs (NSNumber) the statement's plan reads more than once
	BOOL _hasOuterJoin;             // the statement's plan has a Left, Right or Full join
	NSMutableDictionary *_edits;    // NSIndexPath (row, column) -> saved value (NSString / NSNull)
}

/// statement is the SQL that produced result, as it was run (its plan decides which tables are read more than once).
- (instancetype)initWithResult:(PGPostgresResult *)result connection:(PGPostgresConnection *)connection statement:(NSString *)statement;

@property (readonly) PGPostgresResult *result;

/// The reads of relations in a parsed EXPLAIN (FORMAT JSON) plan (the array NSJSONSerialization gives), each
/// @[schema, relation, group]: scans with equal groups are one read (the children of one Append; see the class
/// comment for reads through a WITH query, whose plan is expanded again for each scan of it). nil with error when the
/// plan reads a WITH query it doesn't contain, uses an extension's Custom Scan that names no relation (which may hide
/// reads), or takes more than 10,000 node visits to walk ("This query is too complex to check which rows it shows.").
/// Used by the check; exposed for tests.
+ (NSArray *)readsInPlan:(id)explained error:(NSError **)error;

/// Whether a parsed EXPLAIN (FORMAT JSON) plan has an outer join anywhere ("Join Type" Left, Right or Full), whose
/// NULL-extended rows show NULL for every column of a table they have no row of. Exposed for tests.
+ (BOOL)planHasOuterJoin:(id)explained;

- (NSUInteger)rowCount;
- (NSUInteger)columnCount;

/// The cell's text (NSString) or NSNull, with this editor's saved edits applied.
- (id)valueAtRow:(NSUInteger)row column:(NSUInteger)column;

/// Checks the cell (catalog lookup and plan once per editor, then a count). matchCount is the count (or -1 when not counted);
/// message is the explanation to show when not editable (MySQL's text for NoOrigin/NoMatch/TooManyMatches), else nil.
- (SPPostgresCellEditability)editabilityOfRow:(NSUInteger)row column:(NSUInteger)column
								   matchCount:(NSInteger *)matchCount message:(NSString **)message;

/// For the field editor sheet: the origin column's type (format_type, typmod -1) or nil; nullable is YES when unknown.
- (NSString *)typeNameOfColumn:(NSUInteger)column;
- (BOOL)columnIsNullable:(NSUInteger)column;

/// "schema"."table" of the column's origin, quoted, or nil.
- (NSString *)qualifiedTableNameOfColumn:(NSUInteger)column;

/// Sets the cell's origin column in the one row the cell's values identify. value: NSString or NSNull. On success the
/// server's text of the new value (NSString or NSNull) replaces the cell, and every result column of the same origin
/// column in that row, and is returned. On failure nil; matchCount (if given) is the rows the UPDATE matched when that
/// was not 1, else -1.
///
/// The UPDATE (identified as -editabilityOfRow:column:matchCount:message: counts, with this editor's saved edits
/// applied) runs through SPPostgresRunAtomically and is undone unless it changed exactly one row
/// (SPPostgresErrorRowChanged). A cell refused before counting (no origin, not a table, generated, table read more
/// than once, an outer join's possibly missing row, catalog lookup or plan failed) fails with
/// SPPostgresErrorNotEditable and the same message, without an UPDATE.
- (id)saveValue:(id)value row:(NSUInteger)row column:(NSUInteger)column matchCount:(NSInteger *)matchCount error:(NSError **)error;

@end
