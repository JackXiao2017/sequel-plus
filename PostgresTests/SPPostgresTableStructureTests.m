#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresTableStructure.h"
#import "../Source/Postgres/SPPostgresTableData.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPStructureStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPStructureStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	[self.statements addObject:[query description]];
}
@end

/// Counts KVO notifications.
@interface SPStructureObserver : NSObject
@property (nonatomic, strong) NSMutableArray *changes;
@end

@implementation SPStructureObserver
- (instancetype)init { if ((self = [super init])) _changes = [NSMutableArray array]; return self; }
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	[self.changes addObject:[NSString stringWithFormat:@"%@: %@ -> %@", keyPath, change[NSKeyValueChangeOldKey], change[NSKeyValueChangeNewKey]]];
}
@end

@interface SPPostgresTableStructureTests : XCTestCase
/// Closed in -tearDown, so a failed test can't leave a transaction holding locks that block the cleanup
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray *recorders;
@end

@implementation SPPostgresTableStructureTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.openConnections = [NSMutableArray array];
	self.recorders = [NSMutableArray array];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[SPPostgresTestServers loadStructureFixtureOnPort:port.unsignedIntegerValue];
	}
}

- (void)tearDown
{
	for (PGPostgresConnection *connection in self.openConnections) [connection disconnect];
	self.openConnections = nil;
	self.recorders = nil;

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

/// A connection whose sent statements are recorded in recorder.statements.
- (PGPostgresConnection *)connectOn:(NSNumber *)port recorder:(SPStructureStatementRecorder **)recorder
{
	SPStructureStatementRecorder *newRecorder = [[SPStructureStatementRecorder alloc] init];
	[self.recorders addObject:newRecorder]; // the connection doesn't retain its delegate
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:newRecorder];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	*recorder = newRecorder;
	return connection;
}

- (SPPostgresTableStructure *)structureOn:(PGPostgresConnection *)connection schema:(NSString *)schema table:(NSString *)table
{
	return [[SPPostgresTableStructure alloc] initWithConnection:connection schema:schema table:table];
}

- (SPPostgresTableStructure *)structureOn:(PGPostgresConnection *)connection table:(NSString *)table
{
	return [self structureOn:connection schema:@"structure_test" table:table];
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

- (id)named:(NSString *)name in:(NSArray *)objects
{
	for (id object in objects) {
		if ([[object name] isEqualToString:name]) return object;
	}
	return nil;
}

- (NSArray *)namesOf:(NSArray *)objects
{
	return [objects valueForKey:@"name"];
}

- (SPPostgresStructureColumn *)column:(NSString *)name of:(SPPostgresTableStructure *)structure
{
	NSError *error = nil;
	NSArray *columns = [structure columns:&error];
	XCTAssertNotNil(columns, @"%@", error);
	return [self named:name in:columns];
}

/// Statements that change something (anything but reads and transaction control).
- (NSArray *)changesIn:(NSArray<NSString *> *)statements
{
	NSMutableArray *changes = [NSMutableArray array];
	for (NSString *sql in statements) {
		NSString *upper = [sql uppercaseString];
		if ([upper hasPrefix:@"ALTER"] || [upper hasPrefix:@"CREATE"] || [upper hasPrefix:@"DROP"] || [upper hasPrefix:@"COMMENT"]) {
			[changes addObject:sql];
		}
	}
	return changes;
}

- (SPPostgresColumnDefinition *)definition:(NSString *)name type:(NSString *)type
{
	SPPostgresColumnDefinition *definition = [[SPPostgresColumnDefinition alloc] init];
	definition.name = name;
	definition.typeName = type;
	return definition;
}

#pragma mark - Reading

- (void)testColumnsReportTypesDefaultsAutoKindsAndComments
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		XCTAssertEqual(structure.lockTimeout, 5.0);

		NSError *error = nil;
		NSArray *columns = [structure columns:&error];
		XCTAssertNotNil(columns, @"%@", error);
		XCTAssertEqualObjects([self namesOf:columns], (@[@"id", @"code", @"qty", @"amount", @"Order", @"a \"q\" b", @"gen", @"ident"]));

		SPPostgresStructureColumn *idColumn = [self named:@"id" in:columns];
		XCTAssertEqualObjects(idColumn.autoKind, @"serial");
		XCTAssertEqualObjects(idColumn.typeName, @"integer");
		XCTAssertFalse(idColumn.nullable);
		XCTAssertTrue([idColumn.defaultExpression hasPrefix:@"nextval("], @"%@", idColumn.defaultExpression);
		XCTAssertEqual(idColumn.attnum, 1);

		SPPostgresStructureColumn *ident = [self named:@"ident" in:columns];
		XCTAssertEqualObjects(ident.autoKind, @"identity");
		XCTAssertEqualObjects(ident.typeName, @"bigint");
		XCTAssertNil(ident.defaultExpression);

		SPPostgresStructureColumn *gen = [self named:@"gen" in:columns];
		XCTAssertEqualObjects(gen.autoKind, @"generated");
		XCTAssertEqualObjects(gen.generationExpression, @"(id * 2)");
		XCTAssertNil(gen.defaultExpression);

		SPPostgresStructureColumn *amount = [self named:@"amount" in:columns];
		XCTAssertEqualObjects(amount.typeName, @"numeric(10,2)");
		XCTAssertEqualObjects(amount.defaultExpression, @"0");
		XCTAssertEqualObjects(amount.autoKind, @"");
		XCTAssertNil(amount.generationExpression);
		XCTAssertTrue(amount.nullable);

		XCTAssertEqualObjects([[self named:@"code" in:columns] comment], @"the code");
		XCTAssertNil([[self named:@"qty" in:columns] comment]);

		XCTAssertEqualObjects([structure tableComment:&error], @"the t table");
		XCTAssertEqualObjects([structure relationKind:&error], @"table");

		SPPostgresTableStructure *view = [self structureOn:connection table:@"t_view"];
		XCTAssertEqualObjects([view relationKind:&error], @"view");
		XCTAssertEqualObjects([self namesOf:[view columns:&error]], (@[@"code"]));
		XCTAssertEqualObjects([view indexes:&error], @[]);
		XCTAssertEqualObjects([view constraints:&error], @[]);
		XCTAssertNil([view tableComment:&error]);
	}
}

- (void)testIndexesAndConstraintsExcludeNotNullRows
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableStructure *structure = [self structureOn:[self connectOn:port] table:@"t"];
		NSError *error = nil;

		NSArray *indexes = [structure indexes:&error];
		XCTAssertNotNil(indexes, @"%@", error);
		XCTAssertEqualObjects([self namesOf:indexes], (@[@"t_amount_idx", @"t_code_key", @"t_pkey", @"t_qty_amount_idx"]));

		SPPostgresIndex *pkey = [self named:@"t_pkey" in:indexes];
		XCTAssertTrue(pkey.isPrimary);
		XCTAssertTrue(pkey.isUnique);
		XCTAssertEqualObjects(pkey.constraintName, @"t_pkey");
		XCTAssertEqualObjects(pkey.columns, @[@"id"]);
		XCTAssertEqualObjects(pkey.method, @"btree");

		SPPostgresIndex *codeKey = [self named:@"t_code_key" in:indexes];
		XCTAssertEqualObjects(codeKey.constraintName, @"t_code_key");
		XCTAssertTrue(codeKey.isUnique);
		XCTAssertFalse(codeKey.isPrimary);

		SPPostgresIndex *pair = [self named:@"t_qty_amount_idx" in:indexes];
		XCTAssertEqualObjects(pair.columns, (@[@"qty", @"amount"]));
		XCTAssertNil(pair.constraintName);
		XCTAssertFalse(pair.isUnique);
		XCTAssertTrue([pair.definition hasPrefix:@"CREATE INDEX t_qty_amount_idx ON structure_test.t USING btree"], @"%@", pair.definition);

		NSArray *constraints = [structure constraints:&error];
		XCTAssertNotNil(constraints, @"%@", error);
		XCTAssertEqualObjects([self namesOf:constraints], (@[@"t_amount_check", @"t_code_key", @"t_pkey"]));
		XCTAssertFalse([[constraints valueForKey:@"kind"] containsObject:@"NOT NULL"]);

		SPPostgresConstraint *check = [self named:@"t_amount_check" in:constraints];
		XCTAssertEqualObjects(check.kind, @"CHECK");
		XCTAssertTrue([check.definition containsString:@"amount >= "], @"%@", check.definition);
		XCTAssertEqualObjects(check.columns, @[@"amount"]);
		XCTAssertEqualObjects(((SPPostgresConstraint *)[self named:@"t_pkey" in:constraints]).kind, @"PRIMARY KEY");
		XCTAssertEqualObjects(((SPPostgresConstraint *)[self named:@"t_code_key" in:constraints]).kind, @"UNIQUE");
		XCTAssertEqualObjects([[self named:@"t_code_key" in:constraints] columns], @[@"code"]);
	}
}

- (void)testForeignKeyDetails
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableStructure *structure = [self structureOn:[self connectOn:port] table:@"child"];
		NSError *error = nil;
		NSArray *constraints = [structure constraints:&error];
		XCTAssertNotNil(constraints, @"%@", error);
		XCTAssertEqualObjects([self namesOf:constraints], (@[@"child_pkey", @"child_t_id_fkey"]));

		SPPostgresConstraint *fk = [self named:@"child_t_id_fkey" in:constraints];
		XCTAssertEqualObjects(fk.kind, @"FOREIGN KEY");
		XCTAssertEqualObjects(fk.columns, @[@"t_id"]);
		XCTAssertEqualObjects(fk.referencedSchema, @"structure_test");
		XCTAssertEqualObjects(fk.referencedTable, @"t");
		XCTAssertEqualObjects(fk.referencedColumns, @[@"id"]);
		XCTAssertEqualObjects(fk.onDelete, @"CASCADE");
		XCTAssertEqualObjects(fk.onUpdate, @"NO ACTION");
		XCTAssertTrue([fk.definition hasPrefix:@"FOREIGN KEY (t_id) REFERENCES"], @"%@", fk.definition);

		SPPostgresConstraint *pkey = [self named:@"child_pkey" in:constraints];
		XCTAssertNil(pkey.referencedTable);
		XCTAssertNil(pkey.onDelete);
	}
}

#pragma mark - Columns

- (void)testAddColumnVariants
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		SPPostgresColumnDefinition *note = [self definition:@"note" type:@"varchar(20)"];
		note.notNull = YES;
		note.defaultExpression = @"'x'";
		note.comment = @"it's a \\ note";
		XCTAssertTrue([structure addColumn:note error:&error], @"%@", error);
		SPPostgresStructureColumn *noteColumn = [self column:@"note" of:structure];
		XCTAssertEqualObjects(noteColumn.typeName, @"character varying(20)");
		XCTAssertFalse(noteColumn.nullable);
		XCTAssertEqualObjects(noteColumn.defaultExpression, @"'x'::character varying");
		XCTAssertEqualObjects(noteColumn.comment, @"it's a \\ note");
		XCTAssertEqualObjects([self value:@"SELECT string_agg(note, ',')::text FROM structure_test.t" on:connection], @"x,x");

		SPPostgresColumnDefinition *big = [self definition:@"big" type:@"bigint"];
		big.autoKind = @"serial";
		XCTAssertTrue([structure addColumn:big error:&error], @"%@", error);
		SPPostgresStructureColumn *bigColumn = [self column:@"big" of:structure];
		XCTAssertEqualObjects(bigColumn.typeName, @"bigint");
		XCTAssertEqualObjects(bigColumn.autoKind, @"serial");
		XCTAssertFalse(bigColumn.nullable);

		SPPostgresColumnDefinition *always = [self definition:@"always_id" type:@"int"];
		always.autoKind = @"identity always";
		XCTAssertTrue([structure addColumn:always error:&error], @"%@", error);
		XCTAssertEqualObjects([[self column:@"always_id" of:structure] autoKind], @"identity always");

		SPPostgresColumnDefinition *byDefault = [self definition:@"by_default" type:@"smallint"];
		byDefault.autoKind = @"identity";
		XCTAssertTrue([structure addColumn:byDefault error:&error], @"%@", error);
		XCTAssertEqualObjects([[self column:@"by_default" of:structure] autoKind], @"identity");

		[recorder.statements removeAllObjects];
		SPPostgresColumnDefinition *bad = [self definition:@"bad" type:@"text"];
		bad.autoKind = @"serial";
		error = nil;
		XCTAssertFalse([structure addColumn:bad error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, @"Only integer columns can be serial.");
		XCTAssertEqualObjects(recorder.statements, @[]);

		SPPostgresColumnDefinition *longName = [self definition:[@"" stringByPaddingToLength:64 withString:@"n" startingAtIndex:0] type:@"text"];
		XCTAssertFalse([structure addColumn:longName error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);
		XCTAssertNil([self column:@"bad" of:structure]);

		// A server error comes back with its message
		XCTAssertFalse([structure addColumn:[self definition:@"code" type:@"text"] error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"already exists"], @"%@", error);
		XCTAssertEqual(error.code, SPPostgresErrorQueryFailed);
	}
}

- (void)testRenameAndCommentAndNullAndDefault
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		XCTAssertTrue([structure renameColumn:@"qty" to:@"quantity" error:&error], @"%@", error);
		XCTAssertNil([self column:@"qty" of:structure]);
		XCTAssertNotNil([self column:@"quantity" of:structure]);

		[recorder.statements removeAllObjects];
		XCTAssertFalse([structure renameColumn:@"quantity" to:[@"" stringByPaddingToLength:64 withString:@"q" startingAtIndex:0] error:&error]);
		XCTAssertFalse([structure renameColumn:@"quantity" to:@"" error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);

		XCTAssertTrue([structure setComment:@"how 'many'" forColumn:@"quantity" error:&error], @"%@", error);
		XCTAssertEqualObjects([[self column:@"quantity" of:structure] comment], @"how 'many'");
		XCTAssertTrue([structure setComment:@"" forColumn:@"quantity" error:&error], @"%@", error);
		XCTAssertNil([[self column:@"quantity" of:structure] comment]);
		XCTAssertTrue([structure setComment:@"again" forColumn:@"quantity" error:&error], @"%@", error);
		XCTAssertTrue([structure setComment:nil forColumn:@"quantity" error:&error], @"%@", error);
		XCTAssertNil([[self column:@"quantity" of:structure] comment]);

		XCTAssertTrue([structure setNullable:NO forColumn:@"amount" error:&error], @"%@", error);
		XCTAssertFalse([[self column:@"amount" of:structure] nullable]);
		XCTAssertTrue([structure setNullable:YES forColumn:@"amount" error:&error], @"%@", error);
		XCTAssertTrue([[self column:@"amount" of:structure] nullable]);

		// "Order" has NULLs
		XCTAssertFalse([structure setNullable:NO forColumn:@"Order" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"contains null values"], @"%@", error);
		XCTAssertTrue([[self column:@"Order" of:structure] nullable]);

		XCTAssertTrue([structure setDefault:@"42" forColumn:@"amount" error:&error], @"%@", error);
		XCTAssertEqualObjects([[self column:@"amount" of:structure] defaultExpression], @"42");
		XCTAssertTrue([structure setDefault:nil forColumn:@"amount" error:&error], @"%@", error);
		XCTAssertNil([[self column:@"amount" of:structure] defaultExpression]);
		XCTAssertTrue([structure setDefault:@"'abc'" forColumn:@"quantity" error:&error], @"%@", error);
		XCTAssertTrue([structure setDefault:@"" forColumn:@"quantity" error:&error], @"%@", error);
		XCTAssertNil([[self column:@"quantity" of:structure] defaultExpression]);
	}
}

- (void)testChangeTypeNeedsUsingThenSucceedsWithIt
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		XCTAssertFalse([structure changeColumn:@"qty" toType:@"integer" using:nil error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"cannot be cast automatically"], @"%@", error);
		XCTAssertTrue([error.localizedDescription containsString:@"\nHINT: "], @"%@", error);
		XCTAssertEqualObjects([[self column:@"qty" of:structure] typeName], @"text");

		error = nil;
		XCTAssertTrue([structure changeColumn:@"qty" toType:@"integer" using:@"nullif(regexp_replace(\"qty\", '\\D', '', 'g'), '')::integer" error:&error], @"%@", error);
		XCTAssertEqualObjects([[self column:@"qty" of:structure] typeName], @"integer");
		XCTAssertEqualObjects([self column:@"SELECT qty::text FROM structure_test.t ORDER BY id" on:connection], (@[@"5", @"12"]));
	}
}

- (void)testDropColumnWithDependentsIsRefusedAndListsThem
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		NSDictionary *expected = @{
			@"code": @[@"constraint t_code_key on table structure_test.t", @"view structure_test.t_view"],
			@"amount": @[@"constraint t_amount_check on table structure_test.t", @"index structure_test.t_amount_idx",
						 @"index structure_test.t_qty_amount_idx"],
			@"qty": @[@"index structure_test.t_qty_amount_idx"],
		};
		for (NSString *name in expected) {
			XCTAssertEqualObjects([structure dependentsOfColumn:name error:&error], expected[name], @"%@ %@", name, error);
		}
		NSArray *idDependents = [structure dependentsOfColumn:@"id" error:&error];
		XCTAssertTrue([idDependents containsObject:@"constraint child_t_id_fkey on table structure_test.child"], @"%@", idDependents);
		XCTAssertTrue([idDependents containsObject:@"constraint t_pkey on table structure_test.t"], @"%@", idDependents);
		XCTAssertTrue([idDependents containsObject:@"column gen of table structure_test.t"], @"%@", idDependents);
		XCTAssertFalse([[idDependents componentsJoinedByString:@" "] containsString:@"sequence"], @"%@", idDependents);
		XCTAssertFalse([[idDependents componentsJoinedByString:@" "] containsString:@"default"], @"%@", idDependents);

		for (NSString *name in @[@"code", @"amount", @"id"]) {
			[recorder.statements removeAllObjects];
			error = nil;
			XCTAssertFalse([structure dropColumn:name error:&error], @"%@", name);
			XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
			XCTAssertEqual(error.code, SPPostgresErrorHasDependents);
			XCTAssertEqual(SPPostgresErrorHasDependents, 9);
			XCTAssertEqualObjects(error.localizedDescription, ([NSString stringWithFormat:@"\"%@\" can't be deleted because other objects depend on it.", name]));
			XCTAssertEqualObjects(error.userInfo[SPPostgresDependentsErrorKey], [structure dependentsOfColumn:name error:NULL]);
			XCTAssertEqualObjects([self changesIn:recorder.statements], @[], @"%@", recorder.statements);
			XCTAssertNotNil([self column:name of:structure], @"%@", name);
		}
	}
}

- (void)testDropFreeColumn
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableStructure *structure = [self structureOn:[self connectOn:port] table:@"t"];
		NSError *error = nil;
		XCTAssertEqualObjects([structure dependentsOfColumn:@"Order" error:&error], @[], @"%@", error);
		XCTAssertTrue([structure dropColumn:@"Order" error:&error], @"%@", error);
		XCTAssertNil([self column:@"Order" of:structure]);
		XCTAssertNotNil([self column:@"ident" of:structure]); // an identity column with its sequence is droppable too
		XCTAssertTrue([structure dropColumn:@"ident" error:&error], @"%@", error);
		XCTAssertNil([self column:@"ident" of:structure]);
	}
}

#pragma mark - Indexes and constraints

- (void)testAddAndDropIndexUniqueAndMethod
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		XCTAssertTrue([structure addIndexNamed:@"t_qty_hash" columns:@[@"qty"] unique:NO method:@"hash" error:&error], @"%@", error);
		SPPostgresIndex *hash = [self named:@"t_qty_hash" in:[structure indexes:&error]];
		XCTAssertEqualObjects(hash.method, @"hash");
		XCTAssertFalse(hash.isUnique);

		XCTAssertTrue([structure addIndexNamed:nil columns:(@[@"Order", @"a \"q\" b"]) unique:YES method:nil error:&error], @"%@", error);
		SPPostgresIndex *made = nil;
		for (SPPostgresIndex *index in [structure indexes:&error]) {
			if ([index.columns isEqual:(@[@"Order", @"a \"q\" b"])]) made = index;
		}
		XCTAssertNotNil(made);
		XCTAssertTrue(made.isUnique);
		XCTAssertEqualObjects(made.method, @"btree");
		XCTAssertNil(made.constraintName);

		[recorder.statements removeAllObjects];
		XCTAssertFalse([structure addIndexNamed:@"x" columns:@[@"qty"] unique:NO method:@"btree; DROP TABLE t" error:&error]);
		XCTAssertFalse([structure addIndexNamed:@"x" columns:@[] unique:NO method:nil error:&error]);
		XCTAssertFalse([structure addIndexNamed:[@"" stringByPaddingToLength:64 withString:@"i" startingAtIndex:0] columns:@[@"qty"] unique:NO method:nil error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);

		XCTAssertTrue([structure dropIndexNamed:@"t_qty_hash" error:&error], @"%@", error);
		XCTAssertTrue([structure dropIndexNamed:made.name error:&error], @"%@", error);
		XCTAssertNil([self named:@"t_qty_hash" in:[structure indexes:&error]]);
		XCTAssertNil([self named:made.name in:[structure indexes:&error]]);

		// The index behind a constraint: the constraint goes
		XCTAssertTrue([structure dropIndexNamed:@"t_code_key" error:&error], @"%@", error);
		XCTAssertNil([self named:@"t_code_key" in:[structure indexes:&error]]);
		XCTAssertNil([self named:@"t_code_key" in:[structure constraints:&error]]);
		XCTAssertTrue([[recorder.statements componentsJoinedByString:@"\n"] containsString:@"DROP CONSTRAINT \"t_code_key\""], @"%@", recorder.statements);
	}
}

- (void)testAddAndDropConstraintsAllKinds
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		XCTAssertNotNil([connection execute:@"CREATE TABLE structure_test.k (a int NOT NULL, b int, c int)"]);
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"k"];
		NSError *error = nil;

		SPPostgresConstraintDefinition *pk = [[SPPostgresConstraintDefinition alloc] init];
		pk.kind = @"PRIMARY KEY";
		pk.columns = @[@"a"];
		XCTAssertTrue([structure addConstraint:pk error:&error], @"%@", error);

		SPPostgresConstraintDefinition *unique = [[SPPostgresConstraintDefinition alloc] init];
		unique.kind = @"UNIQUE";
		unique.name = @"k b/c";
		unique.columns = @[@"b", @"c"];
		XCTAssertTrue([structure addConstraint:unique error:&error], @"%@", error);

		SPPostgresConstraintDefinition *check = [[SPPostgresConstraintDefinition alloc] init];
		check.kind = @"CHECK";
		check.name = @"k_c_pos";
		check.checkExpression = @"c > 0";
		XCTAssertTrue([structure addConstraint:check error:&error], @"%@", error);

		SPPostgresConstraintDefinition *fk = [[SPPostgresConstraintDefinition alloc] init];
		fk.kind = @"FOREIGN KEY";
		fk.name = @"k_b_fk";
		fk.columns = @[@"b"];
		fk.referencedSchema = @"structure_test";
		fk.referencedTable = @"t";
		fk.referencedColumns = @[@"id"];
		fk.onDelete = @"SET NULL";
		XCTAssertTrue([structure addConstraint:fk error:&error], @"%@", error);

		NSArray *constraints = [structure constraints:&error];
		XCTAssertEqualObjects([self namesOf:constraints], (@[@"k b/c", @"k_b_fk", @"k_c_pos", @"k_pkey"]));
		XCTAssertEqualObjects(((SPPostgresConstraint *)[self named:@"k_pkey" in:constraints]).kind, @"PRIMARY KEY");
		XCTAssertEqualObjects([[self named:@"k b/c" in:constraints] columns], (@[@"b", @"c"]));
		SPPostgresConstraint *readFK = [self named:@"k_b_fk" in:constraints];
		XCTAssertEqualObjects(readFK.onDelete, @"SET NULL");
		XCTAssertEqualObjects(readFK.onUpdate, @"NO ACTION");
		XCTAssertEqualObjects(readFK.referencedColumns, @[@"id"]);

		// Values that would go into the SQL unquoted are checked first
		[recorder.statements removeAllObjects];
		SPPostgresConstraintDefinition *badAction = [[SPPostgresConstraintDefinition alloc] init];
		badAction.kind = @"FOREIGN KEY";
		badAction.columns = @[@"c"];
		badAction.referencedTable = @"t";
		badAction.onDelete = @"CASCADE; DROP TABLE structure_test.t";
		XCTAssertFalse([structure addConstraint:badAction error:&error]);
		SPPostgresConstraintDefinition *badKind = [[SPPostgresConstraintDefinition alloc] init];
		badKind.kind = @"EXCLUDE";
		badKind.columns = @[@"c"];
		XCTAssertFalse([structure addConstraint:badKind error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);

		// Without a referenced schema, the table's own; without referenced columns, the primary key
		SPPostgresConstraintDefinition *fkDefaults = [[SPPostgresConstraintDefinition alloc] init];
		fkDefaults.kind = @"FOREIGN KEY";
		fkDefaults.columns = @[@"c"];
		fkDefaults.referencedTable = @"t";
		XCTAssertTrue([structure addConstraint:fkDefaults error:&error], @"%@", error);
		XCTAssertEqualObjects([[self named:@"k_c_fkey" in:[structure constraints:&error]] referencedColumns], @[@"id"]);

		for (NSString *name in @[@"k_c_fkey", @"k_b_fk", @"k_c_pos", @"k b/c", @"k_pkey"]) {
			XCTAssertTrue([structure dropConstraintNamed:name error:&error], @"%@: %@", name, error);
		}
		XCTAssertEqualObjects([structure constraints:&error], @[]);
		XCTAssertEqualObjects([structure indexes:&error], @[]);
	}
}

- (void)testDropReferencedPrimaryKeyFailsWithServerMessage
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;
		XCTAssertFalse([structure dropConstraintNamed:@"t_pkey" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"child"], @"%@", error);
		XCTAssertTrue([error.localizedDescription containsString:@"\nDETAIL: "], @"%@", error);
		XCTAssertFalse([[[recorder.statements componentsJoinedByString:@"\n"] uppercaseString] containsString:@"CASCADE"], @"%@", recorder.statements);
		XCTAssertNotNil([self named:@"t_pkey" in:[structure constraints:&error]]);
		XCTAssertFalse([structure dropIndexNamed:@"t_pkey" error:&error]);
		XCTAssertNotNil([self named:@"t_pkey" in:[structure indexes:&error]]);
	}
}

#pragma mark - Table

- (void)testReadsOfMissingRelationFail
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSString *expected = @"There is no table “gone” in schema “structure_test”.";

		for (SPPostgresTableStructure *structure in @[[self structureOn:connection table:@"gone"],
													  [self structureOn:connection schema:@"no such schema" table:@"t"]]) {
			NSString *message = [structure.schema isEqualToString:@"structure_test"] ? expected
				: @"There is no table “t” in schema “no such schema”.";
			NSError *error = nil;
			XCTAssertNil([structure columns:&error]);
			XCTAssertEqualObjects(error.localizedDescription, message);
			error = nil;
			XCTAssertNil([structure indexes:&error]);
			XCTAssertEqualObjects(error.localizedDescription, message);
			error = nil;
			XCTAssertNil([structure constraints:&error]);
			XCTAssertEqualObjects(error.localizedDescription, message);
			error = nil;
			XCTAssertNil([structure tableComment:&error]);
			XCTAssertEqualObjects(error.localizedDescription, message);
			error = nil;
			XCTAssertNil([structure relationKind:&error]);
			XCTAssertEqualObjects(error.localizedDescription, message);
			error = nil;
			XCTAssertNil([structure dependentsOfColumn:@"id" error:&error]);
			XCTAssertEqualObjects(error.localizedDescription, message);
		}

		// An existing table without comment, indexes or constraints still reads as empty, without an error
		XCTAssertNotNil([connection execute:@"CREATE TABLE structure_test.bare ()"]);
		SPPostgresTableStructure *bare = [self structureOn:connection table:@"bare"];
		NSError *error = nil;
		XCTAssertEqualObjects([bare columns:&error], @[]);
		XCTAssertNil(error);
		XCTAssertEqualObjects([bare indexes:&error], @[]);
		XCTAssertEqualObjects([bare constraints:&error], @[]);
		XCTAssertNil([bare tableComment:&error]);
		XCTAssertNil(error);

		// A rename inside the user's transaction, rolled back: the old name is gone from the object's view
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertTrue([structure renameTableTo:@"gone" error:&error], @"%@", error);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertNil([structure columns:&error]);
		XCTAssertEqualObjects(error.localizedDescription, expected);
	}
}

- (void)testRenameTableNotifiesObservers
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPPostgresTableStructure *structure = [self structureOn:[self connectOn:port] table:@"t"];
		SPStructureObserver *observer = [[SPStructureObserver alloc] init];
		[structure addObserver:observer forKeyPath:@"table" options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:NULL];
		NSError *error = nil;
		XCTAssertTrue([structure renameTableTo:@"t_renamed" error:&error], @"%@", error);
		XCTAssertFalse([structure renameTableTo:@"t_renamed" error:&error]); // same name: the server refuses, no notification
		[structure removeObserver:observer forKeyPath:@"table"];
		XCTAssertEqualObjects(observer.changes, @[@"table: t -> t_renamed"]);
	}
}

- (void)testRenameTableAndTableComment
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		XCTAssertTrue([structure setTableComment:@"it's new" error:&error], @"%@", error);
		XCTAssertEqualObjects([structure tableComment:&error], @"it's new");
		XCTAssertTrue([structure setTableComment:nil error:&error], @"%@", error);
		XCTAssertNil([structure tableComment:&error]);

		SPPostgresTableStructure *view = [self structureOn:connection table:@"t_view"];
		XCTAssertTrue([view setTableComment:@"a view" error:&error], @"%@", error);
		XCTAssertEqualObjects([view tableComment:&error], @"a view");

		[recorder.statements removeAllObjects];
		XCTAssertFalse([structure renameTableTo:[@"" stringByPaddingToLength:64 withString:@"t" startingAtIndex:0] error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"63 bytes"], @"%@", error);
		XCTAssertEqualObjects(recorder.statements, @[]);

		NSString *newName = @"Renamed \"T\"";
		XCTAssertTrue([structure renameTableTo:newName error:&error], @"%@", error);
		XCTAssertEqualObjects(structure.table, newName);
		XCTAssertEqualObjects([self value:@"SELECT to_regclass('structure_test.\"Renamed \"\"T\"\"\"')::text" on:connection], @"structure_test.\"Renamed \"\"T\"\"\"");
		XCTAssertNotNil([self column:@"code" of:structure]);
	}
}

- (void)testOddIdentifiersEverywhere
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection schema:@"Sales Data" table:@"Mixed Case"];
		NSError *error = nil;
		NSString *odd = @"a \"q\" b";
		NSString *renamed = @"Select \"x\"";

		XCTAssertTrue([structure addColumn:[self definition:odd type:@"text"] error:&error], @"%@", error);
		XCTAssertTrue([structure renameColumn:odd to:renamed error:&error], @"%@", error);
		XCTAssertTrue([structure changeColumn:renamed toType:@"varchar(10)" using:nil error:&error], @"%@", error);
		XCTAssertTrue([structure setComment:@"odd one" forColumn:renamed error:&error], @"%@", error);
		XCTAssertTrue([structure setDefault:@"'d'" forColumn:renamed error:&error], @"%@", error);
		XCTAssertTrue([structure setNullable:NO forColumn:@"select" error:&error], @"%@", error); // the table is empty
		XCTAssertFalse([[self column:@"select" of:structure] nullable]);
		XCTAssertTrue([structure setNullable:YES forColumn:@"select" error:&error], @"%@", error);
		SPPostgresStructureColumn *column = [self column:renamed of:structure];
		XCTAssertEqualObjects(column.typeName, @"character varying(10)");
		XCTAssertEqualObjects(column.comment, @"odd one");

		XCTAssertTrue([structure addIndexNamed:@"odd \"idx\"" columns:(@[renamed, @"order"]) unique:YES method:nil error:&error], @"%@", error);
		SPPostgresIndex *index = [self named:@"odd \"idx\"" in:[structure indexes:&error]];
		XCTAssertEqualObjects(index.columns, (@[renamed, @"order"]));
		XCTAssertEqualObjects([structure dependentsOfColumn:renamed error:&error], @[@"index \"Sales Data\".\"odd \"\"idx\"\"\""], @"%@", error);
		XCTAssertTrue([structure dropIndexNamed:@"odd \"idx\"" error:&error], @"%@", error);

		SPPostgresConstraintDefinition *check = [[SPPostgresConstraintDefinition alloc] init];
		check.kind = @"CHECK";
		check.name = @"Odd \"check\"";
		check.checkExpression = @"\"order\" > 0";
		XCTAssertTrue([structure addConstraint:check error:&error], @"%@", error);
		XCTAssertTrue([structure dropConstraintNamed:@"Odd \"check\"" error:&error], @"%@", error);

		XCTAssertTrue([structure dropColumn:renamed error:&error], @"%@", error);
		XCTAssertEqualObjects([self namesOf:[structure columns:&error]], (@[@"order", @"select"]));
		XCTAssertEqualObjects([[[structure constraints:&error] firstObject] name], @"Mixed Case_pkey");
	}
}

#pragma mark - Transactions and locks

- (void)testFailedChangeInsideUserTransactionKeepsItOpen
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSString *before = [self value:@"SHOW lock_timeout" on:connection];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNotNil([connection execute:@"INSERT INTO structure_test.t (qty) VALUES ('77')"]);

		XCTAssertFalse([structure changeColumn:@"qty" toType:@"integer" using:nil error:&error]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM structure_test.t WHERE qty = '77'" on:connection], @"1");
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);

		// A successful change stays part of the user's transaction
		XCTAssertTrue([structure addColumn:[self definition:@"in_tx" type:@"int"] error:&error], @"%@", error);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);
		XCTAssertNotNil([self column:@"in_tx" of:structure]);

		// Refused with dependents: still open
		XCTAssertFalse([structure dropColumn:@"code" error:&error]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);

		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertNil([self column:@"in_tx" of:structure]);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM structure_test.t WHERE qty = '77'" on:connection], @"0");
	}
}

- (void)testAbortedTransactionRefusesChanges
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInError);
		[recorder.statements removeAllObjects];

		XCTAssertFalse([structure addColumn:[self definition:@"nope" type:@"int"] error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"aborted"], @"%@", error);
		XCTAssertFalse([structure dropColumn:@"Order" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"aborted"], @"%@", error);
		XCTAssertFalse([structure renameTableTo:@"t3" error:&error]);
		XCTAssertFalse([structure dropIndexNamed:@"t_amount_idx" error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInError);

		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertNil([self column:@"nope" of:structure]);
		XCTAssertNotNil([self column:@"Order" of:structure]);
	}
}

- (void)testLockHeldElsewhereTimesOutAndRestoresSetting
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		PGPostgresConnection *other = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		structure.lockTimeout = 1;
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"SET lock_timeout = '7s'"]);
		NSString *before = [self value:@"SHOW lock_timeout" on:connection];
		XCTAssertEqualObjects(before, @"7s");

		XCTAssertNotNil([other execute:@"BEGIN"]);
		XCTAssertNotNil([other execute:@"LOCK TABLE structure_test.t IN ACCESS SHARE MODE"]);

		NSDate *start = [NSDate date];
		XCTAssertFalse([structure addColumn:[self definition:@"blocked" type:@"int"] error:&error]);
		XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 5.0);
		XCTAssertTrue([error.localizedDescription containsString:@"lock timeout"], @"%@", error);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionIdle);

		// Inside the user's transaction too
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		start = [NSDate date];
		XCTAssertFalse([structure setNullable:NO forColumn:@"id" error:&error]);
		XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 5.0);
		XCTAssertTrue([error.localizedDescription containsString:@"lock timeout"], @"%@", error);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);

		XCTAssertNotNil([other execute:@"ROLLBACK"]);

		// And after a success
		XCTAssertTrue([structure addColumn:[self definition:@"free" type:@"int"] error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);
	}
}

- (void)testDropColumnLocksTableBeforeCheckingDependents
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPStructureStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		PGPostgresConnection *other = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		structure.lockTimeout = 1;
		NSError *error = nil;

		// Locked elsewhere: it times out on the lock, before the dependents are even read
		XCTAssertNotNil([other execute:@"BEGIN"]);
		XCTAssertNotNil([other execute:@"LOCK TABLE structure_test.t IN ACCESS SHARE MODE"]);
		[recorder.statements removeAllObjects];
		NSDate *start = [NSDate date];
		XCTAssertFalse([structure dropColumn:@"Order" error:&error]);
		XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 5.0);
		XCTAssertTrue([error.localizedDescription containsString:@"lock timeout"], @"%@", error);
		NSString *sent = [recorder.statements componentsJoinedByString:@"\n"];
		XCTAssertTrue([sent containsString:@"LOCK TABLE \"structure_test\".\"t\" IN ACCESS EXCLUSIVE MODE"], @"%@", sent);
		XCTAssertFalse([sent containsString:@"pg_depend"], @"%@", sent);
		XCTAssertNotNil([other execute:@"ROLLBACK"]);

		// Unlocked: LOCK, then the dependents, then the drop
		[recorder.statements removeAllObjects];
		XCTAssertTrue([structure dropColumn:@"Order" error:&error], @"%@", error);
		NSUInteger lock = NSNotFound, depend = NSNotFound, drop = NSNotFound;
		for (NSUInteger i = 0; i < recorder.statements.count; i++) {
			NSString *sql = recorder.statements[i];
			if (lock == NSNotFound && [sql hasPrefix:@"LOCK TABLE"]) lock = i;
			if (depend == NSNotFound && [sql containsString:@"pg_depend"]) depend = i;
			if (drop == NSNotFound && [sql containsString:@"DROP COLUMN"]) drop = i;
		}
		XCTAssertTrue(lock != NSNotFound && depend != NSNotFound && drop != NSNotFound, @"%@", recorder.statements);
		XCTAssertLessThan(lock, depend);
		XCTAssertLessThan(depend, drop);
	}
}

- (void)testUserSetLocalLockTimeoutSurvivesAChange
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresTableStructure *structure = [self structureOn:connection table:@"t"];
		NSError *error = nil;
		XCTAssertNotNil([connection execute:@"SET lock_timeout = '9s'"]);

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNotNil([connection execute:@"SET LOCAL lock_timeout = '3s'"]);
		XCTAssertTrue([structure addColumn:[self definition:@"local_one" type:@"int"] error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], @"3s");
		XCTAssertFalse([structure changeColumn:@"qty" toType:@"integer" using:nil error:&error]);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], @"3s");
		XCTAssertNotNil([connection execute:@"COMMIT"]);

		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], @"9s");
		XCTAssertNotNil([self column:@"local_one" of:structure]);
	}
}

@end
