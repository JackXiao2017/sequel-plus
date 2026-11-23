//
//  SPValueFormatter.h
//  Sequel Plus
//
//  Pretty-printing and compacting for the value popover (SPValuePopover): JSON, XML and HTML. Only whitespace
//  between tokens and tags changes:
//
//  - JSON: a line per member and element, 4-space indent, ": " after keys, empty {} and [] kept on one line; string
//    contents, key order, duplicate keys and number text are never touched. Compact removes all whitespace outside
//    strings.
//  - XML: an element whose content is only elements (and whitespace) gets a child per line; an element with any
//    other text (mixed content), xml:space="preserve", comments, CDATA and processing instructions are kept exactly.
//  - HTML: lines and indents only around block-level elements whose content is block-level elements; inline
//    elements and the text around them stay as they are; void elements need no end tag; pre, textarea, script and
//    style content is copied verbatim. Unclosed or stray tags are tolerated: HTML never reports an error.
//
//  Compact removes exactly the whitespace pretty-printing manages (whitespace-only text where content is only
//  elements), so compact(pretty(x)) == compact(x).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPValueFormat) {
	SPValueFormatJSON,
	SPValueFormatXML,
	SPValueFormatHTML
};

__attribute__((visibility("default")))
@interface SPValueFormatter : NSObject

/// The pretty-printed text; nil, and *error a line such as "Not valid JSON: … around line 1, column 6.", when the
/// text isn't valid JSON or XML. HTML never fails.
+ (nullable NSString *)prettyString:(NSString *)text format:(SPValueFormat)format error:(NSString *_Nullable *_Nullable)error;

/// The text without formatting whitespace; nil and *error as -prettyString:format:error:.
+ (nullable NSString *)compactString:(NSString *)text format:(SPValueFormat)format error:(NSString *_Nullable *_Nullable)error;

@end

/// Whether a grid cell shows the value icon: any value of a text column (CHAR, VARCHAR, TEXT, JSON, XML…), whatever its
/// length, NULL included (it can be edited into a value). Numbers, dates, binary and primary key columns don't.
__attribute__((visibility("default"))) BOOL SPValuePopoverOffersValue(id _Nullable value, BOOL textColumn);

NS_ASSUME_NONNULL_END
