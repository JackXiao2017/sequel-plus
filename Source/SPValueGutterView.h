//
//  SPValueGutterView.h
//  Sequel Plus
//
//  The value popover's gutter (SPValuePopover): line numbers of its text view, and the fold arrows (▾ open, ▸ folded)
//  on the lines a fold region starts on. Lines inside a folded region aren't shown (the numbers skip them). Clicking
//  an arrow asks the popover to toggle that fold (⌥: every fold at that level).
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPValueGutterView : NSRulerView

- (instancetype)initWithScrollView:(NSScrollView *)scrollView textView:(NSTextView *)textView;

/// The 1-based line of a character index of the text (its length: the last line).
- (NSUInteger)lineNumberForCharacterIndex:(NSUInteger)index;
/// The character index a 1-based line starts at (NSNotFound past the end).
- (NSUInteger)characterIndexOfLine:(NSUInteger)line;

/// 1-based lines with a fold arrow, and those of them folded.
@property (copy) NSIndexSet *foldableLines;
@property (copy) NSIndexSet *foldedLines;
/// Character ranges whose lines are hidden by folds (a line starting inside one, or right at its end, isn't drawn).
@property (copy) NSArray<NSValue *> *hiddenRanges;

/// The 1-based lines the last drawing showed (for tests).
@property (readonly, copy) NSArray<NSNumber *> *drawnLines;

/// Called when an arrow is clicked: its 1-based line, and whether ⌥ was held.
@property (copy, nullable) void (^toggle)(NSUInteger line, BOOL allAtLevel);

@end

NS_ASSUME_NONNULL_END
