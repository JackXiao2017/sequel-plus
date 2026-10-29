#import "SPPostgresQueryController.h"
#import "SPPostgresStatementSplitter.h"
#import "SPPostgresConsoleLogger.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTaskRunner.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPConstants.h"
#import <PostgresKit/PostgresKit.h>

// MySQL's Query tab (DBView.xib): the run bar above the results, 23 pt status bar below them
static const CGFloat SPPostgresQueryRunBarHeight = 30;
static const CGFloat SPPostgresQueryStatusBarHeight = 23;

// Column widths fitted to the header and the first rows, as the Content view's
static const CGFloat SPPostgresQueryMinColumnWidth = 40;
static const CGFloat SPPostgresQueryMaxColumnWidth = 300;
static const NSUInteger SPPostgresQueryWidthSampleRows = 100;

#pragma mark - View

/**
 * The Query view's root: handles MySQL's run keys while it is in a window, before the editor or anything else
 * sees them: ⌘R runs the primary action and ⌥⌘R the secondary one (as DBView.xib's run popup). By default
 * the primary action is Run Current; MySQL's "QueryPrimaryControlRunsAll" preference makes it Run All
 * (read at each key press, so a change applies at once). Other keys (e.g. ⇧⌘R, Refresh Databases) pass on.
 */
@interface SPPostgresQueryView : NSView
@property (assign) SPPostgresQueryController *controller;
@end

@implementation SPPostgresQueryView

@synthesize controller;

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
	if (controller && [event type] == NSEventTypeKeyDown && [self window] && ![self isHiddenOrHasHiddenAncestor]) {
		NSEventModifierFlags flags = [event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
		if ([[[event charactersIgnoringModifiers] lowercaseString] isEqualToString:@"r"]) {
			BOOL primary = (flags == NSEventModifierFlagCommand);
			BOOL secondary = (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption));
			if (primary || secondary) {
				BOOL primaryRunsAll = [[NSUserDefaults standardUserDefaults] boolForKey:SPQueryPrimaryControlRunsAll];
				if (![event isARepeat]) {
					if (primary == primaryRunsAll) [controller runAllQueries:self];
					else [controller runCurrentQuery:self];
				}
				return YES;
			}
		}
	}

	return [super performKeyEquivalent:event];
}

@end

#pragma mark - Run

/**
 * What one run produced. The work fills it in on the runner's thread, statement by statement; the completion reads
 * it on the main thread once the work has returned (also after a cancel, so what ran before it is still shown).
 */
@interface SPPostgresQueryRun : NSObject
/// The last row set returned (nil: none).
@property (retain) PGPostgresResult *rowsResult;
/// The status line for the last statement run (@"" before the first).
@property (copy) NSString *status;
@property (assign) BOOL schemaChanged;
@property (assign) BOOL dataChanged;
/// The run stopped because the runner was cancelled (as MySQL's lastQueryWasCancelled: not when the cancel came after
/// every statement had run).
@property (assign) BOOL cancelled;
/// The work ran (NO: the runner skipped it, cancelled before it started).
@property (assign) BOOL started;
/// Raised during the run (e.g. by the test hook); the run stopped there.
@property (retain) NSException *exception;
/// The session's transaction status once the work had run (read on the runner's thread, where nothing else runs)
@property (assign) PGPostgresTransactionStatus transactionStatus;
@end

@implementation SPPostgresQueryRun

@synthesize rowsResult;
@synthesize status;
@synthesize schemaChanged;
@synthesize dataChanged;
@synthesize cancelled;
@synthesize started;
@synthesize exception;
@synthesize transactionStatus;

- (instancetype)init
{
	if ((self = [super init])) status = [@"" copy];
	return self;
}

- (void)dealloc
{
	[rowsResult release];
	[status release];
	[exception release];
	[super dealloc];
}

@end

#pragma mark - Controller

@interface SPPostgresQueryController ()

@property (readwrite, copy) NSString *statusText;

@end

@implementation SPPostgresQueryController
{
	PGPostgresTransactionStatus lastRunTransactionStatus;
	PGPostgresConnection *connection;

	/// The row set the grid shows (nil: none). Values are read from it as the grid draws.
	PGPostgresResult *result;
	NSUInteger resultRowCount;

	SPPostgresQueryView *view;
	NSSplitView *splitView;
	NSTextView *editor;
	SPTableView *resultsView;
	NSButton *runAllButton;
	NSButton *runCurrentButton;
	NSTextField *statusField;

	BOOL running;                   // YES from a run's enqueue until its completion
	BOOL invalidated;

	/// Test seam: called on the runner's thread before each statement runs (see the tests' SPPostgresQueryController (Testing))
	void (^statementWillRunHook)(NSString *statement);
}

@synthesize editor;
@synthesize resultsView;
@synthesize statusText;
@synthesize runDidChangeDatabase;
@synthesize lastRunTransactionStatus;
@synthesize taskRunner;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		taskRunner = [[SPPostgresTaskRunner inlineRunnerWithConnection:theConnection] retain];
		statusText = [@"" copy];
		[self _buildView];
	}

	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[taskRunner release];
	[result release];
	[statusText release];

	[view release];
	[splitView release];
	[editor release];
	[resultsView release];
	[runAllButton release];
	[runCurrentButton release];
	[statusField release];
	[statementWillRunHook release];
	[runDidChangeDatabase release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;

	[view setController:nil];
	[resultsView setDataSource:nil];
	[resultsView setDelegate:nil];
	[runAllButton setTarget:nil];
	[runCurrentButton setTarget:nil];
	// Tooltip owners aren't retained
	[runAllButton removeAllToolTips];
	[runCurrentButton removeAllToolTips];

	// The block may capture the tab
	[runDidChangeDatabase release];
	runDidChangeDatabase = nil;
}

#pragma mark - Statement kinds

/// The statement without leading whitespace and comments (-- … and /* … */, nested as PostgreSQL allows).
+ (NSString *)_statementBody:(NSString *)statement
{
	NSString *rest = statement ?: @"";
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	while (YES) {
		rest = [rest stringByTrimmingCharactersInSet:whitespace];
		if ([rest hasPrefix:@"--"]) {
			NSRange newline = [rest rangeOfString:@"\n"];
			rest = (newline.location == NSNotFound) ? @"" : [rest substringFromIndex:NSMaxRange(newline)];
		}
		else if ([rest hasPrefix:@"/*"]) {
			NSUInteger depth = 0, i = 0, length = [rest length];
			for (; i + 1 < length; i++) {
				unichar a = [rest characterAtIndex:i], b = [rest characterAtIndex:i + 1];
				if (a == '/' && b == '*') { depth++; i++; }
				else if (a == '*' && b == '/') { i++; if (--depth == 0) break; }
			}
			rest = (depth == 0 && i + 1 <= length) ? [rest substringFromIndex:MIN(i + 1, length)] : @"";
		}
		else {
			return rest;
		}
	}
}

/// The statement's first keyword, lowercased (@"" if none).
+ (NSString *)_firstKeyword:(NSString *)statement
{
	NSString *body = [self _statementBody:statement];
	NSUInteger end = 0, length = [body length];
	NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
	while (end < length && [letters characterIsMember:[body characterAtIndex:end]]) end++;
	return [[body substringToIndex:end] lowercaseString];
}

+ (BOOL)statementMayChangeSchema:(NSString *)statement
{
	static NSSet *keywords = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// MySQL's (SPCustomQuery: create|alter|drop|rename), and PostgreSQL's transactional DDL undone or imported
		keywords = [[NSSet alloc] initWithObjects:@"create", @"alter", @"drop", @"rename", @"import", @"rollback", @"abort", nil];
	});
	return [keywords containsObject:[self _firstKeyword:statement]];
}

+ (BOOL)statementMayChangeData:(NSString *)statement
{
	static NSSet *readOnly = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		readOnly = [[NSSet alloc] initWithObjects:@"select", @"show", @"explain", @"values", @"table", nil];
	});
	NSString *keyword = [self _firstKeyword:statement];
	return [keyword length] && ![readOnly containsObject:keyword];
}

/// Test seam (see statementWillRunHook).
- (void)setStatementWillRunHook:(void (^)(NSString *statement))hook
{
	if (hook == statementWillRunHook) return;
	[statementWillRunHook release];
	statementWillRunHook = [hook copy];
}

#pragma mark - Tooltips

/// The run buttons' tooltips, with the key that runs each as MySQL's run preference has it.
- (NSString *)view:(NSView *)theView stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data
{
	BOOL primaryRunsAll = [[NSUserDefaults standardUserDefaults] boolForKey:SPQueryPrimaryControlRunsAll];

	if (theView == runAllButton) {
		return [NSString stringWithFormat:NSLocalizedString(@"Run all queries (%@)", @"Postgres query: run all tooltip (key)"), primaryRunsAll ? @"⌘R" : @"⌥⌘R"];
	}
	if (theView == runCurrentButton) {
		return [NSString stringWithFormat:NSLocalizedString(@"Run the query at the cursor, or the selected queries (%@)", @"Postgres query: run current tooltip (key)"), primaryRunsAll ? @"⌥⌘R" : @"⌘R"];
	}
	return @"";
}

+ (NSFont *)editorFontFromPreferenceData:(NSData *)data
{
	// As MySQL's SPTextView reads it
	NSFont *font = nil;
	if ([data length]) {
		@try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			font = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
		}
		@catch (NSException *exception) {
			font = nil;
		}
	}
	if (![font isKindOfClass:[NSFont class]]) font = [NSFont monospacedSystemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightRegular];
	return font;
}

/// MySQL's query editor font, or the monospaced system font.
- (NSFont *)_editorFont
{
	return [[self class] editorFontFromPreferenceData:[[NSUserDefaults standardUserDefaults] dataForKey:SPCustomQueryEditorFont]];
}

/// MySQL's result table font, or the small system font (as the Content view).
- (NSFont *)_tableFont
{
	NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:SPGlobalResultTableFont];
	NSFont *font = nil;
	if (data) {
		@try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			font = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
		}
		@catch (NSException *exception) {
			font = nil;
		}
	}
	if (![font isKindOfClass:[NSFont class]]) font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	return font;
}

- (NSString *)_nullPlaceholder
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:SPNullValue] ?: @"NULL";
}

- (NSButton *)_newRunButtonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame
{
	NSButton *button = [[NSButton alloc] initWithFrame:frame];
	[button setBezelStyle:NSBezelStyleRounded];
	[[button cell] setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[button setTitle:title];
	[button setAutoresizingMask:NSViewMinXMargin];
	// Asked when shown (see -view:stringForToolTip:point:userData:): the keys follow MySQL's run preference
	[button addToolTipRect:[button bounds] owner:self userData:NULL];
	[button setTarget:self];
	[button setAction:action];
	return button;
}

/// Editor | (run bar, results, status bar), split as MySQL's Query tab.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	view = [[SPPostgresQueryView alloc] initWithFrame:frame];
	[view setController:self];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	CGFloat width = NSWidth(frame);

	splitView = [[NSSplitView alloc] initWithFrame:frame];
	[splitView setVertical:NO];
	[splitView setDividerStyle:NSSplitViewDividerStyleThin];
	[splitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// Editor
	CGFloat editorHeight = 200;
	NSScrollView *editorScrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, editorHeight)] autorelease];
	[editorScrollView setHasVerticalScroller:YES];
	[editorScrollView setHasHorizontalScroller:NO];
	[editorScrollView setAutohidesScrollers:YES];
	[editorScrollView setBorderType:NSNoBorder];
	[editorScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSSize contentSize = [editorScrollView contentSize];
	editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
	[editor setMinSize:NSMakeSize(0, contentSize.height)];
	[editor setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[editor setVerticallyResizable:YES];
	[editor setHorizontallyResizable:NO];
	[editor setAutoresizingMask:NSViewWidthSizable];
	[[editor textContainer] setContainerSize:NSMakeSize(contentSize.width, CGFLOAT_MAX)];
	[[editor textContainer] setWidthTracksTextView:YES];
	[editor setRichText:NO];
	[editor setImportsGraphics:NO];
	[editor setAllowsUndo:YES];
	[editor setUsesFindBar:YES];
	[editor setAutomaticQuoteSubstitutionEnabled:NO];
	[editor setAutomaticDashSubstitutionEnabled:NO];
	[editor setAutomaticTextReplacementEnabled:NO];
	[editor setAutomaticSpellingCorrectionEnabled:NO];
	[editor setAutomaticLinkDetectionEnabled:NO];
	[editor setAutomaticDataDetectionEnabled:NO];
	[editor setContinuousSpellCheckingEnabled:NO];
	[editor setGrammarCheckingEnabled:NO];
	[editor setSmartInsertDeleteEnabled:NO];
	[editor setTextContainerInset:NSMakeSize(2, 4)];
	NSFont *editorFont = [self _editorFont];
	[editor setFont:editorFont];
	[editor setTypingAttributes:@{NSFontAttributeName: editorFont, NSForegroundColorAttributeName: [NSColor textColor]}];
	[editorScrollView setDocumentView:editor];
	[splitView addSubview:editorScrollView];

	// Run bar, results, status bar
	CGFloat lowerHeight = NSHeight(frame) - editorHeight - [splitView dividerThickness];
	NSView *lower = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, lowerHeight)] autorelease];
	[lower setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSView *runBar = [[[NSView alloc] initWithFrame:NSMakeRect(0, lowerHeight - SPPostgresQueryRunBarHeight, width, SPPostgresQueryRunBarHeight)] autorelease];
	[runBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];

	// MySQL's keys, ⌘R (primary) and ⌥⌘R (secondary), are handled by the view (see SPPostgresQueryView), the
	// single place that follows MySQL's run preference; the buttons have no key equivalents of their own
	runAllButton = [self _newRunButtonWithTitle:NSLocalizedString(@"Run All", @"run all button")
										 action:@selector(runAllQueries:)
										  frame:NSMakeRect(width - 98, 4, 90, 22)];

	runCurrentButton = [self _newRunButtonWithTitle:NSLocalizedString(@"Run Current", @"Postgres query: run current button")
											 action:@selector(runCurrentQuery:)
											  frame:NSMakeRect(width - 98 - 100, 4, 100, 22)];

	[runBar addSubview:runCurrentButton];
	[runBar addSubview:runAllButton];
	[lower addSubview:runBar];

	NSScrollView *resultsScrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, SPPostgresQueryStatusBarHeight, width, lowerHeight - SPPostgresQueryStatusBarHeight - SPPostgresQueryRunBarHeight)] autorelease];
	[resultsScrollView setHasVerticalScroller:YES];
	[resultsScrollView setHasHorizontalScroller:YES];
	[resultsScrollView setAutohidesScrollers:YES];
	[resultsScrollView setBorderType:NSNoBorder];
	[resultsScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	resultsView = [[SPTableView alloc] initWithFrame:[[resultsScrollView contentView] bounds]];
	[resultsView setUsesAlternatingRowBackgroundColors:YES];
	[resultsView setAllowsMultipleSelection:YES];
	[resultsView setAllowsColumnReordering:YES];
	[resultsView setColumnAutoresizingStyle:NSTableViewNoColumnAutoresizing];
	[resultsView setFocusRingType:NSFocusRingTypeNone];
	[resultsView setGridStyleMask:[[NSUserDefaults standardUserDefaults] boolForKey:SPDisplayTableViewVerticalGridlines] ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	[resultsView setDataSource:self];
	[resultsView setDelegate:self];
	[resultsScrollView setDocumentView:resultsView];
	[lower addSubview:resultsScrollView];

	SPButtonBar *statusBar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresQueryStatusBarHeight)] autorelease];
	[statusBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 4, width - 16, 14)];
	[statusField setEditable:NO];
	[statusField setSelectable:YES];
	[statusField setBordered:NO];
	[statusField setDrawsBackground:NO];
	[statusField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[statusField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[statusField setAutoresizingMask:NSViewWidthSizable];
	[statusField setStringValue:@""];
	[statusBar addSubview:statusField];
	[lower addSubview:statusBar];

	[splitView addSubview:lower];
	[splitView adjustSubviews];
	[view addSubview:splitView];
}

- (NSView *)view
{
	return view;
}

#pragma mark - Running

/// The user's run keys and buttons do nothing while the runner is busy (one query at a time on the connection).
- (BOOL)_refuseRunWhileBusy
{
	if (!running && ![taskRunner isBusy]) return NO;
	NSBeep();
	return YES;
}

/// Ends the editor's input in progress (an input method's marked text) before its text is read for a run.
- (void)_endEditing
{
	if ([editor hasMarkedText]) [editor unmarkText];
	[editor breakUndoCoalescing];
}

- (IBAction)runAllQueries:(id)sender
{
	if (invalidated || [self _refuseRunWhileBusy]) return;
	[self _endEditing];
	[self _runStatements:[SPPostgresStatementSplitter statementsInSQL:[[[editor string] copy] autorelease]]];
}

- (IBAction)runCurrentQuery:(id)sender
{
	if (invalidated || [self _refuseRunWhileBusy]) return;
	[self _endEditing];

	NSString *text = [[[editor string] copy] autorelease];
	NSRange selection = [editor selectedRange];
	NSArray *statements = nil;

	if (selection.length && NSMaxRange(selection) <= [text length]) {
		statements = [SPPostgresStatementSplitter statementsInSQL:[text substringWithRange:selection]];
	}
	else {
		NSRange range = [SPPostgresStatementSplitter rangeOfStatementAtLocation:selection.location inSQL:text];
		if (range.location != NSNotFound) statements = [SPPostgresStatementSplitter statementsInSQL:[text substringWithRange:range]];
	}

	if (![statements count]) {
		NSBeep();
		return;
	}

	[self _runStatements:statements];
}

/// "1 row" / "N rows", or with " affected".
+ (NSString *)_rowCountText:(unsigned long long)count affected:(BOOL)affected
{
	if (affected) {
		if (count == 1) return NSLocalizedString(@"1 row affected", @"Postgres query: one row affected");
		return [NSString stringWithFormat:NSLocalizedString(@"%llu rows affected", @"Postgres query: rows affected"), count];
	}
	if (count == 1) return NSLocalizedString(@"1 row", @"Postgres query: one row");
	return [NSString stringWithFormat:NSLocalizedString(@"%llu rows", @"Postgres query: rows"), count];
}

/**
 * The status line text for a failed statement: the server's message, then its DETAIL and HINT lines (as psql).
 * Notes an aborted transaction after the message. Called on the thread that ran the statement on connection.
 */
+ (NSString *)_errorTextForStatement:(NSUInteger)number error:(PGPostgresError *)error fallback:(NSString *)fallback connection:(PGPostgresConnection *)connection
{
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *message = [[error errorPrimaryMessage] stringByTrimmingCharactersInSet:whitespace];
	if (![message length]) message = [fallback stringByTrimmingCharactersInSet:whitespace];
	if (![message length]) message = NSLocalizedString(@"An unknown error occurred.", @"Postgres query: unknown error");

	NSMutableString *text = [NSMutableString stringWithFormat:NSLocalizedString(@"Error in statement %lu: %@", @"Postgres query: error in statement (number, server message)"), (unsigned long)number, message];

	// The user's own BEGIN … : nothing more runs in it until they roll back
	if ([connection transactionStatus] == PGPostgresTransactionInError) {
		[text appendString:NSLocalizedString(@" – the current transaction is aborted; ROLLBACK to continue", @"Postgres query: aborted transaction note")];
	}

	[text appendString:SPPostgresErrorDetailLines(error)];

	return text;
}

/**
 * The work of a run, on the runner's thread: runs the statements in order on connection, filling in run as it goes.
 * The first error stops the run, as does a cancel (between statements, or interrupting one). Uses only its
 * arguments (a class method: never the controller's views or state).
 */
+ (void)_runStatements:(NSArray *)statements onConnection:(PGPostgresConnection *)connection runner:(SPPostgresTaskRunner *)runner
				logger:(SPPostgresConsoleLogger *)logger hook:(void (^)(NSString *statement))hook into:(SPPostgresQueryRun *)run
{
	NSUInteger total = [statements count];
	NSUInteger number = 0;
	NSUInteger shownStatement = 0; // the statement whose rows the grid will show (0: none)

	[run setStarted:YES];

	// The run's own statements, and only them, are logged as custom queries: the flag is set and restored here, on
	// the thread that runs them (the logger reads it there, as each query is about to run), so the next task on the
	// runner is logged as an interface query again even before this run's completion reaches the main thread. This
	// work owns the flag: nothing on the main thread sets or restores it.
	BOOL wasLoggingCustomQueries = [logger loggingCustomQueries];
	[logger setLoggingCustomQueries:YES];

	// An exception (from the hook, or a lost connection's) stops the run like an error: what ran is still shown
	@try {
		for (NSString *statement in statements) {
			if ([runner isCancelled]) {
				[run setCancelled:YES];
				break;
			}
			number++;

			if (total > 1) {
				[runner updateDescription:[NSString stringWithFormat:NSLocalizedString(@"Running query %ld of %lu...", @"Running multiple queries string"), (long)number, (unsigned long)total]];
			}

			if (hook) hook(statement);

			// A new error object is made for each failed query: compare with the previous one to know if this
			// statement left one (a lost connection may leave none)
			PGPostgresError *previousError = [[[connection lastError] retain] autorelease];
			PGPostgresResult *statementResult = nil;
			NSString *exceptionReason = nil;

			@try {
				statementResult = [connection execute:statement];
			}
			@catch (NSException *exception) {
				statementResult = nil;
				exceptionReason = [exception reason];
			}

			if (!statementResult) {
				// Interrupted by a cancel: not an error to report
				if ([runner isCancelled]) {
					[run setCancelled:YES];
					break;
				}

				PGPostgresError *error = [connection lastError];
				if (error == previousError) error = nil;

				NSString *fallback = exceptionReason;
				if (![fallback length] && ![connection isConnected]) fallback = NSLocalizedString(@"The connection to the PostgreSQL server was lost.", @"Postgres query: connection lost");
				if (![fallback length]) fallback = [connection libpqErrorMessage];

				NSString *status = [self _errorTextForStatement:number error:error fallback:fallback connection:connection];
				[run setStatus:status];
				[logger logError:status];
				break;
			}

			if (![run schemaChanged]) [run setSchemaChanged:[self statementMayChangeSchema:statement]];
			if (![run dataChanged]) [run setDataChanged:[self statementMayChangeData:statement]];

			NSString *status;
			if ([statementResult returnsRows]) {
				[run setRowsResult:statementResult];
				shownStatement = number;
				status = [self _rowCountText:[statementResult numberOfRows] affected:NO];
			}
			else if ([statementResult copyOutputDiscarded]) {
				status = [NSString stringWithFormat:NSLocalizedString(@"%@ – output not shown", @"Postgres query: COPY TO STDOUT status (command status)"), [statementResult commandStatus]];
			}
			else {
				status = [self _rowCountText:[statementResult numberOfRows] affected:YES];
			}

			// After a SELECT, a command: the rows are the earlier statement's
			if (shownStatement && shownStatement != number) {
				status = [status stringByAppendingFormat:NSLocalizedString(@" – results shown from statement %lu", @"Postgres query: rows are from an earlier statement (number)"), (unsigned long)shownStatement];
			}
			[run setStatus:status];
		}
	}
	@catch (NSException *exception) {
		[run setException:exception];
	}
	@finally {
		[logger setLoggingCustomQueries:wasLoggingCustomQueries];
	}
}

/**
 * Runs the statements in order through the task runner. The grid shows the last row set; the first error stops
 * the run. The status line describes the last statement run, and says which statement the grid's rows come from
 * when it isn't that one. Cancelled, the grid shows the last row set returned before the cancel and the status line
 * says "Query cancelled."; what ran before the cancel is still reported through runDidChangeDatabase.
 */
- (void)_runStatements:(NSArray *)statements
{
	if (invalidated || running || [taskRunner isBusy] || ![statements count]) return;

	// Hold on: an action may arrive from a view whose tab closes while the run's alerts or callbacks spin (the
	// inline runner calls the completion before the blocks are copied)
	[[self retain] autorelease];

	SPPostgresTaskRunner *runner = taskRunner;
	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:[runner connection]];

	running = YES;

	// Everything the work needs, so it never reads this controller
	NSArray *theStatements = [[statements copy] autorelease];
	void (^hook)(NSString *) = [[statementWillRunHook copy] autorelease];
	SPPostgresQueryRun *run = [[[SPPostgresQueryRun alloc] init] autorelease];
	NSUInteger total = [theStatements count];

	NSString *description = (total > 1)
		? [NSString stringWithFormat:NSLocalizedString(@"Running query %ld of %lu...", @"Running multiple queries string"), 1L, (unsigned long)total]
		: NSLocalizedString(@"Running query...", @"Running single query string");
	NSString *cancelTitle = (total > 1) ? NSLocalizedString(@"Stop queries", @"Stop queries string") : NSLocalizedString(@"Stop query", @"Stop query string");

	[runner runTaskWithDescription:description cancelTitle:cancelTitle work:^id(PGPostgresConnection *theConnection, NSError **error) {
		[SPPostgresQueryController _runStatements:theStatements onConnection:theConnection runner:runner logger:logger hook:hook into:run];
		[run setTransactionStatus:[theConnection transactionStatus]];
		return run;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		// Whatever happens, the next run is possible (the work restored the logging flag itself)
		running = NO;

		// Raised on the runner's thread: the inline runner's caller rethrows it below; otherwise it is reported here
		if ([run exception] && ![runner isInline]) [NSApp reportException:[run exception]];

		if (invalidated) return;

		// "Query cancelled." only when the cancel stopped the run (as MySQL's lastQueryWasCancelled), or kept it from
		// starting; a cancel after every statement had run keeps the run's own status
		BOOL stopped = [run cancelled] || (cancelled && ![run started]);
		NSString *status = stopped ? NSLocalizedString(@"Query cancelled.", @"Query cancelled error") : ([run status] ?: @"");
		[self _showResult:[run rowsResult]];
		lastRunTransactionStatus = [run transactionStatus];
		[self setStatusText:status];
		[statusField setStringValue:status];
		[statusField setToolTip:status];

		// As MySQL's Query tab: the tab reloads what the run may have changed (also what ran before a cancel)
		if (([run schemaChanged] || [run dataChanged]) && runDidChangeDatabase) runDidChangeDatabase([run schemaChanged], [run dataChanged]);
	}];

	// As before the runner: an exception raised during an inline run reaches the action's caller, once the state is restored
	if ([runner isInline] && [run exception]) @throw [run exception];
}

#pragma mark - Results

/// Shows theResult's rows (nil: an empty grid without columns).
- (void)_showResult:(PGPostgresResult *)theResult
{
	if (theResult != result) {
		[result release];
		result = [theResult retain];
	}
	resultRowCount = result ? (NSUInteger)[result numberOfRows] : 0;

	while ([[resultsView tableColumns] count]) [resultsView removeTableColumn:[[resultsView tableColumns] lastObject]];

	NSFont *font = [self _tableFont];
	[resultsView setRowHeight:2.0f + ceil([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : font}].height)];

	NSArray *fields = [result fields];
	NSDictionary *attributes = @{NSFontAttributeName : font};
	NSDictionary *headerAttributes = @{NSFontAttributeName : [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]};
	NSString *nullPlaceholder = [self _nullPlaceholder];
	NSUInteger sampleCount = MIN(resultRowCount, SPPostgresQueryWidthSampleRows);

	for (NSUInteger index = 0; index < [fields count]; index++) {
		id field = [fields objectAtIndex:index];
		NSString *name = [field isKindOfClass:[NSString class]] ? field : @"";

		NSTableColumn *tableColumn = [[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)index]] autorelease];
		[[tableColumn headerCell] setStringValue:name];
		[tableColumn setHeaderToolTip:name];
		[tableColumn setEditable:NO];
		[tableColumn setResizingMask:NSTableColumnUserResizingMask];
		[tableColumn setMinWidth:SPPostgresQueryMinColumnWidth];

		NSTextFieldCell *cell = [[[NSTextFieldCell alloc] initTextCell:@""] autorelease];
		[cell setEditable:NO];
		[cell setLineBreakMode:NSLineBreakByTruncatingTail];
		[cell setFont:font];
		[tableColumn setDataCell:cell];

		// As wide as the header and the first rows, within limits
		CGFloat columnWidth = [name sizeWithAttributes:headerAttributes].width + 16;
		for (NSUInteger row = 0; row < sampleCount && columnWidth < SPPostgresQueryMaxColumnWidth; row++) {
			id value = [result textValueAtRow:row column:index];
			NSString *string = [value isKindOfClass:[NSString class]] ? value : nullPlaceholder;
			if ([string length] > 200) string = [string substringToIndex:200];
			columnWidth = MAX(columnWidth, [string sizeWithAttributes:attributes].width + 8);
		}
		[tableColumn setWidth:MIN(MAX(ceil(columnWidth), SPPostgresQueryMinColumnWidth), SPPostgresQueryMaxColumnWidth)];

		[resultsView addTableColumn:tableColumn];
	}

	[resultsView deselectAll:nil];
	[resultsView reloadData];
	[resultsView scrollRowToVisible:0];
}

- (id)_valueAtRow:(NSInteger)rowIndex tableColumn:(NSTableColumn *)tableColumn
{
	if (!result || rowIndex < 0 || (NSUInteger)rowIndex >= resultRowCount) return nil;
	NSInteger column = [[tableColumn identifier] integerValue];
	if (column < 0) return nil;
	return [result textValueAtRow:(unsigned long long)rowIndex column:(NSUInteger)column];
}

- (NSArray *)lastResultColumnNames
{
	if (!result) return nil;
	NSMutableArray *names = [NSMutableArray array];
	for (id field in [result fields]) [names addObject:[field isKindOfClass:[NSString class]] ? field : @""];
	return names;
}

- (NSUInteger)lastResultRowCount
{
	return result ? resultRowCount : 0;
}

- (NSArray *)lastResultRows
{
	if (!result) return nil;
	NSUInteger columnCount = [[result fields] count];
	NSMutableArray *rows = [NSMutableArray arrayWithCapacity:resultRowCount];
	for (NSUInteger row = 0; row < resultRowCount; row++) {
		NSMutableArray *values = [NSMutableArray arrayWithCapacity:columnCount];
		for (NSUInteger column = 0; column < columnCount; column++) {
			id value = [result textValueAtRow:row column:column];
			[values addObject:[value isKindOfClass:[NSString class]] ? value : [NSNull null]];
		}
		[rows addObject:values];
	}
	return rows;
}

#pragma mark - Table view data source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)theTableView
{
	return (NSInteger)resultRowCount;
}

- (id)tableView:(NSTableView *)theTableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	id value = [self _valueAtRow:rowIndex tableColumn:tableColumn];
	if (!value) return nil;
	if (![value isKindOfClass:[NSString class]]) return [self _nullPlaceholder];

	// Very long values are cut for display (the grid draws one line)
	NSString *string = value;
	return [string length] > 10000 ? [string substringToIndex:10000] : string;
}

#pragma mark - Table view delegate

- (BOOL)tableView:(NSTableView *)theTableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	return NO;
}

- (void)tableView:(NSTableView *)theTableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (![cell respondsToSelector:@selector(setTextColor:)]) return;

	// As MySQL's grid: NULL in grey, except in the selected rows
	id value = [self _valueAtRow:rowIndex tableColumn:tableColumn];
	BOOL isNull = value && ![value isKindOfClass:[NSString class]];
	[cell setTextColor:(isNull && ![theTableView isRowSelected:rowIndex]) ? [NSColor lightGrayColor] : [NSColor controlTextColor]];
}

@end
