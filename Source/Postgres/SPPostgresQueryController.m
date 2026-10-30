#import "SPPostgresQueryController.h"
#import "SPPostgresStatementSplitter.h"
#import "SPPostgresConsoleLogger.h"
#import "SPPostgresTableData.h"
#import "SPPostgresTaskRunner.h"
#import "SPPostgresTextView.h"
#import "SPPostgresSQLTokenizer.h"
#import "SPPostgresQueryStore.h"
#import "SPPostgresQueryFavoriteManager.h"
#import "SPTextViewAdditions.h"
#import "SPTableView.h"
#import "SPButtonBar.h"
#import "SPSplitView.h"
#import "SPComboPopupButton.h"
#import "SPConstants.h"
#import "SPStringAdditions.h"
#import <PostgresKit/PostgresKit.h>

// MySQL's Query tab (DBView.xib): 23 pt bars, at the top of the results and at the bottom of the tab
static const CGFloat SPPostgresQueryBarHeight = 23;
// The query information pane's height (DBView.xib), and the editor's and results' minimum heights
static const CGFloat SPPostgresQueryInfoPaneHeight = 119;
static const CGFloat SPPostgresQueryMinPaneHeight = 100;

// The run pop-up button's items (DBView.xib): the primary run item, the secondary one
static const NSInteger SPPostgresQueryPrimaryRunTag = 2;
static const NSInteger SPPostgresQuerySecondaryRunTag = 1;

// SPComboPopupButton's divider offset for a small control (kSPComboPopupButtonLineOffsetSmall, SPComboPopupButton.m:34)
static const NSUInteger SPPostgresQueryRunButtonSmallLineOffset = 15;

static void *SPPostgresQueryRunnerContext = &SPPostgresQueryRunnerContext;
static void *SPPostgresQueryToggleContext = &SPPostgresQueryToggleContext;

// The gear's items (DBView.xib): their tags
static const NSInteger SPPostgresGearPreviousHistoryTag = 3;
static const NSInteger SPPostgresGearNextHistoryTag = 4;
static const NSInteger SPPostgresGearShiftRightTag = 6;
static const NSInteger SPPostgresGearShiftLeftTag = 7;
static const NSInteger SPPostgresGearCompletionListTag = 8;
static const NSInteger SPPostgresGearAutoindentTag = 9;
static const NSInteger SPPostgresGearAutopairTag = 10;
static const NSInteger SPPostgresGearCommentLineTag = 11;
static const NSInteger SPPostgresGearCommentQueryTag = 12;
static const NSInteger SPPostgresGearAllDatabasesTag = 8000;
static const NSInteger SPPostgresGearAllTablesTag = 8001;
static const NSInteger SPPostgresGearAllFieldsTag = 8002;

// The Query History pop-up's items (DBView.xib, SPCustomQuery.h): their tags, and the first entry's index (after the
// hidden title, Copy, Save, Clear, a separator, the filter and a separator)
static const NSInteger SPPostgresHistoryCopyTag = 300000;
static const NSInteger SPPostgresHistorySaveTag = 300001;
static const NSInteger SPPostgresHistoryClearTag = 300002;
static const NSInteger SPPostgresHistoryFirstEntryIndex = 7;
// The entries' titles and tooltips are cut to these lengths (SPQueryController's -historyMenuItemsForFileURL:)
static const NSUInteger SPPostgresHistoryTitleLength = 64;
static const NSUInteger SPPostgresHistoryToolTipLength = 256;
// The Query Favorites pop-up's items (DBView.xib, SPCustomQuery.h): their tags, and the "Global" header's index (after
// the hidden title, Save Query, Save All, Edit, a separator, the filter and a separator); the favorites follow it
static const NSInteger SPPostgresFavoriteSaveQueryTag = 100000;
static const NSInteger SPPostgresFavoriteSaveAllTag = 100001;
static const NSInteger SPPostgresFavoriteHeaderTag = 200000;
static const NSInteger SPPostgresFavoritesHeaderIndex = 7;
// The words after the caret's that the help looks at ("create text search configuration")
static const NSUInteger SPPostgresHelpFollowingWords = 3;

/// The gear's toggles' preferences (MySQL's shared keys), in the menu's order.
static NSArray<NSString *> *SPPostgresGearToggleKeys(void)
{
	return @[SPQueryHistoryReplacesContent, SPQueryFavoriteReplacesContent, SPCustomQueryAutoIndent, SPCustomQueryAutoPairCharacters,
			 SPCustomQueryAutoUppercaseKeywords, SPCustomQueryAutoComplete, SPCustomQueryUpdateAutoHelp];
}

/// Whether the regular expression pattern matches string (as RegexKitLite's -isMatchedByRegex:, which MySQL uses).
static BOOL SPPostgresMatches(NSString *string, NSString *pattern)
{
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
	return [regex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])] != nil;
}

/// Replaces every match of pattern in string with template (as RegexKitLite's -replaceOccurrencesOfRegex:withString:).
static void SPPostgresReplace(NSMutableString *string, NSString *pattern, NSString *template)
{
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
	[regex replaceMatchesInString:string options:0 range:NSMakeRange(0, [string length]) withTemplate:template];
}

/// The capture group of pattern's first match in string, or @"" (as RegexKitLite's -rangeOfRegex:…capture:).
static NSString *SPPostgresCapture(NSString *string, NSString *pattern, NSUInteger group)
{
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
	NSTextCheckingResult *match = [regex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
	if (!match || [match rangeAtIndex:group].location == NSNotFound) return @"";
	return [string substringWithRange:[match rangeAtIndex:group]];
}

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
				// The controller's actions read MySQL's run preference from its defaults, as the run button does
				if (![event isARepeat]) {
					if (primary) [controller runPrimaryQueryAction:self];
					else [controller runSecondaryQueryAction:self];
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
 * The counts and the errors are MySQL's (SPCustomQuery.m: totalQueriesRun, totalAffectedRows, executionTime, errors).
 */
@interface SPPostgresQueryRun : NSObject
/// The last row set returned (nil: none).
@property (retain) PGPostgresResult *rowsResult;
/// The statement whose rows rowsResult holds (0: none).
@property (assign) NSUInteger shownStatement;
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
/// How many statements the run has (MySQL's queryCount).
@property (assign) NSUInteger total;
/// The statements sent to the server, the failing or cancelled one too (MySQL's tempQueries).
@property (readonly) NSMutableArray *ranStatements;
/// The rows returned or affected, summed over the statements that succeeded.
@property (assign) unsigned long long affectedRows;
/// The time spent in the statements, in seconds.
@property (assign) double executionTime;
/// MySQL's errors text ("[ERROR in query K] …" when the run has more than one statement); @"" without errors.
@property (readonly) NSMutableString *errors;
/// The COPY … TO STDOUT statements' notes, in order.
@property (readonly) NSMutableArray *discardedOutputNotes;
@end

@implementation SPPostgresQueryRun

@synthesize rowsResult;
@synthesize shownStatement;
@synthesize schemaChanged;
@synthesize dataChanged;
@synthesize cancelled;
@synthesize started;
@synthesize exception;
@synthesize transactionStatus;
@synthesize total;
@synthesize ranStatements;
@synthesize affectedRows;
@synthesize executionTime;
@synthesize errors;
@synthesize discardedOutputNotes;

- (instancetype)init
{
	if ((self = [super init])) {
		ranStatements = [[NSMutableArray alloc] init];
		errors = [[NSMutableString alloc] init];
		discardedOutputNotes = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[rowsResult release];
	[exception release];
	[ranStatements release];
	[errors release];
	[discardedOutputNotes release];
	[super dealloc];
}

@end

#pragma mark - Controller

@interface SPPostgresQueryController () <NSSplitViewDelegate, NSWindowDelegate, NSMenuDelegate, NSTextFieldDelegate>

@property (readwrite, copy) NSString *statusText;
@property (readwrite, copy) NSString *lastRunQueryText;

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
	NSTextField *infoPaneTitle;
	NSTextView *infoPaneText;
	BOOL infoPaneAnimates;
	NSString *lastRunQueryText;

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
	NSUserDefaultsController *defaultsController; // the edit mode toggle's binding and the gear's toggles, on defaults

	// The gear's items (MySQL's outlets)
	NSMenuItem *previousHistoryMenuItem;
	NSMenuItem *nextHistoryMenuItem;
	NSMenuItem *shiftRightMenuItem;
	NSMenuItem *shiftLeftMenuItem;
	NSMenuItem *commentLineOrSelectionMenuItem;
	NSMenuItem *commentCurrentQueryMenuItem;
	NSMenuItem *completionListMenuItem;
	NSMenuItem *editorFontMenuItem;
	/// The toggles, by their preference key
	NSMutableDictionary<NSString *, NSMenuItem *> *toggleMenuItems;
	void (^helpHandler)(NSString *searchString, BOOL autoHelp);

	// Query History
	SPPostgresQueryStore *historyStore;
	NSPasteboard *pasteboard;
	NSString * (^savePathProvider)(NSString *suggestedName);
	void (^alertPresenter)(NSAlert *alert);
	void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));
	NSArray<NSString *> *historyEntries;    // the entries the menu shows, most recent first
	NSSearchField *historySearchField;
	NSMenuItem *copyHistoryMenuItem;
	NSMenuItem *saveHistoryMenuItem;
	NSMenuItem *clearHistoryMenuItem;
	NSInteger currentHistoryOffsetIndex;    // Previous / Next's entry (-1: none yet), as MySQL's
	BOOL historyItemWasJustInserted;        // Previous / Next is inserting (the selection change keeps the offset)
	BOOL historySaveErrorReported;          // a run's failed history save is reported once
	/// Test seam: called instead of NSBeep() by Previous / Next (see the tests' SPPostgresQueryController (HistoryTesting))
	void (^beepHook)(void);

	// Query Favorites
	SPPostgresQueryStore *favoritesStore;
	NSArray<NSDictionary *> *favoriteEntries; // the favorites the menu shows
	NSSearchField *favoritesSearchField;
	NSMenuItem *saveQueryFavoriteMenuItem;    // tag 100000
	NSMenuItem *saveAllFavoriteMenuItem;      // tag 100001, its alternate
	NSMenuItem *editFavoritesMenuItem;
	NSPanel *favoriteNameSheet;               // MySQL's "Query Favorite Sheet", while it is shown
	NSTextField *favoriteNameField;
	NSButton *favoriteNameSaveButton;
	NSButton *favoriteNameCancelButton;
	BOOL favoriteNameSavesAll;                // the sheet is Save All's (else Save Query's)
	SPPostgresQueryFavoriteManager *favoritesManager; // while it is shown

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
@synthesize infoPaneTitle;
@synthesize infoPaneText;
@synthesize infoPaneAnimates;
@synthesize lastRunQueryText;
@synthesize infoPaneSplitView;
@synthesize helpHandler;
@synthesize historyStore;
@synthesize pasteboard;
@synthesize savePathProvider;
@synthesize alertPresenter;
@synthesize confirmationPresenter;
@synthesize favoritesStore;
@synthesize favoriteNameSheet;
@synthesize favoriteNameField;
@synthesize favoriteNameSaveButton;
@synthesize favoriteNameCancelButton;
@synthesize favoritesManager;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		defaults = [[NSUserDefaults standardUserDefaults] retain];
		statusText = [@"" copy];
		infoPaneAnimates = YES;
		pasteboard = [[NSPasteboard generalPasteboard] retain];
		currentHistoryOffsetIndex = -1;
		historyEntries = [@[] retain];
		favoriteEntries = [@[] retain];
		[self _buildView];
		[self setHistoryStore:[SPPostgresQueryStore sharedHistoryStore]];
		[self setFavoritesStore:[SPPostgresQueryStore sharedFavoritesStore]];
		[self _bindEditModeButton];
		[self _updateToggles];
		[self _updateGearItems];
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
	[lastRunQueryText release];

	[view release];
	[infoPaneSplitView release];
	[editorSplitView release];
	[editor release];
	[resultsView release];
	[infoPaneTitle release];
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
	[helpHandler release];
	[previousHistoryMenuItem release];
	[nextHistoryMenuItem release];
	[shiftRightMenuItem release];
	[shiftLeftMenuItem release];
	[commentLineOrSelectionMenuItem release];
	[commentCurrentQueryMenuItem release];
	[completionListMenuItem release];
	[editorFontMenuItem release];
	[toggleMenuItems release];
	[historyStore release];
	[pasteboard release];
	[savePathProvider release];
	[alertPresenter release];
	[confirmationPresenter release];
	[historyEntries release];
	[historySearchField release];
	[copyHistoryMenuItem release];
	[saveHistoryMenuItem release];
	[clearHistoryMenuItem release];
	[beepHook release];
	[favoritesStore release];
	[favoriteEntries release];
	[favoritesSearchField release];
	[saveQueryFavoriteMenuItem release];
	[saveAllFavoriteMenuItem release];
	[editFavoritesMenuItem release];
	[favoriteNameSheet release];
	[favoriteNameField release];
	[favoriteNameSaveButton release];
	[favoriteNameCancelButton release];
	[favoritesManager release];

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
	[runPrimaryActionMenuItem setTarget:nil];
	[runSecondaryActionMenuItem setTarget:nil];
	[switchDefaultMenuItem setTarget:nil];
	[exportCSVMenuItem setTarget:nil];
	for (NSMenuItem *item in [[gearButton menu] itemArray]) {
		[item setTarget:nil];
		for (NSMenuItem *subitem in [[item submenu] itemArray]) [subitem setTarget:nil];
	}
	[infoPaneSplitView setDelegate:nil];
	// The history's menu, filter and store
	[[NSNotificationCenter defaultCenter] removeObserver:self name:SPPostgresQueryStoreDidChangeNotification object:nil];
	[historyButton setTarget:nil];
	[[historyButton menu] setDelegate:nil];
	for (NSMenuItem *item in [[historyButton menu] itemArray]) [item setTarget:nil];
	[historySearchField setTarget:nil];
	// The favorites' menu, filter, name sheet and manager (ending them drops their references to this controller)
	[favoritesButton setTarget:nil];
	[[favoritesButton menu] setDelegate:nil];
	for (NSMenuItem *item in [[favoritesButton menu] itemArray]) [item setTarget:nil];
	[favoritesSearchField setTarget:nil];
	[self _endFavoriteNameSheet];
	[favoritesManager cancel:nil];
	[savePathProvider release];
	savePathProvider = nil;
	[alertPresenter release];
	alertPresenter = nil;
	[confirmationPresenter release];
	confirmationPresenter = nil;
	// Editor Font… made this the font panel's delegate
	if ([NSFontPanel sharedFontPanelExists] && [[NSFontPanel sharedFontPanel] delegate] == (id)self) [[NSFontPanel sharedFontPanel] setDelegate:nil];
	// A pending auto-help (SPTextView's -autoHelp delay)
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showAutoHelpForCurrentWord:) object:editor];

	// The blocks may capture the tab (the editor's completion names too)
	[(SPPostgresTextView *)editor setCompletionNamesProvider:nil];
	[runDidChangeDatabase release];
	runDidChangeDatabase = nil;
	[exportResultHandler release];
	exportResultHandler = nil;
	[helpHandler release];
	helpHandler = nil;
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
	if (context == SPPostgresQueryToggleContext) {
		if (!invalidated) [self _updateToggles];
		return;
	}
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
	[self _updateToggles];
	[self _updateQueryInteractionInterface];
}

/// The edit mode toggle is bound to MySQL's shared preference, on defaults (as DBView.xib's, on the shared controller).
- (void)_bindEditModeButton
{
	if (invalidated || !defaults || defaultsController) return;
	defaultsController = [[NSUserDefaultsController alloc] initWithDefaults:defaults initialValues:nil];
	[defaultsController setAppliesImmediately:YES];
	[editModeButton bind:NSValueBinding toObject:defaultsController withKeyPath:[@"values." stringByAppendingString:SPEditInSheetEnabled] options:nil];
	// As DBView.xib's: the Query History pop-up is hidden while MySQL's history size is 0
	[historyButton bind:NSHiddenBinding toObject:defaultsController withKeyPath:[@"values." stringByAppendingString:SPCustomQueryMaxHistoryItems]
				options:@{NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName}];
	// The gear's toggles follow defaults (see -_updateToggles)
	for (NSString *key in SPPostgresGearToggleKeys()) {
		[defaultsController addObserver:self forKeyPath:[@"values." stringByAppendingString:key] options:0 context:SPPostgresQueryToggleContext];
	}
}

- (void)_unbindEditModeButton
{
	if (!defaultsController) return;
	[editModeButton unbind:NSValueBinding];
	[historyButton unbind:NSHiddenBinding];
	for (NSString *key in SPPostgresGearToggleKeys()) {
		[defaultsController removeObserver:self forKeyPath:[@"values." stringByAppendingString:key] context:SPPostgresQueryToggleContext];
	}
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
	[self _buildGearMenu:[gearButton menu]];
	[topBar addSubview:gearButton];

	favoritesButton = [self _newRecessedPopUpWithFrame:NSMakeRect(38, 0, 129, 22)
												 title:NSLocalizedString(@"Query Favorites", @"Query Favorites popup button title")
												   key:@"f"
											   toolTip:NSLocalizedString(@"Choose a favorite from the menu or save queries to the favorites (⌥⌘F)", @"query favorites popup button tooltip")];
	[favoritesButton setAutoresizingMask:NSViewMinYMargin];
	[self _buildFavoritesMenu];
	[topBar addSubview:favoritesButton];

	historyButton = [self _newRecessedPopUpWithFrame:NSMakeRect(177, 0, 145, 22)
											   title:NSLocalizedString(@"Query History", @"Query History popup button title")
												 key:@"y"
											 toolTip:NSLocalizedString(@"Choose a query from your recent queries (⌥⌘Y)", @"query history popup button tooltip")];
	[historyButton setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	[self _buildHistoryMenu];
	[topBar addSubview:historyButton];

	// MySQL's run pop-up button: a click runs the primary action, the menu has both and Switch Default. The items show
	// MySQL's keys; SPPostgresQueryView takes ⌘R and ⌥⌘R first (see there)
	runButton = [[SPComboPopupButton alloc] initWithFrame:NSMakeRect(width - 188, 0, 180, 22) pullsDown:YES];
	[runButton setBezelStyle:NSBezelStyleRoundRect];
	[[runButton cell] setControlSize:NSControlSizeSmall];
	[runButton setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[runButton cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[runButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
	// SPComboPopupButton reads its line offset from the control size at init (regular here): made small, it gets the
	// small offset (readonly, so set through KVC; SPPostgresQueryBarTests checks it)
	[runButton setValue:@(SPPostgresQueryRunButtonSmallLineOffset) forKey:@"lineOffset"];

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

	infoPaneTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(15, height - 26, 363, 14)];
	[infoPaneTitle setEditable:NO];
	[infoPaneTitle setSelectable:NO];
	[infoPaneTitle setBordered:NO];
	[infoPaneTitle setDrawsBackground:NO];
	[[infoPaneTitle cell] setControlSize:NSControlSizeSmall];
	[infoPaneTitle setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
	[infoPaneTitle setStringValue:NSLocalizedString(@"Query Status", @"Query Status")];
	[infoPaneTitle setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
	[pane addSubview:infoPaneTitle];

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
	infoPaneSplitView = [[SPSplitView alloc] initWithFrame:NSMakeRect(0, SPPostgresQueryBarHeight, width, splitHeight)];
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
	// MySQL's editor (SPTextView) with Postgres colouring; it reads SPTextView's preferences as it is set up
	SPPostgresTextView *textView = [[SPPostgresTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height) scrollView:editorScrollView];
	editor = textView;
	[textView setAutoindent:[defaults boolForKey:SPCustomQueryAutoIndent]];
	[textView setAutopair:[defaults boolForKey:SPCustomQueryAutoPairCharacters]];
	[textView setAutouppercaseKeywords:[defaults boolForKey:SPCustomQueryAutoUppercaseKeywords]];
	[textView setAutohelp:[defaults boolForKey:SPCustomQueryUpdateAutoHelp]];
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
	[editor setTypingAttributes:@{NSFontAttributeName: editorFont, NSForegroundColorAttributeName: [textView otherTextColor] ?: [NSColor textColor]}];
	// The run button's title follows the caret (see -textViewDidChangeSelection:)
	[editor setDelegate:self];
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
	[infoPaneSplitView setDelegate:self]; // its divider can't be dragged (see -splitView:effectiveRect:…)
	[infoPaneSplitView setCollapsibleSubviewCollapsed:YES animate:NO];
}

- (NSString *)infoPaneString
{
	return [[[infoPaneText string] copy] autorelease];
}

- (NSView *)view
{
	return view;
}

#pragma mark - Split view delegate

/// As SPCustomQuery's: the info pane's divider can't be dragged; the pane is shown and hidden by its toggle only.
- (NSRect)splitView:(NSSplitView *)theSplitView effectiveRect:(NSRect)proposedEffectiveRect forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex
{
	return (theSplitView == infoPaneSplitView) ? NSZeroRect : proposedEffectiveRect;
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
	// As MySQL's: moving the caret starts Previous / Next again from the newest entry
	if (!historyItemWasJustInserted) currentHistoryOffsetIndex = -1;
	[self _updateContextualRunInterface];
	[self _updateGearItems];
}

#pragma mark - Query Favorites

/// MySQL's Query Favorites menu (DBView.xib), after its hidden title item: Save Query to Favorites, Save All to
/// Favorites (its ⌥ alternate), Edit Favorites..., a separator, the filter, a separator. The "Global" header and the
/// favorites follow (see -_reloadFavoritesMenu).
- (void)_buildFavoritesMenu
{
	NSMenu *menu = [favoritesButton menu];
	[menu setAutoenablesItems:NO];
	[menu setDelegate:self];

	saveQueryFavoriteMenuItem = [[menu addItemWithTitle:NSLocalizedString(@"Save Query to Favorites", @"Postgres query favorites: save query menu item") action:@selector(chooseQueryFavorite:) keyEquivalent:@""] retain];
	[saveQueryFavoriteMenuItem setTag:SPPostgresFavoriteSaveQueryTag];
	[saveQueryFavoriteMenuItem setKeyEquivalentModifierMask:NSEventModifierFlagOption];
	[saveQueryFavoriteMenuItem setToolTip:NSLocalizedString(@"Save current query, selection, or - if no selection or current query could be found - the entire content to Favorite.", @"Postgres query favorites: save query tooltip")];
	[saveQueryFavoriteMenuItem setTarget:self];

	saveAllFavoriteMenuItem = [[menu addItemWithTitle:NSLocalizedString(@"Save All to Favorites", @"Save All to Favorites") action:@selector(chooseQueryFavorite:) keyEquivalent:@""] retain];
	[saveAllFavoriteMenuItem setTag:SPPostgresFavoriteSaveAllTag];
	[saveAllFavoriteMenuItem setKeyEquivalentModifierMask:0];
	[saveAllFavoriteMenuItem setAlternate:YES];
	[saveAllFavoriteMenuItem setToolTip:NSLocalizedString(@"Save editor content to Favorite. Press ⌥ to restrict for current query or selection.", @"Postgres query favorites: save all tooltip")];
	[saveAllFavoriteMenuItem setTarget:self];

	editFavoritesMenuItem = [[menu addItemWithTitle:NSLocalizedString(@"Edit Favorites...", @"Postgres query favorites: edit favorites menu item") action:@selector(chooseQueryFavorite:) keyEquivalent:@""] retain];
	[editFavoritesMenuItem setTarget:self];

	[menu addItem:[NSMenuItem separatorItem]];

	// The filter (DBView.xib's "Query Favorite Search" view), as the item's view. No recents autosave name: that would
	// write the standard preferences
	NSView *searchView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 217, 20)] autorelease];
	favoritesSearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, 1, 176, 19)];
	[[favoritesSearchField cell] setControlSize:NSControlSizeSmall];
	[favoritesSearchField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[favoritesSearchField cell] setPlaceholderString:NSLocalizedString(@"Filter", @"filter label")];
	[[favoritesSearchField cell] setScrollable:YES];
	[[favoritesSearchField cell] setUsesSingleLineMode:YES];
	[[favoritesSearchField cell] setSendsSearchStringImmediately:YES];
	[favoritesSearchField setFocusRingType:NSFocusRingTypeNone];
	[favoritesSearchField setTarget:self];
	[favoritesSearchField setAction:@selector(filterQueryFavorites:)];
	[searchView addSubview:favoritesSearchField];
	NSMenuItem *searchItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
	[searchItem setView:searchView];

	[menu addItem:[NSMenuItem separatorItem]];

	[favoritesButton setTarget:self];
	[favoritesButton setAction:@selector(chooseQueryFavorite:)];
	[self _reloadFavoritesMenu];
}

- (void)setFavoritesStore:(SPPostgresQueryStore *)store
{
	if (store == favoritesStore) return;
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	if (favoritesStore) [center removeObserver:self name:SPPostgresQueryStoreDidChangeNotification object:favoritesStore];
	[favoritesStore release];
	favoritesStore = [store retain];
	if (invalidated) return;
	if (favoritesStore) [center addObserver:self selector:@selector(_favoritesStoreDidChange:) name:SPPostgresQueryStoreDidChangeNotification object:favoritesStore];
	[self _reloadFavoritesMenu];
}

/// The store's favorites, as MySQL's menu takes them: dictionaries with a name.
- (NSArray<NSDictionary *> *)_storedFavorites
{
	NSMutableArray *entries = [NSMutableArray array];
	for (id item in [favoritesStore items] ?: @[]) {
		if ([item isKindOfClass:[NSDictionary class]] && [[item objectForKey:@"name"] isKindOfClass:[NSString class]]) [entries addObject:item];
	}
	return entries;
}

- (void)_favoritesStoreDidChange:(NSNotification *)notification
{
	if (invalidated) return;
	[self _reloadFavoritesMenu];
}

/// As MySQL's -queryFavoritesHaveBeenUpdated: (its global list; Postgres tabs have no documents), then the filter is
/// applied again.
- (void)_reloadFavoritesMenu
{
	if (invalidated) return;
	NSArray *entries = [self _storedFavorites];
	[favoriteEntries release];
	favoriteEntries = [entries copy];

	NSMenu *menu = [favoritesButton menu];
	while ([menu numberOfItems] > SPPostgresFavoritesHeaderIndex) [menu removeItemAtIndex:[menu numberOfItems] - 1];

	NSMenuItem *header = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Global", @"Query Favorites : List : Section Heading : global query favorites") action:NULL keyEquivalent:@""] autorelease];
	[header setTag:SPPostgresFavoriteHeaderTag];
	[header setToolTip:NSLocalizedString(@"Globally stored favorites", @"Query Favorites : List : Section Heading : global : tooltip")];
	[header setIndentationLevel:0];
	[header setEnabled:NO];
	[menu addItem:header];

	NSMutableParagraphStyle *paraStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
	[paraStyle setTabStops:@[]];
	[paraStyle addTabStop:[[[NSTextTab alloc] initWithType:NSRightTabStopType location:190.0f] autorelease]];
	NSDictionary *attributes = @{NSParagraphStyleAttributeName: paraStyle, NSFontAttributeName: [NSFont systemFontOfSize:11]};
	for (NSDictionary *favorite in favoriteEntries) {
		id query = [favorite objectForKey:@"query"];
		NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"" action:@selector(chooseQueryFavorite:) keyEquivalent:@""] autorelease];
		[item setAttributedTitle:[[[NSAttributedString alloc] initWithString:[favorite objectForKey:@"name"] attributes:attributes] autorelease]];
		if ([query isKindOfClass:[NSString class]]) {
			[item setToolTip:query];
			[item setRepresentedObject:query];
		}
		[item setIndentationLevel:1];
		[item setTarget:self];
		[menu addItem:item];
	}
	[self filterQueryFavorites:nil];
}

/// As opening the menu: its favorites from the store when it changed (another copy of the app may have written it),
/// and MySQL's -validateMenuItem: for the Save items (enabled with text in the editor, Save Query retitled).
- (void)_updateFavoritesMenu
{
	if (![[self _storedFavorites] isEqualToArray:favoriteEntries]) [self _reloadFavoritesMenu];

	NSString *text = [editor string];
	BOOL hasText = [text length] > 0;
	[saveQueryFavoriteMenuItem setEnabled:hasText];
	[saveAllFavoriteMenuItem setEnabled:hasText];
	if (!hasText) return;
	NSRange current = [self currentQueryRange];
	if ([editor selectedRange].length) [saveQueryFavoriteMenuItem setTitle:NSLocalizedString(@"Save Selection to Favorites", @"Save Selection to Favorites")];
	else if (current.location != NSNotFound && current.length) [saveQueryFavoriteMenuItem setTitle:NSLocalizedString(@"Save Current Query to Favorites", @"Save Current Query to Favorites")];
	else [saveQueryFavoriteMenuItem setTitle:NSLocalizedString(@"Save All to Favorites", @"Save All to Favorites")];
}

- (IBAction)chooseQueryFavorite:(id)sender
{
	if (invalidated) return;
	NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : [favoritesButton selectedItem];

	if (item == saveQueryFavoriteMenuItem || item == saveAllFavoriteMenuItem) {
		[self _beginFavoriteNameSheetSavingAll:(item == saveAllFavoriteMenuItem)];
		return;
	}
	if (item == editFavoritesMenuItem) {
		[self _beginFavoritesManager];
		return;
	}

	// A favorite (the header has no query)
	NSString *query = [item representedObject];
	if ([item tag] == SPPostgresFavoriteHeaderTag || ![query isKindOfClass:[NSString class]]) return;

	// As MySQL's: Favorite Replaces Editor Content, inverted while a modifier key is held; otherwise inserted at the
	// caret (the selection stays after it)
	BOOL replaceContent = [defaults boolForKey:SPQueryFavoriteReplacesContent];
	if ([[NSApp currentEvent] modifierFlags] & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
		replaceContent = !replaceContent;
	}
	NSRange range = replaceContent ? NSMakeRange(0, [[editor string] length]) : NSMakeRange([editor selectedRange].location, 0);
	[self _insertEditorText:query inRange:range];
	[self _editorChangedByGear];
}

/// As MySQL's -filterQueryFavorites:: the favorites whose name doesn't contain the filter's text (case-insensitive, as
/// text, not a pattern) are hidden, and stay in the menu; the header stays.
- (IBAction)filterQueryFavorites:(id)sender
{
	if (invalidated) return;
	NSString *filter = [favoritesSearchField stringValue] ?: @"";
	NSMenu *menu = [favoritesButton menu];
	for (NSInteger i = SPPostgresFavoritesHeaderIndex; i < [menu numberOfItems]; i++) {
		NSMenuItem *item = [menu itemAtIndex:i];
		BOOL matches = [item tag] == SPPostgresFavoriteHeaderTag || ![filter length] || [[item title] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
		[item setHidden:!matches];
	}
}

/// As MySQL's: an empty editor shows "Empty query"; otherwise the name sheet (MySQL's "Query Favorite Sheet", without
/// its "Save globally" box: every Postgres favorite is global) asks for the name.
- (void)_beginFavoriteNameSheetSavingAll:(BOOL)saveAll
{
	if (![[editor string] length]) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:NSLocalizedString(@"Empty query", @"empty query message")];
		[alert setInformativeText:NSLocalizedString(@"Cannot save an empty query.", @"empty query informative message")];
		[self _presentAlert:alert];
		return;
	}
	NSWindow *window = [view window];
	if (favoriteNameSheet || !window || [window attachedSheet]) {
		NSBeep();
		return;
	}
	favoriteNameSavesAll = saveAll;

	// DBView.xib's sheet: 260 × 127, resizable in width to 600
	favoriteNameSheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 260, 127) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
													 backing:NSBackingStoreBuffered defer:YES];
	[favoriteNameSheet setReleasedWhenClosed:NO];
	[favoriteNameSheet setContentMinSize:NSMakeSize(260, 127)];
	[favoriteNameSheet setContentMaxSize:NSMakeSize(600, 127)];
	NSView *content = [favoriteNameSheet contentView];

	NSTextField *label = [NSTextField labelWithString:NSLocalizedString(@"Query Name:", @"Postgres query favorites: name sheet label")];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[label setFrame:NSMakeRect(17, 93, 225, 14)];
	[label setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[content addSubview:label];

	favoriteNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(19, 67, 220, 18)];
	[[favoriteNameField cell] setControlSize:NSControlSizeSmall];
	[favoriteNameField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[favoriteNameField cell] setScrollable:YES];
	[[favoriteNameField cell] setUsesSingleLineMode:YES];
	[favoriteNameField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[favoriteNameField setDelegate:self];
	[content addSubview:favoriteNameField];

	favoriteNameSaveButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 13, 94, 28)];
	favoriteNameCancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(14, 13, 99, 28)];
	NSArray *buttons = @[favoriteNameSaveButton, favoriteNameCancelButton];
	NSArray *titles = @[NSLocalizedString(@"Save", @"save button"), NSLocalizedString(@"Cancel", @"cancel button")];
	for (NSUInteger i = 0; i < 2; i++) {
		NSButton *button = [buttons objectAtIndex:i];
		[button setBezelStyle:NSBezelStyleRounded];
		[[button cell] setControlSize:NSControlSizeSmall];
		[button setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[button setTitle:[titles objectAtIndex:i]];
		[button setTarget:self];
		[content addSubview:button];
	}
	[favoriteNameSaveButton setKeyEquivalent:@"\r"];
	[favoriteNameSaveButton setAction:@selector(_saveNamedFavorite:)];
	[favoriteNameSaveButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	// As MySQL's: Save is enabled once there is a name (-controlTextDidChange:)
	[favoriteNameSaveButton setEnabled:NO];
	[favoriteNameCancelButton setKeyEquivalent:@"\e"];
	[favoriteNameCancelButton setAction:@selector(_cancelNamedFavorite:)];
	[favoriteNameCancelButton setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[favoriteNameSheet setInitialFirstResponder:favoriteNameField];

	[window beginSheet:favoriteNameSheet completionHandler:nil];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	if ([notification object] == favoriteNameField) [favoriteNameSaveButton setEnabled:[[favoriteNameField stringValue] length] > 0];
}

- (void)_endFavoriteNameSheet
{
	if (!favoriteNameSheet) return;
	if ([favoriteNameSheet sheetParent]) [[favoriteNameSheet sheetParent] endSheet:favoriteNameSheet];
	[favoriteNameSheet orderOut:nil];
	[favoriteNameField setDelegate:nil];
	[favoriteNameSaveButton setTarget:nil];
	[favoriteNameCancelButton setTarget:nil];
	[favoriteNameSheet autorelease];
	favoriteNameSheet = nil;
	[favoriteNameField autorelease];
	favoriteNameField = nil;
	[favoriteNameSaveButton autorelease];
	favoriteNameSaveButton = nil;
	[favoriteNameCancelButton autorelease];
	favoriteNameCancelButton = nil;
}

- (void)_cancelNamedFavorite:(id)sender
{
	[self _endFavoriteNameSheet];
}

/// As MySQL's -sheetDidEnd:… ("addSelectionToNewQueryFavorite" / "addAllToNewQueryFavorite"): Save Query saves the
/// selection, else the current query, else the whole text; Save All the whole text. Appended to the favorites, as an
/// explicit save (see +[SPPostgresQueryFavoriteManager writeFavorites:…]).
- (void)_saveNamedFavorite:(id)sender
{
	if (invalidated || !favoriteNameSheet) return;
	NSString *name = [[[favoriteNameField stringValue] copy] autorelease];
	if (![name length]) {
		NSBeep();
		return;
	}
	NSString *text = [editor string];
	NSString *query = text;
	if (!favoriteNameSavesAll) {
		NSRange selection = [editor selectedRange];
		NSRange current = [self currentQueryRange];
		if (selection.length) query = [text substringWithRange:selection];
		else if (current.location != NSNotFound && current.length) query = [text substringWithRange:current];
	}
	// A copy: the text view's string is its live, mutable storage
	query = [NSString stringWithString:query];
	[self _endFavoriteNameSheet];

	NSMutableArray *favorites = [NSMutableArray arrayWithArray:[favoritesStore items] ?: @[]];
	[favorites addObject:@{@"name": name, @"query": query}];
	[SPPostgresQueryFavoriteManager writeFavorites:favorites
										   toStore:favoritesStore
										   confirm:^(NSAlert *alert, void (^completion)(BOOL confirmed)) { [self _confirm:alert completion:completion]; }
											report:^(NSAlert *alert) { [self _presentAlert:alert]; }
										completion:nil];
}

/// Edit Favorites...: the favorites manager, as a sheet on the view's window (its alerts through this controller's
/// presenters when they are set).
- (void)_beginFavoritesManager
{
	NSWindow *window = [view window];
	if (favoritesManager || !window || [window attachedSheet]) {
		NSBeep();
		return;
	}
	favoritesManager = [[SPPostgresQueryFavoriteManager alloc] initWithStore:favoritesStore];
	[favoritesManager setAlertPresenter:alertPresenter];
	[favoritesManager setConfirmationPresenter:confirmationPresenter];
	[favoritesManager beginSheetForWindow:window completion:^(BOOL saved) {
		// The store's notification has rebuilt the menu after a save
		[favoritesManager autorelease];
		favoritesManager = nil;
	}];
}

#pragma mark - Query History

/// MySQL's Query History menu (DBView.xib), after its hidden title item: Copy History, Save History… (its alternate),
/// Clear History (titled for an untitled document, as every Postgres tab is), a separator, the filter, a separator.
/// The entries follow (see -_reloadHistoryMenu).
- (void)_buildHistoryMenu
{
	NSMenu *menu = [historyButton menu];
	[menu setAutoenablesItems:NO];
	[menu setDelegate:self];

	copyHistoryMenuItem = [[menu addItemWithTitle:NSLocalizedString(@"Copy History", @"Postgres query history: copy history menu item") action:@selector(copyQueryHistory:) keyEquivalent:@""] retain];
	[copyHistoryMenuItem setTag:SPPostgresHistoryCopyTag];
	[copyHistoryMenuItem setKeyEquivalentModifierMask:NSEventModifierFlagOption];
	[copyHistoryMenuItem setToolTip:NSLocalizedString(@"Copy all history items onto the clipboard.", @"Postgres query history: copy history tooltip")];
	[copyHistoryMenuItem setTarget:self];

	saveHistoryMenuItem = [[menu addItemWithTitle:NSLocalizedString(@"Save History…", @"Postgres query history: save history menu item") action:@selector(saveQueryHistory:) keyEquivalent:@""] retain];
	[saveHistoryMenuItem setTag:SPPostgresHistorySaveTag];
	[saveHistoryMenuItem setKeyEquivalentModifierMask:0];
	[saveHistoryMenuItem setAlternate:YES];
	[saveHistoryMenuItem setToolTip:NSLocalizedString(@"Save all history items to file. Press ⌥ to copy all history items onto the clipboard.", @"Postgres query history: save history tooltip")];
	[saveHistoryMenuItem setTarget:self];

	// As MySQL's -validateMenuItem: for an untitled document
	clearHistoryMenuItem = [[menu addItemWithTitle:NSLocalizedString(@"Clear Global History", @"clear global history menu item title") action:@selector(clearQueryHistory:) keyEquivalent:@""] retain];
	[clearHistoryMenuItem setTag:SPPostgresHistoryClearTag];
	[clearHistoryMenuItem setToolTip:NSLocalizedString(@"Clear the global history list", @"clear the global history list tooltip message")];
	[clearHistoryMenuItem setTarget:self];

	[menu addItem:[NSMenuItem separatorItem]];

	// The filter (DBView.xib's "Query History Search" view), as the item's view. No recents autosave name: that would
	// write the standard preferences
	NSView *searchView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 217, 20)] autorelease];
	historySearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, 1, 176, 19)];
	[[historySearchField cell] setControlSize:NSControlSizeSmall];
	[historySearchField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[historySearchField cell] setPlaceholderString:NSLocalizedString(@"Filter", @"filter label")];
	[[historySearchField cell] setScrollable:YES];
	[[historySearchField cell] setUsesSingleLineMode:YES];
	[[historySearchField cell] setSendsSearchStringImmediately:YES];
	[historySearchField setFocusRingType:NSFocusRingTypeNone];
	[historySearchField setTarget:self];
	[historySearchField setAction:@selector(filterQueryHistory:)];
	[searchView addSubview:historySearchField];
	NSMenuItem *searchItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
	[searchItem setView:searchView];

	[menu addItem:[NSMenuItem separatorItem]];

	[historyButton setTarget:self];
	[historyButton setAction:@selector(chooseQueryHistory:)];
	[self _updateHistoryItems];
}

- (void)setHistoryStore:(SPPostgresQueryStore *)store
{
	if (store == historyStore) return;
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	if (historyStore) [center removeObserver:self name:SPPostgresQueryStoreDidChangeNotification object:historyStore];
	[historyStore release];
	historyStore = [store retain];
	if (invalidated) return;
	if (historyStore) [center addObserver:self selector:@selector(_historyStoreDidChange:) name:SPPostgresQueryStoreDidChangeNotification object:historyStore];
	currentHistoryOffsetIndex = -1;
	historySaveErrorReported = NO;
	[self _reloadHistoryMenu];
}

/// The store's entries (its strings), most recent first.
- (NSArray<NSString *> *)_storedHistory
{
	NSMutableArray *entries = [NSMutableArray array];
	for (id item in [historyStore items] ?: @[]) {
		if ([item isKindOfClass:[NSString class]]) [entries addObject:item];
	}
	return entries;
}

- (void)_historyStoreDidChange:(NSNotification *)notification
{
	if (invalidated) return;
	[self _reloadHistoryMenu];
}

/// The menu's entries, from the store when it changed (another tab, or another copy of the app, may have written it).
- (void)_reloadHistoryMenuIfChanged
{
	if (![[self _storedHistory] isEqualToArray:historyEntries]) [self _reloadHistoryMenu];
}

/// As MySQL's -historyItemsHaveBeenUpdated:: the entries after the filter, then the filter is applied again.
- (void)_reloadHistoryMenu
{
	if (invalidated) return;
	NSArray *entries = [self _storedHistory];
	[historyEntries release];
	historyEntries = [entries copy];

	NSMenu *menu = [historyButton menu];
	while ([menu numberOfItems] > SPPostgresHistoryFirstEntryIndex) [menu removeItemAtIndex:[menu numberOfItems] - 1];
	for (NSString *entry in historyEntries) {
		NSString *title = ([entry length] > SPPostgresHistoryTitleLength) ? [NSString stringWithFormat:@"%@…", [entry substringToIndex:SPPostgresHistoryTitleLength - 1]] : entry;
		NSString *toolTip = ([entry length] > SPPostgresHistoryToolTipLength) ? [NSString stringWithFormat:@"%@…", [entry substringToIndex:SPPostgresHistoryToolTipLength - 1]] : entry;
		NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:@selector(chooseQueryHistory:) keyEquivalent:@""] autorelease];
		[item setTarget:self];
		[item setToolTip:toolTip];
		[item setRepresentedObject:entry];
		[menu addItem:item];
	}
	[self _updateHistoryItems];
	[self filterQueryHistory:nil];
}

/// As MySQL's -validateMenuItem:: Copy, Save and Clear while there is history.
- (void)_updateHistoryItems
{
	BOOL hasHistory = [historyEntries count] > 0;
	[copyHistoryMenuItem setEnabled:hasHistory];
	[saveHistoryMenuItem setEnabled:hasHistory];
	[clearHistoryMenuItem setEnabled:hasHistory];
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
	if (invalidated) return;
	if (menu == [historyButton menu]) [self _reloadHistoryMenuIfChanged];
	if (menu == [favoritesButton menu]) [self _updateFavoritesMenu];
}

/// As MySQL's -addHistory:forFileURL: (SPQueryController): first, without duplicates, capped at the history size.
- (void)_addHistoryEntry:(NSString *)entry
{
	if (invalidated || !historyStore || ![entry length]) return;
	NSInteger maxItems = [defaults integerForKey:SPCustomQueryMaxHistoryItems];
	// A history size of 0 records nothing (and keeps what is stored)
	if (maxItems <= 0) return;

	NSMutableArray *entries = [NSMutableArray arrayWithArray:[self _storedHistory]];
	[entries removeObject:entry];
	[entries insertObject:entry atIndex:0];
	if ([entries count] > (NSUInteger)maxItems) [entries removeObjectsInRange:NSMakeRange(maxItems, [entries count] - maxItems)];

	NSError *error = nil;
	if (![historyStore setItems:entries error:&error]) {
		// Reported once (not after every run); the file is left as it is
		if (!historySaveErrorReported) {
			historySaveErrorReported = YES;
			[self _presentHistoryError:error title:NSLocalizedString(@"The query could not be added to the history.", @"Postgres query history: add failed")];
		}
	}
}

/// The entries joined with ";\n", as MySQL's -buildHistoryString.
- (NSString *)_historyString
{
	[self _reloadHistoryMenuIfChanged];
	return [historyEntries componentsJoinedByString:@";\n"];
}

/// Inserts text in range of the editor, undoably (as typing it would). Callers then update the run button's title
/// and the gear's items (-_editorChangedByGear).
- (void)_insertEditorText:(NSString *)text inRange:(NSRange)range
{
	[editor breakUndoCoalescing];
	[editor insertText:text replacementRange:range];
	[editor breakUndoCoalescing];
}

- (IBAction)chooseQueryHistory:(id)sender
{
	if (invalidated) return;

	NSString *entry = nil;
	if ([sender isKindOfClass:[NSMenuItem class]]) {
		entry = [(NSMenuItem *)sender representedObject];
	}
	else {
		NSInteger index = [historyButton indexOfSelectedItem] - SPPostgresHistoryFirstEntryIndex;
		if (index >= 0 && index < (NSInteger)[historyEntries count]) entry = [historyEntries objectAtIndex:index];
	}
	if (![entry isKindOfClass:[NSString class]]) return;

	// As MySQL's: History Replaces Editor Content, inverted while a modifier key is held
	BOOL replaceContent = [defaults boolForKey:SPQueryHistoryReplacesContent];
	if ([[NSApp currentEvent] modifierFlags] & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
		replaceContent = !replaceContent;
	}
	NSRange range = replaceContent ? NSMakeRange(0, [[editor string] length]) : [editor selectedRange];
	[self _insertEditorText:entry inRange:range];
	[self _editorChangedByGear];
}

/// Previous (step 1) / Next (step -1) Query from History, as MySQL's -gearMenuItemSelected:: the entry is inserted at
/// the caret (over the selection, so over the entry inserted before) and selected; past either end: a beep.
- (void)_insertHistoryEntryAtOffsetStep:(NSInteger)step
{
	[self _reloadHistoryMenuIfChanged];
	NSInteger count = (NSInteger)[historyEntries count];
	currentHistoryOffsetIndex += step;
	if (count > 0 && currentHistoryOffsetIndex >= 0 && currentHistoryOffsetIndex < count) {
		historyItemWasJustInserted = YES;
		NSString *entry = [historyEntries objectAtIndex:currentHistoryOffsetIndex];
		NSRange selection = [editor selectedRange];
		[self _insertEditorText:entry inRange:selection];
		[editor setSelectedRange:NSMakeRange(selection.location, [entry length])];
		[self _editorChangedByGear];
	}
	else {
		currentHistoryOffsetIndex -= step;
		[self _beep];
	}
	historyItemWasJustInserted = NO;
}

- (void)_beep
{
	if (beepHook) beepHook();
	else NSBeep();
}

/// Test seam (see the tests' SPPostgresQueryController (HistoryTesting)).
- (void)setBeepHook:(void (^)(void))hook
{
	if (hook == beepHook) return;
	[beepHook release];
	beepHook = [hook copy];
}

- (IBAction)copyQueryHistory:(id)sender
{
	if (invalidated) return;
	NSPasteboard *pb = pasteboard ?: [NSPasteboard generalPasteboard];
	[pb declareTypes:@[NSPasteboardTypeString] owner:nil];
	[pb setString:[self _historyString] forType:NSPasteboardTypeString];
}

- (IBAction)saveQueryHistory:(id)sender
{
	if (invalidated) return;
	NSString *history = [self _historyString];

	if (savePathProvider) {
		NSString *path = savePathProvider(@"history.sql");
		if (path) [self _writeHistory:history toURL:[NSURL fileURLWithPath:path]];
		return;
	}

	NSSavePanel *panel = [NSSavePanel savePanel];
	[panel setAllowedFileTypes:@[SPFileExtensionSQL]];
	[panel setExtensionHidden:NO];
	[panel setAllowsOtherFileTypes:YES];
	[panel setCanSelectHiddenExtension:YES];
	[panel setCanCreateDirectories:YES];
	[panel setNameFieldStringValue:@"history"];

	void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
		if (response == NSModalResponseOK && !invalidated) [self _writeHistory:history toURL:[panel URL]];
	};
	NSWindow *window = [view window];
	if (window && ![window attachedSheet]) [panel beginSheetModalForWindow:window completionHandler:completion];
	else completion([panel runModal]);
}

/// Writes history (UTF-8); a failure is shown.
- (void)_writeHistory:(NSString *)history toURL:(NSURL *)url
{
	NSError *error = nil;
	if (![history writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
		[self _presentHistoryError:error title:NSLocalizedString(@"The history could not be saved.", @"Postgres query history: save failed")];
	}
}

- (IBAction)clearQueryHistory:(id)sender
{
	if (invalidated) return;

	// As MySQL's, for an untitled document (every Postgres tab: its history is global)
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Clear History?", @"clear history message")];
	[alert setInformativeText:NSLocalizedString(@"Are you sure you want to clear the global history list? This action cannot be undone.", @"clear global history list informative message")];
	[alert setAlertStyle:NSAlertStyleCritical];
	NSButton *clearButton = [alert addButtonWithTitle:NSLocalizedString(@"Clear", @"clear button")];
	NSButton *cancelButton = [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	// As MySQL's: Cancel has the return key, Clear ⌘R
	[clearButton setKeyEquivalent:@"r"];
	[clearButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[cancelButton setKeyEquivalent:@"\r"];

	[self _confirm:alert completion:^(BOOL confirmed) {
		if (!confirmed || invalidated) return;
		NSError *error = nil;
		// User-confirmed: an unreadable history file is moved aside and replaced (Ruling 7)
		if (![historyStore replaceItems:@[] error:&error]) {
			[self _presentHistoryError:error title:NSLocalizedString(@"The history could not be cleared.", @"Postgres query history: clear failed")];
		}
	}];
}

/// As MySQL's -filterQueryHistory:: the entries that don't contain the filter's text (case-insensitive, as text, not
/// a pattern) are hidden, and stay in the menu.
- (IBAction)filterQueryHistory:(id)sender
{
	if (invalidated) return;
	NSString *filter = [historySearchField stringValue] ?: @"";
	NSMenu *menu = [historyButton menu];
	for (NSInteger i = SPPostgresHistoryFirstEntryIndex; i < [menu numberOfItems]; i++) {
		NSUInteger entryIndex = i - SPPostgresHistoryFirstEntryIndex;
		NSString *entry = (entryIndex < [historyEntries count]) ? [historyEntries objectAtIndex:entryIndex] : @"";
		BOOL matches = ![filter length] || [entry rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
		[[menu itemAtIndex:i] setHidden:!matches];
	}
}

/// Shows an alert (alertPresenter, else a sheet on the view's window, else the log).
- (void)_presentAlert:(NSAlert *)alert
{
	if (invalidated) return;
	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}
	NSWindow *window = [view window];
	if (window && ![window attachedSheet]) [alert beginSheetModalForWindow:window completionHandler:nil];
	else NSLog(@"%@: %@", [alert messageText], [alert informativeText]);
}

- (void)_presentHistoryError:(NSError *)error title:(NSString *)title
{
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:title];
	NSString *detail = [error localizedDescription];
	[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres content: unknown error")];
	[self _presentAlert:alert];
}

/// Asks to confirm (confirmationPresenter, else a sheet on the view's window); completion runs once.
- (void)_confirm:(NSAlert *)alert completion:(void (^)(BOOL confirmed))completion
{
	// A heap copy, so a presenter may keep it (even without copying it) until the answer comes. It runs once and
	// then balances its own Block_copy (deferred to the autorelease pool, as it is still running).
	void (^original)(BOOL) = completion;
	__block BOOL done = NO;
	__block void (^once)(BOOL) = nil;
	once = Block_copy(^(BOOL confirmed) {
		if (done) return;
		done = YES;
		original(confirmed);
		[(id)once autorelease];
	});

	if (confirmationPresenter) {
		confirmationPresenter(alert, once);
		return;
	}
	NSWindow *window = [view window];
	if (!window || [window attachedSheet]) {
		once([alert runModal] == NSAlertFirstButtonReturn);
		return;
	}
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
		once(response == NSAlertFirstButtonReturn);
	}];
}

#pragma mark - The gear menu

/// A gear item (DBView.xib), sent to gearMenuItemSelected: unless action is given.
- (NSMenuItem *)_addGearItemTo:(NSMenu *)menu title:(NSString *)title tag:(NSInteger)tag key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers action:(SEL)action
{
	NSMenuItem *item = [menu addItemWithTitle:title action:(action ?: @selector(gearMenuItemSelected:)) keyEquivalent:key];
	[item setKeyEquivalentModifierMask:modifiers];
	[item setTag:tag];
	[item setTarget:self];
	return item;
}

/// MySQL's gear menu (DBView.xib), after its hidden image item: titles, tags, keys and tooltips as there.
- (void)_buildGearMenu:(NSMenu *)menu
{
	[menu setAutoenablesItems:NO];
	NSEventModifierFlags command = NSEventModifierFlagCommand;
	NSString *up = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
	NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
	toggleMenuItems = [[NSMutableDictionary alloc] init];

	previousHistoryMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Previous Query from History", @"Postgres query gear: previous history item")
												tag:SPPostgresGearPreviousHistoryTag key:up modifiers:NSEventModifierFlagControl action:NULL] retain];
	[previousHistoryMenuItem setToolTip:NSLocalizedString(@"Replaces the current query by the previous one coming from the history.", @"Postgres query gear: previous history item tooltip")];
	nextHistoryMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Next Query from History", @"Postgres query gear: next history item")
											tag:SPPostgresGearNextHistoryTag key:down modifiers:NSEventModifierFlagControl action:NULL] retain];
	[nextHistoryMenuItem setToolTip:NSLocalizedString(@"Replaces the current query by the next one coming from the history.", @"Postgres query gear: next history item tooltip")];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"History Replaces Editor Content", @"Postgres query gear: history replaces content toggle")
												tag:0 key:@"" modifiers:0 action:NULL] forKey:SPQueryHistoryReplacesContent];
	[menu addItem:[NSMenuItem separatorItem]];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"Favorite Replaces Editor Content", @"Postgres query gear: favorite replaces content toggle")
												tag:0 key:@"" modifiers:0 action:NULL] forKey:SPQueryFavoriteReplacesContent];
	[menu addItem:[NSMenuItem separatorItem]];

	shiftRightMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Shift Right", @"Postgres query gear: shift right")
										   tag:SPPostgresGearShiftRightTag key:@"]" modifiers:command action:NULL] retain];
	shiftLeftMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Shift Left", @"Postgres query gear: shift left")
										  tag:SPPostgresGearShiftLeftTag key:@"[" modifiers:command action:NULL] retain];
	commentLineOrSelectionMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Comment Line", @"Title of action menu item to comment line")
													   tag:SPPostgresGearCommentLineTag key:@"/" modifiers:command action:NULL] retain];
	commentCurrentQueryMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Comment Current Query", @"Postgres query gear: comment current query")
													tag:SPPostgresGearCommentQueryTag key:@"/" modifiers:command | NSEventModifierFlagOption action:NULL] retain];
	[commentCurrentQueryMenuItem setAlternate:YES];
	[commentCurrentQueryMenuItem setEnabled:NO];
	completionListMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Completion List", @"Postgres query gear: completion list")
											   tag:SPPostgresGearCompletionListTag key:@"\x1b" modifiers:0 action:NULL] retain];

	NSString *showListTitle = NSLocalizedString(@"Show Completion List", @"Postgres query gear: show completion list submenu");
	NSMenu *listMenu = [[[NSMenu alloc] initWithTitle:showListTitle] autorelease];
	NSEventModifierFlags optionCommand = command | NSEventModifierFlagOption;
	[self _addGearItemTo:listMenu title:NSLocalizedString(@"All Databases Names", @"Postgres query gear: all database names")
					 tag:SPPostgresGearAllDatabasesTag key:@"1" modifiers:optionCommand action:@selector(showCompletionList:)];
	[self _addGearItemTo:listMenu title:NSLocalizedString(@"All Table and View Names", @"Postgres query gear: all table and view names")
					 tag:SPPostgresGearAllTablesTag key:@"2" modifiers:optionCommand action:@selector(showCompletionList:)];
	[self _addGearItemTo:listMenu title:NSLocalizedString(@"All Field Names From Current Table", @"Postgres query gear: all field names")
					 tag:SPPostgresGearAllFieldsTag key:@"3" modifiers:optionCommand action:@selector(showCompletionList:)];
	NSMenuItem *listItem = [menu addItemWithTitle:showListTitle action:NULL keyEquivalent:@""];
	[listItem setSubmenu:listMenu];
	[menu addItem:[NSMenuItem separatorItem]];

	editorFontMenuItem = [[self _addGearItemTo:menu title:NSLocalizedString(@"Editor Font...", @"Postgres query gear: editor font")
										   tag:0 key:@"" modifiers:0 action:NULL] retain];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"Indent New Lines", @"Postgres query gear: indent new lines toggle")
												tag:SPPostgresGearAutoindentTag key:@"" modifiers:0 action:NULL] forKey:SPCustomQueryAutoIndent];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"Auto-pair Characters", @"Postgres query gear: auto-pair toggle")
												tag:SPPostgresGearAutopairTag key:@"" modifiers:0 action:NULL] forKey:SPCustomQueryAutoPairCharacters];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"Auto-uppercase Keywords", @"Postgres query gear: auto-uppercase toggle")
												tag:0 key:@"" modifiers:0 action:NULL] forKey:SPCustomQueryAutoUppercaseKeywords];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"Auto-completion", @"Postgres query gear: auto-completion toggle")
												tag:0 key:@"" modifiers:0 action:NULL] forKey:SPCustomQueryAutoComplete];
	[toggleMenuItems setObject:[self _addGearItemTo:menu title:NSLocalizedString(@"Update Help while typing", @"Postgres query gear: auto-help toggle")
												tag:0 key:@"" modifiers:0 action:NULL] forKey:SPCustomQueryUpdateAutoHelp];
}

/// The toggles' states, and the editor's SPTextView toggles, from defaults.
- (void)_updateToggles
{
	if (invalidated) return;
	for (NSString *key in toggleMenuItems) {
		[[toggleMenuItems objectForKey:key] setState:[defaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff];
	}
	SPPostgresTextView *textView = (SPPostgresTextView *)editor;
	[textView setAutoindent:[defaults boolForKey:SPCustomQueryAutoIndent]];
	[textView setAutopair:[defaults boolForKey:SPCustomQueryAutoPairCharacters]];
	[textView setAutouppercaseKeywords:[defaults boolForKey:SPCustomQueryAutoUppercaseKeywords]];
	[textView setAutohelp:[defaults boolForKey:SPCustomQueryUpdateAutoHelp]];
}

/// As MySQL's -textViewDidChangeSelection:: "Comment Line" or "Comment Selection", and Comment Current Query enabled
/// while the editor holds text.
- (void)_updateGearItems
{
	if (invalidated) return;
	NSString *text = [editor string];
	BOOL hasText = [text rangeOfCharacterFromSet:[[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet]].location != NSNotFound;
	[commentCurrentQueryMenuItem setEnabled:hasText];
	if ([editor selectedRange].length) {
		[commentLineOrSelectionMenuItem setTitle:NSLocalizedString(@"Comment Selection", @"Title of action menu item to comment selection")];
	}
	else {
		[commentLineOrSelectionMenuItem setTitle:NSLocalizedString(@"Comment Line", @"Title of action menu item to comment line")];
	}
}

/// After the gear changed the editor's text or selection.
- (void)_editorChangedByGear
{
	[self _updateContextualRunInterface];
	[self _updateGearItems];
}

- (IBAction)gearMenuItemSelected:(id)sender
{
	if (invalidated) return;

	// "Previous / Next Query from History" (as MySQL's: ⌃↑ the next older entry, ⌃↓ the next newer one)
	if (sender == previousHistoryMenuItem) {
		[self _insertHistoryEntryAtOffsetStep:1];
		return;
	}
	if (sender == nextHistoryMenuItem) {
		[self _insertHistoryEntryAtOffsetStep:-1];
		return;
	}

	SPPostgresTextView *textView = (SPPostgresTextView *)editor;

	// "Shift Right" / "Shift Left" (SPTextView's)
	if (sender == shiftRightMenuItem) {
		[textView shiftSelectionRight];
		[self _editorChangedByGear];
	}
	if (sender == shiftLeftMenuItem) {
		[textView shiftSelectionLeft];
		[self _editorChangedByGear];
	}

	// "Comment Line/Selection" and "Comment Current Query"
	if (sender == commentLineOrSelectionMenuItem) {
		[self _commentOut];
		[self _editorChangedByGear];
	}
	if (sender == commentCurrentQueryMenuItem) {
		[self _commentOutCurrentQueryTakingSelection:NO];
		[self _editorChangedByGear];
	}

	// "Completion List" (⌃: fuzzy)
	if (sender == completionListMenuItem) {
		BOOL fuzzy = ([[NSApp currentEvent] modifierFlags] & NSEventModifierFlagControl) != 0;
		[textView doCompletionByUsingSpellChecker:NO fuzzyMode:fuzzy autoCompleteMode:NO];
	}

	// "Editor Font..." brings up the font panel (SPTextView's -changeFont: saves the font)
	if (sender == editorFontMenuItem) {
		NSFontPanel *panel = [NSFontPanel sharedFontPanel];
		[panel setPanelFont:[editor font] isMultiple:NO];
		[panel setDelegate:self];
		[panel makeKeyAndOrderFront:self];
	}

	// The toggles: the preference flips in defaults, and the editor's toggle follows
	for (NSString *key in toggleMenuItems) {
		NSMenuItem *item = [toggleMenuItems objectForKey:key];
		if (sender != item) continue;
		BOOL enable = ![defaults boolForKey:key];
		[defaults setBool:enable forKey:key];
		[item setState:enable ? NSControlStateValueOn : NSControlStateValueOff];
		if ([key isEqualToString:SPCustomQueryAutoIndent]) [textView setAutoindent:enable];
		else if ([key isEqualToString:SPCustomQueryAutoPairCharacters]) [textView setAutopair:enable];
		else if ([key isEqualToString:SPCustomQueryAutoUppercaseKeywords]) [textView setAutouppercaseKeywords:enable];
		else if ([key isEqualToString:SPCustomQueryUpdateAutoHelp]) [textView setAutohelp:enable];
	}
}

/// As MySQL's font panel modes (SPCustomQuery).
- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel
{
	return NSFontPanelSizeModeMask | NSFontPanelCollectionModeMask;
}

- (IBAction)showCompletionList:(id)sender
{
	if (invalidated) return;
	SPPostgresTextView *textView = (SPPostgresTextView *)editor;
	NSRange insertRange = NSMakeRange([editor selectedRange].location, 0);
	switch ([sender tag]) {
		case SPPostgresGearAllDatabasesTag:
			[textView showCompletionListFor:@"$SP_ASLIST_ALL_DATABASES" atRange:insertRange fuzzySearch:NO];
			break;
		case SPPostgresGearAllTablesTag:
			[textView showCompletionListFor:@"$SP_ASLIST_ALL_TABLES" atRange:insertRange fuzzySearch:NO];
			break;
		case SPPostgresGearAllFieldsTag:
			[textView showCompletionListFor:@"$SP_ASLIST_ALL_FIELDS" atRange:insertRange fuzzySearch:NO];
			break;
	}
}

#pragma mark - Comments

/**
 * The statement Comment Current Query (un)comments: the text between the semicolons around the caret (a comment-only
 * one too, so a commented-out statement is found again), trimmed of whitespace; with the caret after a semicolon in
 * whitespace only, the one before it (as MySQL's). {NSNotFound, 0} when there is none.
 */
- (NSRange)_commentQueryRange
{
	NSString *text = [editor string] ?: @"";
	NSUInteger length = [text length];
	NSUInteger caret = MIN([editor selectedRange].location, length);

	// The semicolons outside strings, quoted identifiers and comments
	NSMutableArray *semicolons = [NSMutableArray array];
	for (SPPostgresSQLToken *token in [SPPostgresSQLTokenizer tokensInString:text range:NSMakeRange(0, length)]) {
		if ([token kind] == SPPostgresTokenOther && [token range].length == 1 && [text characterAtIndex:[token range].location] == ';') {
			[semicolons addObject:@([token range].location)];
		}
	}

	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSRange (^trimmed)(NSUInteger, NSUInteger) = ^NSRange(NSUInteger start, NSUInteger end) {
		while (start < end && [whitespace characterIsMember:[text characterAtIndex:start]]) start++;
		while (end > start && [whitespace characterIsMember:[text characterAtIndex:end - 1]]) end--;
		return (start < end) ? NSMakeRange(start, end - start) : NSMakeRange(NSNotFound, 0);
	};

	NSUInteger start = 0, end = length, previousStart = 0;
	BOOL afterSemicolon = NO;
	for (NSNumber *semicolon in semicolons) {
		NSUInteger location = [semicolon unsignedIntegerValue];
		if (location < caret) {
			previousStart = start;
			start = location + 1;
			afterSemicolon = YES;
		}
		else {
			end = location;
			break;
		}
	}

	NSRange range = trimmed(start, end);
	if (range.location == NSNotFound && afterSemicolon) range = trimmed(previousStart, start - 1);
	return range;
}

/**
 * The text escaped so that it holds no comment delimiter: a backslash is inserted between "/" and "*", and between "*"
 * and "/" (so "/ *" reads "/\*" and "* /" reads "*\/", spaces added here); also after a "/" or "*" followed by a backslash, so that
 * -_unescapedCommentText: restores the text exactly. PostgreSQL's block comments nest, and quotes mean nothing inside
 * one, so an escaped "/ *" (in a comment or a string) can't leave the wrapping comment open.
 */
+ (NSString *)_escapedCommentText:(NSString *)text
{
	NSUInteger length = [text length];
	NSMutableString *escaped = [NSMutableString stringWithCapacity:length + 8];
	for (NSUInteger i = 0; i < length; i++) {
		unichar c = [text characterAtIndex:i];
		[escaped appendFormat:@"%C", c];
		if ((c == '/' || c == '*') && i + 1 < length) {
			unichar next = [text characterAtIndex:i + 1];
			if ((c == '/' && next == '*') || (c == '*' && next == '/') || next == '\\') [escaped appendString:@"\\"];
		}
	}
	return escaped;
}

/// The inverse of +_escapedCommentText:: a backslash right after a "/" or "*" is dropped.
+ (NSString *)_unescapedCommentText:(NSString *)text
{
	NSUInteger length = [text length];
	NSMutableString *unescaped = [NSMutableString stringWithCapacity:length];
	for (NSUInteger i = 0; i < length; i++) {
		unichar c = [text characterAtIndex:i];
		[unescaped appendFormat:@"%C", c];
		if ((c == '/' || c == '*') && i + 1 < length && [text characterAtIndex:i + 1] == '\\') i++;
	}
	return unescaped;
}

/**
 * As MySQL's -commentOutCurrentQueryTakingSelection: (SPCustomQuery.m): wraps the current statement (or the selection)
 * in a block comment ("/ * " … " * /"), its delimiters escaped (+_escapedCommentText:: PostgreSQL's comments nest, so
 * MySQL's escaping of "* /" alone would leave the comment open after an inner "/ *"); or, when it is one block comment
 * already, unwraps and unescapes it, restoring what was wrapped. After wrapping, the caret goes after the opening "/ *".
 */
- (void)_commentOutCurrentQueryTakingSelection:(BOOL)takeSelection
{
	NSRange workingRange = takeSelection ? [editor selectedRange] : [self _commentQueryRange];
	if (workingRange.location == NSNotFound || !workingRange.length) {
		NSBeep();
		return;
	}

	NSString *text = [[editor string] substringWithRange:workingRange];
	if ([text hasSuffix:@"\n"]) {
		workingRange.length--;
		text = [text substringToIndex:[text length] - 1];
	}

	// Already one block comment (whitespace around it aside): uncomment it
	NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSArray *tokens = [SPPostgresSQLTokenizer tokensInString:trimmed range:NSMakeRange(0, [trimmed length])];
	BOOL isUncomment = [tokens count] == 1 && [(SPPostgresSQLToken *)[tokens firstObject] kind] == SPPostgresTokenComment
		&& [trimmed hasPrefix:@"/*"] && [trimmed hasSuffix:@"*/"] && [trimmed length] >= 4;

	NSString *replacement;
	if (isUncomment) {
		NSString *body = [trimmed substringWithRange:NSMakeRange(2, [trimmed length] - 4)];
		if ([body hasPrefix:@" "]) body = [body substringFromIndex:1];
		if ([body hasSuffix:@" "]) body = [body substringToIndex:[body length] - 1];
		replacement = [[self class] _unescapedCommentText:body];
		workingRange = NSMakeRange(workingRange.location + [text rangeOfString:trimmed].location, [trimmed length]);
	}
	else {
		replacement = [NSString stringWithFormat:@"/* %@ */", [[self class] _escapedCommentText:text]];
	}

	// Replace current query/selection by (un)commented string
	[editor setSelectedRange:workingRange];
	[editor insertText:replacement replacementRange:workingRange];

	// If commenting out locate the caret just after the first /*
	if (!isUncomment) [editor setSelectedRange:NSMakeRange(workingRange.location + 2, 0)];
}

/**
 * As MySQL's -commentOut (SPCustomQuery.m), without MySQL's # comments: with a selection, -_commentOutCurrentQuery…;
 * otherwise "-- " is added at the start of the caret's line, or removed (keeping the indentation) when the line is a
 * "-- " comment or a single / * * / one. The caret goes to the next line.
 */
- (void)_commentOut
{
	NSRange oldRange = [editor selectedRange];

	if (oldRange.length) {
		[self _commentOutCurrentQueryTakingSelection:YES];
		return;
	}

	NSString *text = [editor string];
	NSRange lineRange = [text lineRangeForRange:oldRange];
	NSMutableString *n = [NSMutableString stringWithFormat:@"-- %@", [text substringWithRange:lineRange]];

	// Already commented out: uncomment it, keeping the original indentation
	if (SPPostgresMatches(n, @"^-- \\s*--\\s")) {
		NSString *indentation = SPPostgresCapture(n, @"^-- (\\s*)", 1);
		SPPostgresReplace(n, @"^-- \\s*--\\s", [NSRegularExpression escapedTemplateForString:indentation]);
	}
	else if (SPPostgresMatches(n, @"^-- \\s*/\\*.*? ?\\*/\\s*$")) {
		NSString *indentation = SPPostgresCapture(n, @"^-- (\\s*)", 1);
		SPPostgresReplace(n, @"^-- \\s*/\\* ?", [NSRegularExpression escapedTemplateForString:indentation]);
		NSString *trailing = SPPostgresCapture(n, @" ?\\*/(\\s*)$", 1);
		SPPostgresReplace(n, @" ?\\*/\\s*$", [NSRegularExpression escapedTemplateForString:trailing]);
	}

	// Replace the line; the caret goes to the start of the next line, to (un)comment lines one after another
	[editor setSelectedRange:lineRange];
	[editor insertText:n replacementRange:lineRange];
}

#pragma mark - Help

/**
 * What the help is shown for: the selection, or the word at the caret (SPTextView's -getRangeForCurrentWord) and the
 * words after it ("create table", tried before "create"); nil when there is none.
 */
- (NSString *)_helpSearchString
{
	NSString *text = [editor string];
	NSRange wordRange = [editor getRangeForCurrentWord];
	if (wordRange.location == NSNotFound || !wordRange.length || NSMaxRange(wordRange) > [text length]) return nil;
	NSString *word = [text substringWithRange:wordRange];
	if ([editor selectedRange].length) return word;

	NSMutableArray *words = [NSMutableArray arrayWithObject:word];
	NSUInteger restLength = MIN((NSUInteger)200, [text length] - NSMaxRange(wordRange));
	for (SPPostgresSQLToken *token in [SPPostgresSQLTokenizer tokensInString:text range:NSMakeRange(NSMaxRange(wordRange), restLength)]) {
		if ([token kind] == SPPostgresTokenWhitespace) continue;
		if ([token kind] != SPPostgresTokenKeyword && [token kind] != SPPostgresTokenIdentifier) break;
		[words addObject:[text substringWithRange:[token range]]];
		if ([words count] > SPPostgresHelpFollowingWords) break;
	}
	return [words componentsJoinedByString:@" "];
}

- (void)showAutoHelpForCurrentWord:(id)sender
{
	if (invalidated || !helpHandler) return;
	NSString *searchString = [self _helpSearchString];
	if ([searchString length]) helpHandler(searchString, YES);
}

- (void)showHelpForCurrentWord:(id)sender
{
	if (invalidated || !helpHandler) {
		NSBeep();
		return;
	}
	NSString *searchString = [self _helpSearchString];
	if ([searchString length]) helpHandler(searchString, NO);
	else NSBeep();
}

- (void)helpWindowClosedByUser:(NSNotification *)notification
{
	if (invalidated) return;
	// As MySQL's: Update Help while typing is turned off, so the window isn't reopened on key presses
	[defaults setBool:NO forKey:SPCustomQueryUpdateAutoHelp];
	[[toggleMenuItems objectForKey:SPCustomQueryUpdateAutoHelp] setState:NSControlStateValueOff];
	[(SPPostgresTextView *)editor setAutohelp:NO];
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

#pragma mark - Status line and info pane

/**
 * A failed statement's error text: the server's message, then its DETAIL and HINT lines (as psql). Called on the
 * thread that ran the statement.
 */
+ (NSString *)_errorTextForError:(PGPostgresError *)error fallback:(NSString *)fallback
{
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *message = [[error errorPrimaryMessage] stringByTrimmingCharactersInSet:whitespace];
	if (![message length]) message = [fallback stringByTrimmingCharactersInSet:whitespace];
	if (![message length]) message = NSLocalizedString(@"An unknown error occurred.", @"Postgres query: unknown error");

	return [message stringByAppendingString:SPPostgresErrorDetailLines(error)];
}

/// The status line for run, in MySQL's words (SPCustomQuery.m, after the queries have run).
+ (NSString *)_statusTextForRun:(SPPostgresQueryRun *)run
{
	NSString *statusErrorString = [[run errors] length] ? NSLocalizedString(@"Errors", @"Errors title") : NSLocalizedString(@"No errors", @"No errors title");
	NSString *time = [NSString stringForTimeInterval:[run executionTime]];
	NSUInteger queriesRun = [[run ranStatements] count];
	NSString *statusString;

	if ([run cancelled]) {
		// As MySQL's: by totalQueriesRun, the statements sent (the interrupted one too)
		if (queriesRun > 1) {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%@; Cancelled in query %ld, after %@", @"text showing multiple queries were cancelled"),
							statusErrorString, (long)queriesRun, time];
		}
		else {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%@; Cancelled after %@", @"text showing a query was cancelled"),
							statusErrorString, time];
		}
	}
	else if (queriesRun > 1) {
		if ([run affectedRows] == 1) {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%@; 1 row affected in total, by %ld queries taking %@", @"text showing one row has been affected by multiple queries"),
							statusErrorString, (long)queriesRun, time];
		}
		else {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%@; %ld rows affected in total, by %ld queries taking %@", @"text showing how many rows have been affected by multiple queries"),
							statusErrorString, (long)[run affectedRows], (long)queriesRun, time];
		}
	}
	else {
		if ([run affectedRows] == 1) {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%@; 1 row affected", @"text showing one row has been affected by a single query"),
							statusErrorString];
		}
		else {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%@; %ld rows affected", @"text showing how many rows have been affected by a single query"),
							statusErrorString, (long)[run affectedRows]];
		}
		// As MySQL's: a row set with rows (the grid's) counts the time to its first row
		if ([[run rowsResult] numberOfRows]) {
			statusString = [statusString stringByAppendingFormat:NSLocalizedString(@", first row available after %1$@", @"Custom Query : text appended to the “x row(s) affected” messages. $1 is a time interval"), time];
		}
		else {
			statusString = [statusString stringByAppendingFormat:NSLocalizedString(@", taking %1$@", @"Custom Query : text appended to the “x row(s) affected” messages (for update/delete queries). $1 is a time interval"), time];
		}
	}

	return statusString;
}

/// The Postgres-only notes on run, one per line: COPY output not shown, the grid's rows being an earlier statement's,
/// an aborted transaction.
+ (NSArray *)_notesForRun:(SPPostgresQueryRun *)run
{
	NSMutableArray *notes = [NSMutableArray arrayWithArray:[run discardedOutputNotes]];

	// After a row set, other statements ran: the rows are the earlier statement's (said of a run that completed; an
	// error, a cancel too, is what the pane reports then)
	NSUInteger shown = [run shownStatement];
	if (shown && shown != [[run ranStatements] count] && ![[run errors] length]) {
		[notes addObject:[NSString stringWithFormat:NSLocalizedString(@"Note: results shown from statement %lu, the last one that returned rows.", @"Postgres query: the grid's rows are from an earlier statement (number)"), (unsigned long)shown]];
	}

	// The user's own BEGIN … : nothing more runs in it until they roll back
	if ([run transactionStatus] == PGPostgresTransactionInError) {
		[notes addObject:NSLocalizedString(@"The current transaction is aborted; ROLLBACK to continue.", @"Postgres query: aborted transaction note")];
	}

	return notes;
}

/// The info pane's text for run: as MySQL's updateStatusInterfaceWithDetails:, then the Postgres notes.
+ (NSString *)_infoPaneTextForRun:(SPPostgresQueryRun *)run
{
	NSString *text;
	if ([[run errors] length]) text = [[run errors] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	else text = NSLocalizedString(@"There were no errors.", @"text shown when query was successfull");

	NSArray *notes = [self _notesForRun:run];
	if ([notes count]) text = [text stringByAppendingFormat:@"\n%@", [notes componentsJoinedByString:@"\n"]];
	return text;
}

/// As MySQL's -updateStatusInterfaceWithDetails:: the title and text of the info pane, which opens on an error and
/// closes otherwise.
- (void)_updateStatusInterfaceForRun:(SPPostgresQueryRun *)run
{
	BOOL hasErrors = [[run errors] length] > 0;
	if (hasErrors) [infoPaneTitle setStringValue:NSLocalizedString(@"Last Error Message", @"Last Error Message")];
	[infoPaneText setString:[SPPostgresQueryController _infoPaneTextForRun:run]];
	if (hasErrors) [infoPaneText scrollRangeToVisible:NSMakeRange([[infoPaneText string] length], 0)];

	BOOL collapsed = [infoPaneSplitView isCollapsibleSubviewCollapsed];
	if (hasErrors == collapsed) [infoPaneSplitView setCollapsibleSubviewCollapsed:!hasErrors animate:infoPaneAnimates];
}

/**
 * The work of a run, on the runner's thread: runs the statements in order on connection, filling in run as it goes.
 * The first error stops the run, as does a cancel (between statements, or interrupting one). Uses only its
 * arguments (a class method: never the controller's views or state).
 */
+ (void)_runStatements:(NSArray *)statements onConnection:(PGPostgresConnection *)connection runner:(SPPostgresTaskRunner *)runner
				logger:(SPPostgresConsoleLogger *)logger hook:(void (^)(NSString *statement))hook
			  progress:(void (^)(NSString *description))progress into:(SPPostgresQueryRun *)run
{
	NSUInteger total = [statements count];
	NSUInteger number = 0;

	[run setStarted:YES];
	[run setTotal:total];

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
				// Stopped before this statement was sent
				[run setCancelled:YES];
				break;
			}
			number++;

			if (total > 1) {
				NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Running query %ld of %lu...", @"Running multiple queries string"), (long)number, (unsigned long)total];
				[runner updateDescription:description];
				if (progress) progress(description);
			}

			if (hook) hook(statement);

			// A new error object is made for each failed query: compare with the previous one to know if this
			// statement left one (a lost connection may leave none)
			PGPostgresError *previousError = [[[connection lastError] retain] autorelease];
			PGPostgresResult *statementResult = nil;
			NSString *exceptionReason = nil;

			// As MySQL's: the statement counts as run (and is timed) whether it succeeds or not
			[[run ranStatements] addObject:statement];
			CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
			@try {
				statementResult = [connection execute:statement];
			}
			@catch (NSException *exception) {
				statementResult = nil;
				exceptionReason = [exception reason];
			}
			[run setExecutionTime:[run executionTime] + (CFAbsoluteTimeGetCurrent() - startTime)];

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

				// MySQL's errors text; a run still stops at its first error, so that is "Execution stopped!" when
				// statements remain (MySQL's Stop)
				NSString *errorText = [self _errorTextForError:error fallback:fallback];
				if (total > 1) {
					[[run errors] appendFormat:NSLocalizedString(@"[ERROR in query %ld] %@\n", @"error text when multiple custom query failed"), (long)number, errorText];
					if (number < total) [[run errors] appendString:NSLocalizedString(@"Execution stopped!\n", @"execution stopped message")];
				}
				else {
					[[run errors] setString:errorText];
				}
				[logger logError:errorText];
				break;
			}

			if (![run schemaChanged]) [run setSchemaChanged:[self statementMayChangeSchema:statement]];
			if (![run dataChanged]) [run setDataChanged:[self statementMayChangeData:statement]];

			// As MySQL's totalAffectedRows: a row set's rows, a command's affected rows
			[run setAffectedRows:[run affectedRows] + [statementResult numberOfRows]];
			if ([statementResult returnsRows]) {
				[run setRowsResult:statementResult];
				[run setShownStatement:number];
			}
			else if ([statementResult copyOutputDiscarded]) {
				NSString *note = [NSString stringWithFormat:NSLocalizedString(@"%@ – output not shown", @"Postgres query: COPY TO STDOUT status (command status)"), [statementResult commandStatus]];
				if (total > 1) note = [NSString stringWithFormat:NSLocalizedString(@"[query %lu] %@", @"Postgres query: a statement's note (statement number, note)"), (unsigned long)number, note];
				[[run discardedOutputNotes] addObject:note];
			}
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
 * the run. The status line and the info pane then describe the run in MySQL's words (see the class comment).
 * Cancelled, the grid shows the last row set returned before the cancel; what ran before the cancel is still
 * reported through runDidChangeDatabase.
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

	// As MySQL's: the info pane says the run has started (without opening), and the status line is cleared
	[infoPaneTitle setStringValue:NSLocalizedString(@"Query Status", @"Query Status")];
	[infoPaneText setString:description];
	[self setStatusText:@""];
	[statusField setStringValue:@""];
	[statusField setToolTip:nil];

	// As MySQL's (SPCustomQuery.m, its progress updater): the info pane follows the statement running, on the main
	// thread (before the completion, which is delivered after it on the main queue)
	void (^progress)(NSString *) = ^(NSString *text) {
		void (^apply)(void) = ^{
			if (!invalidated && running) [infoPaneText setString:text];
		};
		if ([NSThread isMainThread]) apply();
		else dispatch_async(dispatch_get_main_queue(), apply);
	};

	[runner runTaskWithDescription:description cancelTitle:cancelTitle work:^id(PGPostgresConnection *theConnection, NSError **error) {
		[SPPostgresQueryController _runStatements:theStatements onConnection:theConnection runner:runner logger:logger hook:hook progress:progress into:run];
		[run setTransactionStatus:[theConnection transactionStatus]];
		return run;
	} completion:^(id result, NSError *error, BOOL cancelled) {
		// Whatever happens, the next run is possible (the work restored the logging flag itself)
		running = NO;

		// Raised on the runner's thread: the inline runner's caller rethrows it below; otherwise it is reported here
		if ([run exception] && ![runner isInline]) [NSApp reportException:[run exception]];

		if (invalidated) return;

		// Cancelled only when the cancel stopped the run (as MySQL's lastQueryWasCancelled), or kept it from starting;
		// a cancel after every statement had run keeps the run's own status
		if (cancelled && ![run started]) {
			[run setTotal:total];
			[run setCancelled:YES];
		}
		// As MySQL's: a cancel is an error ("Query cancelled.", "[ERROR in query K] Query cancelled." in a run of
		// several statements, K the statements sent; none sent: the message alone)
		if ([run cancelled]) {
			NSString *cancelText = NSLocalizedString(@"Query cancelled.", @"Query cancelled error");
			NSUInteger sent = [[run ranStatements] count];
			if ([run total] > 1 && sent) {
				[[run errors] appendFormat:NSLocalizedString(@"[ERROR in query %ld] %@\n", @"error text when multiple custom query failed"), (long)sent, cancelText];
			}
			else {
				[[run errors] setString:cancelText];
			}
		}
		[self _showResult:[run rowsResult]];
		lastRunTransactionStatus = [run transactionStatus];
		// As MySQL's usedQuery, recorded (and added to the history) only when a statement was sent
		if ([[run ranStatements] count]) {
			NSString *usedQuery = [[run ranStatements] componentsJoinedByString:@";\n"];
			[self setLastRunQueryText:usedQuery];
			[self _addHistoryEntry:usedQuery];
		}
		NSString *status = [SPPostgresQueryController _statusTextForRun:run];
		[self setStatusText:status];
		[statusField setStringValue:status];
		[statusField setToolTip:status];
		[self _updateStatusInterfaceForRun:run];

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
