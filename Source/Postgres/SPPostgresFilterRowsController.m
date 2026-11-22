//
//  SPPostgresFilterRowsController.m
//  Sequel Plus
//

#import "SPPostgresFilterRowsController.h"
#import "SPPostgresTableData.h"
#import "SPButtonBar.h"

static const CGFloat SPPostgresFilterRowHeight = 29;
static const CGFloat SPPostgresFilterBarHeight = 23;
/// Where the rows start above the area's bottom: the bar and an 8 pt gap (DBView.xib)
static const CGFloat SPPostgresFilterRowsBottom = 31;

typedef NS_ENUM(NSInteger, SPPostgresFilterNodeKind) {
	SPPostgresFilterNodeColumn,
	SPPostgresFilterNodeComparison,
	SPPostgresFilterNodeValue,
};

/// One criterion of a row: a column, a comparison under it, or the value under a comparison that takes one.
@interface SPPostgresFilterNode : NSObject
{
	SPPostgresFilterNodeKind kind;
	NSString *title;
	NSArray *children;
}
@property (assign) SPPostgresFilterNodeKind kind;
@property (copy) NSString *title;
@property (retain) NSArray *children;
@end

@implementation SPPostgresFilterNode
@synthesize kind, title, children;
- (void)dealloc
{
	[title release];
	[children release];
	[super dealloc];
}
@end

@interface SPPostgresFilterRowsController () <NSRuleEditorDelegate, NSTextFieldDelegate>
@end

@implementation SPPostgresFilterRowsController
{
	NSView *view;
	NSScrollView *scrollView;
	NSRuleEditor *ruleEditor;
	NSButton *resetButton, *addFilterButton, *filterButton;
	NSArray *columnNames;
	NSArray *columnNodes;     // SPPostgresFilterNode trees, one per column
	NSUInteger rowCount;      // as of the last rows-changed notification
	NSInteger programmaticChange; // > 0 while this class changes the rows
	BOOL invalidated;             // -invalidate: no more fields, targets or callbacks
	void (^onApply)(void), (^onReset)(void), (^onLastRowRemoved)(void), (^onHeightChanged)(void);
}

@synthesize view, ruleEditor, resetButton, addFilterButton, filterButton;
@synthesize onApply, onReset, onLastRowRemoved, onHeightChanged;

+ (NSArray<NSString *> *)comparisons
{
	return @[@"=", @"≠", @">", @"<", @">=", @"<=", @"LIKE", @"NOT LIKE", @"ILIKE", @"IS NULL", @"IS NOT NULL", @"IN"];
}

+ (BOOL)comparisonTakesValue:(NSString *)comparison
{
	return ![comparison isEqualToString:@"IS NULL"] && ![comparison isEqualToString:@"IS NOT NULL"];
}

- (instancetype)init
{
	if ((self = [super init])) {
		columnNames = [@[] retain];
		columnNodes = [@[] retain];
		[self _buildView];
		[self _updateEnabled];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];
	[view release];
	[scrollView release];
	[ruleEditor release];
	[resetButton release];
	[addFilterButton release];
	[filterButton release];
	[columnNames release];
	[columnNodes release];
	[onApply release];
	[onReset release];
	[onLastRowRemoved release];
	[onHeightChanged release];
	[super dealloc];
}

#pragma mark - View

- (NSButton *)_smallButtonTitled:(NSString *)title toolTip:(NSString *)toolTip frame:(NSRect)frame action:(SEL)action
{
	NSButton *button = [[NSButton alloc] initWithFrame:frame];
	[button setBezelStyle:NSBezelStyleRoundRect];
	[[button cell] setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[button setTitle:title];
	[button setToolTip:toolTip];
	[button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[button setTarget:self];
	[button setAction:action];
	return button;
}

- (void)_buildView
{
	CGFloat width = 700;
	view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresFilterRowsBottom)];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];

	// The rows: DBView.xib's scroll view (no border, scrollers only when needed) holding the rule editor
	scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, SPPostgresFilterRowsBottom, width, 0)];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:NO];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setDrawsBackground:NO];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	ruleEditor = [[NSRuleEditor alloc] initWithFrame:NSMakeRect(0, 0, width, 0)];
	[ruleEditor setNestingMode:NSRuleEditorNestingModeList];
	[ruleEditor setRowHeight:SPPostgresFilterRowHeight];
	[ruleEditor setCanRemoveAllRows:YES];
	[ruleEditor setAutoresizingMask:NSViewWidthSizable];
	[ruleEditor setDelegate:self];
	[scrollView setDocumentView:ruleEditor];
	[view addSubview:scrollView];

	// The bar: DBView.xib's Reset (left), Add Filter and Filter (right)
	SPButtonBar *bar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresFilterBarHeight)] autorelease];
	[bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];

	resetButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, -1, 32, 23)];
	[resetButton setBezelStyle:NSBezelStyleTexturedRounded];
	[resetButton setImage:[NSImage imageNamed:@"button_clear"]];
	[resetButton setTitle:@""];
	[resetButton setImagePosition:NSImageOnly]; // after the title, which resets it
	[resetButton setToolTip:NSLocalizedString(@"Delete any defined filter conditions and reload the table (⌘⎋)", @"Postgres content: filter reset button tooltip")];
	[resetButton setKeyEquivalent:@"\e"];
	[resetButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[resetButton setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[resetButton setTarget:self];
	[resetButton setAction:@selector(_reset:)];
	[bar addSubview:resetButton];

	filterButton = [self _smallButtonTitled:NSLocalizedString(@"Filter", @"filter button title")
									toolTip:NSLocalizedString(@"Query the current table using the filter conditions defined above", @"Postgres content: filter button tooltip")
									  frame:NSMakeRect(width - 10 - 55, 2, 55, 17) action:@selector(_apply:)];
	[bar addSubview:filterButton];

	// In Filter's place, as MySQL's (SPRuleFilterController -awakeFromNib): only one of them shows (see -_updateEnabled)
	addFilterButton = [self _smallButtonTitled:NSLocalizedString(@"Add Filter", @"Postgres content: add filter button title")
									   toolTip:NSLocalizedString(@"Adds a new filter condition which can be used to limit the results displayed below", @"Postgres content: add filter button tooltip")
										 frame:NSMakeRect(width - 10 - 85, 2, 85, 17) action:@selector(_addFilter:)];
	[bar addSubview:addFilterButton];

	[view addSubview:bar];
}

- (CGFloat)preferredHeight
{
	return [ruleEditor numberOfRows] * SPPostgresFilterRowHeight + SPPostgresFilterRowsBottom;
}

/// The rule editor as tall as its rows (AppKit may stretch it to fill the visible area), as wide as the scroll view shows.
- (void)_sizeRuleEditor
{
	NSSize size = NSMakeSize([scrollView contentSize].width, [ruleEditor numberOfRows] * SPPostgresFilterRowHeight);
	[ruleEditor setFrameSize:size];
}

/// As MySQL's (SPRuleFilterController -_updateButtonStates): with no rows only Add Filter shows, Reset disabled; with
/// rows only Filter shows. Nothing is enabled without columns.
- (void)_updateEnabled
{
	BOOL hasColumns = [columnNames count] > 0;
	BOOL empty = [ruleEditor numberOfRows] == 0;
	[ruleEditor setEditable:hasColumns];
	[addFilterButton setHidden:!empty];
	[filterButton setHidden:empty];
	[resetButton setEnabled:hasColumns && !empty];
	[filterButton setEnabled:hasColumns && !empty];
	[addFilterButton setEnabled:hasColumns && empty];
}

#pragma mark - Columns and rows

- (NSArray<NSString *> *)columnNames
{
	return [[columnNames retain] autorelease];
}

- (void)setColumnNames:(NSArray<NSString *> *)names
{
	[self removeAllRows];
	[columnNames release];
	columnNames = [(names ?: @[]) copy];

	NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:[columnNames count]];
	for (NSString *name in columnNames) {
		NSMutableArray *comparisonNodes = [NSMutableArray array];
		for (NSString *comparison in [[self class] comparisons]) {
			SPPostgresFilterNode *comparisonNode = [[[SPPostgresFilterNode alloc] init] autorelease];
			[comparisonNode setKind:SPPostgresFilterNodeComparison];
			[comparisonNode setTitle:comparison];
			if ([[self class] comparisonTakesValue:comparison]) {
				SPPostgresFilterNode *valueNode = [[[SPPostgresFilterNode alloc] init] autorelease];
				[valueNode setKind:SPPostgresFilterNodeValue];
				[valueNode setTitle:@""];
				[comparisonNode setChildren:@[valueNode]];
			}
			[comparisonNodes addObject:comparisonNode];
		}
		SPPostgresFilterNode *columnNode = [[[SPPostgresFilterNode alloc] init] autorelease];
		[columnNode setKind:SPPostgresFilterNodeColumn];
		[columnNode setTitle:name];
		[columnNode setChildren:comparisonNodes];
		[nodes addObject:columnNode];
	}
	[columnNodes release];
	columnNodes = [nodes copy];
	[self _updateEnabled];
}

- (NSUInteger)numberOfRows
{
	return (NSUInteger)[ruleEditor numberOfRows];
}

- (SPPostgresFilterNode *)_columnNodeNamed:(NSString *)name
{
	for (SPPostgresFilterNode *node in columnNodes) {
		if ([[node title] isEqualToString:name]) return node;
	}
	return nil;
}

- (SPPostgresFilterNode *)_child:(NSString *)title of:(SPPostgresFilterNode *)node
{
	for (SPPostgresFilterNode *child in [node children]) {
		if ([[child title] isEqualToString:title]) return child;
	}
	return nil;
}

/// Sets row's criteria to column / comparison (with a fresh value field holding value when the comparison takes one).
- (void)_setRow:(NSInteger)row column:(SPPostgresFilterNode *)columnNode comparison:(SPPostgresFilterNode *)comparisonNode value:(NSString *)value
{
	NSMutableArray *criteria = [NSMutableArray arrayWithObjects:columnNode, comparisonNode, nil];
	NSMutableArray *displayValues = [NSMutableArray arrayWithObjects:[columnNode title], [comparisonNode title], nil];
	SPPostgresFilterNode *valueNode = [[comparisonNode children] firstObject];
	if (valueNode) {
		NSTextField *field = [self _newValueField];
		[field setStringValue:value ?: @""];
		[criteria addObject:valueNode];
		[displayValues addObject:field];
	}
	[ruleEditor setCriteria:criteria andDisplayValues:displayValues forRowAtIndex:row];
}

- (void)addRowAfter:(NSInteger)row column:(NSString *)column comparison:(NSString *)comparison value:(NSString *)value
{
	if (![columnNodes count]) return;
	NSInteger count = [ruleEditor numberOfRows];
	NSInteger after = (row < 0 || row >= count) ? count - 1 : row;

	if (!column && row >= 0 && row < count) column = [[self typedFilters][(NSUInteger)row] column];
	SPPostgresFilterNode *columnNode = [self _columnNodeNamed:column ?: @""] ?: [columnNodes firstObject];
	SPPostgresFilterNode *comparisonNode = [self _child:comparison ?: @"=" of:columnNode];
	if (!comparisonNode) return;

	programmaticChange++;
	[ruleEditor insertRowAtIndex:after + 1 withType:NSRuleEditorRowTypeSimple asSubrowOfRow:-1 animate:NO];
	[self _setRow:after + 1 column:columnNode comparison:comparisonNode value:value];
	programmaticChange--;
	[self _rowsChanged];
}

- (void)removeAllRows
{
	if (![ruleEditor numberOfRows]) return;
	programmaticChange++;
	[ruleEditor removeRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)[ruleEditor numberOfRows])] includeSubrows:YES];
	programmaticChange--;
	[self _rowsChanged];
}

- (void)setFilters:(NSArray<SPPostgresFilter *> *)filters
{
	[self removeAllRows];
	for (SPPostgresFilter *filter in filters) {
		SPPostgresFilterNode *columnNode = [self _columnNodeNamed:[filter column] ?: @""];
		if (!columnNode || ![self _child:[filter comparison] ?: @"" of:columnNode]) continue;
		[self addRowAfter:-1 column:[filter column] comparison:[filter comparison] value:[filter value]];
	}
}

- (NSArray<SPPostgresFilter *> *)typedFilters
{
	NSMutableArray *filters = [NSMutableArray array];
	for (NSInteger row = 0; row < [ruleEditor numberOfRows]; row++) {
		NSArray *criteria = [ruleEditor criteriaForRow:row];
		if ([criteria count] < 2) continue;
		NSTextField *field = [self valueFieldInRow:(NSUInteger)row];
		[filters addObject:[SPPostgresFilter filterWithColumn:[(SPPostgresFilterNode *)criteria[0] title]
												   comparison:[(SPPostgresFilterNode *)criteria[1] title]
														value:field ? [field stringValue] : @""]];
	}
	return filters;
}

- (NSArray<SPPostgresFilter *> *)completeFilters
{
	NSMutableArray *filters = [NSMutableArray array];
	for (SPPostgresFilter *filter in [self typedFilters]) {
		if (![[self class] comparisonTakesValue:[filter comparison]] || [[filter value] length]) [filters addObject:filter];
	}
	return filters;
}

- (NSTextField *)valueFieldInRow:(NSUInteger)row
{
	if ((NSInteger)row >= [ruleEditor numberOfRows]) return nil;
	id last = [[ruleEditor displayValuesForRow:(NSInteger)row] lastObject];
	return [last isKindOfClass:[NSTextField class]] ? last : nil;
}

- (void)focusValueInRow:(NSUInteger)row
{
	NSTextField *field = [self valueFieldInRow:row];
	if (field && [field window]) [[field window] makeFirstResponder:field];
}

/// The row count changed (by this class or the rows' own − and +): resize, and report.
- (void)_rowsChanged
{
	NSUInteger count = (NSUInteger)[ruleEditor numberOfRows];
	[self _updateEnabled];
	if (count == rowCount) return;
	NSUInteger previous = rowCount;
	rowCount = count;
	[self _sizeRuleEditor];
	if (onHeightChanged) onHeightChanged();
	if (!count && previous && !programmaticChange && onLastRowRemoved) onLastRowRemoved();
}

- (void)invalidate
{
	[onApply release];
	onApply = nil;
	[onReset release];
	onReset = nil;
	[onLastRowRemoved release];
	onLastRowRemoved = nil;
	[onHeightChanged release];
	onHeightChanged = nil;
	for (NSButton *button in @[resetButton, addFilterButton, filterButton]) [button setTarget:nil];
	for (NSInteger row = 0; row < [ruleEditor numberOfRows]; row++) {
		NSTextField *field = [self valueFieldInRow:(NSUInteger)row];
		[field setTarget:nil];
		[field setDelegate:nil];
	}
	[ruleEditor setDelegate:nil];
	invalidated = YES;
}

#pragma mark - Actions

- (NSTextField *)_newValueField
{
	if (invalidated) return nil;
	NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 400, 19)] autorelease];
	[[field cell] setControlSize:NSControlSizeSmall];
	[[field cell] setScrollable:YES];
	[[field cell] setUsesSingleLineMode:YES];
	[field setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[field cell] setPlaceholderString:NSLocalizedString(@"Value", @"Postgres content: filter value placeholder")];
	[field setToolTip:NSLocalizedString(@"Enter the value to apply the filter condition with.\nPress ↩ to apply the filter.", @"Postgres content: filter value tooltip")];
	// Only Return / Enter applies (see -control:textView:doCommandBySelector:): no action, so ending the edit any
	// other way (a click elsewhere, hiding the area) never applies what was typed
	[field setDelegate:self];
	return field;
}

- (void)_apply:(id)sender
{
	if (onApply) onApply();
}

/// Return or Enter in a value field applies the rows.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
	if (command != @selector(insertNewline:) && command != @selector(insertNewlineIgnoringFieldEditor:)) return NO;
	[[control window] makeFirstResponder:control]; // ends the edit, so the field holds what was typed
	[self _apply:control];
	return YES;
}

- (void)_addFilter:(id)sender
{
	[self addRowAfter:-1 column:nil comparison:nil value:nil];
	if ([ruleEditor numberOfRows]) [self focusValueInRow:(NSUInteger)[ruleEditor numberOfRows] - 1];
}

/// As MySQL's: empties the rows (only Add Filter shows then).
- (void)_reset:(id)sender
{
	[self removeAllRows];
	if (onReset) onReset();
}

#pragma mark - NSRuleEditorDelegate

- (NSInteger)ruleEditor:(NSRuleEditor *)editor numberOfChildrenForCriterion:(id)criterion withRowType:(NSRuleEditorRowType)rowType
{
	if (rowType != NSRuleEditorRowTypeSimple) return 0;
	if (!criterion) return (NSInteger)[columnNodes count];
	return (NSInteger)[[(SPPostgresFilterNode *)criterion children] count];
}

- (id)ruleEditor:(NSRuleEditor *)editor child:(NSInteger)index forCriterion:(id)criterion withRowType:(NSRuleEditorRowType)rowType
{
	NSArray *children = criterion ? [(SPPostgresFilterNode *)criterion children] : columnNodes;
	return (index >= 0 && (NSUInteger)index < [children count]) ? children[(NSUInteger)index] : nil;
}

- (id)ruleEditor:(NSRuleEditor *)editor displayValueForCriterion:(id)criterion inRow:(NSInteger)row
{
	SPPostgresFilterNode *node = criterion;
	if ([node kind] == SPPostgresFilterNodeValue) return [self _newValueField];
	return [node title];
}

- (void)ruleEditorRowsDidChange:(NSNotification *)notification
{
	[self _rowsChanged];
}

@end
