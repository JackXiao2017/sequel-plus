#import <Foundation/Foundation.h>
#import "SPPostgresTaskRunner.h"

@class PGPostgresConnection;

/**
 * The loading bookkeeping a table pane (Structure, Relations, Triggers, Table Info) shares: its task runner, a load
 * generation (only the latest load's result is applied), whether the table asked for by a switch has loaded (a cancel
 * before it did leaves the pane stale), and the refusal of changes while the runner is busy. The pane supplies the
 * work, what applying a result does, and its own clear step (before a switch, or for no table). Main thread only.
 *
 * Every load is one task: description "Reloading..." and cancel title "Cancel", as MySQL's.
 */
__attribute__((visibility("default")))
@interface SPPostgresPaneLoader : NSObject

/// The runner starts as an inline runner on connection (a load has finished when the call returns).
- (instancetype)initWithConnection:(PGPostgresConnection *)connection;

@property (nonatomic, retain) SPPostgresTaskRunner *taskRunner;

/// A switch was cancelled before its table loaded: Refresh, or the tab showing the pane again, loads it.
@property (readonly, getter=isStale) BOOL stale;

/**
 * Loads through the runner. switching: this load is for a table just switched to (until a load of it completes, a
 * cancel leaves the pane stale). apply runs on the main thread with the work's result, unless the loader was
 * invalidated, a newer load (or -loadNothing) was asked for, or the load was cancelled (no alert then). A nil result
 * is a failure: error is the work's error, possibly nil (the pane then shows "An unknown error occurred.").
 */
- (void)loadSwitching:(BOOL)switching work:(SPPostgresTaskWork)work apply:(void (^)(id result, NSError *error))apply;

/// No table: a load in progress is dropped and the pane isn't stale (the pane clears itself).
- (void)loadNothing;

/// YES (after NSBeep) while the runner is busy: a change, which runs on the main thread, must not go ahead.
- (BOOL)refuseChangeWhileBusy;

/// No result is applied after this (the pane's -invalidate).
- (void)invalidate;

@end
