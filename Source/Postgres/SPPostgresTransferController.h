#import <Cocoa/Cocoa.h>
#import "SPPostgresDocument.h"

@class SPPostgresFavorite;
@class SPPostgresProgressSheet;
@class SPPostgresCheckList;
@class SPPostgresConnector;

/**
 * The Transfer sheet of a PostgreSQL tab (the Transfer toolbar item), built in code: copies this tab's database (the
 * whole of it, or some tables with what they need) into a database of any Postgres favorite, through SPPostgresTransfer.
 *
 * - Scope: "Whole database “<db>”" (default) or "Selected tables" (a checkbox list grouped by schema, preset to the
 *   sidebar's selected table).
 * - To: a favorite (the first that isn't this tab's is preselected), the line under it showing user@host:port,
 *   user@<socket directory> or user@host:port via SSH sshUser@sshHost; Database (the favorite's, until edited);
 *   Password (empty: the one saved in the Keychain for that favorite, read only when Transfer starts; never saved).
 * - Mode: "Empty the target database first" (default; confirmed first by typing the database's name, before any
 *   connection is opened) or "Overwrite tables that already exist on the target".
 *
 * The transfer runs as a two-connection SPPostgresBackgroundJob (this tab's database from the document's provider,
 * then the target) under an SPPostgresProgressSheet. Cancel interrupts both. The outcome is shown as an alert (the
 * document's alertPresenter when set): "Transfer complete", or why the target wasn't changed. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresTransferController : NSObject <NSTextFieldDelegate>

- (instancetype)initWithDocument:(SPPostgresDocument *)document;

/// Shows the sheet on the document's window. The controller keeps itself alive until the transfer (or Cancel) ends.
/// When the tables can't be read, an alert says why (on the sheet, or through the document's alertPresenter when set).
- (void)beginSheet;

/// Called on the main thread once the sheet and any transfer it started have ended.
@property (copy) void (^didEnd)(void);

#pragma mark - Seams

/// The favorites the To: pop-up offers (SPPostgresFavorite). nil (the default): the favorites store's, read by
/// -beginSheet.
@property (copy) NSArray *favorites;

/**
 * Makes the target's connection provider for a favorite and the typed password (nil or empty: none typed). nil (the
 * default): an SPPostgresConnector for a copy of the favorite with the database asked for, with the typed password or
 * else the Keychain's, the Keychain's SSH password, the progress sheet as parentWindow (for its SSH prompts), and a
 * console logger named after the favorite; kept until the job ends.
 */
@property (copy) SPPostgresConnectionProvider (^targetProviderForFavorite)(SPPostgresFavorite *favorite, NSString *password);

/// Asks to confirm Empty mode; answer must be called once (later calls are ignored). nil (the default): the alert of
/// -emptyConfirmationAlertForDatabase:targetDescription:, as a sheet on the Transfer sheet.
@property (copy) void (^emptyConfirmation)(NSString *database, NSString *targetDescription, void (^answer)(BOOL confirmed));

/// The Empty mode confirmation: an NSTextField accessory, and a first button "Empty and Transfer" (destructive),
/// enabled only while the field holds exactly database (as typed, or as set by -setStringValue:); then Cancel.
- (NSAlert *)emptyConfirmationAlertForDatabase:(NSString *)database targetDescription:(NSString *)description;

/// Called on the job's thread at every progress report, before the job checks for a cancel (as Export's).
@property (copy) void (^progressObserver)(SPPostgresProgressSheet *sheet);

/// Where the engine writes its temporary dump; nil: NSTemporaryDirectory().
@property (copy) NSString *temporaryDirectory;

#pragma mark - For tests

@property (readonly) NSPanel *sheet;
@property (readonly) NSButton *wholeDatabaseRadio;
@property (readonly) NSButton *selectedTablesRadio;
@property (readonly) SPPostgresCheckList *tablesList;
@property (readonly) NSPopUpButton *favoritePopup;
@property (readonly) NSTextField *targetDescriptionField;
@property (readonly) NSTextField *databaseField;
@property (readonly) NSSecureTextField *passwordField;
@property (readonly) NSButton *emptyModeRadio;
@property (readonly) NSButton *overwriteModeRadio;
@property (readonly) NSButton *transferButton;

/// The connector the default target provider is opening (until it has connected); nil with another provider.
@property (readonly) SPPostgresConnector *pendingConnector;

/// The progress sheet while a transfer runs.
@property (readonly) SPPostgresProgressSheet *progressSheet;

- (IBAction)transfer:(id)sender;
- (IBAction)cancel:(id)sender;

/// The last transfer's error (the failure alert's message and text; nil after a success); the cancel message after a
/// cancel.
@property (readonly, copy) NSString *lastErrorMessage;

/// What a successful transfer copied ("Copied <n> tables to …" and what it replaced, created or left out), also
/// shown as the "Transfer complete" alert.
@property (readonly, copy) NSString *completionNote;

/// The target line for a favorite: user@host:port, user@<socket directory>, or user@host:port via SSH sshUser@sshHost.
+ (NSString *)targetDescriptionForFavorite:(SPPostgresFavorite *)favorite;

@end
