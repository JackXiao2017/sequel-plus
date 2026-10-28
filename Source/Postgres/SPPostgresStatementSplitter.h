#import <Foundation/Foundation.h>

/**
 * Splits the PostgreSQL Query editor's text into statements at semicolons, as the server's own lexer
 * would. A semicolon doesn't end a statement inside:
 *   - '…' strings ('' is a quote), E'…' strings (\' and '' are quotes), "…" identifiers ("" is a quote),
 *   - $$…$$ and $tag$…$tag$ bodies ($1 and identifiers containing $ are not dollar quotes),
 *   - -- line comments and block comments (slash-star … star-slash, nested).
 *   - SQL-standard function bodies, BEGIN ATOMIC … END (CASE … END nests inside them).
 * An unterminated quote or comment runs to the end of the text (the server then reports it).
 * Pure functions, linear in the text's length; safe on any thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresStatementSplitter : NSObject

/// The statements, in order: trimmed of whitespace, without their semicolons. Empty and comment-only ones are left out.
+ (NSArray *)statementsInSQL:(NSString *)sql;

/**
 * The range in sql of the statement Run Current runs with the cursor at location (clamped to the text): the
 * statement the location is in, or ends right before (just after its semicolon). In the whitespace or comments
 * after the last statement: that statement. Trimmed as -statementsInSQL: returns it. {NSNotFound, 0} if sql
 * has no statement.
 */
+ (NSRange)rangeOfStatementAtLocation:(NSUInteger)location inSQL:(NSString *)sql;

/**
 * The offset just past the last top-level terminating semicolon in sql (one the lexer above accepts as ending a
 * statement), or 0 when there is none. Text read in chunks: everything before it is whole statements, whatever
 * comes next (a dollar-quoted body or string still open at the end of the text) is not.
 */
+ (NSUInteger)lengthOfCompleteStatementsInSQL:(NSString *)sql;

/**
 * The offset just past the semicolon ending the first statement of characters[0..<length], or 0 when the text holds
 * no complete statement. Lexes only that far, so a reader can walk a large buffer statement by statement in linear
 * time. Same lexer and rules as -lengthOfCompleteStatementsInSQL:.
 */
+ (NSUInteger)lengthOfFirstStatementInCharacters:(const unichar *)characters length:(NSUInteger)length;

@end
