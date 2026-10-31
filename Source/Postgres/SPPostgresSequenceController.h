#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;
@class SPPostgresTaskRunner;
@class SPPostgresSequence;
@class SPPostgresSequenceDefinition;

/**
 * The Sequence pane of a PostgreSQL tab (shown while a sequence is selected in the sidebar), laid out as the Table
 * Info pane: a grid of labels with the editable Name, Type, Start, Increment, Minimum, Maximum, Cache, Cycle,
 * Owned by (None or an integer column of the schema's tables) and Comment, then the read-only Owner and Current
 * value, and the Revert, Set Value… and Apply buttons. Number fields take integers only (an NSNumberFormatter with
 * no fraction digits, over the bigint range); an empty Minimum or Maximum means the type's default. An identity
 * column's sequence shows a note, with Name, Type and Owned by read-only. Built in code. Use on the main thread.
 *
 * Edits are pending once the user changes a field (and only then: showing a sequence is never an edit). Apply, or
 * leaving (-commitPendingEdits, which the tab calls before it moves on), sends them with
 * -[SPPostgresSequences alterSequence:to:error:], which sends only what differs from the server. If that fails, an
 * alert shows the server's message, the fields keep what was typed, and -commitPendingEdits returns NO. Revert and
 * Escape in a field give the edits up and read the sequence again.
 *
 * Loads (-showSequence:inSchema:, -reload, Revert) run through taskRunner: with the tab's background runner they
 * return at once and the end state they document holds once the runner is idle. A cancelled load shows no alert: a
 * cancelled switch leaves the pane empty and stale (a reload, or the tab showing it again, loads it); a cancelled
 * reload keeps what was shown. The changes (Apply, -commitPendingEdits, Set Value…) run on the main thread and are
 * refused (NSBeep; the edits stay, -commitPendingEdits returns NO) while the runner is busy.
 */
__attribute__((visibility("default")))
@interface SPPostgresSequenceController : NSObject <NSTextFieldDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The pane. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows schema.name (a nil name empties the pane, giving up any edits). A read error is shown as an alert and in
/// the bottom line.
- (void)showSequence:(NSString *)name inSchema:(NSString *)schema;

/// Reads the sequence again, giving up any edits (Revert).
- (void)reload;

/// Applies pending edits. YES when there were none or they were applied; NO (after the alert) if they failed.
- (BOOL)commitPendingEdits;

/// Ends a Set Value sheet still up, detaches the controls and drops the blocks (on close or replace; also on dealloc).
- (void)invalidate;

/// Apply: sends the edits (see -commitPendingEdits) and reads the sequence again.
- (IBAction)apply:(id)sender;
/// Revert: gives the edits up and reads the sequence again.
- (IBAction)revert:(id)sender;
/// Set Value…: a sheet with the value and "Next call returns this value" (setval's is_called NO).
- (IBAction)setValue:(id)sender;

@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *sequenceName;
/// What the pane shows (nil when empty or the read failed).
@property (readonly) SPPostgresSequence *sequence;
/// YES once the user changed a field, until it is applied, reverted or another sequence is shown.
@property (readonly) BOOL hasPendingEdits;

@property (readonly) NSTextField *nameField;
@property (readonly) NSPopUpButton *typePopup;
@property (readonly) NSTextField *startField;
@property (readonly) NSTextField *incrementField;
@property (readonly) NSTextField *minValueField;
@property (readonly) NSTextField *maxValueField;
@property (readonly) NSTextField *cacheField;
@property (readonly) NSButton *cycleSwitch;
/// "None", then the candidate columns (@"schema.table.column").
@property (readonly) NSPopUpButton *ownedByPopup;
@property (readonly) NSTextField *commentField;
@property (readonly) NSTextField *ownerField;
/// The last value, or "Not used yet".
@property (readonly) NSTextField *currentValueField;
/// The identity column note, or @"".
@property (readonly) NSTextField *identityNoteField;
@property (readonly) NSButton *applyButton;
@property (readonly) NSButton *revertButton;
@property (readonly) NSButton *setValueButton;
/// The Set Value sheet while it is up.
@property (readonly) NSWindow *setValueSheet;
/// The bottom line: the read error, or @"".
@property (readonly, copy) NSString *noticeText;

/// Seconds a change waits for a lock held elsewhere before it fails (default 5).
@property (nonatomic) NSTimeInterval lockTimeout;

/// Runs the loads (default: an inline runner on the connection, so a load has finished when its method returns).
@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;
/// A switch was cancelled before the sequence loaded: the pane is empty until a reload or the next show loads it.
@property (readonly, getter=isStale) BOOL stale;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Called after the sequence was changed (Apply, Set Value…), with its name now (it may have been renamed).
@property (copy) void (^sequenceDidChange)(NSString *name);

@end

/**
 * The Add Sequence… sheet: the pane's fields (no Owner or Current value), prefilled with bigint, start 1, increment
 * 1, cache 1, no cycle, owned by None, and Cancel/Add (Add needs a name of at most 63 bytes). Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresSequenceSheet : NSObject <NSTextFieldDelegate>

/**
 * Shows the sheet on window, listing the integer columns of schema's tables for Owned by. completion is called
 * exactly once: with the definition (Add), or nil (Cancel, or the sheet couldn't be shown). Returns the sheet (nil
 * if it couldn't be shown), which the caller may end with NSModalResponseCancel, e.g. when the tab closes.
 */
+ (NSWindow *)beginInSchema:(NSString *)schema connection:(PGPostgresConnection *)connection window:(NSWindow *)window
				 completion:(void (^)(SPPostgresSequenceDefinition *definitionOrNil))completion;

@end
