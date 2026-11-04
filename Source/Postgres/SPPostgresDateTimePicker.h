#import <Cocoa/Cocoa.h>

/// The date and time types the picker edits (format_type's names: date, time, timetz, timestamp, timestamptz).
typedef NS_ENUM(NSInteger, SPPostgresTemporalKind) {
	SPPostgresTemporalNone = 0,
	SPPostgresTemporalDate,
	SPPostgresTemporalTime,
	SPPostgresTemporalTimeTZ,
	SPPostgresTemporalTimestamp,
	SPPostgresTemporalTimestampTZ
};

/**
 * The date / time picker of the Content and Query result grids: a popover on the cell being edited with a calendar
 * (date and timestamp types), a time stepper (time and timestamp types), a text field holding the value as PostgreSQL
 * takes it, and Now (Today), NULL (when the column takes it), Cancel and Set. Picking a date or time writes the value
 * into the text field; typing in it still works (for 'infinity', BC dates, fractions of a second, …), and Set sends
 * whatever it holds. Use on the main thread.
 *
 * Values are read and written in the ISO style (DateStyle ISO, PostgreSQL's default): 2026-11-03, 14:05:09,
 * 2026-11-03 14:05:09, with an offset for the zoned types (+08:00). A zoned value keeps the offset it was read with
 * (the Mac's own for a new or unreadable one); a value that can't be read starts the pickers at now.
 */
__attribute__((visibility("default")))
@interface SPPostgresDateTimePicker : NSObject <NSPopoverDelegate, NSTextFieldDelegate>

/// The kind of a format_type name ("timestamp(3) with time zone", "date", …); None for arrays and other types.
+ (SPPostgresTemporalKind)kindOfTypeName:(NSString *)typeName;

/// The kind of a MySQL column type (DATE, TIME, DATETIME, TIMESTAMP; any precision); None for YEAR and other types.
/// MySQL values are read and written as the unzoned kinds: 2026-11-03, 14:05:09, 2026-11-03 14:05:09.
+ (SPPostgresTemporalKind)kindOfMySQLTypeName:(NSString *)typeName;

/// The date a value stands for, in the ISO style (nil when it can't be read), and the time zone it was read in (its
/// offset for a zoned kind, else GMT, where the unzoned kinds keep their wall-clock fields).
+ (NSDate *)dateFromText:(NSString *)text kind:(SPPostgresTemporalKind)kind timeZone:(NSTimeZone **)timeZone;

/// The value for date in the ISO style, its fields read in timeZone (offset written for the zoned kinds).
+ (NSString *)textFromDate:(NSDate *)date kind:(SPPostgresTemporalKind)kind timeZone:(NSTimeZone *)timeZone;

/**
 * A picker for value (an NSString; anything else is NULL) of a column of typeName. completion is called once: with the
 * text to send (Set), NSNull (NULL), or nil (Cancel, Escape, a click outside, or when it can't be shown).
 */
- (instancetype)initWithValue:(id)value typeName:(NSString *)typeName allowNull:(BOOL)allowNull completion:(void (^)(id newValueOrNil))completion;

/// As above, for a kind (None is taken as Timestamp); MySQL's grids use this with +kindOfMySQLTypeName:.
- (instancetype)initWithValue:(id)value kind:(SPPostgresTemporalKind)kind allowNull:(BOOL)allowNull completion:(void (^)(id newValueOrNil))completion;

/// Shows the picker as a popover on rect of view (the cell). NO (completion(nil) called) when view has no window.
- (BOOL)showRelativeToRect:(NSRect)rect ofView:(NSView *)view;

/**
 * Starts the in-place editor on tableView's cell and types text into it, replacing the cell's value, as the user would
 * (so the grid's textShouldBeginEditing check still applies); the cell stays being edited. MySQL's grids hand the
 * picker's value over with this. NO when no editor started.
 */
+ (BOOL)continueEditingColumn:(NSInteger)column row:(NSInteger)row ofTableView:(NSTableView *)tableView withText:(NSString *)text;

/// The picker that is open (shown or not yet), nil when none is.
+ (SPPostgresDateTimePicker *)currentPicker;

@property (readonly) SPPostgresTemporalKind kind;
/// The popover's content: the controls below.
@property (readonly) NSView *contentView;
@property (readonly) NSDatePicker *calendarPicker;   // nil for time kinds
@property (readonly) NSDatePicker *timePicker;       // nil for date
@property (readonly) NSTextField *textField;
@property (readonly) NSButton *nowButton;
@property (readonly) NSButton *nullButton;           // nil when the column doesn't take NULL
@property (readonly) NSButton *setButton;
@property (readonly) NSButton *cancelButton;

- (IBAction)pickerChanged:(id)sender;
- (IBAction)setToNow:(id)sender;
- (IBAction)setNull:(id)sender;
- (IBAction)set:(id)sender;
- (IBAction)cancel:(id)sender;

@end
