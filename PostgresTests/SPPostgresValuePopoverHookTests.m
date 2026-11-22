//
//  SPPostgresValuePopoverHookTests.m
//  Sequel Plus
//
//  The PostgreSQL grids' value icon and popover: Content (this file's first part) and Query results. Schema sp_vp,
//  built and dropped here; preferences in a throwaway suite. Against the PostgreSQL 18 test server.
//

#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/SPTextAndLinkCell.h"
#import "../Source/SPValuePopover.h"
#import "../Source/SPValueGutterView.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/Postgres/SPPostgresQueryController.h"

static const NSUInteger SPVPHookTestPort = 55418;
static NSString * const SPVPHookSuite = @"SPPostgresValuePopoverHookTests";

@interface SPPostgresValuePopoverHookTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) PGPostgresConnection *other;
@property (strong) NSUserDefaults *scratch;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<SPValuePopover *> *presented;
@property (copy) NSString *longText;
@property (copy) NSString *veryLongText;
@end

@implementation SPPostgresValuePopoverHookTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	return condition();
}

- (void)run:(NSString *)sql
{
	XCTAssertNotNil([self.other execute:sql], @"%@: %@", sql, [[self.other lastError] errorPrimaryMessage]);
}

- (void)dropFixture
{
	for (NSString *table in @[@"notes", @"tags", @"nokey"]) {
		[self.other execute:[NSString stringWithFormat:@"DROP TABLE IF EXISTS sp_vp.%@", table]];
	}
	[self.other execute:@"DROP SCHEMA IF EXISTS sp_vp"];
}

- (id)serverValue:(NSString *)sql
{
	id value = nil;
	for (NSDictionary *row in [self.other execute:sql]) value = [[row allValues] firstObject];
	return value;
}

static NSString *SPRepeated(NSString *unit, NSUInteger length)
{
	return [@"" stringByPaddingToLength:length withString:unit startingAtIndex:0];
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPVPHookSuite];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPVPHookSuite];
	[self.scratch setBool:NO forKey:@"EditInSheetEnabled"];
	[self.scratch setBool:NO forKey:@"LimitResults"];
	[self.scratch setBool:NO forKey:@"RuleFilterEditorLastVisibilityChoice"];
	self.longText = [NSString stringWithFormat:@"{\"k\":\"%@\"}", SPRepeated(@"a", 200)];   // 208 characters, valid JSON
	self.veryLongText = SPRepeated(@"b", 12000);

	self.other = [SPPostgresTestServers connectedConnectionOnPort:SPVPHookTestPort];
	XCTAssertNotNil(self.other);
	[self dropFixture];
	[self run:@"CREATE SCHEMA sp_vp"];
	[self run:@"CREATE TABLE sp_vp.tags (code text PRIMARY KEY)"];
	[self run:[NSString stringWithFormat:@"INSERT INTO sp_vp.tags VALUES ('%@')", SPRepeated(@"t", 201)]];
	[self run:@"CREATE TABLE sp_vp.notes (id int PRIMARY KEY, body text CHECK (body <> 'forbidden'), data bytea, tag text REFERENCES sp_vp.tags)"];
	[self run:[NSString stringWithFormat:@"INSERT INTO sp_vp.notes VALUES (1, '%@', NULL, '%@')", self.longText, SPRepeated(@"t", 201)]];
	[self run:[NSString stringWithFormat:@"INSERT INTO sp_vp.notes VALUES (2, '%@', NULL, NULL)", SPRepeated(@"c", 200)]];
	[self run:@"INSERT INTO sp_vp.notes VALUES (3, NULL, NULL, NULL)"];
	[self run:@"CREATE TABLE sp_vp.nokey (id text, body text)"];
	[self run:[NSString stringWithFormat:@"INSERT INTO sp_vp.nokey VALUES ('1', '%@')", self.longText]];
	[self run:@"INSERT INTO sp_vp.notes VALUES (5, 'hi', NULL, NULL)"];
	[self run:[NSString stringWithFormat:@"INSERT INTO sp_vp.notes VALUES (4, '%@', decode(repeat('ab', 300), 'hex'), NULL)", self.veryLongText]];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 value popover";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPVPHookTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) { connection = theConnection; done = YES; }];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection);
	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	NSMutableArray *alerts = [NSMutableArray array];
	self.alerts = alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	self.content.defaults = self.scratch;
	self.content.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.document showPane:@"SwitchToTableContentToolbarItemIdentifier"];

	NSMutableArray *presented = [NSMutableArray array];
	self.presented = presented;
	void (^presenter)(SPValuePopover *, NSView *, NSRect) = ^(SPValuePopover *popover, NSView *view, NSRect rect) {
		popover.discardConfirmer = ^BOOL(NSString *column) { return YES; };
		[presented addObject:popover];
	};
	self.content.valuePopoverPresenter = presenter;
	self.query.valuePopoverPresenter = presenter;
	self.query.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
}

- (void)tearDown
{
	for (SPValuePopover *popover in self.presented) [popover closeDiscarding];
	self.presented = nil;
	NSWindow *window = [self.controller window];
	if (window.attachedSheet) [window endSheet:window.attachedSheet];
	[SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[window orderOut:nil];
	self.document = nil;
	self.controller = nil;
	[self dropFixture];
	[self.other disconnect];
	self.other = nil;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPVPHookSuite];
	self.scratch = nil;
	[SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest];
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

- (void)waitForTab
{
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

- (void)selectTable:(NSString *)table
{
	[self.document.sidebar reloadSchema:@"sp_vp"];
	[self waitForTab];
	XCTAssertTrue([self.document.sidebar selectTableNamed:table], @"%@", table);
	[self waitForTab];
	XCTAssertEqualObjects(self.content.table, table);
}

- (NSTableColumn *)tableColumnNamed:(NSString *)name
{
	for (NSTableColumn *column in [[self grid] tableColumns]) {
		if ([[[column headerCell] stringValue] isEqualToString:name]) return column;
	}
	XCTFail(@"No column %@", name);
	return nil;
}

- (NSUInteger)columnIndexNamed:(NSString *)name
{
	return (NSUInteger)[[[self tableColumnNamed:name] identifier] integerValue];
}

- (NSInteger)rowWithId:(NSString *)identifier
{
	NSTableColumn *column = [self tableColumnNamed:@"id"];
	for (NSInteger row = 0; row < [[self grid] numberOfRows]; row++) {
		if ([[[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:column row:row] isEqual:identifier]) return row;
	}
	XCTFail(@"No row with id %@", identifier);
	return -1;
}

/// The cell for column at row, as the grid would draw it.
- (SPTextAndLinkCell *)displayedCell:(NSString *)name row:(NSInteger)row
{
	NSTableColumn *column = [self tableColumnNamed:name];
	id cell = [column dataCellForRow:row];
	XCTAssertTrue([cell isKindOfClass:[SPTextAndLinkCell class]], @"%@ is a %@", name, [cell class]);
	[cell setObjectValue:[[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:column row:row]];
	[(id<NSTableViewDelegate>)[self grid].delegate tableView:[self grid] willDisplayCell:cell forTableColumn:column row:row];
	return cell;
}

- (SPValuePopover *)openValue:(NSString *)name row:(NSInteger)row
{
	NSUInteger before = self.presented.count;
	[self.content showValueAtRow:row column:[self columnIndexNamed:name]];
	XCTAssertEqual(self.presented.count, before + 1, @"a popover was presented");
	return self.presented.lastObject;
}

/// Saves through the popover's Save; YES when it closed (saved).
- (BOOL)saveText:(NSString *)text in:(SPValuePopover *)popover
{
	NSTextView *textView = popover.textView;
	[textView setSelectedRange:NSMakeRange(0, [[textView string] length])];
	[textView insertText:text replacementRange:[textView selectedRange]];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[popover save];
	[self waitForTab];
	return closed;
}

#pragma mark - Content

- (void)testIconOnEveryTextValueAndNull
{
	[self selectTable:@"notes"];
	XCTAssertTrue([self displayedCell:@"body" row:[self rowWithId:@"1"]].valueIconActive, @"208 characters");
	XCTAssertTrue([self displayedCell:@"body" row:[self rowWithId:@"2"]].valueIconActive, @"any length");
	XCTAssertTrue([self displayedCell:@"body" row:[self rowWithId:@"5"]].valueIconActive, @"a short value");
	XCTAssertTrue([self displayedCell:@"body" row:[self rowWithId:@"3"]].valueIconActive, @"NULL: it can be edited into a value");
	XCTAssertFalse([self displayedCell:@"data" row:[self rowWithId:@"4"]].valueIconActive, @"bytea");
	XCTAssertFalse([self displayedCell:@"id" row:[self rowWithId:@"1"]].valueIconActive, @"not a text column");

	// Not on the row being edited
	NSInteger row = [self rowWithId:@"1"];
	[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	[[self grid] editColumn:[[self grid] columnWithIdentifier:[[self tableColumnNamed:@"id"] identifier]] row:row withEvent:nil select:YES];
	XCTAssertFalse([self displayedCell:@"body" row:row].valueIconActive);
	[[self grid] abortEditing];

	// Not on the new row not inserted yet
	[self.content addRow:nil];
	[self waitForTab];
	NSInteger pending = [[self grid] numberOfRows] - 1;
	[[self grid] abortEditing];
	XCTAssertFalse([self displayedCell:@"body" row:pending].valueIconActive);
}

- (void)testNoIconOnPrimaryKeyValues
{
	[self selectTable:@"tags"]; // code text PRIMARY KEY, 201 characters
	XCTAssertFalse([self displayedCell:@"code" row:0].valueIconActive, @"a primary key value, however long");
}

- (void)testLongForeignKeyCellShowsAllThreeButtons
{
	[self selectTable:@"notes"];
	SPTextAndLinkCell *cell = [self displayedCell:@"tag" row:[self rowWithId:@"1"]];
	XCTAssertTrue(cell.linkActive);
	XCTAssertTrue(cell.pickerIconActive, @"a text foreign key: the picker serves it");
	XCTAssertTrue(cell.valueIconActive);
	NSRect frame = NSMakeRect(0, 0, 200, 17);
	// From the right edge: the picker icon, the arrow, the value icon
	NSRect picker = SPTextButtonSlotRect(frame, 0), arrow = SPTextButtonSlotRect(frame, 1), value = SPTextButtonSlotRect(frame, 2);
	XCTAssertEqual([cell buttonAtPoint:NSMakePoint(NSMidX(arrow), 8) inCellFrame:frame], SPTextAndLinkCellLinkButton);
	XCTAssertEqual([cell buttonAtPoint:NSMakePoint(NSMidX(picker), 8) inCellFrame:frame], SPTextAndLinkCellPickerButton);
	XCTAssertEqual([cell buttonAtPoint:NSMakePoint(NSMidX(value), 8) inCellFrame:frame], SPTextAndLinkCellValueButton);
}

- (void)testNullOpensEmptyAndSavesText
{
	[self selectTable:@"notes"];
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"3"]];
	XCTAssertEqualObjects([popover.textView string], @"");
	XCTAssertEqualObjects([popover.titleField stringValue], @"body — NULL");
	XCTAssertFalse([popover.saveButton isEnabled], @"nothing typed: the value stays NULL");
	XCTAssertTrue([self saveText:@"now a value" in:popover]);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 3"], @"now a value");
}

- (void)testIconOpensRawValue
{
	[self selectTable:@"notes"];
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"1"]];
	XCTAssertEqualObjects([popover.textView string], self.longText);
	XCTAssertTrue([popover.textView isEditable]);
	XCTAssertEqualObjects([popover.titleField stringValue], @"body — 208 characters");

	SPValuePopover *large = [self openValue:@"body" row:[self rowWithId:@"4"]];
	XCTAssertEqualObjects([large.textView string], self.veryLongText, @"the whole value, past 10,000 characters");
}

- (void)testSaveWritesThroughCommitPath
{
	[self selectTable:@"notes"];
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"1"]];
	[popover formatJSON];
	NSString *pretty = [popover.textView string];
	XCTAssertNotEqualObjects(pretty, self.longText);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText, @"formatting wrote nothing");
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[popover save];
	[self waitForTab];
	XCTAssertTrue(closed);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], pretty);
	XCTAssertEqualObjects([[[self grid] dataSource] tableView:[self grid] objectValueForTableColumn:[self tableColumnNamed:@"body"] row:[self rowWithId:@"1"]], pretty);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testSaveFailureKeepsPopoverOpen
{
	[self selectTable:@"notes"];
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"1"]];
	XCTAssertFalse([self saveText:@"forbidden" in:popover]);
	XCTAssertTrue([[popover.errorField stringValue] containsString:@"check constraint"], @"%@", [popover.errorField stringValue]);
	XCTAssertEqualObjects([popover.textView string], @"forbidden", @"text kept");
	XCTAssertTrue([popover.saveButton isEnabled]);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText);
	XCTAssertEqual(self.alerts.count, 0u, @"the popover shows the error, no alert over it");

	// Fixed and saved again: the same row
	XCTAssertTrue([self saveText:@"allowed now" in:popover]);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], @"allowed now");
}

- (void)testFormatWithoutSaveWritesNothing
{
	[self selectTable:@"notes"];
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"1"]];
	[popover formatJSON];
	[popover compact];
	[popover cancel];
	[self waitForTab];
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText);
}

- (void)testReloadClosesPopoverWithoutWriting
{
	[self selectTable:@"notes"];
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"1"]];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[popover.textView insertText:@"typed" replacementRange:NSMakeRange(0, 0)];
	[self.content reload];
	[self waitForTab];
	XCTAssertTrue(closed);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText);
}

- (void)testReadOnlyTableOpensCloseOnly
{
	[self selectTable:@"nokey"]; // no primary key: read-only
	SPValuePopover *popover = [self openValue:@"body" row:[self rowWithId:@"1"]];
	XCTAssertFalse([popover.textView isEditable]);
	XCTAssertTrue([popover.saveButton isHidden]);
}

#pragma mark - Query results

- (SPPostgresQueryController *)query
{
	return self.document.queryController;
}

- (void)runQuery:(NSString *)sql
{
	[self.document showPane:@"SwitchToRunQueryToolbarItemIdentifier"];
	[self.query.editor setString:sql];
	[self.query.editor setSelectedRange:NSMakeRange(0, 0)];
	[self.query runAllQueries:nil];
	[self waitForTab];
}

/// The query grid's cell for result column at row, as the grid would draw it.
- (SPTextAndLinkCell *)queryCell:(NSUInteger)column row:(NSInteger)row
{
	NSTableView *grid = self.query.resultsView;
	NSTableColumn *tableColumn = [[grid tableColumns] objectAtIndex:column];
	id cell = [tableColumn dataCellForRow:row];
	XCTAssertTrue([cell isKindOfClass:[SPTextAndLinkCell class]], @"a %@", [cell class]);
	[cell setObjectValue:[[grid dataSource] tableView:grid objectValueForTableColumn:tableColumn row:row]];
	[(id<NSTableViewDelegate>)grid.delegate tableView:grid willDisplayCell:cell forTableColumn:tableColumn row:row];
	return cell;
}

/// Runs sql and returns its result's cell, as drawn.
- (SPTextAndLinkCell *)queryCell:(NSUInteger)column row:(NSInteger)row sql:(NSString *)sql
{
	[self runQuery:sql];
	return [self queryCell:column row:row];
}

- (SPValuePopover *)openQueryValueRow:(NSInteger)row column:(NSUInteger)column
{
	NSUInteger before = self.presented.count;
	[self.query showValueAtRow:row column:column];
	XCTAssertEqual(self.presented.count, before + 1, @"a popover was presented");
	return self.presented.lastObject;
}

- (void)testResultKnowsColumnTypes
{
	PGPostgresResult *result = [self.other execute:@"SELECT body, data, id FROM sp_vp.notes LIMIT 1"];
	XCTAssertEqual([result typeOIDForField:0], 25u, @"text");
	XCTAssertEqual([result typeOIDForField:1], 17u, @"bytea");
	XCTAssertEqual([result typeOIDForField:2], 23u, @"int4");
	XCTAssertEqual([result typeOIDForField:9], 0u, @"out of range");
}

- (void)testQueryIconOnLongValues
{
	[self runQuery:@"SELECT id, body, data FROM sp_vp.notes ORDER BY id"];
	XCTAssertTrue([self queryCell:1 row:0].valueIconActive, @"208 characters");
	XCTAssertTrue([self queryCell:1 row:1].valueIconActive, @"any length");
	XCTAssertFalse([self queryCell:0 row:0].valueIconActive, @"int: not a text column");
	XCTAssertTrue([self queryCell:1 row:2].valueIconActive, @"NULL");
	XCTAssertFalse([self queryCell:2 row:3].valueIconActive, @"bytea");

	SPValuePopover *popover = [self openQueryValueRow:3 column:1];
	XCTAssertEqualObjects([popover.textView string], self.veryLongText, @"the whole value, not the grid's cut text");
	XCTAssertTrue([self queryCell:0 row:0 sql:@"SELECT repeat('n', 250)::varchar AS v"].valueIconActive, @"varchar");
}

- (void)testQueryReadOnlyResultOpensCloseOnly
{
	[self runQuery:@"SELECT body || '' AS b FROM sp_vp.notes WHERE id = 1"];
	SPValuePopover *popover = [self openQueryValueRow:0 column:0];
	XCTAssertFalse([popover.textView isEditable]);
	XCTAssertTrue([popover.saveButton isHidden]);
	XCTAssertEqualObjects([popover.textView string], self.longText);
}

- (void)testQueryEditableResultSaves
{
	[self runQuery:@"SELECT id, body FROM sp_vp.notes WHERE id = 1"];
	SPValuePopover *popover = [self openQueryValueRow:0 column:1];
	XCTAssertTrue([popover.textView isEditable]);
	[popover formatJSON];
	NSString *pretty = [popover.textView string];
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText, @"formatting wrote nothing");
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[popover save];
	[self waitForTab];
	XCTAssertTrue(closed);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], pretty);
	NSTableView *grid = self.query.resultsView;
	XCTAssertEqualObjects([[grid dataSource] tableView:grid objectValueForTableColumn:[[grid tableColumns] objectAtIndex:1] row:0], pretty);
	XCTAssertEqual(self.alerts.count, 0u);
}

- (void)testQuerySaveFailureKeepsPopoverOpen
{
	[self runQuery:@"SELECT id, body FROM sp_vp.notes WHERE id = 1"];
	SPValuePopover *popover = [self openQueryValueRow:0 column:1];
	XCTAssertFalse([self saveText:@"forbidden" in:popover]);
	XCTAssertTrue([[popover.errorField stringValue] containsString:@"check constraint"], @"%@", [popover.errorField stringValue]);
	XCTAssertEqual(self.alerts.count, 0u);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText);
}

- (void)testQueryRerunClosesPopover
{
	[self runQuery:@"SELECT id, body FROM sp_vp.notes WHERE id = 1"];
	SPValuePopover *popover = [self openQueryValueRow:0 column:1];
	__block BOOL closed = NO;
	popover.closed = ^{ closed = YES; };
	[self.query runAllQueries:nil];
	[self waitForTab];
	XCTAssertTrue(closed);
	XCTAssertEqualObjects([self serverValue:@"SELECT body FROM sp_vp.notes WHERE id = 1"], self.longText);
}

@end
