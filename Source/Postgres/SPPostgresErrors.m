#import "SPPostgresErrors.h"
#import <PostgresKit/PostgresKit.h>

NSString * const SPPostgresErrorDomain = @"SPPostgresErrorDomain";
NSString * const SPPostgresSQLStateErrorKey = @"SPPostgresSQLState";
NSString * const SPPostgresDependentsErrorKey = @"SPPostgresDependentsErrorKey";
NSString * const SPPostgresObjectsErrorKey = @"SPPostgresObjectsErrorKey";

NSError *SPPostgresMakeError(NSInteger code, NSString *message, NSDictionary *userInfo)
{
	NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:userInfo ?: @{}];
	info[NSLocalizedDescriptionKey] = message ?: @"";
	return [NSError errorWithDomain:SPPostgresErrorDomain code:code userInfo:info];
}

NSError *SPPostgresDependentsError(PGPostgresConnection *connection, NSError *serverError, NSString *messageOrNil)
{
	if (![[serverError userInfo][SPPostgresSQLStateErrorKey] isEqualToString:@"2BP01"]) return serverError;

	NSString *detail = [[[connection lastError] errorDetailMessage] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSMutableArray *dependents = [NSMutableArray array];
	for (NSString *line in [detail ?: @"" componentsSeparatedByString:@"\n"]) {
		NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([trimmed length]) [dependents addObject:trimmed];
	}
	return SPPostgresMakeError(SPPostgresErrorHasDependents, messageOrNil ?: [serverError localizedDescription],
							   @{SPPostgresDependentsErrorKey: dependents, SPPostgresSQLStateErrorKey: @"2BP01"});
}
