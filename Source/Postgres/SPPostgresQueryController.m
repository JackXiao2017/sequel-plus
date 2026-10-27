#import "SPPostgresQueryController.h"
#import "SPPostgresStatementSplitter.h"
#import "SPPostgresConsoleLogger.h"
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

#pragma mark - Controller

@interface SPPostgresQueryController ()

@property (readwrite, copy) NSString *statusText;

@end

@implementation SPPostgresQueryController
{
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

	BOOL running;
	BOOL invalidated;

	/// Test seam: called before each statement runs (see the tests' SPPostgresQueryController (Testing))
	void (^statementWillRunHook)(NSString *statement);
}

@synthesize editor;
@synthesize resultsView;
@synthesize statusText;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		statusText = [@"" copy];
		[self _buildView];
	}

	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
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

- (IBAction)runAllQueries:(id)sender
{
	if (invalidated) return;
	[self _runStatements:[SPPostgresStatementSplitter statementsInSQL:[editor string]]];
}

- (IBAction)runCurrentQuery:(id)sender
{
	if (invalidated) return;

	NSString *text = [editor string];
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
- (NSString *)_rowCountText:(unsigned long long)count affected:(BOOL)affected
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
 * Notes an aborted transaction after the message.
 */
- (NSString *)_errorTextForStatement:(NSUInteger)number error:(PGPostgresError *)error fallback:(NSString *)fallback
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

	NSString *detail = [[error errorDetailMessage] stringByTrimmingCharactersInSet:whitespace];
	NSString *hint = [[error errorMessageHint] stringByTrimmingCharactersInSet:whitespace];
	if ([detail length]) [text appendFormat:@"\n%@ %@", NSLocalizedString(@"DETAIL:", @"Postgres query: error detail label"), detail];
	if ([hint length]) [text appendFormat:@"\n%@ %@", NSLocalizedString(@"HINT:", @"Postgres query: error hint label"), hint];

	return text;
}

/**
 * Runs the statements in order. The grid shows the last row set; the first error stops the run. The status
 * line describes the last statement run, and says which statement the grid's rows come from when it isn't
 * that one.
 */
- (void)_runStatements:(NSArray *)statements
{
	if (invalidated || running || ![statements count]) return;

	// Hold on: an action may arrive from a view whose tab closes while the run's alerts or callbacks spin
	[[self retain] autorelease];

	SPPostgresConsoleLogger *logger = [SPPostgresConsoleLogger loggerForConnection:connection];
	BOOL wasLoggingCustomQueries = [logger loggingCustomQueries];

	NSString *status = @"";
	NSUInteger number = 0;
	NSUInteger shownStatement = 0; // the statement whose rows the grid shows (0: none)

	running = YES;
	[logger setLoggingCustomQueries:YES];

	// Whatever happens (an exception from AppKit or a hook), the next run must be possible and the
	// interface's own queries logged as such again
	@try {
		[self _showResult:nil];

		for (NSString *statement in statements) {
			number++;

			if (statementWillRunHook) statementWillRunHook(statement);

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
				PGPostgresError *error = [connection lastError];
				if (error == previousError) error = nil;

				NSString *fallback = exceptionReason;
				if (![fallback length] && ![connection isConnected]) fallback = NSLocalizedString(@"The connection to the PostgreSQL server was lost.", @"Postgres query: connection lost");
				if (![fallback length]) fallback = [connection libpqErrorMessage];

				status = [self _errorTextForStatement:number error:error fallback:fallback];
				[logger logError:status];
				break;
			}

			if ([statementResult returnsRows]) {
				[self _showResult:statementResult];
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
		}
	}
	@finally {
		[logger setLoggingCustomQueries:wasLoggingCustomQueries];
		running = NO;

		[self setStatusText:status];
		[statusField setStringValue:status];
		[statusField setToolTip:status];
	}
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
