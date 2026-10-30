#import "SPPostgresSidebarInfoPane.h"
#import "SPPostgresPaneLoader.h"
#import "SPPostgresTaskRunner.h"
#import "SPPostgresTableStructure.h"
#import "ImageAndTextCell.h"

/// MySQL's info table column (DBView.xib)
static NSString * const SPPostgresSidebarInfoColumn = @"info";

@implementation SPPostgresSidebarInfoPane
{
	NSScrollView *scrollView;
	NSTableView *tableView;
	SPPostgresPaneLoader *loader;
	/// Whether the loader's runner is the default inline one (following the connection shown)
	BOOL ownsTaskRunner;
	BOOL invalidated;
	NSArray *lines;
	/// The relation shown (or being read), nil for none
	NSString *shownName;
	NSString *shownSchema;
}

@synthesize tableView;

- (instancetype)initWithFrame:(NSRect)frame
{
	if ((self = [super init])) {
		lines = [@[NSLocalizedString(@"INFORMATION", @"header for blank info pane")] retain];
		loader = [[SPPostgresPaneLoader alloc] initWithConnection:nil];
		ownsTaskRunner = YES;

		// As DBView.xib's "Scroll View (Table Info Table View)": no border, no scrollers, a source-list table
		scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
		[scrollView setBorderType:NSNoBorder];
		[scrollView setHasVerticalScroller:NO];
		[scrollView setHasHorizontalScroller:NO];
		[scrollView setAutohidesScrollers:YES];
		[scrollView setDrawsBackground:NO];
		[scrollView setFocusRingType:NSFocusRingTypeNone];
		[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

		tableView = [[NSTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
		NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresSidebarInfoColumn] autorelease];
		ImageAndTextCell *cell = [[[ImageAndTextCell alloc] init] autorelease];
		[cell setControlSize:NSControlSizeSmall];
		[cell setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[cell setLineBreakMode:NSLineBreakByTruncatingTail];
		[cell setEditable:NO];
		[column setDataCell:cell];
		[column setEditable:NO];
		[column setResizingMask:NSTableColumnAutoresizingMask];
		[column setWidth:NSWidth(frame)];
		[tableView addTableColumn:column];
		[tableView setHeaderView:nil];
		[tableView setStyle:NSTableViewStyleSourceList];
		[tableView setFocusRingType:NSFocusRingTypeNone];
		[tableView setAllowsMultipleSelection:NO];
		[tableView setAllowsEmptySelection:YES];
		[tableView setAllowsColumnReordering:NO];
		[tableView setAllowsTypeSelect:NO];
		[tableView setIntercellSpacing:NSMakeSize(3, 2)];
		[tableView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
		[tableView setDataSource:self];
		[tableView setDelegate:self];
		[scrollView setDocumentView:tableView];
		[tableView sizeLastColumnToFit];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];
	[loader release];
	[tableView release];
	[scrollView release];
	[lines release];
	[shownName release];
	[shownSchema release];
	[super dealloc];
}

- (NSView *)view
{
	return scrollView;
}

- (NSArray<NSString *> *)lines
{
	return [[lines retain] autorelease];
}

- (SPPostgresTaskRunner *)taskRunner
{
	return [loader taskRunner];
}

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	ownsTaskRunner = NO;
	[loader setTaskRunner:runner];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;
	[loader invalidate];
	[tableView setDelegate:nil];
	[tableView setDataSource:nil];
}

#pragma mark - Showing

- (void)_showLines:(NSArray *)theLines
{
	if (invalidated) return;
	[lines release];
	lines = [theLines copy];
	[tableView reloadData];
}

- (void)_setShownName:(NSString *)name schema:(NSString *)schema
{
	if (name != shownName) {
		[shownName release];
		shownName = [name copy];
	}
	if (schema != shownSchema) {
		[shownSchema release];
		shownSchema = [schema copy];
	}
}

- (void)showNothing
{
	[self _setShownName:nil schema:nil];
	[loader loadNothing];
	[self _showLines:@[NSLocalizedString(@"INFORMATION", @"header for blank info pane")]];
}

- (void)showMultipleSelection
{
	[self _setShownName:nil schema:nil];
	[loader loadNothing];
	[self _showLines:@[NSLocalizedString(@"INFORMATION", @"header for blank info pane"), NSLocalizedString(@"multiple selection", @"multiple selection")]];
}

- (void)showRelation:(NSString *)name inSchema:(NSString *)schema connection:(PGPostgresConnection *)connection
{
	[self showRelation:name inSchema:schema view:NO connection:connection];
}

static NSString *SPPostgresInfoHeader(BOOL isView)
{
	return isView ? NSLocalizedString(@"VIEW INFORMATION", @"header for view info pane") : NSLocalizedString(@"TABLE INFORMATION", @"header for table info pane");
}

- (void)showRelation:(NSString *)name inSchema:(NSString *)schema view:(BOOL)isView connection:(PGPostgresConnection *)connection
{
	if (invalidated) return;
	if (![name length] || ![schema length]) {
		[self showNothing];
		return;
	}

	// The default runner follows the connection shown (another database's)
	if (ownsTaskRunner && connection && [[loader taskRunner] connection] != connection) {
		[loader setTaskRunner:[SPPostgresTaskRunner inlineRunnerWithConnection:connection]];
	}

	// "INFORMATION" while the facts are read (and if the read is cancelled, as when Stop cancels the tab's loads)
	NSString *header = SPPostgresInfoHeader(isView);
	[self _setShownName:name schema:schema];
	[self _showLines:@[NSLocalizedString(@"INFORMATION", @"header for blank info pane")]];

	// On the runner's thread: a structure object of its own over the runner's connection, and copies of the names
	NSString *theName = [[name copy] autorelease];
	NSString *theSchema = [[schema copy] autorelease];
	[loader loadSwitching:YES work:^id(PGPostgresConnection *theConnection, NSError **error) {
		SPPostgresTableStructure *structure = [[[SPPostgresTableStructure alloc] initWithConnection:theConnection schema:theSchema table:theName] autorelease];
		return [structure tableInfo:error];
	} apply:^(id result, NSError *error) {
		[self _showLines:result ? [self _linesForInfo:result] : @[header, NSLocalizedString(@"error occurred", @"error occurred")]];
	}];
}

- (void)setComment:(NSString *)comment forRelation:(NSString *)name inSchema:(NSString *)schema
{
	if (invalidated || ![name isEqualToString:shownName] || ![schema isEqualToString:shownSchema]) return;
	// Only over facts read (not while they are read, nor after a failed read)
	if ([lines count] < 2 || [[lines objectAtIndex:1] isEqualToString:NSLocalizedString(@"error occurred", @"error occurred")]) return;

	NSString *prefix = [NSString stringWithFormat:NSLocalizedString(@"comment: %@", @"Postgres table info pane: comment"), @""];
	NSMutableArray *updated = [[lines mutableCopy] autorelease];
	if ([[updated lastObject] hasPrefix:prefix]) [updated removeLastObject];
	if ([comment length]) [updated addObject:[NSString stringWithFormat:NSLocalizedString(@"comment: %@", @"Postgres table info pane: comment"), comment]];
	[self _showLines:updated];
}

/// The rows for -[SPPostgresTableStructure tableInfo:]'s result.
- (NSArray *)_linesForInfo:(NSDictionary *)info
{
	NSString *kind = [info objectForKey:@"kind"];
	BOOL isView = [kind isEqualToString:@"view"] || [kind isEqualToString:@"materialized view"];
	// A plain view holds no rows and takes no space
	BOOL hasStorage = ![kind isEqualToString:@"view"];

	NSMutableArray *result = [NSMutableArray arrayWithObject:SPPostgresInfoHeader(isView)];
	[result addObject:[NSString stringWithFormat:NSLocalizedString(@"type: %@", @"Postgres table info pane: relation kind"), kind ?: @""]];
	[result addObject:[NSString stringWithFormat:NSLocalizedString(@"owner: %@", @"Postgres table info pane: owner"), [info objectForKey:@"owner"] ?: @""]];

	if (hasStorage) {
		id estimate = [info objectForKey:@"rowEstimate"];
		if ([estimate isKindOfClass:[NSNumber class]]) {
			NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
			[formatter setNumberStyle:NSNumberFormatterDecimalStyle];
			[result addObject:[NSString stringWithFormat:NSLocalizedString(@"rows: ~%@", @"Table Info Section : number of rows (estimated value)"), [formatter stringFromNumber:estimate]]];
		}
		else {
			[result addObject:NSLocalizedString(@"rows: unknown", @"Postgres table info pane: no row estimate")];
		}
		[result addObject:[NSString stringWithFormat:NSLocalizedString(@"size: %@", @"Table Info Section : table size on disk"), [info objectForKey:@"tableSize"] ?: @""]];
		[result addObject:[NSString stringWithFormat:NSLocalizedString(@"index size: %@", @"Postgres table info pane: index size"), [info objectForKey:@"indexSize"] ?: @""]];
		[result addObject:[NSString stringWithFormat:NSLocalizedString(@"total size: %@", @"Postgres table info pane: total size"), [info objectForKey:@"totalSize"] ?: @""]];
	}

	id comment = [info objectForKey:@"comment"];
	if ([comment isKindOfClass:[NSString class]] && [comment length]) {
		[result addObject:[NSString stringWithFormat:NSLocalizedString(@"comment: %@", @"Postgres table info pane: comment"), comment]];
	}
	return result;
}

#pragma mark - Table view (as SPTableInfo's info table)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return (NSInteger)[lines count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[lines count]) return nil;
	return [lines objectAtIndex:(NSUInteger)row];
}

- (CGFloat)tableView:(NSTableView *)aTableView heightOfRow:(NSInteger)row
{
	return (row == 0 ? 25 : [aTableView rowHeight]);
}

- (BOOL)tableView:(NSTableView *)aTableView isGroupRow:(NSInteger)row
{
	return row == 0;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)row
{
	return NO;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (![cell isKindOfClass:[ImageAndTextCell class]]) return;
	if (row > 0) {
		[(ImageAndTextCell *)cell setImage:[NSImage imageNamed:@"table-property"]];
		[(ImageAndTextCell *)cell setIndentationLevel:1];
		[(ImageAndTextCell *)cell setDrawsBackground:NO];
	}
	else {
		[(ImageAndTextCell *)cell setImage:nil];
		[(ImageAndTextCell *)cell setIndentationLevel:0];
	}
}

@end
