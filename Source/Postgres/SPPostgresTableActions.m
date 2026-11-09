#import "SPPostgresTableActions.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

/// Seconds to wait for a lock before the change fails (as the other structure changes do)
static const NSTimeInterval SPPostgresTableActionsLockTimeout = 5;

static NSString *SPPostgresQualifiedName(NSString *schema, NSString *name)
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(schema ?: @""), SPPostgresQuoteIdentifier(name ?: @"")];
}

@implementation SPPostgresTableActions

+ (BOOL)truncateTables:(NSArray<NSString *> *)tables inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	return [self truncateTables:tables inSchema:schema restartIdentity:NO connection:connection error:error];
}

+ (BOOL)truncateTables:(NSArray<NSString *> *)tables inSchema:(NSString *)schema restartIdentity:(BOOL)restartIdentity connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	if (![tables count]) return YES;

	NSMutableArray *qualified = [NSMutableArray arrayWithCapacity:[tables count]];
	for (NSString *table in tables) [qualified addObject:SPPostgresQualifiedName(schema, table)];
	NSString *sql = [NSString stringWithFormat:@"TRUNCATE TABLE %@%@", [qualified componentsJoinedByString:@", "], restartIdentity ? @" RESTART IDENTITY" : @""];

	return SPPostgresRunStructureChange(connection, SPPostgresTableActionsLockTimeout, ^BOOL(NSError **bodyError) {
		return SPPostgresExecuteWithDetails(connection, sql, nil, bodyError) != nil;
	}, error);
}

/// pg_total_relation_size of schema.table and whether the user may vacuum it, or nil with *error (missing table).
static NSDictionary *SPPostgresStorageFacts(PGPostgresConnection *connection, NSString *schema, NSString *table, NSError **error)
{
	// MAINTAIN (and the pg_maintain role) exist from PostgreSQL 17; before, only the owner (or a superuser) may vacuum
	PGPostgresResult *result = SPPostgresExecute(connection,
		@"SELECT pg_catalog.pg_total_relation_size(c.oid)::text,"
		" (pg_catalog.pg_has_role(c.relowner, 'USAGE') OR CASE WHEN pg_catalog.current_setting('server_version_num')::int >= 170000"
		"  THEN pg_catalog.has_table_privilege(c.oid, 'MAINTAIN') ELSE false END)::text"
		" FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace"
		" WHERE n.nspname = $1::text AND c.relname = $2::text AND c.relkind IN ('r', 'p', 'm')", @[schema ?: @"", table ?: @""], error);
	if (!result) return nil;
	NSArray *row = [result rowAsArray];
	if (![row count]) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, [NSString stringWithFormat:NSLocalizedString(@"The table “%@” no longer exists.", @"PostgreSQL reduce storage: missing table"), table], nil);
		return nil;
	}
	id bytes = [row objectAtIndex:0];
	id allowed = [row count] > 1 ? [row objectAtIndex:1] : nil;
	return @{@"bytes": @([bytes isKindOfClass:[NSString class]] ? [bytes longLongValue] : 0),
			 @"allowed": @([allowed isKindOfClass:[NSString class]] && [allowed isEqualToString:@"true"])};
}

+ (NSArray<NSDictionary *> *)reduceStorageOfTables:(NSArray<NSString *> *)tables inSchema:(NSString *)schema lockTimeout:(NSTimeInterval)lockTimeout connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	return [self reduceStorageOfTables:tables inSchema:schema skippingTablesNotAllowed:NO lockTimeout:lockTimeout connection:connection error:error];
}

+ (NSArray<NSDictionary *> *)reduceStorageOfTables:(NSArray<NSString *> *)tables inSchema:(NSString *)schema skippingTablesNotAllowed:(BOOL)skipping lockTimeout:(NSTimeInterval)lockTimeout connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	if (![tables count]) return @[];

	if ([connection transactionStatus] != PGPostgresTransactionIdle) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, NSLocalizedString(@"A transaction is open on this connection, and the storage can't be reduced inside one. Commit or roll it back first (COMMIT or ROLLBACK in the Query view).", @"PostgreSQL reduce storage: inside a transaction"), nil);
		return nil;
	}

	// Every table first: nothing is vacuumed unless all of them can be (or, skipping, those that can't are left out)
	NSMutableArray *results = [NSMutableArray arrayWithCapacity:[tables count]];
	NSMutableArray *toVacuum = [NSMutableArray array];
	for (NSString *table in tables) {
		NSError *factsError = nil;
		NSDictionary *facts = SPPostgresStorageFacts(connection, schema, table, &factsError);
		NSString *refusal = nil;
		if (!facts) {
			// A failed query (not a missing table) fails the whole change
			if (!skipping || [connection transactionStatus] != PGPostgresTransactionIdle || ![[factsError localizedDescription] containsString:@"no longer exists"]) {
				if (error) *error = factsError;
				return nil;
			}
			refusal = NSLocalizedString(@"no longer exists", @"PostgreSQL reduce storage: skipped table, missing");
		}
		else if (![[facts objectForKey:@"allowed"] boolValue]) {
			if (!skipping) {
				if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, [NSString stringWithFormat:NSLocalizedString(@"Only the owner of the table “%@” can reduce its storage.", @"PostgreSQL reduce storage: not the owner"), table], nil);
				return nil;
			}
			refusal = NSLocalizedString(@"not the owner", @"PostgreSQL reduce storage: skipped table, not the owner");
		}

		if (refusal) {
			[results addObject:@{@"table": table, @"skipped": refusal}];
		}
		else {
			[results addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"table": table, @"before": [facts objectForKey:@"bytes"]}]];
			[toVacuum addObject:table];
		}
	}
	if (![toVacuum count]) return results;

	// The lock wait is limited for the session (VACUUM runs outside a transaction, so SET LOCAL can't be used)
	PGPostgresResult *previous = SPPostgresExecute(connection, @"SELECT pg_catalog.current_setting('lock_timeout')::text", nil, error);
	if (!previous) return nil;
	id previousValue = [[previous rowAsArray] firstObject];
	if (![previousValue isKindOfClass:[NSString class]]) previousValue = @"0";
	double milliseconds = lockTimeout > 0 ? MIN(ceil(lockTimeout * 1000.0), (double)INT32_MAX) : 0;
	NSString *set = @"SELECT pg_catalog.set_config('lock_timeout', $1::text, false)";
	if (!SPPostgresExecute(connection, set, @[[NSString stringWithFormat:@"%.0f", milliseconds]], error)) return nil;

	NSError *vacuumError = nil;
	BOOL vacuumed = YES;
	for (NSString *table in toVacuum) {
		NSString *sql = [NSString stringWithFormat:@"VACUUM (FULL, ANALYZE) %@", SPPostgresQualifiedName(schema, table)];
		if (!SPPostgresExecuteWithDetails(connection, sql, nil, &vacuumError)) {
			vacuumed = NO;
			break;
		}
	}
	// Set back whatever happened (a failed VACUUM leaves no transaction open)
	SPPostgresExecute(connection, set, @[previousValue], NULL);
	if (!vacuumed) {
		if (error) *error = vacuumError;
		return nil;
	}

	for (id result in results) {
		if (![result isKindOfClass:[NSMutableDictionary class]]) continue;
		NSDictionary *facts = SPPostgresStorageFacts(connection, schema, [result objectForKey:@"table"], error);
		if (!facts) return nil;
		[result setObject:[facts objectForKey:@"bytes"] forKey:@"after"];
	}
	return results;
}

+ (BOOL)dropRelations:(NSArray<NSString *> *)names inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	if (![names count]) return YES;

	// One DROP per kind naming every selected object of that kind: the server resolves dependencies among objects
	// named in the same command (an FK child with its parent). Views go before the tables they read, materialized
	// views first as they may read views. A dependent that is not selected still fails the whole change.
	NSArray *keywordOrder = @[@"MATERIALIZED VIEW", @"VIEW", @"FOREIGN TABLE", @"TABLE"];

	return SPPostgresRunStructureChange(connection, SPPostgresTableActionsLockTimeout, ^BOOL(NSError **bodyError) {
		NSMutableDictionary<NSString *, NSMutableArray *> *namesByKeyword = [NSMutableDictionary dictionary];

		for (NSString *name in names) {
			PGPostgresResult *result = SPPostgresExecute(connection,
				@"SELECT c.relkind::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace"
				" WHERE n.nspname = $1::text AND c.relname = $2::text", @[schema ?: @"", name ?: @""], bodyError);
			if (!result) return NO;

			NSString *kind = [result numberOfRows] ? [result textValueAtRow:0 column:0] : nil;
			NSString *keyword = nil;
			if ([kind isEqualToString:@"r"] || [kind isEqualToString:@"p"]) keyword = @"TABLE";
			else if ([kind isEqualToString:@"f"]) keyword = @"FOREIGN TABLE";
			else if ([kind isEqualToString:@"v"]) keyword = @"VIEW";
			else if ([kind isEqualToString:@"m"]) keyword = @"MATERIALIZED VIEW";

			if (!keyword) {
				if (bodyError) {
					NSString *message = [NSString stringWithFormat:NSLocalizedString(@"\"%@\" can't be removed: it is not a table or view in schema \"%@\".", @"Postgres table actions: name not found or not removable"), name, schema ?: @""];
					*bodyError = SPPostgresMakeError(SPPostgresErrorQueryFailed, message, nil);
				}
				return NO;
			}
			NSMutableArray *qualified = namesByKeyword[keyword];
			if (!qualified) namesByKeyword[keyword] = qualified = [NSMutableArray array];
			[qualified addObject:SPPostgresQualifiedName(schema, name)];
		}

		for (NSString *keyword in keywordOrder) {
			NSArray *qualified = namesByKeyword[keyword];
			if (![qualified count]) continue;

			NSString *sql = [NSString stringWithFormat:@"DROP %@ %@", keyword, [qualified componentsJoinedByString:@", "]];
			NSError *dropError = nil;
			if (SPPostgresExecuteWithDetails(connection, sql, nil, &dropError)) continue;

			// The DETAIL lists the dependents; it is read now, before the savepoint or transaction is rolled back
			dropError = SPPostgresDependentsError(connection, dropError, nil);
			if (bodyError) *bodyError = dropError;
			return NO;
		}
		return YES;
	}, error);
}

+ (BOOL)createTableNamed:(NSString *)name inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection error:(NSError **)error
{
	NSString *sql = [NSString stringWithFormat:@"CREATE TABLE %@ (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY)", SPPostgresQualifiedName(schema, name)];

	return SPPostgresRunStructureChange(connection, SPPostgresTableActionsLockTimeout, ^BOOL(NSError **bodyError) {
		return SPPostgresExecuteWithDetails(connection, sql, nil, bodyError) != nil;
	}, error);
}

@end
