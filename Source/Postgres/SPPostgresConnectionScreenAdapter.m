#import "SPPostgresConnectionScreenAdapter.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresFavoritesStore.h"
#import "SPPostgresConnector.h"
#import "SPPostgresWindowController.h"
#import "SPPostgresErrors.h"
#import "SPKeychain.h"
#import "SPTreeNode.h"
#import "SPGroupNode.h"
#import "SPNamedNode.h"
#import "SPFavoriteColorSupport.h"
#import "SPAlertSheets.h"

static const NSUInteger SPPostgresScreenDefaultPort = 5432;

@interface SPKeychain (SPPostgresKeychainAccess) <SPPostgresKeychainAccess>
@end

@implementation SPKeychain (SPPostgresKeychainAccess)
@end

/**
 * Represented object of a Postgres favorite's outline node. -nodeFavorite returns nil so that any MySQL
 * code reading a favorite dictionary from the selected node sees "no MySQL favorite" rather than crashing.
 */
@interface SPPostgresFavoriteNode : NSObject <SPNamedNode>
{
	SPPostgresFavorite *favorite;
}
@property (nonatomic, retain) SPPostgresFavorite *favorite;
@end

@implementation SPPostgresFavoriteNode
@synthesize favorite;
- (NSString *)nodeName { return [favorite name]; }
- (NSMutableDictionary *)nodeFavorite { return nil; }
- (void)dealloc { [favorite release]; [super dealloc]; }
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
- (NSWindow *)_sheetWindow;
- (void)_showError:(NSError *)error;
- (BOOL)_saveFormAsNew:(BOOL)asNew error:(NSError **)error;
- (void)_storePassword:(NSString *)thePassword sshPassword:(NSString *)theSSHPassword forFavorite:(SPPostgresFavorite *)favorite previous:(SPPostgresFavorite *)previous;
- (void)_applyPortPlaceholders;
- (void)_collectPortFieldsInView:(NSView *)view;
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

	SPTreeNode *rootNode;
	SPTreeNode *sectionNode;
	NSMutableDictionary *nodesByID;

	SPPostgresFavorite *loadedFavorite;
	SPPostgresConnector *pendingConnector;
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
		nodesByID = [[NSMutableDictionary alloc] init];

		// An invisible root, so the section is a top-level row and its favorites are not
		// (the outline's group-row checks look at the grandparent, as for the MySQL tree)
		rootNode = [[SPTreeNode treeNodeWithRepresentedObject:[SPGroupNode groupNodeWithName:@""]] retain];
		[rootNode setIsGroup:YES];
		SPGroupNode *section = [SPGroupNode groupNodeWithName:NSLocalizedString(@"POSTGRESQL", @"PostgreSQL favorites section in the favorites list")];
		[section setNodeIsExpanded:YES];
		sectionNode = [[SPTreeNode treeNodeWithRepresentedObject:section] retain];
		[sectionNode setIsGroup:YES];
		[[rootNode mutableChildNodes] addObject:sectionNode];

		[self _rebuildNodes];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_favoritesDidChange:) name:SPPostgresFavoritesDidChangeNotification object:store];
	}
	return self;
}

- (void)invalidate
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[engineControl setTarget:nil];
	host = nil;

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
	[rootNode release];
	[sectionNode release];
	[nodesByID release];
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
		}

		[[field cell] setPlaceholderString:placeholder];
		[field setNeedsDisplay:YES];
	}];
}

- (SPConnectionEngine)selectedEngine
{
	return engine;
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

	[[sectionNode mutableChildNodes] setArray:nodes];
	[nodesByID setDictionary:newNodesByID];
}

- (void)_favoritesDidChange:(NSNotification *)notification
{
	[self _rebuildNodes];

	if (loadedFavorite && ![nodesByID objectForKey:[loadedFavorite favoriteID]]) {
		[loadedFavorite release];
		loadedFavorite = nil;
	}

	if ([host respondsToSelector:@selector(postgresFavoritesDidChange)]) {
		[host postgresFavoritesDidChange];
	}
}

- (id)sectionNode
{
	return [[sectionNode childNodes] count] ? sectionNode : nil;
}

- (NSArray *)favoriteNodesForOutline
{
	return [sectionNode childNodes];
}

- (BOOL)isPostgresNode:(id)outlineItem
{
	if (!outlineItem) return NO;
	if (outlineItem == sectionNode || outlineItem == rootNode) return YES;
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

	if (![store saveFavorite:favorite error:error]) return NO;

	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:favorite previous:previous];

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

	NSError *error = nil;
	if (![store saveFavorite:favorite error:&error]) {
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
		if (![store removeFavoriteWithID:[favorite favoriteID] error:&error]) {
			if (error) [self _showError:error];
			return;
		}
		[keychain deletePasswordForName:[favorite keychainName] account:[favorite keychainAccount]];
		[keychain deletePasswordForName:[favorite sshKeychainName] account:[favorite sshKeychainAccount]];
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

	NSError *error = nil;
	if (![store saveFavorite:duplicate error:&error]) {
		if (error) [self _showError:error];
		return nil;
	}
	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:duplicate previous:nil];

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

	NSError *error = nil;
	if (![store saveFavorite:renamed error:&error]) {
		if (error) [self _showError:error];
		return;
	}
	[self _storePassword:thePassword sshPassword:theSSHPassword forFavorite:renamed previous:original];

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

	// The window takes over the connector and keeps itself alive while open
	SPPostgresWindowController *windowController = [[SPPostgresWindowController alloc] initWithConnection:connection connector:connector favorite:favorite];
	[windowController showWindow:nil];
	[windowController release];
}

@end
