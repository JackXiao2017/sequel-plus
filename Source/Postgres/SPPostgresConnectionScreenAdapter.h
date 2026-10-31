#import <Cocoa/Cocoa.h>

@class SPPostgresDocument;
@class SPPostgresFavorite;
@class SPPostgresFavoritesStore;
@class SPPostgresFavoritePlacementsStore;
@class SPTreeNode;

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

/**
 * A connection succeeded: put `document` (connected, not hosted yet) in place of the connection
 * screen's tab, at the same index, and select it. SPConnectionController does it with
 * -[SPWindowController replaceTabDocument:withDocument:], which closes its own MySQL tab.
 * The host retains the document as long as it needs it (the tab view item does).
 */
- (void)postgresReplaceConnectionTabWithDocument:(SPPostgresDocument *)document;

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
/// The FAVORITES section node (first child of the MySQL favorites tree).
- (SPTreeNode *)postgresMySQLSection;
/// Where a new Postgres favorite goes: the selected group, else the selected item's displayed parent, else the section.
- (SPTreeNode *)postgresGroupForNewFavorite;

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
 * - Postgres favorites in the one FAVORITES list, placed among the MySQL favorites and groups by an
 *   SPPostgresFavoritesLayout. The MySQL tree is never given a Postgres node: the nodes belong to a hidden
 *   holder node, and where each is displayed is remembered in PostgresFavoritePlacements.plist. The
 *   favorites come from SPPostgresFavoritesStore (never Favorites.plist); passwords use the
 *   "Sequel Pro (PostgreSQL)" keychain names.
 * - Connecting: on success the connection screen's tab becomes an SPPostgresDocument tab (see
 *   -postgresReplaceConnectionTabWithDocument:); no window is opened. On failure the error is shown as a
 *   sheet and the tab stays on its connection screen.
 *
 * Main thread only. The host is not retained; the host calls -invalidate before it goes away.
 */
__attribute__((visibility("default")))
@interface SPPostgresConnectionScreenAdapter : NSObject

/// `controller` is normally the SPConnectionController (not retained).
/// The placements store is the one beside `store`'s file (+[SPPostgresFavoritePlacementsStore storeBesideFavoritesStore:]).
- (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller store:(SPPostgresFavoritesStore *)store;
- (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller
                                       store:(SPPostgresFavoritesStore *)store
                             placementsStore:(SPPostgresFavoritePlacementsStore *)placementsStore;

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
/// Enables or disables the engine control. The host disables it while a connection (of either engine)
/// is being made, so switching engine can't re-run the favorite selection mid-connect.
- (void)setEngineChoiceEnabled:(BOOL)enabled;
/// Sets the engine without the user-switch behaviour (updates the control and the port placeholders).
- (void)setSelectedEngine:(SPConnectionEngine)engine;
/// Action of the engine control. Switching away from the engine of a selected saved favorite moves the
/// selection to Quick Connect, keeping the details typed in the form.
- (IBAction)engineControlChanged:(id)sender;

#pragma mark Outline

/// YES when the store has Postgres favorites (whether or not the outline was prepared yet).
- (BOOL)hasPostgresFavorites;
/**
 * Called by the host before every outline reload. With `saveLayout`, first saves the current arrangement's
 * placements (merged over the stored ones for favorites not in the arrangement, pruned to existing
 * favorites; written only when different). Then resolves against `section` and the stored placements.
 */
- (void)prepareOutlineWithMySQLSection:(SPTreeNode *)section savingLayout:(BOOL)saveLayout;
/// The displayed children of a MySQL group (or of the section): its childNodes with Postgres nodes inserted.
- (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group;
/// The MySQL group a Postgres node is displayed in (the section for the top level); for a MySQL node, its parentNode.
- (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node;
/// Drag and drop (see -[SPPostgresFavoritesLayout moveNodes:toGroup:displayedIndex:]), then saves the placements.
- (void)moveNodes:(NSArray *)nodes toGroup:(SPTreeNode *)group displayedIndex:(NSInteger)index;
/// Sorting: `children` must be the complete displayed children of `group`, reordered. Not saved: the host
/// reloads next, saving the layout.
- (void)setDisplayedChildren:(NSArray *)children ofGroup:(SPTreeNode *)group;
/// Removes every Postgres favorite displayed within `group` (store and keychain items), without asking.
- (void)removePostgresFavoritesWithinGroup:(SPTreeNode *)group;

/// YES for the hidden holder node and the Postgres favorite nodes. A MySQL favorite node (whose favorite
/// dictionary has no engine key) is never a Postgres node.
- (BOOL)isPostgresNode:(id)outlineItem;
/// The favorite for a Postgres favorite node, else nil.
- (SPPostgresFavorite *)favoriteForNode:(id)outlineItem;
- (id)nodeForFavoriteID:(NSString *)favoriteID;
- (NSColor *)labelColorForNode:(id)outlineItem;
- (NSString *)toolTipForNode:(id)outlineItem;
/// The icon for Postgres favorite rows: the PostgreSQL elephant, at the MySQL favorites' icon size.
+ (NSImage *)favoriteImage;

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
/// in the keychain. Selects the saved favorite in the outline. A new favorite goes to the end of the
/// host's -postgresGroupForNewFavorite.
- (BOOL)saveFormAsFavorite:(NSError **)error;
/// Saves the form as a new favorite, even when one is loaded.
- (BOOL)saveFormAsNewFavorite:(NSError **)error;

#pragma mark Actions (UI)

/// Validates, shows a sheet on failure, else saves. `asNew` as for -saveFormAsNewFavorite:. YES when saved.
- (BOOL)saveFormShowingErrors:(BOOL)asNew;
/// Adds a blank "New Favorite" at the end of the host's -postgresGroupForNewFavorite, returns its node.
- (id)addNewFavorite;
/// Asks for confirmation, then removes the favorite and its keychain items.
- (void)removeFavoriteNodeAfterConfirmation:(id)outlineItem;
/// The copy is displayed right after the original.
- (id)duplicateFavoriteNode:(id)outlineItem;
- (void)renameFavoriteNode:(id)outlineItem to:(NSString *)newName;

/// Reads the passwords from the form (or the keychain), runs SPPostgresConnector, and on success hands an
/// SPPostgresDocument to the host to replace the connection tab. Errors are shown as a sheet on the host's window.
- (void)connectFromForm;
/// As -connectFromForm; with `testOnly`, disconnects after success and reports the result instead.
- (void)connectFromFormTestingOnly:(BOOL)testOnly;
- (BOOL)isConnecting;

@end
