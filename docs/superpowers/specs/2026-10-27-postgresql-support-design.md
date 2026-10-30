# PostgreSQL support for the Sequel Pro arm64 fork: design

Date: 2026-10-27
Status: approved by owner 2026-10-27

## Intent

The owner manages both MySQL and PostgreSQL servers. Today Sequel Pro (this arm64 fork at
`~/workspace_ios/sequelpro-forked`) only handles MySQL, so Postgres work happens in other tools.
The goal is to work on PostgreSQL servers the same way MySQL is worked on in Sequel Pro: open a
favorite, often through an SSH tunnel, then browse and edit data, run queries, change structure,
manage roles and copy data between servers, all in an app that looks and feels like Sequel Pro.

## Goals

1. **Connect** to PostgreSQL 12 through 18 over standard TCP/IP, a local socket, or an SSH tunnel,
   with connections saved as favorites alongside the existing MySQL favorites.
2. A **separate PostgreSQL window** with the same look and feel as the MySQL window: centered
   compact title row, compact toolbar on a second row, the rounded white tabs, the left table panel.
3. **Toolbar**, left group: Structure, Content, Relations, Triggers, Table Info, Query. Right group:
   Users, Transfer, History, Console. (Database picker at the far left, as in MySQL. Table Info sits
   between Triggers and Query, matching the MySQL toolbar order.)
4. **Left panel**, top to bottom: schema picker, then tables and views of the selected schema, then
   an **Extensions** section at the very bottom listing extensions installed in the current database.
5. **Content**: browse, filter, sort, edit, add and delete rows of a table, as MySQL's Content tab does.
6. **Query**: run arbitrary SQL with results shown below, as MySQL's Query tab does.
7. **Structure**: a table's columns (type, default, nullability), indexes and constraints.
8. **Relations**: a table's foreign keys.
9. **Triggers**: a table's triggers and the functions they call.
10. **Duplicate Table…** in the table list's right-click menu (clone a table).
11. **Users**: role management following PostgreSQL's own role model (see "Users" below).
12. **Transfer**: copy selected tables, or a whole database, from the current server to another
    PostgreSQL server (see "Transfer" below).
13. **Extensions**: install an extension, change an installed extension's version, and drop an extension.
14. **Table Info**: details of the selected table, as MySQL's Table Info tab shows: owner, row
    estimate, table, index and total size, comment, and the table's CREATE statement.
15. **Export**: export a database, schemas or selected tables as an **SQL dump** or as **CSV**, from
    the File menu as in MySQL.
16. **Import**: import an **SQL dump** or a **CSV** file into the current database or table, from the
    File menu as in MySQL.

## Non-goals (first version)

These are not requested; they can come later:

- Transferring between MySQL and PostgreSQL. Transfer is Postgres to Postgres only.
- Editing views, functions, sequences or other objects beyond what the goals list.
- The bundle, navigator and query-favorites features for Postgres. *(Builder's call.)*

## Anti-goal

**Breaking any existing MySQL feature.** The owner uses the MySQL side daily. Anything that
regresses it makes this a failure even if Postgres works. Consequences:

- The Postgres window and its screens are built **separately** from the MySQL screens. They are not
  made by abstracting the existing MySQL controllers (`SPTableContent`, `SPCustomQuery`,
  `SPTablesList`, `SPUserManager`, `SPTableStructure`, `SPDatabaseDocument` …), which are deeply
  MySQL-specific.
- Shared pieces (favorites list, connection screen, SSH tunnel) may only gain **additions**. With
  no Postgres favorite involved, their MySQL behaviour, stored data and UI must stay exactly as today.
- Existing favorites must load and work unchanged. A favorite with no database-type information
  is a MySQL favorite.

## The parts the owner decided

### Connecting
- Postgres connections live in the **same favorites list** as MySQL, with the same fields:
  name, colour, host, port (default 5432), user, password (keychain), database, plus the SSH
  host, user, key and port.
- The connection form gains a **MySQL / PostgreSQL** choice. TCP/IP, Socket and SSH work as for MySQL.
- Connecting a PostgreSQL favorite opens a **separate PostgreSQL window**.

### Window and left panel
- As in Goals 2 to 4. Extensions go **at the end of the left panel**, below the tables and views.

### Extensions
- Clicking an extension allows: **install** (choose from the server's available extensions),
  **update to another version**, and **drop**.

### Structure (table structure management)
Works like MySQL's Structure tab: a column list on top, with indexes and constraints below, edited
in place with + and − buttons. The owner explicitly needs:
- **Add columns**: name, type (with length or precision where the type takes one), default,
  NOT NULL, identity or serial, and comment.
- **Change columns**: rename, **change type**, change default, set or drop NOT NULL, and edit the
  comment.
- **Delete columns.**
- Also: add and drop indexes; add and drop primary key, unique, check and foreign-key constraints;
  rename the table; and edit the table comment.

PostgreSQL cannot reorder columns, so unlike MySQL there is no drag-to-reorder.

### Users (Postgres-specific role management)
A sheet over the Postgres window, approved from the mockup. It follows PostgreSQL's model, not
MySQL's:

- **Roles list**: logins and groups in one list (a group is a role that cannot log in). Add, remove
  and duplicate roles.
- **General**: role name, password, valid-until, connection limit, and the attributes LOGIN,
  INHERIT, SUPERUSER, CREATEDB, CREATEROLE, REPLICATION and BYPASSRLS.
- **Membership**: roles this role is a member of (optionally WITH ADMIN OPTION), and roles that are
  members of it.
- **Privileges**: choose database and schema, then grant or revoke per object:
  - databases: CONNECT, CREATE, TEMP;
  - schemas: USAGE, CREATE;
  - tables: SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER;
  - sequences: USAGE, SELECT;
  - functions: EXECUTE.

  Plus an option to set **default privileges** for objects created later in the schema.
- Changes are applied together with **Apply**, as in MySQL's User Manager.

### Transfer
- Copy **selected tables** or a **whole database** from the current server to another PostgreSQL
  server. The target is normally an existing favorite and may need its own SSH tunnel.
- The user chooses one of two modes:
  1. **Empty the target database before transfer.** Removes **everything inside the target
     database**: all schemas (including `public`), tables, views, functions, types and extensions.
     Then the copy runs into the emptied database. Only the target database is touched. Other
     databases on that server are never touched.
  2. **Overwrite tables that already exist on the target.** Copied tables that exist on the target
     are replaced. Tables on the target that are not part of the copy are left alone. **If replacing
     a table would break something on the target that depends on it** (a view, a foreign key from
     a table not being copied, and so on), Transfer **stops before changing anything and lists what's
     in the way**. It never cascades deletes onto objects outside the copy.
- The usual case is an empty target. Overwriting an older copy happens sometimes.

### Server versions and privileges
- PostgreSQL **12 through 18** must work.
- The servers are **self-hosted**, and the owner can connect as a superuser. Users, Extensions and
  Transfer may assume superuser rights. When the connected role lacks a right, the server's error
  is shown. No special detection or greyed-out UI is needed for managed services.

### Favorites storage
- The owner **still uses the original Sequel Pro 1.1.2** (`/Applications/Sequel Pro.app`), which
  reads the same `Favorites.plist`. Postgres favorites must therefore **not** be written into that
  file, or the old app would treat them as MySQL favorites. Store them separately and merge them
  into the favorites list shown by this build. Their keychain entries must also not collide with
  names the old app uses.

## Builder's calls (not discussed with the owner)

- **Client library**: build on `Frameworks/PostgresKit` (about 4,500 lines, low-level connect,
  query, result and type handling, unfinished and not linked into the app). Replace its bundled
  `libpq.a` and `libpqtypes.a` (ppc, i386 and x86_64 only) with arm64 builds. Homebrew's `libpq` is
  the expected source, mirroring how the MySQL client was replaced with Homebrew
  `mariadb-connector-c` during the arm64 port. Homebrew has no `libpqtypes` formula, so either
  build it from source for arm64 or rework PostgresKit's type layer onto plain libpq. If
  PostgresKit proves unworkable, talking to libpq directly is acceptable.
- **SSH tunnel**: reuse `SPSSHTunnel` unchanged. It forwards a local port and works with any
  database, but its state types come from SPMySQL, so the Postgres side links against SPMySQL's
  headers.
- **SSL**: the connection form offers "Connect using SSL" for Postgres too (`sslmode=require`, with
  the optional CA, certificate and key paths the favorite already stores), mirroring MySQL. Some
  managed Postgres services refuse connections without it.
- **Window and tabs**: one Postgres connection per Postgres window in the first version. It keeps
  the tab bar's look, showing its single tab. Connecting a Postgres favorite from a MySQL window's
  connection screen opens the new Postgres window and leaves the MySQL tab on its connection
  screen, unchanged.
- **Transfer scope**: "whole database" means every non-system schema. Selected tables keep their
  schema name on the target, and that schema is created if missing. The Transfer sheet lets the
  user pick the target favorite and target database (defaulting to the favorite's database).
- **Duplicate Table…** offers "structure only" or "structure and content", as the MySQL version
  does. It also copies indexes, constraints, defaults and owned sequences.
- **Transfer contents**: schema objects needed to make copied tables usable (tables, columns,
  defaults, indexes, constraints, sequences and their current values, and the table data). A
  whole-database transfer also brings views, functions, triggers, and the extensions they depend
  on. If an extension is not available on the target server, stop and report it rather than
  skipping it silently. Roles and ownership are not transferred. Objects are created as the
  connecting target user.
- **Socket connections**: the connection form's Socket option works for Postgres. The socket
  directory defaults to the usual locations (`/tmp`, then `/var/run/postgresql`, then Homebrew's),
  with a field to override it, mirroring MySQL's socket handling.
- **SQL dumps**: Export writes a plain-SQL dump the app generates itself (schema, then data via
  `COPY … FROM stdin` blocks), so it needs no external `pg_dump` and works on any server version.
  Import accepts these files and plain-format `pg_dump` files, including their `COPY … FROM stdin`
  data blocks. Custom, directory and tar `pg_dump` formats are out of scope.
- **CSV**: export a table or query result to CSV, and import CSV into an existing table with column
  mapping, mirroring MySQL's CSV import and export options (delimiter, quote, header row, NULL
  representation).
- **Confirming destructive Transfer**: "Empty the target database" asks for confirmation by typing
  the target database's name, and shows the target server and database clearly before running.
- **Changing a column's type when existing data won't convert automatically**: show the server's
  error and offer a conversion expression field (Postgres's `USING`), pre-filled with
  `column::newtype`, so the user can adjust and retry.
- **Deleting a column that other objects depend on** (views, indexes, constraints): stop and list
  the dependents, never cascade silently. This matches Transfer's behaviour.
- **Structure changes run in a transaction** where Postgres allows it, so a failed change leaves
  the table as it was.
- **Schemas**: the schema picker defaults to `public` when it exists, otherwise to the first schema
  visible on the search path.
- **History** and **Console** behave as in the MySQL window: navigation history, and a log of the
  SQL sent to the server.

## Constraints and facts about the codebase

- Objective-C, mostly manual retain/release (non-ARC), AppKit, deployment target macOS 12.0,
  `ARCHS=arm64`. Built with
  `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`.
- **No version control on the project itself**: it sits inside a git repo rooted at the user's
  home directory. Initialise a project-level repo before starting, so the MySQL side can be
  compared and rolled back. This directly serves the anti-goal.
- Builds are ad-hoc signed, so macOS asks for keychain access again after each rebuild when a
  favorite with a saved password is selected at launch.
- MySQL coupling: 27 of 159 source files use the SPMySQL connection types directly, and 36 contain
  MySQL-only SQL (`SHOW …`, backtick quoting, `mysql.user`).
- MySQL favorites are stored in `~/Library/Application Support/Sequel Pro/Data/Favorites.plist`, shared with the original 1.1.2 app. Each
  favorite has a `type` (0 TCP/IP, 1 socket, 2 SSH), and there is no database-engine field yet.
- Look-and-feel pieces to reuse in the Postgres window: the compact centered title
  (`_applyCompactWindowTitleFont` in `SPDatabaseDocument.m`), 24pt toolbar icons
  (`SPCompactToolbarImage`), the expanded toolbar style, the PSMTabBar "SequelPro" style (white
  active tab, 9pt rounded corners), and `SPSplitView` for the left panel (saves its width).

## What's left to the builder

Internal architecture of the Postgres window and its controllers. How favorites record the
database type. Postgres catalog queries per server version. How Transfer moves data (for example
`COPY` streaming between two connections). Progress and cancel UI for long operations. Error
presentation. Automated test strategy.
