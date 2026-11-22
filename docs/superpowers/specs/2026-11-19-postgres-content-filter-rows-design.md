# PostgreSQL Content: several filter conditions, with − and + rows like MySQL's

Status: design, 2026-11-19. Branch 2.0.5.

## Intent

In a PostgreSQL tab's **Content** view, the filter bar holds exactly one condition (column, comparison, value,
Filter). The owner wants to filter on several columns at once, with **−** and **+** on each row to remove or add a
condition, the way a MySQL tab's Content filter works. All conditions must match (AND).

## Goals

- The PostgreSQL filter area is a stack of condition rows, each `[column ▾] [comparison ▾] [value] [−] [+]`, drawn
  by the same AppKit control MySQL's filter uses (`NSRuleEditor`), so the two look and behave alike.
- Under the rows, MySQL's bar: **Reset** (clear icon, left), **Add Filter** and **Filter** (right), same titles,
  tooltips and ⌘⎋ for Reset as DBView.xib's.
- Applying runs one query whose WHERE joins every complete row with `AND`.
- Everything the single-row bar does today keeps working (see Constraints).

## Non-goals

- OR, "any of" / "all of" groups, nesting (owner chose AND only; rule editor runs in list mode, not compound).
- MySQL's per-row enable/disable checkboxes and its user-defined content filters (Content Filter Manager).
- Keeping a table's filter when switching to another table and back (PostgreSQL doesn't today; unchanged).
- Any change to MySQL's filter.

## Anti-goals (a failure even if it works)

- A value ever pasted into the SQL. Values stay parameters (`$n::<type>`), as today.
- Breaking today's single-condition paths: the foreign-key arrow ("show referenced rows" with `column = value`),
  the document opening a table with a start filter, `IN` lists, `IS NULL` / `IS NOT NULL` without a value.
- Rows hidden under the button bar (the MySQL bug fixed in 0465a600): the rows always sit above it.
- Tests writing the real preferences.

## Constraints (current behaviour that must hold)

Code: `Source/Postgres/SPPostgresContentController.{h,m}` (bar built in code, ~line 427; `_setFilterBarVisible:`,
`toggleFilterBar:`, `_showFilterInBar:`, `applyFilter:`, `_rebuildFilterBar`), `Source/Postgres/SPPostgresTableData.{h,m}`
(`SPPostgresFilter`, `whereClauseForFilter:values:error:`, `rowsWithFilter:…`, `countRowsWithFilter:`),
`Source/Postgres/SPPostgresDocument.m` (start filters at ~1566 and ~2950). Tests: `PostgresTests/SPPostgresContentBarTests.m`
and others with filter tests (31 test methods mention filter).

- Comparisons are PostgreSQL's list, unchanged: `=`, `≠`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `ILIKE`,
  `IS NULL`, `IS NOT NULL`, `IN`. Their SQL, casts and error messages are unchanged.
- A row whose comparison takes a value but whose value is empty is skipped (today: "an empty value means no filter").
  If no row is complete, the table loads unfiltered.
- Visibility: shown/hidden by the bottom bar's filter toggle, saved in `SPRuleFilterEditorLastVisibilityChoice`
  (shared with MySQL), hidden by default; hiding while a filter is applied reloads page 1 unfiltered, keeping sort.
  Hiding moves focus out of the filter to the grid.
- Shown by a click with no rows: one empty row is added, focused on its value (MySQL adds an empty row the same way).
- Return in a value field applies the filter. Applying goes to page 1 and keeps the sort; task text "Filtering table...".
- A start filter (foreign-key arrow, document) shows the filter area (preference unchanged) holding exactly that one
  row, and the first page is its rows. A start filter on a column the table lacks is dropped, as today.
- Switching tables rebuilds the column menus and empties the rows (today's `_rebuildFilterBar` clears the value).
- With no columns (nil table) the controls are disabled.

## Approaches considered

- **A. Grow the existing hand-built bar** into a stack of hand-built rows, each with − and +. Least risk to existing
  behaviour; looks like PostgreSQL's bar, not MySQL's.
- **B. MySQL's control: `NSRuleEditor` in list mode** with MySQL's Reset / Add Filter / Filter bar. Same look and
  feel as MySQL. MySQL's `SPRuleFilterController` can't be reused: it generates MySQL SQL, reads MySQL column
  types, loads ContentFilters.plist and talks to `SPTableContent`. Only the control, the layout and the behaviours carry over.
- **C. AND/OR groups (compound mode).** Rejected: owner chose AND only.

**Chosen: B** (owner's choice).

## Design

### Look and layout (like DBView.xib's Filter Rule Editor Container)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [id        ▾] [=        ▾] [ 42                              ]  (−) (+)  │  rows: NSRuleEditor in a
│ [status    ▾] [IN       ▾] [ open, held                      ]  (−) (+)  │  scroll view, 29 pt each
├──────────────────────────────────────────────────────────────────────────┤
│ (⌫Reset)                                        [Add Filter]  [Filter]   │  button bar, 23 pt (SPButtonBar)
└──────────────────────────────────────────────────────────────────────────┘
  grid …
```

- Filter area height = rows' height + the 31 pt the rows start above the area's bottom (8 pt gap over the 23 pt bar),
  capped at one third of the Content view's height; past that the rows scroll. The grid takes the rest.
  Hidden, the area takes 0 and the grid the whole height above the bottom bar. Never a negative frame height.
- Row height 29 (as DBView.xib). Controls small size, as MySQL's rule rows.
- The rows grow/shrink as rows are added/removed and as the Content view resizes.

### Behaviour

- **+** on a row inserts an empty row under it (column = that row's column, comparison `=`); **Add Filter** appends one.
  Focus goes to the new row's value field.
- **−** removes its row. Removing the last row clears the filter and, if one was applied, reloads page 1 unfiltered
  (as MySQL's #3071). The area stays shown (empty).
- **Reset** (⌘⎋ while the Content view is frontmost) removes all rows, adds one empty row, and reloads unfiltered if a
  filter was applied.
- **Filter** / Return in a value field: builds the conditions from the complete rows in order and loads page 1.
- Changing a row's comparison to IS NULL / IS NOT NULL disables (empties) its value field.
- The bottom bar's count text keeps today's wording for filtered results.

### Settled after the builder check (designer's calls, following today's bar and MySQL's)

- **Typed rows vs applied filter.** Two things: the rows as typed (live, in the rule editor) and the applied
  conditions (an array, set only by Filter / Return / Reset / removing the last row / a start filter / hiding).
  Paging, sorting, refresh, the count text and "if a filter was applied" all use the applied array, never the live rows
  (today: the `filter` ivar vs the field).
- **Hiding keeps the rows.** Hiding clears the applied array (reloading unfiltered if it was non-empty) but leaves the
  rows as typed; showing again shows them unapplied, with no query, as today's bar and MySQL's do. Only when there are
  no rows does showing add the one empty row.
- **A start filter replaces the rows** (same table or another) with its one row, applies it, and shows the area even
  if the preference says hidden (preference unchanged), as today.
- **Filter with no complete row** still loads page 1, unfiltered, and clears the applied array. Return applies from
  any value field, whatever the other rows hold.
- **Zero rows.** After − on the last row the area keeps the 31 pt under the rows (the 23 pt button bar and its 8 pt
  gap); Add Filter works from there (+ exists only on rows). The one-third cap is of the Content view's height above
  its bottom bar.
- **⌘⎋** is Reset's key equivalent, as in DBView.xib. AppKit only matches key equivalents of views that are visible in
  the key window, so a hidden tab's or a MySQL tab's Reset never fires for this view; a test covers it.
- **Code only**, no XIB. Strings via `NSLocalizedString` with MySQL's existing keys where the text is identical, new
  keys added to `Resources/English.lproj/Localizable.strings` by hand (genstrings doesn't cover `Source/Postgres`).

### Model and SQL

- `SPPostgresFilter` stays as one condition. The controller's state becomes an ordered `NSArray<SPPostgresFilter *>`
  (empty = no filter).
- `SPPostgresTableData` gets array forms: `-rowsWithFilters:sortColumn:ascending:offset:limit:error:` (same other
  parameters as today's) and `-countRowsWithFilters:error:`. WHERE = each condition's predicate (today's per-operator
  SQL, without its own " WHERE ") joined by ` AND `, parameters numbered in row order. The single-filter methods stay,
  calling the array forms with `@[filter]` or `@[]`, so existing callers and tests are unchanged.
- An invalid row (unknown column, empty IN list) fails the whole load with today's message; the rows stay as typed.
- `showTable:inSchema:filter:` keeps its signature (one start condition → one row). An array form
  `showTable:inSchema:filters:` is added for completeness only if the plan needs it (builder's call).

### Tests (ARC test target, real PostgreSQL on 55412 / 55418, scratch defaults as today)

- SQL: two and three conditions AND-ed, parameters numbered across rows, IN + `=` mixed, IS NULL with others, empty-value
  rows skipped, all-empty = unfiltered, single-filter methods unchanged.
- UI: + / − / Add Filter / Reset change the row count and the area height; rows always above the button bar (after
  hide/show, several rows, small view); cap at one third then scroll; Return applies; the FK arrow and document start
  filter show one row; hiding while filtered reloads unfiltered; preference written only by the toggle, to scratch defaults.
- Existing PostgreSQL filter tests are updated to the new controls where they reached into the old popups/field, keeping
  what they assert.

## Left to the builder

- How the rule editor's delegate models criteria (column items → comparison items → value field), and how rows are
  read back (`criteriaForRow:` / `displayValuesForRow:`), following MySQL's `SPRuleFilterController` as a reference.
- Exact SF symbol/image for Reset (MySQL uses `button_clear`), keyboard focus order, accessibility labels.
- Whether helper classes live in a new file (e.g. `SPPostgresFilterRowsController`) or inside the content controller.
- Localized strings: reuse MySQL's existing keys where the text is identical.
