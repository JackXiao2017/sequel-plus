# PostgreSQL Stage 5 (Extensions) — follow-ups

Deferred findings from Stage 5's per-task and final reviews (none block day-to-day use).

## Data layer (Task 1)
- The dependents list is built from the server's DETAIL by hand (the third copy, after column and sequence
  drops); a shared helper would keep them consistent. A truncated "and N other objects (see server log for list)"
  line is shown as one of the dependents.

## Extension pane and sidebar (Task 2)
- After an update the pane reads the extension twice.
- An extension dropped by another session while its pane shows leaves a blank pane (controls disabled) until the
  sidebar reloads.
- When the versions an extension can update to can't be read, every reload of the pane shows that alert again.
- Right-clicking empty space in the left panel now shows the extension menu, so "Add Sequence…" is only on the
  SEQUENCES header and on sequences (the plan asked for this).
- A database switch whose schema reload then fails can leave the Extension pane showing (empty, controls disabled).
- The right-clicked-row path of the extension menu isn't covered by a test.

## Install sheet (Task 3)
- The schema pop-up follows the default version's fixed schema, not the chosen version's (no contrib extension
  differs; the install itself uses the chosen version's).
- If the database's schemas can't be read, the schema pop-up is empty and the extension goes to the search_path
  default without saying so.
- If the missing requirements can't be read, "Also installs" is hidden (the install still installs them).
- No "(default)" marker in the install sheet's version pop-up (the default is preselected).
- Untested: changing the version refreshing "Also installs", a filtered-out selection disabling Install, closing
  the tab while the sheet is up. The fixed-schema test only has a case on PG 12.

## Needs a manual check
- The Extension pane's layout, the Install sheet's layout, and Return in the search field.
