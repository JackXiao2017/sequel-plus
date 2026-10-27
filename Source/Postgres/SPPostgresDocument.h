#import <Cocoa/Cocoa.h>
#import "../SPWindowTabDocument.h"

@class PGPostgresConnection;
@class SPPostgresConnector;
@class SPPostgresContentController;
@class SPPostgresQueryController;
@class SPPostgresFavorite;
@class SPPostgresSidebarController;
@class SPWindowController;

/**
 * A PostgreSQL connection hosted as a tab of an SPWindowController window: the left panel (schema
 * picker, tables, views, extensions), in the right pane the Content view of the selected table or view
 * (see SPPostgresContentController) or the Query view (SPPostgresQueryController), switched by the Content
 * and Query toolbar items and View menu items as on MySQL tabs, the database picker and the console
 * logger. Built in code. Use on the main thread.
 *
 * Takes over `connector` (it keeps it, and disconnects it when the tab closes) and `connection`,
 * which must be the connector's connected connection. Host it with
 * -[SPWindowController addTabDocument:atIndex:select:]; the tab view item keeps it alive.
 *
 * While its tab is active it installs its own toolbar, the window title and the compact title chrome.
 * The toolbar is MySQL's (identifier TableWindowToolbar, the same item identifiers and saved layout);
 * the items Postgres tabs don't support yet are disabled.
 */
__attribute__((visibility("default")))
@interface SPPostgresDocument : NSObject <SPWindowTabDocument, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation, NSSplitViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection connector:(SPPostgresConnector *)connector favorite:(SPPostgresFavorite *)favorite;

/// @"(PostgreSQL <serverVersion>) <favorite name>/<database>", plus @"/<schema>.<table>" when a table is selected.
- (NSString *)windowTitleString;

/**
 * Postgres can't change database within a session: connects a new connector (same favorite and
 * passwords, `database` changed) and, on success, switches the tab to it and closes the old
 * connection. On failure the current connection is kept and the error is shown (see alertPresenter).
 */
- (void)switchToDatabase:(NSString *)database;

/// The favorite name, plus @"/<database>" while another Postgres tab of the same window has the same name.
- (NSString *)tabLabel;

/// The toolbar this tab installs in its window while active.
- (NSToolbar *)toolbar;

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar;

/// NO for every action this tab doesn't implement (MySQL-only items); the window's own items stay enabled.
- (BOOL)validateMenuItem:(NSMenuItem *)item;

/// Shows the Content view of the selected table (needs one), as MySQL's Content toolbar item and View menu item.
- (IBAction)viewContent:(id)sender;

/// Shows the Query view, as MySQL's Query toolbar item and View > Custom Query.
- (IBAction)viewQuery:(id)sender;

/**
 * Shows the tab's alerts (catalog errors, a failed database switch). nil (the default) shows them as
 * sheets on the parent window while the tab is active and the window visible; otherwise they wait
 * until it is. Replaceable, e.g. by tests.
 */
@property (copy) void (^alertPresenter)(NSAlert *alert);

@property (readonly) SPPostgresSidebarController *sidebar;
/// The right pane: the Content view of the table or view selected in the sidebar.
@property (readonly) SPPostgresContentController *contentController;
/// The right pane: the Query view. Its editor's text is kept for the tab's session (also across database switches).
@property (readonly) SPPostgresQueryController *queryController;
@property (readonly) PGPostgresConnection *connection;
@property (readonly) SPPostgresFavorite *favorite;

/// YES while a database switch is connecting. KVO-compliant (drives the tab's progress indicator).
@property (readonly) BOOL isProcessing;

@property (readonly, assign) SPWindowController *parentWindowController;
@property (readonly, assign) NSWindow *parentWindow;
@property (readonly, assign) NSTabViewItem *parentTabViewItem;

@end
