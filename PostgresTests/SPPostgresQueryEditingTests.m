#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresQueryResultEditor.h"
#import "../Source/Postgres/SPPostgresQueryStore.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"

/// The controller's test seam: called on the runner's thread before each statement runs.
@interface SPPostgresQueryController (EditingTesting)
- (void)setStatementWillRunHook:(void (^)(NSString *statement))hook;
@end

// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPQueryEditingReloadKey = @"ReloadAfterEditingRow";
static NSString * const SPQueryEditingInSheetKey = @"EditInSheetEnabled";
static NSString * const SPQueryEditingMaxHistoryKey = @"CustomQueryMaxHistoryItems";
static NSString * const SPQueryEditingNullValueKey = @"NullValue";
static NSString * const SPQueryEditingNull = @"<edit-null>";
static NSString * const SPQueryEditingSuiteName = @"SPPostgresStage12Tests";

/// One refusal shown by the controller's editRefusalPresenter.
@interface SPQueryEditingRefusal : NSObject
@property (copy) NSString *message;
@property (assign) NSInteger row;
@property (assign) NSInteger column;
@end

@implementation SPQueryEditingRefusal
@end

/**
 * The Query tab's inline editing (Stage 12 Task 6): the grid's data source and delegate methods driven directly on a
 * controller with an inline runner (a run has finished when its action returns), on both servers. Preferences, the
 * NULL placeholder too, go to a scratch suite (the controller's defaults); the history is a temporary store.
 */
@interface SPPostgresQueryEditingTests : XCTestCase
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSUserDefaults *scratch;
@property (strong) SPPostgresQueryStore *store;
@property (copy) NSString *directory;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<SPQueryEditingRefusal *> *refusals;
@property (strong) NSMutableArray<NSString *> *statements;
@property (strong) NSMutableArray<NSArray *> *changes;
@property (strong) PGPostgresConnection *connection;
@end

@implementation SPPostgresQueryEditingTests

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
	[self overridePrefs:@{@"CustomQueryAutoIndent": @NO, @"CustomQueryAutoPairCharacters": @NO, @"CustomQueryAutoUppercaseKeywords": @NO,
						  @"CustomQueryAutoComplete": @NO, @"CustomQueryUpdateAutoHelp": @NO, @"CustomQueryHighlightCurrentQuery": @NO}];

	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPQueryEditingSuiteName];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPQueryEditingSuiteName];
	[self.scratch setBool:NO forKey:SPQueryEditingReloadKey];
	[self.scratch setBool:NO forKey:SPQueryEditingInSheetKey];
	[self.scratch setInteger:10 forKey:SPQueryEditingMaxHistoryKey];
	// Read through the controller's defaults (the argument domain would override the suite: it must not hold it)
	XCTAssertNil([[[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain] objectForKey:SPQueryEditingNullValueKey]);
	[self.scratch setObject:SPQueryEditingNull forKey:SPQueryEditingNullValueKey];

	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];

	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 695, 534) styleMask:NSWindowStyleMaskTitled
												backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
	self.alerts = [NSMutableArray array];
	self.refusals = [NSMutableArray array];
	self.statements = [NSMutableArray array];
	self.changes = [NSMutableArray array];

	for (NSNumber *port in [SPPostgresTestServers ports]) [SPPostgresTestServers loadQueryEditFixtureOnPort:port.unsignedIntegerValue];
}

- (void)tearDown
{
	[self closeQuery];
	[self.window close];
	self.window = nil;
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPQueryEditingSuiteName];
	self.scratch = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (void)closeQuery
{
	[self.query invalidate];
	[[self.query view] removeFromSuperview];
	self.query = nil;
	[self.connection disconnect];
	self.connection = nil;
}

/// A new controller on port (the previous one closed), with the seams recording into the test's arrays.
- (void)openQueryOnPort:(NSNumber *)port
{
	[self closeQuery];
	[self.alerts removeAllObjects];
	[self.refusals removeAllObjects];
	[self.statements removeAllObjects];
	[self.changes removeAllObjects];

	NSString *storePath = [self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"PostgresQueryHistory-%@.plist", port]];
	[[NSFileManager defaultManager] removeItemAtPath:storePath error:NULL];
	self.store = [[SPPostgresQueryStore alloc] initWithFileURL:[NSURL fileURLWithPath:storePath]];

	self.connection = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	self.query = [[SPPostgresQueryController alloc] initWithConnection:self.connection];
	self.query.defaults = self.scratch;
	self.query.historyStore = self.store;
	self.query.infoPaneAnimates = NO;

	__weak SPPostgresQueryEditingTests *weakSelf = self;
	self.query.alertPresenter = ^(NSAlert *alert) { [weakSelf.alerts addObject:alert]; };
	self.query.editRefusalPresenter = ^(NSString *message, NSInteger row, NSInteger column) {
		SPQueryEditingRefusal *refusal = [[SPQueryEditingRefusal alloc] init];
		refusal.message = message;
		refusal.row = row;
		refusal.column = column;
		[weakSelf.refusals addObject:refusal];
	};
	self.query.runDidChangeDatabase = ^(BOOL schemaChanged, BOOL dataChanged) { [weakSelf.changes addObject:@[@(schemaChanged), @(dataChanged)]]; };

	[[self.window contentView] addSubview:[self.query view]];
	[[self.query view] setFrame:[[self.window contentView] bounds]];
}

/// Runs sql through Run All (inline: finished on return).
- (void)run:(NSString *)sql
{
	[self.query.editor setString:sql];
	[self.query runAllQueries:nil];
}

/// Records every statement the controller runs from now on.
- (void)recordStatements
{
	NSMutableArray *statements = self.statements;
	[self.query setStatementWillRunHook:^(NSString *statement) {
		@synchronized (statements) { [statements addObject:statement]; }
	}];
}

- (NSTableView *)grid
{
	return self.query.resultsView;
}

- (NSTableColumn *)column:(NSInteger)index
{
	return [[[self grid] tableColumns] objectAtIndex:(NSUInteger)index];
}

- (BOOL)shouldEditRow:(NSInteger)row column:(NSInteger)column
{
	return [self.query tableView:[self grid] shouldEditTableColumn:[self column:column] row:row];
}

- (void)setValue:(id)value row:(NSInteger)row column:(NSInteger)column
{
	[self.query tableView:[self grid] setObjectValue:value forTableColumn:[self column:column] row:row];
}

- (id)gridValueAtRow:(NSInteger)row column:(NSInteger)column
{
	return [self.query tableView:[self grid] objectValueForTableColumn:[self column:column] row:row];
}

- (id)serverValue:(NSString *)sql port:(NSNumber *)port
{
	PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	PGPostgresResult *result = [other execute:sql];
	XCTAssertNotNil(result, @"%@: %@", sql, other.lastError.errorPrimaryMessage);
	id value = [result textValueAtRow:0 column:0];
	[other disconnect];
	return value;
}

#pragma mark - Inline editing

- (void)testKeyedCellEditsInline
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertNotNil(self.query.resultEditor, @"port %@", port);
		XCTAssertTrue([[self column:1] isEditable]);

		XCTAssertTrue([self shouldEditRow:0 column:1], @"port %@: %@", port, [self.refusals.firstObject message]);
		XCTAssertEqual(self.refusals.count, 0u);
		[self setValue:@"uno" row:0 column:1];
		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"uno");
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"uno");
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 2" port:port], @"two");

		// Invalidating drops the editor
		[self.query invalidate];
		XCTAssertNil(self.query.resultEditor);
	}
}

- (void)testExpressionCellRefusedWithMySQLMessage
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, id + 1 FROM query_edit_test.items ORDER BY id"];
		XCTAssertFalse([self shouldEditRow:1 column:1], @"port %@", port);
		XCTAssertEqual(self.refusals.count, 1u);
		XCTAssertEqualObjects(self.refusals.firstObject.message, NSLocalizedString(@"Field is not editable. Field has no or multiple table or database origin(s).",@"field is not editable due to no table/database"));
		XCTAssertEqual(self.refusals.firstObject.row, 1);
		XCTAssertEqual(self.refusals.firstObject.column, 1);
	}
}

- (void)testDuplicateRowsRefusedWithMatchCount
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT n, t FROM query_edit_test.nokey ORDER BY n"];
		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(self.refusals.count, 1u);
		XCTAssertTrue([self.refusals.firstObject.message containsString:@"(2 matches)"], @"%@", self.refusals.firstObject.message);
	}
}

- (void)testEditRefusedWhileRunnerBusy
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		SPPostgresTaskRunner *runner = [[SPPostgresTaskRunner alloc] initWithConnection:self.connection];
		self.query.taskRunner = runner;
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
		XCTAssertNotNil(self.query.resultEditor);

		[SPPostgresTestServers queueSleep:2 onRunner:runner];
		XCTAssertTrue(runner.isBusy);
		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(self.refusals.count, 0u, @"refused silently while busy");

		// A value arriving meanwhile is not sent
		[self setValue:@"busy" row:0 column:1];

		[runner cancelAll];
		XCTAssertTrue([SPPostgresTestServers waitForRunner:runner timeout:10]);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"one");
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"one");
		[runner invalidateWithCompletion:nil];
	}
}

- (void)testSaveErrorShowsAlert
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertTrue([self shouldEditRow:0 column:0], @"port %@: %@", port, [self.refusals.firstObject message]);
		[self setValue:@"abc" row:0 column:0];
		XCTAssertEqual(self.alerts.count, 1u, @"port %@", port);
		XCTAssertEqualObjects(self.alerts.firstObject.messageText, NSLocalizedString(@"Error", @"error"));
		XCTAssertTrue([self.alerts.firstObject.informativeText hasPrefix:@"Couldn't write field.\nPostgreSQL said:"], @"%@", self.alerts.firstObject.informativeText);
		XCTAssertEqualObjects([self gridValueAtRow:0 column:0], @"1");
		XCTAssertEqual(self.changes.count, 0u);
	}
}

/// A value from an edit begun on an earlier result is never sent to the new result's row of the same number.
- (void)testCommitAfterNewRunIsNotSent
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		NSTableColumn *staleColumn = [self column:1];
		XCTAssertTrue([self shouldEditRow:0 column:1], @"port %@", port);

		// Another run: row 0 is now id 2
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id DESC"];
		XCTAssertEqualObjects([self gridValueAtRow:0 column:0], @"2");
		[self.query tableView:[self grid] setObjectValue:@"stale" forTableColumn:staleColumn row:0];
		// Also with the new result's own column, which no shouldEdit approved
		[self setValue:@"stale" row:0 column:1];

		XCTAssertEqual(self.changes.count, 0u, @"port %@", port);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(name, ',' ORDER BY id) FROM query_edit_test.items" port:port], @"one,two");
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"two");
	}
}

/// A cell editor open in the grid when a run starts is closed without committing.
- (void)testRunAbortsOpenCellEditor
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertTrue([self shouldEditRow:0 column:1]);
		[[self grid] editColumn:1 row:0 withEvent:nil select:YES];
		XCTAssertNotNil([[self grid] currentEditor], @"port %@: the grid's field editor opened", port);
		[(NSText *)[[self grid] currentEditor] setString:@"typed"];

		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id DESC"];
		XCTAssertNil([[self grid] currentEditor], @"port %@", port);
		XCTAssertEqual([[self grid] editedRow], -1);
		XCTAssertEqual(self.changes.count, 0u);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(name, ',' ORDER BY id) FROM query_edit_test.items" port:port], @"one,two");

		// Invalidating closes one too
		XCTAssertTrue([self shouldEditRow:0 column:1]);
		[[self grid] editColumn:1 row:0 withEvent:nil select:YES];
		XCTAssertNotNil([[self grid] currentEditor]);
		[self.query invalidate];
		XCTAssertNil([[self grid] currentEditor]);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(name, ',' ORDER BY id) FROM query_edit_test.items" port:port], @"one,two");
	}
}

#pragma mark - Values longer than the grid shows

/// Sets items 1's name to 10,000 x's and a y (the grid cuts values after 10,000 characters); returns it.
- (NSString *)storeLongNameOnPort:(NSNumber *)port
{
	PGPostgresConnection *other = [SPPostgresTestServers connectedConnectionOnPort:port.unsignedIntegerValue];
	XCTAssertNotNil([other execute:@"UPDATE query_edit_test.items SET name = repeat('x', 10000) || 'y' WHERE id = 1"], @"%@", other.lastError.errorPrimaryMessage);
	[other disconnect];
	return [[@"" stringByPaddingToLength:10000 withString:@"x" startingAtIndex:0] stringByAppendingString:@"y"];
}

/// A cell whose value the grid shows cut is never edited in the grid (its in-cell editor would start from the cut
/// text): the field editor sheet opens with the full value, also with edit mode off.
- (void)testLongValueOpensSheetWithFullText
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *full = [self storeLongNameOnPort:port];
		[self openQueryOnPort:port];
		NSMutableArray<NSDictionary *> *sheets = [self installSheetPresenter];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertEqual([[self gridValueAtRow:0 column:1] length], 10000u);

		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(sheets.count, 1u, @"port %@", port);
		XCTAssertEqual([sheets[0][@"value"] length], 10001u);
		XCTAssertEqualObjects(sheets[0][@"value"], full);
		XCTAssertEqualObjects(sheets[0][@"editable"], @YES);
		XCTAssertEqual(self.refusals.count, 0u);

		[self completeSheet:sheets[0] with:[full stringByAppendingString:@"z"]];
		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], [full stringByAppendingString:@"z"]);

		// A short value still edits in the grid
		XCTAssertTrue([self shouldEditRow:1 column:1], @"port %@", port);
		XCTAssertEqual(sheets.count, 1u);
	}
}

/// The cut text of a longer value coming back from the grid is the unchanged value: nothing is sent.
- (void)testCommitOfCutTextSendsNothing
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		NSString *full = [self storeLongNameOnPort:port];
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		NSString *cut = [self gridValueAtRow:0 column:1];
		XCTAssertEqual(cut.length, 10000u);

		// The result is approved (another cell's inline check), then the cut text arrives for the long cell
		XCTAssertTrue([self shouldEditRow:1 column:1], @"port %@", port);
		[self setValue:cut row:0 column:1];

		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);
		XCTAssertEqual(self.changes.count, 0u, @"port %@", port);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], full);
	}
}

#pragma mark - After a save

- (void)testReloadAfterEditRerunsSelect
{
	[self.scratch setBool:YES forKey:SPQueryEditingReloadKey];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		NSString *sql = @"SELECT id, name FROM query_edit_test.items ORDER BY id";
		[self run:sql];
		NSString *lastRun = self.query.lastRunQueryText;
		XCTAssertEqual([[self.store items] count], 1u);
		[[self grid] selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
		[self recordStatements];

		XCTAssertTrue([self shouldEditRow:1 column:1], @"port %@: %@", port, [self.refusals.firstObject message]);
		[self setValue:@"dos" row:1 column:1];
		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);

		XCTAssertEqualObjects(self.statements, @[sql], @"port %@", port);
		XCTAssertEqual([[self.store items] count], 1u, @"the reload adds no history entry");
		XCTAssertEqualObjects(self.query.lastRunQueryText, lastRun);
		XCTAssertEqual([[self grid] selectedRow], 1);
		XCTAssertEqual([[[self grid] selectedRowIndexes] count], 1u);
		XCTAssertEqualObjects([self gridValueAtRow:1 column:1], @"dos");
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 2" port:port], @"dos");
	}
}

- (void)testNoReloadWhenPreferenceOff
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		[self recordStatements];
		XCTAssertTrue([self shouldEditRow:0 column:1], @"port %@: %@", port, [self.refusals.firstObject message]);
		[self setValue:@"uno" row:0 column:1];
		XCTAssertEqual(self.statements.count, 0u, @"port %@: %@", port, self.statements);
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"uno");
	}
}

- (void)testDataChangingStatementIsNotRerun
{
	[self.scratch setBool:YES forKey:SPQueryEditingReloadKey];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"UPDATE query_edit_test.items SET name = name WHERE id = 1 RETURNING id, name"];
		XCTAssertEqual([[self grid] numberOfRows], 1);
		[self recordStatements];
		XCTAssertTrue([self shouldEditRow:0 column:1], @"port %@: %@", port, [self.refusals.firstObject message]);
		[self setValue:@"uno" row:0 column:1];
		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);
		XCTAssertEqual(self.statements.count, 0u, @"port %@: %@", port, self.statements);
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"uno");
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"uno");
	}
}

- (void)testEditTellsTabDataChanged
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertEqual(self.changes.count, 0u);
		XCTAssertTrue([self shouldEditRow:0 column:1]);
		[self setValue:@"uno" row:0 column:1];
		XCTAssertEqualObjects(self.changes, (@[@[@NO, @YES]]), @"port %@", port);

		// An unchanged value sends nothing
		[self setValue:@"uno" row:0 column:1];
		XCTAssertEqual(self.changes.count, 1u);
	}
}

- (void)testExportIncludesEdits
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertTrue([self shouldEditRow:0 column:1]);
		[self setValue:@"uno" row:0 column:1];
		XCTAssertEqualObjects([self.query lastResultRows], (@[@[@"1", @"uno"], @[@"2", @"two"]]), @"port %@", port);
	}
}

- (void)testNullPlaceholderSavesNull
{
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertTrue([self shouldEditRow:0 column:1]);
		[self setValue:SPQueryEditingNull row:0 column:1];
		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);
		XCTAssertEqualObjects([self serverValue:@"SELECT (name IS NULL)::text FROM query_edit_test.items WHERE id = 1" port:port], @"true");
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], SPQueryEditingNull);
		XCTAssertEqualObjects([[self.query lastResultRows] firstObject], (@[@"1", [NSNull null]]));
	}
}

#pragma mark - Edit mode: the field editor sheet

/// What the controller's fieldEditorPresenter got (the completion kept to end the "sheet" later).
- (NSMutableArray<NSDictionary *> *)installSheetPresenter
{
	NSMutableArray<NSDictionary *> *sheets = [NSMutableArray array];
	self.query.fieldEditorPresenter = ^(NSString *value, NSString *columnName, NSString *typeName, BOOL editable, BOOL allowNull, void (^completion)(id newValue)) {
		[sheets addObject:@{@"value": value ?: [NSNull null], @"column": columnName ?: [NSNull null], @"type": typeName ?: [NSNull null],
							@"editable": @(editable), @"allowNull": @(allowNull), @"completion": [completion copy]}];
	};
	return sheets;
}

- (void)completeSheet:(NSDictionary *)sheet with:(id)value
{
	void (^completion)(id) = sheet[@"completion"];
	completion(value);
}

- (void)testEditModeOpensSheetInsteadOfInline
{
	[self.scratch setBool:YES forKey:SPQueryEditingInSheetKey];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		NSMutableArray<NSDictionary *> *sheets = [self installSheetPresenter];
		[self run:@"SELECT id, name, price FROM query_edit_test.items ORDER BY id"];

		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(sheets.count, 1u, @"port %@", port);
		XCTAssertEqualObjects(sheets[0][@"value"], @"one");
		XCTAssertEqualObjects(sheets[0][@"column"], @"name");
		XCTAssertEqualObjects(sheets[0][@"type"], @"text");
		XCTAssertEqualObjects(sheets[0][@"editable"], @YES);
		XCTAssertEqualObjects(sheets[0][@"allowNull"], @YES);
		XCTAssertEqual(self.refusals.count, 0u);

		// One sheet at a time
		XCTAssertFalse([self shouldEditRow:1 column:1]);
		XCTAssertEqual(sheets.count, 1u);

		[self completeSheet:sheets[0] with:@"sheet"];
		XCTAssertEqual(self.alerts.count, 0u, @"port %@: %@", port, [self.alerts.firstObject informativeText]);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"sheet");
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"sheet");
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 2" port:port], @"two");
		// A second call of the same completion sends nothing
		[self completeSheet:sheets[0] with:@"again"];
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"sheet");

		// NULL shows the placeholder; the next sheet opens once the first has ended
		XCTAssertFalse([self shouldEditRow:1 column:2]);
		XCTAssertEqual(sheets.count, 2u);
		XCTAssertEqualObjects(sheets[1][@"value"], SPQueryEditingNull);
		XCTAssertEqualObjects(sheets[1][@"column"], @"price");
		XCTAssertEqualObjects(sheets[1][@"type"], @"numeric");
		[self completeSheet:sheets[1] with:nil];
	}
}

- (void)testSheetReadOnlyForUneditableCell
{
	[self.scratch setBool:YES forKey:SPQueryEditingInSheetKey];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		NSMutableArray<NSDictionary *> *sheets = [self installSheetPresenter];
		[self run:@"SELECT id, upper(name) AS shout FROM query_edit_test.items ORDER BY id"];

		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(sheets.count, 1u, @"port %@", port);
		XCTAssertEqualObjects(sheets[0][@"value"], @"ONE");
		XCTAssertEqualObjects(sheets[0][@"column"], @"shout");
		XCTAssertEqualObjects(sheets[0][@"type"], @"");
		XCTAssertEqualObjects(sheets[0][@"editable"], @NO);
		XCTAssertEqual(self.refusals.count, 0u, @"MySQL shows no tooltip in the sheet's path");

		[self completeSheet:sheets[0] with:@"changed"];
		XCTAssertEqual(self.changes.count, 0u, @"port %@", port);
		XCTAssertEqual(self.alerts.count, 0u, @"nothing was tried: %@", [self.alerts.firstObject informativeText]);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(name, ',' ORDER BY id) FROM query_edit_test.items" port:port], @"one,two");

		// Also an editable cell's sheet can't commit to a cell the sheet didn't approve
		XCTAssertFalse([self shouldEditRow:0 column:0]);
		XCTAssertEqual(sheets.count, 2u);
		XCTAssertEqualObjects(sheets[1][@"editable"], @YES);
		[self completeSheet:sheets[1] with:@"5"];
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(id::text, ',' ORDER BY id) FROM query_edit_test.items" port:port], @"2,5");
	}
}

- (void)testSheetResultDroppedAfterNewRun
{
	[self.scratch setBool:YES forKey:SPQueryEditingInSheetKey];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		NSMutableArray<NSDictionary *> *sheets = [self installSheetPresenter];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(sheets.count, 1u);
		XCTAssertEqualObjects(sheets[0][@"editable"], @YES);

		// Another run: row 0 is now id 2, and the new result's cell was approved inline-wise by no one
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id DESC"];
		[self completeSheet:sheets[0] with:@"stale"];

		XCTAssertEqual(self.changes.count, 0u, @"port %@", port);
		XCTAssertEqualObjects([self serverValue:@"SELECT string_agg(name, ',' ORDER BY id) FROM query_edit_test.items" port:port], @"one,two");
		XCTAssertEqualObjects([self gridValueAtRow:0 column:1], @"two");

		// The ended sheet lets the next one open
		XCTAssertFalse([self shouldEditRow:0 column:1]);
		XCTAssertEqual(sheets.count, 2u);
		[self completeSheet:sheets[1] with:nil];
	}
}

- (void)testCancelledSheetSendsNothing
{
	[self.scratch setBool:YES forKey:SPQueryEditingInSheetKey];
	for (NSNumber *port in [SPPostgresTestServers ports]) {
		[self openQueryOnPort:port];
		NSMutableArray<NSDictionary *> *sheets = [self installSheetPresenter];
		[self run:@"SELECT id, name FROM query_edit_test.items ORDER BY id"];
		[self recordStatements];
		XCTAssertFalse([self shouldEditRow:0 column:1], @"port %@", port);
		XCTAssertEqual(sheets.count, 1u);
		[self completeSheet:sheets[0] with:nil];

		XCTAssertEqual(self.statements.count, 0u, @"port %@: %@", port, self.statements);
		XCTAssertEqual(self.changes.count, 0u);
		XCTAssertEqual(self.alerts.count, 0u);
		XCTAssertEqualObjects([self serverValue:@"SELECT name FROM query_edit_test.items WHERE id = 1" port:port], @"one");
	}
}

@end
