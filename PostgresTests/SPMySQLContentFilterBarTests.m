//
//  SPMySQLContentFilterBarTests.m
//  Sequel Plus
//
//  A MySQL tab's Content view with its rule filter shown: the filter rows sit above the filter's own button bar
//  (Reset, Add Filter, Filter), not under it. Needs the test MySQL server (sp-mysql8 on 127.0.0.1:55438).
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "../Source/SPWindowController.h"

/// The app classes' methods this test calls (their headers pull in the MySQL framework).
@protocol SPFilterBarTestMethods <NSObject>
- (id)valueForKey:(NSString *)key;
- (id)view;
- (BOOL)setState:(NSDictionary *)state fromFile:(BOOL)fromFile;
- (id)getConnection;
- (BOOL)isConnected;
- (NSString *)database;
- (BOOL)isWorking;
- (id)queryString:(NSString *)query;
- (BOOL)queryErrored;
- (NSString *)lastErrorMessage;
- (id)tablesListInstance;
- (id)tableContentInstance;
- (void)updateTables:(id)sender;
- (BOOL)selectItemWithName:(NSString *)name;
- (void)viewContent:(id)sender;
- (void)setRuleEditorVisible:(BOOL)show animate:(BOOL)animate;
- (BOOL)isEmpty;
- (void)addFilterExpression;
- (CGFloat)preferredHeight;
- (NSInteger)numberOfRows;
@end

static NSString * const SPFilterBarTestTable = @"sp_filter_bar_probe";

@interface SPMySQLContentFilterBarTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) id<SPFilterBarTestMethods> document;
@end

@implementation SPMySQLContentFilterBarTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [end timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	[self.controller showWindow:nil];
	[[self.controller window] setFrame:NSMakeRect(80, 80, 1100, 760) display:YES];

	self.document = [self.controller addNewConnection];
	XCTAssertNotNil(self.document);
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

	NSDictionary *connection = @{@"type": @"SPTCPIPConnection", @"host": @"127.0.0.1", @"port": @55438,
	                             @"user": @"root", @"password": @"sptest", @"database": @"sp_test"};
	[self.document setState:@{@"connection": connection, @"auto_connect": @YES} fromFile:NO];
	id<SPFilterBarTestMethods> document = self.document;
	BOOL connected = [self spinUntil:^BOOL{
		return [(id<SPFilterBarTestMethods>)[document getConnection] isConnected] && [[document database] isEqualToString:@"sp_test"] && ![document isWorking];
	} timeout:20];
	if (!connected) {
		XCTSkip(@"The test MySQL server (127.0.0.1:55438) isn't reachable");
	}

	id<SPFilterBarTestMethods> mysql = [self.document getConnection];
	[mysql queryString:[NSString stringWithFormat:@"DROP TABLE IF EXISTS `%@`", SPFilterBarTestTable]];
	[mysql queryString:[NSString stringWithFormat:@"CREATE TABLE `%@` (id INT PRIMARY KEY, name VARCHAR(40))", SPFilterBarTestTable]];
	[mysql queryString:[NSString stringWithFormat:@"INSERT INTO `%@` VALUES (1, 'a'), (2, 'b')", SPFilterBarTestTable]];
	XCTAssertFalse([mysql queryErrored], @"%@", [mysql lastErrorMessage]);
}

- (void)tearDown
{
	if ([(id<SPFilterBarTestMethods>)[self.document getConnection] isConnected]) {
		[(id<SPFilterBarTestMethods>)[self.document getConnection] queryString:[NSString stringWithFormat:@"DROP TABLE IF EXISTS `%@`", SPFilterBarTestTable]];
	}
	// The filter editor resizes itself 0.2 s after a change (SPRuleFilterController -_resize); let it run first
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
	NSTabView *tabView = [self.controller valueForKey:@"tabView"];
	for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
	[[self.controller window] orderOut:nil];
	self.document = nil;
	self.controller = nil;
}

- (id<SPFilterBarTestMethods>)contentShowingProbeTable
{
	id<SPFilterBarTestMethods> document = self.document;
	id<SPFilterBarTestMethods> tables = [document tablesListInstance];
	[tables updateTables:nil];
	XCTAssertTrue([self spinUntil:^BOOL{ return [[tables valueForKey:@"tables"] containsObject:SPFilterBarTestTable]; } timeout:10]);
	XCTAssertTrue([tables selectItemWithName:SPFilterBarTestTable]);
	[document viewContent:nil];
	id<SPFilterBarTestMethods> content = [document tableContentInstance];
	XCTAssertTrue([self spinUntil:^BOOL{
		return [[content valueForKey:@"dataColumns"] count] == 2 && ![document isWorking];
	} timeout:10]);
	return content;
}

- (void)assertRowsAboveButtonBarIn:(id<SPFilterBarTestMethods>)content rows:(NSInteger)rows label:(NSString *)label
{
	id<SPFilterBarTestMethods> ruleFilter = [content valueForKey:@"ruleFilterController"];
	NSView *container = [content valueForKey:@"filterRuleEditorContainer"];
	NSScrollView *rulesScroll = [[(id)ruleFilter view] enclosingScrollView];
	NSView *buttonBar = nil;
	for (NSView *subview in [container subviews]) {
		if ([subview isKindOfClass:NSClassFromString(@"SPButtonBar")]) buttonBar = subview;
	}
	NSLog(@"[%@] content area %@, filter container %@ (hidden %d), rules scroll %@, rule editor %@, button bar %@, rows %ld, preferred %.1f",
	      label, NSStringFromRect([[content valueForKey:@"contentAreaContainer"] frame]),
	      NSStringFromRect([container frame]), [container isHiddenOrHasHiddenAncestor],
	      NSStringFromRect([rulesScroll frame]), NSStringFromRect([[(id)ruleFilter view] frame]),
	      NSStringFromRect([buttonBar frame]), (long)[(id<SPFilterBarTestMethods>)[(id)ruleFilter view] numberOfRows], [ruleFilter preferredHeight]);

	XCTAssertNotNil(buttonBar);
	XCTAssertEqual([(id<SPFilterBarTestMethods>)[(id)ruleFilter view] numberOfRows], rows, @"%@", label);
	XCTAssertGreaterThanOrEqual(NSMinY([rulesScroll frame]), NSMaxY([buttonBar frame]), @"%@: the rows start above the button bar", label);
	XCTAssertGreaterThanOrEqual(NSHeight([rulesScroll frame]), 29.0, @"%@: at least one row shows", label);
	XCTAssertLessThanOrEqual(NSMaxY([rulesScroll frame]), NSHeight([container frame]), @"%@", label);
}

- (void)testFilterRowsSitAboveTheFilterButtonBar
{
	id<SPFilterBarTestMethods> content = [self contentShowingProbeTable];
	id<SPFilterBarTestMethods> ruleFilter = [content valueForKey:@"ruleFilterController"];
	[content setRuleEditorVisible:YES animate:NO];
	if ([ruleFilter isEmpty]) [ruleFilter addFilterExpression];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
	[self assertRowsAboveButtonBarIn:content rows:1 label:@"shown"];
}

- (void)testFilterRowsSitAboveTheButtonBarAfterTheAnimatedToggle
{
	id<SPFilterBarTestMethods> content = [self contentShowingProbeTable];
	[content setRuleEditorVisible:NO animate:NO];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
	// As the Filter toggle button does (-toggleRuleEditorVisible:, without its preference write)
	[content setRuleEditorVisible:YES animate:YES];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
	[self assertRowsAboveButtonBarIn:content rows:1 label:@"toggled"];

	id<SPFilterBarTestMethods> ruleFilter = [content valueForKey:@"ruleFilterController"];
	[ruleFilter addFilterExpression];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
	[self assertRowsAboveButtonBarIn:content rows:2 label:@"two rows"];

	NSWindow *window = [self.controller window];
	[window setFrame:NSMakeRect(80, 80, 900, 420) display:YES];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
	[self assertRowsAboveButtonBarIn:content rows:2 label:@"small window"];
}

@end
