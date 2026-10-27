#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresConnector;
@class SPPostgresFavorite;
@class SPPostgresSidebarController;

#define SP_PG_EXPORT extern __attribute__((visibility("default")))

SP_PG_EXPORT NSString * const SPPostgresToolbarDatabase;
SP_PG_EXPORT NSString * const SPPostgresToolbarStructure;
SP_PG_EXPORT NSString * const SPPostgresToolbarContent;
SP_PG_EXPORT NSString * const SPPostgresToolbarRelations;
SP_PG_EXPORT NSString * const SPPostgresToolbarTriggers;
SP_PG_EXPORT NSString * const SPPostgresToolbarTableInfo;
SP_PG_EXPORT NSString * const SPPostgresToolbarQuery;
SP_PG_EXPORT NSString * const SPPostgresToolbarUsers;
SP_PG_EXPORT NSString * const SPPostgresToolbarTransfer;
SP_PG_EXPORT NSString * const SPPostgresToolbarHistory;
SP_PG_EXPORT NSString * const SPPostgresToolbarConsole;

#undef SP_PG_EXPORT

/**
 * The PostgreSQL window: compact title and toolbar, a single tab for the connection, and the left
 * panel (schema picker, tables, views, extensions). Built in code. Use on the main thread.
 *
 * Takes over `connector` (it keeps it, and disconnects it when the window closes) and `connection`,
 * which must be the connector's connected connection. While its window is open the controller keeps
 * itself alive, so the caller may release it after -showWindow:.
 */
__attribute__((visibility("default")))
@interface SPPostgresWindowController : NSWindowController <NSToolbarDelegate, NSToolbarItemValidation, NSWindowDelegate, NSSplitViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection connector:(SPPostgresConnector *)connector favorite:(SPPostgresFavorite *)favorite;

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;

/// @"(PostgreSQL <serverVersion>) <favorite name>/<database>", plus @"/<schema>.<table>" when a table is selected.
- (NSString *)windowTitleString;

/**
 * Postgres can't change database within a session: connects a new connector (same favorite and
 * password, `database` changed) and, on success, switches the window to it and closes the old
 * connection. On failure the current connection is kept and the error is shown as a sheet.
 */
- (void)switchToDatabase:(NSString *)database;

@property (readonly) SPPostgresSidebarController *sidebar;
@property (readonly) PGPostgresConnection *connection;

@end
