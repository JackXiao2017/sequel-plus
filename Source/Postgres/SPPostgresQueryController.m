#import "SPPostgresQueryController.h"
#import "SPPostgresStatementSplitter.h"
#import "SPPostgresConsoleLogger.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTaskRunner.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPSplitView.h"
#import "SPComboPopupButton.h"
#import "SPConstants.h"
#import <PostgresKit/PostgresKit.h>

// MySQL's Query tab (DBView.xib): 23 pt bars, at the top of the results and at the bottom of the tab
static const CGFloat SPPostgresQueryBarHeight = 23;
// The query information pane's height (DBView.xib), and the editor's and results' minimum heights
static const CGFloat SPPostgresQueryInfoPaneHeight = 119;
static const CGFloat SPPostgresQueryMinPaneHeight = 100;

// The run pop-up button's items (DBView.xib): the primary run item, the secondary one
static const NSInteger SPPostgresQueryPrimaryRunTag = 2;
static const NSInteger SPPostgresQuerySecondaryRunTag = 1;

static void *SPPostgresQueryRunnerContext = &SPPostgresQueryRunnerContext;

// Column widths fitted to the header and the first rows, as the Content view's
static const CGFloat SPPostgresQueryMinColumnWidth = 40;
static const CGFloat SPPostgresQueryMaxColumnWidth = 300;
static const NSUInteger SPPostgresQueryWidthSampleRows = 100;

#pragma mark - View

/**
 * The Query view's root: handles MySQL's run keys while it is in a window, before the editor or anything else
 * sees them (the run pop-up button's items show the same keys, but never get them, so a key press runs once): ⌘R
 * runs the primary action and ⌥⌘R the secondary one (as DBView.xib's run popup). By default the primary action is
 * Run Current; MySQL's "QueryPrimaryControlRunsAll" preference makes it Run All (read at each key press, so a change
 * applies at once). Other keys (e.g. ⇧⌘R, Refresh Databases) pass on.
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

/// The outer split view: as MySQL's (SPCustomQuery's -splitView:effectiveRect:…), its divider can't be dragged; the
/// info pane is shown and hidden by its toggle only.
@interface SPPostgresQueryInfoPaneSplitView : SPSplitView
@end

@implementation SPPostgresQueryInfoPaneSplitView

- (NSRect)splitView:(NSSplitView *)theSplitView effectiveRect:(NSRect)proposedEffectiveRect forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex
{
	return NSZeroRect;
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
	SPPostgresTaskRunner *taskRunner;

	/// The row set the grid shows (nil: none). Values are read from it as the grid draws.
	PGPostgresResult *result;
	NSUInteger resultRowCount;

	SPPostgresQueryView *view;
	SPSplitView *infoPaneSplitView;
	SPSplitView *editorSplitView;
	NSTextView *editor;
	SPTableView *resultsView;
	NSTextView *infoPaneText;

	NSPopUpButton *gearButton;
	NSPopUpButton *favoritesButton;
	NSPopUpButton *historyButton;
	SPComboPopupButton *runButton;
	NSMenuItem *runPrimaryActionMenuItem;   // tag 2, ⌘R
	NSMenuItem *runSecondaryActionMenuItem; // tag 1, ⌥⌘R
	NSMenuItem *switchDefaultMenuItem;

	NSButton *infoPaneButton;
	NSPopUpButton *resultsGearButton;
	NSMenuItem *exportCSVMenuItem;
	NSButton *editModeButton;
	NSTextField *statusField;

	NSUserDefaults *defaults;
	NSUserDefaultsController *defaultsController; // the edit mode toggle's binding, on defaults

	BOOL running;                   // YES from a run's enqueue until its completion
	BOOL observingRunner;           // observing taskRunner's busy (the run controls are disabled while it is)
	BOOL invalidated;

	/// Test seam: called on the runner's thread before each statement runs (see the tests' SPPostgresQueryController (Testing))
	void (^statementWillRunHook)(NSString *statement);
}

@synthesize editor;
@synthesize resultsView;
@synthesize statusText;
@synthesize runDidChangeDatabase;
@synthesize lastRunTransactionStatus;
@synthesize exportResultHandler;
@synthesize defaults;
@synthesize gearButton;
@synthesize favoritesButton;
@synthesize historyButton;
@synthesize runButton;
@synthesize infoPaneButton;
@synthesize resultsGearButton;
@synthesize editModeButton;
@synthesize statusField;
@synthesize infoPaneText;
@synthesize infoPaneSplitView;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		defaults = [[NSUserDefaults standardUserDefaults] retain];
		statusText = [@"" copy];
		[self _buildView];
		[self _bindEditModeButton];
		[self setTaskRunner:[SPPostgresTaskRunner inlineRunnerWithConnection:theConnection]]; // updates the run controls
		[self _updateQueryInteractionInterface];
		[self _updateExportItem];
	}

	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[taskRunner release];
	[defaults release];
	[result release];
	[statusText release];

	[view release];
	[infoPaneSplitView release];
	[editorSplitView release];
	[editor release];
	[resultsView release];
	[infoPaneText release];
	[gearButton release];
	[favoritesButton release];
	[historyButton release];
	[runButton release];
	[runPrimaryActionMenuItem release];
	[runSecondaryActionMenuItem release];
	[switchDefaultMenuItem release];
	[infoPaneButton release];
	[resultsGearButton release];
	[exportCSVMenuItem release];
	[editModeButton release];
	[statusField release];
	[statementWillRunHook release];
	[runDidChangeDatabase release];
	[exportResultHandler release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;

	[self _stopObservingRunner];
	[self _unbindEditModeButton];

	[view setController:nil];
	[resultsView setDataSource:nil];
	[resultsView setDelegate:nil];
	[editor setDelegate:nil];
	[runButton setTarget:nil];
	for (NSMenuItem *item in @[runPrimaryActionMenuItem, runSecondaryActionMenuItem, switchDefaultMenuItem, exportCSVMenuItem]) [item setTarget:nil];

	// The blocks may capture the tab
	[runDidChangeDatabase release];
	runDidChangeDatabase = nil;
	[exportResultHandler release];
	exportResultHandler = nil;
}

#pragma mark - The runner

- (SPPostgresTaskRunner *)taskRunner
{
	return [[taskRunner retain] autorelease];
}

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	if (runner == taskRunner) return;
	[self _stopObservingRunner];
	[taskRunner release];
	taskRunner = [runner retain];
	if (taskRunner && !invalidated) {
		[taskRunner addObserver:self forKeyPath:@"busy" options:0 context:SPPostgresQueryRunnerContext];
		observingRunner = YES;
	}
	[self _updateRunControls];
}

- (void)_stopObservingRunner
{
	if (!observingRunner) return;
	[taskRunner removeObserver:self forKeyPath:@"busy" context:SPPostgresQueryRunnerContext];
	observingRunner = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context != SPPostgresQueryRunnerContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	if (invalidated) return;

	// The runner changes busy on the main thread
	[self _updateRunControls];
}

/// The run button and its run items are disabled while the runner is busy (as is the results gear's export).
- (void)_updateRunControls
{
	if (invalidated) return;
	BOOL idle = ![taskRunner isBusy];
	[runButton setEnabled:idle];
	[runPrimaryActionMenuItem setEnabled:idle];
	[runSecondaryActionMenuItem setEnabled:idle];
	[self _updateExportItem];
}

/// Export Result ▸ As CSV file…: while the grid shows a row set and the runner is idle.
- (void)_updateExportItem
{
	if (invalidated) return;
	[exportCSVMenuItem setEnabled:(result != nil) && ![taskRunner isBusy]];
}

#pragma mark - Preferences

- (void)setDefaults:(NSUserDefaults *)newDefaults
{
	if (newDefaults == defaults) return;
	[self _unbindEditModeButton];
	[defaults release];
	defaults = [newDefaults retain];
	[self _bindEditModeButton];
	[self _updateQueryInteractionInterface];
}

/// The edit mode toggle is bound to MySQL's shared preference, on defaults (as DBView.xib's, on the shared controller).
- (void)_bindEditModeButton
{
	if (invalidated || !defaults || defaultsController) return;
	defaultsController = [[NSUserDefaultsController alloc] initWithDefaults:defaults initialValues:nil];
	[defaultsController setAppliesImmediately:YES];
	[editModeButton bind:NSValueBinding toObject:defaultsController withKeyPath:[@"values." stringByAppendingString:SPEditInSheetEnabled] options:nil];
}

- (void)_unbindEditModeButton
{
	if (!defaultsController) return;
	[editModeButton unbind:NSValueBinding];
	[defaultsController release];
	defaultsController = nil;
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

/// A 32 x 25 textured toggle of MySQL's results bar (DBView.xib), at x in the bar.
- (NSButton *)_newBarToggleWithImage:(NSString *)imageName alternateImage:(NSString *)alternateImageName toolTip:(NSString *)toolTip x:(CGFloat)x
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, -1, 32, 25)];
	[button setButtonType:NSButtonTypeToggle];
	[button setBezelStyle:NSBezelStyleTexturedRounded];
	[button setImage:[NSImage imageNamed:imageName]];
	[button setAlternateImage:[NSImage imageNamed:alternateImageName]];
	[button setTitle:@""];
	[button setImagePosition:NSImageOnly];
	[button setToolTip:toolTip];
	[button setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	return button;
}

/// A gear of MySQL's bars (DBView.xib): a pull-down without arrow, showing its hidden first item's image.
- (NSPopUpButton *)_newGearButtonWithFrame:(NSRect)frame
{
	NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:YES];
	NSPopUpButtonCell *cell = [button cell];
	[button setBezelStyle:NSBezelStyleRegularSquare];
	[cell setArrowPosition:NSPopUpNoArrow];
	[cell setImagePosition:NSImageRight];
	[cell setAlignment:NSTextAlignmentCenter];
	[cell setUsesItemFromMenu:YES];
	[button setFont:[NSFont menuFontOfSize:0]];

	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	NSMenuItem *imageItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
	[imageItem setImage:[NSImage imageNamed:@"button_action"]];
	[imageItem setState:NSControlStateValueOn];
	[imageItem setHidden:YES];
	[button setMenu:menu];
	return button;
}

/// Query Favorites / Query History (DBView.xib): recessed, small pull-downs titled by their hidden first item, with
/// MySQL's ⌥⌘ key.
- (NSPopUpButton *)_newRecessedPopUpWithFrame:(NSRect)frame title:(NSString *)title key:(NSString *)key toolTip:(NSString *)toolTip
{
	NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:YES];
	[button setBezelStyle:NSBezelStyleRecessed];
	[[button cell] setControlSize:NSControlSizeSmall];
	[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[button cell] setLineBreakMode:NSLineBreakByClipping];
	[(NSPopUpButtonCell *)[button cell] setPreferredEdge:NSRectEdgeMaxY];
	[[button cell] setKeyEquivalent:key];
	[[button cell] setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
	[button setToolTip:toolTip];

	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
	[[menu addItemWithTitle:title action:NULL keyEquivalent:@""] setHidden:YES];
	[button setMenu:menu];
	return button;
}

/// The results pane: MySQL's top bar (the gear, Query Favorites, Query History, the run button) over the grid.
- (NSView *)_newResultsPaneWithFrame:(NSRect)frame
{
	CGFloat width = NSWidth(frame), height = NSHeight(frame);
	NSView *pane = [[NSView alloc] initWithFrame:frame];
	[pane setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSScrollView *resultsScrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, height - SPPostgresQueryBarHeight)] autorelease];
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
	[pane addSubview:resultsScrollView];

	SPButtonBar *topBar = [[[SPButtonBar alloc] initWithFrame:NSMakeRect(0, height - SPPostgresQueryBarHeight, width, SPPostgresQueryBarHeight)] autorelease];
	[topBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];

	gearButton = [self _newGearButtonWithFrame:NSMakeRect(0, 0, 35, 23)];
	[gearButton setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	[topBar addSubview:gearButton];

	favoritesButton = [self _newRecessedPopUpWithFrame:NSMakeRect(38, 0, 129, 22)
												 title:NSLocalizedString(@"Query Favorites", @"Query Favorites popup button title")
												   key:@"f"
											   toolTip:NSLocalizedString(@"Choose a favorite from the menu or save queries to the favorites (⌥⌘F)", @"query favorites popup button tooltip")];
	[favoritesButton setAutoresizingMask:NSViewMinYMargin];
	[topBar addSubview:favoritesButton];

	historyButton = [self _newRecessedPopUpWithFrame:NSMakeRect(177, 0, 145, 22)
											   title:NSLocalizedString(@"Query History", @"Query History popup button title")
												 key:@"y"
											 toolTip:NSLocalizedString(@"Choose a query from your recent queries (⌥⌘Y)", @"query history popup button tooltip")];
	[historyButton setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	[topBar addSubview:historyButton];

	// MySQL's run pop-up button: a click runs the primary action, the menu has both and Switch Default. The items show
	// MySQL's keys; SPPostgresQueryView takes ⌘R and ⌥⌘R first (see there)
	runButton = [[SPComboPopupButton alloc] initWithFrame:NSMakeRect(width - 188, 0, 180, 22) pullsDown:YES];
	[runButton setBezelStyle:NSBezelStyleRoundRect];
	[[runButton cell] setControlSize:NSControlSizeSmall];
	[runButton setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[runButton cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[runButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
	// SPComboPopupButton reads its line offset from the control size at init: made small, it is set again here
	[runButton setValue:@15 forKey:@"lineOffset"];

	// Built in the button's own menu, whose delegate the button already is (it tracks the menu being open)
	NSMenu *runMenu = [runButton menu];
	[runMenu setAutoenablesItems:NO];
	[[runMenu addItemWithTitle:NSLocalizedString(@"Run Current", @"Title of button to run current query in custom query view") action:NULL keyEquivalent:@""] setHidden:YES];
	runPrimaryActionMenuItem = [[runMenu addItemWithTitle:NSLocalizedString(@"Run Current Query", @"Title of action menu item to run current query in custom query view") action:@selector(runPrimaryQueryAction:) keyEquivalent:@"r"] retain];
	[runPrimaryActionMenuItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[runPrimaryActionMenuItem setTag:SPPostgresQueryPrimaryRunTag];
	[runPrimaryActionMenuItem setTarget:self];
	[runMenu addItem:[NSMenuItem separatorItem]];
	runSecondaryActionMenuItem = [[runMenu addItemWithTitle:NSLocalizedString(@"Run All Queries", @"Run All menu item title") action:@selector(runSecondaryQueryAction:) keyEquivalent:@"r"] retain];
	[runSecondaryActionMenuItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
	[runSecondaryActionMenuItem setTag:SPPostgresQuerySecondaryRunTag];
	[runSecondaryActionMenuItem setTarget:self];
	switchDefaultMenuItem = [[runMenu addItemWithTitle:NSLocalizedString(@"Switch Default", @"Postgres query: switch default run action menu item") action:@selector(switchDefaultQueryAction:) keyEquivalent:@""] retain];
	[switchDefaultMenuItem setTarget:self];
	[runButton setTarget:self];
	[runButton setAction:@selector(runPrimaryQueryAction:)];
	[topBar addSubview:runButton];

	[pane addSubview:topBar];
	return pane;
}

/// The query information pane (DBView.xib): "Query Status" over the read-only text.
- (NSView *)_newInfoPaneWithFrame:(NSRect)frame
{
	CGFloat width = NSWidth(frame), height = NSHeight(frame);
	NSView *pane = [[NSView alloc] initWithFrame:frame];
	[pane setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSTextField *heading = [[[NSTextField alloc] initWithFrame:NSMakeRect(15, height - 26, 363, 14)] autorelease];
	[heading setEditable:NO];
	[heading setSelectable:NO];
	[heading setBordered:NO];
	[heading setDrawsBackground:NO];
	[[heading cell] setControlSize:NSControlSizeSmall];
	[heading setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
	[heading setStringValue:NSLocalizedString(@"Query Status", @"Postgres query: information pane heading")];
	[heading setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	[pane addSubview:heading];

	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, width - 24, height - 45)] autorelease];
	[scrollView setBorderType:NSNoBorder];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:NO];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setDrawsBackground:NO];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	NSSize contentSize = [scrollView contentSize];
	infoPaneText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
	[infoPaneText setEditable:NO];
	[infoPaneText setSelectable:YES];
	[infoPaneText setRichText:NO];
	[infoPaneText setImportsGraphics:NO];
	[infoPaneText setDrawsBackground:NO];
	[infoPaneText setMinSize:NSMakeSize(0, contentSize.height)];
	[infoPaneText setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[infoPaneText setVerticallyResizable:YES];
	[infoPaneText setHorizontallyResizable:NO];
	[infoPaneText setAutoresizingMask:NSViewWidthSizable];
	[[infoPaneText textContainer] setContainerSize:NSMakeSize(contentSize.width, CGFLOAT_MAX)];
	[[infoPaneText textContainer] setWidthTracksTextView:YES];
	[infoPaneText setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[scrollView setDocumentView:infoPaneText];
	[pane addSubview:scrollView];

	return pane;
}

/// MySQL's results bar (DBView.xib, its frames less the bar's origin there): the info pane toggle, the results gear,
/// the edit mode toggle and the status line.
- (NSView *)_newResultsBarWithWidth:(CGFloat)width
{
	SPButtonBar *bar = [[SPButtonBar alloc] initWithFrame:NSMakeRect(0, 0, width, SPPostgresQueryBarHeight)];
	[bar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];

	resultsGearButton = [self _newGearButtonWithFrame:NSMakeRect(29, 0, 36, 23)];
	[resultsGearButton setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	NSMenu *exportMenu = [[[NSMenu alloc] initWithTitle:NSLocalizedString(@"Export Result", @"Postgres query: export result menu")] autorelease];
	[exportMenu setAutoenablesItems:NO];
	exportCSVMenuItem = [[exportMenu addItemWithTitle:NSLocalizedString(@"As CSV file…", @"Postgres query: export result as CSV menu item") action:@selector(exportResultAsCSV:) keyEquivalent:@""] retain];
	[exportCSVMenuItem setTag:1];
	[exportCSVMenuItem setTarget:self];
	NSMenuItem *exportItem = [[resultsGearButton menu] addItemWithTitle:NSLocalizedString(@"Export Result", @"Postgres query: export result menu") action:NULL keyEquivalent:@""];
	[exportItem setSubmenu:exportMenu];
	[bar addSubview:resultsGearButton];

	infoPaneButton = [self _newBarToggleWithImage:@"button_pane_hide" alternateImage:@"button_pane_show"
										  toolTip:NSLocalizedString(@"Toggle the visibility of the Query Information Pane", @"toggle query information pane tooltip")
												x:-1];
	[infoPaneButton setKeyEquivalent:@"a"];
	[infoPaneButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
	[infoPaneButton setTarget:infoPaneSplitView];
	[infoPaneButton setAction:@selector(toggleCollapse:)];
	[bar addSubview:infoPaneButton];

	// Bound to MySQL's shared preference (see -_bindEditModeButton)
	editModeButton = [self _newBarToggleWithImage:@"button_edit_mode" alternateImage:@"button_edit_mode_selected"
										  toolTip:NSLocalizedString(@"Toggle between editing simple text cells as a spreadsheet or in pop-up sheets", @"edit mode toggle button tooltip")
												x:61];
	[bar addSubview:editModeButton];

	statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(96, 2, width - 96 - 10, 17)];
	[statusField setEditable:NO];
	[statusField setSelectable:YES];
	[statusField setBordered:NO];
	[statusField setDrawsBackground:NO];
	[statusField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[statusField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[statusField setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[statusField setStringValue:@""];
	[bar addSubview:statusField];

	return bar;
}

/**
 * As MySQL's Query tab (DBView.xib), filling the right pane: the results bar along the bottom; over it the outer split
 * view (thin divider) of the editor and results (an inner split view, default divider, each at least 100 pt) and the
 * info pane, collapsible and collapsed at start, its divider not draggable. Nothing is autosaved.
 */
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 695, 534);
	CGFloat width = NSWidth(frame);
	view = [[SPPostgresQueryView alloc] initWithFrame:frame];
	[view setController:self];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	CGFloat splitHeight = NSHeight(frame) - SPPostgresQueryBarHeight;
	infoPaneSplitView = [[SPPostgresQueryInfoPaneSplitView alloc] initWithFrame:NSMakeRect(0, SPPostgresQueryBarHeight, width, splitHeight)];
	[infoPaneSplitView setVertical:NO];
	[infoPaneSplitView setDividerStyle:NSSplitViewDividerStyleThin];
	[infoPaneSplitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	CGFloat upperHeight = splitHeight - SPPostgresQueryInfoPaneHeight - [infoPaneSplitView dividerThickness];
	NSView *upper = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, upperHeight)] autorelease];
	[upper setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	editorSplitView = [[SPSplitView alloc] initWithFrame:[upper bounds]];
	[editorSplitView setVertical:NO];
	[editorSplitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// Editor
	CGFloat editorHeight = 142;
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
	// The run button's title follows the caret (see -textViewDidChangeSelection:)
	[editor setDelegate:self];
	[editorScrollView setDocumentView:editor];
	[editorSplitView addSubview:editorScrollView];

	// Top bar and results
	CGFloat resultsHeight = upperHeight - editorHeight - [editorSplitView dividerThickness];
	NSView *resultsPane = [[self _newResultsPaneWithFrame:NSMakeRect(0, 0, width, resultsHeight)] autorelease];
	[editorSplitView addSubview:resultsPane];
	[editorSplitView adjustSubviews];
	[editorSplitView setMinSize:SPPostgresQueryMinPaneHeight ofSubviewAtIndex:0];
	[editorSplitView setMinSize:SPPostgresQueryMinPaneHeight ofSubviewAtIndex:1];
	[upper addSubview:editorSplitView];
	[infoPaneSplitView addSubview:upper];

	NSView *infoPane = [[self _newInfoPaneWithFrame:NSMakeRect(0, upperHeight + [infoPaneSplitView dividerThickness], width, SPPostgresQueryInfoPaneHeight)] autorelease];
	[infoPaneSplitView addSubview:infoPane];
	[infoPaneSplitView adjustSubviews];
	[view addSubview:infoPaneSplitView];

	[view addSubview:[[self _newResultsBarWithWidth:width] autorelease]];

	// As -[SPCustomQuery awakeFromNib]: the info pane collapses with its toggle, collapsed at start
	[infoPaneSplitView setCollapsibleSubviewIndex:1];
	[infoPaneSplitView setToggleCollapseButton:infoPaneButton];
	[infoPaneSplitView setCollapsibleSubviewCollapsed:YES animate:NO];
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
		NSRange range = [self currentQueryRange];
		if (range.location != NSNotFound) statements = [SPPostgresStatementSplitter statementsInSQL:[text substringWithRange:range]];
	}

	if (![statements count]) {
		NSBeep();
		return;
	}

	[self _runStatements:statements];
}

- (IBAction)runPrimaryQueryAction:(id)sender
{
	if ([defaults boolForKey:SPQueryPrimaryControlRunsAll]) [self runAllQueries:sender];
	else [self runCurrentQuery:sender];
}

- (IBAction)runSecondaryQueryAction:(id)sender
{
	if ([defaults boolForKey:SPQueryPrimaryControlRunsAll]) [self runCurrentQuery:sender];
	else [self runAllQueries:sender];
}

- (IBAction)switchDefaultQueryAction:(id)sender
{
	if (invalidated) return;
	[defaults setBool:![defaults boolForKey:SPQueryPrimaryControlRunsAll] forKey:SPQueryPrimaryControlRunsAll];
	[self _updateQueryInteractionInterface];
}

#pragma mark - Run titles

- (NSRange)currentQueryRange
{
	return [SPPostgresStatementSplitter rangeOfStatementAtLocation:[editor selectedRange].location inSQL:[editor string] ?: @""];
}

/// The caret is after range's statement: past its semicolon, in the whitespace or comments that follow (MySQL's
/// "Run Previous"). Not when the statement isn't terminated (the caret is then still in it, as MySQL's).
- (BOOL)_caretIsAfterQueryRange:(NSRange)range
{
	if (range.location == NSNotFound) return NO;
	NSUInteger caret = [editor selectedRange].location;
	NSString *text = [editor string];
	if (caret <= NSMaxRange(range) || caret > [text length]) return NO;
	NSString *rest = [[text substringWithRange:NSMakeRange(NSMaxRange(range), caret - NSMaxRange(range))] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return [rest hasPrefix:@";"];
}

/// As MySQL's -updateQueryInteractionInterface (SPCustomQuery.m): the run button and items follow the primary action.
- (void)_updateQueryInteractionInterface
{
	if (invalidated) return;
	if ([defaults boolForKey:SPQueryPrimaryControlRunsAll]) {
		[runButton setTitle:NSLocalizedString(@"Run All", @"run all button")];
		[runPrimaryActionMenuItem setTitle:NSLocalizedString(@"Run All Queries", @"Run All menu item title")];
	}
	else {
		[runSecondaryActionMenuItem setTitle:NSLocalizedString(@"Run All Queries", @"Run All menu item title")];
	}
	[self _updateContextualRunInterface];
}

/// As MySQL's -updateContextualRunInterface: "Run Current", "Run Previous" or "Run Selection" on the button (when it
/// runs that) and on the item that runs it.
- (void)_updateContextualRunInterface
{
	if (invalidated) return;
	BOOL primaryRunsAll = [defaults boolForKey:SPQueryPrimaryControlRunsAll];
	NSPopUpButton *button = primaryRunsAll ? nil : runButton;
	NSMenuItem *item = primaryRunsAll ? runSecondaryActionMenuItem : runPrimaryActionMenuItem;

	if (![editor selectedRange].length) {
		if ([self _caretIsAfterQueryRange:[self currentQueryRange]]) {
			[button setTitle:NSLocalizedString(@"Run Previous", @"Title of button to run query just before text caret in custom query view")];
			[item setTitle:NSLocalizedString(@"Run Previous Query", @"Title of action menu item to run query just before text caret in custom query view")];
		}
		else {
			[button setTitle:NSLocalizedString(@"Run Current", @"Title of button to run current query in custom query view")];
			[item setTitle:NSLocalizedString(@"Run Current Query", @"Title of action menu item to run current query in custom query view")];
		}
	}
	else {
		[button setTitle:NSLocalizedString(@"Run Selection", @"Title of button to run selected text in custom query view")];
		[item setTitle:NSLocalizedString(@"Run Selected Text", @"Title of action menu item to run selected text in custom query view")];
	}
}

- (void)textViewDidChangeSelection:(NSNotification *)notification
{
	if ([notification object] != editor) return;
	[self _updateContextualRunInterface];
}

#pragma mark - Export

/// Results gear ▸ Export Result ▸ As CSV file… (the tab's Export sheet, on the query result).
- (IBAction)exportResultAsCSV:(id)sender
{
	if (invalidated || !result || [taskRunner isBusy]) {
		NSBeep();
		return;
	}
	if (exportResultHandler) exportResultHandler();
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
	if (invalidated || ![statements count]) return;
	// A run while the runner is busy (a key equivalent the task display's blocker doesn't stop) is refused
	if (running || [taskRunner isBusy] || [taskRunner isInvalidated]) {
		NSBeep();
		return;
	}

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

	[self _updateExportItem];
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
