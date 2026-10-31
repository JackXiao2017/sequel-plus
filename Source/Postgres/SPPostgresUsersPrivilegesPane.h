#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresRole;
@class SPPostgresUsersPrivilegesPane;

/// What the Privileges pane asks of the Users sheet that owns it.
@protocol SPPostgresUsersPrivilegesPaneDelegate <NSObject>
/// A connection of the sheet's own to database (never the document's); the completion may be called later.
- (void)privilegesPane:(SPPostgresUsersPrivilegesPane *)pane connectionForDatabase:(NSString *)database completion:(void (^)(PGPostgresConnection *connection, NSError *error))completion;
- (void)privilegesPane:(SPPostgresUsersPrivilegesPane *)pane showErrorTitle:(NSString *)title message:(NSString *)message;
/// A cell is about to be edited (the sheet commits the role's typed fields, e.g. a new name, first).
- (void)privilegesPaneWillEdit:(SPPostgresUsersPrivilegesPane *)pane;
/// The pending edits changed (the sheet updates its Apply button).
- (void)privilegesPaneDidChange:(SPPostgresUsersPrivilegesPane *)pane;
@end

/**
 * The Users sheet's Privileges tab, built in code: database, schema and default-privileges creator pop-ups, a grid of
 * one role's direct privileges (an Object column, then a checkbox column per privilege: SELECT INSERT UPDATE DELETE
 * TRUNCATE REFERENCES TRIGGER USAGE CREATE CONNECT TEMP EXECUTE, a cell only where the row's kind has that privilege),
 * and a note for superusers. Rows: the database, then -[SPPostgresPrivileges privilegesForRole:schema:defaultsCreator:].
 *
 * Edits are pending until the sheet applies them. They are kept per role (by its current draft name), database,
 * object and, for the default-privilege rows, creator; switching database, schema, creator or role keeps them, and
 * each set's statements are built against the rows it was read from (and the creator it was read with). Use on the
 * main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresUsersPrivilegesPane : NSObject <NSTableViewDataSource, NSTableViewDelegate>

/// delegate is not retained (the sheet owns the pane).
- (instancetype)initWithDelegate:(id<SPPostgresUsersPrivilegesPaneDelegate>)delegate;

/// Builds the pane's view (once) at frame's size.
- (NSView *)viewWithFrame:(NSRect)frame;

/// Lists the databases (through connection, to database), then shows database with its schemas; NO (error set)
/// when they can't be read.
- (BOOL)startWithDatabase:(NSString *)database connection:(PGPostgresConnection *)connection error:(NSError **)error;

/// Shows role's privileges (nil shows none). role is a draft: its edits are kept under its current name and its
/// privileges read under its server name.
- (void)showRole:(SPPostgresRole *)role;
/// The shown role's superuser flag changed in the draft.
- (void)roleAttributesChanged;
/// Re-reads the creators, the shown database's schemas and the grid (after an apply saved part of the edits).
- (void)reload;

/// A draft role was renamed: its pending edits move to the new name.
- (void)renameRole:(NSString *)from to:(NSString *)to;
/// A draft role was removed: its pending edits go.
- (void)dropEditsForRole:(NSString *)role;

- (BOOL)hasPendingEdits;
/// GRANT / REVOKE … ON DATABASE for every pending database row (any database: they run anywhere).
- (NSArray *)databaseStatements;
/// The databases with other pending edits, sorted by name.
- (NSArray *)databasesWithPendingStatements;
/// The statements for database's pending edits other than database rows.
- (NSArray *)statementsForDatabase:(NSString *)database;
/// Forget pending edits once saved: every database row, or everything in database but its database row.
- (void)forgetDatabaseEdits;
- (void)forgetEditsInDatabase:(NSString *)database;
/// The edited objects pending in database (its database row included), for every role.
- (NSArray *)pendingEditsInDatabase:(NSString *)database;

@property (readonly) NSPopUpButton *databasePopup;
@property (readonly) NSPopUpButton *schemaPopup;
@property (readonly) NSPopUpButton *creatorPopup;
@property (readonly) NSTableView *privilegesTable;
@property (readonly) NSTextField *superuserNote;
@property (readonly) NSProgressIndicator *progressIndicator;
/// The rows as shown (pending edits included).
@property (readonly) NSArray *rowsShown;

@end
