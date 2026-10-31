#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/// Background thread. Return the fetched data (nil is a valid result); set *error and return nil on failure.
typedef id (^SPPostgresTaskWork)(PGPostgresConnection *connection, NSError **error);
/// Main thread. cancelled: the task was cancelled (result and error are then nil).
typedef void (^SPPostgresTaskCompletion)(id result, NSError *error, BOOL cancelled);

/**
 * Runs a tab's loads against its connection, one at a time, in the order they were asked for: each work block on one
 * dedicated serial background queue (so the connection is only ever used by one statement at a time and the window
 * stays responsive), each completion on the main queue, always from a later run loop turn.
 *
 * Cancelling interrupts the running statement (through a PGPostgresCancelToken, re-sent every second until the work
 * block returns), skips the queued tasks, and calls every pending completion with cancelled == YES, in order.
 *
 * The inline runner runs work and completion synchronously on the calling thread instead (for tests and callers that
 * need the data at once).
 *
 * Call everything on the main thread, except -updateDescription: and -isCancelled (any thread). The runner retains its
 * connection; work blocks and completions are copied.
 */
__attribute__((visibility("default")))
@interface SPPostgresTaskRunner : NSObject

- (instancetype)initWithConnection:(PGPostgresConnection *)connection;          // background runner
+ (instancetype)inlineRunnerWithConnection:(PGPostgresConnection *)connection;  // synchronous runner

@property (readonly) PGPostgresConnection *connection;
@property (readonly, getter=isInline) BOOL inlineRunner;
/// KVO-observable, main thread: YES from the first enqueue until the last queued completion has returned.
@property (readonly, getter=isBusy) BOOL busy;
/// KVO-observable, main thread: the running (else next) task's description; nil when idle.
@property (readonly, copy) NSString *currentDescription;
/// KVO-observable: the running task's Cancel button title (nil: not cancellable). Set from enqueue.
@property (readonly, copy) NSString *currentCancelTitle;

- (void)runTaskWithDescription:(NSString *)description cancelTitle:(NSString *)cancelTitle
						  work:(SPPostgresTaskWork)work completion:(SPPostgresTaskCompletion)completion;
/// Main thread, while work runs: changes currentDescription (Query's "Running query K of N...").
- (void)updateDescription:(NSString *)description; // callable from the work block's thread; applied on main
- (void)cancelAll;                                   // main thread
- (BOOL)isCancelled;                                 // work blocks may poll it (any thread)
/// YES once -invalidateWithCompletion: was called (any thread): nothing it runs or guards may use its connection.
- (BOOL)isInvalidated;
/// Cancels everything; no completion is called after this. afterIdle runs on the main thread once the worker
/// is no longer inside a work block (at once, from a later run loop turn, if idle). Idempotent.
- (void)invalidateWithCompletion:(void (^)(void))afterIdle;

@end
