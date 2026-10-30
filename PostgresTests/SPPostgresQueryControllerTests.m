#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresConsoleLogger.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

/// The controller's test seam: called before each statement runs.
@interface SPPostgresQueryController (Testing)
- (void)setStatementWillRunHook:(void (^)(NSString *statement))hook;
@end

/// Records every value a runner's currentDescription takes.
@interface SPQueryTestDescriptionRecorder : NSObject
@property (strong) NSMutableArray *values;
@end

@implementation SPQueryTestDescriptionRecorder

- (instancetype)init
{
	if ((self = [super init])) _values = [NSMutableArray array];
	return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	id value = change[NSKeyValueChangeNewKey];
	if ([value isKindOfClass:[NSString class]]) [self.values addObject:value];
}

@end

static const NSUInteger SPQueryTestPort = 55418;
// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPQueryTestNullValueKey = @"NullValue";
static NSString * const SPQueryTestEditorFontKey = @"CustomQueryEditorFont";
static NSString * const SPQueryTestNull = @"<query-null>";
static NSString * const SPQueryTestToolbarContent = @"SwitchToTableContentToolbarItemIdentifier";
static NSString * const SPQueryTestToolbarQuery = @"SwitchToRunQueryToolbarItemIdentifier";

@interface SPPostgresQueryControllerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@end

@implementation SPPostgresQueryControllerTests

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

- (NSData *)archivedFont:(NSFont *)font
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return [NSArchiver archivedDataWithRootObject:font];
#pragma clang diagnostic pop
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	[SPPostgresTestServers loadFixtureNamed:@"content" onPort:SPQueryTestPort];

	[self overridePrefs:@{SPQueryTestNullValueKey: SPQueryTestNull,
						  SPQueryTestEditorFontKey: [self archivedFont:[NSFont fontWithName:@"Menlo" size:15]]}];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 query";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPQueryTestPort;
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

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPQueryTestPort];
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

- (SPPostgresQueryController *)query
{
	return self.document.queryController;
}

- (NSTableView *)grid
{
	return self.query.resultsView;
}

- (void)setSQL:(NSString *)sql
{
	[self.query.editor setString:sql];
	[self.query.editor setSelectedRange:NSMakeRange(0, 0)];
}

- (NSArray *)columnTitles
{
	NSMutableArray *titles = [NSMutableArray array];
	for (NSTableColumn *column in [[self grid] tableColumns]) [titles addObject:[[column headerCell] stringValue]];
	return titles;
}

- (NSTableColumn *)columnNamed:(NSString *)name
{
	for (NSTableColumn *column in [[self grid] tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:name]) return column;
	}
	XCTFail(@"No column %@ in %@", name, [self columnTitles]);
	return nil;
}

- (id)valueAtRow:(NSInteger)row column:(NSString *)name
{
	return [[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:[self columnNamed:name] row:row];
}

- (id)serverValue:(NSString *)sql
{
	PGPostgresResult *result = [self.other execute:sql];
	XCTAssertNotNil(result, @"%@", [[self.other lastError] errorPrimaryMessage]);
	return [[result rowAsArray] firstObject];
}

- (NSView *)pane
{
	return [[(NSSplitView *)[self.document databaseView] subviews] lastObject];
}

- (NSToolbarItem *)toolbarItem:(NSString *)identifier
{
	for (NSToolbarItem *item in [[self.document toolbar] items]) {
		if ([[item itemIdentifier] isEqualToString:identifier]) return item;
	}
	XCTFail(@"No toolbar item %@", identifier);
	return nil;
}

- (NSButton *)buttonTitled:(NSString *)title inView:(NSView *)view
{
	if ([view isKindOfClass:[NSButton class]] && [[(NSButton *)view title] isEqualToString:title]) return (NSButton *)view;
	for (NSView *subview in [view subviews]) {
		NSButton *found = [self buttonTitled:title inView:subview];
		if (found) return found;
	}
	return nil;
}

#pragma mark - Running

- (void)testRunAllShowsLastResult
{
	[self setSQL:@"SELECT 1; SELECT 2 AS two"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
	XCTAssertEqual([[self grid] numberOfRows], 1);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"two"], @"2");
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testRunCurrentRunsOnlyCursorStatement
{
	[self setSQL:@"SELECT 1 AS one;\nSELECT 2 AS two;\nUPDATE content_test.items SET name = 'changed'"];
	[self.query.editor setSelectedRange:NSMakeRange(3, 0)];
	[self.query runCurrentQuery:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	XCTAssertEqualObjects([self columnTitles], @[@"one"]);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"one"], @"1");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'changed'"], @0, @"the other statements did not run");

	// Cursor on the second line
	NSRange second = [self.query.editor.string rangeOfString:@"AS two"];
	[self.query.editor setSelectedRange:NSMakeRange(second.location, 0)];
	[self.query runCurrentQuery:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'changed'"], @0);

	// A selection runs the selected statements, as MySQL's Run Selection
	NSString *text = self.query.editor.string;
	[self.query.editor setSelectedRange:NSMakeRange(0, [text rangeOfString:@"two"].location + 3)];
	[self.query runCurrentQuery:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'changed'"], @0);
}

- (void)testErrorStopsAndReportsStatementNumber
{
	[self setSQL:@"SELECT 1; SELEC 2; SELECT 3"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	XCTAssertTrue([self.query.statusText hasPrefix:@"Error in statement 2:"], @"%@", self.query.statusText);
	XCTAssertTrue([self.query.statusText containsString:@"syntax error"], @"the server's message: %@", self.query.statusText);
	XCTAssertFalse([self.query.statusText containsString:@"transaction is aborted"], @"not in a transaction");
	XCTAssertEqualObjects([self columnTitles], @[@"?column?"]);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"?column?"], @"1", @"statement 1's result stays");

	// Statement 3 never ran: an error in statement 1 leaves the grid empty
	[self setSQL:@"SELECT 1/0; SELECT 3"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.query.statusText hasPrefix:@"Error in statement 1: division by zero"], @"%@", self.query.statusText);
	XCTAssertEqual([[[self grid] tableColumns] count], 0u);
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqual(self.alerts.count, 0u, @"errors go to the status line");
}

- (void)testAffectedRows
{
	[self setSQL:@"UPDATE content_test.composite_pk SET v = v || '!'"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"3 rows affected");
	XCTAssertEqualObjects([self serverValue:@"SELECT v FROM content_test.composite_pk WHERE a = 2"], @"v3!");
	XCTAssertEqual([[[self grid] tableColumns] count], 0u, @"no result set");

	[self setSQL:@"DELETE FROM content_test.no_pk WHERE x = 1 AND false"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"0 rows affected");

	[self setSQL:@"UPDATE content_test.items SET name = 'one' WHERE id = 1"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"1 row affected");

	// RETURNING gives rows
	[self setSQL:@"UPDATE content_test.items SET name = 'two' WHERE id IN (1, 2) RETURNING id, name"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"2 rows");
	XCTAssertEqualObjects([self columnTitles], (@[@"id", @"name"]));

	// A query with no rows still shows its columns
	[self setSQL:@"SELECT id FROM content_test.items WHERE false"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"0 rows");
	XCTAssertEqualObjects([self columnTitles], @[@"id"]);
}

- (void)testValuesShownAsPostgresTextAndNullAsPlaceholder
{
	[self setSQL:@"SELECT note, price, tags, doc, blob, ts AT TIME ZONE 'UTC' AS ts, flags FROM content_test.items WHERE id IN (1, 4) ORDER BY id"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	XCTAssertEqualObjects(self.query.statusText, @"2 rows");
	XCTAssertEqualObjects([self valueAtRow:0 column:@"note"], SPQueryTestNull);
	XCTAssertEqualObjects([self valueAtRow:1 column:@"price"], @"12345678901234.123456");
	XCTAssertEqualObjects([self valueAtRow:1 column:@"tags"], @"{a,\"b c\"}");
	XCTAssertEqualObjects([self valueAtRow:1 column:@"doc"], @"{\"k\": [1, 2.50, null], \"s\": \"x\\\"y\"}");
	XCTAssertEqualObjects([self valueAtRow:1 column:@"blob"], @"\\x00ff");
	XCTAssertEqualObjects([self valueAtRow:1 column:@"ts"], @"2026-10-28 10:34:56.789012");
	XCTAssertEqualObjects([self valueAtRow:1 column:@"flags"], @"t");

	// NULL in grey, as the Content view
	[[self grid] deselectAll:nil];
	NSInteger noteIndex = [[self grid] columnWithIdentifier:[[self columnNamed:@"note"] identifier]];
	NSTextFieldCell *cell = (NSTextFieldCell *)[[self grid] preparedCellAtColumn:noteIndex row:0];
	XCTAssertEqualObjects([cell stringValue], SPQueryTestNull);
	XCTAssertEqualObjects([cell textColor], [NSColor lightGrayColor]);

	// Read-only
	XCTAssertFalse([(id<NSTableViewDelegate>)[[self grid] delegate] tableView:[self grid] shouldEditTableColumn:[self columnNamed:@"note"] row:0]);
	XCTAssertTrue([[self grid] isKindOfClass:NSClassFromString(@"SPTableView")]);
}

- (void)testAbortedTransactionShownInStatus
{
	[self setSQL:@"BEGIN; UPDATE content_test.composite_pk SET v = 'x'; SELECT 1/0; SELECT 2"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"Error in statement 3: division by zero – the current transaction is aborted; ROLLBACK to continue");
	XCTAssertEqual([self.document.connection transactionStatus], PGPostgresTransactionInError);

	[self setSQL:@"ROLLBACK"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual([self.document.connection transactionStatus], PGPostgresTransactionIdle);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.composite_pk WHERE v = 'x'"], @0);
}

- (void)testCopyFromStdinFailsWithoutWedgingTheConnection
{
	[self setSQL:@"COPY content_test.no_pk FROM STDIN; SELECT 5 AS five"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.query.statusText hasPrefix:@"Error in statement 1:"], @"%@", self.query.statusText);

	// The connection is usable afterwards (by Query and Content alike)
	[self setSQL:@"COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT; SELECT 5 AS five"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
	XCTAssertEqualObjects([self valueAtRow:0 column:@"five"], @"5");
	XCTAssertNotNil([self.document.connection execute:@"SELECT 1"]);
}

- (void)testEmptyEditorRunsNothing
{
	[self setSQL:@"  -- nothing here\n"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"");
	[self.query runCurrentQuery:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"");
}

- (void)testStatusSaysWhichStatementTheRowsAreFrom
{
	[self setSQL:@"SELECT a FROM content_test.composite_pk WHERE a = 1; UPDATE content_test.composite_pk SET v = v; SELECT 9 AS nine; DELETE FROM content_test.no_pk WHERE false"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"0 rows affected – results shown from statement 3");
	XCTAssertEqualObjects([self columnTitles], @[@"nine"]);

	[self setSQL:@"SELECT 1 AS one; UPDATE content_test.composite_pk SET v = v"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"3 rows affected – results shown from statement 1");

	// Last statement is the one shown: no note
	[self setSQL:@"UPDATE content_test.composite_pk SET v = v; SELECT 1 AS one"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
}

- (void)testCopyToStdoutSaysOutputNotShown
{
	[self setSQL:@"COPY (SELECT a FROM content_test.composite_pk) TO STDOUT"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"COPY 3 – output not shown");

	// Only that statement's status says so
	[self setSQL:@"COPY (SELECT 1) TO STDOUT; UPDATE content_test.composite_pk SET v = v"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText, @"3 rows affected");
}

- (void)testErrorShowsDetailAndHint
{
	[self setSQL:@"INSERT INTO content_test.composite_pk (a, b, v) VALUES (1, 'a', 'dup')"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText,
						  @"Error in statement 1: duplicate key value violates unique constraint \"composite_pk_pkey\"\nDETAIL: Key (a, b)=(1, a) already exists.");

	[self setSQL:@"SELECT 1; SELECT content_test.no_such_function(1)"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSArray *lines = [self.query.statusText componentsSeparatedByString:@"\n"];
	XCTAssertEqual(lines.count, 2u, @"%@", self.query.statusText);
	XCTAssertTrue([lines[0] hasPrefix:@"Error in statement 2: function content_test.no_such_function(integer) does not exist"], @"%@", lines[0]);
	XCTAssertTrue([lines[1] hasPrefix:@"HINT: No function matches the given name and argument types."], @"%@", lines[1]);

	// In a transaction, the note follows the message, before DETAIL
	[self setSQL:@"BEGIN; INSERT INTO content_test.composite_pk (a, b, v) VALUES (1, 'a', 'dup')"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects(self.query.statusText,
						  @"Error in statement 2: duplicate key value violates unique constraint \"composite_pk_pkey\" – the current transaction is aborted; ROLLBACK to continue\nDETAIL: Key (a, b)=(1, a) already exists.");
	XCTAssertNotNil([self.document.connection execute:@"ROLLBACK"]);
}

- (void)testExceptionDuringRunRestoresState
{
	// The exception comes out of -runAllQueries: on an inline runner (see testExceptionInBackgroundRunRestoresState)
	self.query.taskRunner = [SPPostgresTaskRunner inlineRunnerWithConnection:self.document.connection];
	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:self.document.connection];
	XCTAssertNotNil(logger);
	XCTAssertFalse(logger.loggingCustomQueries);

	__block NSUInteger calls = 0;
	[self.query setStatementWillRunHook:^(NSString *statement) {
		if (++calls == 2) [NSException raise:NSInternalInconsistencyException format:@"forced"];
	}];
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];
	XCTAssertThrows([self.query runAllQueries:nil]);
	XCTAssertFalse(logger.loggingCustomQueries, @"interface queries are logged as such again");
	XCTAssertEqualObjects(self.query.statusText, @"1 row", @"the status of what ran");

	// Not stuck "running": the next run runs
	[self.query setStatementWillRunHook:nil];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
}

- (void)testStatementsLoggedToConsole
{
	[self overridePrefs:@{@"ConsoleEnableLogging": @YES, @"ConsoleEnableInterfaceLogging": @NO, @"ConsoleEnableCustomQueryLogging": @YES, @"ConsoleEnableErrorLogging": @YES}];

	[self setSQL:@"SELECT 7171 AS a; SELECT 7272 AS b; SELEC 7373"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// Test-only read of the console's existing storage (no public accessor)
	id queryController = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSArray *messages = [[queryController valueForKey:@"messagesFullSet"] copy];
	NSMutableArray *found = [NSMutableArray array];
	NSUInteger lastStatementIndex = NSNotFound;
	for (NSUInteger i = 0; i < messages.count; i++) {
		NSString *text = [messages[i] valueForKey:@"message"];
		// The statements themselves (another test's message may contain the digits, e.g. in a UUID)
		if ([text hasPrefix:@"SELECT 7171"] || [text hasPrefix:@"SELECT 7272"] || [text hasPrefix:@"SELEC 7373"]) {
			[found addObject:messages[i]];
			lastStatementIndex = i;
		}
	}
	XCTAssertEqual(found.count, 3u, @"every statement, the failing one too: %@", [found valueForKey:@"message"]);
	XCTAssertTrue([[found[0] valueForKey:@"message"] hasPrefix:@"SELECT 7171"]);
	XCTAssertEqualObjects([found[0] valueForKey:@"messageConnection"], @"pg18 query");
	XCTAssertEqualObjects([found[0] valueForKey:@"messageDatabase"], @"pgkit_test");
	XCTAssertFalse([[found[0] valueForKey:@"isError"] boolValue]);

	// Then the error, as MySQL logs query errors
	XCTAssertLessThan(lastStatementIndex + 1, messages.count);
	id error = messages[lastStatementIndex + 1];
	XCTAssertTrue([[error valueForKey:@"isError"] boolValue]);
	XCTAssertTrue([[error valueForKey:@"message"] containsString:@"syntax error"], @"%@", [error valueForKey:@"message"]);

	// Interface queries stay governed by the interface logging preference
	NSUInteger before = [[queryController valueForKey:@"messagesFullSet"] count];
	XCTAssertNotNil([self.document.connection execute:@"SELECT 7474"]);
	XCTAssertEqual([[queryController valueForKey:@"messagesFullSet"] count], before);
}

#pragma mark - Editor

- (void)testEditorUsesQueryEditorPreferences
{
	NSTextView *editor = self.query.editor;
	XCTAssertEqualObjects([[editor font] fontName], @"Menlo-Regular");
	XCTAssertEqual([[editor font] pointSize], 15);
	XCTAssertFalse([editor isAutomaticQuoteSubstitutionEnabled]);
	XCTAssertFalse([editor isAutomaticDashSubstitutionEnabled]);
	XCTAssertFalse([editor isAutomaticTextReplacementEnabled]);
	XCTAssertFalse([editor isAutomaticSpellingCorrectionEnabled]);
	XCTAssertTrue([editor allowsUndo]);
	XCTAssertFalse([editor isRichText]);

	XCTAssertNotNil([self buttonTitled:@"Run All" inView:[self.query view]]);
	XCTAssertNotNil([self buttonTitled:@"Run Current" inView:[self.query view]]);
}

- (NSEvent *)keyDown:(NSString *)characters flags:(NSEventModifierFlags)flags
{
	return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
						windowNumber:[[self.controller window] windowNumber] context:nil characters:characters
		 charactersIgnoringModifiers:characters isARepeat:NO keyCode:15];
}

/// Sends a key equivalent to the window's views, as AppKit does before trying the main menu.
- (BOOL)pressKey:(NSString *)characters flags:(NSEventModifierFlags)flags
{
	return [[[self.controller window] contentView] performKeyEquivalent:[self keyDown:characters flags:flags]];
}

- (NSString *)toolTipOf:(NSButton *)button
{
	return [(id<NSViewToolTipOwner>)self.query view:button stringForToolTip:0 point:NSZeroPoint userData:NULL];
}

- (void)testRunKeysFollowMySQLsPrimaryAction
{
	[self overridePrefs:@{@"QueryPrimaryControlRunsAll": @NO}];
	[self.document viewQuery:nil];
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];

	// The buttons have no key equivalents of their own: the view handles MySQL's keys
	NSButton *runAll = [self buttonTitled:@"Run All" inView:[self.query view]];
	NSButton *runCurrent = [self buttonTitled:@"Run Current" inView:[self.query view]];
	XCTAssertEqualObjects([runAll keyEquivalent], @"");
	XCTAssertEqualObjects([runCurrent keyEquivalent], @"");

	// MySQL's default (DBView.xib's run popup): ⌘R runs Current, ⌥⌘R runs All
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"], @"⌘R: Run Current");
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand | NSEventModifierFlagOption]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"], @"⌥⌘R: Run All");
	XCTAssertTrue([[self toolTipOf:runCurrent] hasSuffix:@"(⌘R)"], @"%@", [self toolTipOf:runCurrent]);
	XCTAssertTrue([[self toolTipOf:runAll] hasSuffix:@"(⌥⌘R)"], @"%@", [self toolTipOf:runAll]);

	// ⇧⌘R is MySQL's Refresh Databases menu item: not swallowed, it goes on to the main menu
	[self.query.editor setSelectedRange:NSMakeRange(0, 0)];
	[self.query runCurrentQuery:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse([self pressKey:@"R" flags:NSEventModifierFlagCommand | NSEventModifierFlagShift]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"], @"nothing ran");
	XCTAssertFalse([self pressKey:@"r" flags:NSEventModifierFlagCommand | NSEventModifierFlagControl], @"⌃⌘R (Refresh Tables) passes on too");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// The preference swaps them, read at the key press
	[self overridePrefs:@{@"QueryPrimaryControlRunsAll": @YES}];
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"], @"⌘R: Run All");
	XCTAssertTrue([self pressKey:@"r" flags:NSEventModifierFlagCommand | NSEventModifierFlagOption]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"], @"⌥⌘R: Run Current");
	XCTAssertTrue([[self toolTipOf:runAll] hasSuffix:@"(⌘R)"]);
	XCTAssertTrue([[self toolTipOf:runCurrent] hasSuffix:@"(⌥⌘R)"]);

	// Not in the window (Content showing): the keys aren't the Query view's
	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"items"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.document viewContent:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self setSQL:@"SELECT 3 AS three"];
	[self pressKey:@"r" flags:NSEventModifierFlagCommand];
	XCTAssertEqualObjects([self columnTitles], @[@"one"]);
}

- (void)testEditorFontFallsBackToMonospaced
{
	// Decoded directly: changing the preference would also reach MySQL's editors observing it
	XCTAssertEqualObjects([[SPPostgresQueryController editorFontFromPreferenceData:[self archivedFont:[NSFont fontWithName:@"Menlo" size:11]]] fontName], @"Menlo-Regular");
	for (NSData *data in @[[NSData data], [@"not a font" dataUsingEncoding:NSUTF8StringEncoding], [self archivedFont:(NSFont *)@"a string"]]) {
		NSFont *font = [SPPostgresQueryController editorFontFromPreferenceData:data];
		XCTAssertNotNil(font);
		XCTAssertTrue([font isFixedPitch], @"%@", font);
	}
	XCTAssertTrue([[SPPostgresQueryController editorFontFromPreferenceData:nil] isFixedPitch]);
}

#pragma mark - Pane

- (void)testQueryToolbarItemSwitchesPane
{
	NSToolbarItem *queryItem = [self toolbarItem:SPQueryTestToolbarQuery];
	XCTAssertTrue([self.document validateToolbarItem:queryItem], @"enabled without a table selected");
	XCTAssertEqual([queryItem target], self.document);
	XCTAssertEqual([queryItem action], @selector(viewQuery:));

	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"items"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([[self.document.contentController view] isDescendantOf:[self pane]]);
	XCTAssertFalse([[self.query view] isDescendantOf:[self pane]]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPQueryTestToolbarContent);

	// Query replaces Content in the right pane
	[self.document viewQuery:queryItem];
	XCTAssertTrue([[self.query view] isDescendantOf:[self pane]]);
	XCTAssertFalse([[self.document.contentController view] isDescendantOf:[self pane]]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPQueryTestToolbarQuery);
	XCTAssertTrue(NSEqualRects([[self.query view] frame], [[self pane] bounds]));

	[self setSQL:@"SELECT 42 AS answer"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	// Selecting another table keeps the Query view (as MySQL), the Content view follows the selection
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"composite_pk"]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([[self.query view] isDescendantOf:[self pane]]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPQueryTestToolbarQuery);
	XCTAssertEqualObjects(self.document.contentController.table, @"composite_pk");

	// Back to Content: its rows are there; back to Query: the text and results are kept
	[self.document viewContent:[self toolbarItem:SPQueryTestToolbarContent]];
	XCTAssertTrue([[self.document.contentController view] isDescendantOf:[self pane]]);
	XCTAssertFalse([[self.query view] isDescendantOf:[self pane]]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPQueryTestToolbarContent);
	XCTAssertEqual([[self.document.contentController tableView] numberOfRows], 3);

	[self.document viewQuery:nil];
	XCTAssertEqualObjects(self.query.editor.string, @"SELECT 42 AS answer");
	XCTAssertEqualObjects([self valueAtRow:0 column:@"answer"], @"42");
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
}

- (void)testQueryMenuItemsValidatedThroughWindow
{
	NSMenuItem *viewQuery = [[NSMenuItem alloc] initWithTitle:@"Custom Query" action:@selector(viewQuery:) keyEquivalent:@"6"];
	XCTAssertTrue([self.document validateMenuItem:viewQuery]);
	XCTAssertTrue([(id<NSMenuItemValidation>)self.controller validateMenuItem:viewQuery]);
	XCTAssertTrue([self.controller respondsToSelector:@selector(viewQuery:)]);
	[NSApp sendAction:@selector(viewQuery:) to:self.controller from:viewQuery];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([[self.query view] isDescendantOf:[self pane]]);
}

- (void)testEditorTextKeptAcrossDatabaseSwitch
{
	[self.document viewQuery:nil];
	[self setSQL:@"SELECT current_database()"];
	PGPostgresConnection *oldConnection = self.document.connection;

	[self.document switchToDatabase:@"pgkit_nopublic"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.connection != oldConnection; } timeout:20]);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);

	XCTAssertEqualObjects(self.query.editor.string, @"SELECT current_database()");
	XCTAssertTrue([[self.query view] isDescendantOf:[self pane]], @"still the Query view");
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPQueryTestToolbarQuery);
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"current_database"], @"pgkit_nopublic", @"runs on the new connection");
}

#pragma mark - Refreshing the tab after a run

/// The Content grid's ids, in grid order.
- (NSArray *)contentIds
{
	NSTableView *grid = self.document.contentController.tableView;
	NSTableColumn *idColumn = nil;
	for (NSTableColumn *column in [grid tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:@"id"]) idColumn = column;
	}
	XCTAssertNotNil(idColumn);
	NSMutableArray *ids = [NSMutableArray array];
	for (NSInteger row = 0; row < [grid numberOfRows]; row++) {
		[ids addObject:[[grid dataSource] tableView:grid objectValueForTableColumn:idColumn row:row]];
	}
	return ids;
}

- (NSArray *)contentColumnTitles
{
	NSMutableArray *titles = [NSMutableArray array];
	for (NSTableColumn *column in [self.document.contentController.tableView tableColumns]) [titles addObject:[[column headerCell] stringValue]];
	return titles;
}

/// content_test.<table> selected in the sidebar, then the Query view.
- (void)selectTableThenQuery:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"content_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	[self.document viewQuery:nil];
}

- (void)run:(NSString *)sql
{
	[self setSQL:sql];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertFalse([self.query.statusText hasPrefix:@"Error"], @"%@", self.query.statusText);
}

- (void)testStatementKinds
{
	Class query = [SPPostgresQueryController class];
	for (NSString *sql in @[@"CREATE TABLE t (a int)", @"  alter table t add b int", @"DROP VIEW v", @"rename x",
							@"-- note\nCREATE SCHEMA s", @"/* a /* nested */ b */ drop table t", @"ROLLBACK", @"rollback to savepoint a",
							@"ABORT", @"IMPORT FOREIGN SCHEMA s FROM SERVER f INTO public"]) {
		XCTAssertTrue([query statementMayChangeSchema:sql], @"%@", sql);
	}
	for (NSString *sql in @[@"SELECT 1", @"INSERT INTO t VALUES (1)", @"COMMENT ON TABLE t IS 'x'", @"createx", @"-- CREATE", @"/* unterminated CREATE"]) {
		XCTAssertFalse([query statementMayChangeSchema:sql], @"%@", sql);
	}
	for (NSString *sql in @[@"UPDATE t SET a = 1", @"WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", @"TRUNCATE t", @"rollback", @"/* x */ insert into t default values"]) {
		XCTAssertTrue([query statementMayChangeData:sql], @"%@", sql);
	}
	for (NSString *sql in @[@"SELECT * FROM t", @" -- c\n select 1", @"SHOW search_path", @"EXPLAIN SELECT 1", @"VALUES (1)", @"TABLE t", @""]) {
		XCTAssertFalse([query statementMayChangeData:sql], @"%@", sql);
	}
}

- (void)testCreateTableInQueryAppearsInSidebar
{
	[self selectTableThenQuery:@"items"];
	[self run:@"CREATE TABLE content_test.made_in_query (id int PRIMARY KEY)"];

	XCTAssertTrue([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"made_in_query"], @"%@", [self.document.sidebar itemTitlesInSection:@"TABLES"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedSchema, @"content_test");
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"items", @"the selection is kept");
	XCTAssertEqualObjects([self.document toolbar].selectedItemIdentifier, SPQueryTestToolbarQuery, @"the Query view stays");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);

	// A schema made in the Query view is listed too (leading comments don't hide the statement)
	[self run:@"-- a new schema\n/* block */ create schema content_test_made"];
	PGPostgresConnection *cleanup = [SPPostgresTestServers connectedConnectionOnPort:SPQueryTestPort];
	[self addTeardownBlock:^{
		[cleanup execute:@"DROP SCHEMA IF EXISTS content_test_made CASCADE"];
		[cleanup disconnect];
	}];
	NSPopUpButton *schemaPopup = nil;
	NSMutableArray *views = [NSMutableArray arrayWithObject:[self.document.sidebar view]];
	while (views.count && !schemaPopup) {
		NSView *view = views.lastObject; [views removeLastObject];
		// Not the table list bar's gear pop-up
		if ([view isKindOfClass:[NSPopUpButton class]] && view != (NSView *)self.document.sidebar.gearButton) schemaPopup = (NSPopUpButton *)view;
		[views addObjectsFromArray:view.subviews];
	}
	XCTAssertTrue([[schemaPopup itemTitles] containsObject:@"content_test_made"], @"%@", [schemaPopup itemTitles]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"items");
}

- (void)testDropOfSelectedTableClearsContent
{
	XCTAssertNotNil([self.other execute:@"CREATE TABLE content_test.doomed (id int PRIMARY KEY)"]);
	XCTAssertNotNil([self.other execute:@"INSERT INTO content_test.doomed VALUES (1)"]);
	[self selectTableThenQuery:@"doomed"];
	XCTAssertEqualObjects(self.document.contentController.table, @"doomed");

	[self run:@"DROP TABLE content_test.doomed"];
	XCTAssertFalse([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"doomed"]);
	XCTAssertNil(self.document.sidebar.selectedTableName);
	XCTAssertNil(self.document.contentController.table, @"the Content view no longer shows the dropped table");
	XCTAssertEqual([self.document.contentController.tableView numberOfRows], 0);

	[self.document viewContent:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

- (void)testDataChangedInQueryIsReloadedInContent
{
	[self selectTableThenQuery:@"items"];
	XCTAssertTrue([[self contentIds] containsObject:@"5"]);

	// The key itself changes: an edit through the old row would match nothing ("changed by someone else")
	[self run:@"UPDATE content_test.items SET id = 105 WHERE id = 5"];
	[self.document viewContent:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSArray *ids = [self contentIds];
	XCTAssertFalse([ids containsObject:@"5"], @"Content shows the rows as they are now");
	NSUInteger row = [ids indexOfObject:@"105"];
	XCTAssertNotEqual(row, NSNotFound);

	NSTableView *grid = self.document.contentController.tableView;
	NSTableColumn *nameColumn = nil;
	for (NSTableColumn *column in [grid tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:@"name"]) nameColumn = column;
	}
	[(id<NSTableViewDataSource>)[grid dataSource] tableView:grid setObjectValue:@"edited after query" forTableColumn:nameColumn row:(NSInteger)row];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
	XCTAssertEqualObjects([self serverValue:@"SELECT name FROM content_test.items WHERE id = 105"], @"edited after query");
}

- (void)testAlteredTableShowsNewColumnsInContent
{
	[self selectTableThenQuery:@"items"];
	[self run:@"ALTER TABLE content_test.items ADD COLUMN added_in_query text"];
	[self.document viewContent:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([[self contentColumnTitles] containsObject:@"added_in_query"], @"%@", [self contentColumnTitles]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"items");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

- (void)testDDLInAbortedTransactionWaitsForItsEnd
{
	[self selectTableThenQuery:@"items"];
	[self setSQL:@"BEGIN; CREATE TABLE content_test.in_aborted (a int); SELECT 1/0"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertTrue([self.query.statusText hasPrefix:@"Error"], @"%@", self.query.statusText);
	XCTAssertEqual(self.alerts.count, 0u, @"no catalog reload inside the aborted transaction: %@", [self.alerts.firstObject informativeText]);
	XCTAssertEqual([self.document.connection transactionStatus], PGPostgresTransactionInError);

	[self run:@"ROLLBACK"];
	XCTAssertFalse([[self.document.sidebar itemTitlesInSection:@"TABLES"] containsObject:@"in_aborted"]);
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"items");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts.firstObject informativeText]);
}

#pragma mark - Running in the background

/// The Query controller on a background runner of its own on the tab's connection. Each test waits for it to be idle
/// before using the connection on the main thread; side SQL goes through self.other.
- (SPPostgresTaskRunner *)useBackgroundRunner
{
	SPPostgresTaskRunner *runner = [[SPPostgresTaskRunner alloc] initWithConnection:self.document.connection];
	self.query.taskRunner = runner;
	[self addTeardownBlock:^{
		[runner cancelAll];
		[SPPostgresTestServers waitForRunner:runner timeout:10];
		[runner invalidateWithCompletion:nil];
	}];
	return runner;
}

- (void)testRunAllInBackgroundShowsLastResult
{
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:self.document.connection];

	[self setSQL:@"SELECT 1; SELECT 2 AS b"];
	[self.query runAllQueries:nil];
	XCTAssertTrue(runner.isBusy, @"the run is on the runner's thread");
	XCTAssertEqualObjects(runner.currentCancelTitle, @"Stop queries");

	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertEqualObjects([self columnTitles], @[@"b"]);
	XCTAssertEqual([[self grid] numberOfRows], 1);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"b"], @"2");
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
	XCTAssertFalse(logger.loggingCustomQueries, @"restored after the run");
	XCTAssertEqual(self.alerts.count, 0u);

	// The next run runs
	[self setSQL:@"SELECT 3 AS c"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(runner.currentCancelTitle, @"Stop query");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertEqualObjects([self columnTitles], @[@"c"]);
}

- (void)testCancelLongStatementShowsQueryCancelled
{
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:self.document.connection];

	[self setSQL:@"SELECT 5 AS before; SELECT pg_sleep(30)"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [runner.currentDescription isEqualToString:@"Running query 2 of 2..."]; } timeout:10], @"%@", runner.currentDescription);
	XCTAssertTrue(runner.isBusy);
	[runner cancelAll];

	NSDate *start = [NSDate date];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self.query.statusText isEqualToString:@"Query cancelled."]; } timeout:5], @"%@", self.query.statusText);
	XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 5.0);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:5]);
	XCTAssertEqualObjects(self.query.statusText, @"Query cancelled.");
	XCTAssertEqual(self.alerts.count, 0u, @"a cancel shows no alert");
	XCTAssertNil([self.controller window].attachedSheet);
	XCTAssertFalse(logger.loggingCustomQueries, @"restored after a cancel");
	XCTAssertEqualObjects([self columnTitles], @[@"before"], @"the last row set returned before the cancel");

	// The connection is usable and the next run runs
	[self setSQL:@"SELECT 6 AS after"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"after"], @"6");
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
}

- (void)testStatementsBeforeCancelStillReportChanges
{
	[self addTeardownBlock:^{
		PGPostgresConnection *cleanup = [SPPostgresTestServers connectedConnectionOnPort:SPQueryTestPort];
		[cleanup execute:@"DROP TABLE IF EXISTS sp_t8_x"];
		[cleanup disconnect];
	}];
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	__block NSUInteger calls = 0;
	__block BOOL schema = NO;
	self.query.runDidChangeDatabase = ^(BOOL schemaChanged, BOOL dataChanged) {
		calls++;
		schema = schemaChanged;
	};

	[self setSQL:@"CREATE TABLE sp_t8_x(a int); SELECT pg_sleep(30)"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [runner.currentDescription isEqualToString:@"Running query 2 of 2..."]; } timeout:10], @"%@", runner.currentDescription);
	[self spinUntil:^BOOL{ return NO; } timeout:0.3];
	[runner cancelAll];

	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:5]);
	XCTAssertEqualObjects(self.query.statusText, @"Query cancelled.");
	XCTAssertEqual(calls, 1u, @"the CREATE before the cancel is reported");
	XCTAssertTrue(schema);
	XCTAssertEqual(self.alerts.count, 0u);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM pg_tables WHERE tablename = 'sp_t8_x'"], @1);
}

- (void)testDescriptionCountsStatements
{
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	SPQueryTestDescriptionRecorder *recorder = [[SPQueryTestDescriptionRecorder alloc] init];
	[runner addObserver:recorder forKeyPath:@"currentDescription" options:NSKeyValueObservingOptionNew context:NULL];

	[self setSQL:@"SELECT 1; SELECT 2"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);

	[self setSQL:@"SELECT 3"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	[runner removeObserver:recorder forKeyPath:@"currentDescription"];

	XCTAssertTrue([recorder.values containsObject:@"Running query 1 of 2..."], @"%@", recorder.values);
	XCTAssertTrue([recorder.values containsObject:@"Running query 2 of 2..."], @"%@", recorder.values);
	XCTAssertTrue([recorder.values containsObject:@"Running query..."], @"%@", recorder.values);
	XCTAssertFalse([recorder.values containsObject:@"Running query 1 of 1..."], @"%@", recorder.values);
}

- (void)testRunRefusedWhileBusy
{
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	[runner runTaskWithDescription:@"busy" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		return [connection execute:@"SELECT pg_sleep(1)"];
	} completion:nil];
	XCTAssertTrue(runner.isBusy);

	[self setSQL:@"SELECT 2 AS b"];
	[self.query runAllQueries:nil];
	[self.query runCurrentQuery:nil];
	XCTAssertEqualObjects(runner.currentDescription, @"busy", @"nothing else queued");

	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	[self spinUntil:^BOOL{ return NO; } timeout:0.2];
	XCTAssertEqualObjects(self.query.statusText, @"", @"neither run happened");
	XCTAssertEqual([[[self grid] tableColumns] count], 0u);
}

- (void)testExceptionInBackgroundRunRestoresState
{
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:self.document.connection];
	__block NSUInteger calls = 0;
	[self.query setStatementWillRunHook:^(NSString *statement) {
		XCTAssertFalse([NSThread isMainThread], @"the hook runs on the runner's thread");
		if (++calls == 2) [NSException raise:NSInternalInconsistencyException format:@"forced"];
	}];
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertFalse(logger.loggingCustomQueries);
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
	XCTAssertEqualObjects([self columnTitles], @[@"one"]);

	[self.query setStatementWillRunHook:nil];
	[self.query runAllQueries:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
}

- (void)testNextQueuedTaskIsNotLoggedAsCustomQuery
{
	[self overridePrefs:@{@"ConsoleEnableLogging": @YES, @"ConsoleEnableInterfaceLogging": @NO, @"ConsoleEnableCustomQueryLogging": @YES, @"ConsoleEnableErrorLogging": @YES}];
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:self.document.connection];
	XCTAssertFalse(logger.loggingCustomQueries);

	// The run's work, then at once (on the same worker, before the run's completion reaches the main thread) an
	// interface task of the tab
	[self setSQL:@"SELECT 8181 AS a"];
	[self.query runAllQueries:nil];
	__block BOOL flagInNextTask = YES;
	[runner runTaskWithDescription:@"interface" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		flagInNextTask = logger.loggingCustomQueries;
		return [connection execute:@"SELECT 8282"];
	} completion:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	[self spinUntil:^BOOL{ return NO; } timeout:0.2]; // the console is updated from later main-thread turns

	XCTAssertFalse(flagInNextTask, @"the flag covers only the run's own statements");
	XCTAssertFalse(logger.loggingCustomQueries);
	XCTAssertEqualObjects(self.query.statusText, @"1 row");

	// Test-only read of the console's existing storage (no public accessor)
	id console = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	BOOL sawRun = NO, sawInterface = NO;
	for (id message in [[console valueForKey:@"messagesFullSet"] copy]) {
		NSString *text = [message valueForKey:@"message"];
		if ([text containsString:@"8181"]) sawRun = YES;
		if ([text containsString:@"8282"]) sawInterface = YES;
	}
	XCTAssertTrue(sawRun, @"the run's statement is logged as a custom query");
	XCTAssertFalse(sawInterface, @"the next task's query is an interface query (interface logging is off)");
}

- (void)testLateCancelKeepsTheRunsStatus
{
	SPPostgresTaskRunner *runner = [self useBackgroundRunner];
	__block NSUInteger calls = 0;
	self.query.runDidChangeDatabase = ^(BOOL schemaChanged, BOOL dataChanged) { calls++; };
	[self addTeardownBlock:^{
		PGPostgresConnection *cleanup = [SPPostgresTestServers connectedConnectionOnPort:SPQueryTestPort];
		[cleanup execute:@"DROP TABLE IF EXISTS sp_t8_late"];
		[cleanup disconnect];
	}];

	// Every statement has run; the cancel comes before the completion is delivered
	[self setSQL:@"CREATE TABLE sp_t8_late(a int); SELECT 4 AS d"];
	[self.query runAllQueries:nil];
	__block BOOL workDone = NO;
	[runner runTaskWithDescription:@"marker" cancelTitle:nil work:^id(PGPostgresConnection *connection, NSError **error) {
		workDone = YES;
		return nil;
	} completion:nil];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while (!workDone && [deadline timeIntervalSinceNow] > 0) usleep(1000); // main thread blocked: no completion yet
	XCTAssertTrue(workDone);
	[runner cancelAll];

	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
	XCTAssertEqualObjects(self.query.statusText, @"1 row", @"everything ran: not \"Query cancelled.\"");
	XCTAssertEqualObjects([self columnTitles], @[@"d"]);
	XCTAssertEqual(calls, 1u);
	XCTAssertEqual(self.alerts.count, 0u);
}

@end
