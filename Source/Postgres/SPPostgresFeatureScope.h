#import <Foundation/Foundation.h>

/**
 * The features of a PostgreSQL tab that a release can ship or hold back. The one switch for a release's Postgres
 * scope is SPPostgresFeatureIsAvailable() (SPPostgresFeatureScope.m): a feature it says NO for stays in the code but
 * can't be reached in a Postgres tab (its toolbar item, menu items and sidebar items are disabled or hidden, and a
 * request to show its pane shows Content instead). MySQL tabs never ask.
 *
 * A later release re-enables a feature by editing SPPostgresFeatureIsAvailable() only.
 */
typedef NS_ENUM(NSInteger, SPPostgresFeature) {
	// Always shipped (RC1's scope): listed so every pane maps to a feature
	SPPostgresFeatureContent = 0,
	SPPostgresFeatureQuery,
	SPPostgresFeatureConsole,

	// Held back in 2.0.0-RC1
	SPPostgresFeatureStructure,     // Stage 3: the Structure pane (toolbar, View ▸ Structure ⌘1)
	SPPostgresFeatureRelations,     // Stage 3: the Relations pane
	SPPostgresFeatureTriggers,      // Stage 3: the Triggers pane
	SPPostgresFeatureTableInfo,     // Stage 3: the Table Info pane
	SPPostgresFeatureSequences,     // Stage 3: the sidebar's SEQUENCES section and the Sequence pane
	SPPostgresFeatureExtensions,    // Stage 5: the sidebar's EXTENSIONS section and the Extension pane
	SPPostgresFeatureUsers,         // Stage 4: the Users sheet
	SPPostgresFeatureImportExport,  // Stage 6: File ▸ Import…/Export…, the table list's Export ▸, Export Result
	SPPostgresFeatureTransfer,      // Stage 7/7b: the Transfer sheet
	SPPostgresFeatureTableHistory,  // Table History back/forward (toolbar control, View ▸ Back/Forward)
	SPPostgresFeatureCreateSyntax   // The table list's Show/Copy Create … Syntax
};

/// Whether `feature` can be used in a PostgreSQL tab of this build (see SPPostgresFeatureScope.m).
__attribute__((visibility("default"))) BOOL SPPostgresFeatureIsAvailable(SPPostgresFeature feature);

/**
 * Test-only: YES makes every feature available (the full scope, as before the release scope existed); NO (the
 * default) gives the release's scope. The test bundle sets YES for the whole run (SPTestPrefsGuard) so tests of the
 * held-back features keep running; the scope's own tests set NO. Never called by the app.
 */
__attribute__((visibility("default"))) void SPPostgresFeatureScopeSetFullScopeForTesting(BOOL fullScope);
__attribute__((visibility("default"))) BOOL SPPostgresFeatureScopeIsFullScopeForTesting(void);
