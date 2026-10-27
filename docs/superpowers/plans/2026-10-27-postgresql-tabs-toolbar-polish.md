# PostgreSQL tabs: toolbar parity and flicker-free tab switching

Date: 2026-10-27. Branch: `postgres-tabs`. Owner's request (verbatim):
"use the same tool icons in postgres with mysql, also the size of database selector, don't make the UI flash when changing the tabs between mysql and postgres"

## Goal

Switching between a MySQL tab and a Postgres tab in one window must look like switching between two
MySQL tabs:

- the same toolbar icons (artwork, size, position);
- a database picker of the same size and style;
- no visible flash or jump.

Items unsupported on Postgres stay disabled. That is the owner's earlier requirement, so disabled items
look exactly as MySQL's disabled items do.

## Known facts (start here)

- Each tab document builds its own `NSToolbar` (identifier `TableWindowToolbar`), and
  `didBecomeActiveTabInWindow` installs it with `[parentWindow setToolbar:]`. See
  `-[SPDatabaseDocument didBecomeActiveTabInWindow]` and `-[SPPostgresDocument didBecomeActiveTabInWindow]`.
- MySQL items: `-[SPDatabaseDocument toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:]`
  (Source/SPDatabaseDocument.m ~4078). The database picker is `chooseDatabaseButton` from DBView.xib.
  Its width follows the MySQL left pane: `chooseDatabaseToolbarItem` min/max is set to `leftPaneWidth`
  (~5958–5972), and the left pane is an `SPSplitView` with autosave `DBViewSplitter`. The history
  control is `historyControl` from the nib, sized with `sizeToFit`.
- Postgres items: `-[SPPostgresDocument toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:]`
  (Source/Postgres/SPPostgresDocument.m ~704). Its picker is `databasePopup`, built in code, and its
  width follows the Postgres left pane (`_updateDatabaseToolbarItemWidth`, split view autosave
  `PGViewSplitter`). Its history control is built in code.
- Images on both sides go through `SPCompactToolbarImage` (24 pt).

## Required outcome

1. **Capture first.** Build a way to render the window, toolbar included, for:
   (a) a MySQL connection-screen tab,
   (b) a connected Postgres tab (test server sp-pg18 on 55418, pgkit_test/pgkit),
   (c) a second MySQL tab,
   all in one window. Save PNGs to
   `/private/tmp/claude-501/-Users-Jack-workspace-ios-sequelpro-forked/31936e71-c799-4bbd-9746-97cf20b2cd48/scratchpad/toolbar-parity/`:
   `before-mysql.png`, `before-postgres.png`, then `after-*.png`.
   Use `CGWindowListCreateImage` for the window from inside an app-hosted test; it captures the real
   window, toolbar included. Keep the capture as a test only if it adds value; otherwise put it in a
   test method that skips unless the env var `SP_CAPTURE_TOOLBAR=1` is set. List every visual
   difference you find.
2. **Icons.** Postgres toolbar items use exactly the same images, labels, sizes and item kinds as
   MySQL's for every identifier. This includes the Console item's show/hide image state and the history
   control, which must be the same control type, segment images, style and `sizeToFit`. Prefer one
   shared factory that both documents call, so the two can't drift. If you touch MySQL's item
   construction to share code, MySQL's items must stay identical (assert in a test).
3. **Database picker size.** On both engines the picker has the same width and style at all times in
   one window. Make the Postgres left pane use the same width source as MySQL's: one shared left-pane
   width, e.g. the Postgres split view uses MySQL's `DBViewSplitter` autosave name. Then both pickers
   are always the same width. Also match the popup style (bezel, control size, font) to
   `chooseDatabaseButton`.
4. **No flash.** Find what visibly changes during a MySQL ↔ Postgres switch and remove it, so it is no
   worse than MySQL ↔ MySQL. First measure MySQL ↔ MySQL as the baseline; if that also flashes, say so.
   - Likely causes: toolbar item size differences causing re-layout; `setToolbar:` re-creating item
     views; the title/titlebar label re-layout; the tab content view swap drawing an intermediate frame.
   - Candidate techniques: identical item sizes, so no re-layout; grouping the swap in one display
     update (`[window disableScreenUpdatesUntilFlush]`, or `NSAnimationContext`/`CATransaction` with
     animations disabled); keeping `setVisible:` untouched when it doesn't change.
   - Verify by capturing frames during a switch where practical (several captures in a tight loop
     around the switch), or explain the evidence you used.
   - MySQL ↔ MySQL switching must behave exactly as before.

## Constraints (binding)

- Never break MySQL. MySQL tabs' toolbar items, picker and switching behave as before. The one
  exception: a shared left-pane width means a MySQL window's left pane can follow a width the user set
  on a Postgres tab, which is acceptable and intended.
- The owner's saved toolbar layout and real prefs: tests never write them. `PostgresTests/SPTestPrefsGuard.m`
  already guards toolbar autosave and split-view autosave; keep it effective. If you change autosave
  names, make sure the guard still covers them.
- MRC in app sources; ARC in tests; files only via `ruby Scripts/pg-xcodeproj.rb add-app|add-test`.
- Do not launch the GUI app interactively. The app-hosted test run may show windows briefly; that's fine.
- Never touch the owner's untracked `start_clause.sh`; stage only your own files.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Verification

- `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64`
  passes. Run `bash Scripts/pg-test-servers.sh up` first if needed.
- App build succeeds.
- Before/after PNGs exist in the scratchpad folder above, and the report lists the remaining differences
  (ideally none apart from enabled/disabled state and the left-panel contents).
- Real prefs toolbar config (`defaults read com.sequelpro.SequelPro "NSToolbar Configuration TableWindowToolbar"`)
  and Favorites.plist shasum are unchanged before/after.
