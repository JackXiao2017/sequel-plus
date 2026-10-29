#import "SPPostgresCheckList.h"
#import "SPPostgresCatalog.h"

static NSString * const SPPostgresCheckListCheckColumn = @"check";
static NSString * const SPPostgresCheckListNameColumn = @"name";

@implementation SPPostgresCheckList
{
	NSTableView *tableView;
	NSArray *rows;
	NSMutableArray *checked;
	BOOL groupsByFirstElement;
	void (^checksChanged)(void);
}

@synthesize tableView;
@synthesize groupsByFirstElement;
@synthesize checksChanged;

- (instancetype)initWithFrame:(NSRect)frame inView:(NSView *)content
{
	if ((self = [super init])) {
		checked = [[NSMutableArray alloc] init];
		rows = [@[] copy];

		NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
		[scrollView setHasVerticalScroller:YES];
		[scrollView setAutohidesScrollers:YES];
		[scrollView setBorderType:NSBezelBorder];
		[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

		tableView = [[NSTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
		[tableView setHeaderView:nil];
		[tableView setAllowsEmptySelection:YES];
		[tableView setFocusRingType:NSFocusRingTypeNone];
		[tableView setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];

		NSTableColumn *checkColumn = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresCheckListCheckColumn] autorelease];
		NSButtonCell *checkCell = [[[NSButtonCell alloc] init] autorelease];
		[checkCell setButtonType:NSButtonTypeSwitch];
		[checkCell setTitle:@""];
		[checkColumn setDataCell:checkCell];
		[checkColumn setWidth:22];
		[checkColumn setResizingMask:NSTableColumnNoResizing];
		[tableView addTableColumn:checkColumn];

		NSTableColumn *nameColumn = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresCheckListNameColumn] autorelease];
		NSTextFieldCell *nameCell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[nameCell setEditable:NO];
		[nameCell setLineBreakMode:NSLineBreakByTruncatingTail];
		[nameColumn setDataCell:nameCell];
		[nameColumn setEditable:NO];
		[nameColumn setWidth:frame.size.width - 40];
		[tableView addTableColumn:nameColumn];

		[tableView setDataSource:self];
		[tableView setDelegate:self];
		[scrollView setDocumentView:tableView];
		[content addSubview:scrollView];
	}
	return self;
}

- (void)dealloc
{
	[tableView setDataSource:nil];
	[tableView setDelegate:nil];
	[tableView release];
	[rows release];
	[checked release];
	[checksChanged release];
	[super dealloc];
}

- (NSArray *)rows
{
	return rows;
}

- (void)setRows:(NSArray *)newRows
{
	if (rows != newRows) {
		[rows release];
		rows = [(newRows ?: @[]) copy];
	}
	// Checks of items no longer present go
	NSMutableArray *kept = [NSMutableArray array];
	for (id item in checked) if ([rows containsObject:item]) [kept addObject:item];
	[checked setArray:kept];
	[tableView reloadData];
}

- (BOOL)_isGroupRowAtIndex:(NSInteger)row
{
	if (!groupsByFirstElement || row < 0 || row >= (NSInteger)[rows count]) return NO;
	return [[rows objectAtIndex:(NSUInteger)row] isKindOfClass:[NSString class]];
}

- (BOOL)_isItem:(id)row
{
	if (groupsByFirstElement) return [row isKindOfClass:[NSArray class]];
	return row != nil;
}

- (NSArray *)checkedItems
{
	NSMutableArray *result = [NSMutableArray array];
	for (id row in rows) if ([self _isItem:row] && [checked containsObject:row]) [result addObject:row];
	return result;
}

- (void)setChecked:(BOOL)isChecked item:(id)item
{
	if (!item) return;
	[checked removeObject:item];
	if (isChecked) [checked addObject:item];
	[tableView reloadData];
	if (checksChanged) checksChanged();
}

#pragma mark - Rows

+ (NSArray *)groupedRowsForCatalog:(SPPostgresCatalog *)catalog error:(NSError **)error
{
	NSError *firstError = nil;
	NSArray *schemas = [catalog schemaNames:&firstError];
	NSMutableArray *result = [NSMutableArray array];
	for (NSString *schema in schemas) {
		NSError *tablesError = nil;
		NSArray *tables = [catalog tableNamesInSchema:schema error:&tablesError];
		if (!tables) {
			if (!firstError) firstError = tablesError;
			continue;
		}
		if (![tables count]) continue;
		[result addObject:schema];
		for (NSString *table in tables) [result addObject:@[schema, table]];
	}
	if (firstError && error) *error = firstError;
	return result;
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return (NSInteger)[rows count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[rows count]) return nil;
	BOOL isCheck = [[tableColumn identifier] isEqualToString:SPPostgresCheckListCheckColumn];
	id entry = [rows objectAtIndex:(NSUInteger)row];
	if ([self _isGroupRowAtIndex:row]) return isCheck ? nil : entry;
	if ([entry isKindOfClass:[NSArray class]]) return isCheck ? @([checked containsObject:entry]) : [entry objectAtIndex:1];
	return isCheck ? @([checked containsObject:entry]) : entry;
}

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (![[tableColumn identifier] isEqualToString:SPPostgresCheckListCheckColumn]) return;
	if (row < 0 || row >= (NSInteger)[rows count] || [self _isGroupRowAtIndex:row]) return;
	[self setChecked:[object boolValue] item:[rows objectAtIndex:(NSUInteger)row]];
}

- (BOOL)tableView:(NSTableView *)aTableView isGroupRow:(NSInteger)row
{
	return [self _isGroupRowAtIndex:row];
}

- (NSCell *)tableView:(NSTableView *)aTableView dataCellForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	// A group row spans the columns with its name
	if (!tableColumn && [self _isGroupRowAtIndex:row]) {
		NSTextFieldCell *cell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[cell setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
		return cell;
	}
	return [tableColumn dataCellForRow:row];
}

- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldTrackCell:(NSCell *)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	// The checkboxes toggle though rows can't be selected
	return [[tableColumn identifier] isEqualToString:SPPostgresCheckListCheckColumn] && ![self _isGroupRowAtIndex:row];
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)row
{
	return NO;
}

@end
