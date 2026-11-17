//
//  SPForeignKeyPickerDataSource.h
//  Sequel Plus
//
//  What the foreign key value picker asks of a database: the referenced table's columns, and pages of its rows
//  matching a search and conditions. One source per engine (SPMySQLForeignKeyPickerSource,
//  SPPostgresForeignKeyPickerSource); conditions are plain values, never SQL.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPForeignKeyColumnKind) {
	SPForeignKeyColumnText,
	SPForeignKeyColumnNumber,
	SPForeignKeyColumnDateTime,
	SPForeignKeyColumnOther
};

extern NSString * const SPForeignKeyOpContains __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpStartsWith __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpEquals __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpNotEquals __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpLess __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpLessOrEqual __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpGreater __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpGreaterOrEqual __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpBetween __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpIsNull __attribute__((visibility("default")));
extern NSString * const SPForeignKeyOpIsNotNull __attribute__((visibility("default")));

/// One column of the referenced table.
__attribute__((visibility("default")))
@interface SPForeignKeyPickerColumn : NSObject
@property (readonly, copy) NSString *name;
@property (readonly) SPForeignKeyColumnKind kind;
+ (instancetype)columnWithName:(NSString *)name kind:(SPForeignKeyColumnKind)kind;
/// The operators a condition on a column of this kind offers, in menu order.
+ (NSArray<NSString *> *)operatorsForKind:(SPForeignKeyColumnKind)kind;
@end

/// One "+ Condition" row: column, operator, value (and secondValue for between). Values are sent as parameters.
__attribute__((visibility("default")))
@interface SPForeignKeyCondition : NSObject
@property (readonly, copy) NSString *column;
@property (readonly, copy) NSString *op;
@property (readonly, copy, nullable) NSString *value;
@property (readonly, copy, nullable) NSString *secondValue;
+ (instancetype)conditionWithColumn:(NSString *)column op:(NSString *)op value:(nullable NSString *)value secondValue:(nullable NSString *)secondValue;
@end

/// Escapes \, % and _ in text so that LIKE / ILIKE … ESCAPE '\' matches it literally.
extern NSString *SPForeignKeyEscapeLikePattern(NSString *text) __attribute__((visibility("default")));

@protocol SPForeignKeyPickerDataSource <NSObject>

/// The referenced (key) column.
@property (readonly, copy) NSString *keyColumn;

/// The referenced table's columns in table order, or nil and the server's message. Completion on the main queue.
- (void)loadColumnsWithCompletion:(void (^)(NSArray<SPForeignKeyPickerColumn *> * _Nullable columns, NSString * _Nullable errorMessage))completion;

/**
 * Up to limit rows after offset whose searchColumns contain search (case-insensitively; nil or empty matches every
 * row) and that match every condition, ordered by the key column, then the table's primary key columns. Each row
 * is an array of NSString / NSNull in `columns` order, as text. On failure rows is nil with the server's message.
 * Completion on the main queue.
 */
- (void)fetchRowsWithSearch:(nullable NSString *)search inColumns:(NSArray<NSString *> *)searchColumns
				 conditions:(NSArray<SPForeignKeyCondition *> *)conditions columns:(NSArray<NSString *> *)columns
					 offset:(NSUInteger)offset limit:(NSUInteger)limit
				 completion:(void (^)(NSArray<NSArray *> * _Nullable rows, NSString * _Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END
