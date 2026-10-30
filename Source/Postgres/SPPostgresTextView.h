#import <Cocoa/Cocoa.h>
#import "../SPTextView.h"

/**
 * The PostgreSQL query editor: MySQL's SPTextView (its preferences, colours, line numbers, auto-pair, auto-indent and
 * auto-uppercase), with -doSyntaxHighlighting on SPPostgresSQLTokenizer. Built in code: -initWithFrame:scrollView:
 * runs SPTextView's -awakeFromNib. The toggles are SPTextView's setters (-setAutoindent:, -setAutopair:,
 * -setAutouppercaseKeywords:, -setAutohelp:); SPTextView reads its other preferences from standardUserDefaults.
 * The MySQL features SPTextView gates on SPCustomQuery or on its own class name (tab-trigger snippets, the current
 * query highlight, bundle commands) stay off.
 *
 * Completion (Esc, ⌃Esc fuzzy, auto-completion after CustomQueryAutoCompleteDelay when CustomQueryAutoComplete is on, and
 * the $SP_ASLIST_* lists) is SPTextView's pop-up (SPNarrowDownCompletion) on the names of completionNamesProvider: it
 * never queries the connection and never inserts a backtick. A word typed after an opening " (or a name typed without
 * one) completes to the quoted name; a function gets "()" when CustomQueryFunctionCompletionInsertsArguments is on.
 * F5 (the spelling dictionary) is SPTextView's.
 */
__attribute__((visibility("default")))
@interface SPPostgresTextView : SPTextView

/// A text view that is scrollView's document view, set up as SPTextView is from DBView.xib.
- (instancetype)initWithFrame:(NSRect)frame scrollView:(NSScrollView *)scrollView;

/**
 * The names completion offers besides the buffer's words, the keywords and the function names, under the keys
 * @"databases", @"schemas", @"tables", @"views" and @"columns" (a key may be missing). Called on the main thread each
 * time completion opens; it must return at once, from lists the tab already holds (never a query: the tab's runner may
 * be using the connection). nil: no names.
 */
@property (copy) NSDictionary<NSString *, NSArray<NSString *> *> * (^completionNamesProvider)(void);

/**
 * SPTextView's completion items (SPNarrowDownCompletion dictionaries: "display", "image", "match" when what is inserted
 * differs; never "isRef", which SPNarrowDownCompletion would backtick-quote): the buffer's words (its identifier and
 * keyword tokens) starting with currentWord (as SPTextView, not in browse mode), SPPostgresSQLTokenizer's keywords (uppercased) and
 * function names, then the provider's databases, schemas, tables, views and columns. A name that is not an all-lowercase
 * identifier, or is a keyword, is inserted double-quoted ("match": "Order Items" → "\"Order Items\""). In browse mode
 * (after "name.") only the tables, views and columns.
 */
- (NSArray *)suggestionsForSQLCompletionWith:(NSString *)currentWord dictMode:(BOOL)isDictMode browseMode:(BOOL)dbBrowseMode withTableName:(NSString *)aTableName withDbName:(NSString *)aDbName;

@end
