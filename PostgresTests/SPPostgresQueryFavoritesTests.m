#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresQueryFavoriteManager.h"
#import "../Source/Postgres/SPPostgresQueryStore.h"
#import "../Source/Postgres/SPPostgresTextView.h"
#import "../Source/SPComboPopupButton.h"

// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPFavoritesTestReplacesKey = @"QueryFavoriteReplacesContent";
static NSString * const SPFavoritesTestMySQLFavoritesKey = @"queryFavorites";
static NSString * const SPFavoritesTestSuiteName = @"SPPostgresStage11Tests";
static const NSUInteger SPFavoritesTestPort = 55418;

/// The Query view's favorites and the favorites manager (Stage 11 Task 8): stored in a temporary SPPostgresQueryStore,
/// never in MySQL's queryFavorites preference. Preferences are written to a scratch suite (the controller's defaults);
/// SPTextView's own reads are pinned in the volatile argument domain. Sheets are on an offscreen window and ended here.
@interface SPPostgresQueryFavoritesTests : XCTestCase
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSUserDefaults *scratch;
@property (strong) SPPostgresQueryStore *store;
@property (copy) NSString *directory;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@property (strong) NSMutableArray<NSAlert *> *confirmations;
@property (assign) BOOL answer;
@property (strong) id mysqlFavorites;
/// The connections the tests opened, disconnected in tearDown (so they are not held until the controllers go)
@property (strong) NSMutableArray<PGPostgresConnection *> *connections;
@end

@implementation SPPostgresQueryFavoritesTests

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

- (SPPostgresQueryController *)newControllerWithStore:(SPPostgresQueryStore *)store
{
	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:SPFavoritesTestPort];
	if (connection) [self.connections addObject:connection];
	SPPostgresQueryController *query = [[SPPostgresQueryController alloc] initWithConnection:connection];
	query.defaults = self.scratch;
	query.favoritesStore = store;
	query.infoPaneAnimates = NO;
	return query;
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	[self overridePrefs:@{@"CustomQueryAutoIndent": @NO, @"CustomQueryAutoPairCharacters": @NO, @"CustomQueryAutoUppercaseKeywords": @NO,
						  @"CustomQueryAutoComplete": @NO, @"CustomQueryUpdateAutoHelp": @NO, @"CustomQueryHighlightCurrentQuery": @NO,
						  @"CustomQuerySoftIndent": @NO}];
	self.mysqlFavorites = [[NSUserDefaults standardUserDefaults] objectForKey:SPFavoritesTestMySQLFavoritesKey];

	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPFavoritesTestSuiteName];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPFavoritesTestSuiteName];
	[self.scratch setBool:NO forKey:SPFavoritesTestReplacesKey];

	self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
	self.store = [[SPPostgresQueryStore alloc] initWithFileURL:[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"PostgresQueryFavorites.plist"]]];

	self.connections = [NSMutableArray array];
	self.query = [self newControllerWithStore:self.store];
	self.alerts = [NSMutableArray array];
	self.confirmations = [NSMutableArray array];
	__weak SPPostgresQueryFavoritesTests *weakSelf = self;
	self.query.alertPresenter = ^(NSAlert *alert) { [weakSelf.alerts addObject:alert]; };
	self.query.confirmationPresenter = ^(NSAlert *alert, void (^completion)(BOOL confirmed)) {
		[weakSelf.confirmations addObject:alert];
		completion(weakSelf.answer);
	};

	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 695, 534) styleMask:NSWindowStyleMaskTitled
												backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
	[[self.window contentView] addSubview:[self.query view]];
	[[self.query view] setFrame:[[self.window contentView] bounds]];
	[self.window makeFirstResponder:self.query.editor];
}

- (void)tearDown
{
	[self.query.favoritesManager cancel:nil];
	if (self.query.favoriteNameSheet) [self.query.favoriteNameCancelButton performClick:nil];
	if (self.window.attachedSheet) [self.window endSheet:self.window.attachedSheet];
	[self.query invalidate];
	[[self.query view] removeFromSuperview];
	[self.window orderOut:nil];
	self.window = nil;
	self.query = nil;
	for (PGPostgresConnection *connection in self.connections) [connection disconnect];
	self.connections = nil;
	[[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPFavoritesTestSuiteName];
	self.scratch = nil;
	XCTAssertEqualObjects([[NSUserDefaults standardUserDefaults] objectForKey:SPFavoritesTestMySQLFavoritesKey], self.mysqlFavorites,
						  @"MySQL's queryFavorites preference is never written");
	[super tearDown];
}

#pragma mark - Helpers

- (SPPostgresTextView *)editor
{
	return (SPPostgresTextView *)self.query.editor;
}

- (NSMenu *)favoritesMenu
{
	return [self.query.favoritesButton menu];
}

/// As opening the menu does: MySQL's -validateMenuItem: (the Save item's title and the items' states).
- (void)updateMenu
{
	NSMenu *menu = [self favoritesMenu];
	[[menu delegate] menuNeedsUpdate:menu];
}

/// The favorites' items (after the hidden title, Save Query, Save All, Edit, a separator, the filter, a separator and
/// the "Global" header).
- (NSArray<NSMenuItem *> *)favoriteItems
{
	NSArray *items = [[self favoritesMenu] itemArray];
	return [items count] > 8 ? [items subarrayWithRange:NSMakeRange(8, [items count] - 8)] : @[];
}

- (NSArray<NSString *> *)visibleFavoriteTitles
{
	NSMutableArray *visible = [NSMutableArray array];
	for (NSMenuItem *item in [self favoriteItems]) if (![item isHidden]) [visible addObject:[item title]];
	return visible;
}

- (NSSearchField *)searchField
{
	NSView *view = [[[self favoritesMenu] itemAtIndex:5] view];
	for (NSView *subview in [view subviews]) {
		if ([subview isKindOfClass:[NSSearchField class]]) return (NSSearchField *)subview;
	}
	return nil;
}

/// What a click on the favorites pop-up's item at index does.
- (void)chooseFavoriteItemAtIndex:(NSInteger)index
{
	[[self favoritesMenu] performActionForItemAtIndex:index];
}

/// Types name into the open name sheet (as the field's change notification) and clicks Save.
- (void)nameAndSave:(NSString *)name
{
	XCTAssertNotNil(self.query.favoriteNameSheet);
	NSTextField *field = self.query.favoriteNameField;
	[field setStringValue:name];
	[[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:field];
	XCTAssertTrue([self.query.favoriteNameSaveButton isEnabled]);
	[self.query.favoriteNameSaveButton performClick:nil];
}

- (BOOL)setItems:(NSArray *)items
{
	NSError *error = nil;
	BOOL ok = [self.store setItems:items error:&error];
	XCTAssertTrue(ok, @"%@", error);
	return ok;
}

- (NSString *)asideFileWithPrefix:(NSString *)prefix
{
	for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directory error:NULL]) {
		if ([name hasPrefix:prefix]) return name;
	}
	return nil;
}

#pragma mark - Tests

- (void)testFavoritesMenu
{
	[self setItems:@[@{@"name": @"Count rows", @"query": @"SELECT count(*) FROM t"}, @{@"name": @"Now", @"query": @"SELECT now()"}]];

	NSArray<NSMenuItem *> *items = [[self favoritesMenu] itemArray];
	XCTAssertEqual([items count], 10u);
	XCTAssertEqualObjects([items[0] title], @"Query Favorites");
	XCTAssertTrue([items[0] isHidden]);

	XCTAssertEqualObjects([items[1] title], @"Save Query to Favorites");
	XCTAssertEqual([items[1] tag], 100000);
	XCTAssertEqualObjects([items[1] toolTip], @"Save current query, selection, or - if no selection or current query could be found - the entire content to Favorite.");
	XCTAssertEqual([items[1] keyEquivalentModifierMask], NSEventModifierFlagOption);
	XCTAssertFalse([items[1] isAlternate]);
	XCTAssertEqual([items[1] action], @selector(chooseQueryFavorite:));
	XCTAssertEqual([items[1] target], self.query);

	XCTAssertEqualObjects([items[2] title], @"Save All to Favorites");
	XCTAssertEqual([items[2] tag], 100001);
	XCTAssertEqualObjects([items[2] toolTip], @"Save editor content to Favorite. Press ⌥ to restrict for current query or selection.");
	XCTAssertTrue([items[2] isAlternate]);
	XCTAssertEqual([items[2] keyEquivalentModifierMask], 0u);
	XCTAssertEqual([items[2] action], @selector(chooseQueryFavorite:));

	XCTAssertEqualObjects([items[3] title], @"Edit Favorites...");
	XCTAssertEqual([items[3] action], @selector(chooseQueryFavorite:));
	XCTAssertTrue([items[4] isSeparatorItem]);
	XCTAssertNotNil([self searchField]);
	XCTAssertEqualObjects([[[self searchField] cell] placeholderString], @"Filter");
	XCTAssertTrue([items[6] isSeparatorItem]);

	XCTAssertEqualObjects([items[7] title], @"Global");
	XCTAssertEqual([items[7] tag], 200000);
	XCTAssertFalse([items[7] isEnabled]);
	XCTAssertEqualObjects([items[7] toolTip], @"Globally stored favorites");
	XCTAssertEqual([items[7] indentationLevel], 0);

	XCTAssertEqualObjects([items[8] title], @"Count rows");
	XCTAssertEqualObjects([items[8] toolTip], @"SELECT count(*) FROM t");
	XCTAssertEqual([items[8] indentationLevel], 1);
	XCTAssertEqual([items[8] action], @selector(chooseQueryFavorite:));
	XCTAssertEqualObjects([items[9] title], @"Now");
	XCTAssertEqualObjects([items[9] toolTip], @"SELECT now()");
	XCTAssertEqual([items[9] indentationLevel], 1);

	// Every tab's menu follows the store (another tab writing it too)
	SPPostgresQueryController *other = [self newControllerWithStore:self.store];
	XCTAssertEqual([[[other.favoritesButton menu] itemArray] count], 10u);
	[self setItems:@[@{@"name": @"Only", @"query": @"SELECT 'only'"}]];
	XCTAssertEqualObjects([[self favoriteItems] valueForKey:@"title"], @[@"Only"]);
	XCTAssertEqualObjects([[[other.favoritesButton menu] itemAtIndex:8] title], @"Only");
	XCTAssertEqual([[[other.favoritesButton menu] itemArray] count], 9u);
	[other invalidate];

	// No favorites: only the header
	[self setItems:@[]];
	XCTAssertEqual([[[self favoritesMenu] itemArray] count], 8u);
	XCTAssertEqualObjects([[[self favoritesMenu] itemAtIndex:7] title], @"Global");
}

- (void)testSaveQueryToFavorites
{
	[[self editor] setString:@"SELECT 1;\nSELECT 2;"];
	[[self editor] setSelectedRange:NSMakeRange(3, 0)];

	// The item's title as MySQL's -validateMenuItem:: the current query
	[self updateMenu];
	NSMenuItem *saveItem = [[self favoritesMenu] itemAtIndex:1];
	XCTAssertEqualObjects([saveItem title], @"Save Current Query to Favorites");
	XCTAssertTrue([saveItem isEnabled]);
	XCTAssertTrue([[[self favoritesMenu] itemAtIndex:2] isEnabled]);

	// It asks for a name; Save is enabled once there is one
	[self chooseFavoriteItemAtIndex:1];
	XCTAssertNotNil(self.query.favoriteNameSheet);
	XCTAssertEqual(self.window.attachedSheet, self.query.favoriteNameSheet);
	XCTAssertFalse([self.query.favoriteNameSaveButton isEnabled]);
	[self nameAndSave:@"First"];
	XCTAssertNil(self.query.favoriteNameSheet);
	XCTAssertNil(self.window.attachedSheet);
	NSString *current = [[[self editor] string] substringWithRange:[self.query currentQueryRange]];
	XCTAssertEqualObjects(self.store.items, (@[@{@"name": @"First", @"query": current}]));
	XCTAssertEqualObjects([[self favoriteItems] valueForKey:@"title"], @[@"First"]);

	// A selection: it is saved
	[[self editor] setSelectedRange:NSMakeRange(10, 8)];
	[self updateMenu];
	XCTAssertEqualObjects([saveItem title], @"Save Selection to Favorites");
	[self chooseFavoriteItemAtIndex:1];
	[self nameAndSave:@"Second"];
	XCTAssertEqualObjects(self.store.items, (@[@{@"name": @"First", @"query": current}, @{@"name": @"Second", @"query": @"SELECT 2"}]));

	// Cancel saves nothing
	[self chooseFavoriteItemAtIndex:1];
	[self.query.favoriteNameField setStringValue:@"Never"];
	[self.query.favoriteNameCancelButton performClick:nil];
	XCTAssertNil(self.window.attachedSheet);
	XCTAssertEqual([self.store.items count], 2u);

	// Save All: the whole text
	[self chooseFavoriteItemAtIndex:2];
	XCTAssertEqualObjects([self.query.favoriteNameField stringValue], @"", @"the name field starts empty");
	[self nameAndSave:@"All"];
	XCTAssertEqualObjects([self.store.items lastObject], (@{@"name": @"All", @"query": @"SELECT 1;\nSELECT 2;"}));

	// No current query (only a comment): MySQL's "Save All to Favorites" title, and the whole text is saved
	[[self editor] setString:@"-- just a note"];
	[[self editor] setSelectedRange:NSMakeRange(0, 0)];
	[self updateMenu];
	XCTAssertEqualObjects([saveItem title], @"Save All to Favorites");
	[self chooseFavoriteItemAtIndex:1];
	[self nameAndSave:@"Note"];
	XCTAssertEqualObjects([self.store.items lastObject], (@{@"name": @"Note", @"query": @"-- just a note"}));
	XCTAssertEqual([self.store.items count], 4u);

	// An empty editor: the items are disabled, and choosing one shows MySQL's alert and saves nothing
	[[self editor] setString:@""];
	[self updateMenu];
	XCTAssertFalse([saveItem isEnabled]);
	XCTAssertFalse([[[self favoritesMenu] itemAtIndex:2] isEnabled]);
	[self.query chooseQueryFavorite:saveItem];
	[self.query chooseQueryFavorite:[[self favoritesMenu] itemAtIndex:2]];
	XCTAssertNil(self.window.attachedSheet);
	XCTAssertEqual([self.alerts count], 2u);
	XCTAssertEqualObjects([self.alerts[0] messageText], @"Empty query");
	XCTAssertEqualObjects([self.alerts[0] informativeText], @"Cannot save an empty query.");
	XCTAssertEqual([self.store.items count], 4u);

	// Neither MySQL's preference (checked in tearDown) nor anything else was asked about
	XCTAssertEqual([self.confirmations count], 0u);
}

- (void)testChooseFavoriteInsertsOrReplaces
{
	[self setItems:@[@{@"name": @"One", @"query": @"SELECT 'one'"}, @{@"name": @"Now", @"query": @"SELECT now()"}]];

	// Inserted at the caret, undoably; the run title follows
	[[self editor] setString:@"SELECT 0;\n"];
	[[self editor] setSelectedRange:NSMakeRange(10, 0)];
	XCTAssertEqualObjects([self.query.runButton title], @"Run Previous");
	[self chooseFavoriteItemAtIndex:9];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 0;\nSELECT now()");
	XCTAssertEqualObjects([self.query.runButton title], @"Run Current");
	[[[self editor] undoManager] undo];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 0;\n");

	// The header does nothing
	[self.query chooseQueryFavorite:[[self favoritesMenu] itemAtIndex:7]];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 0;\n");

	// Favorite Replaces Editor Content: it replaces the text
	[self.scratch setBool:YES forKey:SPFavoritesTestReplacesKey];
	[self chooseFavoriteItemAtIndex:8];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 'one'");
	[[[self editor] undoManager] undo];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 0;\n");
}

- (void)testManagerEditsAndSaves
{
	[self setItems:@[@{@"name": @"A", @"query": @"SELECT 'a'"}]];

	// Edit Favorites... opens the manager on the store's favorites
	[self chooseFavoriteItemAtIndex:3];
	SPPostgresQueryFavoriteManager *manager = self.query.favoritesManager;
	XCTAssertNotNil(manager);
	XCTAssertEqual(self.window.attachedSheet, manager.sheet);
	XCTAssertEqual([manager.favoritesTable numberOfRows], 1);
	XCTAssertEqual([manager.favoritesTable selectedRow], 0);
	XCTAssertEqualObjects([manager.nameField stringValue], @"A");
	XCTAssertEqualObjects([manager.queryView string], @"SELECT 'a'");
	XCTAssertTrue([manager.queryView isKindOfClass:[SPPostgresTextView class]]);
	XCTAssertEqualObjects([manager.saveButton title], @"Save");
	XCTAssertEqualObjects([manager.cancelButton title], @"Cancel");

	// Add: "New Favorite", selected; its name and query are set
	[manager.addButton performClick:nil];
	XCTAssertEqual([manager.favoritesTable numberOfRows], 2);
	XCTAssertEqual([manager.favoritesTable selectedRow], 1);
	XCTAssertEqualObjects([manager.nameField stringValue], @"New Favorite");
	XCTAssertEqualObjects([manager.queryView string], @"");
	[manager.nameField setStringValue:@"B"];
	[manager.queryView setString:@"SELECT 'b'"];

	// Duplicate: "B Copy", after it
	[manager.duplicateButton performClick:nil];
	XCTAssertEqual([manager.favoritesTable numberOfRows], 3);
	XCTAssertEqual([manager.favoritesTable selectedRow], 2);
	XCTAssertEqualObjects([manager.nameField stringValue], @"B Copy");
	XCTAssertEqualObjects([manager.queryView string], @"SELECT 'b'");

	// Remove the original: asked first (Cancel keeps it)
	[manager.favoritesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
	XCTAssertEqualObjects([manager.nameField stringValue], @"B");
	self.answer = NO;
	[manager.removeButton performClick:nil];
	XCTAssertEqual([self.confirmations count], 1u);
	XCTAssertEqualObjects([self.confirmations[0] messageText], @"Remove selected query favorites?");
	XCTAssertEqual([manager.favoritesTable numberOfRows], 3);
	self.answer = YES;
	[manager.removeButton performClick:nil];
	XCTAssertEqual([manager.favoritesTable numberOfRows], 2);
	XCTAssertEqualObjects(manager.favorites, (@[@{@"name": @"A", @"query": @"SELECT 'a'"}, @{@"name": @"B Copy", @"query": @"SELECT 'b'"}]));

	// Nothing is written before Save
	XCTAssertEqualObjects(self.store.items, (@[@{@"name": @"A", @"query": @"SELECT 'a'"}]));

	// No selection: remove and duplicate are disabled, the fields too
	[manager.favoritesTable deselectAll:nil];
	XCTAssertFalse([manager.removeButton isEnabled]);
	XCTAssertFalse([manager.duplicateButton isEnabled]);
	XCTAssertFalse([manager.nameField isEnabled]);
	[manager.favoritesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	XCTAssertTrue([manager.removeButton isEnabled]);
	XCTAssertTrue([manager.duplicateButton isEnabled]);

	// Save writes the store (the menu follows) and ends the sheet
	[manager.saveButton performClick:nil];
	XCTAssertNil(self.window.attachedSheet);
	XCTAssertNil(self.query.favoritesManager);
	XCTAssertEqualObjects(self.store.items, (@[@{@"name": @"A", @"query": @"SELECT 'a'"}, @{@"name": @"B Copy", @"query": @"SELECT 'b'"}]));
	XCTAssertEqualObjects([[self favoriteItems] valueForKey:@"title"], (@[@"A", @"B Copy"]));
	XCTAssertEqual([self.alerts count], 0u);

	// Cancel writes nothing
	[self chooseFavoriteItemAtIndex:3];
	manager = self.query.favoritesManager;
	[manager.addButton performClick:nil];
	[manager.nameField setStringValue:@"Discarded"];
	[manager.cancelButton performClick:nil];
	XCTAssertNil(self.window.attachedSheet);
	XCTAssertNil(self.query.favoritesManager);
	XCTAssertEqualObjects(self.store.items, (@[@{@"name": @"A", @"query": @"SELECT 'a'"}, @{@"name": @"B Copy", @"query": @"SELECT 'b'"}]));
}

- (void)testSearchFiltersFavorites
{
	[self setItems:@[@{@"name": @"Count rows", @"query": @"SELECT 1"}, @{@"name": @"Now", @"query": @"SELECT now()"},
					 @{@"name": @"COUNT (2)", @"query": @"SELECT 2"}]];

	NSSearchField *search = [self searchField];
	XCTAssertNotNil(search);
	XCTAssertEqual([search target], self.query);
	XCTAssertEqual([search action], @selector(filterQueryFavorites:));

	[search setStringValue:@"count"];
	[NSApp sendAction:[search action] to:[search target] from:search];
	XCTAssertEqual([[self favoriteItems] count], 3u, @"hidden items stay in the menu");
	XCTAssertEqualObjects([self visibleFavoriteTitles], (@[@"Count rows", @"COUNT (2)"]));
	XCTAssertFalse([[[self favoritesMenu] itemAtIndex:7] isHidden], @"the header stays");

	// A search that is not a valid pattern is matched as text
	[search setStringValue:@"(2"];
	[NSApp sendAction:[search action] to:[search target] from:search];
	XCTAssertEqualObjects([self visibleFavoriteTitles], @[@"COUNT (2)"]);

	// The filter is reapplied when the favorites change
	[self setItems:@[@{@"name": @"Four (2)", @"query": @"SELECT 4"}, @{@"name": @"Five", @"query": @"SELECT 5"}]];
	XCTAssertEqualObjects([self visibleFavoriteTitles], @[@"Four (2)"]);

	// Choosing a filtered favorite inserts that favorite
	[[self editor] setString:@""];
	[self chooseFavoriteItemAtIndex:8];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 4");

	// Cleared: everything shows again
	[search setStringValue:@""];
	[NSApp sendAction:[search action] to:[search target] from:search];
	XCTAssertEqualObjects([self visibleFavoriteTitles], (@[@"Four (2)", @"Five"]));
}

/// Ruling 8: a user-confirmed save over an unreadable favorites file warns first, and only on Continue moves the file
/// aside (never deleted) and writes.
- (void)testCorruptFavoritesStore
{
	NSData *garbage = [@"garbage" dataUsingEncoding:NSUTF8StringEncoding];
	NSURL *badURL = [NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"Bad.plist"]];
	XCTAssertTrue([garbage writeToURL:badURL atomically:YES]);
	SPPostgresQueryStore *bad = [[SPPostgresQueryStore alloc] initWithFileURL:badURL];
	self.query.favoritesStore = bad;
	XCTAssertEqual([[self favoriteItems] count], 0u);

	// The name sheet's Save: asked; Cancel leaves the file as it is
	[[self editor] setString:@"SELECT 1"];
	self.answer = NO;
	[self chooseFavoriteItemAtIndex:2];
	[self nameAndSave:@"One"];
	XCTAssertEqual([self.confirmations count], 1u);
	XCTAssertEqualObjects([self.confirmations[0] messageText], @"The query favorites file can't be read.");
	XCTAssertTrue([[self.confirmations[0] informativeText] containsString:@"Bad.plist"], @"%@", [self.confirmations[0] informativeText]);
	XCTAssertEqualObjects([[self.confirmations[0] buttons][0] title], @"Continue");
	XCTAssertEqualObjects([[self.confirmations[0] buttons][1] title], @"Cancel");
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:badURL], garbage);
	XCTAssertNil([self asideFileWithPrefix:@"Bad.unreadable-"]);

	// Continue: moved aside, then written
	self.answer = YES;
	[self chooseFavoriteItemAtIndex:2];
	[self nameAndSave:@"One"];
	XCTAssertEqual([self.confirmations count], 2u);
	XCTAssertNil(bad.lastLoadError);
	XCTAssertEqualObjects(bad.items, (@[@{@"name": @"One", @"query": @"SELECT 1"}]));
	NSString *aside = [self asideFileWithPrefix:@"Bad.unreadable-"];
	XCTAssertNotNil(aside);
	XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:aside]], garbage);
	XCTAssertEqualObjects([[self favoriteItems] valueForKey:@"title"], @[@"One"]);
	XCTAssertEqual([self.alerts count], 0u);

	// The manager's Save, on another unreadable file: asked; Cancel keeps the sheet open and the file; Continue writes
	NSURL *badURL2 = [NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"Bad2.plist"]];
	XCTAssertTrue([garbage writeToURL:badURL2 atomically:YES]);
	SPPostgresQueryStore *bad2 = [[SPPostgresQueryStore alloc] initWithFileURL:badURL2];
	self.query.favoritesStore = bad2;
	[self chooseFavoriteItemAtIndex:3];
	SPPostgresQueryFavoriteManager *manager = self.query.favoritesManager;
	XCTAssertEqual([manager.favoritesTable numberOfRows], 0);
	[manager.addButton performClick:nil];
	[manager.nameField setStringValue:@"Kept"];
	[manager.queryView setString:@"SELECT 'kept'"];
	self.answer = NO;
	[manager.saveButton performClick:nil];
	XCTAssertEqual([self.confirmations count], 3u);
	XCTAssertEqualObjects([self.confirmations[2] messageText], @"The query favorites file can't be read.");
	XCTAssertEqual(self.window.attachedSheet, manager.sheet, @"still open");
	XCTAssertEqualObjects([NSData dataWithContentsOfURL:badURL2], garbage);
	self.answer = YES;
	[manager.saveButton performClick:nil];
	XCTAssertNil(self.window.attachedSheet);
	XCTAssertEqualObjects(bad2.items, (@[@{@"name": @"Kept", @"query": @"SELECT 'kept'"}]));
	XCTAssertNotNil([self asideFileWithPrefix:@"Bad2.unreadable-"]);

	// A readable store is written without asking
	self.query.favoritesStore = self.store;
	[self chooseFavoriteItemAtIndex:2];
	[self nameAndSave:@"Plain"];
	XCTAssertEqual([self.confirmations count], 4u, @"no new question");
	XCTAssertEqualObjects(self.store.items, (@[@{@"name": @"Plain", @"query": @"SELECT 1"}]));
}

@end
