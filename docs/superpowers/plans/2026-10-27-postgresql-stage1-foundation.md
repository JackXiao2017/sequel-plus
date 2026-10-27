# PostgreSQL Support, Stage 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect to PostgreSQL 12 to 18 over TCP/IP, socket or SSH from a Postgres favorite, and
open a separate PostgreSQL window with the Sequel Pro look, toolbar, database picker, and a left
panel listing schemas, tables, views and extensions.

**Architecture:** A new arm64 build of libpq feeds the existing `Frameworks/PostgresKit`
framework, which is linked into the app. All app-side Postgres code lives in a new
`Source/Postgres/` group (favorites store, connector, catalog queries, window, sidebar), separate
from the MySQL controllers. The connection screen only gains additions: an engine choice and a
Postgres favorites section. MySQL code paths run exactly as before when MySQL is selected. Tests
are a new app-hosted XCTest target, `Postgres Tests` (no OCMock, which is x86_64-only), run
against throwaway Docker Postgres 12 and 18 servers.

**Tech Stack:** Objective-C (manual retain/release, matching the codebase), AppKit, libpq 18
(static, arm64), libpqtypes, PostgresKit, XCTest, Docker (OrbStack), the Ruby `xcodeproj` gem
for project edits.

**Spec:** `docs/superpowers/specs/2026-10-27-postgresql-support-design.md`

## Roadmap (one plan per stage; each stage ends usable)

1. **Foundation** (this plan): connect, Postgres window, left panel, console log.
2. **Data**: Content tab (browse, filter, sort, edit rows), Query tab, History, Duplicate Table….
3. **Structure**: Structure (column, index and constraint editing), Relations, Triggers, Table Info.
4. **Users**: the Postgres role sheet (General, Membership, Privileges, default privileges).
5. **Extensions**: install, change version, drop.
6. **Import / Export**: SQL dumps and CSV.
7. **Transfer**: tables or whole database to another server, with both target modes.

Stages 2 to 7 get their own plans, written when the previous stage is working.

## Global Constraints

- PostgreSQL server versions **12 through 18** must work. Every catalog test runs on both 12 and 18.
- Build: `ARCHS=arm64`, `MACOSX_DEPLOYMENT_TARGET=12.0`. App build command:
  `xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build`.
- **Never break MySQL**: with no Postgres favorite involved, the connection screen, favorites,
  SSH tunnel and MySQL window behave exactly as before. Existing favorites load unchanged.
- **Never write `~/Library/Application Support/Sequel Pro/Data/Favorites.plist`** from Postgres
  code. The original Sequel Pro 1.1.2 reads it. Postgres favorites go to `PostgresFavorites.plist`
  in the same folder.
- Postgres keychain item names start with `Sequel Pro (PostgreSQL)` so they never collide with
  the old app's `Sequel Pro : …` names.
- Manual retain/release, like the surrounding code. No ARC in app sources.
- Identifiers sent to the server are always quoted (`"…"`, with embedded `"` doubled) or passed as
  `$n` parameters. Never interpolate raw names.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Favorites.plist untouched**: any Postgres favorite action (add, edit, delete, connect) must
   leave `Favorites.plist` byte-identical. Pinned in Task 5 and Task 9.
2. **Odd identifiers**: schemas and tables with mixed case, spaces and double quotes (`"Sales Data"`,
   `a"b`) must list correctly and not break queries. Pinned in Task 7.
3. **Connection failures**: wrong password, unreachable host, or no socket found must produce a
   readable error and never hang the UI or touch the MySQL tab. Pinned in Task 6.
4. **No `public` schema**: a database without `public` must still pick a default schema and list
   its tables. Pinned in Task 7.
5. **Existing MySQL favorites with no engine key** must still be treated as MySQL and connect as
   before. Pinned in Task 9.

---

### Task 0: Project repository and baseline

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Initialise a git repository in the project folder.**
  Run `git init` in `~/workspace_ios/sequelpro-forked`, so the project gets its own repository
  instead of being part of the home-directory repo.
- [ ] **Step 2: Write `.gitignore`.** Ignore: `build/`, `.superpowers/`, `*.xcuserstate`,
  `xcuserdata/`, `.DS_Store`, `img.png`.
- [ ] **Step 3: Verify the app still builds.** Run the app build command. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Commit the baseline.** `git add -A && git commit -m "Baseline: arm64 port before PostgreSQL work"`.
  This is the MySQL reference point for every later regression check.

### Task 1: arm64 libpq and libpqtypes

**Files:**
- Modify: `Frameworks/PostgresKit/Scripts/build-libpq.sh` (rewrite)
- Replace: `Frameworks/PostgresKit/Libs/libpq/lib/libpq.a`, `Frameworks/PostgresKit/Libs/libpq/include/*`
- Create: `Frameworks/PostgresKit/Libs/libpq/lib/libpgcommon.a`, `libpgport.a`
- Replace: `Frameworks/PostgresKit/Libs/libpqtypes/lib/libpqtypes.a`, `include/libpqtypes.h`

**Interfaces:**
- Produces: static arm64 `libpq.a` (+ `libpgcommon.a`, `libpgport.a`) from PostgreSQL **18.x**
  source, and `libpqtypes.a`. Both link against the static OpenSSL already bundled at
  `Frameworks/SPMySQLFramework/MySQL Client Libraries/lib/libssl.a` and `libcrypto.a`.

- [ ] **Step 1: Rewrite `build-libpq.sh`.** It downloads the PostgreSQL 18 source tarball and
  configures it with `--with-ssl=openssl --without-icu --without-readline --without-gssapi --without-zlib`,
  `CFLAGS="-arch arm64 -mmacosx-version-min=12.0"`, with the OpenSSL include path from
  `/opt/homebrew/opt/openssl@4`. It builds only `src/interfaces/libpq`, `src/common` and
  `src/port`, then copies the `.a` files and `libpq-fe.h`, `postgres_ext.h` and `pg_config_ext.h`
  into `Libs/libpq`. Next it clones `https://github.com/merlinm/libpqtypes` at a fixed tag and
  builds it statically for arm64 against those headers, copying the results into `Libs/libpqtypes`.
  Work in a temporary directory, never in the repo.
- [ ] **Step 2: Run it.** `bash Frameworks/PostgresKit/Scripts/build-libpq.sh`.
- [ ] **Step 3: Verify the architectures.** `lipo -info` on all four `.a` files. Expected: `architecture: arm64`, each.
- [ ] **Step 4: Verify symbols.** `nm Libs/libpq/lib/libpq.a | grep -c " T _PQconnectdbParams"` gives 1,
  and `nm Libs/libpqtypes/lib/libpqtypes.a | grep -c " T _PQinitTypes"` gives 1.
- [ ] **Step 5: Commit.** `git commit -m "PostgresKit: arm64 libpq 18 and libpqtypes"`.

### Task 2: PostgresKit builds for arm64, gains SSL, and passes integration tests on 12 and 18

**Files:**
- Create: `Scripts/pg-test-servers.sh`
- Modify: `Frameworks/PostgresKit/PostgresKit.xcodeproj/project.pbxproj` (build settings, link libs)
- Modify: `Frameworks/PostgresKit/Source/PGPostgresConnection.h` / `.m`
- Modify: `Frameworks/PostgresKit/Tests/PGPostgresIntegrationTestCase.m`
- Create: `Frameworks/PostgresKit/Tests/PGPostgresSSLTests.m`

**Interfaces:**
- Produces: `Scripts/pg-test-servers.sh up|down|psql <port>`:
  - `postgres:12` on port **55412** with SSL **off**;
  - `postgres:18` on port **55418** with SSL **on** (self-signed certificate generated at
    startup, `-c ssl=on`).

  Both use user `pgkit_test`, password `pgkit`, database `pgkit_test`, and the user is a
  superuser. Container names: `sp-pg12`, `sp-pg18`.
- Produces on `PGPostgresConnection`: `@property (readwrite, retain) NSString *sslMode;` (nil means
  libpq's default), plus `sslRootCertPath`, `sslCertPath` and `sslKeyPath` (`NSString *`). These
  are passed as the libpq `sslmode`, `sslrootcert`, `sslcert` and `sslkey` parameters when non-nil.
- Test port: `PGPostgresIntegrationTestCase` reads the port from the environment variable
  `PGKIT_TEST_PORT` (default 55418).

- [ ] **Step 1: Write `pg-test-servers.sh`** with the containers above. `up` waits until
  `pg_isready` succeeds in each container.
- [ ] **Step 2: Update the PostgresKit project.** `ARCHS=arm64`, `MACOSX_DEPLOYMENT_TARGET=12.0`.
  Link `libpq.a`, `libpgcommon.a`, `libpgport.a`, `libpqtypes.a` and the bundled `libssl.a` and
  `libcrypto.a`. Remove ppc and i386 settings.
- [ ] **Step 3: Write the failing tests** in `PGPostgresSSLTests` (subclass of `XCTestCase`, own connections):
  - `testRequireSSLConnectsToSSLServer`: port 55418, `sslMode = @"require"`. `connect` returns YES,
    and `SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()` returns true.
  - `testRequireSSLFailsAgainstNonSSLServer`: port 55412, `sslMode = @"require"`. `connect` returns
    NO, and `connectionError` contains `"SSL"`.
  - `testPreferSSLConnectsToNonSSLServer`: port 55412, `sslMode = @"prefer"`. `connect` returns YES.
- [ ] **Step 4: Run them and confirm they fail.**
  `bash Scripts/pg-test-servers.sh up && (cd Frameworks/PostgresKit && make test)`. Expected: build
  error (`sslMode` not found).
- [ ] **Step 5: Implement the SSL properties and the `PGKIT_TEST_PORT` lookup.**
- [ ] **Step 6: Run the whole PostgresKit suite on both servers.**
  `(cd Frameworks/PostgresKit && make test)`, then
  `(cd Frameworks/PostgresKit && TEST_RUNNER_PGKIT_TEST_PORT=55412 make test)`. Expected:
  `** TEST SUCCEEDED **` both times. Fix any PostgresKit incompatibility with servers 12 or 18
  that the existing data-type tests expose.
- [ ] **Step 7: Commit.** `git commit -m "PostgresKit: arm64 build, SSL options, tests on PG 12 and 18"`.

### Task 3: Wire PostgresKit into the app and add the `Postgres Tests` target

**Files:**
- Create: `Scripts/pg-xcodeproj.rb`
- Modify: `sequel-pro.xcodeproj/project.pbxproj` (generated by the script only, never hand-edited)
- Create: `sequel-pro.xcodeproj/xcshareddata/xcschemes/Postgres Tests.xcscheme`
- Create: `PostgresTests/SPPostgresTestServers.h` / `.m`, `PostgresTests/SPPostgresSmokeTests.m`, `PostgresTests/Info.plist`

**Interfaces:**
- Produces: `ruby Scripts/pg-xcodeproj.rb setup`, which is idempotent. It:
  - adds `Frameworks/PostgresKit/PostgresKit.xcodeproj` as a subproject;
  - makes "Sequel Pro" depend on, link and embed `PostgresKit.framework`;
  - creates the group `Source/Postgres`;
  - creates the app-hosted XCTest target `Postgres Tests` (`BUNDLE_LOADER` / `TEST_HOST` = the
    app, arm64, no OCMock) and its shared scheme.
- Produces: `ruby Scripts/pg-xcodeproj.rb add-app <files…>` adds sources to the "Sequel Pro"
  target under `Source/Postgres`. `ruby Scripts/pg-xcodeproj.rb add-test <files…>` adds them to
  `Postgres Tests`. Every later task adds its files this way.
- Produces: `SPPostgresTestServers` with
  `+ (NSArray<NSNumber *> *)ports` (returns `@[@55412, @55418]`) and
  `+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port` (user `pgkit_test`,
  password `pgkit`, database `pgkit_test`; fails the test if it can't connect).
- Test command for every later task:
  `xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64`.

- [ ] **Step 1: Write `pg-xcodeproj.rb`** using the `xcodeproj` gem (1.28 is installed).
- [ ] **Step 2: Run `ruby Scripts/pg-xcodeproj.rb setup`.**
- [ ] **Step 3: Write the smoke test.** `SPPostgresSmokeTests.testConnectsToEveryTestServer`: for
  each port, `connectedConnectionOnPort:` returns a connection, and `SELECT 1` returns one row
  with value `1`.
- [ ] **Step 4: Run the test command.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: MySQL regression check.** Run the app build command, launch the app, connect to an
  existing MySQL SSH favorite, and open a table's Content tab. Expected: same behaviour as the Task 0 baseline.
- [ ] **Step 6: Commit.** `git commit -m "Link PostgresKit into the app; add Postgres Tests target"`.

### Task 4: Share the compact window look with the Postgres window

**Files:**
- Create: `Source/NSWindow+SPCompactChrome.h` / `.m`
- Modify: `Source/SPDatabaseDocument.m` (remove `_applyCompactWindowTitleFont` and
  `SPCompactToolbarImage`, and call the category instead)
- Test: `PostgresTests/SPCompactChromeTests.m`

**Interfaces:**
- Produces:
  - `- (void)sp_applyCompactTitle;` on `NSWindow`. Same behaviour as today's
    `_applyCompactWindowTitleFont`: it hides the system title and shows a centred label with
    identifier `SPCompactWindowTitle`, using the small system font with medium weight.
  - `- (void)sp_useExpandedCompactToolbar;` on `NSWindow`. Sets `NSWindowToolbarStyleExpanded` and
    re-applies the title on every `NSWindowDidResizeNotification`.
  - `NSImage *SPCompactToolbarImage(NSImage *image)` (24×24 copy), declared in the header.

- [ ] **Step 1: Write the failing tests.**
  - `testCompactToolbarImageIs24pt`: a 32×32 image becomes `NSMakeSize(24, 24)`.
  - `testCompactTitleShowsWindowTitle`: a titled window with `title = @"(PostgreSQL 18.0) x/y"`
    and `sp_applyCompactTitle` has a titlebar subview with identifier `SPCompactWindowTitle`, whose
    `stringValue` equals the title, and `titleVisibility == NSWindowTitleHidden`.
- [ ] **Step 2: Run them and confirm they fail.** Run the test command. Expected: build error (category missing).
- [ ] **Step 3: Move the code into the category,** and switch `SPDatabaseDocument.m` to call it.
  Behaviour must not change.
- [ ] **Step 4: Run the tests.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: MySQL visual regression check.** Launch the app and take screenshots of the
  connection screen and a connected MySQL window. Compare them with the screenshots from before
  the change. Expected: identical title, toolbar, tabs and side panel.
- [ ] **Step 6: Commit.**

### Task 5: Postgres favorites model and store

**Files:**
- Create: `Source/Postgres/SPPostgresFavorite.h` / `.m`, `Source/Postgres/SPPostgresFavoritesStore.h` / `.m`
- Test: `PostgresTests/SPPostgresFavoritesStoreTests.m`

**Interfaces:**
- Produces: `typedef NS_ENUM(NSInteger, SPPostgresConnectionType) { SPPostgresTCPIPConnection = 0, SPPostgresSocketConnection = 1, SPPostgresSSHConnection = 2 };`
- Produces: `SPPostgresFavorite : NSObject <NSCopying>`. Properties:
  - `NSString *favoriteID` (a UUID string, set on init);
  - `name`;
  - `NSInteger colorIndex` (-1 means none);
  - `SPPostgresConnectionType type`;
  - `host`;
  - `NSUInteger port` (default **5432**);
  - `user`, `database`, `socketPath`;
  - `BOOL useSSL`, plus `sslCACertPath`, `sslCertPath`, `sslKeyPath`;
  - `sshHost`, `sshUser`;
  - `NSUInteger sshPort` (0 means default);
  - `sshKeyPath`.

  Methods:
  - `- (NSDictionary *)dictionaryRepresentation;`
  - `+ (instancetype)favoriteWithDictionary:(NSDictionary *)dictionary;`
  - `- (NSString *)keychainName;` returns `@"Sequel Pro (PostgreSQL) : <name> (<favoriteID>)"`;
  - `- (NSString *)keychainAccount;` returns `@"<user>@<host>/<database>"`;
  - `- (NSString *)sshKeychainName;` returns `@"Sequel Pro (PostgreSQL) SSHTunnel : <name> (<favoriteID>)"`;
  - `- (NSString *)sshKeychainAccount;` returns `@"<sshUser>@<sshHost>"`.
- Produces: `SPPostgresFavoritesStore : NSObject` with:
  - `- (instancetype)initWithFileURL:(NSURL *)fileURL;`
  - `+ (instancetype)sharedStore;` backed by `~/Library/Application Support/Sequel Pro/Data/PostgresFavorites.plist`;
  - `- (NSArray *)favorites;` (sorted by name, case-insensitive);
  - `- (BOOL)saveFavorite:(SPPostgresFavorite *)favorite error:(NSError **)error;` (insert, or replace by ID);
  - `- (BOOL)removeFavoriteWithID:(NSString *)favoriteID error:(NSError **)error;`

  The file format is a plist dictionary `{ "version": 1, "favorites": [ … ] }`. It posts
  `SPPostgresFavoritesDidChangeNotification` after each successful write.

- [ ] **Step 1: Write the failing tests** (each test uses a temporary directory):
  - `testRoundTripPreservesEveryField`
  - `testSaveReplacesFavoriteWithSameID`
  - `testRemoveDeletesOnlyThatFavorite`
  - `testMissingFileMeansNoFavorites`
  - `testNeverTouchesMySQLFavoritesFile`: put a copy of a `Favorites.plist` next to the store's
    file, perform saves and removes, and assert the copy's bytes are unchanged.
  - `testKeychainNamesUsePostgresPrefix`: `keychainName` has the prefix `Sequel Pro (PostgreSQL) : `.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement both classes.** Write atomically with `-[NSDictionary writeToURL:atomically:YES]`.
- [ ] **Step 4: Run the tests.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit.**

### Task 6: Connector (TCP/IP, socket, SSH, SSL)

**Files:**
- Create: `Source/Postgres/SPPostgresConnector.h` / `.m`, `Source/Postgres/SPPostgresErrors.h` / `.m`
- Test: `PostgresTests/SPPostgresConnectorTests.m`

**Interfaces:**
- Consumes: `SPPostgresFavorite` (Task 5), `PGPostgresConnection` with `sslMode` (Task 2), and
  `SPSSHTunnel` (`initToHost:port:login:tunnellingToPort:onHost:`, `setConnectionStateChangeSelector:delegate:`,
  `setPassword:`, `setPasswordKeychainName:account:`, `setKeyFilePath:`, `setParentWindow:`,
  `connect`, `state`, `localPort`, `lastError`, `disconnect`).
- Produces: `extern NSString * const SPPostgresErrorDomain;` with codes
  `SPPostgresErrorConnectionFailed = 1`, `SPPostgresErrorSSHTunnelFailed = 2`,
  `SPPostgresErrorNoSocket = 3`, `SPPostgresErrorCancelled = 4`.
- Produces: `SPPostgresConnector : NSObject` with:
  - `- (instancetype)initWithFavorite:(SPPostgresFavorite *)favorite password:(NSString *)password sshPassword:(NSString *)sshPassword parentWindow:(NSWindow *)parentWindow;`
  - `- (void)connectWithCompletion:(void (^)(PGPostgresConnection *connection, NSError *error))completion;`
    The completion is always called once, on the main thread. Connecting runs off the main thread.
  - `- (void)cancel;` and `- (void)disconnect;` (closes the connection and the tunnel);
  - `@property (readonly) SPSSHTunnel *tunnel;`
  - `+ (NSArray *)defaultSocketDirectories;` returns `@[@"/tmp", @"/var/run/postgresql", @"/opt/homebrew/var/run/postgresql"]`;
  - `+ (NSString *)socketDirectoryForPort:(NSUInteger)port searchDirectories:(NSArray *)directories;`
    returns the first directory containing `.s.PGSQL.<port>`, or nil.

  Behaviour:
  - SSL: `useSSL` YES sends `sslMode = @"require"`, NO sends `@"prefer"`. The certificate paths are
    passed through when set.
  - Socket: an explicit `socketPath` wins. Otherwise the directory comes from
    `socketDirectoryForPort:searchDirectories:`; if that finds nothing, return
    `SPPostgresErrorNoSocket`.
  - SSH: start `SPSSHTunnel` to `host:port` and connect to `127.0.0.1:<tunnel localPort>`.
  - Connect timeout: 10 seconds. The application name sent to the server is `Sequel Pro`.

- [ ] **Step 1: Write the failing tests.**
  - `testTCPConnectsOnBothServers` (55412 and 55418).
  - `testWrongPasswordReportsConnectionFailedWithServerMessage`: code 1, and `localizedDescription`
    contains `password authentication failed`.
  - `testUnreachableHostFailsWithinTimeout`: host `10.255.255.1`; the completion arrives within 15 s
    with code 1.
  - `testSSLRequiredAgainstNonSSLServerFails` (55412, `useSSL = YES`).
  - `testSocketDirectoryFindsFirstMatch`: two temp directories; the second contains an empty file
    `.s.PGSQL.5432`; that one is returned.
  - `testSocketDirectoryNilWhenNoneMatch`.
  - `testSocketTypeWithNoSocketReportsNoSocketError`: socket type, no `socketPath`, port 59999, code 3.
  - `testCompletionRunsOnMainThread`.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the connector.**
- [ ] **Step 4: Run the tests.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Manual SSH check.** Connect to one of the owner's Postgres servers through SSH by
  calling the connector from a temporary test with real details. Expected: `SELECT version()`
  returns. Delete the temporary test afterwards.
- [ ] **Step 6: Commit.**

### Task 7: Catalog queries for the left panel and toolbar

**Files:**
- Create: `Source/Postgres/SPPostgresCatalog.h` / `.m`
- Create: `PostgresTests/Fixtures/catalog.sql`
- Test: `PostgresTests/SPPostgresCatalogTests.m`

**Interfaces:**
- Consumes: `PGPostgresConnection -execute:values:`, `PGPostgresResult`, `lastError`.
- Produces: `SPPostgresCatalog : NSObject` with:
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection;`
  - `- (NSString *)serverVersionString;` (the `server_version` setting, e.g. `@"18.0"`);
  - `- (NSArray *)databaseNames:(NSError **)error;` (`datallowconn AND NOT datistemplate`, sorted);
  - `- (NSArray *)schemaNames:(NSError **)error;` (excluding `pg_catalog`, `information_schema`,
    `pg_toast*` and `pg_temp_*`, sorted);
  - `- (NSString *)defaultSchemaFromSchemas:(NSArray *)schemas;` (`public` if present, else the
    first of `current_schemas(false)` that is present, else the first in the list, else nil);
  - `- (NSArray *)tableNamesInSchema:(NSString *)schema error:(NSError **)error;` (`relkind IN ('r','p')`, sorted);
  - `- (NSArray *)viewNamesInSchema:(NSString *)schema error:(NSError **)error;` (`relkind IN ('v','m')`, sorted);
  - `- (NSArray *)installedExtensions:(NSError **)error;` (dictionaries with keys `@"name"` and
    `@"version"`, from `pg_extension`, sorted by name).

  All schema arguments go in as `$1` parameters.
- Fixture `catalog.sql` (run at test setUp on each server, idempotent):
  - schemas `public`, `"Sales Data"` and `a"b`;
  - tables `public.customers`, `"Sales Data"."Orders 2026"`, `a"b."x"`;
  - view `public.v_customers`;
  - extension `pg_trgm`;
  - a second database `pgkit_nopublic` whose only schema is `app` (with `public` dropped),
    containing table `app.items`.

- [ ] **Step 1: Write the failing tests.** Each runs on both ports.
  - `testSchemasIncludeOddNamesAndExcludeSystemSchemas`: contains `public`, `Sales Data` and `a"b`;
    excludes `pg_catalog` and `information_schema`.
  - `testTablesInOddlyNamedSchema`: `tableNamesInSchema:@"Sales Data"` is `@[@"Orders 2026"]`,
    and `@"a\"b"` gives `@[@"x"]`.
  - `testViewsListed`: `public` gives `@[@"v_customers"]`.
  - `testExtensionsIncludeVersion`: contains name `pg_trgm` with a non-empty version.
  - `testDefaultSchemaPrefersPublic`.
  - `testDefaultSchemaWithoutPublic`: on `pgkit_nopublic` the result is `app`, and
    `tableNamesInSchema:@"app"` is `@[@"items"]`.
  - `testServerVersionMatchesPort`: 55412 starts with `12.`, 55418 starts with `18.`.
  - `testDatabaseNamesExcludeTemplates`: contains `pgkit_test` and not `template0`.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement `SPPostgresCatalog`.**
- [ ] **Step 4: Run the tests.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit.**

### Task 8: The PostgreSQL window and left panel

**Files:**
- Create: `Source/Postgres/SPPostgresWindowController.h` / `.m`, `Source/Postgres/SPPostgresSidebarController.h` / `.m`,
  `Source/Postgres/SPPostgresConsoleLogger.h` / `.m`
- Test: `PostgresTests/SPPostgresWindowTests.m`

**Interfaces:**
- Consumes: `SPPostgresCatalog` (Task 7), `SPPostgresConnector` (Task 6), `NSWindow+SPCompactChrome` (Task 4),
  `PSMTabBarControl` with style `@"SequelPro"`, `SPSplitView`, and `SPQueryController -showMessageInConsole:connection:database:`.
- Produces: toolbar identifier constants `SPPostgresToolbarDatabase`, `…Structure`, `…Content`,
  `…Relations`, `…Triggers`, `…TableInfo`, `…Query`, `…Users`, `…Transfer`, `…History`, `…Console`.
- Produces: `SPPostgresWindowController : NSWindowController` with:
  - `- (instancetype)initWithConnection:(PGPostgresConnection *)connection connector:(SPPostgresConnector *)connector favorite:(SPPostgresFavorite *)favorite;`
  - `- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;` returns, in exactly this
    order: Database, Structure, Content, Relations, Triggers, TableInfo, Query,
    `NSToolbarFlexibleSpaceItemIdentifier`, Users, Transfer, History, Console;
  - `- (NSString *)windowTitleString;` returns `@"(PostgreSQL <serverVersion>) <favorite name>/<database>"`,
    with `@"/<schema>.<table>"` appended when a table is selected;
  - `@property (readonly) SPPostgresSidebarController *sidebar;`

  In stage 1, Structure, Content, Relations, Triggers, TableInfo, Query, Users, Transfer and
  History are present but disabled. Console toggles the shared console window. The database
  picker lists `databaseNames:`; choosing another database reconnects through a new connector with
  the same favorite and that database (Postgres can't switch databases in a session).
- Produces: `SPPostgresSidebarController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>` with:
  - `- (instancetype)initWithCatalog:(SPPostgresCatalog *)catalog;`
  - `- (NSView *)view;` (schema popup on top, outline below);
  - `- (void)reloadSchema:(NSString *)schema;`
  - `- (NSArray *)sectionTitles;` returns `@[@"TABLES", @"VIEWS", @"EXTENSIONS"]`, in that order;
    Extensions is last, as the spec requires;
  - `- (NSArray *)itemTitlesInSection:(NSString *)sectionTitle;`
  - `@property (readonly) NSString *selectedSchema;`
  - `@property (readonly) NSString *selectedTableName;`
- Produces: `SPPostgresConsoleLogger : NSObject <PGPostgresConnectionDelegate>`. Its
  `connection:willExecute:withValues:` forwards the query text to `showMessageInConsole:` with the
  favorite name and database.
- Look: the left panel is an `SPSplitView` with autosave name `PGViewSplitter`, left pane 250 pt
  by default. There's a PSMTabBar with one tab labelled with the favorite name, plus the compact
  title and toolbar from Task 4.

- [ ] **Step 1: Write the failing tests** (app-hosted, against port 55418 with the Task 7 fixture):
  - `testToolbarOrderMatchesSpec`.
  - `testTitleIncludesVersionFavoriteAndDatabase`: the title has the prefix `(PostgreSQL 18.` and
    ends with `/pgkit_test`.
  - `testSidebarSectionsEndWithExtensions`.
  - `testSidebarListsTablesViewsAndExtensionsForPublic`: TABLES contains `customers`, VIEWS contains
    `v_customers`, EXTENSIONS contains `pg_trgm`.
  - `testSwitchingSchemaReloadsTables`: `reloadSchema:@"Sales Data"` makes TABLES `@[@"Orders 2026"]`.
  - `testConsoleLoggerForwardsQueries`: after `SELECT 42`, the shared console's message list
    contains `SELECT 42`.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the window, sidebar and logger.** Build the window in code, without a new xib.
- [ ] **Step 4: Run the tests.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Visual check.** Open a window against 55418 and take a screenshot. Compare it with the
  approved mockup `.superpowers/brainstorm/*/content/postgres-window-v3.html` and with the MySQL
  window: same title row, same toolbar look, rounded tab, and left panel order
  schema → tables → views → extensions.
- [ ] **Step 6: Commit.**

### Task 9: Connection screen integration

**Files:**
- Modify: `Source/SPConnectionController.m`, `Source/SPConnectionController.h` (additions only)
- Create: `Source/Postgres/SPPostgresConnectionScreenAdapter.h` / `.m`
- Test: `PostgresTests/SPPostgresConnectionScreenAdapterTests.m`

**Interfaces:**
- Consumes: `SPPostgresFavoritesStore` (Task 5), `SPPostgresConnector` (Task 6), `SPPostgresWindowController` (Task 8).
- Produces: `typedef NS_ENUM(NSInteger, SPConnectionEngine) { SPConnectionEngineMySQL = 0, SPConnectionEnginePostgreSQL = 1 };`
- Produces: `SPPostgresConnectionScreenAdapter : NSObject`, which owns all Postgres logic on the
  connection screen so that `SPConnectionController` only calls into it:
  - `- (instancetype)initWithConnectionController:(SPConnectionController *)controller store:(SPPostgresFavoritesStore *)store;`
  - `- (NSSegmentedControl *)engineControl;` with segments "MySQL" and "PostgreSQL", placed
    centred above the TCP/IP | Socket | SSH tabs;
  - `- (SPConnectionEngine)selectedEngine;`
  - `- (NSArray *)favoriteNodesForOutline;` returns the Postgres favorites for a separate
    **"POSTGRESQL"** section shown below the existing FAVORITES section;
  - `- (BOOL)isPostgresNode:(id)outlineItem;`
  - `- (void)loadFavoriteIntoForm:(SPPostgresFavorite *)favorite;` (sets the engine to PostgreSQL;
    the port default becomes 5432);
  - `- (SPPostgresFavorite *)favoriteFromForm;`
  - `- (BOOL)saveFormAsFavorite:(NSError **)error;`
  - `- (void)connectFromForm;` reads the passwords from the form or the keychain (Postgres names),
    runs `SPPostgresConnector`, opens `SPPostgresWindowController` on success, and shows an error
    sheet on the MySQL window on failure. The MySQL tab stays on its connection screen either way.

  Rules for `SPConnectionController`:
  - Each change is a guarded branch `if ([postgresAdapter selectedEngine] == SPConnectionEnginePostgreSQL || [postgresAdapter isPostgresNode:item]) { … return; }`
    placed at the top of `initiateConnection:`, `saveFavorite:`, `addFavorite:`, `removeNode:`,
    `duplicateFavorite:` and the outline data-source and selection methods.
  - With MySQL selected and a MySQL node, every existing line runs unchanged.
  - Favorites with no engine key are MySQL.

- [ ] **Step 1: Write the failing tests.**
  - `testFormRoundTripsFavorite`: loading a favorite into the form and reading it back keeps every field.
  - `testSavingPostgresFavoriteWritesOnlyPostgresStore`: the adapter uses a temp store, and the
    MySQL `Favorites.plist` (a temp copy given to the controller under test) is byte-identical afterwards.
  - `testMySQLFavoriteWithoutEngineKeyIsNotPostgres`: `isPostgresNode:` is NO for a node built from
    a MySQL favorite dictionary with no engine key.
  - `testEngineSwitchSetsDefaultPort`: switching to PostgreSQL with an empty port shows 5432;
    switching back to MySQL shows 3306.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the adapter and the guarded branches.**
- [ ] **Step 4: Run the tests.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: End-to-end check.**
  1. Create a TCP/IP Postgres favorite for 55418, connect, and confirm the window opens.
  2. Create an SSH Postgres favorite for one of the owner's servers, connect, and confirm the window opens.
  3. Quit and relaunch: both favorites are still listed under POSTGRESQL.
  4. `diff` `Favorites.plist` against a copy taken before step 1. Expected: no difference.
  5. Launch `/Applications/Sequel Pro.app` (1.1.2) and confirm its favorites list is unchanged.
- [ ] **Step 6: MySQL regression check.** Connect to an existing MySQL SSH favorite, browse a
  table, and run a query. Also add, rename and delete a throwaway MySQL favorite. Expected: same as
  the Task 0 baseline.
- [ ] **Step 7: Commit.** `git commit -m "Connection screen: PostgreSQL engine choice and favorites"`.
