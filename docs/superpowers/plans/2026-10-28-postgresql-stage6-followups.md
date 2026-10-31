# PostgreSQL Stage 6 (Import and Export) — follow-ups

Deferred findings from Stage 6's per-task and final reviews. None block day-to-day use. The first section lists what
an export leaves out, which is worth knowing before relying on a dump as a full copy.

## Known limitations of the SQL dump
- Not exported:
  - row-level security (ENABLE ROW LEVEL SECURITY and policies);
  - grants and owners;
  - aggregates, rules, collations, statistics objects and REPLICA IDENTITY;
  - comments on constraints, indexes and triggers;
  - large objects, publications/subscriptions, event triggers, casts, operators and text search configurations.
- Foreign tables are left out and listed in the dump's header. A view that reads one is still exported, so importing
  it fails. Neither the FDW server nor its user mappings are exported.
- Exporting selected tables doesn't bring their trigger functions or custom types (as `pg_dump -t`).
- Ordering is simpler than pg_dump's. These can still fail to load:
  - a view, column default or CHECK that calls a SQL-standard-body function;
  - a range type with a user subtype diff or canonical function;
  - circular foreign keys in a data-only load;
  - a column whose type is another table's row type.
- A data-only dump switches each table's user triggers off around its data. If an import run statement by statement
  is stopped partway, they can stay off. This needs table ownership. The same is true of
  `pg_dump --disable-triggers`.
- A data-only dump doesn't refresh materialized views.

## Import
- Unknown settings in a dump (SQLSTATE 42704 from a SET) are skipped with a warning. A known setting whose value names
  a missing object (for example `default_text_search_config`) may raise the same code and is also skipped. Checking
  `pg_settings` for the name would make this exact.
- Cancel then a statement failure, in per-statement mode, can show "import failed" wording in some paths.
  `lastErrorMessage` after a teardown cancel during the error question is the statement's error.
- The CSV preview rejects invalid UTF-8 even in columns that won't be imported, so the mapping sheet won't open.
- The CSV header, preview and catalog lists are read on the main thread, on the tab's connection. They fail when the
  tab's own transaction is aborted.
- No "n statements ignored" summary after an import run statement by statement.
- A statement spanning many read chunks is re-lexed each time (only matters for single statements of many MB).
- Wording: a `.bz2` with trailing padding reads as damaged; corruption inside the compressed data can surface as "isn't
  valid UTF-8 text".

## Export
- Cancelling an export to a single file that already existed (replace confirmed) leaves the partly written file for
  CSV; the SQL dump deletes it.
- Selected schemas: a partitioned table in a selected schema whose partitions live in an unselected schema has its
  rows exported by nobody.
- Source lists are read on the document's connection; an aborted transaction leaves them empty (Whole database still
  works) without a visible message.
- A query-result CSV export can't stop mid-write (the rows are in memory; the file is deleted afterwards).
- Cancel wording differs between "The job was cancelled." and "The export was cancelled."

## Code
- PostgresKit COPY:
  - a non-COPY statement given to copyOut:/copyIn: is executed before it's refused;
  - an exception from a handler leaves copy mode;
  - the comment on PQputCopyData failure is wrong.
- The cancel token holds its mutex while PQcancel connects. An unreachable host at that moment delays the job's end
  until the connect times out.
- O(n²) steps in the dump writer's table loop and sort (fine below thousands of tables).

## Untested paths
- Tests:
  - the real open and save panels;
  - SSH prompts on the progress sheet;
  - row_security off (needs a non-superuser role);
  - the import progress throttle;
  - a quoted CSV field straddling the 64 KiB chunk boundary;
  - sequences with is_called = false;
  - disabled, replica and always triggers;
  - NOT VALID constraints;
  - identity columns with custom options.
- Manual check: an SSH favorite whose key passphrase isn't saved. Export and import should show the prompt on the
  progress sheet, and Cancel should work while it connects.
