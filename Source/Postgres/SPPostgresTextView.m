#import "SPPostgresTextView.h"
#import "SPPostgresSQLTokenizer.h"

// The attributes SPTextView's own -doSyntaxHighlighting sets, which its auto-pair (-keyDown:) and auto-help read.
// They are private #defines in Source/SPTextView.m (kLEXToken/kLEXTokenValue, kQuote/kQuoteValue, kSQLkeyword/kValue);
// the values are repeated here.
static NSString * const SPPostgresLEXToken = @"Quoted";          // kLEXToken: inside a token the lexer found (no auto-pair)
static NSString * const SPPostgresLEXTokenValue = @"isMarked";   // kLEXTokenValue
static NSString * const SPPostgresQuote = @"Quote";              // kQuote: inside a string
static NSString * const SPPostgresQuoteValue = @"isQuoted";      // kQuoteValue
static NSString * const SPPostgresSQLKeyword = @"s";             // kSQLkeyword: a keyword (auto-uppercased one token later)
static NSString * const SPPostgresSQLKeywordValue = @"x";        // kValue

// SPTextView.m's partial-parsing limits (SP_SYNTAX_HILITE_BIAS, SP_MAX_TEXT_SIZE_FOR_SYNTAX_HIGHLIGHTING; the trigger,
// SP_TEXT_SIZE_TRIGGER_FOR_PARTLY_PARSING, is in SPTextView.h)
static const NSUInteger SPPostgresSyntaxHiliteBias = 2000;
static const NSUInteger SPPostgresMaxTextSizeForSyntaxHighlighting = 20000000;

@implementation SPPostgresTextView

- (instancetype)initWithFrame:(NSRect)frame scrollView:(NSScrollView *)theScrollView
{
	if ((self = [super initWithFrame:frame])) {
		// As DBView.xib connects it (not retained): the line number ruler and the bounds observer use it
		scrollView = theScrollView;
		[scrollView setDocumentView:self];

		// SPTextView's setup (preferences, colours, ruler, observers); its -dealloc undoes it
		[self awakeFromNib];
	}

	return self;
}

/**
 * SPTextView's -doSyntaxHighlighting (the same range limits, colours and attributes) with the Postgres tokenizer:
 * keywords and built-in type names in the keyword colour, '…' / E'…' / $tag$…$tag$ in the quote colour, "…" in the
 * backtick colour, comments, numbers, $n parameters in the variable colour, anything else in the text colour.
 * A keyword is uppercased (when enabled) once a character has been typed after it, as SPTextView does.
 */
- (void)doSyntaxHighlighting
{
	NSTextStorage *textStore = [self textStorage];
	NSString *selfstr = [self string];
	NSUInteger strlength = [selfstr length];

	if (strlength > SPPostgresMaxTextSizeForSyntaxHighlighting) return;

	NSRange textRange;

	// As SPTextView: a large text is highlighted around the middle of the view port only (±SP_SYNTAX_HILITE_BIAS),
	// from a line start to a line end where one is near enough
	if (strlength > SP_TEXT_SIZE_TRIGGER_FOR_PARTLY_PARSING) {
		NSRect visibleRect = [[[self enclosingScrollView] contentView] documentVisibleRect];
		NSRange visibleRange = [[self layoutManager] glyphRangeForBoundingRectWithoutAdditionalLayout:visibleRect inTextContainer:[self textContainer]];

		if (!visibleRange.length) return;

		NSUInteger curPos = visibleRange.location + (NSUInteger)(visibleRange.length / 2);

		NSUInteger end = curPos + SPPostgresSyntaxHiliteBias;
		NSInteger lengthChecker = SPPostgresSyntaxHiliteBias;
		if (end > strlength) {
			end = strlength;
		}
		else {
			while (end < strlength && lengthChecker > 0) {
				if (CFStringGetCharacterAtIndex((CFStringRef)selfstr, end) == '\n') break;
				end++;
				lengthChecker--;
			}
		}
		if (lengthChecker <= 0) end = curPos + SPPostgresSyntaxHiliteBias;

		NSUInteger start, start_temp;
		if (end <= (SPPostgresSyntaxHiliteBias * 2)) start = 0;
		else start = end - (SPPostgresSyntaxHiliteBias * 2);

		start_temp = start;
		lengthChecker = SPPostgresSyntaxHiliteBias;
		if (start > 0) {
			while (start > 0 && lengthChecker > 0) {
				if (CFStringGetCharacterAtIndex((CFStringRef)selfstr, start) == '\n') break;
				start--;
				lengthChecker--;
			}
		}
		if (lengthChecker <= 0) start = start_temp;

		textRange = NSIntersectionRange(NSMakeRange(start, end - start), NSMakeRange(0, [textStore length]));

		if (!textRange.length) return;
	}
	else {
		textRange = NSMakeRange(0, strlength);
	}

	NSArray<SPPostgresSQLToken *> *tokens = [SPPostgresSQLTokenizer tokensInString:selfstr range:textRange];

	// The keywords to uppercase: as SPTextView, a keyword token marked on the previous pass, now followed by a character
	// that is not (so the keyword is complete). Read before the marks are reset below.
	NSMutableIndexSet *uppercase = [NSMutableIndexSet indexSet];
	if (autouppercaseKeywordsEnabled && textBufferSizeIncreased && !delBackwardsWasPressed) {
		[tokens enumerateObjectsUsingBlock:^(SPPostgresSQLToken *token, NSUInteger idx, BOOL *stop) {
			if (token.kind != SPPostgresTokenKeyword) return;
			NSUInteger tokenEnd = NSMaxRange(token.range) - 1;
			if (tokenEnd + 1 >= strlength) return;
			if (![textStore attribute:SPPostgresSQLKeyword atIndex:tokenEnd effectiveRange:NULL]) return;
			if ([textStore attribute:SPPostgresSQLKeyword atIndex:tokenEnd + 1 effectiveRange:NULL]) return;
			[uppercase addIndex:idx];
		}];
	}

	// Remove the old colours and marks (SPTextView leaves its quote and keyword marks; here a mark always matches the text)
	[textStore removeAttribute:NSForegroundColorAttributeName range:textRange];
	[textStore removeAttribute:SPPostgresLEXToken range:textRange];
	[textStore removeAttribute:SPPostgresQuote range:textRange];
	[textStore removeAttribute:SPPostgresSQLKeyword range:textRange];

	NSUInteger idx = 0;
	for (SPPostgresSQLToken *token in tokens) {
		NSRange tokenRange = NSIntersectionRange(token.range, textRange);
		NSUInteger tokenIndex = idx++;
		if (!tokenRange.length) continue;

		NSColor *tokenColor;
		BOOL marked = NO;
		switch (token.kind) {
			case SPPostgresTokenWhitespace:
				continue;
			case SPPostgresTokenKeyword:
				tokenColor = keywordColor;
				break;
			case SPPostgresTokenString:
				tokenColor = quoteColor;
				marked = YES;
				break;
			case SPPostgresTokenQuotedIdentifier:
				tokenColor = backtickColor;
				marked = YES;
				break;
			case SPPostgresTokenComment:
				tokenColor = commentColor;
				marked = YES;
				break;
			case SPPostgresTokenNumber:
				tokenColor = numericColor;
				break;
			case SPPostgresTokenParameter:
				tokenColor = variableColor;
				break;
			default:
				tokenColor = otherTextColor;
				break;
		}

		if ([uppercase containsIndex:tokenIndex]) {
			NSString *word = [selfstr substringWithRange:tokenRange];
			NSString *upper = [word uppercaseString];
			if (![word isEqualToString:upper] && [upper length] == [word length]) {
				// As SPTextView: registered for undo
				if ([self shouldChangeTextInRange:tokenRange replacementString:upper]) {
					[self replaceCharactersInRange:tokenRange withString:upper];
				}
			}
		}

		if (tokenColor) [textStore addAttribute:NSForegroundColorAttributeName value:tokenColor range:tokenRange];

		// No auto-pairing inside a string, quoted identifier or comment
		if (marked) [textStore addAttribute:SPPostgresLEXToken value:SPPostgresLEXTokenValue range:tokenRange];

		if (token.kind == SPPostgresTokenKeyword) {
			[textStore addAttribute:SPPostgresSQLKeyword value:SPPostgresSQLKeywordValue range:tokenRange];
		}
		else if (token.kind == SPPostgresTokenString) {
			[textStore addAttribute:SPPostgresQuote value:SPPostgresQuoteValue range:tokenRange];
		}
	}

	[self setNeedsDisplayInRect:[self bounds]];
}

@end
