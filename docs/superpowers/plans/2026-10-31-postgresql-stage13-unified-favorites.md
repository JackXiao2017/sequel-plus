# Stage 13: One FAVORITES List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Postgres favorites inside the connection screen's FAVORITES list, at positions the owner sets by
dragging (between MySQL favorites, in MySQL groups), remembered across launches, without ever putting them in
`Favorites.plist`.

**Architecture:**
- **The merge is display-only.**
  - `SPFavoritesController`'s MySQL tree is never given a Postgres node.
  - A new pure class, `SPPostgresFavoritesLayout`, keeps the *displayed* children of each MySQL group: the
    MySQL children, with Postgres nodes inserted where their saved placements say.
  - The connection screen's outline data source, drag and drop, and sort work on those displayed children.
  - Writes go back through the layout, which hands each MySQL group only its MySQL children.
- **Placements:**
  - What is saved: the group path, the MySQL item before the Postgres favorite, a fallback index and an order.
  - Where: a new `PostgresFavoritePlacements.plist`, beside `PostgresFavorites.plist`.
  - When they are worked out again: on every outline reload.
  - When they are saved: after every change this window makes.

**Tech Stack:** Objective-C (MRC in app sources, ARC in "Postgres Tests"), AppKit `NSOutlineView`, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-31-postgresql-unified-favorites-design.md` (approved 2026-10-31)

## Global Constraints

- Never write `~/Library/Application Support/Sequel Pro/Data/Favorites.plist` from Postgres code, and never let a
  Postgres node into `SPFavoritesController`'s tree (`favoritesTree`). Its save, export, import, the General
  preferences "Default favorite" pop-up and favorites menus stay MySQL-only.
- With no Postgres favorites, every MySQL path behaves exactly as before:
  - The controller calls the new adapter methods only behind `[postgresAdapter hasPostgresFavorites]` or another
    Postgres guard.
  - MySQL source edits are limited to those guarded calls, plus the one comparator helper in Task 5.
- Tests never touch real `Favorites.plist`, `PostgresFavorites.plist`, `PostgresFavoritePlacements.plist`, real
  preferences, the login keychain or the general pasteboard. Stores in tests use temp-directory URLs.
- MRC in `Source/Postgres`; ARC in "Postgres Tests". Exported classes use
  `__attribute__((visibility("default")))`. Add files only with `ruby Scripts/pg-xcodeproj.rb add-app <path>` /
  `add-test <path>`.
- Never touch the owner's untracked `start_clause.sh`. Never launch the GUI app. Never kill processes you didn't
  start.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Test command:**
  ```
  timeout 1500 xcodebuild test -project sequel-pro.xcodeproj -scheme "Postgres Tests" -derivedDataPath build/DerivedData ARCHS=arm64
  ```
  - For one class, add `-only-testing:"Postgres Tests/<Class>"`.
  - Start the servers first with `bash Scripts/pg-test-servers.sh up`; existing classes need them.
- **App build:**
  ```
  xcodebuild -project sequel-pro.xcodeproj -scheme "Sequel Pro" -configuration Debug -derivedDataPath build/DerivedData ARCHS=arm64 build
  ```

## Placement record (shared by Tasks 1–4)

A placement is an `NSDictionary`, keyed in the file by the Postgres favorite's `favoriteID` (a UUID string):

| Key | Value |
|---|---|
| `Group` | `NSArray` of `@{@"Name": NSString, @"Nth": NSNumber}`, from the FAVORITES section down. `@[]` = top level. `Nth` = how many earlier sibling *groups* have the same name. |
| `After` | Absent = first in the group. `@{@"FavoriteID": NSNumber}` = after that MySQL favorite (its `SPFavoriteIDKey`). `@{@"GroupName": NSString, @"Nth": NSNumber}` = after that sibling group. |
| `Index` | `NSNumber`: how many MySQL siblings came before it when saved. This is the fallback when `After` is gone. |
| `Order` | `NSNumber`: its position among Postgres favorites that share the same `Group` and `After`. |

**Resolution:**

1. **Find the group.**
   - Walk `Group` from the section node, matching name and Nth among child groups.
   - Any step missing: top level, appended at the end, after every MySQL child.
2. **Find the slot within the group.**
   - `After` names a direct MySQL child of that group: insert right after it.
   - `After` is gone: insert before the MySQL child at `min(Index, count)`.
   - `After` absent: insert at the start.
3. **Several Postgres favorites in one slot:** ascending `Order`, then name, case-insensitive.
4. **Postgres favorites with no placement** (for example, an old file): end of the top level, in the store's
   name order.

---

### Task 1: Placements store

**Files:**
- Create: `Source/Postgres/SPPostgresFavoritePlacementsStore.h`, `Source/Postgres/SPPostgresFavoritePlacementsStore.m`
- Modify: `Source/Postgres/SPPostgresFavoritesStore.{h,m}` (add `-fileURL`)
- Test: `PostgresTests/SPPostgresFavoritePlacementsStoreTests.m`

**Interfaces:**
- Produces:
  ```objc
  extern NSString * const SPPostgresFavoritePlacementsDidChangeNotification; // object: the store, posted after each write
  @interface SPPostgresFavoritePlacementsStore : NSObject
  - (instancetype)initWithFileURL:(NSURL *)fileURL;
  /// The store beside `favoritesStore`'s file: same directory, "PostgresFavoritePlacements.plist".
  + (instancetype)storeBesideFavoritesStore:(SPPostgresFavoritesStore *)favoritesStore;
  /// favoriteID -> placement record; reread from disk on each call; empty when missing/unreadable/newer.
  - (NSDictionary *)placements;
  /// Replaces all placements (atomic write). Refuses (NO, error) when the file on disk is unreadable or newer.
  - (BOOL)setPlacements:(NSDictionary *)placements error:(NSError **)error;
  @end
  // SPPostgresFavoritesStore gains: - (NSURL *)fileURL;
  ```
- **File format:** a dictionary `{ "Version": 1, "Placements": { id: record } }`, written as an XML plist.

- [ ] **Step 1: Write failing tests** in `SPPostgresFavoritePlacementsStoreTests` (ARC, temp directory per test):
  - `testMissingFileHasNoPlacements`: `placements` is `@{}`.
  - `testRoundTrip`:
    - Set `@{@"A": rec1, @"B": rec2}`, where rec1 has a two-level `Group` and `After` FavoriteID `@7`, and rec2 has
      `Group @[]` and no `After`.
    - A new store on the same URL returns an equal dictionary.
  - `testWritePostsNotification`: XCTNSNotificationExpectation on the store object.
  - `testNewerVersionIsNotOverwritten`:
    - Write `{Version: 2, Placements: {}}` by hand.
    - `placements` is empty, `setPlacements:` returns NO with an error, and the file bytes are unchanged.
  - `testBesideFavoritesStore`: the favorites store at `dir/PostgresFavorites.plist` gives the placements URL
    `dir/PostgresFavoritePlacements.plist`.
- [ ] **Step 2: Run** with `-only-testing:"Postgres Tests/SPPostgresFavoritePlacementsStoreTests"`.
  Expected: FAIL (the class doesn't exist).
- [ ] **Step 3: Implement** the store. Follow `SPPostgresFavoritesStore.m`'s read, version and atomic-write
  patterns. `+storeBesideFavoritesStore:` uses the favorites store's new `-fileURL`. Add both files with
  `add-app`, and the test with `add-test`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit:** "Postgres favorites: a placements store beside PostgresFavorites.plist".

### Task 2: Favorite node class and layout resolve/snapshot

**Files:**
- Create: `Source/Postgres/SPPostgresFavoriteNode.{h,m}`. Move `SPPostgresFavoriteNode` out of
  `SPPostgresConnectionScreenAdapter.m` unchanged, and add the sort value below.
- Create: `Source/Postgres/SPPostgresFavoritesLayout.{h,m}`
- Modify: `Source/Postgres/SPPostgresConnectionScreenAdapter.m` (import the new header; delete the moved class)
- Test: `PostgresTests/SPPostgresFavoritesLayoutTests.m`

**Interfaces:**
- Produces:
  ```objc
  @interface SPPostgresFavoriteNode : NSObject <SPNamedNode>   // as today: favorite, nodeName, nodeFavorite (nil)
  @property (nonatomic, retain) SPPostgresFavorite *favorite;
  /// Value for MySQL's favorites sort keys: SPFavoriteNameKey -> name; SPFavoriteHostKey -> host
  /// ("localhost" for a socket favorite); SPFavoriteTypeKey -> @(100 + type), so Postgres sorts after
  /// MySQL's types; SPFavoriteColorIndexKey -> @(colorIndex); any other key -> nil.
  - (id)postgresSortValueForKey:(NSString *)key;
  @end

  /// The sort value of any favorites-tree node: a Postgres node's -postgresSortValueForKey:, else
  /// [[[node representedObject] nodeFavorite] objectForKey:key] (MySQL's existing lookup).
  extern id SPFavoritesSortValueForNode(SPTreeNode *node, NSString *key);

  @interface SPPostgresFavoritesLayout : NSObject
  /// `section`: the MySQL FAVORITES section node (first child of favoritesTree). `postgresNodes`: every
  /// Postgres favorite node, in the store's name order. Replaces the whole arrangement (see Resolution).
  - (void)resolveWithMySQLSection:(SPTreeNode *)section postgresNodes:(NSArray *)postgresNodes placements:(NSDictionary *)placements;
  /// The displayed children of a MySQL group (or of the section): its childNodes with Postgres nodes inserted.
  /// Exactly [group childNodes] when no Postgres node is there.
  - (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group;
  /// The MySQL group a Postgres node is displayed in (the section for the top level); for a MySQL node, its parentNode.
  - (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node;
  /// Postgres nodes displayed in `group` and all its subgroups.
  - (NSArray *)postgresNodesWithinGroup:(SPTreeNode *)group;
  - (BOOL)hasPostgresNodes;
  /// favoriteID -> placement for every Postgres node in the arrangement, computed from where each is displayed now.
  /// MySQL items are matched against the groups' *current* childNodes, so an anchor removed since the last
  /// resolve is skipped: the nearest earlier MySQL sibling still there is used.
  - (NSDictionary *)placements;
  @end
  ```
- **Postgres nodes keep their current parent:** the adapter's hidden holder node, so `[[node parentNode]
  parentNode]` stays non-nil. The layout never adds them to a MySQL node's `mutableChildNodes`.

- [ ] **Step 1: Write failing tests** in `SPPostgresFavoritesLayoutTests` (ARC).
  - **Fixtures:**
    - Build MySQL trees by hand: `SPTreeNode` with `SPGroupNode` / `SPFavoriteNode`, favorites carrying
      `SPFavoriteIDKey`.
    - Build Postgres nodes as `SPTreeNode`s over `SPPostgresFavoriteNode`, inside a holder (root → holder → nodes).
  - **Tests:**
    - `testNoPlacementsAppendsAtTopLevelEndInGivenOrder`:
      - Section has [m1, groupG]; Postgres p_a, p_b, with no placements.
      - Displayed section children are [m1, G, p_a, p_b]. `displayedChildrenOfGroup:G` is `[G childNodes]`.
    - `testAfterFavoriteInNestedGroup`: a placement with Group [{G,0},{H,0}] and After FavoriteID of h2 is
      displayed right after h2 in H.
    - `testAfterAbsentIsFirst`.
    - `testAfterGroupAnchor`: After `{GroupName:"G", Nth:0}`.
    - `testSameNameGroupsUseNth`: two top-level groups named "X". A Group with Nth 1 lands in the second one.
    - `testMissingAnchorFallsBackToIndex`:
      - After names id 99, which is absent, and Index is 1. The group has [a, b, c].
      - Displayed: [a, p, b, c].
      - An Index of 10 clamps to the end.
    - `testMissingGroupFallsBackToTopLevelEnd`: Group [{Gone,0}].
    - `testOrderThenNameWithinSlot`: three Postgres nodes after the same anchor, with Orders 1, 0, 0 and names
      "b", "z", "a", are displayed as a, z, b.
    - `testMySQLChildrenNeverChange`: after resolve, every MySQL group's `childNodes` equals its pre-resolve
      array, and every Postgres node's `parentNode` is still the holder.
    - `testSnapshotRoundTrips`: resolve with placements P, then `placements` resolves again to the same displayed
      arrays. Use the nested, missing-anchor and two-in-one-slot cases.
    - `testSnapshotSkipsRemovedAnchor`:
      - Resolve with p after m2 in [m1, m2, m3]. Remove m2 from the section's `mutableChildNodes`.
      - The snapshot has After = m1's id and Index 1.
    - `testSnapshotFollowsRenamedGroup`: after resolving p into G, rename G with `setNodeName:@"G2"`. The snapshot
    Group is [{G2,0}]. This is how a group renamed in this app keeps its Postgres favorites.
  - `testPostgresNodesWithinGroupIsRecursive`.
    - `testSortValues`:
      - A Postgres node with type socket gives "localhost" for host and `@(100 + SPPostgresSocketConnection)`
        for type.
      - `SPFavoritesSortValueForNode` on a MySQL node returns its dictionary value.
- [ ] **Step 2: Run** with `-only-testing:"Postgres Tests/SPPostgresFavoritesLayoutTests"`. Expected: FAIL (the
  class doesn't exist).
- [ ] **Step 3: Implement** both classes.
  - The layout stores its arrangement in an `NSMapTable` keyed by group node with pointer identity
    (`NSMapTableObjectPointerPersonality`, strong keys and values), plus a node → displayed-parent map table.
  - It stores only groups that contain Postgres nodes.
  - Move `SPPostgresFavoriteNode` with no behaviour change.
  - Add the new files with `add-app` and the test with `add-test`.
- [ ] **Step 4: Run the layout tests and `SPPostgresConnectionScreenAdapterTests`.** Expected: PASS.
- [ ] **Step 5: Commit:** "Postgres favorites: a layout that places Postgres favorites among the MySQL favorites".

### Task 3: Layout changes (move, reorder, add)

**Files:**
- Modify: `Source/Postgres/SPPostgresFavoritesLayout.{h,m}`
- Test: `PostgresTests/SPPostgresFavoritesLayoutTests.m`

**Interfaces:**
- Consumes: Task 2's layout.
- Produces:
  ```objc
  /// Makes `children` (a mix of MySQL and Postgres nodes, each already displayed somewhere or new Postgres
  /// nodes) the displayed children of `group`. The MySQL subset, in that order, becomes [group mutableChildNodes]
  /// (removing each MySQL node from its old parent first). The Postgres ones move here from wherever they were.
  - (void)setDisplayedChildren:(NSArray *)children ofGroup:(SPTreeNode *)group;
  /// Drag and drop: moves `nodes` (in order) to `group` at displayed index `index`, as SPConnectionController's
  /// MySQL drop does with childNodes (an index past a node removed from the same group is shifted down by one).
  - (void)moveNodes:(NSArray *)nodes toGroup:(SPTreeNode *)group displayedIndex:(NSInteger)index;
  /// A new Postgres node: displayed at the end of `group`.
  - (void)appendPostgresNode:(SPTreeNode *)node toGroup:(SPTreeNode *)group;
  /// A new Postgres node: displayed right after `existing` (a displayed Postgres node).
  - (void)insertPostgresNode:(SPTreeNode *)node afterNode:(SPTreeNode *)existing;
  ```

- [ ] **Step 1: Write failing tests:**
  - `testMovePostgresBetweenMySQLFavorites`:
    - Displayed section [m1, m2, p]. Moving p to index 1 gives [m1, p, m2].
    - `[section childNodes]` stays [m1, m2], and `placements[p]` has After m1.
  - `testMovePostgresIntoGroup`: p moves into G at index 0. G displays [p, g1], and its placement Group is [{G,0}]
    with After absent.
  - `testMoveMySQLAcrossDisplayedPostgres`:
    - Displayed [p, m1, m2]. Moving m2 to index 0 gives [m2, p, m1].
    - `[section childNodes]` is [m2, m1].
  - `testMoveMixedSelection`: dragging [m1, p] into G at index 1 keeps their order.
  - `testMoveGroupCarriesItsPostgresNodes`: G holds p. After moving G into H, `displayedChildrenOfGroup:G` still
    holds p, and its placement Group is [{H,0},{G,0}].
  - `testSetDisplayedChildrenSortsTogether`:
    - Set [p_a, m_b, p_c] on the section.
    - Displayed equals that array, and `childNodes` is [m_b].
  - `testAppendAndInsertAfter`: appending to an empty group, and inserting after a Postgres node that is followed
    by another Postgres node in the same slot. The new node lands between them, and its snapshot Order puts it
    there again on resolve.
  - `testNoPostgresNodeEverEntersMySQLTree`:
    - Run every operation above.
    - Walk the MySQL tree recursively and assert that no node's `representedObject` is an
      `SPPostgresFavoriteNode`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** All four methods go through `setDisplayedChildren:ofGroup:`, which updates the
  arrangement and both map tables, then rewrites MySQL `mutableChildNodes`. `moveNodes:` mirrors the index
  arithmetic of `-[SPConnectionController outlineView:acceptDrop:item:childIndex:]`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit:** "Postgres favorites: move, sort and add Postgres favorites in the layout".

### Task 4: Adapter: one list, saved placements

**Files:**
- Modify: `Source/Postgres/SPPostgresConnectionScreenAdapter.{h,m}`
- Test: `PostgresTests/SPPostgresConnectionScreenAdapterTests.m`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces (adapter, replacing `-sectionNode` and `-favoriteNodesForOutline`, which are deleted):
  ```objc
  - (instancetype)initWithConnectionController:(id <SPPostgresConnectionScreenHost>)controller
                                         store:(SPPostgresFavoritesStore *)store
                               placementsStore:(SPPostgresFavoritePlacementsStore *)placementsStore;
  // -initWithConnectionController:store: keeps working: placements store = +storeBesideFavoritesStore:store.
  - (BOOL)hasPostgresFavorites;
  /// Called by the host before every outline reload. With `saveLayout`, first saves the current arrangement's
  /// placements (merged over the stored ones for favorites not in the arrangement, pruned to existing
  /// favorites; written only when different). Then resolves against `section` and the stored placements.
  - (void)prepareOutlineWithMySQLSection:(SPTreeNode *)section savingLayout:(BOOL)saveLayout;
  - (NSArray *)displayedChildrenOfGroup:(SPTreeNode *)group;
  - (SPTreeNode *)displayedParentOfNode:(SPTreeNode *)node;
  - (void)moveNodes:(NSArray *)nodes toGroup:(SPTreeNode *)group displayedIndex:(NSInteger)index;  // then saves placements
  - (void)setDisplayedChildren:(NSArray *)children ofGroup:(SPTreeNode *)group;                    // no save (the host reloads, saving)
  /// Removes every Postgres favorite displayed within `group` (store and keychain items), without asking.
  - (void)removePostgresFavoritesWithinGroup:(SPTreeNode *)group;
  ```
- **Host protocol additions** (`@optional`):
  - `- (SPTreeNode *)postgresMySQLSection;`: the FAVORITES section node.
  - `- (SPTreeNode *)postgresGroupForNewFavorite;`: the selected group, else the selected item's displayed parent,
    else the section.

- [ ] **Step 1: Write failing tests** in `SPPostgresConnectionScreenAdapterTests`:
  - **Setup:**
    - Extend the fake host with the two new methods.
    - Build a small MySQL section, held by the test.
    - Construct the adapter with the temp favorites store. Its placements store is beside it, so it lives in the
      temp directory.
  - **Tests:**
    - `testFirstLoadPutsExistingFavoritesAtTopLevelEndByName`: with placements absent, there are two saved
      favorites, "b" and "a".
    - `testMoveIsSavedAndRestoredByANewAdapter`:
      - Move a Postgres node into group G, then make a new adapter on the same files.
      - After `prepareOutline…savingLayout:NO`, it is displayed in G.
    - `testAddNewFavoriteGoesToEndOfGroupForNewFavorite`: the host returns G, and `addNewFavorite`'s node is the
      last displayed child of G.
    - `testSaveFormAsNewFavoriteGoesToEndOfGroupForNewFavorite`.
    - `testDuplicateIsDisplayedRightAfterOriginal`.
    - `testRemovePostgresFavoritesWithinGroup`:
      - p1 is in G and p2 is in a subgroup of G. Both leave the store and the fake keychain.
      - p3 at top level stays.
    - `testOutsideChangeDoesNotSaveStaleLayout`:
      - Adapter A moves p into G.
      - Adapter B, made earlier on the same files, gets the placements notification. B rebuilds, and after B's
        `prepareOutline…savingLayout:NO`, p is in G.
      - The placements file still says G.
    - `testDeletedFavoritePlacementIsPruned`.
    - `testNothingWrittenWithoutChange`: with the placements file's modification date set in the past, a
      `prepareOutline…savingLayout:YES` with no change doesn't rewrite it.
    - Remove or adapt the existing tests that use `sectionNode` / `favoriteNodesForOutline`.
- [ ] **Step 2: Run** `SPPostgresConnectionScreenAdapterTests`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - **Holder node:** keep `rootNode` → `sectionNode` as the hidden holder, renamed `holderNode`. It is never
    displayed, has no "POSTGRESQL" name, and `isPostgresNode:` still answers YES for it.
  - **The layout:** add an `SPPostgresFavoritesLayout`. `_rebuildNodes` keeps building nodes into the holder.
  - **New favorites** (add, save-as-new, duplicate):
    - Create the node first, then reuse it through `nodesByID`.
    - Put it in the layout with `appendPostgresNode:toGroup:` or `insertPostgresNode:afterNode:`.
    - Write placements, then save the favorite to the store.
    - That way the store's change notification and reload already find it in place.
  - **Notifications:** observe `SPPostgresFavoritePlacementsDidChangeNotification` like the store's notification,
    with a `writingPlacements` flag so the adapter's own writes don't reload twice.
  - **Removing a group's favorites:** `removePostgresFavoritesWithinGroup:` reuses the single-favorite removal
    path without its alert: store removal plus keychain deletion.
- [ ] **Step 4: Run** `SPPostgresConnectionScreenAdapterTests` and the layout tests. Expected: PASS.
- [ ] **Step 5: Commit:** "Postgres favorites: the adapter places Postgres favorites in the one FAVORITES list".

### Task 5: Connection screen: one FAVORITES list

**Files:**
- Modify: `Source/SPConnectionController.m` (Postgres-guarded branches only, plus the comparator's value lookup)
- Test: `PostgresTests/SPPostgresConnectionScreenAdapterTests.m` (sort-value cases are covered in Task 2); a manual
  checklist

**Interfaces:**
- Consumes: Task 4's adapter API, and `SPFavoritesSortValueForNode` from Task 2.

- [ ] **Step 1: Remove the POSTGRESQL section.**
  - In `outlineView:numberOfChildrenOfItem:`, `outlineView:child:ofItem:`, `_reloadFavoritesViewData` and
    `postgresSelectOutlineItem:`, drop the extra top-level row and the section expansion.
  - For a non-nil item, use a private helper, `_displayedChildrenOfNode:`: `[postgresAdapter
    hasPostgresFavorites] ? [postgresAdapter displayedChildrenOfGroup:node] : [node childNodes]`.
  - `postgresSelectOutlineItem:` expands each displayed ancestor of the item (via `displayedParentOfNode:`)
    before selecting it.
- [ ] **Step 2: Reload hook.**
  - `_reloadFavoritesViewData` calls `[postgresAdapter prepareOutlineWithMySQLSection:<section>
    savingLayout:!reloadingForOutsideChange]` before `reloadData`.
  - `<section>` is `[[favoritesRoot childNodes] objectAtIndex:0]`.
  - Add the BOOL ivar `reloadingForOutsideChange`, set to YES around the reload in `_processFavoritesDataChange:`
    and `postgresFavoritesDidChange`.
  - Implement the host methods `postgresMySQLSection` and `postgresGroupForNewFavorite`.
- [ ] **Step 3: Drag and drop.**
  - `writeItems:`: delete the "Postgres favorites can't be dragged" loop.
  - `validateDrop:`: keep refusing a Postgres node as the drop item.
  - `acceptDrop:`: after the existing sort-disabling preamble and the section fallback, when `[postgresAdapter
    hasPostgresFavorites]`, call `[postgresAdapter moveNodes:draggedNodes toGroup:node displayedIndex:childIndex]`
    in place of the `childNodeArray` loop. Then run the existing save, reload, notification and
    default-favorite-pop-up tail.
- [ ] **Step 4: Sorting.**
  - In `_compareFavoritesUsingKey`, replace the two `nodeFavorite objectForKey:` lookups with
    `SPFavoritesSortValueForNode(node, dictKey)`.
  - In `_sortTreeNode:usingKey:`, when the adapter has Postgres favorites, sort `[self
    _displayedChildrenOfNode:node]`, recurse into MySQL groups as now, and write back with `[postgresAdapter
    setDisplayedChildren:ofGroup:]` in place of `setArray:`.
  - Call `[self _sortFavorites]` after the Postgres branches of add, duplicate and rename. It returns at once when
    unsorted, as MySQL's add does.
- [ ] **Step 5: Groups.**
  - `addGroup:` with a Postgres node selected adds the group to `[postgresAdapter displayedParentOfNode:selected]`,
    where a MySQL sibling would put it, not always the top level.
  - `removeNode:`: the "group has children" test uses `[[self _displayedChildrenOfNode:node] count]`, so a group
    holding only Postgres favorites still asks first.
  - `_removeNode:` with a group: call `[postgresAdapter removePostgresFavoritesWithinGroup:node]` before
    `removeFavoriteNode:`.
- [ ] **Step 6: Stay MySQL-only.**
  - `exportFavorites:` passes the selected nodes minus Postgres nodes, and returns when none are left.
  - `validateMenuItem:` disables Export when only Postgres nodes are selected.
  - The default-favorite pop-up and `SPFavoritesController` stay as they are.
- [ ] **Step 7: Build the app and run the full suite.**
  - Expected: `** BUILD SUCCEEDED **`, and `** TEST SUCCEEDED **` with 0 failures.
  - Then check that no Postgres test wrote the real Data folder: `ls -la ~/Library/Application\
    Support/Sequel\ Pro/Data/` shows no `PostgresFavoritePlacements.plist` dated today, and `Favorites.plist`
    has no newer modification time than before the run.
- [ ] **Step 8: Commit:** "Connection screen: one FAVORITES list; Postgres favorites drag into MySQL groups".

## Review Focus

1. **`Favorites.plist` written after a Postgres drag.** After dragging a Postgres favorite between two MySQL
   favorites, the file has only MySQL content, with the MySQL order as displayed minus the Postgres item.
   Pinned by Task 3's `testNoPostgresNodeEverEntersMySQLTree` and `testMoveMySQLAcrossDisplayedPostgres`.
2. **Two connection tabs open.** Tab A moves a Postgres favorite, and tab B's next reload must not save its stale
   layout over A's. Pinned by Task 4's `testOutsideChangeDoesNotSaveStaleLayout`.
3. **The 1.1.2 app edited `Favorites.plist`** (group renamed or deleted, anchor deleted). Postgres favorites stay
   in the nearest place. Pinned by Task 2's `testMissingAnchorFallsBackToIndex`,
   `testMissingGroupFallsBackToTopLevelEnd` and `testSnapshotSkipsRemovedAnchor`.
4. **Deleting a group that holds only Postgres favorites.** It must ask first, then delete them and their
   keychain items. Pinned by Task 4's `testRemovePostgresFavoritesWithinGroup`; the alert is on the manual
   checklist.
5. **No Postgres favorites at all.** The list, drag, sort, add and delete behave exactly as before. Covered by
   the `hasPostgresFavorites` guards and Task 2's `testNoPlacementsAppendsAtTopLevelEndInGivenOrder` (the
   displayed children equal `childNodes`); the final review checks every guard.

## Manual checklist (owner, after Task 5)

1. Postgres favorites now appear at the end of FAVORITES (no POSTGRESQL section), with the elephant icon.
2. Drag one between two MySQL favorites, into a group and into a nested group; quit and relaunch: they stay.
3. Open the 1.1.2 app: its favorites list is unchanged, with no Postgres entries.
4. Sort by name, host, type and colour (and reversed): Postgres and MySQL favorites sort together. With type,
   Postgres comes after MySQL.
5. With a Postgres favorite selected inside a group: + adds a new one at the end of that group, Duplicate adds a
   copy right after it, and New Folder makes the folder in that group.
6. Delete a group holding only Postgres favorites: it asks first, then they are gone, including their saved
   passwords.
7. With two connection tabs open, drag in one: the other tab's list follows after it reloads.
