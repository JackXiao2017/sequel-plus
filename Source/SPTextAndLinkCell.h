//
//  SPTextAndLinkCell.h
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

typedef NS_ENUM(NSInteger, SPTextAndLinkCellButton) {
	SPTextAndLinkCellNoButton,
	SPTextAndLinkCellLinkButton,   // the foreign key arrow
	SPTextAndLinkCellValueButton,  // the value icon: opens the whole value (SPValuePopover)
	SPTextAndLinkCellPickerButton  // the picker icon: opens the foreign key value picker (SPForeignKeyPicker)
};

/// The foreign key arrow's rect in a cell's frame (at the right edge).
__attribute__((visibility("default"))) NSRect SPTextLinkRectFromCellRect(NSRect cellRect);
/// The value icon's rect in a cell's frame with no picker icon: left of the arrow when the arrow shows too, else at the
/// right edge.
__attribute__((visibility("default"))) NSRect SPTextValueIconRectFromCellRect(NSRect cellRect, BOOL hasLinkArrow);
/// The rect of the slot-th button from the right edge (0: where the arrow alone sits). Shown buttons take slots in
/// order: the picker icon, the arrow, the value icon.
__attribute__((visibility("default"))) NSRect SPTextButtonSlotRect(NSRect cellRect, NSUInteger slot);

__attribute__((visibility("default")))
@interface SPTextAndLinkCell : NSTextFieldCell 
{
	BOOL hasLink;
	BOOL linkActive;

	NSButtonCell *linkButton;
	id linkTarget;
	SEL linkAction;
	
	NSInteger lastLinkColumn;
	NSInteger lastLinkRow;
	NSInteger drawState;

	BOOL hasValueIcon;
	BOOL valueIconActive;
	BOOL allowsExpansionToolTips;
	NSButtonCell *valueButton;
	id valueTarget;
	SEL valueAction;

	BOOL hasPickerIcon;
	BOOL pickerIconActive;
	NSButtonCell *pickerButton;
	id pickerTarget;
	SEL pickerAction;
}

@property (readwrite, assign) BOOL linkActive;

/// Whether the value icon shows (set per row, as linkActive); only once -setValueTarget:action: gave it an action.
@property (readwrite, assign) BOOL valueIconActive;

/// Whether the picker icon shows (set per row); only once -setPickerTarget:action: gave it an action.
@property (readwrite, assign) BOOL pickerIconActive;

/// NO (as before): the cell suppresses AppKit's expansion tooltip for cut-off text. YES keeps it.
@property (readwrite, assign) BOOL allowsExpansionToolTips;

- (void) setTarget:(id)theTarget action:(SEL)theAction;

/// The value icon's target and action (action:(SPTextAndLinkCell *)sender); getClickedRow/Column tell its row too.
- (void)setValueTarget:(id)theTarget action:(SEL)theAction;

/// The picker icon's target and action (action:(SPTextAndLinkCell *)sender); getClickedRow/Column tell its row too.
- (void)setPickerTarget:(id)theTarget action:(SEL)theAction;

- (NSInteger) getClickedColumn;
- (NSInteger) getClickedRow;

/// The part of cellFrame the text is drawn in: less the active buttons.
- (NSRect)textFrameForCellFrame:(NSRect)cellFrame;
/// The active button at point (in the cell's view), if any.
- (SPTextAndLinkCellButton)buttonAtPoint:(NSPoint)point inCellFrame:(NSRect)cellFrame;
/// Where the value icon's image sits in its rect (for tests).
- (NSCellImagePosition)valueIconImagePosition;

@end
