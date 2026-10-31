#import <Foundation/Foundation.h>

/// The kinds of SPPostgresDumpObject; each is also the word its displayName starts with.
extern NSString *const SPPostgresDumpObjectTable __attribute__((visibility("default")));          // relkind r and p
extern NSString *const SPPostgresDumpObjectForeignTable __attribute__((visibility("default")));
extern NSString *const SPPostgresDumpObjectView __attribute__((visibility("default")));
extern NSString *const SPPostgresDumpObjectMaterializedView __attribute__((visibility("default")));
extern NSString *const SPPostgresDumpObjectSequence __attribute__((visibility("default")));
extern NSString *const SPPostgresDumpObjectRoutine __attribute__((visibility("default")));        // functions and procedures
extern NSString *const SPPostgresDumpObjectType __attribute__((visibility("default")));           // enum, composite, range
extern NSString *const SPPostgresDumpObjectDomain __attribute__((visibility("default")));
extern NSString *const SPPostgresDumpObjectExtension __attribute__((visibility("default")));

/**
 * One object a dump creates (SPPostgresDumpWriter's objectsInScope:), or one that exists on a server. Immutable;
 * equal when kind, schema, name and arguments are.
 */
__attribute__((visibility("default")))
@interface SPPostgresDumpObject : NSObject <NSCopying>
{
	NSString *kind;
	NSString *schema;
	NSString *name;
	NSString *arguments;
}

+ (instancetype)objectWithKind:(NSString *)kind schema:(NSString *)schema name:(NSString *)name arguments:(NSString *)arguments;

/// One of the SPPostgresDumpObject… constants.
@property (readonly, copy) NSString *kind;
/// For an extension, the schema it is installed in.
@property (readonly, copy) NSString *schema;
@property (readonly, copy) NSString *name;
/// A routine's pg_get_function_identity_arguments text (@"" for none); nil for every other kind.
@property (readonly, copy) NSString *arguments;

/// The kind word and the qualified name, each part quoted only where needed: `table "Sales Data"."Orders 2026"`,
/// `routine public.audit_row()`, `extension citext`.
@property (readonly, copy) NSString *displayName;

@end
