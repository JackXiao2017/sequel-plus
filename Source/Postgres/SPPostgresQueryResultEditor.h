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
	SPPostgresCellCheckFailed              // catalog lookup or count failed (aborted transaction, lost connection)
};

/**
 * One result of the Query tab, made editable cell by cell with MySQL's rule (SPCustomQuery's
 * fieldEditStatusForRow:andColumn:): a cell is editable when its column is a plain column of a table, and the row's
 * identifying values (the table's primary-key columns present in the result, or else every result column of that
 * table) match exactly one row of it.
 *
 * The origin tables' columns are read from the catalog once per editor (one query for all of them; a failed lookup is
 * retried on the next check). Reads run through SPPostgresRunGuardedRead, so inside the user's open transaction a
 * failure leaves it open. Identifiers are quoted and values sent as parameters.
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryResultEditor : NSObject
{
	PGPostgresResult *_result;
	PGPostgresConnection *_connection;
	NSDictionary *_tables;          // origin OID (NSNumber) -> table info
	NSMutableDictionary *_edits;    // NSIndexPath (row, column) -> saved value (NSString / NSNull)
}

- (instancetype)initWithResult:(PGPostgresResult *)result connection:(PGPostgresConnection *)connection;

@property (readonly) PGPostgresResult *result;

- (NSUInteger)rowCount;
- (NSUInteger)columnCount;

/// The cell's text (NSString) or NSNull, with this editor's saved edits applied.
- (id)valueAtRow:(NSUInteger)row column:(NSUInteger)column;

/// Checks the cell (catalog lookup once per editor, then a count). matchCount is the count (or -1 when not counted);
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
/// (SPPostgresErrorRowChanged). A cell refused before counting (no origin, not a table, generated, catalog lookup
/// failed) fails with SPPostgresErrorNotEditable and the same message, without an UPDATE.
- (id)saveValue:(id)value row:(NSUInteger)row column:(NSUInteger)column matchCount:(NSInteger *)matchCount error:(NSError **)error;

@end
