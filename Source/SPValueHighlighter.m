//
//  SPValueHighlighter.m
//  Sequel Plus
//

#import "SPValueHighlighter.h"

@implementation SPValueToken
{
@public
	SPValueTokenKind _kind;
	NSRange _range;
}

- (SPValueTokenKind)kind
{
	return _kind;
}

- (NSRange)range
{
	return _range;
}

@end

static inline BOOL SPVHIsSpace(unichar c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static inline BOOL SPVHIsNameStart(unichar c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == ':' || c > 0x7F;
}

static inline BOOL SPVHIsNameChar(unichar c)
{
	return SPVHIsNameStart(c) || (c >= '0' && c <= '9') || c == '-' || c == '.';
}

static void SPVHAdd(NSMutableArray *tokens, SPValueTokenKind kind, NSUInteger start, NSUInteger end)
{
	if (end <= start) return;
	SPValueToken *token = [[SPValueToken alloc] init];
	token->_kind = kind;
	token->_range = NSMakeRange(start, end - start);
	[tokens addObject:token];
	[token release];
}

/// The offset just past needle at or after from, or length when it isn't there (the token runs to the end).
static NSUInteger SPVHEndOf(NSString *text, NSString *needle, NSUInteger from, NSUInteger length, BOOL caseInsensitive)
{
	if (from >= length) return length;
	NSRange found = [text rangeOfString:needle options:caseInsensitive ? NSCaseInsensitiveSearch : 0 range:NSMakeRange(from, length - from)];
	return found.location == NSNotFound ? length : NSMaxRange(found);
}

static void SPVHScanJSON(const unichar *chars, NSUInteger length, NSMutableArray *tokens)
{
	NSUInteger i = 0;
	while (i < length) {
		unichar c = chars[i];
		if (c == '"') {
			NSUInteger start = i++;
			while (i < length && chars[i] != '"') i += (chars[i] == '\\') ? 2 : 1;
			i = MIN(i + 1, length);
			NSUInteger next = i;
			while (next < length && SPVHIsSpace(chars[next])) next++;
			SPVHAdd(tokens, (next < length && chars[next] == ':') ? SPValueTokenKey : SPValueTokenString, start, i);
			continue;
		}
		if (c == '-' || (c >= '0' && c <= '9')) {
			NSUInteger start = i++;
			while (i < length && ((chars[i] >= '0' && chars[i] <= '9') || chars[i] == '.' || chars[i] == 'e' || chars[i] == 'E' || chars[i] == '+' || chars[i] == '-')) i++;
			SPVHAdd(tokens, SPValueTokenNumber, start, i);
			continue;
		}
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			NSUInteger start = i;
			while (i < length && ((chars[i] >= 'a' && chars[i] <= 'z') || (chars[i] >= 'A' && chars[i] <= 'Z'))) i++;
			NSString *word = [NSString stringWithCharacters:chars + start length:i - start];
			if ([word isEqualToString:@"true"] || [word isEqualToString:@"false"] || [word isEqualToString:@"null"]) SPVHAdd(tokens, SPValueTokenLiteral, start, i);
			continue;
		}
		i++;
	}
}

static void SPVHScanMarkup(NSString *text, const unichar *chars, NSUInteger length, BOOL html, NSMutableArray *tokens)
{
	NSUInteger i = 0;
	while (i < length) {
		unichar c = chars[i];

		// An entity in text
		if (c == '&') {
			NSUInteger end = i + 1;
			while (end < length && end - i <= 32 && (SPVHIsNameChar(chars[end]) || chars[end] == '#')) end++;
			if (end < length && chars[end] == ';' && end > i + 1) {
				SPVHAdd(tokens, SPValueTokenEntity, i, end + 1);
				i = end + 1;
			} else {
				i++;
			}
			continue;
		}
		if (c != '<') { i++; continue; }

		NSUInteger start = i;
		NSUInteger rest = length - i;
		if (rest >= 4 && chars[i + 1] == '!' && chars[i + 2] == '-' && chars[i + 3] == '-') {
			i = SPVHEndOf(text, @"-->", i + 4, length, NO);
			SPVHAdd(tokens, SPValueTokenComment, start, i);
			continue;
		}
		if (rest >= 9 && [text compare:@"<![CDATA[" options:0 range:NSMakeRange(i, 9)] == NSOrderedSame) {
			i = SPVHEndOf(text, @"]]>", i + 9, length, NO);
			SPVHAdd(tokens, SPValueTokenComment, start, i);
			continue;
		}
		if (rest >= 2 && chars[i + 1] == '?') {
			i = SPVHEndOf(text, @"?>", i + 2, length, NO);
			SPVHAdd(tokens, SPValueTokenDeclaration, start, i);
			continue;
		}
		if (rest >= 2 && chars[i + 1] == '!') {
			i = SPVHEndOf(text, @">", i + 2, length, NO);
			SPVHAdd(tokens, SPValueTokenDeclaration, start, i);
			continue;
		}

		BOOL closing = (rest >= 2 && chars[i + 1] == '/');
		NSUInteger nameStart = i + (closing ? 2 : 1);
		if (nameStart >= length || !SPVHIsNameStart(chars[nameStart])) { i++; continue; } // a "<" that starts no tag
		NSUInteger nameEnd = nameStart;
		while (nameEnd < length && SPVHIsNameChar(chars[nameEnd])) nameEnd++;
		SPVHAdd(tokens, SPValueTokenTag, start, nameEnd);
		NSString *name = [[NSString stringWithCharacters:chars + nameStart length:nameEnd - nameStart] lowercaseString];
		i = nameEnd;

		// Attributes, up to ">" or "/>"
		BOOL selfClosed = NO, ended = NO;
		while (i < length) {
			unichar a = chars[i];
			if (SPVHIsSpace(a)) { i++; continue; }
			if (a == '>') { SPVHAdd(tokens, SPValueTokenTag, i, i + 1); i++; ended = YES; break; }
			if (a == '/' && i + 1 < length && chars[i + 1] == '>') { SPVHAdd(tokens, SPValueTokenTag, i, i + 2); i += 2; ended = YES; selfClosed = YES; break; }
			if (closing || !SPVHIsNameChar(a)) { i++; continue; }
			NSUInteger attributeStart = i;
			while (i < length && !SPVHIsSpace(chars[i]) && chars[i] != '=' && chars[i] != '>' && chars[i] != '/') i++;
			SPVHAdd(tokens, SPValueTokenAttribute, attributeStart, i);
			NSUInteger after = i;
			while (after < length && SPVHIsSpace(chars[after])) after++;
			if (after >= length || chars[after] != '=') continue;
			i = after + 1;
			while (i < length && SPVHIsSpace(chars[i])) i++;
			if (i >= length) break;
			NSUInteger valueStart = i;
			if (chars[i] == '"' || chars[i] == '\'') {
				unichar quote = chars[i++];
				while (i < length && chars[i] != quote) i++;
				i = MIN(i + 1, length);
			} else {
				while (i < length && !SPVHIsSpace(chars[i]) && chars[i] != '>') i++;
			}
			SPVHAdd(tokens, SPValueTokenValue, valueStart, i);
		}

		// HTML script and style contents are code, not markup: left plain up to their end tag
		if (html && ended && !closing && !selfClosed && ([name isEqualToString:@"script"] || [name isEqualToString:@"style"])) {
			NSRange end = [text rangeOfString:[@"</" stringByAppendingString:name] options:NSCaseInsensitiveSearch range:NSMakeRange(i, length - i)];
			i = (end.location == NSNotFound) ? length : end.location;
		}
	}
}

@implementation SPValueHighlighter

+ (NSArray<SPValueToken *> *)tokensInText:(NSString *)text format:(SPValueFormat)format
{
	NSUInteger length = [text length];
	NSMutableArray *tokens = [NSMutableArray array];
	if (!length) return tokens;
	unichar *chars = malloc(sizeof(unichar) * length);
	[text getCharacters:chars range:NSMakeRange(0, length)];
	if (format == SPValueFormatJSON) SPVHScanJSON(chars, length, tokens);
	else SPVHScanMarkup(text, chars, length, format == SPValueFormatHTML, tokens);
	free(chars);
	return tokens;
}

/// Whether text has a line break inside range.
static BOOL SPVHSpansLines(NSString *text, NSRange range)
{
	return range.length && [text rangeOfString:@"\n" options:NSLiteralSearch range:range].location != NSNotFound;
}

+ (NSArray<NSValue *> *)foldRangesInText:(NSString *)text format:(SPValueFormat)format
{
	NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
	NSUInteger length = [text length];
	if (!length) return ranges;

	if (format == SPValueFormatJSON) {
		unichar *chars = malloc(sizeof(unichar) * length);
		[text getCharacters:chars range:NSMakeRange(0, length)];
		NSMutableArray<NSNumber *> *open = [NSMutableArray array];
		NSUInteger i = 0;
		while (i < length) {
			unichar c = chars[i];
			if (c == '"') {
				i++;
				while (i < length && chars[i] != '"') i += (chars[i] == '\\') ? 2 : 1;
				i++;
				continue;
			}
			if (c == '{' || c == '[') [open addObject:@(i)];
			else if ((c == '}' || c == ']') && [open count]) {
				NSUInteger start = [[open lastObject] unsignedIntegerValue] + 1;
				[open removeLastObject];
				NSRange inside = NSMakeRange(start, i - start);
				if (SPVHSpansLines(text, inside)) [ranges addObject:[NSValue valueWithRange:inside]];
			}
			i++;
		}
		free(chars);
	}
	else {
		BOOL html = (format == SPValueFormatHTML);
		static NSSet *voidElements;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			voidElements = [[NSSet alloc] initWithArray:@[@"area", @"base", @"br", @"col", @"embed", @"hr", @"img", @"input", @"link",
														 @"meta", @"param", @"source", @"track", @"wbr"]];
		});
		NSMutableArray<NSString *> *names = [NSMutableArray array];   // open elements
		NSMutableArray<NSNumber *> *starts = [NSMutableArray array];  // where each one's content starts
		NSString *pendingName = nil; // the start tag being read ("<name" seen, its ">" not yet)
		for (SPValueToken *token in [self tokensInText:text format:format]) {
			NSRange range = token.range;
			if (token.kind == SPValueTokenComment) {
				NSString *comment = [text substringWithRange:range];
				if ([comment hasPrefix:@"<!--"] && [comment hasSuffix:@"-->"] && range.length >= 7) {
					NSRange inside = NSMakeRange(range.location + 4, range.length - 7);
					if (SPVHSpansLines(text, inside)) [ranges addObject:[NSValue valueWithRange:inside]];
				}
				continue;
			}
			if (token.kind != SPValueTokenTag) continue;
			unichar first = [text characterAtIndex:range.location];
			if (first == '<' && range.length >= 2 && [text characterAtIndex:range.location + 1] == '/') {
				pendingName = nil;
				NSString *name = [text substringWithRange:NSMakeRange(range.location + 2, range.length - 2)];
				if (html) name = [name lowercaseString];
				NSUInteger index = [names indexOfObjectWithOptions:NSEnumerationReverse passingTest:^BOOL(NSString *open, NSUInteger idx, BOOL *stop) { return [open isEqualToString:name]; }];
				if (index == NSNotFound) continue;
				NSUInteger start = [[starts objectAtIndex:index] unsignedIntegerValue];
				NSRange inside = NSMakeRange(start, range.location - start);
				if (SPVHSpansLines(text, inside)) [ranges addObject:[NSValue valueWithRange:inside]];
				[names removeObjectsInRange:NSMakeRange(index, [names count] - index)];
				[starts removeObjectsInRange:NSMakeRange(index, [starts count] - index)];
			}
			else if (first == '<') {
				pendingName = [text substringWithRange:NSMakeRange(range.location + 1, range.length - 1)];
				if (html) pendingName = [pendingName lowercaseString];
			}
			else if (first == '>' && pendingName) {
				if (!html || ![voidElements containsObject:pendingName]) {
					[names addObject:pendingName];
					[starts addObject:@(NSMaxRange(range))];
				}
				pendingName = nil;
			}
			else pendingName = nil; // "/>": an empty element
		}
	}

	[ranges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
		NSUInteger x = [a rangeValue].location, y = [b rangeValue].location;
		return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
	}];
	return ranges;
}

+ (NSColor *)colorForKind:(SPValueTokenKind)kind
{
	switch (kind) {
		case SPValueTokenKey: return [NSColor systemPurpleColor];
		case SPValueTokenString: return [NSColor systemRedColor];
		case SPValueTokenNumber: return [NSColor systemBlueColor];
		case SPValueTokenLiteral: return [NSColor systemOrangeColor];
		case SPValueTokenTag: return [NSColor systemBlueColor];
		case SPValueTokenAttribute: return [NSColor systemOrangeColor];
		case SPValueTokenValue: return [NSColor systemRedColor];
		case SPValueTokenComment: return [NSColor systemGrayColor];
		case SPValueTokenEntity: return [NSColor systemPurpleColor];
		case SPValueTokenDeclaration: return [NSColor systemGrayColor];
	}
	return [NSColor textColor];
}

@end
