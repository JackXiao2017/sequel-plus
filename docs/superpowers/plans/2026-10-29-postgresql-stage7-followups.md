# PostgreSQL Stage 7 (Transfer) — follow-ups

Deferred findings from Stage 7's per-task and final reviews. None of them can leave a target database half-changed:
every write happens in one transaction that a failure or Cancel rolls back.

## To look at first
- **Progress sheet race (unverified).** `SPPostgresProgressSheet -end` only calls `endSheet:` when the panel already
  has a sheet parent. Transfer ends its own sheet and begins the progress sheet on the same window right away. If
  AppKit queues the progress sheet behind the outgoing one (slow or asleep display) and the job ends first, the
  queued sheet could attach afterwards and stay. This is a plausible cause of one 120 s timeout of
  `SPPostgresTransferControllerTests testControllerDeallocatesAfterTransfer` (it passed in every other run).
  Proposed fix: keep the parent window and always call `[parent endSheet:panel]` in `-end`; begin the progress sheet
  from the Transfer sheet's end handler. Export and Import share the progress sheet.

## Engine and dump
- Empty mode reads the target's schema and extension lists before the load transaction starts. A schema created
  in that moment survives the emptying.
- No `lock_timeout` on the target session: a lock held by another session makes Transfer wait until Cancel.
- Empty mode leaves database-level objects: event triggers whose function isn't in a dropped schema, publications,
  procedural languages other than `plpgsql`.
- A selected-tables copy fails at load (rolled back, server error shown) when:
  - a column uses a user multirange type (its range isn't followed);
  - a default calls an identity sequence of a table outside the copy;
  - a dependency exists on the target as a different kind, or in another schema;
  - a copied type has the name of a target table's row type.
  It also doesn't follow functions used in defaults, CHECKs or indexes.
- The source is read in three snapshots (objects, dependencies, the dump), so concurrent DDL on the source can make
  them disagree.
- After a successful load the target session's `search_path` is left empty (the job disconnects it).
- `tablesCopied` is the writer's table count minus partitioned parents read separately; the writer could report the
  number of COPY blocks itself. The status line counts partitioned parents ("Reading table 6 of 6") while the
  completion says "Copied 5 tables".
- A failure while `COMMIT` is in flight (lost connection) still reads "wasn't changed"; the outcome is unknown then.

## Dump writer (Export paths)
- A data-only dump with `includeDependencies` writes `setval` for dependency sequences it didn't create.
- With `includeStructure` NO, a missing table gives no error (the header promises one).

## Background job and sheets
- On a target failure or a cancel, the job's completion can run before the discarded connection's disconnect has
  finished (header could say so); one comment overstates the job's lifetime.
- The Transfer item's size is pinned at 28×28 to match MySQL's item; `SPToolbarParityTests` would catch a drift.
- Reverse gating (Export/Import/Users disabled while Transfer is up) is untested.

## Tests
- `testJobCancelWhileWritingInterruptsLoad` leaves a sleeping load for up to 60 s if its wait fails.
- The favorites-store redirect in the toolbar test swizzles `+sharedStore` process-wide (restored in `@finally`).
- The lock-wait test's teardown disconnects its holder twice.

## Needs a manual check
- The Transfer sheet's layout; the typed-name confirmation; the Transfer item next to Users on Postgres and MySQL
  tabs (no shift when switching).
- An SSH target favorite whose key passphrase isn't saved: the prompt should appear on the progress sheet, and Cancel
  should work while it connects.
- A real transfer between two servers, in both modes, including one Overwrite that is stopped by a view.
