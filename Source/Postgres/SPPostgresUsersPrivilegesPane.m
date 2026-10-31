#import "SPPostgresUsersPrivilegesPane.h"
#import "SPPostgresPrivileges.h"
#import "SPPostgresRoles.h"
#import "SPPostgresTableData.h"
#import <PostgresKit/PostgresKit.h>

static NSString * const SPPostgresPrivilegesObjectColumn = @"object";
static NSString * const SPPostgresPrivilegesDatabaseKind = @"database";

/// The grid's privilege columns, in order.
static NSArray *SPPostgresPrivilegesColumns(void)
{
	return @[@"SELECT", @"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE", @"REFERENCES", @"TRIGGER", @"USAGE", @"CREATE", @"CONNECT", @"TEMP", @"EXECUTE"];
}

static BOOL SPPostgresPrivilegesIsDefaultKind(NSString *kind)
{
	return [kind hasPrefix:@"default "];
}

static BOOL SPPostgresPrivilegesSame(NSString *a, NSString *b)
{
	return a == b || (a && b && [a isEqualToString:b]);
}

/// Column 0 of every row of a query selecting text, or nil (error set) on failure.
static NSArray *SPPostgresPrivilegesNames(PGPostgresConnection *connection, NSString *sql, NSError **error)
{
	PGPostgresResult *result = SPPostgresExecuteWithDetails(connection, sql, nil, error);
	if (!result) return nil;
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:(NSUInteger)[result numberOfRows]];
	for (unsigned long long row = 0; row < [result numberOfRows]; row++) {
		id value = [result textValueAtRow:row column:0];
		if ([value isKindOfClass:[NSString class]]) [names addObject:value];
	}
	return names;
}

/**
 * One pending edit: role's privileges on one object of database, as read (original) and as edited. creator is the
 * role the default-privilege rows were read for (nil for other rows).
 */
@interface SPPostgresUsersPendingPrivilege : NSObject
{
@public
	NSString *role;
	NSString *database;
	NSString *creator;
	SPPostgresPrivilegeObject *original;
	SPPostgresPrivilegeObject *edited;
}
@end

@implementation SPPostgresUsersPendingPrivilege

- (void)dealloc
{
	[role release];
	[database release];
	[creator release];
	[original release];
	[edited release];
	[super dealloc];
}

- (BOOL)isDatabaseRow
{
	return [[original kind] isEqualToString:SPPostgresPrivilegesDatabaseKind];
}

- (NSArray *)statements
{
	return [SPPostgresPrivileges statementsForRole:role original:@[original] edited:@[edited] defaultsCreator:creator];
}

@end

@implementation SPPostgresUsersPrivilegesPane
{
	id<SPPostgresUsersPrivilegesPaneDelegate> delegate; // not retained

	NSView *view;
	NSPopUpButton *databasePopup;
	NSPopUpButton *schemaPopup;
	NSPopUpButton *creatorPopup;
	NSProgressIndicator *progressIndicator;
	NSTableView *privilegesTable;
	NSTextField *superuserNote;
	NSButtonCell *checkCell;
	NSTextFieldCell *emptyCell;

	/// The shown database (and the connection its rows are read through), schema and creator
	PGPostgresConnection *connection;
	NSString *databaseName;
	NSString *schemaName;
	NSString *creatorName;
	BOOL connecting;

	SPPostgresRole *role;
	/// As read, and as shown (pending edits in place)
	NSArray *readRows;
	NSArray *rowsShown;

	NSMutableArray *pending;
	/// Creators (as the pop-up lists them: server names) renamed in the draft, to their draft names
	NSMutableDictionary *creatorDraftNames;
}

@synthesize databasePopup, schemaPopup, creatorPopup, privilegesTable, superuserNote, progressIndicator, rowsShown;

- (instancetype)initWithDelegate:(id<SPPostgresUsersPrivilegesPaneDelegate>)theDelegate
{
	if ((self = [super init])) {
		delegate = theDelegate;
		readRows = [@[] retain];
		rowsShown = [@[] retain];
		pending = [[NSMutableArray alloc] init];
		creatorDraftNames = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[privilegesTable setDelegate:nil];
	[privilegesTable setDataSource:nil];
	[view release];
	[databasePopup release];
	[schemaPopup release];
	[creatorPopup release];
	[progressIndicator release];
	[privilegesTable release];
	[superuserNote release];
	[checkCell release];
	[emptyCell release];
	[connection release];
	[databaseName release];
	[schemaName release];
	[creatorName release];
	[role release];
	[readRows release];
	[rowsShown release];
	[pending release];
	[creatorDraftNames release];
	[super dealloc];
}

#pragma mark - Building

- (NSTextField *)_label:(NSString *)text frame:(NSRect)frame
{
	NSTextField *label = [NSTextField labelWithString:text];
	[label setFrame:frame];
	[label setAlignment:NSTextAlignmentRight];
	[label setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	return label;
}

- (NSPopUpButton *)_popupWithFrame:(NSRect)frame identifier:(NSString *)identifier action:(SEL)action
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
	[popup setIdentifier:identifier];
	[popup setTarget:self];
	[popup setAction:action];
	[popup setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	return popup;
}

- (NSView *)viewWithFrame:(NSRect)frame
{
	if (view) return view;
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	CGFloat width = NSWidth(frame), height = NSHeight(frame);

	CGFloat y = height - 12 - 26;
	[view addSubview:[self _label:NSLocalizedString(@"Database:", @"Postgres users: privileges database label") frame:NSMakeRect(4, y + 5, 66, 17)]];
	databasePopup = [self _popupWithFrame:NSMakeRect(72, y, 160, 26) identifier:@"usersPrivilegesDatabase" action:@selector(_databaseChosen:)];
	[view addSubview:databasePopup];
	[view addSubview:[self _label:NSLocalizedString(@"Schema:", @"Postgres users: privileges schema label") frame:NSMakeRect(236, y + 5, 56, 17)]];
	schemaPopup = [self _popupWithFrame:NSMakeRect(294, y, 160, 26) identifier:@"usersPrivilegesSchema" action:@selector(_schemaChosen:)];
	[view addSubview:schemaPopup];
	progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(460, y + 5, 16, 16)];
	[progressIndicator setStyle:NSProgressIndicatorStyleSpinning];
	[progressIndicator setControlSize:NSControlSizeSmall];
	[progressIndicator setDisplayedWhenStopped:NO];
	[progressIndicator setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	[view addSubview:progressIndicator];

	y -= 30;
	NSTextField *creatorLabel = [self _label:NSLocalizedString(@"Default privileges for objects created by:", @"Postgres users: privileges default creator label") frame:NSMakeRect(4, y + 5, 266, 17)];
	[view addSubview:creatorLabel];
	creatorPopup = [self _popupWithFrame:NSMakeRect(272, y, 182, 26) identifier:@"usersPrivilegesCreator" action:@selector(_creatorChosen:)];
	[creatorPopup setToolTip:NSLocalizedString(@"The rows “… created later” apply to objects this role creates in the schema", @"Postgres users: privileges creator tooltip")];
	[view addSubview:creatorPopup];

	// The note under the grid, for a superuser
	superuserNote = [[NSTextField labelWithString:NSLocalizedString(@"Superusers bypass all privilege checks.", @"Postgres users: superuser privileges note")] retain];
	[superuserNote setIdentifier:@"usersSuperuserNote"];
	[superuserNote setTextColor:[NSColor secondaryLabelColor]];
	[superuserNote setFrame:NSMakeRect(8, 6, width - 16, 17)];
	[superuserNote setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[superuserNote setHidden:YES];
	[view addSubview:superuserNote];

	NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(8, 28, width - 16, y - 8 - 28)] autorelease];
	[scroll setHasVerticalScroller:YES];
	[scroll setHasHorizontalScroller:YES];
	[scroll setAutohidesScrollers:YES];
	[scroll setBorderType:NSBezelBorder];
	[scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	privilegesTable = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
	[privilegesTable setIdentifier:@"usersPrivileges"];
	[privilegesTable setRowHeight:18];
	[privilegesTable setUsesAlternatingRowBackgroundColors:YES];
	[privilegesTable setFocusRingType:NSFocusRingTypeNone];
	[privilegesTable setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];
	[privilegesTable setAllowsColumnReordering:NO];

	NSTableColumn *object = [[[NSTableColumn alloc] initWithIdentifier:SPPostgresPrivilegesObjectColumn] autorelease];
	[[object headerCell] setStringValue:NSLocalizedString(@"Object", @"Postgres users: privileges object column")];
	[object setEditable:NO];
	[object setWidth:200];
	[object setMinWidth:100];
	[[object dataCell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[privilegesTable addTableColumn:object];

	checkCell = [[NSButtonCell alloc] initTextCell:@""];
	[checkCell setButtonType:NSButtonTypeSwitch];
	[checkCell setImagePosition:NSImageOnly];
	[checkCell setControlSize:NSControlSizeSmall];
	emptyCell = [[NSTextFieldCell alloc] initTextCell:@""];
	[emptyCell setEditable:NO];

	for (NSString *privilege in SPPostgresPrivilegesColumns()) {
		NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:privilege] autorelease];
		[[column headerCell] setStringValue:privilege];
		[[column headerCell] setAlignment:NSTextAlignmentCenter];
		[column setDataCell:checkCell];
		CGFloat columnWidth = MAX(34, ceil([[column headerCell] cellSize].width) + 10);
		[column setWidth:columnWidth];
		[column setMinWidth:34];
		[privilegesTable addTableColumn:column];
	}
	[privilegesTable setDataSource:self];
	[privilegesTable setDelegate:self];
	[scroll setDocumentView:privilegesTable];
	[view addSubview:scroll];

	[self _updateControls];
	return view;
}

- (void)_updateControls
{
	[databasePopup setEnabled:!connecting && [databasePopup numberOfItems] > 0];
	[schemaPopup setEnabled:!connecting && [schemaPopup numberOfItems] > 0];
	[creatorPopup setEnabled:!connecting && [creatorPopup numberOfItems] > 0];
	if (connecting) [progressIndicator startAnimation:nil];
	else [progressIndicator stopAnimation:nil];
	[superuserNote setHidden:![role superuser]];
}

static void SPPostgresPrivilegesFill(NSPopUpButton *popup, NSArray *titles, NSString *selected)
{
	[popup removeAllItems];
	// One by one: addItemsWithTitles: drops duplicates and treats some titles specially
	for (NSString *title in titles) {
		[popup addItemWithTitle:@""];
		[[popup lastItem] setTitle:title];
	}
	if (selected) [popup selectItemWithTitle:selected];
}

#pragma mark - Database, schema, creator

- (BOOL)startWithDatabase:(NSString *)database connection:(PGPostgresConnection *)theConnection error:(NSError **)error
{
	NSArray *databases = SPPostgresPrivilegesNames(theConnection,
		@"SELECT datname::text FROM pg_catalog.pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1", error);
	if (!databases) return NO;
	if (![databases containsObject:database]) databases = [databases arrayByAddingObject:database];
	SPPostgresPrivilegesFill(databasePopup, databases, database);
	return [self _showDatabase:database connection:theConnection error:error];
}

/// Makes database (through theConnection) the shown one: its schemas (public if there is one), the creators.
- (BOOL)_showDatabase:(NSString *)database connection:(PGPostgresConnection *)theConnection error:(NSError **)error
{
	NSArray *schemas = SPPostgresPrivilegesNames(theConnection,
		@"SELECT nspname::text FROM pg_catalog.pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY 1", error);
	if (!schemas) return NO;
	NSArray *creators = SPPostgresPrivilegesNames(theConnection, @"SELECT rolname::text FROM pg_catalog.pg_roles WHERE rolname !~ '^pg_' ORDER BY 1", error);
	if (!creators) return NO;

	[connection release];
	connection = [theConnection retain];
	[databaseName release];
	databaseName = [database copy];
	[databasePopup selectItemWithTitle:database];

	NSString *schema = [schemas containsObject:@"public"] ? @"public" : [schemas firstObject];
	SPPostgresPrivilegesFill(schemaPopup, schemas, schema);
	SPPostgresPrivilegesFill(creatorPopup, creators, nil);
	[self _showSchema:schema];
	return YES;
}

/// Shows schema, with its owner (or, for pg_database_owner, the database's owner) as the creator for the default rows.
- (void)_showSchema:(NSString *)schema
{
	[schemaName release];
	schemaName = [schema copy];

	NSString *owner = nil;
	if (schema) {
		NSError *error = nil;
		owner = [[[[SPPostgresPrivileges alloc] initWithConnection:connection] autorelease] ownerOfSchema:schema error:&error];
		if (!owner) [delegate privilegesPane:self showErrorTitle:NSLocalizedString(@"Could not read the privileges", @"Postgres users: privileges read failed title") message:[error localizedDescription] ?: @""];
	}
	// The owner may be a predefined role (pg_database_owner owns public on PostgreSQL 15+): listed, but nobody
	// creates objects as pg_database_owner, so default privileges for it never apply. The database's owner (whom
	// it stands for) is the creator offered first then.
	if (owner && ![creatorPopup itemWithTitle:owner]) {
		[creatorPopup addItemWithTitle:@""];
		[[creatorPopup lastItem] setTitle:owner];
	}
	NSString *creator = owner;
	if ([owner isEqualToString:@"pg_database_owner"]) {
		NSError *error = nil;
		NSArray *databaseOwner = SPPostgresPrivilegesNames(connection,
			@"SELECT pg_catalog.pg_get_userbyid(datdba)::text FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database()", &error);
		NSString *name = [databaseOwner firstObject];
		if ([name length]) {
			if (![creatorPopup itemWithTitle:name]) {
				[creatorPopup addItemWithTitle:@""];
				[[creatorPopup lastItem] setTitle:name];
			}
			creator = name;
		}
		else if (!databaseOwner) {
			NSLog(@"Postgres users: could not read the database's owner: %@", [error localizedDescription]);
		}
	}
	[self _setCreator:creator ?: [creatorPopup titleOfSelectedItem]];
	[self _reloadRows];
}

- (void)_setCreator:(NSString *)creator
{
	if (creator) [creatorPopup selectItemWithTitle:creator];
	[creatorName release];
	creatorName = [[creatorPopup titleOfSelectedItem] copy];
	if (![creatorName length]) {
		[creatorName release];
		creatorName = nil;
	}
}

- (void)_databaseChosen:(id)sender
{
	NSString *chosen = [[[databasePopup titleOfSelectedItem] copy] autorelease];
	if (connecting || !chosen || SPPostgresPrivilegesSame(chosen, databaseName)) return;

	connecting = YES;
	[self _updateControls];
	[[self retain] autorelease];
	[delegate privilegesPane:self connectionForDatabase:chosen completion:^(PGPostgresConnection *theConnection, NSError *error) {
		connecting = NO;
		NSError *readError = error;
		if (!theConnection || ![self _showDatabase:chosen connection:theConnection error:&readError]) {
			[databasePopup selectItemWithTitle:databaseName];
			[self _updateControls];
			[delegate privilegesPane:self showErrorTitle:[NSString stringWithFormat:NSLocalizedString(@"Could not open database “%@”", @"Postgres users: connection failed title"), chosen]
							 message:[readError localizedDescription] ?: NSLocalizedString(@"The connection failed.", @"Postgres users: connection failed, no reason")];
			return;
		}
		[self _updateControls];
	}];
}

- (void)_schemaChosen:(id)sender
{
	NSString *chosen = [schemaPopup titleOfSelectedItem];
	if (connecting || SPPostgresPrivilegesSame(chosen, schemaName)) return;
	[self _showSchema:chosen];
}

- (void)_creatorChosen:(id)sender
{
	if (connecting || SPPostgresPrivilegesSame([creatorPopup titleOfSelectedItem], creatorName)) return;
	[self _setCreator:nil];
	[self _reloadRows];
}

- (void)reload
{
	if (!connection || !databaseName) return;
	// The roles were re-read: renamed creators now have their new names on the server (and in the pop-up)
	[creatorDraftNames removeAllObjects];
	NSString *schema = [[schemaName copy] autorelease];
	NSString *creator = [[creatorName copy] autorelease];
	NSError *error = nil;
	if (![self _showDatabase:databaseName connection:connection error:&error]) {
		[delegate privilegesPane:self showErrorTitle:NSLocalizedString(@"Could not read the privileges", @"Postgres users: privileges read failed title") message:[error localizedDescription] ?: @""];
		return;
	}
	// Back to the schema and creator shown before, when they are still there
	if (schema && ![schema isEqualToString:schemaName] && [schemaPopup itemWithTitle:schema]) {
		[schemaPopup selectItemWithTitle:schema];
		[self _showSchema:schema];
	}
	if (creator && ![creator isEqualToString:creatorName] && [creatorPopup itemWithTitle:creator]) {
		[self _setCreator:creator];
		[self _reloadRows];
	}
}

#pragma mark - The role and its rows

- (void)showRole:(SPPostgresRole *)theRole
{
	if (theRole != role) {
		[role release];
		role = [theRole retain];
	}
	[self _updateControls];
	[self _reloadRows];
}

- (void)roleAttributesChanged
{
	[self _updateControls];
	[privilegesTable reloadData];
}

- (BOOL)_editable
{
	return role && ![role markedForDeletion] && !connecting && connection != nil;
}

/// Reads the shown role's rows in the shown database and schema.
- (void)_reloadRows
{
	NSArray *rows = @[];
	if (role && connection && databaseName) {
		SPPostgresPrivileges *reader = [[[SPPostgresPrivileges alloc] initWithConnection:connection] autorelease];
		NSString *serverName = [role originalName] ?: [role name];
		NSError *error = nil;
		NSArray *databaseRows = [reader databasePrivilegesForRole:serverName database:databaseName error:&error];
		NSArray *schemaRows = (databaseRows && schemaName) ? [reader privilegesForRole:serverName schema:schemaName defaultsCreator:creatorName error:&error] : @[];
		if (databaseRows && schemaRows) {
			rows = [databaseRows arrayByAddingObjectsFromArray:schemaRows];
		}
		else {
			[delegate privilegesPane:self showErrorTitle:NSLocalizedString(@"Could not read the privileges", @"Postgres users: privileges read failed title") message:[error localizedDescription] ?: @""];
		}
	}
	[readRows release];
	readRows = [rows copy];
	[self _refreshShownRows];
}

- (void)_refreshShownRows
{
	NSMutableArray *shown = [NSMutableArray arrayWithCapacity:[readRows count]];
	for (SPPostgresPrivilegeObject *object in readRows) {
		SPPostgresUsersPendingPrivilege *entry = [self _pendingFor:object];
		[shown addObject:entry ? entry->edited : object];
	}
	[rowsShown release];
	rowsShown = [shown copy];
	[privilegesTable reloadData];
}

/// The creator an object's pending edit is kept under: the shown creator's draft name for a default row, else nil.
- (NSString *)_creatorFor:(SPPostgresPrivilegeObject *)object
{
	if (!SPPostgresPrivilegesIsDefaultKind([object kind]) || !creatorName) return nil;
	return [creatorDraftNames objectForKey:creatorName] ?: creatorName;
}

- (SPPostgresUsersPendingPrivilege *)_pendingFor:(SPPostgresPrivilegeObject *)object
{
	NSString *roleName = [role name];
	NSString *creator = [self _creatorFor:object];
	for (SPPostgresUsersPendingPrivilege *entry in pending) {
		if (SPPostgresPrivilegesSame(entry->role, roleName) && SPPostgresPrivilegesSame(entry->database, databaseName)
			&& SPPostgresPrivilegesSame(entry->creator, creator) && SPPostgresPrivilegesSame([entry->original kind], [object kind])
			&& SPPostgresPrivilegesSame([entry->original schema], [object schema]) && SPPostgresPrivilegesSame([entry->original name], [object name])) {
			return entry;
		}
	}
	return nil;
}

- (BOOL)_row:(NSInteger)row has:(NSString *)privilege
{
	if (row < 0 || row >= (NSInteger)[rowsShown count]) return NO;
	return [[[rowsShown objectAtIndex:(NSUInteger)row] availablePrivileges] containsObject:privilege];
}

/// Ticks or unticks privilege on the row's object, as a pending edit (dropped when back to what was read).
- (void)_set:(BOOL)value privilege:(NSString *)privilege row:(NSInteger)row
{
	if (![self _editable] || ![self _row:row has:privilege] || row >= (NSInteger)[readRows count]) return;
	[delegate privilegesPaneWillEdit:self];
	if (![self _editable]) return;
	SPPostgresPrivilegeObject *read = [readRows objectAtIndex:(NSUInteger)row];
	NSString *creator = [self _creatorFor:read];
	if (SPPostgresPrivilegesIsDefaultKind([read kind]) && !creator) return; // nobody to set them for

	SPPostgresUsersPendingPrivilege *entry = [self _pendingFor:read];
	if (!entry) {
		entry = [[[SPPostgresUsersPendingPrivilege alloc] init] autorelease];
		entry->role = [[role name] copy];
		entry->database = [databaseName copy];
		entry->creator = [creator copy];
		entry->original = [read copy];
		entry->edited = [read copy];
		[pending addObject:entry];
	}
	NSMutableSet *granted = [[[entry->edited granted] mutableCopy] autorelease];
	if (value) [granted addObject:privilege];
	else [granted removeObject:privilege];
	[entry->edited setGranted:granted];
	if ([[entry->edited granted] isEqualToSet:[entry->original granted]]) [pending removeObject:entry];

	[self _refreshShownRows];
	[delegate privilegesPaneDidChange:self];
}

#pragma mark - Pending edits

- (void)renameRole:(NSString *)from to:(NSString *)to
{
	if (!from || !to) return;
	for (SPPostgresUsersPendingPrivilege *entry in pending) {
		if (SPPostgresPrivilegesSame(entry->role, from)) {
			[entry->role release];
			entry->role = [to copy];
		}
		// Default privileges set for objects the renamed role creates: they are applied after the rename
		if (SPPostgresPrivilegesSame(entry->creator, from)) {
			[entry->creator release];
			entry->creator = [to copy];
		}
	}

	// The pop-up keeps the server name; its edits are kept (and found) under the draft name
	BOOL known = NO;
	for (NSString *serverName in [creatorDraftNames allKeys]) {
		if ([[creatorDraftNames objectForKey:serverName] isEqualToString:from]) {
			[creatorDraftNames setObject:to forKey:serverName];
			known = YES;
		}
	}
	if (!known && ![creatorDraftNames objectForKey:from]) [creatorDraftNames setObject:to forKey:from];
	[self _refreshShownRows];
}

- (void)dropEditsForRole:(NSString *)roleName
{
	NSMutableIndexSet *gone = [NSMutableIndexSet indexSet];
	[pending enumerateObjectsUsingBlock:^(SPPostgresUsersPendingPrivilege *entry, NSUInteger index, BOOL *stop) {
		// Its own edits, and the default privileges for objects it would create
		if (SPPostgresPrivilegesSame(entry->role, roleName) || SPPostgresPrivilegesSame(entry->creator, roleName)) [gone addIndex:index];
	}];
	[pending removeObjectsAtIndexes:gone];
	[self _refreshShownRows];
}

- (BOOL)hasPendingEdits
{
	return [pending count] > 0;
}

- (NSArray *)databaseStatements
{
	NSMutableArray *statements = [NSMutableArray array];
	for (SPPostgresUsersPendingPrivilege *entry in pending) {
		if ([entry isDatabaseRow]) [statements addObjectsFromArray:[entry statements]];
	}
	return statements;
}

- (NSArray *)databasesWithPendingStatements
{
	NSMutableSet *databases = [NSMutableSet set];
	for (SPPostgresUsersPendingPrivilege *entry in pending) {
		if (![entry isDatabaseRow] && entry->database) [databases addObject:entry->database];
	}
	return [[databases allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)statementsForDatabase:(NSString *)database
{
	NSMutableArray *statements = [NSMutableArray array];
	for (SPPostgresUsersPendingPrivilege *entry in pending) {
		if (![entry isDatabaseRow] && SPPostgresPrivilegesSame(entry->database, database)) [statements addObjectsFromArray:[entry statements]];
	}
	return statements;
}

- (void)forgetDatabaseEdits
{
	NSMutableIndexSet *gone = [NSMutableIndexSet indexSet];
	[pending enumerateObjectsUsingBlock:^(SPPostgresUsersPendingPrivilege *entry, NSUInteger index, BOOL *stop) {
		if ([entry isDatabaseRow]) [gone addIndex:index];
	}];
	[pending removeObjectsAtIndexes:gone];
	[self _refreshShownRows];
}

- (void)forgetEditsInDatabase:(NSString *)database
{
	NSMutableIndexSet *gone = [NSMutableIndexSet indexSet];
	[pending enumerateObjectsUsingBlock:^(SPPostgresUsersPendingPrivilege *entry, NSUInteger index, BOOL *stop) {
		if (![entry isDatabaseRow] && SPPostgresPrivilegesSame(entry->database, database)) [gone addIndex:index];
	}];
	[pending removeObjectsAtIndexes:gone];
	[self _refreshShownRows];
}

- (NSArray *)pendingEditsInDatabase:(NSString *)database
{
	NSMutableArray *edits = [NSMutableArray array];
	for (SPPostgresUsersPendingPrivilege *entry in pending) {
		if (SPPostgresPrivilegesSame(entry->database, database)) [edits addObject:[[entry->edited copy] autorelease]];
	}
	return edits;
}

#pragma mark - The grid

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
	return (NSInteger)[rowsShown count];
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[rowsShown count]) return nil;
	SPPostgresPrivilegeObject *object = [rowsShown objectAtIndex:(NSUInteger)row];
	NSString *identifier = [column identifier];
	if ([identifier isEqualToString:SPPostgresPrivilegesObjectColumn]) {
		if (SPPostgresPrivilegesIsDefaultKind([object kind])) return [object name];
		return [NSString stringWithFormat:@"%@ %@", [object kind], [object name]];
	}
	if (![self _row:row has:identifier]) return nil;
	return @([[object granted] containsObject:identifier]);
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	[self _set:[value boolValue] privilege:[column identifier] row:row];
}

- (NSCell *)tableView:(NSTableView *)table dataCellForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	if (!column) return nil;
	if ([[column identifier] isEqualToString:SPPostgresPrivilegesObjectColumn]) return [column dataCell];
	return [self _row:row has:[column identifier]] ? checkCell : emptyCell;
}

- (BOOL)tableView:(NSTableView *)table shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	NSString *identifier = [column identifier];
	if ([identifier isEqualToString:SPPostgresPrivilegesObjectColumn] || ![self _editable] || ![self _row:row has:identifier]) return NO;
	return !(SPPostgresPrivilegesIsDefaultKind([[rowsShown objectAtIndex:(NSUInteger)row] kind]) && !creatorName);
}

- (void)tableView:(NSTableView *)table willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	if (row < 0 || row >= (NSInteger)[rowsShown count]) return;
	SPPostgresPrivilegeObject *object = [rowsShown objectAtIndex:(NSUInteger)row];
	if ([[column identifier] isEqualToString:SPPostgresPrivilegesObjectColumn]) {
		// A pending row is bold; the default-privilege rows are grey
		BOOL isPending = row < (NSInteger)[readRows count] && [self _pendingFor:[readRows objectAtIndex:(NSUInteger)row]] != nil;
		[cell setFont:isPending ? [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize] + 1] : [NSFont systemFontOfSize:[NSFont smallSystemFontSize] + 1]];
		[cell setTextColor:SPPostgresPrivilegesIsDefaultKind([object kind]) ? [NSColor secondaryLabelColor] : [NSColor labelColor]];
		return;
	}
	if (cell == checkCell) [cell setEnabled:[self tableView:table shouldEditTableColumn:column row:row]];
}

- (NSString *)tableView:(NSTableView *)table toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)column row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation
{
	if (row < 0 || row >= (NSInteger)[rowsShown count]) return nil;
	SPPostgresPrivilegeObject *object = [rowsShown objectAtIndex:(NSUInteger)row];
	if (SPPostgresPrivilegesIsDefaultKind([object kind]) && creatorName) {
		return [NSString stringWithFormat:NSLocalizedString(@"Granted on objects %@ creates in %@ from now on", @"Postgres users: default privileges row tooltip"), creatorName, schemaName ?: @""];
	}
	NSString *privilege = [column identifier];
	if ([[object grantable] containsObject:privilege]) return NSLocalizedString(@"Held with grant option", @"Postgres users: grantable privilege tooltip");
	return nil;
}

@end
