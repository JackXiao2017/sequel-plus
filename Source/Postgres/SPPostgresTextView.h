#import <Cocoa/Cocoa.h>
#import "../SPTextView.h"

/**
 * The PostgreSQL query editor: MySQL's SPTextView (its preferences, colours, line numbers, auto-pair, auto-indent and
 * auto-uppercase), with -doSyntaxHighlighting on SPPostgresSQLTokenizer. Built in code: -initWithFrame:scrollView:
 * runs SPTextView's -awakeFromNib. The toggles are SPTextView's setters (-setAutoindent:, -setAutopair:,
 * -setAutouppercaseKeywords:, -setAutohelp:); SPTextView reads its other preferences from standardUserDefaults.
 * The MySQL features SPTextView gates on SPCustomQuery or on its own class name (tab-trigger snippets, the current
 * query highlight, bundle commands) stay off.
 */
__attribute__((visibility("default")))
@interface SPPostgresTextView : SPTextView

/// A text view that is scrollView's document view, set up as SPTextView is from DBView.xib.
- (instancetype)initWithFrame:(NSRect)frame scrollView:(NSScrollView *)scrollView;

@end
