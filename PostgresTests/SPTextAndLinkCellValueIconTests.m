//
//  SPTextAndLinkCellValueIconTests.m
//  Sequel Plus
//
//  The grids' cell (SPTextAndLinkCell) shows a value icon, left of the foreign key arrow when both show, for a text
//  text column's value (NULL too); each button hits and fires on its own.
//

#import <XCTest/XCTest.h>
#import "../Source/SPTextAndLinkCell.h"
#import "../Source/SPValueFormatter.h"

@interface SPTextAndLinkCell (Testing)
- (void)_followButton:(SPTextAndLinkCellButton)button atPoint:(NSPoint)point inTableView:(NSTableView *)tableView;
@end

@interface SPCellClickRecorder : NSObject <NSTableViewDataSource>
@property (strong) NSMutableArray<NSString *> *clicks;
@end
@implementation SPCellClickRecorder
- (instancetype)init { if ((self = [super init])) _clicks = [NSMutableArray array]; return self; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return 1; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row { return @"x"; }
- (void)linkClicked:(SPTextAndLinkCell *)cell { [_clicks addObject:[NSString stringWithFormat:@"link %ld,%ld", (long)[cell getClickedRow], (long)[cell getClickedColumn]]]; }
- (void)valueClicked:(SPTextAndLinkCell *)cell { [_clicks addObject:[NSString stringWithFormat:@"value %ld,%ld", (long)[cell getClickedRow], (long)[cell getClickedColumn]]]; }
@end

@interface SPTextAndLinkCellValueIconTests : XCTestCase
@end

@implementation SPTextAndLinkCellValueIconTests

static NSString *SPRepeat(NSUInteger count)
{
	return [@"" stringByPaddingToLength:count withString:@"x" startingAtIndex:0];
}

- (void)testOffersValueRule
{
	// Every value of a text column, whatever its length
	XCTAssertTrue(SPValuePopoverOffersValue(@"x", YES));
	XCTAssertTrue(SPValuePopoverOffersValue(@"", YES));
	XCTAssertTrue(SPValuePopoverOffersValue(SPRepeat(5000), YES));
	XCTAssertFalse(SPValuePopoverOffersValue(@"42", NO), @"not a text column (numbers, dates, binary)");
	XCTAssertTrue(SPValuePopoverOffersValue([NSNull null], YES), @"NULL too: it can be edited into a value");
	XCTAssertFalse(SPValuePopoverOffersValue([NSNull null], NO));
	XCTAssertFalse(SPValuePopoverOffersValue(nil, YES));
	XCTAssertFalse(SPValuePopoverOffersValue([NSData dataWithBytes:"x" length:1], YES));
}

- (void)testValueIconRectSitsLeftOfArrow
{
	NSRect cell = NSMakeRect(10, 20, 200, 17);
	NSRect withArrow = SPTextValueIconRectFromCellRect(cell, YES);
	NSRect alone = SPTextValueIconRectFromCellRect(cell, NO);
	NSRect arrow = SPTextLinkRectFromCellRect(cell);
	XCTAssertLessThanOrEqual(NSMaxX(withArrow), NSMinX(arrow));
	XCTAssertGreaterThan(NSMinX(withArrow), NSMinX(cell));
	XCTAssertEqualWithAccuracy(NSMaxX(alone), NSMaxX(cell) - 2, 2.0, @"at the right edge without an arrow");
	XCTAssertEqual(NSHeight(alone), NSHeight(cell));
}

- (void)testValueIconSitsAtTheRightEdgeAsTheArrowDoes
{
	NSRect cell = NSMakeRect(10, 20, 200, 17);
	XCTAssertTrue(NSEqualRects(SPTextValueIconRectFromCellRect(cell, NO), SPTextLinkRectFromCellRect(cell)), @"alone: exactly where the arrow would be");
	NSRect withArrow = SPTextValueIconRectFromCellRect(cell, YES);
	XCTAssertEqualWithAccuracy(NSMinX(SPTextLinkRectFromCellRect(cell)) - NSMaxX(withArrow), 2.0, 0.01, @"with the arrow: right next to it");
	XCTAssertEqual(NSWidth(withArrow), NSWidth(SPTextLinkRectFromCellRect(cell)));
	XCTAssertEqual([[[SPTextAndLinkCell alloc] initTextCell:@""] valueIconImagePosition], NSImageRight, @"the image hugs the right, as the arrow's");
}

- (void)testTextAreaLeavesRoomForIcon
{
	SPTextAndLinkCell *cell = [[SPTextAndLinkCell alloc] initTextCell:@""];
	NSRect frame = NSMakeRect(0, 0, 200, 17);
	XCTAssertEqual(NSWidth([cell textFrameForCellFrame:frame]), 200.0, @"no buttons: the whole cell");

	[cell setValueTarget:self action:@selector(description)]; [cell setLineBreakMode:NSLineBreakByClipping];
	XCTAssertEqual(NSWidth([cell textFrameForCellFrame:frame]), 200.0, @"icon not active yet");
	cell.valueIconActive = YES;
	CGFloat withIcon = NSWidth([cell textFrameForCellFrame:frame]);
	XCTAssertLessThan(withIcon, 200.0);
	XCTAssertLessThanOrEqual(withIcon, NSMinX(SPTextValueIconRectFromCellRect(frame, NO)) - 6, @"room between the text and the icon");

	[cell setTarget:self action:@selector(description)];
	cell.linkActive = YES;
	XCTAssertLessThanOrEqual(NSWidth([cell textFrameForCellFrame:frame]), NSMinX(SPTextValueIconRectFromCellRect(frame, YES)) - 6);
}

- (void)testValueIconAndLinkArrowHitSeparately
{
	SPCellClickRecorder *recorder = [[SPCellClickRecorder alloc] init];
	SPTextAndLinkCell *cell = [[SPTextAndLinkCell alloc] initTextCell:@""];
	[cell setTarget:recorder action:@selector(linkClicked:)];
	[cell setValueTarget:recorder action:@selector(valueClicked:)];
	NSRect frame = NSMakeRect(0, 0, 200, 17);
	NSRect icon = SPTextValueIconRectFromCellRect(frame, YES);
	NSRect arrow = SPTextLinkRectFromCellRect(frame);
	NSPoint inIcon = NSMakePoint(NSMidX(icon), NSMidY(icon));
	NSPoint inArrow = NSMakePoint(NSMidX(arrow), NSMidY(arrow));
	NSPoint inText = NSMakePoint(20, 8);

	// Neither active: nothing to hit
	XCTAssertEqual([cell buttonAtPoint:inIcon inCellFrame:frame], SPTextAndLinkCellNoButton);
	XCTAssertEqual([cell buttonAtPoint:inArrow inCellFrame:frame], SPTextAndLinkCellNoButton);

	cell.linkActive = YES;
	cell.valueIconActive = YES;
	XCTAssertEqual([cell buttonAtPoint:inIcon inCellFrame:frame], SPTextAndLinkCellValueButton);
	XCTAssertEqual([cell buttonAtPoint:inArrow inCellFrame:frame], SPTextAndLinkCellLinkButton);
	XCTAssertEqual([cell buttonAtPoint:inText inCellFrame:frame], SPTextAndLinkCellNoButton);

	// Only the arrow: the icon's place is text again
	cell.valueIconActive = NO;
	XCTAssertEqual([cell buttonAtPoint:inIcon inCellFrame:frame], SPTextAndLinkCellNoButton);
	XCTAssertEqual([cell buttonAtPoint:inArrow inCellFrame:frame], SPTextAndLinkCellLinkButton);

	// Only the icon: it sits at the right edge, where the arrow would be
	cell.linkActive = NO;
	cell.valueIconActive = YES;
	NSRect lone = SPTextValueIconRectFromCellRect(frame, NO);
	XCTAssertEqual([cell buttonAtPoint:NSMakePoint(NSMidX(lone), NSMidY(lone)) inCellFrame:frame], SPTextAndLinkCellValueButton);

	// Each click fires its own action, with the clicked row and column
	NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"0"];
	[column setWidth:280];
	[table addTableColumn:column];
	[table setDataSource:recorder];
	[table reloadData];
	[table tile];
	cell.linkActive = YES;
	[cell _followButton:SPTextAndLinkCellValueButton atPoint:NSMakePoint(5, 5) inTableView:table];
	[cell _followButton:SPTextAndLinkCellLinkButton atPoint:NSMakePoint(5, 5) inTableView:table];
	NSString *where = [NSString stringWithFormat:@"%ld,%ld", (long)[table rowAtPoint:NSMakePoint(5, 5)], (long)[table columnAtPoint:NSMakePoint(5, 5)]];
	XCTAssertEqualObjects(recorder.clicks, (@[[@"value " stringByAppendingString:where], [@"link " stringByAppendingString:where]]));
}

@end
