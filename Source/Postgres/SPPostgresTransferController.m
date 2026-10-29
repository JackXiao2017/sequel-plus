#import "SPPostgresTransferController.h"
#import "SPPostgresDocument.h"
#import "SPPostgresSidebarController.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresCheckList.h"
#import "SPPostgresTransfer.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import "SPPostgresProgressSheet.h"
#import "SPPostgresBackgroundJob.h"
#import "SPPostgresConnector.h"
#import "SPPostgresConsoleLogger.h"
#import "SPPostgresFavorite.h"
#import "SPPostgresFavoritesStore.h"
#import "SPKeychain.h"
#import <PostgresKit/PostgresKit.h>

static const NSUInteger SPPostgresTransferDefaultPort = 5432;

/// The Empty mode confirmation's text field: enables its button only while it holds exactly the expected name (as
/// typed, or as set by -setStringValue:).
@interface SPPostgresTransferConfirmationField : NSTextField
{
	NSString *expected;
	NSButton *button; // not retained: the alert holds both
}
- (void)setExpected:(NSString *)name button:(NSButton *)theButton;
@end

@implementation SPPostgresTransferConfirmationField

- (void)dealloc
{
	[expected release];
	[super dealloc];
}

- (void)_updateButton
{
	[button setEnabled:expected != nil && [[self stringValue] isEqualToString:expected]];
}

- (void)setExpected:(NSString *)name button:(NSButton *)theButton
{
	[expected release];
	expected = [name copy];
	button = theButton;
	[self _updateButton];
}

- (void)setStringValue:(NSString *)value
{
	[super setStringValue:value];
	[self _updateButton];
}

- (void)textDidChange:(NSNotification *)notification
{
	[super textDidChange:notification];
	[self _updateButton];
}

@end

@interface SPPostgresTransferController ()
- (void)_updateControls;
- (void)_finish;
@end

@implementation SPPostgresTransferController
{
	SPPostgresDocument *document; // retained until the controller goes away
	NSString *database;

	NSPanel *sheet;
	NSButton *wholeDatabaseRadio;
	NSButton *selectedTablesRadio;
	SPPostgresCheckList *tablesList;
	NSPopUpButton *favoritePopup;
	NSTextField *targetDescriptionField;
	NSTextField *databaseField;
	NSSecureTextField *passwordField;
	NSButton *emptyModeRadio;
	NSButton *overwriteModeRadio;
	NSButton *transferButton;
	NSButton *cancelButton;

	/// The user typed in the Database field: it no longer follows the favorite
	BOOL databaseEdited;

	SPPostgresProgressSheet *progressSheet;
	SPPostgresBackgroundJob *job;
	SPPostgresConnector *pendingConnector;
	NSString *lastErrorMessage;
	NSString *completionNote;
	BOOL began;
	BOOL finished;
	BOOL running;
	/// Empty mode's confirmation is being asked
	BOOL confirming;
}

@synthesize didEnd;
@synthesize favorites;
@synthesize targetProviderForFavorite;
@synthesize emptyConfirmation;
@synthesize progressObserver;
@synthesize temporaryDirectory;
@synthesize sheet;
@synthesize wholeDatabaseRadio;
@synthesize selectedTablesRadio;
@synthesize tablesList;
@synthesize favoritePopup;
@synthesize targetDescriptionField;
@synthesize databaseField;
@synthesize passwordField;
@synthesize emptyModeRadio;
@synthesize overwriteModeRadio;
@synthesize transferButton;
@synthesize pendingConnector;
@synthesize progressSheet;
@synthesize lastErrorMessage;
@synthesize completionNote;

- (instancetype)initWithDocument:(SPPostgresDocument *)theDocument
{
	if ((self = [super init])) {
		document = [theDocument retain];
		database = [[theDocument currentDatabase] copy];
	}
	return self;
}

- (void)dealloc
{
	[tablesList setChecksChanged:nil];
	for (NSControl *control in [NSArray arrayWithObjects:wholeDatabaseRadio, selectedTablesRadio, favoritePopup, emptyModeRadio, overwriteModeRadio, transferButton, cancelButton, nil]) [control setTarget:nil];
	[databaseField setDelegate:nil];

	[didEnd release];
	[favorites release];
	[targetProviderForFavorite release];
	[emptyConfirmation release];
	[progressObserver release];
	[temporaryDirectory release];
	[sheet release];
	[wholeDatabaseRadio release];
	[selectedTablesRadio release];
	[tablesList release];
	[favoritePopup release];
	[targetDescriptionField release];
	[databaseField release];
	[passwordField release];
	[emptyModeRadio release];
	[overwriteModeRadio release];
	[transferButton release];
	[cancelButton release];
	[progressSheet release];
	[job release];
	[pendingConnector release];
	[lastErrorMessage release];
	[completionNote release];
	[database release];
	[document release];
	[super dealloc];
}

- (void)_setLastErrorMessage:(NSString *)message
{
	if (message == lastErrorMessage) return;
	[lastErrorMessage release];
	lastErrorMessage = [message copy];
}

- (void)_setCompletionNote:(NSString *)note
{
	if (note == completionNote) return;
	[completionNote release];
	completionNote = [note copy];
}

- (void)_setPendingConnector:(SPPostgresConnector *)connector
{
	if (connector == pendingConnector) return;
	[pendingConnector release];
	pendingConnector = [connector retain];
}

#pragma mark - Target description

+ (NSString *)targetDescriptionForFavorite:(SPPostgresFavorite *)favorite
{
	if (!favorite) return @"";
	NSString *user = [favorite user] ?: @"";
	if ([favorite type] == SPPostgresSocketConnection) {
		NSString *directory = [[favorite socketPath] length] ? [favorite socketPath] : NSLocalizedString(@"local socket", @"Postgres transfer: target line for a socket favorite without a socket directory");
		return [NSString stringWithFormat:@"%@@%@", user, directory];
	}
	NSString *line = [NSString stringWithFormat:@"%@@%@:%lu", user, [favorite host] ?: @"", (unsigned long)([favorite port] ?: SPPostgresTransferDefaultPort)];
	if ([favorite type] == SPPostgresSSHConnection) {
		line = [NSString stringWithFormat:NSLocalizedString(@"%@ via SSH %@@%@", @"Postgres transfer: target line through an SSH tunnel (user@host:port, SSH user, SSH host)"), line, [favorite sshUser] ?: @"", [favorite sshHost] ?: @""];
	}
	return line;
}

#pragma mark - Building

- (NSTextField *)_labelWithFrame:(NSRect)frame text:(NSString *)text
{
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setStringValue:text];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	[label setAlignment:NSTextAlignmentRight];
	return label;
}

- (NSButton *)_radioWithFrame:(NSRect)frame title:(NSString *)title action:(SEL)action on:(BOOL)on
{
	NSButton *radio = [[NSButton alloc] initWithFrame:frame];
	[radio setButtonType:NSButtonTypeRadio];
	[radio setTitle:title];
	[radio setState:on ? NSControlStateValueOn : NSControlStateValueOff];
	[radio setTarget:self];
	[radio setAction:action];
	[radio setAutoresizingMask:NSViewMinYMargin];
	return radio;
}

- (void)_buildSheet
{
	if (sheet) return;

	CGFloat width = 520, height = 500;
	sheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setContentMinSize:NSMakeSize(width, height)];
	[sheet setTitle:NSLocalizedString(@"Transfer", @"Postgres transfer sheet: title")];
	NSView *content = [sheet contentView];

	NSTextField *heading = [self _labelWithFrame:NSMakeRect(20, height - 36, width - 40, 18) text:NSLocalizedString(@"Transfer", @"Postgres transfer sheet: title")];
	[heading setAlignment:NSTextAlignmentLeft];
	[heading setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[heading setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:heading];

	// Scope
	wholeDatabaseRadio = [self _radioWithFrame:NSMakeRect(20, height - 66, width - 40, 20)
										 title:[NSString stringWithFormat:NSLocalizedString(@"Whole database “%@”", @"Postgres transfer sheet: scope (database)"), database ?: @""]
										action:@selector(_scopeChanged:) on:YES];
	[content addSubview:wholeDatabaseRadio];
	selectedTablesRadio = [self _radioWithFrame:NSMakeRect(20, height - 90, width - 40, 20) title:NSLocalizedString(@"Selected tables", @"Postgres transfer sheet: scope") action:@selector(_scopeChanged:) on:NO];
	[content addSubview:selectedTablesRadio];

	CGFloat listBottom = 258;
	tablesList = [[SPPostgresCheckList alloc] initWithFrame:NSMakeRect(40, listBottom, width - 60, height - 98 - listBottom) inView:content];
	[tablesList setGroupsByFirstElement:YES];
	// Not capturing self: the list keeps the block, and the controller keeps the list
	__block SPPostgresTransferController *controller = self;
	[tablesList setChecksChanged:^{ [controller _updateControls]; }];

	// Target
	NSTextField *toLabel = [self _labelWithFrame:NSMakeRect(20, 216, 80, 18) text:NSLocalizedString(@"To:", @"Postgres transfer sheet: target favorite label")];
	[toLabel setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:toLabel];
	favoritePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, 211, 280, 26) pullsDown:NO];
	[favoritePopup setTarget:self];
	[favoritePopup setAction:@selector(_favoriteChanged:)];
	[favoritePopup setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:favoritePopup];

	targetDescriptionField = [[self _labelWithFrame:NSMakeRect(108, 192, width - 128, 16) text:@""] retain];
	[targetDescriptionField setAlignment:NSTextAlignmentLeft];
	[targetDescriptionField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[targetDescriptionField setTextColor:[NSColor secondaryLabelColor]];
	[targetDescriptionField setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[targetDescriptionField setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[content addSubview:targetDescriptionField];

	NSTextField *databaseLabel = [self _labelWithFrame:NSMakeRect(20, 160, 80, 18) text:NSLocalizedString(@"Database:", @"Postgres transfer sheet: target database label")];
	[databaseLabel setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:databaseLabel];
	databaseField = [[NSTextField alloc] initWithFrame:NSMakeRect(108, 158, 240, 22)];
	[databaseField setDelegate:self];
	[databaseField setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:databaseField];

	NSTextField *passwordLabel = [self _labelWithFrame:NSMakeRect(20, 128, 80, 18) text:NSLocalizedString(@"Password:", @"Postgres transfer sheet: target password label")];
	[passwordLabel setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:passwordLabel];
	passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(108, 126, 240, 22)];
	[passwordField setPlaceholderString:NSLocalizedString(@"Saved in Keychain", @"Postgres transfer sheet: password placeholder")];
	[passwordField setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:passwordField];

	// Mode
	emptyModeRadio = [self _radioWithFrame:NSMakeRect(20, 88, width - 40, 20) title:NSLocalizedString(@"Empty the target database first", @"Postgres transfer sheet: mode") action:@selector(_modeChanged:) on:YES];
	[emptyModeRadio setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:emptyModeRadio];
	overwriteModeRadio = [self _radioWithFrame:NSMakeRect(20, 64, width - 40, 20) title:NSLocalizedString(@"Overwrite tables that already exist on the target", @"Postgres transfer sheet: mode") action:@selector(_modeChanged:) on:NO];
	[overwriteModeRadio setAutoresizingMask:NSViewMaxYMargin];
	[content addSubview:overwriteModeRadio];

	// Buttons
	transferButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 20 - 100, 12, 100, 32)];
	[transferButton setBezelStyle:NSBezelStyleRounded];
	[transferButton setTitle:NSLocalizedString(@"Transfer", @"Postgres transfer sheet: transfer button")];
	[transferButton setKeyEquivalent:@"\r"];
	[transferButton setTarget:self];
	[transferButton setAction:@selector(transfer:)];
	[transferButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:transferButton];

	cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 20 - 100 - 100, 12, 100, 32)];
	[cancelButton setBezelStyle:NSBezelStyleRounded];
	[cancelButton setTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[cancelButton setKeyEquivalent:@"\e"];
	[cancelButton setTarget:self];
	[cancelButton setAction:@selector(cancel:)];
	[cancelButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	[content addSubview:cancelButton];
}

/// The tables of this tab's database (catalog queries on the tab's connection), preset to the sidebar's selected table;
/// the favorites, the first that isn't this tab's selected.
- (void)_loadContents
{
	SPPostgresCatalog *catalog = [[[SPPostgresCatalog alloc] initWithConnection:[document connection]] autorelease];
	NSError *error = nil;
	NSArray *rows = [SPPostgresCheckList groupedRowsForCatalog:catalog error:&error];
	if (error) [self _setLastErrorMessage:[error localizedDescription]];
	[tablesList setRows:rows ?: @[]];

	SPPostgresSidebarController *sidebar = [document sidebar];
	NSString *selectedSchema = [sidebar selectedSchema];
	NSString *selectedTable = [sidebar selectionIsTable] ? [sidebar selectedTableName] : nil;
	if (selectedTable && selectedSchema && [[tablesList rows] containsObject:@[selectedSchema, selectedTable]]) {
		[tablesList setChecked:YES item:@[selectedSchema, selectedTable]];
	}

	if (!favorites) [self setFavorites:[[SPPostgresFavoritesStore sharedStore] favorites] ?: @[]];

	// addItemWithTitle: would merge favorites with the same name: one menu item per favorite
	[favoritePopup removeAllItems];
	NSString *ownID = [[document favorite] favoriteID];
	NSInteger preselected = -1;
	for (NSUInteger index = 0; index < [favorites count]; index++) {
		SPPostgresFavorite *favorite = [favorites objectAtIndex:index];
		[[favoritePopup menu] addItemWithTitle:[favorite name] ?: @"" action:NULL keyEquivalent:@""];
		BOOL own = [ownID length] && [[favorite favoriteID] isEqualToString:ownID];
		if (preselected < 0 && !own) preselected = (NSInteger)index;
	}
	if ([favorites count]) [favoritePopup selectItemAtIndex:preselected >= 0 ? preselected : 0];
	[self _favoriteChanged:nil];
}

#pragma mark - Controls

- (SPPostgresFavorite *)_selectedFavorite
{
	NSInteger index = [favoritePopup indexOfSelectedItem];
	return (index >= 0 && (NSUInteger)index < [favorites count]) ? [favorites objectAtIndex:index] : nil;
}

- (BOOL)_wholeDatabase
{
	return [wholeDatabaseRadio state] == NSControlStateValueOn;
}

- (SPPostgresTransferMode)_mode
{
	return [overwriteModeRadio state] == NSControlStateValueOn ? SPPostgresTransferOverwrite : SPPostgresTransferEmptyTarget;
}

- (BOOL)_canTransfer
{
	if (finished || running || confirming) return NO;
	if (![self _selectedFavorite] || ![[databaseField stringValue] length]) return NO;
	return [self _wholeDatabase] || [[tablesList checkedItems] count] > 0;
}

- (void)_updateControls
{
	[[tablesList tableView] setEnabled:![self _wholeDatabase]];
	[favoritePopup setEnabled:[favorites count] > 0];
	[transferButton setEnabled:[self _canTransfer]];
}

- (void)_scopeChanged:(id)sender
{
	BOOL whole = (sender == wholeDatabaseRadio);
	[wholeDatabaseRadio setState:whole ? NSControlStateValueOn : NSControlStateValueOff];
	[selectedTablesRadio setState:whole ? NSControlStateValueOff : NSControlStateValueOn];
	[self _updateControls];
}

- (void)_modeChanged:(id)sender
{
	BOOL empty = (sender == emptyModeRadio);
	[emptyModeRadio setState:empty ? NSControlStateValueOn : NSControlStateValueOff];
	[overwriteModeRadio setState:empty ? NSControlStateValueOff : NSControlStateValueOn];
	[self _updateControls];
}

/// The target line follows the favorite; so does the Database field, until it is edited.
- (void)_favoriteChanged:(id)sender
{
	SPPostgresFavorite *favorite = [self _selectedFavorite];
	[targetDescriptionField setStringValue:[[self class] targetDescriptionForFavorite:favorite]];
	if (!databaseEdited) [databaseField setStringValue:[favorite database] ?: @""];
	[self _updateControls];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	if ([notification object] == databaseField) databaseEdited = YES;
	[self _updateControls];
}

#pragma mark - Sheet

- (void)beginSheet
{
	NSWindow *window = [document parentWindow];
	if (began || !window || [window attachedSheet]) {
		began = YES;
		[self _finish];
		return;
	}
	began = YES;
	[self retain]; // until -_finish

	[self _buildSheet];
	[self _loadContents];
	[self _updateControls];
	[window beginSheet:sheet completionHandler:nil];
}

/// Takes the sheet off the window (the controller stays).
- (void)_endSheet
{
	if ([sheet sheetParent]) [[sheet sheetParent] endSheet:sheet];
	[sheet orderOut:nil];
}

- (IBAction)cancel:(id)sender
{
	if (finished) return;
	if (running) {
		// The job sees it and stops (the target's transaction rolls back), then the controller ends
		[progressSheet cancel:nil];
		return;
	}
	// The confirmation sheet, if up, ends as Cancel (its answer is ignored once finished)
	NSWindow *alertWindow = [sheet attachedSheet];
	if (alertWindow) [sheet endSheet:alertWindow returnCode:NSAlertSecondButtonReturn];
	[self _endSheet];
	[self _finish];
}

- (void)_finish
{
	if (finished) return;
	finished = YES;
	[self _endSheet];

	void (^theDidEnd)(void) = [didEnd autorelease];
	didEnd = nil; // it may hold the document, which holds this controller
	if (theDidEnd) theDidEnd();
	if (began && sheet) [self autorelease]; // balances -beginSheet's retain
}

#pragma mark - Confirmation

- (NSAlert *)emptyConfirmationAlertForDatabase:(NSString *)theDatabase targetDescription:(NSString *)description
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleCritical];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Empty “%@” and transfer into it?", @"Postgres transfer: empty confirmation title (database)"), theDatabase ?: @""]];
	[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Everything in database “%@” on %@ will be deleted: all schemas (including public), tables, views, functions, types and extensions. Other databases on that server aren't touched.\n\nType the database's name to confirm.", @"Postgres transfer: empty confirmation text (database, target description)"), theDatabase ?: @"", description ?: @""]];
	NSButton *confirm = [alert addButtonWithTitle:NSLocalizedString(@"Empty and Transfer", @"Postgres transfer: empty confirmation button")];
	[confirm setHasDestructiveAction:YES];
	NSButton *cancel = [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[cancel setKeyEquivalent:@"\e"];

	SPPostgresTransferConfirmationField *field = [[[SPPostgresTransferConfirmationField alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)] autorelease];
	[field setPlaceholderString:theDatabase];
	[field setExpected:theDatabase button:confirm];
	[alert setAccessoryView:field];
	return alert;
}

#pragma mark - Transferring

- (IBAction)transfer:(id)sender
{
	if (![self _canTransfer]) return;

	SPPostgresFavorite *favorite = [[[self _selectedFavorite] copy] autorelease];
	NSString *targetDatabase = [[[databaseField stringValue] copy] autorelease];
	NSString *password = [[[passwordField stringValue] copy] autorelease];
	SPPostgresTransferMode mode = [self _mode];
	NSArray *tables = [self _wholeDatabase] ? nil : [[[tablesList checkedItems] copy] autorelease];

	if (mode != SPPostgresTransferEmptyTarget) {
		[self _startTransferTo:favorite database:targetDatabase password:password mode:mode tables:tables];
		return;
	}

	// Empty mode: confirmed first, before any connection is opened
	confirming = YES;
	[self _updateControls];
	__block BOOL answered = NO;
	void (^answer)(BOOL) = [[^(BOOL confirmed) {
		if (answered) return;
		answered = YES;
		confirming = NO;
		if (finished) return;
		if (confirmed) [self _startTransferTo:favorite database:targetDatabase password:password mode:mode tables:tables];
		else [self _updateControls];
	} copy] autorelease];

	NSString *description = [[self class] targetDescriptionForFavorite:favorite];
	if (emptyConfirmation) {
		emptyConfirmation(targetDatabase, description, answer);
		return;
	}
	NSAlert *alert = [self emptyConfirmationAlertForDatabase:targetDatabase targetDescription:description];
	[alert beginSheetModalForWindow:sheet completionHandler:^(NSModalResponse response) {
		answer(response == NSAlertFirstButtonReturn);
	}];
	[[alert window] makeFirstResponder:[alert accessoryView]];
}

/// The target's default provider: a connector for a copy of the favorite with the database asked for, the typed
/// password or else the Keychain's (read now, as the transfer starts), the Keychain's SSH password, its SSH prompts on
/// the progress sheet, and a console logger named after the favorite; kept until the job ends.
- (SPPostgresConnectionProvider)_defaultTargetProviderForFavorite:(SPPostgresFavorite *)favorite password:(NSString *)typed sheetWindow:(NSWindow *)window
{
	SPPostgresFavorite *base = [[favorite copy] autorelease];
	NSString *typedPassword = [[typed copy] autorelease];
	SPPostgresConnectionProvider provider = ^(NSString *targetDatabase, void (^completion)(PGPostgresConnection *, NSError *)) {
		SPKeychain *keychain = [[[SPKeychain alloc] init] autorelease];
		// The Keychain items are named after the favorite as saved (its database included)
		NSString *thePassword = [typedPassword length] ? typedPassword : [keychain getPasswordForName:[base keychainName] account:[base keychainAccount]];
		NSString *theSSHPassword = ([base type] == SPPostgresSSHConnection) ? [keychain getPasswordForName:[base sshKeychainName] account:[base sshKeychainAccount]] : nil;
		SPPostgresFavorite *target = [[base copy] autorelease];
		[target setDatabase:targetDatabase];
		SPPostgresConnector *connector = [[[SPPostgresConnector alloc] initWithFavorite:target
																			  password:[thePassword length] ? thePassword : nil
																		   sshPassword:[theSSHPassword length] ? theSSHPassword : nil
																		  parentWindow:window] autorelease];
		[self _setPendingConnector:connector];
		void (^done)(PGPostgresConnection *, NSError *) = [[completion copy] autorelease];
		[connector connectWithCompletion:^(PGPostgresConnection *connection, NSError *error) {
			if (connection) {
				// Its statements go to the Console under the target favorite's name (COPY data never does)
				SPPostgresConsoleLogger *logger = [[[SPPostgresConsoleLogger alloc] initWithConnectionName:[base name] ?: @"" database:targetDatabase] autorelease];
				[logger attachToConnection:connection];
				[SPPostgresBackgroundJob keepOwner:connector untilJobEndsOnConnection:connection];
			}
			if (pendingConnector == connector) [self _setPendingConnector:nil];
			done(connection, error);
		}];
	};
	return [[provider copy] autorelease];
}

static NSError *SPPostgresTransferCancelledError(void)
{
	return SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The transfer was cancelled.", @"Postgres transfer: cancelled"), nil);
}

- (void)_startTransferTo:(SPPostgresFavorite *)favorite database:(NSString *)targetDatabase password:(NSString *)password mode:(SPPostgresTransferMode)mode tables:(NSArray *)tables
{
	running = YES;
	[self _setLastErrorMessage:nil];
	[self _setCompletionNote:nil];
	[self _endSheet];

	NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Transferring “%@” to “%@”…", @"Postgres transfer: progress title (source database, target database)"), database, targetDatabase];
	[progressSheet release];
	progressSheet = [[SPPostgresProgressSheet beginOnWindow:[document parentWindow] title:title] retain];
	SPPostgresProgressSheet *progress = progressSheet;
	[progress setStatus:NSLocalizedString(@"Connecting…", @"Postgres transfer: progress status while connecting") fraction:0];
	NSWindow *progressWindow = [progress panel];

	// The job's blocks hold the controller only while the job runs (it lets go of them when it ends)
	SPPostgresConnectionProvider sourceProvider = [document connectionProviderForJobWithSheetWindow:^NSWindow *{
		return progressWindow;
	} connecting:^(SPPostgresConnector *connector) {
		[self _setPendingConnector:connector];
	}];
	SPPostgresConnectionProvider targetProvider = targetProviderForFavorite ? targetProviderForFavorite(favorite, password)
		: [self _defaultTargetProviderForFavorite:favorite password:password sheetWindow:progressWindow];

	// Cleared by the progress sheet's -end: not capturing self
	__block SPPostgresTransferController *controller = self;
	[progress setCancelHandler:^{
		// While connecting: the job ends at once. Once it runs: the engine sees the sheet's flag, and the statements
		// both connections are running are interrupted
		SPPostgresBackgroundJob *theJob = controller->job;
		SPPostgresConnector *connecting = [theJob waitingForConnection] ? [[controller->pendingConnector retain] autorelease] : nil;
		[theJob cancel];
		[connecting cancel];
	}];

	NSString *directory = [[temporaryDirectory copy] autorelease];
	void (^observer)(SPPostgresProgressSheet *) = [[progressObserver copy] autorelease];
	NSMutableDictionary *results = [NSMutableDictionary dictionary];
	BOOL (^work)(PGPostgresConnection *, PGPostgresConnection *, NSError **) = ^BOOL(PGPostgresConnection *source, PGPostgresConnection *target, NSError **error) {
		if ([progress cancelled]) {
			if (error) *error = SPPostgresTransferCancelledError();
			return NO;
		}
		SPPostgresTransfer *transfer = [[[SPPostgresTransfer alloc] initWithSource:source target:target] autorelease];
		if (tables) [transfer setTables:tables];
		else [transfer setWholeDatabase:YES];
		[transfer setMode:mode];
		if (directory) [transfer setTemporaryDirectory:directory];
		__block SPPostgresTransfer *engine = transfer; // the engine keeps the block
		[transfer setProgress:^BOOL(SPPostgresTransferPhase phase, double fraction, NSString *detail) {
			NSString *status = nil;
			double bar = 0;
			switch (phase) {
				case SPPostgresTransferChecking:
					status = NSLocalizedString(@"Checking the target…", @"Postgres transfer: progress status");
					break;
				case SPPostgresTransferReading:
					status = [NSString stringWithFormat:NSLocalizedString(@"Reading table %lu of %lu: %@", @"Postgres transfer: progress status (index, count, table)"), (unsigned long)[engine readingTableIndex], (unsigned long)[engine readingTableCount], detail ?: @""];
					bar = fraction * 0.5;
					break;
				case SPPostgresTransferWriting:
					status = [NSString stringWithFormat:NSLocalizedString(@"Writing to “%@”…", @"Postgres transfer: progress status (target database)"), targetDatabase];
					bar = 0.5 + fraction * 0.5;
					break;
			}
			[progress setStatus:status fraction:bar];
			if (observer) observer(progress);
			return ![progress cancelled];
		}];
		BOOL ok = [transfer run:error];
		[transfer setProgress:nil];
		if (ok) {
			// Read on the main thread once the job has ended
			[results setObject:@([transfer tablesCopied]) forKey:@"tablesCopied"];
			[results setObject:[transfer replacedObjects] ?: @[] forKey:@"replacedObjects"];
			[results setObject:[transfer dependenciesCreated] ?: @[] forKey:@"dependenciesCreated"];
			[results setObject:[transfer foreignTablesSkipped] ?: @[] forKey:@"foreignTablesSkipped"];
			[results setObject:[transfer skippedSettings] ?: @[] forKey:@"skippedSettings"];
		}
		return ok;
	};

	NSString *favoriteName = [favorite name] ?: @"";
	[job release];
	job = [[SPPostgresBackgroundJob runOnDatabase:database provider:sourceProvider targetDatabase:targetDatabase targetProvider:targetProvider work:work completion:^(BOOL ok, NSError *error) {
		// Whatever failed after Cancel (e.g. the statement the cancel interrupted) is the cancel
		NSError *outcome = error;
		if (!ok && [progress cancelled] && !([[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorCancelled)) {
			outcome = SPPostgresTransferCancelledError();
		}
		[self _jobEndedWithSuccess:ok error:outcome results:results database:targetDatabase favoriteName:favoriteName];
	}] retain];
}

/// "“<db>” on “<favorite>”"
static NSString *SPPostgresTransferPlace(NSString *targetDatabase, NSString *favoriteName)
{
	return [NSString stringWithFormat:NSLocalizedString(@"“%@” on “%@”", @"Postgres transfer: target database on favorite"), targetDatabase, favoriteName];
}

/// "Copied <n> tables to “<db>” on “<favorite>”." and, when any, what was replaced, created, left out or skipped.
- (NSString *)_completionNoteForResults:(NSDictionary *)results database:(NSString *)targetDatabase favoriteName:(NSString *)favoriteName
{
	NSUInteger count = [[results objectForKey:@"tablesCopied"] unsignedIntegerValue];
	NSString *place = SPPostgresTransferPlace(targetDatabase, favoriteName);
	NSMutableArray *lines = [NSMutableArray array];
	[lines addObject:(count == 1)
		? [NSString stringWithFormat:NSLocalizedString(@"Copied 1 table to %@.", @"Postgres transfer: completion (target)"), place]
		: [NSString stringWithFormat:NSLocalizedString(@"Copied %lu tables to %@.", @"Postgres transfer: completion (count, target)"), (unsigned long)count, place]];

	NSArray *replaced = [results objectForKey:@"replacedObjects"];
	if ([replaced count]) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Replaced: %@.", @"Postgres transfer: completion, objects replaced on the target"), [replaced componentsJoinedByString:@", "]]];
	NSArray *created = [results objectForKey:@"dependenciesCreated"];
	if ([created count]) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Also created, as the tables need them: %@.", @"Postgres transfer: completion, dependencies created"), [created componentsJoinedByString:@", "]]];
	NSArray *foreign = [results objectForKey:@"foreignTablesSkipped"];
	if ([foreign count]) {
		NSMutableArray *names = [NSMutableArray array];
		for (NSArray *pair in foreign) [names addObject:[NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier([pair objectAtIndex:0]), SPPostgresQuoteIdentifier([pair objectAtIndex:1])]];
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Foreign tables aren't copied (nor their servers and user mappings): %@.", @"Postgres transfer: completion, foreign tables left out"), [names componentsJoinedByString:@", "]]];
	}
	NSArray *settings = [results objectForKey:@"skippedSettings"];
	if ([settings count]) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Settings the target doesn't know were skipped: %@.", @"Postgres transfer: completion, settings skipped"), [settings componentsJoinedByString:@", "]]];
	return [lines componentsJoinedByString:@"\n\n"];
}

- (void)_jobEndedWithSuccess:(BOOL)ok error:(NSError *)error results:(NSDictionary *)results database:(NSString *)targetDatabase favoriteName:(NSString *)favoriteName
{
	if (finished) return;
	[progressSheet end];
	[job release];
	job = nil;
	[self _setPendingConnector:nil];
	running = NO;

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	if (ok) {
		[self _setCompletionNote:[self _completionNoteForResults:results database:targetDatabase favoriteName:favoriteName]];
		[alert setMessageText:NSLocalizedString(@"Transfer complete", @"Postgres transfer: success title")];
		[alert setInformativeText:completionNote];
	}
	else if ([[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorCancelled) {
		// A cancel isn't an error: nothing to show (the target's transaction, if any, rolled back)
		[self _setLastErrorMessage:[error localizedDescription] ?: [SPPostgresTransferCancelledError() localizedDescription]];
		alert = nil;
	}
	else {
		NSString *message = [NSString stringWithFormat:NSLocalizedString(@"The transfer failed. %@ wasn't changed.", @"Postgres transfer: failure title (target)"), SPPostgresTransferPlace(targetDatabase, favoriteName)];
		NSMutableString *text = [NSMutableString stringWithString:[error localizedDescription] ?: @""];
		NSArray *dependents = [[error userInfo] objectForKey:SPPostgresDependentsErrorKey];
		if ([dependents count]) {
			[text appendFormat:@"\n\n%@\n%@", NSLocalizedString(@"In the way:", @"Postgres transfer: failure, the target's objects depending on objects the transfer would replace"), [dependents componentsJoinedByString:@"\n"]];
		}
		[self _setLastErrorMessage:[NSString stringWithFormat:@"%@\n\n%@", message, text]];
		[alert setMessageText:message];
		[alert setInformativeText:text];
	}
	if (alert) {
		[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
		// As the document shows its alerts: never dropped, it waits while the tab isn't shown
		[document presentAlert:alert];
	}
	[self _finish];
}

@end
