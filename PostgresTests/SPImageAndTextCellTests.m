#import <XCTest/XCTest.h>

// The MySQL table list's cell (not exported to the test bundle: looked up at run time)
@interface NSObject (SPImageAndTextCellTests)
- (void)setTrailingText:(NSString *)text;
- (NSString *)trailingText;
- (void)setIndentationLevel:(NSInteger)level;
@end

/// The table size the MySQL table list shows after a table's name: ImageAndTextCell's trailing text.
@interface SPImageAndTextCellTests : XCTestCase
@end

@implementation SPImageAndTextCellTests

- (NSTextFieldCell *)cellWithTitle:(NSString *)title trailing:(NSString *)trailing
{
	NSTextFieldCell *cell = [[NSClassFromString(@"ImageAndTextCell") alloc] initTextCell:title];
	XCTAssertNotNil(cell);
	[cell setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[cell setLineBreakMode:NSLineBreakByTruncatingTail];
	[(id)cell setTrailingText:trailing];
	return cell;
}

/// The cell drawn into a 200 x 17 bitmap; returns the alpha of each column (summed over the rows).
- (NSArray<NSNumber *> *)inkByColumnOf:(NSTextFieldCell *)cell
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:200 pixelsHigh:17 bitsPerSample:8 samplesPerPixel:4
	                                                                  hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
	NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 17)];
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
	[cell drawWithFrame:NSMakeRect(0, 0, 200, 17) inView:view];
	[NSGraphicsContext restoreGraphicsState];

	NSMutableArray *ink = [NSMutableArray array];
	for (NSInteger x = 0; x < 200; x++) {
		NSUInteger sum = 0;
		for (NSInteger y = 0; y < 17; y++) {
			NSUInteger pixel[4];
			[rep getPixel:pixel atX:x y:y];
			sum += pixel[3];
		}
		[ink addObject:@(sum)];
	}
	return ink;
}

- (NSUInteger)inkIn:(NSArray<NSNumber *> *)ink from:(NSInteger)start to:(NSInteger)end
{
	NSUInteger sum = 0;
	for (NSInteger x = start; x < end; x++) sum += [ink[x] unsignedIntegerValue];
	return sum;
}

- (void)testTrailingTextIsDrawnRightAlignedAfterTheName
{
	NSTextFieldCell *plain = [self cellWithTitle:@"orders" trailing:nil];
	NSTextFieldCell *sized = [self cellWithTitle:@"orders" trailing:@"16.0 KiB"];
	XCTAssertNil([(id)plain trailingText]);
	XCTAssertEqualObjects([(id)sized trailingText], @"16.0 KiB");
	XCTAssertEqualObjects([(id)[sized copy] trailingText], @"16.0 KiB", @"copies keep it");

	NSArray *plainInk = [self inkByColumnOf:plain];
	NSArray *sizedInk = [self inkByColumnOf:sized];
	XCTAssertEqual([self inkIn:plainInk from:140 to:200], 0u, @"no size: nothing at the right");
	XCTAssertGreaterThan([self inkIn:sizedInk from:150 to:200], 0u, @"the size at the right edge");
	XCTAssertEqual([self inkIn:sizedInk from:196 to:200], 0u, @"4 points from the edge");
	XCTAssertEqual([self inkIn:sizedInk from:0 to:60], [self inkIn:plainInk from:0 to:60], @"the name drawn as before");

	// Back to nil (the list's other rows): as before
	[(id)sized setTrailingText:nil];
	XCTAssertEqualObjects([self inkByColumnOf:sized], plainInk);
}

- (void)testLongNameTruncatesBeforeTheSize
{
	NSString *longName = @"a_very_long_table_name_that_does_not_fit_in_the_list_at_all";
	NSArray *plainInk = [self inkByColumnOf:[self cellWithTitle:longName trailing:nil]];
	NSArray *sizedInk = [self inkByColumnOf:[self cellWithTitle:longName trailing:@"1.2 GiB"]];
	XCTAssertGreaterThan([self inkIn:plainInk from:150 to:200], 0u, @"without a size the name fills the row");

	// With one, a gap separates the (truncated) name from the size
	NSInteger gap = 0, longestGap = 0;
	for (NSInteger x = 100; x < 196; x++) {
		gap = [sizedInk[x] unsignedIntegerValue] ? 0 : gap + 1;
		longestGap = MAX(longestGap, gap);
	}
	XCTAssertGreaterThanOrEqual(longestGap, 4);
}

@end
