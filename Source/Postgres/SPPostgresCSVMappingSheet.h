#import <Cocoa/Cocoa.h>

/**
 * The CSV import's mapping sheet, built in code: the target table (a pop-up of the database's tables as
 * "schema.table"), a preview of the file's first rows, and for each column of the table a pop-up of the CSV's columns
 * plus "— Not imported —". Columns map by matching name (case-insensitive) first; when no name matches, by position.
 * A generated column is never imported (its pop-up is disabled). Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresCSVMappingSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate>

/**
 * tables: @[schema, table] pairs; selectedTable: the one to start with (nil or unlisted: the first). csvColumnNames:
 * the header's names (or "Column 1"…); previewRows: arrays of NSString/NSNull. columnsProvider returns a table's
 * columns in attnum order, each @{@"name": NSString, @"generated": NSNumber BOOL}, or nil with an error.
 */
- (instancetype)initWithTables:(NSArray *)tables
				 selectedTable:(NSArray *)selectedTable
				csvColumnNames:(NSArray *)csvColumnNames
				   previewRows:(NSArray *)previewRows
			   columnsProvider:(NSArray *(^)(NSString *schema, NSString *table, NSError **error))columnsProvider;

/// Shows the sheet on window; completion is called once, after the sheet ended, with YES for Import, NO for Cancel.
- (void)beginSheetForWindow:(NSWindow *)window completion:(void (^)(BOOL import))completion;

/// Ends the sheet as Cancel would.
- (void)cancelSheet;

/// The target: its schema and table.
@property (readonly) NSString *selectedSchema;
@property (readonly) NSString *selectedTable;

/// One entry per column of the target table (attnum order): the 0-based CSV column (NSNumber) or NSNull, as
/// +[SPPostgresCSV importPath:…columnMapping:…] takes it.
- (NSArray *)mapping;

/// The target table's column names, in the order of -columnPopups and -mapping.
@property (readonly) NSArray *tableColumnNames;

/// The last error reading a table's columns, or nil.
@property (readonly, copy) NSString *lastErrorMessage;

#pragma mark - For tests

@property (readonly) NSPanel *sheet;
/// Items "schema.table", each with @[schema, table] as its represented object.
@property (readonly) NSPopUpButton *tablePopup;
/// One column per CSV column (identifier its index as a string), the first rows.
@property (readonly) NSTableView *previewTable;
/// One per table column: item 0 "— Not imported —", then the CSV's columns.
- (NSArray *)columnPopups;
@property (readonly) NSButton *importButton;
@property (readonly) NSButton *cancelButton;

- (IBAction)import:(id)sender;
- (IBAction)cancel:(id)sender;

@end
