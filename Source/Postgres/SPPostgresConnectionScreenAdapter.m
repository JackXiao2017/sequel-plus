#import "SPPostgresConnectionScreenAdapter.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresFavoriteNode.h"
#import "SPPostgresFavoritesStore.h"
#import "SPPostgresFavoritePlacementsStore.h"
#import "SPPostgresFavoritesLayout.h"
#import "SPPostgresConnector.h"
#import "SPPostgresDocument.h"
#import "SPPostgresErrors.h"
#import "SPKeychain.h"
#import "SPTreeNode.h"
#import "SPGroupNode.h"
#import "SPNamedNode.h"
#import "SPFavoriteColorSupport.h"
#import "SPAlertSheets.h"

static const NSUInteger SPPostgresScreenDefaultPort = 5432;
static NSString * const SPPostgresScreenMySQLDefaultPort = @"3306";
static NSString * const SPPostgresScreenMySQLHostLabel = @"MySQL Host:"; // as in ConnectionView.xib's SSH tab
static NSString * const SPPostgresScreenPostgreSQLHostLabel = @"PostgreSQL Host:";
static NSString * const SPPostgresScreenDatabaseImage = @"database-small"; // the MySQL favorites' icon (SPConnectionController.m)
static NSString * const SPPostgresScreenElephantImage = @"postgres-elephant"; // the PostgreSQL elephant (postgresql.org press kit)

@interface SPKeychain (SPPostgresKeychainAccess) <SPPostgresKeychainAccess>
@end

@implementation SPKeychain (SPPostgresKeychainAccess)
@end

static NSString *SPPGNonEmpty(NSString *s)
{
	if (![s isKindOfClass:[NSString class]]) return nil;
	return [s length] ? s : nil;
}

static NSString *SPPGOrEmpty(NSString *s)
{
	return s ? s : @"";
}

@interface SPPostgresConnectionScreenAdapter ()
- (void)_rebuildNodes;
- (void)_favoritesDidChange:(NSNotification *)notification;
- (void)_placementsDidChange:(NSNotification *)notification;
- (NSDictionary *)_currentPlacementsOver:(NSDictionary *)stored;
- (NSDictionary *)_savePlacements;
- (SPTreeNode *)_displayNewFavorite:(SPPostgresFavorite *)favorite afterNode:(SPTreeNode *)existing;
- (void)_forgetUnsavedFavorite;
- (BOOL)_removeFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error;
- (NSWindow *)_sheetWindow;
- (void)_showError:(NSError *)error;
- (BOOL)_saveFormAsNew:(BOOL)asNew error:(NSError **)error;
- (void)_storePassword:(NSString *)thePassword sshPassword:(NSString *)theSSHPassword forFavorite:(SPPostgresFavorite *)favorite previous:(SPPostgresFavorite *)previous;
- (void)_rollBackPasswordsOf:(SPPostgresFavorite *)favorite to:(SPPostgresFavorite *)previous password:(NSString *)oldPassword sshPassword:(NSString *)oldSSHPassword;
- (void)_applyPortPlaceholders;
- (void)_collectPortFieldsInView:(NSView *)view;
- (NSError *)_connectionValidationError;
- (void)_reportFavoritesLoadError;
- (void)_connectionAttemptFinished:(SPPostgresConnector *)attemptConnector connection:(PGPostgresConnection *)connection error:(NSError *)error favorite:(SPPostgresFavorite *)favorite testOnly:(BOOL)testOnly;
@end

@implementation SPPostgresConnectionScreenAdapter
{
	id <SPPostgresConnectionScreenHost> host; // not retained
	SPPostgresFavoritesStore *store;
	id <SPPostgresKeychainAccess> keychain;

	SPConnectionEngine engine;
	NSSegmentedControl *engineControl;
	CGFloat engineControlAreaHeight;
	NSMutableArray *portFields;
	NSMutableArray *originalPortPlaceholders;

	// "MySQL Host:" labels in the form (no outlet in ConnectionView.xib) and their frames and fonts as loaded
	NSMutableArray *hostLabels;
	NSMutableArray *originalHostLabelFrames;
	NSMutableArray *originalHostLabelFonts;

	// The Postgres favorite nodes are children of a hidden holder (under an invisible root), never of a MySQL
	// group; the layout says where each is displayed in the FAVORITES list
	SPTreeNode *rootNode;
	SPTreeNode *holderNode;
	NSMutableDictionary *nodesByID;
	SPPostgresFavoritePlacementsStore *placementsStore;
	SPPostgresFavoritesLayout *layout;
	SPTreeNode *mysqlSection; // the section of the last -prepareOutline…, nil before

	SPPostgresFavorite *loadedFavorite;
	SPPostgresConnector *pendingConnector;

	// Port fields whose value binding the adapter re-made (see -_applyPortPlaceholders); unbound by -invalidate
	NSMutableArray *reboundPortFields;

	// The description of the favorites file error last reported (see -_reportFavoritesLoadError)
	NSString *reportedLoadError;

	// YES during the adapter's own store writes (see -_favoritesDidChange:)
	BOOL writingToStore;
	// YES during the adapter's own placements writes (see -_placementsDidChange:)
	BOOL writingPlacements;
	// YES while the host reloads for another window's placements write (see -_placementsDidChange:)
	BOOL applyingOutsidePlacements;
	// YES while the host reloads the outline for a store change made by this adapter (see -loadFavoriteIntoForm:)
	BOOL handlingStoreChange;
}

@synthesize keychain;

- (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller store:(SPPostgresFavoritesStore *)theStore
{
	return [self initWithConnectionController:controller store:theStore placementsStore:[SPPostgresFavoritePlacementsStore storeBesideFavoritesStore:theStore]];
}

- (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller store:(SPPostgresFavoritesStore *)theStore placementsStore:(SPPostgresFavoritePlacementsStore *)thePlacementsStore
{
	if ((self = [super init])) {
		host = controller;
		store = [theStore retain];
		placementsStore = [thePlacementsStore retain];
		layout = [[SPPostgresFavoritesLayout alloc] init];
		keychain = [[SPKeychain alloc] init];
		engine = SPConnectionEngineMySQL;
		portFields = [[NSMutableArray alloc] init];
		originalPortPlaceholders = [[NSMutableArray alloc] init];
		hostLabels = [[NSMutableArray alloc] init];
		originalHostLabelFrames = [[NSMutableArray alloc] init];
		originalHostLabelFonts = [[NSMutableArray alloc] init];
		reboundPortFields = [[NSMutableArray alloc] init];
		nodesByID = [[NSMutableDictionary alloc] init];

		// The hidden holder of the Postgres nodes (never displayed), under an invisible root as the MySQL
		// favorites are under favoritesTree
		rootNode = [[SPTreeNode treeNodeWithRepresentedObject:[SPGroupNode groupNodeWithName:@""]] retain];
		[rootNode setIsGroup:YES];
		holderNode = [[SPTreeNode treeNodeWithRepresentedObject:[SPGroupNode groupNodeWithName:@""]] retain];
		[holderNode setIsGroup:YES];
		[[rootNode mutableChildNodes] addObject:holderNode];

		[self _rebuildNodes];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_favoritesDidChange:) name:SPPostgresFavoritesDidChangeNotification object:store];
		// Any placements store: another window's adapter has its own store object for the same file
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_placementsDidChange:) name:SPPostgresFavoritePlacementsDidChangeNotification object:nil];
	}
	return self;
}

- (void)invalidate
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reportFavoritesLoadError) object:nil];
	[engineControl setTarget:nil];
	host = nil;

	// The port bindings this adapter made point at the host (the controller), which is going away. Only
	// these: bindings the adapter never re-made are the host's own. None are restored.
	for (NSTextField *field in reboundPortFields) [field unbind:NSValueBinding];
	[reboundPortFields removeAllObjects];

	// The completion still runs (Cancelled); with no pending connector it does nothing
	SPPostgresConnector *connector = pendingConnector;
	pendingConnector = nil;
	[connector cancel];
	[connector release];
}

- (void)dealloc
{
	[self invalidate];
	[store release];
	[keychain release];
	[engineControl release];
	[portFields release];
	[originalPortPlaceholders release];
	[hostLabels release];
	[originalHostLabelFrames release];
	[originalHostLabelFonts release];
	[reboundPortFields release];
	[reportedLoadError release];
	[rootNode release];
	[holderNode release];
	[nodesByID release];
	[placementsStore release];
	[layout release];
	[mysqlSection release];
	[loadedFavorite release];
	[super dealloc];
}

#pragma mark - Engine choice

- (NSSegmentedControl *)engineControl
{
	if (!engineControl) {
		engineControl = [[NSSegmentedControl segmentedControlWithLabels:@[@"MySQL", @"PostgreSQL"]
		                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
		                                                         target:self
		                                                         action:@selector(engineControlChanged:)] retain];
		[engineControl setSegmentStyle:NSSegmentStyleRounded];
		[engineControl setSelectedSegment:engine];
		[engineControl sizeToFit];
		[engineControl setToolTip:NSLocalizedString(@"Database engine of this connection", @"engine choice tooltip on the connection screen")];
	}
	return engineControl;
}

- (CGFloat)installEngineControlInContainer:(NSView *)container
{
	NSSegmentedControl *control = [self engineControl];
	if ([control superview] == container) return engineControlAreaHeight;

	NSTabView *tabView = nil;
	for (NSView *subview in [container subviews]) {
		if ([subview isKindOfClass:[NSTabView class]]) {
			tabView = (NSTabView *)subview;
			break;
		}
	}

	NSRect controlFrame = [control frame];
	engineControlAreaHeight = ceil(NSHeight(controlFrame)) + 12;

	// Make room: the tabs move down by the band's height. The container grows by the same amount
	// (the host adds -engineControlAreaHeight when sizing it), so the tab view keeps its size.
	if (tabView) {
		NSRect tabFrame = [tabView frame];
		tabFrame.size.height -= engineControlAreaHeight;
		[tabView setFrame:tabFrame];

		for (NSTabViewItem *item in [tabView tabViewItems]) {
			[self _collectPortFieldsInView:[item view]];
		}
	}

	// Centred, pinned to the top of the (unflipped) container
	NSRect bounds = [container bounds];
	controlFrame.origin.x = round((NSWidth(bounds) - NSWidth(controlFrame)) / 2);
	controlFrame.origin.y = [container isFlipped] ? 6 : NSHeight(bounds) - 6 - NSHeight(controlFrame);
	[control setFrame:controlFrame];
	[control setAutoresizingMask:(NSViewMinXMargin | NSViewMaxXMargin | ([container isFlipped] ? NSViewMaxYMargin : NSViewMinYMargin))];
	[container addSubview:control];

	[self _applyPortPlaceholders];

	return engineControlAreaHeight;
}

- (CGFloat)engineControlAreaHeight
{
	return engineControlAreaHeight;
}

- (void)_collectPortFieldsInView:(NSView *)view
{
	if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable] && [[(NSTextField *)view stringValue] isEqualToString:SPPostgresScreenMySQLHostLabel]) {
		[hostLabels addObject:view];
		[originalHostLabelFrames addObject:[NSValue valueWithRect:[view frame]]];
		[originalHostLabelFonts addObject:[(NSTextField *)view font]];
	}
	if ([view isKindOfClass:[NSTextField class]]) {
		NSDictionary *binding = [view infoForBinding:NSValueBinding];
		if ([[binding objectForKey:NSObservedKeyPathKey] isEqualToString:@"port"]) {
			NSString *placeholder = [[(NSTextField *)view cell] placeholderString];
			NSDictionary *options = [binding objectForKey:NSOptionsKey];
			[portFields addObject:view];
			[originalPortPlaceholders addObject:@{ @"placeholder": (placeholder ? placeholder : @""),
			                                       @"options": (options ? options : @{}) }];
		}
	}
	for (NSView *subview in [view subviews]) {
		[self _collectPortFieldsInView:subview];
	}
}

/**
 * Shows the engine's default port in empty port fields. The fields' value bindings carry the
 * placeholder for a nil port (NSNullPlaceholder, 3306 in ConnectionView.xib) and the cell carries it
 * for an empty one, so both are switched: the binding is re-made with the same object, key path and
 * options except the null placeholder. Switching back to MySQL restores the original options.
 */
- (void)_applyPortPlaceholders
{
	NSString *postgresPort = [NSString stringWithFormat:@"%lu", (unsigned long)SPPostgresScreenDefaultPort];
	[portFields enumerateObjectsUsingBlock:^(NSTextField *field, NSUInteger idx, BOOL *stop) {
		NSDictionary *original = [originalPortPlaceholders objectAtIndex:idx];
		BOOL postgres = (engine == SPConnectionEnginePostgreSQL);
		NSString *placeholder = postgres ? postgresPort : [original objectForKey:@"placeholder"];

		NSDictionary *binding = [field infoForBinding:NSValueBinding];
		id observed = [binding objectForKey:NSObservedObjectKey];
		NSString *keyPath = [binding objectForKey:NSObservedKeyPathKey];
		NSMutableDictionary *options = [[[original objectForKey:@"options"] mutableCopy] autorelease];
		BOOL hadNullPlaceholder = ([options objectForKey:NSNullPlaceholderBindingOption] != nil);
		if (postgres && hadNullPlaceholder) [options setObject:postgresPort forKey:NSNullPlaceholderBindingOption];

		NSString *current = [[binding objectForKey:NSOptionsKey] objectForKey:NSNullPlaceholderBindingOption];
		NSString *wanted = [options objectForKey:NSNullPlaceholderBindingOption];
		if (observed && keyPath && hadNullPlaceholder && !(current == wanted || [current isEqual:wanted])) {
			[observed retain];
			[field unbind:NSValueBinding];
			[field bind:NSValueBinding toObject:observed withKeyPath:keyPath options:options];
			[observed release];
			if (![reboundPortFields containsObject:field]) [reboundPortFields addObject:field];
		}

		[[field cell] setPlaceholderString:placeholder];
		[field setNeedsDisplay:YES];
	}];

	// The SSH tab's "MySQL Host:" label names the engine. It is right-aligned against its field, so the
	// longer PostgreSQL text grows it leftwards from the same right edge, as far as the tab's left edge,
	// and only if it still doesn't fit is its font reduced to fit. MySQL gets the nib frame and font back.
	BOOL postgres = (engine == SPConnectionEnginePostgreSQL);
	[hostLabels enumerateObjectsUsingBlock:^(NSTextField *label, NSUInteger idx, BOOL *stop) {
		NSRect frame = [[originalHostLabelFrames objectAtIndex:idx] rectValue];
		NSFont *font = [originalHostLabelFonts objectAtIndex:idx];
		[label setFont:font];
		[label setStringValue:(postgres ? SPPostgresScreenPostgreSQLHostLabel : SPPostgresScreenMySQLHostLabel)];
		if (postgres) {
			CGFloat needed = ceil([[label cell] cellSize].width);
			if (needed > NSWidth(frame)) {
				CGFloat grow = MIN(needed - NSWidth(frame), NSMinX(frame));
				frame.origin.x -= grow;
				frame.size.width += grow;
			}
			if (needed > NSWidth(frame)) {
				CGFloat size = floor([font pointSize] * NSWidth(frame) / needed * 2) / 2;
				[label setFont:[NSFont fontWithDescriptor:[font fontDescriptor] size:MAX(size, 10)]];
			}
		}
		[label setFrame:frame];
		[[label superview] setNeedsDisplay:YES];
	}];
}

- (SPConnectionEngine)selectedEngine
{
	return engine;
}

- (void)setEngineChoiceEnabled:(BOOL)enabled
{
	[engineControl setEnabled:enabled];
}

- (void)setSelectedEngine:(SPConnectionEngine)newEngine
{
	engine = (newEngine == SPConnectionEnginePostgreSQL) ? SPConnectionEnginePostgreSQL : SPConnectionEngineMySQL;
	[engineControl setSelectedSegment:engine];
	[self _applyPortPlaceholders];
}

+ (NSArray *)_formKeys
{
	return @[@"type", @"name", @"host", @"user", @"password", @"database", @"socket", @"port", @"useSSL", @"colorIndex",
	         @"sslKeyFileLocationEnabled", @"sslKeyFileLocation", @"sslCertificateFileLocationEnabled", @"sslCertificateFileLocation",
	         @"sslCACertFileLocationEnabled", @"sslCACertFileLocation",
	         @"sshHost", @"sshUser", @"sshPassword", @"sshKeyLocationEnabled", @"sshKeyLocation", @"sshPort"];
}

- (IBAction)engineControlChanged:(id)sender
{
	SPConnectionEngine newEngine = ([engineControl selectedSegment] == SPConnectionEnginePostgreSQL) ? SPConnectionEnginePostgreSQL : SPConnectionEngineMySQL;
	if (newEngine == engine) return;

	// A saved favorite of the other engine can't change engine: move to Quick Connect, keeping the
	// details in the form so they can be connected or saved as the new engine.
	id item = [host respondsToSelector:@selector(postgresSelectedOutlineItem)] ? [host postgresSelectedOutlineItem] : nil;
	BOOL leaveFavorite = NO;
	if (newEngine == SPConnectionEngineMySQL) {
		leaveFavorite = ([self favoriteForNode:item] != nil);
	}
	else if (item && [host respondsToSelector:@selector(postgresItemIsSavedMySQLFavorite:)]) {
		leaveFavorite = [host postgresItemIsSavedMySQLFavorite:item];
	}

	if (leaveFavorite && [host respondsToSelector:@selector(selectQuickConnectItem)]) {
		NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
		for (NSString *key in [[self class] _formKeys]) {
			id value = [(id)host valueForKey:key];
			[snapshot setObject:(value ? value : [NSNull null]) forKey:key];
		}

		[host selectQuickConnectItem];

		for (NSString *key in [[self class] _formKeys]) {
			id value = [snapshot objectForKey:key];
			[(id)host setValue:(value == [NSNull null] ? nil : value) forKey:key];
		}
	}

	// The previous engine's default port (or none) means "the default": clear it so the new engine's
	// default applies (shown as the placeholder). Any other port was chosen and is kept.
	NSString *previousDefault = (engine == SPConnectionEnginePostgreSQL) ? [NSString stringWithFormat:@"%lu", (unsigned long)SPPostgresScreenDefaultPort] : SPPostgresScreenMySQLDefaultPort;
	NSString *port = [[host port] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![port length] || [port isEqualToString:previousDefault]) [host setPort:nil];

	[self setSelectedEngine:newEngine];
}

#pragma mark - Outline

- (void)_rebuildNodes
{
	NSArray *favorites = [store favorites];
	NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:[favorites count]];
	NSMutableDictionary *newNodesByID = [NSMutableDictionary dictionaryWithCapacity:[favorites count]];

	for (SPPostgresFavorite *favorite in favorites) {
		NSString *favoriteID = [favorite favoriteID];
		if (!favoriteID || [newNodesByID objectForKey:favoriteID]) continue;

		// Reuse nodes so the outline keeps its selection across reloads
		SPTreeNode *node = [nodesByID objectForKey:favoriteID];
		if (!node) {
			SPPostgresFavoriteNode *represented = [[[SPPostgresFavoriteNode alloc] init] autorelease];
			node = [SPTreeNode treeNodeWithRepresentedObject:represented];
		}
		[(SPPostgresFavoriteNode *)[node representedObject] setFavorite:favorite];
		[nodes addObject:node];
		[newNodesByID setObject:node forKey:favoriteID];
	}

	[[holderNode mutableChildNodes] setArray:nodes];
	[nodesByID setDictionary:newNodesByID];

	// An unreadable favorites file is reported from a later run loop turn: the host may still be setting up
	// its window (the adapter is made while the connection screen loads)
	NSError *loadError = [store lastLoadError];
	if (!loadError) {
		[reportedLoadError release], reportedLoadError = nil;
	}
	else if (![[loadError localizedDescription] isEqualToString:reportedLoadError]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reportFavoritesLoadError) object:nil];
		[self performSelector:@selector(_reportFavoritesLoadError) withObject:nil afterDelay:0];
	}
}

/// Shows the favorites file error once per distinct error: as a sheet on the host's window, else in the log.
- (void)_reportFavoritesLoadError
{
	NSError *loadError = [store lastLoadError];
	NSString *description = [loadError localizedDescription];
	if (!host || !loadError || [description isEqualToString:reportedLoadError]) return;

	[reportedLoadError release];
	reportedLoadError = [description copy];

	NSWindow *window = [self _sheetWindow];
	if (window) {
		SPOnewayAlertSheet(NSLocalizedString(@"PostgreSQL favorites could not be read", @"PostgreSQL favorites file unreadable title"), window, description);
	}
	else {
		NSLog(@"PostgreSQL favorites could not be read: %@", description);
	}
}

- (void)_favoritesDidChange:(NSNotification *)notification
{
	[self _rebuildNodes];

	// Re-place the nodes now (new ones by their stored placement, removed ones gone), keeping the arrangement
	// not saved yet; nothing is written here (the host's reload saves)
	if (mysqlSection) {
		[layout resolveWithMySQLSection:mysqlSection postgresNodes:[holderNode childNodes] placements:[self _currentPlacementsOver:[placementsStore placements]]];
	}

	if (loadedFavorite && ![nodesByID objectForKey:[loadedFavorite favoriteID]]) {
		[loadedFavorite release];
		loadedFavorite = nil;
	}

	if ([host respondsToSelector:@selector(postgresFavoritesDidChange)]) {
		// Only this adapter's own writes keep the loaded form as it is (it already holds what was saved);
		// a change made elsewhere (another connection tab, another store client) reloads it
		BOOL wasHandling = handlingStoreChange;
		handlingStoreChange = writingToStore;
		[host postgresFavoritesDidChange];
		handlingStoreChange = wasHandling;
	}
}

- (BOOL)_saveToStore:(SPPostgresFavorite *)favorite error:(NSError **)error
{
	BOOL wasWriting = writingToStore;
	writingToStore = YES;
	BOOL saved = [store saveFavorite:favorite error:error];
	writingToStore = wasWriting;
	return saved;
}

- (BOOL)_removeFromStoreFavoriteWithID:(NSString *)favoriteID error:(NSError **)error
{
	BOOL wasWriting = writingToStore;
	writingToStore = YES;
	BOOL removed = [store removeFavoriteWithID:favoriteID error:error];
	writingToStore = wasWriting;
	return removed;
}

/// Placements changed on disk. The adapter's own writes are ignored (the arrangement already is what was
/// written); another window's write replaces this arrangement (any part not saved yet is dropped, so it
/// can't overwrite the newer file) and reloads the host.
- (void)_placementsDidChange:(NSNotification *)notification
{
	if (writingPlacements) return;
	NSURL *changedURL = [[notification object] respondsToSelector:@selector(fileURL)] ? [[notification object] fileURL] : nil;
	NSString *changedPath = [[changedURL URLByStandardizingPath] path];
	if (!changedPath || ![changedPath isEqualToString:[[[placementsStore fileURL] URLByStandardizingPath] path]]) return;

	if (mysqlSection) {
		[layout resolveWithMySQLSection:mysqlSection postgresNodes:[holderNode childNodes] placements:[placementsStore placements]];
	}

	if ([host respondsToSelector:@selector(postgresFavoritesDidChange)]) {
		// Only where favorites are displayed changed: the loaded form stays as it is. The reload doesn't save:
		// the arrangement is the file's, and the file may already hold the placement of a favorite the other
		// window is about to save, which pruning would drop.
		BOOL wasHandling = handlingStoreChange, wasApplying = applyingOutsidePlacements;
		handlingStoreChange = YES;
		applyingOutsidePlacements = YES;
		[host postgresFavoritesDidChange];
		handlingStoreChange = wasHandling;
		applyingOutsidePlacements = wasApplying;
	}
}

/// `stored` with the current arrangement's placements over it, without placements of favorites the store no
/// longer has (kept all when the favorites file couldn't be read: the nodes don't say what exists then).
- (NSDictionary *)_currentPlacementsOver:(NSDictionary *)stored
{
	NSMutableDictionary *current = [NSMutableDictionary dictionaryWithDictionary:stored];
	if (mysqlSection) [current addEntriesFromDictionary:[layout placements]];
	if (![store lastLoadError]) {
		for (id favoriteID in [current allKeys]) {
			if (![nodesByID objectForKey:favoriteID]) [current removeObjectForKey:favoriteID];
		}
	}
	return current;
}

/// Writes the current placements when they differ from the file's. Returns them.
- (NSDictionary *)_savePlacements
{
	NSDictionary *stored = [placementsStore placements];
	NSDictionary *current = [self _currentPlacementsOver:stored];
	if ([current isEqualToDictionary:stored]) return current;

	BOOL wasWriting = writingPlacements;
	writingPlacements = YES;
	NSError *error = nil;
	if (![placementsStore setPlacements:current error:&error]) {
		NSLog(@"PostgreSQL favorite placements could not be saved: %@", [error localizedDescription]);
	}
	writingPlacements = wasWriting;
	return current;
}

- (BOOL)hasPostgresFavorites
{
	return [nodesByID count] > 0;
}

- (void)prepareOutlineWithMySQLSection:(SPTreeNode *)section savingLayout:(BOOL)saveLayout
{
	// Saving: what was written, or (if the write failed) what is displayed now, so nothing moves
	NSDictionary *placements = (saveLayout && !applyingOutsidePlacements) ? [self _savePlacements] : [placementsStore placements];

	[section retain];
	[mysqlSection release];
	mysqlSection = section;
	[layout resolveWithMySQLSection:section postgresNodes:[holderNode childNodes] placements:placements];
}

- (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group
{
	return [layout displayedChildrenOfGroup:group];
}

- (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node
{
	return [layout displayedParentOfNode:node];
}

- (void)moveNodes:(NSArray *)nodes toGroup:(SPTreeNode *)group displayedIndex:(NSInteger)index
{
	if (!mysqlSection) return;
	[layout moveNodes:nodes toGroup:group displayedIndex:index];
	[self _savePlacements];
}

- (void)setDisplayedChildren:(NSArray *)children ofGroup:(SPTreeNode *)group
{
	if (!mysqlSection) return;
	[layout setDisplayedChildren:children ofGroup:group];
}

- (void)removePostgresFavoritesWithinGroup:(SPTreeNode *)group
{
	NSMutableArray *favorites = [NSMutableArray array];
	for (SPTreeNode *node in [layout postgresNodesWithinGroup:group]) {
		SPPostgresFavorite *favorite = [self favoriteForNode:node];
		if (favorite) [favorites addObject:favorite];
	}

	for (SPPostgresFavorite *favorite in favorites) {
		NSError *error = nil;
		if (![self _removeFavorite:favorite error:&error]) {
			if (error) [self _showError:error];
			return;
		}
	}
}

/**
 * The node of a new favorite (not in the store yet), displayed right after `existing`, else at the end of the
 * host's group for new favorites, with the placements written. Saving the favorite next then finds it in
 * place (-_rebuildNodes reuses the node). Before the outline was prepared it gets no placement: it shows at
 * the end of the top level.
 */
- (SPTreeNode *)_displayNewFavorite:(SPPostgresFavorite *)favorite afterNode:(SPTreeNode *)existing
{
	SPPostgresFavoriteNode *represented = [[[SPPostgresFavoriteNode alloc] init] autorelease];
	[represented setFavorite:favorite];
	SPTreeNode *node = [SPTreeNode treeNodeWithRepresentedObject:represented];
	[[holderNode mutableChildNodes] addObject:node];
	[nodesByID setObject:node forKey:[favorite favoriteID]];

	if (!mysqlSection) return node;

	if (existing) {
		[layout insertPostgresNode:node afterNode:existing];
	}
	else {
		SPTreeNode *group = [host respondsToSelector:@selector(postgresGroupForNewFavorite)] ? [host postgresGroupForNewFavorite] : nil;
		if (!group || ![group isGroup] || [self isPostgresNode:group]) group = mysqlSection;
		[layout appendPostgresNode:node toGroup:group];
	}
	[self _savePlacements];

	return node;
}

/// Saving a new favorite failed: drop its node (its placement is pruned by the next save).
- (void)_forgetUnsavedFavorite
{
	[self _rebuildNodes];
	if (mysqlSection) {
		[layout resolveWithMySQLSection:mysqlSection postgresNodes:[holderNode childNodes] placements:[self _currentPlacementsOver:[placementsStore placements]]];
	}
}

/// Removes `favorite` from the store, then its keychain items.
- (BOOL)_removeFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error
{
	if (![self _removeFromStoreFavoriteWithID:[favorite favoriteID] error:error]) return NO;
	[keychain deletePasswordForName:[favorite keychainName] account:[favorite keychainAccount]];
	[keychain deletePasswordForName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
	return YES;
}

- (BOOL)isPostgresNode:(id)outlineItem
{
	if (!outlineItem) return NO;
	if (outlineItem == holderNode || outlineItem == rootNode) return YES;
	return [self favoriteForNode:outlineItem] != nil;
}

- (SPPostgresFavorite *)favoriteForNode:(id)outlineItem
{
	if (![outlineItem isKindOfClass:[NSTreeNode class]]) return nil;
	id represented = [(NSTreeNode *)outlineItem representedObject];
	if (![represented isKindOfClass:[SPPostgresFavoriteNode class]]) return nil;
	return [(SPPostgresFavoriteNode *)represented favorite];
}

- (id)nodeForFavoriteID:(NSString *)favoriteID
{
	return favoriteID ? [nodesByID objectForKey:favoriteID] : nil;
}

- (NSColor *)labelColorForNode:(id)outlineItem
{
	SPPostgresFavorite *favorite = [self favoriteForNode:outlineItem];
	if (!favorite || [favorite colorIndex] < 0) return nil;
	return [[SPFavoriteColorSupport sharedInstance] colorForIndex:[favorite colorIndex]];
}

+ (NSImage *)favoriteImage
{
	static NSImage *image = nil;
	if (!image) {
		// The PostgreSQL elephant, at the MySQL favorites' icon size (16 pt, with a 2x representation)
		NSImage *elephant = [NSImage imageNamed:SPPostgresScreenElephantImage];
		if (elephant) {
			image = [elephant copy];
			NSImage *mysql = [NSImage imageNamed:SPPostgresScreenDatabaseImage];
			[image setSize:(mysql ? [mysql size] : NSMakeSize(16, 16))];
			return image;
		}

		// Fallback (resource missing): the MySQL favorites' icon tinted PostgreSQL blue
		NSImage *base = [NSImage imageNamed:SPPostgresScreenDatabaseImage];
		NSSize size = base ? [base size] : NSMakeSize(16, 16);
		// Drawn on demand, so the tint follows the base image's 1x/2x representations
		image = [[NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
			[base drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
			[[NSColor colorWithCalibratedRed:0x33 / 255.0 green:0x67 / 255.0 blue:0x91 / 255.0 alpha:0.75] set];
			NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
			return YES;
		}] retain];
	}
	return image;
}

- (NSString *)toolTipForNode:(id)outlineItem
{
	SPPostgresFavorite *favorite = [self favoriteForNode:outlineItem];
	if (!favorite) return nil;
	NSString *where = ([favorite type] == SPPostgresSocketConnection) ? @"localhost" : [favorite host];
	return [where length] ? [NSString stringWithFormat:@"%@ (PostgreSQL, %@)", [favorite name], where] : [NSString stringWithFormat:@"%@ (PostgreSQL)", [favorite name]];
}

- (void)didSelectMySQLItemIsFavorite:(BOOL)isFavorite
{
	if (loadedFavorite) {
		[loadedFavorite release];
		loadedFavorite = nil;
	}
	if (isFavorite && engine != SPConnectionEngineMySQL) {
		[self setSelectedEngine:SPConnectionEngineMySQL];
	}
}

#pragma mark - Form

- (SPPostgresFavorite *)loadedFavorite
{
	return loadedFavorite;
}

- (void)loadFavoriteIntoForm:(SPPostgresFavorite *)favorite
{
	if (!favorite) return;

	// A store change re-selects the loaded favorite when its row moves (e.g. renamed so it re-sorts).
	// The form already holds what was saved, including the passwords: reloading it from the store and
	// keychain at that point could only lose edits, so keep it.
	if (handlingStoreChange && [[loadedFavorite favoriteID] isEqualToString:[favorite favoriteID]]) {
		[self setSelectedEngine:SPConnectionEnginePostgreSQL];
		return;
	}

	[self setSelectedEngine:SPConnectionEnginePostgreSQL];

	SPPostgresFavorite *copy = [favorite copy];
	[loadedFavorite release];
	loadedFavorite = copy;

	[host setType:[favorite type]];
	[host setName:SPPGOrEmpty([favorite name])];
	[host setHost:SPPGOrEmpty([favorite host])];
	[host setPort:([favorite port] ? [NSString stringWithFormat:@"%lu", (unsigned long)[favorite port]] : @"")];
	[host setUser:SPPGOrEmpty([favorite user])];
	[host setDatabase:SPPGOrEmpty([favorite database])];
	[host setSocket:SPPGOrEmpty([favorite socketPath])];
	[host setColorIndex:[favorite colorIndex]];

	[host setUseSSL:([favorite useSSL] ? NSOnState : NSOffState)];
	[host setSslKeyFileLocationEnabled:([[favorite sslKeyPath] length] ? NSOnState : NSOffState)];
	[host setSslKeyFileLocation:SPPGOrEmpty([favorite sslKeyPath])];
	[host setSslCertificateFileLocationEnabled:([[favorite sslCertPath] length] ? NSOnState : NSOffState)];
	[host setSslCertificateFileLocation:SPPGOrEmpty([favorite sslCertPath])];
	[host setSslCACertFileLocationEnabled:([[favorite sslCACertPath] length] ? NSOnState : NSOffState)];
	[host setSslCACertFileLocation:SPPGOrEmpty([favorite sslCACertPath])];

	[host setSshHost:SPPGOrEmpty([favorite sshHost])];
	[host setSshUser:SPPGOrEmpty([favorite sshUser])];
	[host setSshPort:([favorite sshPort] ? [NSString stringWithFormat:@"%lu", (unsigned long)[favorite sshPort]] : @"")];
	[host setSshKeyLocationEnabled:([[favorite sshKeyPath] length] ? NSOnState : NSOffState)];
	[host setSshKeyLocation:SPPGOrEmpty([favorite sshKeyPath])];

	NSString *thePassword = [keychain getPasswordForName:[favorite keychainName] account:[favorite keychainAccount]];
	[host setPassword:([thePassword length] ? thePassword : nil)];
	NSString *theSSHPassword = [keychain getPasswordForName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
	[host setSshPassword:([theSSHPassword length] ? theSSHPassword : nil)];
}

- (SPPostgresFavorite *)favoriteFromForm
{
	SPPostgresFavorite *favorite = [[[SPPostgresFavorite alloc] init] autorelease];
	if (loadedFavorite) [favorite setFavoriteID:[loadedFavorite favoriteID]];

	NSInteger formType = [host type];
	[favorite setType:(formType == SPPostgresSocketConnection || formType == SPPostgresSSHConnection) ? (SPPostgresConnectionType)formType : SPPostgresTCPIPConnection];

	NSString *theHost = SPPGNonEmpty([[host host] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
	[favorite setHost:theHost];
	NSInteger thePort = [[host port] integerValue];
	[favorite setPort:(thePort > 0 ? (NSUInteger)thePort : SPPostgresScreenDefaultPort)];
	[favorite setUser:SPPGNonEmpty([host user])];
	[favorite setDatabase:SPPGNonEmpty([host database])];
	[favorite setSocketPath:SPPGNonEmpty([host socket])];
	[favorite setColorIndex:[host colorIndex]];

	[favorite setUseSSL:([host useSSL] == NSOnState)];
	[favorite setSslKeyPath:([host sslKeyFileLocationEnabled] ? SPPGNonEmpty([host sslKeyFileLocation]) : nil)];
	[favorite setSslCertPath:([host sslCertificateFileLocationEnabled] ? SPPGNonEmpty([host sslCertificateFileLocation]) : nil)];
	[favorite setSslCACertPath:([host sslCACertFileLocationEnabled] ? SPPGNonEmpty([host sslCACertFileLocation]) : nil)];

	[favorite setSshHost:SPPGNonEmpty([[host sshHost] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]])];
	[favorite setSshUser:SPPGNonEmpty([host sshUser])];
	NSInteger theSSHPort = [[host sshPort] integerValue];
	[favorite setSshPort:(theSSHPort > 0 ? (NSUInteger)theSSHPort : 0)];
	[favorite setSshKeyPath:([host sshKeyLocationEnabled] ? SPPGNonEmpty([host sshKeyLocation]) : nil)];

	// Name: as typed, else generated like the MySQL form does (host/database)
	NSString *theName = SPPGNonEmpty([[host name] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
	if (!theName) {
		NSString *where = ([favorite type] == SPPostgresSocketConnection) ? @"localhost" : [favorite host];
		if ([where length]) {
			theName = [[favorite database] length] ? [NSString stringWithFormat:@"%@/%@", where, [favorite database]] : where;
		}
		else {
			theName = NSLocalizedString(@"Untitled", @"Name for an untitled connection");
		}
	}
	[favorite setName:theName];

	return favorite;
}

- (NSError *)validationErrorForForm
{
	NSString *message = nil;
	NSInteger formType = [host type];
	NSString *theHost = [[host host] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	// libpq would silently use its default socket for an empty host: require one for TCP/IP and SSH
	if ((formType == SPPostgresTCPIPConnection || formType == SPPostgresSSHConnection) && ![theHost length]) {
		message = NSLocalizedString(@"Insufficient details provided to establish a connection. Please enter at least the hostname.", @"insufficient details informative message");
	}
	else if (formType == SPPostgresSSHConnection && ![[[host sshHost] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]) {
		message = NSLocalizedString(@"Insufficient details provided to establish a connection. Please enter the hostname for the SSH Tunnel, or disable the SSH Tunnel.", @"insufficient SSH tunnel details informative message");
	}

	if (!message) return nil;

	return [NSError errorWithDomain:SPPostgresErrorDomain
	                           code:SPPostgresErrorInvalidSettings
	                       userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Insufficient connection details", @"insufficient details message"),
	                                   NSLocalizedRecoverySuggestionErrorKey: message }];
}

- (NSError *)_connectionValidationError
{
	NSError *error = [self validationErrorForForm];
	if (error) return error;

	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *title = nil;
	NSString *message = nil;

	if ([host type] == SPPostgresSSHConnection && [host sshKeyLocationEnabled] && [[host sshKeyLocation] length]
		&& ![fm fileExistsAtPath:[[host sshKeyLocation] stringByExpandingTildeInPath]]) {
		title = NSLocalizedString(@"SSH Key not found", @"SSH key check error");
		message = NSLocalizedString(@"A SSH key location was specified, but no file was found in the specified location.  Please re-select the key and try again.", @"SSH key not found message");
	}
	else if ([host useSSL]) {
		NSArray *checks = @[
			@[@([host sslKeyFileLocationEnabled]), SPPGOrEmpty([host sslKeyFileLocation]), NSLocalizedString(@"SSL Key File not found", @"SSL key file check error")],
			@[@([host sslCertificateFileLocationEnabled]), SPPGOrEmpty([host sslCertificateFileLocation]), NSLocalizedString(@"SSL Certificate File not found", @"SSL certificate file check error")],
			@[@([host sslCACertFileLocationEnabled]), SPPGOrEmpty([host sslCACertFileLocation]), NSLocalizedString(@"SSL Certificate Authority File not found", @"SSL certificate authority file check error")]
		];
		for (NSArray *check in checks) {
			NSString *path = [check objectAtIndex:1];
			if ([[check objectAtIndex:0] integerValue] && [path length] && ![fm fileExistsAtPath:[path stringByExpandingTildeInPath]]) {
				title = [check objectAtIndex:2];
				message = [NSString stringWithFormat:NSLocalizedString(@"No file was found at %@. Please re-select it and try again.", @"PostgreSQL SSL file not found (path)"), path];
				break;
			}
		}
	}

	if (!title) return nil;

	return [NSError errorWithDomain:SPPostgresErrorDomain code:SPPostgresErrorInvalidSettings userInfo:@{ NSLocalizedDescriptionKey: title, NSLocalizedRecoverySuggestionErrorKey: message }];
}

- (BOOL)saveFormAsFavorite:(NSError **)error
{
	return [self _saveFormAsNew:NO error:error];
}

- (BOOL)saveFormAsNewFavorite:(NSError **)error
{
	return [self _saveFormAsNew:YES error:error];
}

- (BOOL)_saveFormAsNew:(BOOL)asNew error:(NSError **)error
{
	NSError *validationError = [self validationErrorForForm];
	if (validationError) {
		if (error) *error = validationError;
		return NO;
	}

	SPPostgresFavorite *previous = asNew ? nil : [[loadedFavorite retain] autorelease];
	SPPostgresFavorite *favorite = [self favoriteFromForm];
	if (!previous) [favorite setFavoriteID:[[NSUUID UUID] UUIDString]];

	NSString *thePassword = [[[host password] copy] autorelease];
	NSString *theSSHPassword = [[[host sshPassword] copy] autorelease];

	// Keychain first: the store's change notification (sent from inside -saveFavorite:) can make the
	// host load the favorite, and its passwords must already be under the new names by then.
	NSString *oldPassword = previous ? [keychain getPasswordForName:[previous keychainName] account:[previous keychainAccount]] : nil;
	NSString *oldSSHPassword = previous ? [keychain getPasswordForName:[previous sshKeychainName] account:[previous sshKeychainAccount]] : nil;
	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:favorite previous:previous];

	// A new favorite is displayed (and its placement written) before it is saved
	if (!previous) [self _displayNewFavorite:favorite afterNode:nil];

	if (![self _saveToStore:favorite error:error]) {
		[self _rollBackPasswordsOf:favorite to:previous password:oldPassword sshPassword:oldSSHPassword];
		if (!previous) [self _forgetUnsavedFavorite];
		return NO;
	}

	SPPostgresFavorite *copy = [favorite copy];
	[loadedFavorite release];
	loadedFavorite = copy;

	id node = [self nodeForFavoriteID:[favorite favoriteID]];
	if (node && [host respondsToSelector:@selector(postgresSelectOutlineItem:)]) {
		[host postgresSelectOutlineItem:node];
	}

	return YES;
}

/**
 * Undoes -_storePassword:…forFavorite:`favorite` previous:`previous` after a failed store save: the items
 * go back under `previous`'s names with their old values, or are removed when there was no previous.
 */
- (void)_rollBackPasswordsOf:(SPPostgresFavorite *)favorite to:(SPPostgresFavorite *)previous password:(NSString *)oldPassword sshPassword:(NSString *)oldSSHPassword
{
	if (previous) {
		[self _storePassword:oldPassword sshPassword:oldSSHPassword forFavorite:previous previous:favorite];
	}
	else {
		[keychain deletePasswordForName:[favorite keychainName] account:[favorite keychainAccount]];
		[keychain deletePasswordForName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
	}
}

/**
 * Stores (or removes) the passwords under `favorite`'s Postgres keychain names, moving the items of
 * `previous` (the favorite as it was saved before) when its names or accounts changed.
 */
- (void)_storePassword:(NSString *)thePassword sshPassword:(NSString *)theSSHPassword forFavorite:(SPPostgresFavorite *)favorite previous:(SPPostgresFavorite *)previous
{
	NSArray *pairs = @[
		@[SPPGOrEmpty(thePassword), [favorite keychainName], [favorite keychainAccount],
		  (previous ? [previous keychainName] : @""), (previous ? [previous keychainAccount] : @"")],
		@[SPPGOrEmpty(theSSHPassword), [favorite sshKeychainName], [favorite sshKeychainAccount],
		  (previous ? [previous sshKeychainName] : @""), (previous ? [previous sshKeychainAccount] : @"")]
	];

	for (NSArray *pair in pairs) {
		NSString *secret = [pair objectAtIndex:0];
		NSString *newName = [pair objectAtIndex:1], *newAccount = [pair objectAtIndex:2];
		NSString *oldName = [pair objectAtIndex:3], *oldAccount = [pair objectAtIndex:4];
		BOOL hasOld = (previous != nil);

		if (![secret length]) {
			if (hasOld) [keychain deletePasswordForName:oldName account:oldAccount];
			if (hasOld && !([oldName isEqualToString:newName] && [oldAccount isEqualToString:newAccount])) {
				[keychain deletePasswordForName:newName account:newAccount];
			}
			continue;
		}

		if (hasOld && [keychain passwordExistsForName:oldName account:oldAccount]) {
			[keychain updateItemWithName:oldName account:oldAccount toName:newName account:newAccount password:secret];
		}
		else if ([keychain passwordExistsForName:newName account:newAccount]) {
			[keychain updateItemWithName:newName account:newAccount toName:newName account:newAccount password:secret];
		}
		else {
			[keychain addPassword:secret forName:newName account:newAccount];
		}
	}
}

#pragma mark - Actions (UI)

- (NSWindow *)_sheetWindow
{
	return [host respondsToSelector:@selector(postgresSheetWindow)] ? [host postgresSheetWindow] : nil;
}

- (void)_showError:(NSError *)error
{
	NSString *message = [[error userInfo] objectForKey:NSLocalizedRecoverySuggestionErrorKey];
	SPOnewayAlertSheet([error localizedDescription], [self _sheetWindow], (message ? message : @""));
}

- (BOOL)saveFormShowingErrors:(BOOL)asNew
{
	NSError *error = nil;
	if ([self _saveFormAsNew:asNew error:&error]) return YES;
	if (error) [self _showError:error];
	return NO;
}

- (id)addNewFavorite
{
	SPPostgresFavorite *favorite = [[[SPPostgresFavorite alloc] init] autorelease];
	[favorite setName:NSLocalizedString(@"New Favorite", @"new favorite name")];

	[self _displayNewFavorite:favorite afterNode:nil];

	NSError *error = nil;
	if (![self _saveToStore:favorite error:&error]) {
		[self _forgetUnsavedFavorite];
		if (error) [self _showError:error];
		return nil;
	}
	return [self nodeForFavoriteID:[favorite favoriteID]];
}

- (void)removeFavoriteNodeAfterConfirmation:(id)outlineItem
{
	SPPostgresFavorite *favorite = [[[self favoriteForNode:outlineItem] retain] autorelease];
	if (!favorite) return;

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Delete favorite '%@'?", @"delete database message"), [favorite name]]];
	[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the favorite '%@'? This operation cannot be undone.", @"delete database informative message"), [favorite name]]];
	[alert setAlertStyle:NSAlertStyleCritical];
	NSButton *deleteButton = [alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	NSButton *cancelButton = [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	// As for MySQL favorites: Return cancels, Cmd-D deletes
	[deleteButton setKeyEquivalent:@"d"];
	[deleteButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[cancelButton setKeyEquivalent:@"\r"];

	void (^remove)(void) = ^{
		NSError *error = nil;
		if (![self _removeFavorite:favorite error:&error]) {
			if (error) [self _showError:error];
			return;
		}
		if ([host respondsToSelector:@selector(selectQuickConnectItem)]) [host selectQuickConnectItem];
	};

	NSWindow *window = [self _sheetWindow];
	if (window) {
		[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
			if (returnCode == NSAlertFirstButtonReturn) remove();
		}];
	}
	else if ([alert runModal] == NSAlertFirstButtonReturn) {
		remove();
	}
}

- (id)duplicateFavoriteNode:(id)outlineItem
{
	SPPostgresFavorite *original = [self favoriteForNode:outlineItem];
	if (!original) return nil;

	SPPostgresFavorite *duplicate = [[original copy] autorelease];
	[duplicate setFavoriteID:[[NSUUID UUID] UUIDString]];
	[duplicate setName:[NSString stringWithFormat:NSLocalizedString(@"%@ Copy", @"Initial favourite name after duplicating a previous favourite"), [original name]]];

	NSString *thePassword = [keychain getPasswordForName:[original keychainName] account:[original keychainAccount]];
	NSString *theSSHPassword = [keychain getPasswordForName:[original sshKeychainName] account:[original sshKeychainAccount]];

	// Keychain first (see -_saveFormAsNew:error:)
	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:duplicate previous:nil];

	[self _displayNewFavorite:duplicate afterNode:outlineItem];

	NSError *error = nil;
	if (![self _saveToStore:duplicate error:&error]) {
		[self _rollBackPasswordsOf:duplicate to:nil password:nil sshPassword:nil];
		[self _forgetUnsavedFavorite];
		if (error) [self _showError:error];
		return nil;
	}

	return [self nodeForFavoriteID:[duplicate favoriteID]];
}

- (void)renameFavoriteNode:(id)outlineItem to:(NSString *)newName
{
	SPPostgresFavorite *original = [[[self favoriteForNode:outlineItem] retain] autorelease];
	NSString *trimmed = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (!original || ![trimmed length] || [trimmed isEqualToString:[original name]]) return;

	SPPostgresFavorite *renamed = [[original copy] autorelease];
	[renamed setName:trimmed];

	// The keychain names contain the favorite's name: move the items
	NSString *thePassword = [keychain getPasswordForName:[original keychainName] account:[original keychainAccount]];
	NSString *theSSHPassword = [keychain getPasswordForName:[original sshKeychainName] account:[original sshKeychainAccount]];

	// Keychain first (see -_saveFormAsNew:error:)
	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:renamed previous:original];

	NSError *error = nil;
	if (![self _saveToStore:renamed error:&error]) {
		[self _rollBackPasswordsOf:renamed to:original password:thePassword sshPassword:theSSHPassword];
		if (error) [self _showError:error];
		return;
	}

	if ([[loadedFavorite favoriteID] isEqualToString:[renamed favoriteID]]) {
		[loadedFavorite setName:trimmed];
		[host setName:trimmed];
	}
}

#pragma mark - Connecting

- (BOOL)isConnecting
{
	return pendingConnector != nil;
}

- (void)connectFromForm
{
	[self connectFromFormTestingOnly:NO];
}

- (void)connectFromFormTestingOnly:(BOOL)testOnly
{
	if (pendingConnector) return;

	NSError *validationError = [self _connectionValidationError];
	if (validationError) {
		[self _showError:validationError];
		return;
	}

	SPPostgresFavorite *favorite = [self favoriteFromForm];

	// Passwords: as typed, else from the keychain under the Postgres names of the loaded favorite
	SPPostgresFavorite *keychainSource = loadedFavorite ? loadedFavorite : favorite;
	NSString *thePassword = [host password];
	if (![thePassword length]) thePassword = [keychain getPasswordForName:[keychainSource keychainName] account:[keychainSource keychainAccount]];
	NSString *theSSHPassword = [host sshPassword];
	if (![theSSHPassword length]) theSSHPassword = [keychain getPasswordForName:[keychainSource sshKeychainName] account:[keychainSource sshKeychainAccount]];

	pendingConnector = [[SPPostgresConnector alloc] initWithFavorite:favorite password:thePassword sshPassword:theSSHPassword parentWindow:[self _sheetWindow]];

	if ([host respondsToSelector:@selector(postgresSetConnecting:)]) [host postgresSetConnecting:YES];

	// The block retains self (released when the connector releases it); it must not retain the
	// connector, which owns the block.
	__block SPPostgresConnector *attemptConnector = pendingConnector;
	[pendingConnector connectWithCompletion:^(PGPostgresConnection *connection, NSError *error) {
		[self _connectionAttemptFinished:attemptConnector connection:connection error:error favorite:favorite testOnly:testOnly];
	}];
}

- (void)_connectionAttemptFinished:(SPPostgresConnector *)attemptConnector connection:(PGPostgresConnection *)connection error:(NSError *)error favorite:(SPPostgresFavorite *)favorite testOnly:(BOOL)testOnly
{
	// Invalidated (pendingConnector already released and cancelled) or a stale attempt
	if (!pendingConnector || attemptConnector != pendingConnector) return;

	SPPostgresConnector *connector = [pendingConnector autorelease];
	pendingConnector = nil;

	if ([host respondsToSelector:@selector(postgresSetConnecting:)]) [host postgresSetConnecting:NO];

	if (error || !connection) {
		if ([error code] == SPPostgresErrorCancelled && [[error domain] isEqualToString:SPPostgresErrorDomain]) return;

		if (testOnly && [host respondsToSelector:@selector(postgresShowTestResult:)]) {
			[host postgresShowTestResult:NSLocalizedString(@"Connection failed!", @"PostgreSQL connection test failed")];
		}
		NSString *message = [error localizedDescription];
		SPOnewayAlertSheet(NSLocalizedString(@"Unable to connect to PostgreSQL", @"PostgreSQL connection failed title"),
		                   [self _sheetWindow],
		                   (message ? message : NSLocalizedString(@"The connection failed.", @"PostgreSQL connection failed, no detail")));
		return;
	}

	if (testOnly) {
		[connector disconnect];
		if ([host respondsToSelector:@selector(postgresShowTestResult:)]) {
			[host postgresShowTestResult:NSLocalizedString(@"Connection succeeded", @"PostgreSQL connection test succeeded")];
		}
		return;
	}

	// The document takes over the connector (and closes the connection when it goes away). The host puts it
	// in place of the connection tab, which retains it. Replacing the tab closes the host's MySQL document,
	// which may release the host and this adapter's last owner: nothing here touches either afterwards (the
	// connector's completion block keeps this adapter alive until this method returns).
	SPPostgresDocument *document = [[SPPostgresDocument alloc] initWithConnection:connection connector:connector favorite:favorite];
	[host postgresReplaceConnectionTabWithDocument:document];
	[document release];
}

@end
