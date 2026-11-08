#import "SPPostgresRowsGrid.h"

// The Edit menu's copy items' tags (SPCopyTable.m)
static const NSInteger SPPostgresRowsMenuCopy = 2001;
static const NSInteger SPPostgresRowsMenuCopyWithColumns = 2002;
static const NSInteger SPPostgresRowsMenuCopyAsSQL = 2003;

@implementation SPPostgresRowsGrid

- (id<SPPostgresRowsGridDelegate>)_rowsDelegate
{
	id theDelegate = [self delegate];
	return [theDelegate conformsToProtocol:@protocol(SPPostgresRowsGridDelegate)] ? theDelegate : nil;
}

+ (NSArray<NSMenuItem *> *)copyMenuItemsForGrid:(NSTableView *)grid
{
	NSArray *titles = @[NSLocalizedString(@"Copy", @"copy contextual menu item"),
						NSLocalizedString(@"Copy with Column Names", @"copy with column names contextual menu item"),
						NSLocalizedString(@"Copy as SQL INSERT", @"copy as sql insert contextual menu item")];
	NSInteger tags[] = {SPPostgresRowsMenuCopy, SPPostgresRowsMenuCopyWithColumns, SPPostgresRowsMenuCopyAsSQL};
	NSMutableArray *items = [NSMutableArray array];
	for (NSUInteger i = 0; i < [titles count]; i++) {
		NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:@selector(copy:) keyEquivalent:@""] autorelease];
		[item setTag:tags[i]];
		[item setTarget:grid];
		[items addObject:item];
	}
	return items;
}

- (IBAction)copy:(id)sender
{
	id<SPPostgresRowsGridDelegate> rowsDelegate = [self _rowsDelegate];
	if (![self numberOfSelectedRows] || !rowsDelegate) {
		NSBeep();
		return;
	}
	NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : SPPostgresRowsMenuCopy;
	if (tag == SPPostgresRowsMenuCopyAsSQL) [rowsDelegate rowsGridCopyAsSQLInserts:self];
	else [rowsDelegate rowsGrid:self copyRowsWithColumnNames:(tag == SPPostgresRowsMenuCopyWithColumns)];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if ([menuItem action] == @selector(copy:)) {
		return [self numberOfSelectedRows] > 0 && [self _rowsDelegate];
	}
	// SPTableView may not validate menu items itself (then, as AppKit: enabled, as the grid handles the action)
	if ([SPTableView instancesRespondToSelector:@selector(validateMenuItem:)]) return [super validateMenuItem:menuItem];
	return YES;
}

@end

/// A PostgreSQL identifier, double-quoted.
static NSString *SPPostgresRowsQuotedIdentifier(NSString *name)
{
	return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

/// A value as an SQL literal: NULL, or a standard-conforming quoted string (quotes doubled; backslashes as they are).
static NSString *SPPostgresRowsLiteral(id value)
{
	if (![value isKindOfClass:[NSString class]]) return @"NULL";
	return [NSString stringWithFormat:@"'%@'", [(NSString *)value stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

NSString *SPPostgresTabText(NSArray<NSString *> *columnNames, NSArray<NSArray *> *rows, NSString *nullString)
{
	NSMutableArray *lines = [NSMutableArray arrayWithCapacity:[rows count] + 1];
	if (columnNames) [lines addObject:[columnNames componentsJoinedByString:@"\t"]];
	for (NSArray *row in rows) {
		NSMutableArray *fields = [NSMutableArray arrayWithCapacity:[row count]];
		for (id value in row) {
			if ([value isKindOfClass:[NSNull class]]) {
				[fields addObject:nullString];
				continue;
			}
			NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
			text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"↵"];
			text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"↵"];
			text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"↵"];
			[fields addObject:[text stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"]];
		}
		[lines addObject:[fields componentsJoinedByString:@"\t"]];
	}
	return [lines componentsJoinedByString:@"\n"];
}

NSString *SPPostgresSQLInserts(NSString *qualifiedTableName, NSArray<NSString *> *columnNames, NSArray<NSArray *> *rows)
{
	NSMutableArray *quotedNames = [NSMutableArray arrayWithCapacity:[columnNames count]];
	for (NSString *name in columnNames) [quotedNames addObject:SPPostgresRowsQuotedIdentifier(name)];

	NSMutableArray *lines = [NSMutableArray arrayWithCapacity:[rows count]];
	for (NSArray *row in rows) {
		NSMutableArray *literals = [NSMutableArray arrayWithCapacity:[row count]];
		for (id value in row) [literals addObject:SPPostgresRowsLiteral(value)];
		[lines addObject:[NSString stringWithFormat:@"\t(%@)", [literals componentsJoinedByString:@", "]]];
	}

	return [NSString stringWithFormat:@"INSERT INTO %@ (%@)\nVALUES\n%@;", qualifiedTableName,
			[quotedNames componentsJoinedByString:@", "], [lines componentsJoinedByString:@",\n"]];
}
