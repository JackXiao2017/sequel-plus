# PostgreSQL Stage 4 (Users: roles, membership, privileges) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Postgres tab, the Users toolbar item and Database ▸ User Accounts… (⌘U) open a Users sheet that
manages PostgreSQL roles the way the approved mockup shows:
- **Roles list:** logins and groups in one list; add, remove and duplicate.
- **General:** name, password, valid until, connection limit, and LOGIN, INHERIT, SUPERUSER, CREATEDB, CREATEROLE,
  REPLICATION, BYPASSRLS.
- **Membership:** roles this role is a member of (with admin option), and roles that are members of it.
- **Privileges:** pick a database and schema, then grant or revoke on the database, the schema, and its tables,
  sequences and functions, plus default privileges for objects created later in the schema.
- Nothing changes on the server until **Apply**; Cancel discards everything.

**Architecture:**
- Two data-layer classes with no UI:
  - `SPPostgresRoles` reads roles and memberships and turns role edits into SQL.
  - `SPPostgresPrivileges` reads one role's privileges in one database and turns privilege edits into SQL.
- Edits are held as drafts. Each class has a pure `statementsFor…` method (original vs draft → SQL list), tested
  without a server, and an apply method that runs that list in one transaction.
- The sheet, `SPPostgresUsersController`, never uses the document's connection. It gets its own connections, one
  per database it touches, from a `connectionProvider` block. The user's open Query transaction is never involved.
  The document's provider opens them with `SPPostgresConnector`, exactly as a database switch does; tests pass
  their own provider.
- **Apply order:**
  1. Role changes plus database-level grants (cluster objects) run in one transaction on the current database's
     sheet connection.
  2. Then each other database's schema and object grants run in that database's own transaction.
  3. A failure in step 1 changes nothing. A failure in step 2 keeps what committed and leaves the failed
     database's edits pending, and the message names that database.

**Tech Stack:** Objective-C (MRC in app sources), AppKit built in code, PostgresKit over static libpq, XCTest (ARC),
Docker test servers (PG 12 on 55412, PG 18 on 55418).

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md` ("Users (Postgres-specific role
management)", "Server versions and privileges") as amended by `docs/superpowers/specs/2026-10-27-postgresql-tabs-design.md`
("Users is shared: MySQL's User Manager on MySQL tabs, Postgres roles on Postgres tabs (stage 4)"). The approved
mockup is `.superpowers/brainstorm/68962-1793065565/content/postgres-roles.html`.

## Builder's decisions (the spec leaves these open)

- **Passwords are never sent or logged in plain text.** They are hashed client-side with libpq's
  `PQencryptPasswordConn` (the server's `password_encryption`, normally SCRAM), so the console, the server log and
  `pg_stat_activity` see only the verifier. The password field is always shown empty; empty means "unchanged". A
  **Clear password** checkbox sends `PASSWORD NULL`.
- **Predefined `pg_*` roles** are hidden from the Roles list but offered under "Member of", for example
  `pg_read_all_data`.
- **Duplicate** creates a pending new role named `<name>_copy` (then `_copy2` and so on) with the source's
  attributes, connection limit, valid-until and "member of" memberships. It does not copy the password, members
  or privileges, since privileges live in every database separately.
- **Deleting a role** never uses `DROP OWNED` or `REASSIGN OWNED`. When the server refuses because the role owns
  objects or holds privileges, its message and DETAIL list is shown and the whole Apply is rolled back. The
  connected role cannot be removed: − is disabled for it.
- **Privileges show direct grants only.** Each object's ACL is read with `aclexplode(coalesce(acl,
  acldefault(kind, owner)))` for the role's oid, so an owner shows its implicit privileges. Membership-inherited
  and superuser rights are not shown as ticks. A superuser role gets the note "Superusers bypass all privilege
  checks."
- **Privilege sets per kind** (spec): database CONNECT, CREATE, TEMP; schema USAGE, CREATE; table, view,
  materialized view and foreign table: SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER; sequence
  USAGE, SELECT; function or procedure EXECUTE. Routines are granted with `ON ROUTINE s.f(<identity args>)`
  (PG 11+), so overloads and procedures work. Aggregates are excluded from the list.
- **Default privileges** appear as three extra rows: "Tables created later", "Sequences created later" and
  "Functions created later". They apply to objects that a chosen creator role makes in this schema, via
  `ALTER DEFAULT PRIVILEGES FOR ROLE <creator> IN SCHEMA <s> GRANT|REVOKE … TO <role>`. The creator pop-up defaults
  to the schema's owner. They are read from `pg_default_acl`.
- **Membership revoke on PG 16+:** a membership may have several grantors. Removing it revokes every
  `pg_auth_members` row with `GRANTED BY <grantor>`, so the membership really goes. Below 16 a plain `REVOKE` is
  used.
- **Apply closes the sheet** only when everything succeeded. On failure the sheet stays open with the error and
  every edit not applied.

## Global Constraints

- **Never break MySQL.**
  - MySQL's `SPUserManager` and its xib are untouched.
  - `showUserManager:` on MySQL tabs behaves exactly as before. Postgres tabs implement their own
    `showUserManager:` in `SPPostgresDocument`.
  - Any shared-file edit is additive and inert for MySQL tabs.
- PostgreSQL **12 through 18**. Every data-layer test runs on both 55412 and 55418.
- **Identifiers** are always quoted with `SPPostgresQuoteIdentifier`. Values are quoted with `SPPostgresQuoteLiteral`
  or sent as `$n` parameters. Role and DDL statements can't take parameters, so they use literals.
- **Names:** role names follow the 63-byte rule (`+[SPPostgresTableDuplicator isValidTableName:]`); an invalid name
  fails before anything is sent.
- **Never cascade.** No `CASCADE`, `DROP OWNED` or `REASSIGN OWNED`, and no `GRANTED BY` other than for revoking
  memberships as described above.
- **Superuser assumption (spec):** the owner connects as a superuser. When the connected role lacks a right, the
  server's error is shown; nothing is greyed out for that.
- **Tests:**
  - Test roles are named with the prefix `sp_t4_` (odd names: `sp_t4_Sales Rep`, `sp_t4_a"b`, `sp_t4_user`), since
    roles are cluster-wide on the shared Docker servers.
  - Each test drops what it created in `tearDown` with plain `DROP ROLE IF EXISTS` after revoking its grants. The
    helper may use `DROP OWNED BY` (test-only cleanup, never app code).
  - The second database is the catalog fixture's `pgkit_nopublic` (schema `app`, table `app.items`).
- **Tests and prefs:** never write `Favorites.plist`. Tests never persist into real prefs or the login keychain;
  `PostgresTests/SPTestPrefsGuard.m` stays effective.
- **Code conventions:**
  - MRC in app sources; ARC in `Postgres Tests`.
  - Add files only with `ruby Scripts/pg-xcodeproj.rb add-app|add-test`.
  - Exported classes and functions need `__attribute__((visibility("default")))`.
- **Test command:** `timeout 900 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests"
  -derivedDataPath build/DerivedData ARCHS=arm64`. Run `bash Scripts/pg-test-servers.sh up` first.
- **App build:** `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath
  build/DerivedData ARCHS=arm64 build`.
- **Agent sessions:**
  - Implementer sessions never launch the GUI app; the controller does the visual checks.
  - Never kill processes you didn't start.
  - Never touch the owner's untracked `start_clause.sh`; stage only your own files.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A password typed in the sheet**:
   - It must never appear in plain text in anything sent to the server, the console logger, or an error message.
   - Pinned in Task 1 (`testPasswordIsSentHashed`): a delegate captures every statement and none contains the
     password, and logging in with the password then works.
2. **Removing a role that owns a table or holds a privilege** (here or in another database):
   - Nothing changes, including the other edits in the same Apply.
   - The server's message with its DETAIL list is shown.
   - Pinned in Task 1 (`testDropRoleThatOwnsObjectsIsRefusedAndRollsBack`).
3. **Odd role names**:
   - Names: `sp_t4_Sales Rep`, `sp_t4_a"b`, `sp_t4_user`.
   - Create, rename, password, membership and every kind of grant must work, and a 64-byte name is refused before
     sending.
   - Pinned in Task 1 (`testOddRoleNames`) and Task 2 (`testGrantsWorkForOddNamesAndObjects`, on the
     `"Sales Data"."Orders 2026"` table).
4. **The user has a transaction open in the Query view** while using the Users sheet:
   - The sheet's reads and Apply don't touch it; it stays open with its uncommitted work.
   - Pinned in Task 3 (`testUsersSheetNeverUsesTheDocumentConnection`).
5. **Apply fails partway**: the second database's grants fail (for example, the table was dropped meanwhile).
   - The role changes and the first database committed, and the sheet says so.
   - The failed database's edits are still pending, and the sheet stays open.
   - Pinned in Task 4 (`testApplyFailureInSecondDatabaseKeepsItsEdits`).

---

### Task 1: `SPPostgresRoles`, roles, membership and password hashing

**Files:**
- Modify: `Frameworks/PostgresKit/Source/PGPostgresConnection.h/.m`. Add
  `- (NSString *)encryptedPassword:(NSString *)password forRole:(NSString *)role;`, which wraps
  `PQencryptPasswordConn(conn, pw, role, NULL)`, frees with `PQfreemem`, and returns nil when not connected or on
  failure.
- Create: `Source/Postgres/SPPostgresRoles.h/.m`.
- Test: `PostgresTests/SPPostgresRolesTests.m`. Shared test-role cleanup goes in `SPPostgresTestServers`:
  `+ (void)dropTestRolesOnPort:(NSUInteger)port;` drops every role named `sp_t4_%` after `DROP OWNED BY` in
  `pgkit_test` and `pgkit_nopublic`.

**Interfaces:**
- **Consumes:** `SPPostgresExecute`, `SPPostgresExecuteWithDetails`, `SPPostgresQuoteIdentifier`,
  `SPPostgresQuoteLiteral`, `SPPostgresMakeError`, and `+[SPPostgresTableDuplicator isValidTableName:]`.
- **Produces `SPPostgresRole : NSObject <NSCopying>`**, a readwrite draft and snapshot in one:
  - `name`;
  - `originalName` (nil for a role not yet created);
  - `BOOL canLogin, inherit, superuser, createDB, createRole, replication, bypassRLS`;
  - `NSInteger connectionLimit` (-1 means unlimited);
  - `NSDate *validUntil` (nil means never; the server's `infinity` reads as nil);
  - `newPassword`: nil means unchanged and is never read from the server;
  - `BOOL clearPassword`;
  - `NSDictionary *memberOf`: role name → `@(BOOL adminOption)`;
  - `NSDictionary *members`: role name → `@(BOOL adminOption)`;
  - `BOOL markedForDeletion`;
  - `- (BOOL)isGroup` returns `!canLogin`.
- **Produces `SPPostgresRoles : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `- (NSArray *)roles:(NSError **)error;` returns every role sorted by name, with memberships filled in (from
    `pg_roles` and `pg_auth_members`). Names starting `pg_` are excluded.
  - `- (NSArray *)allRoleNames:(NSError **)error;` returns every role name including `pg_*`, for the Member of
    list.
  - `- (NSString *)sessionRoleName;` returns `session_user`.
  - `- (NSArray *)statementsForOriginalRoles:(NSArray *)originals edited:(NSArray *)edited error:(NSError **)error;`
    - It is pure apart from password hashing (it calls `encryptedPassword:forRole:`), and returns the SQL
      strings in run order.
    - The order:
      1. Drops: `DROP ROLE`.
      2. Renames: `ALTER ROLE … RENAME TO …`.
      3. Creates: `CREATE ROLE … WITH <attrs> [CONNECTION LIMIT n] [VALID UNTIL '…'] [PASSWORD '<hash>']`.
      4. Attribute, limit, valid-until and password changes: one `ALTER ROLE … WITH …` per role, listing only the
         changed items.
      5. Membership revokes.
      6. Membership grants.
    - Membership is diffed per pair. A pair that only gains or loses admin gets `GRANT … WITH ADMIN OPTION` or
      `REVOKE ADMIN OPTION FOR …`.
    - Valid until is written as `'infinity'` or an ISO 8601 timestamp with its UTC offset.
    - It fails without returning statements on an invalid name, a duplicate name, or a password on a role whose
      hashing failed.
  - `extern BOOL SPPostgresApplyInTransaction(PGPostgresConnection *connection, NSArray *statements, NSError **error);`
    (exported from `SPPostgresRoles.h`) does the BEGIN/statements/COMMIT-or-ROLLBACK below; Task 2 and the sheet reuse it.
  - `- (BOOL)applyStatements:(NSArray *)statements error:(NSError **)error;`
    - Runs `BEGIN`, then the statements, then `COMMIT`. On the first failure it runs `ROLLBACK`.
    - The error carries the server message with its DETAIL and HINT lines (`SPPostgresExecuteWithDetails`).
    - An empty list is a no-op.
  - The PG 16+ membership revoke (see the decisions) needs the grantors. `roles:` records them internally per
    pair, and `statementsFor…` emits one `REVOKE … GRANTED BY` per grantor when the server is 16+ (`serverVersion`
    ≥ 160000).

- [ ] **Step 1: Write the failing tests**, each on both ports, with `tearDown` calling `dropTestRolesOnPort:`:
  - `testRolesListsAttributesAndHidesPredefined`:
    - Create `sp_t4_login` (LOGIN CREATEDB CONNECTION LIMIT 3 VALID UNTIL '2030-01-02 03:04:05+00') and
      `sp_t4_group` (NOLOGIN) via raw SQL, with `sp_t4_login` a member of `sp_t4_group` WITH ADMIN OPTION.
    - `roles:` has both, with the right flags, limit, a validUntil equal to that instant, and memberOf
      `{sp_t4_group: @YES}`. `sp_t4_group`'s members is `{sp_t4_login: @YES}`, and no name starts with `pg_`.
    - `allRoleNames:` contains `pg_read_all_stats`.
  - `testStatementsForNewAndChangedRoles` (pure, no apply):
    - A new group role gives exactly `CREATE ROLE "sp_t4_g" WITH NOLOGIN INHERIT NOSUPERUSER NOCREATEDB
      NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 VALID UNTIL 'infinity'`.
    - Toggling only CREATEDB on an existing role gives exactly `ALTER ROLE "sp_t4_login" WITH CREATEDB`.
    - Unchanged roles give no statements.
  - `testApplyCreatesRenamesAltersAndDrops`: one apply that creates `sp_t4_new`, renames `sp_t4_old` to
    `sp_t4_renamed`, sets CONNECTION LIMIT 7 on it, and drops `sp_t4_gone`. A re-read shows exactly that.
  - `testPasswordIsSentHashed`:
    - Use a connection made with a capturing `PGPostgresConnectionDelegate` (see `SPPostgresTestServers`).
    - Set the password `Pw-sp_t4!` on the new LOGIN role `sp_t4_pw`.
    - No captured statement contains `Pw-sp_t4!`, and the `PASSWORD` literal starts with `SCRAM-SHA-256$` or
      `md5`.
    - A fresh connection as `sp_t4_pw` / `Pw-sp_t4!` connects.
    - `clearPassword` then makes `pg_authid.rolpassword` NULL.
  - `testMembershipGrantRevokeAndAdminOption`:
    - Add a membership.
    - Then flip only its admin option; the re-read shows the flip, and the statement is `REVOKE ADMIN OPTION FOR`.
    - Then remove the membership.
  - `testRevokeMembershipWithAnotherGrantorOnPG16Plus`, on port 55418 only:
    - `sp_t4_grantor` (CREATEROLE, admin of `sp_t4_group`) grants `sp_t4_group` to `sp_t4_member`.
    - Removing the membership in the draft and applying as the superuser leaves no `pg_auth_members` row.
  - `testDropRoleThatOwnsObjectsIsRefusedAndRollsBack`:
    - `sp_t4_owner` owns table `public.sp_t4_owned`.
    - One apply drops `sp_t4_owner` and creates `sp_t4_side`.
    - It returns NO; the message contains `sp_t4_owner` and the DETAIL contains `sp_t4_owned`.
    - Both roles are as before, so `sp_t4_side` does not exist. The test drops the table in tearDown.
  - `testOddRoleNames`:
    - Create, rename, set a password, and add a membership between `sp_t4_Sales Rep` and `sp_t4_a"b`, then
      rename to `sp_t4_user`; everything round-trips.
    - A name of 64 bytes fails before anything is sent.
- [ ] **Step 2: Run the tests and see them fail.** Expected: `SPPostgresRoles` is undefined.
- [ ] **Step 3: Implement** `encryptedPassword:forRole:` in PostgresKit and `SPPostgresRoles` as specified.
- [ ] **Step 4: Run the full test suite.** Expected: everything passes, 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 4 Task 1: roles, membership and hashed passwords`.

---

### Task 2: `SPPostgresPrivileges`, one role's grants in one database

**Files:**
- Create: `Source/Postgres/SPPostgresPrivileges.h/.m`.
- Test: `PostgresTests/SPPostgresPrivilegesTests.m`.

**Interfaces:**
- **Consumes:** Task 1's `SPPostgresApplyInTransaction` (its `applyStatements:error:` uses it too).
- **Produces `SPPostgresPrivilegeObject : NSObject <NSCopying>`:**
  - `kind`: one of
    - `@"database"`, `@"schema"`;
    - `@"table"`, `@"view"`, `@"materialized view"`, `@"foreign table"`;
    - `@"sequence"`, `@"function"`;
    - `@"default tables"`, `@"default sequences"`, `@"default functions"`.
  - `schema`, `name`. For a function, `name` is `f(<identity args>)` for display and `signature` holds the
    identity args. For the three default kinds, `name` is the display text ("Tables created later" and so on).
  - `NSArray *availablePrivileges`, in the spec's order for the kind.
  - `NSSet *granted` (readwrite).
  - `NSSet *grantable` (privileges held WITH GRANT OPTION; read-only, shown but not editable in this stage).
- **Produces `SPPostgresPrivileges : NSObject`:**
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;` The connection is to the database
    being edited.
  - `- (NSArray *)databasePrivilegesForRole:(NSString *)role database:(NSString *)database error:(NSError **)error;`
    returns one object of kind `database`.
  - `- (NSArray *)privilegesForRole:(NSString *)role schema:(NSString *)schema defaultsCreator:(NSString *)creator error:(NSError **)error;`
    - Returns the schema row, then tables, views, materialized views and foreign tables, then sequences, then
      functions (each group sorted by name), then the three default rows for `creator`.
    - The role may not exist yet (a pending new role): every row then has an empty `granted`.
  - `- (NSString *)ownerOfSchema:(NSString *)schema error:(NSError **)error;` gives the default creator.
  - `+ (NSArray *)statementsForRole:(NSString *)role original:(NSArray *)originals edited:(NSArray *)edited defaultsCreator:(NSString *)creator;`
    - Pure. Per object it emits one `GRANT p1, p2 ON <kind> <qualified> TO <role>` and one `REVOKE … FROM <role>`.
    - `<kind>` is `DATABASE`, `SCHEMA`, `TABLE` (for every table-like kind), `SEQUENCE`, `ROUTINE`, or for the
      default rows
      `ALTER DEFAULT PRIVILEGES FOR ROLE <creator> IN SCHEMA <s> GRANT … ON TABLES|SEQUENCES|FUNCTIONS TO <role>`
      (`FUNCTIONS`, since `ROUTINES` needs PG 14).
    - Privileges are written in the kind's order.
  - `- (BOOL)applyStatements:(NSArray *)statements error:(NSError **)error;`

- [ ] **Step 1: Write the failing tests**, each on both ports, with roles `sp_t4_priv` (and so on) dropped in
  tearDown:
  - `testReadsDirectGrantsPerKind`:
    - Raw SQL grants `sp_t4_priv` CONNECT on `pgkit_test`, USAGE on `public`, SELECT and UPDATE on
      `public.customers`, SELECT on `public.v_customers`, and EXECUTE on a fixture function
      `public.sp_t4_fn(integer)`; the test creates and drops it.
    - Each row's `granted` matches. `customers` lists exactly the seven table privileges as available.
    - The function row's name is `sp_t4_fn(integer)`.
  - `testOwnerShowsImplicitPrivileges`: for a table owned by `sp_t4_owner` with a NULL ACL, all seven are ticked.
  - `testStatementsAreMinimalAndOrdered` (pure):
    - Going from {SELECT} to {SELECT, INSERT, DELETE} gives exactly `GRANT INSERT, DELETE ON TABLE
      "public"."customers" TO "sp_t4_priv"`.
    - Removing EXECUTE gives exactly `REVOKE EXECUTE ON ROUTINE "public"."sp_t4_fn"(integer) FROM "sp_t4_priv"`.
  - `testApplyRoundTripsEveryKind`: tick one privilege of every kind (database, schema, table, sequence, function),
    apply, and re-read; then untick them all, apply, and re-read empty.
  - `testDefaultPrivileges`:
    - Tick SELECT on "Tables created later" with creator `pgkit_test` and apply.
    - `pg_default_acl` has the entry, and a table created afterwards by `pgkit_test` in that schema has SELECT
      for `sp_t4_priv`.
    - Untick, apply, and the entry is gone.
  - `testGrantsWorkForOddNamesAndObjects`: role `sp_t4_Sales Rep` on `"Sales Data"."Orders 2026"` and on schema
    `"a""b"`.
  - `testOtherDatabase`: with a connection to `pgkit_nopublic`, schema `app` lists `items`, and a grant on it
    applies there.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** `SPPostgresPrivileges` as specified.
  - Read ACLs with `aclexplode(coalesce(<acl>, acldefault('<c>', <owner>)))`, filtered on `grantee =
    <role oid>`. The kind letters are `'d'` database, `'n'` schema, `'r'` relation, `'s'` sequence and `'f'`
    function.
  - Default privileges are read from `pg_default_acl`, with no acldefault fallback.
- [ ] **Step 4: Run the full test suite.** Expected: everything passes, 0 failures.
- [ ] **Step 5: Commit** with the message `Postgres Stage 4 Task 2: per-database privileges and default privileges`.

---

### Task 3: The Users sheet (Roles list, General, Membership, Apply) and its wiring

**Files:**
- Create: `Source/Postgres/SPPostgresUsersController.h/.m`, built in code like `SPPostgresConstraintSheet`.
- Modify: `Source/Postgres/SPPostgresDocument.h/.m`.
  - Add `- (IBAction)showUserManager:(id)sender;`.
  - The Users toolbar item gets that action instead of `unavailableInThisVersion:`, and joins
    `_availableToolbarItemIdentifiers`.
  - `validateMenuItem:` and `validateToolbarItem:` enable it while connected, not processing, and no sheet is
    attached.
  - The document's connection provider: a fresh `SPPostgresConnector` for the favorite with `database` changed, as
    in `switchToDatabase:` (the same passwords and parent window). The connectors are owned by the controller and
    disconnected when the sheet ends.
- Test: `PostgresTests/SPPostgresUsersControllerTests.m`. Update the Users expectations in
  `SPPostgresToolbarTests.m` and `SPToolbarParityTests.m`, where Users is now enabled on Postgres tabs.

**Interfaces:**
- **Consumes:** Task 1 (`SPPostgresRoles`, `SPPostgresRole`, `SPPostgresApplyInTransaction`). Task 4 adds the
  Privileges tab into the tab view this task creates.
- **Produces `SPPostgresUsersController : NSObject`:**
  - `- (instancetype)initWithDatabase:(NSString *)database connectionProvider:(void (^)(NSString *database, void (^completion)(PGPostgresConnection *connection, NSError *error)))provider;`
    - `database` is the document's current database.
    - The provider's completion may be called synchronously (as in tests) or later.
  - `- (void)beginSheetForWindow:(NSWindow *)window completion:(void (^)(BOOL applied))completion;`
    - Connects to `database` first and loads the roles; a failure shows the error and does not open the sheet.
  - `- (void)endSheet;`
  - Exposed for tests (readonly unless noted):
    - `sheet`, `rolesTable`, `tabView`;
    - `nameField`, `passwordField`, `clearPasswordCheckbox`;
    - `validUntilCheckbox`, `validUntilPicker`, `connectionLimitField`;
    - the seven attribute checkboxes `loginCheckbox`, `inheritCheckbox`, `superuserCheckbox`, `createDBCheckbox`,
      `createRoleCheckbox`, `replicationCheckbox`, `bypassRLSCheckbox`;
    - `memberOfTable`, `membersTable` (columns: checkbox, name, Admin checkbox);
    - `addButton`, `removeButton`, `duplicateButton`, `applyButton`, `cancelButton`;
    - `NSArray *editedRoles`, `SPPostgresRole *selectedRole`, `NSString *lastErrorMessage`;
    - `@property (copy) void (^alertPresenter)(NSAlert *alert);` (nil shows a sheet-on-sheet alert);
    - `- (void)apply:(id)sender;`, `- (void)cancel:(id)sender;`, `- (void)addRole:(id)sender;`,
      `- (void)removeRole:(id)sender;`, `- (void)duplicateRole:(id)sender;`.
- **Layout (mockup):**
  - The sheet is 760×520 and resizable, with a minimum of 680×460.
  - Left: the ROLES list, 200 wide. Each row has an icon (`NSImageNameUser`, or `NSImageNameUserGroup` for a
    group), the name, and a grey subtitle: "superuser", "group, no login", or none.
  - Under the list are the +, − and duplicate buttons.
  - Right: an NSTabView with the tabs General, Membership and Privileges (a placeholder until Task 4).
  - Bottom right: Cancel and Apply. Apply is the default button and is enabled only when there are changes.
  - A row marked for deletion shows its name struck through until Apply (as MySQL marks deleted users); − on a
    new, unapplied role just removes it.
  - Labels and checkboxes use the mockup's wording: "Can log in", "Inherit privileges", "Superuser",
    "Create databases", "Create roles", "Replication", "Bypass row-level security", "Connection limit:" with the
    placeholder "-1 = unlimited", "Valid until:" with the checkbox "Expires" and a date picker, "Password:" with
    the placeholder "unchanged", and "Clear password".
  - Membership has "Member of:" and "Members of this role:".

- [ ] **Step 1: Write the failing tests.** Use a provider that returns `SPPostgresTestServers` connections, on
  both ports; tearDown drops `sp_t4_%` roles.
  - `testSheetListsRolesAndShowsGeneral`:
    - Begin on an offscreen window.
    - The list contains `sp_t4_login` (created in setUp) with no subtitle, and `sp_t4_group` with the subtitle
      "group, no login".
    - Selecting `sp_t4_login` fills the fields, and the password field is empty.
  - `testAddEditApplyCreatesRole`:
    - `addRole:`, set the name `sp_t4_ui`, tick Create databases, and set the connection limit to 4.
    - Apply is enabled; `apply:` creates the role with exactly those attributes, and the completion gets YES.
  - `testCancelDiscardsEverything`: edit a name and tick Superuser, then `cancel:`. Nothing changed on the server,
    and the completion gets NO.
  - `testDuplicateCopiesAttributesAndMemberships`: it creates `sp_t4_login_copy` with the same flags and
    memberOf, and no password.
  - `testRemoveMarksThenApplyDrops`: the row shows as marked, and apply drops it.
  - `testRemoveDisabledForSessionRole`: selecting `pgkit_test` disables −.
  - `testApplyFailureKeepsSheetAndEdits`:
    - Mark `sp_t4_owner` (which owns a table) for deletion, and edit another role.
    - apply returns with `lastErrorMessage` containing the server's text; the sheet is still attached, and both
      edits are still pending.
  - `testUsersSheetNeverUsesTheDocumentConnection`:
    - Through `SPPostgresDocument` (as in `SPPostgresDocumentTests`), open a transaction in the document's
      connection and insert a row. Run `showUserManager:` with a test provider, apply a role change, and end.
    - The document's connection is still in a transaction, and the row is still visible in it.
  - `testUsersToolbarItemAndMenuEnabled`: on a Postgres document, `validateToolbarItem:` for Users and
    `validateMenuItem:` for `showUserManager:` are YES.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** the controller and the document wiring.
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and the build succeeds. The
  MySQL toolbar parity test still passes for MySQL tabs.
- [ ] **Step 5: Commit** with the message `Postgres Stage 4 Task 3: Users sheet with roles, general and membership`.

---

### Task 4: The Privileges tab and applying across databases

**Files:**
- Modify: `Source/Postgres/SPPostgresUsersController.h/.m`.
- Test: `PostgresTests/SPPostgresUsersControllerTests.m` (additions).

**Interfaces:**
- **Consumes:** Task 2 (`SPPostgresPrivileges`, `SPPostgresPrivilegeObject`), and Task 3's controller and provider.
- **Produces, on `SPPostgresUsersController`, for tests:**
  - `databasePopup`, `schemaPopup`, `creatorPopup`, `privilegesTable`, `superuserNote` (an NSTextField, hidden
    unless the selected role is a superuser);
  - `- (NSArray *)privilegeRowsShown;` returns the `SPPostgresPrivilegeObject`s in the grid.
- **Behaviour:**
  - **Grid:** an Object column showing kind and name ("table customers"), then one checkbox column per privilege
    name. The order is SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER USAGE CREATE CONNECT TEMP
    EXECUTE. A cell is shown only when its row's kind has that privilege; otherwise it is empty and not editable.
  - **Rows:** the database row first, then the rows of `privilegesForRole:schema:defaultsCreator:`.
  - **Changing database:** connects to it through the provider, with a progress indicator. The popups are disabled
    while connecting. On failure the previous database is reselected and the error is shown.
  - **Pending edits** are kept per (role, database, schema). Changing database, schema, creator or role keeps them,
    and coming back shows them.
  - **Renames:** pending edits are keyed by the role's current draft name. Renaming a role in General re-keys
    them, and a new role's edits are applied after it is created.
  - **Removing a role** drops its pending privilege edits.
  - **Apply:**
    1. Role statements plus every pending database-kind grant run in one transaction on the current database's
       connection.
    2. Then each database's other statements run on that database's connection (connecting if needed), the
       current database first, then the others in name order.
    3. On a failure in step 2, the message is `Roles and <done databases> were saved; changes in <db> were not:
       <server message>`. The sheet re-reads and stays open, with that database's edits and those of any
       database after it still pending.

- [ ] **Step 1: Write the failing tests**, on both ports:
  - `testGridShowsKindsAndOnlyApplicableCells`: for `sp_t4_priv` in `pgkit_test`/`public`, the rows start with
    database `pgkit_test`, then schema `public`, include table `customers` and view `v_customers`, and end with
    the three default rows. The CONNECT cell exists only on the database row.
  - `testTickApplyGrants`: tick SELECT on `customers` and CONNECT on the database, then apply. The server shows
    both grants, and the sheet ends with YES.
  - `testEditsInTwoDatabasesApplyToBoth`: tick in `pgkit_test`, switch to `pgkit_nopublic`/`app`, tick SELECT on
    `items`, then apply. Both are granted.
  - `testEditsSurviveSwitchingBack`: tick, switch database, switch back, and the tick is still shown as pending.
  - `testNewRoleGetsItsPrivileges`: add `sp_t4_fresh` and tick SELECT on `customers` in the same session; apply
    creates the role and grants it.
  - `testApplyFailureInSecondDatabaseKeepsItsEdits`:
    - Pend a General change, a grant in `pgkit_test`, and a grant on `app.items` in `pgkit_nopublic`.
    - Drop `app.items` behind the sheet's back (re-created in tearDown via the catalog fixture), then apply.
    - The General change and the `pgkit_test` grant are on the server, and the sheet is still open.
    - `lastErrorMessage` starts with `Roles and pgkit_test were saved; changes in pgkit_nopublic were not:`, and
      the `pgkit_nopublic` edit is still pending.
  - `testSuperuserNote`: a superuser role shows the note; others don't.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement** the tab and the multi-database apply.
- [ ] **Step 4: Run the full test suite, then build the app.** Expected: 0 failures and the build succeeds.
- [ ] **Step 5: Commit** with the message `Postgres Stage 4 Task 4: Privileges tab and applying across databases`.
