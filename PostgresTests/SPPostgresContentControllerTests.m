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
#import "../Source/Postgres/SPPostgresTaskRunner.h"

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

	// The filter bar hidden (its default): the filters are applied without it being shown; edit mode off (cells are
	// edited in place, never in the field editor sheet), whatever the saved preferences say
	[self overridePrefs:@{SPLimitResults: @YES, SPLimitResultsValue: @1000, SPNullValue: SPContentTestNull, @"RuleFilterEditorLastVisibilityChoice": @NO, @"EditInSheetEnabled": @NO}];
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
	// The first loads run on the tab's runner
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPContentTestPort];

	// A view whose every row takes 50 ms to read (200 rows: 10 s), for loads to be cancelled in the middle (::text: a
	// view column can't be void)
	XCTAssertNotNil([self.other execute:@"CREATE VIEW content_test.sp_t8_slow AS SELECT g, pg_sleep(0.05)::text AS s FROM generate_series(1,200) g"]);
}

- (void)tearDown
{
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	[self.content.taskRunner cancelAll];
	[SPPostgresTestServers waitForRunner:self.content.taskRunner timeout:30];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[self.other execute:@"DROP VIEW IF EXISTS content_test.sp_t8_slow"];
	[self.other disconnect];
	self.other = nil;
	self.alerts = nil;
	[super tearDown];
}

#pragma mark - Helpers

/// Gives the Content view the tab's background runner (as the tab does). Every test using it waits for the runner before anything else uses the connection.
- (void)useTabRunner
{
	self.content.taskRunner = self.document.taskRunner;
	XCTAssertFalse(self.content.taskRunner.isInline);
}

/// Gives the Content view an inline runner on the tab's connection (a load has finished when its method returns), for
/// the tests of what happens inside a synchronous load.
- (void)useInlineRunner
{
	self.content.taskRunner = [SPPostgresTaskRunner inlineRunnerWithConnection:self.document.connection];
	XCTAssertTrue(self.content.taskRunner.isInline);
}

/// Waits until the tab's loads (Content's included) have finished.
- (void)waitForContent
{
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.content.taskRunner timeout:30]);
}

/// Queues a statement taking `seconds` on the tab's runner, ahead of whatever is asked next.
- (void)queueSleep:(double)seconds
{
	NSString *sql = [NSString stringWithFormat:@"SELECT pg_sleep(%g)", seconds];
	[self.content.taskRunner runTaskWithDescription:@"Sleeping..." cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		return [connection execute:sql];
	} completion:nil];
	XCTAssertTrue(self.content.taskRunner.isBusy);
}

/// Spins the run loop for `seconds` (the runner's completions arrive meanwhile).
- (void)spinFor:(NSTimeInterval)seconds
{
	[self spinUntil:^BOOL{ return NO; } timeout:seconds];
}

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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
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
	[self waitForContent];
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	[self waitForContent];
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"1");
	XCTAssertEqualObjects([self valueAtRow:29 column:@"id"], @"4", @"id 4 has the biggest price");
	XCTAssertEqual([[self grid] highlightedTableColumn], price);
	XCTAssertNotNil([[self grid] indicatorImageInTableColumn:price]);

	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:price];
	[self waitForContent];
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"4");
	XCTAssertEqualObjects([self valueAtRow:29 column:@"id"], @"1");

	// Another column: ascending again, and the old indicator goes
	NSTableColumn *name = [self columnNamed:@"name"];
	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:name];
	[self waitForContent];
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];

	XCTAssertEqualObjects([self idsInGrid], (@[@"1", @"10", @"11", @"12", @"13", @"14", @"15", @"16", @"17", @"18", @"19"]));
	XCTAssertEqualObjects(content.countText, @"11 rows of 30 match filter");

	// IS NULL needs no value
	[columnPopup selectItemWithTitle:@"note"];
	[comparisonPopup selectItemWithTitle:@"IS NULL"];
	[comparisonPopup sendAction:[comparisonPopup action] to:[comparisonPopup target]];
	XCTAssertFalse([valueField isEnabled]);
	[filterButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
	XCTAssertEqualObjects([self idsInGrid], (@[@"1"]));

	// A filter the server rejects: the alert is shown and the rows stay
	[columnPopup selectItemWithTitle:@"tags"];
	[comparisonPopup selectItemWithTitle:@"="];
	[comparisonPopup sendAction:[comparisonPopup action] to:[comparisonPopup target]];
	[valueField setStringValue:@"not an array"];
	[filterButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([[self.alerts[0] informativeText] containsString:@"array"], @"%@", [self.alerts[0] informativeText]);
	XCTAssertEqualObjects([self idsInGrid], (@[@"1"]));

	// An empty value clears the filter
	[columnPopup selectItemWithTitle:@"name"];
	[comparisonPopup selectItemWithTitle:@"="];
	[valueField setStringValue:@""];
	[filterButton performClick:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects(content.countText, @"30 rows in table");
}

- (void)testEditCellUpdatesServer
{
	[self selectTable:@"items"];
	XCTAssertTrue([self canEditRow:4 column:@"name"]);

	[self setValue:@"edited" atRow:4 column:@"name"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 5"], @"edited");
	XCTAssertEqualObjects([self valueAtRow:4 column:@"name"], @"edited");

	// The NULL placeholder sets NULL; Postgres's own format comes back for the edited value
	[self setValue:SPContentTestNull atRow:4 column:@"note"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT note IS NULL FROM content_test.items WHERE id = 5"], @YES);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"note"], SPContentTestNull);
	[self setValue:@"2.50" atRow:4 column:@"price"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.500000");

	// A value the server rejects: alert, and the row shows the server's value again
	[self setValue:@"not a number" atRow:4 column:@"price"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.500000");

	// The row was deleted by someone else: told so, and the grid reloaded
	XCTAssertNotNil([self.other execute:@"DELETE FROM content_test.items WHERE id = 6"]);
	[self setValue:@"too late" atRow:5 column:@"name"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 2u);
	XCTAssertEqualObjects([self.alerts[1] messageText], @"This row was changed or deleted by someone else.");
	XCTAssertEqual([[self grid] numberOfRows], 29);
	XCTAssertFalse([[self idsInGrid] containsObject:@"6"]);
}

- (void)testEditInProgressIsSavedBeforeDatabaseSwitch
{
	[self selectTable:@"items"];
	NSTableView *grid = [self grid];
	NSInteger column = [[grid tableColumns] indexOfObject:[self columnNamed:@"name"]];
	[grid editColumn:column row:4 withEvent:nil select:YES];
	NSText *editor = [grid currentEditor];
	XCTAssertNotNil(editor, @"the cell is being edited");
	[editor setString:@"saved before switch"];

	PGPostgresConnection *oldConnection = self.document.connection;
	[self.document switchToDatabase:@"postgres"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 5"], @"saved before switch");
	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.document windowTitleString] hasSuffix:@"/postgres"] && !self.document.isProcessing; } timeout:20]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertNotEqual(self.document.connection, oldConnection);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT doubled FROM content_test.generated_cols"], @6);
	XCTAssertEqual(self.alerts.count, 0u);

	[self setValue:@"5" atRow:0 column:@"a"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
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
	[self waitForContent];
	XCTAssertEqualObjects([asked messageText], @"Delete rows?");
	XCTAssertEqualObjects([asked informativeText], @"Are you sure you want to delete the selected 2 rows from this table? This action cannot be undone.");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);

	answer = YES;
	[content removeRows:nil];
	[self waitForContent];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @29);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE id IN (30, 31)"], @0);
	XCTAssertEqual([[self grid] numberOfRows], 29);

	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[content removeRows:nil];
	[self waitForContent];
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
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 2u);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"8");
	XCTAssertTrue([[content valueForKey:@"previousPageButton"] isEnabled]);

	[content nextPage:nil];
	[self waitForContent];
	[content nextPage:nil];
	[self waitForContent];
	[content nextPage:nil];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 5u);
	XCTAssertEqualObjects([self idsInGrid], (@[@"29", @"30"]));
	XCTAssertEqualObjects(content.countText, @"Rows 29 - 30 of 30 from table");
	XCTAssertFalse([[content valueForKey:@"nextPageButton"] isEnabled]);
	[content nextPage:nil];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 5u);

	[content previousPage:nil];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 4u);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"22");

	// "Limit results" off: everything on one page
	[self overridePrefs:@{SPLimitResults: @NO}];
	[content reload];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
	XCTAssertEqual(content.pageCount, 1u);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqual([[self grid] numberOfRows], 30);
}

- (void)testFailedFirstLoadEmptiesGridAndBottomBar
{
	// A view whose rows can't be read: its columns load, its count and rows fail on the server
	XCTAssertNotNil([self.other execute:@"CREATE VIEW content_test.broken_view AS SELECT g AS x FROM generate_series(1, 3) AS g WHERE 1 / (g - g) = 0"]);

	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects(content.countText, @"30 rows in table");

	XCTAssertTrue([self.document.sidebar selectTableNamed:@"broken_view"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertTrue([[self.alerts[0] informativeText] containsString:@"division by zero"], @"%@", [self.alerts[0] informativeText]);

	// Nothing of the previous table is left: no rows, no counts, nothing to add, delete or page
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqualObjects([[[self grid] tableColumns] valueForKeyPath:@"headerCell.stringValue"], (@[@"x"]));
	XCTAssertEqualObjects(content.countText, @"");
	XCTAssertEqualObjects([[content valueForKey:@"countField"] stringValue], @"");
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqual(content.pageCount, 1u);
	for (NSString *button in @[@"addButton", @"removeButton", @"previousPageButton", @"nextPageButton"]) {
		XCTAssertFalse([[content valueForKey:button] isEnabled], @"%@", button);
	}
	XCTAssertTrue([[content valueForKey:@"refreshButton"] isEnabled], @"Refresh retries");
	XCTAssertFalse([self canEditRow:0 column:@"x"]);

	// Retrying still fails the same way, and still shows the error
	[content refresh:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self waitForContent];
	XCTAssertEqual(self.alerts.count, 2u);
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqualObjects(content.countText, @"");
}

- (void)testHeaderClickSortsFromFirstPage
{
	[self overridePrefs:@{SPLimitResultsValue: @7}];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	[content nextPage:nil];
	[self waitForContent];
	[content nextPage:nil];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 3u);

	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:[self columnNamed:@"id"]];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"1");
	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:[self columnNamed:@"id"]];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"id"], @"30");
	XCTAssertEqualObjects(content.countText, @"Rows 1 - 7 of 30 from table");
}

- (void)testAddRowOnFullLastPageUpdatesPaging
{
	// 35 rows: five full pages of 7
	XCTAssertNotNil([self.other execute:@"INSERT INTO content_test.items (name) SELECT 'extra ' || g FROM generate_series(1, 5) AS g"]);
	[self overridePrefs:@{SPLimitResultsValue: @7}];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	XCTAssertEqual(content.pageCount, 5u);
	for (NSUInteger i = 0; i < 4; i++) {
		[content nextPage:nil];
		[self waitForContent];
	}
	XCTAssertEqual(content.currentPage, 5u);
	XCTAssertEqual([[self grid] numberOfRows], 7);
	XCTAssertFalse([[content valueForKey:@"nextPageButton"] isEnabled]);

	[content addRow:nil];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqual([[self grid] numberOfRows], 8, @"the new row is shown for editing");
	XCTAssertEqual(content.pageCount, 6u);
	XCTAssertEqual(content.currentPage, 5u);
	XCTAssertTrue([[content valueForKey:@"nextPageButton"] isEnabled]);
	XCTAssertTrue([[content valueForKey:@"previousPageButton"] isEnabled]);

	[content nextPage:nil];
	[self waitForContent];
	XCTAssertEqual(content.currentPage, 6u);
	XCTAssertEqualObjects([self idsInGrid], (@[@"36"]));
	XCTAssertFalse([[content valueForKey:@"nextPageButton"] isEnabled]);
}

- (void)testConfirmationCompletionMayBeStoredAndCalledLater
{
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;

	// The presenter keeps the completion (no copy of its own) and answers after the run loop has turned
	__block void (^stored)(BOOL) = nil;
	content.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) {
		stored = (__bridge void (^)(BOOL))(__bridge void *)completion; // plain pointer, not copied
	};
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	@autoreleasepool {
		[content removeRows:nil];
	}
	XCTAssertNotNil(stored);
	[self spinUntil:^BOOL{ return NO; } timeout:0.1];

	stored(YES);
	[self waitForContent];
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE id = 1"], @0);
	XCTAssertEqual([[self grid] numberOfRows], 29);

	// A second answer is ignored
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	stored(YES);
	[self waitForContent];
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @29);
	stored = nil;
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
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse([self.document validateToolbarItem:item]);
}

#pragma mark - Background loading

- (void)testShowTableLoadsInBackground
{
	[self useTabRunner];
	SPPostgresContentController *content = self.content;
	XCTAssertEqual(content.taskRunner, self.document.taskRunner, @"the tab's runner");
	XCTAssertFalse(content.taskRunner.isInline);

	[content showTable:@"items" inSchema:@"content_test"];
	XCTAssertTrue(content.taskRunner.isBusy, @"showTable: returns while the rows load");
	XCTAssertEqualObjects(content.taskRunner.currentDescription, @"Loading items...");
	XCTAssertEqualObjects(content.taskRunner.currentCancelTitle, @"Stop");
	XCTAssertEqualObjects(content.countText, @"Loading table data...");
	XCTAssertEqualObjects([[content valueForKey:@"countField"] stringValue], @"Loading table data...");
	[self waitForContent];

	// What the inline (synchronous) path shows for the same table
	SPPostgresContentController *reference = [[SPPostgresContentController alloc] initWithConnection:self.other];
	XCTAssertTrue(reference.taskRunner.isInline);
	[reference showTable:@"items" inSchema:@"content_test"];
	XCTAssertFalse(reference.taskRunner.isBusy);

	XCTAssertEqual([[self grid] numberOfRows], [reference.tableView numberOfRows]);
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects([[[self grid] tableColumns] valueForKeyPath:@"headerCell.stringValue"], [[reference.tableView tableColumns] valueForKeyPath:@"headerCell.stringValue"]);
	for (NSInteger row = 0; row < 30; row++) {
		for (NSUInteger column = 0; column < [[[self grid] tableColumns] count]; column++) {
			XCTAssertEqualObjects([[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:[[self grid] tableColumns][column] row:row],
								  [[reference.tableView dataSource] tableView:reference.tableView objectValueForTableColumn:[reference.tableView tableColumns][column] row:row]);
		}
	}
	XCTAssertEqualObjects(content.countText, reference.countText);
	XCTAssertEqualObjects(content.countText, @"30 rows in table");
	XCTAssertEqualObjects(content.noticeText, reference.noticeText);
	XCTAssertTrue([[content valueForKey:@"addButton"] isEnabled]);
	XCTAssertEqual(self.alerts.count, 0u);
	[reference invalidate];
}

- (void)testCancelDuringTableSwitchShowsColumnsWithoutRowsNoAlert
{
	[self useTabRunner];
	SPPostgresContentController *content = self.content;
	[content showTable:@"sp_t8_slow" inSchema:@"content_test"];
	XCTAssertTrue(content.taskRunner.isBusy);
	[self spinFor:0.3];
	XCTAssertTrue(content.taskRunner.isBusy, @"still counting the slow view's rows");
	[content.taskRunner cancelAll];
	[self waitForContent];

	XCTAssertEqualObjects([[[self grid] tableColumns] valueForKeyPath:@"headerCell.stringValue"], (@[@"g", @"s"]));
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqual(self.alerts.count, 0u, @"a cancelled load shows no alert");
	XCTAssertTrue([[content valueForKey:@"refreshButton"] isEnabled], @"Refresh loads it");
	XCTAssertEqualObjects(content.countText, @"");
	for (NSString *button in @[@"addButton", @"removeButton", @"previousPageButton", @"nextPageButton"]) {
		XCTAssertFalse([[content valueForKey:button] isEnabled], @"%@", button);
	}
}

- (void)testCancelDuringReloadKeepsRows
{
	[self useTabRunner];
	[self overridePrefs:@{SPLimitResultsValue: @10}];
	SPPostgresContentController *content = self.content;
	[content showTable:@"sp_t8_slow" inSchema:@"content_test"];
	[self waitForContent];
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqual(content.pageCount, 20u);
	NSArray *ids = [self idsOfSlowView];
	NSString *countText = content.countText;
	XCTAssertEqualObjects(ids, (@[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"10"]));
	XCTAssertEqualObjects(countText, @"Rows 1 - 10 of 200 from table");

	[content nextPage:nil];
	XCTAssertTrue(content.taskRunner.isBusy);
	XCTAssertEqualObjects(content.taskRunner.currentDescription, @"Loading page 2...");
	[self spinFor:0.3];
	[content.taskRunner cancelAll];
	[self waitForContent];

	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqualObjects([self idsOfSlowView], ids);
	XCTAssertEqualObjects(content.countText, countText);
	XCTAssertTrue([[content valueForKey:@"nextPageButton"] isEnabled]);
	XCTAssertEqual(self.alerts.count, 0u);
}

/// The g column of the grid (the slow view's rows).
- (NSArray *)idsOfSlowView
{
	NSMutableArray *ids = [NSMutableArray array];
	for (NSInteger row = 0; row < [[self grid] numberOfRows]; row++) [ids addObject:[self valueAtRow:row column:@"g"]];
	return ids;
}

- (void)testBackgroundLoadErrorShowsAlertAndEndsTask
{
	[self useTabRunner];
	XCTAssertNotNil([self.other execute:@"CREATE TABLE content_test.sp_t8_gone (id int PRIMARY KEY)"]);
	SPPostgresContentController *content = self.content;

	[self queueSleep:0.5];
	[content showTable:@"sp_t8_gone" inSchema:@"content_test"];
	XCTAssertNotNil([self.other execute:@"DROP TABLE content_test.sp_t8_gone"]);
	[self waitForContent];

	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self.alerts.firstObject messageText], @"Could not load the columns of “sp_t8_gone”");
	XCTAssertFalse(content.taskRunner.isBusy);
	XCTAssertFalse(self.document.isProcessing, @"the task ended");
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqualObjects(content.countText, @"");
}

- (void)testRemoveRowsRefusedWhileBusy
{
	[self useTabRunner];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	__block NSUInteger asked = 0;
	content.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) { asked++; completion(YES); };
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

	[self queueSleep:1];
	[content removeRows:nil];
	XCTAssertEqual(asked, 0u, @"not even asked while busy");
	[self waitForContent];
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @30);
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqual(self.alerts.count, 0u);
}

/// The other short writes refuse too: a cell edit (not sent, the grid keeps the server's value) and Add.
- (void)testEditAndAddRefusedWhileBusy
{
	[self useTabRunner];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;

	[self queueSleep:1];
	XCTAssertFalse([self canEditRow:4 column:@"name"], @"no edit starts while busy");
	[(id<NSTableViewDataSource>)[[self grid] dataSource] tableView:[self grid] setObjectValue:@"while busy" forTableColumn:[self columnNamed:@"name"] row:4];
	[content addRow:nil];
	XCTAssertTrue(content.taskRunner.isBusy);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"name"], @"item 5");
	[self waitForContent];

	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 5"], @"item 5");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @30);
	XCTAssertEqual([[self grid] numberOfRows], 30);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"name"], @"item 5");
	XCTAssertTrue([self canEditRow:4 column:@"name"], @"editable again once idle");
	XCTAssertEqual(self.alerts.count, 0u);
}

/// A load commits the cell being edited first, while the runner is still idle (so the edit is saved, not lost).
- (void)testLoadCommitsEditBeforeQueueing
{
	[self useTabRunner];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	NSTableView *grid = [self grid];
	NSInteger column = [[grid tableColumns] indexOfObject:[self columnNamed:@"name"]];
	[grid editColumn:column row:4 withEvent:nil select:YES];
	NSText *editor = [grid currentEditor];
	XCTAssertNotNil(editor, @"the cell is being edited");
	[editor setString:@"committed by refresh"];

	[content refresh:nil];
	XCTAssertNil([grid currentEditor]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 5"], @"committed by refresh");
	[self waitForContent];
	XCTAssertEqualObjects([self valueAtRow:4 column:@"name"], @"committed by refresh");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

- (void)testLoadDescriptions
{
	[self useTabRunner];
	[self overridePrefs:@{SPLimitResultsValue: @7}];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	SPPostgresTaskRunner *runner = content.taskRunner;

	[content reload];
	XCTAssertEqualObjects(runner.currentDescription, @"Reloading data...");
	XCTAssertEqualObjects(runner.currentCancelTitle, @"Stop");
	[self waitForContent];
	[content refresh:nil];
	XCTAssertEqualObjects(runner.currentDescription, @"Reloading data...");
	[self waitForContent];

	[[[self grid] delegate] tableView:[self grid] didClickTableColumn:[self columnNamed:@"price"]];
	XCTAssertEqualObjects(runner.currentDescription, @"Sorting table...");
	[self waitForContent];

	[content nextPage:nil];
	XCTAssertEqualObjects(runner.currentDescription, @"Loading page 2...");
	[self waitForContent];
	[content previousPage:nil];
	XCTAssertEqualObjects(runner.currentDescription, @"Loading page 1...");
	[self waitForContent];

	NSTextField *valueField = [content valueForKey:@"filterValueField"];
	[(NSPopUpButton *)[content valueForKey:@"filterColumnPopup"] selectItemWithTitle:@"name"];
	[valueField setStringValue:@"item 1"];
	[content applyFilter:nil];
	XCTAssertEqualObjects(runner.currentDescription, @"Filtering table...");
	[self waitForContent];
	XCTAssertEqualObjects([self idsInGrid], (@[@"1"]));
	XCTAssertEqual(self.alerts.count, 0u);
}

/// A newer load supersedes an older one: only the last one's rows are shown.
- (void)testNewerLoadSupersedesOlder
{
	[self useTabRunner];
	[self overridePrefs:@{SPLimitResultsValue: @7}];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;

	[content nextPage:nil];
	[content showTable:@"no_pk" inSchema:@"content_test"];
	[self waitForContent];
	XCTAssertEqualObjects(content.table, @"no_pk");
	XCTAssertEqual([[self grid] numberOfRows], 2);
	XCTAssertEqual(content.currentPage, 1u);
	XCTAssertEqualObjects(content.countText, @"2 rows in table");
	XCTAssertEqual(self.alerts.count, 0u);
}

#pragma mark - Committing a cell

/// Starts editing row's cell in the grid with text typed in (not yet committed).
- (void)typeInCellAtRow:(NSInteger)row column:(NSString *)name text:(NSString *)text
{
	NSTableView *grid = [self grid];
	[[grid window] makeFirstResponder:grid];
	[grid editColumn:[[grid tableColumns] indexOfObject:[self columnNamed:name]] row:row withEvent:nil select:YES];
	XCTAssertNotNil([grid currentEditor], @"the cell is being edited");
	[[grid currentEditor] setString:text];
}

/// What Tab does in the grid (AppKit's own Tab handling needs a key window, which tests don't have): the edit ending
/// commits the cell (the data source is told while the editor is still up), then the next cell's edit starts.
- (void)tabFromCellAtRow:(NSInteger)row column:(NSString *)name to:(NSString *)nextName
{
	NSTableView *grid = [self grid];
	XCTAssertNotNil([grid currentEditor]);
	id value = [[[grid currentEditor] string] copy];
	[(id<NSTableViewDataSource>)[grid dataSource] tableView:grid setObjectValue:value forTableColumn:[self columnNamed:name] row:row];
	[grid editColumn:[[grid tableColumns] indexOfObject:[self columnNamed:nextName]] row:row withEvent:nil select:YES];
}

/// Tab commits the cell and goes on editing the next one: the reload (inline, inside the commit) doesn't end it.
- (void)testTabToNextCellKeepsEditingAfterReload
{
	[self selectTable:@"items"];
	[self useInlineRunner];
	NSTableView *grid = [self grid];
	[self typeInCellAtRow:4 column:@"price" text:@"2.50"];

	[self tabFromCellAtRow:4 column:@"price" to:@"flags"];
	[self spinFor:0.3];

	XCTAssertEqualObjects([self serverValue:@"SELECT price::text FROM content_test.items WHERE id = 5"], @"2.500000");
	XCTAssertNotNil([grid currentEditor], @"the next cell is still being edited");
	XCTAssertEqual([grid editedRow], 4);
	XCTAssertEqual([grid editedColumn], (NSInteger)[[grid tableColumns] indexOfObject:[self columnNamed:@"flags"]]);
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.500000", @"reloaded: Postgres's own format");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

/// The same with the tab's background runner: the reload waits until the next cell's edit has ended.
- (void)testTabToNextCellKeepsEditingWithBackgroundRunner
{
	[self useTabRunner];
	[self selectTable:@"items"];
	NSTableView *grid = [self grid];
	[self typeInCellAtRow:4 column:@"price" text:@"2.50"];

	[self tabFromCellAtRow:4 column:@"price" to:@"flags"];
	[self spinFor:0.3];

	XCTAssertEqualObjects([self serverValue:@"SELECT price::text FROM content_test.items WHERE id = 5"], @"2.500000");
	XCTAssertNotNil([grid currentEditor], @"the next cell is still being edited");
	XCTAssertEqual([grid editedColumn], (NSInteger)[[grid tableColumns] indexOfObject:[self columnNamed:@"flags"]]);
	XCTAssertFalse(self.content.taskRunner.isBusy, @"no load while the next cell is edited");
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.50", @"shown as sent until the reload");

	// Ending that edit runs the pending reload
	XCTAssertTrue([[grid window] makeFirstResponder:nil]);
	XCTAssertNil([grid currentEditor]);
	[self spinFor:0.1];
	[self waitForContent];
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"2.500000");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

/// Add commits the cell being edited and reloads before adding: the cell shows Postgres's format, and after a
/// row-changed error the rows are reloaded as the alert says.
- (void)testAddRowReloadsCommittedCellFirst
{
	[self selectTable:@"items"];
	[self useInlineRunner];
	SPPostgresContentController *content = self.content;
	[self typeInCellAtRow:4 column:@"price" text:@"3.5"];
	[content addRow:nil];

	XCTAssertEqualObjects([self serverValue:@"SELECT price::text FROM content_test.items WHERE id = 5"], @"3.500000");
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"3.500000");
	XCTAssertEqual([[self grid] numberOfRows], 31);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);

	// The row was deleted meanwhile: the alert says the rows were reloaded, and they were
	[[[self grid] window] makeFirstResponder:nil];
	XCTAssertNotNil([self.other execute:@"DELETE FROM content_test.items WHERE id = 6"]);
	[self typeInCellAtRow:5 column:@"name" text:@"too late"];
	[content addRow:nil];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects([self.alerts[0] messageText], @"This row was changed or deleted by someone else.");
	XCTAssertFalse([[self idsInGrid] containsObject:@"6"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);
}

/// With the tab's background runner, + while a cell is being edited saves the cell and adds the row in one click (as
/// MySQL's and as on an inline runner); the saved cell is reloaded once the new row's edit ends.
- (void)testAddWhileEditingAddsInOneClickWithBackgroundRunner
{
	[self.controller showWindow:nil];
	[self selectTable:@"items"];
	SPPostgresContentController *content = self.content;
	XCTAssertFalse(content.taskRunner.isInline);
	[self typeInCellAtRow:4 column:@"price" text:@"3.5"];

	[content addRow:nil];
	XCTAssertEqualObjects([self serverValue:@"SELECT price::text FROM content_test.items WHERE id = 5"], @"3.500000", @"the cell is saved");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31, @"and the row added, in one click");
	XCTAssertEqual([[self grid] numberOfRows], 31);
	XCTAssertEqual([[self grid] editedRow], 30, @"the new row is being edited");
	XCTAssertFalse(content.taskRunner.isBusy, @"nothing queued while the new row is edited");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);

	// Its edit ends: the reload shows Postgres's own format
	XCTAssertTrue([[[self grid] window] makeFirstResponder:nil]);
	[self spinFor:0.1];
	[self waitForContent];
	XCTAssertEqualObjects([self valueAtRow:4 column:@"price"], @"3.500000");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items"], @31);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

@end
