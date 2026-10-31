//
//  SPWindowTabDocument.h
//  sequel-pro
//
//  The contract between SPWindowController and the document hosted in one of its tabs.
//  SPDatabaseDocument (MySQL) conforms with methods it already had; other engines' documents
//  (PostgreSQL) conform so they can live in the same windows.
//
//  The window controller does not retain a tab document itself: the NSTabViewItem that
//  carries it as its identifier does, exactly as for MySQL documents.
//

#import <Cocoa/Cocoa.h>

@class SPWindowController;

@protocol SPWindowTabDocument <NSObject>

- (NSView *)databaseView;

- (void)setParentWindowController:(SPWindowController *)controller;
- (void)setParentWindow:(NSWindow *)window;
- (void)setParentTabViewItem:(NSTabViewItem *)item;

- (void)didBecomeActiveTabInWindow;
- (void)willResignActiveTabInWindow;
- (void)updateWindowTitle:(id)sender;

- (BOOL)parentTabShouldClose;
- (void)parentTabDidClose;

/**
 * Drives the tab's progress indicator (bound and observed via KVO), so it must be KVO-compliant.
 */
@property (readonly) BOOL isProcessing;

@optional

- (void)tabDidBecomeKey;
- (void)tabDidResize;

/**
 * Tooltip shown for the tab while it is not selected.
 */
- (NSString *)tabToolTip;

/**
 * Sent just before the tab is closed by -[SPWindowController replaceTabDocument:withDocument:]
 * (its place taken by another document), so -parentTabDidClose can tell that close from the user's.
 */
- (void)setIsBeingReplacedInTab:(BOOL)flag;

@end
