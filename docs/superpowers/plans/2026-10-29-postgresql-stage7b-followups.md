# PostgreSQL Stage 7b (Transfer target picker) — follow-ups

Deferred findings from Stage 7b's reviews. Stage 7's follow-ups
(`2026-10-29-postgresql-stage7-followups.md`) still apply, except its first item: the progress sheet now always ends
its sheet (7b Task 1).

## Open: occasional Transfer test hang
- In 2 of about 8 full-suite runs, Transfer controller tests waited out their 120 s limit in `transferWith:`
  (Stage 7: `testControllerDeallocatesAfterTransfer` once; 7b: `testCancelDuringTransfer`,
  `testControllerDeallocatesAfterTransfer` and `testDefaultTargetConnectUsesTheSession` in one run). They passed when
  rerun, alone and in full runs.
- The stuck-progress-sheet theory didn't hold (on this macOS a queued sheet already has a sheet parent).
- A full run with a watcher on both servers' `pg_stat_activity` (every 5 s) passed and saw no long lock wait and no
  long idle-in-transaction session. Next step if it recurs: log the job's phase, `window.attachedSheet` and
  `pg_stat_activity` from `transferWith:` when it times out.

## Sheet
- The database list and `CREATE DATABASE` run synchronously on the main thread; a slow or dead session freezes the
  sheet until the server answers or TCP times out.
- Choosing the same favorite again after a failed connect forgets the password typed at the prompt and the
  databases created in this sheet (safe: one more prompt or confirmation). Retry keeps them.
- A stale prompt answer returns without refreshing the controls (unreachable from the UI today).
- Untested: the session staying open while the job runs; teardown while a prompt is pending then answered; Cancel of
  New Database… with nothing selected; the SSH default path at controller level (the connector's SSH tests cover the
  shared tunnel).

## Connector and catalog
- A wrong password is recognised only from the server's English "password authentication failed" message (a missing
  password in any language). Documented in `SPPostgresConnector.h`.
- A shared tunnel that fails to forward is reported as ConnectionFailed, not SSHTunnelFailed.

## Progress sheet
- The gap between the Transfer sheet's end and the progress sheet's start (Cancel there finishes cleanly) has no test
  that reaches it; an early cancel there leaves `lastErrorMessage` unset.
- Its tests spin 2 s each.

## Needs a manual check
- The sheet with a real server: the menu filling, "Connecting…"/"Not connected"/Retry, New Database… (and its name
  rules), the password prompt for a favorite without a saved password.
- An SSH target favorite whose key passphrase isn't saved: one prompt on the Transfer sheet, none during the
  transfer; closing the tab while that prompt is up.
