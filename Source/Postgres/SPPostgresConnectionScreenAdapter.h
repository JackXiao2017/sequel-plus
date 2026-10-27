#import <Cocoa/Cocoa.h>

@class SPPostgresFavorite;
@class SPPostgresFavoritesStore;

typedef NS_ENUM(NSInteger, SPConnectionEngine) {
	SPConnectionEngineMySQL = 0,
	SPConnectionEnginePostgreSQL = 1
};

/**
 * What the adapter needs from the connection screen. SPConnectionController conforms: the form
 * properties are its existing ones (the form's text fields are bound to them), and it implements the
 * optional UI hooks. Tests use a plain object with the same properties, so the adapter can be tested
 * without the ConnectionView nib or a document window.
 */
@protocol SPPostgresConnectionScreenHost <NSObject>

@property (readwrite, assign) NSInteger type;
@property (readwrite, retain) NSString *name;
@property (readwrite, retain) NSString *host;
@property (readwrite, retain) NSString *user;
@property (readwrite, retain) NSString *password;
@property (readwrite, retain) NSString *database;
@property (readwrite, retain) NSString *socket;
@property (readwrite, retain) NSString *port;
@property (readwrite, assign) NSInteger useSSL;
@property (readwrite, assign) NSInteger colorIndex;
@property (readwrite, assign) NSInteger sslKeyFileLocationEnabled;
@property (readwrite, retain) NSString *sslKeyFileLocation;
@property (readwrite, assign) NSInteger sslCertificateFileLocationEnabled;
@property (readwrite, retain) NSString *sslCertificateFileLocation;
@property (readwrite, assign) NSInteger sslCACertFileLocationEnabled;
@property (readwrite, retain) NSString *sslCACertFileLocation;
@property (readwrite, retain) NSString *sshHost;
@property (readwrite, retain) NSString *sshUser;
@property (readwrite, retain) NSString *sshPassword;
@property (readwrite, assign) NSInteger sshKeyLocationEnabled;
@property (readwrite, retain) NSString *sshKeyLocation;
@property (readwrite, retain) NSString *sshPort;

@optional

/// Window for sheets (the MySQL tab's window).
- (NSWindow *)postgresSheetWindow;
/// The single selected outline item, or nil.
- (id)postgresSelectedOutlineItem;
/// YES for a saved MySQL favorite leaf (not Quick Connect, not a group).
- (BOOL)postgresItemIsSavedMySQLFavorite:(id)item;
- (void)selectQuickConnectItem;
/// The Postgres favorites changed: reload the outline, keeping the selection.
- (void)postgresFavoritesDidChange;
/// Select (and scroll to) an outline item.
- (void)postgresSelectOutlineItem:(id)item;
/// Start or stop the connecting state of the form (progress indicator, buttons).
- (void)postgresSetConnecting:(BOOL)connecting;
/// Show the result of "Test connection" in the form's status text.
- (void)postgresShowTestResult:(NSString *)result;

@end

/// The keychain calls the adapter makes (SPKeychain conforms). Replaceable for tests.
@protocol SPPostgresKeychainAccess <NSObject>
- (void)addPassword:(NSString *)password forName:(NSString *)name account:(NSString *)account;
- (NSString *)getPasswordForName:(NSString *)name account:(NSString *)account;
- (void)deletePasswordForName:(NSString *)name account:(NSString *)account;
- (BOOL)passwordExistsForName:(NSString *)name account:(NSString *)account;
- (void)updateItemWithName:(NSString *)name account:(NSString *)account toName:(NSString *)newName account:(NSString *)newAccount password:(NSString *)password;
@end

/**
 * All PostgreSQL logic of the (shared, MySQL) connection screen. SPConnectionController owns one and
 * only calls into it from guarded branches, so with MySQL selected and a MySQL favorite the
 * controller's own code runs unchanged.
 *
 * - The engine choice: a centred MySQL / PostgreSQL segmented control above the TCP/IP | Socket | SSH
 *   tabs. With PostgreSQL chosen, empty port fields show 5432.
 * - The "POSTGRESQL" section of the favorites outline, below FAVORITES. Its favorites come from
 *   SPPostgresFavoritesStore (never Favorites.plist); passwords use the "Sequel Pro (PostgreSQL)"
 *   keychain names.
 * - Connecting: opens a separate SPPostgresWindowController; the MySQL tab stays on its connection screen.
 *
 * Main thread only. The host is not retained; the host calls -invalidate before it goes away.
 */
__attribute__((visibility("default")))
@interface SPPostgresConnectionScreenAdapter : NSObject

/// `controller` is normally the SPConnectionController (not retained).
- (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller store:(SPPostgresFavoritesStore *)store;

/// Defaults to an SPKeychain.
@property (nonatomic, retain) id <SPPostgresKeychainAccess> keychain;

/// Cancels a pending connection attempt and forgets the host. Safe to call more than once.
- (void)invalidate;

#pragma mark Engine choice

- (NSSegmentedControl *)engineControl;

/**
 * Adds the engine control centred at the top of `container` (the connection form's resize container)
 * and moves the top of its NSTabView down to make room. Returns the height added above the tabs, which
 * the host adds to the container's height. Port fields (text fields in the tab view bound to "port")
 * get the engine's default port as placeholder.
 */
- (CGFloat)installEngineControlInContainer:(NSView *)container;

/// The height installEngineControlInContainer: returned (0 before it is called).
- (CGFloat)engineControlAreaHeight;

- (SPConnectionEngine)selectedEngine;
/// Sets the engine without the user-switch behaviour (updates the control and the port placeholders).
- (void)setSelectedEngine:(SPConnectionEngine)engine;
/// Action of the engine control. Switching away from the engine of a selected saved favorite moves the
/// selection to Quick Connect, keeping the details typed in the form.
- (IBAction)engineControlChanged:(id)sender;

#pragma mark Outline

/// The "POSTGRESQL" section node (a top-level group), or nil when there are no Postgres favorites.
- (id)sectionNode;
/// The Postgres favorites' outline nodes, sorted by name.
- (NSArray *)favoriteNodesForOutline;
/// YES for the POSTGRESQL section node and its favorite nodes. A MySQL favorite node (whose favorite
/// dictionary has no engine key) is never a Postgres node.
- (BOOL)isPostgresNode:(id)outlineItem;
/// The favorite for a Postgres favorite node, else nil.
- (SPPostgresFavorite *)favoriteForNode:(id)outlineItem;
- (id)nodeForFavoriteID:(NSString *)favoriteID;
- (NSColor *)labelColorForNode:(id)outlineItem;
- (NSString *)toolTipForNode:(id)outlineItem;

/// A MySQL item (or nothing) was selected: forget the loaded Postgres favorite; a saved MySQL favorite
/// switches the engine back to MySQL.
- (void)didSelectMySQLItemIsFavorite:(BOOL)isFavorite;

#pragma mark Form

/// Fills the form (host properties) from `favorite`, with its passwords from the keychain, and sets the
/// engine to PostgreSQL.
- (void)loadFavoriteIntoForm:(SPPostgresFavorite *)favorite;
/// The loaded favorite, if one is being edited.
- (SPPostgresFavorite *)loadedFavorite;
/// A favorite from the form. Keeps the loaded favorite's ID. An empty port means 5432.
- (SPPostgresFavorite *)favoriteFromForm;
/// nil when the form can be saved or connected, else the reason (e.g. TCP/IP without a host).
- (NSError *)validationErrorForForm;

/// Saves the form to the loaded favorite, or as a new favorite when none is loaded, with its passwords
/// in the keychain. Selects the saved favorite in the outline.
- (BOOL)saveFormAsFavorite:(NSError **)error;
/// Saves the form as a new favorite, even when one is loaded.
- (BOOL)saveFormAsNewFavorite:(NSError **)error;

#pragma mark Actions (UI)

/// Validates, shows a sheet on failure, else saves. `asNew` as for -saveFormAsNewFavorite:. YES when saved.
- (BOOL)saveFormShowingErrors:(BOOL)asNew;
/// Adds a blank "New Favorite", returns its node.
- (id)addNewFavorite;
/// Asks for confirmation, then removes the favorite and its keychain items.
- (void)removeFavoriteNodeAfterConfirmation:(id)outlineItem;
- (id)duplicateFavoriteNode:(id)outlineItem;
- (void)renameFavoriteNode:(id)outlineItem to:(NSString *)newName;

/// Reads the passwords from the form (or the keychain), runs SPPostgresConnector, and on success opens a
/// PostgreSQL window. Errors are shown as a sheet on the host's window.
- (void)connectFromForm;
/// As -connectFromForm; with `testOnly`, disconnects after success and reports the result instead.
- (void)connectFromFormTestingOnly:(BOOL)testOnly;
- (BOOL)isConnecting;

@end
