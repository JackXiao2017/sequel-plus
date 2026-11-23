# PostgreSQL: keep idle connections alive, and reconnect like MySQL

## Why

A PostgreSQL tab left idle for a while is silently dropped by something between the Mac and the server (router,
firewall, VPN, cloud load balancer). The next action (say, Content) sends its query into the dead connection; macOS
retransmits for about 2 minutes, then libpq reports "SSL error: unexpected eof while reading". The tab is then
unusable: the app only says to close it and connect again.

Cause: PostgresKit turns libpq's TCP keep-alives on and sets their probe interval (60 s), but not `keepalives_idle`,
so the first probe waits for macOS's default idle time, 2 hours. Nothing crosses an idle connection before that.

MySQL tabs don't have the problem: SPMySQL pings while idle (Preferences ▸ Network ▸ Keep connection alive, 60 s by
default), checks the connection before using it after 30 s unused, reconnects silently once (restoring the
database and encoding), and only if that fails shows a sheet: Reconnect / Disconnect.

## Goals
- An idle PostgreSQL connection stays up, as MySQL's does, using the same two preferences (Keep connection alive,
  its interval).
- After a drop, the next action reconnects by itself and then runs, within seconds, not after a 2 minute wait.
- When reconnecting fails, a sheet as MySQL's: **Reconnect** (try again) or **Disconnect** (close the tab).
- Works for direct (TCP, socket) and SSH tunnelled favorites.

## Non-goals
- Retrying a statement that failed part way: it may have changed data. Its error shows as today; the next action
  reconnects.
- Transfer's and Export's own short-lived connections, and other windows' connections.
- Restoring session state the user set by hand in the Query editor (SET …, temporary tables, prepared statements).
  As with MySQL, a reconnect is a new session.

## Anti-goals
- A silent reconnect that hides lost work: if the dropped session had a transaction open, the user is told (the
  sheet, below), never reconnected silently.
- Blocking the main thread while checking or reconnecting.

## Approaches considered
1. **Reconnect in place (chosen).** The tab keeps its one PGPostgresConnection; reconnecting replaces its libpq
   session (same parameters, a new SSH tunnel's port when the tunnel had to be restarted). Every view keeps its
   reference, so nothing has to be re-wired.
2. Replace the connection object (a new connector, as a database switch does) and hand it to every view. More
   code touched, more ways to leave a view on the old object.
3. Only keep-alives (no reconnect). Prevents most drops but leaves the tab dead after any that still happens
   (server restart, laptop sleep, network change). The user chose keep-alive + reconnect.

## Design
1. **Keep-alive.** PostgresKit sends `keepalives_idle` = `keepalives_interval` = the Keep connection alive interval
   (60 s default) and `keepalives_count` = 3, and the PostgreSQL connector takes both values from the shared MySQL
   preferences (`SPUseKeepAlive`, `SPKeepAliveInterval`). An SSH tunnelled connection already gets
   ServerAliveInterval from the same preferences.
2. **Check before use.** Before the task runner runs a task, if the connection was unused for 30 s or more (or is
   already known to be broken), it checks it with a ping that gives up after 10 s (a dead connection is found in
   seconds, not in the 2 minutes the kernel takes). A healthy connection costs one round trip.
3. **Reconnect.** A failed check reconnects the same connection object once, silently: for an SSH favorite, first
   restarting the tunnel if it's down (its sheets, if any, on the tab's window). Session settings are re-applied
   as on any connect. Then the task runs. The Console logs the reconnect.
4. **Failure.** If the silent attempt fails, or the lost session had a transaction open, the tab shows a sheet:
   "The connection to the PostgreSQL server was lost" with the reason, **Reconnect** and **Disconnect**.
   Reconnect tries again (the sheet comes back if it fails); Disconnect closes the tab. The waiting task runs after
   a successful reconnect, or is dropped on Disconnect.
5. **During a task.** A connection lost while a statement runs keeps today's error; the connection is marked
   broken, so the next task goes through 2–4.

## Left to the builder
- How the ping is sent and timed out (e.g. an empty query with a deadline on the socket).
- How the runner waits for the main-thread reconnect (the reconnect needs the main thread for the tunnel's
  sheets).
- The exact strings, following MySQL's sheet.
