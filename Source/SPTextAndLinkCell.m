//
//  SPTextAndLinkCell.m
//  sequel-pro
//
//  Created by Rowan Beentje on July 16, 2009.
//  Copyright (c) 2009 Rowan Beentje. All rights reserved.
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

#import "SPTextAndLinkCell.h"
#import "SPTableView.h"

@implementation SPTextAndLinkCell

@synthesize linkActive;
@synthesize valueIconActive;
@synthesize pickerIconActive;
@synthesize allowsExpansionToolTips;

/**
 * Provide a method to derive the link rect from a cell rect.
 */
NSRect SPTextLinkRectFromCellRect(NSRect inRect)
{
	return NSMakeRect(inRect.origin.x + inRect.size.width - 15, inRect.origin.y - 1, 12, inRect.size.height);
}

static const CGFloat SPTextValueIconGap = 6; // between the text and the value icon

/// Buttons sit where the arrow alone does (at the right edge, the same size), each next one just left of the previous.
NSRect SPTextButtonSlotRect(NSRect inRect, NSUInteger slot)
{
	NSRect arrow = SPTextLinkRectFromCellRect(inRect);
	return NSOffsetRect(arrow, -(CGFloat)slot * (NSWidth(arrow) + 2), 0);
}

NSRect SPTextValueIconRectFromCellRect(NSRect inRect, BOOL hasLinkArrow)
{
	return SPTextButtonSlotRect(inRect, hasLinkArrow ? 1 : 0);
}

static const NSCellImagePosition SPTextValueIconImagePosition = NSImageRight; // as the arrow's image


#pragma mark -
#pragma mark Setup and teardown

/**
 * Initialise
 */
- (id) initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self) {
		hasLink = NO;
		linkActive = YES;
		linkButton = nil;
		linkTarget = nil;
		drawState = SPLinkDrawStateNormal;
		
		lastLinkColumn = NSNotFound;
		lastLinkRow = NSNotFound;
	}
	return self;
}

/**
 * Deallocate
 */
- (void) dealloc
{
	if (linkButton) SPClear(linkButton);
	if (valueButton) SPClear(valueButton);
	if (pickerButton) SPClear(pickerButton);

	[super dealloc];
}

/**
 * Encodes using a given receiver.
 */
- (void) encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
}

/**
 * Returns a new instance which is a copy of the receiver
 */
- (id) copyWithZone:(NSZone *)zone {
	SPTextAndLinkCell *copy = (SPTextAndLinkCell *)[super copyWithZone:zone];
	copy->linkButton = nil;
	if (linkButton) copy->linkButton = [linkButton copyWithZone:zone];
	copy->linkTarget = linkTarget;
	copy->linkAction = linkAction;
	copy->valueButton = valueButton ? [valueButton copyWithZone:zone] : nil;
	copy->valueTarget = valueTarget;
	copy->valueAction = valueAction;
	copy->pickerButton = pickerButton ? [pickerButton copyWithZone:zone] : nil;
	copy->pickerTarget = pickerTarget;
	copy->pickerAction = pickerAction;
	return copy;
}


#pragma mark -
#pragma mark Enabling link functionality

/**
 * Set the link target and action - this also enables the link
 * arrow within the cell.
 */
- (void) setTarget:(id)theTarget action:(SEL)theAction
{
	linkTarget = theTarget;
	linkAction = theAction;

	if (!hasLink) {
		hasLink = YES;

		linkButton = [[NSButtonCell alloc] init];
		[linkButton setButtonType:NSMomentaryChangeButton];
		[linkButton setImagePosition:NSImageRight];
		[linkButton setTitle:@""];
		[linkButton setBordered:NO];
		[linkButton setShowsBorderOnlyWhileMouseInside:YES];
		[linkButton setImage:[NSImage imageNamed:@"link-arrow"]];
		[linkButton setAlternateImage:[NSImage imageNamed:@"link-arrow-clicked"]];
	}
}

/**
 * Set the value icon's target and action - this also enables the icon (shown while valueIconActive).
 */
- (void)setValueTarget:(id)theTarget action:(SEL)theAction
{
	valueTarget = theTarget;
	valueAction = theAction;

	if (!hasValueIcon) {
		hasValueIcon = YES;

		valueButton = [[NSButtonCell alloc] init];
		[valueButton setButtonType:NSButtonTypeMomentaryChange];
		[valueButton setImagePosition:SPTextValueIconImagePosition];
		[valueButton setTitle:@""];
		[valueButton setBordered:NO];
		NSImage *image = [NSImage imageWithSystemSymbolName:@"doc.text.magnifyingglass" accessibilityDescription:NSLocalizedString(@"Show the whole value", @"value popover icon: accessibility description")];
		NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightRegular];
		image = [image imageWithSymbolConfiguration:configuration] ?: image;
		[image setTemplate:YES];
		[valueButton setImage:image];
		[valueButton setImageScaling:NSImageScaleProportionallyDown];
	}
}

/**
 * Set the picker icon's target and action - this also enables the icon (shown while pickerIconActive).
 */
- (void)setPickerTarget:(id)theTarget action:(SEL)theAction
{
	pickerTarget = theTarget;
	pickerAction = theAction;

	if (!hasPickerIcon) {
		hasPickerIcon = YES;

		pickerButton = [[NSButtonCell alloc] init];
		[pickerButton setButtonType:NSButtonTypeMomentaryChange];
		[pickerButton setImagePosition:SPTextValueIconImagePosition];
		[pickerButton setTitle:@""];
		[pickerButton setBordered:NO];
		NSImage *image = [NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:NSLocalizedString(@"Choose a value", @"foreign key picker icon: accessibility description")];
		NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightRegular];
		image = [image imageWithSymbolConfiguration:configuration] ?: image;
		[image setTemplate:YES];
		[pickerButton setImage:image];
		[pickerButton setImageScaling:NSImageScaleProportionallyDown];
	}
}

#pragma mark -
#pragma mark Drawing and interaction

- (BOOL)_pickerIconShows
{
	return hasPickerIcon && pickerIconActive;
}

/// The slot of each shown button (the picker icon, the arrow, the value icon, in that order from the right).
- (NSUInteger)_pickerSlot
{
	return 0;
}

- (NSUInteger)_linkSlot
{
	return [self _pickerIconShows] ? 1 : 0;
}

- (NSUInteger)_valueSlot
{
	return ([self _pickerIconShows] ? 1 : 0) + ([self _linkShows] ? 1 : 0);
}

- (NSUInteger)_shownButtonCount
{
	return ([self _linkShows] ? 1 : 0) + ([self _pickerIconShows] ? 1 : 0) + ([self _valueIconShows] ? 1 : 0);
}

- (BOOL)_linkShows
{
	return hasLink && linkActive;
}

- (BOOL)_valueIconShows
{
	return hasValueIcon && valueIconActive;
}

- (NSCellImagePosition)valueIconImagePosition
{
	return SPTextValueIconImagePosition;
}

- (NSRect)textFrameForCellFrame:(NSRect)cellFrame
{
	NSRect textRect = cellFrame;
	// The text stops short of the icons (a gap, so they never touch); the arrow alone keeps its old room
	if ([self _valueIconShows] || [self _pickerIconShows]) {
		NSRect leftmost = SPTextButtonSlotRect(cellFrame, [self _shownButtonCount] - 1);
		textRect.size.width = MAX(0, NSMinX(leftmost) - SPTextValueIconGap - NSMinX(cellFrame));
	}
	else if ([self _linkShows]) textRect.size.width = MAX(0, cellFrame.size.width - 18);
	return textRect;
}

- (SPTextAndLinkCellButton)buttonAtPoint:(NSPoint)p inCellFrame:(NSRect)cellFrame
{
	if ([self _linkShows]) {
		NSRect linkRect = SPTextButtonSlotRect(cellFrame, [self _linkSlot]);
		if (p.x > linkRect.origin.x && p.x < (linkRect.origin.x + linkRect.size.width)) return SPTextAndLinkCellLinkButton;
	}
	if ([self _pickerIconShows]) {
		NSRect iconRect = SPTextButtonSlotRect(cellFrame, [self _pickerSlot]);
		if (p.x > iconRect.origin.x && p.x < NSMaxX(iconRect)) return SPTextAndLinkCellPickerButton;
	}
	if ([self _valueIconShows]) {
		NSRect iconRect = SPTextButtonSlotRect(cellFrame, [self _valueSlot]);
		if (p.x > iconRect.origin.x && p.x < NSMaxX(iconRect)) return SPTextAndLinkCellValueButton;
	}
	return SPTextAndLinkCellNoButton;
}

/// Records the clicked row and column (at point, in tableView) and sends the button's action.
- (void)_followButton:(SPTextAndLinkCellButton)button atPoint:(NSPoint)p inTableView:(NSTableView *)tableView
{
	lastLinkColumn = [tableView columnAtPoint:p];
	lastLinkRow = [tableView rowAtPoint:p];
	id target = (button == SPTextAndLinkCellValueButton) ? valueTarget : (button == SPTextAndLinkCellPickerButton) ? pickerTarget : linkTarget;
	SEL action = (button == SPTextAndLinkCellValueButton) ? valueAction : (button == SPTextAndLinkCellPickerButton) ? pickerAction : linkAction;
	if (target && action) [target performSelector:action withObject:self];
	// The table then asks whether to edit the cell during this same click: it mustn't (see -[SPTableView isClickingCellButton])
	if ([tableView isKindOfClass:[SPTableView class]]) [(SPTableView *)tableView cellDidFollowButton];
}

/**
 * Redraw the table cell, altering super draw behavior to leave space
 * for the link if necessary.
 */
- (void)drawInteriorWithFrame:(NSRect)aRect inView:(NSView *)controlView
{

	// Fast case for no buttons
	if (![self _shownButtonCount]) {
		[super drawInteriorWithFrame:aRect inView:controlView];
		return;
	}

	// Draw the text
	[super drawInteriorWithFrame:[self textFrameForCellFrame:aRect] inView:controlView];

	// The value icon: a template image, white on an emphasized selection as the text is
	if ([self _valueIconShows]) {
		[valueButton setBackgroundStyle:[self backgroundStyle]];
		[valueButton drawInteriorWithFrame:SPTextButtonSlotRect(aRect, [self _valueSlot]) inView:controlView];
	}
	if ([self _pickerIconShows]) {
		[pickerButton setBackgroundStyle:[self backgroundStyle]];
		[pickerButton drawInteriorWithFrame:SPTextButtonSlotRect(aRect, [self _pickerSlot]) inView:controlView];
	}
	if (![self _linkShows]) return;

	NSRect linkRect = SPTextButtonSlotRect(aRect, [self _linkSlot]);

	// Get the new link state
	NSInteger newDrawState = ([self isHighlighted])?
							((([(NSTableView *)[self controlView] editedColumn] != -1
								|| [[[self controlView] window] firstResponder] == [self controlView])
								&& [[[self controlView] window] isKeyWindow])?SPLinkDrawStateHighlight:SPLinkDrawStateBackgroundHighlight):
							SPLinkDrawStateNormal;

	// Update the link arrow style if the state has changed
	if (drawState != newDrawState) {
		drawState = newDrawState;
		switch (drawState) {
			case SPLinkDrawStateNormal:
				[linkButton setImage:[NSImage imageNamed:@"link-arrow"]];
				[linkButton setAlternateImage:[NSImage imageNamed:@"link-arrow-clicked"]];
				break;
			case SPLinkDrawStateHighlight:
				[linkButton setImage:[NSImage imageNamed:@"link-arrow-highlighted"]];
				[linkButton setAlternateImage:[NSImage imageNamed:@"link-arrow-highlighted-clicked"]];
				break;
			case SPLinkDrawStateBackgroundHighlight:
				[linkButton setImage:[NSImage imageNamed:@"link-arrow-clicked"]];
				[linkButton setAlternateImage:[NSImage imageNamed:@"link-arrow"]];
				break;
		}
	}

	[linkButton drawInteriorWithFrame:linkRect inView:controlView];
}

/**
 * Allow hit tracking for link functionality
 */
- (NSCellHitResult) hitTestForEvent:(NSEvent *)event inRect:(NSRect)cellFrame ofView:(NSView *)controlView
{

	// Fast case for no buttons - make entire cell editable click area
	if (![self _shownButtonCount]) return NSCellHitContentArea | NSCellHitEditableTextArea;

	NSPoint p = [[[controlView window] contentView] convertPoint:[event locationInWindow] toView:controlView];

	// Hit a button if it falls within its rectangle for this cell
	if ([self buttonAtPoint:p inCellFrame:cellFrame] != SPTextAndLinkCellNoButton) {

		// Return a trackable hit
		return NSCellHitContentArea | NSCellHitTrackableArea;

	// Otherwise return an editable hit - this allows the entire cell to be clicked to edit the contents.
	} else {
		return NSCellHitContentArea | NSCellHitEditableTextArea;
	}
}

/**
 * Allow mouse tracking within the button cell, to support expected click
 * behaviour in the button cell.
 */
- (BOOL)trackMouse:(NSEvent *)theEvent inRect:(NSRect)cellFrame ofView:(NSView *)controlView untilMouseUp:(BOOL)untilMouseUp
{

	// Fast case for no buttons
	if (![self _shownButtonCount]) return [super trackMouse:theEvent inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];

	NSPoint p = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];

	// Fast path for if not in a button rect - just pass to super
	SPTextAndLinkCellButton button = [self buttonAtPoint:p inCellFrame:cellFrame];
	if (button == SPTextAndLinkCellNoButton)
		return [super trackMouse:theEvent inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];
	NSButtonCell *buttonCell = (button == SPTextAndLinkCellValueButton) ? valueButton : (button == SPTextAndLinkCellPickerButton) ? pickerButton : linkButton;
	NSRect linkRect = (button == SPTextAndLinkCellValueButton) ? SPTextButtonSlotRect(cellFrame, [self _valueSlot])
		: (button == SPTextAndLinkCellPickerButton) ? SPTextButtonSlotRect(cellFrame, [self _pickerSlot]) : SPTextButtonSlotRect(cellFrame, [self _linkSlot]);

	// Ignore events other than mouse down.
	if ([theEvent type] != NSLeftMouseDown) return YES;

	// Continue tracking the mouse while it's down, updating the state as it enters and leaves the cell,
	// until it is released; if still within the cell, follow the link.
	BOOL mouseInButton = YES;
	while (1) {
		if (mouseInButton) {

			// Highlight the button
			[buttonCell highlight:YES withFrame:linkRect inView:controlView];

			// Continue to track until mouse completes a click or exits the cell while still down
			BOOL mouseClicked = [buttonCell trackMouse:theEvent inRect:linkRect ofView:controlView untilMouseUp:NO];
			if (mouseClicked) {

				// Remove highlight, capture the clicked row and cell, and follow the button
				[buttonCell highlight:NO withFrame:linkRect inView:controlView];
				NSTableView *tableView = (NSTableView *)[self controlView];
				p = [[[tableView window] contentView] convertPoint:[theEvent locationInWindow] toView:tableView];
				[self _followButton:button atPoint:p inTableView:tableView];
				return YES;
			}

			// Mouse has exited the cell.  Remove highlight.
			mouseInButton = NO;
			[buttonCell highlight:NO withFrame:linkRect inView:controlView];
		}

		// Keep tracking the mouse outside the button, until the mouse button is released or it reenters the button
		theEvent = [[controlView window] nextEventMatchingMask: NSLeftMouseUpMask | NSLeftMouseDraggedMask];
		p = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];
		mouseInButton = NSMouseInRect(p, linkRect, [controlView isFlipped]);

		// If the event is a mouse release, break the loop.
		if ([theEvent type] == NSLeftMouseUp) break;
	}

	return YES;
}

#pragma mark -
#pragma mark Information getters

/**
 * Retrieve the last column that recorded a click with the link cell
 */
- (NSInteger) getClickedColumn
{
	return lastLinkColumn;
}

/**
 * Retrieve the last row that recorded a click with the link cell
 */
- (NSInteger) getClickedRow
{
	return lastLinkRow;
}

/**
 * Suppress the built-in expansion tooltip
 */
- (NSRect)expansionFrameWithFrame:(NSRect)cellFrame inView:(NSView *)view
{
	if (allowsExpansionToolTips) return [super expansionFrameWithFrame:cellFrame inView:view];
	return NSZeroRect;
}

@end
