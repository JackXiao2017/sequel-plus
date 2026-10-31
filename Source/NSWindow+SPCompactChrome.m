#import "NSWindow+SPCompactChrome.h"

NSImage *SPCompactToolbarImage(NSImage *image)
{
	NSImage *compactImage = [[image copy] autorelease];
	[compactImage setSize:NSMakeSize(24, 24)];
	return compactImage;
}

@implementation NSWindow (SPCompactChrome)

- (void)sp_applyCompactTitle
{
	NSButton *closeButton = [self standardWindowButton:NSWindowCloseButton];
	NSView *titlebarView = [closeButton superview];
	if (!titlebarView) return;

	NSTextField *titleLabel = nil;
	for (NSView *subview in [titlebarView subviews]) {
		if ([[subview identifier] isEqualToString:@"SPCompactWindowTitle"]) {
			titleLabel = (NSTextField *)subview;
			break;
		}
	}

	if (!titleLabel) {
		titleLabel = [NSTextField labelWithString:@""];
		[titleLabel setIdentifier:@"SPCompactWindowTitle"];
		[titleLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightMedium]];
		[titleLabel setAlignment:NSTextAlignmentCenter];
		[titleLabel setLineBreakMode:NSLineBreakByTruncatingMiddle];
		[titleLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
		[titlebarView addSubview:titleLabel];
		[self setTitleVisibility:NSWindowTitleHidden];
	}

	[titleLabel setStringValue:[self title]];

	// Span the titlebar clear of the window buttons, vertically aligned with them
	CGFloat inset = NSMaxX([[self standardWindowButton:NSWindowZoomButton] frame]) + 20;
	CGFloat labelHeight = [titleLabel fittingSize].height;
	[titleLabel setFrame:NSMakeRect(inset, round(NSMidY([closeButton frame]) - labelHeight / 2), [titlebarView bounds].size.width - inset * 2, labelHeight)];
}

- (void)sp_compactWindowDidResize:(NSNotification *)notification
{
	[self sp_applyCompactTitle];
}

- (void)sp_useExpandedCompactToolbar
{
	// Keep the classic layout: title on its own row above a compact toolbar
	if (@available(macOS 11.0, *)) [self setToolbarStyle:NSWindowToolbarStyleExpanded];

	// Keep the compact title centered as the window resizes; remove first so there is only ever one observer
	[self sp_stopCompactTitleTracking];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sp_compactWindowDidResize:) name:NSWindowDidResizeNotification object:self];
}

- (void)sp_stopCompactTitleTracking
{
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResizeNotification object:self];
}

@end
