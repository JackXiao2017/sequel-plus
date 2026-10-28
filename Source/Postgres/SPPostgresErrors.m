#import "SPPostgresErrors.h"

NSString * const SPPostgresErrorDomain = @"SPPostgresErrorDomain";
NSString * const SPPostgresDependentsErrorKey = @"SPPostgresDependentsErrorKey";

NSError *SPPostgresMakeError(NSInteger code, NSString *message, NSDictionary *userInfo)
{
	NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:userInfo ?: @{}];
	info[NSLocalizedDescriptionKey] = message ?: @"";
	return [NSError errorWithDomain:SPPostgresErrorDomain code:code userInfo:info];
}
