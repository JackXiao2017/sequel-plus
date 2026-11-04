#import "SPPostgresDateTimePicker.h"

static SPPostgresDateTimePicker *SPPostgresCurrentDateTimePicker = nil;

/// A gregorian calendar in timeZone (the fields the pickers and the text show).
static NSCalendar *SPPostgresPickerCalendar(NSTimeZone *timeZone)
{
	NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
	[calendar setTimeZone:timeZone ?: [NSTimeZone timeZoneForSecondsFromGMT:0]];
	return calendar;
}

static BOOL SPPostgresKindHasDate(SPPostgresTemporalKind kind)
{
	return kind == SPPostgresTemporalDate || kind == SPPostgresTemporalTimestamp || kind == SPPostgresTemporalTimestampTZ;
}

static BOOL SPPostgresKindHasTime(SPPostgresTemporalKind kind)
{
	return kind != SPPostgresTemporalDate && kind != SPPostgresTemporalNone;
}

static BOOL SPPostgresKindIsZoned(SPPostgresTemporalKind kind)
{
	return kind == SPPostgresTemporalTimeTZ || kind == SPPostgresTemporalTimestampTZ;
}

@implementation SPPostgresDateTimePicker
{
	SPPostgresTemporalKind kind;
	NSTimeZone *timeZone;
	NSDate *date;
	BOOL allowNull;
	void (^completion)(id);
	BOOL done;

	NSPopover *popover;
	NSViewController *contentController;
	NSView *contentView;
	NSDatePicker *calendarPicker;
	NSDatePicker *timePicker;
	NSTextField *textField;
	NSButton *nowButton;
	NSButton *nullButton;
	NSButton *setButton;
	NSButton *cancelButton;
}

@synthesize kind, contentView, calendarPicker, timePicker, textField, nowButton, nullButton, setButton, cancelButton;

#pragma mark - Types and values

+ (SPPostgresTemporalKind)kindOfTypeName:(NSString *)typeName
{
	NSString *type = [[typeName lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	if (![type length] || [type hasSuffix:@"]"]) return SPPostgresTemporalNone;
	// timestamp(3) with time zone -> timestamp with time zone
	NSRegularExpression *precision = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(\\s*\\d+\\s*\\)" options:0 error:NULL];
	type = [precision stringByReplacingMatchesInString:type options:0 range:NSMakeRange(0, [type length]) withTemplate:@""];

	if ([type isEqualToString:@"date"]) return SPPostgresTemporalDate;
	if ([type isEqualToString:@"time"] || [type isEqualToString:@"time without time zone"]) return SPPostgresTemporalTime;
	if ([type isEqualToString:@"timetz"] || [type isEqualToString:@"time with time zone"]) return SPPostgresTemporalTimeTZ;
	if ([type isEqualToString:@"timestamp"] || [type isEqualToString:@"timestamp without time zone"]) return SPPostgresTemporalTimestamp;
	if ([type isEqualToString:@"timestamptz"] || [type isEqualToString:@"timestamp with time zone"]) return SPPostgresTemporalTimestampTZ;
	return SPPostgresTemporalNone;
}

/// The offset of a zone suffix (Z, +08, +05:30, -0330, +01:02:03), in seconds; NO when it isn't one.
static BOOL SPPostgresOffsetSeconds(NSString *zone, NSInteger *seconds)
{
	if ([zone isEqualToString:@"Z"] || [zone isEqualToString:@"z"]) {
		*seconds = 0;
		return YES;
	}
	NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^([+-])(\\d{2})(?::?(\\d{2}))?(?::?(\\d{2}))?$" options:0 error:NULL];
	NSTextCheckingResult *match = [pattern firstMatchInString:zone options:0 range:NSMakeRange(0, [zone length])];
	if (!match) return NO;
	NSInteger value = [[zone substringWithRange:[match rangeAtIndex:2]] integerValue] * 3600;
	if ([match rangeAtIndex:3].location != NSNotFound) value += [[zone substringWithRange:[match rangeAtIndex:3]] integerValue] * 60;
	if ([match rangeAtIndex:4].location != NSNotFound) value += [[zone substringWithRange:[match rangeAtIndex:4]] integerValue];
	*seconds = [[zone substringWithRange:[match rangeAtIndex:1]] isEqualToString:@"-"] ? -value : value;
	return YES;
}

+ (NSDate *)dateFromText:(NSString *)text kind:(SPPostgresTemporalKind)theKind timeZone:(NSTimeZone **)outZone
{
	NSString *value = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![value length] || theKind == SPPostgresTemporalNone) return nil;

	NSString *datePart = @"(\\d{4,})-(\\d{1,2})-(\\d{1,2})";
	NSString *timePart = @"(\\d{1,2}):(\\d{2})(?::(\\d{2})(?:\\.\\d+)?)?";
	NSString *zonePart = @"\\s*(Z|z|[+-]\\d{2}(?::?\\d{2}(?::?\\d{2})?)?)?";
	NSString *patternString = nil;
	if (theKind == SPPostgresTemporalDate) patternString = [NSString stringWithFormat:@"^%@$", datePart];
	else if (SPPostgresKindHasDate(theKind)) patternString = [NSString stringWithFormat:@"^%@(?:[ T]%@)?%@$", datePart, timePart, zonePart];
	else patternString = [NSString stringWithFormat:@"^%@%@$", timePart, zonePart];

	NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:patternString options:0 error:NULL];
	NSTextCheckingResult *match = [pattern firstMatchInString:value options:0 range:NSMakeRange(0, [value length])];
	if (!match) return nil;

	NSInteger (^group)(NSUInteger, NSInteger) = ^NSInteger(NSUInteger index, NSInteger missing) {
		NSRange range = [match rangeAtIndex:index];
		return range.location == NSNotFound ? missing : [[value substringWithRange:range] integerValue];
	};
	NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
	NSUInteger next = 1;
	if (SPPostgresKindHasDate(theKind)) {
		[components setYear:group(1, 2000)];
		[components setMonth:group(2, 1)];
		[components setDay:group(3, 1)];
		next = 4;
	}
	else {
		[components setYear:2000];
		[components setMonth:1];
		[components setDay:1];
	}
	// A date has no time fields: midnight
	[components setHour:SPPostgresKindHasTime(theKind) ? group(next, 0) : 0];
	[components setMinute:SPPostgresKindHasTime(theKind) ? group(next + 1, 0) : 0];
	[components setSecond:SPPostgresKindHasTime(theKind) ? group(next + 2, 0) : 0];
	if ([components month] < 1 || [components month] > 12 || [components day] < 1 || [components day] > 31 ||
		[components hour] > 24 || [components minute] > 59 || [components second] > 60) return nil;

	// The zone: the value's offset for a zoned kind (else the Mac's); GMT for the others, which have none
	NSTimeZone *zone = [NSTimeZone timeZoneForSecondsFromGMT:0];
	if (SPPostgresKindIsZoned(theKind)) {
		zone = [NSTimeZone localTimeZone];
		NSRange zoneRange = [match rangeAtIndex:next + 3];
		NSInteger seconds = 0;
		if (zoneRange.location != NSNotFound && SPPostgresOffsetSeconds([value substringWithRange:zoneRange], &seconds)) {
			zone = [NSTimeZone timeZoneForSecondsFromGMT:seconds];
		}
	}

	NSCalendar *calendar = SPPostgresPickerCalendar(zone);
	NSDate *result = [calendar dateFromComponents:components];
	// A day the month doesn't have (2026-02-30) rolls over: refused
	NSDateComponents *check = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:result];
	if ([check year] != [components year] || [check month] != [components month] || [check day] != [components day]) {
		if ([components hour] != 24) return nil;
	}
	if (outZone) *outZone = zone;
	return result;
}

+ (NSString *)textFromDate:(NSDate *)theDate kind:(SPPostgresTemporalKind)theKind timeZone:(NSTimeZone *)zone
{
	if (!theDate || theKind == SPPostgresTemporalNone) return @"";
	NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
	[formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
	[formatter setCalendar:SPPostgresPickerCalendar(zone)];
	[formatter setTimeZone:zone ?: [NSTimeZone timeZoneForSecondsFromGMT:0]];
	NSDictionary *formats = @{@(SPPostgresTemporalDate): @"yyyy-MM-dd",
							  @(SPPostgresTemporalTime): @"HH:mm:ss",
							  @(SPPostgresTemporalTimeTZ): @"HH:mm:ssxxx",
							  @(SPPostgresTemporalTimestamp): @"yyyy-MM-dd HH:mm:ss",
							  @(SPPostgresTemporalTimestampTZ): @"yyyy-MM-dd HH:mm:ssxxx"};
	[formatter setDateFormat:formats[@(theKind)]];
	return [formatter stringFromDate:theDate];
}

#pragma mark - Picker

+ (SPPostgresDateTimePicker *)currentPicker
{
	return SPPostgresCurrentDateTimePicker;
}

- (NSButton *)_buttonWithTitle:(NSString *)title action:(SEL)action
{
	NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
	[button setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[button sizeToFit];
	return [button retain];
}

- (NSDatePicker *)_pickerWithStyle:(NSDatePickerStyle)style elements:(NSDatePickerElementFlags)elements
{
	NSDatePicker *picker = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
	[picker setDatePickerStyle:style];
	[picker setDatePickerElements:elements];
	[picker setDatePickerMode:NSDatePickerModeSingle];
	[picker setCalendar:SPPostgresPickerCalendar(timeZone)];
	[picker setTimeZone:timeZone];
	[picker setLocale:[NSLocale currentLocale]];
	[picker setDateValue:date];
	[picker setTarget:self];
	[picker setAction:@selector(pickerChanged:)];
	[picker sizeToFit];
	return picker;
}

+ (SPPostgresTemporalKind)kindOfMySQLTypeName:(NSString *)typeName
{
	NSString *type = [[typeName uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	NSRange paren = [type rangeOfString:@"("];
	if (paren.location != NSNotFound) type = [type substringToIndex:paren.location];
	if ([type isEqualToString:@"DATE"]) return SPPostgresTemporalDate;
	if ([type isEqualToString:@"TIME"]) return SPPostgresTemporalTime;
	if ([type isEqualToString:@"DATETIME"] || [type isEqualToString:@"TIMESTAMP"]) return SPPostgresTemporalTimestamp;
	return SPPostgresTemporalNone;
}

+ (BOOL)continueEditingColumn:(NSInteger)column row:(NSInteger)row ofTableView:(NSTableView *)tableView withText:(NSString *)text
{
	if (!tableView || column < 0 || column >= [tableView numberOfColumns] || row < 0 || row >= [tableView numberOfRows]) return NO;
	[tableView editColumn:column row:row withEvent:nil select:YES];
	NSTextView *editor = (NSTextView *)[tableView currentEditor];
	if (![editor isKindOfClass:[NSTextView class]]) return NO;
	[editor insertText:(text ?: @"") replacementRange:NSMakeRange(0, [[editor string] length])];
	return YES;
}

- (instancetype)initWithValue:(id)value typeName:(NSString *)typeName allowNull:(BOOL)nullable completion:(void (^)(id))theCompletion
{
	return [self initWithValue:value kind:[[self class] kindOfTypeName:typeName] allowNull:nullable completion:theCompletion];
}

- (instancetype)initWithValue:(id)value kind:(SPPostgresTemporalKind)theKind allowNull:(BOOL)nullable completion:(void (^)(id))theCompletion
{
	if (!(self = [super init])) return nil;
	kind = theKind;
	if (kind == SPPostgresTemporalNone) kind = SPPostgresTemporalTimestamp;
	allowNull = nullable;
	completion = [theCompletion copy];

	NSString *text = [value isKindOfClass:[NSString class]] ? value : @"";
	NSTimeZone *zone = nil;
	NSDate *read = [[self class] dateFromText:text kind:kind timeZone:&zone];
	timeZone = [(zone ?: (SPPostgresKindIsZoned(kind) ? [NSTimeZone localTimeZone] : [NSTimeZone timeZoneForSecondsFromGMT:0])) retain];
	if (read) date = [read retain];
	else {
		// Now, as the wall clock shows it (an unzoned value keeps its fields in GMT, so now's fields are moved there)
		NSDate *now = [NSDate date];
		if (!SPPostgresKindIsZoned(kind)) now = [now dateByAddingTimeInterval:[[NSTimeZone localTimeZone] secondsFromGMTForDate:now]];
		date = [now retain];
	}

	[self _buildViewWithText:text];
	return self;
}

- (void)_buildViewWithText:(NSString *)text
{
	CGFloat width = 260, margin = 12, y = margin;
	NSMutableArray *rows = [NSMutableArray array];

	// Bottom up: buttons, text field, time row, calendar
	setButton = [self _buttonWithTitle:NSLocalizedString(@"Set", @"Postgres date picker: set button") action:@selector(set:)];
	[setButton setKeyEquivalent:@"\r"];
	cancelButton = [self _buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") action:@selector(cancel:)];
	[cancelButton setKeyEquivalent:@"\033"];
	if (allowNull) nullButton = [self _buttonWithTitle:NSLocalizedString(@"NULL", @"Postgres date picker: NULL button") action:@selector(setNull:)];
	CGFloat buttonHeight = NSHeight([setButton frame]);
	[setButton setFrameOrigin:NSMakePoint(width - margin - NSWidth([setButton frame]), y)];
	[cancelButton setFrameOrigin:NSMakePoint(NSMinX([setButton frame]) - 4 - NSWidth([cancelButton frame]), y)];
	[nullButton setFrameOrigin:NSMakePoint(margin, y)];
	[rows addObjectsFromArray:nullButton ? @[setButton, cancelButton, nullButton] : @[setButton, cancelButton]];
	y += buttonHeight + 8;

	textField = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, y, width - 2 * margin, 22)];
	[textField setStringValue:text ?: @""];
	[textField setFont:[NSFont userFixedPitchFontOfSize:[NSFont smallSystemFontSize] + 1]];
	[textField setPlaceholderString:[[self class] textFromDate:date kind:kind timeZone:timeZone]];
	[[textField cell] setScrollable:YES];
	[textField setTarget:self];
	[textField setAction:@selector(set:)];
	[textField setDelegate:self];
	[rows addObject:textField];
	y += 22 + 8;

	NSString *nowTitle = (kind == SPPostgresTemporalDate) ? NSLocalizedString(@"Today", @"Postgres date picker: today button") : NSLocalizedString(@"Now", @"Postgres date picker: now button");
	nowButton = [self _buttonWithTitle:nowTitle action:@selector(setToNow:)];
	if (SPPostgresKindHasTime(kind)) {
		timePicker = [self _pickerWithStyle:NSDatePickerStyleTextFieldAndStepper elements:NSDatePickerElementFlagHourMinuteSecond];
		[timePicker setFrameOrigin:NSMakePoint(margin, y)];
		[rows addObject:timePicker];
	}
	CGFloat rowHeight = MAX(NSHeight([nowButton frame]), timePicker ? NSHeight([timePicker frame]) : 0);
	[nowButton setFrameOrigin:NSMakePoint(width - margin - NSWidth([nowButton frame]), y + (rowHeight - NSHeight([nowButton frame])) / 2)];
	[timePicker setFrameOrigin:NSMakePoint(margin, y + (rowHeight - NSHeight([timePicker frame])) / 2)];
	[rows addObject:nowButton];
	y += rowHeight + 8;

	if (SPPostgresKindHasDate(kind)) {
		calendarPicker = [self _pickerWithStyle:NSDatePickerStyleClockAndCalendar elements:NSDatePickerElementFlagYearMonthDay];
		[calendarPicker setFrameOrigin:NSMakePoint((width - NSWidth([calendarPicker frame])) / 2, y)];
		[rows addObject:calendarPicker];
		y += NSHeight([calendarPicker frame]) + 6;
	}

	contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, y + margin - 6)];
	for (NSView *subview in rows) [contentView addSubview:subview];
}

- (void)dealloc
{
	[popover setDelegate:nil];
	[popover release];
	[contentController release];
	[contentView release];
	[calendarPicker release];
	[timePicker release];
	[textField release];
	[nowButton release];
	[nullButton release];
	[setButton release];
	[cancelButton release];
	[timeZone release];
	[date release];
	[completion release];
	[super dealloc];
}

- (BOOL)showRelativeToRect:(NSRect)rect ofView:(NSView *)view
{
	if (![view window] || SPPostgresCurrentDateTimePicker) {
		[self _finishWith:nil];
		return NO;
	}
	SPPostgresCurrentDateTimePicker = [self retain]; // until it finishes

	contentController = [[NSViewController alloc] init];
	[contentController setView:contentView];
	popover = [[NSPopover alloc] init];
	[popover setContentViewController:contentController];
	[popover setContentSize:[contentView frame].size];
	[popover setBehavior:NSPopoverBehaviorTransient];
	[popover setDelegate:self];
	[popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMaxY];
	[[contentView window] makeFirstResponder:textField];
	[[textField currentEditor] selectAll:nil];
	return YES;
}

#pragma mark - Actions

/// The date the pickers show, combined: the calendar's day and the stepper's time.
- (void)pickerChanged:(id)sender
{
	NSCalendar *calendar = SPPostgresPickerCalendar(timeZone);
	NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:date];
	if (sender == calendarPicker || !timePicker) {
		NSDateComponents *day = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[calendarPicker dateValue] ?: date];
		[components setYear:[day year]];
		[components setMonth:[day month]];
		[components setDay:[day day]];
	}
	if (sender == timePicker && timePicker) {
		NSDateComponents *time = [calendar components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[timePicker dateValue]];
		[components setHour:[time hour]];
		[components setMinute:[time minute]];
		[components setSecond:[time second]];
	}
	[self _showDate:[calendar dateFromComponents:components]];
}

- (void)_showDate:(NSDate *)newDate
{
	if (!newDate) return;
	[date release];
	date = [newDate retain];
	if (calendarPicker && ![[calendarPicker dateValue] isEqualToDate:date]) [calendarPicker setDateValue:date];
	if (timePicker && ![[timePicker dateValue] isEqualToDate:date]) [timePicker setDateValue:date];
	[textField setStringValue:[[self class] textFromDate:date kind:kind timeZone:timeZone]];
}

/// Typing a value the pickers can read moves them to it.
- (void)controlTextDidChange:(NSNotification *)notification
{
	NSTimeZone *zone = nil;
	NSDate *typed = [[self class] dateFromText:[textField stringValue] kind:kind timeZone:&zone];
	if (!typed) return;
	if (zone && ![zone isEqualToTimeZone:timeZone]) {
		[timeZone release];
		timeZone = [zone retain];
		for (NSDatePicker *picker in @[calendarPicker ?: (id)[NSNull null], timePicker ?: (id)[NSNull null]]) {
			if (![picker isKindOfClass:[NSDatePicker class]]) continue;
			[picker setCalendar:SPPostgresPickerCalendar(timeZone)];
			[picker setTimeZone:timeZone];
		}
	}
	[date release];
	date = [typed retain];
	[calendarPicker setDateValue:date];
	[timePicker setDateValue:date];
}

- (IBAction)setToNow:(id)sender
{
	NSDate *now = [NSDate date];
	if (SPPostgresKindIsZoned(kind)) {
		// Now in the Mac's own zone
		[timeZone release];
		timeZone = [[NSTimeZone localTimeZone] retain];
		for (NSDatePicker *picker in @[calendarPicker ?: (id)[NSNull null], timePicker ?: (id)[NSNull null]]) {
			if (![picker isKindOfClass:[NSDatePicker class]]) continue;
			[picker setCalendar:SPPostgresPickerCalendar(timeZone)];
			[picker setTimeZone:timeZone];
		}
	}
	else {
		now = [now dateByAddingTimeInterval:[[NSTimeZone localTimeZone] secondsFromGMTForDate:now]];
	}
	[self _showDate:now];
}

- (IBAction)setNull:(id)sender
{
	if (!allowNull) {
		NSBeep();
		return;
	}
	[self _finishWith:[NSNull null]];
}

- (IBAction)set:(id)sender
{
	NSString *text = [[textField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[self _finishWith:text];
}

- (IBAction)cancel:(id)sender
{
	[self _finishWith:nil];
}

/// Calls completion once, closes the popover and lets go of the picker.
- (void)_finishWith:(id)value
{
	if (done) return;
	done = YES;
	void (^handler)(id) = [[completion retain] autorelease];
	[completion release];
	completion = nil;

	[popover setDelegate:nil];
	if ([popover isShown]) [popover close];
	if (handler) handler(value);
	if (SPPostgresCurrentDateTimePicker == self) {
		SPPostgresCurrentDateTimePicker = nil;
		[self autorelease];
	}
}

#pragma mark - Popover delegate

/// Escape or a click outside closes it: cancelled.
- (void)popoverDidClose:(NSNotification *)notification
{
	[self _finishWith:nil];
}

@end
