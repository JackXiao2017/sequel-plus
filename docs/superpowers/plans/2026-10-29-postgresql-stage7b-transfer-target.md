# PostgreSQL Stage 7b (Transfer target picker) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Transfer sheet, the target database is chosen from a menu listing the target server's databases,
with "New Database…" to create one; the Password field goes away (Keychain, or a prompt only when the server asks);
and the progress sheet can never stay stuck over the window.

**Architecture:**
- **One target session per sheet.** Choosing a favorite opens a connection to it (its SSH tunnel included) that lives
  until the sheet ends. It lists the databases and creates new ones. The transfer's own target connection goes
  through the same SSH tunnel, with the password that worked, so nothing is asked twice.
- **Password prompt** only when libpq reports that the server wants a password it wasn't given, or rejected the one
  it was given.
- **Progress sheet:** `-end` always ends the sheet on the window it was begun on, even while AppKit still has it
  queued; Transfer begins it only once its own sheet has ended.

**Tech Stack:** Objective-C (MRC in app sources), AppKit built in code, PostgresKit over static libpq, XCTest (ARC).
Docker test servers: PG 12 on 55412, PG 18 on 55418 (TCP logins use scram-sha-256 passwords).

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md` (Transfer: "The Transfer sheet lets the user
pick the target favorite and target database (defaulting to the favorite's database)"), as amended by the owner on
2026-10-29 in chat: "The target database need to change to db selector, list the databases in target connection. And
provide an option to create a new database, then need to enter the database name to create", and the Password field
is to go (approved proposal: Keychain, prompt only when needed, never saved). Builds on
`docs/superpowers/plans/2026-10-29-postgresql-stage7-transfer.md`, whose decisions still hold except where this plan
changes them.

## Builder's decisions (approved with the proposal)

### Target database menu
- Choosing a favorite (and when the sheet opens) connects to it: database = the favorite's database, or `postgres`
  when that is empty. If that fails for any reason other than SSH or a password, one retry on `postgres`.
- The menu (`databasePopup`) lists `-[SPPostgresCatalog databaseNames:]` (connectable, non-template, by name), then a
  separator, then **New Database…**. The favorite's database is selected when listed, else the first.
- While connecting: one disabled item "Connecting…", Transfer disabled. On failure: one disabled item "Not
  connected", the error in a line under the menu (`targetStatusField`), a **Retry** button next to it, Transfer
  disabled.
- Switching favorite closes the previous session (connection and tunnel) and opens the new one. A connect still
  pending for the previous favorite is cancelled and its result ignored.
- The session's statements go to the Console under the favorite's name.

### New Database…
- Choosing it shows an alert as a sheet on the Transfer sheet: message "New database on “<favorite>”", a text field,
  buttons **Create** (enabled while the name is non-empty and at most 63 bytes in UTF-8) and **Cancel**.
- Create runs `CREATE DATABASE <SPPostgresQuoteIdentifier(name)>` on the session (owner the favorite's user, the
  server's default template and encoding), re-lists, and selects the new database. A server error (e.g. it exists) is
  shown as an alert on the sheet and the menu goes back to the previous selection. Cancel restores the previous
  selection too.
- The database stays if the Transfer is then cancelled.
- **A database created in this sheet** needs no Empty-mode confirmation (there is nothing to lose); every other
  database still asks for its name to be typed.
- This lifts Stage 7's "no `CREATE DATABASE` in app code" for this one action. `DROP DATABASE` stays forbidden.

### Password
- The Password field is removed. The session uses the Keychain password (read when the session connects), or none.
- If the connect fails and libpq says the server asked for a password and none was given
  (`PQconnectionNeedsPassword`), or a password was sent (`PQconnectionUsedPassword`) and the message contains
  "password authentication failed", the connector reports **`SPPostgresErrorPasswordRequired = 11`** and the sheet
  shows a password prompt (alert sheet: "Password for <user> on “<favorite>”", secure field, **Connect** / Cancel). The
  entered password is used for this sheet's session and the transfer only, never saved. Cancel leaves "Not
  connected" with Retry.

### The transfer's target connection
- The job's target provider opens a new connection for the chosen database **through the session's SSH tunnel**
  (when the favorite uses SSH) with the session's password: no prompt. It is kept until the job ends, as before.
- The session stays open while the transfer runs and closes when the controller finishes.

### Progress sheet
- `SPPostgresProgressSheet` remembers the window it was begun on. `-end` calls `[window endSheet:panel]` whether or
  not the panel is attached yet (AppKit removes a queued sheet too), then `orderOut:`.
- Transfer begins the progress sheet from its own sheet's end handler (not right after `endSheet:`).

## Global Constraints
- Everything in the Stage 7 plan's Global Constraints, except: `CREATE DATABASE` is allowed in the New Database…
  action only.
- No MySQL source changes; outside Postgres code only additive `project.pbxproj` entries.
- Test databases created by tests are named `sp_t7_%` and dropped in tearDown (test code only, `DROP DATABASE IF
  EXISTS`); tests never touch other databases than `pgkit_io_src`, `pgkit_io_dst` and `sp_t7_%`.
- Tests never read or write real prefs, favorites stores or the login keychain: controller tests use seams.
- Test command, app build, agent-session rules and commit trailer as in the Stage 7 plan.

## Review Focus
1. **Switching favorite while a connect (or an SSH prompt) is pending:** the old attempt is cancelled, its late
   result can't fill the menu, and no tunnel leaks. Pinned in Task 3 (`testSwitchingFavoriteIgnoresLateResult`).
2. **A wrong password, then a right one:** prompt, retry, menu fills; Transfer then needs no second prompt. Pinned in
   Task 3 (`testPasswordPromptThenTransfer`).
3. **"New Database…" with a name that already exists:** server error shown, selection restored, nothing created.
   Pinned in Task 3 (`testNewDatabaseExistingNameShowsError`).
4. **The job ends while the progress sheet is still queued behind the outgoing sheet:** the window ends with no
   sheet. Pinned in Task 1 (`testEndWhileQueuedLeavesNoSheet`).
5. **Closing the tab while the sheet's session is connected:** the session and tunnel close. Pinned in Task 3
   (`testTeardownClosesSession`).

---

### Task 1: The progress sheet always ends its sheet

**Files:** Modify `Source/Postgres/SPPostgresProgressSheet.h/.m`, `Source/Postgres/SPPostgresTransferController.m`
(begin the progress sheet from the Transfer sheet's end handler). Test: `PostgresTests/SPPostgresProgressSheetTests.m`
(create, or add to an existing progress-sheet test file if there is one).

- [ ] **Step 1: Write the failing tests:**
  - `testEndWhileQueuedLeavesNoSheet`: a window with a sheet attached; `beginOnWindow:` a progress sheet (queued);
    `-end` it; end the first sheet; spin the run loop until 2 s: `window.attachedSheet` is nil and the progress panel
    isn't visible.
  - `testEndAfterAttachEndsSheet`: begin on a window without a sheet, spin until attached, `-end`: no attached sheet.
- [ ] **Step 2: Run them; see the first fail.**
- [ ] **Step 3: Implement** (keep the window: not retained if the window may outlive nothing else — follow how the
  sheet keeps itself alive; release it in `-end`), and change Transfer's sequencing.
- [ ] **Step 4: Run the full suite.** Expected: 0 failures (Export and Import tests included).
- [ ] **Step 5: Commit** `Postgres Stage 7b Task 1: the progress sheet always ends its sheet`.

---

### Task 2: Password-required errors, shared tunnels, creating databases

**Files:**
- Modify `Frameworks/PostgresKit/Source/PGPostgresConnection.h/.m`: `@property (readonly) BOOL
  connectionNeededPassword;` and `@property (readonly) BOOL connectionUsedPassword;`, read from libpq
  (`PQconnectionNeedsPassword`, `PQconnectionUsedPassword`) when a connect fails, before the PGconn is freed.
- Modify `Source/Postgres/SPPostgresErrors.h`: `SPPostgresErrorPasswordRequired = 11`.
- Modify `Source/Postgres/SPPostgresConnector.h/.m`:
  - a failed connect is reported as `SPPostgresErrorPasswordRequired` (message: the server's) per the decisions;
  - `- (instancetype)initWithFavorite:(SPPostgresFavorite *)favorite password:(NSString *)password sharingTunnelOf:(SPPostgresConnector *)other;`:
    for an SSH favorite connects to `127.0.0.1:[[other tunnel] localPort]` without opening a tunnel, retaining
    `other` until it disconnects (its own `-disconnect` never closes `other`'s tunnel); for other favorites behaves as
    the normal initializer with no parent window. Fails with `SPPostgresErrorSSHTunnelFailed` if `other` has no
    connected tunnel for an SSH favorite.
- Modify `Source/Postgres/SPPostgresCatalog.h/.m`: `- (BOOL)createDatabase:(NSString *)name error:(NSError **)error;`
  (`CREATE DATABASE` + quoted name; server message with DETAIL/HINT on failure; refuses an empty name or one over
  63 bytes with `SPPostgresErrorInvalidSettings` before sending).
- Test: `PostgresTests/SPPostgresConnectorTests.m`, `PostgresTests/SPPostgresCatalogTests.m` (add).

- [ ] **Step 1: Write the failing tests** (both ports):
  - `testMissingPasswordReportsPasswordRequired`: connector for a TCP favorite (127.0.0.1, user pgkit_test) with nil
    password → `SPPostgresErrorPasswordRequired`.
  - `testWrongPasswordReportsPasswordRequired`: password `wrong` → `SPPostgresErrorPasswordRequired`.
  - `testMissingDatabaseIsNotPasswordRequired`: right password, database `sp_t7_missing` →
    `SPPostgresErrorConnectionFailed`.
  - `testSharingConnectorOnTCPConnectsAndLeavesOtherOpen`: connector B sharing A (both TCP): B connects; after B's
    `-disconnect`, A's connection is still connected.
  - `testCreateDatabase`: `createDatabase:@"sp_t7_new"` succeeds and `databaseNames:` contains it; a second call fails
    with the server's "already exists" message; `@""` and a 64-byte name fail with `SPPostgresErrorInvalidSettings`
    and send nothing. tearDown drops `sp_t7_%` databases.
- [ ] **Step 2: Run them; see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite.** Expected: 0 failures.
- [ ] **Step 5: Commit** `Postgres Stage 7b Task 2: password-required errors, shared tunnels, CREATE DATABASE`.

---

### Task 3: The target database menu, New Database… and the password prompt

**Files:** Modify `Source/Postgres/SPPostgresTransferController.h/.m`. Test:
`PostgresTests/SPPostgresTransferControllerTests.m` (update for the removed field and new seams).

**Interfaces:**
- Removed: `databaseField`, `passwordField`, `targetProviderForFavorite`.
- Added for tests: `databasePopup` (NSPopUpButton), `targetStatusField`, `retryButton`, `selectedDatabase`
  (NSString, nil while none), and these seams:
  - `@property (copy) void (^targetConnect)(SPPostgresFavorite *favorite, NSString *database, NSString *password, id sessionToken, void (^completion)(PGPostgresConnection *connection, id sessionToken, NSError *error));`
    — opens a target connection. `sessionToken` nil opens the session (the default makes an SPPostgresConnector with
    the Keychain or given password and the Transfer sheet as parentWindow, and returns the connector as the token);
    non-nil opens the transfer's connection to `database` through that session (the default: a connector
    `sharingTunnelOf:` the token, kept until the job ends). Tests return SPPostgresTestServers connections.
  - `@property (copy) void (^passwordPrompt)(SPPostgresFavorite *favorite, void (^answer)(NSString *password));`
    (nil answer = Cancel). nil: the alert sheet of the decisions.
  - `@property (copy) void (^newDatabasePrompt)(SPPostgresFavorite *favorite, void (^answer)(NSString *name));` (nil
    answer = Cancel). nil: the alert sheet of the decisions.
- `emptyConfirmation` is not called for a database created in this sheet.

- [ ] **Step 1: Write the failing tests** (both ports; source `pgkit_io_src`, favorites in memory):
  - `testMenuListsTargetDatabases`: after the session connects, the menu contains `pgkit_io_src` and `pgkit_io_dst`,
    not `template0`/`template1`, then a separator and "New Database…"; `pgkit_io_dst` (the favorite's) is selected;
    Transfer enabled.
  - `testConnectingAndFailureStates`: a `targetConnect` that hasn't answered shows "Connecting…" with Transfer
    disabled; one that fails shows "Not connected", the error in `targetStatusField`, Retry visible; Retry connects
    again.
  - `testSwitchingFavoriteIgnoresLateResult`: favorite A's connect answers after B was chosen: the menu shows B's
    databases and A's connection is disconnected.
  - `testPasswordPromptThenTransfer`: `targetConnect` fails with `SPPostgresErrorPasswordRequired` unless given
    `pgkit`; `passwordPrompt` answers `pgkit`; the menu fills; a whole-database transfer into `pgkit_io_dst` (Empty,
    confirmed) succeeds; `passwordPrompt` was called exactly once and the transfer's connection was asked for with
    password `pgkit` and the session token.
  - `testNewDatabaseCreatesAndSelects`: choosing "New Database…" with answer `sp_t7_made` creates it, selects it;
    a whole-database transfer into it runs without calling `emptyConfirmation` and its rows match the source's.
  - `testNewDatabaseExistingNameShowsError`: answer `pgkit_io_dst`: an alert with the server's message, the
    selection back to `pgkit_io_dst`, the menu unchanged.
  - `testNewDatabaseCancelRestoresSelection`.
  - `testTeardownClosesSession`: closing the document while the session is connected disconnects it.
  - Keep every existing test passing in its new form (defaults, confirmation, end-to-end, overwrite blocked, cancel,
    toolbar, dealloc).
- [ ] **Step 2: Run them; see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite, then build the app.** Expected: 0 failures, `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `Postgres Stage 7b Task 3: target database menu, New Database… and password prompt`.
