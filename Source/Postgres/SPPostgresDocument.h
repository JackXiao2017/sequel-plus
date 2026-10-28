#import <Cocoa/Cocoa.h>
#import "../SPWindowTabDocument.h"

@class PGPostgresConnection;
@class SPPostgresConnector;
@class SPPostgresContentController;
@class SPPostgresQueryController;
@class SPPostgresFavorite;
@class SPPostgresHistory;
@class SPPostgresSidebarController;
@class SPPostgresStructureController;
@class SPPostgresRelationsController;
@class SPPostgresTriggersController;
@class SPPostgresTableInfoController;
@class SPWindowController;

/// The panes of a PostgreSQL tab's right side (-showPane:, -currentPane, and the tab's history entries).
extern NSString * const SPPostgresPaneStructure __attribute__((visibility("default"))); // @"structure"
extern NSString * const SPPostgresPaneContent __attribute__((visibility("default")));   // @"content"
extern NSString * const SPPostgresPaneRelations __attribute__((visibility("default"))); // @"relations"
extern NSString * const SPPostgresPaneTriggers __attribute__((visibility("default")));  // @"triggers"
extern NSString * const SPPostgresPaneInfo __attribute__((visibility("default")));      // @"info"
extern NSString * const SPPostgresPaneQuery __attribute__((visibility("default")));     // @"query"

/**
 * A PostgreSQL connection hosted as a tab of an SPWindowController window: the left panel (schema
 * picker, tables, views, extensions), in the right pane one of the named panes (see -showPane:): the Structure
 * view of the selected table or view (SPPostgresStructureController), its Content view
 * (SPPostgresContentController), Relations, Triggers, Table Info, or the Query view (SPPostgresQueryController),
 * switched by the toolbar items and View menu items (⌘1–⌘6) as on MySQL tabs, the database picker and the
 * console logger. Built in code. Use on the main thread.
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
 * An edit in progress in the Content grid is saved first (if it can't be, nothing happens). If the user
 * has a transaction open (or aborted) in this session, closing it would roll it back, so they are asked
 * first (see confirmationPresenter); Cancel leaves everything as it was.
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

/**
 * Shows a pane (one of the SPPostgresPane… names) in the right pane, as MySQL's tab view does: the other panes
 * are taken out of the window, keeping their state. An edit in progress in the pane being left is ended (saved)
 * first; if it can't be, nothing changes. A pane the Query view may have made stale reloads as it is shown.
 * Unknown names show Content.
 */
- (void)showPane:(NSString *)pane;

/// The pane shown in the right pane (an SPPostgresPane… name).
@property (readonly) NSString *currentPane;

/// The Structure view of the selected table or view (needs one), as MySQL's Structure toolbar item and View > Structure (⌘1).
- (IBAction)viewStructure:(id)sender;

/// Shows the Content view of the selected table (needs one), as MySQL's Content toolbar item and View menu item.
- (IBAction)viewContent:(id)sender;

/// Relations (⌘3) and Triggers (⌘4): for a table or partitioned table only.
- (IBAction)viewRelations:(id)sender;
- (IBAction)viewTriggers:(id)sender;

/// Table Info (⌘5), as MySQL's View > Table Info: for any selected table or view.
- (IBAction)viewStatus:(id)sender;

/// Shows the Query view, as MySQL's Query toolbar item and View > Custom Query.
- (IBAction)viewQuery:(id)sender;

/**
 * Shows the tab's alerts (catalog errors, a failed database switch). nil (the default) shows them as
 * sheets on the parent window while the tab is active and the window visible; otherwise they wait
 * until it is. Replaceable, e.g. by tests.
 */
@property (copy) void (^alertPresenter)(NSAlert *alert);

/**
 * Asks to confirm a database switch that would roll back the user's open transaction: call completion
 * exactly once with YES to switch (later calls are ignored). The completion is a heap block that stays valid
 * until it is called, so a presenter may store it. nil (the default) shows a sheet on the parent window.
 * Replaceable, e.g. by tests.
 */
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

@property (readonly) SPPostgresSidebarController *sidebar;
/// The right pane: the Structure view of the table or view selected in the sidebar.
@property (readonly) SPPostgresStructureController *structureController;
/// The right pane: the Relations view (foreign keys) of the table selected in the sidebar.
@property (readonly) SPPostgresRelationsController *relationsController;
/// The right pane: the Triggers view of the table selected in the sidebar.
@property (readonly) SPPostgresTriggersController *triggersController;
/// The right pane: the Table Info view of the table or view selected in the sidebar.
@property (readonly) SPPostgresTableInfoController *infoController;
/// The right pane: the Content view of the table or view selected in the sidebar.
@property (readonly) SPPostgresContentController *contentController;
/// The right pane: the Query view. Its editor's text is kept for the tab's session (also across database switches).
@property (readonly) SPPostgresQueryController *queryController;
/// The tab's Table History (the toolbar's History control, View > Back/Forward In History).
@property (readonly) SPPostgresHistory *history;
@property (readonly) PGPostgresConnection *connection;
@property (readonly) SPPostgresFavorite *favorite;

/// YES while a database switch is connecting. KVO-compliant (drives the tab's progress indicator).
@property (readonly) BOOL isProcessing;

@property (readonly, assign) SPWindowController *parentWindowController;
@property (readonly, assign) NSWindow *parentWindow;
@property (readonly, assign) NSTabViewItem *parentTabViewItem;

@end
