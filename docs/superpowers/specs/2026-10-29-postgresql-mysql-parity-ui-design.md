# PostgreSQL tabs at MySQL parity: background loading, button bars, Query tab

Date: 2026-10-29
Status: draft for owner approval (builder check done)
Builds on: docs/superpowers/specs/2026-10-27-postgresql-support-design.md and
2026-10-27-postgresql-tabs-design.md (Stages 1–7b are done; branch `postgres-stage7`)

## Intent and why

The owner uses Postgres tabs next to MySQL tabs in the same windows. Two things make Postgres tabs feel worse:

1. **Freezes.** Every Postgres load runs on the main thread, so on a big table or a slow server the whole window
   locks until the server answers. The owner notices the freeze, not just the missing tab spinner.
2. **Missing controls.** The button bars under the Content table, under the table list and in the Query tab
   have fewer buttons and functions than MySQL's. The owner wants them cloned from MySQL: **all icons and
   functions need to match MySQL**.

Success: a Postgres tab looks and behaves like a MySQL tab in these places. The window never freezes on a load,
the tab spinner turns while one runs, and every MySQL button is there with the same icon, tooltip, shortcut,
position and behaviour, except where PostgreSQL has no equivalent (listed below).

## Goals

- Loading in the background with MySQL's tab spinner, loading display and Cancel.
- MySQL's bar under the table list, with its info pane and gear menu.
- MySQL's bar under the Content table.
- MySQL's Query tab: both bars, the editor features behind the gear menu, favorites, history.
- Editable query results, as MySQL's.

## Non-goals

- Changing anything in MySQL tabs.
- Features MySQL doesn't have in these places.
- XML export (Postgres export has none; menus leave the XML item out).
- MySQL-only concepts with no Postgres meaning: table encoding, collation and engine in Add Table; MySQL's
  Check/Repair/Optimize-style table maintenance (not in the gear menu MySQL shows here anyway).

## Anti-goals (a failure even if the feature works)

- **Breaking or changing any existing MySQL feature.** This is the owner's standing anti-goal. Shared classes
  (`SPTextView`, `SPTableView`, `SPWindowController`, the field editor sheet, query favorites/history managers)
  may be reused, but MySQL's behaviour through them must not change; MySQL's tests and toolbar parity tests stay
  green.
- Writing `~/Library/Application Support/Sequel Pro/Data/Favorites.plist` from Postgres code (the owner's
  original Sequel Pro 1.1.2 app reads it). Postgres query favorites and history must not land in MySQL's
  favorites or history stores.
- Tests persisting into real preferences or the login keychain.
- Two queries at once on one Postgres connection (libpq allows one at a time); a UI that lets a second load
  start while one runs.
- A window that still freezes on a load from the tabs this design covers.

## Constraints

- Objective-C, mostly MRC in app sources and `Frameworks/PostgresKit`; ARC in the "Postgres Tests" target.
- Postgres views are built in code (no xibs), as all Postgres views so far.
- Images: the app's own (`Resources/Images/button_*`), the same names MySQL's xib uses.
- Tests run against the Docker PG12/PG18 servers (`Scripts/pg-test-servers.sh up`).
- CASCADE only in Transfer's Empty mode; DROP DATABASE never in app code (unchanged). This design adds
  `DROP TABLE` (Remove Table) and `TRUNCATE` (Truncate Table), both as MySQL's: confirmation alert, no CASCADE
  unless the owner later asks.
- Each stage below lands on its own, with its own plan, review and test run, MySQL untouched.

## Stage 8: background loading, tab spinner, Cancel (owner: "same as MySQL, show loading and allow cancel")

What runs in the background: every load a Postgres tab does on the main thread today. The table list (sidebar,
including schema/database switches), Content rows and counts, Structure, Relations, Triggers, Table Info, the
Query tab's runs, and the extension/sequence lists.

Behaviour, as MySQL's task mechanism (`-[SPDatabaseDocument startTaskWithDescription:]`,
`enableTaskCancellationWithTitle:…`, `endTask`):

- While a load runs, the document's `isProcessing` is YES, so the tab's existing spinner (bound in
  `SPWindowController`) turns. It stops when the load ends: success, failure or cancel.
- The tab shows MySQL's loading display: the content area dims with the task description ("Loading table
  data…", "Running query…", etc., MySQL's strings where MySQL has one) and, as MySQL, a Cancel/Stop button that
  appears after MySQL's delay.
- While a load runs, the tab's controls that would start another query on that connection are disabled, as
  MySQL disables its interface during a task. The window stays responsive: moving, resizing, switching tabs and
  windows; other tabs keep working.
- Cancel sends a server-side cancel (PQcancel; PostgresKit already has a cancel token from Stage 6) and leaves
  the view as it was before the load (the previous rows, the previous result). A cancelled load is not an
  error alert.
- Closing the tab during a load cancels it and waits for nothing on the main thread.
- Short writes (saving a cell, deleting rows, rename, comment) stay synchronous, as today.

## Stage 9: the table list bar and its info pane

Clone MySQL's sidebar bar (DBView.xib, under the table list): 23 pt bar, in MySQL's order and icons:

| Button | Image | Tooltip | Does |
|---|---|---|---|
| Add | `button_add` | Add new table | Add Table sheet (below) |
| Info pane | `button_pane_hide` / `button_pane_show` | Toggle the visibility of the Information panel | Shows/hides the info pane |
| Gear | `button_action` (pull-down) | — | Menu below |
| Refresh | `button_refresh` | Refresh table list | Reloads the list (background) |

plus MySQL's split-view handle (`button_bar_handle`) at the right.

**Info pane:** a small pane under the table list, as MySQL's "Table Information" pane, for the selected table
or view: type, rows (estimate, as the Table Info tab), sizes, comment, and other facts the Table Info tab
already reads. Its shown/hidden state follows Shared settings.

**Gear menu**, MySQL's items and order, acting on the selected table(s)/view(s):

- Rename Table… and Duplicate Table… (exist today in the right-click menu; reuse them).
- Truncate Table (new): `TRUNCATE` of the selected table(s) after MySQL's confirmation alert.
- Remove Table (new): `DROP TABLE` / `DROP VIEW` of the selected item(s) after MySQL's confirmation alert.
- Open Table in New Tab (new), with the ⌥ alternate Open Table in New Window: a new Postgres tab/window on the
  same favorite, database and schema, with that table selected.
- Export ▸ As SQL dump… / As CSV file… (new here): opens the existing Postgres Export with the selection.
- Show Create Table Syntax… / Copy Create Table Syntax (new): the existing `SPPostgresCreateStatement` output.

With a sequence or extension selected, the gear menu shows that kind's items (Add/Delete Sequence,
Install/Drop Extension), the same as the right-click menu does today. The right-click menu on tables gains the
same new items, as MySQL's does.

**Add Table** (new): a sheet as MySQL's, asking only for the name (encoding/collation/engine don't apply). It
creates the table in the selected schema with one column, PostgreSQL's equivalent of MySQL's
`id INT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT`:
`CREATE TABLE schema.name (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY)`, then selects it and shows
Structure, as MySQL does.

## Stage 10: the Content bar

Clone MySQL's Content bar (DBView.xib, under the data table), same order, icons, tooltips and shortcuts:

Left: Add row (⌥⌘A), Delete row(s) (⌫), Duplicate row (⌘D, new), Refresh (⌘R), Edit mode toggle (new),
Filter show/hide (new). Middle: the row count line. Right: Previous page, Jump to page (⌘J, new), Next page.

- **Duplicate row:** inserts a copy of the selected row with column defaults for identity/serial and generated
  columns (as MySQL leaves the auto-increment key out), then shows it.
- **Edit mode toggle** (`button_edit_mode` / `button_edit_mode_selected`): MySQL's "Toggle between editing
  simple text cells as a spreadsheet or in pop-up sheets": when on, double-click opens the field editor sheet
  instead of inline editing. Same preference as MySQL's toggle (Shared settings).
- **Filter show/hide** (`button_filter` / `button_filter_active`): shows or hides the existing Postgres filter
  bar above the table; the active image when a filter is applied, as MySQL.
- **Jump to page** (`button_pagination`): MySQL's pagination popover (page number field, Go, and the rows per
  page settings MySQL's popover offers).

## Stage 11: the Query tab

Clone MySQL's Query tab bars and the features behind them. Owner: the editor and results get MySQL's features
too (colouring, completion, editable results).

**Bar under the editor**, MySQL's: gear menu, Query Favorites pop-up, Query History pop-up, and the Run Current
pop-up button (Run Current Query ⌘R, Run All Queries ⌥⌘R, Switch Default — replacing today's two buttons; the
existing "QueryPrimaryControlRunsAll" behaviour is kept).

**Gear menu**, MySQL's items: Previous/Next Query from History, History Replaces Editor Content, Favorite
Replaces Editor Content, Shift Right/Left, Comment Line, Comment Current Query, Completion List ▸ (database
names, table and view names, column names of the current table), Editor Font…, Indent New Lines, Auto-pair
Characters, Auto-uppercase Keywords, Auto-completion, Update Help while typing.

**Editor features**, as MySQL's editor: syntax colouring (PostgreSQL keywords, types and functions; quoted
identifiers `"…"`, dollar-quoted strings `$tag$…$tag$`, `--` and `/* */` comments), auto-pair, auto-uppercase
keywords, indent new lines, completion of schemas, tables, views and columns from the current database, the
query editor font and colour preferences MySQL's editor uses. "Update Help while typing" shows PostgreSQL's
documentation for the keyword at the cursor, in MySQL's help window, as the keyword's title and a clickable
link into postgresql.org's docs for the connected server's major version (`https://www.postgresql.org/docs/<major>/…`;
a keyword with no mapped page links to the docs' SQL commands index). No web view, no bundled copy, nothing
fetched while typing.

**Favorites and history:** MySQL's menus and manager (save query / save all, edit favorites, search; copy,
save, clear history). Stored separately from MySQL's: nothing written for Postgres is read by MySQL tabs or the
1.1.2 app, and vice versa.

**Bar under the results**, MySQL's: query info pane toggle (`button_pane_hide`), gear with Export Result ▸ As
CSV file…, edit mode toggle, and MySQL's status text ("N rows in set", "N rows affected", time taken).

**Query info pane:** as MySQL's, lists each statement's error or affected-row message of the last run.

Runs go through Stage 8's background mechanism (spinner, Cancel).

## Stage 12: editable query results

As MySQL's: a query result is editable when all its columns come from one table that has a primary key (or
the conditions MySQL uses; the builder matches MySQL's rule as closely as PostgreSQL's result metadata allows,
`PQftable`/`PQftablecol`). Then cells can be edited inline or in the field editor sheet (per the edit mode
toggle), saved with an UPDATE by key, as the Content tab saves. Otherwise the results stay read-only, with
MySQL's explanation where MySQL shows one.

## Shared settings

The app has the bundle id `com.sequelpro.SequelPro`, the same as the 1.1.2 app, so MySQL tabs, Postgres tabs and
1.1.2 share one preferences store. **Owner: share the editor and paging settings with MySQL.** Every control
cloned from MySQL reads and writes the same preference key MySQL's control does: the Query gear toggles (Indent
New Lines, Auto-pair Characters, Auto-uppercase Keywords, Auto-completion, Update Help while typing, History /
Favorite Replaces Editor Content), Editor Font…, Switch Default (`QueryPrimaryControlRunsAll`), rows per page in
the Jump to page popover (`SPLimitResults` / `SPLimitResultsValue`), the edit mode toggle, and the info pane's
shown/hidden state (wherever MySQL keeps it; if MySQL doesn't persist it, neither does Postgres). Flipping one in a
Postgres tab changes it for MySQL tabs too, exactly as flipping it in a MySQL tab does today. The exceptions are
favorites and history, which stay separate (anti-goals). Tests use a scratch defaults domain, never the real one.

## Decisions

Owner (in chat, 2026-10-29):
- Editor and paging settings are shared with MySQL (see Shared settings).
- The freeze is the problem; loading goes to the background, with MySQL's loading display and Cancel.
- The mockups of the Content and table-list bars are right (the blue-outlined new buttons above).
- The Query tab gets MySQL's bars and the features behind them: colouring, completion, editable results.
- Order of work: Stage 8 background loading; 9 table-list bar and info pane; 10 Content bar; 11 Query tab;
  12 editable query results.

Builder's calls (mine, approved with this document unless the owner objects):
- Add Table creates `id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY` and asks only for a name.
- Postgres favorites and history are stored apart from MySQL's.
- Help while typing shows a title and a link to the server's major version of the postgresql.org docs in MySQL's
  help window; no web view.
- Short writes stay synchronous.
- Truncate and Remove never use CASCADE; a dependency error shows the server's message.

## Left to the builder

- How background work is structured (one serial queue per connection, a reused `SPPostgresBackgroundJob`, or
  similar), as long as the anti-goals hold.
- Whether the editor reuses `SPTextView` with a Postgres token set or is a Postgres subclass/sibling, as long as
  MySQL's editor behaviour doesn't change.
- Where Postgres favorites and history are stored.
- Exact layout numbers, taken from DBView.xib.
