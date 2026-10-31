#import "SPPostgresImportController.h"
#import "SPPostgresDocument.h"
#import "SPPostgresSidebarController.h"
#import "SPPostgresCatalog.h"
#import "SPPostgresCSV.h"
#import "SPPostgresCSVMappingSheet.h"
#import "SPPostgresDumpReader.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import "SPPostgresProgressSheet.h"
#import "SPPostgresBackgroundJob.h"
#import "SPPostgresConnector.h"
#import <PostgresKit/PostgresKit.h>

/// The format pop-up's items, and the delimiter pop-up's (, ; Tab | Custom)
static const NSInteger SPImportFormatSQL = 0;
static const NSInteger SPImportFormatCSV = 1;
static const NSInteger SPImportTabDelimiterIndex = 2;
static const NSInteger SPImportCustomDelimiterIndex = 4;
/// How many rows the mapping sheet previews
static const NSUInteger SPImportPreviewRows = 10;

@interface SPPostgresImportController () <NSTextFieldDelegate>
- (void)_finish;
@end

@implementation SPPostgresImportController
{
	SPPostgresDocument *document; // retained until the controller goes away
	NSString *database;

	NSView *accessoryView;
	NSPopUpButton *formatPopup;
	NSView *sqlOptions;
	NSView *csvOptionsView;
	NSButton *singleTransactionCheckbox;
	NSPopUpButton *delimiterPopup;
	NSTextField *customDelimiterField;
	NSTextField *quoteField;
	NSPopUpButton *escapePopup;
	NSButton *headerCheckbox;
	NSTextField *nullField;

	NSOpenPanel *openPanel;
	SPPostgresCSVMappingSheet *mappingSheet;
	SPPostgresProgressSheet *progressSheet;
	SPPostgresBackgroundJob *job;
	SPPostgresConnector *pendingConnector;
	/// The alert asking Stop / Ignore / Ignore All while it is up
	NSAlert *errorAlert;

	SPPostgresCSVOptions *csvOptions;
	SPPostgresImportErrorChoice (^errorChoiceProvider)(NSError *);
	NSString *lastErrorMessage;
	NSString *completionNote;

	BOOL kept;      // retained by -_keep until -_finish
	BOOL finished;
	BOOL running;
	BOOL abandoned; // Cancel came while nothing could be cancelled yet
}

@synthesize didEnd;
@synthesize formatPopup;
@synthesize singleTransactionCheckbox;
@synthesize csvOptions;
@synthesize errorChoiceProvider;
@synthesize mappingSheet;
@synthesize progressSheet;
@synthesize pendingConnector;
@synthesize running;
@synthesize lastErrorMessage;
@synthesize completionNote;

+ (NSString *)formatForPath:(NSString *)path
{
	NSString *name = [[path lastPathComponent] lowercaseString];
	for (NSString *compressed in @[@".gz", @".gzip", @".bz2", @".bz"]) {
		if ([name hasSuffix:compressed]) {
			name = [name substringToIndex:[name length] - [compressed length]];
			break;
		}
	}
	NSString *extension = [name pathExtension];
	return ([extension isEqualToString:@"csv"] || [extension isEqualToString:@"tsv"]) ? @"csv" : @"sql";
}

- (instancetype)initWithDocument:(SPPostgresDocument *)theDocument
{
	if ((self = [super init])) {
		document = [theDocument retain];
		database = [[theDocument currentDatabase] copy];
		csvOptions = [[SPPostgresCSVOptions alloc] init];
		[self _buildAccessoryView];
		[self _showOptionsFromCSVOptions];
	}
	return self;
}

- (void)dealloc
{
	for (NSControl *control in [NSArray arrayWithObjects:formatPopup, singleTransactionCheckbox, delimiterPopup, escapePopup, headerCheckbox, nil]) [control setTarget:nil];
	[customDelimiterField setDelegate:nil];
	[quoteField setDelegate:nil];
	[nullField setDelegate:nil];
	[openPanel setDelegate:nil];

	[didEnd release];
	[accessoryView release];
	[formatPopup release];
	[sqlOptions release];
	[csvOptionsView release];
	[singleTransactionCheckbox release];
	[delimiterPopup release];
	[customDelimiterField release];
	[quoteField release];
	[escapePopup release];
	[headerCheckbox release];
	[nullField release];
	[openPanel release];
	[mappingSheet release];
	[progressSheet release];
	[job release];
	[pendingConnector release];
	[errorAlert release];
	[csvOptions release];
	[errorChoiceProvider release];
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

#pragma mark - The open panel's accessory

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

- (NSTextField *)_fieldWithFrame:(NSRect)frame
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
	[field setDelegate:self];
	return field;
}

- (void)_buildAccessoryView
{
	CGFloat width = 480, height = 170;
	accessoryView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

	[accessoryView addSubview:[self _labelWithFrame:NSMakeRect(0, height - 30, 100, 18) text:NSLocalizedString(@"Format:", @"Postgres import panel: format label")]];
	formatPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, height - 35, 120, 26) pullsDown:NO];
	[formatPopup addItemsWithTitles:@[@"SQL", @"CSV"]];
	[formatPopup setTarget:self];
	[formatPopup setAction:@selector(_controlChanged:)];
	[accessoryView addSubview:formatPopup];

	NSRect optionsFrame = NSMakeRect(0, 0, width, height - 40);

	// SQL
	sqlOptions = [[NSView alloc] initWithFrame:optionsFrame];
	singleTransactionCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(104, optionsFrame.size.height - 26, 340, 20)];
	[singleTransactionCheckbox setButtonType:NSButtonTypeSwitch];
	[singleTransactionCheckbox setTitle:NSLocalizedString(@"Run in a single transaction", @"Postgres import panel: SQL option")];
	[singleTransactionCheckbox setState:NSControlStateValueOn];
	[sqlOptions addSubview:singleTransactionCheckbox];
	NSTextField *sqlNote = [self _labelWithFrame:NSMakeRect(122, optionsFrame.size.height - 62, 340, 32) text:NSLocalizedString(@"All or nothing: any error rolls everything back. Off: each statement commits on its own.", @"Postgres import panel: single transaction note")];
	[sqlNote setAlignment:NSTextAlignmentLeft];
	[sqlNote setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[sqlNote setTextColor:[NSColor secondaryLabelColor]];
	[sqlOptions addSubview:sqlNote];
	[accessoryView addSubview:sqlOptions];

	// CSV
	csvOptionsView = [[NSView alloc] initWithFrame:optionsFrame];
	CGFloat top = optionsFrame.size.height;
	[csvOptionsView addSubview:[self _labelWithFrame:NSMakeRect(0, top - 24, 100, 18) text:NSLocalizedString(@"Delimiter:", @"Postgres import panel: CSV option")]];
	delimiterPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, top - 29, 110, 26) pullsDown:NO];
	[delimiterPopup addItemsWithTitles:@[@",", @";", NSLocalizedString(@"Tab", @"Postgres import panel: tab delimiter"), @"|", NSLocalizedString(@"Custom", @"Postgres import panel: custom delimiter")]];
	[delimiterPopup setTarget:self];
	[delimiterPopup setAction:@selector(_controlChanged:)];
	[csvOptionsView addSubview:delimiterPopup];
	customDelimiterField = [self _fieldWithFrame:NSMakeRect(222, top - 26, 40, 22)];
	[csvOptionsView addSubview:customDelimiterField];

	[csvOptionsView addSubview:[self _labelWithFrame:NSMakeRect(0, top - 54, 100, 18) text:NSLocalizedString(@"Quote:", @"Postgres import panel: CSV option")]];
	quoteField = [self _fieldWithFrame:NSMakeRect(106, top - 56, 40, 22)];
	[csvOptionsView addSubview:quoteField];
	[csvOptionsView addSubview:[self _labelWithFrame:NSMakeRect(160, top - 54, 60, 18) text:NSLocalizedString(@"Escape:", @"Postgres import panel: CSV option")]];
	escapePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(224, top - 59, 70, 26) pullsDown:NO];
	[escapePopup addItemsWithTitles:@[@"\"", @"\\"]];
	[csvOptionsView addSubview:escapePopup];

	headerCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(104, top - 82, 300, 20)];
	[headerCheckbox setButtonType:NSButtonTypeSwitch];
	[headerCheckbox setTitle:NSLocalizedString(@"First row holds column names", @"Postgres import panel: CSV option")];
	[csvOptionsView addSubview:headerCheckbox];

	[csvOptionsView addSubview:[self _labelWithFrame:NSMakeRect(0, top - 108, 100, 18) text:NSLocalizedString(@"NULL as:", @"Postgres import panel: CSV option")]];
	nullField = [self _fieldWithFrame:NSMakeRect(106, top - 110, 100, 22)];
	[csvOptionsView addSubview:nullField];
	NSTextField *encoding = [self _labelWithFrame:NSMakeRect(220, top - 108, 240, 18) text:NSLocalizedString(@"Encoding: UTF-8", @"Postgres import panel: CSV encoding")];
	[encoding setAlignment:NSTextAlignmentLeft];
	[encoding setTextColor:[NSColor secondaryLabelColor]];
	[csvOptionsView addSubview:encoding];
	[accessoryView addSubview:csvOptionsView];

	[self _updateControls];
}

/// The CSV controls show csvOptions.
- (void)_showOptionsFromCSVOptions
{
	NSString *delimiter = [csvOptions delimiter] ?: @",";
	NSInteger index = SPImportCustomDelimiterIndex;
	if ([delimiter isEqualToString:@","]) index = 0;
	else if ([delimiter isEqualToString:@";"]) index = 1;
	else if ([delimiter isEqualToString:@"\t"]) index = SPImportTabDelimiterIndex;
	else if ([delimiter isEqualToString:@"|"]) index = 3;
	[delimiterPopup selectItemAtIndex:index];
	[customDelimiterField setStringValue:index == SPImportCustomDelimiterIndex ? delimiter : @""];
	[quoteField setStringValue:[csvOptions quote] ?: @"\""];
	[escapePopup selectItemAtIndex:[[csvOptions escape] isEqualToString:@"\\"] ? 1 : 0];
	[headerCheckbox setState:[csvOptions header] ? NSControlStateValueOn : NSControlStateValueOff];
	[nullField setStringValue:[csvOptions nullString] ?: @""];
	[self _updateControls];
}

/// csvOptions takes the CSV controls' values.
- (void)_readCSVOptionsFromControls
{
	NSString *delimiter;
	switch ([delimiterPopup indexOfSelectedItem]) {
		case 1: delimiter = @";"; break;
		case SPImportTabDelimiterIndex: delimiter = @"\t"; break;
		case 3: delimiter = @"|"; break;
		case SPImportCustomDelimiterIndex: delimiter = [customDelimiterField stringValue]; break;
		default: delimiter = @","; break;
	}
	SPPostgresCSVOptions *options = [[[SPPostgresCSVOptions alloc] init] autorelease];
	[options setDelimiter:delimiter];
	[options setQuote:[quoteField stringValue]];
	[options setEscape:[escapePopup indexOfSelectedItem] == 1 ? @"\\" : @"\""];
	[options setHeader:[headerCheckbox state] == NSControlStateValueOn];
	[options setNullString:[nullField stringValue]];
	[self setCsvOptions:options];
}

- (void)_updateControls
{
	BOOL csv = [formatPopup indexOfSelectedItem] == SPImportFormatCSV;
	[sqlOptions setHidden:csv];
	[csvOptionsView setHidden:!csv];
	[customDelimiterField setEnabled:[delimiterPopup indexOfSelectedItem] == SPImportCustomDelimiterIndex];
}

- (void)_controlChanged:(id)sender
{
	[self _updateControls];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self _updateControls];
}

/// The format follows the file chosen (a .tsv also presets the Tab delimiter); the user can change it after.
- (void)panelSelectionDidChange:(id)sender
{
	NSString *path = [[openPanel URL] path];
	if (![path length]) return;
	BOOL csv = [[[self class] formatForPath:path] isEqualToString:@"csv"];
	[formatPopup selectItemAtIndex:csv ? SPImportFormatCSV : SPImportFormatSQL];
	NSString *name = [[path lastPathComponent] lowercaseString];
	if (csv && ([name hasSuffix:@".tsv"] || [name containsString:@".tsv."])) [delimiterPopup selectItemAtIndex:SPImportTabDelimiterIndex];
	[self _updateControls];
}

#pragma mark - Flow

/// Keeps the controller alive until -_finish.
- (void)_keep
{
	if (kept) return;
	kept = YES;
	[self retain];
}

- (void)beginImport
{
	NSWindow *window = [document parentWindow];
	if (finished || openPanel || running || mappingSheet) return;
	[self _keep];
	if (!window || [window attachedSheet]) {
		[self _finish];
		return;
	}

	openPanel = [[NSOpenPanel openPanel] retain];
	[openPanel setCanChooseFiles:YES];
	[openPanel setCanChooseDirectories:NO];
	[openPanel setAllowsMultipleSelection:NO];
	[openPanel setPrompt:NSLocalizedString(@"Import", @"Postgres import panel: prompt")];
	[openPanel setMessage:[NSString stringWithFormat:NSLocalizedString(@"Choose a SQL or CSV file to import into “%@”.", @"Postgres import panel: message (database)"), database ?: @""]];
	[openPanel setAccessoryView:accessoryView];
	[openPanel setAccessoryViewDisclosed:YES];
	[openPanel setDelegate:self];
	[openPanel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		NSString *path = (response == NSModalResponseOK) ? [[openPanel URL] path] : nil;
		[openPanel setDelegate:nil];
		[openPanel autorelease];
		openPanel = nil;
		if (![path length] || abandoned) {
			[self _finish];
			return;
		}
		[self _readCSVOptionsFromControls];
		NSString *format = [formatPopup indexOfSelectedItem] == SPImportFormatCSV ? @"csv" : @"sql";
		// The next sheet attaches once the panel has gone
		dispatch_async(dispatch_get_main_queue(), ^{
			[self importPath:path format:format];
		});
	}];
}

- (void)importPath:(NSString *)path format:(NSString *)format
{
	if (finished || running || mappingSheet) return;
	[self _keep];
	[self _setLastErrorMessage:nil];
	[completionNote release];
	completionNote = nil;
	if (abandoned) {
		[self _finish];
		return;
	}
	if ([format isEqualToString:@"csv"]) [self _showMappingForPath:path];
	else [self _runSQLImportOfPath:path];
}

- (void)cancel
{
	if (finished) return;
	abandoned = YES;
	if (openPanel) {
		NSWindow *parent = [openPanel sheetParent];
		if (parent) [parent endSheet:openPanel returnCode:NSModalResponseCancel];
		else [openPanel cancel:nil];
		return;
	}
	if (mappingSheet) {
		[mappingSheet cancelSheet];
		return;
	}
	if (running) {
		// Stop is the answer to a question still up; the job sees the cancel and rolls back
		if (errorAlert) [[[errorAlert window] sheetParent] endSheet:[errorAlert window] returnCode:NSAlertFirstButtonReturn];
		[progressSheet cancel:nil];
		return;
	}
	[self _finish];
}

- (void)_finish
{
	if (finished) return;
	finished = YES;
	void (^theDidEnd)(void) = [didEnd autorelease];
	didEnd = nil; // it may hold the document, which holds this controller
	if (theDidEnd) theDidEnd();
	if (kept) [self autorelease]; // balances -_keep
}

- (void)_presentError:(NSString *)message
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"The import failed", @"Postgres import: error title")];
	[alert setInformativeText:message ?: @""];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
	[document presentAlert:alert];
}

#pragma mark - CSV mapping

/// The table's columns in attnum order (@{name, generated}), read on the document's connection (catalog only).
- (NSArray *)_columnsOfTable:(NSString *)table schema:(NSString *)schema error:(NSError **)error
{
	NSString *qualified = [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(schema), SPPostgresQuoteIdentifier(table)];
	PGPostgresResult *result = SPPostgresExecuteWithDetails([document connection],
		@"SELECT a.attname::text, (a.attgenerated <> '')::text FROM pg_catalog.pg_attribute a"
		" WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum", @[qualified], error);
	if (!result) return nil;
	NSMutableArray *columns = [NSMutableArray array];
	for (unsigned long long row = 0; row < [result numberOfRows]; row++) {
		id name = [result textValueAtRow:row column:0];
		id generated = [result textValueAtRow:row column:1];
		[columns addObject:@{@"name": [name isKindOfClass:[NSString class]] ? name : @"", @"generated": @([generated isEqual:@"true"])}];
	}
	return columns;
}

- (void)_showMappingForPath:(NSString *)path
{
	SPPostgresCSVOptions *options = [[csvOptions copy] autorelease];

	// The file's columns and first rows (a few rows: read here)
	NSError *error = nil;
	NSArray *names = [SPPostgresCSV headerAtPath:path options:options error:&error];
	NSArray *rows = names ? [SPPostgresCSV previewRowsAtPath:path options:options limit:SPImportPreviewRows error:&error] : nil;
	if (!names || !rows) {
		[self _setLastErrorMessage:[error localizedDescription] ?: NSLocalizedString(@"The file can't be read.", @"Postgres import: unreadable CSV")];
		[self _presentError:lastErrorMessage];
		[self _finish];
		return;
	}

	// The database's tables, from the document's connection (catalog queries only)
	SPPostgresCatalog *catalog = [[[SPPostgresCatalog alloc] initWithConnection:[document connection]] autorelease];
	NSError *catalogError = nil;
	NSMutableArray *tables = [NSMutableArray array];
	for (NSString *schema in [catalog schemaNames:&catalogError] ?: @[]) {
		for (NSString *table in [catalog tableNamesInSchema:schema error:NULL] ?: @[]) [tables addObject:@[schema, table]];
	}
	if (![tables count]) {
		[self _setLastErrorMessage:[catalogError localizedDescription] ?: NSLocalizedString(@"The database has no tables to import into.", @"Postgres import: no tables")];
		[self _presentError:lastErrorMessage];
		[self _finish];
		return;
	}

	SPPostgresSidebarController *sidebar = [document sidebar];
	NSArray *selected = nil;
	if ([sidebar selectionIsTable] && [sidebar selectedTableName] && [sidebar selectedSchema]) selected = @[[sidebar selectedSchema], [sidebar selectedTableName]];

	__block SPPostgresImportController *controller = self; // the sheet lives no longer than the controller
	mappingSheet = [[SPPostgresCSVMappingSheet alloc] initWithTables:tables selectedTable:selected csvColumnNames:names previewRows:rows
													 columnsProvider:^NSArray *(NSString *schema, NSString *table, NSError **columnsError) {
		return [controller _columnsOfTable:table schema:schema error:columnsError];
	}];

	NSWindow *window = [document parentWindow];
	if (!window) {
		[self _finish];
		return;
	}
	[mappingSheet beginSheetForWindow:window completion:^(BOOL import) {
		SPPostgresCSVMappingSheet *theSheet = [mappingSheet autorelease];
		mappingSheet = nil;
		if (!import || abandoned) {
			[self _finish];
			return;
		}
		[self _runCSVImportOfPath:path options:options schema:[theSheet selectedSchema] table:[theSheet selectedTable] mapping:[theSheet mapping]];
	}];
}

#pragma mark - Jobs

- (SPPostgresProgressSheet *)_beginProgressForPath:(NSString *)path
{
	NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Importing “%@”…", @"Postgres import: progress title (file name)"), [path lastPathComponent]];
	[progressSheet release];
	progressSheet = [[SPPostgresProgressSheet beginOnWindow:[document parentWindow] title:title] retain];
	[progressSheet setStatus:NSLocalizedString(@"Connecting…", @"Postgres import: progress status while connecting") fraction:0];
	return progressSheet;
}

/// When the job last showed its progress (job thread only).
typedef struct {
	BOOL shown;
	CFAbsoluteTime time;
	unsigned long long bytesRead;
} SPPostgresImportReportState;

/**
 * The job's progress report: bytes read of the file's size; whether to go on. The status is only formatted when
 * 100 ms have passed or the bytes read moved 0.1% of the file since it was last shown (a report comes after every
 * statement); the cancel is checked every time.
 */
static BOOL SPPostgresImportReport(SPPostgresProgressSheet *progress, SPPostgresImportReportState *state, unsigned long long bytesRead, unsigned long long fileSize)
{
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	unsigned long long moved = bytesRead > state->bytesRead ? bytesRead - state->bytesRead : state->bytesRead - bytesRead;
	if (!state->shown || now - state->time >= 0.1 || moved * 1000 >= fileSize) {
		state->shown = YES;
		state->time = now;
		state->bytesRead = bytesRead;
		NSString *status = [NSString stringWithFormat:NSLocalizedString(@"%@ of %@", @"Postgres import: progress status (bytes read, file size)"),
							[NSByteCountFormatter stringFromByteCount:(long long)bytesRead countStyle:NSByteCountFormatterCountStyleFile],
							[NSByteCountFormatter stringFromByteCount:(long long)fileSize countStyle:NSByteCountFormatterCountStyleFile]];
		[progress setStatus:status fraction:fileSize ? MIN(1.0, (double)bytesRead / (double)fileSize) : 0];
	}
	return ![progress cancelled];
}

static NSError *SPPostgresImportCancelledError(void)
{
	return SPPostgresMakeError(SPPostgresErrorCancelled, NSLocalizedString(@"The import was cancelled.", @"Postgres import: cancelled"), nil);
}

/**
 * Runs work as a background job on a connection from the document's provider (as the Export sheet does): its SSH
 * sheets go to the progress sheet, and a Cancel while connecting cancels the pending connector and ends the job.
 * completion runs on the main thread with the job's outcome.
 */
- (void)_runJobWithProgress:(SPPostgresProgressSheet *)progress work:(BOOL (^)(PGPostgresConnection *connection, NSError **error))work completion:(void (^)(BOOL ok, NSError *error))completion
{
	running = YES;
	NSWindow *progressWindow = [progress panel];
	SPPostgresConnectionProvider provider = [document connectionProviderForJobWithSheetWindow:^NSWindow *{
		return progressWindow;
	} connecting:^(SPPostgresConnector *theConnector) {
		if (theConnector == pendingConnector) return;
		[pendingConnector release];
		pendingConnector = [theConnector retain];
	}];

	[progress setCancelHandler:^{
		// While connecting: the job ends at once. Once it runs: the work sees the sheet's flag, and the statement its
		// connection is running is interrupted (a lock wait, a long statement)
		SPPostgresConnector *connecting = [job waitingForConnection] ? [[pendingConnector retain] autorelease] : nil;
		[job cancel];
		[connecting cancel];
	}];

	void (^done)(BOOL, NSError *) = [[completion copy] autorelease];
	[job release];
	job = [[SPPostgresBackgroundJob runOnDatabase:database provider:provider work:work completion:^(BOOL ok, NSError *error) {
		[progressSheet end];
		[job release];
		job = nil;
		[pendingConnector release];
		pendingConnector = nil;
		running = NO;
		// Whatever failed after Cancel (e.g. the statement the cancel interrupted) is the cancel
		NSError *outcome = error;
		if (!ok && [progress cancelled] && !([[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorCancelled)) outcome = SPPostgresImportCancelledError();
		done(ok, outcome);
	}] retain];
}

/// After a job: the document reloads when anything may have changed; an error (not a cancel, nor one the user
/// already answered with Stop) is shown.
- (void)_jobEndedWithSuccess:(BOOL)ok error:(NSError *)error changed:(BOOL)changed alreadyShown:(BOOL)alreadyShown
{
	if (changed) [document importDidChangeDatabase];
	if (ok && [completionNote length]) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"The import finished", @"Postgres import: finished with a note title")];
		[alert setInformativeText:completionNote];
		[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
		[document presentAlert:alert];
	}
	if (!ok) {
		BOOL cancelled = [[error domain] isEqualToString:SPPostgresErrorDomain] && [error code] == SPPostgresErrorCancelled;
		[self _setLastErrorMessage:[error localizedDescription] ?: NSLocalizedString(@"The import failed.", @"Postgres import: failed without a message")];
		if (!cancelled && !alreadyShown) [self _presentError:lastErrorMessage];
	}
	[self _finish];
}

/**
 * Asked on the job's thread after a failed statement in per-statement mode: errorChoiceProvider, or an alert on the
 * progress sheet (Stop, Ignore, Ignore All). *userStopped is set when the user saw the error and chose Stop.
 */
- (SPPostgresImportErrorChoice)_choiceForError:(NSError *)error progress:(SPPostgresProgressSheet *)progress userStopped:(BOOL *)userStopped
{
	if ([progress cancelled]) return SPPostgresImportStop;

	__block SPPostgresImportErrorChoice choice = SPPostgresImportStop;
	SPPostgresImportErrorChoice (^provider)(NSError *) = [[errorChoiceProvider retain] autorelease];
	if (provider) {
		dispatch_sync(dispatch_get_main_queue(), ^{
			choice = provider(error);
		});
	}
	else {
		dispatch_semaphore_t answered = dispatch_semaphore_create(0);
		NSString *message = [[[error localizedDescription] copy] autorelease];
		dispatch_async(dispatch_get_main_queue(), ^{
			if ([progress cancelled] || finished) {
				dispatch_semaphore_signal(answered);
				return;
			}
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setMessageText:NSLocalizedString(@"A statement failed", @"Postgres import: per-statement error title")];
			[alert setInformativeText:message ?: @""];
			[alert addButtonWithTitle:NSLocalizedString(@"Stop", @"Postgres import: stop after an error")];
			[alert addButtonWithTitle:NSLocalizedString(@"Ignore", @"Postgres import: ignore this error")];
			[alert addButtonWithTitle:NSLocalizedString(@"Ignore All", @"Postgres import: ignore every error")];
			[errorAlert release];
			errorAlert = [alert retain];
			[alert beginSheetModalForWindow:[progress panel] completionHandler:^(NSModalResponse response) {
				if (response == NSAlertSecondButtonReturn) choice = SPPostgresImportIgnore;
				else if (response == NSAlertThirdButtonReturn) choice = SPPostgresImportIgnoreAll;
				else choice = SPPostgresImportStop;
				[errorAlert release];
				errorAlert = nil;
				dispatch_semaphore_signal(answered);
			}];
		});
		dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
		dispatch_release(answered);
	}
	if (choice == SPPostgresImportStop && userStopped) *userStopped = YES;
	return choice;
}

- (void)_runSQLImportOfPath:(NSString *)path
{
	SPPostgresProgressSheet *progress = [self _beginProgressForPath:path];
	BOOL singleTransaction = [singleTransactionCheckbox state] == NSControlStateValueOn;
	__block NSUInteger statementsRun = 0;
	__block BOOL userStopped = NO;
	__block NSArray *skippedSettings = nil; // retained by the work

	[self _runJobWithProgress:progress work:^BOOL(PGPostgresConnection *connection, NSError **error) {
		if ([progress cancelled]) {
			if (error) *error = SPPostgresImportCancelledError();
			return NO;
		}
		SPPostgresDumpReader *reader = [[[SPPostgresDumpReader alloc] initWithPath:path error:error] autorelease];
		if (!reader) return NO;
		SPPostgresSQLImporter *importer = [[[SPPostgresSQLImporter alloc] initWithConnection:connection reader:reader] autorelease];
		[importer setSingleTransaction:singleTransaction];
		__block SPPostgresImportReportState reportState = {NO, 0, 0};
		[importer setProgress:^BOOL(unsigned long long bytesRead, unsigned long long fileSize) {
			return SPPostgresImportReport(progress, &reportState, bytesRead, fileSize);
		}];
		[importer setErrorHandler:^SPPostgresImportErrorChoice(NSError *statementError, SPPostgresDumpItem *item) {
			return [self _choiceForError:statementError progress:progress userStopped:&userStopped];
		}];
		BOOL ok = [importer run:error];
		statementsRun = [importer statementsRun];
		skippedSettings = [[importer skippedSettings] retain];
		return ok;
	} completion:^(BOOL ok, NSError *error) {
		NSArray *skipped = [skippedSettings autorelease];
		skippedSettings = nil;
		if (ok && [skipped count]) {
			NSString *names = [skipped componentsJoinedByString:@", "];
			NSString *note = [skipped count] == 1
				? [NSString stringWithFormat:NSLocalizedString(@"1 setting this server doesn't know was skipped: %@.", @"Postgres import: one unknown SET skipped (name)"), names]
				: [NSString stringWithFormat:NSLocalizedString(@"%lu settings this server doesn't know were skipped: %@.", @"Postgres import: unknown SETs skipped (count, names)"), (unsigned long)[skipped count], names];
			[completionNote release];
			completionNote = [note copy];
		}
		// In per-statement mode what ran stays committed, even after an error or a cancel
		BOOL changed = ok || (!singleTransaction && statementsRun > 0);
		[self _jobEndedWithSuccess:ok error:error changed:changed alreadyShown:userStopped];
	}];
}

- (void)_runCSVImportOfPath:(NSString *)path options:(SPPostgresCSVOptions *)options schema:(NSString *)schema table:(NSString *)table mapping:(NSArray *)mapping
{
	SPPostgresProgressSheet *progress = [self _beginProgressForPath:path];
	[self _runJobWithProgress:progress work:^BOOL(PGPostgresConnection *connection, NSError **error) {
		if ([progress cancelled]) {
			if (error) *error = SPPostgresImportCancelledError();
			return NO;
		}
		__block SPPostgresImportReportState reportState = {NO, 0, 0};
		return [SPPostgresCSV importPath:path options:options intoTable:table schema:schema columnMapping:mapping connection:connection
								progress:^BOOL(unsigned long long bytesRead, unsigned long long fileSize) {
			return SPPostgresImportReport(progress, &reportState, bytesRead, fileSize);
		} error:error];
	} completion:^(BOOL ok, NSError *error) {
		[self _jobEndedWithSuccess:ok error:error changed:ok alreadyShown:NO];
	}];
}

@end
