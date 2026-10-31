#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresCreateStatement.h"
#import "../Source/Postgres/SPPostgresTableStructure.h"
#import "../Source/Postgres/SPPostgresStatementSplitter.h"

/// The generated CREATE statement (both ports): it recreates what it describes, read back through Task 1's readers.
@interface SPPostgresCreateStatementTests : XCTestCase
/// Closed in -tearDown, so a failed test can't leave a transaction holding locks that block the cleanup
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@end

@implementation SPPostgresCreateStatementTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[SPPostgresTestServers loadStructureFixtureOnPort:port.unsignedIntegerValue];
	}
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[SPPostgresTestServers dropStructureFixtureOnPort:port.unsignedIntegerValue];
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

- (void)run:(NSString *)sql on:(PGPostgresConnection *)connection
{
	XCTAssertNotNil([connection execute:sql], @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
}

- (id)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	return [[result rowAsArray] firstObject];
}

- (NSInteger)serverVersionOn:(PGPostgresConnection *)connection
{
	return [[self value:@"SELECT current_setting('server_version_num')::int" on:connection] integerValue];
}

- (NSString *)createStatementFor:(NSString *)table schema:(NSString *)schema on:(PGPostgresConnection *)connection
{
	NSError *error = nil;
	NSString *statement = [SPPostgresCreateStatement createStatementForTable:table inSchema:schema connection:connection error:&error];
	XCTAssertNotNil(statement, @"%@.%@: %@", schema, table, error);
	return statement;
}

/// Runs each statement of sql (as the Query view splits it).
- (void)execute:(NSString *)sql on:(PGPostgresConnection *)connection
{
	for (NSString *statement in [SPPostgresStatementSplitter statementsInSQL:sql]) {
		XCTAssertNotNil([connection execute:statement], @"%@: %@\n\nin:\n%@", statement, connection.lastError.errorPrimaryMessage, sql);
	}
}

- (NSArray *)describe:(NSArray *)objects keys:(NSArray *)keys
{
	NSMutableArray *described = [NSMutableArray array];
	for (id object in objects) [described addObject:[object dictionaryWithValuesForKeys:keys]];
	return described;
}

/// Everything Task 1 and 3's readers say about the relation.
- (NSDictionary *)snapshotOf:(NSString *)table schema:(NSString *)schema on:(PGPostgresConnection *)connection
{
	SPPostgresTableStructure *structure = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:schema table:table];
	NSError *error = nil;
	NSArray *columns = [structure columns:&error];
	XCTAssertNotNil(columns, @"%@", error);
	NSArray *indexes = [structure indexes:&error];
	XCTAssertNotNil(indexes, @"%@", error);
	NSArray *constraints = [structure constraints:&error];
	XCTAssertNotNil(constraints, @"%@", error);
	NSArray *triggers = [structure triggers:&error];
	XCTAssertNotNil(triggers, @"%@", error);
	NSString *kind = [structure relationKind:&error];
	XCTAssertNotNil(kind, @"%@", error);
	error = nil;
	NSString *comment = [structure tableComment:&error];
	XCTAssertNil(error);

	// Not in the readers: each column's collation, and PostgreSQL 18's NOT NULL constraints (none before 18)
	NSString *relation = [NSString stringWithFormat:@"%@.%@", [self quoted:schema], [self quoted:table]];
	PGPostgresResult *details = [connection execute:
		@"SELECT (SELECT coalesce(json_agg(a.attname || ' ' || coalesce(co.collname, '-') ORDER BY a.attnum), '[]')"
		"   FROM pg_attribute a LEFT JOIN pg_collation co ON co.oid = a.attcollation WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped)::text,"
		" (SELECT coalesce(json_agg(c.conname || ' ' || pg_get_constraintdef(c.oid) || ' ' || c.connoinherit || ' ' || c.convalidated || ' ' || c.conislocal ORDER BY c.conname), '[]')"
		"   FROM pg_constraint c WHERE c.conrelid = $1::regclass AND c.contype = 'n')::text" values:@[relation]];
	XCTAssertNotNil(details, @"%@", connection.lastError.errorPrimaryMessage);
	NSArray *row = [details rowAsArray];

	return @{
		@"collations": row[0],
		@"notNullConstraints": row[1],
		@"kind": kind,
		@"comment": comment ?: [NSNull null],
		@"columns": [self describe:columns keys:@[@"name", @"typeName", @"nullable", @"defaultExpression", @"autoKind", @"generationExpression", @"comment", @"attnum"]],
		@"indexes": [self describe:indexes keys:@[@"name", @"definition", @"columns", @"method", @"isUnique", @"isPrimary", @"constraintName"]],
		@"constraints": [self describe:constraints keys:@[@"name", @"kind", @"definition", @"columns", @"referencedSchema", @"referencedTable", @"referencedColumns", @"onUpdate", @"onDelete"]],
		@"triggers": [self describe:triggers keys:@[@"name", @"timing", @"events", @"level", @"functionSchema", @"functionName", @"condition", @"enabled", @"definition"]],
	};
}

- (NSString *)quoted:(NSString *)identifier
{
	return [NSString stringWithFormat:@"\"%@\"", [identifier stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

/// Generates the relation's statement, drops the relation, runs the statement and compares the readers' views.
- (NSString *)roundTrip:(NSString *)table schema:(NSString *)schema kind:(NSString *)dropKind on:(PGPostgresConnection *)connection
{
	NSDictionary *before = [self snapshotOf:table schema:schema on:connection];
	NSString *statement = [self createStatementFor:table schema:schema on:connection];
	[self run:[NSString stringWithFormat:@"DROP %@ \"%@\".\"%@\"", dropKind, [schema stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""],
			   [table stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]] on:connection];
	[self execute:statement on:connection];
	NSDictionary *after = [self snapshotOf:table schema:schema on:connection];
	for (NSString *key in before) {
		XCTAssertEqualObjects(after[key], before[key], @"%@.%@ %@ differs; statement:\n%@", schema, table, key, statement);
	}
	return statement;
}

#pragma mark - Tables

- (void)testCreateStatementRecreatesTable
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		BOOL pg18 = [self serverVersionOn:connection] >= 180000;

		[self run:@"CREATE TABLE structure_test.rt_parent (id int PRIMARY KEY, k text UNIQUE)" on:connection];
		[self run:[NSString stringWithFormat:@"CREATE TABLE structure_test.rt ("
				   " id bigint GENERATED ALWAYS AS IDENTITY,"
				   " ref int GENERATED BY DEFAULT AS IDENTITY,"
				   " code varchar(20) COLLATE \"C\" NOT NULL,"
				   " label text DEFAULT 'x''y',"
				   " qty numeric(10,2) NOT NULL DEFAULT 0,"
				   " doubled numeric GENERATED ALWAYS AS (qty * 2) STORED,"
				   " parent_id int,"
				   " area box,"
				   " \"Odd \"\"Col\"\" name\" int,"
				   " \"order\" text[]%@,"
				   " CONSTRAINT rt_pkey PRIMARY KEY (id),"
				   " CONSTRAINT rt_code_key UNIQUE (code),"
				   " CONSTRAINT rt_qty_check CHECK (qty >= 0),"
				   " CONSTRAINT rt_parent_fk FOREIGN KEY (parent_id) REFERENCES structure_test.rt_parent (id) ON DELETE SET NULL,"
				   " CONSTRAINT rt_area_excl EXCLUDE USING gist (area WITH &&))",
				   pg18 ? @", virt int GENERATED ALWAYS AS (\"Odd \"\"Col\"\" name\" + 1) VIRTUAL" : @""] on:connection];
		[self run:@"ALTER TABLE structure_test.rt ADD CONSTRAINT rt_label_check CHECK (label <> '') NOT VALID" on:connection];
		[self run:@"CREATE INDEX rt_label_idx ON structure_test.rt (lower(label))" on:connection];
		[self run:@"CREATE UNIQUE INDEX rt_partial_idx ON structure_test.rt (parent_id) WHERE parent_id > 0" on:connection];
		[self run:@"COMMENT ON TABLE structure_test.rt IS 'round ''trip'''" on:connection];
		[self run:@"COMMENT ON COLUMN structure_test.rt.code IS 'the code'" on:connection];
		[self run:@"COMMENT ON COLUMN structure_test.rt.\"Odd \"\"Col\"\" name\" IS 'odd'" on:connection];
		[self run:@"CREATE TRIGGER rt_touch BEFORE UPDATE OF code ON structure_test.rt FOR EACH ROW WHEN (OLD.code IS DISTINCT FROM NEW.code) EXECUTE FUNCTION structure_test.touch()" on:connection];
		[self run:@"CREATE TRIGGER rt_audit AFTER INSERT OR DELETE ON structure_test.rt FOR EACH STATEMENT EXECUTE FUNCTION structure_test.touch()" on:connection];
		[self run:@"ALTER TABLE structure_test.rt DISABLE TRIGGER rt_audit" on:connection];
		[self run:@"CREATE TRIGGER rt_replica AFTER UPDATE ON structure_test.rt FOR EACH ROW EXECUTE FUNCTION structure_test.touch()" on:connection];
		[self run:@"ALTER TABLE structure_test.rt ENABLE REPLICA TRIGGER rt_replica" on:connection];

		NSString *statement = [self roundTrip:@"rt" schema:@"structure_test" kind:@"TABLE" on:connection];
		XCTAssertTrue([statement hasPrefix:@"CREATE TABLE \"structure_test\".\"rt\" (\n    \"id\" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"ref\" integer GENERATED BY DEFAULT AS IDENTITY NOT NULL,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"code\" character varying(20) COLLATE \"C\" NOT NULL,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"label\" text DEFAULT 'x''y'::text,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"doubled\" numeric GENERATED ALWAYS AS ((qty * (2)::numeric)) STORED,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    CONSTRAINT \"rt_pkey\" PRIMARY KEY (id),\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"REFERENCES structure_test.rt_parent(id) ON DELETE SET NULL"], @"qualified whatever the search_path: %@", statement);
		XCTAssertTrue([statement containsString:@"\n\nALTER TABLE \"structure_test\".\"rt\" ADD CONSTRAINT \"rt_label_check\" CHECK ((label <> ''::text)) NOT VALID;\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n\nCREATE INDEX rt_label_idx ON structure_test.rt USING btree (lower(label));\n"], @"%@", statement);
		XCTAssertFalse([statement containsString:@"CREATE UNIQUE INDEX rt_pkey"], @"constraint indexes come with their constraints: %@", statement);
		XCTAssertTrue([statement containsString:@"\n\nCOMMENT ON TABLE \"structure_test\".\"rt\" IS 'round ''trip''';\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n\nCOMMENT ON COLUMN \"structure_test\".\"rt\".\"Odd \"\"Col\"\" name\" IS 'odd';\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"EXECUTE FUNCTION structure_test.touch();\n\nALTER TABLE \"structure_test\".\"rt\" DISABLE TRIGGER \"rt_audit\";"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"ALTER TABLE \"structure_test\".\"rt\" ENABLE REPLICA TRIGGER \"rt_replica\";"], @"%@", statement);
		XCTAssertTrue([statement hasSuffix:@";\n"], @"%@", statement);
		if (pg18) XCTAssertTrue([statement containsString:@" GENERATED ALWAYS AS ((\"Odd \"\"Col\"\" name\" + 1)) VIRTUAL,\n"], @"%@", statement);
		XCTAssertEqualObjects([self value:@"SELECT tgenabled::text FROM pg_trigger WHERE tgname = 'rt_replica'" on:connection], @"R");

		// Odd identifiers: "Sales Data"."Mixed Case" with a quote, a space, mixed case and reserved words everywhere
		[self run:@"ALTER TABLE \"Sales Data\".\"Mixed Case\" ADD COLUMN \"a \"\"q\"\" b\" text COLLATE \"C\", ADD COLUMN \"Mixed Col\" int GENERATED BY DEFAULT AS IDENTITY" on:connection];
		[self run:@"ALTER TABLE \"Sales Data\".\"Mixed Case\" ADD CONSTRAINT \"Odd \"\"chk\"\"\" CHECK (\"select\" <> '')" on:connection];
		[self run:@"CREATE UNIQUE INDEX \"Odd idx\" ON \"Sales Data\".\"Mixed Case\" (\"a \"\"q\"\" b\", \"Mixed Col\")" on:connection];
		[self run:@"COMMENT ON TABLE \"Sales Data\".\"Mixed Case\" IS 'it''s odd'" on:connection];
		[self run:@"COMMENT ON COLUMN \"Sales Data\".\"Mixed Case\".\"select\" IS 'reserved'" on:connection];
		[self run:@"CREATE TRIGGER \"Odd \"\"trig\"\"\" BEFORE INSERT ON \"Sales Data\".\"Mixed Case\" FOR EACH ROW EXECUTE FUNCTION structure_test.touch()" on:connection];
		statement = [self roundTrip:@"Mixed Case" schema:@"Sales Data" kind:@"TABLE" on:connection];
		XCTAssertTrue([statement hasPrefix:@"CREATE TABLE \"Sales Data\".\"Mixed Case\" (\n    \"order\" integer NOT NULL,\n    \"select\" text,\n    \"a \"\"q\"\" b\" text COLLATE \"C\",\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"CONSTRAINT \"Odd \"\"chk\"\"\" CHECK ((\"select\" <> ''::text))"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"COMMENT ON COLUMN \"Sales Data\".\"Mixed Case\".\"select\" IS 'reserved';"], @"%@", statement);
	}
}

- (void)testSerialEmitsNextvalDefault
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSString *statement = [self createStatementFor:@"t" schema:@"structure_test" on:connection];
		XCTAssertTrue([statement hasPrefix:@"CREATE TABLE \"structure_test\".\"t\" (\n    \"id\" integer DEFAULT nextval('structure_test.t_id_seq'::regclass) NOT NULL,\n"], @"%@", statement);
		XCTAssertFalse([statement containsString:@"SEQUENCE"], @"no sequence DDL: %@", statement);
		XCTAssertFalse([statement containsString:@"serial"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"ident\" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"gen\" integer GENERATED ALWAYS AS ((id * 2)) STORED,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"a \"\"q\"\" b\" text,\n"], @"%@", statement);
		XCTAssertTrue([statement containsString:@"\n    \"amount\" numeric(10,2) DEFAULT 0,\n"], @"%@", statement);
		XCTAssertFalse([statement containsString:@"COLLATE"], @"the types' own collations: %@", statement);
		XCTAssertTrue([statement containsString:@"CREATE INDEX t_qty_amount_idx ON structure_test.t USING btree (qty, amount);"], @"%@", statement);
	}
}

- (void)testPartitionedAndInheritedTables
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE TABLE structure_test.pt (id int NOT NULL, created date NOT NULL, note text) PARTITION BY RANGE (created)" on:connection];
		[self run:@"CREATE INDEX pt_note_idx ON structure_test.pt (note)" on:connection];
		[self run:@"CREATE TABLE structure_test.pt_2026 PARTITION OF structure_test.pt (CONSTRAINT pt_2026_id_check CHECK (id > 0)) FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')" on:connection];
		[self run:@"CREATE TABLE structure_test.pt_other PARTITION OF structure_test.pt DEFAULT" on:connection];
		[self run:@"CREATE TRIGGER pt_touch AFTER INSERT ON structure_test.pt FOR EACH ROW EXECUTE FUNCTION structure_test.touch()" on:connection];
		[self run:@"CREATE TABLE structure_test.base (id int, name text, CONSTRAINT base_id_check CHECK (id > 0))" on:connection];
		[self run:@"CREATE TABLE structure_test.base2 (extra int)" on:connection];
		[self run:@"CREATE TABLE structure_test.derived (more text NOT NULL) INHERITS (structure_test.base, structure_test.base2)" on:connection];

		NSString *parent = [self createStatementFor:@"pt" schema:@"structure_test" on:connection];
		XCTAssertTrue([parent hasPrefix:@"CREATE TABLE \"structure_test\".\"pt\" (\n    \"id\" integer NOT NULL,\n    \"created\" date NOT NULL,\n    \"note\" text\n)\nPARTITION BY RANGE (created);\n"], @"%@", parent);
		XCTAssertTrue([parent containsString:@"\n\nCREATE INDEX pt_note_idx ON structure_test.pt USING btree (note);\n"], @"plain ON, so partitions get it: %@", parent);
		XCTAssertTrue([parent containsString:@"\n\nCREATE TRIGGER pt_touch AFTER INSERT ON structure_test.pt FOR EACH ROW EXECUTE FUNCTION structure_test.touch();\n"], @"%@", parent);

		NSString *partition = [self createStatementFor:@"pt_2026" schema:@"structure_test" on:connection];
		XCTAssertEqualObjects(partition, @"CREATE TABLE \"structure_test\".\"pt_2026\" PARTITION OF \"structure_test\".\"pt\" (\n    CONSTRAINT \"pt_2026_id_check\" CHECK ((id > 0))\n)\n"
							  "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');\n", @"the parent's columns, index and trigger come with PARTITION OF");
		NSString *other = [self createStatementFor:@"pt_other" schema:@"structure_test" on:connection];
		XCTAssertEqualObjects(other, @"CREATE TABLE \"structure_test\".\"pt_other\" PARTITION OF \"structure_test\".\"pt\"\nDEFAULT;\n");

		// Recreated: the parent first, then its partitions
		NSDictionary *before2026 = [self snapshotOf:@"pt_2026" schema:@"structure_test" on:connection];
		NSDictionary *beforeOther = [self snapshotOf:@"pt_other" schema:@"structure_test" on:connection];
		[self roundTripTables:@[@"pt"] recreate:@[parent, partition, other] on:connection];
		XCTAssertEqualObjects([self snapshotOf:@"pt_2026" schema:@"structure_test" on:connection], before2026);
		XCTAssertEqualObjects([self snapshotOf:@"pt_other" schema:@"structure_test" on:connection], beforeOther);

		// Inheritance: the parents in order; the inherited columns and check come from them
		NSString *child = [self roundTrip:@"derived" schema:@"structure_test" kind:@"TABLE" on:connection];
		XCTAssertEqualObjects(child, @"CREATE TABLE \"structure_test\".\"derived\" (\n    \"more\" text NOT NULL\n)\nINHERITS (\"structure_test\".\"base\", \"structure_test\".\"base2\");\n");
		NSString *base = [self createStatementFor:@"base" schema:@"structure_test" on:connection];
		XCTAssertFalse([base containsString:@"INHERITS"], @"%@", base);
	}
}

/// Drops tables (snapshotting them first), runs the statements, and compares.
- (void)roundTripTables:(NSArray *)tables recreate:(NSArray *)statements on:(PGPostgresConnection *)connection
{
	NSMutableDictionary *before = [NSMutableDictionary dictionary];
	for (NSString *table in tables) before[table] = [self snapshotOf:table schema:@"structure_test" on:connection];
	for (NSString *table in tables) [self run:[NSString stringWithFormat:@"DROP TABLE structure_test.%@", table] on:connection];
	for (NSString *statement in statements) [self execute:statement on:connection];
	for (NSString *table in tables) XCTAssertEqualObjects([self snapshotOf:table schema:@"structure_test" on:connection], before[table], @"%@", table);
}

#pragma mark - Views

- (void)testViewAndMaterializedView
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"COMMENT ON VIEW structure_test.t_view IS 'the view'" on:connection];
		[self run:@"CREATE VIEW structure_test.checked WITH (security_barrier = true) AS SELECT id, qty FROM structure_test.t WHERE qty IS NOT NULL WITH LOCAL CHECK OPTION" on:connection];
		[self run:@"CREATE MATERIALIZED VIEW structure_test.mv AS SELECT id, code FROM structure_test.t" on:connection];
		[self run:@"CREATE UNIQUE INDEX mv_id_idx ON structure_test.mv (id)" on:connection];
		[self run:@"COMMENT ON COLUMN structure_test.mv.code IS 'mv code'" on:connection];
		[self run:@"CREATE MATERIALIZED VIEW structure_test.mv_empty AS SELECT id FROM structure_test.t WITH NO DATA" on:connection];

		NSString *view = [self roundTrip:@"t_view" schema:@"structure_test" kind:@"VIEW" on:connection];
		XCTAssertTrue([view hasPrefix:@"CREATE VIEW \"structure_test\".\"t_view\" AS\n SELECT "], @"%@", view);
		XCTAssertTrue([view containsString:@"FROM structure_test.t;\n\nCOMMENT ON VIEW \"structure_test\".\"t_view\" IS 'the view';\n"], @"%@", view);

		NSString *checked = [self roundTrip:@"checked" schema:@"structure_test" kind:@"VIEW" on:connection];
		XCTAssertTrue([checked hasPrefix:@"CREATE VIEW \"structure_test\".\"checked\" WITH (security_barrier=true) AS\n"], @"%@", checked);
		XCTAssertTrue([checked hasSuffix:@"\nWITH LOCAL CHECK OPTION;\n"], @"%@", checked);
		XCTAssertEqualObjects([self value:@"SELECT array_to_string(reloptions, ',') FROM pg_class WHERE oid = 'structure_test.checked'::regclass" on:connection], @"security_barrier=true,check_option=local");

		NSString *indexBefore = [self value:@"SELECT pg_get_indexdef('structure_test.mv_id_idx'::regclass)" on:connection];
		NSString *matview = [self roundTrip:@"mv" schema:@"structure_test" kind:@"MATERIALIZED VIEW" on:connection];
		XCTAssertTrue([matview hasPrefix:@"CREATE MATERIALIZED VIEW \"structure_test\".\"mv\" AS\n SELECT "], @"%@", matview);
		XCTAssertTrue([matview containsString:@"\n\nCREATE UNIQUE INDEX mv_id_idx ON structure_test.mv USING btree (id);\n"], @"%@", matview);
		XCTAssertTrue([matview containsString:@"\n\nCOMMENT ON COLUMN \"structure_test\".\"mv\".\"code\" IS 'mv code';\n"], @"%@", matview);
		XCTAssertFalse([matview containsString:@"NO DATA"], @"%@", matview);
		XCTAssertEqualObjects([self value:@"SELECT pg_get_indexdef('structure_test.mv_id_idx'::regclass)" on:connection], indexBefore);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::int FROM structure_test.mv" on:connection], @2);

		NSString *empty = [self roundTrip:@"mv_empty" schema:@"structure_test" kind:@"MATERIALIZED VIEW" on:connection];
		XCTAssertTrue([empty hasSuffix:@"\nWITH NO DATA;\n"], @"%@", empty);
		XCTAssertEqualObjects([self value:@"SELECT relispopulated::text FROM pg_class WHERE oid = 'structure_test.mv_empty'::regclass" on:connection], @"false");
	}
}

#pragma mark - NOT NULL

- (void)testNoNotNullConstraintDuplicatesOnPG18
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE TABLE structure_test.nn (a int NOT NULL, b text NOT NULL, c int, CONSTRAINT nn_c_check CHECK (c > 0))" on:connection];
		if ([self serverVersionOn:connection] >= 180000) {
			XCTAssertEqualObjects([self value:@"SELECT count(*)::int FROM pg_constraint WHERE conrelid = 'structure_test.nn'::regclass AND contype = 'n'" on:connection], @2,
								  @"PostgreSQL 18 records NOT NULL as constraints");
		}

		NSString *statement = [self roundTrip:@"nn" schema:@"structure_test" kind:@"TABLE" on:connection];
		XCTAssertEqualObjects(statement, @"CREATE TABLE \"structure_test\".\"nn\" (\n    \"a\" integer NOT NULL,\n    \"b\" text NOT NULL,\n    \"c\" integer,\n"
							  "    CONSTRAINT \"nn_c_check\" CHECK ((c > 0))\n);\n");
		XCTAssertEqual([[statement componentsSeparatedByString:@"NOT NULL"] count], 3u, @"once per column: %@", statement);
	}
}

/// PostgreSQL 18's NOT NULL constraints keep a name of their own, NO INHERIT and NOT VALID.
- (void)testNotNullConstraintDetailsOnPG18
{
	PGPostgresConnection *connection = [self connectOn:@55418];
	if ([self serverVersionOn:connection] < 180000) return;
	[self run:@"CREATE TABLE structure_test.nnx (a int CONSTRAINT my_a_nn NOT NULL NO INHERIT, b int NOT NULL, c int, \"Odd \"\"d\"\"\" int CONSTRAINT \"Odd nn\" NOT NULL)" on:connection];
	[self run:@"INSERT INTO structure_test.nnx VALUES (1, 1, NULL, 1)" on:connection];
	[self run:@"ALTER TABLE structure_test.nnx ADD CONSTRAINT c_nn NOT NULL c NOT VALID" on:connection];
	[self run:@"CREATE TABLE structure_test.nnx_rows AS SELECT * FROM structure_test.nnx" on:connection];

	NSString *statement = [self roundTrip:@"nnx" schema:@"structure_test" kind:@"TABLE" on:connection];
	XCTAssertEqualObjects(statement, @"CREATE TABLE \"structure_test\".\"nnx\" (\n"
						  "    \"a\" integer CONSTRAINT \"my_a_nn\" NOT NULL NO INHERIT,\n"
						  "    \"b\" integer NOT NULL,\n"
						  "    \"c\" integer,\n"
						  "    \"Odd \"\"d\"\"\" integer CONSTRAINT \"Odd nn\" NOT NULL\n"
						  ");\n\n"
						  "ALTER TABLE \"structure_test\".\"nnx\" ADD CONSTRAINT \"c_nn\" NOT NULL c NOT VALID;\n");

	// With the data, as a dump loads it: the table, its rows (c NULL), then the unvalidated constraint
	NSString *alter = @"ALTER TABLE \"structure_test\".\"nnx\" ADD CONSTRAINT \"c_nn\" NOT NULL c NOT VALID;\n";
	[self run:@"DROP TABLE structure_test.nnx" on:connection];
	[self execute:[statement stringByReplacingOccurrencesOfString:alter withString:@""] on:connection];
	[self run:@"INSERT INTO structure_test.nnx SELECT * FROM structure_test.nnx_rows" on:connection];
	[self execute:alter on:connection];
	XCTAssertEqualObjects([self value:@"SELECT count(*)::int FROM structure_test.nnx WHERE c IS NULL" on:connection], @1);
}

#pragma mark - Session and failures

/// Inside the user's transaction (with their own SET LOCAL search_path) and outside one, the session is left as it was.
- (void)testLeavesSessionAsItWas
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSString *path = [self value:@"SHOW search_path" on:connection];
		[self createStatementFor:@"t" schema:@"structure_test" on:connection];
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionIdle);
		XCTAssertEqualObjects([self value:@"SHOW search_path" on:connection], path);

		[self run:@"BEGIN" on:connection];
		[self run:@"SET LOCAL search_path = structure_test" on:connection];
		NSString *statement = [self createStatementFor:@"t" schema:@"structure_test" on:connection];
		XCTAssertTrue([statement containsString:@"CREATE INDEX t_amount_idx ON structure_test.t USING"], @"still qualified: %@", statement);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SHOW search_path" on:connection], @"structure_test");
		[self run:@"ROLLBACK" on:connection];
		XCTAssertEqualObjects([self value:@"SHOW search_path" on:connection], path);
	}
}

- (void)testMissingTableAndAbortedTransactionFail
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		XCTAssertNil([SPPostgresCreateStatement createStatementForTable:@"nope" inSchema:@"structure_test" connection:connection error:&error]);
		XCTAssertEqualObjects([error localizedDescription], @"There is no table “nope” in schema “structure_test”.");

		[self run:@"BEGIN" on:connection];
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		error = nil;
		XCTAssertNil([SPPostgresCreateStatement createStatementForTable:@"t" inSchema:@"structure_test" connection:connection error:&error]);
		XCTAssertTrue([[error localizedDescription] containsString:@"aborted"], @"%@", error);
		XCTAssertEqual([connection transactionStatus], PGPostgresTransactionInError);
		[self run:@"ROLLBACK" on:connection];
	}
}

#pragma mark - Table info (data)

- (void)testTableInfoData
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		[self run:@"CREATE TABLE structure_test.fresh (id int PRIMARY KEY)" on:connection];
		[self run:@"INSERT INTO structure_test.fresh VALUES (1), (2)" on:connection];
		SPPostgresTableStructure *fresh = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:@"structure_test" table:@"fresh"];
		NSError *error = nil;
		NSDictionary *info = [fresh tableInfo:&error];
		XCTAssertNotNil(info, @"%@", error);
		XCTAssertEqualObjects(info[@"kind"], @"table");
		XCTAssertEqualObjects(info[@"owner"], @"pgkit_test");
		XCTAssertEqualObjects(info[@"rowEstimate"], [NSNull null], @"never analysed");
		XCTAssertEqualObjects(info[@"comment"], [NSNull null]);
		XCTAssertEqualObjects(info[@"tableSize"], [self value:@"SELECT pg_size_pretty(pg_table_size('structure_test.fresh'))" on:connection]);
		XCTAssertEqualObjects(info[@"indexSize"], [self value:@"SELECT pg_size_pretty(pg_indexes_size('structure_test.fresh'))" on:connection]);
		XCTAssertEqualObjects(info[@"totalSize"], [self value:@"SELECT pg_size_pretty(pg_total_relation_size('structure_test.fresh'))" on:connection]);
		XCTAssertTrue([info[@"totalSize"] hasSuffix:@"kB"], @"%@", info[@"totalSize"]);

		[self run:@"ANALYZE structure_test.fresh" on:connection];
		XCTAssertEqualObjects([fresh tableInfo:&error][@"rowEstimate"], @2);

		SPPostgresTableStructure *t = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:@"structure_test" table:@"t"];
		XCTAssertEqualObjects([t tableInfo:&error][@"comment"], @"the t table");
		SPPostgresTableStructure *view = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:@"structure_test" table:@"t_view"];
		info = [view tableInfo:&error];
		XCTAssertEqualObjects(info[@"kind"], @"view");
		XCTAssertEqualObjects(info[@"rowEstimate"], [NSNull null]);

		SPPostgresTableStructure *gone = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:@"structure_test" table:@"gone"];
		error = nil;
		XCTAssertNil([gone tableInfo:&error]);
		XCTAssertEqualObjects([error localizedDescription], @"There is no table “gone” in schema “structure_test”.");
	}
}

@end
