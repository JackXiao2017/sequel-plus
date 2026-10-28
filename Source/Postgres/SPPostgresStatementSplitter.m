#import "SPPostgresStatementSplitter.h"

/// A piece of the text up to and including a semicolon (or the end of the text).
typedef struct {
	NSUInteger start;      // first character
	NSUInteger end;        // after its semicolon (or the end of the text)
	NSUInteger trimStart;  // first character that isn't whitespace (NSNotFound: none)
	NSUInteger trimEnd;    // after the last character that isn't whitespace, before the semicolon
	BOOL hasCode;          // has something besides whitespace and comments
} SPPostgresSegment;

static BOOL SPIsWhitespace(unichar c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v' || c == 0xA0 || c == 0x2028 || c == 0x2029 || c == 0xFEFF;
}

/// May start an identifier or a dollar-quote tag (PostgreSQL: letters, _, and any non-ASCII character).
static BOOL SPIsIdentifierStart(unichar c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80;
}

/// May continue a dollar-quote tag.
static BOOL SPIsTagCharacter(unichar c)
{
	return SPIsIdentifierStart(c) || (c >= '0' && c <= '9');
}

/// May continue an identifier (or a number): then a following $ or ' doesn't open a quote.
static BOOL SPIsIdentifierCharacter(unichar c)
{
	return SPIsTagCharacter(c) || c == '$';
}

/// YES if the word chars[0..<length] is keyword (lowercase ASCII), ignoring case.
static BOOL SPWordIs(const unichar *chars, NSUInteger length, const char *keyword)
{
	if (length != strlen(keyword)) return NO;
	for (NSUInteger k = 0; k < length; k++) {
		unichar c = chars[k];
		if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
		if (c != (unichar)keyword[k]) return NO;
	}
	return YES;
}

/// The first position at or after i that isn't whitespace or in a comment.
static NSUInteger SPSkipWhitespaceAndComments(const unichar *chars, NSUInteger length, NSUInteger i)
{
	while (i < length) {
		if (SPIsWhitespace(chars[i])) {
			i++;
		}
		else if (chars[i] == '-' && i + 1 < length && chars[i + 1] == '-') {
			while (i < length && chars[i] != '\n' && chars[i] != '\r') i++;
		}
		else if (chars[i] == '/' && i + 1 < length && chars[i + 1] == '*') {
			NSUInteger depth = 1;
			i += 2;
			while (i < length && depth > 0) {
				if (chars[i] == '/' && i + 1 < length && chars[i + 1] == '*') { depth++; i += 2; }
				else if (chars[i] == '*' && i + 1 < length && chars[i + 1] == '/') { depth--; i += 2; }
				else i++;
			}
		}
		else {
			break;
		}
	}
	return MIN(i, length);
}

/**
 * Appends the segments of chars[0..<length] to segments, in order, covering it without gaps (at least one).
 * With stopAtFirst, stops after the first segment that ends at a semicolon (appending only that one), so the cost
 * is the length of that statement; when there is none, the whole text is one segment ending at length.
 * Returns YES if it stopped at a semicolon (only with stopAtFirst).
 */
static BOOL SPLexSegments(const unichar *chars, NSUInteger length, BOOL stopAtFirst, NSMutableData *segments)
{
	SPPostgresSegment segment = {0, 0, NSNotFound, 0, NO};

	// Inside a SQL-standard function body (BEGIN ATOMIC … END, PostgreSQL 14+), semicolons end its statements,
	// not this one. CASE … END nests inside it. Counted only there, so a column named begin or end elsewhere
	// changes nothing, and neither do transactions (BEGIN; … COMMIT; END;).
	NSUInteger atomicDepth = 0;

	// Notes the token [from, to) of the current segment
	#define SP_NOTE_TOKEN(from, to, code) do { \
		if (segment.trimStart == NSNotFound) segment.trimStart = (from); \
		segment.trimEnd = (to); \
		if (code) segment.hasCode = YES; \
	} while (0)

	NSUInteger i = 0;
	while (i < length) {
		unichar c = chars[i];
		unichar next = (i + 1 < length) ? chars[i + 1] : 0;

		if (c == ';' && atomicDepth == 0) {
			segment.end = i + 1;
			[segments appendBytes:&segment length:sizeof(segment)];
			if (stopAtFirst) return YES;
			segment = (SPPostgresSegment){i + 1, i + 1, NSNotFound, 0, NO};
			i++;
			continue;
		}

		if (SPIsWhitespace(c)) {
			i++;
			continue;
		}

		NSUInteger j;

		// -- line comment
		if (c == '-' && next == '-') {
			j = i + 2;
			while (j < length && chars[j] != '\n' && chars[j] != '\r') j++;
			SP_NOTE_TOKEN(i, j, NO);
			i = j;
			continue;
		}

		// /* block comment */, nested
		if (c == '/' && next == '*') {
			NSUInteger depth = 1;
			j = i + 2;
			while (j < length && depth > 0) {
				if (chars[j] == '/' && j + 1 < length && chars[j + 1] == '*') {
					depth++;
					j += 2;
				}
				else if (chars[j] == '*' && j + 1 < length && chars[j + 1] == '/') {
					depth--;
					j += 2;
				}
				else {
					j++;
				}
			}
			SP_NOTE_TOKEN(i, MIN(j, length), NO);
			i = MIN(j, length);
			continue;
		}

		// 'string' (E'string' with backslash escapes): '' is a quote in both
		if (c == '\'') {
			BOOL escapes = i > 0 && (chars[i - 1] == 'E' || chars[i - 1] == 'e') && !(i > 1 && SPIsIdentifierCharacter(chars[i - 2]));
			j = i + 1;
			while (j < length) {
				if (escapes && chars[j] == '\\') {
					j += 2;
					continue;
				}
				if (chars[j] == '\'') {
					if (j + 1 < length && chars[j + 1] == '\'') {
						j += 2;
						continue;
					}
					j++;
					break;
				}
				j++;
			}
			j = MIN(j, length);
			SP_NOTE_TOKEN(i, j, YES);
			i = j;
			continue;
		}

		// "identifier": "" is a quote
		if (c == '"') {
			j = i + 1;
			while (j < length) {
				if (chars[j] == '"') {
					if (j + 1 < length && chars[j + 1] == '"') {
						j += 2;
						continue;
					}
					j++;
					break;
				}
				j++;
			}
			j = MIN(j, length);
			SP_NOTE_TOKEN(i, j, YES);
			i = j;
			continue;
		}

		// $tag$ … $tag$ (not $1, nor a $ inside an identifier)
		if (c == '$' && !(i > 0 && SPIsIdentifierCharacter(chars[i - 1]))) {
			j = i + 1;
			if (j < length && SPIsIdentifierStart(chars[j])) {
				j++;
				while (j < length && SPIsTagCharacter(chars[j])) j++;
			}
			if (j < length && chars[j] == '$') {
				NSUInteger tagLength = j + 1 - i;
				NSUInteger end = length;
				for (NSUInteger k = j + 1; k + tagLength <= length; k++) {
					if (chars[k] == '$' && memcmp(chars + k, chars + i, tagLength * sizeof(unichar)) == 0) {
						end = k + tagLength;
						break;
					}
				}
				SP_NOTE_TOKEN(i, end, YES);
				i = end;
				continue;
			}
		}

		// A word: BEGIN ATOMIC, and CASE / END inside it, nest
		if (SPIsIdentifierStart(c) && !(i > 0 && SPIsIdentifierCharacter(chars[i - 1]))) {
			j = i + 1;
			while (j < length && SPIsIdentifierCharacter(chars[j])) j++;

			if (SPWordIs(chars + i, j - i, "begin")) {
				NSUInteger wordStart = SPSkipWhitespaceAndComments(chars, length, j);
				NSUInteger wordEnd = wordStart;
				while (wordEnd < length && SPIsIdentifierCharacter(chars[wordEnd])) wordEnd++;
				if (SPWordIs(chars + wordStart, wordEnd - wordStart, "atomic")) atomicDepth++;
			}
			else if (atomicDepth > 0 && SPWordIs(chars + i, j - i, "case")) {
				atomicDepth++;
			}
			else if (atomicDepth > 0 && SPWordIs(chars + i, j - i, "end")) {
				atomicDepth--;
			}

			SP_NOTE_TOKEN(i, j, YES);
			i = j;
			continue;
		}

		SP_NOTE_TOKEN(i, i + 1, YES);
		i++;
	}

	#undef SP_NOTE_TOKEN

	segment.end = length;
	[segments appendBytes:&segment length:sizeof(segment)];
	return NO;
}

@implementation SPPostgresStatementSplitter

/// Every segment of sql, in order, covering it without gaps (at least one).
+ (NSData *)_segmentsInSQL:(NSString *)sql
{
	NSUInteger length = [sql length];
	NSMutableData *segments = [NSMutableData data];

	unichar *chars = length ? malloc(sizeof(unichar) * length) : NULL;
	if (length && !chars) return segments;
	if (length) [sql getCharacters:chars range:NSMakeRange(0, length)];

	SPLexSegments(chars, length, NO, segments);

	free(chars);

	return segments;
}

+ (NSUInteger)lengthOfCompleteStatementsInSQL:(NSString *)sql
{
	if (![sql length]) return 0;

	NSData *data = [self _segmentsInSQL:sql];
	const SPPostgresSegment *segments = [data bytes];
	NSUInteger count = [data length] / sizeof(SPPostgresSegment);

	// Every segment but the last ends at a top-level semicolon; the last one runs to the end of the text
	return (count >= 2) ? segments[count - 2].end : 0;
}

+ (NSUInteger)lengthOfFirstStatementInCharacters:(const unichar *)characters length:(NSUInteger)length
{
	if (!characters || !length) return 0;

	NSMutableData *data = [NSMutableData dataWithCapacity:sizeof(SPPostgresSegment)];
	if (!SPLexSegments(characters, length, YES, data)) return 0;
	return ((const SPPostgresSegment *)[data bytes])->end;
}

+ (NSString *)topLevelCodeOfStatement:(NSString *)sql
{
	NSUInteger length = [sql length];
	if (!length) return @"";

	unichar *chars = malloc(sizeof(unichar) * length);
	if (!chars) return @"";
	[sql getCharacters:chars range:NSMakeRange(0, length)];

	NSUInteger depth = 0;
	NSUInteger i = 0;
	while (i < length) {
		unichar c = chars[i];
		unichar next = (i + 1 < length) ? chars[i + 1] : 0;
		NSUInteger j = i + 1;
		BOOL blank = depth > 0;

		if (c == '-' && next == '-') {
			j = i + 2;
			while (j < length && chars[j] != '\n' && chars[j] != '\r') j++;
			blank = YES;
		}
		else if (c == '/' && next == '*') {
			NSUInteger nesting = 1;
			j = i + 2;
			while (j < length && nesting > 0) {
				if (chars[j] == '/' && j + 1 < length && chars[j + 1] == '*') { nesting++; j += 2; }
				else if (chars[j] == '*' && j + 1 < length && chars[j + 1] == '/') { nesting--; j += 2; }
				else j++;
			}
			blank = YES;
		}
		else if (c == '\'') {
			BOOL escapes = i > 0 && (chars[i - 1] == 'E' || chars[i - 1] == 'e') && !(i > 1 && SPIsIdentifierCharacter(chars[i - 2]));
			j = i + 1;
			while (j < length) {
				if (escapes && chars[j] == '\\') { j += 2; continue; }
				if (chars[j] == '\'') {
					if (j + 1 < length && chars[j + 1] == '\'') { j += 2; continue; }
					j++;
					break;
				}
				j++;
			}
			blank = YES;
		}
		else if (c == '"') {
			j = i + 1;
			while (j < length) {
				if (chars[j] == '"') {
					if (j + 1 < length && chars[j + 1] == '"') { j += 2; continue; }
					j++;
					break;
				}
				j++;
			}
			blank = YES;
		}
		else if (c == '$' && !(i > 0 && SPIsIdentifierCharacter(chars[i - 1]))) {
			NSUInteger k = i + 1;
			if (k < length && SPIsIdentifierStart(chars[k])) {
				k++;
				while (k < length && SPIsTagCharacter(chars[k])) k++;
			}
			if (k < length && chars[k] == '$') {
				NSUInteger tagLength = k + 1 - i;
				j = length;
				for (NSUInteger m = k + 1; m + tagLength <= length; m++) {
					if (chars[m] == '$' && memcmp(chars + m, chars + i, tagLength * sizeof(unichar)) == 0) {
						j = m + tagLength;
						break;
					}
				}
				blank = YES;
			}
		}
		else if (c == '(') {
			depth++;
			blank = YES;
		}
		else if (c == ')') {
			if (depth > 0) depth--;
			blank = YES;
		}

		j = MIN(j, length);
		if (blank) {
			for (NSUInteger k = i; k < j; k++) chars[k] = ' ';
		}
		i = j;
	}

	NSString *code = [NSString stringWithCharacters:chars length:length];
	free(chars);
	return code;
}

+ (NSArray *)statementsInSQL:(NSString *)sql
{
	if (![sql length]) return @[];

	NSData *data = [self _segmentsInSQL:sql];
	const SPPostgresSegment *segments = [data bytes];
	NSUInteger count = [data length] / sizeof(SPPostgresSegment);

	NSMutableArray *statements = [NSMutableArray arrayWithCapacity:count];
	for (NSUInteger k = 0; k < count; k++) {
		if (!segments[k].hasCode) continue;
		[statements addObject:[sql substringWithRange:NSMakeRange(segments[k].trimStart, segments[k].trimEnd - segments[k].trimStart)]];
	}

	return statements;
}

+ (NSRange)rangeOfStatementAtLocation:(NSUInteger)location inSQL:(NSString *)sql
{
	if (![sql length]) return NSMakeRange(NSNotFound, 0);

	location = MIN(location, [sql length]);

	NSData *data = [self _segmentsInSQL:sql];
	const SPPostgresSegment *segments = [data bytes];
	NSUInteger count = [data length] / sizeof(SPPostgresSegment);
	if (!count) return NSMakeRange(NSNotFound, 0);

	// The segment the location is in, or right after (just after a semicolon: the statement it ends)
	NSUInteger found = count - 1;
	for (NSUInteger k = 0; k < count; k++) {
		if (location <= segments[k].end) {
			found = k;
			break;
		}
	}

	// Only whitespace or comments there: the statement before, else the one after
	NSInteger k = (NSInteger)found;
	while (k >= 0 && !segments[k].hasCode) k--;
	if (k < 0) {
		k = (NSInteger)found;
		while ((NSUInteger)k < count && !segments[k].hasCode) k++;
		if ((NSUInteger)k >= count) return NSMakeRange(NSNotFound, 0);
	}

	return NSMakeRange(segments[k].trimStart, segments[k].trimEnd - segments[k].trimStart);
}

@end
