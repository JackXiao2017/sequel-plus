//
//  SPValueHighlighter.h
//  Sequel Plus
//
//  The value popover's colors (SPValuePopover): the parts of JSON, XML or HTML text and the color each is drawn in.
//  Only a display: the popover draws these as the layout manager's temporary attributes, so the text itself (what
//  Save writes, what undo restores, what is copied) stays plain. Never fails: malformed text gets what can be found.
//

#import <Cocoa/Cocoa.h>
#import "SPValueFormatter.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPValueTokenKind) {
	SPValueTokenKey,          // JSON: a member name
	SPValueTokenString,       // JSON: a string value
	SPValueTokenNumber,       // JSON
	SPValueTokenLiteral,      // JSON: true, false, null
	SPValueTokenTag,          // XML / HTML: "<name", "</name", ">", "/>"
	SPValueTokenAttribute,    // XML / HTML: an attribute's name
	SPValueTokenValue,        // XML / HTML: an attribute's value (with its quotes)
	SPValueTokenComment,      // XML / HTML: <!-- … --> and <![CDATA[ … ]]>
	SPValueTokenEntity,       // XML / HTML: &amp; &#x41; …
	SPValueTokenDeclaration   // XML / HTML: <?xml …?>, <!DOCTYPE …>
};

__attribute__((visibility("default")))
@interface SPValueToken : NSObject
@property (readonly) SPValueTokenKind kind;
@property (readonly) NSRange range;
@end

__attribute__((visibility("default")))
@interface SPValueHighlighter : NSObject

/// The colored parts of text read as format, in order.
+ (NSArray<SPValueToken *> *)tokensInText:(NSString *)text format:(SPValueFormat)format;

/// The ranges a fold can hide (NSValue ranges, by start): the inside of a JSON object or array, an XML / HTML element
/// (between its start and end tags) or a comment, where that inside spans more than one line.
+ (NSArray<NSValue *> *)foldRangesInText:(NSString *)text format:(SPValueFormat)format;

/// The color of a kind: system colors, so they follow light and dark mode.
+ (NSColor *)colorForKind:(SPValueTokenKind)kind;

@end

NS_ASSUME_NONNULL_END
