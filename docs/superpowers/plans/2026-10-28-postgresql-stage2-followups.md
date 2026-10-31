# PostgreSQL Stage 2 (Content, Query, History, Duplicate) — follow-ups

Deferred findings from Stage 2's per-task and final reviews (none block day-to-day use).

## Data layer (Task 1)
- Sort / `=` on json or point columns gives the raw server error; no tiebreak for tables/views without a PK (ctid); failed metadata load isn't cached.
- ACTIVE/UNKNOWN transaction status falls to BEGIN/COMMIT (refusing would be stricter); transactionStatus has the same race window as isConnected.
- Savepoint path defers deferred-constraint errors to the user's own COMMIT.
- Domains over constrained types still cast to the domain (possible explicit-cast truncation).
- PGPostgresError getters are assign-style (dangling if retained across errors); key dedupe vs nondeterministic collations.

## Content view (Task 2)
- Every cell commit reloads the page plus 2 COUNT(*) on the main thread (slow on big tables; selection may move); inside a user transaction each load now also costs 2 savepoint round trips.
- A literal equal to the NULL placeholder becomes NULL (same as MySQL); a rejected filter's controls stay showing; addRow increments matchingRowCount under an active filter.
- Confirmation completion: a late second call after the pool drains would be a use-after-free (header says "ignored").
- Tests: no successful retry after a failed first load; broken_view fixture cleanup unverified.

## Query view (Task 3)
- Database switch rebuilds the Query controller (loses undo, results, status).
- Results grid has no ⌘C copy (MySQL uses SPCopyTable).
- DETAIL/HINT only visible in the status tooltip (one-line field).
- A non-body `begin atomic` would swallow the rest of the script (contrived).
- Refresh classifier misses SELECT … INTO and DDL inside DO blocks (as MySQL's does); BEGIN/COMMIT/SET count as data changes (extra Content reloads).
- Any DDL resets Content's filter/sort/page even when the shown table wasn't touched (e.g. CREATE INDEX elsewhere).
- Catalog reloads after DDL (sidebar, database popup, column metadata) run without a savepoint inside the user's open transaction — a rare failure would abort it (same exposure as Stage 1's schema reload).

## History and Duplicate Table (Task 4)
- History de-dupes only against the current entry; back/forward segments have no pop-up entry menus; restore brings back selection + pane only (no sort/page/filter).
- A switch with a history entry loads Content twice (default table, then the entry's).
- Customize-palette item takes the single history control instance (same pattern as databasePopup).
- Duplicate copies columns, indexes, constraints, defaults and the table comment, but not foreign keys (MySQL does), triggers, policies, grants or UNLOGGED; runs synchronously on the main thread (as MySQL).
- A copy made inside a user transaction stays in the sidebar after rollback until the schema reloads.
- Sheet disables Duplicate on names over 63 bytes without saying why (tooltip/hint).
- Untested (currently unreachable): failed post-create lookup error; abandoned history move when no connector starts.

## Resolved
- Flaky `SPPostgresConnectionScreenAdapterTests testConnectReplacesConnectionTab`: the Keychain-prompt hang fixed by the test prefs guard (b46e7b3).
