#import "SPPostgresExportController.h"
#import "SPPostgresDocument.h"
#import "SPPostgresQueryController.h"
#import "SPPostgresSidebarController.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresDumpWriter.h"
#import "SPPostgresTableData.h"
#import "SPPostgresCSV.h"
#import "SPPostgresErrors.h"
#import "SPPostgresProgressSheet.h"
#import "SPPostgresBackgroundJob.h"
#import "SPPostgresConnector.h"
#import <PostgresKit/PostgresKit.h>
#import <sys/stat.h>

typedef NS_ENUM(NSInteger, SPPostgresExportFormat) {
	SPPostgresExportFormatSQL = 0,
	SPPostgresExportFormatCSV = 1
};

typedef NS_ENUM(NSInteger, SPPostgresExportSource) {
	SPPostgresExportSourceDatabase = 0,
	SPPostgresExportSourceSchemas = 1,
	SPPostgresExportSourceTables = 2,
	SPPostgresExportSourceQueryResult = 3
};

static NSString * const SPPostgresExportCheckColumn = @"check";
static NSString * const SPPostgresExportNameColumn = @"name";
/// The delimiter pop-up's items: , ; Tab | Custom
static const NSInteger SPPostgresExportCustomDelimiterIndex = 4;

/// <schema>.<table>.csv, with path separators (which can't be in a file name) as "-".
static NSString *SPPostgresExportCSVFileName(NSString *schema, NSString *table)
{
	NSString *name = [NSString stringWithFormat:@"%@.%@.csv", schema, table];
	return [[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

@interface SPPostgresExportController ()
- (void)_buildSheet;
- (void)_loadLists;
- (void)_updateControls;
- (void)_finish;
@end

@implementation SPPostgresExportController
{
	SPPostgresDocument *document; // retained until the controller goes away
	NSString *database;

	NSPanel *sheet;
	NSSegmentedControl *formatControl;
	NSPopUpButton *sourcePopup;
	NSTableView *schemasTable;
	NSTableView *tablesTable;
	NSTextField *sourceNote;
	NSView *sqlOptions;
	NSView *csvOptions;
	NSButton *structureCheckbox;
	NSButton *dataCheckbox;
	NSButton *compressCheckbox;
	NSPopUpButton *delimiterPopup;
	NSTextField *customDelimiterField;
	NSTextField *quoteField;
	NSPopUpButton *escapePopup;
	NSButton *headerCheckbox;
	NSTextField *nullField;
	NSButton *exportButton;
	NSButton *cancelButton;

	NSArray *schemaNames;
	/// The Selected tables list: NSString (a schema's group row) or @[schema, table]
	NSArray *tableRows;
	NSMutableArray *checkedSchemaList;
	NSMutableArray *checkedTableList;

	NSArray *queryColumnNames;
	NSUInteger queryRowCount;

	SPPostgresProgressSheet *progressSheet;
	NSString *lastErrorMessage;
	NSString *completionNote;
	BOOL began;
	BOOL finished;
	BOOL running;
	/// Cancel came while the path was being chosen: nothing starts
	BOOL abandoned;

	/// The running job, and the connector the default provider is connecting for it (nil once connected)
	SPPostgresBackgroundJob *job;
	SPPostgresConnector *pendingConnector;
	/// Partitioned tables (relkind p) as @[schema, table]: a CSV of a database or schemas leaves them out, as their
	/// partitions export their own rows
	NSSet *partitionedTables;
}

@synthesize didEnd;
@synthesize sheet;
@synthesize formatControl;
@synthesize sourcePopup;
@synthesize schemasTable;
@synthesize tablesTable;
@synthesize structureCheckbox;
@synthesize dataCheckbox;
@synthesize compressCheckbox;
@synthesize delimiterPopup;
@synthesize customDelimiterField;
@synthesize quoteField;
@synthesize escapePopup;
@synthesize headerCheckbox;
@synthesize nullField;
@synthesize exportButton;
@synthesize savePathProvider;
@synthesize progressObserver;
@synthesize progressSheet;
@synthesize lastErrorMessage;
@synthesize completionNote;
@synthesize pendingConnector;

- (instancetype)initWithDocument:(SPPostgresDocument *)theDocument
{
	if ((self = [super init])) {
		document = [theDocument retain];
		database = [[theDocument currentDatabase] copy];
		checkedSchemaList = [[NSMutableArray alloc] init];
		checkedTableList = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[schemasTable setDataSource:nil];
	[schemasTable setDelegate:nil];
	[tablesTable setDataSource:nil];
	[tablesTable setDelegate:nil];
	for (NSControl *control in [NSArray arrayWithObjects:formatControl, sourcePopup, delimiterPopup, structureCheckbox, dataCheckbox, compressCheckbox, headerCheckbox, exportButton, cancelButton, nil]) [control setTarget:nil];
	[quoteField setDelegate:nil];
	[customDelimiterField setDelegate:nil];
	[nullField setDelegate:nil];

	[didEnd release];
	[savePathProvider release];
	[progressObserver release];
	[sheet release];
	[formatControl release];
	[sourcePopup release];
	[schemasTable release];
	[tablesTable release];
	[sourceNote release];
	[sqlOptions release];
	[csvOptions release];
	[structureCheckbox release];
	[dataCheckbox release];
	[compressCheckbox release];
	[delimiterPopup release];
	[customDelimiterField release];
	[quoteField release];
	[escapePopup release];
	[headerCheckbox release];
	[nullField release];
	[exportButton release];
	[cancelButton release];
	[schemaNames release];
	[tableRows release];
	[checkedSchemaList release];
	[checkedTableList release];
	[queryColumnNames release];
	[progressSheet release];
	[job release];
	[pendingConnector release];
	[partitionedTables release];
	[lastErrorMessage release];
	[completionNote release];
	[database release];
	[document release];
	[super dealloc];
}

- (void)_setLastErrorMessage:(NSString *)message
{
	if (message == lastErrorMessage) return;
	[lastErrorMessage release];
	lastErrorMessage = [message copy];
}

- (void)_setCompletionNote:(NSString *)note
{
	if (note == completionNote) return;
	[completionNote release];
	completionNote = [note copy];
}

#pragma mark - Building

- (NSTextField *)_labelWithFrame:(NSRect)frame text:(NSString *)text
{
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setStringValue:text];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	[label setAlignment:NSTextAlignmentRight];
	return label;
}

- (NSButton *)_checkboxWithFrame:(NSRect)frame title:(NSString *)title on:(BOOL)on
{
	NSButton *checkbox = [[NSButton alloc] initWithFrame:frame];
	[checkbox setButtonType:NSButtonTypeSwitch];
	[checkbox setTitle:title];
	[checkbox setState:on ? NSControlStateValueOn : NSControlStateValueOff];
	[checkbox setTarget:self];
	[checkbox setAction:@selector(_controlChanged:)];
	return checkbox;
}

- (NSTextField *)_fieldWithFrame:(NSRect)frame text:(NSString *)text
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
	[field setStringValue:text];
	[field setDelegate:self];
	return field;
}

- (NSTableView *)_checkListWithFrame:(NSRect)frame inView:(NSView *)content
{
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSBezelBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSTableView *tableView = [[NSTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
	[tableView setHeaderView:nil];
	[tableView setAllowsEmptySelection:YES];
	[tableView setFocusRingType:NSFocusRingTypeNone];
	[tableView setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];

	NSTableColumn *checkColumn = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresExportCheckColumn] autorelease];
	NSButtonCell *checkCell = [[[NSButtonCell alloc] init] autorelease];
	[checkCell setButtonType:NSButtonTypeSwitch];
	[checkCell setTitle:@""];
	[checkColumn setDataCell:checkCell];
	[checkColumn setWidth:22];
	[checkColumn setResizingMask:NSTableColumnNoResizing];
	[tableView addTableColumn:checkColumn];

	NSTableColumn *nameColumn = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresExportNameColumn] autorelease];
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
	return tableView;
}

- (void)_buildSheet
{
	if (sheet) return;

	CGFloat width = 540, height = 500;
	sheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setContentMinSize:NSMakeSize(width, height)];
	NSView *content = [sheet contentView];

	NSTextField *heading = [self _labelWithFrame:NSMakeRect(20, height - 36, width - 40, 18) text:[NSString stringWithFormat:NSLocalizedString(@"Export “%@”", @"Postgres export sheet: heading (database)"), database ?: @""]];
	[heading setAlignment:NSTextAlignmentLeft];
	[heading setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[heading setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:heading];

	// Format
	NSTextField *formatLabel = [self _labelWithFrame:NSMakeRect(20, height - 70, 80, 18) text:NSLocalizedString(@"Format:", @"Postgres export sheet: format label")];
	[formatLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:formatLabel];
	formatControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(108, height - 73, 140, 24)];
	[formatControl setSegmentCount:2];
	[formatControl setLabel:@"SQL" forSegment:0];
	[formatControl setLabel:@"CSV" forSegment:1];
	[formatControl setWidth:64 forSegment:0];
	[formatControl setWidth:64 forSegment:1];
	[formatControl setTrackingMode:NSSegmentSwitchTrackingSelectOne];
	[formatControl setSelectedSegment:SPPostgresExportFormatSQL];
	[formatControl setTarget:self];
	[formatControl setAction:@selector(_controlChanged:)];
	[formatControl setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:formatControl];

	// Source
	NSTextField *sourceLabel = [self _labelWithFrame:NSMakeRect(20, height - 104, 80, 18) text:NSLocalizedString(@"Source:", @"Postgres export sheet: source label")];
	[sourceLabel setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:sourceLabel];
	sourcePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, height - 109, 220, 26) pullsDown:NO];
	[sourcePopup setAutoenablesItems:NO];
	[sourcePopup addItemsWithTitles:@[NSLocalizedString(@"Whole database", @"Postgres export sheet: source"),
									  NSLocalizedString(@"Selected schemas", @"Postgres export sheet: source"),
									  NSLocalizedString(@"Selected tables", @"Postgres export sheet: source"),
									  NSLocalizedString(@"Query result", @"Postgres export sheet: source")]];
	[sourcePopup setTarget:self];
	[sourcePopup setAction:@selector(_controlChanged:)];
	[sourcePopup setAutoresizingMask:NSViewMinYMargin];
	[content addSubview:sourcePopup];

	// The lists (one shown at a time), or a note in their place
	NSRect listFrame = NSMakeRect(20, 200, width - 40, height - 320);
	schemasTable = [[self _checkListWithFrame:listFrame inView:content] retain];
	tablesTable = [[self _checkListWithFrame:listFrame inView:content] retain];
	sourceNote = [[self _labelWithFrame:NSMakeRect(20, 200 + listFrame.size.height - 24, width - 40, 18) text:@""] retain];
	[sourceNote setAlignment:NSTextAlignmentLeft];
	[sourceNote setTextColor:[NSColor secondaryLabelColor]];
	[sourceNote setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:sourceNote];

	// SQL options
	NSRect optionsFrame = NSMakeRect(20, 56, width - 40, 134);
	sqlOptions = [[NSView alloc] initWithFrame:optionsFrame];
	[sqlOptions setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	structureCheckbox = [self _checkboxWithFrame:NSMakeRect(84, 104, 300, 20) title:NSLocalizedString(@"Structure", @"Postgres export sheet: SQL option") on:YES];
	dataCheckbox = [self _checkboxWithFrame:NSMakeRect(84, 80, 300, 20) title:NSLocalizedString(@"Data", @"Postgres export sheet: SQL option") on:YES];
	compressCheckbox = [self _checkboxWithFrame:NSMakeRect(84, 56, 300, 20) title:NSLocalizedString(@"Compress (gzip)", @"Postgres export sheet: SQL option") on:NO];
	[sqlOptions addSubview:structureCheckbox];
	[sqlOptions addSubview:dataCheckbox];
	[sqlOptions addSubview:compressCheckbox];
	[content addSubview:sqlOptions];

	// CSV options
	csvOptions = [[NSView alloc] initWithFrame:optionsFrame];
	[csvOptions setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[csvOptions addSubview:[self _labelWithFrame:NSMakeRect(0, 108, 80, 18) text:NSLocalizedString(@"Delimiter:", @"Postgres export sheet: CSV option")]];
	delimiterPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(84, 103, 110, 26) pullsDown:NO];
	[delimiterPopup addItemsWithTitles:@[@",", @";", NSLocalizedString(@"Tab", @"Postgres export sheet: tab delimiter"), @"|", NSLocalizedString(@"Custom", @"Postgres export sheet: custom delimiter")]];
	[delimiterPopup setTarget:self];
	[delimiterPopup setAction:@selector(_controlChanged:)];
	[csvOptions addSubview:delimiterPopup];
	customDelimiterField = [self _fieldWithFrame:NSMakeRect(202, 106, 40, 22) text:@""];
	[csvOptions addSubview:customDelimiterField];

	[csvOptions addSubview:[self _labelWithFrame:NSMakeRect(0, 78, 80, 18) text:NSLocalizedString(@"Quote:", @"Postgres export sheet: CSV option")]];
	quoteField = [self _fieldWithFrame:NSMakeRect(86, 76, 40, 22) text:@"\""];
	[csvOptions addSubview:quoteField];
	[csvOptions addSubview:[self _labelWithFrame:NSMakeRect(140, 78, 60, 18) text:NSLocalizedString(@"Escape:", @"Postgres export sheet: CSV option")]];
	escapePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(204, 73, 70, 26) pullsDown:NO];
	[escapePopup addItemsWithTitles:@[@"\"", @"\\"]];
	[csvOptions addSubview:escapePopup];

	headerCheckbox = [self _checkboxWithFrame:NSMakeRect(84, 48, 300, 20) title:NSLocalizedString(@"First row holds column names", @"Postgres export sheet: CSV option") on:YES];
	[csvOptions addSubview:headerCheckbox];

	[csvOptions addSubview:[self _labelWithFrame:NSMakeRect(0, 18, 80, 18) text:NSLocalizedString(@"NULL as:", @"Postgres export sheet: CSV option")]];
	nullField = [self _fieldWithFrame:NSMakeRect(86, 16, 120, 22) text:@""];
	[csvOptions addSubview:nullField];
	[content addSubview:csvOptions];

	// Buttons
	exportButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 20 - 100, 12, 100, 32)];
	[exportButton setBezelStyle:NSBezelStyleRounded];
	[exportButton setTitle:NSLocalizedString(@"Export…", @"Postgres export sheet: export button")];
	[exportButton setKeyEquivalent:@"\r"];
	[exportButton setTarget:self];
	[exportButton setAction:@selector(export:)];
	[exportButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:exportButton];

	cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 20 - 100 - 100, 12, 100, 32)];
	[cancelButton setBezelStyle:NSBezelStyleRounded];
	[cancelButton setTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[cancelButton setKeyEquivalent:@"\e"];
	[cancelButton setTarget:self];
	[cancelButton setAction:@selector(cancel:)];
	[cancelButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancelButton];
}

#pragma mark - Lists

/// The schemas and their tables, read from the document's connection (catalog queries only), and the Query view's
/// result; the tables list is preset to the sidebar's selected table.
- (void)_loadLists
{
	SPPostgresCatalog *catalog = [[[SPPostgresCatalog alloc] initWithConnection:[document connection]] autorelease];
	NSError *error = nil;
	NSArray *schemas = [catalog schemaNames:&error];
	NSMutableArray *rows = [NSMutableArray array];
	for (NSString *schema in schemas) {
		NSError *tablesError = nil;
		NSArray *tables = [catalog tableNamesInSchema:schema error:&tablesError];
		if (!tables) {
			if (!error) error = tablesError;
			continue;
		}
		if (![tables count]) continue;
		[rows addObject:schema];
		for (NSString *table in tables) [rows addObject:@[schema, table]];
	}
	if (error) [self _setLastErrorMessage:[error localizedDescription]];

	// Which of them are partitioned (a failure leaves the set empty)
	NSMutableSet *partitioned = [NSMutableSet set];
	PGPostgresResult *partitionedResult = [[document connection] execute:@"SELECT n.nspname::text, c.relname::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'p'"];
	for (unsigned long long row = 0; row < [partitionedResult numberOfRows]; row++) {
		id schema = [partitionedResult textValueAtRow:row column:0], table = [partitionedResult textValueAtRow:row column:1];
		if ([schema isKindOfClass:[NSString class]] && [table isKindOfClass:[NSString class]]) [partitioned addObject:@[schema, table]];
	}
	[partitionedTables release];
	partitionedTables = [partitioned copy];

	[schemaNames release];
	schemaNames = [(schemas ?: @[]) copy];
	[tableRows release];
	tableRows = [rows copy];

	SPPostgresSidebarController *sidebar = [document sidebar];
	NSString *selectedSchema = [sidebar selectedSchema];
	NSString *selectedTable = [sidebar selectionIsTable] ? [sidebar selectedTableName] : nil;
	if (selectedTable && selectedSchema && [tableRows containsObject:@[selectedSchema, selectedTable]]) {
		[checkedTableList addObject:@[selectedSchema, selectedTable]];
	}
	if (selectedSchema && [schemaNames containsObject:selectedSchema]) [checkedSchemaList addObject:selectedSchema];

	// Only whether the Query view holds a result, and how many rows: the rows are read when the result is exported
	SPPostgresQueryController *query = [document queryController];
	[queryColumnNames release];
	queryColumnNames = [[query lastResultColumnNames] copy];
	queryRowCount = queryColumnNames ? [query lastResultRowCount] : 0;

	[schemasTable reloadData];
	[tablesTable reloadData];
}

- (NSArray *)checkedSchemas
{
	NSMutableArray *result = [NSMutableArray array];
	for (NSString *schema in schemaNames) if ([checkedSchemaList containsObject:schema]) [result addObject:schema];
	return result;
}

- (NSArray *)checkedTables
{
	NSMutableArray *result = [NSMutableArray array];
	for (id row in tableRows) if ([row isKindOfClass:[NSArray class]] && [checkedTableList containsObject:row]) [result addObject:row];
	return result;
}

- (void)setChecked:(BOOL)checked schema:(NSString *)schema
{
	if (!schema) return;
	[checkedSchemaList removeObject:schema];
	if (checked) [checkedSchemaList addObject:schema];
	[schemasTable reloadData];
	[self _updateControls];
}

- (void)setChecked:(BOOL)checked table:(NSString *)table schema:(NSString *)schema
{
	if (!table || !schema) return;
	NSArray *pair = @[schema, table];
	[checkedTableList removeObject:pair];
	if (checked) [checkedTableList addObject:pair];
	[tablesTable reloadData];
	[self _updateControls];
}

#pragma mark - Table views

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	if (tableView == schemasTable) return (NSInteger)[schemaNames count];
	if (tableView == tablesTable) return (NSInteger)[tableRows count];
	return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	BOOL isCheck = [[tableColumn identifier] isEqualToString:SPPostgresExportCheckColumn];
	if (tableView == schemasTable) {
		if (row < 0 || row >= (NSInteger)[schemaNames count]) return nil;
		NSString *schema = [schemaNames objectAtIndex:(NSUInteger)row];
		return isCheck ? @([checkedSchemaList containsObject:schema]) : schema;
	}
	if (tableView == tablesTable) {
		if (row < 0 || row >= (NSInteger)[tableRows count]) return nil;
		id entry = [tableRows objectAtIndex:(NSUInteger)row];
		if ([entry isKindOfClass:[NSString class]]) return isCheck ? nil : entry;
		return isCheck ? @([checkedTableList containsObject:entry]) : [entry objectAtIndex:1];
	}
	return nil;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (![[tableColumn identifier] isEqualToString:SPPostgresExportCheckColumn]) return;
	BOOL checked = [object boolValue];
	if (tableView == schemasTable && row >= 0 && row < (NSInteger)[schemaNames count]) {
		[self setChecked:checked schema:[schemaNames objectAtIndex:(NSUInteger)row]];
	}
	else if (tableView == tablesTable && row >= 0 && row < (NSInteger)[tableRows count]) {
		id entry = [tableRows objectAtIndex:(NSUInteger)row];
		if ([entry isKindOfClass:[NSArray class]]) [self setChecked:checked table:[entry objectAtIndex:1] schema:[entry objectAtIndex:0]];
	}
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
	if (tableView != tablesTable || row < 0 || row >= (NSInteger)[tableRows count]) return NO;
	return [[tableRows objectAtIndex:(NSUInteger)row] isKindOfClass:[NSString class]];
}

- (NSCell *)tableView:(NSTableView *)tableView dataCellForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	// A group row spans the columns with its schema name
	if (!tableColumn && [self tableView:tableView isGroupRow:row]) {
		NSTextFieldCell *cell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[cell setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
		return cell;
	}
	return [tableColumn dataCellForRow:row];
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return NO;
}

- (BOOL)tableView:(NSTableView *)tableView shouldTrackCell:(NSCell *)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	// The checkboxes toggle though rows can't be selected
	return [[tableColumn identifier] isEqualToString:SPPostgresExportCheckColumn] && ![self tableView:tableView isGroupRow:row];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
	return NO;
}

#pragma mark - Controls

- (SPPostgresExportFormat)_format
{
	return [formatControl selectedSegment] == SPPostgresExportFormatCSV ? SPPostgresExportFormatCSV : SPPostgresExportFormatSQL;
}

- (SPPostgresExportSource)_source
{
	NSInteger index = [sourcePopup indexOfSelectedItem];
	return (index >= 0 && index <= SPPostgresExportSourceQueryResult) ? (SPPostgresExportSource)index : SPPostgresExportSourceDatabase;
}

- (NSString *)_delimiter
{
	switch ([delimiterPopup indexOfSelectedItem]) {
		case 1: return @";";
		case 2: return @"\t";
		case 3: return @"|";
		case SPPostgresExportCustomDelimiterIndex: return [customDelimiterField stringValue];
		default: return @",";
	}
}

- (SPPostgresCSVOptions *)_csvOptions
{
	SPPostgresCSVOptions *options = [[[SPPostgresCSVOptions alloc] init] autorelease];
	[options setDelimiter:[self _delimiter]];
	[options setQuote:[quoteField stringValue]];
	[options setEscape:[escapePopup indexOfSelectedItem] == 1 ? @"\\" : @"\""];
	[options setHeader:[headerCheckbox state] == NSControlStateValueOn];
	[options setNullString:[nullField stringValue]];
	return options;
}

/// The tables a CSV export writes, as @[schema, table] pairs.
- (NSArray *)_csvTables
{
	switch ([self _source]) {
		case SPPostgresExportSourceTables:
			return [self checkedTables];
		case SPPostgresExportSourceSchemas: {
			NSArray *schemas = [self checkedSchemas];
			NSMutableArray *pairs = [NSMutableArray array];
			for (id row in tableRows) if ([row isKindOfClass:[NSArray class]] && [schemas containsObject:[row objectAtIndex:0]] && ![partitionedTables containsObject:row]) [pairs addObject:row];
			return pairs;
		}
		case SPPostgresExportSourceDatabase: {
			NSMutableArray *pairs = [NSMutableArray array];
			for (id row in tableRows) if ([row isKindOfClass:[NSArray class]] && ![partitionedTables containsObject:row]) [pairs addObject:row];
			return pairs;
		}
		default:
			return @[];
	}
}

- (BOOL)_canExport
{
	if (running) return NO;
	SPPostgresExportFormat format = [self _format];
	SPPostgresExportSource source = [self _source];

	if (source == SPPostgresExportSourceSchemas && ![[self checkedSchemas] count]) return NO;
	if (source == SPPostgresExportSourceTables && ![[self checkedTables] count]) return NO;

	if (format == SPPostgresExportFormatSQL) {
		if (source == SPPostgresExportSourceQueryResult) return NO;
		return [structureCheckbox state] == NSControlStateValueOn || [dataCheckbox state] == NSControlStateValueOn;
	}

	if (source == SPPostgresExportSourceQueryResult && !queryColumnNames) return NO;
	if ([[self _delimiter] length] != 1 || [[quoteField stringValue] length] != 1) return NO;
	return YES;
}

/// Follows the format and source: which options and list are shown, what can be chosen.
- (void)_updateControls
{
	SPPostgresExportFormat format = [self _format];
	BOOL csv = (format == SPPostgresExportFormatCSV);

	// Query result: CSV only, and only with a result in the Query view
	NSMenuItem *queryItem = [sourcePopup itemAtIndex:SPPostgresExportSourceQueryResult];
	[queryItem setEnabled:csv && queryColumnNames != nil];
	if ([self _source] == SPPostgresExportSourceQueryResult && ![queryItem isEnabled]) [sourcePopup selectItemAtIndex:SPPostgresExportSourceDatabase];

	SPPostgresExportSource source = [self _source];
	[[schemasTable enclosingScrollView] setHidden:source != SPPostgresExportSourceSchemas];
	[[tablesTable enclosingScrollView] setHidden:source != SPPostgresExportSourceTables];

	NSString *note = @"";
	if (source == SPPostgresExportSourceDatabase) {
		note = csv ? NSLocalizedString(@"Every table of the database, one CSV file each.", @"Postgres export sheet: whole database CSV note")
				   : NSLocalizedString(@"Every schema of the database.", @"Postgres export sheet: whole database SQL note");
	}
	else if (source == SPPostgresExportSourceQueryResult) {
		note = [NSString stringWithFormat:NSLocalizedString(@"The %lu rows the Query view shows (the query isn't run again).", @"Postgres export sheet: query result note (row count)"), (unsigned long)queryRowCount];
	}
	[sourceNote setStringValue:note];
	[sourceNote setHidden:![note length]];

	[sqlOptions setHidden:csv];
	[csvOptions setHidden:!csv];
	[customDelimiterField setEnabled:[delimiterPopup indexOfSelectedItem] == SPPostgresExportCustomDelimiterIndex];

	[exportButton setEnabled:[self _canExport]];
}

- (void)_controlChanged:(id)sender
{
	[self _updateControls];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self _updateControls];
}

#pragma mark - Sheet

- (void)beginSheet
{
	NSWindow *window = [document parentWindow];
	if (began || !window || [window attachedSheet]) {
		began = YES;
		[self _finish];
		return;
	}
	began = YES;
	[self retain]; // until -_finish

	[self _buildSheet];
	[self _loadLists];
	[self _updateControls];
	[window beginSheet:sheet completionHandler:nil];
}

/// Takes the sheet off the window (the controller stays).
- (void)_endSheet
{
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];
}

- (IBAction)cancel:(id)sender
{
	if (finished) return;
	if (running) {
		// The job sees it and stops; it deletes what it wrote, then the controller ends. While the path is being
		// chosen, nothing starts.
		if (progressSheet) [progressSheet cancel:nil];
		else abandoned = YES;
		return;
	}
	[self _endSheet];
	[self _finish];
}

- (void)_finish
{
	if (finished) return;
	finished = YES;
	[self _endSheet];

	void (^theDidEnd)(void) = [didEnd autorelease];
	didEnd = nil; // it may hold the document, which holds this controller
	if (theDidEnd) theDidEnd();
	if (began && sheet) [self autorelease]; // balances -beginSheet's retain
}

#pragma mark - Exporting

/// Asks where to write (see savePathProvider), then calls completion with the path or nil.
- (void)_choosePathSuggesting:(NSString *)suggestedName directory:(BOOL)directory completion:(void (^)(NSString *path))completion
{
	if (savePathProvider) {
		completion(savePathProvider(suggestedName, directory));
		return;
	}

	NSWindow *window = [document parentWindow];
	void (^done)(NSString *) = [[completion copy] autorelease];
	if (directory) {
		NSOpenPanel *panel = [NSOpenPanel openPanel];
		[panel setCanChooseFiles:NO];
		[panel setCanChooseDirectories:YES];
		[panel setCanCreateDirectories:YES];
		[panel setAllowsMultipleSelection:NO];
		[panel setPrompt:NSLocalizedString(@"Export", @"Postgres export: folder panel prompt")];
		[panel setMessage:NSLocalizedString(@"Choose the folder that receives one CSV file per table. Files with the same names are replaced.", @"Postgres export: folder panel message")];
		[panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
			done(response == NSModalResponseOK ? [[panel URL] path] : nil);
		}];
		return;
	}

	NSSavePanel *panel = [NSSavePanel savePanel];
	[panel setNameFieldStringValue:suggestedName];
	[panel setCanCreateDirectories:YES];
	[panel setExtensionHidden:NO];
	[panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		done(response == NSModalResponseOK ? [[panel URL] path] : nil);
	}];
}

- (IBAction)export:(id)sender
{
	if (finished || running || ![self _canExport]) return;
	[self _setLastErrorMessage:nil];
	[self _setCompletionNote:nil];

	SPPostgresExportFormat format = [self _format];
	SPPostgresExportSource source = [self _source];

	NSString *suggestedName = nil;
	BOOL directory = NO;
	NSArray *csvTables = nil;
	if (format == SPPostgresExportFormatSQL) {
		suggestedName = [NSString stringWithFormat:@"%@.sql%@", database, [compressCheckbox state] == NSControlStateValueOn ? @".gz" : @""];
	}
	else if (source == SPPostgresExportSourceQueryResult) {
		suggestedName = @"query-result.csv";
	}
	else {
		csvTables = [self _csvTables];
		if (![csvTables count]) {
			[self _setLastErrorMessage:NSLocalizedString(@"There are no tables to export.", @"Postgres export: no tables")];
			[self _presentError:lastErrorMessage];
			return;
		}
		if ([csvTables count] == 1) suggestedName = SPPostgresExportCSVFileName([[csvTables firstObject] objectAtIndex:0], [[csvTables firstObject] objectAtIndex:1]);
		else {
			suggestedName = database;
			directory = YES;
		}
	}

	running = YES; // while the path is chosen, nothing else starts
	[self _endSheet];
	[self _choosePathSuggesting:suggestedName directory:directory completion:^(NSString *path) {
		if (abandoned) {
			running = NO;
			[self _finish];
			return;
		}
		if (![path length]) {
			// Back to the sheet
			running = NO;
			NSWindow *window = [document parentWindow];
			if (window && ![window attachedSheet] && !finished) {
				[self _updateControls];
				[window beginSheet:sheet completionHandler:nil];
			}
			else [self _finish];
			return;
		}
		if (format == SPPostgresExportFormatSQL) [self _runSQLExportToPath:path];
		else if (source == SPPostgresExportSourceQueryResult) [self _runQueryResultExportToPath:path];
		else [self _runCSVExportOfTables:csvTables toPath:path directory:directory];
	}];
}

- (SPPostgresProgressSheet *)_beginProgress
{
	NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Exporting “%@”…", @"Postgres export: progress title (database)"), database];
	[progressSheet release];
	progressSheet = [[SPPostgresProgressSheet beginOnWindow:[document parentWindow] title:title] retain];
	[progressSheet setStatus:NSLocalizedString(@"Connecting…", @"Postgres export: progress status while connecting") fraction:0];
	return progressSheet;
}

/**
 * Runs work as a background job on a connection from the document's provider. Its SSH sheets (host key, passwords)
 * go to the progress sheet, which is on the window by then; a Cancel while connecting cancels the pending connector
 * and ends the job at once.
 */
- (void)_runJobWithProgress:(SPPostgresProgressSheet *)progress work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work
{
	NSWindow *progressWindow = [progress panel];
	SPPostgresConnectionProvider provider = [document connectionProviderForJobWithSheetWindow:^NSWindow *{
		return progressWindow;
	} connecting:^(SPPostgresConnector *theConnector) {
		if (theConnector == pendingConnector) return;
		[pendingConnector release];
		pendingConnector = [theConnector retain];
	}];

	[progress setCancelHandler:^{
		// While connecting: the job ends at once. Once it runs: the work sees the sheet's flag, and the statement its
		// connection is running is interrupted (a lock wait, a long statement)
		SPPostgresConnector *connecting = [job waitingForConnection] ? [[pendingConnector retain] autorelease] : nil;
		[job cancel];
		[connecting cancel];
	}];

	[job release];
	job = [[SPPostgresBackgroundJob runOnDatabase:database provider:provider work:work completion:^(BOOL ok, NSError *error) {
		// Whatever failed after Cancel (e.g. the statement the cancel interrupted) is the cancel
		NSError *outcome = error;
		if (!ok && [progress cancelled] && !([[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorCancelled)) {
			outcome = SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The export was cancelled.", @"Postgres export: cancelled"), nil);
		}
		[self _jobEndedWithSuccess:ok error:outcome];
	}] retain];
}

/// The job's progress report: shows it, lets the test seam see it, and answers whether to go on.
static BOOL SPPostgresExportReport(SPPostgresProgressSheet *progress, void (^observer)(SPPostgresProgressSheet *), NSUInteger index, NSUInteger count, NSString *table)
{
	NSString *status = [NSString stringWithFormat:NSLocalizedString(@"Table %lu of %lu: %@", @"Postgres export: progress status (index, count, table)"), (unsigned long)index, (unsigned long)count, table];
	[progress setStatus:status fraction:count ? (double)(index > 0 ? index - 1 : 0) / (double)count : 0];
	if (observer) observer(progress);
	return ![progress cancelled];
}

- (void)_runSQLExportToPath:(NSString *)path
{
	SPPostgresProgressSheet *progress = [self _beginProgress];
	SPPostgresExportSource source = [self _source];
	NSArray *schemas = (source == SPPostgresExportSourceSchemas) ? [self checkedSchemas] : nil;
	NSArray *tables = (source == SPPostgresExportSourceTables) ? [self checkedTables] : nil;
	BOOL structure = [structureCheckbox state] == NSControlStateValueOn;
	BOOL data = [dataCheckbox state] == NSControlStateValueOn;
	BOOL compress = [compressCheckbox state] == NSControlStateValueOn;
	void (^observer)(SPPostgresProgressSheet *) = [[progressObserver copy] autorelease];

	[self _runJobWithProgress:progress work:^BOOL(PGPostgresConnection *connection, NSError **error) {
		if ([progress cancelled]) {
			if (error) *error = SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The export was cancelled.", @"Postgres export: cancelled"), nil);
			return NO;
		}
		SPPostgresDumpWriter *writer = [[[SPPostgresDumpWriter alloc] initWithConnection:connection] autorelease];
		if (schemas) [writer setSchemas:schemas];
		else if (tables) [writer setTables:tables];
		else [writer setWholeDatabase:YES];
		[writer setIncludeStructure:structure];
		[writer setIncludeData:data];
		[writer setCompress:compress];
		[writer setProgress:^BOOL(NSUInteger index, NSUInteger count, NSString *table) {
			return SPPostgresExportReport(progress, observer, index, count, table);
		}];
		BOOL ok = [writer writeToPath:path error:error];
		if (ok && [[writer foreignTablesSkipped] count]) {
			NSMutableArray *names = [NSMutableArray array];
			for (NSArray *pair in [writer foreignTablesSkipped]) [names addObject:[NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier([pair objectAtIndex:0]), SPPostgresQuoteIdentifier([pair objectAtIndex:1])]];
			NSString *note = [NSString stringWithFormat:NSLocalizedString(@"Foreign tables aren't exported (nor their servers and user mappings): %@.", @"Postgres export: foreign tables left out (names)"), [names componentsJoinedByString:@", "]];
			// Before the job's completion, which is queued after this on the main queue
			dispatch_async(dispatch_get_main_queue(), ^{
				[self _setCompletionNote:note];
			});
		}
		return ok;
	}];
}

- (void)_runCSVExportOfTables:(NSArray *)tables toPath:(NSString *)path directory:(BOOL)directory
{
	SPPostgresProgressSheet *progress = [self _beginProgress];
	SPPostgresCSVOptions *options = [[[self _csvOptions] copy] autorelease];
	void (^observer)(SPPostgresProgressSheet *) = [[progressObserver copy] autorelease];

	[self _runJobWithProgress:progress work:^BOOL(PGPostgresConnection *connection, NSError **error) {
		NSMutableArray *written = [NSMutableArray array];
		NSError *failure = nil; // retained until the end
		BOOL ok = YES;

		// One consistent snapshot for every table
		if (![connection execute:@"BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"]) {
			failure = [SPPostgresMakeError(SPPostgresErrorQueryFailed, [[connection lastError] errorPrimaryMessage] ?: NSLocalizedString(@"The export could not start.", @"Postgres export: BEGIN failed"), nil) retain];
			ok = NO;
		}

		NSUInteger count = [tables count];
		for (NSUInteger index = 0; ok && index < count; index++) {
			@autoreleasepool {
				NSArray *pair = [tables objectAtIndex:index];
				NSString *schema = [pair objectAtIndex:0], *table = [pair objectAtIndex:1];
				if (!SPPostgresExportReport(progress, observer, index + 1, count, table)) {
					failure = [SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The export was cancelled.", @"Postgres export: cancelled"), nil) retain];
					ok = NO;
					continue;
				}
				NSString *file = directory ? [path stringByAppendingPathComponent:SPPostgresExportCSVFileName(schema, table)] : path;
				// A file that was there before is replaced, and stays after a cancel or a failure: only the files this
				// export created are deleted then
				struct stat existing;
				if (lstat([file fileSystemRepresentation], &existing) != 0) [written addObject:file];
				NSError *tableError = nil;
				ok = [SPPostgresCSV exportTable:table schema:schema connection:connection options:options toPath:file cancel:^BOOL{
					return [progress cancelled];
				} error:&tableError];
				if (!ok) failure = [tableError retain];
			}
		}

		if (ok && ![connection execute:@"COMMIT"]) {
			failure = [SPPostgresMakeError(SPPostgresErrorQueryFailed, [[connection lastError] errorPrimaryMessage] ?: NSLocalizedString(@"The export could not finish.", @"Postgres export: COMMIT failed"), nil) retain];
			ok = NO;
		}
		if (!ok) {
			// The connection is discarded after the job; a rollback leaves the server tidy meanwhile
			if ([connection transactionStatus] != PGPostgresTransactionIdle) [connection execute:@"ROLLBACK"];
			// Every file this export created goes, not only the one it was writing
			for (NSString *file in written) unlink([file fileSystemRepresentation]);
			if (error) *error = [[failure retain] autorelease];
		}
		[failure release];
		return ok;
	}];
}

- (void)_runQueryResultExportToPath:(NSString *)path
{
	SPPostgresProgressSheet *progress = [self _beginProgress];
	[progress setStatus:NSLocalizedString(@"Writing the query result…", @"Postgres export: progress status for a query result") fraction:0];
	SPPostgresCSVOptions *options = [[[self _csvOptions] copy] autorelease];
	// The rows the Query view holds, read now that they are exported (the sheet only kept their count)
	NSArray *rows = [[document queryController] lastResultRows];
	NSArray *names = [[queryColumnNames retain] autorelease];
	void (^observer)(SPPostgresProgressSheet *) = [[progressObserver copy] autorelease];

	// The rows are the client's: no connection is needed
	[self retain];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError *failure = nil;
		BOOL ok = NO;
		@autoreleasepool {
			if (SPPostgresExportReport(progress, observer, 1, 1, NSLocalizedString(@"query result", @"Postgres export: the query result as a table name"))) {
				NSError *writeError = nil;
				ok = [SPPostgresCSV exportRows:rows ?: @[] columnNames:names ?: @[] options:options toPath:path error:&writeError];
				failure = [writeError retain];
			}
			if (ok && [progress cancelled]) {
				unlink([path fileSystemRepresentation]);
				ok = NO;
			}
			if (!ok && !failure) failure = [SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The export was cancelled.", @"Postgres export: cancelled"), nil) retain];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _jobEndedWithSuccess:ok error:failure];
			[failure release];
			[self release];
		});
	});
}

- (void)_jobEndedWithSuccess:(BOOL)ok error:(NSError *)error
{
	if (finished) return;
	[progressSheet end];
	[job release];
	job = nil;
	[pendingConnector release];
	pendingConnector = nil;
	running = NO;

	if (!ok) {
		BOOL cancelled = [[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorCancelled;
		NSString *message = [error localizedDescription] ?: NSLocalizedString(@"The export failed.", @"Postgres export: failed without a message");
		[self _setLastErrorMessage:message];
		[self _setCompletionNote:nil];
		if (!cancelled) [self _presentError:message];
	}
	else if ([completionNote length]) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"The export finished", @"Postgres export: finished with a note title")];
		[alert setInformativeText:completionNote];
		[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
		[document presentAlert:alert];
	}
	[self _finish];
}

- (void)_presentError:(NSString *)message
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"The export failed", @"Postgres export: error title")];
	[alert setInformativeText:message ?: @""];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];

	// On the Export sheet while it is up (no presenter set); otherwise as the document shows its alerts: never
	// dropped, it waits while the tab isn't shown and queues behind a sheet still attached
	if ([sheet sheetParent] && ![document alertPresenter]) [alert beginSheetModalForWindow:sheet completionHandler:nil];
	else [document presentAlert:alert];
}

@end
