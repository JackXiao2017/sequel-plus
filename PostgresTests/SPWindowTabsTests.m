#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "../Source/SPWindowTabDocument.h"
#import "../Source/SPWindowController.h"

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

#pragma mark - Tests

@interface SPWindowTabsTests : XCTestCase
@property (strong) SPWindowController *controller;
@end

@implementation SPWindowTabsTests

- (NSTabView *)tabView
{
	return [self.controller valueForKey:@"tabView"];
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
	id mysql = [self.controller addNewConnection];
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
	[self.controller addNewConnection];
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
	[self.controller addNewConnection];
	id second = [self.controller addNewConnection];
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

	id b = [self.controller addNewConnection];

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

- (void)testMenuValidationWithFakeTabSelected
{
	SPFakeTabDocument *fake = [[SPFakeTabDocument alloc] init];
	[self.controller addTabDocument:fake atIndex:0 select:YES];

	NSMenuItem *closeTab = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@""];
	XCTAssertTrue([self.controller validateMenuItem:closeTab]);
}

@end
