#import "SPPostgresHistory.h"

/// As MySQL's history (SPHistoryController)
static const NSUInteger SPPostgresHistoryMaximumEntries = 50;

@implementation SPPostgresHistory
{
	NSMutableArray *entries;
	/// Index of the current entry; NSNotFound while empty
	NSUInteger position;
}

- (instancetype)init
{
	if ((self = [super init])) {
		entries = [[NSMutableArray alloc] init];
		position = NSNotFound;
	}
	return self;
}

- (void)dealloc
{
	[entries release];
	[super dealloc];
}

- (void)recordDatabase:(NSString *)db schema:(NSString *)schema table:(NSString *)table pane:(NSString *)pane
{
	NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithCapacity:4];
	[entry setObject:db ?: @"" forKey:@"database"];
	[entry setObject:schema ?: @"" forKey:@"schema"];
	if ([table length]) [entry setObject:table forKey:@"table"];
	[entry setObject:pane ?: @"content" forKey:@"pane"];

	if ([entry isEqualToDictionary:[self currentEntry]]) return;

	// Recording after going back drops the entries ahead
	if (position != NSNotFound && position + 1 < [entries count]) {
		[entries removeObjectsInRange:NSMakeRange(position + 1, [entries count] - position - 1)];
	}

	[entries addObject:[[entry copy] autorelease]];
	if ([entries count] > SPPostgresHistoryMaximumEntries) [entries removeObjectAtIndex:0];
	position = [entries count] - 1;
}

- (void)renameTable:(NSString *)oldName to:(NSString *)newName inDatabase:(NSString *)db schema:(NSString *)schema
{
	if (![oldName length] || ![newName length]) return;

	for (NSUInteger i = 0; i < [entries count]; i++) {
		NSDictionary *entry = [entries objectAtIndex:i];
		if (![[entry objectForKey:@"table"] isEqualToString:oldName]) continue;
		if (![[entry objectForKey:@"database"] isEqualToString:db ?: @""] || ![[entry objectForKey:@"schema"] isEqualToString:schema ?: @""]) continue;

		NSMutableDictionary *renamed = [[entry mutableCopy] autorelease];
		[renamed setObject:newName forKey:@"table"];
		[entries replaceObjectAtIndex:i withObject:[[renamed copy] autorelease]];
	}
}

- (NSDictionary *)goBack
{
	if (![self canGoBack]) return nil;
	position--;
	return [self currentEntry];
}

- (NSDictionary *)goForward
{
	if (![self canGoForward]) return nil;
	position++;
	return [self currentEntry];
}

- (BOOL)canGoBack
{
	return position != NSNotFound && position > 0;
}

- (BOOL)canGoForward
{
	return position != NSNotFound && position + 1 < [entries count];
}

- (NSDictionary *)currentEntry
{
	return (position != NSNotFound) ? [entries objectAtIndex:position] : nil;
}

@end
