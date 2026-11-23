# PostgreSQL Stage 3 (Structure, Relations, Triggers, Table Info, Sequences) — follow-ups

Deferred findings from Stage 3's per-task and final reviews (none block day-to-day use).

## Structure data layer (Task 1)
- Dropping a column whose owned sequence another table's default also uses, or a partition-key column, gets the server's refusal rather than the listed-dependents alert (nothing cascades).
- Empty reads cost one extra existence query; `dependentsOfColumn:` on a nonexistent column returns no dependents (the DROP then gets the server's message).

## Structure view (Task 2)
- `showTable:` still discards an unsavable draft on internal paths (user moves are vetoed first).
- The "field editor can't resign" path is untested (needs the GUI).

## Relations and Triggers (Task 3)
- The Function and References columns show `schema.name` unquoted (ambiguous when a name contains a dot).
- On PG 15+, trigger clones on partitions are listed; dropping one there gets the server's refusal.

## Table Info and CREATE statement (Task 4)
- Table Info isn't marked stale by trigger changes (it re-reads every time it is shown).
- The CREATE statement doesn't include a partition's or inheritance child's own overrides on inherited columns (NOT NULL, DEFAULT), or identity sequence options (documented in the header). Serial columns appear as `DEFAULT nextval(…)` without sequence DDL.
- A partitioned table's sizes are the parent's own (0 bytes); summing partitions is optional.
- The round-trip test compares collations by name only.

## Sequences (Task 5)
- The number fields accept `1e3` as 1000.
- If the sidebar reload after a rename fails, the sidebar keeps the old name (pre-existing pattern).
- For about one run-loop turn after leaving a sequence with a pending rename, the sidebar still shows the old name.

## Cross-pane (final review)
- Renames done in the Query view (`ALTER … RENAME`) don't update History entries; Rename Table… and sequence renames do.
- One redundant sidebar reload after a schema pop-up change.
- The click path in the "leave a sequence with a pending rename" test imitates NSTableView's order rather than real mouse tracking (the keyboard path is real) — worth a manual click during the visual check.
