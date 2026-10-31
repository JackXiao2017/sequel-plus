# PostgreSQL Stage 8: background loading, tab spinner, loading display and Cancel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Postgres tab never freezes the window on a load: loads run on a background thread on the tab's own connection, the tab's spinner turns, MySQL's loading display appears with a Stop/Cancel button, and Cancel interrupts the query on the server.

**Architecture:** A per-connection `SPPostgresTaskRunner` runs queued work blocks one at a time on a background thread and calls their completions on the main thread; each controller's load splits into a *fetch* (work block: connection and data-layer objects only) and an *apply* (completion: UI). Controllers default to an *inline* runner (fetch and apply synchronously, as today), so standalone controller tests keep working; the tab hands every controller its background runner. A `SPPostgresTaskDisplay` loads MySQL's own `ProgressIndicatorLayer.xib` (same look, delays and Cancel button) and blocks input to the tab while the runner is busy; the document's existing `isProcessing` drives the tab spinner.

**Tech Stack:** Objective-C (MRC app sources, ARC tests), AppKit, PostgresKit/libpq (`PGPostgresCancelToken`), XCTest against the Docker PG12/PG18 servers.

**Spec:** `docs/superpowers/specs/2026-10-29-postgresql-mysql-parity-ui-design.md` (section "Stage 8").

## Global Constraints

- Never break or change existing MySQL features. MySQL source files are not modified in this stage, except `sequel-pro.xcodeproj/project.pbxproj` (additive, via `ruby Scripts/pg-xcodeproj.rb add-app|add-test`). `ProgressIndicatorLayer.xib` is loaded, not edited.
- One query at a time on a Postgres connection: nothing may use a tab's connection on the main thread while its runner is busy.
- Never write `~/Library/Application Support/Sequel Pro/Data/Favorites.plist` from Postgres code; tests never persist into real preferences or the login keychain.
- Short writes stay synchronous on the main thread (saving a cell, adding/deleting rows, rename, duplicate, comment, structure edits, sequence/extension changes); they refuse to start (`NSBeep()`, return) while the runner is busy.
- A cancelled load never shows an error alert.
- MRC in `Source/Postgres` (`__block` for self captures that must not retain; blocks copied when stored); ARC in `PostgresTests`. Exported classes carry `__attribute__((visibility("default")))`.
- Implementer agents never launch the GUI app and never kill processes they didn't start; never touch the owner's untracked `start_clause.sh`.
- Tests: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64`; servers via `bash Scripts/pg-test-servers.sh up`. Single class: append `-only-testing:"Postgres Tests"/<Class>`.
- App build: `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## MySQL behaviour to copy (from `Source/SPDatabaseDocument.m`, `SPTableContent.m`, `SPCustomQuery.m`)

- Display: `ProgressIndicatorLayer.xib` in a borderless, clear, non-opaque child window of the tab's window, alpha 0, centered on the window; shown only for the active tab (removed in `willResignActiveTabInWindow`, re-added in `didBecomeActiveTabInWindow`). Indicator fore colour white with shadow (offset 1,−1, blur 1, black 0.75). Hidden for the first 0.5 s, then faded in over 0.6 s (30 fps timer). The duration label shows elapsed `HH:MM:SS` (`NSDateComponentsFormatter`, hours/minutes/seconds, pad), updated every second, bold 13 pt with shadow (MySQL lines 1380–1404). At the end: alpha 0, timers stopped.
- Cancel button: hidden at task start; shown with a title when the task is cancellable. Titles: content row loads `Stop` (`NSLocalizedString(@"Stop", @"stop button")`); query runs `Stop query` / `Stop queries` (more than one statement); every other load `Cancel` (`@"cancel button"`). Clicking disables it, then cancels.
- Descriptions (MySQL's strings and comments): `Loading %@...` (`@"Loading table task string"`, table name) for a table's first load; `Reloading data...` (`@"Reloading data task description"`) for a reload; `Filtering table...` (`@"Filtering table task description"`); `Loading page %lu...` (`@"Loading table page task string"`); `Sorting table...` (`@"Sorting table task description"`); `Running query...` (`@"Running single query string"`) / `Running query %ld of %lu...` (`@"Running multiple queries string"`, updated per statement); `Reloading...` (`@"Reloading table task string"`) for Structure, Relations, Triggers, Table Info, Sequence, Extension panes and the table list; `Loading database '%@'...` is not used (database switches keep their Stage 2 flow).
- Query cancelled status: `Query cancelled.` (`@"Query cancelled error"`).

## Rulings in this plan (owner can overturn)

- **Cancel while switching to another table** shows the new table's columns with no rows (Content) or an empty pane (others), marks the pane stale so Refresh or the next show loads it, and shows no alert. Cancel during a reload, page, filter or sort keeps what was shown (rows, filter, sort, page). The spec's "leaves the view as it was" can't hold for a switch: the sidebar selection already moved. Cost if wrong: one Refresh click.
- **"Dims the content area"** in the spec is MySQL's dark HUD; no extra dimming layer (MySQL has none). Cost if wrong: cosmetic.
- **Cancel cancels everything queued**, not just the running task (one user action can queue several loads, e.g. Content and Structure on a table switch).

## Review Focus

1. Closing the tab while a load runs: no crash, no main-thread wait, the connection is closed only after the worker thread has left libpq, and no completion touches the torn-down tab. (Task 6 test `testCloseTabDuringLoadClosesConnectionAfterWorker`.)
2. A server error in a background load still shows the same alert as today, on the main thread, and the tab ends its task (spinner stops). (Task 3 test `testBackgroundLoadErrorShowsAlertAndEndsTask`.)
3. Chained flows that were synchronous (database switch → sidebar reload → history entry applied; Query DDL → sidebar reload keeping selection) end in the same state as before. (Task 5 tests `testDatabaseSwitchAppliesHistoryAfterListLoads`, `testQueryDDLReloadsListKeepingSelection`.)
4. A Cancel arriving after the work finished but before its completion ran: the result is dropped, the view stays as before, no alert. (Task 1 test `testCancelAfterWorkFinishedDropsResult`.)
5. A short write attempted while busy (e.g. ⌫ in the grid via a key equivalent, ⌘R in the editor) does nothing and never touches the connection. (Task 3 `testRemoveRowsRefusedWhileBusy`, Task 4 `testRunRefusedWhileBusy`.)

---

### Task 1: `SPPostgresTaskRunner`

**Files:**
- Create: `Source/Postgres/SPPostgresTaskRunner.h`, `Source/Postgres/SPPostgresTaskRunner.m`
- Create: `PostgresTests/SPPostgresTaskRunnerTests.m`
- Modify: `PostgresTests/SPPostgresTestServers.h/.m` (wait helper)
- Modify: `sequel-pro.xcodeproj/project.pbxproj` (via `Scripts/pg-xcodeproj.rb`)

**Interfaces:**
- Produces:
```objc
/// Background thread. Return the fetched data (nil is a valid result); set *error and return nil on failure.
typedef id (^SPPostgresTaskWork)(PGPostgresConnection *connection, NSError **error);
/// Main thread. cancelled: the task was cancelled (result and error are then nil).
typedef void (^SPPostgresTaskCompletion)(id result, NSError *error, BOOL cancelled);

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
/// Cancels everything; no completion is called after this. afterIdle runs on the main thread once the worker
/// is no longer inside a work block (at once, from a later run loop turn, if idle). Idempotent.
- (void)invalidateWithCompletion:(void (^)(void))afterIdle;
@end
```
- `SPPostgresTestServers`: `+ (BOOL)waitForRunner:(SPPostgresTaskRunner *)runner timeout:(NSTimeInterval)timeout;` spins the main run loop until `!isBusy`; YES if idle in time.

Semantics the tests pin:
- FIFO, one at a time, on one dedicated serial background queue per runner; completions on the main queue, each from a later run loop turn, in enqueue order.
- Cancel: the running task's statement is interrupted through a `PGPostgresCancelToken` the worker takes from the connection before each work block (invalidated after it); the request is re-sent every second until the work block returns (as `SPPostgresBackgroundJob -cancel`). Queued tasks never run. Every pending completion is then called with `cancelled == YES` (in order), including a task whose work had already returned.
- Inline runner: `runTask…` calls work then completion synchronously before returning; `busy` is YES during the call; `cancelAll` does nothing; `isCancelled` NO.
- After `invalidateWithCompletion:`, `runTask…` drops the task without calling anything.

- [ ] **Step 1: Write the failing tests** in `SPPostgresTaskRunnerTests` (ARC; a connection to PG18 from `SPPostgresTestServers`):
  - `testRunsWorkOffMainAndCompletionOnMain` — work asserts `![NSThread isMainThread]`, returns `@42`; completion asserts main thread, `result == @42`, `cancelled == NO`.
  - `testTasksRunInOrderOneAtATime` — three tasks append to an array (work) with `SELECT pg_sleep(0.1)`; completions' order is 1,2,3; no overlap (an atomic counter never exceeds 1).
  - `testBusyIsKVOObservable` — observe `busy`: YES after first enqueue, NO only after the last completion returned.
  - `testErrorIsPassedToCompletion` — work runs `SELECT 1/0` and returns the error; completion gets it, `cancelled == NO`.
  - `testCancelInterruptsRunningStatement` — work runs `SELECT pg_sleep(30)`; `cancelAll` after 0.3 s; completion `cancelled == YES` within 5 s; the connection then runs `SELECT 1` fine.
  - `testCancelSkipsQueuedTasks` — second task's work never runs; both completions `cancelled == YES`, in order.
  - `testCancelAfterWorkFinishedDropsResult` — `cancelAll` called from inside a block dispatched to main *after* work returned but before its completion runs (use a semaphore signalled at the end of work, then `cancelAll` on main before spinning); completion `cancelled == YES`, result nil.
  - `testInvalidateCallsNoCompletionAndAfterIdleAfterWorker` — running `pg_sleep(30)`; `invalidateWithCompletion:` → completion never called; `afterIdle` called once on main after the work returned (assert a flag set at the end of work is YES when it runs).
  - `testInlineRunnerIsSynchronous` — work and completion both ran before `runTask…` returned, both on main.
  - `testUpdateDescriptionFromWorkReachesMain` — `currentDescription` observed on main changes to the updated text.
- [ ] **Step 2: Run** `-only-testing:"Postgres Tests"/SPPostgresTaskRunnerTests` → FAIL (class missing).
- [ ] **Step 3: Implement** `SPPostgresTaskRunner` (serial `dispatch_queue_t`, a main-thread pending array of task records, a generation counter so a cancel drops results of tasks that already returned; cancel token handling as described).
- [ ] **Step 4: Run** the class → PASS; run the full suite → no regressions.
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 1: SPPostgresTaskRunner`.

### Task 2: `SPPostgresTaskDisplay` and the tab's busy state

**Files:**
- Create: `Source/Postgres/SPPostgresTaskDisplay.h`, `Source/Postgres/SPPostgresTaskDisplay.m`
- Modify: `Source/Postgres/SPPostgresDocument.m` (own a runner per connection; display; `isProcessing`; teardown and database-switch ordering)
- Create: `PostgresTests/SPPostgresTaskDisplayTests.m`; Modify: `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- Consumes: Task 1.
- Produces:
```objc
@interface SPPostgresTaskDisplay : NSObject
- (instancetype)initWithRunner:(SPPostgresTaskRunner *)runner;  // observes busy/currentDescription/currentCancelTitle
@property (assign) NSWindow *parentWindow;   // nil: nothing shown; set/cleared on tab activate/resign
@property (assign) NSView *blockedView;      // the tab's view; input to it is blocked while busy
@property (readonly) NSWindow *progressWindow;   // the child window (tests)
@property (readonly) NSButton *cancelButton;     // the xib's Cancel button (tests)
@property (readonly) NSTextField *descriptionField; // the xib's description text (tests)
- (IBAction)cancelTask:(id)sender;  // the xib's action: disables the button, [runner cancelAll]
- (void)invalidate;                 // stops observing, timers, removes the child window and blocker
@end
// SPPostgresDocument (public, for tests and later stages):
@property (readonly) SPPostgresTaskRunner *taskRunner;
```
- The display loads `ProgressIndicatorLayer` with itself as the nib owner: it declares the outlets the xib connects (`taskProgressLayer` (NSBox), `taskProgressIndicator` (YRKSpinningProgressIndicator), `taskDescriptionText`, `taskCancelButton`, `taskDurationTime`) and the `cancelTask:` action. Look, timings and labels exactly as "MySQL behaviour to copy".
- Input blocking: while busy, a transparent view added on top of `blockedView` returns itself from `hitTest:` and swallows mouse, right/other mouse, scroll and key events; the window's first responder (if inside `blockedView`) moves to it and is restored afterwards if it still is in the window. Removed when idle.
- Document: `isProcessing` = runner busy OR a database switch connecting (the existing `pendingConnector` path). Existing `isProcessing` users (toolbar validation, history control, sheets refusing to open) then also hold during loads. The document creates a runner in `_attachCurrentConnection` for each new connection; on a database switch the old runner is invalidated and `[oldConnector disconnect]` runs from its `afterIdle`. `_tearDown`: `[taskDisplay invalidate]`, then `[taskRunner invalidateWithCompletion:^{ [connector disconnect]; }]` replaces the direct `[connector disconnect]` (the block keeps the connector alive).

- [ ] **Step 1: Write the failing tests.** `SPPostgresTaskDisplayTests` (a real borderless test window, background runner on PG18):
  - `testHiddenForHalfASecondThenFadesIn` — task `pg_sleep(2)`: progress window alpha 0 at 0.3 s, > 0 at 0.8 s, 1 by 1.3 s; child of the parent window; description field shows the task description.
  - `testCancelButtonShowsTitleAndCancels` — cancelTitle `Stop`: button visible with title "Stop"; `performClick:` → button disabled, task completion `cancelled == YES`; after the task, alpha 0.
  - `testNoCancelTitleHidesButton` — cancelTitle nil → button hidden.
  - `testInputBlockedWhileBusy` — while busy, `[window.contentView hitTest:]` on a point inside `blockedView` returns the blocker; after idle it returns the original subview.
  - `testNoParentWindowShowsNothing` — parentWindow nil: no child window added; busy still blocks input once parentWindow is set mid-task.
  - `SPPostgresDocumentTests`: `testIsProcessingFollowsRunner` (enqueue a `pg_sleep(0.3)` task on `taskRunner`: `isProcessing` YES, then NO), `testCloseTabDuringLoadClosesConnectionAfterWorker` (task `pg_sleep(30)`; tear the tab down (as existing teardown tests do); returns at once (< 0.5 s); the connection's server backend is gone within 5 s, checked from a second connection in `pg_stat_activity` by the backend pid; no completion ran).
- [ ] **Step 2: Run** both classes → FAIL.
- [ ] **Step 3: Implement** the display and the document changes.
- [ ] **Step 4: Run** both classes → PASS; full suite → no regressions.
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 2: task display, busy tab, teardown after the worker`.

### The conversion pattern (Tasks 3–7)

Each controller gets `@property (retain) SPPostgresTaskRunner *taskRunner;` (default: `+inlineRunnerWithConnection:` made in `-init…`); the document sets its runner right after creating the controller. A load becomes:

1. Main thread: validate, note what is being loaded (a per-controller *load generation* integer, incremented per load; also on `invalidate`).
2. `runTaskWithDescription:cancelTitle:work:completion:` — the work block captures only immutable copies (names, filter, sort, page) and data-layer objects (`SPPostgresTableData`, `SPPostgresCatalog`, `SPPostgresTableStructure`, …), never `self`'s UI or mutable ivars; it returns a dictionary or object with everything fetched.
3. Completion (main): drop it if the controller was invalidated or the generation moved on; on `cancelled` follow the ruling (no alert); on error present the same alert as today; on success apply exactly what the synchronous code applies today.

Public load methods keep their names and documented end states; with the inline runner those end states hold when the method returns, with a background runner when the runner is idle. Methods whose callers need to act after the load gain a `completion:` variant (named per task) and the old name calls it with nil. Short writes stay synchronous and start with `if ([taskRunner isBusy]) { NSBeep(); return; }`. Existing controller tests stay as they are (inline runner). Existing `SPPostgresDocumentTests` use the tab's background runner: from Task 3 on, a test that asserts right after an action that now loads in the background waits with `waitForRunner:` first — only the waiting is added, expected values never change. Each task adds tests with a background runner and `+[SPPostgresTestServers waitForRunner:timeout:]`.

### Task 3: Content in the background

**Files:** Modify `Source/Postgres/SPPostgresContentController.h/.m`, `Source/Postgres/SPPostgresDocument.m` (`_installContentController` sets the runner); Test `PostgresTests/SPPostgresContentControllerTests.m`.

**Interfaces:** Consumes Tasks 1–2. Produces `-[SPPostgresContentController setTaskRunner:]`; `showTable:inSchema:` and `reload` unchanged in name.

- Work for a table switch: `columns:`, `isEditable`, `readOnlyReason`, then the first page (`countRowsWithFilter:` ×1–2, `rowsWithFilter:…`). For reload/page/filter/sort: the counts and rows only. `SPPostgresTableData` is created on main and used only by the worker while the task runs.
- Descriptions/cancel title: see "MySQL behaviour to copy" (`Loading %@...` on switch, `Reloading data...` on Refresh and reload, `Filtering table...`, `Loading page %lu...`, `Sorting table...`; cancel title `Stop`).
- On a table switch the bottom bar's count text shows MySQL's `Loading table data...` (`@"Loading table data string"`) until the completion.

- [ ] **Step 1: Write the failing tests** (background runner):
  - `testShowTableLoadsInBackground` — `showTable:` returns with `isBusy` YES; after waiting, rows/count text equal what the inline path gives for the same fixture table.
  - `testCancelDuringTableSwitchShowsColumnsWithoutRowsNoAlert` — setUp creates the view `sp_t8_slow AS SELECT g, pg_sleep(0.05) AS s FROM generate_series(1,200) g` (dropped in tearDown); `showTable:@"sp_t8_slow"`, `cancelAll` at 0.3 s → its columns are shown, 0 rows, the alert presenter was never called, Refresh enabled.
  - `testCancelDuringReloadKeepsRows` — with Limit results on at 10 (scratch defaults), load `sp_t8_slow` and wait; then `nextPage:` and `cancelAll` at 0.3 s → page 1, the same 10 rows and count text as before.
  - `testBackgroundLoadErrorShowsAlertAndEndsTask` — drop the table from a second connection after `showTable:` of it was queued behind a `pg_sleep(0.5)` task → one alert with today's title, runner idle afterwards.
  - `testRemoveRowsRefusedWhileBusy` — while a `pg_sleep(1)` task is queued, `removeRows:` doesn't call the confirmation presenter and the row count is unchanged.
- [ ] **Step 2: Run** class → new tests FAIL, old tests PASS.
- [ ] **Step 3: Implement** the split per the pattern; guard `addRow:`, `removeRows:`, the cell edit path.
- [ ] **Step 4: Run** class → PASS; full suite → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 3: Content loads in the background`.

### Task 4: Query runs in the background

**Files:** Modify `Source/Postgres/SPPostgresQueryController.h/.m`, `Source/Postgres/SPPostgresDocument.m`; Test `PostgresTests/SPPostgresQueryControllerTests.m`.

- The whole statement loop (today's `_runStatements:` body up to `@finally`) runs in one work block; it collects per statement what the main thread needs (the last row-returning `PGPostgresResult`, status text, schema/data-changed flags) and calls `updateDescription:` with `Running query %ld of %lu...` before each statement (single statement: `Running query...`). `statementWillRunHook` is now called on the worker thread (document it in the header). `setLoggingCustomQueries:YES` is set on main before enqueue and restored in the completion (also on cancel).
- Cancel title `Stop query` / `Stop queries`. On cancel the status line is `Query cancelled.`; the grid shows the last row set returned before the cancel (as it does on an error); `runDidChangeDatabase` still fires for statements that succeeded before the cancel.
- `running` stays YES until the completion; ⌘R / ⌥⌘R / the buttons do nothing while the runner is busy.

- [ ] **Step 1: Write the failing tests** (background runner): `testRunAllInBackgroundShowsLastResult` (`SELECT 1; SELECT 2 AS b` → grid column `b`, status as today), `testCancelLongStatementShowsQueryCancelled` (`SELECT pg_sleep(30)`, cancel at 0.3 s → status `Query cancelled.` within 5 s, no alert), `testStatementsBeforeCancelStillReportChanges` (`CREATE TABLE sp_t8_x(a int); SELECT pg_sleep(30)` cancelled → `runDidChangeDatabase(YES, …)` called once; drop the table in tearDown), `testDescriptionCountsStatements` (observe `currentDescription` sees `Running query 2 of 2...`), `testRunRefusedWhileBusy` (runner busy with `pg_sleep(1)`: `runAllQueries:` doesn't queue a second task — status unchanged after both finish).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** class and full suite → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 4: Query runs in the background with Stop`.

### Task 5: The table list (sidebar) in the background

**Files:** Modify `Source/Postgres/SPPostgresSidebarController.h/.m`, `Source/Postgres/SPPostgresDocument.m`; Test the sidebar's existing test class (or `SPPostgresDocumentTests` where the sidebar is tested through the tab).

**Interfaces:** Produces completion variants the document chains on:
```objc
- (void)reloadSchema:(NSString *)schema selectingSequence:(NSString *)sequence completion:(void (^)(BOOL loaded))completion;
- (void)reloadWithCatalog:(SPPostgresCatalog *)catalog completion:(void (^)(BOOL loaded))completion;
- (void)reloadKeepingSelection:(void (^)(BOOL loaded))completion;
```
`loaded` NO on error or cancel (lists unchanged, as today's failure). Existing methods call these with nil. The sidebar takes the runner via `setTaskRunner:`; the schema popup and outline selection changes made by the user start the reload (description `Reloading...`, cancel title `Cancel`).

- Document call sites that act on the list after a reload move into the completion: `_databaseSwitchBy…` (install controllers and `_applyHistoryEntry:` after `reloadWithCatalog:` completes), `_applyHistoryEntry:` (select the table after `reloadSchema:` completes), rename/duplicate/sequence create/drop (select the new item after the reload), `_queryRunChangedSchema:data:` and `_reloadSidebarKeepingSelection`.

- [ ] **Step 1: Write the failing tests** (document with its background runner): `testDatabaseSwitchAppliesHistoryAfterListLoads` (switch database through history back/forward as the existing history tests do → after waiting, the recorded schema and table are selected), `testQueryDDLReloadsListKeepingSelection` (select table A; run `CREATE TABLE sp_t8_new(a int)` in Query; after waiting, `sp_t8_new` is listed and A is still selected), `testCancelSchemaSwitchKeepsList` (enqueue a `pg_sleep(1)` task, then choose another schema in the popup, `cancelAll` → list and popup unchanged, no alert), `testRenameSelectsRenamedTableAfterReload`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** class and full suite → PASS (existing document tests that assert right after a reload now wait with `waitForRunner:`; change only the waiting, never the expected values).
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 5: table list loads in the background`.

### Task 6: Structure, Relations, Triggers and Table Info in the background

**Files:** Modify `Source/Postgres/SPPostgresStructureController.m`, `SPPostgresRelationsController.m`, `SPPostgresTriggersController.m`, `SPPostgresTableInfoController.m` (+ headers for `taskRunner`), `Source/Postgres/SPPostgresDocument.m`; Tests in each controller's test class.

- `showTable:inSchema:` and `reload` per the pattern; description `Reloading...`, cancel title `Cancel`. Their writes (column/index/constraint/relation/trigger edits, comment save) stay synchronous and are refused while busy.
- The stale-flag logic in the document (`structureNeedsReset`, `_refresh…IfStale`) is unchanged; a cancelled switch sets the pane's flag back to stale (ruling).

- [ ] **Step 1: Write the failing tests**, one per controller (background runner): `testShowTableLoadsInBackground` (same fields as the inline path after waiting) and `testCancelledSwitchShowsEmptyPaneNoAlert` (enqueue a `pg_sleep(1)` task first, then `showTable:`, `cancelAll` → pane empty, no alert); plus `SPPostgresDocumentTests testCancelledPaneReloadsWhenShownAgain`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** classes and full suite → PASS.
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 6: Structure, Relations, Triggers and Table Info load in the background`.

### Task 7: Sequence and Extension panes in the background

**Files:** Modify `Source/Postgres/SPPostgresSequenceController.m`, `SPPostgresExtensionController.m` (+ headers), `Source/Postgres/SPPostgresDocument.m`; Tests in their classes.

- `showSequence:inSchema:` / `showExtension:` and `reload` per the pattern; description `Reloading...`, cancel title `Cancel`; Apply/Set Value/Update/Drop stay synchronous and are refused while busy.
- After this task no Postgres tab code path runs a read on the tab's connection on the main thread outside the inline runner, except: `_attachCurrentConnection`'s `SELECT current_database()` / server version (connect time, before the tab is shown), the short writes, and the Import/Export/Transfer/Users sheets (own connections or own progress sheets). The implementer lists every remaining main-thread `execute:` / catalog call in `Source/Postgres` in the report, each with which of these exceptions it is.

- [ ] **Step 1: Write the failing tests** (background runner) as Task 6 for both controllers.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** classes and full suite → PASS; app build succeeds.
- [ ] **Step 5: Commit** `Postgres Stage 8 Task 7: Sequence and Extension panes load in the background`.
