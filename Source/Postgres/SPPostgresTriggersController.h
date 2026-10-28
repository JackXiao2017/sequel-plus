#import <Cocoa/Cocoa.h>

@class PGPostgresConnection;

/// A trigger to add, as the add-trigger sheet returns it (see -[SPPostgresTableStructure addTriggerNamed:…]).
__attribute__((visibility("default")))
@interface SPPostgresTriggerDefinition : NSObject
{
	NSString *_name;
	NSString *_timing;
	NSArray *_events;
	NSArray *_updateColumns;
	NSString *_level;
	NSString *_function;
	NSString *_condition;
}

@property (readwrite, copy) NSString *name;
/// @"BEFORE" or @"AFTER" (@"INSTEAD OF" is for views).
@property (readwrite, copy) NSString *timing;
/// Some of @"INSERT", @"UPDATE", @"DELETE", @"TRUNCATE".
@property (readwrite, copy) NSArray *events;
/// UPDATE OF these columns; nil or empty for any column.
@property (readwrite, copy) NSArray *updateColumns;
/// @"ROW" or @"STATEMENT".
@property (readwrite, copy) NSString *level;
/// One of -[SPPostgresTableStructure triggerFunctions:] (@"schema.name", quoted when needed).
@property (readwrite, copy) NSString *function;
/// The WHEN condition as typed (sent as is); nil for none.
@property (readwrite, copy) NSString *condition;

@end

/**
 * The add-trigger sheet, built in code: a name, the timing (BEFORE / AFTER), the events (INSERT, UPDATE, DELETE,
 * TRUNCATE checkboxes) with the columns UPDATE is limited to (optional), the level (FOR EACH ROW / STATEMENT), the
 * trigger function (from the list given), and an optional WHEN condition (sent as typed).
 *
 * Add is enabled only for what PostgreSQL could take: a name of at most 63 bytes, at least one event, a function,
 * TRUNCATE and WHEN only where the level allows (TRUNCATE: statement level; WHEN: row level).
 *
 * Use on the main thread. completion is called exactly once: with the definition (Add), or nil (Cancel, or the
 * window can't take a sheet).
 */
__attribute__((visibility("default")))
@interface SPPostgresTriggerSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

+ (void)beginWithColumns:(NSArray *)columnNames functions:(NSArray *)functions window:(NSWindow *)window completion:(void (^)(SPPostgresTriggerDefinition *definitionOrNil))completion;

@end

/**
 * The Triggers view of a PostgreSQL tab, laid out as MySQL's Triggers tab: a grid of the table's triggers (Name,
 * Timing, Event, Level, Function, Enabled) with a bottom bar (+, −, refresh, "Triggers for table: <name>"), and
 * below it, read-only and monospaced, the selected trigger's function source. Editing function bodies is left to
 * the Query view. Built in code. Use on the main thread.
 *
 * The Enabled checkbox runs ALTER TABLE … ENABLE / DISABLE TRIGGER at once; if that fails an alert shows the
 * server's message and the grid shows the server's state again. + opens SPPostgresTriggerSheet; − asks, then drops.
 * Each change runs through SPPostgresTableStructure (SPPostgresRunStructureChange).
 *
 * A non-empty emptyStateText (set by the tab, e.g. for a view) hides the grid, bar and source and shows that text.
 */
__attribute__((visibility("default")))
@interface SPPostgresTriggersController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

/// The grid, its bar and the function source. Built once; sized by the caller (autoresizes).
- (NSView *)view;

/// Shows the triggers of schema.table (a nil table empties the grid). A read error is shown as an alert and in
/// the bottom bar.
- (void)showTable:(NSString *)table inSchema:(NSString *)schema;

/// Reads the triggers again (keeping the selected trigger where it is still there).
- (void)reload;

/// Detaches the grid and buttons, ends a sheet still up, and drops the presenters (called by the tab on close or
/// replace; also on dealloc).
- (void)invalidate;

- (IBAction)addTrigger:(id)sender;
/// Drops the selected trigger after confirmation (see confirmationPresenter).
- (IBAction)removeTrigger:(id)sender;
- (IBAction)refresh:(id)sender;

@property (readonly) NSTableView *triggersView;
/// The selected trigger's function source (pg_get_functiondef), read-only.
@property (readonly) NSTextView *functionSourceView;
@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *table;
/// The bottom bar's text: @"Triggers for table: <name>", the read error, or @"".
@property (readonly, copy) NSString *noticeText;
/// Shown instead of the grid when not empty (e.g. @"Triggers aren't available for views.").
@property (nonatomic, copy) NSString *emptyStateText;
/// Seconds a change waits for a lock held elsewhere before it fails (default 5), passed to the table's
/// SPPostgresTableStructure.
@property (nonatomic) NSTimeInterval lockTimeout;

/// Shows errors. nil (the default) shows them as sheets on the view's window.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm a deletion (first button: delete); call completion exactly once. nil (the default) shows a
/// sheet on the view's window.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

/// Shows the add-trigger sheet for the table's columns and the trigger functions; call completion once with the
/// definition or nil. nil (the default) shows SPPostgresTriggerSheet on the view's window.
@property (copy) void (^triggerSheetPresenter)(NSArray *columnNames, NSArray *functions, void (^completion)(SPPostgresTriggerDefinition *definitionOrNil));

@end
