#import <Cocoa/Cocoa.h>

@class SPPostgresDocument;
@class SPPostgresProgressSheet;
@class SPPostgresConnector;

/**
 * The Export sheet of a PostgreSQL tab (File ▸ Export…), built in code.
 *
 * - Format: SQL (a dump by SPPostgresDumpWriter: Structure, Data, "Compress (gzip)") or CSV (Delimiter, Quote, Escape,
 *   "First row holds column names", NULL as).
 * - Source: Whole database, Selected schemas (a checkbox list), Selected tables (a checkbox list grouped by schema,
 *   preset to the sidebar's selected table) or Query result (CSV only: the rows the Query view holds; enabled when
 *   it holds a result).
 * - SQL asks for a file (<database>.sql or .sql.gz). CSV writes one file per table: one table asks for a file
 *   (<schema>.<table>.csv), several for a folder that receives <schema>.<table>.csv each; a query result asks for a
 *   file (query-result.csv). CSV of the whole database or of schemas exports each of their tables.
 *
 * The export runs as an SPPostgresBackgroundJob on a connection from the document's provider, in one REPEATABLE READ
 * READ ONLY snapshot, under an SPPostgresProgressSheet ("Table 3 of 12: orders"). Cancel stops it, interrupting the
 * statement running, and deletes the files it created (a CSV file that replaced an existing one stays). An error is
 * shown as an alert (the document's alertPresenter when set). Foreign tables are left out of a SQL dump, and the
 * completion says which. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresExportController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

- (instancetype)initWithDocument:(SPPostgresDocument *)document;

/// Shows the sheet on the document's window. The controller keeps itself alive until the export (or Cancel) ends.
- (void)beginSheet;

/// As -beginSheet, with the Query result source chosen and the format on CSV (the Query view's Export Result ▸ As CSV
/// file…). The source falls back as -beginSheet's when the Query view holds no result.
- (void)beginSheetWithQueryResultSource;

/// Called on the main thread once the sheet and any export it started have ended.
@property (copy) void (^didEnd)(void);

#pragma mark - For tests

@property (readonly) NSPanel *sheet;
/// Segment 0: SQL, 1: CSV.
@property (readonly) NSSegmentedControl *formatControl;
/// Items: Whole database, Selected schemas, Selected tables, Query result.
@property (readonly) NSPopUpButton *sourcePopup;
/// Columns @"check" and @"name".
@property (readonly) NSTableView *schemasTable;
/// Columns @"check" and @"name"; a group row per schema (its name), then its tables.
@property (readonly) NSTableView *tablesTable;

@property (readonly) NSButton *structureCheckbox;
@property (readonly) NSButton *dataCheckbox;
@property (readonly) NSButton *compressCheckbox;

/// Items: , ; Tab | Custom.
@property (readonly) NSPopUpButton *delimiterPopup;
@property (readonly) NSTextField *customDelimiterField;
@property (readonly) NSTextField *quoteField;
/// Items: " and \.
@property (readonly) NSPopUpButton *escapePopup;
@property (readonly) NSButton *headerCheckbox;
@property (readonly) NSTextField *nullField;

@property (readonly) NSButton *exportButton;

/// The checked schemas, and the checked tables as @[schema, table] pairs, in list order.
@property (readonly) NSArray *checkedSchemas;
@property (readonly) NSArray *checkedTables;
- (void)setChecked:(BOOL)checked schema:(NSString *)schema;
- (void)setChecked:(BOOL)checked table:(NSString *)table schema:(NSString *)schema;

/**
 * Where to write: called with the suggested file name, and directory YES when a folder is wanted (several CSV files;
 * the name is then the database's). Returns the path, or nil to go back to the sheet. nil (the default) shows an
 * NSSavePanel (or, for a folder, an NSOpenPanel) on the window. Tests return a temporary path.
 */
@property (copy) NSString * (^savePathProvider)(NSString *suggestedName, BOOL directory);

/// Test seam: called on the job's thread at every progress report, before the job checks for a cancel.
@property (copy) void (^progressObserver)(SPPostgresProgressSheet *sheet);

/// The connector the default connection provider is opening for the export (its parentWindow is the progress
/// sheet, which hosts its SSH prompts), until it has connected; nil with another provider.
@property (readonly) SPPostgresConnector *pendingConnector;

/// The progress sheet while an export runs.
@property (readonly) SPPostgresProgressSheet *progressSheet;

- (IBAction)export:(id)sender;
- (IBAction)cancel:(id)sender;

/// The last export's error message (nil after a success); the cancel message after a cancel.
@property (readonly, copy) NSString *lastErrorMessage;

/// What a successful export had to say, also shown as an alert (the foreign tables a SQL dump left out); nil when
/// nothing.
@property (readonly, copy) NSString *completionNote;

@end
