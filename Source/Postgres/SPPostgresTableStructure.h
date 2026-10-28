#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * Runs body, a structure change (DDL), as SPPostgresRunAtomically does with the savepoint `sp_structure`, with the
 * session's lock_timeout set to lockTimeout seconds (0 or less: no limit) while it runs, so that a lock held
 * elsewhere gives an error rather than a wait without end. lock_timeout is back to its previous value afterwards,
 * whether body succeeds or fails: it is set inside the transaction or savepoint, restored there before a
 * successful finish, and undone with it on failure, so the restore never ends or aborts the user's transaction.
 * Inside an aborted transaction nothing is sent and it fails with a message saying to roll it back.
 */
extern BOOL SPPostgresRunStructureChange(PGPostgresConnection *connection, NSTimeInterval lockTimeout, BOOL (^body)(NSError **error),
										 NSError **error) __attribute__((visibility("default")));

/// One column of a table or view, as the Structure view shows it.
__attribute__((visibility("default")))
@interface SPPostgresStructureColumn : NSObject
{
	NSString *_name;
	NSString *_typeName;
	BOOL _nullable;
	NSString *_defaultExpression;
	NSString *_autoKind;
	NSString *_generationExpression;
	NSString *_comment;
	NSInteger _attnum;
}

@property (readonly, copy) NSString *name;
/// format_type(atttypid, atttypmod), e.g. @"numeric(10,2)".
@property (readonly, copy) NSString *typeName;
@property (readonly) BOOL nullable;
/// pg_get_expr of the default, nil if there is none (identity and generated columns have none).
@property (readonly, copy) NSString *defaultExpression;
/// @"" (none), @"serial" (the default is nextval of a sequence owned by this column), @"identity" (BY DEFAULT),
/// @"identity always" or @"generated".
@property (readonly, copy) NSString *autoKind;
/// The expression of a generated column, nil otherwise.
@property (readonly, copy) NSString *generationExpression;
/// nil if none.
@property (readonly, copy) NSString *comment;
@property (readonly) NSInteger attnum;

@end

/// One index of a table.
__attribute__((visibility("default")))
@interface SPPostgresIndex : NSObject
{
	NSString *_name;
	NSString *_definition;
	NSArray *_columns;
	NSString *_method;
	BOOL _isUnique;
	BOOL _isPrimary;
	NSString *_constraintName;
}

@property (readonly, copy) NSString *name;
/// pg_get_indexdef.
@property (readonly, copy) NSString *definition;
/// The key columns' names (or expression text), in order.
@property (readonly, copy) NSArray *columns;
/// The access method: @"btree", @"hash", @"gist", @"gin", @"brin", …
@property (readonly, copy) NSString *method;
@property (readonly) BOOL isUnique;
@property (readonly) BOOL isPrimary;
/// The constraint the index backs (primary key, unique, exclusion), nil if none.
@property (readonly, copy) NSString *constraintName;

@end

/// One constraint of a table: primary key, unique, check, foreign key or exclusion (NOT NULL is shown per column).
__attribute__((visibility("default")))
@interface SPPostgresConstraint : NSObject
{
	NSString *_name;
	NSString *_kind;
	NSString *_definition;
	NSArray *_columns;
	NSString *_referencedSchema;
	NSString *_referencedTable;
	NSArray *_referencedColumns;
	NSString *_onUpdate;
	NSString *_onDelete;
}

@property (readonly, copy) NSString *name;
/// @"PRIMARY KEY", @"UNIQUE", @"CHECK", @"FOREIGN KEY" or @"EXCLUDE".
@property (readonly, copy) NSString *kind;
/// pg_get_constraintdef.
@property (readonly, copy) NSString *definition;
/// The constrained columns' names, in order (empty for a CHECK that names no column).
@property (readonly, copy) NSArray *columns;
/// Foreign keys only (nil otherwise).
@property (readonly, copy) NSString *referencedSchema;
@property (readonly, copy) NSString *referencedTable;
@property (readonly, copy) NSArray *referencedColumns;
/// Foreign keys only: @"NO ACTION", @"RESTRICT", @"CASCADE", @"SET NULL" or @"SET DEFAULT".
@property (readonly, copy) NSString *onUpdate;
@property (readonly, copy) NSString *onDelete;

@end

/// One trigger of a table (internal ones, e.g. a foreign key's, are left out).
__attribute__((visibility("default")))
@interface SPPostgresTrigger : NSObject
{
	NSString *_name;
	NSString *_timing;
	NSString *_events;
	NSString *_level;
	NSString *_functionSchema;
	NSString *_functionName;
	NSString *_condition;
	BOOL _enabled;
	NSString *_definition;
	NSString *_functionDefinition;
}

@property (readonly, copy) NSString *name;
/// @"BEFORE", @"AFTER" or @"INSTEAD OF".
@property (readonly, copy) NSString *timing;
/// As pg_get_triggerdef writes them, between the timing and ON, e.g. @"INSERT OR UPDATE OF \"code\"".
@property (readonly, copy) NSString *events;
/// @"ROW" or @"STATEMENT".
@property (readonly, copy) NSString *level;
@property (readonly, copy) NSString *functionSchema;
@property (readonly, copy) NSString *functionName;
/// The WHEN condition as pg_get_triggerdef writes it (without its enclosing parentheses), nil if none.
@property (readonly, copy) NSString *condition;
/// tgenabled <> 'D' (enabled, also when it fires only as replica or always).
@property (readonly) BOOL enabled;
/// pg_get_triggerdef.
@property (readonly, copy) NSString *definition;
/// pg_get_functiondef of the trigger function.
@property (readonly, copy) NSString *functionDefinition;

@end

/// A column to add.
__attribute__((visibility("default")))
@interface SPPostgresColumnDefinition : NSObject
{
	NSString *_name;
	NSString *_typeName;
	NSString *_defaultExpression;
	BOOL _notNull;
	NSString *_autoKind;
	NSString *_comment;
}

@property (readwrite, copy) NSString *name;
/// SQL as typed (e.g. @"varchar(20)"), sent as is.
@property (readwrite, copy) NSString *typeName;
/// SQL as typed, sent as is; nil or empty for none.
@property (readwrite, copy) NSString *defaultExpression;
@property (readwrite) BOOL notNull;
/// nil or @"" (none), @"serial", @"identity" (BY DEFAULT) or @"identity always".
@property (readwrite, copy) NSString *autoKind;
/// nil or empty for none.
@property (readwrite, copy) NSString *comment;

@end

/// A constraint to add.
__attribute__((visibility("default")))
@interface SPPostgresConstraintDefinition : NSObject
{
	NSString *_kind;
	NSString *_name;
	NSArray *_columns;
	NSString *_checkExpression;
	NSString *_referencedSchema;
	NSString *_referencedTable;
	NSArray *_referencedColumns;
	NSString *_onUpdate;
	NSString *_onDelete;
}

/// @"PRIMARY KEY", @"UNIQUE", @"CHECK" or @"FOREIGN KEY".
@property (readwrite, copy) NSString *kind;
/// nil lets the server name it.
@property (readwrite, copy) NSString *name;
/// Column names (not for CHECK).
@property (readwrite, copy) NSArray *columns;
/// CHECK only: SQL as typed, sent as is.
@property (readwrite, copy) NSString *checkExpression;
/// FOREIGN KEY only. A nil schema means the table's own; nil or empty columns mean the referenced primary key.
@property (readwrite, copy) NSString *referencedSchema;
@property (readwrite, copy) NSString *referencedTable;
@property (readwrite, copy) NSArray *referencedColumns;
/// FOREIGN KEY only: nil (the server's default, NO ACTION), @"NO ACTION", @"RESTRICT", @"CASCADE", @"SET NULL" or
/// @"SET DEFAULT".
@property (readwrite, copy) NSString *onUpdate;
@property (readwrite, copy) NSString *onDelete;

@end

/**
 * The structure of one table, view, materialized view or foreign table: its columns, indexes and constraints,
 * and the changes the Structure view makes to them.
 *
 * Each change runs at once, through SPPostgresRunStructureChange: all or nothing, with lock_timeout set to
 * lockTimeout, inside the user's transaction (in a savepoint) when one is open, and refused without sending
 * anything inside an aborted one. Identifiers are always quoted; a column type, default, CHECK or USING
 * expression is sent as typed. Nothing is ever dropped with CASCADE. A failed change returns NO with the
 * server's message, followed by its DETAIL and HINT lines.
 *
 * Errors use SPPostgresErrorDomain: SPPostgresErrorQueryFailed (the server's message, or a value refused before
 * sending) and SPPostgresErrorHasDependents (-dropColumn:error:).
 */
__attribute__((visibility("default")))
@interface SPPostgresTableStructure : NSObject
{
	PGPostgresConnection *_connection;
	NSString *_schema;
	NSString *_table;
	NSTimeInterval _lockTimeout;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table;

@property (readonly, copy) NSString *schema;
/// The table's name (updated by -renameTableTo:error:).
@property (readonly, copy) NSString *table;
/// Seconds a change waits for a lock held elsewhere before it fails (default 5; 0 or less waits without limit).
@property (readwrite) NSTimeInterval lockTimeout;

/// SPPostgresStructureColumn objects in attnum order, or nil on failure.
- (NSArray *)columns:(NSError **)error;
/// SPPostgresIndex objects by name (empty for views), or nil on failure.
- (NSArray *)indexes:(NSError **)error;
/// SPPostgresConstraint objects by name (empty for views), or nil on failure.
- (NSArray *)constraints:(NSError **)error;
/// The comment, or nil (with *error unset) when there is none; nil with *error set on failure.
- (NSString *)tableComment:(NSError **)error;
/// @"table", @"partitioned table", @"view", @"materialized view" or @"foreign table"; nil on failure.
- (NSString *)relationKind:(NSError **)error;

/// ADD COLUMN, then COMMENT ON COLUMN when a comment is given. serial needs an integer type (integer, bigint,
/// smallint), which becomes serial / bigserial / smallserial.
- (BOOL)addColumn:(SPPostgresColumnDefinition *)definition error:(NSError **)error;
- (BOOL)renameColumn:(NSString *)column to:(NSString *)newName error:(NSError **)error;
/// ALTER COLUMN … TYPE typeName [USING usingExpression]; usingExpression nil for none.
- (BOOL)changeColumn:(NSString *)column toType:(NSString *)typeName using:(NSString *)usingExpression error:(NSError **)error;
/// nil or empty drops the default.
- (BOOL)setDefault:(NSString *)expression forColumn:(NSString *)column error:(NSError **)error;
- (BOOL)setNullable:(BOOL)nullable forColumn:(NSString *)column error:(NSError **)error;
/// nil or empty removes the comment.
- (BOOL)setComment:(NSString *)comment forColumn:(NSString *)column error:(NSError **)error;
/**
 * What would go with the column if it were dropped: views, indexes, constraints (including foreign keys of
 * other tables that reference it), generated columns, … as pg_describe_object describes them (a view as
 * `view s.v`, not its rule), sorted. The column's own default and the sequence it owns are not listed.
 */
- (NSArray *)dependentsOfColumn:(NSString *)column error:(NSError **)error;
/// Refused (SPPostgresErrorHasDependents, with the list in SPPostgresDependentsErrorKey) when anything depends
/// on the column; nothing is dropped then.
- (BOOL)dropColumn:(NSString *)column error:(NSError **)error;

/// CREATE [UNIQUE] INDEX [name] ON the table USING method (columns). name nil lets the server name it; method is
/// btree (nil), hash, gist, gin or brin.
- (BOOL)addIndexNamed:(NSString *)name columns:(NSArray *)columns unique:(BOOL)unique method:(NSString *)method error:(NSError **)error;
/// Drops the index, or, when it backs a constraint, that constraint.
- (BOOL)dropIndexNamed:(NSString *)name error:(NSError **)error;
- (BOOL)addConstraint:(SPPostgresConstraintDefinition *)definition error:(NSError **)error;
- (BOOL)dropConstraintNamed:(NSString *)name error:(NSError **)error;

/// SPPostgresTrigger objects by name, or nil on failure.
- (NSArray *)triggers:(NSError **)error;
/// The functions a trigger can execute (returning trigger, outside pg_catalog and information_schema), as
/// @"schema.name" with each part quoted when needed, sorted; nil on failure.
- (NSArray *)triggerFunctions:(NSError **)error;
/**
 * CREATE TRIGGER name timing events [OF columns] ON the table FOR EACH level [WHEN (condition)] EXECUTE FUNCTION
 * function(). timing is BEFORE, AFTER or INSTEAD OF; events some of INSERT, UPDATE, DELETE, TRUNCATE; columns
 * (UPDATE only) nil or empty for any; level ROW or STATEMENT; qualifiedFunction one of -triggerFunctions:'s strings
 * (anything else is refused, so it never carries SQL); condition as typed, nil or empty for none.
 */
- (BOOL)addTriggerNamed:(NSString *)name timing:(NSString *)timing events:(NSArray *)events updateColumns:(NSArray *)columns level:(NSString *)level function:(NSString *)qualifiedFunction condition:(NSString *)condition error:(NSError **)error;
/// DROP TRIGGER name ON the table (never CASCADE).
- (BOOL)dropTriggerNamed:(NSString *)name error:(NSError **)error;
/// ALTER TABLE … ENABLE | DISABLE TRIGGER name.
- (BOOL)setTrigger:(NSString *)name enabled:(BOOL)enabled error:(NSError **)error;

- (BOOL)renameTableTo:(NSString *)newName error:(NSError **)error;
/// nil or empty removes the comment.
- (BOOL)setTableComment:(NSString *)comment error:(NSError **)error;

@end
