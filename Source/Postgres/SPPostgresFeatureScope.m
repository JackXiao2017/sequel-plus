#import "SPPostgresFeatureScope.h"

/// Set only by tests (SPPostgresFeatureScopeSetFullScopeForTesting); main thread.
static BOOL SPPostgresFeatureFullScope = NO;

/**
 * The release's Postgres scope: THE place to change it. 2.0.0-RC1 ships favorites, the Postgres UI, the table list
 * (and its bottom bar), and the Content, Query and Console views; every other feature stays in the code, unreachable.
 */
BOOL SPPostgresFeatureIsAvailable(SPPostgresFeature feature)
{
	if (SPPostgresFeatureFullScope) return YES;

	switch (feature) {
		case SPPostgresFeatureContent:
		case SPPostgresFeatureQuery:
		case SPPostgresFeatureConsole:
			return YES;

		case SPPostgresFeatureStructure:
		case SPPostgresFeatureRelations:
		case SPPostgresFeatureTriggers:
		case SPPostgresFeatureTableInfo:
		case SPPostgresFeatureSequences:
		case SPPostgresFeatureExtensions:
		case SPPostgresFeatureUsers:
		case SPPostgresFeatureImportExport:
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
