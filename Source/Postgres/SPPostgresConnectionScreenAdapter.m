#import "SPPostgresConnectionScreenAdapter.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresFavoriteNode.h"
#import "SPPostgresFavoritesStore.h"
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
- (void)_checkLoadError;
- (void)_favoritesDidChange:(NSNotification *)notification;
- (SPTreeNode *)_groupForNewFavorite;
- (BOOL)_removeFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error;
- (void)_removeKeychainItemsOfFavorite:(SPPostgresFavorite *)favorite;
- (NSWindow *)_sheetWindow;
- (void)_showError:(NSError *)error;
- (BOOL)_saveFormAsNew:(BOOL)asNew validate:(BOOL)validate error:(NSError **)error;
- (BOOL)_saveFormAsNew:(BOOL)asNew validate:(BOOL)validate inGroup:(SPTreeNode *)group atIndex:(NSUInteger)index error:(NSError **)error;
- (void)_convertNewMySQLFavorite:(id)mysqlItem;
- (void)_storePassword:(NSString *)thePassword sshPassword:(NSString *)theSSHPassword forFavorite:(SPPostgresFavorite *)favorite previous:(SPPostgresFavorite *)previous;
- (void)_rollBackPasswordsOf:(SPPostgresFavorite *)favorite to:(SPPostgresFavorite *)previous password:(NSString *)oldPassword sshPassword:(NSString *)oldSSHPassword;
- (void)_reportFavoritesLoadError;
- (void)_applyPortPlaceholders;
- (void)_collectPortFieldsInView:(NSView *)view;
- (void)_addDatabasesOptionToTabView:(NSView *)tabItemView;
- (void)_applyDatabasesOption;
- (NSError *)_connectionValidationError;
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

	SPPostgresFavorite *loadedFavorite;
	SPPostgresConnector *pendingConnector;

	// Port and Database fields whose value binding the adapter re-made (see -_applyPortPlaceholders and
	// -_applyDatabasesOption); unbound by -invalidate
	NSMutableArray *reboundPortFields;

	// The "Show all databases" checkbox under each tab's Database field (MySQL and PostgreSQL; see -_applyDatabasesOption):
	// per tab, the form container, its checkbox, and the frames as loaded of the views that move to make room
	NSMutableArray *databasesOptionTabs;
	BOOL databasesOptionShown;
	BOOL showAllDatabases;

	// The description of the favorites file error last reported (see -_reportFavoritesLoadError)
	NSString *reportedLoadError;

	// YES during the adapter's own store writes (see -_favoritesDidChange:)
	BOOL writingToStore;
	// YES while the host reloads the outline for a store change made by this adapter (see -loadFavoriteIntoForm:)
	BOOL handlingStoreChange;
}

@synthesize keychain;

- (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller store:(SPPostgresFavoritesStore *)theStore
{
	if ((self = [super init])) {
		host = controller;
		store = [theStore retain];
		keychain = [[SPKeychain alloc] init];
		engine = SPConnectionEngineMySQL;
		portFields = [[NSMutableArray alloc] init];
		originalPortPlaceholders = [[NSMutableArray alloc] init];
		hostLabels = [[NSMutableArray alloc] init];
		originalHostLabelFrames = [[NSMutableArray alloc] init];
		originalHostLabelFonts = [[NSMutableArray alloc] init];
		reboundPortFields = [[NSMutableArray alloc] init];
		showAllDatabases = YES;

		[self _checkLoadError];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_favoritesDidChange:) name:SPPostgresFavoritesDidChangeNotification object:store];
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
	[databasesOptionTabs release];
	[reportedLoadError release];
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
			[self _addDatabasesOptionToTabView:[item view]];
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
	[self _applyDatabasesOption];

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
		// Its row may have moved (-_applyDatabasesOption): only its width and font are this method's
		frame.origin.y = NSMinY([label frame]);
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
	[self _applyDatabasesOption];
}

#pragma mark - Show all databases

/// Height of the row the checkbox takes, under the Database field.
static const CGFloat SPPostgresDatabasesOptionRowHeight = 26;

/**
 * Adds the (hidden) "Show all databases" checkbox to the form container of tabItemView: the subview holding a field
 * bound to "database". Notes which views move when it is shown (-_applyDatabasesOption): the container, its Database
 * row and the rows above it, and the container's siblings below it (the SSL details).
 */
- (void)_addDatabasesOptionToTabView:(NSView *)tabItemView
{
	NSView *container = nil;
	NSView *databaseField = nil;
	for (NSView *candidate in [tabItemView subviews]) {
		for (NSView *view in [candidate subviews]) {
			if (![view isKindOfClass:[NSTextField class]]) continue;
			if ([[[view infoForBinding:NSValueBinding] objectForKey:NSObservedKeyPathKey] isEqualToString:@"database"]) {
				container = candidate;
				databaseField = view;
				break;
			}
		}
		if (container) break;
	}
	if (!container) return;

	NSMutableArray *above = [NSMutableArray array];
	for (NSView *view in [container subviews]) {
		if (NSMinY([view frame]) >= NSMinY([databaseField frame]) - 4) [above addObject:view];
	}
	NSMutableArray *below = [NSMutableArray array];
	for (NSView *sibling in [tabItemView subviews]) {
		if (sibling != container && NSMaxY([sibling frame]) <= NSMinY([container frame]) + 1) [below addObject:sibling];
	}

	NSButton *checkbox = [NSButton checkboxWithTitle:NSLocalizedString(@"Show all databases", @"PostgreSQL connection: show all databases checkbox")
											  target:self action:@selector(showAllDatabasesChanged:)];
	[checkbox setToolTip:NSLocalizedString(@"On: the database selector lists every database you can use. Off: only this connection's database (enter it in Database).", @"connection: show all databases tooltip")];
	NSRect fieldFrame = [databaseField frame];
	[checkbox setFrame:NSMakeRect(NSMinX(fieldFrame) - 2, NSMinY(fieldFrame) - 2, NSWidth(fieldFrame) + 4, 18)];
	[checkbox setHidden:YES];
	[container addSubview:checkbox];

	if (!databasesOptionTabs) databasesOptionTabs = [[NSMutableArray alloc] init];
	NSString *placeholder = [[(NSTextField *)databaseField cell] placeholderString];
	NSDictionary *options = [[databaseField infoForBinding:NSValueBinding] objectForKey:NSOptionsKey];
	[databasesOptionTabs addObject:@{@"container": container, @"checkbox": checkbox, @"above": above, @"below": below,
	                                 @"databaseField": databaseField, @"placeholder": (placeholder ? placeholder : @""),
	                                 @"options": (options ? options : @{})}];
}

/// Each form (MySQL and PostgreSQL) shows the checkbox in a row under its Database field (the Database row and those
/// above it move up, the form grows at the bottom, its top staying), once. Views move by the row's height from where
/// they are (the host may have resized the forms since). The host then sizes the tabs again.
- (void)_applyDatabasesOption
{
	for (NSDictionary *tab in databasesOptionTabs) {
		[[tab objectForKey:@"checkbox"] setState:showAllDatabases ? NSControlStateValueOn : NSControlStateValueOff];
		// Off: the Database field must be filled (-databaseOptionValidationError). The placeholder is in the cell (empty
		// value) and in the value binding (nil value, NSNullPlaceholder): both switch, as for the port fields
		NSTextField *field = [tab objectForKey:@"databaseField"];
		NSString *placeholder = showAllDatabases ? [tab objectForKey:@"placeholder"] : NSLocalizedString(@"required", @"connection: database placeholder when not showing all databases");
		NSMutableDictionary *options = [[[tab objectForKey:@"options"] mutableCopy] autorelease];
		NSDictionary *binding = [field infoForBinding:NSValueBinding];
		id observed = [binding objectForKey:NSObservedObjectKey];
		NSString *keyPath = [binding objectForKey:NSObservedKeyPathKey];
		if ([options objectForKey:NSNullPlaceholderBindingOption] && !showAllDatabases) [options setObject:placeholder forKey:NSNullPlaceholderBindingOption];
		NSString *current = [[binding objectForKey:NSOptionsKey] objectForKey:NSNullPlaceholderBindingOption];
		NSString *wanted = [options objectForKey:NSNullPlaceholderBindingOption];
		if (observed && keyPath && wanted && ![current isEqual:wanted]) {
			[observed retain];
			[field unbind:NSValueBinding];
			[field bind:NSValueBinding toObject:observed withKeyPath:keyPath options:options];
			[observed release];
			if (![reboundPortFields containsObject:field]) [reboundPortFields addObject:field];
		}
		[[field cell] setPlaceholderString:placeholder];
		[field setNeedsDisplay:YES];
	}

	BOOL shown = YES;
	if (shown == databasesOptionShown) return;
	databasesOptionShown = shown;

	CGFloat delta = shown ? SPPostgresDatabasesOptionRowHeight : -SPPostgresDatabasesOptionRowHeight;
	for (NSDictionary *tab in databasesOptionTabs) {
		NSView *container = [tab objectForKey:@"container"];
		NSButton *checkbox = [tab objectForKey:@"checkbox"];

		// The rows are placed here, not by autoresizing
		BOOL autoresizes = [container autoresizesSubviews];
		[container setAutoresizesSubviews:NO];
		NSRect frame = [container frame];
		frame.origin.y -= delta;
		frame.size.height += delta;
		[container setFrame:frame];
		[container setAutoresizesSubviews:autoresizes];

		for (NSView *view in [tab objectForKey:@"above"]) [view setFrameOrigin:NSMakePoint(NSMinX([view frame]), NSMinY([view frame]) + delta)];
		for (NSView *view in [tab objectForKey:@"below"]) [view setFrameOrigin:NSMakePoint(NSMinX([view frame]), NSMinY([view frame]) - delta)];
		[checkbox setHidden:!shown];
		[container setNeedsDisplay:YES];
	}

	if ([databasesOptionTabs count] && [host respondsToSelector:@selector(resizeTabViewToConnectionType:animating:)]) {
		[host resizeTabViewToConnectionType:(NSUInteger)[host type] animating:NO];
	}
}

- (BOOL)showAllDatabases
{
	return showAllDatabases;
}

- (void)setShowAllDatabases:(BOOL)show
{
	showAllDatabases = show;
	[self _applyDatabasesOption];
}

- (IBAction)showAllDatabasesChanged:(id)sender
{
	[self setShowAllDatabases:([sender state] == NSControlStateValueOn)];
	// An edit of the form, like typing in a field: the host shows Save Changes, Add to Favorites and Test Connection
	if ([host respondsToSelector:@selector(postgresFormDidChange)]) [host postgresFormDidChange];
}

- (NSError *)databaseOptionValidationError
{
	if (showAllDatabases) return nil;
	if ([[[host database] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]) return nil;
	return [NSError errorWithDomain:SPPostgresErrorDomain
	                           code:SPPostgresErrorInvalidSettings
	                       userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Insufficient connection details", @"insufficient details message"),
	                                   NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Please enter a database, or turn on Show all databases.", @"connection: database required when not showing all databases") }];
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

	id selectedItem = [host respondsToSelector:@selector(postgresSelectedOutlineItem)] ? [host postgresSelectedOutlineItem] : nil;

	// The MySQL favorite just added with "+" becomes a PostgreSQL favorite: it stays selected for editing
	if (newEngine == SPConnectionEnginePostgreSQL && selectedItem
		&& [host respondsToSelector:@selector(postgresItemIsNewMySQLFavorite:)] && [host postgresItemIsNewMySQLFavorite:selectedItem]
		&& [host respondsToSelector:@selector(postgresRemoveMySQLFavorite:)]) {
		[self _convertNewMySQLFavorite:selectedItem];
		return;
	}

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

/**
 * Replaces `mysqlItem` (the MySQL favorite just added with "+") by a PostgreSQL favorite with the form's
 * details, in its place (same group, same position), and selects it. The details aren't validated: the favorite
 * is still being filled in. If the Postgres favorite can't be saved, the MySQL one is kept and the engine stays MySQL.
 */
- (void)_convertNewMySQLFavorite:(id)mysqlItem
{
	// MySQL's default port (or none) means "the default": PostgreSQL's then applies
	NSString *port = [[host port] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![port length] || [port isEqualToString:SPPostgresScreenMySQLDefaultPort]) [host setPort:nil];

	[self setSelectedEngine:SPConnectionEnginePostgreSQL];
	[loadedFavorite release], loadedFavorite = nil;

	SPTreeNode *group = nil;
	NSUInteger index = NSNotFound;
	if ([mysqlItem isKindOfClass:[NSTreeNode class]] && [(NSTreeNode *)mysqlItem parentNode]) {
		group = (SPTreeNode *)[(NSTreeNode *)mysqlItem parentNode];
		index = [[group childNodes] indexOfObjectIdenticalTo:mysqlItem];
	}

	NSError *error = nil;
	if (![self _saveFormAsNew:YES validate:NO inGroup:group atIndex:index error:&error]) {
		[self setSelectedEngine:SPConnectionEngineMySQL];
		if (error) [self _showError:error];
		return;
	}

	id node = [self nodeForFavoriteID:[loadedFavorite favoriteID]];
	[host postgresRemoveMySQLFavorite:mysqlItem];
	if (node && [host respondsToSelector:@selector(postgresSelectOutlineItem:)]) [host postgresSelectOutlineItem:node];
}

#pragma mark - Outline

/// An error importing the Postgres favorites of the RC builds is reported from a later run loop turn: the host may
/// still be setting up its window (the adapter is made while the connection screen loads).
- (void)_checkLoadError
{
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
	[self _checkLoadError];

	if (loadedFavorite && ![self nodeForFavoriteID:[loadedFavorite favoriteID]]) {
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

- (SPTreeNode *)_addToStore:(SPPostgresFavorite *)favorite group:(SPTreeNode *)group index:(NSUInteger)index error:(NSError **)error
{
	BOOL wasWriting = writingToStore;
	writingToStore = YES;
	SPTreeNode *node = [store addFavorite:favorite toGroup:group atIndex:index error:error];
	writingToStore = wasWriting;
	return node;
}

- (BOOL)_removeFromStoreFavoriteWithID:(NSString *)favoriteID error:(NSError **)error
{
	BOOL wasWriting = writingToStore;
	writingToStore = YES;
	BOOL removed = [store removeFavoriteWithID:favoriteID error:error];
	writingToStore = wasWriting;
	return removed;
}

/// Where a new favorite goes: the host's group for new favorites (a MySQL group or the section).
- (SPTreeNode *)_groupForNewFavorite
{
	SPTreeNode *group = [host respondsToSelector:@selector(postgresGroupForNewFavorite)] ? [host postgresGroupForNewFavorite] : nil;
	return (group && [group isGroup] && ![self isPostgresNode:group]) ? group : [store section];
}

- (BOOL)hasPostgresFavorites
{
	return [[store favoriteNodes] count] > 0;
}

- (void)removeKeychainItemsOfPostgresFavoritesWithinNode:(id)node
{
	SPPostgresFavorite *favorite = [self favoriteForNode:node];
	if (favorite) {
		[self _removeKeychainItemsOfFavorite:favorite];
		return;
	}
	if (![node isKindOfClass:[NSTreeNode class]]) return;
	for (id child in [(NSTreeNode *)node childNodes]) [self removeKeychainItemsOfPostgresFavoritesWithinNode:child];
}

- (void)_removeKeychainItemsOfFavorite:(SPPostgresFavorite *)favorite
{
	[keychain deletePasswordForName:[favorite keychainName] account:[favorite keychainAccount]];
	[keychain deletePasswordForName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
}

/// Removes `favorite` from the tree, then its keychain items.
- (BOOL)_removeFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error
{
	if (![self _removeFromStoreFavoriteWithID:[favorite favoriteID] error:error]) return NO;
	[self _removeKeychainItemsOfFavorite:favorite];
	return YES;
}

- (BOOL)isPostgresNode:(id)outlineItem
{
	return [self favoriteForNode:outlineItem] != nil;
}

- (SPPostgresFavorite *)favoriteForNode:(id)outlineItem
{
	return SPPostgresFavoriteForNode(outlineItem);
}

- (id)nodeForFavoriteID:(NSString *)favoriteID
{
	return [store nodeForFavoriteID:favoriteID];
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
	// Quick Connect: every database (a MySQL favorite's own setting is set by the host after this)
	[self setShowAllDatabases:YES];
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
	[self setShowAllDatabases:[favorite showAllDatabases]];
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
	[favorite setShowAllDatabases:showAllDatabases];
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

	if (!message) return [self databaseOptionValidationError];

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
	return [self _saveFormAsNew:NO validate:YES error:error];
}

- (BOOL)saveFormAsNewFavorite:(NSError **)error
{
	return [self _saveFormAsNew:YES validate:YES error:error];
}

- (BOOL)_saveFormAsNew:(BOOL)asNew validate:(BOOL)validate error:(NSError **)error
{
	return [self _saveFormAsNew:asNew validate:validate inGroup:nil atIndex:NSNotFound error:error];
}

/// A new favorite goes into `group` at `index`; with no group, at the end of the group for new favorites.
- (BOOL)_saveFormAsNew:(BOOL)asNew validate:(BOOL)validate inGroup:(SPTreeNode *)group atIndex:(NSUInteger)index error:(NSError **)error
{
	NSError *validationError = validate ? [self validationErrorForForm] : nil;
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

	BOOL saved = previous ? [self _saveToStore:favorite error:error]
	                      : ([self _addToStore:favorite group:(group ? group : [self _groupForNewFavorite]) index:(group ? index : NSNotFound) error:error] != nil);
	if (!saved) {
		[self _rollBackPasswordsOf:favorite to:previous password:oldPassword sshPassword:oldSSHPassword];
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
	if ([self _saveFormAsNew:asNew validate:YES error:&error]) return YES;
	if (error) [self _showError:error];
	return NO;
}

- (id)addNewFavorite
{
	SPPostgresFavorite *favorite = [[[SPPostgresFavorite alloc] init] autorelease];
	[favorite setName:NSLocalizedString(@"New Favorite", @"new favorite name")];

	NSError *error = nil;
	SPTreeNode *node = [self _addToStore:favorite group:[self _groupForNewFavorite] index:NSNotFound error:&error];
	if (!node && error) [self _showError:error];
	return node;
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

	// Keychain first (see -_saveFormAsNew:validate:error:)
	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:duplicate previous:nil];

	// Right after the original, in its group
	SPTreeNode *group = (SPTreeNode *)[(NSTreeNode *)outlineItem parentNode];
	NSUInteger index = group ? [[group childNodes] indexOfObjectIdenticalTo:outlineItem] : NSNotFound;

	NSError *error = nil;
	SPTreeNode *node = [self _addToStore:duplicate group:group index:(index == NSNotFound ? NSNotFound : index + 1) error:&error];
	if (!node) {
		[self _rollBackPasswordsOf:duplicate to:nil password:nil sshPassword:nil];
		if (error) [self _showError:error];
		return nil;
	}

	return node;
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

	// Keychain first (see -_saveFormAsNew:validate:error:)
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
