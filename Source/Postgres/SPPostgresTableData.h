#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Quotes a PostgreSQL identifier: wraps it in double quotes and doubles any embedded double quote.
extern NSString *SPPostgresQuoteIdentifier(NSString *identifier) __attribute__((visibility("default")));

/// One column of a table or view, as described by pg_attribute.
__attribute__((visibility("default")))
@interface SPPostgresColumn : NSObject
{
	NSString *_name;
	NSString *_typeName;
	NSString *_castTypeName;
	NSString *_defaultExpression;
	NSInteger _primaryKeyPosition;
	BOOL _nullable;
	BOOL _isGenerated;
}

@property (readonly, copy) NSString *name;
/// format_type(atttypid, atttypmod), e.g. @"numeric(20,6)" or @"text[]".
@property (readonly, copy) NSString *typeName;
/// format_type(atttypid, NULL): the type without its modifier, used to cast parameters. Casting to it (rather
/// than to typeName) leaves the modifier to the assignment, which errors instead of silently truncating
/// (an explicit ::varchar(3) cast truncates).
@property (readonly, copy) NSString *castTypeName;
@property (readonly) BOOL nullable;
/// The column default as SQL text, or nil if there is none (generated columns have none).
@property (readonly, copy) NSString *defaultExpression;
@property (readonly) BOOL isPrimaryKey;
/// 1-based position in the primary key, 0 if the column is not part of it.
@property (readonly) NSInteger primaryKeyPosition;
/// YES for identity ALWAYS columns and generated columns.
@property (readonly) BOOL isGenerated;

@end

/// One condition of the Content view's filter bar.
__attribute__((visibility("default")))
@interface SPPostgresFilter : NSObject
{
	NSString *_column;
	NSString *_operator;
	NSString *_value;
}

+ (instancetype)filterWithColumn:(NSString *)column operator:(NSString *)op value:(NSString *)value;

@property (readwrite, copy) NSString *column;
/// One of @"=", @"≠" (sent as <>), @">", @"<", @">=", @"<=", @"LIKE", @"NOT LIKE", @"ILIKE",
/// @"IS NULL", @"IS NOT NULL", @"IN".
@property (readwrite, copy) NSString *operator;
/// The value, sent as a parameter (ignored for IS NULL / IS NOT NULL). For IN, a comma-separated list whose
/// items (trimmed of surrounding whitespace) are sent as separate parameters.
@property (readwrite, copy) NSString *value;

@end

/**
 * Data access for the Content view of one table or view.
 *
 * Values are read as PostgreSQL text ("col"::text) and written as text parameters cast to the column type
 * ($n::<type>), so every type displays in Postgres's own format and round-trips exactly. Identifiers are
 * always quoted and values always sent as parameters. Rows are NSArrays of NSString, or NSNull for SQL NULL,
 * in column (attnum) order.
 *
 * Rows can be changed only when the relation is a table (or partitioned table) with a primary key; edits
 * identify the row by its full primary key, so an UPDATE or DELETE can never match more than one row.
 * The column list is read once and cached.
 *
 * Errors use SPPostgresErrorDomain: SPPostgresErrorQueryFailed (the server's message), SPPostgresErrorNotEditable
 * (refused before any SQL is sent) and SPPostgresErrorRowChanged (an edit matched no row).
 */
__attribute__((visibility("default")))
@interface SPPostgresTableData : NSObject
{
	PGPostgresConnection *_connection;
	NSString *_schema;
	NSString *_table;
	NSArray *_columns;
	NSString *_relationKind;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table;

@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;

/// SPPostgresColumn objects in attnum order (dropped columns excluded), or nil on failure.
- (NSArray *)columns:(NSError **)error;

/// YES when the relation is a table or partitioned table with a primary key.
- (BOOL)isEditable;

/// Why the rows can't be edited, or nil when they can.
- (NSString *)readOnlyReason;

/// A page of rows. column may be nil for no explicit sort; rows are then in primary-key order (if any), and the
/// primary key also breaks ties after the sort column, so paging is stable. filter may be nil.
- (NSArray *)rowsWithFilter:(SPPostgresFilter *)filter sortColumn:(NSString *)column ascending:(BOOL)ascending
					 offset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError **)error;

/// Exact count(*) of the rows matching filter (nil for all), or -1 on failure.
- (NSInteger)countRowsWithFilter:(SPPostgresFilter *)filter error:(NSError **)error;

/// Sets one column of the row identified by originalRow's primary-key values. value is an NSString or NSNull.
/// Fails with SPPostgresErrorRowChanged when no row matched.
- (BOOL)updateRow:(NSArray *)originalRow column:(NSString *)column value:(id)value error:(NSError **)error;

/// Inserts a row; columns missing from valuesByColumn (name -> NSString/NSNull) get their defaults.
/// Returns the inserted row (via RETURNING) in the same format as -rowsWithFilter:…, or nil on failure.
- (NSArray *)insertRowWithValues:(NSDictionary *)valuesByColumn error:(NSError **)error;

/// Deletes the rows (as returned by -rowsWithFilter:…) by primary key, in one transaction. If any row is
/// already gone, nothing is deleted and the error is SPPostgresErrorRowChanged.
- (BOOL)deleteRows:(NSArray *)rows error:(NSError **)error;

@end
