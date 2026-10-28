#import "SPPostgresTableDuplicator.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

/// PostgreSQL's identifier limit (NAMEDATALEN - 1), in bytes
static const NSUInteger SPPostgresMaximumIdentifierLength = 63;

static NSError *SPPostgresDuplicatorError(NSString *message)
{
	return [NSError errorWithDomain:SPPostgresErrorDomain code:SPPostgresErrorQueryFailed userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// YES for an optionally signed run of digits (a catalog number put into DDL, which takes no parameters).
static BOOL SPPostgresIsInteger(id value)
{
	if (![value isKindOfClass:[NSString class]] || ![value length]) return NO;
	NSString *digits = [value hasPrefix:@"-"] ? [value substringFromIndex:1] : value;
	return [digits length] && [digits rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound
		&& [digits canBeConvertedToEncoding:NSASCIIStringEncoding];
}

@implementation SPPostgresTableDuplicator

#pragma mark - Helpers

/// Every row of the query as an array of NSString / NSNull (the query selects text), or nil on failure.
+ (NSArray *)rowsOf:(NSString *)sql values:(NSArray *)values connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	PGPostgresResult *result = SPPostgresExecute(connection, sql, values, error);
	if (!result) return nil;

	NSMutableArray *rows = [NSMutableArray arrayWithCapacity:(NSUInteger)[result numberOfRows]];
	for (unsigned long long row = 0; row < [result numberOfRows]; row++) {
		NSMutableArray *fields = [NSMutableArray arrayWithCapacity:[result numberOfFields]];
		for (NSUInteger column = 0; column < [result numberOfFields]; column++) {
			id value = [result textValueAtRow:row column:column];
			[fields addObject:[value isKindOfClass:[NSString class]] ? value : [NSNull null]];
		}
		[rows addObject:fields];
	}
	return rows;
}

/// @[oid, relkind] of schema.name, @[] if there is no such relation, nil on failure.
+ (NSArray *)relation:(NSString *)name inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	NSArray *rows = [self rowsOf:@"SELECT c.oid::text, c.relkind::text FROM pg_catalog.pg_class c "
					 "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1::text AND c.relname = $2::text"
						  values:@[schema, name] connection:connection error:error];
	if (!rows) return nil;
	return [rows count] ? [rows firstObject] : @[];
}

/// "schema"."name"
+ (NSString *)qualified:(NSString *)name schema:(NSString *)schema
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(schema), SPPostgresQuoteIdentifier(name)];
}

/// name, shortened (by whole characters) so that name + suffix fits PostgreSQL's identifier limit.
+ (NSString *)name:(NSString *)name fittingWithSuffix:(NSString *)suffix
{
	NSUInteger suffixLength = [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	while ([name length] && [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + suffixLength > SPPostgresMaximumIdentifierLength) {
		NSRange last = [name rangeOfComposedCharacterSequenceAtIndex:[name length] - 1];
		name = [name substringToIndex:last.location];
	}
	return [name stringByAppendingString:suffix];
}

/// <table>_<column>_seq, or with 1, 2, … appended while that name is taken in the schema (as PostgreSQL names serial sequences).
+ (NSString *)sequenceNameForTable:(NSString *)table column:(NSString *)column schema:(NSString *)schema
						connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	NSString *base = [NSString stringWithFormat:@"%@_%@", table, column];
	for (NSUInteger attempt = 0; attempt < 1000; attempt++) {
		NSString *suffix = attempt ? [NSString stringWithFormat:@"_seq%lu", (unsigned long)attempt] : @"_seq";
		NSString *candidate = [self name:base fittingWithSuffix:suffix];
		NSArray *existing = [self relation:candidate inSchema:schema connection:connection error:error];
		if (!existing) return nil;
		if (![existing count]) return candidate;
	}
	if (error) *error = SPPostgresDuplicatorError(NSLocalizedString(@"Could not find a free name for the copy's sequence.", @"Postgres duplicate table: no free sequence name"));
	return nil;
}

#pragma mark - Duplicating

+ (BOOL)isValidTableName:(NSString *)name
{
	return [name length] > 0 && [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= SPPostgresMaximumIdentifierLength;
}

+ (BOOL)duplicateTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName withContent:(BOOL)withContent
			connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	if (![table length] || ![schema length] || ![newName length]) {
		if (error) *error = SPPostgresDuplicatorError(NSLocalizedString(@"The table and the new name must not be empty.", @"Postgres duplicate table: empty name"));
		return NO;
	}
	if (![self isValidTableName:newName]) {
		if (error) *error = SPPostgresDuplicatorError([NSString stringWithFormat:NSLocalizedString(@"The name “%@” is too long: PostgreSQL names can be at most 63 bytes.", @"Postgres duplicate table: name too long"), newName]);
		return NO;
	}

	NSString *aborted = NSLocalizedString(@"The current transaction is aborted, so the table was not duplicated. Roll it back first.", @"Postgres duplicate table inside an aborted transaction");

	return SPPostgresRunAtomically(connection, @"sp_duplicate_table", aborted, ^BOOL(NSError **bodyError) {
		return [self _duplicateTable:table inSchema:schema toName:newName withContent:withContent connection:connection error:bodyError];
	}, error);
}

/// The work of +duplicateTable:…, inside the transaction or savepoint.
+ (BOOL)_duplicateTable:(NSString *)table inSchema:(NSString *)schema toName:(NSString *)newName withContent:(BOOL)withContent
			 connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	NSArray *source = [self relation:table inSchema:schema connection:connection error:error];
	if (!source) return NO;
	if (![source count]) {
		if (error) *error = SPPostgresDuplicatorError([NSString stringWithFormat:NSLocalizedString(@"There is no table “%@” in schema “%@”.", @"Postgres duplicate table: no such table"), table, schema]);
		return NO;
	}
	NSString *sourceOid = [source objectAtIndex:0];
	NSString *kind = [source objectAtIndex:1];
	if ([kind isEqualToString:@"p"]) {
		// LIKE would make an ordinary, empty-partitioned table of it, losing the partitioning
		if (error) *error = SPPostgresDuplicatorError([NSString stringWithFormat:NSLocalizedString(@"“%@” is a partitioned table. Duplicating partitioned tables is not supported.", @"Postgres duplicate table: partitioned table"), table]);
		return NO;
	}
	if (![kind isEqualToString:@"r"]) {
		if (error) *error = SPPostgresDuplicatorError([NSString stringWithFormat:NSLocalizedString(@"“%@” is not a table. Only tables can be duplicated.", @"Postgres duplicate table: not a table"), table]);
		return NO;
	}

	// Serial columns: a default of nextval() on a sequence the column owns. LIKE copies the default as it is,
	// so the copy would share the original's sequence.
	NSArray *serials = [self rowsOf:
		@"SELECT a.attname::text, sn.nspname::text, s.relname::text, format_type(q.seqtypid, NULL)::text, q.seqincrement::text, "
		"q.seqmin::text, q.seqmax::text, q.seqstart::text, q.seqcache::text, q.seqcycle::text "
		"FROM pg_catalog.pg_attribute a "
		"JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum "
		"JOIN pg_catalog.pg_depend dd ON dd.classid = 'pg_catalog.pg_attrdef'::regclass AND dd.objid = ad.oid AND dd.refclassid = 'pg_catalog.pg_class'::regclass "
		"JOIN pg_catalog.pg_class s ON s.oid = dd.refobjid AND s.relkind = 'S' "
		"JOIN pg_catalog.pg_depend od ON od.classid = 'pg_catalog.pg_class'::regclass AND od.objid = s.oid AND od.refclassid = 'pg_catalog.pg_class'::regclass "
		"AND od.refobjid = a.attrelid AND od.refobjsubid = a.attnum AND od.deptype = 'a' "
		"JOIN pg_catalog.pg_namespace sn ON sn.oid = s.relnamespace "
		"JOIN pg_catalog.pg_sequence q ON q.seqrelid = s.oid "
		"WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attidentity = '' ORDER BY a.attnum"
							 values:@[sourceOid] connection:connection error:error];
	if (!serials) return NO;

	// Identity columns' sequences (LIKE gives the copy new ones, starting afresh)
	NSString *identitySQL =
		@"SELECT a.attname::text, a.attidentity::text, sn.nspname::text, s.relname::text "
		"FROM pg_catalog.pg_attribute a "
		"JOIN pg_catalog.pg_depend d ON d.classid = 'pg_catalog.pg_class'::regclass AND d.refclassid = 'pg_catalog.pg_class'::regclass "
		"AND d.refobjid = a.attrelid AND d.refobjsubid = a.attnum AND d.deptype = 'i' "
		"JOIN pg_catalog.pg_class s ON s.oid = d.objid AND s.relkind = 'S' "
		"JOIN pg_catalog.pg_namespace sn ON sn.oid = s.relnamespace "
		"WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attidentity <> '' ORDER BY a.attnum";
	NSArray *identities = [self rowsOf:identitySQL values:@[sourceOid] connection:connection error:error];
	if (!identities) return NO;

	// The columns rows are copied through: not generated ones (stored or virtual), which are computed again
	NSArray *insertable = [self rowsOf:@"SELECT a.attname::text FROM pg_catalog.pg_attribute a "
							"WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '' ORDER BY a.attnum"
								values:@[sourceOid] connection:connection error:error];
	if (!insertable) return NO;

	NSString *sourceName = [self qualified:table schema:schema];
	NSString *targetName = [self qualified:newName schema:schema];

	if (!SPPostgresExecute(connection, [NSString stringWithFormat:@"CREATE TABLE %@ (LIKE %@ INCLUDING ALL)", targetName, sourceName], nil, error)) return NO;

	// The copy, by its quoted name (never looked up by a relname the server might have truncated)
	NSArray *targetRows = [self rowsOf:@"SELECT $1::regclass::oid::text" values:@[targetName] connection:connection error:error];
	if (!targetRows) return NO;
	NSString *targetOid = [[targetRows firstObject] firstObject];
	if (![targetOid isKindOfClass:[NSString class]] || ![targetOid length]) {
		if (error) *error = SPPostgresDuplicatorError([NSString stringWithFormat:NSLocalizedString(@"The new table “%@” could not be found after it was created.", @"Postgres duplicate table: copy not found"), newName]);
		return NO;
	}

	// The table's own comment (LIKE copies only those of columns, constraints and indexes)
	NSArray *comment = [self rowsOf:@"SELECT obj_description($1::oid, 'pg_class')::text" values:@[sourceOid] connection:connection error:error];
	if (!comment) return NO;
	NSString *commentText = [[comment firstObject] firstObject];
	if ([commentText isKindOfClass:[NSString class]]) {
		NSString *commentSQL = [NSString stringWithFormat:@"COMMENT ON TABLE %@ IS %@", targetName, SPPostgresQuoteLiteral(commentText)];
		if (!SPPostgresExecute(connection, commentSQL, nil, error)) return NO;
	}

	// Each serial column gets a sequence of its own, with the original's settings, owned by the copy's column
	for (NSArray *serial in serials) {
		NSString *column = [serial objectAtIndex:0];
		NSString *sequence = [self sequenceNameForTable:newName column:column schema:schema connection:connection error:error];
		if (!sequence) return NO;
		NSString *sequenceName = [self qualified:sequence schema:schema];

		NSMutableString *create = [NSMutableString stringWithFormat:@"CREATE SEQUENCE %@", sequenceName];
		NSString *type = [serial objectAtIndex:3];
		if ([@[@"smallint", @"integer", @"bigint"] containsObject:type]) [create appendFormat:@" AS %@", type];
		NSArray *clauses = @[@" INCREMENT BY %@", @" MINVALUE %@", @" MAXVALUE %@", @" START WITH %@", @" CACHE %@"];
		for (NSUInteger i = 0; i < [clauses count]; i++) {
			NSString *number = [serial objectAtIndex:4 + i];
			if (SPPostgresIsInteger(number)) [create appendFormat:[clauses objectAtIndex:i], number];
		}
		[create appendString:[[serial objectAtIndex:9] isEqual:@"true"] ? @" CYCLE" : @" NO CYCLE"];
		if (!SPPostgresExecute(connection, create, nil, error)) return NO;

		NSString *setDefault = [NSString stringWithFormat:@"ALTER TABLE %@ ALTER COLUMN %@ SET DEFAULT nextval(%@::regclass)",
								targetName, SPPostgresQuoteIdentifier(column), SPPostgresQuoteLiteral(sequenceName)];
		if (!SPPostgresExecute(connection, setDefault, nil, error)) return NO;

		NSString *owned = [NSString stringWithFormat:@"ALTER SEQUENCE %@ OWNED BY %@.%@", sequenceName, targetName, SPPostgresQuoteIdentifier(column)];
		if (!SPPostgresExecute(connection, owned, nil, error)) return NO;

		if (withContent) {
			NSString *continueFrom = [NSString stringWithFormat:@"SELECT setval($1::regclass, last_value, is_called) FROM %@",
									  [self qualified:[serial objectAtIndex:2] schema:[serial objectAtIndex:1]]];
			if (!SPPostgresExecute(connection, continueFrom, @[sequenceName], error)) return NO;
		}
	}

	if (!withContent) return YES;

	// Rows, keeping identity ALWAYS values; ONLY: not the rows of tables inheriting from it
	if ([insertable count]) {
		NSMutableArray *columns = [NSMutableArray arrayWithCapacity:[insertable count]];
		for (NSArray *row in insertable) [columns addObject:SPPostgresQuoteIdentifier([row firstObject])];
		NSString *list = [columns componentsJoinedByString:@", "];

		BOOL hasAlwaysIdentity = NO;
		for (NSArray *identity in identities) {
			if ([[identity objectAtIndex:1] isEqual:@"a"]) hasAlwaysIdentity = YES;
		}

		NSString *insert = [NSString stringWithFormat:@"INSERT INTO %@ (%@)%@ SELECT %@ FROM ONLY %@",
							targetName, list, hasAlwaysIdentity ? @" OVERRIDING SYSTEM VALUE" : @"", list, sourceName];
		if (!SPPostgresExecute(connection, insert, nil, error)) return NO;
	}

	// The copy's identity sequences continue from the original's
	if ([identities count]) {
		NSArray *targetIdentities = [self rowsOf:identitySQL values:@[targetOid] connection:connection error:error];
		if (!targetIdentities) return NO;

		for (NSArray *identity in identities) {
			for (NSArray *copy in targetIdentities) {
				if (![[copy objectAtIndex:0] isEqual:[identity objectAtIndex:0]]) continue;
				NSString *continueFrom = [NSString stringWithFormat:@"SELECT setval($1::regclass, last_value, is_called) FROM %@",
										  [self qualified:[identity objectAtIndex:3] schema:[identity objectAtIndex:2]]];
				NSString *copySequence = [self qualified:[copy objectAtIndex:3] schema:[copy objectAtIndex:2]];
				if (!SPPostgresExecute(connection, continueFrom, @[copySequence], error)) return NO;
			}
		}
	}

	return YES;
}

@end
