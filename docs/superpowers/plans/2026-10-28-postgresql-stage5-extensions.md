# PostgreSQL Stage 5 (Extensions) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a Postgres tab, the EXTENSIONS section at the bottom of the left panel lets the user:
- **install** an extension, chosen from the server's available extensions;
- **update** an installed extension to another version;
- **drop** an extension.

All three work as the Sequences section from Stage 3 does.

**Architecture:**
- A data layer, `SPPostgresExtensions`, reads installed and available extensions, versions and update paths, and
  runs `CREATE`/`ALTER … UPDATE`/`DROP EXTENSION`.
- Every change goes through the existing `SPPostgresRunStructureChange` on the document's connection (savepoint
  `sp_structure` with `lock_timeout`). A failure leaves the database as it was, and the user's open Query
  transaction survives, exactly as Structure changes do.
- Selecting an extension shows a new right-hand **Extension pane** (`SPPostgresPaneExtension`) with its details,
  an "Update to" pop-up and a Drop button.
- "Install Extension…" opens a sheet listing the extensions not yet installed.

**Tech Stack:** Objective-C (MRC in app sources), AppKit built in code, PostgresKit over static libpq, XCTest (ARC),
Docker test servers (PG 12 on 55412, PG 18 on 55418).

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md`:
- Goal 13: "install an extension, change an installed extension's version, and drop an extension".
- "Window and left panel": extensions at the end of the left panel.
- "Extensions": "Clicking an extension allows: install (choose from the server's available extensions), update to
  another version, and drop".
- "Server versions and privileges": "Users, Extensions and Transfer may assume superuser rights. When the connected
  role lacks a right, the server's error is shown".

These are amended by `docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`.

## Builder's decisions (the spec leaves these open)

- **Where it lives:** extensions are database-wide, so the sheet and the pane don't depend on the schema picker,
  except for the default install schema.
- **Required extensions are installed explicitly, never with `CASCADE`.**
  - Installing `earthdistance` when `cube` is missing runs `CREATE EXTENSION "cube"` first, then
    `CREATE EXTENSION "earthdistance"`, in one atomic change.
  - The missing requirements are found transitively from `pg_available_extension_versions.requires` for the
    chosen version (each requirement at its default version).
  - The sheet lists them before installing: "Also installs: cube".
- **Install schema:** the sheet offers the database's schemas and defaults to the schema selected in the left
  panel.
  - A non-relocatable extension whose control file fixes a schema (`pg_available_extension_versions.schema` is
    not NULL) shows that schema with the pop-up disabled, and its `CREATE` has no `WITH SCHEMA`.
  - Required extensions go into the chosen schema too, unless their control file fixes one.
- **Version on install:** a pop-up of the extension's available versions, defaulting to `default_version`, sent as
  `VERSION '<v>'` only when it differs from the default.
- **Update targets:** the versions reachable from the installed one (`pg_extension_update_paths(name)`, `source` =
  installed, `path IS NOT NULL`), sorted with the default version marked "(default)". When there are none, the
  pane says "No other version available" and Update is disabled.
- **Drop never cascades.** `DROP EXTENSION "x"` without `CASCADE`.
  - When the server refuses because something depends on the extension (SQLSTATE `2BP01`), the error becomes
    `SPPostgresErrorHasDependents`, with the message `"<x>" can't be dropped because other objects depend on it.`
  - `SPPostgresDependentsErrorKey` holds the server's DETAIL lines, split on newlines, for example
    `column tags of table items depends on type hstore` or `extension earthdistance depends on extension cube`.
  - The alert lists them, as Stage 3's column drop does.
- **Confirming:** Drop asks first, with "Drop extension “<x>”?" and "Drop" / "Cancel". The Drop button is
  destructive.
- **`plpgsql`** is listed like any other extension. Dropping it gets the server's refusal or succeeds, as with
  any other extension. No special case.
- **Not in History:** selecting an extension is not recorded in Table History, because History entries belong to
  a schema and extensions don't.
- **After any change** the sidebar reloads keeping its selection: an install may create tables or views, and a
  drop may remove some. Content, Structure and Query are marked stale, as after Query-view DDL.
  - After an install, the new extension is selected.
  - After a drop, nothing is selected.
- **Toolbar:** while the Extension pane shows, only Query and the document-level items are enabled, as with the
  Sequence pane. ⌘1 returns to the Extension pane, as with sequences.

## Global Constraints

- **Never break MySQL.** No MySQL controller changes. Any shared-file edit is additive and inert for MySQL tabs.
- PostgreSQL **12 through 18**. Every data-layer test runs on both 55412 and 55418.
  - `pg_available_extension_versions.trusted` exists only on PG 13+, so don't read it.
- **Quoting:** identifiers, including extension names such as `uuid-ossp`, always go through
  `SPPostgresQuoteIdentifier`. Versions go through `SPPostgresQuoteLiteral`. Reads use `$n` parameters.
- **Never cascade:** no `CASCADE` anywhere in app code.
- **Atomic changes:** every change runs through `SPPostgresRunStructureChange(connection, lockTimeout, body,
  error)` (Stage 3 R1: savepoint `sp_structure`, `SET LOCAL lock_timeout` restored), with `lockTimeout` default 5.
  An aborted user transaction refuses without sending.
- **Superuser assumption (spec):** a role lacking the right gets the server's error. Nothing is greyed out for it.
- **Tests:**
  - Extension tests use their own database, `pgkit_ext`, created when missing. `SPPostgresTestServers` gets
    `+ (PGPostgresConnection *)extensionTestConnectionOnPort:(NSUInteger)port;`, which creates `pgkit_ext` if
    needed, connects to it, and drops every installed extension except `plpgsql` (dependents first, using
    `DROP EXTENSION … CASCADE` and `DROP TABLE` in test code only).
  - Tests never touch `pgkit_test`'s `pg_trgm`, which the catalog tests rely on.
  - Extensions used: `hstore` (versions 1.4 and up on both servers; installing 1.4 leaves an update path),
    `cube` and `earthdistance` (requires `cube`), `citext`, `uuid-ossp`.
- **Tests and prefs:** never write `Favorites.plist`. Tests never persist into real prefs or the login keychain;
  `PostgresTests/SPTestPrefsGuard.m` stays effective.
- **Code conventions:**
  - MRC in app sources; ARC in `Postgres Tests`.
  - Add files only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test`.
  - Exported classes and functions need `__attribute__((visibility("default")))`.
- **Test command:** `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests"
  -derivedDataPath build/DerivedData ARCHS=arm64`. Run `bash Scripts/pg-test-servers.sh up` first.
- **App build:** `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath
  build/DerivedData ARCHS=arm64 build`.
- **Agent sessions:**
  - Implementer sessions never launch the GUI app; the controller does the visual checks.
  - Never kill processes you didn't start.
  - Never touch the owner's untracked `start_clause.sh`; stage only your own files.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Dropping an extension something depends on**:
   - Cases: a table column of type `hstore`, or `earthdistance` installed on top of `cube`.
   - Nothing is dropped, and every dependent the server names is listed.
   - Pinned in Task 1 (`testDropWithDependentsIsRefusedAndListsThem`) and Task 2 (`testDropWithDependentsShowsList`).
2. **Installing an extension that needs another**:
   - `earthdistance` with `cube` missing installs both, and the sheet says "Also installs: cube".
   - If anything fails, neither is left installed.
   - Pinned in Task 1 (`testInstallInstallsMissingRequirementsFirst`,
     `testFailedInstallLeavesNothingInstalled`) and Task 3 (`testSheetShowsAlsoInstalls`).
3. **The user's open transaction in the Query view**:
   - A failing install, update or drop leaves it open and usable.
   - An aborted transaction refuses without sending.
   - Pinned in Task 1 (`testFailedChangeInsideUserTransactionKeepsItOpen`,
     `testAbortedTransactionRefusesChanges`).
4. **Odd names**:
   - `uuid-ossp` (a hyphen) is installed into schema `"Sales Data"`, then updated (none available) and dropped.
   - Pinned in Task 1 (`testOddNamesAndSchemas`).
5. **A version the server can't install or reach** (a typo, or a version removed meanwhile):
   - The server's error is shown and nothing changes.
   - Pinned in Task 1 (`testFailedInstallLeavesNothingInstalled` uses version `9.9`).

---

### Task 1: `SPPostgresExtensions`, reading and changing extensions

**Files:**
- Create: `Source/Postgres/SPPostgresExtensions.h/.m`.
- Modify: `PostgresTests/SPPostgresTestServers.h/.m`. Add `extensionTestConnectionOnPort:` (see Global
  Constraints).
- Test: `PostgresTests/SPPostgresExtensionsTests.m`.

**Interfaces:**
- **Consumes:**
  - `SPPostgresRunStructureChange`, `SPPostgresExecute`, `SPPostgresExecuteWithDetails`;
  - `SPPostgresQuoteIdentifier`, `SPPostgresQuoteLiteral`;
  - `SPPostgresMakeError`, `SPPostgresErrorHasDependents`, `SPPostgresDependentsErrorKey`,
    `SPPostgresSQLStateErrorKey`.

  Find each one's header with grep.
- **Produces `SPPostgresExtension : NSObject`** (readonly):
  - `name`, `version`, `schema`;
  - `comment` (from `pg_available_extensions.comment`, nil if none);
  - `BOOL relocatable`;
  - `defaultVersion` (the server's default version for it);
  - `NSArray *requiredBy`: the names of installed extensions that require it.
- **Produces `SPPostgresAvailableExtension : NSObject`** (readonly):
  - `name`, `defaultVersion`, `comment`;
  - `NSArray *versions` (all available versions, server order);
  - `fixedSchema`: the control file's schema for the default version, nil if none.
- **Produces `SPPostgresExtensions : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `@property NSTimeInterval lockTimeout;` (default 5)
  - `- (NSArray *)installedExtensions:(NSError **)error;` returns `SPPostgresExtension`s sorted by name.
  - `- (SPPostgresExtension *)extensionNamed:(NSString *)name error:(NSError **)error;`
    - nil with nil error when it isn't installed.
  - `- (NSArray *)availableExtensions:(NSError **)error;` returns `SPPostgresAvailableExtension`s that are not
    installed, sorted by name.
  - `- (NSArray *)updateTargetsForExtension:(NSString *)name error:(NSError **)error;`
    - Version strings reachable from the installed version, sorted by `pg_extension_update_paths` order.
    - Empty when there are none.
  - `- (NSArray *)missingRequirementsForExtension:(NSString *)name version:(NSString *)version error:(NSError **)error;`
    - Uninstalled required extensions, transitively, in install order (dependencies first, no duplicates).
    - A nil version means the default.
  - `- (BOOL)installExtension:(NSString *)name version:(NSString *)version schema:(NSString *)schema error:(NSError **)error;`
    - Installs the missing requirements first, then the extension, in one `SPPostgresRunStructureChange`.
    - A nil or default version sends no `VERSION`. A nil schema, or a fixed control-file schema, sends no
      `WITH SCHEMA`.
  - `- (BOOL)updateExtension:(NSString *)name toVersion:(NSString *)version error:(NSError **)error;` runs
    `ALTER EXTENSION "x" UPDATE TO '<v>'`.
  - `- (BOOL)dropExtension:(NSString *)name error:(NSError **)error;`
    - SQLSTATE `2BP01` maps to `SPPostgresErrorHasDependents` as in the decisions.
    - Other errors carry the server message with its DETAIL and HINT.

- [ ] **Step 1: Write the failing tests**, each on both ports, using `extensionTestConnectionOnPort:`:
  - `testInstalledAndAvailableLists`:
    - After installing `citext`, `installedExtensions:` has `plpgsql` and `citext`. `citext` has `schema`
      `public`, the right version and a non-nil comment.
    - `availableExtensions:` contains `hstore` (with `1.4` in `versions`) and not `citext`.
  - `testInstallWithVersionThenUpdate`:
    - Install `hstore` version `1.4` into `public`. Its `version` is `1.4`.
    - `updateTargetsForExtension:@"hstore"` contains `1.5` and the default version.
    - Update to the default version. `version` equals `defaultVersion`, and the update targets are now empty.
  - `testInstallInstallsMissingRequirementsFirst`:
    - `missingRequirementsForExtension:@"earthdistance" version:nil` is exactly `@[@"cube"]`.
    - `installExtension:@"earthdistance"` installs both.
    - `cube`'s `requiredBy` is `@[@"earthdistance"]`.
  - `testFailedInstallLeavesNothingInstalled`: `installExtension:@"earthdistance" version:@"9.9" schema:nil` fails
    with the server's message, and neither `earthdistance` nor `cube` is installed.
  - `testDropWithDependentsIsRefusedAndListsThem`:
    - Install `hstore`, create `public.sp_t5_items (tags hstore)`, and drop `hstore`.
    - The error code is `SPPostgresErrorHasDependents`, and the dependents contain a line mentioning `sp_t5_items`.
    - With `earthdistance` installed, dropping `cube` lists a line mentioning `earthdistance`.
    - Both stay installed. tearDown drops the table.
  - `testDropSucceeds`: drop `citext`; `extensionNamed:` then returns nil with a nil error.
  - `testFailedChangeInsideUserTransactionKeepsItOpen`: run `BEGIN` and insert into a temp table. A failing
    install (version `9.9`) leaves `transactionStatus` in-transaction (not aborted), and the inserted row is still
    there.
  - `testAbortedTransactionRefusesChanges`: after `BEGIN` and a failing statement, `installExtension:` returns NO
    without sending anything; check with the capturing delegate from `SPPostgresTestServers`.
  - `testOddNamesAndSchemas`:
    - Create schema `"Sales Data"` in `pgkit_ext`, install `uuid-ossp` into it, and confirm it's listed with that
      schema.
    - Its update targets are empty.
    - Drop it.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** `SPPostgresExtensions` as specified.
- [ ] **Step 4: Run the full test suite.** Expected: everything passes, 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 5 Task 1: extensions data layer`.

---

### Task 2: The Extension pane, Drop, and the sidebar menu

**Files:**
- Create: `Source/Postgres/SPPostgresExtensionController.h/.m`, built in code like `SPPostgresSequenceController`.
- Modify: `Source/Postgres/SPPostgresSidebarController.h/.m`.
  - Add `@property (readonly) NSString *selectedExtensionName;`. It is nil unless an extension is selected;
    `selectedTableName` and `selectedSequenceName` are nil then.
  - Add `- (BOOL)selectExtensionNamed:(NSString *)name;`.
  - Add `@property (readonly) NSMenu *extensionMenu;`, the right-click menu on an extension, the EXTENSIONS header,
    or empty space below it. It has "Install Extension…" (always) and "Drop Extension…" (on an extension only:
    the row right-clicked, or else the selected one).
  - `menuForRow:` returns it for those rows.
  - Delegate methods: `- (void)sidebarInstallExtension:(SPPostgresSidebarController *)sidebar;` and
    `- (void)sidebar:(SPPostgresSidebarController *)sidebar dropExtensionNamed:(NSString *)name;`.
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`.
  - Add the pane `SPPostgresPaneExtension` (`@"extension"`) with the property `extensionController`.
  - The pane is shown whenever an extension is selected, with the toolbar and ⌘1 behaviour from the decisions.
  - It is not recorded in History.
  - Drop runs from both the pane's button and the sidebar menu. `sidebarInstallExtension:` calls
    `showInstallExtensionSheet:` (Task 3); in this task it is an empty stub method.
- Test: `PostgresTests/SPPostgresExtensionControllerTests.m`, plus additions to `SPPostgresDocumentTests.m`.

**Interfaces:**
- **Consumes:** Task 1's `SPPostgresExtensions` and `SPPostgresExtension`. Use the document's `alertPresenter` and
  `confirmationPresenter`, the pane mechanism (`showPane:`, `_canShowPane:`), and the stale flags set after
  Query-view DDL (find how `SPPostgresQueryController` marks panes stale).
- **Produces `SPPostgresExtensionController : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `- (NSView *)view;`
  - `- (void)showExtension:(NSString *)name;` reads the extension and its update targets.
  - Exposed for tests:
    - `nameField`, `versionField`, `schemaField`, `commentField`, `requiredByField`: read-only labels.
      `requiredByField` is "Required by: earthdistance", and hidden when nothing requires it.
    - `updatePopup` lists the targets; the default is marked "1.8 (default)" and preselected when present.
    - `updateButton`, `dropButton`, `noUpdateLabel` ("No other version available").
  - `@property (assign) id<SPPostgresExtensionControllerDelegate> delegate;` with:
    - `- (void)extensionController:(SPPostgresExtensionController *)controller didChangeExtension:(NSString *)name;`
      tells the document to reload the sidebar and mark panes stale;
    - `- (void)extensionController:(SPPostgresExtensionController *)controller wantsToDropExtension:(NSString *)name;`
      lets the document confirm and drop, shared with the sidebar menu path.
  - `- (void)update:(id)sender;` runs `updateExtension:toVersion:` with the pop-up's version, shows the error
    through the document's alert presenter on failure, and refreshes itself.

- [ ] **Step 1: Write the failing tests**, on both ports, against `pgkit_ext` through `extensionTestConnectionOnPort:`:
  - `testPaneShowsDetailsAndUpdateTargets`:
    - With `hstore` 1.4 installed, `showExtension:@"hstore"` shows version `1.4` and schema `public`.
    - `updatePopup` has `1.5` and the default (marked), with the default preselected.
  - `testUpdateFromPane`: `update:` brings `hstore` to the default version; the pane then shows `noUpdateLabel`
    with Update disabled, and the delegate heard `didChangeExtension:`.
  - `testRequiredByShown`: with `earthdistance` installed, `cube`'s pane shows "Required by: earthdistance".
  - In SPPostgresDocumentTests, for a document connected to `pgkit_ext`:
    - `testSelectingExtensionShowsExtensionPane`: selecting `citext` in the sidebar shows `SPPostgresPaneExtension`.
      Structure, Content, Relations, Triggers and Table Info validate NO, and Query validates YES.
    - `testDropExtensionConfirmsAndDrops`: the confirmation presenter is asked with "Drop extension “citext”?".
      YES drops it, the sidebar no longer lists it, and nothing is selected.
    - `testDropWithDependentsShowsList`: dropping `hstore` while `sp_t5_items` uses it shows an alert whose
      informative text mentions `sp_t5_items`, and `hstore` is still listed.
    - `testExtensionMenuItems`: `menuForRow:` on an extension row has both items enabled. On the EXTENSIONS header
      only "Install Extension…" is visible. On a table row the table menu is unchanged.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** the pane, the sidebar additions and the document wiring.
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and the build succeeds.
- [ ] **Step 5: Commit** with the message `Postgres Stage 5 Task 2: Extension pane, drop and sidebar menu`.

---

### Task 3: The Install Extension sheet

**Files:**
- Create: `Source/Postgres/SPPostgresInstallExtensionSheet.h/.m`, built in code like `SPPostgresConstraintSheet`.
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`. Add `- (IBAction)showInstallExtensionSheet:(id)sender;`
  (replacing Task 2's stub), reached from the sidebar's "Install Extension…".
- Test: `PostgresTests/SPPostgresInstallExtensionSheetTests.m`.

**Interfaces:**
- **Consumes:** Task 1 (`availableExtensions:`, `missingRequirementsForExtension:version:error:`,
  `installExtension:version:schema:error:`) and the catalog's `schemaNames:`. From Task 2: the document's
  post-change reload and stale marking, and `selectExtensionNamed:`.
- **Produces `SPPostgresInstallExtensionSheet : NSObject`:**
  - `+ (void)beginWithConnection:(PGPostgresConnection *)connection schema:(NSString *)defaultSchema window:(NSWindow *)window completion:(void (^)(NSString *installedNameOrNil))completion;`
  - The completion is called exactly once: with the installed name after a successful Install, or nil on Cancel.
  - Exposed for tests via `+ (SPPostgresInstallExtensionSheet *)currentSheet` (nil when none is open):
    - `extensionsTable` (columns: Name, Default version, Description) and `filterField`, which filters by
      case-insensitive substring of name or description;
    - `versionPopup`, `schemaPopup`, `alsoInstallsLabel`, `installButton`, `cancelButton`;
    - `lastErrorMessage`;
    - `- (BOOL)selectExtensionNamed:(NSString *)name;`, `- (void)install:(id)sender;`, `- (void)cancel:(id)sender;`.
- **Behaviour:**
  - The sheet is 560×420, resizable, titled "Install Extension".
  - Install is disabled until a row is selected.
  - The version pop-up lists the selected extension's versions with its default preselected.
  - The schema pop-up follows the decisions: the fixed schema is shown and disabled.
  - `alsoInstallsLabel` reads "Also installs: cube" (comma-separated), refreshed on every selection or version
    change, and hidden when nothing is missing.
  - On failure the sheet stays open with the server message in an alert and in `lastErrorMessage`.
  - On success the sheet closes, the document reloads the sidebar, selects the new extension, and shows its pane.

- [ ] **Step 1: Write the failing tests**, on both ports, against `pgkit_ext` on an offscreen window:
  - `testListsOnlyUninstalledAndFilters`: `citext` is installed beforehand, so it is not listed; `hstore` is.
    Typing `earth` in the filter leaves exactly `earthdistance`.
  - `testSheetShowsAlsoInstalls`: selecting `earthdistance` shows "Also installs: cube". Selecting `hstore` hides
    the label.
  - `testInstallWithVersionAndSchema`: select `hstore`, version `1.4`, schema `public`, then Install. `hstore` 1.4
    is installed in `public`, and the completion got `@"hstore"`.
  - `testInstallFailureKeepsSheetOpen`: after selecting `hstore`, install `hstore` behind the sheet's back with
    raw SQL, then Install. `lastErrorMessage` contains `already exists`, and the sheet is still attached.
  - `testCancelInstallsNothing`: the completion gets nil, and nothing new is installed.
  - In SPPostgresDocumentTests, `testInstallSelectsNewExtension`: installing `citext` through the document's
    sheet, completed via `currentSheet`, leaves `citext` listed and selected, with the Extension pane shown.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** the sheet and the document action.
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and the build succeeds.
- [ ] **Step 5: Commit** with the message `Postgres Stage 5 Task 3: Install Extension sheet`.
