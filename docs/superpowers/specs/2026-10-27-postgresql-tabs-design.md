# PostgreSQL connections as tabs in the MySQL windows: design amendment

Date: 2026-10-27
Status: approved by owner 2026-10-27 (in chat)
Amends: docs/superpowers/specs/2026-10-27-postgresql-support-design.md

## What changes and why

Stage 1 opened every PostgreSQL connection in a separate PostgreSQL window. The owner now wants
PostgreSQL connections to open **in the same windows as MySQL connections, as tabs**, next to MySQL
tabs. The window keeps **one toolbar** whose items are greyed out when they don't apply to the
active tab's engine.

Everything else in the base design still holds. That includes the anti-goal (never break MySQL),
the separate Postgres favorites store, the Postgres-specific feature set, and the left-panel order
(schema picker, then tables and views, then extensions at the end).

Owner-approved order of work:

1. This amendment: tabs in the same window (this document).
2. Content, Query and Table History for PostgreSQL (planned as stage 2).
3. Structure, Relations, Triggers and Table Info for PostgreSQL (planned as stage 3).

Each one is built as part of the Postgres tab.

## Decisions (owner)

- Postgres connections are tabs in the MySQL windows. There is no separate Postgres window any more.
- One toolbar per window. Items that the active tab's engine doesn't support are disabled.

## Decisions (builder's calls, approved with the proposal)

- **Tab document, not MySQL changes.**
  - A new `SPPostgresDocument` represents a Postgres tab. It owns the connector, connection,
    catalog, sidebar, console logger and database picker, which are the pieces of today's
    `SPPostgresWindowController` without the window.
  - `SPDatabaseDocument`'s behaviour is untouched.
  - `SPWindowController` talks to any tab through a small protocol, `SPWindowTabDocument`.
- **MySQL-only code keeps seeing MySQL documents only.**
  - `-[SPWindowController selectedTableDocument]` and `-[SPAppController frontDocument]` keep
    their `SPDatabaseDocument *` type. They return **nil while a Postgres tab is active**.
  - Every MySQL-only feature (menus, navigator, process list, server variables, bundles, console
    filters) then behaves as it does with no connection, and does not crash.
  - A new `-selectedDocument` (returning `id <SPWindowTabDocument>`) serves generic tab handling.
- **Menu forwarding.**
  - The window controller forwards first-responder actions to the active tab document only if
    that document responds to them.
  - `SPPostgresDocument` implements `validateMenuItem:` / `validateToolbarItem:` to disable what it
    doesn't support.
- **One toolbar.**
  - Every tab installs a toolbar with the same identifier (`TableWindowToolbar`) and the same item
    identifiers, so the user's saved toolbar configuration applies to both.
  - The MySQL toolbar gains one disabled Transfer item, its only toolbar change; Transfer is
    PostgreSQL-only.
  - The Postgres toolbar serves every MySQL item identifier and disables the ones it doesn't support yet.
  - Users is shared: MySQL's User Manager on MySQL tabs, Postgres roles on Postgres tabs (stage 4).
- **Connecting from the connection screen.**
  - A successful Postgres connect **replaces the connecting tab**: its MySQL connection document is
    removed from that tab position and the Postgres document is inserted at the same index and selected.
  - A failed connect leaves the tab exactly as it was.
- **Tab bar.** Postgres tabs use the same PSMTabBar style. The label is the favorite name (plus
  `/database` when other tabs need disambiguation, as MySQL does), and the tab colour is the
  favorite's colour. Dragging a Postgres tab to another window or a new window works as for MySQL.
- **Window title.** While a Postgres tab is active, the compact title shows
  `(PostgreSQL <version>) <favorite>/<database>[/<schema>.<table>]`, as the stage-1 window did.
- **Closing.** Closing a Postgres tab disconnects its connection and tunnel. Closing the window
  closes all its tabs.

## Non-goals of this amendment

- Content, Query, History, Structure, Relations, Triggers and Table Info behaviour (steps 2–3).
- Saving or restoring Postgres tabs in session restore and `.spf` files. *(Builder's call: later.)*

## Risks

`SPWindowController` sits under every MySQL tab. Every change there must be additive or behind
"is this tab a MySQL document" checks. Each task ends with MySQL regression checks: build, the
connection screen, and connected-window screenshots unchanged, plus tab switching, dragging and
closing with MySQL-only windows.
