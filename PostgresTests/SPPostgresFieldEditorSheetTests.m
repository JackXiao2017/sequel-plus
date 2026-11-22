#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPPostgresFieldEditorSheet.h"
#import "../Source/SPFieldEditorController.h"

@interface SPFieldEditorController (SPPostgresFieldEditorSheetTests)
- (void)closeEditSheet:(id)sender;
@end

/// The shared field editor sheet. Only testLargeValueOpensAndSavesPromptly opens a real one.
@interface SPPostgresFieldEditorSheetTests : XCTestCase
@end

@implementation SPPostgresFieldEditorSheetTests

- (void)testMySQLOnlyTypesBlanked
{
	for (NSString *type in @[@"json", @"JSON", @"bit", @"float", @"Geometry", @"varbinary"]) {
		XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:type], @"", @"%@", type);
	}
	XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:nil], @"");
	XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:@"integer"], @"integer");
	XCTAssertEqualObjects([SPPostgresFieldEditorSheet fieldEditorTypeForTypeName:@"text"], @"text");
}

- (void)testNoWindowCompletesWithNil
{
	__block BOOL called = NO;
	__block id result = @"unset";
	[SPPostgresFieldEditorSheet editValue:@"v" columnName:@"c" typeName:@"text" editable:YES allowNull:YES window:nil
							   completion:^(id newValue) { called = YES; result = newValue; }];
	XCTAssertTrue(called, @"completes synchronously");
	XCTAssertNil(result);
}

/// A 3 MB value (what Content now sends to the sheet instead of the in-cell editor) opens, shows and saves without
/// hanging the main thread.
- (void)testLargeValueOpensAndSavesPromptly
{
	// 3 MB with no break anywhere (the hardest to wrap)
	NSMutableString *value = [NSMutableString stringWithCapacity:3000000];
	for (NSUInteger i = 0; i < 30000; i++) [value appendString:[@"" stringByPaddingToLength:100 withString:@"abcdefghij" startingAtIndex:i % 10]];
	[self assertLargeValueOpensAndSavesPromptly:value];
}

- (void)testLargeValueOfShortLinesOpensAndSavesPromptly
{
	// 3 MB of 100-character lines (a log, CSV, formatted JSON)
	NSMutableString *value = [NSMutableString stringWithCapacity:3000000];
	for (NSUInteger i = 0; i < 30000; i++) [value appendString:[[@"" stringByPaddingToLength:99 withString:@"word, " startingAtIndex:i % 6] stringByAppendingString:@"\n"]];
	[self assertLargeValueOpensAndSavesPromptly:value];
}

- (void)assertLargeValueOpensAndSavesPromptly:(NSString *)value
{
	__block id result = nil;
	__block BOOL done = NO;
	NSDate *start = [NSDate date];
	SPFieldEditorController *editor = nil;
	NSTextView *text = [self openSheetWithValue:value result:^(id newValue) { result = newValue; done = YES; } editor:&editor];
	[[text window] displayIfNeeded];
	NSTimeInterval opened = -[start timeIntervalSinceNow];
	XCTAssertLessThan(opened, 5.0, @"opening took %.1f s", opened);
	XCTAssertEqual([[text string] length], [value length]);

	[text setSelectedRange:NSMakeRange([[text string] length], 0)];
	[self typeKey:@"!" into:text];
	[editor closeEditSheet:[editor valueForKey:@"editSheetOkButton"]];
	for (NSUInteger i = 0; i < 50 && !done; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	NSTimeInterval total = -[start timeIntervalSinceNow];
	XCTAssertTrue(done);
	XCTAssertEqual([(NSString *)result length], [value length] + 1);
	XCTAssertLessThan(total, 10.0, @"open, type and save took %.1f s", total);
	NSLog(@"3 MB sheet: opened in %.2f s, saved after %.2f s", opened, total);
}

- (NSTextView *)openSheetWithValue:(NSString *)value result:(void (^)(id))completion editor:(SPFieldEditorController **)outEditor
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 700) styleMask:NSWindowStyleMaskTitled
													 backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[window orderFront:nil];
	[self addTeardownBlock:^{
		while (window.attachedSheet) [window endSheet:window.attachedSheet];
		[window orderOut:nil];
	}];
	[SPPostgresFieldEditorSheet editValue:value columnName:@"note" typeName:@"text" editable:YES allowNull:YES window:window completion:completion];
	XCTAssertNotNil(window.attachedSheet);
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
	SPFieldEditorController *editor = [[SPPostgresFieldEditorSheet openSheetOnWindow:window] valueForKey:@"fieldEditor"];
	NSTextView *text = [editor valueForKey:@"editTextView"];
	[[text window] makeFirstResponder:text];
	*outEditor = editor;
	return text;
}

/// A key press, as the keyboard sends it, to the text view's window.
- (void)typeKey:(NSString *)characters into:(NSTextView *)text
{
	NSWindow *window = [text window];
	NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime]
								windowNumber:[window windowNumber] context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:18];
	[window sendEvent:key];
}

/// What's typed is what OK saves, with no maximum length (PostgreSQL's sheet sets none; the sheet only noticed typing
/// when one was set, so OK returned the value as it was opened).
- (void)testTypedTextIsSavedWithoutMaximumLength
{
	__block id result = nil;
	__block BOOL done = NO;
	SPFieldEditorController *editor = nil;
	NSTextView *text = [self openSheetWithValue:@"abc" result:^(id newValue) { result = newValue; done = YES; } editor:&editor];
	[text setSelectedRange:NSMakeRange(3, 0)];
	[self typeKey:@"!" into:text];
	XCTAssertEqualObjects([text string], @"abc!");
	[editor closeEditSheet:[editor valueForKey:@"editSheetOkButton"]];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
	XCTAssertTrue(done);
	XCTAssertEqualObjects(result, @"abc!");
}

/// Pasted text (several characters at once) is saved too.
- (void)testPastedTextIsSavedWithoutMaximumLength
{
	__block id result = nil;
	SPFieldEditorController *editor = nil;
	NSTextView *text = [self openSheetWithValue:@"abc" result:^(id newValue) { result = newValue; } editor:&editor];
	[text setSelectedRange:NSMakeRange(0, 3)];
	[text insertText:@"pasted text" replacementRange:[text selectedRange]];
	[editor closeEditSheet:[editor valueForKey:@"editSheetOkButton"]];
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
	XCTAssertEqualObjects(result, @"pasted text");
}

@end
