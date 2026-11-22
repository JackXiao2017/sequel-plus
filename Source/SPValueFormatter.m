//
//  SPValueFormatter.m
//  Sequel Plus
//

#import "SPValueFormatter.h"

static NSString *const SPValueFormatterIndent = @"    ";

/// Elements nested deeper than this are copied as they are (laid out by a recursion that must fit a worker's stack).
static const NSUInteger SPValueFormatterMaxDepth = 200;

BOOL SPValuePopoverOffersValue(id value, BOOL textColumn)
{
	return textColumn && ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNull class]]);
}

static inline BOOL SPVFIsSpace(unichar c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static void SPVFAppendIndent(NSMutableString *out, NSUInteger level)
{
	for (NSUInteger i = 0; i < level; i++) [out appendString:SPValueFormatterIndent];
}

/// The line (1-based) of offset in chars.
static NSUInteger SPVFLineAt(const unichar *chars, NSUInteger offset)
{
	NSUInteger line = 1;
	for (NSUInteger i = 0; i < offset; i++) if (chars[i] == '\n') line++;
	return line;
}

#pragma mark - JSON

/// nil when text is valid JSON (any value at the top), else the message to show.
static NSString *SPVFJSONError(NSString *text)
{
	NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
	NSError *error = nil;
	if (data && [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&error]) return nil;
	NSString *reason = [[error userInfo] objectForKey:NSDebugDescriptionErrorKey] ?: [error localizedDescription];
	if (![reason length]) reason = @"the text can't be read";
	return [NSString stringWithFormat:@"Not valid JSON: %@", reason];
}

/// Pretty (YES) or compact (NO) valid JSON: whitespace outside strings is dropped and, for pretty, put back.
static NSString *SPVFJSONLayout(NSString *text, BOOL pretty)
{
	NSUInteger length = [text length];
	unichar *chars = malloc(sizeof(unichar) * (length + 1));
	[text getCharacters:chars range:NSMakeRange(0, length)];
	NSMutableString *out = [NSMutableString stringWithCapacity:length + length / 4];
	NSUInteger level = 0;

	NSUInteger i = 0;
	while (i < length) {
		unichar c = chars[i];
		if (SPVFIsSpace(c)) { i++; continue; }
		if (c == '"') {
			// A string, verbatim up to its unescaped closing quote
			NSUInteger start = i++;
			while (i < length && chars[i] != '"') i += (chars[i] == '\\') ? 2 : 1;
			i = MIN(i + 1, length);
			[out appendString:[NSString stringWithCharacters:chars + start length:i - start]];
			continue;
		}
		if (c == '{' || c == '[') {
			unichar close = (c == '{') ? '}' : ']';
			NSUInteger next = i + 1;
			while (next < length && SPVFIsSpace(chars[next])) next++;
			if (next < length && chars[next] == close) {
				[out appendFormat:@"%C%C", c, close];
				i = next + 1;
				continue;
			}
			[out appendFormat:@"%C", c];
			level++;
			if (pretty) { [out appendString:@"\n"]; SPVFAppendIndent(out, level); }
			i++;
			continue;
		}
		if (c == '}' || c == ']') {
			if (level) level--;
			if (pretty) { [out appendString:@"\n"]; SPVFAppendIndent(out, level); }
			[out appendFormat:@"%C", c];
			i++;
			continue;
		}
		if (c == ',') {
			[out appendString:@","];
			if (pretty) { [out appendString:@"\n"]; SPVFAppendIndent(out, level); }
			i++;
			continue;
		}
		if (c == ':') {
			[out appendString:pretty ? @": " : @":"];
			i++;
			continue;
		}
		// A number or a literal, verbatim
		NSUInteger start = i;
		while (i < length && !SPVFIsSpace(chars[i]) && chars[i] != ',' && chars[i] != ':' && chars[i] != '}' && chars[i] != ']'
			   && chars[i] != '{' && chars[i] != '[' && chars[i] != '"') i++;
		[out appendString:[NSString stringWithCharacters:chars + start length:i - start]];
	}
	free(chars);
	return out;
}

#pragma mark - XML and HTML

typedef NS_ENUM(NSInteger, SPVFNodeKind) {
	SPVFNodeText,     // character data (CDATA too)
	SPVFNodeOther,    // a comment, processing instruction, doctype, or (HTML) a stray end tag
	SPVFNodeElement
};

@interface SPVFNode : NSObject
{
@public
	SPVFNodeKind kind;
	NSRange range;      // the whole node in the source (an element: its start tag to its end tag)
	NSRange openRange;  // an element's start tag
	NSRange closeRange; // an element's end tag (length 0: none)
	NSString *name;     // an element's name (lowercase for HTML)
	BOOL verbatim;      // xml:space="preserve", or an HTML raw-text element: copied as it is
	BOOL whitespace;    // a text node of whitespace only
	NSMutableArray<SPVFNode *> *children;
}
@end

@implementation SPVFNode

- (instancetype)init
{
	if ((self = [super init])) children = [[NSMutableArray alloc] init];
	return self;
}

- (void)dealloc
{
	[name release];
	[children release];
	[super dealloc];
}

@end

static NSSet<NSString *> *SPVFHTMLBlockElements(void)
{
	static NSSet *set;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		set = [[NSSet alloc] initWithArray:@[@"html", @"head", @"body", @"title", @"meta", @"link", @"script", @"style",
											 @"div", @"p", @"ul", @"ol", @"li", @"dl", @"dt", @"dd", @"table", @"caption",
											 @"thead", @"tbody", @"tfoot", @"tr", @"td", @"th", @"colgroup", @"col",
											 @"section", @"article", @"header", @"footer", @"nav", @"aside", @"main",
											 @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"form", @"fieldset", @"legend",
											 @"blockquote", @"figure", @"figcaption", @"pre", @"hr", @"address",
											 @"details", @"summary", @"noscript", @"template", @"video", @"audio",
											 @"canvas", @"iframe", @"select", @"option", @"optgroup"]];
	});
	return set;
}

static NSSet<NSString *> *SPVFHTMLVoidElements(void)
{
	static NSSet *set;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		set = [[NSSet alloc] initWithArray:@[@"area", @"base", @"br", @"col", @"embed", @"hr", @"img", @"input", @"link",
											 @"meta", @"param", @"source", @"track", @"wbr"]];
	});
	return set;
}

static NSSet<NSString *> *SPVFHTMLRawTextElements(void)
{
	static NSSet *set;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ set = [[NSSet alloc] initWithArray:@[@"pre", @"textarea", @"script", @"style"]]; });
	return set;
}

/// Parses XML (strict: unbalanced tags are an error) or HTML (tolerant) into a document node's children.
@interface SPVFParser : NSObject
{
	const unichar *chars;
	NSUInteger length;
	NSString *source;
	BOOL html;
@public
	SPVFNode *root; // the tree parsed so far, also after an error (to be taken apart by SPVFTearDown)
}
- (instancetype)initWithString:(NSString *)string characters:(const unichar *)characters html:(BOOL)isHTML;
/// The document (its children are the top-level nodes), or nil and *error.
- (SPVFNode *)parse:(NSString **)error;
@end

@implementation SPVFParser

- (instancetype)initWithString:(NSString *)string characters:(const unichar *)characters html:(BOOL)isHTML
{
	if ((self = [super init])) {
		source = string;
		chars = characters;
		length = [string length];
		html = isHTML;
	}
	return self;
}

/// The offset of needle at or after from, or NSNotFound.
- (void)dealloc
{
	[root release];
	[super dealloc];
}

- (NSUInteger)find:(NSString *)needle from:(NSUInteger)from caseInsensitive:(BOOL)insensitive
{
	if (from >= length) return NSNotFound;
	NSRange found = [source rangeOfString:needle options:insensitive ? NSCaseInsensitiveSearch : 0 range:NSMakeRange(from, length - from)];
	return found.location;
}

/// The end (one past '>') of the tag starting at start, skipping quoted attribute values; NSNotFound if none.
- (NSUInteger)tagEndFrom:(NSUInteger)start
{
	unichar quote = 0;
	for (NSUInteger i = start + 1; i < length; i++) {
		unichar c = chars[i];
		if (quote) { if (c == quote) quote = 0; }
		else if (c == '"' || c == '\'') quote = c;
		else if (c == '>') return i + 1;
		else if (html && c == '<') return NSNotFound; // "<a <b>": not a tag
	}
	return NSNotFound;
}

- (NSString *)nameFrom:(NSUInteger)start
{
	NSUInteger end = start;
	while (end < length && !SPVFIsSpace(chars[end]) && chars[end] != '>' && chars[end] != '/') end++;
	NSString *name = [NSString stringWithCharacters:chars + start length:end - start];
	return html ? [name lowercaseString] : name;
}

static inline BOOL SPVFIsNameStart(unichar c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == ':' || c > 0x7F;
}

- (NSString *)errorAt:(NSUInteger)offset message:(NSString *)message
{
	return [NSString stringWithFormat:@"Not valid XML: %@ at line %lu", message, (unsigned long)SPVFLineAt(chars, offset)];
}

- (SPVFNode *)parse:(NSString **)error
{
	SPVFNode *document = [[[SPVFNode alloc] init] autorelease];
	document->kind = SPVFNodeElement;
	[root release];
	root = [document retain];
	NSMutableArray<SPVFNode *> *stack = [NSMutableArray arrayWithObject:document];
	NSCountedSet *openNames = [NSCountedSet set]; // the names on the stack: a stray end tag is known at once

	NSUInteger i = 0, textStart = 0;
	while (i <= length) {
		BOOL atTag = (i < length && chars[i] == '<');
		if (i < length && !atTag) { i++; continue; }

		// The text before this tag (or the end)
		if (i > textStart) {
			SPVFNode *text = [[[SPVFNode alloc] init] autorelease];
			text->kind = SPVFNodeText;
			text->range = NSMakeRange(textStart, i - textStart);
			text->whitespace = YES;
			for (NSUInteger k = textStart; k < i; k++) if (!SPVFIsSpace(chars[k])) { text->whitespace = NO; break; }
			[((SPVFNode *)[stack lastObject])->children addObject:text];
		}
		if (i == length) break;

		NSUInteger start = i;
		NSUInteger end = NSNotFound;
		SPVFNode *node = nil;

		if ([source compare:@"<!--" options:0 range:NSMakeRange(start, MIN((NSUInteger)4, length - start))] == NSOrderedSame) {
			NSUInteger close = [self find:@"-->" from:start + 4 caseInsensitive:NO];
			if (close == NSNotFound) {
				if (!html) { if (error) *error = [self errorAt:start message:@"a comment is not closed"]; return nil; }
			} else end = close + 3;
			if (end != NSNotFound) { node = [[[SPVFNode alloc] init] autorelease]; node->kind = SPVFNodeOther; }
		}
		else if ([source compare:@"<![CDATA[" options:0 range:NSMakeRange(start, MIN((NSUInteger)9, length - start))] == NSOrderedSame) {
			NSUInteger close = [self find:@"]]>" from:start + 9 caseInsensitive:NO];
			if (close == NSNotFound) {
				if (!html) { if (error) *error = [self errorAt:start message:@"a CDATA section is not closed"]; return nil; }
			} else end = close + 3;
			if (end != NSNotFound) { node = [[[SPVFNode alloc] init] autorelease]; node->kind = SPVFNodeText; }
		}
		else if (start + 1 < length && (chars[start + 1] == '?' || chars[start + 1] == '!')) {
			end = (chars[start + 1] == '?') ? [self find:@"?>" from:start + 2 caseInsensitive:NO] : [self tagEndFrom:start];
			if (end != NSNotFound && chars[start + 1] == '?') end += 2;
			if (end == NSNotFound) {
				if (!html) { if (error) *error = [self errorAt:start message:@"a declaration is not closed"]; return nil; }
			} else { node = [[[SPVFNode alloc] init] autorelease]; node->kind = SPVFNodeOther; }
		}
		else if (start + 1 < length && chars[start + 1] == '/') {
			end = [self tagEndFrom:start];
			if (end == NSNotFound) {
				if (!html) { if (error) *error = [self errorAt:start message:@"an end tag is not closed"]; return nil; }
			} else {
				NSString *name = [self nameFrom:start + 2];
				// The open element it closes (HTML: anywhere up the stack, closing those above it)
				NSUInteger match = NSNotFound;
				for (NSUInteger s = [stack count] - 1; s > 0 && (!html || [openNames countForObject:name]); s--) {
					SPVFNode *open = [stack objectAtIndex:s];
					if ([open->name isEqualToString:name]) { match = s; break; }
					if (!html) break;
				}
				if (match == NSNotFound) {
					if (!html) {
						SPVFNode *open = [stack count] > 1 ? [stack lastObject] : nil;
						if (error) *error = [self errorAt:start message:open ? [NSString stringWithFormat:@"</%@> does not match <%@>", name, open->name]
																		: [NSString stringWithFormat:@"</%@> has no start tag", name]];
						return nil;
					}
					node = [[[SPVFNode alloc] init] autorelease];
					node->kind = SPVFNodeOther;
				} else {
					while ([stack count] - 1 > match) {
						SPVFNode *unclosed = [stack lastObject];
						unclosed->range.length = start - unclosed->range.location;
						[openNames removeObject:unclosed->name];
						[stack removeLastObject];
					}
					SPVFNode *open = [stack lastObject];
					open->closeRange = NSMakeRange(start, end - start);
					open->range.length = end - open->range.location;
					[openNames removeObject:open->name];
					[stack removeLastObject];
					i = textStart = end;
					continue;
				}
			}
		}
		else if (start + 1 < length && SPVFIsNameStart(chars[start + 1])) {
			end = [self tagEndFrom:start];
			if (end == NSNotFound) {
				if (!html) { if (error) *error = [self errorAt:start message:@"a start tag is not closed"]; return nil; }
			} else {
				node = [[[SPVFNode alloc] init] autorelease];
				node->kind = SPVFNodeElement;
				node->name = [[self nameFrom:start + 1] retain];
				node->openRange = NSMakeRange(start, end - start);
				node->range = node->openRange;
				BOOL empty = (end >= 2 && chars[end - 2] == '/') || (html && [SPVFHTMLVoidElements() containsObject:node->name]);
				NSString *tag = [source substringWithRange:node->openRange];
				if (!html && ([tag rangeOfString:@"xml:space=\"preserve\""].location != NSNotFound
							  || [tag rangeOfString:@"xml:space='preserve'"].location != NSNotFound)) node->verbatim = YES;

				[((SPVFNode *)[stack lastObject])->children addObject:node];
				if (!empty && html && [SPVFHTMLRawTextElements() containsObject:node->name]) {
					// Raw text up to its end tag, as one text node
					node->verbatim = YES;
					NSUInteger close = [self find:[@"</" stringByAppendingString:node->name] from:end caseInsensitive:YES];
					NSUInteger closeEnd = (close == NSNotFound) ? NSNotFound : [self tagEndFrom:close];
					if (close == NSNotFound || closeEnd == NSNotFound) {
						node->range.length = length - start;
						i = textStart = length;
					} else {
						node->closeRange = NSMakeRange(close, closeEnd - close);
						node->range.length = closeEnd - start;
						i = textStart = closeEnd;
					}
					continue;
				}
				if (!empty) {
					[stack addObject:node];
					[openNames addObject:node->name];
					i = textStart = end;
					continue;
				}
			}
		}
		else if (!html) {
			if (error) *error = [self errorAt:start message:@"a \"<\" doesn't start a tag"];
			return nil;
		}

		if (!node) { i = start + 1; continue; } // HTML: a "<" that starts no tag is text
		node->range = NSMakeRange(start, end - start);
		if (node->kind == SPVFNodeText) node->whitespace = NO;
		if (node->kind != SPVFNodeElement) [((SPVFNode *)[stack lastObject])->children addObject:node];
		i = textStart = end;
	}

	if ([stack count] > 1) {
		if (!html) {
			SPVFNode *open = [stack lastObject];
			if (error) *error = [self errorAt:open->range.location message:[NSString stringWithFormat:@"<%@> is not closed", open->name]];
			return nil;
		}
		for (NSUInteger s = 1; s < [stack count]; s++) {
			SPVFNode *unclosed = [stack objectAtIndex:s];
			unclosed->range.length = length - unclosed->range.location;
		}
	}
	return document;
}

@end

/// Laying a parsed document out again: pretty or compact.
@interface SPVFLayout : NSObject
{
	NSString *source;
	BOOL html;
	BOOL pretty;
	NSMutableString *out;
}
- (instancetype)initWithSource:(NSString *)string html:(BOOL)isHTML pretty:(BOOL)isPretty;
- (NSString *)layoutDocument:(SPVFNode *)document;
@end

@implementation SPVFLayout

- (instancetype)initWithSource:(NSString *)string html:(BOOL)isHTML pretty:(BOOL)isPretty
{
	if ((self = [super init])) {
		source = string;
		html = isHTML;
		pretty = isPretty;
		out = [NSMutableString stringWithCapacity:[string length] + [string length] / 4];
	}
	return self;
}

- (BOOL)isBlock:(SPVFNode *)node
{
	return node->kind == SPVFNodeElement && [SPVFHTMLBlockElements() containsObject:node->name];
}

/// Content made only of elements (HTML: block-level ones), comments and whitespace: its layout is managed.
- (BOOL)hasManagedContent:(SPVFNode *)node isDocument:(BOOL)isDocument
{
	if (node->verbatim) return NO;
	if (html && !isDocument && ![self isBlock:node]) return NO;
	BOOL any = NO;
	for (SPVFNode *child in node->children) {
		if (child->kind == SPVFNodeText) {
			if (!child->whitespace) return NO;
			continue;
		}
		if (html && child->kind == SPVFNodeElement && ![self isBlock:child]) return NO;
		any = YES;
	}
	return any;
}

- (void)appendRange:(NSRange)range
{
	if (range.length) [out appendString:[source substringWithRange:range]];
}

- (void)layoutNode:(SPVFNode *)node level:(NSUInteger)level
{
	if (node->kind != SPVFNodeElement || level >= SPValueFormatterMaxDepth || ![self hasManagedContent:node isDocument:NO]) {
		[self appendRange:node->range];
		return;
	}
	[self appendRange:node->openRange];
	[self layoutChildrenOf:node level:level + 1];
	if (node->closeRange.length) {
		if (pretty) { [out appendString:@"\n"]; SPVFAppendIndent(out, level); }
		[self appendRange:node->closeRange];
	}
}

- (void)layoutChildrenOf:(SPVFNode *)node level:(NSUInteger)level
{
	BOOL first = YES;
	for (SPVFNode *child in node->children) {
		if (child->kind == SPVFNodeText && child->whitespace) continue;
		if (pretty && (level > 0 || !first)) {
			[out appendString:@"\n"];
			SPVFAppendIndent(out, level);
		}
		[self layoutNode:child level:level];
		first = NO;
	}
}

- (NSString *)layoutDocument:(SPVFNode *)document
{
	// The top level: XML's is always laid out; HTML's only when it is all block-level
	if (html && ![self hasManagedContent:document isDocument:YES]) return source;
	[self layoutChildrenOf:document level:0];
	return out;
}

@end

/// Takes a tree apart one level at a time: releasing a deeply nested tree would recurse once per level.
static void SPVFTearDown(SPVFNode *root)
{
	if (!root) return;
	NSMutableArray *all = [NSMutableArray array];
	NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
	while ([todo count]) {
		SPVFNode *node = [todo lastObject];
		[all addObject:node];
		[todo removeLastObject];
		[todo addObjectsFromArray:node->children];
	}
	for (SPVFNode *node in all) [node->children removeAllObjects];
}

static NSString *SPVFMarkupLayout(NSString *text, BOOL html, BOOL pretty, NSString **error)
{
	NSUInteger length = [text length];
	unichar *chars = malloc(sizeof(unichar) * (length + 1));
	[text getCharacters:chars range:NSMakeRange(0, length)];
	NSString *result = nil;
	@autoreleasepool {
		SPVFParser *parser = [[SPVFParser alloc] initWithString:text characters:chars html:html];
		NSString *parseError = nil;
		SPVFNode *document = [parser parse:&parseError];
		if (document) {
			SPVFLayout *layout = [[SPVFLayout alloc] initWithSource:text html:html pretty:pretty];
			result = [[layout layoutDocument:document] copy];
			[layout release];
		} else if (error) {
			*error = [parseError retain];
		}
		SPVFTearDown(parser->root);
		[parser release];
	}
	free(chars);
	if (!result && error) [*error autorelease];
	return [result autorelease];
}

#pragma mark -

@implementation SPValueFormatter

+ (NSString *)_layoutString:(NSString *)text format:(SPValueFormat)format pretty:(BOOL)pretty error:(NSString **)error
{
	if (error) *error = nil;
	if (!text) return nil;
	switch (format) {
		case SPValueFormatJSON: {
			NSString *problem = SPVFJSONError(text);
			if (problem) {
				if (error) *error = problem;
				return nil;
			}
			return SPVFJSONLayout(text, pretty);
		}
		case SPValueFormatXML:
			return SPVFMarkupLayout(text, NO, pretty, error);
		case SPValueFormatHTML:
			return SPVFMarkupLayout(text, YES, pretty, error);
	}
	return nil;
}

+ (NSString *)prettyString:(NSString *)text format:(SPValueFormat)format error:(NSString **)error
{
	return [self _layoutString:text format:format pretty:YES error:error];
}

+ (NSString *)compactString:(NSString *)text format:(SPValueFormat)format error:(NSString **)error
{
	return [self _layoutString:text format:format pretty:NO error:error];
}

@end
