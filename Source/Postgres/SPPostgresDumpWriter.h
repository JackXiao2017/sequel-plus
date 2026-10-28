#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * Writes a plain SQL dump of a database, some of its schemas, or some tables, that loads into an empty database in
 * one pass (psql, or SPPostgresSQLImporter). The order mirrors pg_dump's, so loading the data never fires a trigger
 * nor trips a foreign key:
 *   1. a header comment (naming the foreign tables left out), then SET client_encoding, standard_conforming_strings,
 *      check_function_bodies and an empty search_path;
 *   2. CREATE SCHEMA IF NOT EXISTS for each schema (except public);
 *   3. CREATE EXTENSION IF NOT EXISTS (a database: every one but plpgsql; schemas: those installed in them; tables:
 *      none, or with includeDependencies those the tables need), each after the extensions it requires;
 *   4. enums, ranges, domains (without their CHECK constraints) and composite types, in dependency order (for tables,
 *      only with includeDependencies; extension members left out);
 *   5. functions and procedures (pg_get_functiondef; for tables, only their trigger functions with
 *      includeDependencies); those with a SQL-standard body, or using a table's or view's row type, come after the
 *      views;
 *   6. CREATE SEQUENCE with every option (identity columns' sequences are created by their tables);
 *   7. each table's own part (SPPostgresCreateStatement's SPPostgresCreatePartTable), parents before partitions
 *      and inheritance children, then the identity columns' sequence options and ALTER SEQUENCE … OWNED BY;
 *   8. views and materialized views (WITH NO DATA) in dependency order, then the functions held back in 5, then
 *      the domains' CHECK constraints (ALTER DOMAIN … ADD CONSTRAINT, as they may call any function);
 *   9. one COPY … FROM stdin block per table holding rows (generated columns left out, partitioned parents
 *      skipped), referenced tables first; in a data-only dump each table's user triggers are disabled around its
 *      block;
 *  10. setval for every sequence exported (identity ones through pg_get_serial_sequence);
 *  11. indexes, foreign keys (and constraints that aren't validated), triggers with their enable state, then
 *      REFRESH MATERIALIZED VIEW for the populated ones;
 *  12. comments on schemas, types, functions and sequences.
 * Structure is 2–8, 11 and 12; data is 9 and 10. No DROP, ownership or privileges are written. Foreign tables are left
 * out altogether (their servers and user mappings aren't exported, so creating them would fail the import); the
 * header lists them, and so does foreignTablesSkipped.
 *
 * Everything is read in one REPEATABLE READ READ ONLY transaction, so the dump is one consistent snapshot, with
 * row_security off: a table whose row-level security would hide rows from the role fails the export instead of
 * exporting a subset. Use on a
 * connection of its own that has no transaction open; synchronous, on the caller's thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresDumpWriter : NSObject
{
	PGPostgresConnection *connection;
	BOOL wholeDatabase;
	NSArray *schemas;
	NSArray *tables;
	BOOL includeStructure;
	BOOL includeData;
	BOOL compress;
	BOOL (^progress)(NSUInteger tableIndex, NSUInteger tableCount, NSString *table);

	FILE *plainFile;
	void *gzipFile;
	NSError *writeError;
	NSArray *foreignTablesSkipped;
	BOOL includeDependencies;
	NSArray *skippedObjects;
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The scope: set exactly one of these.
@property BOOL wholeDatabase;
/// Schema names.
@property (copy) NSArray *schemas;
/// @[schema, table] pairs. Only the tables (and views) themselves, their owned sequences, data, indexes, constraints
/// and triggers are written: trigger functions and the types they use are not, as with pg_dump -t, unless
/// includeDependencies. A partitioned table brings its partitions, recursively (as pg_dump --table-and-children).
@property (copy) NSArray *tables;

/**
 * Default NO; only with tables. Also writes what the tables need to be usable, each in its usual section (and the
 * schemas they're in): the user types their columns use, followed through domains' base types, composite types'
 * attributes, array element types and range subtypes (4, domains' CHECKs in 8); the extensions owning any of those
 * types or trigger functions, with the extensions they require (3); the functions their triggers call (5); the
 * sequences their column defaults call with nextval that they don't own (6, with their setval in 10, and comments).
 */
@property BOOL includeDependencies;
/// SPPostgresDumpObjects: dependencies (from includeDependencies) equal to one of these aren't written, as they exist
/// where the dump will load. Every other object is written whatever this holds.
@property (copy) NSArray *skippedObjects;

/// Both default YES.
@property BOOL includeStructure;
@property BOOL includeData;

/// gzip the file.
@property BOOL compress;

/// Called before each table's data (or, without data, before its CREATE), tableIndex from 1, and again with the same
/// tableIndex after every MiB of a table's COPY data; returning NO cancels (also in the middle of a COPY).
@property (copy) BOOL (^progress)(NSUInteger tableIndex, NSUInteger tableCount, NSString *table);

/**
 * Writes the dump to path. An empty schemas or tables list, or neither structure nor data, fails at once with
 * SPPostgresErrorInvalidSettings. On failure or cancel, the transaction is rolled back, the file deleted, and NO returned
 * with an error in SPPostgresErrorDomain (SPPostgresErrorCancelled on cancel).
 */
- (BOOL)writeToPath:(NSString *)path error:(NSError **)error;

/**
 * The objects -writeToPath:error: would create with the current settings, as SPPostgresDumpObjects sorted by kind,
 * then schema, then name (then arguments): tables (partitions included), views, materialized views, sequences
 * (standalone and serial ones, not identity ones), routines, types, domains and extensions (an empty list without
 * includeStructure). Foreign tables aren't included (never written), nor are skippedObjects' dependencies. Reads in
 * a READ ONLY transaction of its own (no DDL), on a connection with no transaction open, which it leaves idle; nil
 * with an error as -writeToPath:error: (settings, missing tables, query failures).
 */
- (NSArray *)objectsInScope:(NSError **)error;

/// The part of -objectsInScope: that includeDependencies adds (empty when it is NO).
- (NSArray *)dependenciesInScope:(NSError **)error;

/// The foreign tables in scope that the last -writeToPath:error: left out, as @[schema, table] pairs.
@property (readonly) NSArray *foreignTablesSkipped;

/// The extension names in CREATE order: each after those it requires (requirements maps a name to an NSSet of
/// names; others are ignored), otherwise in the given order. For tests.
+ (NSArray *)orderedExtensions:(NSArray *)names requirements:(NSDictionary *)requirements;

@end
