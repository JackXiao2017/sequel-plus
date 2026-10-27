#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableDuplicator.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Statements run on each server before every test (dup_test is dropped and rebuilt; the "Sales Data"
/// schema belongs to the catalog fixture, whose tests list its tables, so only our own tables are touched).
static NSArray<NSString *> *SPDuplicatorSetupStatements(void)
{
	return @[
		@"DROP SCHEMA IF EXISTS dup_test CASCADE",
		@"CREATE SCHEMA dup_test",
		@"CREATE TABLE dup_test.src ("
			" id serial PRIMARY KEY,"
			" gone text,"
			" code text NOT NULL UNIQUE,"
			" qty integer DEFAULT 3 CHECK (qty >= 0),"
			" ident bigint GENERATED ALWAYS AS IDENTITY,"
			" doubled integer GENERATED ALWAYS AS (qty * 2) STORED,"
			" note text)",
		@"ALTER TABLE dup_test.src DROP COLUMN gone",
		@"CREATE INDEX src_note_idx ON dup_test.src (lower(note))",
		@"COMMENT ON COLUMN dup_test.src.note IS 'a note'",
		@"INSERT INTO dup_test.src (code, qty, note) SELECT 'c' || g, g, CASE WHEN g = 2 THEN NULL ELSE 'note ' || g END FROM generate_series(1, 7) g",
		@"DELETE FROM dup_test.src WHERE id > 5",
		@"CREATE TABLE dup_test.taken (id integer)",
		@"COMMENT ON TABLE dup_test.src IS 'it''s the \\ source'",
		@"CREATE TABLE dup_test.parent (id integer PRIMARY KEY, v text UNIQUE)",
		@"CREATE TABLE dup_test.child (extra text) INHERITS (dup_test.parent)",
		@"INSERT INTO dup_test.parent (id, v) VALUES (1, 'own')",
		@"INSERT INTO dup_test.child (id, v, extra) VALUES (1, 'own', 'dup key'), (2, 'kid', 'x')",
		@"CREATE VIEW dup_test.src_view AS SELECT id FROM dup_test.src",
		@"CREATE TABLE dup_test.parted (id integer NOT NULL, v text) PARTITION BY RANGE (id)",
		@"CREATE TABLE dup_test.parted_1 PARTITION OF dup_test.parted FOR VALUES FROM (0) TO (100)",
		@"CREATE SCHEMA IF NOT EXISTS \"Sales Data\"",
		@"DROP TABLE IF EXISTS \"Sales Data\".\"a\"\"b\", \"Sales Data\".\"a\"\"b_copy\" CASCADE",
		@"CREATE TABLE \"Sales Data\".\"a\"\"b\" (id serial PRIMARY KEY, \"we\"\"ird col\" text)",
		@"INSERT INTO \"Sales Data\".\"a\"\"b\" (\"we\"\"ird col\") VALUES ('x'), ('y')",
	];
}

@interface SPPostgresTableDuplicatorTests : XCTestCase
/// Closed in -tearDown, so a failed test can't leave a transaction holding locks that block the cleanup
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresTableDuplicatorTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		XCTAssertNotNil(connection);
		for (NSString *sql in SPDuplicatorSetupStatements()) {
			XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
		}
		[connection disconnect];
	}
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;

	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
		[connection execute:@"SET lock_timeout = '10s'"];
		[connection execute:@"DROP SCHEMA IF EXISTS dup_test CASCADE"];
		[connection execute:@"DROP TABLE IF EXISTS \"Sales Data\".\"a\"\"b\", \"Sales Data\".\"a\"\"b_copy\" CASCADE"];
		[connection disconnect];
	}
	[super tearDown];
}

#pragma mark - Helpers

- (PGPostgresConnection *)connectOn:(NSNumber *)port
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	return connection;
}

/// The first column of every row, as text (the SQL must select text).
- (NSArray *)column:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	NSMutableArray *values = [NSMutableArray array];
	for (NSUInteger i = 0; i < result.numberOfRows; i++) {
		id value = [result textValueAtRow:i column:0];
		[values addObject:value ?: [NSNull null]];
	}
	return values;
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	return [[self column:sql on:connection] firstObject];
}

/// Columns as "name type nullable default identity generated", in order.
- (NSArray *)columnsOf:(NSString *)qualified on:(PGPostgresConnection *)connection
{
	NSString *sql = [NSString stringWithFormat:
		@"SELECT (a.attname || ' ' || format_type(a.atttypid, a.atttypmod) || ' ' || a.attnotnull::text || ' '"
		" || a.attidentity::text || '/' || a.attgenerated::text || ' '"
		" || COALESCE(regexp_replace(pg_get_expr(d.adbin, d.adrelid), 'nextval\\(.*\\)', 'nextval'), '-')"
		" || ' ' || COALESCE(col_description(a.attrelid, a.attnum), '-'))::text"
		" FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum"
		" WHERE a.attrelid = '%@'::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum", qualified];
	return [self column:sql on:connection];
}

/// Index and constraint definitions with the table name taken out, sorted.
- (NSArray *)indexesAndConstraintsOf:(NSString *)qualified table:(NSString *)table on:(PGPostgresConnection *)connection
{
	NSString *sql = [NSString stringWithFormat:
		@"SELECT x::text FROM ("
		" SELECT regexp_replace(pg_get_indexdef(indexrelid), '^.* USING ', 'INDEX USING ') AS x FROM pg_index WHERE indrelid = '%1$@'::regclass"
		" UNION ALL SELECT contype::text || ' ' || pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '%1$@'::regclass AND contype <> 'n'"
		") s ORDER BY 1", qualified];
	(void)table;
	return [self column:sql on:connection];
}

- (NSArray *)rowsOf:(NSString *)qualified on:(PGPostgresConnection *)connection
{
	return [self column:[NSString stringWithFormat:@"SELECT t::text FROM %@ t ORDER BY 1", qualified] on:connection];
}

#pragma mark - Tests

- (void)testStructureOnlyCopyHasNoRowsButSameColumnsIndexesConstraints
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:NO connection:connection error:&error], @"%@: %@", port, error);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle, @"its own transaction is committed");

		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM dup_test.src_copy" on:connection], @"0");
		XCTAssertEqualObjects([self columnsOf:@"dup_test.src_copy" on:connection], [self columnsOf:@"dup_test.src" on:connection], @"%@", port);
		NSArray *indexes = [self indexesAndConstraintsOf:@"dup_test.src_copy" table:@"src_copy" on:connection];
		XCTAssertEqualObjects(indexes, [self indexesAndConstraintsOf:@"dup_test.src" table:@"src" on:connection], @"%@", port);
		XCTAssertEqual(indexes.count, 6u, @"the pkey, unique and lower(note) indexes, and the PRIMARY KEY, UNIQUE and CHECK constraints: %@", indexes);

		// The serial column has its own sequence, owned by the copy
		XCTAssertEqualObjects([self value:@"SELECT pg_get_serial_sequence('dup_test.src_copy', 'id')::text" on:connection], @"dup_test.src_copy_id_seq");
		XCTAssertEqualObjects([self value:@"SELECT nextval('dup_test.src_copy_id_seq')::text" on:connection], @"1", @"a fresh sequence without content");
		XCTAssertNotEqualObjects([self value:@"SELECT pg_get_serial_sequence('dup_test.src_copy', 'ident')::text" on:connection],
								 [self value:@"SELECT pg_get_serial_sequence('dup_test.src', 'ident')::text" on:connection]);
		[connection disconnect];
	}
}

- (void)testCopyWithContentHasSameRows
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:YES connection:connection error:&error], @"%@: %@", port, error);

		NSArray *rows = [self rowsOf:@"dup_test.src_copy" on:connection];
		XCTAssertEqual(rows.count, 5u);
		XCTAssertEqualObjects(rows, [self rowsOf:@"dup_test.src" on:connection], @"identity ALWAYS values and generated columns too");

		// The identity column continues after the copied values, from its own sequence
		XCTAssertNotNil([connection execute:@"INSERT INTO dup_test.src_copy (code) VALUES ('new')"], @"%@", connection.lastError.errorPrimaryMessage);
		XCTAssertEqualObjects([self value:@"SELECT ident::text FROM dup_test.src_copy WHERE code = 'new'" on:connection], @"8");
		XCTAssertEqualObjects([self value:@"SELECT doubled::text FROM dup_test.src_copy WHERE code = 'new'" on:connection], @"6");
		[connection disconnect];
	}
}

- (void)testSerialGetsOwnSequenceContinuingFromOld
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:YES connection:connection error:&error], @"%@: %@", port, error);

		NSString *oldBefore = [self value:@"SELECT last_value::text FROM dup_test.src_id_seq" on:connection];
		XCTAssertEqualObjects(oldBefore, @"7");

		XCTAssertNotNil([connection execute:@"INSERT INTO dup_test.src_copy (code) VALUES ('n1'), ('n2')"], @"%@", connection.lastError.errorPrimaryMessage);
		XCTAssertEqualObjects(([self column:@"SELECT id::text FROM dup_test.src_copy WHERE code LIKE 'n%' ORDER BY id" on:connection]), (@[@"8", @"9"]), @"after the copied max (5) and the old sequence's position");
		XCTAssertEqualObjects([self value:@"SELECT last_value::text FROM dup_test.src_id_seq" on:connection], oldBefore, @"the old sequence doesn't move");

		// Owned by the copy's column: dropping the copy drops its sequence, and the original keeps working
		XCTAssertEqualObjects([self value:@"SELECT pg_get_serial_sequence('dup_test.src_copy', 'id')::text" on:connection], @"dup_test.src_copy_id_seq");
		XCTAssertNotNil([connection execute:@"DROP TABLE dup_test.src_copy"]);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class WHERE relname = 'src_copy_id_seq'" on:connection], @"0");
		XCTAssertNotNil([connection execute:@"INSERT INTO dup_test.src (code) VALUES ('after')"], @"%@", connection.lastError.errorPrimaryMessage);
		XCTAssertEqualObjects([self value:@"SELECT id::text FROM dup_test.src WHERE code = 'after'" on:connection], @"8");
		[connection disconnect];
	}
}

- (void)testFailureRollsBackAndLeavesNoTable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"taken" withContent:YES connection:connection error:&error]);
		XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
		XCTAssertTrue([error.localizedDescription containsString:@"already exists"], @"the server's message: %@", error.localizedDescription);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle, @"rolled back");
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class WHERE relname IN ('taken_id_seq')" on:connection], @"0");

		// A failure after CREATE TABLE (the content breaks a NOT VALID check, which the copy enforces) leaves
		// neither the table nor its sequence behind
		XCTAssertNotNil([connection execute:@"ALTER TABLE dup_test.src ADD CONSTRAINT qty_small CHECK (qty < 3) NOT VALID"]);
		error = nil;
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:YES connection:connection error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"qty_small"], @"%@", error.localizedDescription);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class WHERE relname IN ('src_copy', 'src_copy_id_seq')" on:connection], @"0");
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle);
		XCTAssertNotNil([connection execute:@"ALTER TABLE dup_test.src DROP CONSTRAINT qty_small"]);

		// The serial's sequence name is taken: a free one is chosen, as PostgreSQL does for serial columns
		XCTAssertNotNil([connection execute:@"CREATE VIEW dup_test.other_copy_id_seq AS SELECT 1 AS x"]);
		error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"other_copy" withContent:YES connection:connection error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SELECT pg_get_serial_sequence('dup_test.other_copy', 'id')::text" on:connection], @"dup_test.other_copy_id_seq1");

		// Not a table
		error = nil;
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"src_view" inSchema:@"dup_test" toName:@"v2" withContent:NO connection:connection error:&error]);
		XCTAssertTrue(error.localizedDescription.length > 0);
		error = nil;
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"nope" inSchema:@"dup_test" toName:@"v2" withContent:NO connection:connection error:&error]);
		XCTAssertTrue(error.localizedDescription.length > 0);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class WHERE relname = 'v2'" on:connection], @"0");
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle);
		[connection disconnect];
	}
}

- (void)testPartitionedTableRefusedWithClearMessage
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"parted" inSchema:@"dup_test" toName:@"parted_copy" withContent:YES connection:connection error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"partitioned"], @"%@", error.localizedDescription);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class WHERE relname = 'parted_copy'" on:connection], @"0");

		// A partition on its own is an ordinary table
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"parted_1" inSchema:@"dup_test" toName:@"parted_1_copy" withContent:YES connection:connection error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SELECT relispartition::text FROM pg_class WHERE oid = 'dup_test.parted_1_copy'::regclass" on:connection], @"false");
		[connection disconnect];
	}
}

- (void)testOddNamesQuoted
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"a\"b" inSchema:@"Sales Data" toName:@"a\"b_copy" withContent:YES connection:connection error:&error], @"%@: %@", port, error);

		XCTAssertEqualObjects([self rowsOf:@"\"Sales Data\".\"a\"\"b_copy\"" on:connection], [self rowsOf:@"\"Sales Data\".\"a\"\"b\"" on:connection]);
		XCTAssertEqualObjects([self value:@"SELECT pg_get_serial_sequence('\"Sales Data\".\"a\"\"b_copy\"', 'id')::text" on:connection], @"\"Sales Data\".\"a\"\"b_copy_id_seq\"");
		XCTAssertNotNil([connection execute:@"INSERT INTO \"Sales Data\".\"a\"\"b_copy\" (\"we\"\"ird col\") VALUES ('z')"], @"%@", connection.lastError.errorPrimaryMessage);
		XCTAssertEqualObjects([self value:@"SELECT max(id)::text FROM \"Sales Data\".\"a\"\"b_copy\"" on:connection], @"3");
		[connection disconnect];
	}
}

- (void)testDuplicateInsideUserTransactionUsesSavepoint
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNotNil([connection execute:@"INSERT INTO dup_test.taken VALUES (42)"]);
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:YES connection:connection error:&error], @"%@", error);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction, @"the user's transaction stays open");

		// A failing duplicate undoes only its own work
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"taken" withContent:NO connection:connection error:&error]);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM dup_test.src_copy" on:connection], @"5");
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM dup_test.taken" on:connection], @"1");

		// The user decides: rolling back takes the copy away too
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class WHERE relname IN ('src_copy', 'src_copy_id_seq')" on:connection], @"0");
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM dup_test.taken" on:connection], @"0");

		// Inside an aborted transaction: refused with a clear message, the transaction left as it was
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		error = nil;
		XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:NO connection:connection error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"aborted"], @"%@", error.localizedDescription);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInError);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		[connection disconnect];
	}
}

- (void)testInheritanceParentCopiesOnlyItsOwnRows
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM dup_test.parent" on:connection], @"3", @"the parent's scan includes its child's rows");
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"parent" inSchema:@"dup_test" toName:@"parent_copy" withContent:YES connection:connection error:&error], @"%@: %@", port, error);
		XCTAssertEqualObjects([self rowsOf:@"dup_test.parent_copy" on:connection], (@[@"(1,own)"]), @"%@: only the parent's own row", port);
		[connection disconnect];
	}
}

- (void)testOverLongNameRefused
{
	NSString *ascii64 = [@"" stringByPaddingToLength:64 withString:@"n" startingAtIndex:0];
	NSString *utf8Of64Bytes = [@"" stringByPaddingToLength:32 withString:@"\u00e9" startingAtIndex:0]; // 32 x 2 bytes
	NSString *ascii63 = [@"" stringByPaddingToLength:63 withString:@"m" startingAtIndex:0];
	XCTAssertFalse([SPPostgresTableDuplicator isValidTableName:ascii64]);
	XCTAssertFalse([SPPostgresTableDuplicator isValidTableName:utf8Of64Bytes]);
	XCTAssertFalse([SPPostgresTableDuplicator isValidTableName:@""]);
	XCTAssertTrue([SPPostgresTableDuplicator isValidTableName:ascii63]);

	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		for (NSString *name in @[ascii64, utf8Of64Bytes]) {
			NSError *error = nil;
			XCTAssertFalse([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:name withContent:YES connection:connection error:&error]);
			XCTAssertTrue([error.localizedDescription containsString:@"63"], @"%@", error.localizedDescription);
		}
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'dup_test' AND c.relname NOT IN ('src', 'src_id_seq', 'src_ident_seq', 'src_pkey', 'src_code_key', 'src_note_idx', 'taken', 'src_view', 'parted', 'parted_1', 'parent', 'child', 'parent_pkey', 'parent_v_key', 'parted_1_pkey') AND c.relkind IN ('r', 'S')" on:connection], @"0", @"nothing created");

		// 63 bytes is fine, and the copy's identity sequence still continues
		NSError *error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:ascii63 withContent:YES connection:connection error:&error], @"%@", error);
		NSString *insert = [NSString stringWithFormat:@"INSERT INTO dup_test.%@ (code) VALUES ('new')", ascii63];
		XCTAssertNotNil([connection execute:insert], @"%@", connection.lastError.errorPrimaryMessage);
		[connection disconnect];
	}
}

- (void)testTableCommentCopied
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"src" inSchema:@"dup_test" toName:@"src_copy" withContent:NO connection:connection error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SELECT obj_description('dup_test.src_copy'::regclass, 'pg_class')::text" on:connection], @"it's the \\ source");
		XCTAssertTrue([SPPostgresTableDuplicator duplicateTable:@"taken" inSchema:@"dup_test" toName:@"taken_copy" withContent:NO connection:connection error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SELECT obj_description('dup_test.taken_copy'::regclass, 'pg_class')::text" on:connection], [NSNull null], @"no comment, none added");
		[connection disconnect];
	}
}

@end
