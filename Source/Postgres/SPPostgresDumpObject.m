#import "SPPostgresDumpObject.h"
#import "SPPostgresTableData.h"

NSString *const SPPostgresDumpObjectTable = @"table";
NSString *const SPPostgresDumpObjectForeignTable = @"foreign table";
NSString *const SPPostgresDumpObjectView = @"view";
NSString *const SPPostgresDumpObjectMaterializedView = @"materialized view";
NSString *const SPPostgresDumpObjectSequence = @"sequence";
NSString *const SPPostgresDumpObjectRoutine = @"routine";
NSString *const SPPostgresDumpObjectType = @"type";
NSString *const SPPostgresDumpObjectDomain = @"domain";
NSString *const SPPostgresDumpObjectExtension = @"extension";

/// The identifier as quote_ident writes it: bare when it is a plain lower-case name and not a keyword the server
/// would misread (pg_get_keywords() rows whose catcode isn't 'U', as of PostgreSQL 18).
static NSString *SPDumpObjectIdentifier(NSString *identifier)
{
	static NSSet *keywords = nil;
	static NSCharacterSet *notPlain = nil;
	static NSCharacterSet *plainStart = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		keywords = [[NSSet alloc] initWithArray:[@"all analyse analyze and any array as asc asymmetric authorization between bigint binary bit "
			"boolean both case cast char character check coalesce collate collation column concurrently constraint create cross "
			"current_catalog current_date current_role current_schema current_time current_timestamp current_user dec decimal "
			"default deferrable desc distinct do else end except exists extract false fetch float for foreign freeze from full "
			"grant greatest group grouping having ilike in initially inner inout int integer intersect interval into is isnull "
			"join json json_array json_arrayagg json_exists json_object json_objectagg json_query json_scalar json_serialize "
			"json_table json_value lateral leading least left like limit localtime localtimestamp merge_action national natural "
			"nchar none normalize not notnull null nullif numeric offset on only or order out outer overlaps overlay placing "
			"position precision primary real references returning right row select session_user setof similar smallint some "
			"substring symmetric system_user table tablesample then time timestamp to trailing treat trim true union unique user "
			"using values varchar variadic verbose when where window with xmlattributes xmlconcat xmlelement xmlexists xmlforest "
			"xmlnamespaces xmlparse xmlpi xmlroot xmlserialize xmltable" componentsSeparatedByString:@" "]];
		notPlain = [[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_$"] invertedSet] retain];
		plainStart = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz_"] retain];
	});
	NSString *text = identifier ?: @"";
	BOOL plain = [text length] && [text rangeOfCharacterFromSet:notPlain].location == NSNotFound
		&& [plainStart characterIsMember:[text characterAtIndex:0]]
		&& ![keywords containsObject:text];
	return plain ? text : SPPostgresQuoteIdentifier(text);
}

@implementation SPPostgresDumpObject

@synthesize kind;
@synthesize schema;
@synthesize name;
@synthesize arguments;

+ (instancetype)objectWithKind:(NSString *)aKind schema:(NSString *)aSchema name:(NSString *)aName arguments:(NSString *)theArguments
{
	SPPostgresDumpObject *object = [[[self alloc] init] autorelease];
	object->kind = [aKind copy];
	object->schema = [aSchema copy];
	object->name = [aName copy];
	object->arguments = [theArguments copy];
	return object;
}

- (void)dealloc
{
	[kind release];
	[schema release];
	[name release];
	[arguments release];
	[super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
	return [self retain];
}

static BOOL SPDumpObjectSame(NSString *a, NSString *b)
{
	return a == b || [a isEqualToString:b];
}

- (BOOL)isEqual:(id)object
{
	if (object == self) return YES;
	if (![object isKindOfClass:[SPPostgresDumpObject class]]) return NO;
	SPPostgresDumpObject *other = object;
	return SPDumpObjectSame(kind, other->kind) && SPDumpObjectSame(schema, other->schema) && SPDumpObjectSame(name, other->name) && SPDumpObjectSame(arguments, other->arguments);
}

- (NSUInteger)hash
{
	return [kind hash] ^ ([schema hash] * 31) ^ ([name hash] * 17) ^ [arguments hash];
}

- (NSString *)displayName
{
	if ([kind isEqualToString:SPPostgresDumpObjectExtension]) return [NSString stringWithFormat:@"%@ %@", kind, SPDumpObjectIdentifier(name)];
	NSString *qualified = [NSString stringWithFormat:@"%@.%@", SPDumpObjectIdentifier(schema), SPDumpObjectIdentifier(name)];
	if ([kind isEqualToString:SPPostgresDumpObjectRoutine]) qualified = [qualified stringByAppendingFormat:@"(%@)", arguments ?: @""];
	return [NSString stringWithFormat:@"%@ %@", kind, qualified];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@: %@>", [self class], [self displayName]];
}

@end
