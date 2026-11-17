//
//  SPForeignKeyPickerDataSource.m
//  Sequel Plus
//

#import "SPForeignKeyPickerDataSource.h"

NSString * const SPForeignKeyOpContains = @"contains";
NSString * const SPForeignKeyOpStartsWith = @"starts with";
NSString * const SPForeignKeyOpEquals = @"=";
NSString * const SPForeignKeyOpNotEquals = @"≠";
NSString * const SPForeignKeyOpLess = @"<";
NSString * const SPForeignKeyOpLessOrEqual = @"≤";
NSString * const SPForeignKeyOpGreater = @">";
NSString * const SPForeignKeyOpGreaterOrEqual = @"≥";
NSString * const SPForeignKeyOpBetween = @"between";
NSString * const SPForeignKeyOpIsNull = @"is NULL";
NSString * const SPForeignKeyOpIsNotNull = @"is not NULL";

NSString *SPForeignKeyEscapeLikePattern(NSString *text, unichar escape)
{
	NSMutableString *escaped = [NSMutableString stringWithCapacity:[text length]];
	for (NSUInteger i = 0; i < [text length]; i++) {
		unichar c = [text characterAtIndex:i];
		if (c == escape || c == '%' || c == '_') [escaped appendFormat:@"%C", escape];
		[escaped appendFormat:@"%C", c];
	}
	return escaped;
}

@implementation SPForeignKeyPickerColumn

@synthesize name = _name;
@synthesize kind = _kind;

+ (instancetype)columnWithName:(NSString *)name kind:(SPForeignKeyColumnKind)kind
{
	SPForeignKeyPickerColumn *column = [[[self alloc] init] autorelease];
	column->_name = [name copy];
	column->_kind = kind;
	return column;
}

+ (NSArray<NSString *> *)operatorsForKind:(SPForeignKeyColumnKind)kind
{
	NSArray *nullOps = @[SPForeignKeyOpIsNull, SPForeignKeyOpIsNotNull];
	switch (kind) {
		case SPForeignKeyColumnText:
			return [@[SPForeignKeyOpContains, SPForeignKeyOpStartsWith, SPForeignKeyOpEquals, SPForeignKeyOpNotEquals] arrayByAddingObjectsFromArray:nullOps];
		case SPForeignKeyColumnNumber:
		case SPForeignKeyColumnDateTime:
			return [@[SPForeignKeyOpEquals, SPForeignKeyOpNotEquals, SPForeignKeyOpLess, SPForeignKeyOpLessOrEqual,
					  SPForeignKeyOpGreater, SPForeignKeyOpGreaterOrEqual, SPForeignKeyOpBetween] arrayByAddingObjectsFromArray:nullOps];
		default:
			return [@[SPForeignKeyOpEquals, SPForeignKeyOpNotEquals] arrayByAddingObjectsFromArray:nullOps];
	}
}

- (void)dealloc
{
	[_name release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ kind %ld>", [self class], _name, (long)_kind];
}

@end

@implementation SPForeignKeyCondition

@synthesize column = _column;
@synthesize op = _op;
@synthesize value = _value;
@synthesize secondValue = _secondValue;

+ (instancetype)conditionWithColumn:(NSString *)column op:(NSString *)op value:(NSString *)value secondValue:(NSString *)secondValue
{
	SPForeignKeyCondition *condition = [[[self alloc] init] autorelease];
	condition->_column = [column copy];
	condition->_op = [op copy];
	condition->_value = [value copy];
	condition->_secondValue = [secondValue copy];
	return condition;
}

- (void)dealloc
{
	[_column release];
	[_op release];
	[_value release];
	[_secondValue release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %@ %@ %@ %@>", [self class], _column, _op, _value, _secondValue];
}

@end
