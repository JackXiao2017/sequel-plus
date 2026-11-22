# PostgreSQL Keep-alive and Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PostgreSQL tab's idle connection stays up (TCP keep-alives from the Keep connection alive preference), and
after a drop the next task reconnects the same connection object by itself, or asks Reconnect / Disconnect as MySQL.

**Architecture:** PostgresKit gains keep-alive idle/count parameters, a ping with a deadline and a synchronous
in-place reconnect. SPPostgresTaskRunner checks the connection before a task after 30 s unused, and on failure asks
its connection delegate (the document, main thread) to prepare (reopen the SSH tunnel), reconnects on its worker,
and if that fails asks the delegate whether to retry. The document shows MySQL's choice as a sheet.

**Tech Stack:** Objective-C (MRC in Source/ and PostgresKit; ARC in PostgresTests), libpq, XCTest against the docker
test servers (`Scripts/pg-test-servers.sh up`; PostgreSQL 18 on 55418).

**Spec:** `docs/superpowers/specs/2026-11-21-postgres-keepalive-reconnect-design.md`

## Global Constraints
- Keep-alive values come from the shared MySQL preferences `SPUseKeepAlive` and `SPKeepAliveInterval` (60 s when unset or 0).
- `keepalives_idle` = `keepalives_interval` = that interval; `keepalives_count` = 3.
- Check before use after 30 s unused; the check gives up after 10 s.
- One silent reconnect; never silent when the lost session had a transaction open (in transaction or in error).
- A statement that failed part way is never re-run.
- Never block the main thread while checking or reconnecting.
- Sheet: title "The connection to the PostgreSQL server was lost", buttons "Reconnect" and "Disconnect"; Disconnect closes the tab.
- Tests never write real preferences (pin through the volatile argument domain); new test files are registered with `ruby Scripts/pg-xcodeproj.rb add-test`; classes tests use need `__attribute__((visibility("default")))`.
- No commits until the user says so (ignore the plan's commit steps; leave changes in the working tree).

## Review Focus
1. SSH favorite whose tunnel died (sleep, network change): the tunnel is reopened, possibly on a new local port, and the connection follows it. Not testable without SSH credentials in tests: check by reading `-reopenTunnelIfNeededOnWindow:completion:` closely.
2. A tab closed (runner invalidated) while the worker waits for the delegate or the sheet: the worker stops waiting, nothing is called after invalidation, no crash. Task 3 test `testInvalidateWhileWaitingForDecision`.
3. Two tasks queued when the drop is found: one reconnect, both run on the new session. Task 3 test `testQueuedTasksShareOneReconnect`.
4. Transaction open at the drop: sheet first, no silent attempt. Task 3 test `testOpenTransactionAsksFirst`.
5. Queries the document runs directly on the main thread (not through the runner) after a drop: they fail with today's error and mark nothing; the next runner task checks and reconnects. Task 3 test `testBrokenConnectionIsCheckedEvenWhenRecentlyUsed`.

---

### Task 1: PostgresKit keep-alive parameters, ping with deadline, in-place reconnect

**Files:**
- Modify: `Frameworks/PostgresKit/Source/PGConstants.h`, `PGConstants.m` (params `keepalives_idle`, `keepalives_count`; `PGPostgresConnectionKeepAliveCount = 3`)
- Modify: `Frameworks/PostgresKit/Source/PGPostgresConnection.h`, `.m` (`-_createConnectionParameters`, new methods)
- Create: `PostgresTests/SPTestTCPRelay.h`, `.m` (a local TCP relay that can freeze: stop relaying without closing)
- Test: `PostgresTests/SPPostgresReconnectTests.m`

**Interfaces:**
- Produces:
  - `- (BOOL)pingWithTimeout:(NSTimeInterval)timeout;` — on the thread that uses the connection. Sends an empty query and waits for its answer up to `timeout`; YES if the server answered. NO when not connected, on any error or on timeout; after NO the session is unusable until `-reestablishConnection`.
  - `- (BOOL)reestablishConnection;` — on the thread that uses the connection, synchronous. Closes the libpq session (no delegate callbacks), opens a new one with the current parameters (host and port may have been changed since), honouring the connect timeout, then sets error verbosity and the notice processor, applies the session settings and loads the database parameters, as `-_pollConnection:` does. Returns `-isConnected`; on NO, `-connectionError` says why.
  - `SPTestTCPRelay`: `- (instancetype)initForwardingToPort:(NSUInteger)port;` `@property (readonly) NSUInteger localPort;` `- (void)freeze;` (keeps the sockets open, relays nothing more) `- (void)stop;`

- [ ] **Step 1: Write the failing tests** in `SPPostgresReconnectTests` (port 55418, `SPPostgresTestServers connectedConnectionOnPort:`):
  - `testKeepAliveParametersReachLibpq`: connection with `keepAliveInterval = 45`; `PQconninfo([c postgresConnection])` has `keepalives` "1", `keepalives_idle` "45", `keepalives_interval` "45", `keepalives_count` "3".
  - `testPingAnswersOnAHealthyConnection`: `XCTAssertTrue([c pingWithTimeout:5])`, then a normal `SELECT 1` still works.
  - `testPingFailsFastWhenTheBackendIsGone`: another connection runs `SELECT pg_terminate_backend(<c's serverProcessId>)`; `pingWithTimeout:5` returns NO in under 2 s.
  - `testPingGivesUpAtTheDeadlineWhenTheNetworkIsSilent`: c connects through `SPTestTCPRelay` (host 127.0.0.1, relay port, sslmode disable or prefer); `[relay freeze]`; `pingWithTimeout:1` returns NO in 0.9–3 s.
  - `testReestablishGivesANewSessionWithTheSessionSettings`: `SET datestyle TO 'SQL'` on c, terminate its backend, ping NO, `XCTAssertTrue([c reestablishConnection])`, `serverProcessId` changed, `SHOW datestyle` begins with "ISO", `SELECT 1` works.
  - `testReestablishFailsWithAReasonWhenTheServerIsUnreachable`: c through a relay, terminate, `[relay stop]`, `reestablishConnection` NO, `connectionError` non-empty, `isConnected` NO.
- [ ] **Step 2: Register the new files, run, see them fail** (`pingWithTimeout:` / `reestablishConnection` unknown).
  Run: `xcodebuild -project sequel-plus.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData test -only-testing:"Postgres Tests/SPPostgresReconnectTests"`
- [ ] **Step 3: Implement.** Two more fixed parameter slots after `keepalives_interval` (`keepalives_idle` = interval, `keepalives_count` = 3; grow `paramCount` and the fixed index accordingly). Ping: `PQsendQuery(conn, "")`, then loop `poll(PQsocket, POLLIN, remaining ms)` / `PQconsumeInput` / `PQisBusy` until the deadline; drain `PQgetResult` to NULL; success only for `PGRES_EMPTY_QUERY` and `PQstatus == CONNECTION_OK`. Reestablish: `PQfinish` the old session, `-_createConnectionParameters`, `PQconnectdbParams`.
- [ ] **Step 4: Run, all pass;** also run `SPPostgresConnectorTests` (connection parameters changed).

### Task 2: Connector keep-alive preferences and tunnel reopening

**Files:**
- Modify: `Source/Postgres/SPPostgresConnector.h`, `.m`
- Test: `PostgresTests/SPPostgresConnectorTests.m`

**Interfaces:**
- Consumes: Task 1's keep-alive parameters.
- Produces: `- (void)reopenTunnelIfNeededOnWindow:(NSWindow *)window completion:(void (^)(NSError *error))completion;` — main thread; completion on the main thread from a later run loop turn. Not an SSH favorite, or its tunnel still connected: nil. Shares another connector's tunnel that isn't connected: `SPPostgresErrorSSHTunnelFailed`. Its own tunnel down: closes it, opens a new one exactly as the first connect did (password, keychain, key file; sheets on `window`), and once connected sets the connection's host to 127.0.0.1 and port to the new tunnel's local port, then completes nil; a failed or cancelled tunnel completes with `SPPostgresErrorSSHTunnelFailed` / `SPPostgresErrorCancelled`.

- [ ] **Step 1: Failing tests:**
  - `testKeepAliveFollowsThePreferences`: with the argument domain pinned to `SPUseKeepAlive` YES and `SPKeepAliveInterval` 25, a connected connector's connection has `useKeepAlive` YES and `keepAliveInterval` 25; with 0 it is 60; with `SPUseKeepAlive` NO, `useKeepAlive` NO.
  - `testReopenTunnelIsANoOpWithoutSSH`: a connected TCP connector's reopen completes once, on the main thread, after the call returned, with nil, and the connection's port is unchanged.
  - `testReopenSharedTunnelThatIsDownFails`: the shape of `testSharingConnectorForSSHFavoriteWithoutTunnelFails` (a sharing connector whose owner has no tunnel) completes with `SPPostgresErrorSSHTunnelFailed`.
- [ ] **Step 2: Run, see them fail.** `-only-testing:"Postgres Tests/SPPostgresConnectorTests"`
- [ ] **Step 3: Implement** (keep-alive from `NSUserDefaults standardUserDefaults` in `-_startPostgresWithHost:port:useSocket:`; the reopen keeps its own completion, separate from the connect completion and its `finished` flag).
- [ ] **Step 4: Run, all pass.**

### Task 3: Task runner checks before use and drives the reconnect

**Files:**
- Modify: `Source/Postgres/SPPostgresTaskRunner.h`, `.m`
- Test: `PostgresTests/SPPostgresTaskRunnerTests.m`

**Interfaces:**
- Consumes: Task 1's `-pingWithTimeout:`, `-reestablishConnection`, `-transactionStatus`, `-connectionError`, `-libpqErrorMessage`.
- Produces:
  ```objc
  @protocol SPPostgresTaskRunnerConnectionDelegate <NSObject>
  // All on the main thread; each completion/decision is called exactly once, from any later turn.
  - (void)taskRunner:(SPPostgresTaskRunner *)runner prepareReconnectWithCompletion:(void (^)(NSError *error))completion;
  - (void)taskRunner:(SPPostgresTaskRunner *)runner connectionLost:(NSString *)reason transactionLost:(BOOL)transactionLost
            decision:(void (^)(BOOL reconnect))decision;
  - (void)taskRunnerDidReconnect:(SPPostgresTaskRunner *)runner;
  @end
  @property (assign) id<SPPostgresTaskRunnerConnectionDelegate> connectionDelegate; // nil: no checks (as today)
  @property (assign) NSTimeInterval idleCheckInterval; // 30
  @property (assign) NSTimeInterval pingTimeout;       // 10
  ```
  Worker, before a task's work (background runner only, delegate set, task not cancelled): if the time since the last
  task's work ended is ≥ `idleCheckInterval`, or the connection was found not connected after the last work, ping.
  If the ping fails: unless the last work left a transaction open (in transaction / in error), prepare (wait for the
  delegate's completion) and, if it gave nil, `reestablishConnection`; on success call `taskRunnerDidReconnect:` (main)
  and run the work. Otherwise ask `connectionLost:transactionLost:decision:` with the reason (the connection's error);
  YES repeats prepare + reestablish (asking again on failure); NO skips the work: its completion, and every queued
  task's, gets `cancelled == YES`. Waiting for the main thread checks `invalidated` every 0.1 s and gives up when set
  (the work is skipped). After each work: record the time, whether the connection is connected and its transaction
  status.

- [ ] **Step 1: Failing tests** (real connection on 55418; a fake delegate records calls and answers from blocks; `idleCheckInterval = 0` unless stated; drops made with `pg_terminate_backend` from another connection between tasks):
  - `testNoCheckWithoutDelegate`: drop, run a task: its work runs and fails (today's behaviour), no delegate calls.
  - `testDroppedConnectionReconnectsSilentlyAndRunsTheTask`: drop; the task's `SELECT 1` succeeds; delegate saw prepare once and didReconnect once, no connectionLost; `serverProcessId` changed.
  - `testHealthyConnectionIsNotReconnected`: no drop; no delegate calls; same `serverProcessId`.
  - `testRecentlyUsedConnectionIsNotPinged`: `idleCheckInterval = 30`, drop, task fails as today (no delegate calls).
  - `testBrokenConnectionIsCheckedEvenWhenRecentlyUsed`: `idleCheckInterval = 30`; drop; first task fails; second task reconnects and succeeds.
  - `testFailedReconnectAsksAndRetries`: prepare answers an error the first time, nil the second; connectionLost called once with a non-empty reason and `transactionLost` NO; decision YES; task succeeds.
  - `testDisconnectDecisionCancelsTheQueuedTasks`: prepare answers an error; decision NO; two queued tasks both complete with `cancelled` YES, their work never ran.
  - `testOpenTransactionAsksFirst`: a task runs `BEGIN`; drop; next task: connectionLost called with `transactionLost` YES before any prepare; decision YES; task succeeds.
  - `testQueuedTasksShareOneReconnect`: drop, queue two tasks; prepare and didReconnect each once; both succeed with the same `serverProcessId`.
  - `testInvalidateWhileWaitingForDecision`: decision never answered; invalidate; afterIdle runs; no completion called.
- [ ] **Step 2: Run, see them fail.** `-only-testing:"Postgres Tests/SPPostgresTaskRunnerTests"`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the runner tests, then `SPPostgresContentBarTests` and `SPPostgresDocumentTests` (callers unchanged).**

### Task 4: The document reconnects its tab (tunnel, sheet, console, close)

**Files:**
- Modify: `Source/Postgres/SPPostgresDocument.h`, `.m`; `Source/Postgres/SPPostgresConsoleLogger.h`, `.m`
- Test: `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- Consumes: Task 2's `-reopenTunnelIfNeededOnWindow:completion:`; Task 3's protocol and properties.
- Produces:
  - The document is the `connectionDelegate` of every task runner it creates (also a database switch's), cleared in `-_tearDown`.
  - `@property (copy) void (^connectionLostPresenter)(NSAlert *alert, void (^completion)(BOOL reconnect));` — test hook; without it the alert is a sheet on the tab's window (held while the tab isn't shown, as `-_presentAlert:`).
  - Alert: message "The connection to the PostgreSQL server was lost"; informative text = the reason, then (transaction lost) "The open transaction was rolled back: its changes were not saved."; buttons "Reconnect" (first), "Disconnect". Disconnect closes this tab as File ▸ Close Tab does for it.
  - `SPPostgresConsoleLogger -logNote:(NSString *)note` — shown as the logger shows queries, when console logging is on; the document logs "Reconnected to the server" after `taskRunnerDidReconnect:`.
  - `-_reportCatalogError:`'s lost-connection advice becomes "The lists show what was loaded before the connection was lost. Sequel Plus reconnects when you next use this tab."

- [ ] **Step 1: Failing tests** (an opened document on 55418, as the existing document tests open one; `taskRunner.idleCheckInterval = 0`):
  - `testDocumentIsTheRunnersConnectionDelegate`.
  - `testDroppedConnectionReconnectsOnNextLoad`: drop; reload the sidebar (or show a table's content); it loads; no alert; the Console logger got the note.
  - `testLostSheetReconnect`: make prepare fail once (a document test hook or a TCP favorite on a stopped relay, then restart it), the presenter sees the alert's message and buttons; answering YES reconnects and the load completes.
  - `testLostSheetDisconnectClosesTheTab`: answering NO closes the tab (the document is torn down, its window controller no longer has the tab).
- [ ] **Step 2: Run, see them fail.** `-only-testing:"Postgres Tests/SPPostgresDocumentTests"`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, all pass.**

### Task 5: Changelog and full suite

**Files:** Modify `CHANGELOG.md` (2.0.5: "PostgreSQL: idle connections stay up, and reconnect like MySQL's").

- [ ] **Step 1:** CHANGELOG entry: keep-alive from Preferences ▸ Network; a dropped connection reconnects on next use (SSH tunnel too); the sheet; open transaction asks first; a failed statement isn't re-run.
- [ ] **Step 2:** Full suite with the real preferences snapshotted before and after (unchanged); known failures only (`testIndentNewLines`, the `SPRuleFilterController _resize` restart).
