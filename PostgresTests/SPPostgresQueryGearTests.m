#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresTextView.h"
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/SPComboPopupButton.h"

// The help classes (Source/Postgres/SPPostgresHelp.h, which imports SPHelpViewerController.h; not imported here)
@interface SPPostgresHelpDataSource : NSObject
- (instancetype)initWithServerMajorVersion:(NSString *)major;
+ (NSString *)documentationPathForKeyword:(NSString *)keyword;
+ (NSString *)majorVersionFromServerVersion:(NSString *)serverVersion;
- (NSString *)HTMLHelpContentsForSearchString:(NSString *)searchString autoHelp:(BOOL)autoHelp;
@end

// MySQL's preference keys (Source/SPConstants.m; the header is not ARC-clean)
static NSString * const SPGearTestAutoIndentKey = @"CustomQueryAutoIndent";
static NSString * const SPGearTestAutoPairKey = @"CustomQueryAutoPairCharacters";
static NSString * const SPGearTestAutoUppercaseKey = @"CustomQueryAutoUppercaseKeywords";
static NSString * const SPGearTestAutoCompleteKey = @"CustomQueryAutoComplete";
static NSString * const SPGearTestAutoHelpKey = @"CustomQueryUpdateAutoHelp";
static NSString * const SPGearTestHistoryReplacesKey = @"QueryHistoryReplacesContent";
static NSString * const SPGearTestFavoriteReplacesKey = @"QueryFavoriteReplacesContent";
static NSString * const SPGearTestSoftIndentKey = @"CustomQuerySoftIndent";
static NSString * const SPGearTestSoftIndentWidthKey = @"CustomQuerySoftIndentWidth";
static NSString * const SPGearTestAutoHelpDelayKey = @"CustomQueryAutoHelpDelay";
static NSString * const SPGearTestHighlightQueryKey = @"CustomQueryHighlightCurrentQuery";
static NSString * const SPGearTestSuiteName = @"SPPostgresStage11Tests";
static const NSUInteger SPGearTestPort = 55418;

/// The Query view's gear menu (Stage 11 Task 6) and Update Help while typing (the tab's PostgreSQL help window). The
/// gear writes its preferences to a scratch suite (the controller's defaults); SPTextView's own reads are pinned in
/// the volatile argument domain.
@interface SPPostgresQueryGearTests : XCTestCase
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSUserDefaults *scratch;
// A connected tab (the help test)
@property (strong) SPWindowController *windowController;
@property (strong) SPPostgresDocument *document;
@end

@implementation SPPostgresQueryGearTests

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

/// Removes keys from the argument domain for this test, so the scratch suite's values are read (the argument domain is
/// in every NSUserDefaults' search list).
- (void)unpinPrefs:(NSArray<NSString *> *)keys
{
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSDictionary *original = [prefs volatileDomainForName:NSArgumentDomain] ?: @{};
	NSMutableDictionary *domain = [original mutableCopy];
	[domain removeObjectsForKeys:keys];
	[prefs removeVolatileDomainForName:NSArgumentDomain];
	[prefs setVolatileDomain:domain forName:NSArgumentDomain];
	[self addTeardownBlock:^{
		[prefs removeVolatileDomainForName:NSArgumentDomain];
		[prefs setVolatileDomain:original forName:NSArgumentDomain];
	}];
}

/// What the gear wrote to the scratch suite for key (its own domain, whatever the argument domain pins), or nil.
- (id)scratchValue:(NSString *)key
{
	return [[NSUserDefaults standardUserDefaults] persistentDomainForName:SPGearTestSuiteName][key];
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	[self overridePrefs:@{SPGearTestAutoIndentKey: @NO, SPGearTestAutoPairKey: @NO, SPGearTestAutoUppercaseKey: @NO,
						  SPGearTestAutoCompleteKey: @NO, SPGearTestAutoHelpKey: @NO, SPGearTestHighlightQueryKey: @NO,
						  SPGearTestSoftIndentKey: @NO, SPGearTestAutoHelpDelayKey: @1000}];

	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPGearTestSuiteName];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPGearTestSuiteName];

	self.query = [[SPPostgresQueryController alloc] initWithConnection:nil];
	self.query.defaults = self.scratch;
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 695, 534) styleMask:NSWindowStyleMaskTitled
												backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;
	[[self.window contentView] addSubview:[self.query view]];
	[[self.query view] setFrame:[[self.window contentView] bounds]];
	[self.window makeFirstResponder:self.query.editor];
}

- (void)tearDown
{
	if (self.document) {
		// Any help window a test opened
		[[self.document.helpViewerController window] orderOut:nil];
		NSWindow *window = [self.windowController window];
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		NSTabView *tabView = [self.windowController valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
		self.document = nil;
		self.windowController = nil;
	}
	[self.query invalidate];
	[[self.query view] removeFromSuperview];
	[self.window close];
	self.window = nil;
	self.query = nil;
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPGearTestSuiteName];
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

/// The saved (persistent) standard preference for key, NSNull when there is none.
- (id)savedPreference:(NSString *)key
{
	NSDictionary *domain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
	return domain[key] ?: [NSNull null];
}

- (SPPostgresTextView *)editor
{
	return (SPPostgresTextView *)self.query.editor;
}

- (NSMenuItem *)gearItem:(NSString *)title
{
	for (NSMenuItem *item in [[self.query.gearButton menu] itemArray]) {
		if ([[item title] isEqualToString:title]) return item;
	}
	XCTFail(@"no gear item %@", title);
	return nil;
}

/// What a click on the item does.
- (void)choose:(NSMenuItem *)item
{
	NSMenu *menu = [item menu];
	[menu performActionForItemAtIndex:[menu indexOfItem:item]];
}

#pragma mark - Tests

- (void)testGearMenuItems
{
	NSMenu *menu = [self.query.gearButton menu];
	NSArray<NSMenuItem *> *items = [menu itemArray];
	NSEventModifierFlags command = NSEventModifierFlagCommand;
	NSEventModifierFlags optionCommand = NSEventModifierFlagCommand | NSEventModifierFlagOption;
	NSString *up = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
	NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];

	// title, tag, key, modifiers ("-": a separator); DBView.xib's
	NSArray *expected = @[
		@[@"Previous Query from History", @3, up, @(NSEventModifierFlagControl)],
		@[@"Next Query from History", @4, down, @(NSEventModifierFlagControl)],
		@[@"History Replaces Editor Content", @0, @"", @0],
		@[@"-"],
		@[@"Favorite Replaces Editor Content", @0, @"", @0],
		@[@"-"],
		@[@"Shift Right", @6, @"]", @(command)],
		@[@"Shift Left", @7, @"[", @(command)],
		@[@"Comment Line", @11, @"/", @(command)],
		@[@"Comment Current Query", @12, @"/", @(optionCommand)],
		@[@"Completion List", @8, @"\x1b", @0],
		@[@"Show Completion List", @0, @"", @0],
		@[@"-"],
		@[@"Editor Font...", @0, @"", @0],
		@[@"Indent New Lines", @9, @"", @0],
		@[@"Auto-pair Characters", @10, @"", @0],
		@[@"Auto-uppercase Keywords", @0, @"", @0],
		@[@"Auto-completion", @0, @"", @0],
		@[@"Update Help while typing", @0, @"", @0],
	];

	XCTAssertEqual([items count], [expected count] + 1);
	XCTAssertTrue([items[0] isHidden]);
	XCTAssertEqualObjects([items[0] image], [NSImage imageNamed:@"button_action"]);
	XCTAssertFalse([menu autoenablesItems]);

	for (NSUInteger i = 0; i < [expected count]; i++) {
		NSArray *want = expected[i];
		NSMenuItem *item = items[i + 1];
		if ([want[0] isEqualToString:@"-"]) {
			XCTAssertTrue([item isSeparatorItem], @"item %lu", (unsigned long)i + 1);
			continue;
		}
		XCTAssertEqualObjects([item title], want[0]);
		XCTAssertEqual([item tag], [want[1] integerValue], @"%@", want[0]);
		XCTAssertEqualObjects([item keyEquivalent], want[2], @"%@", want[0]);
		if ([want[2] length]) XCTAssertEqual([item keyEquivalentModifierMask], [want[3] unsignedIntegerValue], @"%@", want[0]);
		if (![item hasSubmenu]) {
			XCTAssertEqual([item target], self.query, @"%@", want[0]);
			XCTAssertEqual([item action], @selector(gearMenuItemSelected:), @"%@", want[0]);
		}
	}

	XCTAssertEqualObjects([[self gearItem:@"Previous Query from History"] toolTip], @"Replaces the current query by the previous one coming from the history.");
	XCTAssertEqualObjects([[self gearItem:@"Next Query from History"] toolTip], @"Replaces the current query by the next one coming from the history.");
	XCTAssertTrue([[self gearItem:@"Comment Current Query"] isAlternate]);
	XCTAssertFalse([[self gearItem:@"Comment Current Query"] isEnabled], @"no query yet");

	NSArray<NSMenuItem *> *listItems = [[[self gearItem:@"Show Completion List"] submenu] itemArray];
	NSArray *listExpected = @[@[@"All Databases Names", @8000, @"1"], @[@"All Table and View Names", @8001, @"2"], @[@"All Field Names From Current Table", @8002, @"3"]];
	XCTAssertEqual([listItems count], [listExpected count]);
	for (NSUInteger i = 0; i < [listExpected count]; i++) {
		XCTAssertEqualObjects([listItems[i] title], listExpected[i][0]);
		XCTAssertEqual([listItems[i] tag], [listExpected[i][1] integerValue]);
		XCTAssertEqualObjects([listItems[i] keyEquivalent], listExpected[i][2]);
		XCTAssertEqual([listItems[i] keyEquivalentModifierMask], optionCommand);
		XCTAssertEqual([listItems[i] action], @selector(showCompletionList:));
		XCTAssertEqual([listItems[i] target], self.query);
	}

	// Previous / Next Query from History: only a beep for now (Task 7); the editor is untouched
	[[self editor] setString:@"SELECT 1"];
	[self choose:[self gearItem:@"Previous Query from History"]];
	[self choose:[self gearItem:@"Next Query from History"]];
	XCTAssertEqualObjects([[self editor] string], @"SELECT 1");
}

- (void)testToggleItemsWriteSharedPreferences
{
	NSDictionary *toggles = @{
		@"Indent New Lines": SPGearTestAutoIndentKey,
		@"Auto-pair Characters": SPGearTestAutoPairKey,
		@"Auto-uppercase Keywords": SPGearTestAutoUppercaseKey,
		@"Auto-completion": SPGearTestAutoCompleteKey,
		@"Update Help while typing": SPGearTestAutoHelpKey,
		@"History Replaces Editor Content": SPGearTestHistoryReplacesKey,
		@"Favorite Replaces Editor Content": SPGearTestFavoriteReplacesKey,
	};
	NSDictionary *getters = @{
		SPGearTestAutoIndentKey: NSStringFromSelector(@selector(autoindent)),
		SPGearTestAutoPairKey: NSStringFromSelector(@selector(autopair)),
		SPGearTestAutoUppercaseKey: NSStringFromSelector(@selector(autouppercaseKeywords)),
		SPGearTestAutoHelpKey: NSStringFromSelector(@selector(autohelp)),
	};
	// The scratch suite's own values are read (SPTextView's reads of these keys are not what is tested here)
	[self unpinPrefs:[toggles allValues]];
	NSMutableDictionary *standardBefore = [NSMutableDictionary dictionary];
	for (NSString *key in [toggles allValues]) standardBefore[key] = [self savedPreference:key];

	BOOL (^editorValue)(NSString *) = ^BOOL(NSString *key) {
		return [[[self editor] valueForKey:getters[key]] boolValue];
	};

	// Off to start with (the app's registered defaults turn some on)
	for (NSString *key in [toggles allValues]) [self.scratch setBool:NO forKey:key];

	for (NSString *title in toggles) {
		NSString *key = toggles[title];
		NSMenuItem *item = [self gearItem:title];
		XCTAssertFalse([self.scratch boolForKey:key], @"%@", key);
		XCTAssertEqual([item state], NSControlStateValueOff, @"%@", title);

		[self choose:item];
		XCTAssertTrue([self.scratch boolForKey:key], @"%@ flips %@", title, key);
		XCTAssertEqual([item state], NSControlStateValueOn, @"%@", title);
		if (getters[key]) XCTAssertTrue(editorValue(key), @"%@", key);

		[self choose:item];
		XCTAssertFalse([self.scratch boolForKey:key], @"%@ flips %@ back", title, key);
		XCTAssertEqual([item state], NSControlStateValueOff, @"%@", title);
		if (getters[key]) XCTAssertFalse(editorValue(key), @"%@", key);

		// A change made elsewhere
		[self.scratch setBool:YES forKey:key];
		XCTAssertTrue([self spinUntil:^BOOL{ return [item state] == NSControlStateValueOn; } timeout:2], @"%@ follows defaults", title);
		if (getters[key]) XCTAssertTrue(editorValue(key), @"%@", key);
		[self.scratch setBool:NO forKey:key];
		XCTAssertTrue([self spinUntil:^BOOL{ return [item state] == NSControlStateValueOff; } timeout:2], @"%@ follows defaults", title);
		if (getters[key]) XCTAssertFalse(editorValue(key), @"%@", key);
	}

	for (NSString *key in [toggles allValues]) {
		XCTAssertEqualObjects([self savedPreference:key], standardBefore[key], @"the saved %@ is untouched", key);
	}
}

- (void)testShiftAndComment
{
	SPPostgresTextView *editor = [self editor];

	// Shift Right / Left: a tab, or CustomQuerySoftIndentWidth spaces (SPTextView's)
	[editor setString:@"SELECT 1"];
	[editor setSelectedRange:NSMakeRange(3, 0)];
	[self choose:[self gearItem:@"Shift Right"]];
	XCTAssertEqualObjects([editor string], @"\tSELECT 1");
	[self choose:[self gearItem:@"Shift Left"]];
	XCTAssertEqualObjects([editor string], @"SELECT 1");

	[self overridePrefs:@{SPGearTestSoftIndentKey: @YES, SPGearTestSoftIndentWidthKey: @4}];
	[self choose:[self gearItem:@"Shift Right"]];
	XCTAssertEqualObjects([editor string], @"    SELECT 1");
	[self choose:[self gearItem:@"Shift Left"]];
	XCTAssertEqualObjects([editor string], @"SELECT 1");

	// Comment Line: "-- " on the caret's line, removed again (the caret goes to the next line)
	[editor setString:@"SELECT 1;\nSELECT 2;"];
	[editor setSelectedRange:NSMakeRange(14, 0)];
	NSMenuItem *commentLine = [self gearItem:@"Comment Line"];
	[self choose:commentLine];
	XCTAssertEqualObjects([editor string], @"SELECT 1;\n-- SELECT 2;");
	[editor setSelectedRange:NSMakeRange(12, 0)];
	[self choose:commentLine];
	XCTAssertEqualObjects([editor string], @"SELECT 1;\nSELECT 2;");
	[editor setSelectedRange:NSMakeRange(2, 0)];
	[self choose:commentLine];
	XCTAssertEqualObjects([editor string], @"-- SELECT 1;\nSELECT 2;");
	[editor setSelectedRange:NSMakeRange(0, 0)];
	[self choose:commentLine];
	XCTAssertEqualObjects([editor string], @"SELECT 1;\nSELECT 2;");

	// With a selection: "Comment Selection", wrapping it in /* */
	[editor setSelectedRange:NSMakeRange(7, 1)];
	XCTAssertEqualObjects([commentLine title], @"Comment Selection");
	[self choose:commentLine];
	XCTAssertEqualObjects([editor string], @"SELECT /* 1 */;\nSELECT 2;");
	[editor setSelectedRange:NSMakeRange(3, 0)];
	XCTAssertEqualObjects([commentLine title], @"Comment Line");

	// Comment Current Query: the current statement wrapped, and unwrapped on a second use
	[editor setString:@"SELECT 1;\nSELECT 2"];
	[editor setSelectedRange:NSMakeRange(13, 0)];
	NSRange current = [self.query currentQueryRange];
	XCTAssertEqualObjects([[editor string] substringWithRange:current], @"SELECT 2");
	NSMenuItem *commentQuery = [self gearItem:@"Comment Current Query"];
	XCTAssertTrue([commentQuery isEnabled]);
	[self choose:commentQuery];
	XCTAssertEqualObjects([editor string], @"SELECT 1;\n/* SELECT 2 */");
	XCTAssertEqual([editor selectedRange].location, current.location + 2);
	[self choose:commentQuery];
	XCTAssertEqualObjects([editor string], @"SELECT 1;\nSELECT 2");

	// A "*/" inside is escaped, and restored when unwrapped
	[editor setString:@"SELECT 1 /* x */ + 2"];
	[editor setSelectedRange:NSMakeRange(3, 0)];
	[self choose:commentQuery];
	XCTAssertEqualObjects([editor string], @"/* SELECT 1 /* x *\\/ + 2 */");
	[self choose:commentQuery];
	XCTAssertEqualObjects([editor string], @"SELECT 1 /* x */ + 2");

	// The run button follows the changed text (a programmatic change)
	[editor setString:@"SELECT 1;\nSELECT 2"];
	[editor setSelectedRange:NSMakeRange(3, 0)];
	[editor setSelectedRange:NSMakeRange(5, 4)];
	XCTAssertEqualObjects([self.query.runButton title], @"Run Selection");
	[self choose:commentLine];
	XCTAssertEqual([editor selectedRange].length, 0u);
	XCTAssertEqualObjects([self.query.runButton title], @"Run Current");
}

- (void)testEditorFontShowsFontPanel
{
	NSFontPanel *panel = [NSFontPanel sharedFontPanel];
	[panel orderOut:nil];
	[self choose:[self gearItem:@"Editor Font..."]];
	XCTAssertTrue([panel isVisible]);
	XCTAssertEqualObjects([panel delegate], (id)self.query);
	[panel orderOut:nil];
	[self.query invalidate];
	XCTAssertNil([panel delegate], @"invalidate lets go of the panel");
}

- (void)testHelpPathsAndLinks
{
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"select"], @"sql-select.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"SELECT"], @"sql-select.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"create table"], @"sql-createtable.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"create table items"], @"sql-createtable.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"alter table"], @"sql-altertable.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"start transaction"], @"sql-start-transaction.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"select items"], @"sql-select.html", @"the word alone");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"returning"], @"sql-commands.html");
	XCTAssertEqualObjects([SPPostgresHelpDataSource documentationPathForKeyword:@"create"], @"sql-commands.html");
	XCTAssertNil([SPPostgresHelpDataSource documentationPathForKeyword:@"items"]);
	XCTAssertNil([SPPostgresHelpDataSource documentationPathForKeyword:@""]);

	XCTAssertEqualObjects([SPPostgresHelpDataSource majorVersionFromServerVersion:@"18.6"], @"18");
	XCTAssertEqualObjects([SPPostgresHelpDataSource majorVersionFromServerVersion:@"9.6.24"], @"9.6");
	XCTAssertEqualObjects([SPPostgresHelpDataSource majorVersionFromServerVersion:@"unknown"], @"current");

	SPPostgresHelpDataSource *source = [[SPPostgresHelpDataSource alloc] initWithServerMajorVersion:@"18"];
	NSString *html = [source HTMLHelpContentsForSearchString:@"select" autoHelp:YES];
	XCTAssertTrue([html containsString:@"<a href=\"https://www.postgresql.org/docs/18/sql-select.html\">"], @"%@", html);
	XCTAssertTrue([html containsString:@"SELECT"]);
	XCTAssertTrue([html containsString:@"<title>Version 18: SELECT</title>"], @"%@", html);

	html = [source HTMLHelpContentsForSearchString:@"create table" autoHelp:YES];
	XCTAssertTrue([html containsString:@"<a href=\"https://www.postgresql.org/docs/18/sql-createtable.html\">"], @"%@", html);
	XCTAssertTrue([html containsString:@"CREATE TABLE"]);

	html = [source HTMLHelpContentsForSearchString:@"items" autoHelp:YES];
	XCTAssertTrue([html containsString:@"No results found."], @"%@", html);
	XCTAssertFalse([html containsString:@"https://"], @"%@", html);

	SPPostgresHelpDataSource *old = [[SPPostgresHelpDataSource alloc] initWithServerMajorVersion:@"9.6"];
	html = [old HTMLHelpContentsForSearchString:@"select" autoHelp:NO];
	XCTAssertTrue([html containsString:@"<a href=\"https://www.postgresql.org/docs/9.6/sql-select.html\">"], @"%@", html);

	// The table of contents (the help window's TOC button)
	html = [source HTMLHelpContentsForSearchString:@"contents" autoHelp:NO];
	XCTAssertTrue([html containsString:@"href='alter%20table'"], @"%@", html);
}

/// A connected tab on PG18 (as SPPostgresTextViewTests): its Query view writes to the scratch suite.
- (void)openDocument
{
	[SPPostgresTestServers loadFixtureNamed:@"content" onPort:SPGearTestPort];

	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 gear";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPGearTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

	self.windowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.windowController window]);

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
	self.document.alertPresenter = ^(NSAlert *alert) { XCTFail(@"alert: %@ %@", alert.messageText, alert.informativeText); };
	[self.windowController addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertNotNil(self.document.queryController);
	self.document.queryController.defaults = self.scratch;
}

- (void)testAutoHelpShowsWordAtCaret
{
	[self openDocument];
	id savedBefore = [self savedPreference:SPGearTestAutoHelpKey];

	// Update Help while typing on (SPTextView reads it from the standard defaults; the gear's state from the scratch suite)
	[self overridePrefs:@{SPGearTestAutoHelpKey: @YES}];
	[self.scratch setBool:YES forKey:SPGearTestAutoHelpKey];
	SPPostgresTextView *editor = (SPPostgresTextView *)self.document.queryController.editor;

	// Inside a string: nothing is shown
	[editor setString:@"SELECT 'select' FROM items"];
	[editor setSelectedRange:NSMakeRange(10, 0)];
	[editor doSyntaxHighlighting];
	[editor autoHelp];
	[self spinUntil:^BOOL{ return NO; } timeout:0.4];
	XCTAssertNil(self.document.helpViewerController, @"no help for a word in a string");

	// Inside a comment: nothing either (Ruling 5)
	[editor setString:@"-- select\nSELECT 1"];
	[editor setSelectedRange:NSMakeRange(5, 0)];
	[editor doSyntaxHighlighting];
	[editor autoHelp];
	[self spinUntil:^BOOL{ return NO; } timeout:0.4];
	XCTAssertNil(self.document.helpViewerController, @"no help for a word in a comment");

	// The word at the caret
	[editor setString:@"select 1 from items"];
	[editor setSelectedRange:NSMakeRange(2, 0)];
	[editor doSyntaxHighlighting];
	[editor autoHelp];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[self.document.helpViewerController window] isVisible]; } timeout:5]);
	NSWindow *helpWindow = [self.document.helpViewerController window];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[helpWindow title] isEqualToString:@"PostgreSQL Help (Version 18: SELECT)"]; } timeout:5], @"%@", [helpWindow title]);

	// Two words: "create table"
	[editor setString:@"create table t (a int)"];
	[editor setSelectedRange:NSMakeRange(1, 0)];
	[editor doSyntaxHighlighting];
	[editor autoHelp];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[helpWindow title] isEqualToString:@"PostgreSQL Help (Version 18: CREATE TABLE)"]; } timeout:5], @"%@", [helpWindow title]);

	// The editor's context menu item (⌃H): titled for PostgreSQL, it shows the help for the selection
	[editor setString:@"UPDATE items SET a = 1"];
	[editor setSelectedRange:NSMakeRange(0, 6)];
	NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"MySQL Help for Word" action:@selector(showMySQLHelpForCurrentWord:) keyEquivalent:@"h"];
	XCTAssertTrue([editor validateMenuItem:helpItem]);
	XCTAssertEqualObjects([helpItem title], @"PostgreSQL Help for Selection");
	[editor showMySQLHelpForCurrentWord:helpItem];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[helpWindow title] isEqualToString:@"PostgreSQL Help (Version 18: UPDATE)"]; } timeout:5], @"%@", [helpWindow title]);
	[editor setSelectedRange:NSMakeRange(2, 0)];
	[editor validateMenuItem:helpItem];
	XCTAssertEqualObjects([helpItem title], @"PostgreSQL Help for Word");

	// Closed by the user: Update Help while typing goes off (in the scratch suite), as MySQL's
	NSMenuItem *autoHelpItem = nil;
	for (NSMenuItem *item in [[self.document.queryController.gearButton menu] itemArray]) {
		if ([[item title] isEqualToString:@"Update Help while typing"]) autoHelpItem = item;
	}
	XCTAssertEqual([autoHelpItem state], NSControlStateValueOn);
	[helpWindow performClose:nil];
	XCTAssertFalse([helpWindow isVisible]);
	XCTAssertEqualObjects([self scratchValue:SPGearTestAutoHelpKey], @NO);
	XCTAssertEqual([autoHelpItem state], NSControlStateValueOff);
	XCTAssertFalse([editor autohelp]);
	XCTAssertEqualObjects([self savedPreference:SPGearTestAutoHelpKey], savedBefore, @"the saved preference is untouched");
}

@end
