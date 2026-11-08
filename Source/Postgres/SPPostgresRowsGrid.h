#import <Cocoa/Cocoa.h>
#import "SPTableView.h"

NS_ASSUME_NONNULL_BEGIN

/// A PostgreSQL grid's controller (the grid's delegate): what Edit ▸ Copy, Copy with Column Names and Copy as SQL
/// INSERT (and the grid's right-click menu's) copy from it.
@protocol SPPostgresRowsGridDelegate <NSObject>
/// The selected rows as tab-separated text (see SPPostgresTabText), on the controller's pasteboard.
- (void)rowsGrid:(NSTableView *)grid copyRowsWithColumnNames:(BOOL)withColumnNames;
/// The selected rows as INSERT statements (see SPPostgresSQLInserts), on the controller's pasteboard.
- (void)rowsGridCopyAsSQLInserts:(NSTableView *)grid;
@end

/// SPTableView whose Edit ▸ Copy (⌘C), Copy with Column Names (⌥⌘C) and Copy as SQL INSERT (⌃⌥⌘C) go to its delegate
/// (an SPPostgresRowsGridDelegate), as MySQL's grids (SPCopyTable) copy their selected rows. No paste.
@interface SPPostgresRowsGrid : SPTableView

/// The right-click menu's Copy, Copy with Column Names and Copy as SQL INSERT (MySQL's, DBView.xib), aimed at grid.
+ (NSArray<NSMenuItem *> *)copyMenuItemsForGrid:(NSTableView *)grid;

@end

/// MySQL's Copy (and Copy with Column Names), for PostgreSQL: a line per row (after the column names' line, when
/// given), the values tab-separated, NULL (NSNull) as nullString, line breaks and tabs in a value as ↵ and ⇥.
NSString *SPPostgresTabText(NSArray<NSString *> *_Nullable columnNames, NSArray<NSArray *> *rows, NSString *nullString);

/// MySQL's Copy as SQL INSERT, for PostgreSQL: one INSERT INTO `qualifiedTableName` (the columns, quoted) with a VALUES
/// line per row, each value a quoted literal (PostgreSQL casts it to the column's type) or NULL (NSNull):
///
///     INSERT INTO "public"."items" ("id", "name")
///     VALUES
///     	('1', 'a'),
///     	('2', NULL);
NSString *SPPostgresSQLInserts(NSString *qualifiedTableName, NSArray<NSString *> *columnNames, NSArray<NSArray *> *rows);

NS_ASSUME_NONNULL_END
