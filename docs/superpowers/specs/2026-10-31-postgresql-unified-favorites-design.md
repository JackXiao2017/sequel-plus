# One FAVORITES list for MySQL and PostgreSQL favorites (Stage 13)

Date: 2026-10-31
Status: draft for owner approval
Builds on: 2026-10-27-postgresql-support-design.md (Postgres favorites, Stage 1) and
2026-10-29-postgresql-mysql-parity-ui-design.md (Stages 8–12). Branch `postgres-stage13`, stacked on
`postgres-stage12`.

## Intent and why

The connection screen's favorites list has two sections:
- **FAVORITES:** the MySQL favorites and groups, in the order the owner arranged by dragging. They are saved in
  `~/Library/Application Support/Sequel Pro/Data/Favorites.plist`.
- **POSTGRESQL:** the Postgres favorites, always sorted by name. They are saved in `PostgresFavorites.plist` next
  to it.

The owner organises connections by project or customer with groups, and a project often has both a MySQL and a
PostgreSQL server. Splitting the list by engine breaks that organisation. **Owner: show MySQL and Postgres
favorites in the same FAVORITES list, and let me drag Postgres favorites into my MySQL groups and between MySQL
favorites.**

Success: there is one FAVORITES list. Each Postgres favorite (with its own elephant icon) sits wherever the owner
dropped it, and it stays there across launches. The owner's original Sequel Pro 1.1.2 app keeps seeing exactly
the MySQL favorites and groups it sees today.

## Goals

- Remove the POSTGRESQL section. Postgres favorites appear inside FAVORITES: at the top level, or in any group at
  any depth.
- Drag and drop treats Postgres favorites like MySQL favorites:
  - drag a Postgres favorite between favorites, into a group, out of a group, or to the top level
  - drag several mixed favorites at once
  - drag a group that contains Postgres favorites; they move with it
- Postgres favorites remember their position across launches.
- The sort menu (by name, host, type, colour, and reversed) sorts Postgres and MySQL favorites together. Each
  group is sorted as it is now. The "type" key needs a value for a Postgres favorite; see "Left to the builder".
- A new Postgres favorite (the + button, or "Add to Favorites" with PostgreSQL selected) goes where a new MySQL
  favorite would go.
- Duplicating a Postgres favorite places the copy right after the original, as MySQL's duplicate does.
- Deleting a group in this app deletes the Postgres favorites inside it, along with the MySQL ones:
  - Their keychain passwords are removed, as for MySQL favorites in the group.
  - MySQL's confirmation alert for a group counts and warns about them too.
- Everything else about a Postgres favorite stays as it is:
  - selecting it switches the form to PostgreSQL and fills it
  - its tooltip
  - its colour
  - Save changes
  - its icon

## Non-goals

- Postgres favorites in other places that list MySQL favorites today:
  - the "Default favorite" pop-up in General preferences
  - favorites export and import
  - any menu that lists favorites

  These stay MySQL-only, as they are now.
- Changing how the 1.1.2 app shows anything.
- Moving Postgres favorites into `Favorites.plist`, or MySQL favorites out of it.
- Converting a favorite from one engine to the other.

## Anti-goals (a failure even if the feature works)

- **A Postgres favorite, or anything describing one, written into `Favorites.plist`.** The 1.1.2 app reads that
  file. It must keep the exact structure it has today: MySQL favorites and groups, nothing else. When this app
  saves `Favorites.plist`, Postgres nodes are left out, and the groups and MySQL favorites around them are saved
  as they appear.
- **A Postgres favorite lost or hidden** because something changed in `Favorites.plist`, through this app or the
  1.1.2 app. A Postgres favorite that can't be placed where it was is still shown (see "When its place is gone").
- **Any change to MySQL favorites behaviour**, other than Postgres favorites now appearing among them:
  - drag and drop, sorting, renaming, groups, keychain entries
  - the default favorite, export and import
- MySQL's tests and parity tests stay green.
- Tests writing the real `Favorites.plist`, `PostgresFavorites.plist`, real preferences, or the login keychain.

## Constraints

- Objective-C, MRC in app sources, ARC in the "Postgres Tests" target. Views in code. Add files only through
  `ruby Scripts/pg-xcodeproj.rb`.
- Postgres logic lives in `Source/Postgres` (`SPPostgresConnectionScreenAdapter` and friends).
  `SPConnectionController.m` and `SPFavoritesController.m` only call into it from guarded branches, as Stage 1
  set up. MySQL source edits are limited to those calls, and every MySQL path must behave exactly as before when
  there are no Postgres favorites.
- Postgres favorites stay in `PostgresFavorites.plist`. Their position is saved in this app's own storage (the
  Postgres favorites file or a file beside it), never in `Favorites.plist`.
- A stored position must still make sense when the 1.1.2 app has edited `Favorites.plist` in the meantime. That
  app can reorder, rename, add and delete MySQL favorites and groups.
- The favorites file format is versioned (`SPPostgresFavoritesStore` already refuses newer versions). An older
  `PostgresFavorites.plist` without positions loads with every Postgres favorite at the end of the top level,
  sorted by name. That is where the old POSTGRESQL section's order puts them.

## When its place is gone

A Postgres favorite's saved place may no longer exist, because the 1.1.2 app (or this app, for a MySQL
favorite) deleted or renamed its group, or deleted the MySQL favorite it was next to. Then:

1. **Its group is still there:** it stays in that group, as close as possible to where it was.
2. **Its group is gone:** it moves to the top level, at the end.

It is never deleted or hidden this way. Deleting a group *in this app* is different: that deletes the Postgres
favorites in it, after the confirmation (see Goals).

## Decisions

Owner (in chat, 2026-10-31):
- One FAVORITES list for both engines. The POSTGRESQL section goes.
- Postgres favorites can be dragged into MySQL groups and between MySQL favorites.
- The playback was approved as written, including these points:
  - A group holding only Postgres favorites looks empty in the 1.1.2 app.
  - Places that are gone fall back as above.
  - Deleting a group deletes the Postgres favorites in it.
  - Sorting covers both engines.
  - The MySQL / PostgreSQL switch above the form is unchanged.
  - New Postgres favorites go where a new MySQL favorite would.

Builder's calls (mine, from the builder check; approved with this document unless the owner objects):
- **Postgres favorites are merged into the displayed tree only.** `SPFavoritesController`'s tree, and so
  `Favorites.plist`, export/import, the default-favorite pop-up and any menu, keep seeing MySQL nodes only. This
  is what keeps the non-goals true. MySQL code that reads a group's children for display, or for the
  delete-group confirmation, asks the adapter for that group's Postgres children too.
- **This app does not watch `Favorites.plist` for outside edits; it never has.** Saved places are worked out
  again each time the displayed tree is built (at launch and on every reload), against the MySQL tree in memory.
  Running both apps at once and editing favorites in both is unchanged from today: the last writer wins for
  MySQL favorites. Postgres positions follow the "When its place is gone" rule.
- **Anchors are MySQL favorites and groups only.** Postgres favorites have UUID ids and MySQL favorites have
  numeric ids, so the two never collide. Postgres favorites next to each other keep their own saved order.

## Left to the builder

- **How a position is stored.** For example, the parent group's path plus the MySQL favorite or group it follows,
  by its `id`. Groups have only a name and a position, so the builder decides how to identify a group robustly,
  including two groups with the same name. A test must cover the 1.1.2 app having reordered, renamed and deleted
  things.
- **How Postgres nodes live in the one tree**, while `SPFavoritesController` keeps saving only MySQL nodes.
  Options include filtering Postgres nodes out on save, or merging them into the displayed tree only. The
  constraint is the anti-goal above.
- **The "type" sort value for a Postgres favorite.** For example, sort it after MySQL's connection types, under
  "PostgreSQL".
- **When this app writes positions.** On every drop, sort, add, duplicate and group delete, and whether in the
  same write as the favorite or separately.
- Whether `-[SPPostgresFavoritesStore favorites]` keeps its sorted-by-name contract, with positions kept
  elsewhere, or changes it.
