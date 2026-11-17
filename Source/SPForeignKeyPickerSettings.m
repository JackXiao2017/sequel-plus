//
//  SPForeignKeyPickerSettings.m
//  Sequel Plus
//

#import "SPForeignKeyPickerSettings.h"
#import "SPConstants.h"

@implementation SPForeignKeyPickerSettings
{
	NSUserDefaults *_defaults;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
{
	if ((self = [super init])) {
		_defaults = [defaults retain];
	}
	return self;
}

- (void)dealloc
{
	[_defaults release];
	[super dealloc];
}

+ (NSString *)tableKeyWithKind:(NSString *)kind host:(NSString *)host port:(NSInteger)port database:(NSString *)database schema:(NSString *)schema table:(NSString *)table
{
	// A JSON array, so no two different inputs can join into the same key.
	NSArray *parts = @[kind ?: @"", host ?: @"", @(port), database ?: [NSNull null], schema ?: [NSNull null], table ?: @""];
	NSData *data = [NSJSONSerialization dataWithJSONObject:parts options:0 error:NULL];
	return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

- (NSArray<NSString *> *)shownColumnsForTableKey:(NSString *)key available:(NSArray<NSString *> *)available keyColumn:(NSString *)keyColumn
{
	NSArray *remembered = [[_defaults dictionaryForKey:SPForeignKeyPickerShownColumns] objectForKey:key];
	if (![remembered isKindOfClass:[NSArray class]]) remembered = nil;

	NSMutableArray *shown = [NSMutableArray arrayWithCapacity:[available count]];
	if ([available containsObject:keyColumn]) [shown addObject:keyColumn];
	for (NSString *column in available) {
		if ([column isEqualToString:keyColumn]) continue;
		if (!remembered || [remembered containsObject:column]) [shown addObject:column];
	}
	return shown;
}

- (void)setShownColumns:(NSArray<NSString *> *)columns forTableKey:(NSString *)key
{
	NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:[_defaults dictionaryForKey:SPForeignKeyPickerShownColumns] ?: @{}];
	if (columns) [all setObject:[[columns copy] autorelease] forKey:key];
	else [all removeObjectForKey:key];
	[_defaults setObject:all forKey:SPForeignKeyPickerShownColumns];
}

- (BOOL)pickerEnabled
{
	id value = [_defaults objectForKey:SPForeignKeyPickerEnabled];
	return value ? [value boolValue] : YES;
}

@end
