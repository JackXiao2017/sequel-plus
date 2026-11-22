# Foreign key value picker (MySQL and PostgreSQL Content views)

Sequel Plus 2.0.5. Status: design, awaiting approval.

## Intent

When you edit a cell whose column is a foreign key, you shouldn't have to know or look up the referenced key. As in DataGrip, editing the cell opens a pop-up that lists rows of the referenced table. You narrow the list with a search box and, if needed, extra column conditions, then choose a row; its key goes into the cell. This works the same in the MySQL and the PostgreSQL Content views.

## Goals

- Editing a foreign-key cell in the Content view (MySQL and PostgreSQL) opens the picker, anchored under the cell, the way date and time cells open the date / time picker today.
- The list shows rows of the referenced table: the referenced (key) column first and in bold, then the columns chosen in the ⚙︎ menu, in table order.
- **Search box** (focused on open): matches what you type, case-insensitively as "contains", against every shown column; matches are highlighted. The list updates as you type (debounced).
- **+ Condition** adds rows of column ▾ / operator ▾ / value / −. All conditions and the search must match (AND). Operators depend on the column's type:
  - text: contains, starts with, =, ≠
  - numbers and dates/times: =, ≠, <, ≤, >, ≥, between
  - every column: is NULL, is not NULL
- **⚙︎ menu**: "Show columns" with a tick per column of the referenced table (the key column always ticked and disabled), then Show All Columns and Reset to Default. Changes apply at once and the menu stays open.
- **The ⚙︎ choice is remembered** per database kind (MySQL / PostgreSQL), server (host and port), database, schema (PostgreSQL) and referenced table. It applies whichever foreign key opens that table. The default, for a table never set, is all columns. A remembered column the table no longer has is skipped.
- Rows load 200 at a time, ordered by the key column; scrolling to the end (or "Load more") fetches the next 200. The footer shows how many are shown, e.g. "200 shown, more…" or "3 matches".
- The cell's current value is tinted in the list when it's among the loaded rows.
- **Keyboard:** ↑/↓ move the selection, Return or double-click chooses, Escape cancels.
- **Choose** puts the chosen key, as text, into the cell's in-place editor; the cell stays in editing until Return saves it or Escape drops it, exactly as after the date picker. Saving, undo, and errors behave as for any cell edit.
- **NULL** (only when the column allows NULL) puts the NULL placeholder into the editor the same way.
- **Type a value…** closes the picker and opens the normal in-cell editor on the current value.
- **Cancel** (or clicking outside) leaves the cell as it was, not being edited.
- With "edit in sheet" mode on, the field editor sheet of a foreign-key cell gets a **Choose…** button that opens the same picker; its result replaces the sheet's text.

## Non-goals

- Foreign keys over more than one column: the picker can only set one column, so those cells keep the normal in-cell editor.
- The Custom Query result grids and any other grid: Content view only.
- Remembering the search or conditions: each time the picker opens they start empty.
- Choosing several rows, or creating a row in the referenced table from the picker.
- Showing columns of other tables (joins) in the list.

## Anti-goals (would make it a failure even if it works)

- Anything MySQL did before stops working or behaves differently for a cell that isn't a foreign key (memory rule: never break MySQL features).
- The picker blocks the window or beachballs on a big referenced table: all queries run off the main thread and can be cancelled by closing the picker or typing again.
- Tests write to the real preferences, the login keychain or the general pasteboard (memory rule).
- The picker ever runs anything but SELECT on the referenced table.

## Constraints

- Objective-C, manual retain/release, as the surrounding Content view code. macOS 12+ (deployment target), arm64.
- The shared date / time picker (`Source/Postgres/SPPostgresDateTimePicker.{h,m}`) is already used by both Content views. It is the model for opening a popover on a cell and handing its value to the in-place editor (`continueEditingColumn:row:ofTableView:withText:` on MySQL; the `pickerHandoff` path on PostgreSQL).
- Foreign keys are already known to both views:
  - MySQL: `SPTableContent` puts `foreignkeyreference` (`table`, `column`) on a column from `[tableDataInstance getConstraints]`, which also carries the full `columns` / `ref_columns` lists, so single-column keys can be told apart.
  - PostgreSQL: `SPPostgresTableData -foreignKeyReferences:` returns column → `schema`, `table`, `column`. Its query (pg_constraint, `conkey[1]`) must also say whether the key has more than one column (e.g. `array_length(con.conkey, 1)`).
- Values must always be bound or quoted for their engine: backtick-quoted identifiers and escaped strings on MySQL (SPMySQL), `quote_ident`/parameters on PostgreSQL.
- Search compares text: on PostgreSQL `col::text ILIKE $n`; on MySQL `CAST(col AS CHAR) LIKE ?` (case-insensitive by collation). LIKE wildcards in what's typed are escaped.
- Preferences used by the store must be injectable (both views already take a defaults object for tests); tests use a throwaway suite.

## Approaches

1. **One shared picker with a small adapter per database (chosen).** One picker class owns everything you see. It asks an adapter protocol to "list the referenced table's columns" and "fetch up to N rows after offset M matching this search and these conditions, with these columns". A MySQL adapter and a PostgreSQL adapter build the SQL and run it on the view's existing connection. One column-settings store. The look and behaviour are the same in both and fixes land once; the cost is one new shared piece and a small hook in each view.
2. Two separate pickers, each built on its view's own filter code. Reuses the filter SQL building, but the window is built twice and the two drift apart. Rejected: more code, no visible gain.
3. Load the whole referenced table once and filter in memory. Simplest, but slow and memory-hungry on large tables. Rejected.

## Design (chosen approach)

### Pieces

- **`SPForeignKeyPicker`** (new, shared, `Source/`): the popover and its view — search field, condition rows, results table, ⚙︎ menu, footer with NULL / Type a value… / Cancel / Choose. Created with the adapter, the reference (schema, table, key column), the current value, whether NULL is allowed, and a completion block receiving one of: a chosen value, NULL, "type a value", or cancel. Shown relative to a cell's rect, like the date picker.
- **`SPForeignKeyPickerDataSource`** (protocol): `columnsOfReferencedTable` (name and a type group: text / number / date-time / other) and `rowsMatching:conditions:columns:offset:limit:completion:` (asynchronous; returns rows of text or NULL, or an error) plus `cancel`. Conditions are plain value objects (column, operator, value(s)), never SQL.
- **`SPMySQLForeignKeyPickerSource`** and **`SPPostgresForeignKeyPickerSource`** (new): build and run the SELECT on a background queue on the view's connection, and map types to the type groups.
- **`SPForeignKeyPickerSettings`** (new): reads and writes the shown columns per key (kind, host:port, database, schema, table) in the injected defaults, under one dictionary key.
- **Content view hooks:** in each view's `shouldEditTableColumn:`, before the date picker check: a cell that can be edited in place and whose column is a single-column foreign key opens the picker and returns NO. Its completion hands the text to the in-place editor through the same handoff the date picker uses. The field editor sheets (MySQL `SPFieldEditorController`, PostgreSQL `SPPostgresFieldEditorSheet`) get the Choose… button when given a reference.

### Calls made after the builder check (author's calls, not the user's)

- **Connection.** PostgreSQL: the adapter's fetches go through the tab's `SPPostgresTaskRunner`, the only thing allowed to use the tab's connection (one statement at a time, on its background queue). MySQL: the adapter queries the view's `SPMySQLConnection` from a background queue, as the view's own background loads do (SPMySQL serialises access). No second connection. A fetch made stale by more typing isn't killed: each fetch is at most 200 rows, so it's left to finish and its result is dropped. Closing the picker drops any pending result the same way.
- **Starting an edit.** The picker opens wherever the date picker opens today: `shouldEditTableColumn:` is reached by a double-click and by keyboard-started edits alike, and the handoff into the in-place editor is the date picker's. Its known limits are inherited, not fixed here. Pasting, multi-row edits and other paths that don't go through `shouldEditTableColumn:` are unchanged.
- **Condition values** are not validated in the picker: they're sent as parameters (PostgreSQL: untyped, so the server infers the column's type; MySQL: escaped string literals), and a value the server rejects shows its message in the list area.
- **Ordering and duplicates.** Rows are ordered by the key column, then by the table's primary key columns when it has them (MySQL allows a foreign key to reference a non-unique index). Duplicate key values are shown as they are.
- **Key types.** The key is handed over as the text the grid shows. A foreign key whose column is binary (MySQL BINARY / VARBINARY / BLOB, PostgreSQL bytea) doesn't open the picker; it keeps the in-cell editor. Other types (uuid, enum, numbers, dates) go through as text.
- **Test servers.** PostgreSQL adapter tests use the existing PG12 / PG18 test servers (`Scripts/pg-test-servers.sh`). MySQL adapter tests use the existing throwaway MySQL test container `sp-mysql8` (127.0.0.1:55438, as `PostgresTests/SPMySQLTransferTests.m` does, skipping when it isn't running), each in its own test database dropped afterwards. Never the user's `encompass_2-mysql-1`.

### Decided by the user after the builder check

- **A switch to turn it off.** Preferences ▸ Tables gets a checkbox, **Open the value picker when editing a foreign key**, on by default, shared by MySQL and PostgreSQL (one new defaults key). When it's off, foreign-key cells edit exactly as before this change, and the field editor sheet doesn't show Choose…. Both views follow a change at once, as they do for other table preferences.
- **MySQL is tested against a real server** (the `sp-mysql8` test container above), not only by checking the SQL text.

### Errors and edge cases

- The referenced table can't be read (no privilege, gone): the list area shows the server's message; NULL, Type a value… and Cancel still work.
- A query fails mid-typing: the message replaces the list until the next successful fetch.
- The view changes table, reloads, or starts a task while the picker is open: the picker's result is dropped, as the date picker's is.
- A row whose key is NULL can't be chosen.

## Left to the builder

- Exact pixel layout, sizes, and debounce interval (around 250 ms).
- How "between" takes its two values.
- Whether "Load more" is a button, automatic on scroll, or both.
- Where the new files sit (`Source/` vs `Source/Postgres/`) and their exact names, as long as the shared picker isn't PostgreSQL-only.
- Test shape, as long as both adapters' SQL is covered against the test servers (`sp-mysql8`, and the PG12 / PG18 test servers) and the store and the preference are tested with a throwaway defaults suite.

## Mockups

`.superpowers/brainstorm/68875-1794891541/content/`: `fk-picker-v2.html` (⚙︎ menu and remembered columns) and `fk-picker-b-multi.html` (option "A + B", the chosen one).
