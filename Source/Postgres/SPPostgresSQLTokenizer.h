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
@interface SPPostgresSQLTokenizer : NSObject

/// The tokens of the given range of string, in order, covering the range exactly without gaps.
+ (NSArray<SPPostgresSQLToken *> *)tokensInString:(NSString *)string range:(NSRange)range;

/// Lowercase keywords and built-in type names (frozen from PostgreSQL 18).
+ (NSSet<NSString *> *)keywords;

/// Lowercase, sorted names of built-in functions (frozen from PostgreSQL 18).
+ (NSArray<NSString *> *)functionNames;

@end
