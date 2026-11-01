#import "SPPostgresFeatureScope.h"

/// Set only by tests (SPPostgresFeatureScopeSetFullScopeForTesting); main thread.
static BOOL SPPostgresFeatureFullScope = NO;

/**
 * The release's Postgres scope: THE place to change it. 2.0.0-RC3 ships every Postgres feature (RC1: Content, Query,
 * Console; RC2: Structure, Relations, Triggers, Table Info, Import/Export; RC3: Transfer, Users, Sequences, Extensions,
 * Table History, Create Syntax). A later release holds a feature back by returning NO for it here.
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
		case SPPostgresFeatureSequences:
		case SPPostgresFeatureExtensions:
		case SPPostgresFeatureUsers:
		case SPPostgresFeatureTransfer:
		case SPPostgresFeatureTableHistory:
		case SPPostgresFeatureCreateSyntax:
			return YES;
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
