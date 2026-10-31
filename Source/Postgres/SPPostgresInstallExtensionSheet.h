#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;

/**
 * The Install Extension sheet, built in code (560×420, resizable): the extensions the server offers that are not
 * installed (Name, Default version, Description), a filter (case-insensitive substring of the name or the
 * description), the selected extension's versions (its default preselected) and the install schema (the database's
 * schemas, starting at the given one; a schema the control file fixes is shown, disabled), and "Also installs: …"
 * for the missing requirements installed with it.
 *
 * Install runs SPPostgresExtensions' installExtension:version:schema:error: on the connection. On failure the sheet
 * stays open, with the server's message in an alert (see alertPresenter) and in lastErrorMessage; on success it
 * closes. Use on the main thread. completion is called exactly once: with the installed name (Install), or nil
 * (Cancel, or when the sheet can't be shown).
 */
__attribute__((visibility("default")))
@interface SPPostgresInstallExtensionSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>

+ (void)beginWithConnection:(PGPostgresConnection *)connection schema:(NSString *)defaultSchema window:(NSWindow *)window completion:(void (^)(NSString *installedNameOrNil))completion;

/// The sheet that is open, nil when none is.
+ (SPPostgresInstallExtensionSheet *)currentSheet;

@property (readonly) NSWindow *sheet;
/// Columns "name", "defaultVersion", "comment" (Name, Default version, Description).
@property (readonly) NSTableView *extensionsTable;
@property (readonly) NSSearchField *filterField;
@property (readonly) NSPopUpButton *versionPopup;
@property (readonly) NSPopUpButton *schemaPopup;
/// "Also installs: a, b", hidden when nothing is missing.
@property (readonly) NSTextField *alsoInstallsLabel;
@property (readonly) NSButton *installButton;
@property (readonly) NSButton *cancelButton;
/// The server's message from the last failed Install, nil before one.
@property (readonly, copy) NSString *lastErrorMessage;

/// Shows an alert (a failed Install); nil: as a sheet on this sheet.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// The tab's runner (nil: none). The sheet reads and installs on the main thread, so while it is busy Install is
/// refused (NSBeep) and "Also installs" isn't read (it is read again on the next change of extension or version).
@property (retain) SPPostgresTaskRunner *taskRunner;

/// Selects the listed extension (clearing the filter if it hides it); NO when it isn't offered.
- (BOOL)selectExtensionNamed:(NSString *)name;

- (IBAction)install:(id)sender;
- (IBAction)cancel:(id)sender;

@end
