#import "SPPostgresFeatureScope.h"

/// Set only by tests (SPPostgresFeatureScopeSetFullScopeForTesting); main thread.
static BOOL SPPostgresFeatureFullScope = NO;

/**
 * The release's Postgres scope: THE place to change it. 2.0.0-RC2 ships favorites, the Postgres UI, the table list
 * (and its bottom bar, with Duplicate Table), the Content, Query and Console views (RC1), and the Structure, Relations,
 * Triggers and Table Info views and Import/Export (RC2); every other feature stays in the code, unreachable.
 */
BOOL SPPostgresFeatureIsAvailable(SPPostgresFeature feature)
{
	if (SPPostgresFeatureFullScope) return YES;

	switch (feature) {
		case SPPostgresFeatureContent:
		case SPPostgresFeatureQuery:
		case SPPostgresFeatureConsole:
		case SPPostgresFeatureStructure:
		case SPPostgresFeatureRelations:
		case SPPostgresFeatureTriggers:
		case SPPostgresFeatureTableInfo:
		case SPPostgresFeatureImportExport:
			return YES;

		case SPPostgresFeatureSequences:
		case SPPostgresFeatureExtensions:
		case SPPostgresFeatureUsers:
		case SPPostgresFeatureTransfer:
		case SPPostgresFeatureTableHistory:
		case SPPostgresFeatureCreateSyntax:
			return NO;
	}
	return NO;
}

void SPPostgresFeatureScopeSetFullScopeForTesting(BOOL fullScope)
{
	SPPostgresFeatureFullScope = fullScope;
}

BOOL SPPostgresFeatureScopeIsFullScopeForTesting(void)
{
	return SPPostgresFeatureFullScope;
}
