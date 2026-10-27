#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresTableData.h"

static const NSUInteger SPContentTestPort = 55418;
// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPLimitResults = @"LimitResults";
static NSString * const SPLimitResultsValue = @"LimitResultsValue";
static NSString * const SPNullValue = @"NullValue";
static NSString * const SPContentTestNull = @"<null-placeholder>";
static NSString * const SPContentTestToolbarContent = @"SwitchToTableContentToolbarItemIdentifier";

/// Records the statements a connection is about to send (PostgresKit reports willExecute only to a delegate
/// passed at init).
@interface SPContentStatementRecorder : NSObject <PGPostgresConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *statements;
@end

@implementation SPContentStatementRecorder
- (instancetype)init { if ((self = [super init])) _statements = [NSMutableArray array]; return self; }
- (void)connectionEstablished:(PGPostgresConnection *)connection {}
- (void)connectionReset:(PGPostgresConnection *)connection {}
- (void)connectionDisconnected:(PGPostgresConnection *)connection {}
- (void)connection:(PGPostgresConnection *)connection notice:(NSString *)notice {}
- (void)connection:(PGPostgresConnection *)connection willExecute:(NSObject *)query withValues:(NSArray *)values
{
	@synchronized (self) { [self.statements addObject:[query description]]; }
}
/// Statements that change data.
- (NSArray *)writes
{
	NSMutableArray *writes = [NSMutableArray array];
	@synchronized (self) {
		for (NSString *statement in self.statements) {
			NSString *upper = [[statement stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
			if ([upper hasPrefix:@"UPDATE"] || [upper hasPrefix:@"INSERT"] || [upper hasPrefix:@"DELETE"]) [writes addObject:statement];
		}
	}
	return writes;
}
@end

@interface SPPostgresContentControllerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@end

@implementation SPPostgresContentControllerTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

/// Overrides preferences for this test in the volatile argument domain (never the saved preferences).
- (void)overridePrefs:(NSDictionary *)values
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	[domain addEntriesFromDictionary:values];
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	[SPPostgresTestServers loadFixtureNamed:@"content" onPort:SPContentTestPort];

	[self overridePrefs:@{SPLimitResults: @YES, SPLimitResultsValue: @1000, SPNullValue: SPContentTestNull}];
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] stringForKey:SPNullValue], SPContentTestNull);

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 content";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPContentTestPort;
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
	NSMutableArray *alerts = [NSMutableArray array];
	self.alerts = alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPContentTestPort];
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
	[self.other disconnect];
	self.other = nil;
	self.alerts = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresContentController *)content
{
	return self.document.contentController;
}

- (NSTableView *)grid
{
	return self.content.tableView;
}

/// Selects content_test.<table> in the sidebar.
- (void)selectTable:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
}

- (NSTableColumn *)columnNamed:(NSString *)name
{
	for (NSTableColumn *column in [[self grid] tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:name]) return column;
	}
	XCTFail(@"No column %@", name);
	return nil;
}

- (id)valueAtRow:(NSInteger)row column:(NSString *)name
{
	return [[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:[self columnNamed:name] row:row];
}

- (NSArray *)idsInGrid
{
	NSMutableArray *ids = [NSMutableArray array];
	for (NSInteger row = 0; row < [[self grid] numberOfRows]; row++) [ids addObject:[self valueAtRow:row column:@"id"]];
	return ids;
}

- (id)serverValue:(NSString *)sql
{
	PGPostgresResult *result = [self.other execute:sql];
	XCTAssertNotNil(result, @"%@", [[self.other lastError] errorPrimaryMessage]);
	return [[result rowAsArray] firstObject];
}

- (void)setValue:(id)value atRow:(NSInteger)row column:(NSString *)name
{
	[(id<NSTableViewDataSource>)[[self grid] dataSource] tableView:[self grid] setObjectValue:value forTableColumn:[self columnNamed:name] row:row];
}

- (BOOL)canEditRow:(NSInteger)row column:(NSString *)name
{
	return [(id<NSTableViewDelegate>)[[self grid] delegate] tableView:[self grid] shouldEditTableColumn:[self columnNamed:name] row:row];
}

- (NSToolbarItem *)contentToolbarItem
{
	for (NSToolbarItem *item in [[self.document toolbar] items]) {
		if ([[item itemIdentifier] isEqualToString:SPContentTestToolbarContent]) return item;
	}
	XCTFail(@"No Content toolbar item");
	return nil;
}

#pragma mark - Tests

- (void)testSelectingTableShowsItsRows
{
	// The right pane hosts the content view
	NSView *pane = [[(NSSplitView *)[self.document databaseView] subviews] lastObject];
	XCTAssertTrue([[self.content view] isDescendantOf:pane]);
	XCTAssertTrue([[self grid] isDescendantOf:[self.content view]]);
	XCTAssertTrue([[self grid] isKindOfClass:NSClassFromString(@"SPTableView")]);

	[self selectTable:@"items"];
	XCTAssertEqual([[self grid] numberOfRows], 30);

	NSMutableArray *titles = [NSMutableArray array];
	for (NSTableColumn *column in [[self grid] tableColumns]) [titles addObject:[[column headerCell] stringValue]];
	XCTAssertEqualObjects(titles, (@[@"id", @"name", @"note", @"price", @"flags", @"tags", @"doc", @"blob", @"ts", @"Mixed Case"]));
	XCTAssertEqualObjects([self valueAtRow:0 column:@"name"], @"item 1");
	XCTAssertEqualObjects([self valueAtRow:3 column:@"tags"], @"{a,\"b c\"}");
	XCTAssertEqualObjects(self.content.countText, @"30 rows in table");
	XCTAssertEqualObjects(self.content.noticeText, @"");
	XCTAssertEqual(self.content.currentPage, 1u);
	XCTAssertEqual(self.content.pageCount, 1u);

	// Deselecting (a schema reload clears the selection) empties the grid
	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqual([[[self grid] tableColumns] count], 0u);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testNullShownWithPlaceholder
{
	[self selectTable:@"items"];

	// id 1 has a NULL note, id 2 an empty one
	XCTAssertEqualObjects([self valueAtRow:0 column:@"note"], SPContentTestNull);
	XCTAssertEqualObjects([self valueAtRow:1 column:@"note"], @"");

	[[self grid] deselectAll:nil];
	NSInteger noteIndex = [[self grid] columnWithIdentifier:[[self columnNamed:@"note"] identifier]];
	NSTextFieldCell *nullCell = (NSTextFieldCell *)[[self grid] preparedCellAtColumn:noteIndex row:0];
	XCTAssertEqualObjects([nullCell stringValue], SPContentTestNull);
	XCTAssertEqualObjects([nullCell textColor], [NSColor lightGrayColor], @"NULL is grey");
	NSTextFieldCell *emptyCell = (NSTextFieldCell *)[[self grid] preparedCellAtColumn:noteIndex row:1];
	XCTAssertEqualObjects([emptyCell stringValue], @"");
	XCTAssertNotEqualObjects([emptyCell textColor], [NSColor lightGrayColor]);
}

- (void)testHeaderClickSorts
{
	[self selectTable:@"items"];
	NSTableColumn *price = [self columnNamed:@"price"];

	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:price];
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"1");
	XCTAssertEqualObjects([self valueAtRow:29 column:@"id"], @"4", @"id 4 has the biggest price");
	XCTAssertEqual([[self grid] highlightedTableColumn], price);
	XCTAssertNotNil([[self grid] indicatorImageInTableColumn:price]);

	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:price];
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"4");
	XCTAssertEqualObjects([self valueAtRow:29 column:@"id"], @"1");

	// Another column: ascending again, and the old indicator goes
	NSTableColumn *name = [self columnNamed:@"name"];
	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:name];
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"1");
	XCTAssertEqualObjects([self valueAtRow:1 column:@"id"], @"10");
	XCTAssertNil([[self grid] indicatorImageInTableColumn:price]);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testFilterNarrowsRows
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;

	NSPopUpButton *columnPopup = [content valueForKey:@"filterColumnPopup"];
	NSPopUpButton *comparisonPopup = [content valueForKey:@"filterComparisonPopup"];
	NSTextField *valueField = [content valueForKey:@"filterValueField"];
	NSButton *filterButton = [content valueForKey:@"filterButton"];
	XCTAssertEqualObjects([columnPopup itemTitles], ([[[self grid] tableColumns] valueForKeyPath:@"headerCell.stringValue"]));
	XCTAssertTrue([[comparisonPopup itemTitles] containsObject:@"LIKE"]);

	[columnPopup selectItemWithTitle:@"name"];
	[comparisonPopup selectItemWithTitle:@"LIKE"];
	[valueField setStringValue:@"item 1%"];
	[filterButton performClick:nil];

	XCTAssertEqualObjects([self idsInGrid], (@[@"1", @"10", @"11", @"12", @"13", @"14", @"15", @"16", @"17", @"18", @"19"]));
	XCTAssertEqualObjects(content.countText, @"11 rows of 30 match filter");

	// IS NULL needs no value
	[columnPopup selectItemWithTitle:@"note"];
	[comparisonPopup selectItemWithTitle:@"IS NULL"];
	[comparisonPopup sendAction:[comparisonPopup action] to:[comparisonPopup target]];
	XCTAssertFalse([valueField isEnabled]);
	[filterButton performClick:nil];
	XCTAssertEqualObjects([self idsInGrid], (@[@"1"]));

	// A filter the server rejects: the alert is shown and the rows stay
	[columnPopup selectItemWithTitle:@"tags"];
	[comparisonPopup selectItemWithTitle:@"="];
	[comparisonPopup sendAction:[comparisonPopup action] to:[comparisonPopup target]];
	[valueField setStringValue:@"not an array"];
	[filterButton performClick:nil];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([[self.alerts[0] informativeText] containsString:@"array"], @"%@", [self.alerts[0] informativeText]);
	XCTAssertEqualObjects([self idsInGrid], (@[@"1"]));

	// An empty value clears the filter
	[columnPopup selectItemWithTitle:@"name"];
	[comparisonPopup selectItemWithTitle:@"="];
	[valueField setStringValue:@""];
	[filterButton performClick:nil];
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects(content.countText, @"30 rows in table");
}

- (void)testEditCellUpdatesServer
{
	[self selectTable:@"items"];
	XCTAssertTrue([self canEditRow:4 column:@"name"]);

	[self setValue:@"edited" atRow:4 column:@"name"];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 5"], @"edited");
	XCTAssertEqualObjects([self valueAtRow:4 column:@"name"], @"edited");

	// The NULL placeholder sets NULL; Postgres's own format comes back for the edited value
	[self setValue:SPContentTestNull atRow:4 column:@"note"];
	XCTAssertEqualObjects([self serverValue:@"SELECT note IS NULL FROM content_test.items WHERE id = 5"], @YES);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"note"], SPContentTestNull);
	[self setValue:@"2.50" atRow:4 column:@"price"];
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.500000");

	// A value the server rejects: alert, and the row shows the server's value again
	[self setValue:@"not a number" atRow:4 column:@"price"];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.500000");

	// The row was deleted by someone else: told so, and the grid reloaded
	XCTAssertNotNil([self.other execute:@"DELETE FROM content_test.items WHERE id = 6"]);
	[self setValue:@"too late" atRow:5 column:@"name"];
	XCTAssertEqual(self.alerts.count, 2u);
	XCTAssertEqualObjects([self.alerts[1] messageText], @"This row was changed or deleted by someone else.");
	XCTAssertEqual([[self grid] numberOfRows], 29);
	XCTAssertFalse([[self idsInGrid] containsObject:@"6"]);
}

- (void)testEditOnNoPrimaryKeyIsRefused
{
	[self selectTable:@"no_pk"];
	SPPostgresContentController *content = self.content;
	SPPostgresTableData *data = [[SPPostgresTableData alloc] initWithConnection:self.other schema:@"content_test" table:@"no_pk"];
	XCTAssertNotNil([data columns:NULL]);
	XCTAssertNotNil([data readOnlyReason]);
	XCTAssertEqualObjects(content.noticeText, [data readOnlyReason]);
	XCTAssertEqualObjects([[content valueForKey:@"noticeField"] stringValue], [data readOnlyReason]);
	XCTAssertEqual([[self grid] numberOfRows], 2);

	XCTAssertFalse([self canEditRow:0 column:@"y"]);
	XCTAssertFalse([[content valueForKey:@"addButton"] isEnabled]);
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	XCTAssertFalse([[content valueForKey:@"removeButton"] isEnabled]);

	[self setValue:@"changed" atRow:0 column:@"y"];
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.no_pk WHERE y = 'same'"], @2);

	// A view is read-only too
	[self selectTable:@"items_view"];
	XCTAssertEqualObjects(content.noticeText, @"This is a view, so its rows can't be edited.");
	XCTAssertFalse([self canEditRow:0 column:@"name"]);

	// No statement that changes data is ever sent for a read-only relation
	SPContentStatementRecorder *recorder = [[SPContentStatementRecorder alloc] init];
	PGPostgresConnection *recorded = [SPPostgresTestServers connectedConnectionOnPort:SPContentTestPort database:@"pgkit_test" delegate:recorder];
	SPPostgresContentController *standalone = [[SPPostgresContentController alloc] initWithConnection:recorded];
	standalone.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) { completion(YES); };
	NSMutableArray *standaloneAlerts = [NSMutableArray array];
	standalone.alertPresenter = ^(NSAlert *alert) { [standaloneAlerts addObject:alert]; };
	[standalone showTable:@"no_pk" inSchema:@"content_test"];
	NSTableView *grid = standalone.tableView;
	XCTAssertEqual([grid numberOfRows], 2);
	[(id<NSTableViewDataSource>)[grid dataSource] tableView:grid setObjectValue:@"changed" forTableColumn:[grid tableColumns][1] row:0];
	[standalone addRow:nil];
	[grid selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[standalone removeRows:nil];
	XCTAssertEqualObjects([recorder writes], (@[]));
	XCTAssertEqual([grid numberOfRows], 2);
	[standalone invalidate];
	[recorded disconnect];
}

- (void)testGeneratedColumnsAreNotEditable
{
	XCTAssertNotNil([self.other execute:@"INSERT INTO content_test.generated_cols (a) VALUES (3)"]);
	[self selectTable:@"generated_cols"];
	XCTAssertEqual([[self grid] numberOfRows], 1);
	XCTAssertFalse([self canEditRow:0 column:@"id"]);
	XCTAssertFalse([self canEditRow:0 column:@"doubled"]);
	XCTAssertTrue([self canEditRow:0 column:@"a"]);
	XCTAssertTrue([self canEditRow:0 column:@"seq"]);

	// Even if asked, a generated column is not sent
	[self setValue:@"99" atRow:0 column:@"doubled"];
	XCTAssertEqualObjects([self serverValue:@"SELECT doubled FROM content_test.generated_cols"], @6);
	XCTAssertEqual(self.alerts.count, 0u);

	[self setValue:@"5" atRow:0 column:@"a"];
	XCTAssertEqualObjects([self serverValue:@"SELECT doubled FROM content_test.generated_cols"], @10);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"doubled"], @"10");
}

- (void)testAddAndDeleteRow
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	XCTAssertTrue([[content valueForKey:@"addButton"] isEnabled]);

	[content addRow:nil];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);
	XCTAssertEqual([[self grid] numberOfRows], 31);
	XCTAssertEqualObjects([self valueAtRow:30 column:@"id"], @"31");
	XCTAssertEqualObjects([self valueAtRow:30 column:@"name"], SPContentTestNull);
	XCTAssertEqual([[self grid] selectedRow], 30);

	// Delete asks first; cancelling deletes nothing
	__block NSAlert *asked = nil;
	__block BOOL answer = NO;
	content.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) { asked = alert; completion(answer); };
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(29, 2)] byExtendingSelection:NO];
	XCTAssertTrue([[content valueForKey:@"removeButton"] isEnabled]);
	[content removeRows:nil];
	XCTAssertEqualObjects([asked messageText], @"Delete rows?");
	XCTAssertEqualObjects([asked informativeText], @"Are you sure you want to delete the selected 2 rows from this table? This action cannot be undone.");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);

	answer = YES;
	[content removeRows:nil];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @29);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE id IN (30, 31)"], @0);
	XCTAssertEqual([[self grid] numberOfRows], 29);

	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[content removeRows:nil];
	XCTAssertEqualObjects([asked messageText], @"Delete selected row?");
	XCTAssertEqual([[self grid] numberOfRows], 28);
}

- (void)testPagingWithSmallPageSize
{
	[self overridePrefs:@{SPLimitResultsValue: @7}];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;

	XCTAssertEqual(content.pageCount, 5u);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqual([[self grid] numberOfRows], 7);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"1");
	XCTAssertEqualObjects(content.countText, @"Rows 1 - 7 of 30 from table");
	XCTAssertFalse([[content valueForKey:@"previousPageButton"] isEnabled]);
	XCTAssertTrue([[content valueForKey:@"nextPageButton"] isEnabled]);

	[content nextPage:nil];
	XCTAssertEqual(content.currentPage, 2u);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"8");
	XCTAssertTrue([[content valueForKey:@"previousPageButton"] isEnabled]);

	[content nextPage:nil];
	[content nextPage:nil];
	[content nextPage:nil];
	XCTAssertEqual(content.currentPage, 5u);
	XCTAssertEqualObjects([self idsInGrid], (@[@"29", @"30"]));
	XCTAssertEqualObjects(content.countText, @"Rows 29 - 30 of 30 from table");
	XCTAssertFalse([[content valueForKey:@"nextPageButton"] isEnabled]);
	[content nextPage:nil];
	XCTAssertEqual(content.currentPage, 5u);

	[content previousPage:nil];
	XCTAssertEqual(content.currentPage, 4u);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"22");

	// "Limit results" off: everything on one page
	[self overridePrefs:@{SPLimitResults: @NO}];
	[content reload];
	XCTAssertEqual(content.pageCount, 1u);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqual([[self grid] numberOfRows], 30);
}

- (void)testContentToolbarItemEnabledOnlyWithTableSelected
{
	NSToolbarItem *item = [self contentToolbarItem];
	XCTAssertEqual([item target], self.document);
	XCTAssertEqualObjects(NSStringFromSelector([item action]), @"viewContent:");

	XCTAssertNil([self.document.sidebar selectedTableName]);
	XCTAssertFalse([self.document validateToolbarItem:item]);

	[self selectTable:@"items"];
	XCTAssertTrue([self.document validateToolbarItem:item]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPContentTestToolbarContent);

	[self selectTable:@"items_view"];
	XCTAssertTrue([self.document validateToolbarItem:item]);

	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertFalse([self.document validateToolbarItem:item]);
}

@end
