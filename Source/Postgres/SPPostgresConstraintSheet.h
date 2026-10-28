#import <Cocoa/Cocoa.h>
#import "SPPostgresTableStructure.h"

@class PGPostgresConnection;

/// The kind SPPostgresConstraintSheet takes for an index (the others are SPPostgresConstraintDefinition's kinds).
extern NSString * const SPPostgresConstraintSheetIndexKind __attribute__((visibility("default")));

/// An index to add, as the constraint sheet returns it for the kind @"INDEX" (kind is @"INDEX").
__attribute__((visibility("default")))
@interface SPPostgresIndexDefinition : SPPostgresConstraintDefinition
{
	BOOL _unique;
	NSString *_method;
}

@property (readwrite) BOOL unique;
/// nil (btree), @"btree", @"hash", @"gist", @"gin" or @"brin".
@property (readwrite, copy) NSString *method;

@end

/**
 * The sheet that adds an index or a constraint, built in code, as MySQL's add-index sheet. Used by the Structure
 * view (indexes and constraints) and the Relations view (foreign keys).
 *
 * - @"INDEX": a name (optional), the columns, Unique and the access method. The completion gets an
 *   SPPostgresIndexDefinition.
 * - @"PRIMARY KEY", @"UNIQUE", @"CHECK": a kind pop-up (these three and FOREIGN KEY), a name (optional), and the
 *   columns, or a CHECK's expression (sent as typed).
 * - @"FOREIGN KEY": a name (optional), the columns, the referenced schema and table (listed from the catalog) and
 *   that table's columns, and ON UPDATE / ON DELETE.
 *
 * Use on the main thread. completion is called exactly once: with the definition (Add), or nil (Cancel).
 */
__attribute__((visibility("default")))
@interface SPPostgresConstraintSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

/// The referenced schema starts as the session's current schema.
+ (void)beginForKind:(NSString *)kind columns:(NSArray *)columnNames connection:(PGPostgresConnection *)connection window:(NSWindow *)window completion:(void (^)(SPPostgresConstraintDefinition *definitionOrNil))completion;

/// Same, with the referenced schema starting as `schema` (the table's own), when it is listed.
+ (void)beginForKind:(NSString *)kind columns:(NSArray *)columnNames schema:(NSString *)schema connection:(PGPostgresConnection *)connection window:(NSWindow *)window completion:(void (^)(SPPostgresConstraintDefinition *definitionOrNil))completion;

@end
