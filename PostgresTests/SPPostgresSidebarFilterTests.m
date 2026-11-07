#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/SPSplitView.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

static const NSUInteger SPSidebarFilterTestPort = 55418;

// Not in the public headers
@interface SPPostgresDocument (SPSidebarFilterTests)
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (IBAction)makeTableListFilterHaveFocus:(id)sender;
@end

/// A sidebar delegate that refuses selection changes (as the tab does when an edit can't be saved).
@interface SPSidebarRefusingTestDelegate : NSObject <SPPostgresSidebarControllerDelegate>
@property NSUInteger asked;
@end

@implementation SPSidebarRefusingTestDelegate
- (void)sidebarSelectionDidChange:(SPPostgresSidebarController *)sidebar {}
- (BOOL)sidebarShouldChangeSelection:(SPPostgresSidebarController *)sidebar { self.asked++; return NO; }
@end

/**
 * The Postgres table list's filter field and collapsible sections (TABLES, VIEWS, SEQUENCES, EXTENSIONS).
 */
@interface SPPostgresSidebarFilterTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
/// Each section header's expanded state and disclosure button state when the tab opened, before -setUp expands them
@property (strong) NSDictionary<NSString *, NSArray *> *initialSections;
@end

@implementation SPPostgresSidebarFilterTests

+ (void)setUp
{
	[super setUp];
	[SPPostgresTestServers loadFixtureNamed:@"catalog" onPort:SPSidebarFilterTestPort];
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPSidebarFilterTestPort];
	[admin execute:@"CREATE TABLE IF NOT EXISTS public.spf_alpha (id integer PRIMARY KEY)"];
	[admin execute:@"CREATE TABLE IF NOT EXISTS public.spf_beta (id integer PRIMARY KEY)"];
	[admin execute:@"CREATE SEQUENCE IF NOT EXISTS public.spf_seq"];
	[admin execute:@"CREATE OR REPLACE VIEW public.spf_alpha_v AS SELECT id FROM public.spf_alpha"];
	[admin execute:@"CREATE SCHEMA IF NOT EXISTS spf_other"];
	[admin execute:@"CREATE TABLE IF NOT EXISTS spf_other.spf_other_t (id integer PRIMARY KEY)"];
}

+ (void)tearDown
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPSidebarFilterTestPort];
	[admin execute:@"DROP VIEW IF EXISTS public.spf_alpha_v"];
	[admin execute:@"DROP TABLE IF EXISTS public.spf_alpha"];
	[admin execute:@"DROP TABLE IF EXISTS public.spf_beta"];
	[admin execute:@"DROP SEQUENCE IF EXISTS public.spf_seq"];
	[admin execute:@"DROP TABLE IF EXISTS spf_other.spf_other_t"];
	[admin execute:@"DROP SCHEMA IF EXISTS spf_other"];
	[super tearDown];
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 filter";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPSidebarFilterTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);

	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block NSError *error = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) {
		connection = theConnection;
		error = theError;
		done = YES;
	}];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection, @"%@", error);

	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	self.document.alertPresenter = ^(NSAlert *alert) {};
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.document.sidebar.selectedSchema, @"public");

	// As the tab opened, then every section expanded for the tests
	NSMutableDictionary *initial = [NSMutableDictionary dictionary];
	for (NSString *title in @[@"TABLES", @"VIEWS", @"SEQUENCES", @"EXTENSIONS"]) {
		id section = [self sectionItemNamed:title];
		NSButton *disclosure = [self disclosureOfSection:title];
		initial[title] = @[@([[self outline] isItemExpanded:section]), @([self.sidebar isSectionCollapsed:title]),
						   @(disclosure != nil ? disclosure.state : -1), @(disclosure != nil ? NSMinX(disclosure.frame) : -1),
						   @(NSMinX([[[disclosure superview] viewWithTag:3] frame]))];
		XCTAssertTrue([self.sidebar setSection:title collapsed:NO], @"%@", title);
	}
	self.initialSections = initial;
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresSidebarController *)sidebar
{
	return self.document.sidebar;
}

- (NSOutlineView *)outline
{
	return [(NSScrollView *)self.sidebar.infoSplitView.subviews.firstObject documentView];
}

/// The titles of the outline's rows, headers included, in order.
- (NSArray<NSString *> *)rowTitles
{
	NSOutlineView *outline = [self outline];
	NSMutableArray *titles = [NSMutableArray array];
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		[titles addObject:[self.sidebar outlineView:outline objectValueForTableColumn:nil byItem:[outline itemAtRow:row]]];
	}
	return titles;
}

- (id)sectionItemNamed:(NSString *)title
{
	NSOutlineView *outline = [self outline];
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		if ([self.sidebar outlineView:outline isGroupItem:item] && [[item valueForKey:@"title"] isEqualToString:title]) return item;
	}
	return nil;
}

/// The disclosure button of a section header's (shown) cell.
- (NSButton *)disclosureOfSection:(NSString *)title
{
	NSInteger row = [[self outline] rowForItem:[self sectionItemNamed:title]];
	if (row < 0) return nil;
	NSView *cell = [[self outline] viewAtColumn:0 row:row makeIfNecessary:YES];
	for (NSView *subview in cell.subviews) {
		if ([subview isKindOfClass:[NSButton class]]) return (NSButton *)subview;
	}
	return nil;
}

- (void)waitForRunner
{
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

#pragma mark - The filter field

- (void)testFilterFieldSitsBetweenSchemaBarAndList
{
	NSSearchField *field = self.sidebar.filterField;
	XCTAssertNotNil(field);
	XCTAssertEqual([field superview], [self.sidebar view]);
	XCTAssertEqualObjects([[field cell] placeholderString], @"Filter");
	XCTAssertEqualObjects(self.sidebar.filterString, @"");

	// Above the list (flipped: no; higher y is higher up), below the schema pop-up
	NSRect fieldFrame = [field frame];
	NSRect listFrame = [self.sidebar.infoSplitView frame];
	XCTAssertGreaterThanOrEqual(NSMinY(fieldFrame), NSMaxY(listFrame));
	XCTAssertLessThanOrEqual(NSMaxY(fieldFrame), NSHeight([[self.sidebar view] bounds]) - 26);
	XCTAssertTrue([field target] == self.sidebar);
	XCTAssertEqual([field action], @selector(updateFilter:));
}

- (void)testFilterListsMatchingNamesInEverySection
{
	NSArray *allTables = [self.sidebar itemTitlesInSection:@"TABLES"];
	XCTAssertTrue([allTables containsObject:@"customers"]);
	XCTAssertTrue([allTables containsObject:@"spf_alpha"]);

	// Ignoring case, anywhere in the name; every section is filtered; headers stay
	self.sidebar.filterString = @"SPF_";
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"TABLES"], (@[@"spf_alpha", @"spf_beta"]));
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"VIEWS"], @[@"spf_alpha_v"]);
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"SEQUENCES"], @[@"spf_seq"]);
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"EXTENSIONS"], @[]);
	XCTAssertEqualObjects([self rowTitles], (@[@"TABLES", @"spf_alpha", @"spf_beta", @"VIEWS", @"spf_alpha_v", @"SEQUENCES", @"spf_seq", @"EXTENSIONS"]));
	// The lists themselves are whole
	XCTAssertEqualObjects([self.sidebar itemTitlesInSection:@"TABLES"], allTables);

	self.sidebar.filterString = @"alpha";
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"TABLES"], @[@"spf_alpha"]);
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"VIEWS"], @[@"spf_alpha_v"]);

	// Typing in the field does the same
	[self.sidebar.filterField setStringValue:@"trgm"];
	[self.sidebar updateFilter:self.sidebar.filterField];
	XCTAssertEqualObjects(self.sidebar.filterString, @"trgm");
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"EXTENSIONS"], @[@"pg_trgm"]);
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"TABLES"], @[]);

	// Cleared: everything again
	self.sidebar.filterString = @"";
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"TABLES"], allTables);
	XCTAssertEqualObjects([self.sidebar.filterField stringValue], @"");
}

- (void)testFilterKeepsMatchingSelectionAndClearsHiddenOne
{
	XCTAssertTrue([self.sidebar selectTableNamed:@"spf_alpha"]);
	[self waitForRunner];

	self.sidebar.filterString = @"spf";
	XCTAssertEqualObjects(self.sidebar.selectedTableName, @"spf_alpha");
	XCTAssertEqual([self outline].selectedRowIndexes.count, 1u);

	// Hiding the selected table deselects it
	self.sidebar.filterString = @"beta";
	XCTAssertNil(self.sidebar.selectedTableName);
	XCTAssertEqual([self outline].selectedRowIndexes.count, 0u);
}

- (void)testFilterKeptAcrossReload
{
	self.sidebar.filterString = @"spf_b";
	[self.sidebar reloadKeepingSelection];
	[self waitForRunner];
	XCTAssertEqualObjects(self.sidebar.filterString, @"spf_b");
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"TABLES"], @[@"spf_beta"]);
}

- (void)testSelectingAHiddenTableClearsTheFilter
{
	self.sidebar.filterString = @"beta";
	XCTAssertTrue([self.sidebar selectTableNamed:@"spf_alpha"]);
	[self waitForRunner];
	XCTAssertEqualObjects(self.sidebar.filterString, @"");
	XCTAssertEqualObjects([self.sidebar.filterField stringValue], @"");
	XCTAssertEqualObjects(self.sidebar.selectedTableName, @"spf_alpha");

	// Several at once
	self.sidebar.filterString = @"spf_alpha";
	XCTAssertTrue(([self.sidebar selectRelationsNamed:@[@"spf_alpha", @"spf_beta"]]));
	XCTAssertEqualObjects(self.sidebar.selectedRelationNames, (@[@"spf_alpha", @"spf_beta"]));
	XCTAssertEqualObjects(self.sidebar.filterString, @"");
}

- (void)testFilterRefusedByDelegateKeepsPreviousText
{
	XCTAssertTrue([self.sidebar selectTableNamed:@"spf_alpha"]);
	[self waitForRunner];

	SPSidebarRefusingTestDelegate *refusing = [[SPSidebarRefusingTestDelegate alloc] init];
	id<SPPostgresSidebarControllerDelegate> original = self.sidebar.delegate;
	self.sidebar.delegate = refusing;

	// Keeping the selected table visible needs no asking
	self.sidebar.filterString = @"alpha";
	XCTAssertEqual(refusing.asked, 0u);
	XCTAssertEqualObjects(self.sidebar.filterString, @"alpha");

	// Hiding it is refused
	self.sidebar.filterString = @"beta";
	XCTAssertEqual(refusing.asked, 1u);
	XCTAssertEqualObjects(self.sidebar.filterString, @"alpha");
	XCTAssertEqualObjects([self.sidebar.filterField stringValue], @"alpha");
	XCTAssertEqualObjects(self.sidebar.selectedTableName, @"spf_alpha");

	self.sidebar.delegate = original;
}

- (void)testFilterTablesMenuItemFocusesTheField
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(makeTableListFilterHaveFocus:) keyEquivalent:@""];
	XCTAssertTrue([self.document validateMenuItem:item]);
	XCTAssertEqualObjects([item title], @"Filter Tables");

	[self.document makeTableListFilterHaveFocus:nil];
	NSResponder *responder = [[self.controller window] firstResponder];
	BOOL fieldHasFocus = (responder == self.sidebar.filterField) ||
		([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder delegate] == (id)self.sidebar.filterField);
	XCTAssertTrue(fieldHasFocus, @"%@", responder);
}

#pragma mark - Collapsible sections

- (void)testSectionsStartCollapsedWithDisclosureAtFront
{
	for (NSString *title in @[@"TABLES", @"VIEWS", @"SEQUENCES", @"EXTENSIONS"]) {
		NSArray *initial = self.initialSections[title];
		XCTAssertEqualObjects(initial[0], @NO, @"%@ starts collapsed", title);
		XCTAssertEqualObjects(initial[1], @YES, @"%@", title);
		XCTAssertEqualObjects(initial[2], @(NSControlStateValueOff), @"%@'s button shows collapsed", title);
		// The button is in front of the title
		XCTAssertLessThan([initial[3] doubleValue], [initial[4] doubleValue], @"%@", title);

		// The source list's hover-only Show/Hide is not used; the button is always shown
		id section = [self sectionItemNamed:title];
		XCTAssertTrue(NSIsEmptyRect([[self outline] frameOfOutlineCellAtRow:[[self outline] rowForItem:section]]), @"%@", title);
		NSButton *disclosure = [self disclosureOfSection:title];
		XCTAssertFalse(disclosure.hidden, @"%@", title);
		XCTAssertEqual(disclosure.bezelStyle, NSBezelStyleDisclosure);
		XCTAssertEqual(disclosure.state, NSControlStateValueOn, @"%@'s button shows expanded", title);
	}
}

- (void)testDisclosureButtonTogglesTheSection
{
	NSButton *disclosure = [self disclosureOfSection:@"TABLES"];
	[disclosure performClick:nil];
	XCTAssertTrue([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertFalse([[self rowTitles] containsObject:@"spf_alpha"]);
	disclosure = [self disclosureOfSection:@"TABLES"];
	XCTAssertEqual(disclosure.state, NSControlStateValueOff);

	[disclosure performClick:nil];
	XCTAssertFalse([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertTrue([[self rowTitles] containsObject:@"spf_alpha"]);
	XCTAssertEqual([self disclosureOfSection:@"TABLES"].state, NSControlStateValueOn);

	// Collapsing in code updates the button too
	XCTAssertTrue([self.sidebar setSection:@"VIEWS" collapsed:YES]);
	XCTAssertEqual([self disclosureOfSection:@"VIEWS"].state, NSControlStateValueOff);
}

- (void)testCollapseAndExpandSections
{
	XCTAssertTrue([self.sidebar setSection:@"TABLES" collapsed:YES]);
	XCTAssertTrue([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertFalse([[self outline] isItemExpanded:[self sectionItemNamed:@"TABLES"]]);
	XCTAssertFalse([[self rowTitles] containsObject:@"spf_alpha"]);
	XCTAssertTrue([[self rowTitles] containsObject:@"spf_alpha_v"]);

	// Collapsing with the header's button is remembered too
	[[self outline] collapseItem:[self sectionItemNamed:@"EXTENSIONS"]];
	XCTAssertTrue([self.sidebar isSectionCollapsed:@"EXTENSIONS"]);

	// Kept across a reload and a schema change
	[self.sidebar reloadKeepingSelection];
	[self waitForRunner];
	XCTAssertFalse([[self outline] isItemExpanded:[self sectionItemNamed:@"TABLES"]]);
	XCTAssertFalse([[self outline] isItemExpanded:[self sectionItemNamed:@"EXTENSIONS"]]);
	XCTAssertTrue([[self outline] isItemExpanded:[self sectionItemNamed:@"VIEWS"]]);

	[self.sidebar reloadSchema:@"spf_other"];
	[self waitForRunner];
	XCTAssertEqualObjects(self.sidebar.selectedSchema, @"spf_other");
	XCTAssertEqualObjects([self.sidebar itemTitlesInSection:@"TABLES"], @[@"spf_other_t"]);
	XCTAssertFalse([[self outline] isItemExpanded:[self sectionItemNamed:@"TABLES"]]);
	XCTAssertFalse([[self rowTitles] containsObject:@"spf_other_t"]);

	// Expanded again
	XCTAssertTrue([self.sidebar setSection:@"TABLES" collapsed:NO]);
	XCTAssertFalse([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertTrue([[self rowTitles] containsObject:@"spf_other_t"]);
	[[self outline] expandItem:[self sectionItemNamed:@"EXTENSIONS"]];
	XCTAssertFalse([self.sidebar isSectionCollapsed:@"EXTENSIONS"]);
}

- (void)testCollapsingTheSelectedRowsSectionDeselectsIt
{
	XCTAssertTrue([self.sidebar selectTableNamed:@"spf_alpha"]);
	[self waitForRunner];

	XCTAssertTrue([self.sidebar setSection:@"TABLES" collapsed:YES]);
	XCTAssertNil(self.sidebar.selectedTableName);
	XCTAssertEqualObjects(self.sidebar.selectedRelationNames, @[]);

	// Selecting a table of a collapsed section expands it
	XCTAssertTrue([self.sidebar selectTableNamed:@"spf_beta"]);
	[self waitForRunner];
	XCTAssertFalse([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertTrue([[self outline] isItemExpanded:[self sectionItemNamed:@"TABLES"]]);
	XCTAssertEqualObjects(self.sidebar.selectedTableName, @"spf_beta");

	// The same for a sequence
	XCTAssertTrue([self.sidebar setSection:@"SEQUENCES" collapsed:YES]);
	XCTAssertTrue([self.sidebar selectSequenceNamed:@"spf_seq"]);
	[self waitForRunner];
	XCTAssertFalse([self.sidebar isSectionCollapsed:@"SEQUENCES"]);
	XCTAssertEqualObjects(self.sidebar.selectedSequenceName, @"spf_seq");
}

- (void)testCollapseRefusedByDelegateKeepsSectionOpen
{
	XCTAssertTrue([self.sidebar selectTableNamed:@"spf_alpha"]);
	[self waitForRunner];

	SPSidebarRefusingTestDelegate *refusing = [[SPSidebarRefusingTestDelegate alloc] init];
	id<SPPostgresSidebarControllerDelegate> original = self.sidebar.delegate;
	self.sidebar.delegate = refusing;

	XCTAssertFalse([self.sidebar setSection:@"TABLES" collapsed:YES]);
	XCTAssertEqual(refusing.asked, 1u);
	XCTAssertFalse([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertEqualObjects(self.sidebar.selectedTableName, @"spf_alpha");

	// A section without the selection collapses without asking
	XCTAssertTrue([self.sidebar setSection:@"VIEWS" collapsed:YES]);
	XCTAssertEqual(refusing.asked, 1u);

	self.sidebar.delegate = original;
}

- (void)testFilterAppliesInsideCollapsedSections
{
	XCTAssertTrue([self.sidebar setSection:@"TABLES" collapsed:YES]);
	self.sidebar.filterString = @"spf";
	XCTAssertTrue([self.sidebar isSectionCollapsed:@"TABLES"]);
	XCTAssertEqualObjects([self.sidebar displayedItemTitlesInSection:@"TABLES"], (@[@"spf_alpha", @"spf_beta"]));
	XCTAssertFalse([[self rowTitles] containsObject:@"spf_alpha"]);
	XCTAssertTrue([[self rowTitles] containsObject:@"spf_alpha_v"]);
}

#pragma mark - Table sizes

/// The (shown) cell of the table or view row titled `title`.
- (NSTableCellView *)cellOfRowTitled:(NSString *)title
{
	NSOutlineView *outline = [self outline];
	for (NSInteger row = 0; row < outline.numberOfRows; row++) {
		id item = [outline itemAtRow:row];
		if (![self.sidebar outlineView:outline isGroupItem:item] && [[item valueForKey:@"title"] isEqualToString:title]) {
			return [outline viewAtColumn:0 row:row makeIfNecessary:YES];
		}
	}
	return nil;
}

- (void)testTableRowsShowTheirSizeRightAligned
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPSidebarFilterTestPort];
	NSString *expected = [[[admin execute:@"SELECT pg_size_pretty(pg_total_relation_size('public.spf_alpha'))::text AS n"] rowAsDictionary] objectForKey:@"n"];
	[admin disconnect];

	NSTableCellView *cell = [self cellOfRowTitled:@"spf_alpha"];
	XCTAssertNotNil(cell);
	[[self outline] layoutSubtreeIfNeeded]; // as when the row is drawn
	NSTextField *size = [cell viewWithTag:1];
	XCTAssertFalse([size isHidden]);
	XCTAssertNotNil(expected);
	XCTAssertEqualObjects([size stringValue], expected, @"as the table info pane's total size: shows it");
	XCTAssertEqual([size alignment], NSTextAlignmentRight);
	XCTAssertEqualWithAccuracy(NSMaxX([size frame]), NSWidth([cell bounds]) - 4, 1, @"at the trailing edge");
	XCTAssertLessThanOrEqual(NSMaxX([[cell textField] frame]), NSMinX([size frame]), @"the name ends before the size");

	NSTableCellView *view = [self cellOfRowTitled:@"spf_alpha_v"];
	XCTAssertNotNil(view);
	XCTAssertTrue([[view viewWithTag:1] isHidden], @"a view has no size");
}

@end
