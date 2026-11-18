//
//  SPProcessListController.m
//  sequel-pro
//
//  Created by Stuart Connolly (stuconnolly.com) on November 12, 2009.
//  Copyright (c) 2009 Stuart Connolly. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//
//  More info at <https://github.com/sequelpro/sequelpro>

#import "SPProcessListController.h"
#import "SPDatabaseDocument.h"
#import "SPAlertSheets.h"
#import "SPAppController.h"
#import "SPDataCellFormatter.h"
#import "SPThreadAdditions.h"
#import "SPConnectionSummary.h"

#import <SPMySQL/SPMySQL.h>

// Constants
static NSString *SPKillProcessQueryMode        = @"SPKillProcessQueryMode";
static NSString *SPKillProcessConnectionMode   = @"SPKillProcessConnectionMode";
static NSString *SPTableViewIDColumnIdentifier = @"Id";

static NSString * const SPKillModeKey = @"SPKillMode";
static NSString * const SPKillIdKey   = @"SPKillId";

@interface SPProcessListController ()

- (void)_processListRefreshed;
- (void)_setConnectionSummary:(SPConnectionSummary *)summary;
- (void)_updateProcessCountText;
- (void)_layOutLikePostgresServerProcesses;
- (void)_updateKillButtons;
- (void)_startAutoRefreshTimer;
- (void)_killAutoRefreshTimer;
- (void)_fireAutoRefresh:(NSTimer *)timer;
- (void)_updateSelectedAutoRefreshIntervalInterface;
- (void)_startAutoRefreshTimerWithInterval:(NSTimeInterval)interval;
- (void)_getDatabaseProcessListInBackground:(id)object;
- (void)_killProcessQueryWithId:(long long)processId;
- (void)_killProcessConnectionWithId:(long long)processId;
- (void)_updateServerProcessesFilterForFilterString:(NSString *)filterString;
- (void)_addPreferenceObservers;
- (void)_removePreferenceObservers;

@end

@implementation SPProcessListController

@synthesize connection;

#pragma mark -
#pragma mark Initialisation

- (id)init
{
	if ((self = [super initWithWindowNibName:@"DatabaseProcessList"])) {
		
		autoRefreshTimer = nil;
		processListThreadRunning = NO;
		
		showFullProcessList = [prefs boolForKey:SPProcessListShowFullProcessList];
		
		processes = [[NSMutableArray alloc] init];
		processesFiltered = processes; // weak: the list shows every process until a filter is typed
		
		prefs = [NSUserDefaults standardUserDefaults];
		
		showFullProcessList = [prefs boolForKey:SPProcessListShowFullProcessList];
	}
	
	return self;
}

- (void)awakeFromNib
{	
	[[self window] setTitle:[NSString stringWithFormat:NSLocalizedString(@"Server Processes on %@", @"server processes window title (var = hostname)"),[[SPAppDelegate frontDocument] name]]];
	
	// (The frame is remembered from -displayProcessListWindow on, once it is shown)
	
	// Show/hide table columns
	[[processListTableView tableColumnWithIdentifier:SPTableViewIDColumnIdentifier] setHidden:![prefs boolForKey:SPProcessListShowProcessID]];
	
	// Set the process table view's vertical gridlines if required
	[processListTableView setGridStyleMask:([prefs boolForKey:SPDisplayTableViewVerticalGridlines]) ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];

	// Set the strutcture and index view's font
	BOOL useMonospacedFont = [prefs boolForKey:SPUseMonospacedFonts];
	CGFloat monospacedFontSize = [prefs floatForKey:SPMonospacedFontSize] > 0 ? [prefs floatForKey:SPMonospacedFontSize] : [NSFont smallSystemFontSize];

	for (NSTableColumn *column in [processListTableView tableColumns])
	{
		[[column dataCell] setFont:useMonospacedFont ? [NSFont fontWithName:SPDefaultMonospacedFontName size:monospacedFontSize] : [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];

		// Add a formatter for linebreak display
		[[column dataCell] setFormatter:[[SPDataCellFormatter new] autorelease]];
	
		// Also, if available restore the table's column widths
		NSNumber *columnWidth = [[prefs objectForKey:SPProcessListTableColumnWidths] objectForKey:[[column headerCell] stringValue]];
				
		if (columnWidth) [column setWidth:[columnWidth floatValue]];
	}

	[self _layOutLikePostgresServerProcesses];
	[self _updateProcessCountText];
	[self _updateKillButtons];

	[self _addPreferenceObservers];
}

#pragma mark -
#pragma mark Layout

/**
 * Returns button, sized to its title (at least 90 points wide, as PostgreSQL's Server Processes buttons).
 */
- (NSButton *)_sizedButton:(NSButton *)button forTitles:(NSArray *)titles
{
	CGFloat width = 90;
	for (NSString *title in titles) {
		[button setTitle:title];
		[button sizeToFit];
		width = MAX(width, NSWidth([button frame]) + 12);
	}
	[button setTitle:[titles firstObject]];
	NSRect frame = [button frame];
	frame.size.width = width;
	[button setFrame:frame];
	return button;
}

- (NSButton *)_newButtonWithTitle:(NSString *)title action:(SEL)action target:(id)target
{
	NSButton *button = [[NSButton buttonWithTitle:title target:target action:action] retain];
	return [self _sizedButton:button forTitles:@[title]];
}

/**
 * Lays the window out as PostgreSQL's Server Processes window: the connections against the limit at the top left, the
 * filter at the top right, the list between; along the bottom the row count, Auto Refresh with how often, the ⚙︎ menu,
 * then Save As..., Refresh, Kill Query, Kill Connection and Close, 12 points apart.
 */
- (void)_layOutLikePostgresServerProcesses
{
	NSWindow *window = [self window];
	NSView *content = [window contentView];
	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	NSFont *font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
	[window setContentSize:NSMakeSize(900, 460)];
	CGFloat width = NSWidth([content bounds]);
	CGFloat height = NSHeight([content bounds]);

	// The old button bar along the bottom goes
	for (NSView *view in [content subviews]) {
		if ([view isKindOfClass:NSClassFromString(@"SPButtonBar")]) [view setHidden:YES];
	}

	// Top: the summary, the progress indicator, the filter
	[[filterProcessesSearchField cell] setControlSize:NSControlSizeRegular];
	[filterProcessesSearchField setFont:font];
	[filterProcessesSearchField setFrame:NSMakeRect(width - 240, height - 38, 220, 22)];
	[filterProcessesSearchField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
	[refreshProgressIndicator setFrame:NSMakeRect(width - 262, height - 35, 16, 16)];
	[refreshProgressIndicator setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];

	summaryLabel = [[NSTextField labelWithString:@""] retain];
	[summaryLabel setFont:smallFont];
	[summaryLabel setTextColor:[NSColor secondaryLabelColor]];
	[summaryLabel setLineBreakMode:NSLineBreakByTruncatingTail];
	[summaryLabel setFrame:NSMakeRect(20, height - 32, width - 292, 14)];
	[summaryLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[summaryLabel setHidden:YES];
	[content addSubview:summaryLabel];

	// The list
	NSScrollView *scrollView = [processListTableView enclosingScrollView];
	[scrollView setFrame:NSMakeRect(20, 52, width - 40, height - 100)];
	[scrollView setBorderType:NSBezelBorder];
	[scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// Bottom left: the row count, Auto Refresh, how often, ⚙︎
	[processesCountTextField setFrame:NSMakeRect(20, 20, 110, 14)];
	[processesCountTextField setAlignment:NSTextAlignmentLeft];
	[processesCountTextField setTextColor:[NSColor secondaryLabelColor]];
	[[processesCountTextField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[processesCountTextField setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[processesCountTextField setHidden:NO];

	[autoRefreshButton setTitle:NSLocalizedString(@"Auto Refresh", @"server processes: auto refresh checkbox")];
	[autoRefreshButton sizeToFit];
	[autoRefreshButton setFrameOrigin:NSMakePoint(NSMaxX([processesCountTextField frame]) + 12, 18)];
	[autoRefreshButton setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];

	autoRefreshIntervalPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[[autoRefreshIntervalPopUp cell] setControlSize:NSControlSizeSmall];
	[autoRefreshIntervalPopUp setFont:smallFont];
	for (NSNumber *seconds in @[@1, @2, @5, @10, @30, @60]) {
		NSString *title = [seconds integerValue] == 1
			? NSLocalizedString(@"Every second", @"server processes: auto refresh interval of one second")
			: [NSString stringWithFormat:NSLocalizedString(@"Every %ld seconds", @"server processes: auto refresh interval in seconds"), (long)[seconds integerValue]];
		[autoRefreshIntervalPopUp addItemWithTitle:title];
		NSMenuItem *item = [autoRefreshIntervalPopUp lastItem];
		[item setTag:[seconds integerValue]];
		[item setTarget:self];
		[item setAction:@selector(setAutoRefreshInterval:)];
	}
	[[autoRefreshIntervalPopUp menu] addItem:[NSMenuItem separatorItem]];
	[autoRefreshIntervalPopUp addItemWithTitle:NSLocalizedString(@"Custom…", @"server processes: custom auto refresh interval")];
	[[autoRefreshIntervalPopUp lastItem] setTag:-1];
	[[autoRefreshIntervalPopUp lastItem] setTarget:self];
	[[autoRefreshIntervalPopUp lastItem] setAction:@selector(setCustomAutoRefreshInterval:)];
	[autoRefreshIntervalPopUp sizeToFit];
	[autoRefreshIntervalPopUp setFrameOrigin:NSMakePoint(NSMaxX([autoRefreshButton frame]) + 6, 14)];
	[autoRefreshIntervalPopUp setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	[content addSubview:autoRefreshIntervalPopUp];

	// ⚙︎ keeps Show Process ID and Show FULL Process List; the interval has its own menu now
	BOOL afterFullList = NO;
	for (NSMenuItem *item in [actionsPopUp itemArray]) {
		if ([item submenu] || (afterFullList && [item isSeparatorItem])) [item setHidden:YES];
		if ([item action] == @selector(toggeleShowFullProcessList:)) afterFullList = YES;
	}
	[actionsPopUp setFrame:NSMakeRect(NSMaxX([autoRefreshIntervalPopUp frame]) + 12, 14, 36, 22)];
	[actionsPopUp setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
	CGFloat leftEdge = NSMaxX([actionsPopUp frame]);

	// Bottom right, right to left: Close, Kill Connection, Kill Query, Refresh, Save As...
	closeButton = [self _newButtonWithTitle:NSLocalizedString(@"Close", @"close button") action:@selector(performClose:) target:window];
	[closeButton setKeyEquivalent:@"\033"];
	killConnectionButton = [self _newButtonWithTitle:NSLocalizedString(@"Kill Connection", @"server processes: kill connection button") action:@selector(killProcessConnection:) target:self];
	killQueryButton = [self _newButtonWithTitle:NSLocalizedString(@"Kill Query", @"server processes: kill query button") action:@selector(killProcessQuery:) target:self];

	// The same push button as the ones made here (and PostgreSQL's)
	NSBezelStyle bezel = [closeButton bezelStyle];
	[refreshProcessesButton setButtonType:NSButtonTypeMomentaryPushIn];
	[refreshProcessesButton setBezelStyle:bezel];
	[refreshProcessesButton setImage:nil];
	[refreshProcessesButton setAlternateImage:nil];
	[refreshProcessesButton setImagePosition:NSNoImage];
	[[refreshProcessesButton cell] setControlSize:NSControlSizeRegular];
	[refreshProcessesButton setFont:font];
	[self _sizedButton:refreshProcessesButton forTitles:@[NSLocalizedString(@"Refresh", @"refresh button")]];

	[saveProcessesButton setButtonType:NSButtonTypeMomentaryPushIn];
	[saveProcessesButton setBezelStyle:bezel];
	[[saveProcessesButton cell] setControlSize:NSControlSizeRegular];
	[saveProcessesButton setFont:font];
	// Wide enough for the filtered list's title too
	[self _sizedButton:saveProcessesButton forTitles:@[NSLocalizedString(@"Save As...", @"save as button title"), NSLocalizedString(@"Save View As...", @"save view as button title")]];

	CGFloat x = width - 14;
	for (NSButton *button in @[closeButton, killConnectionButton, killQueryButton, refreshProcessesButton, saveProcessesButton]) {
		NSRect frame = [button frame];
		x -= NSWidth(frame);
		frame.origin = NSMakePoint(x, 12);
		[button setFrame:frame];
		[button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
		if ([button superview] != content) [content addSubview:button];
		x -= 12;
	}

	// Narrowest: the buttons still clear of the controls on the left
	CGFloat buttonsWidth = width - 14 - (x + 12);
	NSSize minSize = NSMakeSize(MAX(640, leftEdge + 12 + buttonsWidth + 14), 300);
	[window setContentMinSize:minSize];
	// Opens wide enough for all of it (everything above keeps its place as the window resizes)
	if (width < minSize.width) [window setContentSize:NSMakeSize(minSize.width, height)];
}

/**
 * Kill Query and Kill Connection act on one selected process.
 */
- (void)_updateKillButtons
{
	BOOL one = [processListTableView numberOfSelectedRows] == 1;
	[killQueryButton setEnabled:one];
	[killConnectionButton setEnabled:one];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self _updateKillButtons];
}

/**
 * Interface loading
 */
- (void)windowDidLoad
{
	// Update the selected auto refresh interval
	[self _updateSelectedAutoRefreshIntervalInterface];
}

#pragma mark -
#pragma mark IB action methods

/**
 * Copies the currently selected process(es) to the pasteboard.
 */
- (IBAction)copy:(id)sender
{	
	NSResponder *firstResponder = [[self window] firstResponder];
	
	if ((firstResponder == processListTableView) && ([processListTableView numberOfSelectedRows] > 0)) {
		
		NSMutableString *string = [NSMutableString string];
		NSIndexSet *rows = [processListTableView selectedRowIndexes];
		
		[rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL * _Nonnull stop) {
			if (i < [processesFiltered count]) {
				NSDictionary *process = NSArrayObjectAtIndex(processesFiltered, i);
				
				NSString *stringTmp = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@",
									   [process objectForKey:@"Id"],
									   [process objectForKey:@"User"],
									   [process objectForKey:@"Host"],
									   [process objectForKey:@"db"],
									   [process objectForKey:@"Command"],
									   [process objectForKey:@"Time"],
									   [process objectForKey:@"State"],
									   [process objectForKey:@"Info"]];
				
				[string appendString:stringTmp];
				[string appendString:@"\n"];
			}
		}];
		
		NSPasteboard *pasteBoard = [NSPasteboard generalPasteboard];
		
		// Copy the string to the pasteboard
		[pasteBoard declareTypes:@[NSStringPboardType] owner:nil];
		[pasteBoard setString:string forType:NSStringPboardType];
	}
}

/**
 * Close the current sheet
 */
- (IBAction)closeSheet:(id)sender
{
	[NSApp endSheet:[sender window] returnCode:[sender tag]];
	[[sender window] orderOut:self];
}

/**
 * If required start the auto refresh timer.
 */
- (void)showWindow:(id)sender
{
	// If the auto refresh option is enable start the timer
	if ([prefs boolForKey:SPProcessListEnableAutoRefresh]) {
		
		// Start the auto refresh time but by pass the interface updates
		[self _startAutoRefreshTimer];
	}
	
	[super showWindow:sender];
}

/**
 * Refreshes the process list.
 */
- (IBAction)refreshProcessList:(id)sender
{
	// If the document is currently performing a task (most likely threaded) on the current connection, don't
	// allow a refresh to prevent connection lock errors.
	if ([(SPDatabaseDocument *)[connection delegate] isWorking]) return;
	
	// Also, only proceed if there is not already a background thread running.
	if (processListThreadRunning) return;
	
	// Start progress Indicator
	[refreshProgressIndicator startAnimation:self];
	[refreshProgressIndicator setHidden:NO];
	
	// Disable controls
	[refreshProcessesButton setEnabled:NO];
	[saveProcessesButton setEnabled:NO];
	[filterProcessesSearchField setEnabled:NO];
	
	processListThreadRunning = YES;
		
	// Get the processes list on a background thread
	[NSThread detachNewThreadWithName:@"SPProcessListController retrieving process list" target:self selector:@selector(_getDatabaseProcessListInBackground:) object:nil];
}

/**
 * Saves the process list to the selected file.
 */
- (IBAction)saveServerProcesses:(id)sender
{
	NSSavePanel *panel = [NSSavePanel savePanel];
		
	[panel setExtensionHidden:NO];
	[panel setAllowsOtherFileTypes:YES];
	[panel setCanSelectHiddenExtension:YES];
	
    [panel setNameFieldStringValue:@"ServerProcesses"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
        if (returnCode == NSOKButton) {
            if ([processesFiltered count] > 0) {
                NSMutableString *processesString = [NSMutableString stringWithFormat:@"# MySQL server processes for %@\n\n", [[SPAppDelegate frontDocument] host]];
                
                for (NSDictionary *process in processesFiltered)
                {
                    NSString *stringTmp = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@",
                                           [process objectForKey:@"Id"],
                                           [process objectForKey:@"User"],
                                           [process objectForKey:@"Host"],
                                           [process objectForKey:@"db"],
                                           [process objectForKey:@"Command"],
                                           [process objectForKey:@"Time"],
                                           [process objectForKey:@"State"],
                                           [process objectForKey:@"Info"]];
                    
                    [processesString appendString:stringTmp];
                    [processesString appendString:@"\n"];
                }
                
                [processesString writeToURL:[panel URL] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }
    }];
}

/**
 * Kills the currently selected process' query.
 */
- (IBAction)killProcessQuery:(id)sender
{
	// No process selected. Interface validation should prevent this.
	if ([processListTableView numberOfSelectedRows] != 1) return;
	
	long long processId = [[[processesFiltered objectAtIndex:[processListTableView selectedRow]] valueForKey:@"Id"] longLongValue];
		
	NSAlert *alert = [NSAlert alertWithMessageText:NSLocalizedString(@"Kill query?", @"kill query message")
									 defaultButton:NSLocalizedString(@"Kill", @"kill button") 
								   alternateButton:NSLocalizedString(@"Cancel", @"cancel button") 
									   otherButton:nil 
						 informativeTextWithFormat:NSLocalizedString(@"Are you sure you want to kill the current query executing on connection ID %lld?\n\nPlease be aware that continuing to kill this query may result in data corruption. Please proceed with caution.", @"kill query informative message"), processId];
	
	NSArray *buttons = [alert buttons];
	
	// Change the alert's cancel button to have the key equivalent of return
	[[buttons objectAtIndex:0] setKeyEquivalent:@"k"];
	[[buttons objectAtIndex:0] setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[[buttons objectAtIndex:1] setKeyEquivalent:@"\r"];
	
	[alert setAlertStyle:NSCriticalAlertStyle];
	
	// while the alert is displayed, the results may be updated and the selectedRow may point to a different
	// row or has disappeared (= -1) by the time the didEndSelector is invoked,
	// so we must remember the ACTUAL processId we prompt the user to kill.
	NSDictionary *userInfo = @{SPKillModeKey: SPKillProcessQueryMode, SPKillIdKey: @(processId)};
	[alert beginSheetModalForWindow:[self window]
					  modalDelegate:self
					 didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:)
						contextInfo:[userInfo retain]]; //keep in mind contextInfo is a void * and not an id => no memory management here
}

/**
 * Kills the currently selected proceess' connection.
 */
- (IBAction)killProcessConnection:(id)sender
{
	// No process selected. Interface validation should prevent this.
	if ([processListTableView numberOfSelectedRows] != 1) return;
	
	long long processId = [[[processesFiltered objectAtIndex:[processListTableView selectedRow]] valueForKey:@"Id"] longLongValue];
	
	NSAlert *alert = [NSAlert alertWithMessageText:NSLocalizedString(@"Kill connection?", @"kill connection message")
									 defaultButton:NSLocalizedString(@"Kill", @"kill button") 
								   alternateButton:NSLocalizedString(@"Cancel", @"cancel button") 
									   otherButton:nil 
						 informativeTextWithFormat:NSLocalizedString(@"Are you sure you want to kill connection ID %lld?\n\nPlease be aware that continuing to kill this connection may result in data corruption. Please proceed with caution.", @"kill connection informative message"), processId];
	
	NSArray *buttons = [alert buttons];
	
	// Change the alert's cancel button to have the key equivalent of return
	[[buttons objectAtIndex:0] setKeyEquivalent:@"k"];
	[[buttons objectAtIndex:0] setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
	[[buttons objectAtIndex:1] setKeyEquivalent:@"\r"];
	
	[alert setAlertStyle:NSCriticalAlertStyle];
	
	// while the alert is displayed, the results may be updated and the selectedRow may point to a different
	// row or has disappeared (= -1) by the time the didEndSelector is invoked,
	// so we must remember the ACTUAL processId we prompt the user to kill.
	NSDictionary *userInfo = @{SPKillModeKey: SPKillProcessConnectionMode, SPKillIdKey: @(processId)};
	[alert beginSheetModalForWindow:[self window]
					  modalDelegate:self
					 didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:)
						contextInfo:[userInfo retain]]; //keep in mind contextInfo is a void * and not an id => no memory management here
}

/**
 * Toggles the display of the process ID table column.
 */
- (IBAction)toggleShowProcessID:(NSMenuItem *)sender
{
	[[processListTableView tableColumnWithIdentifier:SPTableViewIDColumnIdentifier] setHidden:([sender state])];
}

/**
 * Toggles the display of the FULL process list.
 */
- (IBAction)toggeleShowFullProcessList:(NSMenuItem *)sender
{
	showFullProcessList = (!showFullProcessList);

	[self refreshProcessList:self];
}

/**
 * Toggles whether or not auto refresh is enabled.
 */
- (IBAction)toggleProcessListAutoRefresh:(NSButton *)sender
{
	BOOL enable = [sender state];
	
	// Enable/Disable the refresh button
	[refreshProcessesButton setEnabled:(!enable)];
	[autoRefreshIntervalPopUp setEnabled:enable];
	
	(enable) ? [self _startAutoRefreshTimer] : [self _killAutoRefreshTimer];
}

/**
 * Changes the auto refresh time interval based on the selected item
 */
- (IBAction)setAutoRefreshInterval:(id)sender
{
	[self _startAutoRefreshTimerWithInterval:[sender tag]];
}

/**
 * Displays the set custom auto-refresh interval sheet.
 */
- (IBAction)setCustomAutoRefreshInterval:(id)sender
{
	[customIntervalTextField setStringValue:[prefs stringForKey:SPProcessListAutoRrefreshInterval]];
	
	[NSApp beginSheet:customIntervalWindow
	   modalForWindow:[self window]
		modalDelegate:self
	   didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:)
		  contextInfo:NULL];
}

#pragma mark -
#pragma mark Other methods

/**
 * Displays the process list sheet attached to the supplied window.
 */
- (void)displayProcessListWindow
{
	// Remember the window's frame (from now on: set when it is shown, not when it loads)
	[self setWindowFrameAutosaveName:@"ProcessList"];

	// Weak reference
	processesFiltered = processes;
	
	[self refreshProcessList:self];
	 
	[self showWindow:self];
}

/**
 * Invoked when the kill alerts are dismissed. Decide what to do based on the user's decision.
 */
- (void)sheetDidEnd:(id)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
	// Order out current sheet to suppress overlapping of sheets
	if ([sheet respondsToSelector:@selector(orderOut:)]) {
		[sheet orderOut:nil];
	}
	else if ([sheet respondsToSelector:@selector(window)]) {
		[[sheet window] orderOut:nil];
	}

	if (sheet == customIntervalWindow) {
		if (returnCode == NSAlertDefaultReturn) [self _startAutoRefreshTimerWithInterval:[customIntervalTextField integerValue]];
		else [self _updateSelectedAutoRefreshIntervalInterface]; // the interval menu shows the interval again, not Custom…
	}
	else {
		NSDictionary *userInfo = [(NSDictionary *)contextInfo autorelease]; //we retained it during the beginSheet… call because Cocoa does not do memory management on void *.
		if (returnCode == NSAlertDefaultReturn) {
			long long processId = [[userInfo objectForKey:SPKillIdKey] longLongValue];
			
			NSString *mode = [userInfo objectForKey:SPKillModeKey];
			if ([mode isEqualToString:SPKillProcessQueryMode]) {
				[self _killProcessQueryWithId:processId];
			}
			else if ([mode isEqualToString:SPKillProcessConnectionMode]) {
				[self _killProcessConnectionWithId:processId];
			}
			else {
				[NSException raise:NSInternalInconsistencyException format:@"%s: Unhandled branch for mode=%@", __PRETTY_FUNCTION__, mode];
			}
		}
	}
}

/**
 * Menu item validation.
 */
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	SEL action = [menuItem action];
	
	if (action == @selector(copy:)) {
		return ([processListTableView numberOfSelectedRows] > 0);
	}
	
	if ((action == @selector(killProcessQuery:)) || (action == @selector(killProcessConnection:))) {
		return ([processListTableView numberOfSelectedRows] == 1);
	}
	
	if ((action == @selector(setAutoRefreshInterval:)) || (action == @selector(setCustomAutoRefreshInterval:))) {
		return [prefs boolForKey:SPProcessListEnableAutoRefresh];
	}
	
	return YES;
}


/**
 * This method is called as part of Key Value Observing which is used to watch for prefernce changes which effect the interface.
 */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{	
	// Display table veiew vertical gridlines preference changed
	if ([keyPath isEqualToString:SPDisplayTableViewVerticalGridlines]) {
        [processListTableView setGridStyleMask:([[change objectForKey:NSKeyValueChangeNewKey] boolValue]) ? NSTableViewSolidVerticalGridLineMask : NSTableViewGridNone];
	}
	// Use monospaced fonts preference changed
	else if ([keyPath isEqualToString:SPUseMonospacedFonts]) {
		
		BOOL useMonospacedFont = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		CGFloat monospacedFontSize = [prefs floatForKey:SPMonospacedFontSize] > 0 ? [prefs floatForKey:SPMonospacedFontSize] : [NSFont smallSystemFontSize];

		for (NSTableColumn *column in [processListTableView tableColumns])
		{
			[[column dataCell] setFont:useMonospacedFont ? [NSFont fontWithName:SPDefaultMonospacedFontName size:monospacedFontSize] : [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		}
		
		[processListTableView reloadData];
	}
}

#pragma mark -
#pragma mark Text field delegate methods

/**
 * Apply the filter string to the current process list.
 */
- (void)controlTextDidChange:(NSNotification *)notification
{
	id object = [notification object];
	
	if (object == filterProcessesSearchField) {
		[self _updateServerProcessesFilterForFilterString:[object stringValue]];
	}
	else if (object == customIntervalTextField) {
		[customIntervalButton setEnabled:(([[customIntervalTextField stringValue] length] > 0) && ([customIntervalTextField integerValue] > 0))];
	}
}

#pragma mark -
#pragma mark Window delegate methods

/**
 * Kill the auto refresh timer if it's running.
 */
- (void)windowWillClose:(NSNotification *)notification
{	
	// If the filtered array is allocated and it's not a reference to the processes array get rid of it
	if ((processesFiltered) && (processesFiltered != processes)) {
		SPClear(processesFiltered);
	}
	
	// Kill the auto refresh timer if running
	[self _killAutoRefreshTimer];	
}

#pragma mark -
#pragma mark Private API

/**
 * Called by the background thread on the main thread once it has completed getting the list of processes.
 */
- (void)_setConnectionSummary:(SPConnectionSummary *)summary
{
	[connectionSummary release];
	connectionSummary = [summary retain];
}

/**
 * The count line: the server's connections against its limit (red once only superusers could connect), after
 * "Showing N of M" while the list is filtered.
 */
- (void)_updateProcessCountText
{
	BOOL filtered = processesFiltered && processesFiltered != processes;
	[processesCountTextField setStringValue:filtered
		? [NSString stringWithFormat:NSLocalizedString(@"%lu of %lu rows", @"server processes: filtered row count"), (unsigned long)[processesFiltered count], (unsigned long)[processes count]]
		: [NSString stringWithFormat:NSLocalizedString(@"%lu rows", @"server processes: row count"), (unsigned long)[processes count]]];
	[processesCountTextField setHidden:NO];

	NSString *summary = [connectionSummary text];
	[summaryLabel setStringValue:summary ?: @""];
	[summaryLabel setTextColor:[connectionSummary isFull] ? [NSColor systemRedColor] : [NSColor secondaryLabelColor]];
	[summaryLabel setHidden:![summary length]];
}

- (void)_processListRefreshed
{
	processListThreadRunning = NO;
	
	// Reapply any filters is required
	if ([[filterProcessesSearchField stringValue] length] > 0) {
		[self _updateServerProcessesFilterForFilterString:[filterProcessesSearchField stringValue]];
	}
	
	// Reset sort descriptors
	[processesFiltered sortUsingDescriptors:[processListTableView sortDescriptors]];
	
	// Reload data
	[processListTableView reloadData];
	[self _updateProcessCountText];
	[self _updateKillButtons];
	
	// Enable controls
	[filterProcessesSearchField setEnabled:YES];
	[saveProcessesButton setEnabled:YES];
	[refreshProcessesButton setEnabled:(![autoRefreshButton state])];
	
	// Stop progress Indicator
	[refreshProgressIndicator stopAnimation:self];
	[refreshProgressIndicator setHidden:YES];
}

/**
 * Starts the auto refresh timer.
 */
- (void)_startAutoRefreshTimer
{		
	autoRefreshTimer = [[NSTimer scheduledTimerWithTimeInterval:[prefs doubleForKey:SPProcessListAutoRrefreshInterval] target:self selector:@selector(_fireAutoRefresh:) userInfo:nil repeats:YES] retain];
}

/**
 * Kills the auto refresh timer.
 */
- (void)_killAutoRefreshTimer
{
	// If the auto refresh timer is running, kill it
	if (autoRefreshTimer && [autoRefreshTimer isValid]) {		
		[autoRefreshTimer invalidate];
		SPClear(autoRefreshTimer);
	}
}

/**
 * Refreshes the process list when called by the auto refesh timer.
 */
- (void)_fireAutoRefresh:(NSTimer *)timer
{	
	[self refreshProcessList:self];
}

/**
 *
 */
- (void)_updateSelectedAutoRefreshIntervalInterface
{	
	BOOL found = NO;
	NSInteger interval = [prefs integerForKey:SPProcessListAutoRrefreshInterval];
	
	NSArray *items = [[autoRefreshIntervalMenuItem submenu] itemArray];
	
	// Uncheck all items
	for (NSMenuItem *item in items)
	{
		[item setState:NSOffState];
	}
	
	// Check the selected item
	for (NSMenuItem *item in items)
	{ 		
		if (interval == [item tag]) {
			found = YES;
			[item setState:NSOnState];
			break;
		}
	}
	
	// If a match wasn't found then a custom value is set
	if (!found) [(NSMenuItem*)[items objectAtIndex:([items count] - 1)] setState:NSOnState];

	// The interval menu: a custom interval gets an item of its own (before the separator), chosen
	for (NSMenuItem *item in [[[autoRefreshIntervalPopUp itemArray] copy] autorelease]) {
		if ([[item representedObject] isEqual:@"custom"]) [[autoRefreshIntervalPopUp menu] removeItem:item];
	}
	if (interval > 0 && ![autoRefreshIntervalPopUp selectItemWithTag:interval]) {
		NSInteger separator = [[autoRefreshIntervalPopUp menu] indexOfItem:[[[autoRefreshIntervalPopUp itemArray] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"separatorItem == YES"]] firstObject]];
		NSMenuItem *custom = [[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Every %ld seconds", @"server processes: auto refresh interval in seconds"), (long)interval] action:@selector(setAutoRefreshInterval:) keyEquivalent:@""] autorelease];
		[custom setTag:interval];
		[custom setTarget:self];
		[custom setRepresentedObject:@"custom"];
		[[autoRefreshIntervalPopUp menu] insertItem:custom atIndex:(separator >= 0 ? separator : [autoRefreshIntervalPopUp numberOfItems])];
		[autoRefreshIntervalPopUp selectItem:custom];
	}
	[autoRefreshIntervalPopUp setEnabled:[prefs boolForKey:SPProcessListEnableAutoRefresh]];
}

/**
 * Starts the auto refresh time with the supplied time interval.
 */
- (void)_startAutoRefreshTimerWithInterval:(NSTimeInterval)interval
{
	[prefs setDouble:interval forKey:SPProcessListAutoRrefreshInterval];
	
	// Update the interface
	[self _updateSelectedAutoRefreshIntervalInterface];
	
	// Kill the timer and restart it with the new interval
	[self _killAutoRefreshTimer];
	[self _startAutoRefreshTimer];
}

/**
 * Gets a list of current database processed on a background thread.
 */
- (void)_getDatabaseProcessListInBackground:(id)object;
{	
	@autoreleasepool {
		NSUInteger i = 0;

		// Get processes
		if ([connection isConnected]) {

			SPMySQLResult *processList = (showFullProcessList) ? [connection queryString:@"SHOW FULL PROCESSLIST"] : [connection listProcesses];

			[processList setReturnDataAsStrings:YES];

			[[processes onMainThread] removeAllObjects];

			for (i = 0; i < [processList numberOfRows]; i++)
			{
				//SPMySQL.framewokr currently returns numbers as NSString, which will break sorting of numbers in this case.
				NSMutableDictionary *rowsFixed = [[processList getRowAsDictionary] mutableCopy];

				// The ID can be a 64-bit value on 64-bit servers
				id idColumn = [rowsFixed objectForKey:@"Id"];
				if (idColumn != nil && [idColumn isKindOfClass:[NSString class]]) {
					long long numRaw = [(NSString *)idColumn longLongValue];
					NSNumber *num = [NSNumber numberWithLongLong:numRaw];
					[rowsFixed setObject:num forKey:@"Id"];
				}

				// Time is a signed int(7) - this is a 32 bit int value
				id timeColumn = [rowsFixed objectForKey:@"Time"];
				if(timeColumn != nil && [timeColumn isKindOfClass:[NSString class]]) {
					int numRaw = [(NSString *)timeColumn intValue];
					NSNumber *num = [NSNumber numberWithInt:numRaw];
					[rowsFixed setObject:num forKey:@"Time"];
				}

				// This is pretty bad from a performance standpoint, but we must not
				// interfere with the NSTableView's reload cycle and there is no way
				// to know when it starts/ends. We only know it will happen on the
				// main thread, so we have to interlock with that.
				[[processes onMainThread] addObject:[[rowsFixed copy] autorelease]];
				[rowsFixed release];
			}
		}

		// The connections against the limit (nil when they can't be read)
		SPConnectionSummary *summary = [connection isConnected] ? [SPConnectionSummary summaryForMySQLConnection:connection] : nil;
		[self performSelectorOnMainThread:@selector(_setConnectionSummary:) withObject:summary waitUntilDone:NO];

		// Update the UI on the main thread
		[self performSelectorOnMainThread:@selector(_processListRefreshed) withObject:nil waitUntilDone:NO];
	}
}

/**
 * Attempts to kill the query executing on the connection associate with the supplied ID.
 */
- (void)_killProcessQueryWithId:(long long)processId
{
	// Kill the query
	[connection queryString:[NSString stringWithFormat:@"KILL QUERY %lld", processId]];
	
	// Check for errors
	if ([connection queryErrored]) {
		SPOnewayAlertSheet(
			NSLocalizedString(@"Unable to kill query", @"error killing query message"),
			[self window],
			[NSString stringWithFormat:NSLocalizedString(@"An error occured while attempting to kill the query associated with connection %lld.\n\nMySQL said: %@", @"error killing query informative message"), processId, [connection lastErrorMessage]]
		);
	}
	
	// Refresh the process list
	[self refreshProcessList:self];
}

/**
 * Attempts the kill the connection associated with the supplied ID.
 */
- (void)_killProcessConnectionWithId:(long long)processId
{
	// Kill the connection
	[connection queryString:[NSString stringWithFormat:@"KILL CONNECTION %lld", processId]];
	
	// Check for errors
	if ([connection queryErrored]) {
		SPOnewayAlertSheet(
			NSLocalizedString(@"Unable to kill connection", @"error killing connection message"),
			[self window],
			[NSString stringWithFormat:NSLocalizedString(@"An error occured while attempting to kill connection %lld.\n\nMySQL said: %@", @"error killing query informative message"), processId, [connection lastErrorMessage]]
		);
	}
	
	// Refresh the process list
	[self refreshProcessList:self];
}

/**
 * Filter the displayed server processes against the supplied filter string.
 */
- (void)_updateServerProcessesFilterForFilterString:(NSString *)filterString
{
	[saveProcessesButton setEnabled:NO];
		
	filterString = [[filterString lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	
	// If the filtered array is allocated and its not a reference to the processes array,
	// relase it to prevent memory leaks upon the next allocation.
	if ((processesFiltered) && (processesFiltered != processes)) {
		SPClear(processesFiltered);
	}
	
	processesFiltered = [[NSMutableArray alloc] init];
	
	if ([filterString length] == 0) {
		[processesFiltered release];
		processesFiltered = processes;
		
		[saveProcessesButton setEnabled:YES];
		[saveProcessesButton setTitle:NSLocalizedString(@"Save As...", @"save as button title")];
		[self _updateProcessCountText];
		
		[processListTableView reloadData];
		
		return;
	}
	
	// Perform filtering
	for (NSDictionary *process in processes) 
	{
		if (([[[process objectForKey:@"Id"] stringValue] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound) ||
			([[process objectForKey:@"User"] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound) ||
			([[process objectForKey:@"Host"] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound) ||
			((![[process objectForKey:@"db"] isNSNull]) && ([[process objectForKey:@"db"] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound)) ||
			([[process objectForKey:@"Command"] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound) ||
			((![[process objectForKey:@"Time"] isNSNull]) && ([[[process objectForKey:@"Time"] stringValue] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound)) ||
			((![[process objectForKey:@"State"] isNSNull]) && ([[process objectForKey:@"State"] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound)) ||
			((![[process objectForKey:@"Info"] isNSNull]) && ([[process objectForKey:@"Info"] rangeOfString:filterString options:NSCaseInsensitiveSearch].location != NSNotFound)))
		{
			[processesFiltered addObject:process];
		}
	}
	
	[processListTableView reloadData];
	
	[self _updateProcessCountText];
	
	if ([processesFiltered count] == 0) return;
	
	[saveProcessesButton setEnabled:YES];
	[saveProcessesButton setTitle:NSLocalizedString(@"Save View As...", @"save view as button title")];
}

/**
 * Add any necessary preference observers to allow live updating on changes.
 */
- (void)_addPreferenceObservers
{
	// Register as an observer for the when the UseMonospacedFonts preference changes
	[prefs addObserver:self forKeyPath:SPUseMonospacedFonts options:NSKeyValueObservingOptionNew context:NULL];

	// Register to obeserve table view vertical grid line pref changes
	[prefs addObserver:self forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
}

/**
 * Remove any previously added preference observers.
 */
- (void)_removePreferenceObservers
{
	[prefs removeObserver:self forKeyPath:SPUseMonospacedFonts];
	[prefs removeObserver:self forKeyPath:SPDisplayTableViewVerticalGridlines];
}

#pragma mark - SPProcessListControllerDataSource

#pragma mark Tableview delegate methods

/**
 * Table view delegate method. Returns the number of rows in the table veiw.
 */
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return [processesFiltered count];
}

/**
 * Table view delegate method. Returns the specific object for the request column and row.
 */
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	id object = ((NSUInteger)row < [processesFiltered count]) ? [[processesFiltered objectAtIndex:row] valueForKey:[tableColumn identifier]] : @"";

	if ([object isNSNull]) {
		return [prefs stringForKey:SPNullValue];
	}

	// If the string is exactly 100 characters long, and FULL process lists are not enabled, it's a safe
	// bet that the string is truncated
	if (!showFullProcessList && [object isKindOfClass:[NSString class]] && [(NSString *)object length] == 100) {
		return [object stringByAppendingString:@"…"];
	}

	return object;
}

/**
 * Table view delegate method. Called when the user changes the sort by column.
 */
- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray *)oldDescriptors
{
	[processesFiltered sortUsingDescriptors:[tableView sortDescriptors]];

	[tableView reloadData];
}

/**
 * Table view delegate method. Called whenever the user changes a column width.
 */
- (void)tableViewColumnDidResize:(NSNotification *)notification
{
	// Only widths the user drags in the header are remembered: not the table's own resizing (the window's layout,
	// a window resize, the last column filling the width)
	if ([[processListTableView headerView] resizedColumn] < 0) return;

	NSTableColumn *column = [[notification userInfo] objectForKey:@"NSTableColumn"];

	// Get the existing table column widths dictionary if it exists
	NSMutableDictionary *tableColumnWidths = ([prefs objectForKey:SPProcessListTableColumnWidths]) ?
	[NSMutableDictionary dictionaryWithDictionary:[prefs objectForKey:SPProcessListTableColumnWidths]] :
	[NSMutableDictionary dictionary];

	// Save column size
	NSString *columnName = [[column headerCell] stringValue];

	if (columnName) {
		[tableColumnWidths setObject:[NSNumber numberWithDouble:[column width]] forKey:columnName];

		[prefs setObject:tableColumnWidths forKey:SPProcessListTableColumnWidths];
	}
}

#pragma mark -

- (void)dealloc
{
	processListThreadRunning = NO;

	[self _removePreferenceObservers];

	SPClear(processes);
	SPClear(connectionSummary);
	SPClear(summaryLabel);
	SPClear(autoRefreshIntervalPopUp);
	SPClear(killQueryButton);
	SPClear(killConnectionButton);
	SPClear(closeButton);
	
	if (autoRefreshTimer) SPClear(autoRefreshTimer);
	
	[super dealloc];
}

@end
