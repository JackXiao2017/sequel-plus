#import <XCTest/XCTest.h>
#import "../Source/Postgres/SPQueryScriptStore.h"

@interface SPQueryScriptStoreTests : XCTestCase
@property (strong) NSURL *dir;
@property (strong) SPQueryScriptStore *store;
@end

@implementation SPQueryScriptStoreTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	NSString *name = [@"SPQueryScriptStoreTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	self.store = [[SPQueryScriptStore alloc] initWithDirectoryURL:[self.dir URLByAppendingPathComponent:@"Query Scripts" isDirectory:YES]];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
}

- (void)spinFor:(NSTimeInterval)seconds
{
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

/// Types `text` as the user does (the edit posts NSTextDidChangeNotification).
- (void)type:(NSString *)text into:(NSTextView *)textView
{
	[textView setSelectedRange:NSMakeRange([[textView string] length], 0)];
	[textView insertText:text replacementRange:[textView selectedRange]];
}

#pragma mark - Store

- (void)testSavesLoadsAndRemovesScripts
{
	NSString *key = [SPQueryScriptStore keyForEngine:SPQueryScriptEnginePostgreSQL favoriteID:@"ABC"];
	XCTAssertNil([self.store scriptForKey:key]);

	NSError *error = nil;
	XCTAssertTrue([self.store saveScript:@"SELECT 1;\n-- é" forKey:key error:&error], @"%@", error);
	XCTAssertEqualObjects([self.store scriptForKey:key], @"SELECT 1;\n-- é");
	XCTAssertTrue([[[self.store fileURLForKey:key] pathExtension] isEqualToString:@"sql"]);

	// A new store on the same folder reads it
	SPQueryScriptStore *other = [[SPQueryScriptStore alloc] initWithDirectoryURL:self.store.directoryURL];
	XCTAssertEqualObjects([other scriptForKey:key], @"SELECT 1;\n-- é");

	// Empty removes it
	XCTAssertTrue([self.store saveScript:@"" forKey:key error:&error], @"%@", error);
	XCTAssertNil([self.store scriptForKey:key]);
	XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[[self.store fileURLForKey:key] path]]);
	XCTAssertTrue([self.store saveScript:nil forKey:key error:&error], @"removing nothing is fine");
}

- (void)testKeysSeparateConnections
{
	NSString *pgFavorite = [SPQueryScriptStore keyForEngine:SPQueryScriptEnginePostgreSQL favoriteID:@"1"];
	NSString *mysqlFavorite = [SPQueryScriptStore keyForEngine:SPQueryScriptEngineMySQL favoriteID:@"1"];
	XCTAssertNotEqualObjects(pgFavorite, mysqlFavorite);
	XCTAssertNil([SPQueryScriptStore keyForEngine:SPQueryScriptEngineMySQL favoriteID:@""]);

	NSString *(^server)(NSString *, NSString *, NSString *) = ^NSString *(NSString *host, NSString *port, NSString *user) {
		return [SPQueryScriptStore keyForEngine:SPQueryScriptEngineMySQL type:0 host:host port:port user:user socket:nil sshHost:nil sshUser:nil];
	};
	XCTAssertEqualObjects(server(@"DB.example.com ", @"3306", @"root"), server(@"db.example.com", @"3306", @"root"), @"host ignores case and spaces");
	XCTAssertNotEqualObjects(server(@"db", @"3306", @"root"), server(@"db", @"3307", @"root"));
	XCTAssertNotEqualObjects(server(@"db", @"3306", @"root"), server(@"db", @"3306", @"alice"));
	XCTAssertNotEqualObjects(server(@"a|b", @"1", @"c"), server(@"a", @"b|1", @"c"), @"a separator in a value can't merge two connections");
	XCTAssertNotEqualObjects(server(@"db", @"3306", @"root"),
	                         [SPQueryScriptStore keyForEngine:SPQueryScriptEnginePostgreSQL type:0 host:@"db" port:@"3306" user:@"root" socket:nil sshHost:nil sshUser:nil]);
	XCTAssertNotEqualObjects(server(@"db", @"3306", @"root"),
	                         [SPQueryScriptStore keyForEngine:SPQueryScriptEngineMySQL type:2 host:@"db" port:@"3306" user:@"root" socket:nil sshHost:@"bastion" sshUser:@"me"]);
	XCTAssertNotEqualObjects([self.store fileURLForKey:pgFavorite], [self.store fileURLForKey:mysqlFavorite]);
}

#pragma mark - Autosaver

- (void)testTypingIsSavedAfterTheDelay
{
	NSString *key = @"k";
	NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	SPQueryScriptAutosaver *autosaver = [[SPQueryScriptAutosaver alloc] initWithTextView:textView store:self.store key:key];
	autosaver.delay = 0.1;

	[self type:@"SELECT now();" into:textView];
	XCTAssertNil([self.store scriptForKey:key], @"not before the delay");
	[self spinFor:0.4];
	XCTAssertEqualObjects([self.store scriptForKey:key], @"SELECT now();");

	// Clearing the editor removes the saved script
	[textView setSelectedRange:NSMakeRange(0, [[textView string] length])];
	[textView insertText:@"" replacementRange:[textView selectedRange]];
	[self spinFor:0.4];
	XCTAssertNil([self.store scriptForKey:key]);
	[autosaver invalidate];
}

- (void)testInvalidateSavesAPendingEditAndStopsWatching
{
	NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	SPQueryScriptAutosaver *autosaver = [[SPQueryScriptAutosaver alloc] initWithTextView:textView store:self.store key:@"k"];
	autosaver.delay = 60;

	[self type:@"SELECT 1;" into:textView];
	[autosaver invalidate];
	XCTAssertEqualObjects([self.store scriptForKey:@"k"], @"SELECT 1;", @"saved at once on invalidate");

	[self type:@" SELECT 2;" into:textView];
	[autosaver saveIfEdited];
	XCTAssertEqualObjects([self.store scriptForKey:@"k"], @"SELECT 1;", @"no longer watching");
}

- (void)testUneditedEditorNeverReplacesTheSavedScript
{
	XCTAssertTrue([self.store saveScript:@"SAVED" forKey:@"k" error:nil]);
	NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	[textView setString:@"SET BY CODE"];
	SPQueryScriptAutosaver *autosaver = [[SPQueryScriptAutosaver alloc] initWithTextView:textView store:self.store key:@"k"];
	[textView setString:@"ALSO BY CODE"];
	[autosaver invalidate];
	XCTAssertEqualObjects([self.store scriptForKey:@"k"], @"SAVED");
}

- (void)testLoadsOnlyIntoAnEmptyEditor
{
	XCTAssertTrue([self.store saveScript:@"SAVED" forKey:@"k" error:nil]);

	NSTextView *empty = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	SPQueryScriptAutosaver *autosaver = [[SPQueryScriptAutosaver alloc] initWithTextView:empty store:self.store key:@"k"];
	autosaver.delay = 0.05;
	__block NSUInteger inserts = 0;
	XCTAssertTrue([autosaver loadIntoEmptyEditorUsing:^(NSString *script) {
		inserts++;
		// As the MySQL editor's load does: an edit that posts the change notification
		[empty insertText:script replacementRange:NSMakeRange(0, 0)];
	}]);
	XCTAssertEqual(inserts, 1u);
	XCTAssertEqualObjects([empty string], @"SAVED");
	XCTAssertFalse([autosaver loadIntoEmptyEditorUsing:nil], @"not empty any more");
	[self spinFor:0.2];
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[[self.store fileURLForKey:@"k"] path]]);
	[autosaver invalidate];

	NSTextView *full = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	[full setString:@"MINE"];
	SPQueryScriptAutosaver *other = [[SPQueryScriptAutosaver alloc] initWithTextView:full store:self.store key:@"k"];
	XCTAssertFalse([other loadIntoEmptyEditorUsing:nil]);
	XCTAssertEqualObjects([full string], @"MINE");

	NSTextView *unknown = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	SPQueryScriptAutosaver *none = [[SPQueryScriptAutosaver alloc] initWithTextView:unknown store:self.store key:@"nothing saved"];
	XCTAssertFalse([none loadIntoEmptyEditorUsing:nil]);
	XCTAssertEqualObjects([unknown string], @"");
	[other invalidate];
	[none invalidate];
}

@end
