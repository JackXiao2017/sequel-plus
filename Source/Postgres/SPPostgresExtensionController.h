#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresExtension;
@class SPPostgresExtensionController;

@protocol SPPostgresExtensionControllerDelegate <NSObject>
/// The extension was changed (updated): the tab reloads its lists and marks its panes stale.
- (void)extensionController:(SPPostgresExtensionController *)controller didChangeExtension:(NSString *)name;
/// Drop was pressed: the tab confirms and drops (as from the sidebar's "Drop Extension…").
- (void)extensionController:(SPPostgresExtensionController *)controller wantsToDropExtension:(NSString *)name;
@end

/**
 * The Extension pane of a PostgreSQL tab (shown while an extension is selected in the sidebar), laid out as the
 * Sequence pane: read-only Name, Version, Schema and Comment, "Required by: …" (hidden when nothing requires it),
 * then the update targets (pg_extension_update_paths from the installed version, the server's default marked
 * "(default)" and preselected) with Update, or "No other version available" with Update disabled, and Drop.
 * Extensions are database-wide: the pane doesn't depend on the schema picker. Built in code. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresExtensionController : NSObject

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The pane. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Reads the extension and its update targets (nil empties the pane). A read error is shown as an alert.
- (void)showExtension:(NSString *)name;

/// Reads the shown extension again.
- (void)reload;

/// Update: ALTER EXTENSION … UPDATE TO the pop-up's version. A failure is shown as an alert; the pane reads again.
- (IBAction)update:(id)sender;

/// Drop…: asks the delegate (which confirms and drops).
- (IBAction)drop:(id)sender;

/// Detaches the controls and drops the blocks (on close or replace; also on dealloc).
- (void)invalidate;

/// The name shown (nil when empty).
@property (readonly, copy) NSString *extensionName;
/// What the pane shows (nil when empty, not installed, or the read failed).
@property (readonly) SPPostgresExtension *extension;

@property (readonly) NSTextField *nameField;
@property (readonly) NSTextField *versionField;
@property (readonly) NSTextField *schemaField;
@property (readonly) NSTextField *commentField;
/// "Required by: earthdistance" (comma-separated); hidden when nothing requires it.
@property (readonly) NSTextField *requiredByField;
/// The update targets (titles "1.5", "1.8 (default)"; each item's representedObject is its version).
@property (readonly) NSPopUpButton *updatePopup;
@property (readonly) NSButton *updateButton;
@property (readonly) NSButton *dropButton;
/// "No other version available", shown instead of the pop-up when there are no update targets.
@property (readonly) NSTextField *noUpdateLabel;

/// Seconds a change waits for a lock held elsewhere before it fails (default 5).
@property (nonatomic) NSTimeInterval lockTimeout;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

@property (assign) id<SPPostgresExtensionControllerDelegate> delegate;

@end
