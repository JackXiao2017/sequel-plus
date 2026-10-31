#import <Cocoa/Cocoa.h>

@class SPPostgresTaskRunner;

/**
 * Shows a tab's runner at work as MySQL tabs show their tasks: MySQL's ProgressIndicatorLayer (spinner, the task's
 * description, the elapsed time and a Cancel button) in a borderless, clear child window centered on parentWindow,
 * hidden for the task's first 0.5 s, then faded in over 0.6 s. The Cancel button is shown (with the task's title)
 * only while the running task can be cancelled; clicking it disables it and cancels the runner's tasks.
 *
 * While the runner is busy and parentWindow is set, input to blockedView is blocked: a transparent view over it takes
 * every click, scroll and key (the window's first responder, if inside blockedView, moves to it and is given back
 * afterwards while it is still in the window).
 *
 * Main thread only. The display retains its runner until -invalidate; call -invalidate before letting it go.
 */
__attribute__((visibility("default")))
@interface SPPostgresTaskDisplay : NSObject

/// Observes the runner's busy, currentDescription and currentCancelTitle.
- (instancetype)initWithRunner:(SPPostgresTaskRunner *)runner;

/// nil: nothing shown and nothing blocked. Set when the tab becomes active, cleared when it resigns.
@property (assign) NSWindow *parentWindow;
/// The tab's view: input to it is blocked while busy.
@property (assign) NSView *blockedView;

/// The child window (for tests).
@property (readonly) NSWindow *progressWindow;
/// The xib's Cancel button and description text (for tests).
@property (readonly) NSButton *cancelButton;
@property (readonly) NSTextField *descriptionField;

/// The Cancel button's action: disables the button, then cancels the runner's tasks.
- (IBAction)cancelTask:(id)sender;

/// Stops observing the runner and the timers, removes the child window and the blocker. Idempotent.
- (void)invalidate;

@end
