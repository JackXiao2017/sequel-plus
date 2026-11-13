#import "SPMySQLStorageReducer.h"

/// `name`, with backticks doubled.
static NSString *SPMySQLStorageReducerQuote(NSString *name)
{
	return [NSString stringWithFormat:@"`%@`", [name ?: @"" stringByReplacingOccurrencesOfString:@"`" withString:@"``"]];
}

/// name as a hex string literal of its UTF-8 bytes, read as utf8mb4: no quoting or escaping (sql_mode) to get wrong.
static NSString *SPMySQLStorageReducerLiteral(NSString *name)
{
	NSData *bytes = [name ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
	if (![bytes length]) return @"''";
	NSMutableString *hex = [NSMutableString stringWithCapacity:[bytes length] * 2];
	const unsigned char *raw = [bytes bytes];
	for (NSUInteger i = 0; i < [bytes length]; i++) [hex appendFormat:@"%02X", raw[i]];
	return [NSString stringWithFormat:@"CONVERT(0x%@ USING utf8mb4)", hex];
}

static NSString *SPMySQLStorageReducerText(id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

@implementation SPMySQLStorageReducer

/// DATA_LENGTH + INDEX_LENGTH of table in the current database, or nil (*errorMessage set when the query failed).
+ (NSNumber *)_sizeOfTable:(NSString *)table query:(SPMySQLStorageReducerQuery)query errorMessage:(NSString **)errorMessage
{
	NSString *sql = [NSString stringWithFormat:@"SELECT CAST(COALESCE(DATA_LENGTH, 0) + COALESCE(INDEX_LENGTH, 0) AS CHAR) AS bytes FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %@", SPMySQLStorageReducerLiteral(table)];
	NSArray *rows = query(sql, errorMessage);
	if (!rows) return nil;
	NSString *bytes = SPMySQLStorageReducerText([[rows firstObject] objectForKey:@"bytes"]);
	return @(bytes ? [bytes longLongValue] : 0);
}

/// The message of OPTIMIZE's error rows (Msg_type "error"), joined; nil when there is none.
+ (NSString *)_errorOfOptimizeRows:(NSArray<NSDictionary *> *)rows
{
	NSMutableArray *messages = [NSMutableArray array];
	for (NSDictionary *row in rows) {
		NSString *type = SPMySQLStorageReducerText([row objectForKey:@"Msg_type"]);
		if ([[type lowercaseString] isEqualToString:@"error"]) {
			NSString *text = SPMySQLStorageReducerText([row objectForKey:@"Msg_text"]);
			if ([text length]) [messages addObject:text];
		}
	}
	if ([messages count]) return [messages componentsJoinedByString:@" "];
	return nil;
}

+ (NSArray<NSDictionary *> *)reduceStorageOfTables:(NSArray<NSString *> *)tables skippingFailures:(BOOL)skipping query:(SPMySQLStorageReducerQuery)query isCancelled:(BOOL (^)(void))isCancelled errorMessage:(NSString **)errorMessage
{
	if (errorMessage) *errorMessage = nil;
	if (![tables count]) return @[];

	// MySQL 8 caches the sizes in information_schema; read them fresh meanwhile (an older server has no such variable)
	NSString *ignored = nil;
	NSArray *expiryRows = query(@"SELECT CAST(@@SESSION.information_schema_stats_expiry AS CHAR) AS expiry", &ignored);
	NSString *previousExpiry = SPMySQLStorageReducerText([[expiryRows firstObject] objectForKey:@"expiry"]);
	if (previousExpiry && !query(@"SET SESSION information_schema_stats_expiry = 0", &ignored)) previousExpiry = nil;

	NSMutableArray *results = [NSMutableArray arrayWithCapacity:[tables count]];
	NSString *failure = nil;
	BOOL cancelled = NO;

	for (NSString *table in tables) {
		if (isCancelled && isCancelled()) {
			cancelled = YES;
			break;
		}

		NSString *message = nil;
		NSNumber *before = [self _sizeOfTable:table query:query errorMessage:&message];
		if (!before) {
			failure = message ?: @"";
			break;
		}

		NSArray *rows = query([NSString stringWithFormat:@"OPTIMIZE TABLE %@", SPMySQLStorageReducerQuote(table)], &message);
		// A cancelled statement fails too: that is a cancel, not an error
		if (isCancelled && isCancelled()) {
			cancelled = YES;
			break;
		}
		if (!rows) {
			// The statement itself failed (the connection, a syntax the server refused): nothing more is tried
			failure = [NSString stringWithFormat:NSLocalizedString(@"%@: %@", @"MySQL reduce storage failure: table, server message"), table, message ?: @""];
			break;
		}
		NSString *tableError = [self _errorOfOptimizeRows:rows];
		if (tableError) {
			if (!skipping) {
				failure = [NSString stringWithFormat:NSLocalizedString(@"%@: %@", @"MySQL reduce storage failure: table, server message"), table, tableError];
				break;
			}
			[results addObject:@{@"table": table, @"skipped": tableError}];
			continue;
		}

		NSNumber *after = [self _sizeOfTable:table query:query errorMessage:&message];
		if (!after) {
			failure = message ?: @"";
			break;
		}
		[results addObject:@{@"table": table, @"before": before, @"after": after}];
	}

	// The session's own value back, whatever happened
	if (previousExpiry) {
		query([NSString stringWithFormat:@"SET SESSION information_schema_stats_expiry = %lld", [previousExpiry longLongValue]], &ignored);
	}

	if (cancelled) return nil;
	if (failure) {
		if (errorMessage) *errorMessage = failure;
		return nil;
	}
	return results;
}

+ (NSArray<NSString *> *)resultLinesFor:(NSArray<NSDictionary *> *)results sizeFormatter:(NSString *(^)(long long bytes))sizeFormatter
{
	NSMutableArray *lines = [NSMutableArray array];
	NSMutableArray *skipped = [NSMutableArray array];
	long long before = 0, after = 0;
	for (NSDictionary *result in results) {
		NSString *reason = [result objectForKey:@"skipped"];
		if (reason) {
			[skipped addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: skipped (%@)", @"MySQL reduce storage result line: table skipped, reason"), [result objectForKey:@"table"], reason]];
			continue;
		}
		long long tableBefore = [[result objectForKey:@"before"] longLongValue];
		long long tableAfter = [[result objectForKey:@"after"] longLongValue];
		before += tableBefore;
		after += tableAfter;
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: %@ → %@", @"MySQL reduce storage result line: table, size before, size after"), [result objectForKey:@"table"], sizeFormatter(tableBefore), sizeFormatter(tableAfter)]];
	}
	if ([lines count] > 1) {
		[lines insertObject:[NSString stringWithFormat:NSLocalizedString(@"Total: %@ → %@", @"MySQL reduce storage result total: size before, size after"), sizeFormatter(before), sizeFormatter(after)] atIndex:0];
		[lines insertObject:@"" atIndex:1];
	}
	if ([skipped count]) {
		if ([lines count]) [lines addObject:@""];
		[lines addObjectsFromArray:skipped];
	}
	return lines;
}

@end
