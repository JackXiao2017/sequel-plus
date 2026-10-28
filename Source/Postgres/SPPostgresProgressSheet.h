#import <Cocoa/Cocoa.h>

/**
 * The sheet shown while a background job (an export, an import) runs: a title, a status line, a determinate bar and
 * Cancel. Built in code. -beginOnWindow:title: and -end are for the main thread; -setStatus:fraction:, -cancelled and
 * -cancel: can be called from any thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresProgressSheet : NSObject

/// Shows the sheet on window (it is attached once the window can take a sheet). The sheet keeps itself alive until -end.
+ (instancetype)beginOnWindow:(NSWindow *)window title:(NSString *)title;

/**
 * Sets the status line and the bar (fraction from 0 to 1; a negative one leaves the bar as it is). Thread-safe and
 * throttled: the sheet is updated on the main thread at most about 10 times a second, always ending with the latest
 * values.
 */
- (void)setStatus:(NSString *)status fraction:(double)fraction;

/// YES once Cancel was clicked (or -cancel: called). Thread-safe.
@property (readonly) BOOL cancelled;

/// What Cancel does: sets cancelled (the job checks it and stops) and shows "Cancelling…". Thread-safe.
- (IBAction)cancel:(id)sender;

/// Called once on the main thread when Cancel is clicked (or -cancel: called from any thread), after cancelled is set:
/// e.g. to stop a job still waiting for its connection. Cleared by -end.
@property (copy) void (^cancelHandler)(void);

/// Ends the sheet. Later status updates are ignored.
- (void)end;

#pragma mark - For tests

@property (readonly) NSPanel *panel;
@property (readonly) NSTextField *titleField;
@property (readonly) NSTextField *statusField;
@property (readonly) NSProgressIndicator *progressIndicator;
@property (readonly) NSButton *cancelButton;

@end
