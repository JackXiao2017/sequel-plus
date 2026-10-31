#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// One sequence of a schema, as pg_sequence (PostgreSQL 10+) describes it. Numbers are NSNumber (long long).
__attribute__((visibility("default")))
@interface SPPostgresSequence : NSObject
{
	NSString *_schema;
	NSString *_name;
	NSString *_dataType;
	NSNumber *_start;
	NSNumber *_increment;
	NSNumber *_minValue;
	NSNumber *_maxValue;
	NSNumber *_cache;
	BOOL _cycle;
	NSNumber *_lastValue;
	NSNumber *_pendingValue;
	BOOL _isCalled;
	NSString *_ownedBy;
	BOOL _isIdentity;
	NSString *_identityColumn;
	NSString *_owner;
	NSString *_comment;
}

@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *name;
/// @"smallint", @"integer" or @"bigint".
@property (readonly, copy) NSString *dataType;
@property (readonly, copy) NSNumber *start;
@property (readonly, copy) NSNumber *increment;
@property (readonly, copy) NSNumber *minValue;
@property (readonly, copy) NSNumber *maxValue;
@property (readonly, copy) NSNumber *cache;
@property (readonly) BOOL cycle;
/// The value nextval last returned (or setval set with is_called true); nil while is_called is false (never used,
/// or "the next call returns this value"), and when the user may not read the sequence.
@property (readonly, copy) NSNumber *lastValue;
@property (readonly) BOOL isCalled;
/// What the next nextval returns while is_called is false (last_value: the start of a sequence never used, or the
/// value setval(…, false) set); nil once it was called, and when the user may not read the sequence.
@property (readonly, copy) NSNumber *pendingValue;
/// @"schema.table.column" of the column the sequence is OWNED BY (pg_depend deptype 'a', as serial columns'), or nil.
@property (readonly, copy) NSString *ownedBy;
/// The sequence behind an identity column (pg_depend deptype 'i'): its options are changed through that column.
@property (readonly) BOOL isIdentity;
/// @"schema.table.column" of that identity column, nil for any other sequence.
@property (readonly, copy) NSString *identityColumn;
@property (readonly, copy) NSString *owner;
/// nil if none.
@property (readonly, copy) NSString *comment;

@end

/**
 * A sequence to create, or what an existing one should become (-alterSequence:to:error:). A nil number means the
 * server default: CREATE leaves the clause out; ALTER leaves start, increment and cache as they are, and sends NO
 * MINVALUE / NO MAXVALUE when the current bound isn't already the default one. A nil dataType keeps the type
 * (CREATE: the server's, bigint). An empty ownedBy or comment means none.
 */
__attribute__((visibility("default")))
@interface SPPostgresSequenceDefinition : NSObject
{
	NSString *_name;
	NSString *_dataType;
	NSNumber *_start;
	NSNumber *_increment;
	NSNumber *_minValue;
	NSNumber *_maxValue;
	NSNumber *_cache;
	BOOL _cycle;
	NSString *_ownedBy;
	NSString *_comment;
}

@property (readwrite, copy) NSString *name;
/// @"smallint", @"integer" or @"bigint" (anything else is refused before anything is sent).
@property (readwrite, copy) NSString *dataType;
@property (readwrite, copy) NSNumber *start;
@property (readwrite, copy) NSNumber *increment;
@property (readwrite, copy) NSNumber *minValue;
@property (readwrite, copy) NSNumber *maxValue;
@property (readwrite, copy) NSNumber *cache;
@property (readwrite) BOOL cycle;
/// @"schema.table.column" (as -ownerColumnCandidates: lists them), or nil / @"" for none.
@property (readwrite, copy) NSString *ownedBy;
@property (readwrite, copy) NSString *comment;

/// The definition that leaves the sequence as it is.
+ (instancetype)definitionWithSequence:(SPPostgresSequence *)sequence;

@end

/**
 * Reads and changes the sequences of one schema. Every change runs through SPPostgresRunStructureChange (savepoint
 * sp_structure inside the user's transaction, lock_timeout = lockTimeout), so a failure leaves everything as it
 * was and the user's transaction open; inside an aborted transaction nothing is sent. Identifiers are quoted with
 * SPPostgresQuoteIdentifier, numbers are written from NSNumber, never from typed text. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresSequences : NSObject
{
	PGPostgresConnection *_connection;
	NSString *_schema;
	NSTimeInterval _lockTimeout;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection schema:(NSString *)schema;

@property (readonly, copy) NSString *schema;

/// Seconds a change waits for a lock held elsewhere before it fails (default 5; 0: no limit).
@property NSTimeInterval lockTimeout;

/// The sequence, or nil (with an error) when there is none of that name or it can't be read.
- (SPPostgresSequence *)sequenceNamed:(NSString *)name error:(NSError **)error;

/// @"schema.table.column" of every smallint, integer and bigint column of the schema's tables (the columns OWNED BY
/// can name), sorted; nil on failure.
- (NSArray *)ownerColumnCandidates:(NSError **)error;

/// CREATE SEQUENCE "schema"."name" AS … INCREMENT BY … MINVALUE … MAXVALUE … START WITH … CACHE … [NO] CYCLE
/// [OWNED BY …], then COMMENT ON SEQUENCE when a comment is given, all or nothing.
- (BOOL)createSequence:(SPPostgresSequenceDefinition *)definition error:(NSError **)error;

/**
 * Changes what differs between definition and the sequence on the server, all or nothing: ALTER SEQUENCE … AS /
 * INCREMENT BY / MINVALUE / MAXVALUE / START WITH / CACHE / CYCLE / OWNED BY (OWNED BY NONE when cleared), then
 * RENAME TO, then COMMENT ON SEQUENCE. Nothing that is unchanged is sent (no DDL at all when nothing changed).
 *
 * For an identity column's sequence the options go through ALTER TABLE "s"."t" ALTER COLUMN "c" SET …; a rename or
 * an OWNED BY change is refused ("This sequence belongs to identity column t.c; rename or detach it from the
 * column."), and so is a type change (its type is the column's). A name over 63 bytes is refused. Refusals send
 * nothing.
 */
- (BOOL)alterSequence:(NSString *)name to:(SPPostgresSequenceDefinition *)definition error:(NSError **)error;

/// SELECT setval(…, value, isCalled): with isCalled NO, the next nextval returns value.
- (BOOL)setValue:(NSNumber *)value isCalled:(BOOL)isCalled ofSequence:(NSString *)name error:(NSError **)error;

/// @"schema.table.column" of every column whose default uses the sequence (pg_depend from the default, pg_attrdef,
/// to the sequence), and an identity sequence's column; sorted. nil on failure.
- (NSArray *)columnsUsingSequence:(NSString *)name error:(NSError **)error;

/**
 * DROP SEQUENCE (never CASCADE). When columns use it (-columnsUsingSequence:), nothing is sent and it fails with
 * SPPostgresErrorHasDependents, the message `"<name>" can't be deleted because these columns use it.` and the
 * columns under SPPostgresDependentsErrorKey.
 */
- (BOOL)dropSequence:(NSString *)name error:(NSError **)error;

@end
