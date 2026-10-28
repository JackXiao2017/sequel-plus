#import <Cocoa/Cocoa.h>
#import "SPPostgresSQLImporter.h"

@class SPPostgresDocument;
@class SPPostgresCSVOptions;
@class SPPostgresCSVMappingSheet;
@class SPPostgresProgressSheet;
@class SPPostgresConnector;

/**
 * File ▸ Import… on a PostgreSQL tab: an open panel whose accessory picks the format (SQL or CSV, from the file's
 * extension: .csv/.tsv, also before .gz/.bz2, is CSV, anything else SQL; changeable), "Run in a single transaction"
 * for SQL and the CSV options (encoding UTF-8, a BOM skipped). gzip and bzip2 files are read transparently.
 *
 * - SQL runs with SPPostgresSQLImporter. In a single transaction any error rolls everything back, and the alert names
 *   the statement's line; otherwise each statement commits on its own and an error asks Stop, Ignore or Ignore All.
 * - CSV shows a mapping sheet (SPPostgresCSVMappingSheet) over the database's tables, then imports with
 *   +[SPPostgresCSV importPath:…] in one transaction.
 *
 * Each import runs as an SPPostgresBackgroundJob on a connection from the document's provider (never the tab's own),
 * under an SPPostgresProgressSheet showing the bytes read of the file's size. Cancel rolls back the open transaction
 * (in per-statement mode, what already committed stays). After an import that changed anything the document reloads
 * its sidebar keeping the selection and marks every pane stale. Errors (not cancels) are shown as alerts through the
 * document. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresImportController : NSObject <NSOpenSavePanelDelegate>

- (instancetype)initWithDocument:(SPPostgresDocument *)document;

/// Shows the open panel as a sheet on the document's window. The controller keeps itself alive until the import
/// (or Cancel) ends.
- (void)beginImport;

/// Imports path as @"sql" or @"csv" with the accessory's settings (singleTransactionCheckbox, csvOptions): the step
/// after the open panel, also used by tests. CSV shows the mapping sheet first.
- (void)importPath:(NSString *)path format:(NSString *)format;

/// Ends whatever is up: the open panel or mapping sheet as Cancel, a running import cancelled (rolled back).
- (void)cancel;

/// Called on the main thread once the panel, sheets and any import they started have ended.
@property (copy) void (^didEnd)(void);

#pragma mark - For tests

/// Item 0: SQL, 1: CSV.
@property (readonly) NSPopUpButton *formatPopup;
/// "Run in a single transaction" (SQL), on by default.
@property (readonly) NSButton *singleTransactionCheckbox;
/// The CSV options the import uses (the accessory's controls are read into it when the open panel ends).
@property (retain) SPPostgresCSVOptions *csvOptions;

/// Decides after a failed statement in per-statement mode (called on the main thread). nil shows an alert with Stop,
/// Ignore and Ignore All.
@property (copy) SPPostgresImportErrorChoice (^errorChoiceProvider)(NSError *error);

/// The mapping sheet while it is shown.
@property (readonly) SPPostgresCSVMappingSheet *mappingSheet;
/// The progress sheet while an import runs.
@property (readonly) SPPostgresProgressSheet *progressSheet;
/// The connector the default provider is opening for the import (its SSH prompts go to the progress sheet).
@property (readonly) SPPostgresConnector *pendingConnector;
/// YES from the start of an import job until it has ended.
@property (readonly, getter=isRunning) BOOL running;

/// The last import's error message (nil after a success); the cancel message after a cancel.
@property (readonly, copy) NSString *lastErrorMessage;

/// The format an extension implies: @"csv" for .csv and .tsv (also under .gz or .bz2), else @"sql".
+ (NSString *)formatForPath:(NSString *)path;

@end
