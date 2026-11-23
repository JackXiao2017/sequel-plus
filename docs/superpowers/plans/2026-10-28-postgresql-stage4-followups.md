# PostgreSQL Stage 4 (Users: roles, membership, privileges) — follow-ups

Deferred findings from Stage 4's per-task and final reviews (none block day-to-day use). Every one of them fails
safely: the server refuses and the whole Apply rolls back, or the sheet shows something slightly off.

## Roles and membership (Task 1)
- Swapped or chained renames in one Apply (A→B and B→A) aren't reordered; the server refuses and Apply rolls back.
- On PG 16+, a membership granted by several grantors is revoked per grantor in name order; when one grant depends
  on another the server refuses (rollback).
- Names starting `pg_` aren't refused before sending (the server refuses).
- A grantor dropped in the same Apply is still named in `GRANTED BY` (rollback).
- PG 12/13 with MD5 passwords: renaming a *group* role that has a password clears it silently (login roles are
  refused until a new password is entered).

## Privileges data (Task 2)
- Window functions are left out of the function rows along with aggregates.
- A privilege granted by another grantor can't be revoked by a superuser's REVOKE: Apply succeeds and the tick
  stays.
- Live tests don't cover overloads, procedures, odd function names, materialized views, foreign or partitioned
  tables (the statements for them are unit-tested).

## Users sheet (Task 3)
- An invalid connection limit ("abc") is reverted with a beep at Apply, without a message.
- Duplicating a role with a long name can exceed 63 bytes; it is refused only at Apply.
- An alert can appear after the sheet has ended (a colliding name still in the field on Cancel); a second error
  alert while one is showing falls back to a modal alert.
- Connect or load failures before the sheet opens are shown on the window even if another tab is in front by then
  (the sheet itself only opens on its own tab).
- Large clusters (thousands of roles): membership lists and change tracking are quadratic.

## Privileges tab (Task 4 and final review)
- A default-privileges tick can still be made for a creator marked for removal; if the drop succeeds, that
  database's step fails on every Apply until the tick is removed.
- `pg_database_owner` can still be chosen as creator explicitly; its default privileges never apply.
- When an Apply has no role changes, the partial-failure message doesn't mention database-level grants (CONNECT,
  CREATE, TEMP) that were saved.
- A failed re-read after a partial Apply is only logged; the next Apply would re-send the role changes (Cancel
  recovers).
- Unmarking a role marked for removal doesn't bring back its pending privilege edits.
- Untested: a failed database switch in the pop-up, and the pop-ups being disabled while connecting.

## Needs a manual check
- An SSH favorite whose key passphrase isn't saved: choosing another database in Privileges should show the
  passphrase prompt on the Users sheet.
- Return triggers Apply; the "Users on <favorite>" header; the 12-column grid's horizontal scrolling and bold
  pending rows; the superuser note.
