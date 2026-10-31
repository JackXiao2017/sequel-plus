#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, SPPostgresTokenKind) {
	SPPostgresTokenWhitespace,
	SPPostgresTokenKeyword,
	SPPostgresTokenIdentifier,
	SPPostgresTokenQuotedIdentifier,
	SPPostgresTokenString,
	SPPostgresTokenComment,
	SPPostgresTokenNumber,
	SPPostgresTokenParameter,
	SPPostgresTokenOther
};

/// One token: its kind and its range in the tokenized string.
__attribute__((visibility("default")))
@interface SPPostgresSQLToken : NSObject

@property (readonly) SPPostgresTokenKind kind;
@property (readonly) NSRange range;

@end

/**
 * A pure SQL tokenizer for the PostgreSQL query editor (colouring, auto-uppercase, completion).
 * Lexing follows SPPostgresStatementSplitter: '' doubling, E'' backslash escapes, "" doubling, $tag$ bodies
 * (tags must match), nested block comments. An unterminated string, quoted identifier, dollar body or
 * comment runs to the end of the range. Single pass over UTF-16 code units; safe on any thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresSQLTokenizer : NSObject

/// The tokens of the given range of string, in order, covering the range exactly without gaps.
+ (NSArray<SPPostgresSQLToken *> *)tokensInString:(NSString *)string range:(NSRange)range;

/// Lowercase keywords and built-in type names (frozen from PostgreSQL 18).
+ (NSSet<NSString *> *)keywords;

/// Lowercase keywords that can't be used as a column name unquoted (frozen from PostgreSQL 18, pg_get_keywords()
/// catcode 'R', reserved, and 'T', type_func_name, e.g. join, left, is): a name that is one of them must be double-quoted
/// to be used as an identifier.
+ (NSSet<NSString *> *)reservedKeywords;

/// Lowercase, sorted names of built-in functions (frozen from PostgreSQL 18).
+ (NSArray<NSString *> *)functionNames;

@end
