# PostgreSQL stage 1 — follow-ups for later stages

Deferred minor findings from the stage 1 per-task and final reviews (none block day-to-day use). Triage before or during Stage 2.

## Do early in Stage 2
- Run catalog queries off the main thread (beachball over slow SSH).
- PostgresKit: post-connect SET runs in a blocking PQexec not bounded by timeout/cancel — move to PQsendQuery + poll loop; add a SET-failure test.
- No Cancel button for Postgres connects (locks up to tunnel timeout + 10 s).
- Database switch still re-prompts if the SSH password was typed into the tunnel's own prompt.

## Deferred minors (from review ledger)
- T1: build-libpq.sh OpenSSL major detection via strings|sed is a brittle heuristic
- T1: libpgcommon/libpgport non-_shlib variants alongside libpq.a's embedded copies — watch for duplicate symbols at link (Task 2)
- T2: datestyle/intervalstyle/extra_float_digits forced via startup `options` — fragile behind PgBouncer and after user `SET DateStyle` (relevant to Stage 2 Query tab)
- T2: PGPostgresLibpqShims.c works around Task 1 shipping _shlib libpgcommon; proper fix = ship non-shlib libpgcommon/libpgport and delete shim
- T2: PGPostgresIntegrationTestCase sets NSTimeZone default in setUp, never restored
- T2: PGPostgresTimeTZ description formats in default zone, labels with value offset (pre-existing)
- T2: BC dates in date-only path via NSDateComponents year<=0 untested
- T2: negative interval components wrap in NSUInteger fields (pre-existing)
- T2: pg-test-servers.sh start_server unused image param; reuses existing container regardless of config
- T2: stale connectionEstablished:/Failed: can arrive after connectionDisconnected: (poll loop ended before disconnect) — CARRY TO TASK 6: connector must ignore callbacks after disconnect/cancel
- T2: deadline timeout leaves half-open PGconn/fd until next connect/disconnect
- T2: disconnect busy-waits on caller thread (usleep loop) up to ~100 ms + one PQconnectPoll step
- T2: cross-thread disconnect before _connection assigned is a no-op
- T2: PGPostgresConnectionTests hard-code 55418, ignore PGKIT_TEST_PORT; timeout test assumes 10.255.255.1 black-holes
- T2: _loadDatabaseParameters swaps _parameters on poller thread without sync (pre-existing)
- T3: test target links SDK-versioned Cocoa.framework path (MacOSX26.0.sdk) from new_target — breaks on SDK change
- T3: each project.save re-serializes pbxproj (churn); test-target settings applied only on creation
- T3: SPPostgresTestServers leaves half-open connection on timeout
- T4: SPCompactChromeTests relies on setContentSize: posting resize on deferred unshown window; CGFloat XCTAssertEqual
- T4: sp_stopCompactTitleTracking has no production caller; test drives window-level only, not SPWindowController drag path
- T5: favorite with missing id gets fresh UUID each load (unremovable, keychain names drift)
- T5: removeFavoriteWithID writes + notifies when nothing matched
- T5: sort not stable for equal names (add favoriteID tie-break)
- T5: unsynchronised read-modify-write across threads
- T5: favoriteWithDictionary allocs SPPostgresFavorite not self
- T5: untested remove on v2 file / file missing version; unreachable-parent treated as missing; write-failure NSError has no description
- T6: second tunnel disconnect after 1 s is a heuristic; stray ssh -N possible under load
- T6: inherited unlocked read of tunnel delegate/selector (same as MySQL)
- T6: TCP/IP favorite with empty host silently uses libpq default socket — reject with "host required" (consider in Task 9 form validation)
- T6: tests miss explicit socketPath precedence, .s.PGSQL file-form parsing, background-thread call, SSL error message check
- T6: tunnel Idle callback before lastError set → generic message without parent window
- T6: pg-test-servers.sh start_sshd assumes sp-pg-net exists
- T6: off-main release of connector can race proxy target read — header should say "release on main thread"
- T7: fixture splitter executes header comment chunk; dead hasPrefix branch
- T7: testViewsListed asserts exact array (brittle); sort check uses compare: vs server C collation
- T7: serverVersionString/defaultSchemaFromSchemas swallow errors — window treats nil version as unknown (CARRY TO TASK 8)
- T7: execute:values: sends UTF8String regardless of client_encoding; embedded NUL truncates
- T7: error-population test disconnects first (exercises fallback message)
- T8: showWindow: after close shows a dead window (should return early when tornDown)
- T8: switchToDatabase: current db during pending switch opens needless connection
- T8: Refresh Databases menu item target not cleared in _tearDown
- T8: all PG windows share frame autosave name SPPostgresWindow (no cascade)
- T8: console test pref restore skipped on failure (use addTeardownBlock)
- T8: window tests depend on SPPostgresCatalogTests fixture loader
- T8: logger may load console nib off main thread (same as MySQL)
- T9: no Cancel for PG connects (≤10 s lock; closing tab cancels) — tell owner
- T9: "+" can save empty-host TCP/IP PG favorite (connect/save reject later)
- T9: no test covers controller-level Favorites.plist guards (adapter-only byte check)
- T9: live-connect test leaves window on failure; engine-fit test leaks a nib-loaded controller
- T9: MySQL-only localhost clearing applies to PG form; Quick Connect keeps PostgreSQL engine selected
- T9: reload suppression applies to all store notifications (cross-window concurrent edit of same favorite can revert rename / orphan keychain items) — set flag only around adapter's own saves
- T9: extra keychain reads per save (rollback support) → more prompts on ad-hoc builds
- T9: postgresFavoritesDidChange re-selects by old node objects (may clear selection) — unverified, pre-existing in task
- Final fix wave: re-review — all F1–F9 addressed, no new Critical/Important; residual minors: F2 SET via blocking PQexec unbounded by timeout/cancel (use PQsendQuery in Stage 2); SET-failure path untested; libpqErrorMessage unsynchronised (guarded by usage); two alerts possible after switch; partial reload failure after switch keeps previous db's schema/lists
