#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>
#import "SPPostgresTestServers.h"
#import "../Source/SPWindowController.h"
#import "../Source/Postgres/SPPostgresDocument.h"
#import "../Source/Postgres/SPPostgresSidebarController.h"
#import "../Source/Postgres/SPPostgresContentController.h"
#import "../Source/Postgres/SPPostgresQueryController.h"
#import "../Source/Postgres/SPPostgresConnector.h"
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresTaskRunner.h"
#import "../Source/Postgres/SPPostgresDateTimePicker.h"

static const NSUInteger SPDateTimePickerTestPort = 55418;
static NSString * const SPDateTimePickerSuiteName = @"SPPostgresDateTimePickerTests";

@interface SPPostgresQueryController (SPDateTimePickerTests)
- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row;
@end

/**
 * The date / time picker of the Content and Query result grids: reading and writing values, its controls, and the
 * grids opening it on date and time cells (public.sp_dtp_dates, made and dropped here).
 */
@interface SPPostgresDateTimePickerTests : XCTestCase
@property (strong) SPWindowController *controller;
@property (strong) SPPostgresDocument *document;
@property (strong) SPPostgresQueryController *query;
@property (strong) NSWindow *window;
@property (strong) NSUserDefaults *scratch;
@property (strong) NSMutableArray<NSAlert *> *alerts;
@end

@implementation SPPostgresDateTimePickerTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (!condition() && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}

- (void)setUp
{
	self.continueAfterFailure = NO;
	self.alerts = [NSMutableArray array];
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPDateTimePickerTestPort];
	[admin execute:@"DROP TABLE IF EXISTS public.sp_dtp_dates"];
	XCTAssertNotNil([admin execute:@"CREATE TABLE public.sp_dtp_dates (id integer PRIMARY KEY, d date, t time, ttz timetz, ts timestamp(3), tstz timestamptz NOT NULL)"], @"%@", admin.lastError.errorPrimaryMessage);
	XCTAssertNotNil([admin execute:@"INSERT INTO public.sp_dtp_dates VALUES (1, '2026-11-03', '14:05:09', '14:05:09+05:30', '2026-11-03 14:05:09.250', '2026-11-03 14:05:09+08')"]);
}

- (void)tearDown
{
	if ([SPPostgresDateTimePicker currentPicker]) [[SPPostgresDateTimePicker currentPicker] cancel:nil];
	[self.query invalidate];
	[[self.query view] removeFromSuperview];
	self.query = nil;
	[self.window close];
	self.window = nil;
	if (self.controller) {
		NSWindow *window = [self.controller window];
		if (window.attachedSheet) [window endSheet:window.attachedSheet];
		NSTabView *tabView = [self.controller valueForKey:@"tabView"];
		for (NSTabViewItem *item in [tabView tabViewItems]) [tabView removeTabViewItem:item];
		[window orderOut:nil];
	}
	self.document = nil;
	self.controller = nil;
	if (self.scratch) [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPDateTimePickerSuiteName];
	self.scratch = nil;
	[[SPPostgresTestServers connectedConnectionOnPort:SPDateTimePickerTestPort] execute:@"DROP TABLE IF EXISTS public.sp_dtp_dates"];
	[SPPostgresTestServers disconnectConnectionsOpenedDuringCurrentTest];
	[super tearDown];
}

- (id)serverValue:(NSString *)sql
{
	PGPostgresConnection *admin = [SPPostgresTestServers connectedConnectionOnPort:SPDateTimePickerTestPort];
	id value = nil;
	for (NSDictionary *row in [admin execute:sql]) value = [[row allValues] firstObject];
	return value;
}

#pragma mark - Reading and writing values

- (void)testKindsOfTypeNames
{
	NSDictionary *kinds = @{@"date": @(SPPostgresTemporalDate),
							@"time without time zone": @(SPPostgresTemporalTime), @"time(3) without time zone": @(SPPostgresTemporalTime), @"time": @(SPPostgresTemporalTime),
							@"time with time zone": @(SPPostgresTemporalTimeTZ), @"timetz": @(SPPostgresTemporalTimeTZ),
							@"timestamp without time zone": @(SPPostgresTemporalTimestamp), @"timestamp(6) without time zone": @(SPPostgresTemporalTimestamp),
							@"timestamp with time zone": @(SPPostgresTemporalTimestampTZ), @"timestamp(0) with time zone": @(SPPostgresTemporalTimestampTZ), @"timestamptz": @(SPPostgresTemporalTimestampTZ),
							@"date[]": @(SPPostgresTemporalNone), @"timestamp without time zone[]": @(SPPostgresTemporalNone),
							@"interval": @(SPPostgresTemporalNone), @"text": @(SPPostgresTemporalNone), @"": @(SPPostgresTemporalNone)};
	for (NSString *name in kinds) XCTAssertEqual([SPPostgresDateTimePicker kindOfTypeName:name], [kinds[name] integerValue], @"%@", name);
	XCTAssertEqual([SPPostgresDateTimePicker kindOfTypeName:nil], SPPostgresTemporalNone);
}

- (void)testValuesReadAndWrittenInTheISOStyle
{
	NSTimeZone *zone = nil;
	// date
	NSDate *date = [SPPostgresDateTimePicker dateFromText:@"2026-11-03" kind:SPPostgresTemporalDate timeZone:&zone];
	XCTAssertEqualObjects([SPPostgresDateTimePicker textFromDate:date kind:SPPostgresTemporalDate timeZone:zone], @"2026-11-03");
	// timestamp: fractions read (dropped when written); a T separator
	date = [SPPostgresDateTimePicker dateFromText:@"2026-11-03T14:05:09.250" kind:SPPostgresTemporalTimestamp timeZone:&zone];
	XCTAssertEqualObjects([SPPostgresDateTimePicker textFromDate:date kind:SPPostgresTemporalTimestamp timeZone:zone], @"2026-11-03 14:05:09");
	// timestamptz keeps the value's offset (+08 as the server writes it, +05:30, -03:30, Z)
	for (NSArray *pair in @[@[@"2026-11-03 14:05:09+08", @"2026-11-03 14:05:09+08:00"], @[@"2026-11-03 14:05:09.5+05:30", @"2026-11-03 14:05:09+05:30"],
							@[@"2026-01-31 23:59:59-03:30", @"2026-01-31 23:59:59-03:30"], @[@"2026-11-03 00:00:00Z", @"2026-11-03 00:00:00+00:00"]]) {
		date = [SPPostgresDateTimePicker dateFromText:pair[0] kind:SPPostgresTemporalTimestampTZ timeZone:&zone];
		XCTAssertNotNil(date, @"%@", pair[0]);
		XCTAssertEqualObjects([SPPostgresDateTimePicker textFromDate:date kind:SPPostgresTemporalTimestampTZ timeZone:zone], pair[1]);
	}
	// The instant is right: +08 is 06:05:09 UTC
	date = [SPPostgresDateTimePicker dateFromText:@"2026-11-03 14:05:09+08" kind:SPPostgresTemporalTimestampTZ timeZone:&zone];
	XCTAssertEqualObjects([SPPostgresDateTimePicker textFromDate:date kind:SPPostgresTemporalTimestampTZ timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]], @"2026-11-03 06:05:09+00:00");
	// time, timetz
	date = [SPPostgresDateTimePicker dateFromText:@"14:05:09.123" kind:SPPostgresTemporalTime timeZone:&zone];
	XCTAssertEqualObjects([SPPostgresDateTimePicker textFromDate:date kind:SPPostgresTemporalTime timeZone:zone], @"14:05:09");
	date = [SPPostgresDateTimePicker dateFromText:@"14:05+05:30" kind:SPPostgresTemporalTimeTZ timeZone:&zone];
	XCTAssertEqualObjects([SPPostgresDateTimePicker textFromDate:date kind:SPPostgresTemporalTimeTZ timeZone:zone], @"14:05:00+05:30");
	// A zoned value without an offset: the Mac's zone
	[SPPostgresDateTimePicker dateFromText:@"2026-11-03 14:05:09" kind:SPPostgresTemporalTimestampTZ timeZone:&zone];
	XCTAssertEqual([zone secondsFromGMT], [[NSTimeZone localTimeZone] secondsFromGMT]);

	// Not read: special values, other styles, impossible days, nonsense
	for (NSString *text in @[@"infinity", @"-infinity", @"epoch", @"2026-02-30", @"2026-13-01", @"03/11/2026", @"2026-11-03 25:00:00", @"", @"14:05"]) {
		SPPostgresTemporalKind kind = [text isEqualToString:@"14:05"] ? SPPostgresTemporalDate : SPPostgresTemporalTimestamp;
		XCTAssertNil([SPPostgresDateTimePicker dateFromText:text kind:kind timeZone:&zone], @"%@", text);
	}
	XCTAssertNotNil([SPPostgresDateTimePicker dateFromText:@"2028-02-29" kind:SPPostgresTemporalDate timeZone:&zone], @"a leap day");
}

#pragma mark - The picker's controls

- (void)testControlsFollowTheKind
{
	SPPostgresDateTimePicker *date = [[SPPostgresDateTimePicker alloc] initWithValue:@"2026-11-03" typeName:@"date" allowNull:YES completion:nil];
	XCTAssertNotNil(date.calendarPicker);
	XCTAssertNil(date.timePicker);
	XCTAssertEqualObjects(date.nowButton.title, @"Today");
	XCTAssertNotNil(date.nullButton);
	XCTAssertEqualObjects(date.textField.stringValue, @"2026-11-03");
	XCTAssertEqualObjects([date.calendarPicker.dateValue description], [[SPPostgresDateTimePicker dateFromText:@"2026-11-03" kind:SPPostgresTemporalDate timeZone:NULL] description], @"the calendar starts on the cell's day");

	SPPostgresDateTimePicker *time = [[SPPostgresDateTimePicker alloc] initWithValue:@"14:05:09" typeName:@"time without time zone" allowNull:NO completion:nil];
	XCTAssertNil(time.calendarPicker);
	XCTAssertNotNil(time.timePicker);
	XCTAssertEqualObjects(time.nowButton.title, @"Now");
	XCTAssertNil(time.nullButton, @"not nullable");

	SPPostgresDateTimePicker *stamp = [[SPPostgresDateTimePicker alloc] initWithValue:[NSNull null] typeName:@"timestamp with time zone" allowNull:YES completion:nil];
	XCTAssertNotNil(stamp.calendarPicker);
	XCTAssertNotNil(stamp.timePicker);
	XCTAssertEqualObjects(stamp.textField.stringValue, @"", @"NULL starts empty");
	XCTAssertTrue([stamp.textField.placeholderString length] > 0, @"now as the placeholder");
	for (NSView *control in @[stamp.calendarPicker, stamp.timePicker, stamp.textField, stamp.setButton, stamp.cancelButton, stamp.nowButton, stamp.nullButton]) {
		XCTAssertEqual(control.superview, stamp.contentView);
		XCTAssertTrue(NSContainsRect(stamp.contentView.bounds, control.frame), @"%@ inside", control);
	}
}

- (void)testPickingTypingAndAnswers
{
	__block id answer = @"unset";
	SPPostgresDateTimePicker *picker = [[SPPostgresDateTimePicker alloc] initWithValue:@"2026-11-03 14:05:09" typeName:@"timestamp without time zone" allowNull:YES completion:^(id value) { answer = value; }];
	NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
	calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];

	// Another day on the calendar keeps the time; another time keeps the day
	NSDateComponents *day = [[NSDateComponents alloc] init];
	day.year = 2027; day.month = 1; day.day = 15;
	picker.calendarPicker.dateValue = [calendar dateFromComponents:day];
	[picker pickerChanged:picker.calendarPicker];
	XCTAssertEqualObjects(picker.textField.stringValue, @"2027-01-15 14:05:09");
	NSDateComponents *time = [[NSDateComponents alloc] init];
	time.year = 2000; time.month = 1; time.day = 1; time.hour = 8; time.minute = 30; time.second = 0;
	picker.timePicker.dateValue = [calendar dateFromComponents:time];
	[picker pickerChanged:picker.timePicker];
	XCTAssertEqualObjects(picker.textField.stringValue, @"2027-01-15 08:30:00");

	// Typing a value moves the pickers to it
	picker.textField.stringValue = @"2025-06-01 23:00:00";
	[picker controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:picker.textField]];
	XCTAssertEqualObjects([picker.calendarPicker.dateValue description], [[calendar dateFromComponents:({ NSDateComponents *c = [[NSDateComponents alloc] init]; c.year = 2025; c.month = 6; c.day = 1; c.hour = 23; c; })] description]);

	// Now: today's wall clock
	[picker setToNow:nil];
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	formatter.dateFormat = @"yyyy-MM-dd";
	XCTAssertTrue([picker.textField.stringValue hasPrefix:[formatter stringFromDate:[NSDate date]]], @"%@", picker.textField.stringValue);

	// Set: the text as typed (special values too), trimmed
	picker.textField.stringValue = @" infinity ";
	[picker set:nil];
	XCTAssertEqualObjects(answer, @"infinity");
	[picker cancel:nil];
	XCTAssertEqualObjects(answer, @"infinity", @"answered once");

	picker = [[SPPostgresDateTimePicker alloc] initWithValue:@"2026-11-03" typeName:@"date" allowNull:YES completion:^(id value) { answer = value; }];
	[picker setNull:nil];
	XCTAssertEqualObjects(answer, [NSNull null]);
	picker = [[SPPostgresDateTimePicker alloc] initWithValue:@"2026-11-03" typeName:@"date" allowNull:NO completion:^(id value) { answer = value; }];
	[picker setNull:nil];
	XCTAssertEqualObjects(answer, [NSNull null], @"refused: no answer yet");
	[picker cancel:nil];
	XCTAssertNil(answer);
}

#pragma mark - The grids

- (void)openDocument
{
	SPPostgresFavorite *favorite = [[SPPostgresFavorite alloc] init];
	favorite.name = @"pg18 date picker";
	favorite.type = SPPostgresTCPIPConnection;
	favorite.host = @"127.0.0.1";
	favorite.port = SPDateTimePickerTestPort;
	favorite.user = @"pgkit_test";
	favorite.database = @"pgkit_test";
	self.controller = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
	XCTAssertNotNil([self.controller window]);
	SPPostgresConnector *connector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:@"pgkit" sshPassword:nil parentWindow:nil];
	__block PGPostgresConnection *connection = nil;
	__block BOOL done = NO;
	[connector connectWithCompletion:^(PGPostgresConnection *theConnection, NSError *theError) { connection = theConnection; done = YES; }];
	XCTAssertTrue([self spinUntil:^BOOL{ return done; } timeout:20]);
	XCTAssertNotNil(connection);
	self.document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	NSMutableArray *alerts = self.alerts;
	self.document.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[self.controller addTabDocument:self.document atIndex:0 select:YES];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
}

/// Ends the grid's in-place edit as Return / clicking away does: the edited text is saved.
- (void)endEditingInGrid:(NSTableView *)grid
{
	XCTAssertNotNil([grid currentEditor]);
	[[grid window] makeFirstResponder:grid];
	XCTAssertNil([grid currentEditor]);
}

- (void)testContentOpensThePickerOnDateCells
{
	[self openDocument];
	XCTAssertTrue([self.document.sidebar selectTableNamed:@"sp_dtp_dates"]);
	[self.document viewContent:nil];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	NSTableView *grid = self.document.contentController.tableView;
	XCTAssertEqual(grid.numberOfRows, 1);
	NSTableColumn *(^column)(NSString *) = ^NSTableColumn *(NSString *name) {
		for (NSTableColumn *tableColumn in grid.tableColumns) if ([tableColumn.headerCell.stringValue isEqualToString:name]) return tableColumn;
		return nil;
	};
	BOOL (^shouldEdit)(NSString *) = ^BOOL(NSString *name) {
		return [(id<NSTableViewDelegate>)grid.delegate tableView:grid shouldEditTableColumn:column(name) row:0];
	};

	// A text cell: the in-cell editor, no picker
	XCTAssertTrue(shouldEdit(@"id"));
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);

	// Each date or time column: the picker instead, with its kind
	NSDictionary *kinds = @{@"d": @(SPPostgresTemporalDate), @"t": @(SPPostgresTemporalTime), @"ttz": @(SPPostgresTemporalTimeTZ),
							@"ts": @(SPPostgresTemporalTimestamp), @"tstz": @(SPPostgresTemporalTimestampTZ)};
	for (NSString *name in kinds) {
		XCTAssertFalse(shouldEdit(name), @"%@", name);
		SPPostgresDateTimePicker *picker = [SPPostgresDateTimePicker currentPicker];
		XCTAssertNotNil(picker, @"%@", name);
		XCTAssertEqual(picker.kind, [kinds[name] integerValue], @"%@", name);
		XCTAssertFalse(shouldEdit(@"d"), @"no second picker while one is open");
		[picker cancel:nil];
		XCTAssertNil([SPPostgresDateTimePicker currentPicker]);
	}
	XCTAssertEqualObjects([self serverValue:@"SELECT d::text FROM public.sp_dtp_dates"], @"2026-11-03", @"Cancel sends nothing");

	XCTAssertNil([grid currentEditor], @"Cancel: the cell isn't being edited");

	// Set: the picked value goes into the cell's in-place editor, not to the server, and the cell stays being edited
	XCTAssertFalse(shouldEdit(@"d"));
	SPPostgresDateTimePicker *picker = [SPPostgresDateTimePicker currentPicker];
	XCTAssertEqualObjects(picker.textField.stringValue, @"2026-11-03");
	XCTAssertNotNil(picker.nullButton, @"d takes NULL");
	picker.textField.stringValue = @"2027-01-15";
	[picker set:nil];
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);
	XCTAssertNotNil([grid currentEditor], @"the cell is being edited");
	XCTAssertEqual(grid.editedColumn, (NSInteger)[grid.tableColumns indexOfObject:column(@"d")]);
	XCTAssertEqual(grid.editedRow, 0);
	XCTAssertEqualObjects([[grid currentEditor] string], @"2027-01-15");
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT d::text FROM public.sp_dtp_dates"], @"2026-11-03", @"not saved yet");
	// Ending the edit saves it
	[self endEditingInGrid:grid];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT d::text FROM public.sp_dtp_dates"], @"2027-01-15");

	// NULL: the NULL placeholder in the editor, saved as NULL when the edit ends
	XCTAssertFalse(shouldEdit(@"ts"));
	[[SPPostgresDateTimePicker currentPicker] setNull:nil];
	XCTAssertEqualObjects([[grid currentEditor] string], @"NULL");
	XCTAssertEqualObjects([self serverValue:@"SELECT (ts IS NULL)::text FROM public.sp_dtp_dates"], @"false");
	[self endEditingInGrid:grid];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT (ts IS NULL)::text FROM public.sp_dtp_dates"], @"true");

	// A NOT NULL column has no NULL button; a zoned value keeps its offset
	XCTAssertFalse(shouldEdit(@"tstz"));
	picker = [SPPostgresDateTimePicker currentPicker];
	XCTAssertNil(picker.nullButton);
	NSTimeZone *zone = nil;
	XCTAssertNotNil([SPPostgresDateTimePicker dateFromText:picker.textField.stringValue kind:SPPostgresTemporalTimestampTZ timeZone:&zone], @"%@", picker.textField.stringValue);
	picker.textField.stringValue = @"2026-12-24 18:00:00+00:00";
	[picker set:nil];
	XCTAssertEqualObjects([[grid currentEditor] string], @"2026-12-24 18:00:00+00:00");
	[self endEditingInGrid:grid];
	XCTAssertTrue([SPPostgresTestServers waitForRunner:self.document.taskRunner timeout:30]);
	XCTAssertEqualObjects([self serverValue:@"SELECT (tstz = '2026-12-24 18:00:00+00')::text FROM public.sp_dtp_dates"], @"true");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts valueForKey:@"informativeText"]);
}

- (void)testQueryResultOpensThePickerOnDateCells
{
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:SPDateTimePickerSuiteName];
	self.scratch = [[NSUserDefaults alloc] initWithSuiteName:SPDateTimePickerSuiteName];
	[self.scratch setBool:NO forKey:@"EditInSheetEnabled"];
	[self.scratch setBool:NO forKey:@"ReloadAfterEditingRow"];
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 695, 534) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	self.window.releasedWhenClosed = NO;

	PGPostgresConnection *connection = [SPPostgresTestServers connectedConnectionOnPort:SPDateTimePickerTestPort database:@"pgkit_test"];
	self.query = [[SPPostgresQueryController alloc] initWithConnection:connection];
	self.query.defaults = self.scratch;
	NSMutableArray *alerts = self.alerts;
	self.query.alertPresenter = ^(NSAlert *alert) { [alerts addObject:alert]; };
	[[self.window contentView] addSubview:[self.query view]];
	[[self.query view] setFrame:[[self.window contentView] bounds]];

	[self.query.editor setString:@"SELECT id, t, ttz FROM public.sp_dtp_dates"];
	[self.query runAllQueries:nil];
	XCTAssertNotNil(self.query.resultEditor);
	NSTableView *grid = self.query.resultsView;
	BOOL (^shouldEdit)(NSInteger) = ^BOOL(NSInteger column) {
		return [self.query tableView:grid shouldEditTableColumn:grid.tableColumns[(NSUInteger)column] row:0];
	};

	XCTAssertTrue(shouldEdit(0), @"id: the in-cell editor");
	XCTAssertNil([SPPostgresDateTimePicker currentPicker]);

	XCTAssertFalse(shouldEdit(1), @"t: the picker");
	SPPostgresDateTimePicker *picker = [SPPostgresDateTimePicker currentPicker];
	XCTAssertEqual(picker.kind, SPPostgresTemporalTime);
	XCTAssertEqualObjects(picker.textField.stringValue, @"14:05:09");
	picker.textField.stringValue = @"09:15:00";
	[picker set:nil];
	XCTAssertEqual(grid.editedColumn, 1, @"the cell stays being edited");
	XCTAssertEqualObjects([[grid currentEditor] string], @"09:15:00");
	XCTAssertEqualObjects([self serverValue:@"SELECT t::text FROM public.sp_dtp_dates"], @"14:05:09", @"not saved yet");
	[self endEditingInGrid:grid];
	XCTAssertTrue([self spinUntil:^BOOL{ return ![self.query.taskRunner isBusy]; } timeout:20]);
	XCTAssertEqualObjects([self serverValue:@"SELECT t::text FROM public.sp_dtp_dates"], @"09:15:00");

	XCTAssertFalse(shouldEdit(2), @"ttz: the picker");
	picker = [SPPostgresDateTimePicker currentPicker];
	XCTAssertEqual(picker.kind, SPPostgresTemporalTimeTZ);
	[picker cancel:nil];
	XCTAssertNil([grid currentEditor], @"Cancel: the cell isn't being edited");
	XCTAssertEqualObjects([self serverValue:@"SELECT ttz::text FROM public.sp_dtp_dates"], @"14:05:09+05:30");
	XCTAssertEqual(self.alerts.count, 0u, @"%@", [self.alerts valueForKey:@"informativeText"]);
}

@end
