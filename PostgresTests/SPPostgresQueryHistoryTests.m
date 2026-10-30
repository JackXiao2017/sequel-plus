#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresQueryStore.h"
#import "../Source/Postgres/SPPostgresTextView.h"
#import "../Source/SPComboPopupButton.h"

/// The controller's test seam: called instead of NSBeep() by the history's Previous / Next.
@interface SPPostgresQueryController (HistoryTesting)
- (void)setBeepHook:(void (^)(void))hook;
@end

// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPHistoryTestMaxItemsKey = @"CustomQueryMaxHistoryItems";
static NSString * const SPHistoryTestReplacesKey = @"QueryHistoryReplacesContent";
static NSString * const SPHistoryTestMySQLHistoryKey = @"queryHistory";
static NSString * const SPHistoryTestSuiteName = @"SPPostgresStage11Tests";
static const NSUInteger SPHistoryTestPort = 55418;

/// The Query view's history (Stage 11 Task 7): stored in a temporary SPPostgresQueryStore, never in MySQL's
/// queryHistory preference. Preferences are written to a scratch suite (the controller's defaults); SPTextView's own
/// reads are pinned in the volatile argument domain.
@interface SPPostgresQueryHistoryTests : XCTestCase
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSUserDefaults *scratch;
@property (strong) SPPostgresQueryStore *store;
@property (strong) NSPasteboard *pasteboard;
@property (copy) NSString *directory;
@property (assign) NSUInteger beeps;
@end

@implementation SPPostgresQueryHistoryTests

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
						  @"CustomQueryAutoComplete": @NO, @"CustomQueryUpdateAutoHelp": @NO, @"CustomQueryHighlightCurrentQuery": @NO,
						  @"CustomQuerySoftIndent": @NO}];

	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPHistoryTestSuiteName];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPHistoryTestSuiteName];
	[self.scratch setInteger:3 forKey:SPHistoryTestMaxItemsKey];
	[self.scratch setBool:NO forKey:SPHistoryTestReplacesKey];

	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
	self.store = [[SPPostgresQueryStore alloc] initWithFileURL:[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"PostgresQueryHistory.plist"]]];
	self.pasteboard = [NSPasteboard pasteboardWithUniqueName];

	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:SPHistoryTestPort];
	self.query = [[SPPostgresQueryController alloc] initWithConnection:connection];
	self.query.defaults = self.scratch;
	self.query.historyStore = self.store;
	self.query.pasteboard = self.pasteboard;
	self.query.infoPaneAnimates = NO;
	__weak SPPostgresQueryHistoryTests *weakSelf = self;
	[self.query setBeepHook:^{ weakSelf.beeps++; }];

	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 695, 534) styleMask:NSWindowStyleMaskTitled
												backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
	[[self.window contentView] addSubview:[self.query view]];
	[[self.query view] setFrame:[[self.window contentView] bounds]];
	[self.window makeFirstResponder:self.query.editor];
}

- (void)tearDown
{
	[self.query invalidate];
	[[self.query view] removeFromSuperview];
	[self.window close];
	self.window = nil;
	self.query = nil;
	[self.pasteboard releaseGlobally];
	self.pasteboard = nil;
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPHistoryTestSuiteName];
	self.scratch = nil;
	[super tearDown];
}

#pragma mark - Helpers

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (SPPostgresTextView *)editor
{
	return (SPPostgresTextView *)self.query.editor;
}

/// Runs every statement of text (the inline runner: the run has finished when this returns).
- (void)runAll:(NSString *)text
{
	[[self editor] setString:text];
	[self.query runAllQueries:nil];
}

- (NSMenu *)historyMenu
{
	return [self.query.historyButton menu];
}

/// The entries' items (after the hidden title, Copy, Save, Clear, a separator, the search field and a separator).
- (NSArray<NSMenuItem *> *)entryItems
{
	NSArray *items = [[self historyMenu] itemArray];
	return [items count] > 7 ? [items subarrayWithRange:NSMakeRange(7, [items count] - 7)] : @[];
}

- (NSSearchField *)searchField
{
	NSView *view = [[[self historyMenu] itemAtIndex:5] view];
	for (NSView *subview in [view subviews]) {
		if ([subview isKindOfClass:[NSSearchField class]]) return (NSSearchField *)subview;
	}
	return nil;
}

/// What a click on the history pop-up's item at index does.
- (void)chooseHistoryItemAtIndex:(NSInteger)index
{
	[[self historyMenu] performActionForItemAtIndex:index];
}

- (NSMenuItem *)gearItem:(NSString *)title
{
	for (NSMenuItem *item in [[self.query.gearButton menu] itemArray]) {
		if ([[item title] isEqualToString:title]) return item;
	}
	XCTFail(@"no gear item %@", title);
	return nil;
}

- (void)chooseGearItem:(NSString *)title
{
	NSMenuItem *item = [self gearItem:title];
	[[item menu] performActionForItemAtIndex:[[item menu] indexOfItem:item]];
}

#pragma mark - Tests

- (void)testRunAddsHistoryEntry
{
	id mysqlHistory = [[NSUserDefaults standardUserDefaults] objectForKey:SPHistoryTestMySQLHistoryKey];

	[self runAll:@"SELECT 1; SELECT 2"];
	XCTAssertEqualObjects(self.query.lastRunQueryText, @"SELECT 1;\nSELECT 2");
	XCTAssertEqualObjects(self.store.items, @[@"SELECT 1;\nSELECT 2"]);

	// Again: not duplicated
	[self runAll:@"SELECT 1; SELECT 2"];
	XCTAssertEqualObjects(self.store.items, @[@"SELECT 1;\nSELECT 2"]);

	// Most recent first; an older entry run again moves to the front
	[self runAll:@"SELECT 3"];
	[self runAll:@"SELECT 1; SELECT 2"];
	XCTAssertEqualObjects(self.store.items, (@[@"SELECT 1;\nSELECT 2", @"SELECT 3"]));

	// Capped at CustomQueryMaxHistoryItems (3)
	for (NSString *text in @[@"SELECT 4", @"SELECT 5", @"SELECT 6", @"SELECT 7", @"SELECT 8"]) [self runAll:text];
	XCTAssertEqualObjects(self.store.items, (@[@"SELECT 8", @"SELECT 7", @"SELECT 6"]));

	// A failing statement was sent, so it is recorded too (as MySQL's usedQuery)
	[self runAll:@"SELECT * FROM no_such_table_here"];
	XCTAssertEqualObjects(self.store.items[0], @"SELECT * FROM no_such_table_here");

	// The menu follows the store
	NSArray *titles = [[self entryItems] valueForKey:@"title"];
	XCTAssertEqualObjects(titles, (@[@"SELECT * FROM no_such_table_here", @"SELECT 8", @"SELECT 7"]));

	// MySQL's history preference is untouched
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] objectForKey:SPHistoryTestMySQLHistoryKey], mysqlHistory);
}

- (void)testHistoryMenu
{
	NSString *longQuery = [@"SELECT " stringByPaddingToLength:300 withString:@"x" startingAtIndex:0];
	NSError *error = nil;
	XCTAssertTrue(([self.store setItems:@[@"SELECT 'one'", longQuery, @"SELECT 'two'"] error:&error]), @"%@", error);

	NSArray<NSMenuItem *> *items = [[self historyMenu] itemArray];
	XCTAssertEqual([items count], 10u);
	XCTAssertEqualObjects([items[0] title], @"Query History");
	XCTAssertTrue([items[0] isHidden]);

	XCTAssertEqualObjects([items[1] title], @"Copy History");
	XCTAssertEqual([items[1] tag], 300000);
	XCTAssertEqualObjects([items[1] toolTip], @"Copy all history items onto the clipboard.");
	XCTAssertEqual([items[1] action], @selector(copyQueryHistory:));
	XCTAssertEqual([items[1] target], self.query);

	XCTAssertEqualObjects([items[2] title], @"Save History…");
	XCTAssertEqual([items[2] tag], 300001);
	XCTAssertEqualObjects([items[2] toolTip], @"Save all history items to file. Press ⌥ to copy all history items onto the clipboard.");
	XCTAssertTrue([items[2] isAlternate]);
	XCTAssertEqual([items[2] action], @selector(saveQueryHistory:));

	// Postgres tabs are untitled, so MySQL's title for an untitled document
	XCTAssertEqualObjects([items[3] title], @"Clear Global History");
	XCTAssertEqual([items[3] tag], 300002);
	XCTAssertEqualObjects([items[3] toolTip], @"Clear the global history list");
	XCTAssertEqual([items[3] action], @selector(clearQueryHistory:));

	XCTAssertTrue([items[4] isSeparatorItem]);
	XCTAssertNotNil([self searchField]);
	XCTAssertEqualObjects([[[self searchField] cell] placeholderString], @"Filter");
	XCTAssertTrue([items[6] isSeparatorItem]);

	// The entries: titles cut to 64 characters, tooltips to 256 (as MySQL's)
	XCTAssertEqualObjects([items[7] title], @"SELECT 'one'");
	XCTAssertEqualObjects([items[7] toolTip], @"SELECT 'one'");
	XCTAssertEqualObjects([items[8] title], ([NSString stringWithFormat:@"%@…", [longQuery substringToIndex:63]]));
	XCTAssertEqualObjects([items[8] toolTip], ([NSString stringWithFormat:@"%@…", [longQuery substringToIndex:255]]));
	XCTAssertEqualObjects([items[9] title], @"SELECT 'two'");
	for (NSUInteger i = 1; i < 4; i++) XCTAssertTrue([items[i] isEnabled], @"%@", [items[i] title]);

	// Choosing an entry inserts it at the caret, undoably
	[[self editor] setString:@"SELECT 0;\n"];
	[[self editor] setSelectedRange:NSMakeRange(10, 0)];
	XCTAssertEqualObjects([self.query.runButton title], @"Run Previous");
	[self chooseHistoryItemAtIndex:9];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 0;\nSELECT 'two'");
	XCTAssertEqualObjects([self.query.runButton title], @"Run Current", @"the run title follows the inserted text");
	[[[self editor] undoManager] undo];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 0;\n");

	// History Replaces Editor Content: it replaces the text
	[self.scratch setBool:YES forKey:SPHistoryTestReplacesKey];
	[self chooseHistoryItemAtIndex:7];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'one'");

	// Copy History: the entries joined with ";\n", on the injected pasteboard
	[self chooseHistoryItemAtIndex:1];
	XCTAssertEqualObjects([self.pasteboard stringForType:NSPasteboardTypeString], ([NSString stringWithFormat:@"SELECT 'one';\n%@;\nSELECT 'two'", longQuery]));

	// Clear History asks first: Cancel keeps it, Clear empties the store
	__block NSAlert *asked = nil;
	__block BOOL answer = NO;
	self.query.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL confirmed)) {
		asked = alert;
		completion(answer);
	};
	[self chooseHistoryItemAtIndex:3];
	XCTAssertEqualObjects([asked messageText], @"Clear History?");
	XCTAssertEqualObjects([asked informativeText], @"Are you sure you want to clear the global history list? This action cannot be undone.");
	XCTAssertEqual([self.store.items count], 3u);
	answer = YES;
	[self chooseHistoryItemAtIndex:3];
	XCTAssertEqualObjects(self.store.items, @[]);
	XCTAssertEqual([[self entryItems] count], 0u);
	for (NSUInteger i = 1; i < 4; i++) XCTAssertFalse([[[self historyMenu] itemAtIndex:i] isEnabled], @"nothing to copy, save or clear");

	// Hidden when CustomQueryMaxHistoryItems is 0, following defaults
	XCTAssertFalse([self.query.historyButton isHidden]);
	[self.scratch setInteger:0 forKey:SPHistoryTestMaxItemsKey];
	XCTAssertTrue([self spinUntil:^BOOL{ return [self.query.historyButton isHidden]; } timeout:2]);
	[self.scratch setInteger:5 forKey:SPHistoryTestMaxItemsKey];
	XCTAssertTrue([self spinUntil:^BOOL{ return ![self.query.historyButton isHidden]; } timeout:2]);
}

- (void)testCorruptHistoryStore
{
	NSURL *badURL = [NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"Bad.plist"]];
	NSData *garbage = [@"garbage" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertTrue([garbage writeToURL:badURL atomically:YES]);
	NSMutableArray<NSAlert *> *shown = [NSMutableArray array];
	self.query.alertPresenter = ^(NSAlert *alert) { [shown addObject:alert]; };
	self.query.historyStore = [[SPPostgresQueryStore alloc] initWithFileURL:badURL];
	XCTAssertEqual([[self entryItems] count], 0u);

	// Recording a run refuses (the file is left as it is) and is reported once
	[self runAll:@"SELECT 1"];
	[self runAll:@"SELECT 2"];
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:badURL], garbage);
	XCTAssertEqual([shown count], 1u, @"a failed save is reported, once");

	// Cancelled: nothing changes
	__block BOOL answer = NO;
	self.query.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL confirmed)) { completion(answer); };
	[self.query clearQueryHistory:nil];
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:badURL], garbage);

	// A confirmed Clear replaces it, moving the unreadable file aside
	answer = YES;
	[self.query clearQueryHistory:nil];
	XCTAssertEqual([shown count], 1u, @"no error");
	XCTAssertNil(self.query.historyStore.lastLoadError);
	XCTAssertEqualObjects(self.query.historyStore.items, @[]);
	NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL];
	NSString *aside = nil;
	for (NSString *name in names) if ([name hasPrefix:@"Bad.unreadable-"]) aside = name;
	XCTAssertNotNil(aside, @"%@", names);
	XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:aside]], garbage);

	// The history works again
	[self runAll:@"SELECT 3"];
	XCTAssertEqualObjects(self.query.historyStore.items, @[@"SELECT 3"]);
	XCTAssertEqualObjects([[self entryItems] valueForKey:@"title"], @[@"SELECT 3"]);
	XCTAssertTrue([[[self historyMenu] itemAtIndex:3] isEnabled]);
}

- (void)testSearchFiltersHistory
{
	NSError *error = nil;
	XCTAssertTrue(([self.store setItems:@[@"SELECT 'one'", @"SELECT 'TWO'", @"SELECT 'three'", @"SELECT 'two (2)'"] error:&error]), @"%@", error);

	NSSearchField *search = [self searchField];
	XCTAssertNotNil(search);
	XCTAssertEqual([search target], self.query);
	XCTAssertEqual([search action], @selector(filterQueryHistory:));

	[search setStringValue:@"two"];
	[NSApp sendAction:[search action] to:[search target] from:search];
	NSArray<NSMenuItem *> *entries = [self entryItems];
	XCTAssertEqual([entries count], 4u, @"hidden items stay in the menu");
	NSMutableArray *visible = [NSMutableArray array];
	for (NSMenuItem *item in entries) if (![item isHidden]) [visible addObject:[item title]];
	XCTAssertEqualObjects(visible, (@[@"SELECT 'TWO'", @"SELECT 'two (2)'"]));

	// A search that is not a valid pattern is matched as text
	[search setStringValue:@"(2"];
	[NSApp sendAction:[search action] to:[search target] from:search];
	[visible removeAllObjects];
	for (NSMenuItem *item in [self entryItems]) if (![item isHidden]) [visible addObject:[item title]];
	XCTAssertEqualObjects(visible, (@[@"SELECT 'two (2)'"]));

	// The filter is reapplied when the history changes
	XCTAssertTrue(([self.store setItems:@[@"SELECT 'four (2)'", @"SELECT 'five'"] error:&error]), @"%@", error);
	[visible removeAllObjects];
	for (NSMenuItem *item in [self entryItems]) if (![item isHidden]) [visible addObject:[item title]];
	XCTAssertEqualObjects(visible, (@[@"SELECT 'four (2)'"]));

	// Choosing a filtered entry inserts that entry
	[[self editor] setString:@""];
	[self chooseHistoryItemAtIndex:7];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'four (2)'");

	// Cleared: everything shows again
	[search setStringValue:@""];
	[NSApp sendAction:[search action] to:[search target] from:search];
	for (NSMenuItem *item in [self entryItems]) XCTAssertFalse([item isHidden]);
}

- (void)testPreviousNextFromHistory
{
	NSError *error = nil;
	XCTAssertTrue(([self.store setItems:@[@"SELECT 'newest'", @"SELECT 'older'", @"SELECT 'oldest'"] error:&error]), @"%@", error);
	[[self editor] setString:@"-- x\n"];
	[[self editor] setSelectedRange:NSMakeRange(5, 0)];

	// ⌃↑: the newest entry, selected; again: the next one, replacing it
	[self chooseGearItem:@"Previous Query from History"];
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'newest'");
	XCTAssertTrue(NSEqualRanges([[self editor] selectedRange], NSMakeRange(5, 15)));
	XCTAssertEqualObjects([self.query.runButton title], @"Run Selection", @"the run title follows the inserted text");
	[self chooseGearItem:@"Previous Query from History"];
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'older'");
	[self chooseGearItem:@"Previous Query from History"];
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'oldest'");
	XCTAssertEqual(self.beeps, 0u);

	// Past the oldest: a beep, the text unchanged
	[self chooseGearItem:@"Previous Query from History"];
	XCTAssertEqual(self.beeps, 1u);
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'oldest'");

	// ⌃↓ steps back, to the newest, then beeps
	[self chooseGearItem:@"Next Query from History"];
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'older'");
	[self chooseGearItem:@"Next Query from History"];
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'newest'");
	[self chooseGearItem:@"Next Query from History"];
	XCTAssertEqual(self.beeps, 2u);
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'newest'");

	// Undoable (in a test every step is in the same event, so one undo takes them all back)
	[[[self editor] undoManager] undo];
	XCTAssertEqualObjects([[self editor] string], @"-- x\n");
	[[[self editor] undoManager] redo];
	XCTAssertEqualObjects([[self editor] string], @"-- x\nSELECT 'newest'");

	// Moving the caret starts again from the newest
	[[self editor] setString:@""];
	[[self editor] setSelectedRange:NSMakeRange(0, 0)];
	[self chooseGearItem:@"Previous Query from History"];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'newest'");

	// An empty history: ⌃↓ / ⌃↑ beep
	XCTAssertTrue([self.store setItems:@[] error:&error], @"%@", error);
	[[self editor] setSelectedRange:NSMakeRange(0, 0)];
	self.beeps = 0;
	[self chooseGearItem:@"Previous Query from History"];
	[self chooseGearItem:@"Next Query from History"];
	XCTAssertEqual(self.beeps, 2u);
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'newest'");
}

- (void)testSaveHistoryWritesFile
{
	NSError *error = nil;
	XCTAssertTrue(([self.store setItems:@[@"SELECT 'é'", @"SELECT 1;\nSELECT 2"] error:&error]), @"%@", error);

	NSString *path = [self.directory stringByAppendingPathComponent:@"saved.sql"];
	__block NSString *suggested = nil;
	self.query.savePathProvider = ^NSString *(NSString *suggestedName) {
		suggested = suggestedName;
		return path;
	};
	[self chooseHistoryItemAtIndex:2];
	XCTAssertEqualObjects(suggested, @"history.sql");
	XCTAssertEqualObjects([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL], @"SELECT 'é';\nSELECT 1;\nSELECT 2");

	// Cancelled (no path): nothing is written
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	self.query.savePathProvider = ^NSString *(NSString *suggestedName) { return nil; };
	[self.query saveQueryHistory:nil];
	XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);

	// A failed write is reported
	__block NSAlert *shown = nil;
	self.query.alertPresenter = ^(NSAlert *alert) { shown = alert; };
	self.query.savePathProvider = ^NSString *(NSString *suggestedName) { return @"/nonexistent-dir-for-sp-tests/history.sql"; };
	[self.query saveQueryHistory:nil];
	XCTAssertNotNil(shown);
}

@end
