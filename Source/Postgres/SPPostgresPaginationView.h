#import <Cocoa/Cocoa.h>

/**
 * The Content tab's "Jump to page" popover content, as MySQL's (ContentPaginationView.xib) without its "Defer loading
 * of blobs and texts" row: a page field, stepper and Go, then MySQL's "Limit result to: [n] rows" settings, bound to
 * the LimitResults and LimitResultsValue preferences of the given defaults. The page controls and the limit field
 * and stepper are enabled only while LimitResults is on. Built in code. Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresPaginationView : NSViewController

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;

/// The page shown in the page field and stepper (1-based), and the stepper's maximum.
@property (nonatomic) NSUInteger page, maxPage;

/// Go (or Return in the page field) takes the typed page into page (empty or not a number: 1), then sends action to
/// target with this view controller.
@property (assign) id target;
@property SEL action;

@property (readonly) NSTextField *pageField, *limitField;
@property (readonly) NSButton *goButton, *limitCheckbox;

/// Puts the focus in the page field.
- (void)makeInputFirstResponder;

@end
