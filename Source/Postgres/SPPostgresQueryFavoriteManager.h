#import <Cocoa/Cocoa.h>

@class SPPostgresQueryStore;

/**
 * The PostgreSQL Query tab's favorites manager, a sheet built in code on MySQL's QueryFavoriteManager.xib layout: the
 * favorites list on the left over an SPButtonBar with add, remove and duplicate (button_add, button_remove,
 * button_duplicate), the selected favorite's name and query (an SPPostgresTextView) on the right, Cancel and Save at
 * the bottom. MySQL's tab triggers and its .spf import/export are left out, and every Postgres favorite is global.
 *
 * The edits are kept in the sheet until Save, which writes them to the store (never MySQL's queryFavorites
 * preference); Cancel writes nothing. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresQueryFavoriteManager : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate>

/// The store's favorites (its @{@"name", @"query"} items) are the sheet's starting list.
- (instancetype)initWithStore:(SPPostgresQueryStore *)store;

/// Shows the sheet on window; completion is called once, after the sheet ended: YES after Save wrote the store, NO for
/// Cancel.
- (void)beginSheetForWindow:(NSWindow *)window completion:(void (^)(BOOL saved))completion;

/**
 * Writes favorites to store, as an explicit user save (Ruling 8): -setItems:error:, except when the store's file can't
 * be read (lastLoadError): the user is then told it will be moved aside and asked (Cancel / Continue), and on
 * Continue -replaceItems:error: moves it aside and writes. A failed write is reported through report. completion gets
 * whether the store was written.
 */
+ (void)writeFavorites:(NSArray *)favorites
			   toStore:(SPPostgresQueryStore *)store
			   confirm:(void (^)(NSAlert *alert, void (^completion)(BOOL confirmed)))confirm
				report:(void (^)(NSAlert *alert))report
			completion:(void (^)(BOOL written))completion;

/// Shows the manager's alerts (a failed save). nil (the default): a sheet on the manager's sheet.
@property (copy) void (^alertPresenter)(NSAlert *alert);

/// Asks to confirm (Remove, moving an unreadable file aside); completion is called once with whether the first button
/// was chosen. nil (the default): a sheet on the manager's sheet.
@property (copy) void (^confirmationPresenter)(NSAlert *alert, void (^completion)(BOOL confirmed));

/// The favorites as edited so far (each @{@"name", @"query"}), including the selected one's fields.
- (NSArray *)favorites;

- (IBAction)addQueryFavorite:(id)sender;
/// Duplicates the selected favorite ("<name> Copy"), as MySQL's; NSBeep unless exactly one is selected.
- (IBAction)duplicateQueryFavorite:(id)sender;
/// Asks (MySQL's "Remove selected query favorites?"), then removes the selected favorites from the list.
- (IBAction)removeQueryFavorite:(id)sender;
- (IBAction)save:(id)sender;
- (IBAction)cancel:(id)sender;

#pragma mark - For tests

@property (readonly) NSPanel *sheet;
@property (readonly) NSTableView *favoritesTable;
@property (readonly) NSTextField *nameField;
@property (readonly) NSTextView *queryView;
@property (readonly) NSButton *addButton;
@property (readonly) NSButton *removeButton;
@property (readonly) NSButton *duplicateButton;
@property (readonly) NSButton *saveButton;
@property (readonly) NSButton *cancelButton;

@end
