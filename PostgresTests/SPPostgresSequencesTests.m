#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresSequences.h"
#import "../Source/Postgres/SPPostgresCatalog.h"
#import "../Source/Postgres/SPPostgresErrors.h"

/// Records every statement a connection is about to send (a PGPostgresConnection delegate seam).
@interface SPSequenceStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPSequenceStatementRecorder
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

/// SPPostgresSequences and the catalog's sequence list, on PG 12 and 18.
@interface SPPostgresSequencesTests : XCTestCase
@property (strong) NSMutableArray<PGPostgresConnection *> *openConnections;
@property (strong) NSMutableArray *recorders;
@end

@implementation SPPostgresSequencesTests

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

- (PGPostgresConnection *)connectOn:(NSNumber *)port recorder:(SPSequenceStatementRecorder **)recorder
{
	SPSequenceStatementRecorder *newRecorder = [[SPSequenceStatementRecorder alloc] init];
	[self.recorders addObject:newRecorder]; // the connection doesn't retain its delegate
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue database:@"pgkit_test" delegate:newRecorder];
	XCTAssertNotNil(connection);
	if (connection) [self.openConnections addObject:connection];
	*recorder = newRecorder;
	return connection;
}

- (SPPostgresSequences *)sequencesOn:(PGPostgresConnection *)connection
{
	return [[SPPostgresSequences alloc] initWithConnection:connection schema:@"structure_test"];
}

- (NSString *)value:(NSString *)sql on:(PGPostgresConnection *)connection
{
	PGPostgresResult *result = [connection execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, connection.lastError.errorPrimaryMessage);
	id value = [result textValueAtRow:0 column:0];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Statements that change something (anything but reads and transaction control).
- (NSArray *)changesIn:(NSArray<NSString *> *)statements
{
	NSMutableArray *changes = [NSMutableArray array];
	for (NSString *sql in statements) {
		NSString *upper = [sql uppercaseString];
		if ([upper hasPrefix:@"ALTER"] || [upper hasPrefix:@"CREATE"] || [upper hasPrefix:@"DROP"] || [upper hasPrefix:@"COMMENT"] || [upper containsString:@"SETVAL"]) {
			[changes addObject:sql];
		}
	}
	return changes;
}

- (SPPostgresSequence *)sequence:(NSString *)name of:(SPPostgresSequences *)sequences
{
	NSError *error = nil;
	SPPostgresSequence *sequence = [sequences sequenceNamed:name error:&error];
	XCTAssertNotNil(sequence, @"%@: %@", name, error);
	return sequence;
}

- (BOOL)exists:(NSString *)qualified on:(PGPostgresConnection *)connection
{
	NSString *sql = [NSString stringWithFormat:@"SELECT (to_regclass(%@) IS NOT NULL)::text", [self literal:qualified]];
	return [[self value:sql on:connection] isEqualToString:@"true"];
}

- (NSString *)literal:(NSString *)text
{
	return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

#pragma mark - Reading

- (void)testCatalogListsSequencesSorted
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresCatalog *catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];
		NSError *error = nil;
		XCTAssertEqualObjects([catalog sequenceNamesInSchema:@"structure_test" error:&error], (@[@"seq_free", @"seq_used", @"t_id_seq", @"t_ident_seq"]), @"%@: %@", port, error);
		XCTAssertTrue([[catalog sequenceNamesInSchema:@"Sales Data" error:&error] containsObject:@"Odd \"Seq\""], @"%@", error);
		XCTAssertFalse([[catalog tableNamesInSchema:@"Sales Data" error:&error] containsObject:@"Odd \"Seq\""], @"not a table");
		XCTAssertFalse([[catalog tableNamesInSchema:@"structure_test" error:&error] containsObject:@"seq_free"]);
		XCTAssertEqualObjects([catalog sequenceNamesInSchema:@"no such schema" error:&error], @[]);
	}
}

- (void)testSequenceDetails
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		SPPostgresSequences *sequences = [self sequencesOn:connection];

		SPPostgresSequence *free = [self sequence:@"seq_free" of:sequences];
		XCTAssertEqualObjects(free.schema, @"structure_test");
		XCTAssertEqualObjects(free.name, @"seq_free");
		XCTAssertEqualObjects(free.dataType, @"bigint");
		XCTAssertEqualObjects(free.start, @100);
		XCTAssertEqualObjects(free.increment, @5);
		XCTAssertEqualObjects(free.minValue, @1);
		XCTAssertEqualObjects(free.maxValue, @(LLONG_MAX));
		XCTAssertEqual([free.maxValue longLongValue], LLONG_MAX, @"bigint limits fit");
		XCTAssertEqualObjects(free.cache, @1);
		XCTAssertFalse(free.cycle);
		XCTAssertEqualObjects(free.comment, @"free");
		XCTAssertNil(free.lastValue, @"never called");
		XCTAssertFalse(free.isCalled);
		XCTAssertNil(free.ownedBy);
		XCTAssertFalse(free.isIdentity);
		XCTAssertNil(free.identityColumn);
		XCTAssertEqualObjects(free.owner, @"pgkit_test");

		XCTAssertEqualObjects([self value:@"SELECT nextval('structure_test.seq_free')::text" on:connection], @"100");
		free = [self sequence:@"seq_free" of:sequences];
		XCTAssertEqualObjects(free.lastValue, @100);
		XCTAssertTrue(free.isCalled);

		SPPostgresSequence *serial = [self sequence:@"t_id_seq" of:sequences];
		XCTAssertEqualObjects(serial.ownedBy, @"structure_test.t.id");
		XCTAssertEqualObjects(serial.dataType, @"integer");
		XCTAssertEqualObjects(serial.maxValue, @(INT32_MAX));
		XCTAssertFalse(serial.isIdentity);
		XCTAssertNil(serial.comment);

		SPPostgresSequence *identity = [self sequence:@"t_ident_seq" of:sequences];
		XCTAssertTrue(identity.isIdentity);
		XCTAssertEqualObjects(identity.identityColumn, @"structure_test.t.ident");
		XCTAssertNil(identity.ownedBy, @"identity is deptype i, not a");
		XCTAssertEqualObjects(identity.dataType, @"bigint");

		// A descending smallint sequence: negative bounds
		XCTAssertNotNil([connection execute:@"CREATE SEQUENCE structure_test.down AS smallint INCREMENT BY -1"]);
		SPPostgresSequence *down = [self sequence:@"down" of:sequences];
		XCTAssertEqualObjects(down.dataType, @"smallint");
		XCTAssertEqualObjects(down.increment, @-1);
		XCTAssertEqualObjects(down.minValue, @(INT16_MIN));
		XCTAssertEqualObjects(down.maxValue, @-1);
		XCTAssertEqualObjects(down.start, @-1);

		NSError *error = nil;
		XCTAssertNil([sequences sequenceNamed:@"nope" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"nope"], @"%@", error);
		XCTAssertNil([sequences sequenceNamed:@"t" error:&error], @"a table is not a sequence");
	}
}

- (void)testOwnerColumnCandidates
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		PGPostgresConnection *connection = [self connectOn:port];
		NSError *error = nil;
		NSArray *candidates = [[self sequencesOn:connection] ownerColumnCandidates:&error];
		// Integer columns of tables only (not t.code, not the view t_view)
		XCTAssertEqualObjects(candidates, (@[@"structure_test.child.id", @"structure_test.child.t_id", @"structure_test.t.Order", @"structure_test.t.gen",
											 @"structure_test.t.id", @"structure_test.t.ident", @"structure_test.used_t.n"]), @"%@: %@", port, error);
	}
}

#pragma mark - Create

- (void)testCreateWithAllOptionsAndOwnedBy
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSError *error = nil;

		SPPostgresSequenceDefinition *definition = [[SPPostgresSequenceDefinition alloc] init];
		definition.name = @"made";
		definition.dataType = @"integer";
		definition.increment = @-2;
		definition.minValue = @-1000;
		definition.maxValue = @50;
		definition.start = @10;
		definition.cache = @3;
		definition.cycle = YES;
		definition.ownedBy = @"structure_test.used_t.n";
		definition.comment = @"it's made";
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences createSequence:definition error:&error], @"%@: %@", port, error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[
			@"CREATE SEQUENCE \"structure_test\".\"made\" AS integer INCREMENT BY -2 MINVALUE -1000 MAXVALUE 50 START WITH 10 CACHE 3 CYCLE OWNED BY \"structure_test\".\"used_t\".\"n\"",
			@"COMMENT ON SEQUENCE \"structure_test\".\"made\" IS 'it''s made'"]));

		SPPostgresSequence *made = [self sequence:@"made" of:sequences];
		XCTAssertEqualObjects(made.dataType, @"integer");
		XCTAssertEqualObjects(made.increment, @-2);
		XCTAssertEqualObjects(made.minValue, @-1000);
		XCTAssertEqualObjects(made.maxValue, @50);
		XCTAssertEqualObjects(made.start, @10);
		XCTAssertEqualObjects(made.cache, @3);
		XCTAssertTrue(made.cycle);
		XCTAssertEqualObjects(made.ownedBy, @"structure_test.used_t.n");
		XCTAssertEqualObjects(made.comment, @"it's made");

		// Only a name: the server's defaults (no clause is sent for a nil number)
		SPPostgresSequenceDefinition *plain = [[SPPostgresSequenceDefinition alloc] init];
		plain.name = @"plain";
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences createSequence:plain error:&error], @"%@", error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[@"CREATE SEQUENCE \"structure_test\".\"plain\" NO CYCLE"]));
		SPPostgresSequence *plainSequence = [self sequence:@"plain" of:sequences];
		XCTAssertEqualObjects(plainSequence.dataType, @"bigint");
		XCTAssertEqualObjects(plainSequence.start, @1);
		XCTAssertNil(plainSequence.comment);

		// The whole bigint range, both signs
		SPPostgresSequenceDefinition *wide = [[SPPostgresSequenceDefinition alloc] init];
		wide.name = @"wide";
		wide.dataType = @"bigint";
		wide.minValue = @(LLONG_MIN);
		wide.maxValue = @(LLONG_MAX);
		wide.start = @(LLONG_MIN);
		wide.increment = @(LLONG_MAX);
		XCTAssertTrue([sequences createSequence:wide error:&error], @"%@", error);
		SPPostgresSequence *wideSequence = [self sequence:@"wide" of:sequences];
		XCTAssertEqual([wideSequence.minValue longLongValue], LLONG_MIN);
		XCTAssertEqual([wideSequence.maxValue longLongValue], LLONG_MAX);
		XCTAssertEqual([wideSequence.start longLongValue], LLONG_MIN);
		XCTAssertEqual([wideSequence.increment longLongValue], LLONG_MAX);

		// Refused before anything is sent: a type that isn't an integer type, a 64-byte name, an unknown column
		[recorder.statements removeAllObjects];
		SPPostgresSequenceDefinition *bad = [[SPPostgresSequenceDefinition alloc] init];
		bad.name = @"bad";
		bad.dataType = @"bigint; DROP TABLE structure_test.t";
		XCTAssertFalse([sequences createSequence:bad error:&error]);
		bad.dataType = nil;
		bad.name = [@"" stringByPaddingToLength:64 withString:@"x" startingAtIndex:0];
		XCTAssertFalse([sequences createSequence:bad error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"63 bytes"], @"%@", error);
		XCTAssertEqualObjects(recorder.statements, @[]);
		bad.name = @"bad";
		bad.ownedBy = @"structure_test.t.nope";
		XCTAssertFalse([sequences createSequence:bad error:&error]);
		XCTAssertEqualObjects([self changesIn:recorder.statements], @[]);
		XCTAssertFalse([self exists:@"structure_test.bad" on:connection]);

		// A server refusal (a name that is taken) creates nothing, and its comment isn't set
		SPPostgresSequenceDefinition *taken = [[SPPostgresSequenceDefinition alloc] init];
		taken.name = @"seq_free";
		taken.comment = @"replaced?";
		XCTAssertFalse([sequences createSequence:taken error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"already exists"], @"%@", error);
		XCTAssertEqualObjects([self sequence:@"seq_free" of:sequences].comment, @"free");
	}
}

#pragma mark - Alter

- (void)testAlterChangesOnlyWhatChangedAndRenames
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSError *error = nil;

		// Unchanged: no DDL
		SPPostgresSequenceDefinition *definition = [SPPostgresSequenceDefinition definitionWithSequence:[self sequence:@"seq_free" of:sequences]];
		XCTAssertEqualObjects(definition.name, @"seq_free");
		XCTAssertEqualObjects(definition.increment, @5);
		XCTAssertEqualObjects(definition.comment, @"free");
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:@"seq_free" to:definition error:&error], @"%@", error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], @[]);

		// One option
		definition.increment = @7;
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:@"seq_free" to:definition error:&error], @"%@", error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[@"ALTER SEQUENCE \"structure_test\".\"seq_free\" INCREMENT BY 7"]));
		XCTAssertEqualObjects([self sequence:@"seq_free" of:sequences].increment, @7);

		// Several options, the type, OWNED BY
		definition = [SPPostgresSequenceDefinition definitionWithSequence:[self sequence:@"seq_free" of:sequences]];
		definition.dataType = @"integer";
		definition.maxValue = @1000;
		definition.cycle = YES;
		definition.cache = @4;
		definition.start = @200;
		definition.minValue = nil; // already the default 1: not sent
		definition.ownedBy = @"structure_test.used_t.n";
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:@"seq_free" to:definition error:&error], @"%@", error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[@"ALTER SEQUENCE \"structure_test\".\"seq_free\" AS integer MAXVALUE 1000 START WITH 200 CACHE 4 CYCLE OWNED BY \"structure_test\".\"used_t\".\"n\""]));
		SPPostgresSequence *changed = [self sequence:@"seq_free" of:sequences];
		XCTAssertEqualObjects(changed.dataType, @"integer");
		XCTAssertEqualObjects(changed.maxValue, @1000);
		XCTAssertEqualObjects(changed.start, @200);
		XCTAssertEqualObjects(changed.cache, @4);
		XCTAssertTrue(changed.cycle);
		XCTAssertEqualObjects(changed.ownedBy, @"structure_test.used_t.n");

		// Back to defaults: NO MAXVALUE, NO CYCLE, OWNED BY NONE; then a rename and the comment cleared
		definition = [SPPostgresSequenceDefinition definitionWithSequence:changed];
		definition.maxValue = nil;
		definition.cycle = NO;
		definition.ownedBy = nil;
		definition.name = @"seq \"free\" 2";
		definition.comment = @"";
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:@"seq_free" to:definition error:&error], @"%@", error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[
			@"ALTER SEQUENCE \"structure_test\".\"seq_free\" NO MAXVALUE NO CYCLE OWNED BY NONE",
			@"ALTER SEQUENCE \"structure_test\".\"seq_free\" RENAME TO \"seq \"\"free\"\" 2\"",
			@"COMMENT ON SEQUENCE \"structure_test\".\"seq \"\"free\"\" 2\" IS NULL"]));
		XCTAssertNil([sequences sequenceNamed:@"seq_free" error:NULL]);
		SPPostgresSequence *renamed = [self sequence:@"seq \"free\" 2" of:sequences];
		XCTAssertEqualObjects(renamed.maxValue, @(INT32_MAX));
		XCTAssertFalse(renamed.cycle);
		XCTAssertNil(renamed.ownedBy);
		XCTAssertNil(renamed.comment);

		// A 64-byte name is refused before anything is sent
		definition = [SPPostgresSequenceDefinition definitionWithSequence:renamed];
		definition.name = [@"" stringByPaddingToLength:64 withString:@"y" startingAtIndex:0];
		definition.increment = @9;
		[recorder.statements removeAllObjects];
		XCTAssertFalse([sequences alterSequence:@"seq \"free\" 2" to:definition error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"63 bytes"], @"%@", error);
		XCTAssertEqualObjects(recorder.statements, @[]);

		// All or nothing: a refused option leaves the rename undone too
		definition.name = @"other";
		definition.minValue = @500; // above MAXVALUE
		XCTAssertFalse([sequences alterSequence:@"seq \"free\" 2" to:definition error:&error]);
		XCTAssertNotNil([sequences sequenceNamed:@"seq \"free\" 2" error:NULL]);
		XCTAssertNil([sequences sequenceNamed:@"other" error:NULL]);

		// A sequence that is gone
		XCTAssertFalse([sequences alterSequence:@"gone" to:definition error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"gone"], @"%@", error);
	}
}

- (void)testAlterIdentitySequenceGoesThroughColumnAndRefusesRename
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSError *error = nil;

		SPPostgresSequence *identity = [self sequence:@"t_ident_seq" of:sequences];
		SPPostgresSequenceDefinition *definition = [SPPostgresSequenceDefinition definitionWithSequence:identity];
		definition.increment = @3;
		definition.cache = @2;
		definition.maxValue = @100000;
		definition.cycle = YES;
		definition.start = @7;
		definition.comment = @"ident's";
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:@"t_ident_seq" to:definition error:&error], @"%@: %@", port, error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[
			@"ALTER TABLE \"structure_test\".\"t\" ALTER COLUMN \"ident\" SET INCREMENT BY 3 SET MAXVALUE 100000 SET START WITH 7 SET CACHE 2 SET CYCLE",
			@"COMMENT ON SEQUENCE \"structure_test\".\"t_ident_seq\" IS 'ident''s'"]));
		identity = [self sequence:@"t_ident_seq" of:sequences];
		XCTAssertEqualObjects(identity.increment, @3);
		XCTAssertEqualObjects(identity.maxValue, @100000);
		XCTAssertTrue(identity.cycle);
		XCTAssertTrue(identity.isIdentity);

		definition = [SPPostgresSequenceDefinition definitionWithSequence:identity];
		definition.maxValue = nil;
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:@"t_ident_seq" to:definition error:&error], @"%@", error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[@"ALTER TABLE \"structure_test\".\"t\" ALTER COLUMN \"ident\" SET NO MAXVALUE"]));

		// Rename, OWNED BY and the type are refused, and nothing is sent
		NSString *refusal = @"This sequence belongs to identity column t.ident; rename or detach it from the column.";
		[recorder.statements removeAllObjects];
		definition = [SPPostgresSequenceDefinition definitionWithSequence:identity];
		definition.name = @"renamed_ident";
		definition.increment = @4;
		XCTAssertFalse([sequences alterSequence:@"t_ident_seq" to:definition error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, refusal);
		definition.name = @"t_ident_seq";
		definition.ownedBy = @"structure_test.t.id";
		XCTAssertFalse([sequences alterSequence:@"t_ident_seq" to:definition error:&error]);
		XCTAssertEqualObjects(error.localizedDescription, refusal);
		definition.ownedBy = nil;
		definition.dataType = @"integer";
		XCTAssertFalse([sequences alterSequence:@"t_ident_seq" to:definition error:&error]);
		XCTAssertEqualObjects([self changesIn:recorder.statements], @[]);
		XCTAssertEqualObjects([self sequence:@"t_ident_seq" of:sequences].increment, @3);
	}
}

#pragma mark - Value

- (void)testSetValueNextCallReturnsIt
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSError *error = nil;

		XCTAssertTrue([sequences setValue:@500 isCalled:NO ofSequence:@"seq_free" error:&error], @"%@: %@", port, error);
		SPPostgresSequence *free = [self sequence:@"seq_free" of:sequences];
		XCTAssertFalse(free.isCalled);
		XCTAssertNil(free.lastValue);
		XCTAssertEqualObjects([self value:@"SELECT nextval('structure_test.seq_free')::text" on:connection], @"500");

		XCTAssertTrue([sequences setValue:@42 isCalled:YES ofSequence:@"seq_free" error:&error], @"%@", error);
		free = [self sequence:@"seq_free" of:sequences];
		XCTAssertTrue(free.isCalled);
		XCTAssertEqualObjects(free.lastValue, @42);
		XCTAssertEqualObjects([self value:@"SELECT nextval('structure_test.seq_free')::text" on:connection], @"47");

		// The bigint limit, and an odd name
		XCTAssertTrue([sequences setValue:@(LLONG_MAX) isCalled:YES ofSequence:@"seq_free" error:&error], @"%@", error);
		XCTAssertEqual([[self sequence:@"seq_free" of:sequences].lastValue longLongValue], LLONG_MAX);

		// Out of range: the server's message, nothing changes
		XCTAssertFalse([sequences setValue:@0 isCalled:YES ofSequence:@"seq_free" error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"out of bounds"], @"%@", error);
		XCTAssertEqual([[self sequence:@"seq_free" of:sequences].lastValue longLongValue], LLONG_MAX);
		XCTAssertFalse([sequences setValue:nil isCalled:YES ofSequence:@"seq_free" error:&error], @"a value is needed");
	}
}

#pragma mark - Drop

- (void)testDropSequenceInUseIsRefusedAndListsColumns
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSError *error = nil;

		XCTAssertEqualObjects([sequences columnsUsingSequence:@"seq_used" error:&error], @[@"structure_test.used_t.n"], @"%@: %@", port, error);
		XCTAssertEqualObjects([sequences columnsUsingSequence:@"t_id_seq" error:&error], @[@"structure_test.t.id"]);
		XCTAssertEqualObjects([sequences columnsUsingSequence:@"t_ident_seq" error:&error], @[@"structure_test.t.ident"]);
		XCTAssertEqualObjects([sequences columnsUsingSequence:@"seq_free" error:&error], @[]);

		// Another schema's column using it is listed too
		XCTAssertNotNil([connection execute:@"CREATE TABLE \"Sales Data\".\"uses seq\" (\"a b\" bigint DEFAULT nextval('structure_test.seq_used'))"]);
		XCTAssertEqualObjects([sequences columnsUsingSequence:@"seq_used" error:&error], (@[@"Sales Data.uses seq.a b", @"structure_test.used_t.n"]));

		for (NSString *name in @[@"seq_used", @"t_id_seq", @"t_ident_seq"]) {
			[recorder.statements removeAllObjects];
			XCTAssertFalse([sequences dropSequence:name error:&error], @"%@", name);
			XCTAssertEqualObjects(error.domain, SPPostgresErrorDomain);
			XCTAssertEqual(error.code, SPPostgresErrorHasDependents);
			NSString *expected = [NSString stringWithFormat:@"\"%@\" can't be deleted because these columns use it.", name];
			XCTAssertEqualObjects(error.localizedDescription, expected);
			XCTAssertEqualObjects(error.userInfo[SPPostgresDependentsErrorKey], [sequences columnsUsingSequence:name error:NULL]);
			XCTAssertEqualObjects([self changesIn:recorder.statements], @[], @"nothing sent");
			XCTAssertTrue([self exists:[@"structure_test." stringByAppendingString:name] on:connection]);
		}
		XCTAssertNotNil([connection execute:@"DROP TABLE \"Sales Data\".\"uses seq\""]);
	}
}

- (void)testDropFreeSequence
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSError *error = nil;

		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences dropSequence:@"seq_free" error:&error], @"%@: %@", port, error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[@"DROP SEQUENCE \"structure_test\".\"seq_free\""]));
		XCTAssertFalse([self exists:@"structure_test.seq_free" on:connection]);
		for (NSString *sql in recorder.statements) XCTAssertFalse([[sql uppercaseString] containsString:@"CASCADE"], @"%@", sql);

		XCTAssertFalse([sequences dropSequence:@"seq_free" error:&error], @"gone");
	}
}

#pragma mark - Odd identifiers

- (void)testOddSequenceName
{
	NSString *odd = @"Odd \"Seq\"";
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [[SPPostgresSequences alloc] initWithConnection:connection schema:@"Sales Data"];
		NSError *error = nil;

		SPPostgresSequence *sequence = [self sequence:odd of:sequences];
		XCTAssertEqualObjects(sequence.schema, @"Sales Data");
		XCTAssertEqualObjects(sequence.name, odd);
		XCTAssertEqualObjects([sequences columnsUsingSequence:odd error:&error], @[]);
		XCTAssertTrue([[sequences ownerColumnCandidates:&error] containsObject:@"Sales Data.Mixed Case.order"], @"%@", error);

		SPPostgresSequenceDefinition *definition = [SPPostgresSequenceDefinition definitionWithSequence:sequence];
		definition.increment = @2;
		definition.ownedBy = @"Sales Data.Mixed Case.order";
		definition.comment = @"odd's";
		[recorder.statements removeAllObjects];
		XCTAssertTrue([sequences alterSequence:odd to:definition error:&error], @"%@: %@", port, error);
		XCTAssertEqualObjects([self changesIn:recorder.statements], (@[
			@"ALTER SEQUENCE \"Sales Data\".\"Odd \"\"Seq\"\"\" INCREMENT BY 2 OWNED BY \"Sales Data\".\"Mixed Case\".\"order\"",
			@"COMMENT ON SEQUENCE \"Sales Data\".\"Odd \"\"Seq\"\"\" IS 'odd''s'"]));
		sequence = [self sequence:odd of:sequences];
		XCTAssertEqualObjects(sequence.ownedBy, @"Sales Data.Mixed Case.order");
		XCTAssertEqualObjects(sequence.comment, @"odd's");

		XCTAssertTrue([sequences setValue:@9 isCalled:NO ofSequence:odd error:&error], @"%@", error);
		XCTAssertEqualObjects([self value:@"SELECT nextval('\"Sales Data\".\"Odd \"\"Seq\"\"\"')::text" on:connection], @"9");

		definition = [SPPostgresSequenceDefinition definitionWithSequence:sequence];
		definition.name = @"Odd \"Seq\" 2";
		definition.ownedBy = nil;
		XCTAssertTrue([sequences alterSequence:odd to:definition error:&error], @"%@", error);
		XCTAssertNotNil([self sequence:@"Odd \"Seq\" 2" of:sequences]);
		definition.name = odd;
		XCTAssertTrue([sequences alterSequence:@"Odd \"Seq\" 2" to:definition error:&error], @"%@", error);

		SPPostgresSequenceDefinition *created = [[SPPostgresSequenceDefinition alloc] init];
		created.name = @"select";
		created.comment = @"reserved";
		XCTAssertTrue([sequences createSequence:created error:&error], @"%@", error);
		XCTAssertEqualObjects([self sequence:@"select" of:sequences].comment, @"reserved");
		XCTAssertTrue([sequences dropSequence:@"select" error:&error], @"%@", error);
		XCTAssertTrue([sequences dropSequence:odd error:&error], @"%@", error);
		XCTAssertNil([sequences sequenceNamed:odd error:NULL]);
	}
}

#pragma mark - Transactions

- (void)testChangesInsideUserTransactionKeepItOpen
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		SPSequenceStatementRecorder *recorder = nil;
		PGPostgresConnection *connection = [self connectOn:port recorder:&recorder];
		SPPostgresSequences *sequences = [self sequencesOn:connection];
		NSString *before = [self value:@"SHOW lock_timeout" on:connection];
		NSError *error = nil;

		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNotNil([connection execute:@"INSERT INTO structure_test.used_t DEFAULT VALUES"]);

		// A server refusal: the transaction stays open, with its row
		SPPostgresSequenceDefinition *definition = [SPPostgresSequenceDefinition definitionWithSequence:[self sequence:@"seq_free" of:sequences]];
		definition.increment = @0;
		XCTAssertFalse([sequences alterSequence:@"seq_free" to:definition error:&error]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction, @"%@", port);
		XCTAssertEqualObjects([self value:@"SELECT count(*)::text FROM structure_test.used_t" on:connection], @"1");
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);

		// In use: refused, still open
		XCTAssertFalse([sequences dropSequence:@"seq_used" error:&error]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);

		// Changes that succeed are part of the user's transaction
		definition.increment = @11;
		XCTAssertTrue([sequences alterSequence:@"seq_free" to:definition error:&error], @"%@", error);
		SPPostgresSequenceDefinition *created = [[SPPostgresSequenceDefinition alloc] init];
		created.name = @"in_tx";
		XCTAssertTrue([sequences createSequence:created error:&error], @"%@", error);
		XCTAssertTrue([sequences setValue:@3 isCalled:YES ofSequence:@"in_tx" error:&error], @"%@", error);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInTransaction);
		XCTAssertEqualObjects([self value:@"SHOW lock_timeout" on:connection], before);

		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
		XCTAssertEqualObjects([self sequence:@"seq_free" of:sequences].increment, @5);
		XCTAssertNil([sequences sequenceNamed:@"in_tx" error:NULL]);

		// An aborted transaction refuses every change without sending it
		XCTAssertNotNil([connection execute:@"BEGIN"]);
		XCTAssertNil([connection execute:@"SELECT 1/0"]);
		[recorder.statements removeAllObjects];
		XCTAssertFalse([sequences createSequence:created error:&error]);
		XCTAssertTrue([error.localizedDescription containsString:@"aborted"], @"%@", error);
		XCTAssertFalse([sequences setValue:@3 isCalled:YES ofSequence:@"seq_free" error:&error]);
		XCTAssertFalse([sequences dropSequence:@"seq_free" error:&error]);
		XCTAssertEqualObjects(recorder.statements, @[]);
		XCTAssertEqual(connection.transactionStatus, PGPostgresTransactionInError);
		XCTAssertNotNil([connection execute:@"ROLLBACK"]);
	}
}

@end
