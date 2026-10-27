#import <Cocoa/Cocoa.h>

/**
 * Return a copy of a toolbar image drawn at 24x24, as NSToolbar's size mode is ignored on modern macOS.
 * (Default visibility so the app-hosted test bundle can link it despite the app hiding symbols.)
 */
__attribute__((visibility("default"))) NSImage *SPCompactToolbarImage(NSImage *image);

/**
 * The compact window look shared by the MySQL and PostgreSQL windows.
 */
@interface NSWindow (SPCompactChrome)

/**
 * Hide the system title and show it in a smaller font, centered in the titlebar. AppKit has no public
 * API for the title font, so a label with identifier SPCompactWindowTitle is used; if the titlebar
 * can't be found the default title is left as is.
 */
- (void)sp_applyCompactTitle;

/**
 * Use the expanded toolbar style (title on its own row above the toolbar) and keep the compact title
 * updated on every resize. Safe to call repeatedly: the window keeps a single resize observer.
 */
- (void)sp_useExpandedCompactToolbar;

/**
 * Stop re-applying the compact title on resize (the counterpart of sp_useExpandedCompactToolbar).
 */
- (void)sp_stopCompactTitleTracking;

@end
