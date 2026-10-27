#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "../Source/SPWindowTabDocument.h"
#import "../Source/SPWindowController.h"
#import <PostgresKit/PostgresKit.h>
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"

#pragma mark - Test-only tab document

/**
 * A non-MySQL tab document: an empty view, counters for every protocol call and one action of its own.
 */
@interface SPFakeTabDocument : NSObject <SPWindowTabDocument>

@property (strong) NSView *view;
@property (unsafe_unretained) SPWindowController *parentWindowController;
@property (unsafe_unretained) NSWindow *parentWindow;
@property (unsafe_unretained) NSTabViewItem *parentTabViewItem;
@property (readwrite) BOOL isProcessing;

@property NSUInteger databaseViewCount;
@property NSUInteger becameActiveCount;
@property NSUInteger resignedCount;
@property NSUInteger updateTitleCount;
@property NSUInteger shouldCloseCount;
@property NSUInteger didCloseCount;
@property NSUInteger becameKeyCount;
@property NSUInteger resizeCount;
@property NSUInteger fakeActionCount;

- (IBAction)fakeAction:(id)sender;

@end

@implementation SPFakeTabDocument

- (instancetype)init
{
	if ((self = [super init])) {
		_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
	}
	return self;
}

- (NSView *)databaseView { self.databaseViewCount++; return self.view; }
- (void)didBecomeActiveTabInWindow { self.becameActiveCount++; }
- (void)willResignActiveTabInWindow { self.resignedCount++; }
- (void)updateWindowTitle:(id)sender { self.updateTitleCount++; }
- (BOOL)parentTabShouldClose { self.shouldCloseCount++; return YES; }
- (void)parentTabDidClose { self.didCloseCount++; self.parentWindow = nil; }
- (void)tabDidBecomeKey { self.becameKeyCount++; }
- (void)tabDidResize { self.resizeCount++; }
- (NSString *)tabToolTip { return @"fake tooltip"; }
- (IBAction)fakeAction:(id)sender { self.fakeActionCount++; }

@end

/**
 * A tab document exposing only the protocol: no -parentWindow or -parentWindowController getters.
 */
@interface SPBareTabDocument : NSObject <SPWindowTabDocument>
@property (readwrite) BOOL isProcessing;
@property NSUInteger didCloseCount;
@end

@implementation SPBareTabDocument
{
	NSView *_view;
}

- (instancetype)init
{
	if ((self = [super init])) _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
	return self;
}

- (NSView *)databaseView { return _view; }
- (void)setParentWindowController:(SPWindowController *)controller {}
- (void)setParentWindow:(NSWindow *)window {}
- (void)setParentTabViewItem:(NSTabViewItem *)item {}
- (void)didBecomeActiveTabInWindow {}
- (void)willResignActiveTabInWindow {}
- (void)updateWindowTitle:(id)sender {}
- (BOOL)parentTabShouldClose { return YES; }
- (void)parentTabDidClose { self.didCloseCount++; }

@end

#pragma mark - Tests

@interface NSObject (SPWindowTabsTestsPSM)
- (void)removeTabForCell:(id)cell;
@end

// Tab bar delegate method and a MySQL action implemented by the app (not in the public headers)
@interface SPWindowController (SPWindowTabsTests)
- (void)tabView:(NSTabView *)aTabView didDropTabViewItem:(NSTabViewItem *)tabViewItem inTabBar:(id)tabBarControl;
- (IBAction)showServerVariables:(id)sender;
- (BOOL)windowShouldClose:(id)sender;
@end

@interface NSObject (SPWindowTabsTestsMySQL)
- (id)connectionController;
- (void)_enableWindowToolbarItemsAfterConnecting;
@end

@interface SPWindowTabsTests : XCTestCase
@property (strong) SPWindowController *controller;
@end

@implementation SPWindowTabsTests

- (NSTabView *)tabView
{
	return [self.controller valueForKey:@"tabView"];
}

- (id)tabBar
{
	return [self.controller valueForKey:@"tabBar"];
}

/**
 * Tab bar cells must be in tab view item order, and each cell's progress indicator must be bound
 * to its own item's document.
 */
- (void)assertCellsMatchItems
{
	NSArray *cells = [[self tabBar] valueForKey:@"cells"];
	NSArray *items = [[self tabView] tabViewItems];

	XCTAssertEqual([cells count], [items count]);
	for (NSUInteger i = 0; i < [items count]; i++) {
		id cell = [cells objectAtIndex:i];
		XCTAssertEqual([cell valueForKey:@"representedObject"], [items objectAtIndex:i], @"cell %lu", (unsigned long)i);
		NSDictionary *binding = [[cell valueForKey:@"indicator"] infoForBinding:@"animate"];
		XCTAssertEqual([binding objectForKey:NSObservedObjectKey], [[items objectAtIndex:i] identifier], @"indicator %lu", (unsigned long)i);
	}
}

/**
 * A MySQL tab on its connection screen. Its filter editor resizes itself 0.2 s after it is built
 * (SPRuleFilterController -_resize) and messages freed objects if the document is gone by then
 * (pre-existing): let that happen now, so tests may close or replace the tab right away.
 */
- (id)addMySQLTab
{
	id mysql = [self.controller addNewConnection];
	XCTAssertNotNil(mysql);
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
	return mysql;
}

/**
 * Three tabs: MySQL, fake, fake.
 */
- (NSArray *)addThreeTabs
{
	id mysql = [self addMySQLTab];
	SPFakeTabDocument *b = [[SPFakeTabDocument alloc] init];
	SPFakeTabDocument *c = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:b atIndex:1 select:NO];
	[self.controller addTabDocument:c atIndex:2 select:NO];
	[self assertCellsMatchItems];
	return @[mysql, b, c];
}

- (void)setUp
{
	self.continueAfterFailure = NO;

	// As -[SPAppController newWindow] does. The window's delegate is deliberately not set: its
	// -windowWillClose: autoreleases the controller, which this (ARC) test owns.
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);
}

- (void)tearDown
{
	// A MySQL tab's filter editor resizes itself 0.2 s after it is built (SPRuleFilterController -_resize);
	// let that run while the MySQL document is still alive, or it messages freed objects in a later test.
	for (NSTabViewItem *item in [[self tabView] tabViewItems]) {
		if ([[item identifier] isKindOfClass:NSClassFromString(@"SPDatabaseDocument")]) {
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
			break;
		}
	}

	// Close every tab the way the tab bar does, so documents get -parentTabDidClose
	for (NSTabViewItem *item in [[self tabView] tabViewItems]) {
		[[self tabView] removeTabViewItem:item];
	}
	[[self.controller window] orderOut:nil];
	self.controller = nil;
}

- (void)testAddingFakeTabMakesItSelectedDocument
{
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];

	[self.controller addTabDocument:fake atIndex:0 select:YES];

	XCTAssertEqual((id)[self.controller selectedDocument], fake);
	XCTAssertNil([self.controller selectedTableDocument]);
	XCTAssertEqual(fake.becameActiveCount, 1u);
	XCTAssertEqual(fake.parentWindowController, self.controller);
	XCTAssertEqual(fake.parentWindow, [self.controller window]);
	XCTAssertEqual(fake.parentTabViewItem, [[self tabView] tabViewItemAtIndex:0]);
	XCTAssertEqual([[[self tabView] tabViewItemAtIndex:0] view], fake.view);
}

- (void)testDocumentsListsOnlyMySQLDocuments
{
	id mysql = [self addMySQLTab];
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];

	[self.controller addTabDocument:fake atIndex:1 select:NO];

	XCTAssertEqual([[self.controller documents] count], 1u);
	XCTAssertEqual([[self.controller documents] firstObject], mysql);
	XCTAssertEqual([[self.controller tabDocuments] count], 2u);
	XCTAssertEqual([[self.controller tabDocuments] objectAtIndex:0], mysql);
	XCTAssertEqual([[self.controller tabDocuments] objectAtIndex:1], fake);
	// Not selected: the MySQL tab stays the selected one
	XCTAssertEqual([self.controller selectedTableDocument], mysql);
	XCTAssertEqual(fake.becameActiveCount, 0u);
}

- (void)testForwardingSkipsDocumentsThatDontRespond
{
	// With a MySQL tab selected, MySQL actions are forwarded as before
	[self addMySQLTab];
	XCTAssertTrue([self.controller respondsToSelector:@selector(showServerVariables:)]);

	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:fake atIndex:1 select:YES];

	XCTAssertFalse([self.controller respondsToSelector:@selector(showServerVariables:)]);
	XCTAssertTrue([self.controller respondsToSelector:@selector(fakeAction:)]);

	[self.controller performSelector:@selector(fakeAction:) withObject:nil];
	XCTAssertEqual(fake.fakeActionCount, 1u);

	[NSApp sendAction:@selector(fakeAction:) to:self.controller from:nil];
	XCTAssertEqual(fake.fakeActionCount, 2u);
}

- (void)testReplaceKeepsIndexAndSelects
{
	[self addMySQLTab];
	id second = [self addMySQLTab];
	XCTAssertNotNil([second parentWindow]);

	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];
	[self.controller replaceTabDocument:second withDocument:fake];

	XCTAssertEqual([[self.controller tabDocuments] count], 2u);
	XCTAssertEqual([[self.controller tabDocuments] objectAtIndex:1], fake);
	XCTAssertEqual((id)[self.controller selectedDocument], fake);
	XCTAssertEqual([[self tabView] indexOfTabViewItem:[[self tabView] selectedTabViewItem]], 1);
	XCTAssertNil([self.controller selectedTableDocument]);
	XCTAssertEqual(fake.becameActiveCount, 1u);
	XCTAssertEqual(fake.parentTabViewItem, [[self tabView] tabViewItemAtIndex:1]);
	// -[SPDatabaseDocument parentTabDidClose] clears its parent window
	XCTAssertNil([second parentWindow]);
	XCTAssertEqual([[self.controller documents] count], 1u);
}

- (void)testSwitchingTabsResignsAndActivates
{
	SPFakeTabDocument *a = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:a atIndex:0 select:YES];

	id b = [self addMySQLTab];

	XCTAssertEqual(a.resignedCount, 1u);
	XCTAssertEqual([self.controller selectedTableDocument], b);
	XCTAssertEqual((id)[self.controller selectedDocument], b);

	[self.controller selectTabAtIndex:0];
	XCTAssertEqual(a.becameActiveCount, 2u);
	XCTAssertEqual((id)[self.controller selectedDocument], a);
	XCTAssertNil([self.controller selectedTableDocument]);

	[self.controller selectTabAtIndex:1];
	XCTAssertEqual(a.resignedCount, 2u);
	XCTAssertEqual([self.controller selectedTableDocument], b);
}

- (void)testClosingFakeTabClearsSelectionAndObservation
{
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:fake atIndex:0 select:YES];

	// The tab's progress indicator follows the document's isProcessing
	fake.isProcessing = YES;
	fake.isProcessing = NO;

	[[self tabView] removeTabViewItem:[[self tabView] tabViewItemAtIndex:0]];

	XCTAssertEqual(fake.didCloseCount, 1u);
	XCTAssertNil([self.controller selectedDocument]);
	XCTAssertNil([self.controller selectedTableDocument]);
	// Every KVO observer (the window controller's and the tab bar's) was removed
	XCTAssertTrue([fake observationInfo] == NULL);
}

- (void)testInsertInMiddleKeepsCellOrder
{
	NSArray *docs = [self addThreeTabs];
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];

	[self.controller addTabDocument:fake atIndex:1 select:YES];

	NSArray *expected = @[docs[0], fake, docs[1], docs[2]];
	XCTAssertEqualObjects([self.controller tabDocuments], expected);
	[self assertCellsMatchItems];
}

- (void)testReplaceFirstKeepsCellOrder
{
	NSArray *docs = [self addThreeTabs];
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];

	[self.controller replaceTabDocument:docs[0] withDocument:fake];

	NSArray *expected = @[fake, docs[1], docs[2]];
	XCTAssertEqualObjects([self.controller tabDocuments], expected);
	XCTAssertEqual((id)[self.controller selectedDocument], fake);
	[self assertCellsMatchItems];
}

- (void)testReplaceMiddleKeepsCellOrder
{
	NSArray *docs = [self addThreeTabs];
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];

	[self.controller replaceTabDocument:docs[1] withDocument:fake];

	NSArray *expected = @[docs[0], fake, docs[2]];
	XCTAssertEqualObjects([self.controller tabDocuments], expected);
	XCTAssertEqual([docs[1] didCloseCount], 1u);
	[self assertCellsMatchItems];
}

- (void)testReplaceLastKeepsCellOrder
{
	NSArray *docs = [self addThreeTabs];
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];

	[self.controller replaceTabDocument:docs[2] withDocument:fake];

	NSArray *expected = @[docs[0], docs[1], fake];
	XCTAssertEqualObjects([self.controller tabDocuments], expected);
	[self assertCellsMatchItems];
}

/**
 * Moves a tab view item from this test's controller to target the way PSMTabDragAssistant does
 * before it sends the drop delegate call: the source cell is removed first (so the source gets no
 * didClose), then the item moves between the tab views.
 */
- (void)moveItem:(NSTabViewItem *)item toController:(SPWindowController *)target
{
	for (id cell in [[[self tabBar] valueForKey:@"cells"] copy]) {
		if ([cell valueForKey:@"representedObject"] == item) {
			[[self tabBar] performSelector:@selector(removeTabForCell:) withObject:cell];
		}
	}
	[[self tabView] removeTabViewItem:item];
	[(NSTabView *)[target valueForKey:@"tabView"] insertTabViewItem:item atIndex:0];
}

// The drop delegate call goes to the source window's controller with the source tab view. A
// document without parentWindow/parentWindowController is found through that tab view's window.
- (void)testDropOfDocumentWithoutWindowAccessorsUsesSourceTabView
{
	SPBareTabDocument *bare = [[SPBareTabDocument alloc] init];
	[self.controller addTabDocument:bare atIndex:0 select:YES];
	NSTabViewItem *item = [[self tabView] tabViewItemAtIndex:0];

	SPWindowController *target = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([target window]);
	[self moveItem:item toController:target];

	XCTAssertNoThrow([self.controller tabView:[self tabView] didDropTabViewItem:item inTabBar:[target valueForKey:@"tabBar"]]);

	XCTAssertNil([self.controller selectedDocument]);
	XCTAssertEqual((id)[target selectedDocument], bare);

	// The source's observer was swapped for the target's: closing the tab leaves none behind
	XCTAssertNoThrow([(NSTabView *)[target valueForKey:@"tabView"] removeTabViewItem:item]);
	XCTAssertEqual(bare.didCloseCount, 1u);
	XCTAssertTrue([bare observationInfo] == NULL);
	[[target window] orderOut:nil];
}

// With no source window at all, the drop must not throw (removeObserver:nil).
- (void)testDropWithNoSourceWindowDoesNotThrow
{
	SPBareTabDocument *bare = [[SPBareTabDocument alloc] init];
	[self.controller addTabDocument:bare atIndex:0 select:YES];
	NSTabViewItem *item = [[self tabView] tabViewItemAtIndex:0];

	SPWindowController *target = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([target window]);
	[self moveItem:item toController:target];

	NSTabView *detachedTabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
	XCTAssertNoThrow([self.controller tabView:detachedTabView didDropTabViewItem:item inTabBar:[target valueForKey:@"tabBar"]]);
	XCTAssertEqual((id)[target selectedDocument], bare);

	// The target observes the document and removes its observer when the tab closes
	XCTAssertNoThrow([(NSTabView *)[target valueForKey:@"tabView"] removeTabViewItem:item]);
	XCTAssertEqual(bare.didCloseCount, 1u);

	// The unknown source keeps its observation (nothing could identify it); clean it up here
	[bare removeObserver:self.controller forKeyPath:@"isProcessing"];
	XCTAssertTrue([bare observationInfo] == NULL);
	[self.controller updateSelectedTableDocument];
	[[target window] orderOut:nil];
}

- (void)testMenuValidationWithFakeTabSelected
{
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:fake atIndex:0 select:YES];

	NSMenuItem *closeTab = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:closeTab]);
}

#pragma mark - Colour strip

- (CGFloat)collapsedTabBarHeight
{
	return [[[self tabBar] valueForKey:@"heightCollapsed"] doubleValue];
}

- (void)testCollapsedTabBarShowsColourOfNonMySQLTab
{
	SPFakeTabDocument *coloured = [[SPFakeTabDocument alloc] init];
	SPFakeTabDocument *plain = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:coloured atIndex:0 select:NO];
	[[[self tabView] tabViewItemAtIndex:0] setColor:[NSColor systemRedColor]];
	[self.controller addTabDocument:plain atIndex:1 select:NO];
	// No colour: nil, as tab documents set it (NSTabViewItem's default colour isn't nil)
	[[[self tabView] tabViewItemAtIndex:1] setValue:nil forKey:@"color"];
	[[self tabView] selectTabViewItemAtIndex:1];
	XCTAssertEqual((id)[self.controller selectedDocument], plain);
	XCTAssertEqual([self collapsedTabBarHeight], 1.0);

	// Switching between two non-MySQL tabs updates the tab bar: the selected tab's colour shows as the 8 pt strip
	[[self tabView] selectTabViewItemAtIndex:0];
	XCTAssertEqual((id)[self.controller selectedDocument], coloured);
	XCTAssertEqual([self collapsedTabBarHeight], 8.0);

	[[self tabView] selectTabViewItemAtIndex:1];
	XCTAssertEqual([self collapsedTabBarHeight], 1.0);

	// A colour change followed by -updateTabBar (as a tab document's -updateWindowTitle: does)
	[[[self tabView] tabViewItemAtIndex:1] setColor:[NSColor systemBlueColor]];
	[self.controller updateTabBar];
	XCTAssertEqual([self collapsedTabBarHeight], 8.0);
}

- (void)testCollapsedTabBarForMySQLTabIsUnchanged
{
	// A coloured non-MySQL tab, then an unconnected MySQL tab: MySQL's own rule (connection colour) applies
	SPFakeTabDocument *coloured = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:coloured atIndex:0 select:YES];
	[[[self tabView] tabViewItemAtIndex:0] setColor:[NSColor systemRedColor]];
	[self.controller updateTabBar];
	XCTAssertEqual([self collapsedTabBarHeight], 8.0);

	id mysql = [self addMySQLTab];
	XCTAssertEqual([self.controller selectedTableDocument], mysql);
	[[[self tabView] tabViewItemAtIndex:1] setColor:[NSColor systemBlueColor]];
	[self.controller updateTabBar];
	XCTAssertEqual([self collapsedTabBarHeight], 1.0, @"not connected: no strip, whatever the tab colour");

	[[self tabView] selectTabViewItemAtIndex:0];
	XCTAssertEqual([self collapsedTabBarHeight], 8.0);

	// Let the MySQL tab's filter editor finish its delayed resize before it closes (see SPPostgresDocumentTests)
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
}

#pragma mark - PostgreSQL tabs: drag and close

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}



/// A PostgreSQL tab document connected to PG 18 on 55418 (Scripts/pg-test-servers.sh), not hosted yet.
- (SPPostgresDocument *)connectedPostgresDocument
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"tabs test";
	favorite.colorIndex = 4;
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = 55418;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";

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

	return [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
}

- (void)testMoveTabToNewWindowKeepsConnection
{
	id mysql = [self addMySQLTab];
	SPPostgresDocument *postgres = [self connectedPostgresDocument];
	[self.controller addTabDocument:postgres atIndex:1 select:YES];
	XCTAssertEqual((id)[self.controller selectedDocument], postgres);
	NSString *label = [postgres.parentTabViewItem label];
	NSColor *color = [postgres.parentTabViewItem color];
	XCTAssertEqualObjects(label, @"tabs test");
	XCTAssertNotNil(color);

	// As in the app, the window is on screen (the tab bar has its tracking rects)
	[self.controller showWindow:nil];
	[self spinUntil:^BOOL{ return NO; } timeout:0.2];

	[self.controller moveSelectedTabInNewWindow:nil];

	SPWindowController *newController = postgres.parentWindowController;
	XCTAssertNotNil(newController);
	XCTAssertNotEqual(newController, self.controller);
	// The new window's controller owns itself (it is the window's delegate); closing the window frees it
	[self addTeardownBlock:^{ [[newController window] close]; }];

	XCTAssertEqualObjects([newController tabDocuments], @[postgres]);
	XCTAssertEqualObjects([self.controller tabDocuments], @[mysql]);
	XCTAssertEqual((id)[newController selectedDocument], postgres);
	XCTAssertEqual(postgres.parentWindow, [newController window]);
	XCTAssertEqual(postgres.parentTabViewItem, [(NSTabView *)[newController valueForKey:@"tabView"] tabViewItemAtIndex:0]);

	// The tab works in its new window, with the same label and colour
	XCTAssertTrue(postgres.connection.isConnected);
	XCTAssertNotNil([postgres.connection execute:@"SELECT 1"]);
	XCTAssertEqualObjects([postgres.parentTabViewItem label], label);
	XCTAssertEqualObjects([postgres.parentTabViewItem color], color);
	XCTAssertEqual([[newController window] toolbar], [postgres toolbar]);
	XCTAssertEqualObjects([[newController window] title], [postgres windowTitleString]);

	// The source window is back on its MySQL tab
	XCTAssertEqual([self.controller selectedTableDocument], mysql);
	XCTAssertNotEqual([[self.controller window] toolbar], [postgres toolbar]);

	// Only the new window observes the tab: closing it there leaves no observer behind
	PGPostgresConnection *connection = postgres.connection;
	[(NSTabView *)[newController valueForKey:@"tabView"] removeTabViewItem:postgres.parentTabViewItem];
	XCTAssertTrue([postgres observationInfo] == NULL);
	XCTAssertTrue([self spinUntil:^BOOL{ return !connection.isConnected; } timeout:2]);
}

/// The same action for a MySQL tab (it used to raise: the tab's tracking rects were removed twice).
- (void)testMoveMySQLTabToNewWindow
{
	id first = [self addMySQLTab];
	id second = [self addMySQLTab];
	XCTAssertEqual([self.controller selectedTableDocument], second);
	[self.controller showWindow:nil];
	[self spinUntil:^BOOL{ return NO; } timeout:0.4]; // see -tearDown

	XCTAssertNoThrow([self.controller moveSelectedTabInNewWindow:nil]);

	SPWindowController *newController = [second parentWindowController];
	XCTAssertNotNil(newController);
	XCTAssertNotEqual(newController, self.controller);
	[self addTeardownBlock:^{ [[newController window] close]; }];
	XCTAssertEqualObjects([newController tabDocuments], @[second]);
	XCTAssertEqual([newController selectedTableDocument], second);
	XCTAssertEqual([second parentWindow], [newController window]);
	XCTAssertEqualObjects([self.controller tabDocuments], @[first]);
	XCTAssertEqual([self.controller selectedTableDocument], first);
}

- (void)testClosingWindowDisconnectsPostgresTabs
{
	id mysql = [self addMySQLTab];
	SPPostgresDocument *postgres = [self connectedPostgresDocument];
	[self.controller addTabDocument:postgres atIndex:1 select:YES];
	PGPostgresConnection *connection = postgres.connection;
	XCTAssertTrue(connection.isConnected);
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]]; // see -tearDown

	// As the app's windows: the controller is the window's delegate and frees itself in -windowWillClose:
	NSWindow *window = [self.controller window];
	[window setDelegate:(id <NSWindowDelegate>)self.controller];
	(void)CFBridgingRetain(self.controller); // the reference -windowWillClose: autoreleases (this test keeps its own)
	[self.controller showWindow:nil];

	// The close button: every tab is asked, then the window closes
	XCTAssertTrue([self.controller windowShouldClose:window]);
	[window close];

	XCTAssertFalse([window isVisible]);
	XCTAssertEqual([[self.controller tabDocuments] count], 0u);
	XCTAssertNil([mysql valueForKey:@"parentWindow"]);
	XCTAssertNil(postgres.parentWindow, @"the Postgres tab got -parentTabDidClose");
	XCTAssertTrue([self spinUntil:^BOOL{ return !connection.isConnected; } timeout:2]);
}

#pragma mark - A MySQL tab connecting in the background (R8)

/// Every item is enabled, but MySQL's Transfer item (an SPDisabledToolbarItem, never enabled).
- (void)assertEnabledAfterConnecting:(NSToolbar *)toolbar
{
	Class alwaysDisabled = NSClassFromString(@"SPDisabledToolbarItem");
	XCTAssertNotNil(alwaysDisabled);
	for (NSToolbarItem *item in [toolbar items]) {
		if ([item isKindOfClass:alwaysDisabled]) XCTAssertFalse([item isEnabled]);
		else XCTAssertTrue([item isEnabled], @"%@", [item itemIdentifier]);
	}
}

/// A MySQL tab that finishes connecting while a PostgreSQL tab is selected must not enable the
/// Postgres tab's toolbar items; with the MySQL tab selected, every item is enabled as before.
- (void)testBackgroundMySQLConnectLeavesPostgresToolbarAlone
{
	id mysql = [self addMySQLTab];
	SPPostgresDocument *postgres = [self connectedPostgresDocument];
	[self.controller addTabDocument:postgres atIndex:1 select:YES];

	NSToolbar *postgresToolbar = [[self.controller window] toolbar];
	XCTAssertEqual(postgresToolbar, [postgres toolbar]);
	NSToolbarItem *history = nil;
	for (NSToolbarItem *item in [postgresToolbar items]) {
		if ([[item itemIdentifier] isEqualToString:@"HistoryNavigationToolbarItemIdentifier"]) history = item;
	}
	XCTAssertNotNil(history);
	XCTAssertFalse([history isEnabled]);
	NSArray *enabledBefore = [[postgresToolbar items] valueForKey:@"enabled"];

	[[mysql connectionController] _enableWindowToolbarItemsAfterConnecting];

	XCTAssertFalse([history isEnabled]);
	XCTAssertEqualObjects([[postgresToolbar items] valueForKey:@"enabled"], enabledBefore);

	// MySQL tab selected: its (window's) toolbar items are all enabled, as before
	[self.controller selectTabAtIndex:0];
	NSToolbar *mysqlToolbar = [[self.controller window] toolbar];
	XCTAssertNotEqual(mysqlToolbar, postgresToolbar);
	XCTAssertGreaterThan([[mysqlToolbar items] count], 0u);
	for (NSToolbarItem *item in [mysqlToolbar items]) [item setEnabled:NO];

	[[mysql connectionController] _enableWindowToolbarItemsAfterConnecting];

	[self assertEnabledAfterConnecting:mysqlToolbar];
}

/// MySQL-only window: a background tab finishing its connect enables the window's (selected tab's)
/// toolbar items, exactly as before.
- (void)testBackgroundMySQLConnectInMySQLOnlyWindowEnablesToolbarAsBefore
{
	id background = [self addMySQLTab];
	[self addMySQLTab];
	XCTAssertNotEqual([self.controller selectedTableDocument], background);
	NSToolbar *toolbar = [[self.controller window] toolbar];
	XCTAssertGreaterThan([[toolbar items] count], 0u);
	for (NSToolbarItem *item in [toolbar items]) [item setEnabled:NO];

	[[background connectionController] _enableWindowToolbarItemsAfterConnecting];

	[self assertEnabledAfterConnecting:toolbar];
}

@end
