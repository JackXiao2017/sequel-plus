#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * Writes a plain SQL dump of a database, some of its schemas, or some tables, that loads into an empty database in
 * one pass (psql, or SPPostgresSQLImporter). The order mirrors pg_dump's, so loading the data never fires a trigger
 * nor trips a foreign key:
 *   1. a header comment, then SET client_encoding, standard_conforming_strings, check_function_bodies and an empty
 *      search_path;
 *   2. CREATE SCHEMA IF NOT EXISTS for each schema (except public);
 *   3. CREATE EXTENSION IF NOT EXISTS (a database: every one but plpgsql; schemas: those installed in them; tables:
 *      none);
 *   4. enums, ranges, domains and composite types, in dependency order (not for tables; extension members left out);
 *   5. functions and procedures (pg_get_functiondef); those with a SQL-standard body, or using a table's or view's
 *      row type, come after the views;
 *   6. CREATE SEQUENCE with every option (identity columns' sequences are created by their tables);
 *   7. each table's own part (SPPostgresCreateStatement's SPPostgresCreatePartTable), parents before partitions
 *      and inheritance children, then the identity columns' sequence options and ALTER SEQUENCE … OWNED BY;
 *   8. views and materialized views (WITH NO DATA) in dependency order, then the functions held back in 5;
 *   9. one COPY … FROM stdin block per table holding rows (generated columns left out, partitioned parents and
 *      foreign tables skipped), referenced tables first; in a data-only dump each table's user triggers are
 *      disabled around its block;
 *  10. setval for every sequence exported (identity ones through pg_get_serial_sequence);
 *  11. indexes, foreign keys (and constraints that aren't validated), triggers with their enable state, then
 *      REFRESH MATERIALIZED VIEW for the populated ones;
 *  12. comments on schemas, types, functions and sequences.
 * Structure is 2–8, 11 and 12; data is 9 and 10. No DROP, ownership or privileges are written.
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
}

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The scope: set exactly one of these.
@property BOOL wholeDatabase;
/// Schema names.
@property (copy) NSArray *schemas;
/// @[schema, table] pairs. Only the tables (and views) themselves, their owned sequences, data, indexes, constraints
/// and triggers are written: trigger functions and the types they use are not, as with pg_dump -t. A partitioned
/// table brings its partitions, recursively (as pg_dump --table-and-children).
@property (copy) NSArray *tables;

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

@end
