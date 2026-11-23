//
//  SPValuePopover.h
//  Sequel Plus
//
//  The whole value of a grid cell, in a popover anchored to the cell (the cell's value icon opens it; see
//  SPTextAndLinkCell). It opens showing the value exactly as stored. Format: JSON / XML / HTML pretty-print the text
//  once, when clicked (SPValueFormatter); Compact removes that formatting again, as the format last clicked; Revert
//  puts the stored value back; all three are undoable like typing. Save, the only thing that writes, hands the text
//  exactly as shown to the grid's saver. Closing after typing asks first; formatting alone never asks. Once a format
//  was clicked the text is drawn in that format's colors (SPValueHighlighter), through Compact and typing, until
//  Revert; the colors are only drawn, the text stays plain. A gutter shows line numbers, and, with a format clicked,
//  fold arrows on the lines that start a multi-line block (a JSON object or array, an XML / HTML element or comment):
//  a folded block shows as ⋯ (its text is all still there for Save, copy and undo); clicking the ⋯ or moving the caret
//  into it unfolds it, and typing, Format, Compact or Revert unfold everything.
//
//  docs/superpowers/specs/2026-11-22-long-text-value-popover-design.md
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The last popover size (NSStringFromSize) in the defaults given to -initWithValue:…: one size for every grid.
extern NSString *const SPValuePopoverSizeKey __attribute__((visibility("default")));

__attribute__((visibility("default")))
@interface SPValuePopover : NSObject <NSPopoverDelegate, NSTextViewDelegate>

/**
 * saver is nil when the cell can't be edited: the text is then read-only and the only button is Close. Otherwise
 * Save calls saver with the text as shown; saver must call done exactly once, on the main thread: nil when saved
 * (the popover closes), or the error to show (the popover stays open, text kept).
 */
- (instancetype)initWithValue:(NSString *)value columnName:(NSString *)columnName defaults:(NSUserDefaults *)defaults
						saver:(nullable void (^)(NSString *text, void (^done)(NSString *_Nullable error)))saver;

/// Shows it as a transient popover under rect of view (the cell). NO when view has no window.
- (BOOL)showRelativeToRect:(NSRect)rect ofView:(NSView *)view;

/// Closes it with no question and no write (the grid reloads, the tab closes…).
- (void)closeDiscarding;

/// Called once, after it closes however it closes.
@property (copy, nullable) void (^closed)(void);

/// Asked before closing with typed changes: YES discards. nil: the "Discard your changes to <column>?" alert.
@property (copy, nullable) BOOL (^discardConfirmer)(NSString *columnName);

/// Values longer than this (characters) are formatted off the main thread: 256 * 1024.
@property NSUInteger backgroundThreshold;

/// Texts longer than this (characters) are not colored: 512 * 1024.
@property NSUInteger colorLimit;

/// The stored value is NULL (opened as empty text): the title says NULL, and Save stays off until something is typed.
@property (nonatomic) BOOL valueIsNull;

/// The content size (560 × 400 by default, at least 360 × 220); remembered when it closes.
@property (nonatomic) NSSize contentSize;

@property (readonly) BOOL isShown;

/// The gutter (line numbers and fold arrows): the scroll view's vertical ruler.
@property (readonly) NSRulerView *gutterView;
/// 1-based lines with a fold arrow, and those of them folded, ascending.
@property (readonly) NSArray<NSNumber *> *foldableLines;
@property (readonly) NSArray<NSNumber *> *foldedLines;
/// As clicking the arrow of a 1-based line (allAtLevel: ⌥-click, every fold at that level); no arrow there: nothing.
- (void)toggleFoldAtLine:(NSUInteger)line allAtLevel:(BOOL)allAtLevel;
/// The 1-based line of a character index of the text.
- (NSUInteger)lineNumberForCharacterIndex:(NSUInteger)index;

#pragma mark - For tests

@property (readonly) NSTextView *textView;
@property (readonly) NSTextField *titleField;
@property (readonly) NSTextField *errorField;
@property (readonly) NSButton *jsonButton;
@property (readonly) NSButton *xmlButton;
@property (readonly) NSButton *htmlButton;
@property (readonly) NSButton *compactButton;
@property (readonly) NSButton *revertButton;
@property (readonly) NSButton *saveButton;
@property (readonly) NSButton *cancelButton;
@property (readonly) BOOL busy;   // a background format is running

- (void)formatJSON;
- (void)formatXML;
- (void)formatHTML;
- (void)compact;
- (void)revert;
- (void)save;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
