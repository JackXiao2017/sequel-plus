#import "SPPostgresPaginationView.h"
#import "SPConstants.h"

@interface SPPostgresPaginationView () <NSTextFieldDelegate>
@end

@implementation SPPostgresPaginationView
{
	NSUserDefaultsController *defaultsController;
	NSTextField *pageField;
	NSStepper *pageStepper;
	NSButton *goButton;
	NSButton *limitCheckbox;
	NSTextField *limitField;
	NSStepper *limitStepper;
}

@synthesize page;
@synthesize maxPage;
@synthesize target;
@synthesize action;

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
{
	if ((self = [super initWithNibName:nil bundle:nil])) {
		// Bindings onto the given defaults (not the shared controller's standardUserDefaults)
		defaultsController = [[NSUserDefaultsController alloc] initWithDefaults:defaults initialValues:nil];
		[defaultsController setAppliesImmediately:YES];
		page = 1;
		maxPage = 1;
	}
	return self;
}

- (void)dealloc
{
	// The controls (made with the view) let go of the defaults controller and of this view controller
	if (pageField) {
		for (NSControl *control in @[pageField, pageStepper, goButton, limitCheckbox, limitField, limitStepper]) {
			[control unbind:NSValueBinding];
			[control unbind:NSEnabledBinding];
		}
		[pageField setDelegate:nil];
		[pageStepper setTarget:nil];
		[goButton setTarget:nil];
	}

	[pageField release];
	[pageStepper release];
	[goButton release];
	[limitCheckbox release];
	[limitField release];
	[limitStepper release];
	[defaultsController release];
	[super dealloc];
}

#pragma mark - The view

- (NSTextField *)_newLabelWithFrame:(NSRect)frame title:(NSString *)title
{
	NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
	[label setStringValue:title];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setDrawsBackground:NO];
	[[label cell] setControlSize:NSControlSizeSmall];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	return label;
}

- (NSTextField *)_newNumberFieldWithFrame:(NSRect)frame formatter:(NSNumberFormatter *)formatter
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
	[[field cell] setControlSize:NSControlSizeSmall];
	[field setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[field setAlignment:NSTextAlignmentRight];
	[[field cell] setScrollable:YES];
	[[field cell] setUsesSingleLineMode:YES];
	[field setFormatter:formatter];
	return field;
}

- (NSStepper *)_newStepperWithFrame:(NSRect)frame max:(double)max
{
	NSStepper *stepper = [[NSStepper alloc] initWithFrame:frame];
	[[stepper cell] setControlSize:NSControlSizeSmall];
	[stepper setMinValue:1];
	[stepper setMaxValue:max];
	return stepper;
}

- (NSButton *)_newCheckboxWithFrame:(NSRect)frame title:(NSString *)title
{
	NSButton *checkbox = [[NSButton alloc] initWithFrame:frame];
	[checkbox setButtonType:NSButtonTypeSwitch];
	[checkbox setTitle:title];
	[[checkbox cell] setControlSize:NSControlSizeSmall];
	[checkbox setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	return checkbox;
}

- (void)_bind:(NSString *)binding of:(NSControl *)control toPreference:(NSString *)key
{
	[control bind:binding toObject:defaultsController withKeyPath:[@"values." stringByAppendingString:key] options:nil];
}

/// MySQL's ContentPaginationView.xib without its "Defer loading of blobs and texts" row (the rest 25 pt lower).
- (void)loadView
{
	NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 64)] autorelease];

	// Jump to page: [page] [stepper] [Go]
	NSTextField *pageLabel = [[self _newLabelWithFrame:NSMakeRect(15, 39, 129, 14) title:NSLocalizedString(@"Jump to page:", @"Postgres content: jump to page label")] autorelease];
	[pageLabel setAlignment:NSTextAlignmentRight];

	NSNumberFormatter *pageFormatter = [[[NSNumberFormatter alloc] init] autorelease];
	[pageFormatter setFormatterBehavior:NSNumberFormatterBehavior10_4];
	[pageFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
	[pageFormatter setAllowsFloats:NO];
	[pageFormatter setLenient:YES];
	[pageFormatter setMinimum:@1];
	pageField = [self _newNumberFieldWithFrame:NSMakeRect(150, 36, 52, 19) formatter:pageFormatter];
	[pageField setDelegate:self];

	pageStepper = [self _newStepperWithFrame:NSMakeRect(204, 34, 15, 22) max:1];
	[pageStepper setTarget:self];
	[pageStepper setAction:@selector(_pageStepped:)];

	goButton = [[NSButton alloc] initWithFrame:NSMakeRect(225, 37, 91, 17)];
	[goButton setBezelStyle:NSBezelStyleRoundRect];
	[[goButton cell] setControlSize:NSControlSizeSmall];
	[goButton setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[goButton setTitle:NSLocalizedString(@"Go", @"Postgres content: jump to page Go button")];
	[goButton setTarget:self];
	[goButton setAction:@selector(_go:)];

	// Return in the page field clicks Go
	[pageField setTarget:goButton];
	[pageField setAction:@selector(performClick:)];

	NSBox *separator = [[[NSBox alloc] initWithFrame:NSMakeRect(14, 25, 302, 5)] autorelease];
	[separator setBoxType:NSBoxSeparator];

	// [x] Limit result to: [n] [stepper] rows
	limitCheckbox = [self _newCheckboxWithFrame:NSMakeRect(15, 6, 166, 18) title:NSLocalizedString(@"Limit result to:", @"Postgres content: limit result checkbox")];

	NSNumberFormatter *limitFormatter = [[[NSNumberFormatter alloc] init] autorelease];
	[limitFormatter setFormatterBehavior:NSNumberFormatterBehavior10_4];
	[limitFormatter setAllowsFloats:NO];
	[limitFormatter setMinimum:@0];
	[limitFormatter setMaximum:@100000];
	limitField = [self _newNumberFieldWithFrame:NSMakeRect(187, 6, 52, 19) formatter:limitFormatter];
	[[limitField cell] setSendsActionOnEndEditing:YES];

	limitStepper = [self _newStepperWithFrame:NSMakeRect(241, 3, 15, 22) max:100000];
	[limitStepper setValueWraps:YES];

	NSTextField *rowsLabel = [[self _newLabelWithFrame:NSMakeRect(259, 8, 60, 14) title:NSLocalizedString(@"rows", @"Postgres content: rows label after the page size")] autorelease];

	for (NSView *subview in @[pageLabel, pageField, pageStepper, goButton, separator, limitCheckbox, limitField, limitStepper, rowsLabel]) {
		[subview setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
		[view addSubview:subview];
	}

	// MySQL's bindings, onto the given defaults
	[self _bind:NSValueBinding of:limitCheckbox toPreference:SPLimitResults];
	[self _bind:NSValueBinding of:limitField toPreference:SPLimitResultsValue];
	[self _bind:NSValueBinding of:limitStepper toPreference:SPLimitResultsValue];
	for (NSControl *control in @[pageField, pageStepper, goButton, limitField, limitStepper]) {
		[self _bind:NSEnabledBinding of:control toPreference:SPLimitResults];
	}

	[self setView:view];
	[self _showPage];
}

- (NSTextField *)pageField
{
	[self view];
	return pageField;
}

- (NSTextField *)limitField
{
	[self view];
	return limitField;
}

- (NSButton *)goButton
{
	[self view];
	return goButton;
}

- (NSButton *)limitCheckbox
{
	[self view];
	return limitCheckbox;
}

#pragma mark - The page

- (void)setPage:(NSUInteger)newPage
{
	page = newPage;
	[self _showPage];
}

- (void)setMaxPage:(NSUInteger)newMaxPage
{
	maxPage = newMaxPage;
	[self _showPage];
}

- (void)_showPage
{
	if (!pageField) return;
	[pageStepper setMaxValue:MAX(1, (double)maxPage)];
	[pageStepper setIntegerValue:(NSInteger)page];
	[pageField setObjectValue:@(page)];
}

- (void)_pageStepped:(id)sender
{
	[self setPage:(NSUInteger)MAX(1, [pageStepper integerValue])];
}

/// The typed page (empty or not a number: 1) to target.
- (void)_go:(id)sender
{
	NSInteger typed = [pageField integerValue];
	[self setPage:(typed > 0) ? (NSUInteger)typed : 1];
	if (target && action) [target performSelector:action withObject:self];
}

- (void)makeInputFirstResponder
{
	[[pageField window] makeFirstResponder:pageField];
}

/// A page that isn't a number (or is below 1) is taken as typed: Go treats it as page 1, without the formatter's alert.
- (BOOL)control:(NSControl *)control didFailToFormatString:(NSString *)string errorDescription:(NSString *)error
{
	return YES;
}

@end
