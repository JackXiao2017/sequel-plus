#import "SPPostgresTextView.h"
#import "SPPostgresSQLTokenizer.h"
#import "SPNarrowDownCompletion.h"
#import "SPConstants.h"

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

// The context menu's "MySQL Help for Word/Selection" item (SP_CQ_SEARCH_IN_MYSQL_HELP_MENU_ITEM_TAG, SPTextView.m)
static const NSInteger SPPostgresHelpMenuItemTag = 1000;

// SPTextView's private pop-up placement (Source/SPTextView.m), used as SPTextView's own completion uses it
@interface SPTextView (SPPostgresCompletionPlacement)
- (void)_positionCompletionPopup:(SPNarrowDownCompletion *)aPopup relativeToTextAtLocation:(NSUInteger)aLocation;
@end

// SPNarrowDownCompletion's private methods (Source/SPNarrowDownCompletion.m): the filtering of the items, and the event
// loop -orderFront: starts after a delay
@interface SPNarrowDownCompletion (SPPostgresCompletionPrivate)
- (void)filter;
- (void)watchUserEvents;
@end

/**
 * The overrides below mirror private SPNarrowDownCompletion code (Source/SPNarrowDownCompletion.m), and must follow it
 * if it changes: -filter its filtering (lines 644–770), -insertAutocompletePlaceholder its placeholder (958–995) and
 * -insert_text: its insertion (1048–1092).
 *
 * MySQL's completion pop-up for the Postgres editor's items, whose "match" may be a double-quoted name:
 * - a filter typed without a leading " (Ord) finds a quoted name by the name itself (Order Items), as one typed after a
 *   " finds it by its quoted form (SPNarrowDownCompletion only compares "match" when an item has one);
 * - the autocompletion placeholder is shown only when what is inserted starts with what was typed, and the replaced
 *   range ends at the caret;
 * - a function gets "()" (CustomQueryFunctionCompletionInsertsArguments), not MySQL's argument snippet for a MySQL
 *   function of that name;
 * - -close also drops the event loop -orderFront: scheduled, so a pop-up closed before it starts never runs it.
 * No item is a reference ("isRef"), so nothing here is backtick-quoted and backtickMode stays 0.
 */
@interface SPPostgresNarrowDownCompletion : SPNarrowDownCompletion

/// The replaced range goes past the caret (a closing " or the rest of the word): SPNarrowDownCompletion's placeholder
/// assumes it ends there, so none is shown.
@property (assign) BOOL rangeExtendsPastCaret;

@end

@implementation SPPostgresNarrowDownCompletion

@synthesize rangeExtendsPastCaret;

- (void)filter
{
	NSString *typed = staticPrefix ? [staticPrefix stringByAppendingString:mutablePrefix] : [NSString stringWithString:mutablePrefix];
	if (dictMode || [typed hasPrefix:@"\""]) {
		[super filter];
		return;
	}

	// The quoted items, filtered on their name: copies without "match", mapped back to the items once filtered
	NSArray *items = suggestions;
	NSMutableArray *byName = [NSMutableArray arrayWithCapacity:[items count]];
	NSMapTable *originals = [[NSMapTable alloc] initWithKeyOptions:(NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality)
													  valueOptions:NSPointerFunctionsStrongMemory capacity:0];
	for (NSDictionary *item in items) {
		if (![[item objectForKey:@"match"] hasPrefix:@"\""]) {
			[byName addObject:item];
			continue;
		}
		NSMutableDictionary *copy = [[item mutableCopy] autorelease];
		[copy removeObjectForKey:@"match"];
		[byName addObject:copy];
		[originals setObject:item forKey:copy];
	}

	suggestions = byName;
	@try {
		[super filter];
	}
	@finally {
		suggestions = items;
	}

	if ([originals count] && filtered) {
		NSMutableArray *mapped = [NSMutableArray arrayWithCapacity:[filtered count]];
		for (id item in filtered) [mapped addObject:([originals objectForKey:item] ?: item)];
		[filtered release];
		filtered = [mapped retain];
	}
	[originals release];
}

- (void)insertAutocompletePlaceholder
{
	if (rangeExtendsPastCaret) return;

	NSInteger row = [theTableView selectedRow];
	if (row >= 0 && (NSUInteger)row < [filtered count]) {
		NSDictionary *item = [filtered objectAtIndex:(NSUInteger)row];
		NSString *match = [item objectForKey:@"match"] ?: [item objectForKey:@"display"];
		if (match && ![[match lowercaseString] hasPrefix:[originalFilterString lowercaseString]]) {
			// "Order Items" for Ord: no placeholder (the rest of the text wouldn't be what is inserted)
			[self removeAutocompletionPlaceholderUsingFastMethod:YES];
			return;
		}
	}
	[super insertAutocompletePlaceholder];
}

- (void)insert_text:(NSString *)aString
{
	NSInteger row = [theTableView selectedRow];
	NSDictionary *item = (row >= 0 && (NSUInteger)row < [filtered count]) ? [filtered objectAtIndex:(NSUInteger)row] : nil;
	if (dictMode || ![[item objectForKey:@"image"] hasPrefix:@"func"]) {
		[super insert_text:aString];
		return;
	}

	// SPNarrowDownCompletion's insertion (backtickMode is 0: no item is a reference), then "()" for the arguments
	NSUInteger length = [[theView string] length];
	if (NSMaxRange(theCharRange) > length) theCharRange = NSIntersectionRange(NSMakeRange(0, length), theCharRange);
	[theView breakUndoCoalescing];
	if (![theView selectedRange].length) [theView setSelectedRange:theCharRange];
	[theView breakUndoCoalescing];
	[theView insertText:aString];
	if ([prefs boolForKey:SPCustomQueryFunctionCompletionInsertsArguments] && ![aString hasSuffix:@")"]) {
		[theView insertText:@"()"];
		[theView moveLeft:nil];
	}
}

- (void)close
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(watchUserEvents) object:nil];
	[super close];
}

@end

#pragma mark -

/// The name as completion inserts it: double-quoted ("" for ") unless it is an all-lowercase identifier and not a
/// reserved or type_func_name keyword (+[SPPostgresSQLTokenizer reservedKeywords]; an unreserved one, e.g. name or
/// type, is a valid column name as it is).
static NSString *SPPostgresCompletionInsertedName(NSString *name)
{
	static NSCharacterSet *notIdentifier = nil;
	static NSCharacterSet *notFirst = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableCharacterSet *identifier = [NSMutableCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz_0123456789$"];
		notIdentifier = [[identifier invertedSet] retain];
		notFirst = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789$"] retain];
	});

	BOOL plain = [name length]
		&& [name rangeOfCharacterFromSet:notIdentifier].location == NSNotFound
		&& ![notFirst characterIsMember:[name characterAtIndex:0]]
		&& ![[SPPostgresSQLTokenizer reservedKeywords] containsObject:name];
	if (plain) return name;

	return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

/// A completion item for a name (SPNarrowDownCompletion's keys; "match" only when the inserted text differs).
static NSDictionary *SPPostgresCompletionNameItem(NSString *name, NSString *image)
{
	NSString *inserted = SPPostgresCompletionInsertedName(name);
	if ([inserted isEqualToString:name]) return @{@"display": name, @"image": image};
	return @{@"display": name, @"match": inserted, @"image": image};
}

/// Whether c is part of an unquoted identifier (letters, digits, _ and $).
static BOOL SPPostgresIsIdentifierCharacter(unichar c)
{
	return c == '_' || c == '$' || [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c];
}

@implementation SPPostgresTextView

@synthesize completionNamesProvider;

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
		else if (token.kind == SPPostgresTokenString || token.kind == SPPostgresTokenComment) {
			// As SPTextView (its tokens < 4: strings and comments): auto-help skips them
			[textStore addAttribute:SPPostgresQuote value:SPPostgresQuoteValue range:tokenRange];
		}
	}

	[self setNeedsDisplayInRect:[self bounds]];
}

#pragma mark - Help

/**
 * SPTextView's -autoHelp for the Query controller (the delegate) instead of MySQL's SPCustomQuery: when
 * CustomQueryUpdateAutoHelp is on, the help for the selection, or for the word at the caret when it is not inside a
 * string or comment, after 0.1 s (-showAutoHelpForCurrentWord:).
 */
- (void)autoHelp
{
	if (![prefs boolForKey:SPCustomQueryUpdateAutoHelp] || ![[self string] length]) return;

	id helpTarget = [self delegate];
	if (![helpTarget respondsToSelector:@selector(showAutoHelpForCurrentWord:)]) return;

	// If selection show Help for it
	if ([self selectedRange].length) {
		[helpTarget performSelector:@selector(showAutoHelpForCurrentWord:) withObject:self afterDelay:0.1];
		return;
	}
	// Otherwise show Help if caret is not inside quotes
	NSUInteger cursorPosition = [self selectedRange].location;
	// If cursor at the end go one char leftwards
	if (cursorPosition > 0 && cursorPosition >= [[self string] length]) cursorPosition--;
	if (cursorPosition < [[self string] length] && ![(NSString *)[[self textStorage] attribute:SPPostgresQuote atIndex:cursorPosition effectiveRange:NULL] length]) {
		[helpTarget performSelector:@selector(showAutoHelpForCurrentWord:) withObject:self afterDelay:0.1];
	}
}

/// The context menu's help item (⌃H): the PostgreSQL help for the word or selection (the Query controller's).
- (IBAction)showMySQLHelpForCurrentWord:(id)sender
{
	id helpTarget = [self delegate];
	if ([helpTarget respondsToSelector:@selector(showHelpForCurrentWord:)]) [helpTarget performSelector:@selector(showHelpForCurrentWord:) withObject:self];
	else NSBeep();
}

/// The help item's title: "PostgreSQL Help for Word" / "… for Selection".
- (NSString *)_helpMenuItemTitle
{
	return [self selectedRange].length
		? NSLocalizedString(@"PostgreSQL Help for Selection", @"Postgres query editor: context menu help item (selection)")
		: NSLocalizedString(@"PostgreSQL Help for Word", @"Postgres query editor: context menu help item (word)");
}

/// SPTextView's context menu, its help item titled for PostgreSQL (SPTextView titles it again for MySQL's editors).
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSMenu *menu = [super menuForEvent:event];
	[[menu itemWithTag:SPPostgresHelpMenuItemTag] setTitle:[self _helpMenuItemTitle]];
	return menu;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	BOOL valid = [super validateMenuItem:menuItem];
	if ([menuItem action] == @selector(showMySQLHelpForCurrentWord:)) [menuItem setTitle:[self _helpMenuItemTitle]];
	return valid;
}

#pragma mark - Completion

/// The provider's names for key, nil-safe.
- (NSArray<NSString *> *)_completionNames:(NSDictionary *)names forKey:(NSString *)key
{
	id list = [names objectForKey:key];
	return [list isKindOfClass:[NSArray class]] ? list : @[];
}

- (NSArray *)suggestionsForSQLCompletionWith:(NSString *)currentWord dictMode:(BOOL)isDictMode browseMode:(BOOL)dbBrowseMode withTableName:(NSString *)aTableName withDbName:(NSString *)aDbName
{
	NSMutableArray *items = [NSMutableArray array];
	if (!currentWord) currentWord = @"";

	if (!dbBrowseMode) {
		// As SPTextView: the buffer's words starting with the current word (below 1 MB), without it, sorted. A word is
		// an identifier or keyword token (so widget_count is one word, and nothing inside strings or comments)
		NSString *text = [self string];
		if ([text length] && [text length] < 1000000) {
			NSMutableSet *words = [NSMutableSet set];
			for (SPPostgresSQLToken *token in [SPPostgresSQLTokenizer tokensInString:text range:NSMakeRange(0, [text length])]) {
				if ([token kind] != SPPostgresTokenIdentifier && [token kind] != SPPostgresTokenKeyword) continue;
				NSString *string = [text substringWithRange:[token range]];
				if ([string hasPrefix:currentWord]) [words addObject:string];
			}
			[words removeObject:currentWord];
			for (NSString *word in [[words allObjects] sortedArrayUsingSelector:@selector(localizedCompare:)]) {
				[items addObject:@{@"display": word, @"image": @"dummy-small"}];
			}
		}

		if (!isDictMode) {
			for (NSString *keyword in [[[SPPostgresSQLTokenizer keywords] allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
				[items addObject:@{@"display": [keyword uppercaseString], @"image": @"dummy-small"}];
			}
			for (NSString *function in [SPPostgresSQLTokenizer functionNames]) {
				[items addObject:@{@"display": function, @"image": @"func-small"}];
			}
		}
	}

	if (isDictMode) return items;

	NSDictionary *names = completionNamesProvider ? completionNamesProvider() : nil;
	if (!dbBrowseMode) {
		for (NSString *name in [self _completionNames:names forKey:@"databases"]) [items addObject:SPPostgresCompletionNameItem(name, @"database-small")];
		for (NSString *name in [self _completionNames:names forKey:@"schemas"]) [items addObject:SPPostgresCompletionNameItem(name, @"database-small")];
	}
	for (NSString *name in [self _completionNames:names forKey:@"tables"]) [items addObject:SPPostgresCompletionNameItem(name, @"table-small-square")];
	for (NSString *name in [self _completionNames:names forKey:@"views"]) [items addObject:SPPostgresCompletionNameItem(name, @"table-view-small-square")];
	for (NSString *name in [self _completionNames:names forKey:@"columns"]) [items addObject:SPPostgresCompletionNameItem(name, @"field-small-square")];

	return items;
}

/**
 * SPTextView's auto-completion timer action without its SPCustomQuery gate: when CustomQueryAutoComplete is on, the
 * editor is the key window's first responder, nothing is selected and the character before the caret is a word's,
 * completion opens in auto-complete mode (the spelling dictionary inside a string or comment, as SPTextView's).
 * SPTextView schedules it after CustomQueryAutoCompleteDelay when a character is typed.
 */
- (void)doAutoCompletion
{
	if (completionIsOpen || ![self delegate]) return;

	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(doAutoCompletion) object:nil];
	if (![prefs boolForKey:SPCustomQueryAutoComplete]) return;

	NSRange r = [self selectedRange];
	if (r.length || snippetControlCounter > -1 || !r.location) return;

	NSCharacterSet *ignoreCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"\"'`;,()[]{}=+/<> \t\n\r"];
	if ([ignoreCharacterSet characterIsMember:[[self string] characterAtIndex:r.location - 1]]) return;
	if ([[NSApp keyWindow] firstResponder] != self) return;

	BOOL useSpellChecker = ([[self textStorage] attribute:SPPostgresQuote atIndex:r.location - 1 effectiveRange:NULL] != nil);
	[self doCompletionByUsingSpellChecker:useSpellChecker fuzzyMode:NO autoCompleteMode:YES];
}

/**
 * SPTextView's completion (Esc, ⌃Esc, auto-completion) for PostgreSQL identifiers, in SPPostgresNarrowDownCompletion:
 * the word is the identifier at the caret, or a "quoted identifier opened before the caret on its line (its closing "
 * replaced too); after "name." only the tables, views and columns are offered. The spelling dictionary mode (F5, or
 * auto-completion in a string) is SPTextView's.
 */
- (void)doCompletionByUsingSpellChecker:(BOOL)isDictMode fuzzyMode:(BOOL)fuzzySearch autoCompleteMode:(BOOL)autoCompleteMode
{
	if (isDictMode) {
		[super doCompletionByUsingSpellChecker:isDictMode fuzzyMode:fuzzySearch autoCompleteMode:autoCompleteMode];
		return;
	}

	if ([prefs boolForKey:SPCustomQueryAutoComplete]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(doAutoCompletion) object:nil];
	}

	if (![self isEditable] || (completionIsOpen && !completionWasReinvokedAutomatically)) return;

	[self breakUndoCoalescing];
	completionFuzzyMode = fuzzySearch;

	NSString *text = [self string];
	NSUInteger length = [text length];
	NSUInteger caretPos = NSMaxRange([self selectedRange]);
	[self setSelectedRange:NSMakeRange(caretPos, 0)];

	// A "quoted identifier opened before the caret on this line (the tokenizer runs it to the caret when unclosed)
	NSRange lineRange = [text lineRangeForRange:NSMakeRange(caretPos, 0)];
	NSUInteger start = caretPos;
	NSUInteger end = caretPos;
	BOOL quoted = NO;
	if (caretPos > lineRange.location) {
		NSRange headRange = NSMakeRange(lineRange.location, caretPos - lineRange.location);
		SPPostgresSQLToken *last = [[SPPostgresSQLTokenizer tokensInString:text range:headRange] lastObject];
		if ([last kind] == SPPostgresTokenQuotedIdentifier && NSMaxRange([last range]) == caretPos) {
			NSString *token = [text substringWithRange:[last range]];
			NSUInteger quotes = [[token componentsSeparatedByString:@"\""] count] - 1;
			if (quotes % 2) {
				quoted = YES;
				start = [last range].location;
				// Up to and with the closing " on this line (an auto-paired one, or the rest of a name being edited)
				NSUInteger lineEnd = NSMaxRange(lineRange);
				NSRange closing = [text rangeOfString:@"\"" options:0 range:NSMakeRange(caretPos, lineEnd - caretPos)];
				if (closing.location != NSNotFound) end = NSMaxRange(closing);
			}
		}
	}
	if (!quoted) {
		while (start > lineRange.location && SPPostgresIsIdentifierCharacter([text characterAtIndex:start - 1])) start--;
		while (end < length && SPPostgresIsIdentifierCharacter([text characterAtIndex:end])) end++;
	}

	NSRange completionRange = NSMakeRange(start, end - start);
	if (completionRange.length > 100000) return;

	// What is typed (to the caret for a quoted name: its closing " is not typed)
	NSString *filter = quoted ? [text substringWithRange:NSMakeRange(start, caretPos - start)] : [text substringWithRange:completionRange];

	// After "qualifier.": browse mode (the qualifier, unquoted)
	NSString *qualifier = nil;
	if (start > 0 && [text characterAtIndex:start - 1] == '.') {
		NSUInteger qualifierEnd = start - 1;
		NSUInteger qualifierStart = qualifierEnd;
		if (qualifierEnd > lineRange.location && [text characterAtIndex:qualifierEnd - 1] == '"') {
			NSRange opening = [text rangeOfString:@"\"" options:NSBackwardsSearch range:NSMakeRange(lineRange.location, qualifierEnd - 1 - lineRange.location)];
			if (opening.location != NSNotFound) {
				qualifierStart = opening.location;
				NSString *inner = [text substringWithRange:NSMakeRange(qualifierStart + 1, qualifierEnd - qualifierStart - 2)];
				qualifier = [inner stringByReplacingOccurrencesOfString:@"\"\"" withString:@"\""];
			}
		}
		else {
			while (qualifierStart > lineRange.location && SPPostgresIsIdentifierCharacter([text characterAtIndex:qualifierStart - 1])) qualifierStart--;
			if (qualifierStart < qualifierEnd) qualifier = [text substringWithRange:NSMakeRange(qualifierStart, qualifierEnd - qualifierStart)];
		}
	}
	BOOL browseMode = (qualifier != nil);

	// As SPTextView: no auto-uppercasing of the word being completed
	if (completionRange.length && caretPos) [[self textStorage] removeAttribute:SPPostgresSQLKeyword range:completionRange];

	NSArray *items = [self suggestionsForSQLCompletionWith:filter dictMode:NO browseMode:browseMode withTableName:qualifier withDbName:nil];

	if (completionIsOpen) [completionPopup close], completionPopup = nil;
	completionIsOpen = YES;
	// Owned as SPTextView owns its pop-ups: the window releases itself when closed
	completionPopup = [[SPPostgresNarrowDownCompletion alloc] initWithItems:items
	                                                           alreadyTyped:filter
	                                                           staticPrefix:@""
	                                               additionalWordCharacters:@"_.$"
	                                                          caseSensitive:NO
	                                                              charRange:completionRange
	                                                             parseRange:completionRange
	                                                                 inView:self
	                                                               dictMode:NO
	                                                         tabTriggerMode:[self isSnippetMode]
	                                                            fuzzySearch:fuzzySearch
	                                                           backtickMode:0
	                                                             selectedDb:@""
	                                                         caretMovedLeft:NO
	                                                           autoComplete:autoCompleteMode
	                                                              oneColumn:NO
	                                                                  alias:nil
	                                               withDBStructureRetriever:nil];

	[(SPPostgresNarrowDownCompletion *)completionPopup setRangeExtendsPastCaret:(end > caretPos)];
	completionParseRangeLocation = completionRange.location;

	[self _positionCompletionPopup:completionPopup relativeToTextAtLocation:completionRange.location];

	[completionPopup orderFront:self];
	[completionPopup insertAutocompletePlaceholder];
}

/**
 * SPTextView's predefined lists from the provider (never the delegate's MySQL tablesListInstance or document):
 * $SP_ASLIST_ALL_DATABASES the databases, $SP_ASLIST_ALL_TABLES the tables and views, $SP_ASLIST_ALL_FIELDS the
 * current table's columns. Any other kind is logged and beeps, as SPTextView's.
 */
- (void)showCompletionListFor:(NSString *)kind atRange:(NSRange)aRange fuzzySearch:(BOOL)fuzzySearchMode
{
	if ([prefs boolForKey:SPCustomQueryAutoComplete]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(doAutoCompletion) object:nil];
	}

	NSDictionary *names = completionNamesProvider ? completionNamesProvider() : nil;
	NSMutableArray *items = [NSMutableArray array];

	if ([kind isEqualToString:@"$SP_ASLIST_ALL_TABLES"]) {
		for (NSString *name in [self _completionNames:names forKey:@"tables"]) [items addObject:SPPostgresCompletionNameItem(name, @"table-small-square")];
		for (NSString *name in [self _completionNames:names forKey:@"views"]) [items addObject:SPPostgresCompletionNameItem(name, @"table-view-small-square")];
	}
	else if ([kind isEqualToString:@"$SP_ASLIST_ALL_DATABASES"]) {
		for (NSString *name in [self _completionNames:names forKey:@"databases"]) [items addObject:SPPostgresCompletionNameItem(name, @"database-small")];
	}
	else if ([kind isEqualToString:@"$SP_ASLIST_ALL_FIELDS"]) {
		for (NSString *name in [self _completionNames:names forKey:@"columns"]) [items addObject:SPPostgresCompletionNameItem(name, @"field-small-square")];
	}
	else {
		NSLog(@"“%@” is not a valid completion list", kind);
		NSBeep();
		return;
	}

	if (completionIsOpen) [completionPopup close], completionPopup = nil;
	completionIsOpen = YES;
	completionPopup = [[SPPostgresNarrowDownCompletion alloc] initWithItems:items
	                                                           alreadyTyped:@""
	                                                           staticPrefix:@""
	                                               additionalWordCharacters:@"_."
	                                                          caseSensitive:NO
	                                                              charRange:aRange
	                                                             parseRange:aRange
	                                                                 inView:self
	                                                               dictMode:NO
	                                                         tabTriggerMode:[self isSnippetMode]
	                                                            fuzzySearch:fuzzySearchMode
	                                                           backtickMode:0
	                                                             selectedDb:@""
	                                                         caretMovedLeft:NO
	                                                           autoComplete:NO
	                                                              oneColumn:NO
	                                                                  alias:nil
	                                               withDBStructureRetriever:nil];

	[self _positionCompletionPopup:completionPopup relativeToTextAtLocation:aRange.location];

	[completionPopup orderFront:self];
}

- (void)dealloc
{
	[completionNamesProvider release];
	[super dealloc];
}

@end
