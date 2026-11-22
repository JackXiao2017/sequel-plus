//
//  SPPostgresFilterRowsController.h
//  Sequel Plus
//

#import <Cocoa/Cocoa.h>

@class SPPostgresFilter;

NS_ASSUME_NONNULL_BEGIN

/**
 * The filter area of a PostgreSQL tab's Content view, as a MySQL tab's (DBView.xib's Filter Rule Editor Container):
 * condition rows (an NSRuleEditor in list mode: column, comparison, value, − and +) in a scroll view starting 31 pt up,
 * over a 23 pt SPButtonBar with Reset (⌘⎋) and, in one place, Add Filter (no rows) or Filter (rows), as MySQL's.
 * Every row is one SPPostgresFilter; the caller ANDs
 * them. It knows nothing of tables or loading: it reports through the callbacks.
 */
__attribute__((visibility("default")))
@interface SPPostgresFilterRowsController : NSObject

/// The comparisons a row offers, in menu order.
+ (NSArray<NSString *> *)comparisons;

/// The area: the rules' scroll view (y = 31) over the button bar (y = 0). Width-sizable; the caller sizes its height
/// and the scroll view's (see preferredHeight).
@property (readonly) NSView *view;
@property (readonly) NSRuleEditor *ruleEditor;
@property (readonly) NSButton *resetButton, *addFilterButton, *filterButton;

/// The columns a row can filter on. Setting it removes every row; with none, all controls are disabled.
@property (copy) NSArray<NSString *> *columnNames;

- (NSUInteger)numberOfRows;
/// Inserts a row after row (−1 appends): column (nil: row's column, or the first column when appending or there is no
/// such row), comparison (nil: "="), value (nil: empty; not shown for IS NULL / IS NOT NULL). Nothing without columns.
- (void)addRowAfter:(NSInteger)row column:(nullable NSString *)column comparison:(nullable NSString *)comparison value:(nullable NSString *)value;
- (void)removeAllRows;
/// Replaces the rows with one per filter, skipping filters on a column not in columnNames or with an unknown comparison.
- (void)setFilters:(NSArray<SPPostgresFilter *> *)filters;
/// Every row as typed, in order (value @"" where none is shown).
- (NSArray<SPPostgresFilter *> *)typedFilters;
/// The rows that make a condition: comparisons without a value, or a non-empty value.
- (NSArray<SPPostgresFilter *> *)completeFilters;
/// The row's value field, or nil when its comparison takes no value.
- (nullable NSTextField *)valueFieldInRow:(NSUInteger)row;
/// Makes the row's value field first responder (when it has one and is in a window).
- (void)focusValueInRow:(NSUInteger)row;

/// Drops every target, delegate and callback (the view may outlive whoever owns this controller).
- (void)invalidate;

/// The area's height for all rows: rows × 29 + 31.
@property (readonly) CGFloat preferredHeight;

/// Filter, or Return in a value field.
@property (copy, nullable) void (^onApply)(void);
/// Reset (also ⌘⎋), after it has emptied the rows.
@property (copy, nullable) void (^onReset)(void);
/// A row's − removed the only row (not called when rows are removed through this class).
@property (copy, nullable) void (^onLastRowRemoved)(void);
/// The number of rows, and so preferredHeight, changed.
@property (copy, nullable) void (^onHeightChanged)(void);

@end

NS_ASSUME_NONNULL_END
