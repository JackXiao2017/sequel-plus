#import "SPPostgresSequenceController.h"
#import "SPPostgresSequences.h"
#import "SPPostgresTableDuplicator.h"
#import "SPPostgresErrors.h"
#import "SPPostgresPaneLoader.h"
#import <PostgresKit/PostgresKit.h>

// As the Table Info pane: right-aligned labels at x 20, values from x 128
static const CGFloat SPPostgresSequenceMargin = 20;
static const CGFloat SPPostgresSequenceValueX = 128;
static const CGFloat SPPostgresSequenceRowHeight = 26;
static const CGFloat SPPostgresSequenceNumberWidth = 220;
static const CGFloat SPPostgresSequenceNoticeHeight = 22;

static NSString * const SPPostgresSequenceNone = @"None";

/**
 * NSNumberFormatter writes numbers through a double, which loses bigint values past 2^53 (9007199254740993 shows as
 * …992, LLONG_MAX - 1 as LLONG_MAX). This one writes the long long value itself; it parses as NSNumberFormatter does,
 * then takes the exact value from the digits.
 */
@interface SPPostgresSequenceIntegerFormatter : NSNumberFormatter
@end

@implementation SPPostgresSequenceIntegerFormatter

- (NSString *)stringForObjectValue:(id)value
{
	if ([value isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%lld", [value longLongValue]];
	return [super stringForObjectValue:value];
}

- (NSString *)editingStringForObjectValue:(id)value
{
	return [self stringForObjectValue:value];
}

- (BOOL)getObjectValue:(out id *)value forString:(NSString *)string errorDescription:(out NSString **)error
{
	if (![super getObjectValue:value forString:string errorDescription:error]) return NO;
	if (!value || ![*value isKindOfClass:[NSNumber class]]) return YES;

	// Plain digits (the usual case): their exact value, not the double's (super checked the range)
	NSString *text = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSScanner *scanner = [NSScanner scannerWithString:text];
	long long exact = 0;
	if ([scanner scanLongLong:&exact] && [scanner isAtEnd]) *value = [NSNumber numberWithLongLong:exact];
	return YES;
}

@end

/// Integers only, over the bigint range (no grouping, no fraction digits), written exactly. An empty string is nil.
static NSNumberFormatter *SPPostgresSequenceNewFormatter(void)
{
	NSNumberFormatter *formatter = [[SPPostgresSequenceIntegerFormatter alloc] init];
	[formatter setNumberStyle:NSNumberFormatterNoStyle];
	[formatter setAllowsFloats:NO];
	[formatter setMaximumFractionDigits:0];
	[formatter setUsesGroupingSeparator:NO];
	[formatter setMinimum:@(LLONG_MIN)];
	[formatter setMaximum:@(LLONG_MAX)];
	return formatter;
}

/// A field's number (nil when empty); NO (with an error) when its text isn't a whole number in range.
static BOOL SPPostgresSequenceReadNumber(NSTextField *field, NSString *label, NSNumber **number, NSError **error)
{
	NSString *text = [[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	*number = nil;
	if (![text length]) return YES;

	id value = nil;
	if (![[field formatter] getObjectValue:&value forString:text errorDescription:NULL] || ![value isKindOfClass:[NSNumber class]]) {
		if (error) *error = SPPostgresMakeError(SPPostgresErrorQueryFailed, [NSString stringWithFormat:NSLocalizedString(@"%@ “%@” is not a whole number between -9223372036854775808 and 9223372036854775807.", @"Postgres sequence pane: bad number (label, text)"), label, text], nil);
		return NO;
	}
	*number = [NSNumber numberWithLongLong:[value longLongValue]];
	return YES;
}

#pragma mark - Form

/**
 * The fields of a sequence, as a label grid (shared by the pane and the Add Sequence sheet): Name, Type, Start,
 * Increment, Minimum, Maximum, Cache, Cycle, Owned by, Comment. Each field reports its edits to the delegate
 * (controlTextDidChange:) or the target/action (pop-ups, checkbox).
 */
@interface SPPostgresSequenceForm : NSObject
{
@public
	NSTextField *nameField;
	NSPopUpButton *typePopup;
	NSTextField *startField;
	NSTextField *incrementField;
	NSTextField *minValueField;
	NSTextField *maxValueField;
	NSTextField *cacheField;
	NSButton *cycleSwitch;
	NSPopUpButton *ownedByPopup;
	NSTextField *commentField;
	/// The y below the last row
	CGFloat bottom;
}

- (instancetype)initInView:(NSView *)view top:(CGFloat)top width:(CGFloat)width small:(BOOL)small delegate:(id<NSTextFieldDelegate>)delegate target:(id)target action:(SEL)action;
- (void)showCandidates:(NSArray *)candidates selected:(NSString *)selected;
- (void)showDefinition:(SPPostgresSequenceDefinition *)definition;
/// The fields as a definition; nil (with an error) when a number field doesn't hold a whole number.
- (SPPostgresSequenceDefinition *)definition:(NSError **)error;
/// The field's key in a definition (@"name", @"increment", …), or nil.
- (NSString *)keyOfControl:(id)control;
- (void)detach;

@end

@implementation SPPostgresSequenceForm

- (NSTextField *)_labelWithText:(NSString *)text atY:(CGFloat)y font:(NSFont *)font
{
	NSTextField *label = [NSTextField labelWithString:text];
	[label setFont:font];
	[label setAlignment:NSTextAlignmentRight];
	[label setFrame:NSMakeRect(SPPostgresSequenceMargin, y + 3, SPPostgresSequenceValueX - SPPostgresSequenceMargin - 8, 17)];
	[label setAutoresizingMask:NSViewMinYMargin];
	return label;
}

/// An editable field (retained: the caller releases it).
- (NSTextField *)_newFieldAtY:(CGFloat)y width:(CGFloat)width identifier:(NSString *)identifier font:(NSFont *)font number:(BOOL)number delegate:(id<NSTextFieldDelegate>)delegate
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(SPPostgresSequenceValueX, y, width, 22)];
	[field setIdentifier:identifier];
	[field setFont:font];
	[[field cell] setUsesSingleLineMode:YES];
	[[field cell] setScrollable:YES];
	[field setDelegate:delegate];
	if (number) {
		NSNumberFormatter *formatter = SPPostgresSequenceNewFormatter();
		[field setFormatter:formatter];
		[formatter release];
		[field setAlignment:NSTextAlignmentRight];
	}
	return field;
}

- (NSPopUpButton *)_newPopupAtY:(CGFloat)y width:(CGFloat)width identifier:(NSString *)identifier font:(NSFont *)font target:(id)target action:(SEL)action
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(SPPostgresSequenceValueX - 3, y - 1, width + 6, 26) pullsDown:NO];
	[popup setIdentifier:identifier];
	[popup setFont:font];
	[popup setTarget:target];
	[popup setAction:action];
	return popup;
}

- (instancetype)initInView:(NSView *)view top:(CGFloat)top width:(CGFloat)width small:(BOOL)small delegate:(id<NSTextFieldDelegate>)delegate target:(id)target action:(SEL)action
{
	if ((self = [super init])) {
		NSFont *font = small ? [NSFont systemFontOfSize:[NSFont smallSystemFontSize]] : [NSFont systemFontOfSize:[NSFont systemFontSize]];
		NSFont *labelFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
		CGFloat wide = width - SPPostgresSequenceValueX - SPPostgresSequenceMargin;
		CGFloat narrow = MIN(SPPostgresSequenceNumberWidth, wide);
		CGFloat y = top - 22;

		[view addSubview:[self _labelWithText:NSLocalizedString(@"Name:", @"Postgres sequence: name label") atY:y font:labelFont]];
		nameField = [self _newFieldAtY:y width:wide identifier:@"sequenceName" font:font number:NO delegate:delegate];
		[nameField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
		[view addSubview:nameField];
		y -= SPPostgresSequenceRowHeight;

		[view addSubview:[self _labelWithText:NSLocalizedString(@"Type:", @"Postgres sequence: type label") atY:y font:labelFont]];
		typePopup = [self _newPopupAtY:y width:narrow identifier:@"sequenceType" font:font target:target action:action];
		[typePopup addItemsWithTitles:@[@"smallint", @"integer", @"bigint"]];
		[typePopup setAutoresizingMask:NSViewMinYMargin];
		[view addSubview:typePopup];
		y -= SPPostgresSequenceRowHeight;

		NSArray *numbers = @[@[NSLocalizedString(@"Start:", @"Postgres sequence: start label"), @"sequenceStart"],
							 @[NSLocalizedString(@"Increment:", @"Postgres sequence: increment label"), @"sequenceIncrement"],
							 @[NSLocalizedString(@"Minimum:", @"Postgres sequence: minimum label"), @"sequenceMinValue"],
							 @[NSLocalizedString(@"Maximum:", @"Postgres sequence: maximum label"), @"sequenceMaxValue"],
							 @[NSLocalizedString(@"Cache:", @"Postgres sequence: cache label"), @"sequenceCache"]];
		NSTextField *numberFields[5] = {nil};
		NSUInteger index = 0;
		for (NSArray *number in numbers) {
			[view addSubview:[self _labelWithText:number[0] atY:y font:labelFont]];
			NSTextField *field = [self _newFieldAtY:y width:narrow identifier:number[1] font:font number:YES delegate:delegate];
			[field setAutoresizingMask:NSViewMinYMargin];
			if ([number[1] hasSuffix:@"Value"]) [field setPlaceholderString:NSLocalizedString(@"Default", @"Postgres sequence: empty min/max placeholder")];
			[view addSubview:field];
			numberFields[index++] = field;
			y -= SPPostgresSequenceRowHeight;
		}
		startField = numberFields[0];
		incrementField = numberFields[1];
		minValueField = numberFields[2];
		maxValueField = numberFields[3];
		cacheField = numberFields[4];

		cycleSwitch = [[NSButton checkboxWithTitle:NSLocalizedString(@"Cycle (wrap around at the limit)", @"Postgres sequence: cycle checkbox") target:target action:action] retain];
		[cycleSwitch setIdentifier:@"sequenceCycle"];
		[cycleSwitch setFont:font];
		[cycleSwitch setFrame:NSMakeRect(SPPostgresSequenceValueX, y + 2, wide, 18)];
		[cycleSwitch setAutoresizingMask:NSViewMinYMargin];
		[view addSubview:cycleSwitch];
		y -= SPPostgresSequenceRowHeight;

		[view addSubview:[self _labelWithText:NSLocalizedString(@"Owned by:", @"Postgres sequence: owned by label") atY:y font:labelFont]];
		ownedByPopup = [self _newPopupAtY:y width:wide identifier:@"sequenceOwnedBy" font:font target:target action:action];
		[ownedByPopup setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
		[[ownedByPopup cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
		[view addSubview:ownedByPopup];
		y -= SPPostgresSequenceRowHeight;

		[view addSubview:[self _labelWithText:NSLocalizedString(@"Comment:", @"Postgres sequence: comment label") atY:y font:labelFont]];
		commentField = [self _newFieldAtY:y width:wide identifier:@"sequenceComment" font:font number:NO delegate:delegate];
		[commentField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
		[view addSubview:commentField];

		bottom = y;
		[self showCandidates:@[] selected:nil];
	}
	return self;
}

- (void)dealloc
{
	[self detach];
	[nameField release];
	[typePopup release];
	[startField release];
	[incrementField release];
	[minValueField release];
	[maxValueField release];
	[cacheField release];
	[cycleSwitch release];
	[ownedByPopup release];
	[commentField release];
	[super dealloc];
}

- (void)detach
{
	for (NSTextField *field in @[nameField, startField, incrementField, minValueField, maxValueField, cacheField, commentField]) [field setDelegate:nil];
	for (NSControl *control in @[typePopup, cycleSwitch, ownedByPopup]) [control setTarget:nil];
}

- (void)showCandidates:(NSArray *)candidates selected:(NSString *)selected
{
	[ownedByPopup removeAllItems];
	[ownedByPopup addItemWithTitle:NSLocalizedString(SPPostgresSequenceNone, @"Postgres sequence: owned by none")];
	// Titles as given (a column name may look like a menu separator or repeat)
	for (NSString *candidate in candidates) [[ownedByPopup menu] addItemWithTitle:candidate action:NULL keyEquivalent:@""];
	if ([selected length] && ![candidates containsObject:selected]) [[ownedByPopup menu] addItemWithTitle:selected action:NULL keyEquivalent:@""];
	if ([selected length]) [ownedByPopup selectItemAtIndex:[ownedByPopup indexOfItemWithTitle:selected]];
	else [ownedByPopup selectItemAtIndex:0];
}

- (void)_showNumber:(NSNumber *)number inField:(NSTextField *)field
{
	if (number) [field setObjectValue:number];
	else [field setStringValue:@""];
}

- (void)showDefinition:(SPPostgresSequenceDefinition *)definition
{
	[nameField setStringValue:[definition name] ?: @""];
	if ([definition dataType] && [typePopup indexOfItemWithTitle:[definition dataType]] < 0) [typePopup addItemWithTitle:[definition dataType]];
	[typePopup selectItemWithTitle:[definition dataType] ?: @"bigint"];
	[self _showNumber:[definition start] inField:startField];
	[self _showNumber:[definition increment] inField:incrementField];
	[self _showNumber:[definition minValue] inField:minValueField];
	[self _showNumber:[definition maxValue] inField:maxValueField];
	[self _showNumber:[definition cache] inField:cacheField];
	[cycleSwitch setState:[definition cycle] ? NSControlStateValueOn : NSControlStateValueOff];
	NSString *owned = [definition ownedBy];
	if ([owned length] && [ownedByPopup indexOfItemWithTitle:owned] < 0) [[ownedByPopup menu] addItemWithTitle:owned action:NULL keyEquivalent:@""];
	if ([owned length]) [ownedByPopup selectItemAtIndex:[ownedByPopup indexOfItemWithTitle:owned]];
	else [ownedByPopup selectItemAtIndex:0];
	[commentField setStringValue:[definition comment] ?: @""];
}

- (SPPostgresSequenceDefinition *)definition:(NSError **)error
{
	SPPostgresSequenceDefinition *definition = [[[SPPostgresSequenceDefinition alloc] init] autorelease];
	[definition setName:[nameField stringValue]];
	[definition setDataType:[typePopup titleOfSelectedItem]];

	NSNumber *number = nil;
	if (!SPPostgresSequenceReadNumber(startField, NSLocalizedString(@"Start", @"Postgres sequence: start (in an error)"), &number, error)) return nil;
	[definition setStart:number];
	if (!SPPostgresSequenceReadNumber(incrementField, NSLocalizedString(@"Increment", @"Postgres sequence: increment (in an error)"), &number, error)) return nil;
	[definition setIncrement:number];
	if (!SPPostgresSequenceReadNumber(minValueField, NSLocalizedString(@"Minimum", @"Postgres sequence: minimum (in an error)"), &number, error)) return nil;
	[definition setMinValue:number];
	if (!SPPostgresSequenceReadNumber(maxValueField, NSLocalizedString(@"Maximum", @"Postgres sequence: maximum (in an error)"), &number, error)) return nil;
	[definition setMaxValue:number];
	if (!SPPostgresSequenceReadNumber(cacheField, NSLocalizedString(@"Cache", @"Postgres sequence: cache (in an error)"), &number, error)) return nil;
	[definition setCache:number];

	[definition setCycle:[cycleSwitch state] == NSControlStateValueOn];
	[definition setOwnedBy:[ownedByPopup indexOfSelectedItem] > 0 ? [ownedByPopup titleOfSelectedItem] : nil];
	[definition setComment:[commentField stringValue]];
	return definition;
}

- (NSString *)keyOfControl:(id)control
{
	if (control == nameField) return @"name";
	if (control == typePopup) return @"dataType";
	if (control == startField) return @"start";
	if (control == incrementField) return @"increment";
	if (control == minValueField) return @"minValue";
	if (control == maxValueField) return @"maxValue";
	if (control == cacheField) return @"cache";
	if (control == cycleSwitch) return @"cycle";
	if (control == ownedByPopup) return @"ownedBy";
	if (control == commentField) return @"comment";
	return nil;
}

@end

#pragma mark - Pane

@interface SPPostgresSequenceController ()

@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *sequenceName;
@property (readwrite, retain) SPPostgresSequence *sequence;
@property (readwrite, copy) NSString *noticeText;

- (void)_buildView;
- (void)_loadSwitching:(BOOL)switching;
- (void)_load;
- (void)_updateControls;

@end

@implementation SPPostgresSequenceController
{
	PGPostgresConnection *connection;
	SPPostgresSequences *sequences;
	NSTimeInterval lockTimeout;

	SPPostgresPaneLoader *loader; // the runner, the load generation, staleness, and refusing changes while busy

	/// The definition keys (@"increment", …) of the fields the user changed since the last load, apply or revert
	NSMutableSet *editedKeys;
	/// The Owned by candidates shown with the sequence
	NSArray *shownCandidates;

	NSView *view;
	SPPostgresSequenceForm *form;
	NSTextField *ownerField;
	NSTextField *currentValueField;
	NSTextField *identityNoteField;
	NSTextField *noticeField;
	NSButton *applyButton;
	NSButton *revertButton;
	NSButton *setValueButton;

	NSWindow *setValueSheet;
	NSTextField *setValueField;
	NSButton *setValueNextCall;
	NSButton *setValueOKButton;

	BOOL invalidated;
}

@synthesize schema;
@synthesize sequenceName;
@synthesize sequence;
@synthesize noticeText;
@synthesize alertPresenter;
@synthesize sequenceDidChange;
@synthesize ownerField, currentValueField, identityNoteField, applyButton, revertButton, setValueButton, setValueSheet;

#pragma mark Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		loader = [[SPPostgresPaneLoader alloc] initWithConnection:theConnection];
		editedKeys = [[NSMutableSet alloc] init];
		noticeText = [@"" copy];
		lockTimeout = 5;
		[self _buildView];
		[self _updateControls];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[loader release];
	[sequences release];
	[editedKeys release];
	[shownCandidates release];
	[schema release];
	[sequenceName release];
	[sequence release];
	[noticeText release];

	[view release];
	[form release];
	[ownerField release];
	[currentValueField release];
	[identityNoteField release];
	[noticeField release];
	[applyButton release];
	[revertButton release];
	[setValueButton release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;

	// A Set Value sheet still up ends (its completion sees invalidated)
	if (setValueSheet) [[setValueSheet sheetParent] endSheet:setValueSheet returnCode:NSModalResponseCancel];

	invalidated = YES;
	[loader invalidate];
	[form detach];
	for (NSButton *button in @[applyButton, revertButton, setValueButton]) [button setTarget:nil];

	// The blocks may capture the tab
	[alertPresenter release], alertPresenter = nil;
	[sequenceDidChange release], sequenceDidChange = nil;
}

#pragma mark View

- (NSTextField *)nameField { return form->nameField; }
- (NSPopUpButton *)typePopup { return form->typePopup; }
- (NSTextField *)startField { return form->startField; }
- (NSTextField *)incrementField { return form->incrementField; }
- (NSTextField *)minValueField { return form->minValueField; }
- (NSTextField *)maxValueField { return form->maxValueField; }
- (NSTextField *)cacheField { return form->cacheField; }
- (NSButton *)cycleSwitch { return form->cycleSwitch; }
- (NSPopUpButton *)ownedByPopup { return form->ownedByPopup; }
- (NSTextField *)commentField { return form->commentField; }

- (NSView *)view
{
	return view;
}

/// A read-only value next to its label (retained: the caller releases it).
- (NSTextField *)_newValueAtY:(CGFloat)y label:(NSString *)label width:(CGFloat)width
{
	NSTextField *title = [NSTextField labelWithString:label];
	[title setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[title setAlignment:NSTextAlignmentRight];
	[title setFrame:NSMakeRect(SPPostgresSequenceMargin, y, SPPostgresSequenceValueX - SPPostgresSequenceMargin - 8, 17)];
	[title setAutoresizingMask:NSViewMinYMargin];
	[view addSubview:title];

	NSTextField *field = [[NSTextField labelWithString:@""] retain];
	[field setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[field setSelectable:YES];
	[field setFrame:NSMakeRect(SPPostgresSequenceValueX, y, width - SPPostgresSequenceValueX - SPPostgresSequenceMargin, 17)];
	[field setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[view addSubview:field];
	return field;
}

- (NSButton *)_newButton:(NSString *)title action:(SEL)action identifier:(NSString *)identifier
{
	NSButton *button = [[NSButton buttonWithTitle:title target:self action:action] retain];
	[button setIdentifier:identifier];
	[button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
	return button;
}

/// The form from the top, then Owner, Current value and the identity note; the buttons and the bottom line below.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	CGFloat width = NSWidth(frame);
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	form = [[SPPostgresSequenceForm alloc] initInView:view top:NSHeight(frame) - SPPostgresSequenceMargin + 2 width:width small:YES delegate:self target:self action:@selector(_controlEdited:)];

	CGFloat y = form->bottom - SPPostgresSequenceRowHeight + 3;
	ownerField = [self _newValueAtY:y label:NSLocalizedString(@"Owner:", @"Postgres sequence: owner label") width:width];
	y -= 22;
	currentValueField = [self _newValueAtY:y label:NSLocalizedString(@"Current value:", @"Postgres sequence: current value label") width:width];
	y -= 30;

	identityNoteField = [[NSTextField wrappingLabelWithString:@""] retain];
	[identityNoteField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[identityNoteField setTextColor:[NSColor secondaryLabelColor]];
	[identityNoteField setFrame:NSMakeRect(SPPostgresSequenceValueX, y - 14, width - SPPostgresSequenceValueX - SPPostgresSequenceMargin, 32)];
	[identityNoteField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[view addSubview:identityNoteField];

	// Buttons, bottom right: Revert, Set Value…, Apply
	applyButton = [self _newButton:NSLocalizedString(@"Apply", @"Postgres sequence: apply button") action:@selector(apply:) identifier:@"sequenceApplyButton"];
	revertButton = [self _newButton:NSLocalizedString(@"Revert", @"Postgres sequence: revert button") action:@selector(revert:) identifier:@"sequenceRevertButton"];
	setValueButton = [self _newButton:NSLocalizedString(@"Set Value…", @"Postgres sequence: set value button") action:@selector(setValue:) identifier:@"sequenceSetValueButton"];
	[applyButton setKeyEquivalent:@"\r"];
	CGFloat x = width - SPPostgresSequenceMargin;
	for (NSButton *button in @[applyButton, setValueButton, revertButton]) {
		NSSize size = [button fittingSize];
		size.width = MAX(size.width, 90);
		x -= size.width;
		[button setFrame:NSMakeRect(x, SPPostgresSequenceNoticeHeight + 4, size.width, size.height)];
		[view addSubview:button];
		x -= 8;
	}

	// The bottom line
	noticeField = [[NSTextField labelWithString:@""] retain];
	[noticeField setFrame:NSMakeRect(SPPostgresSequenceMargin, 4, width - 2 * SPPostgresSequenceMargin, 14)];
	[noticeField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[[noticeField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[noticeField setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[view addSubview:noticeField];
}

- (NSTimeInterval)lockTimeout
{
	return lockTimeout;
}

- (void)setLockTimeout:(NSTimeInterval)timeout
{
	lockTimeout = timeout;
	[sequences setLockTimeout:timeout];
}

- (BOOL)hasPendingEdits
{
	return sequence && [editedKeys count] > 0;
}

/// The controls follow what is shown: editable while a sequence is (Name, Type, Owned by not for an identity
/// sequence's), Apply and Revert while there are edits.
- (void)_updateControls
{
	BOOL loaded = (sequence != nil);
	BOOL identity = [sequence isIdentity];
	for (NSTextField *field in @[form->startField, form->incrementField, form->minValueField, form->maxValueField, form->cacheField, form->commentField]) {
		[field setEditable:loaded];
		[field setEnabled:loaded];
	}
	[form->nameField setEditable:loaded && !identity];
	[form->nameField setEnabled:loaded];
	[form->typePopup setEnabled:loaded && !identity];
	[form->ownedByPopup setEnabled:loaded && !identity];
	[form->cycleSwitch setEnabled:loaded];
	[setValueButton setEnabled:loaded];
	[applyButton setEnabled:[self hasPendingEdits]];
	[revertButton setEnabled:[self hasPendingEdits]];
}

#pragma mark Alerts

- (void)_presentError:(NSError *)error title:(NSString *)title
{
	if (invalidated) return;

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:title];
	NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];

	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}
	NSWindow *window = [view window];
	if (window && ![window attachedSheet]) [alert beginSheetModalForWindow:window completionHandler:nil];
	else NSLog(@"%@: %@", [alert messageText], [alert informativeText]);
}

#pragma mark Loading

/// The runner's thread: the sequence and the Owned by candidates, read through sequences alone (nil, with *error, if
/// either can't be read).
static NSDictionary *SPPostgresSequenceRead(SPPostgresSequences *sequences, NSString *name, NSError **error)
{
	SPPostgresSequence *loaded = [sequences sequenceNamed:name error:error];
	if (!loaded) return nil;
	NSArray *candidates = [sequences ownerColumnCandidates:error];
	if (!candidates) return nil;
	return @{@"sequence" : loaded, @"candidates" : candidates};
}

// A load (a switch, -reload, Revert) gives the edits up before it is asked for (the fields go back to what is shown),
// so the busy state's focus change applies nothing, and goes through the pane loader (SPPostgresPaneLoader). On the
// runner's thread the work uses only the sequences object (made on the main thread, where nothing uses it while the
// runner is busy: changes are refused then) and a copy of the name. A change reads the sequence again at once, on the
// main thread, as part of the change (-_load).

- (SPPostgresTaskRunner *)taskRunner
{
	return [loader taskRunner];
}

- (void)setTaskRunner:(SPPostgresTaskRunner *)runner
{
	[loader setTaskRunner:runner];
}

- (BOOL)isStale
{
	return [loader isStale];
}

- (void)showSequence:(NSString *)name inSchema:(NSString *)theSchema
{
	if (invalidated) return;

	[self setSequenceName:name];
	[self setSchema:theSchema];
	[sequences release];
	sequences = nil;
	if ([name length] && [theSchema length]) {
		sequences = [[SPPostgresSequences alloc] initWithConnection:connection schema:theSchema];
		[sequences setLockTimeout:lockTimeout];
	}

	// The previous sequence goes at once
	[self _abortFieldEditing];
	[self _clearSequence];
	[self _loadSwitching:YES];
}

- (void)reload
{
	if (invalidated) return;
	[self _loadSwitching:NO];
}

/// Ends an edit in a field of the pane without keeping it (the fields are about to be set).
- (void)_abortFieldEditing
{
	NSWindow *window = [view window];
	id responder = [window firstResponder];
	if (![responder isKindOfClass:[NSText class]]) return;
	id field = [(NSText *)responder delegate];
	if ([field isKindOfClass:[NSTextField class]] && [form keyOfControl:field]) [(NSTextField *)field abortEditing];
}

/// Reads the sequence through the runner (see -_applySequence:error:), the edits given up first.
- (void)_loadSwitching:(BOOL)switching
{
	if ([self hasPendingEdits] || [editedKeys count]) {
		[self _abortFieldEditing];
		[editedKeys removeAllObjects];
		[self _showSequence:sequence candidates:shownCandidates];
	}
	if (!sequences) {
		[loader loadNothing];
		[self _clearSequence];
		return;
	}

	SPPostgresSequences *target = sequences;
	NSString *name = [[sequenceName copy] autorelease];
	[loader loadSwitching:switching work:^id(PGPostgresConnection *theConnection, NSError **error) {
		return SPPostgresSequenceRead(target, name, error);
	} apply:^(id result, NSError *error) {
		[self _applySequence:result error:error];
	}];
}

/// Reads the sequence on the main thread and shows it: part of a change, which runs only while the runner is idle.
- (void)_load
{
	[self _abortFieldEditing];
	[editedKeys removeAllObjects];
	if (!sequences) {
		[self _clearSequence];
		return;
	}
	NSError *error = nil;
	NSDictionary *result = SPPostgresSequenceRead(sequences, sequenceName, &error);
	[self _applySequence:result error:error];
}

/// An empty pane, no bottom line (no sequence, or before a switch's sequence has loaded).
- (void)_clearSequence
{
	[editedKeys removeAllObjects];
	[self _showSequence:nil candidates:nil];
	[self setNoticeText:@""];
	[noticeField setStringValue:@""];
}

/// Shows what was read (SPPostgresSequenceRead). nil means it couldn't be read: the pane empties and the error is
/// shown, as an alert and in the bottom line.
- (void)_applySequence:(NSDictionary *)result error:(NSError *)error
{
	[self _abortFieldEditing];
	[editedKeys removeAllObjects];

	if (result) {
		[self _showSequence:[result objectForKey:@"sequence"] candidates:[result objectForKey:@"candidates"]];
		[self setNoticeText:@""];
		[noticeField setStringValue:@""];
		return;
	}

	[self _showSequence:nil candidates:nil];
	NSString *message = [[[[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"] firstObject];
	if (![message length]) message = NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error");
	[self setNoticeText:[NSString stringWithFormat:NSLocalizedString(@"Could not load the sequence: %@", @"Postgres sequence: bottom line on a read failure"), message]];
	[noticeField setStringValue:noticeText];
	[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the sequence “%@”", @"Postgres sequence: load failed"), sequenceName]];
}

/// The fields show loaded (nil: empty) with candidates for Owned by.
- (void)_showSequence:(SPPostgresSequence *)loaded candidates:(NSArray *)candidates
{
	[self setSequence:loaded];
	NSArray *previous = shownCandidates; // candidates may be it
	shownCandidates = [candidates copy];
	[previous release];

	SPPostgresSequenceDefinition *definition = loaded ? [SPPostgresSequenceDefinition definitionWithSequence:loaded] : [[[SPPostgresSequenceDefinition alloc] init] autorelease];
	if ([loaded isIdentity]) [definition setOwnedBy:[loaded identityColumn]]; // shown, read-only
	[form showCandidates:candidates ?: @[] selected:nil];
	[form showDefinition:definition];
	if (!loaded) {
		for (NSTextField *field in @[form->startField, form->incrementField, form->minValueField, form->maxValueField, form->cacheField]) [field setStringValue:@""];
	}

	[ownerField setStringValue:[loaded owner] ?: @""];
	NSString *current = @"";
	if ([loaded lastValue]) current = [NSString stringWithFormat:@"%lld", [[loaded lastValue] longLongValue]];
	else if ([loaded pendingValue]) current = [NSString stringWithFormat:NSLocalizedString(@"%lld (next call returns this)", @"Postgres sequence: is_called false (the value nextval returns next)"), [[loaded pendingValue] longLongValue]];
	else if (loaded) current = NSLocalizedString(@"Not used yet", @"Postgres sequence: value not readable (no SELECT privilege)");
	[currentValueField setStringValue:current];
	NSString *note = @"";
	if ([loaded isIdentity]) {
		NSArray *parts = [[loaded identityColumn] componentsSeparatedByString:@"."];
		NSString *column = [parts count] >= 3 ? [NSString stringWithFormat:@"%@.%@", parts[[parts count] - 2], parts[[parts count] - 1]] : [loaded identityColumn];
		// The table and column as the server names them (a schema or table name with a dot can't be split back)
		NSString *identity = [loaded identityColumn];
		NSString *prefix = [[loaded schema] stringByAppendingString:@"."];
		if ([identity hasPrefix:prefix]) column = [identity substringFromIndex:[prefix length]];
		note = [NSString stringWithFormat:NSLocalizedString(@"This sequence belongs to identity column %@; rename or detach it from the column.", @"Postgres sequence: identity note (table.column)"), column];
	}
	[identityNoteField setStringValue:note];

	[self _updateControls];
}

#pragma mark Edits

/// What the sequence should become: the loaded sequence, with what the user changed (and only that) from the fields.
- (SPPostgresSequenceDefinition *)_editedDefinition:(NSError **)error
{
	SPPostgresSequenceDefinition *typed = [form definition:error];
	if (!typed) return nil;

	// The name as typed, without surrounding whitespace (as the Add Sequence sheet takes it)
	[typed setName:[[typed name] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];

	SPPostgresSequenceDefinition *definition = [SPPostgresSequenceDefinition definitionWithSequence:sequence];
	for (NSString *key in editedKeys) [definition setValue:[typed valueForKey:key] forKey:key];
	return definition;
}

/// YES (after NSBeep) while the runner is busy: a change runs on the main thread, so never while a load uses the
/// connection.
- (BOOL)_refuseChangeWhileBusy
{
	return [loader refuseChangeWhileBusy];
}

- (BOOL)commitPendingEdits
{
	if (invalidated || ![self hasPendingEdits]) return YES;
	if ([self _refuseChangeWhileBusy]) return NO; // the edits stay

	NSError *error = nil;
	SPPostgresSequenceDefinition *definition = [self _editedDefinition:&error];
	NSString *oldName = [[sequenceName copy] autorelease];
	if (!definition || ![sequences alterSequence:oldName to:definition error:&error]) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change the sequence “%@”", @"Postgres sequence: alter failed"), oldName]];
		return NO;
	}

	NSString *newName = [definition name] ?: oldName;
	[self setSequenceName:newName];
	[self _load];

	// Last: the tab may show another sequence (a rename reloads its list)
	[[self retain] autorelease];
	if (sequenceDidChange) sequenceDidChange(newName);
	return YES;
}

- (IBAction)apply:(id)sender
{
	// Return is its key equivalent, which the task display's blocker doesn't stop
	if (invalidated || !sequence || [self _refuseChangeWhileBusy]) return;
	NSWindow *window = [view window];
	if (window && [[window firstResponder] isKindOfClass:[NSText class]] && ![window makeFirstResponder:nil]) return;
	[self commitPendingEdits];
}

- (IBAction)revert:(id)sender
{
	if (invalidated) return;
	[self _loadSwitching:NO];
}

/// A field's text changed: that field is edited.
- (void)controlTextDidChange:(NSNotification *)notification
{
	// The Set Value sheet's field: Set follows it
	if ([notification object] == setValueField) {
		[self _validateSetValueSheet];
		return;
	}

	NSString *key = [form keyOfControl:[notification object]];
	if (!key || !sequence) return;
	[editedKeys addObject:key];
	[self _updateControls];
}

/// A pop-up or the checkbox changed.
- (void)_controlEdited:(id)sender
{
	NSString *key = [form keyOfControl:sender];
	if (!key || !sequence) return;
	[editedKeys addObject:key];
	[self _updateControls];
}

/// Escape in a field gives the edits up.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
	if (commandSelector == @selector(cancelOperation:) && [form keyOfControl:control]) {
		[self revert:control];
		return YES;
	}
	return NO;
}

#pragma mark Set Value

- (IBAction)setValue:(id)sender
{
	NSWindow *window = [view window];
	if (invalidated || !sequence || setValueSheet || !window || [window attachedSheet] || [self _refuseChangeWhileBusy]) return;

	// Edits are applied first (the value is set on what the server has)
	if ([[window firstResponder] isKindOfClass:[NSText class]] && ![window makeFirstResponder:nil]) return;
	if (![self commitPendingEdits]) return;

	NSFont *smallFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	setValueSheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 130) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[setValueSheet setReleasedWhenClosed:NO];
	[setValueSheet setTitle:NSLocalizedString(@"Set Value", @"Postgres sequence: set value sheet title")];
	NSView *content = [setValueSheet contentView];

	NSTextField *message = [NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Set the value of “%@” to:", @"Postgres sequence: set value message"), sequenceName]];
	[message setFrame:NSMakeRect(17, 96, 266, 16)];
	[message setFont:smallFont];
	[message setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[content addSubview:message];

	setValueField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 70, 260, 21)];
	[setValueField setIdentifier:@"setValueField"];
	[setValueField setFont:smallFont];
	[[setValueField cell] setUsesSingleLineMode:YES];
	NSNumberFormatter *formatter = SPPostgresSequenceNewFormatter();
	[setValueField setFormatter:formatter];
	[formatter release];
	NSNumber *suggested = [sequence lastValue] ?: [sequence pendingValue];
	if (suggested) [setValueField setObjectValue:suggested];
	[setValueField setDelegate:(id<NSTextFieldDelegate>)self];
	[content addSubview:setValueField];

	setValueNextCall = [[NSButton checkboxWithTitle:NSLocalizedString(@"Next call returns this value", @"Postgres sequence: set value is_called false checkbox") target:nil action:NULL] retain];
	[setValueNextCall setIdentifier:@"setValueNextCall"];
	[setValueNextCall setFont:smallFont];
	[setValueNextCall setFrame:NSMakeRect(18, 44, 262, 18)];
	[content addSubview:setValueNextCall];

	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(_closeSetValueSheet:)];
	[cancel setFrame:NSMakeRect(104, 10, 90, 28)];
	[cancel setTag:NSModalResponseCancel];
	[cancel setKeyEquivalent:@"\e"];
	[content addSubview:cancel];

	setValueOKButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Set", @"Postgres sequence: set value button in the sheet") target:self action:@selector(_closeSetValueSheet:)] retain];
	[setValueOKButton setIdentifier:@"setValueButton"];
	[setValueOKButton setFrame:NSMakeRect(194, 10, 90, 28)];
	[setValueOKButton setTag:NSModalResponseOK];
	[setValueOKButton setKeyEquivalent:@"\r"];
	[content addSubview:setValueOKButton];

	[setValueSheet setInitialFirstResponder:setValueField];
	[self _validateSetValueSheet];

	NSString *name = [[sequenceName copy] autorelease];
	SPPostgresSequences *target = [[sequences retain] autorelease];
	[self retain]; // until the sheet ends
	[window beginSheet:setValueSheet completionHandler:^(NSModalResponse returnCode) {
		NSNumber *value = nil;
		BOOL ok = (returnCode == NSModalResponseOK) && SPPostgresSequenceReadNumber(setValueField, @"", &value, NULL) && value;
		BOOL isCalled = ([setValueNextCall state] != NSControlStateValueOn);

		[setValueField setDelegate:nil];
		[setValueSheet orderOut:nil];
		[setValueSheet release], setValueSheet = nil;
		[setValueField release], setValueField = nil;
		[setValueNextCall release], setValueNextCall = nil;
		[setValueOKButton release], setValueOKButton = nil;

		if (ok && !invalidated && target == sequences && ![self _refuseChangeWhileBusy]) {
			NSError *error = nil;
			if ([target setValue:value isCalled:isCalled ofSequence:name error:&error]) {
				[self _load];
				if (sequenceDidChange) sequenceDidChange(name);
			}
			else {
				[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not set the value of “%@”", @"Postgres sequence: setval failed"), name]];
			}
		}
		[self release];
	}];
}

- (void)_validateSetValueSheet
{
	NSNumber *value = nil;
	[setValueOKButton setEnabled:SPPostgresSequenceReadNumber(setValueField, @"", &value, NULL) && value != nil];
}

- (void)_closeSetValueSheet:(id)sender
{
	if (!setValueSheet) return;
	if ([sender tag] == NSModalResponseOK && ![setValueOKButton isEnabled]) {
		NSBeep();
		return;
	}
	[[setValueSheet sheetParent] endSheet:setValueSheet returnCode:[sender tag]];
}

@end

#pragma mark - Add Sequence sheet

@implementation SPPostgresSequenceSheet
{
	NSWindow *sheet;
	SPPostgresSequenceForm *form;
	NSButton *addButton;
	void (^completion)(SPPostgresSequenceDefinition *);
}

+ (NSWindow *)beginInSchema:(NSString *)schema connection:(PGPostgresConnection *)connection window:(NSWindow *)window
				 completion:(void (^)(SPPostgresSequenceDefinition *))theCompletion
{
	if (!theCompletion) return nil;
	if (!window || [window attachedSheet]) {
		theCompletion(nil);
		return nil;
	}

	SPPostgresSequences *sequences = [[[SPPostgresSequences alloc] initWithConnection:connection schema:schema] autorelease];
	NSArray *candidates = [sequences ownerColumnCandidates:NULL] ?: @[];

	SPPostgresSequenceSheet *controller = [[self alloc] init];
	NSWindow *shown = [controller _beginOn:window schema:schema candidates:candidates completion:theCompletion]; // keeps itself until the sheet ends
	[controller release];
	return shown;
}

- (void)dealloc
{
	[form release];
	[sheet release];
	[addButton release];
	[completion release];
	[super dealloc];
}

- (NSWindow *)_beginOn:(NSWindow *)window schema:(NSString *)schema candidates:(NSArray *)candidates completion:(void (^)(SPPostgresSequenceDefinition *))theCompletion
{
	completion = [theCompletion copy];

	CGFloat width = 440, height = 360;
	sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[sheet setReleasedWhenClosed:NO];
	[sheet setTitle:NSLocalizedString(@"Add Sequence", @"Postgres add sequence sheet title")];
	NSView *content = [sheet contentView];

	NSTextField *message = [NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Add a sequence to schema “%@”:", @"Postgres add sequence sheet message"), schema]];
	[message setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
	[message setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[message setFrame:NSMakeRect(SPPostgresSequenceMargin, height - 34, width - 2 * SPPostgresSequenceMargin, 17)];
	[content addSubview:message];

	form = [[SPPostgresSequenceForm alloc] initInView:content top:height - 44 width:width small:NO delegate:self target:nil action:NULL];
	[form showCandidates:candidates selected:nil];

	// bigint, start 1, increment 1, cache 1, no cycle, owned by None; Minimum and Maximum: the type's defaults
	SPPostgresSequenceDefinition *defaults = [[[SPPostgresSequenceDefinition alloc] init] autorelease];
	[defaults setName:@""];
	[defaults setDataType:@"bigint"];
	[defaults setStart:@1];
	[defaults setIncrement:@1];
	[defaults setCache:@1];
	[form showDefinition:defaults];

	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"cancel button") target:self action:@selector(_close:)];
	[cancel setFrame:NSMakeRect(width - SPPostgresSequenceMargin - 190, 12, 90, 28)];
	[cancel setTag:NSModalResponseCancel];
	[cancel setKeyEquivalent:@"\e"];
	[content addSubview:cancel];

	addButton = [[NSButton buttonWithTitle:NSLocalizedString(@"Add", @"Postgres add sequence sheet: add button") target:self action:@selector(_close:)] retain];
	[addButton setIdentifier:@"sequenceAddButton"];
	[addButton setFrame:NSMakeRect(width - SPPostgresSequenceMargin - 96, 12, 96, 28)];
	[addButton setTag:NSModalResponseOK];
	[addButton setKeyEquivalent:@"\r"];
	[content addSubview:addButton];

	[sheet setInitialFirstResponder:form->nameField];
	[self _validate];

	[self retain]; // until the sheet ends
	[window beginSheet:sheet completionHandler:^(NSModalResponse returnCode) {
		NSError *error = nil;
		SPPostgresSequenceDefinition *definition = (returnCode == NSModalResponseOK) ? [form definition:&error] : nil;
		[definition setName:[self _name]];
		[form detach];
		[sheet orderOut:nil];
		void (^done)(SPPostgresSequenceDefinition *) = [[completion retain] autorelease];
		[completion release];
		completion = nil;
		if (done) done(definition);
		[self release];
	}];
	return sheet;
}

/// The typed name, trimmed (as the Duplicate and Rename Table sheets do).
- (NSString *)_name
{
	return [[form->nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// Add needs a name PostgreSQL keeps as given and whole numbers.
- (void)_validate
{
	[addButton setEnabled:[SPPostgresTableDuplicator isValidTableName:[self _name]] && [form definition:NULL] != nil];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self _validate];
}

- (void)_close:(id)sender
{
	if ([sender tag] == NSModalResponseOK && ![addButton isEnabled]) {
		NSBeep();
		return;
	}
	[[sheet sheetParent] endSheet:sheet returnCode:[sender tag]];
}

@end
