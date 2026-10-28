#import "SPPostgresConstraintSheet.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresTableDuplicator.h"
#import <PostgresKit/PostgresKit.h>

NSString * const SPPostgresConstraintSheetIndexKind = @"INDEX";

static const CGFloat SPPostgresConstraintSheetWidth = 440;
static const CGFloat SPPostgresConstraintSheetLabelWidth = 120;
static const CGFloat SPPostgresConstraintSheetMargin = 20;

@implementation SPPostgresIndexDefinition

@synthesize unique = _unique;
@synthesize method = _method;

- (void)dealloc
{
	[_method release];
	[super dealloc];
}

@end

@implementation SPPostgresConstraintSheet
{
	NSString *initialKind;
	NSArray *columnNames;
	NSString *initialSchema;
	PGPostgresConnection *connection;
	SPPostgresCatalog *catalog;
	void (^completion)(SPPostgresConstraintDefinition *);

	NSMutableArray *chosenColumns;      // in the order they were checked
	NSArray *referencedColumnNames;
	NSMutableArray *chosenReferenced;

	NSWindow *sheet;
	NSWindow *parentWindow;
	NSTextField *titleLabel;
	NSPopUpButton *kindPopup;
	NSTextField *nameField;
	NSTableView *columnsTable;
	NSTextField *checkField;
	NSButton *uniqueSwitch;
	NSPopUpButton *methodPopup;
	NSPopUpButton *schemaPopup;
	NSPopUpButton *tablePopup;
	NSTableView *referencedTable;
	NSPopUpButton *onUpdatePopup;
	NSPopUpButton *onDeletePopup;
	NSButton *addButton;

	/// Each row of the form: @[label, control view] (the label may be NSNull), laid out top-down while visible
	NSMutableArray *rows;
}

#pragma mark - Begin

+ (void)beginForKind:(NSString *)kind columns:(NSArray *)columnNames connection:(PGPostgresConnection *)connection window:(NSWindow *)window completion:(void (^)(SPPostgresConstraintDefinition *))completion
{
	[self beginForKind:kind columns:columnNames schema:nil connection:connection window:window completion:completion];
}

+ (void)beginForKind:(NSString *)kind columns:(NSArray *)columnNames schema:(NSString *)schema connection:(PGPostgresConnection *)connection window:(NSWindow *)window completion:(void (^)(SPPostgresConstraintDefinition *))completion
{
	if (!completion) return;
	if (!window || [window attachedSheet]) {
		completion(nil);
		return;
	}

	SPPostgresConstraintSheet *controller = [[self alloc] initWithKind:kind columns:columnNames schema:schema connection:connection completion:completion];
	[controller _beginOn:window]; // keeps itself until the sheet ends
	[controller release];
}

- (instancetype)initWithKind:(NSString *)kind columns:(NSArray *)theColumns schema:(NSString *)schema connection:(PGPostgresConnection *)theConnection completion:(void (^)(SPPostgresConstraintDefinition *))theCompletion
{
	if ((self = [super init])) {
		initialKind = [([kind length] ? kind : @"PRIMARY KEY") copy];
		columnNames = [(theColumns ?: @[]) copy];
		initialSchema = [schema copy];
		connection = [theConnection retain];
		catalog = [[SPPostgresCatalog alloc] initWithConnection:connection];
		completion = [theCompletion copy];
		chosenColumns = [[NSMutableArray alloc] init];
		chosenReferenced = [[NSMutableArray alloc] init];
		referencedColumnNames = [@[] retain];
		rows = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[columnsTable setDataSource:nil];
	[columnsTable setDelegate:nil];
	[referencedTable setDataSource:nil];
	[referencedTable setDelegate:nil];
	[nameField setDelegate:nil];
	[checkField setDelegate:nil];

	[initialKind release];
	[columnNames release];
	[initialSchema release];
	[connection release];
	[catalog release];
	[completion release];
	[chosenColumns release];
	[referencedColumnNames release];
	[chosenReferenced release];
	[sheet release];
	[titleLabel release];
	[kindPopup release];
	[nameField release];
	[columnsTable release];
	[checkField release];
	[uniqueSwitch release];
	[methodPopup release];
	[schemaPopup release];
	[tablePopup release];
	[referencedTable release];
	[onUpdatePopup release];
	[onDeletePopup release];
	[addButton release];
	[rows release];

	[super dealloc];
}

#pragma mark - Building

- (NSString *)_kind
{
	if ([initialKind isEqualToString:SPPostgresConstraintSheetIndexKind]) return SPPostgresConstraintSheetIndexKind;
	if (![kindPopup isHidden] && [kindPopup titleOfSelectedItem]) return [kindPopup titleOfSelectedItem];
	return initialKind;
}

- (NSTextField *)_label:(NSString *)text
{
	NSTextField *label = [NSTextField labelWithString:text];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[label setAlignment:NSTextAlignmentRight];
	return label;
}

- (NSPopUpButton *)_popupWithTitles:(NSArray *)titles identifier:(NSString *)identifier
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 22) pullsDown:NO];
	[popup setIdentifier:identifier];
	[[popup cell] setControlSize:NSControlSizeSmall];
	[popup setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[popup addItemsWithTitles:titles];
	return popup;
}

- (NSTextField *)_fieldWithIdentifier:(NSString *)identifier placeholder:(NSString *)placeholder
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 19)];
	[field setIdentifier:identifier];
	[[field cell] setControlSize:NSControlSizeSmall];
	[field setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[field cell] setScrollable:YES];
	[[field cell] setUsesSingleLineMode:YES];
	[[field cell] setPlaceholderString:placeholder];
	[field setDelegate:self];
	return field;
}

/// A checkbox list of column names in a scroll view (checked: chosen).
- (NSTableView *)_columnListWithIdentifier:(NSString *)identifier scrollView:(NSScrollView **)scrollView
{
	*scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 96)] autorelease];
	[*scrollView setHasVerticalScroller:YES];
	[*scrollView setAutohidesScrollers:YES];
	[*scrollView setBorderType:NSBezelBorder];

	NSTableView *list = [[NSTableView alloc] initWithFrame:[[*scrollView contentView] bounds]];
	[list setIdentifier:identifier];
	[list setHeaderView:nil];
	[list setRowHeight:17];
	[list setFocusRingType:NSFocusRingTypeNone];
	[list setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];

	NSTableColumn *use = [[[NSTableColumn alloc] initWithIdentifier:@"use"] autorelease];
	NSButtonCell *check = [[[NSButtonCell alloc] initTextCell:@""] autorelease];
	[check setButtonType:NSButtonTypeSwitch];
	[check setControlSize:NSControlSizeSmall];
	[check setImagePosition:NSImageOnly];
	[use setDataCell:check];
	[use setWidth:20];
	[list addTableColumn:use];

	NSTableColumn *name = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
	[[name dataCell] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[name setEditable:NO];
	[name setWidth:170];
	[list addTableColumn:name];

	[list setDataSource:self];
	[list setDelegate:self];
	[*scrollView setDocumentView:list];
	return list;
}

- (void)_addRow:(NSString *)label control:(NSView *)control
{
	[rows addObject:@[label ? (id)[self _label:label] : (id)[NSNull null], control]];
}

- (void)_build
{
	BOOL isIndex = [initialKind isEqualToString:SPPostgresConstraintSheetIndexKind];
	BOOL isForeignKey = [initialKind isEqualToString:@"FOREIGN KEY"];

	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, SPPostgresConstraintSheetWidth, 200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];

	NSString *title = isIndex ? NSLocalizedString(@"Add Index", @"Postgres constraint sheet: index title")
		: (isForeignKey ? NSLocalizedString(@"Add Foreign Key", @"Postgres constraint sheet: foreign key title") : NSLocalizedString(@"Add Constraint", @"Postgres constraint sheet: constraint title"));
	[sheet setTitle:title];
	titleLabel = [[NSTextField labelWithString:title] retain];
	[titleLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];

	// The kind (constraints other than a foreign key, which has its own mode)
	kindPopup = [self _popupWithTitles:@[@"PRIMARY KEY", @"UNIQUE", @"CHECK", @"FOREIGN KEY"] identifier:@"constraintKind"];
	if ([kindPopup indexOfItemWithTitle:initialKind] >= 0) [kindPopup selectItemWithTitle:initialKind];
	[kindPopup setTarget:self];
	[kindPopup setAction:@selector(_kindChanged:)];
	[kindPopup setHidden:isIndex || isForeignKey];
	[self _addRow:NSLocalizedString(@"Type:", @"Postgres constraint sheet: kind label") control:kindPopup];

	nameField = [self _fieldWithIdentifier:@"constraintName" placeholder:NSLocalizedString(@"Optional", @"Postgres constraint sheet: optional name placeholder")];
	[self _addRow:NSLocalizedString(@"Name:", @"Postgres constraint sheet: name label") control:nameField];

	NSScrollView *columnsScroll = nil;
	columnsTable = [self _columnListWithIdentifier:@"constraintColumns" scrollView:&columnsScroll];
	[self _addRow:NSLocalizedString(@"Columns:", @"Postgres constraint sheet: columns label") control:columnsScroll];

	checkField = [self _fieldWithIdentifier:@"constraintCheck" placeholder:NSLocalizedString(@"e.g. price > 0", @"Postgres constraint sheet: check placeholder")];
	[checkField setFont:[NSFont monospacedSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightRegular]];
	[self _addRow:NSLocalizedString(@"Check:", @"Postgres constraint sheet: check label") control:checkField];

	// Index options
	uniqueSwitch = [[NSButton checkboxWithTitle:NSLocalizedString(@"Unique", @"Postgres constraint sheet: unique checkbox") target:nil action:NULL] retain];
	[uniqueSwitch setIdentifier:@"indexUnique"];
	[uniqueSwitch setControlSize:NSControlSizeSmall];
	[uniqueSwitch setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[self _addRow:nil control:uniqueSwitch];
	methodPopup = [self _popupWithTitles:@[@"btree", @"hash", @"gist", @"gin", @"brin"] identifier:@"indexMethod"];
	[self _addRow:NSLocalizedString(@"Method:", @"Postgres constraint sheet: index method label") control:methodPopup];

	// Foreign key: the referenced schema and table (from the catalog), its columns, the actions
	schemaPopup = [self _popupWithTitles:@[] identifier:@"referencedSchema"];
	[schemaPopup setTarget:self];
	[schemaPopup setAction:@selector(_schemaChanged:)];
	[self _addRow:NSLocalizedString(@"References schema:", @"Postgres constraint sheet: referenced schema label") control:schemaPopup];
	tablePopup = [self _popupWithTitles:@[] identifier:@"referencedTable"];
	[tablePopup setTarget:self];
	[tablePopup setAction:@selector(_tableChanged:)];
	[self _addRow:NSLocalizedString(@"Table:", @"Postgres constraint sheet: referenced table label") control:tablePopup];
	NSScrollView *referencedScroll = nil;
	referencedTable = [self _columnListWithIdentifier:@"referencedColumns" scrollView:&referencedScroll];
	[referencedScroll setToolTip:NSLocalizedString(@"None checked: the table's primary key", @"Postgres constraint sheet: referenced columns tooltip")];
	[self _addRow:NSLocalizedString(@"Referenced columns:", @"Postgres constraint sheet: referenced columns label") control:referencedScroll];
	NSArray *actions = @[@"NO ACTION", @"RESTRICT", @"CASCADE", @"SET NULL", @"SET DEFAULT"];
	onUpdatePopup = [self _popupWithTitles:actions identifier:@"onUpdate"];
	[self _addRow:NSLocalizedString(@"On update:", @"Postgres constraint sheet: on update label") control:onUpdatePopup];
	onDeletePopup = [self _popupWithTitles:actions identifier:@"onDelete"];
	[self _addRow:NSLocalizedString(@"On delete:", @"Postgres constraint sheet: on delete label") control:onDeletePopup];

	NSView *content = [sheet contentView];
	[content addSubview:titleLabel];
	for (NSArray *row in rows) {
		if ([row objectAtIndex:0] != [NSNull null]) [content addSubview:[row objectAtIndex:0]];
		[content addSubview:[row objectAtIndex:1]];
	}

	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(_close:)];
	[cancel setTag:NSModalResponseCancel];
	[cancel setKeyEquivalent:@"\e"];
	[cancel setFrame:NSMakeRect(SPPostgresConstraintSheetWidth - 200, 12, 91, 28)];
	[content addSubview:cancel];
	addButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Add", @"Postgres constraint sheet: add button") target:self action:@selector(_close:)] retain];
	[addButton setIdentifier:@"constraintAddButton"];
	[addButton setTag:NSModalResponseOK];
	[addButton setKeyEquivalent:@"\r"];
	[addButton setFrame:NSMakeRect(SPPostgresConstraintSheetWidth - 110, 12, 91, 28)];
	[content addSubview:addButton];

	[self _loadSchemas];
	[self _updateVisibility];
	[sheet setInitialFirstResponder:nameField];
}

/// Shows the rows the kind uses, laid out top-down, and fits the sheet to them.
- (void)_updateVisibility
{
	NSString *kind = [self _kind];
	BOOL isIndex = [kind isEqualToString:SPPostgresConstraintSheetIndexKind];
	BOOL isCheck = [kind isEqualToString:@"CHECK"];
	BOOL isForeignKey = [kind isEqualToString:@"FOREIGN KEY"];
	BOOL showsKind = !isIndex && ![initialKind isEqualToString:@"FOREIGN KEY"];

	NSDictionary *visible = @{
		@"constraintKind": @(showsKind),
		@"constraintName": @YES,
		@"constraintColumns": @(!isCheck),
		@"constraintCheck": @(isCheck),
		@"indexUnique": @(isIndex),
		@"indexMethod": @(isIndex),
		@"referencedSchema": @(isForeignKey),
		@"referencedTable": @(isForeignKey),
		@"referencedColumns": @(isForeignKey),
		@"onUpdate": @(isForeignKey),
		@"onDelete": @(isForeignKey),
	};

	CGFloat height = 0;
	for (NSArray *row in rows) {
		NSView *control = [row objectAtIndex:1];
		NSString *identifier = [control identifier] ?: [[(NSScrollView *)control documentView] identifier];
		BOOL shown = [[visible objectForKey:identifier] boolValue];
		[control setHidden:!shown];
		if ([row objectAtIndex:0] != [NSNull null]) [[row objectAtIndex:0] setHidden:!shown];
		if (shown) height += NSHeight([control frame]) + 8;
	}
	height += 30 + 56; // title, buttons

	NSRect frame = [sheet frame];
	NSRect contentRect = [sheet contentRectForFrameRect:frame];
	contentRect.origin.y += NSHeight(contentRect) - height;
	contentRect.size.height = height;
	[sheet setFrame:[sheet frameRectForContentRect:contentRect] display:[sheet isVisible] animate:NO];

	CGFloat y = height - 14 - 18;
	[titleLabel setFrame:NSMakeRect(SPPostgresConstraintSheetMargin, y, SPPostgresConstraintSheetWidth - 2 * SPPostgresConstraintSheetMargin, 18)];
	y -= 10;
	CGFloat controlX = SPPostgresConstraintSheetMargin + SPPostgresConstraintSheetLabelWidth + 8;
	CGFloat controlWidth = SPPostgresConstraintSheetWidth - controlX - SPPostgresConstraintSheetMargin;
	for (NSArray *row in rows) {
		NSView *control = [row objectAtIndex:1];
		if ([control isHidden]) continue;
		CGFloat controlHeight = NSHeight([control frame]);
		y -= controlHeight;
		[control setFrame:NSMakeRect(controlX, y, controlWidth, controlHeight)];
		id label = [row objectAtIndex:0];
		if (label != [NSNull null]) [label setFrame:NSMakeRect(SPPostgresConstraintSheetMargin, y + controlHeight - 18, SPPostgresConstraintSheetLabelWidth, 16)];
		y -= 8;
	}

	[self _validate];
}

#pragma mark - Catalog

- (void)_loadSchemas
{
	NSArray *schemas = [catalog schemaNames:NULL] ?: @[];
	[schemaPopup removeAllItems];
	[schemaPopup addItemsWithTitles:schemas];

	NSString *schema = initialSchema;
	if (![schemas containsObject:schema]) {
		PGPostgresResult *result = [connection execute:@"SELECT current_schema()::text"];
		id current = [result numberOfRows] ? [[result rowAsArray] firstObject] : nil;
		schema = [current isKindOfClass:[NSString class]] ? current : nil;
	}
	if ([schemas containsObject:schema]) [schemaPopup selectItemWithTitle:schema];
	[self _loadTables];
}

- (void)_loadTables
{
	NSString *schema = [schemaPopup titleOfSelectedItem];
	NSArray *tables = schema ? ([catalog tableNamesInSchema:schema error:NULL] ?: @[]) : @[];
	[tablePopup removeAllItems];
	[tablePopup addItemsWithTitles:tables];
	[self _loadReferencedColumns];
}

- (void)_loadReferencedColumns
{
	NSString *schema = [schemaPopup titleOfSelectedItem];
	NSString *table = [tablePopup titleOfSelectedItem];
	NSArray *names = @[];
	if ([schema length] && [table length]) {
		SPPostgresTableStructure *structure = [[[SPPostgresTableStructure alloc] initWithConnection:connection schema:schema table:table] autorelease];
		names = [[structure columns:NULL] valueForKey:@"name"] ?: @[];
	}
	[referencedColumnNames release];
	referencedColumnNames = [names copy];
	[chosenReferenced removeAllObjects];
	[referencedTable reloadData];
	[self _validate];
}

- (void)_schemaChanged:(id)sender
{
	[self _loadTables];
}

- (void)_tableChanged:(id)sender
{
	[self _loadReferencedColumns];
}

- (void)_kindChanged:(id)sender
{
	[self _updateVisibility];
}

#pragma mark - Validation

- (void)_validate
{
	NSString *kind = [self _kind];
	NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	BOOL valid = ![name length] || [SPPostgresTableDuplicator isValidTableName:name];

	if ([kind isEqualToString:@"CHECK"]) {
		valid = valid && [[[checkField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
	}
	else {
		valid = valid && [chosenColumns count] > 0;
	}
	if ([kind isEqualToString:@"FOREIGN KEY"]) {
		valid = valid && [[tablePopup titleOfSelectedItem] length] > 0 && (![chosenReferenced count] || [chosenReferenced count] == [chosenColumns count]);
	}
	[addButton setEnabled:valid];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self _validate];
}

#pragma mark - Column lists

- (NSInteger)numberOfRowsInTableView:(NSTableView *)list
{
	return (NSInteger)[(list == columnsTable ? columnNames : referencedColumnNames) count];
}

- (id)tableView:(NSTableView *)list objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSArray *names = (list == columnsTable) ? columnNames : referencedColumnNames;
	if (row < 0 || row >= (NSInteger)[names count]) return nil;
	NSString *name = [names objectAtIndex:(NSUInteger)row];
	if ([[tableColumn identifier] isEqualToString:@"use"]) return @([(list == columnsTable ? chosenColumns : chosenReferenced) containsObject:name]);
	return name;
}

- (void)tableView:(NSTableView *)list setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSArray *names = (list == columnsTable) ? columnNames : referencedColumnNames;
	NSMutableArray *chosen = (list == columnsTable) ? chosenColumns : chosenReferenced;
	if (row < 0 || row >= (NSInteger)[names count] || ![[tableColumn identifier] isEqualToString:@"use"]) return;

	NSString *name = [names objectAtIndex:(NSUInteger)row];
	[chosen removeObject:name];
	if ([object boolValue]) [chosen addObject:name];
	[list reloadData];
	[self _validate];
}

- (BOOL)tableView:(NSTableView *)list shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	return [[tableColumn identifier] isEqualToString:@"use"];
}

#pragma mark - Ending

- (void)_beginOn:(NSWindow *)window
{
	[self _build];
	parentWindow = window;

	[self retain]; // until the sheet ends
	[window beginSheet:sheet completionHandler:^(NSModalResponse returnCode) {
		SPPostgresConstraintDefinition *definition = (returnCode == NSModalResponseOK) ? [self _definition] : nil;
		[sheet orderOut:nil];
		void (^done)(SPPostgresConstraintDefinition *) = [[completion retain] autorelease];
		[completion release];
		completion = nil;
		if (done) done(definition);
		[self release];
	}];
}

- (void)_close:(id)sender
{
	if ([sender tag] == NSModalResponseOK && ![addButton isEnabled]) {
		NSBeep();
		return;
	}
	[[sheet sheetParent] endSheet:sheet returnCode:[sender tag]];
}

- (SPPostgresConstraintDefinition *)_definition
{
	NSString *kind = [self _kind];
	NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	SPPostgresConstraintDefinition *definition = nil;
	if ([kind isEqualToString:SPPostgresConstraintSheetIndexKind]) {
		SPPostgresIndexDefinition *index = [[[SPPostgresIndexDefinition alloc] init] autorelease];
		[index setUnique:[uniqueSwitch state] == NSControlStateValueOn];
		[index setMethod:[methodPopup titleOfSelectedItem]];
		definition = index;
	}
	else {
		definition = [[[SPPostgresConstraintDefinition alloc] init] autorelease];
	}

	[definition setKind:kind];
	[definition setName:[name length] ? name : nil];
	if ([kind isEqualToString:@"CHECK"]) {
		[definition setCheckExpression:[checkField stringValue]];
	}
	else {
		[definition setColumns:[[chosenColumns copy] autorelease]];
	}
	if ([kind isEqualToString:@"FOREIGN KEY"]) {
		[definition setReferencedSchema:[schemaPopup titleOfSelectedItem]];
		[definition setReferencedTable:[tablePopup titleOfSelectedItem]];
		[definition setReferencedColumns:[chosenReferenced count] ? [[chosenReferenced copy] autorelease] : nil];
		NSString *onUpdate = [onUpdatePopup titleOfSelectedItem];
		NSString *onDelete = [onDeletePopup titleOfSelectedItem];
		[definition setOnUpdate:[onUpdate isEqualToString:@"NO ACTION"] ? nil : onUpdate];
		[definition setOnDelete:[onDelete isEqualToString:@"NO ACTION"] ? nil : onDelete];
	}
	return definition;
}

@end
