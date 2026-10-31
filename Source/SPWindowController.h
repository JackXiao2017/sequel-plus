//
//  SPWindowController.h
//  sequel-pro
//
//  Created by Rowan Beentje on May 16, 2010.
//  Copyright (c) 2010 Rowan Beentje. All rights reserved.
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

#import "SPWindowTabDocument.h"

@class PSMTabBarControl;
@class SPDatabaseDocument;

// Default visibility so the app-hosted test bundle can link it despite the app hiding symbols.
__attribute__((visibility("default")))
@interface SPWindowController : NSWindowController <NSWindowDelegate>
{
	IBOutlet PSMTabBarControl *tabBar;
	IBOutlet NSTabView *tabView;

	NSClipView *titleBarLineHidingView;
	BOOL isOSVersionAtLeast10_7_0;

	NSMenuItem *closeWindowMenuItem;
	NSMenuItem *closeTabMenuItem;

	NSMutableArray *managedDatabaseConnections;
	SPDatabaseDocument *selectedTableDocument;

	// The selected tab's document of any engine (not retained, like selectedTableDocument).
	// Equal to selectedTableDocument whenever the selected tab is a MySQL tab.
	id <SPWindowTabDocument> selectedTabDocument;
}

// Database connection management
- (IBAction)addNewConnection:(id)sender;
- (IBAction)moveSelectedTabInNewWindow:(id)sender;

- (SPDatabaseDocument *)addNewConnection;

/**
 * @danger THIS IS NOT RETAINED!!! 
 *
 * Ever only directly use it on the main thread! 
 * Do not cache it without retaining first!
 * For background threads get it and retain it via the main thread!
 *   Release it on the main thread again.
 */
- (SPDatabaseDocument *)selectedTableDocument;

/**
 * The selected tab's document, whatever its engine. -selectedTableDocument is this document
 * when it is an SPDatabaseDocument, and nil otherwise. Not retained (see above).
 */
- (id <SPWindowTabDocument>)selectedDocument;

/**
 * Every tab's document, of any engine, in tab order. -documents lists only the MySQL ones.
 */
- (NSArray *)tabDocuments;

/**
 * Hosts a document in a new tab at index (clamped to the tab count). The tab view item retains
 * the document; the window controller does not.
 */
- (void)addTabDocument:(id <SPWindowTabDocument>)document atIndex:(NSInteger)index select:(BOOL)select;

/**
 * Puts newDocument in oldDocument's tab position and selects it; oldDocument's tab is closed
 * and it receives -parentTabDidClose.
 */
- (void)replaceTabDocument:(id <SPWindowTabDocument>)oldDocument withDocument:(id <SPWindowTabDocument>)newDocument;

- (void)updateSelectedTableDocument;
- (void)updateAllTabTitles:(id)sender;
- (IBAction)closeTab:(id)sender;
- (IBAction)selectNextDocumentTab:(id)sender;
- (IBAction)selectPreviousDocumentTab:(id)sender;
- (IBAction)toggleTabBarShown:(id)sender;
- (NSArray *)documents;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)setHideForSingleTab:(BOOL)hide;
- (void)updateTabBar;

@end
