//
//  SPForeignKeyPicker.h
//  Sequel Plus
//
//  The foreign key value picker of the MySQL and PostgreSQL Content views: a popover on the cell being edited that
//  lists rows of the referenced table (the key column first, in bold, then the columns ticked in the ⚙︎ menu,
//  remembered per table), narrowed by a search box over the shown columns and optional "+ Condition" rows (all
//  ANDed). Choose (Return, double-click) hands the row's key back as text; NULL, Type a value… and Cancel (Escape,
//  a click outside) are the other outcomes. Rows load 200 at a time. Use on the main thread.
//

#import <Cocoa/Cocoa.h>
#import "SPForeignKeyPickerDataSource.h"

@class SPForeignKeyPickerSettings;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPForeignKeyPickerOutcome) {
	SPForeignKeyPickerChose,      // value: the chosen row's key, as text
	SPForeignKeyPickerChoseNull,  // value: nil
	SPForeignKeyPickerTypeValue,  // value: nil; edit the cell as text instead
	SPForeignKeyPickerCancelled   // value: nil
};

/// One "+ Condition" row: column ▾, operator ▾, value (two for between), −.
__attribute__((visibility("default")))
@interface SPForeignKeyConditionRow : NSStackView
@property (readonly) NSPopUpButton *columnPopUp;
@property (readonly) NSPopUpButton *operatorPopUp;
@property (readonly) NSTextField *valueField;
@property (readonly) NSTextField *secondValueField; // shown for between
@property (readonly) NSButton *removeButton;
@end

__attribute__((visibility("default")))
@interface SPForeignKeyPicker : NSObject <NSPopoverDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>

/**
 * Starts loading the referenced table's columns and first page at once. title is shown after "Choose" (e.g.
 * "orders.customer_id · public.customers"); value is the cell's current value (its row is tinted when loaded).
 * completion is called exactly once, on the main thread.
 */
- (instancetype)initWithDataSource:(id<SPForeignKeyPickerDataSource>)source settings:(SPForeignKeyPickerSettings *)settings
						  tableKey:(NSString *)tableKey title:(NSString *)title currentValue:(nullable id)value allowNull:(BOOL)allowNull
						completion:(void (^)(SPForeignKeyPickerOutcome outcome, NSString * _Nullable value))completion;

/// Shows it as a transient popover on rect of view (the cell); closing it is Cancelled. NO (and Cancelled) when
/// view has no window.
- (BOOL)showRelativeToRect:(NSRect)rect ofView:(NSView *)view;

/// The popover's content view.
@property (readonly) NSView *contentView;

#pragma mark - For tests

@property (readonly) NSTextField *titleField;
@property (readonly) NSSearchField *searchField;
@property (readonly) NSTableView *resultsTable;
@property (readonly) NSStackView *conditionsView;     // SPForeignKeyConditionRow arranged subviews
@property (readonly, nullable) NSButton *nullButton;  // hidden when the column doesn't take NULL
@property (readonly) NSButton *loadMoreButton;        // hidden when every match is loaded
@property (readonly) NSArray<NSArray *> *rows;        // loaded rows, shown columns' values (NSString / NSNull)
@property (readonly, copy) NSString *statusText;      // the footer's count
@property (readonly, copy, nullable) NSString *errorMessage; // the server's message shown instead of the list
@property (readonly) NSInteger currentValueRow;       // the tinted row, or -1
@property NSTimeInterval searchDelay;                 // the search debounce (0.25 s; tests set 0)

- (void)addCondition;
/// The ⚙︎ menu (built afresh): "Show columns", a tick per column, Show All Columns, Reset to Default.
- (NSMenu *)columnsMenu;
- (void)loadMore;
- (void)choose;
- (void)chooseNull;
- (void)typeValue;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
