#import <Cocoa/Cocoa.h>

/**
 * A resizable sheet listing rows of strings in a table, built in code: Database ▸ Show Server Variables… (pg_settings)
 * and Show Server Processes… (pg_stat_activity).
 *
 * columns: dictionaries with @"key" (the rows' key, also the column's identifier), @"title" and optionally @"width".
 * The filter field shows the rows any of whose values contains its text (case-insensitive). ⌘C (Edit ▸ Copy) copies
 * the selected rows, their values tab-separated in column order, one per line. Close ends the sheet.
 *
 * With a refresh block there is a Refresh button (it calls the block, which sets rows when it has read them). With a
 * process action block there are Cancel Query and Kill Connection buttons, enabled when one row is selected that is not
 * the tab's own session (its @"own" is @"true"); they call the block with that row and terminate NO / YES. Rows are
 * matched across a refresh by @"pid" (the selection follows it), else by index.
 *
 * Use on the main thread. completion is called once, when the sheet closes (nil: not shown, see the return value).
 */
__attribute__((visibility("default")))
@interface SPPostgresServerListSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>

+ (SPPostgresServerListSheet *)beginOnWindow:(NSWindow *)window
									   title:(NSString *)title
									 columns:(NSArray<NSDictionary *> *)columns
										rows:(NSArray<NSDictionary *> *)rows
									 refresh:(void (^)(void))refresh
							   processAction:(void (^)(NSDictionary *row, BOOL terminate))processAction
								  completion:(void (^)(void))completion;

/// The sheet that is open, nil when none is.
+ (SPPostgresServerListSheet *)currentSheet;

/// All rows (setting it reloads the table, keeping the filter and, by pid, the selection).
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;
/// The rows the table shows (those the filter matches).
@property (readonly) NSArray<NSDictionary *> *displayedRows;

@property (readonly) NSWindow *sheet;
@property (readonly) NSTableView *tableView;
@property (readonly) NSSearchField *filterField;
@property (readonly) NSTextField *countLabel;
@property (readonly) NSButton *refreshButton;      // nil without a refresh block
@property (readonly) NSButton *cancelQueryButton;  // nil without a process action block
@property (readonly) NSButton *killButton;         // nil without a process action block
@property (readonly) NSButton *closeButton;

- (IBAction)updateFilter:(id)sender;
- (IBAction)refresh:(id)sender;
- (IBAction)cancelQuery:(id)sender;
- (IBAction)killConnection:(id)sender;
- (IBAction)close:(id)sender;
/// The selected rows, tab-separated (see above); nil when none is selected.
- (NSString *)selectedRowsText;
- (IBAction)copy:(id)sender;

@end
