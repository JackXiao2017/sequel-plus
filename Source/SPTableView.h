//
//  SPTableView.h
//  sequel-pro
//
//  Created by Hans-Jörg Bibiko on July 15, 2009.
//  Copyright (c) 2009 Hans-Jörg Bibiko. All rights reserved.
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

@interface SPTableView : NSTableView
{
	BOOL tabEditingDisabled;
	SEL emptyDoubleClickAction;
	NSEvent *cellButtonEvent;
}

@property (readwrite, assign) BOOL tabEditingDisabled;

- (void)setEmptyDoubleClickAction:(SEL)aSelector;

/// YES while the event being handled is a click on a cell's button (value icon, picker icon, link arrow): a left mouse
/// down on one, or the event a cell followed its button on (-cellDidFollowButton).
- (BOOL)isClickingCellButton;
/// Called by a cell (SPTextAndLinkCell) once it has followed one of its buttons, during the event that did it.
- (void)cellDidFollowButton;

@end
