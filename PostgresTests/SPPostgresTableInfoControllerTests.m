#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "SPTestPrefsGuard.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresStructureController.h"
#import "../Source/Postgres/SPPostgresTableInfoController.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresCreateStatement.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

static const NSUInteger SPInfoTestPort = 55418;

// MySQL's identifiers (the app's constants aren't exported to the test bundle)
static NSString * const SPInfoTestToolbarInfo = @"SwitchToTableInfoToolbarItemIdentifier";
static NSString * const SPInfoTestEditorFontKey = @"CustomQueryEditorFont";

@interface SPPostgresDocument (SPPostgresTableInfoControllerTests)
- (IBAction)backForwardInHistory:(id)sender;
- (BOOL)parentTabShouldClose;
@end

@interface SPWindowController (SPPostgresTableInfoControllerTests)
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

/// The Table Info pane of a Postgres tab hosted in a window (port 55418).
@interface SPPostgresTableInfoControllerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@end

@implementation SPPostgresTableInfoControllerTests

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
	[SPPostgresTestServers loadStructureFixtureOnPort:SPInfoTestPort];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 info";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPInfoTestPort;
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
	self.document.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL)) { completion(YES); };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPInfoTestPort];
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
	[self.other execute:@"ROLLBACK"];
	[self.other disconnect];
	self.other = nil;
	self.alerts = nil;
	[SPPostgresTestServers dropStructureFixtureOnPort:SPInfoTestPort];
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresTableInfoController *)info
{
	return self.document.infoController;
}

- (void)select:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"structure_test"];
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
}

- (void)showInfoOf:(NSString *)table
{
	[self select:table];
	[self.document viewStatus:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneInfo);
	XCTAssertEqualObjects(self.info.table, table);
}

- (id)serverValue:(NSString *)sql
{
	PGPostgresResult *result = [self.other execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, [[self.other lastError] errorPrimaryMessage]);
	return [[result rowAsArray] firstObject];
}

- (void)serverRun:(NSString *)sql
{
	XCTAssertNotNil([self.other execute:sql], @"%@: %@", sql, [[self.other lastError] errorPrimaryMessage]);
}

- (NSMenuItem *)menuItem:(SEL)action key:(NSString *)key
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSStringFromSelector(action) action:action keyEquivalent:key];
	[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	return item;
}

- (NSArray *)labelsIn:(NSView *)root
{
	NSMutableArray *labels = [NSMutableArray array];
	NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
	while (queue.count) {
		NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
		if ([v isKindOfClass:[NSTextField class]] && ![(NSTextField *)v isEditable]) [labels addObject:[(NSTextField *)v stringValue]];
		[queue addObjectsFromArray:v.subviews];
	}
	return labels;
}

- (void)runQuery:(NSString *)sql
{
	[self.document viewQuery:nil];
	[[self.document.queryController editor] setString:sql];
	[self.document.queryController runAllQueries:nil];
}

/// Types text into the comment box (replacing what is there), as the user would, with the box focused.
- (void)typeComment:(NSString *)text
{
	NSTextView *box = self.info.commentView;
	XCTAssertTrue([[box window] makeFirstResponder:box]);
	NSRange all = NSMakeRange(0, [[box string] length]);
	[box setSelectedRange:all];
	[box insertText:text replacementRange:all];
	XCTAssertEqualObjects([box string], text);
}

- (BOOL)flag:(NSString *)name
{
	return [[self.document valueForKey:name] boolValue];
}

#pragma mark - Tests

- (void)testInfoShowsOwnerSizesAndEstimate
{
	[self serverRun:@"CREATE TABLE structure_test.fresh (id int PRIMARY KEY, v text)"];
	[self serverRun:@"INSERT INTO structure_test.fresh VALUES (1, 'a'), (2, 'b')"];
	[self showInfoOf:@"fresh"];
	SPPostgresTableInfoController *info = self.info;

	NSArray *labels = [self labelsIn:[info view]];
	for (NSString *label in @[@"Type:", @"Owner:", @"Rows:", @"Table size:", @"Index size:", @"Total size:", @"Comments:", @"Create syntax:"]) {
		XCTAssertTrue([labels containsObject:label], @"%@ in %@", label, labels);
	}
	XCTAssertNotNil([[info view] window], @"in the window");
	XCTAssertEqualObjects([info.typeField stringValue], @"table");
	XCTAssertEqualObjects([info.ownerField stringValue], @"pgkit_test");
	XCTAssertEqualObjects([info.rowsField stringValue], @"Unknown (not analyzed)");
	XCTAssertEqualObjects([info.tableSizeField stringValue], [self serverValue:@"SELECT pg_size_pretty(pg_table_size('structure_test.fresh'))"]);
	XCTAssertEqualObjects([info.indexSizeField stringValue], [self serverValue:@"SELECT pg_size_pretty(pg_indexes_size('structure_test.fresh'))"]);
	XCTAssertEqualObjects([info.totalSizeField stringValue], [self serverValue:@"SELECT pg_size_pretty(pg_total_relation_size('structure_test.fresh'))"]);
	XCTAssertTrue([[info.indexSizeField stringValue] hasSuffix:@"kB"], @"%@", [info.indexSizeField stringValue]);
	XCTAssertEqualObjects(info.noticeText, @"");

	// The estimate after ANALYZE, shown when the pane is next shown
	[self serverRun:@"ANALYZE structure_test.fresh"];
	[self.document viewContent:nil];
	[self.document viewStatus:nil];
	XCTAssertEqualObjects([info.rowsField stringValue], @"~2");

	// A view
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t_view"]);
	XCTAssertEqualObjects(info.table, @"t_view");
	XCTAssertEqualObjects([info.typeField stringValue], @"view");
	XCTAssertEqualObjects([info.rowsField stringValue], @"Unknown (not analyzed)");

	// Gone elsewhere: the alert and the bottom line
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"fresh"]);
	[self serverRun:@"DROP TABLE structure_test.fresh"];
	[info reload];
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(self.alerts[0].messageText, @"Could not load the information of “fresh”");
	XCTAssertEqualObjects(info.noticeText, @"Could not load the information: There is no table “fresh” in schema “structure_test”.");
	XCTAssertFalse([info.commentView isEditable]);
	XCTAssertEqualObjects([info.typeField stringValue], @"");
}

- (void)testCommentEditPersists
{
	[self showInfoOf:@"t"];
	SPPostgresTableInfoController *info = self.info;
	NSTextView *box = info.commentView;
	XCTAssertEqualObjects([box string], @"the t table");
	XCTAssertTrue([box isEditable]);
	XCTAssertFalse(info.hasPendingComment);

	// Leaving the pane ends the edit: saved, and the Structure view goes stale
	[self typeComment:@"it's new"];
	XCTAssertTrue(info.hasPendingComment);
	[self.document viewContent:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], @"it's new");
	XCTAssertTrue([self flag:@"structureNeedsReset"]);
	XCTAssertFalse(info.hasPendingComment);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// The box losing the focus ends it too; the create syntax follows
	[self.document viewStatus:nil];
	XCTAssertEqualObjects([box string], @"it's new");
	[self typeComment:@"  second  "];
	XCTAssertTrue([[box window] makeFirstResponder:nil]);
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], @"second", @"trimmed, as MySQL's");
	XCTAssertTrue([[info.createSyntaxView string] containsString:@"COMMENT ON TABLE \"structure_test\".\"t\" IS 'second';"], @"%@", [info.createSyntaxView string]);

	// A failure (a lock held elsewhere): the alert, the text stays and the tab stays
	info.lockTimeout = 0.5;
	[self serverRun:@"BEGIN"];
	[self serverRun:@"LOCK TABLE structure_test.t IN ACCESS EXCLUSIVE MODE"];
	[self typeComment:@"locked out"];
	[self.document viewStructure:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneInfo, @"the failed edit keeps the pane");
	XCTAssertEqual(self.alerts.count, 1u);
	XCTAssertEqualObjects(self.alerts[0].messageText, @"Could not change the comment of “t”");
	XCTAssertTrue([self.alerts[0].informativeText containsString:@"lock"], @"%@", self.alerts[0].informativeText);
	XCTAssertEqualObjects([box string], @"locked out");
	XCTAssertTrue(info.hasPendingComment);
	XCTAssertEqual([[box window] firstResponder], box);
	NSOutlineView *outline = [self.document.sidebar valueForKey:@"outlineView"];
	XCTAssertFalse([(id<NSOutlineViewDelegate>)[outline delegate] selectionShouldChangeInOutlineView:outline], @"nor does the selection move");
	XCTAssertEqual(self.alerts.count, 2u);
	XCTAssertFalse([self.document parentTabShouldClose], @"nor does the tab close");
	XCTAssertEqual(self.alerts.count, 3u);
	XCTAssertEqualObjects([box string], @"locked out");

	// Once the lock is gone it saves
	[self serverRun:@"ROLLBACK"];
	[self.document viewStructure:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], @"locked out");
	XCTAssertEqual(self.alerts.count, 3u);

	// Escape puts the saved comment back; an empty comment removes it
	[self.document viewStatus:nil];
	[self typeComment:@"never mind"];
	[box doCommandBySelector:@selector(cancelOperation:)];
	XCTAssertEqualObjects([box string], @"locked out");
	XCTAssertFalse(info.hasPendingComment);
	[self typeComment:@""];
	XCTAssertTrue([info commitPendingEdits]);
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], [NSNull null]);
	XCTAssertEqual(self.alerts.count, 3u);
}

/// The console's messages so far that contain text (test-only read of SPQueryController's storage).
- (NSArray *)loggedMessagesContaining:(NSString *)text
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	id console = [(id)NSClassFromString(@"SPQueryController") valueForKey:@"sharedQueryController"];
	NSMutableArray *found = [NSMutableArray array];
	for (id message in [[console valueForKey:@"messagesFullSet"] copy]) {
		NSString *logged = [message valueForKey:@"message"];
		if ([logged containsString:text]) [found addObject:logged];
	}
	return found;
}

/// A comment with surrounding whitespace (as SQL can set it) is not an edit just because Info shows it.
- (void)testViewingPaddedCommentIsNotAnEdit
{
	[self overridePrefs:@{@"ConsoleEnableLogging": @YES, @"ConsoleEnableInterfaceLogging": @YES, @"ConsoleEnableCustomQueryLogging": @YES, @"ConsoleEnableErrorLogging": @YES}];
	NSString *marker = [NSString stringWithFormat:@"padded-%u", arc4random()];
	[self serverRun:[NSString stringWithFormat:@"COMMENT ON TABLE structure_test.t IS E' %@\\n'", marker]];
	NSString *padded = [NSString stringWithFormat:@" %@\n", marker];

	[self showInfoOf:@"t"];
	SPPostgresTableInfoController *info = self.info;
	XCTAssertEqualObjects([info.commentView string], padded);
	XCTAssertFalse(info.hasPendingComment, @"only viewed");
	XCTAssertTrue([[info.commentView window] makeFirstResponder:info.commentView], @"focused, not edited");
	[self.document viewContent:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	NSPredicate *commentOn = [NSPredicate predicateWithFormat:@"SELF CONTAINS 'COMMENT ON'"];
	XCTAssertEqualObjects([[self loggedMessagesContaining:marker] filteredArrayUsingPredicate:commentOn], @[], @"no COMMENT ON was sent");
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], padded);

	// While another session holds a lock COMMENT ON would wait for: leaving is still free
	info.lockTimeout = 0.5;
	[self serverRun:@"BEGIN"];
	[self serverRun:@"LOCK TABLE structure_test.t IN SHARE MODE"];
	[self.document viewStatus:nil];
	XCTAssertEqualObjects([info.commentView string], padded);
	XCTAssertTrue([[info.commentView window] makeFirstResponder:info.commentView]);
	[self.document viewStructure:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure, @"not vetoed");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// A real edit that fails vetoes leaving; Escape gives it up, and then leaving works
	[self.document viewStatus:nil];
	[self typeComment:@"changed"];
	XCTAssertTrue(info.hasPendingComment);
	[self.document viewContent:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneInfo, @"vetoed");
	XCTAssertEqual(self.alerts.count, 1u);
	[info.commentView doCommandBySelector:@selector(cancelOperation:)];
	XCTAssertEqualObjects([info.commentView string], padded);
	XCTAssertFalse(info.hasPendingComment);
	[self.document viewContent:nil];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneContent);
	XCTAssertEqual(self.alerts.count, 1u);
	[self serverRun:@"ROLLBACK"];
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], padded);

	// A real edit is sent (and logged)
	[self.document viewStatus:nil];
	[self typeComment:[marker stringByAppendingString:@" edited"]];
	[self.document viewContent:nil];
	XCTAssertEqual([[[self loggedMessagesContaining:[marker stringByAppendingString:@" edited"]] filteredArrayUsingPredicate:commentOn] count], 1u, @"the log does show COMMENT ON");
}

- (void)testCreateSyntaxShown
{
	NSFont *font = [NSFont fontWithName:@"Menlo" size:15];
	XCTAssertNotNil(font);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	[self overridePrefs:@{SPInfoTestEditorFontKey: [NSArchiver archivedDataWithRootObject:font]}];
#pragma clang diagnostic pop

	[self showInfoOf:@"t"];
	NSTextView *syntax = self.info.createSyntaxView;
	NSError *error = nil;
	NSString *expected = [SPPostgresCreateStatement createStatementForTable:@"t" inSchema:@"structure_test" connection:self.other error:&error];
	XCTAssertNotNil(expected, @"%@", error);
	XCTAssertEqualObjects([syntax string], expected);
	XCTAssertTrue([[syntax string] hasPrefix:@"CREATE TABLE \"structure_test\".\"t\" ("]);
	XCTAssertFalse([syntax isEditable]);
	XCTAssertTrue([syntax isSelectable]);
	XCTAssertEqualObjects([[syntax font] fontName], @"Menlo-Regular");
	XCTAssertEqual([[syntax font] pointSize], 15.0);

	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t_view"]);
	XCTAssertTrue([[syntax string] hasPrefix:@"CREATE VIEW \"structure_test\".\"t_view\" AS\n"], @"%@", [syntax string]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testQueryDDLMarksStructurePanesStale
{
	[self showInfoOf:@"t"];
	[self.document viewStructure:nil];
	[self runQuery:@"ALTER TABLE structure_test.t ADD COLUMN z int"];
	for (NSString *flag in @[@"structureNeedsReset", @"relationsNeedReset", @"triggersNeedReset", @"infoNeedsReset"]) {
		XCTAssertTrue([self flag:flag], @"%@", flag);
	}

	// ⌘1 shows z
	NSMenuItem *structureItem = [self menuItem:@selector(viewStructure:) key:@"1"];
	XCTAssertTrue([self.controller validateMenuItem:structureItem]);
	[self.controller performSelector:@selector(viewStructure:) withObject:structureItem];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneStructure);
	NSTableView *columns = self.document.structureController.columnsView;
	NSMutableArray *names = [NSMutableArray array];
	for (NSInteger row = 0; row < [columns numberOfRows]; row++) {
		[names addObject:[[columns dataSource] tableView:columns objectValueForTableColumn:[columns tableColumnWithIdentifier:@"name"] row:row] ?: @""];
	}
	XCTAssertEqualObjects([names lastObject], @"z", @"%@", names);

	// And Table Info's create syntax
	[self.document viewStatus:nil];
	XCTAssertTrue([[self.info.createSyntaxView string] containsString:@"\n    \"z\" integer\n"] || [[self.info.createSyntaxView string] containsString:@"\n    \"z\" integer,\n"],
				  @"%@", [self.info.createSyntaxView string]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

- (void)testTableInfoMenuItem
{
	NSMenuItem *infoItem = [self menuItem:@selector(viewStatus:) key:@"5"];
	XCTAssertFalse([self.controller validateMenuItem:infoItem], @"nothing selected");

	[self select:@"t_view"];
	XCTAssertTrue([self.controller validateMenuItem:infoItem], @"views too");
	[self.controller performSelector:@selector(viewStatus:) withObject:infoItem];
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneInfo);
	XCTAssertNotNil([[self.info view] window]);
	XCTAssertEqualObjects([[self.document toolbar] selectedItemIdentifier], SPInfoTestToolbarInfo);
	XCTAssertEqualObjects([self.info.typeField stringValue], @"view");

	// The selection follows while the pane is shown
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"t"]);
	XCTAssertEqualObjects(self.info.table, @"t");
	XCTAssertEqualObjects([self.info.typeField stringValue], @"table");
	XCTAssertEqualObjects([self.info.commentView string], @"the t table");

	// History: back to t_view's Info
	NSMenuItem *back = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(backForwardInHistory:) keyEquivalent:@""];
	back.tag = 0;
	[self.document backForwardInHistory:back];
	XCTAssertEqualObjects(self.document.sidebar.selectedTableName, @"t_view");
	XCTAssertEqualObjects(self.document.currentPane, SPPostgresPaneInfo);
	XCTAssertEqualObjects([self.info.typeField stringValue], @"view");

	// Another pane takes it out of the window
	[self.document viewContent:nil];
	XCTAssertNil([[self.info view] window]);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

#pragma mark - Background loading

/// Gives Table Info the tab's background runner (the tab keeps it on an inline runner until Stage 8 Task 7). Every
/// test using it waits for the runner before anything else uses the connection; side SQL goes through `other`.
- (SPPostgresTableInfoController *)infoOnTabRunner
{
	SPPostgresTableInfoController *info = self.info;
	info.taskRunner = self.document.taskRunner;
	XCTAssertFalse(info.taskRunner.isInline);
	return info;
}

- (NSArray *)shownValuesOf:(SPPostgresTableInfoController *)info
{
	return @[[info.typeField stringValue], [info.ownerField stringValue], [info.rowsField stringValue], [info.tableSizeField stringValue],
			 [info.indexSizeField stringValue], [info.totalSizeField stringValue], [info.commentView string], [info.createSyntaxView string],
			 info.noticeText, @([info.commentView isEditable])];
}

- (void)testShowTableLoadsInBackground
{
	SPPostgresTableInfoController *info = [self infoOnTabRunner];
	[info showTable:@"t" inSchema:@"structure_test"];
	XCTAssertTrue(info.taskRunner.isBusy, @"showTable: returns while the information loads");
	XCTAssertEqualObjects(info.taskRunner.currentDescription, @"Reloading...");
	XCTAssertEqualObjects(info.taskRunner.currentCancelTitle, @"Cancel");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:info.taskRunner timeout:30]);

	SPPostgresTableInfoController *reference = [[SPPostgresTableInfoController alloc] initWithConnection:self.other];
	XCTAssertTrue(reference.taskRunner.isInline);
	[reference showTable:@"t" inSchema:@"structure_test"];
	XCTAssertFalse(reference.taskRunner.isBusy);

	XCTAssertEqualObjects([self shownValuesOf:info], [self shownValuesOf:reference]);
	XCTAssertEqualObjects([info.typeField stringValue], @"table");
	XCTAssertEqualObjects([info.commentView string], @"the t table");
	XCTAssertTrue([[info.createSyntaxView string] hasPrefix:@"CREATE TABLE"], @"%@", [info.createSyntaxView string]);
	XCTAssertFalse(info.stale);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
	[reference invalidate];
}

- (void)testCancelledSwitchShowsEmptyPaneNoAlert
{
	SPPostgresTableInfoController *info = [self infoOnTabRunner];
	SPPostgresTaskRunner *runner = info.taskRunner;
	[info showTable:@"t" inSchema:@"structure_test"];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqualObjects([info.typeField stringValue], @"table");

	[SPPostgresTestServers queueSleep:1 onRunner:runner];
	[info showTable:@"child" inSchema:@"structure_test"];
	XCTAssertTrue(runner.isBusy);
	[runner cancelAll];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);

	XCTAssertEqualObjects(info.table, @"child");
	XCTAssertEqualObjects([self shownValuesOf:info], (@[@"", @"", @"", @"", @"", @"", @"", @"", @"", @NO]));
	XCTAssertEqual(self.alerts.count, 0u, @"a cancelled load shows no alert");
	XCTAssertTrue(info.stale, @"the next show (or a reload) loads it");

	[info reload];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);
	XCTAssertEqualObjects([info.typeField stringValue], @"table");
	XCTAssertTrue([[info.createSyntaxView string] containsString:@"child"], @"%@", [info.createSyntaxView string]);
	XCTAssertFalse(info.stale);
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);
}

/// A comment save while a load runs is refused (nothing reaches the connection); the typed text stays.
- (void)testCommentSaveRefusedWhileBusy
{
	[self showInfoOf:@"t"];
	SPPostgresTableInfoController *info = [self infoOnTabRunner];
	SPPostgresTaskRunner *runner = info.taskRunner;
	[self typeComment:@"while busy"];
	XCTAssertTrue(info.hasPendingComment);

	[SPPostgresTestServers queueSleep:1 onRunner:runner];
	XCTAssertFalse([info commitPendingEdits]);
	XCTAssertTrue(info.hasPendingComment);
	XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:30]);

	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], @"the t table");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", self.alerts.firstObject.informativeText);

	// Once idle it saves
	XCTAssertTrue([info commitPendingEdits]);
	XCTAssertEqualObjects([self serverValue:@"SELECT obj_description('structure_test.t'::regclass, 'pg_class')"], @"while busy");
}

@end
