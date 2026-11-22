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

@implementation SPTextAndLinkCell

@synthesize linkActive;
@synthesize valueIconActive;
@synthesize allowsExpansionToolTips;

/**
 * Provide a method to derive the link rect from a cell rect.
 */
NSRect SPTextLinkRectFromCellRect(NSRect inRect)
{
	return NSMakeRect(inRect.origin.x + inRect.size.width - 15, inRect.origin.y - 1, 12, inRect.size.height);
}

static const CGFloat SPTextValueIconGap = 6; // between the text and the value icon

/// The value icon sits where the arrow does (at the right edge, the same size); with the arrow, right next to it.
NSRect SPTextValueIconRectFromCellRect(NSRect inRect, BOOL hasLinkArrow)
{
	NSRect arrow = SPTextLinkRectFromCellRect(inRect);
	return hasLinkArrow ? NSOffsetRect(arrow, -(NSWidth(arrow) + 2), 0) : arrow;
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

#pragma mark -
#pragma mark Drawing and interaction

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
	// The text stops short of the value icon (a gap between them, so they never touch)
	if ([self _valueIconShows]) textRect.size.width = MAX(0, NSMinX(SPTextValueIconRectFromCellRect(cellFrame, [self _linkShows])) - SPTextValueIconGap - NSMinX(cellFrame));
	else if ([self _linkShows]) textRect.size.width = MAX(0, cellFrame.size.width - 18);
	return textRect;
}

- (SPTextAndLinkCellButton)buttonAtPoint:(NSPoint)p inCellFrame:(NSRect)cellFrame
{
	if ([self _linkShows]) {
		NSRect linkRect = SPTextLinkRectFromCellRect(cellFrame);
		if (p.x > linkRect.origin.x && p.x < (linkRect.origin.x + linkRect.size.width)) return SPTextAndLinkCellLinkButton;
	}
	if ([self _valueIconShows]) {
		NSRect iconRect = SPTextValueIconRectFromCellRect(cellFrame, [self _linkShows]);
		if (p.x > iconRect.origin.x && p.x < NSMaxX(iconRect)) return SPTextAndLinkCellValueButton;
	}
	return SPTextAndLinkCellNoButton;
}

/// Records the clicked row and column (at point, in tableView) and sends the button's action.
- (void)_followButton:(SPTextAndLinkCellButton)button atPoint:(NSPoint)p inTableView:(NSTableView *)tableView
{
	lastLinkColumn = [tableView columnAtPoint:p];
	lastLinkRow = [tableView rowAtPoint:p];
	id target = (button == SPTextAndLinkCellValueButton) ? valueTarget : linkTarget;
	SEL action = (button == SPTextAndLinkCellValueButton) ? valueAction : linkAction;
	if (target && action) [target performSelector:action withObject:self];
}

/**
 * Redraw the table cell, altering super draw behavior to leave space
 * for the link if necessary.
 */
- (void)drawInteriorWithFrame:(NSRect)aRect inView:(NSView *)controlView
{

	// Fast case for no buttons
	if (![self _linkShows] && ![self _valueIconShows]) {
		[super drawInteriorWithFrame:aRect inView:controlView];
		return;
	}

	// Draw the text
	[super drawInteriorWithFrame:[self textFrameForCellFrame:aRect] inView:controlView];

	// The value icon: a template image, white on an emphasized selection as the text is
	if ([self _valueIconShows]) {
		[valueButton setBackgroundStyle:[self backgroundStyle]];
		[valueButton drawInteriorWithFrame:SPTextValueIconRectFromCellRect(aRect, [self _linkShows]) inView:controlView];
	}
	if (![self _linkShows]) return;

	NSRect linkRect = SPTextLinkRectFromCellRect(aRect);

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
	if (![self _linkShows] && ![self _valueIconShows]) return NSCellHitContentArea | NSCellHitEditableTextArea;

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
	if (![self _linkShows] && ![self _valueIconShows]) return [super trackMouse:theEvent inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];

	NSPoint p = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];

	// Fast path for if not in a button rect - just pass to super
	SPTextAndLinkCellButton button = [self buttonAtPoint:p inCellFrame:cellFrame];
	if (button == SPTextAndLinkCellNoButton)
		return [super trackMouse:theEvent inRect:cellFrame ofView:controlView untilMouseUp:untilMouseUp];
	NSButtonCell *buttonCell = (button == SPTextAndLinkCellValueButton) ? valueButton : linkButton;
	NSRect linkRect = (button == SPTextAndLinkCellValueButton) ? SPTextValueIconRectFromCellRect(cellFrame, [self _linkShows]) : SPTextLinkRectFromCellRect(cellFrame);

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
