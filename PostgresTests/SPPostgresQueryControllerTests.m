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

	XCTAssertEqualObjects([self columnTitles], @[@"one"]);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"one"], @"1");
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'changed'"], @0, @"the other statements did not run");

	// Cursor on the second line
	NSRange second = [self.query.editor.string rangeOfString:@"AS two"];
	[self.query.editor setSelectedRange:NSMakeRange(second.location, 0)];
	[self.query runCurrentQuery:nil];
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'changed'"], @0);

	// A selection runs the selected statements, as MySQL's Run Selection
	NSString *text = self.query.editor.string;
	[self.query.editor setSelectedRange:NSMakeRange(0, [text rangeOfString:@"two"].location + 3)];
	[self.query runCurrentQuery:nil];
	XCTAssertEqualObjects([self columnTitles], @[@"two"]);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.items WHERE name = 'changed'"], @0);
}

- (void)testErrorStopsAndReportsStatementNumber
{
	[self setSQL:@"SELECT 1; SELEC 2; SELECT 3"];
	[self.query runAllQueries:nil];

	XCTAssertTrue([self.query.statusText hasPrefix:@"Error in statement 2:"], @"%@", self.query.statusText);
	XCTAssertTrue([self.query.statusText containsString:@"syntax error"], @"the server's message: %@", self.query.statusText);
	XCTAssertFalse([self.query.statusText containsString:@"transaction is aborted"], @"not in a transaction");
	XCTAssertEqualObjects([self columnTitles], @[@"?column?"]);
	XCTAssertEqualObjects([self valueAtRow:0 column:@"?column?"], @"1", @"statement 1's result stays");

	// Statement 3 never ran: an error in statement 1 leaves the grid empty
	[self setSQL:@"SELECT 1/0; SELECT 3"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([self.query.statusText hasPrefix:@"Error in statement 1: division by zero"], @"%@", self.query.statusText);
	XCTAssertEqual([[[self grid] tableColumns] count], 0u);
	XCTAssertEqual([[self grid] numberOfRows], 0);
	XCTAssertEqual(self.alerts.count, 0u, @"errors go to the status line");
}

- (void)testAffectedRows
{
	[self setSQL:@"UPDATE content_test.composite_pk SET v = v || '!'"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"3 rows affected");
	XCTAssertEqualObjects([self serverValue:@"SELECT v FROM content_test.composite_pk WHERE a = 2"], @"v3!");
	XCTAssertEqual([[[self grid] tableColumns] count], 0u, @"no result set");

	[self setSQL:@"DELETE FROM content_test.no_pk WHERE x = 1 AND false"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"0 rows affected");

	[self setSQL:@"UPDATE content_test.items SET name = 'one' WHERE id = 1"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"1 row affected");

	// RETURNING gives rows
	[self setSQL:@"UPDATE content_test.items SET name = 'two' WHERE id IN (1, 2) RETURNING id, name"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"2 rows");
	XCTAssertEqualObjects([self columnTitles], (@[@"id", @"name"]));

	// A query with no rows still shows its columns
	[self setSQL:@"SELECT id FROM content_test.items WHERE false"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"0 rows");
	XCTAssertEqualObjects([self columnTitles], @[@"id"]);
}

- (void)testValuesShownAsPostgresTextAndNullAsPlaceholder
{
	[self setSQL:@"SELECT note, price, tags, doc, blob, ts AT TIME ZONE 'UTC' AS ts, flags FROM content_test.items WHERE id IN (1, 4) ORDER BY id"];
	[self.query runAllQueries:nil];

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
	XCTAssertEqualObjects(self.query.statusText, @"Error in statement 3: division by zero – the current transaction is aborted; ROLLBACK to continue");
	XCTAssertEqual([self.document.connection transactionStatus], PGPostgresTransactionInError);

	[self setSQL:@"ROLLBACK"];
	[self.query runAllQueries:nil];
	XCTAssertEqual([self.document.connection transactionStatus], PGPostgresTransactionIdle);
	XCTAssertEqualObjects([self serverValue:@"SELECT count(*) FROM content_test.composite_pk WHERE v = 'x'"], @0);
}

- (void)testCopyFromStdinFailsWithoutWedgingTheConnection
{
	[self setSQL:@"COPY content_test.no_pk FROM STDIN; SELECT 5 AS five"];
	[self.query runAllQueries:nil];
	XCTAssertTrue([self.query.statusText hasPrefix:@"Error in statement 1:"], @"%@", self.query.statusText);

	// The connection is usable afterwards (by Query and Content alike)
	[self setSQL:@"COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT; SELECT 5 AS five"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"1 row");
	XCTAssertEqualObjects([self valueAtRow:0 column:@"five"], @"5");
	XCTAssertNotNil([self.document.connection execute:@"SELECT 1"]);
}

- (void)testEmptyEditorRunsNothing
{
	[self setSQL:@"  -- nothing here\n"];
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects(self.query.statusText, @"");
	[self.query runCurrentQuery:nil];
	XCTAssertEqualObjects(self.query.statusText, @"");
}

- (void)testStatementsLoggedToConsole
{
	[self overridePrefs:@{@"ConsoleEnableLogging": @YES, @"ConsoleEnableInterfaceLogging": @NO, @"ConsoleEnableCustomQueryLogging": @YES, @"ConsoleEnableErrorLogging": @YES}];

	[self setSQL:@"SELECT 7171 AS a; SELECT 7272 AS b; SELEC 7373"];
	[self.query runAllQueries:nil];

	// Test-only read of the console's existing storage (no public accessor)
	id queryController = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSArray *messages = [[queryController valueForKey:@"messagesFullSet"] copy];
	NSMutableArray *found = [NSMutableArray array];
	NSUInteger lastStatementIndex = NSNotFound;
	for (NSUInteger i = 0; i < messages.count; i++) {
		NSString *text = [messages[i] valueForKey:@"message"];
		if ([text containsString:@"7171"] || [text containsString:@"7272"] || [text containsString:@"7373"]) {
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

	// Run All / Run Current with MySQL's key equivalents
	NSButton *runAll = [self buttonTitled:@"Run All" inView:[self.query view]];
	NSButton *runCurrent = [self buttonTitled:@"Run Current" inView:[self.query view]];
	XCTAssertNotNil(runAll);
	XCTAssertNotNil(runCurrent);
	XCTAssertEqualObjects([runAll keyEquivalent], @"r");
	XCTAssertEqual([runAll keyEquivalentModifierMask], NSEventModifierFlagCommand);
	XCTAssertEqualObjects([runCurrent keyEquivalent], @"r");
	XCTAssertEqual([runCurrent keyEquivalentModifierMask], NSEventModifierFlagCommand | NSEventModifierFlagShift);

	// The keys reach the view while it is in the window
	[self.document viewQuery:nil];
	[self setSQL:@"SELECT 1 AS one; SELECT 2 AS two"];
	NSEvent *(^key)(NSString *, NSEventModifierFlags) = ^NSEvent *(NSString *characters, NSEventModifierFlags flags) {
		return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
							windowNumber:[[self.controller window] windowNumber] context:nil characters:characters
			 charactersIgnoringModifiers:characters isARepeat:NO keyCode:15];
	};
	XCTAssertTrue([[[self.controller window] contentView] performKeyEquivalent:key(@"R", NSEventModifierFlagCommand | NSEventModifierFlagShift)]);
	XCTAssertEqualObjects([self columnTitles], @[@"one"], @"Run Current");
	XCTAssertTrue([[[self.controller window] contentView] performKeyEquivalent:key(@"r", NSEventModifierFlagCommand)]);
	XCTAssertEqualObjects([self columnTitles], @[@"two"], @"Run All");
	XCTAssertFalse([[self.query view] performKeyEquivalent:key(@"r", NSEventModifierFlagCommand | NSEventModifierFlagOption)], @"not ours");
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
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"items"]);
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

	// Selecting another table keeps the Query view (as MySQL), the Content view follows the selection
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"composite_pk"]);
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
	XCTAssertTrue([[self.query view] isDescendantOf:[self pane]]);
}

- (void)testEditorTextKeptAcrossDatabaseSwitch
{
	[self.document viewQuery:nil];
	[self setSQL:@"SELECT current_database()"];
	PGPostgresConnection *oldConnection = self.document.connection;

	[self.document switchToDatabase:@"pgkit_nopublic"];
	XCTAssertTrue([self spinUntil:^BOOL{ return self.document.connection != oldConnection; } timeout:20]);

	XCTAssertEqualObjects(self.query.editor.string, @"SELECT current_database()");
	XCTAssertTrue([[self.query view] isDescendantOf:[self pane]], @"still the Query view");
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPQueryTestToolbarQuery);
	[self.query runAllQueries:nil];
	XCTAssertEqualObjects([self valueAtRow:0 column:@"current_database"], @"pgkit_nopublic", @"runs on the new connection");
}

@end
