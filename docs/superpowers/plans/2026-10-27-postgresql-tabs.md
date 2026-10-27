# PostgreSQL Tabs in MySQL Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open PostgreSQL connections as tabs in the existing Sequel Pro windows next to MySQL tabs,
sharing one toolbar whose items are disabled when the active tab's engine doesn't support them.

**Architecture:** `SPWindowController` hosts any tab through a small `SPWindowTabDocument` protocol.
`SPDatabaseDocument` conforms with methods it already has, so its behaviour doesn't change.
The stage-1 `SPPostgresWindowController` becomes `SPPostgresDocument`, a tab document without a
window of its own. MySQL-only code keeps receiving only `SPDatabaseDocument`s:
`selectedTableDocument` and `frontDocument` return nil while a Postgres tab is active.

**Tech Stack:** Objective-C (MRC in app sources), AppKit, PSMTabBar, PostgresKit, XCTest (ARC), Docker test servers.

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`, amending
`docs/superpowers/specs/2026-10-27-postgresql-support-design.md`.

## Global Constraints

- **Never break MySQL.** With only MySQL tabs, windows, tabs, the toolbar (apart from the one added
  disabled Transfer item, placed after Users), menus, tab drag, tab close and window close behave
  exactly as before.
- `-[SPWindowController selectedTableDocument]` and `-[SPAppController frontDocument]` keep
  returning `SPDatabaseDocument *`, and return **nil while a Postgres tab is selected**.
- One toolbar identifier, `TableWindowToolbar`, for both engines. Postgres tabs use the MySQL item
  identifiers (`SPMainToolbar*` in Source/SPConstants.m) plus one new identifier,
  `SPMainToolbarTransfer` = `@"TransferToolbarItemIdentifier"`.
- Postgres tab title format: `(PostgreSQL <version>) <favorite name>/<database>[/<schema>.<table>]`.
  Tab label: favorite name. Tab colour: favorite colour.
- Never write `~/Library/Application Support/Sequel Pro/Data/Favorites.plist`. Tests never persist
  into real prefs or the login keychain.
- MRC in app sources; ARC in `Postgres Tests`. Add files only with `ruby Scripts/pg-xcodeproj.rb
  add-app|add-test`; exported classes and constants need `__attribute__((visibility("default")))`.
- Test command: `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests"
  -derivedDataPath build/DerivedData ARCHS=arm64`. Docker servers: `bash Scripts/pg-test-servers.sh up`.
- Don't launch the GUI app from implementer sessions: it restores the owner's live MySQL session.
  The controller does the visual checks.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A MySQL menu action with a Postgres tab active.** Examples: Database ▸ Refresh, Show Navigator,
   Process List, bundles. Each must be disabled or do nothing; none may crash. Pinned in Task 1 (forwarding) and Task 2 (validation).
2. **A window with mixed tabs.** Switching MySQL ↔ Postgres must swap the toolbar state, window title
   and side panel correctly every time. Pinned in Task 3.
3. **Dragging a Postgres tab into another window or out to a new window.** The connection must keep
   working and the tab must keep its title and colour. Pinned in Task 4.
4. **Closing a window that has both tab types.** Every Postgres connection disconnects, and the MySQL
   close prompts behave as before. Pinned in Task 4.
5. **A failed Postgres connect from the connection screen.** The tab must stay a usable MySQL
   connection screen. Pinned in Task 4.

---

### Task 1: `SPWindowTabDocument` and generic tabs in `SPWindowController`

**Files:**
- Create: `Source/SPWindowTabDocument.h`
- Modify: `Source/SPWindowController.h`, `Source/SPWindowController.m`, `Source/SPDatabaseDocument.h`
  (declare conformance only)
- Test: `PostgresTests/SPWindowTabsTests.m`

**Interfaces:**
- Produces: `@protocol SPWindowTabDocument <NSObject>`. These are methods `SPDatabaseDocument`
  already has, so they need no new MySQL code:
  - `- (NSView *)databaseView;`
  - `- (void)setParentWindowController:(SPWindowController *)controller;`
  - `- (void)setParentWindow:(NSWindow *)window;`
  - `- (void)setParentTabViewItem:(NSTabViewItem *)item;`
  - `- (void)didBecomeActiveTabInWindow;`
  - `- (void)willResignActiveTabInWindow;`
  - `- (void)updateWindowTitle:(id)sender;`
  - `- (BOOL)parentTabShouldClose;`
  - `- (void)parentTabDidClose;`
  - `@property (readonly) BOOL isProcessing;`

  `@optional`: `- (void)tabDidBecomeKey;`, `- (void)tabDidResize;`, `- (NSString *)tabToolTip;`
- Produces on `SPWindowController`:
  - `- (id <SPWindowTabDocument>)selectedDocument;`
  - `- (NSArray *)tabDocuments;` (every tab's document, in tab order)
  - `- (void)addTabDocument:(id <SPWindowTabDocument>)document atIndex:(NSInteger)index select:(BOOL)select;`
  - `- (void)replaceTabDocument:(id <SPWindowTabDocument>)oldDocument withDocument:(id <SPWindowTabDocument>)newDocument;`
    It replaces the document at the same index and selects it. `oldDocument` gets `parentTabDidClose`.
- Behaviour:
  - `selectedTableDocument` returns `selectedDocument` only when it is an `SPDatabaseDocument`, else nil.
  - `documents` keeps returning only `SPDatabaseDocument`s.
  - `forwardInvocation:`, `methodSignatureForSelector:`, `respondsToSelector:` and `performSelector:…`
    forward to `selectedDocument` only if it responds to the selector.
  - Tab-view delegate methods (`didSelect`, `shouldClose`, `didClose`, tooltip, drag/drop, `updateAllTabTitles:`)
    use the protocol, falling back to the existing MySQL code when the document is an `SPDatabaseDocument`.
  - The `SPDocumentWillCloseNotification` observation stays MySQL-only. Non-MySQL tabs clear
    `selectedDocument` from `tabView:didCloseTabViewItem:`.

- [ ] **Step 1: Write failing tests.** Use a test-only `SPFakeTabDocument` that conforms to the
  protocol: an empty view, counters for every protocol call, and a test action `-fakeAction:`.
  Load `SPWindowController` from the `MainWindow` nib, as `SPAppController -newWindow` does; read
  that method for the nib name.
  - `testAddingFakeTabMakesItSelectedDocument`: after `addTabDocument:atIndex:0 select:YES`,
    `selectedDocument` is the fake, `selectedTableDocument` is nil, and `didBecomeActiveTabInWindow`
    was called once.
  - `testDocumentsListsOnlyMySQLDocuments`: one MySQL tab (from `addNewConnection`) plus one fake.
    `documents` count is 1 and `tabDocuments` count is 2.
  - `testForwardingSkipsDocumentsThatDontRespond`: with the fake selected,
    `[controller respondsToSelector:@selector(showServerVariables:)]` is NO, and
    `respondsToSelector:@selector(fakeAction:)` is YES.
  - `testReplaceKeepsIndexAndSelects`: two MySQL tabs. Replace the second with a fake: the fake is
    at index 1 and selected, and the old document received `parentTabDidClose`.
  - `testSwitchingTabsResignsAndActivates`: fake A ↔ MySQL B. A gets `willResign` once when B is
    selected, and B becomes `selectedTableDocument`.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the protocol, the conformance declaration and the window controller changes.**
- [ ] **Step 4: Run the full suite and the app build.** Both pass.
- [ ] **Step 5: Commit.**

### Task 2: `SPPostgresDocument`, the Postgres tab (replaces `SPPostgresWindowController`)

**Files:**
- Create: `Source/Postgres/SPPostgresDocument.h/.m`
- Delete: `Source/Postgres/SPPostgresWindowController.h/.m`. Move its behaviour into the document;
  update the project with the script, extending it with a `remove` command if needed.
- Modify/move tests: `PostgresTests/SPPostgresWindowTests.m` → `PostgresTests/SPPostgresDocumentTests.m`

**Interfaces:**
- Consumes: `SPWindowTabDocument` and the Task 1 `SPWindowController` API; `SPPostgresSidebarController`,
  `SPPostgresCatalog`, `SPPostgresConnector`, `SPPostgresConsoleLogger`, `NSWindow+SPCompactChrome`.
- Produces: `SPPostgresDocument : NSObject <SPWindowTabDocument>` with:
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection connector:(SPPostgresConnector *)connector favorite:(SPPostgresFavorite *)favorite;`
  - `- (NSString *)windowTitleString;` (format as in Global Constraints)
  - `- (void)switchToDatabase:(NSString *)database;`
  - `@property (readonly) SPPostgresSidebarController *sidebar;`
  - `@property (readonly) PGPostgresConnection *connection;`
  - `@property (readonly) SPPostgresFavorite *favorite;`
  - `@property (copy) void (^alertPresenter)(NSAlert *alert);`
  - `- (BOOL)validateMenuItem:(NSMenuItem *)item;` returns NO for every action it doesn't implement.
- The document's `databaseView` is the stage-1 window content: an `SPSplitView` (autosave
  `PGViewSplitter`), the left panel and the empty right pane. It has no tab bar of its own; the
  window's tab bar is used.
- `didBecomeActiveTabInWindow` installs the Postgres toolbar (Task 3), sets the window title, and
  applies `sp_applyCompactTitle` / `sp_useExpandedCompactToolbar`.
- `updateWindowTitle:` sets the tab item's label (favorite name) and colour (favorite colour) and,
  when this tab is selected, the window title.
- `parentTabDidClose` disconnects the connector, which closes the tunnel too.
- Database switching, error reporting (`alertPresenter`, sheet on `parentWindow`) and console logging
  keep their stage-1 behaviour and tests.

- [ ] **Step 1: Port the stage-1 window tests to the document.** Host it in a window controller with
  `addTabDocument:`. Keep the assertions: sidebar sections, schema switching, title format, database
  switch success/failure, catalog error reporting, console logging. Add:
  - `testTabLabelAndColourComeFromFavorite`
  - `testClosingTabDisconnects` (`parentTabDidClose` → `[connection isConnected] == NO` within 2 s)
  - `testMenuValidationDisablesUnsupportedActions` (`validateMenuItem:` NO for an item whose action is
    `@selector(showServerVariables:)`)
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement `SPPostgresDocument` and remove `SPPostgresWindowController`.**
- [ ] **Step 4: Run the full suite and the app build.**
- [ ] **Step 5: Commit.**

### Task 3: One toolbar for both engines

**Files:**
- Modify: `Source/SPConstants.h/.m` (add `SPMainToolbarTransfer`), `Source/SPDatabaseDocument.m`
  (allowed and default items gain Transfer right after Users; the item is created disabled and
  validated NO), `Source/Postgres/SPPostgresDocument.m` (toolbar)
- Both engines share the saved toolbar layout (autosave `TableWindowToolbar`). The owner's existing
  saved layout has no Transfer item, so on toolbar setup either engine inserts Transfer right after
  Users (or before Console if Users was removed) **once**, when the configuration lacks it. If the
  user later removes it through Customize Toolbar, it is not re-added: record the one-time insertion
  under the preference key `SPToolbarTransferItemAdded`. This is the only visible MySQL change: one
  greyed-out icon.
- Test: `PostgresTests/SPPostgresToolbarTests.m`

**Interfaces:**
- Produces:
  - `extern NSString *SPMainToolbarTransfer;` = `@"TransferToolbarItemIdentifier"`.
  - The Postgres document's `NSToolbar` uses identifier `TableWindowToolbar` with allowed and default
    identifiers **identical** to the MySQL document's plus `SPMainToolbarTransfer`. The default order:
    Database, Structure, Content, Relations, Triggers, Table Info, Query, flexible space, History,
    Users, Transfer, Console.
- Postgres enabling in this plan:
  - Database picker and Console are enabled.
  - Structure, Content, Relations, Triggers, Table Info, Query, History, Users and Transfer are
    disabled until their stages; History is a disabled view item.
- MySQL enabling: as before; Transfer is always disabled.
- Images are MySQL's (via `SPCompactToolbarImage`); Transfer uses the stage-1 SF Symbol
  `arrow.left.arrow.right`.

- [ ] **Step 1: Write failing tests.**
  - `testPostgresToolbarSharesIdentifierAndItems`: Postgres toolbar identifier `TableWindowToolbar`;
    its delegate's allowed identifiers ⊇ the MySQL document's allowed identifiers ∪ {Transfer}.
  - `testMySQLToolbarAllowsTransferButDisablesIt`: an `SPDatabaseDocument`'s toolbar delegate creates
    a Transfer item, and `validateToolbarItem:` returns NO.
  - `testMySQLDefaultItemsGainOnlyTransfer`: the MySQL default identifiers equal the pre-change list
    (copy it from `toolbarDefaultItemIdentifiers:` at base commit `72190e4` into the test) with
    Transfer inserted right after Users, and nothing else changed.
  - `testTransferInsertedOnceIntoSavedLayout`: a toolbar whose items lack Transfer gets it after Users
    on setup. With the preference key set, it is not inserted again. Use a volatile `NSArgumentDomain`
    override for the key, never the real prefs.
  - `testPostgresEnablement`: only Database and Console validate YES.
  - `testSwitchingTabsSwapsToolbarState`: MySQL tab ↔ Postgres tab in one window. The window's toolbar
    identifier stays `TableWindowToolbar`, and Content validates YES on a connected MySQL tab with a
    table selected (use an `SPDatabaseDocument` with a stubbed selection if a live MySQL isn't
    available; otherwise assert only the Postgres side and note it) and NO on the Postgres tab.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite and the app build.**
- [ ] **Step 5: Commit.**

### Task 4: Connect into the current tab; drag and close

**Files:**
- Modify: `Source/Postgres/SPPostgresConnectionScreenAdapter.h/.m`; `Source/SPConnectionController.m`
  (host method only, additive)
- Test: `PostgresTests/SPPostgresConnectionScreenAdapterTests.m`, `PostgresTests/SPWindowTabsTests.m`

**Interfaces:**
- Produces on `SPPostgresConnectionScreenHost`: `- (void)postgresReplaceConnectionTabWithDocument:(SPPostgresDocument *)document;`
  `SPConnectionController` implements it as
  `[[dbDocument parentWindowController] replaceTabDocument:dbDocument withDocument:document]`.
- On a successful connect the adapter creates `SPPostgresDocument` and calls the host method; it never
  opens a window. On failure: the stage-1 error sheet, and the tab is unchanged.
- Tab drag between windows and to a new window works for Postgres tabs. The window controller's
  drag/drop code moves the protocol document and calls `setParentWindowController:` / `setParentWindow:`
  on it.
- Window close: `windowShouldClose:` asks every tab document `parentTabShouldClose`; Postgres tabs
  always return YES. Every Postgres tab gets `parentTabDidClose`.

- [ ] **Step 1: Write failing tests.**
  - `testConnectReplacesConnectionTab`: live connect to 55418 from a form in a window controller. The
    tab at the same index now holds an `SPPostgresDocument`, there are no extra windows, and
    `selectedDocument` is the Postgres document.
  - `testFailedConnectLeavesTab`: wrong password → the same `SPDatabaseDocument` is still at that
    index and an error was presented.
  - `testMoveTabToNewWindowKeepsConnection`: a Postgres tab moved with `moveSelectedTabInNewWindow:`
    is in the new window controller's `tabDocuments`, `SELECT 1` still works, and its label is unchanged.
  - `testClosingWindowDisconnectsPostgresTabs`: a window with one MySQL connection-screen tab and one
    Postgres tab. After close, the Postgres connection `isConnected` is NO within 2 s.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite and the app build. Check that `Favorites.plist`'s shasum is unchanged.**
- [ ] **Step 5: Commit.**
- [ ] **Step 6 (controller): Visual and MySQL regression check.**
  1. Connection screen and a MySQL-only window look as before, apart from the Transfer item.
  2. Connect to the PG18 test server from a MySQL window's connection tab: it opens as a tab.
  3. The toolbar greys out correctly when switching between a MySQL tab and the Postgres tab.
  4. Drag the Postgres tab out to a new window.
  5. Close the window.
