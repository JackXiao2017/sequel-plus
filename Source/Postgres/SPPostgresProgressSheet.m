#import "SPPostgresProgressSheet.h"

/// At most about 10 updates a second
static const NSTimeInterval SPPostgresProgressSheetUpdateInterval = 0.1;

@interface SPPostgresProgressSheet ()
- (void)_buildWithTitle:(NSString *)title;
- (void)_attachToWindow:(NSWindow *)window;
- (void)_applyPendingUpdate;
@end

@implementation SPPostgresProgressSheet
{
	NSPanel *panel;
	NSTextField *titleField;
	NSTextField *statusField;
	NSProgressIndicator *progressIndicator;
	NSButton *cancelButton;

	/// Guards everything below (touched from any thread)
	NSLock *lock;
	BOOL cancelled;
	BOOL ended;
	BOOL updateScheduled;
	NSString *pendingStatus;
	double pendingFraction;
	NSTimeInterval lastUpdate;
}

@synthesize panel;
@synthesize titleField;
@synthesize statusField;
@synthesize progressIndicator;
@synthesize cancelButton;

+ (instancetype)beginOnWindow:(NSWindow *)window title:(NSString *)title
{
	SPPostgresProgressSheet *sheet = [[[self alloc] init] autorelease];
	[sheet _buildWithTitle:title];
	[sheet retain]; // until -end
	[sheet _attachToWindow:window];
	return sheet;
}

- (instancetype)init
{
	if ((self = [super init])) {
		lock = [[NSLock alloc] init];
		pendingFraction = -1;
	}
	return self;
}

- (void)dealloc
{
	[cancelButton setTarget:nil];
	[panel release];
	[titleField release];
	[statusField release];
	[progressIndicator release];
	[cancelButton release];
	[pendingStatus release];
	[lock release];
	[super dealloc];
}

- (NSTextField *)_labelWithFrame:(NSRect)frame font:(NSFont *)font
{
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	[label setFont:font];
	[label setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[label setAutoresizingMask:NSViewWidthSizable];
	return label;
}

- (void)_buildWithTitle:(NSString *)title
{
	CGFloat width = 440, height = 128;
	panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	[panel setReleasedWhenClosed:NO];
	NSView *content = [panel contentView];

	titleField = [[self _labelWithFrame:NSMakeRect(20, height - 36, width - 40, 18) font:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]] retain];
	[titleField setStringValue:title ?: @""];
	[content addSubview:titleField];

	statusField = [[self _labelWithFrame:NSMakeRect(20, height - 58, width - 40, 16) font:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]] retain];
	[statusField setStringValue:@""];
	[content addSubview:statusField];

	progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, height - 82, width - 40, 20)];
	[progressIndicator setStyle:NSProgressIndicatorStyleBar];
	[progressIndicator setIndeterminate:NO];
	[progressIndicator setMinValue:0];
	[progressIndicator setMaxValue:1];
	[progressIndicator setDoubleValue:0];
	[progressIndicator setAutoresizingMask:NSViewWidthSizable];
	[content addSubview:progressIndicator];

	cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 20 - 96, 12, 96, 32)];
	[cancelButton setBezelStyle:NSBezelStyleRounded];
	[cancelButton setTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[cancelButton setKeyEquivalent:@"\e"];
	[cancelButton setTarget:self];
	[cancelButton setAction:@selector(cancel:)];
	[cancelButton setAutoresizingMask:NSViewMinXMargin];
	[content addSubview:cancelButton];
}

- (void)_attachToWindow:(NSWindow *)window
{
	if (!window) return;
	[window beginSheet:panel completionHandler:nil];
}

#pragma mark - Status

- (void)setStatus:(NSString *)status fraction:(double)fraction
{
	NSTimeInterval delay = 0;
	BOOL schedule = NO;

	[lock lock];
	if (!ended) {
		if (status) {
			[pendingStatus release];
			pendingStatus = [status copy];
		}
		if (fraction >= 0) pendingFraction = MIN(fraction, 1.0);
		if (!updateScheduled) {
			updateScheduled = YES;
			schedule = YES;
			NSTimeInterval since = [NSDate timeIntervalSinceReferenceDate] - lastUpdate;
			delay = (since >= SPPostgresProgressSheetUpdateInterval) ? 0 : SPPostgresProgressSheetUpdateInterval - since;
		}
	}
	[lock unlock];

	if (!schedule) return;

	// The block keeps the sheet until it has run
	[self retain];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self _applyPendingUpdate];
		[self release];
	});
}

/// On the main thread: shows the latest status and fraction.
- (void)_applyPendingUpdate
{
	[lock lock];
	updateScheduled = NO;
	lastUpdate = [NSDate timeIntervalSinceReferenceDate];
	NSString *status = [[pendingStatus retain] autorelease];
	double fraction = pendingFraction;
	BOOL isEnded = ended;
	BOOL isCancelled = cancelled;
	[lock unlock];

	if (isEnded) return;
	// "Cancelling…" stays once Cancel was clicked
	if (status && !isCancelled) [statusField setStringValue:status];
	if (fraction >= 0) [progressIndicator setDoubleValue:fraction];
}

#pragma mark - Cancel

- (BOOL)cancelled
{
	[lock lock];
	BOOL result = cancelled;
	[lock unlock];
	return result;
}

- (IBAction)cancel:(id)sender
{
	[lock lock];
	BOOL already = cancelled || ended;
	cancelled = YES;
	[lock unlock];
	if (already) return;

	void (^show)(void) = ^{
		[cancelButton setEnabled:NO];
		[statusField setStringValue:NSLocalizedString(@"Cancelling…", @"Postgres progress sheet: cancelling")];
	};
	if ([NSThread isMainThread]) show();
	else {
		[self retain];
		dispatch_async(dispatch_get_main_queue(), ^{
			show();
			[self release];
		});
	}
}

#pragma mark - End

- (void)end
{
	[lock lock];
	BOOL already = ended;
	ended = YES;
	[lock unlock];
	if (already) return;

	NSWindow *parent = [panel sheetParent];
	if (parent) [parent endSheet:panel];
	[panel orderOut:nil];
	[self autorelease]; // balances +beginOnWindow:title:
}

@end
