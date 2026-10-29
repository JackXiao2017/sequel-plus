#import "SPPostgresTableInfoController.h"
#import "SPPostgresTableStructure.h"
#import "SPPostgresCreateStatement.h"
#import "SPPostgresQueryController.h"
#import "SPPostgresTaskRunner.h"
#import "SPConstants.h"
#import <PostgresKit/PostgresKit.h>

// MySQL's Table Info tab: right-aligned labels at x 20, values from x 128
static const CGFloat SPPostgresInfoMargin = 20;
static const CGFloat SPPostgresInfoValueX = 128;
static const CGFloat SPPostgresInfoRowHeight = 22;
static const CGFloat SPPostgresInfoCommentHeight = 70;
static const CGFloat SPPostgresInfoNoticeHeight = 22;

@interface SPPostgresTableInfoController ()

@property (readwrite, copy) NSString *schema;
@property (readwrite, copy) NSString *table;
@property (readwrite, copy) NSString *noticeText;

- (void)_buildView;
- (void)_loadInBackground;
- (void)_showInfo:(NSDictionary *)info syntax:(NSString *)syntax;
- (NSString *)_trimmedComment;

@end

@implementation SPPostgresTableInfoController
{
	PGPostgresConnection *connection;
	SPPostgresTableStructure *structure;
	NSString *savedComment; // what the server holds (@"" for none)
	BOOL commentEdited;     // the user typed in the box since it was loaded, saved or reverted
	NSTimeInterval lockTimeout;

	SPPostgresTaskRunner *taskRunner;
	NSUInteger loadGeneration; // taken by each load (and by -invalidate): only the latest one's completion is applied
	BOOL switchPending;        // -showTable:inSchema: asked for a table not loaded yet (a cancel leaves the view stale)
	BOOL stale;

	NSView *view;
	NSTextField *typeField;
	NSTextField *ownerField;
	NSTextField *rowsField;
	NSTextField *tableSizeField;
	NSTextField *indexSizeField;
	NSTextField *totalSizeField;
	NSTextView *commentView;
	NSTextView *createSyntaxView;
	NSTextField *noticeField;

	BOOL invalidated;
}

@synthesize schema;
@synthesize table;
@synthesize noticeText;
@synthesize alertPresenter;
@synthesize tableInfoDidChange;
@synthesize taskRunner;
@synthesize stale;
@synthesize typeField, ownerField, rowsField, tableSizeField, indexSizeField, totalSizeField;
@synthesize commentView, createSyntaxView;

#pragma mark - Setup

- (instancetype)initWithConnection:(PGPostgresConnection *)theConnection
{
	if ((self = [super init])) {
		connection = [theConnection retain];
		taskRunner = [[SPPostgresTaskRunner inlineRunnerWithConnection:theConnection] retain];
		savedComment = [@"" retain];
		noticeText = [@"" copy];
		lockTimeout = 5;
		[self _buildView];
	}
	return self;
}

- (void)dealloc
{
	[self invalidate];

	[connection release];
	[taskRunner release];
	[structure release];
	[savedComment release];
	[schema release];
	[table release];
	[noticeText release];

	[view release];
	[typeField release];
	[ownerField release];
	[rowsField release];
	[tableSizeField release];
	[indexSizeField release];
	[totalSizeField release];
	[commentView release];
	[createSyntaxView release];
	[noticeField release];

	[super dealloc];
}

- (void)invalidate
{
	if (invalidated) return;
	invalidated = YES;
	loadGeneration++;

	[commentView setDelegate:nil];

	// The presenters may capture the tab
	[alertPresenter release], alertPresenter = nil;
	[tableInfoDidChange release], tableInfoDidChange = nil;
}

#pragma mark - View

- (NSTextField *)_labelWithText:(NSString *)text atY:(CGFloat)y
{
	NSTextField *label = [NSTextField labelWithString:text];
	[label setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[label setAlignment:NSTextAlignmentRight];
	[label setFrame:NSMakeRect(SPPostgresInfoMargin, y, SPPostgresInfoValueX - SPPostgresInfoMargin - 8, 17)];
	[label setAutoresizingMask:NSViewMinYMargin];
	return label;
}

/// A selectable, read-only value next to its label (retained: the caller releases it).
- (NSTextField *)_newValueFieldAtY:(CGFloat)y width:(CGFloat)width
{
	NSTextField *field = [[NSTextField labelWithString:@""] retain];
	[field setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[field setSelectable:YES];
	[field setFrame:NSMakeRect(SPPostgresInfoValueX, y, width - SPPostgresInfoValueX - SPPostgresInfoMargin, 17)];
	[field setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	return field;
}

- (NSScrollView *)_scrollViewWithTextView:(NSTextView *)textView frame:(NSRect)frame
{
	NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setAutohidesScrollers:YES];
	[scrollView setBorderType:NSBezelBorder];

	[textView setMinSize:NSMakeSize(0, NSHeight(frame))];
	[textView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	[textView setVerticallyResizable:YES];
	[textView setHorizontallyResizable:NO];
	[textView setAutoresizingMask:NSViewWidthSizable];
	[[textView textContainer] setWidthTracksTextView:YES];
	[[textView textContainer] setContainerSize:NSMakeSize(NSWidth(frame), CGFLOAT_MAX)];
	[textView setRichText:NO];
	[textView setAutomaticQuoteSubstitutionEnabled:NO];
	[textView setAutomaticDashSubstitutionEnabled:NO];
	[textView setAutomaticTextReplacementEnabled:NO];
	[scrollView setDocumentView:textView];
	return scrollView;
}

/// The labels, the comment box and the create syntax, from the top as MySQL's Table Info tab.
- (void)_buildView
{
	NSRect frame = NSMakeRect(0, 0, 700, 500);
	CGFloat width = NSWidth(frame);
	CGFloat height = NSHeight(frame);
	view = [[NSView alloc] initWithFrame:frame];
	[view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

	// Labels from the top
	CGFloat y = height - SPPostgresInfoMargin - 17;
	NSArray *titles = @[NSLocalizedString(@"Type:", @"Postgres table info: type label"),
						NSLocalizedString(@"Owner:", @"Postgres table info: owner label"),
						NSLocalizedString(@"Rows:", @"Postgres table info: row estimate label"),
						NSLocalizedString(@"Table size:", @"Postgres table info: table size label"),
						NSLocalizedString(@"Index size:", @"Postgres table info: index size label"),
						NSLocalizedString(@"Total size:", @"Postgres table info: total size label")];
	NSMutableArray *fields = [NSMutableArray array];
	for (NSString *title in titles) {
		[view addSubview:[self _labelWithText:title atY:y]];
		NSTextField *field = [self _newValueFieldAtY:y width:width];
		[view addSubview:field];
		[fields addObject:field];
		[field release]; // the view holds it; the ivar below retains it again
		y -= SPPostgresInfoRowHeight;
	}
	typeField = [[fields objectAtIndex:0] retain];
	ownerField = [[fields objectAtIndex:1] retain];
	rowsField = [[fields objectAtIndex:2] retain];
	tableSizeField = [[fields objectAtIndex:3] retain];
	indexSizeField = [[fields objectAtIndex:4] retain];
	totalSizeField = [[fields objectAtIndex:5] retain];

	// Comments
	y -= 6;
	CGFloat commentTop = y + 17;
	[view addSubview:[self _labelWithText:NSLocalizedString(@"Comments:", @"Postgres table info: comment label") atY:y]];
	NSRect commentFrame = NSMakeRect(SPPostgresInfoValueX, commentTop - SPPostgresInfoCommentHeight, width - SPPostgresInfoValueX - SPPostgresInfoMargin, SPPostgresInfoCommentHeight);
	commentView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(commentFrame), SPPostgresInfoCommentHeight)];
	[commentView setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[commentView setDelegate:self];
	[commentView setEditable:NO];
	NSScrollView *commentScroll = [self _scrollViewWithTextView:commentView frame:commentFrame];
	[commentScroll setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
	[view addSubview:commentScroll];

	// Create syntax, to the bottom bar
	CGFloat syntaxTop = NSMinY(commentFrame) - 14;
	[view addSubview:[self _labelWithText:NSLocalizedString(@"Create syntax:", @"Postgres table info: create syntax label") atY:syntaxTop - 17]];
	NSRect syntaxFrame = NSMakeRect(SPPostgresInfoValueX, SPPostgresInfoNoticeHeight, width - SPPostgresInfoValueX - SPPostgresInfoMargin, syntaxTop - SPPostgresInfoNoticeHeight);
	createSyntaxView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(syntaxFrame), NSHeight(syntaxFrame))];
	[createSyntaxView setEditable:NO];
	[createSyntaxView setSelectable:YES];
	NSScrollView *syntaxScroll = [self _scrollViewWithTextView:createSyntaxView frame:syntaxFrame];
	[syntaxScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[view addSubview:syntaxScroll];

	// The bottom line
	noticeField = [[NSTextField labelWithString:@""] retain];
	[noticeField setFrame:NSMakeRect(SPPostgresInfoMargin, 4, width - 2 * SPPostgresInfoMargin, 14)];
	[noticeField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[noticeField setTextColor:[NSColor secondaryLabelColor]];
	[[noticeField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	[noticeField setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
	[view addSubview:noticeField];
}

- (NSView *)view
{
	return view;
}

- (NSTimeInterval)lockTimeout
{
	return lockTimeout;
}

- (void)setLockTimeout:(NSTimeInterval)timeout
{
	lockTimeout = timeout;
	[structure setLockTimeout:timeout];
}

#pragma mark - Alerts

- (void)_presentError:(NSError *)error title:(NSString *)title
{
	if (invalidated) return;

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setAlertStyle:NSAlertStyleWarning];
	[alert setMessageText:title];
	NSString *detail = [[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[alert setInformativeText:[detail length] ? detail : NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error")];

	if (alertPresenter) {
		alertPresenter(alert);
		return;
	}
	NSWindow *window = [view window];
	if (window && ![window attachedSheet]) [alert beginSheetModalForWindow:window completionHandler:nil];
	else NSLog(@"%@: %@", [alert messageText], [alert informativeText]);
}

#pragma mark - Loading

/// The runner's thread: the table's information and create syntax, read through structure and connection alone (nil,
/// with *error, if either can't be read).
static NSDictionary *SPPostgresTableInfoRead(SPPostgresTableStructure *structure, NSString *table, NSString *schema, PGPostgresConnection *connection, NSError **error)
{
	NSDictionary *info = [structure tableInfo:error];
	if (!info) return nil;
	NSString *syntax = [SPPostgresCreateStatement createStatementForTable:table inSchema:schema connection:connection error:error];
	if (!syntax) return nil;
	return @{@"info" : info, @"syntax" : syntax};
}

// A load (a switch, -reload) drops a comment edit not saved (as it always has: the text is replaced), so the busy
// state's focus change saves nothing, and takes a new load generation. On the runner's thread the work uses only the
// structure object (made on the main thread, where nothing uses it while the runner is busy: saving is refused then)
// and copies of the names. Back on the main thread the completion is dropped if the controller was invalidated or a
// newer load was asked for; a cancelled load shows no alert (a cancelled switch leaves the view stale); a failed one
// shows the error.

- (void)showTable:(NSString *)theTable inSchema:(NSString *)theSchema
{
	if (invalidated) return;

	[self setTable:theTable];
	[self setSchema:theSchema];
	[structure release];
	structure = nil;
	if ([theTable length] && [theSchema length]) {
		structure = [[SPPostgresTableStructure alloc] initWithConnection:connection schema:theSchema table:theTable];
		[structure setLockTimeout:lockTimeout];
	}

	// The previous table's information goes at once
	[self _showInfo:nil syntax:nil];
	[self setNoticeText:@""];
	[noticeField setStringValue:@""];
	switchPending = (structure != nil);
	[self _loadInBackground];
}

- (void)reload
{
	if (invalidated) return;
	[self _loadInBackground];
}

/// Reads the table's information and create syntax; on failure the view empties and the error is shown.
- (void)_loadInBackground
{
	NSUInteger generation = ++loadGeneration;
	stale = NO;
	if (commentEdited) {
		[commentView setString:savedComment];
		commentEdited = NO;
	}
	if (!structure) {
		switchPending = NO;
		[self _applyInfo:nil error:nil];
		return;
	}

	SPPostgresTableStructure *target = structure;
	NSString *theTable = [[table copy] autorelease];
	NSString *theSchema = [[schema copy] autorelease];
	[taskRunner runTaskWithDescription:NSLocalizedString(@"Reloading...", @"Reloading table task string") cancelTitle:NSLocalizedString(@"Cancel", @"cancel button") work:^id(PGPostgresConnection *theConnection, NSError **error) {
		return SPPostgresTableInfoRead(target, theTable, theSchema, theConnection, error);
	} completion:^(id result, NSError *error, BOOL cancelled) {
		if (invalidated || generation != loadGeneration) return;
		if (cancelled) {
			if (switchPending) stale = YES;
			return;
		}
		switchPending = NO;
		[self _applyInfo:result error:error];
	}];
}

/// Shows what was read (SPPostgresTableInfoRead); nil with a table: the view empties and the error is shown.
- (void)_applyInfo:(NSDictionary *)result error:(NSError *)error
{
	[self _showInfo:[result objectForKey:@"info"] syntax:[result objectForKey:@"syntax"]];

	if (structure && !result) {
		NSString *message = [[[[error localizedDescription] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"] firstObject];
		if (![message length]) message = NSLocalizedString(@"An unknown error occurred.", @"Postgres structure: unknown error");
		[self setNoticeText:[NSString stringWithFormat:NSLocalizedString(@"Could not load the information: %@", @"Postgres table info: bottom line on a read failure"), message]];
		[noticeField setStringValue:noticeText];
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not load the information of “%@”", @"Postgres table info: load failed"), table]];
	}
	else {
		[self setNoticeText:@""];
		[noticeField setStringValue:@""];
	}
}

- (void)_showInfo:(NSDictionary *)info syntax:(NSString *)syntax
{
	id rows = [info objectForKey:@"rowEstimate"];
	NSString *rowsText = @"";
	if (info) {
		if ([rows isKindOfClass:[NSNumber class]]) {
			NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];
			[formatter setNumberStyle:NSNumberFormatterDecimalStyle];
			rowsText = [@"~" stringByAppendingString:[formatter stringFromNumber:rows]];
		}
		else rowsText = NSLocalizedString(@"Unknown (not analyzed)", @"Postgres table info: no row estimate");
	}
	[typeField setStringValue:[info objectForKey:@"kind"] ?: @""];
	[ownerField setStringValue:[info objectForKey:@"owner"] ?: @""];
	[rowsField setStringValue:rowsText];
	[tableSizeField setStringValue:[info objectForKey:@"tableSize"] ?: @""];
	[indexSizeField setStringValue:[info objectForKey:@"indexSize"] ?: @""];
	[totalSizeField setStringValue:[info objectForKey:@"totalSize"] ?: @""];

	id comment = [info objectForKey:@"comment"];
	NSString *commentText = [comment isKindOfClass:[NSString class]] ? comment : @"";
	[savedComment release];
	savedComment = [commentText copy];
	commentEdited = NO;
	[commentView setString:commentText];
	[commentView setEditable:info != nil];

	[createSyntaxView setFont:[SPPostgresQueryController editorFontFromPreferenceData:[[NSUserDefaults standardUserDefaults] dataForKey:SPCustomQueryEditorFont]]];
	[createSyntaxView setString:syntax ?: @""];
	[createSyntaxView scrollRangeToVisible:NSMakeRange(0, 0)];
}

#pragma mark - Comment

- (NSString *)_trimmedComment
{
	return [[commentView string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/**
 * Only what the user typed is pending: a comment set elsewhere (e.g. in SQL) with surrounding whitespace is shown
 * as it is, and merely viewing it must never send COMMENT ON. Trimmed text is compared with the trimmed saved
 * comment, as MySQL's Table Info does.
 */
- (BOOL)hasPendingComment
{
	if (!commentEdited || !structure || ![commentView isEditable]) return NO;
	NSString *saved = [savedComment stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return ![[self _trimmedComment] isEqualToString:saved];
}

- (BOOL)commitPendingEdits
{
	if (invalidated || ![self hasPendingComment]) return YES;

	// Saving runs on the main thread, so never while a load is using the connection: the text stays
	if ([taskRunner isBusy]) {
		NSBeep();
		return NO;
	}

	NSString *comment = [[[self _trimmedComment] copy] autorelease];
	NSError *error = nil;
	if (![structure setTableComment:comment error:&error]) {
		[self _presentError:error title:[NSString stringWithFormat:NSLocalizedString(@"Could not change the comment of “%@”", @"Postgres table info: comment change failed"), table]];
		return NO;
	}

	[savedComment release];
	savedComment = [comment retain];
	commentEdited = NO;
	[commentView setString:comment];

	// The create syntax follows (a failure to read it keeps the old text; the comment is saved)
	NSString *syntax = [SPPostgresCreateStatement createStatementForTable:table inSchema:schema connection:connection error:NULL];
	if (syntax) [createSyntaxView setString:syntax];

	if (tableInfoDidChange) tableInfoDidChange();
	return YES;
}

#pragma mark - Text view delegate

- (void)textDidChange:(NSNotification *)notification
{
	if ([notification object] == commentView) commentEdited = YES;
}

/// The comment box keeps the focus (and its text) when the comment can't be saved.
- (BOOL)textShouldEndEditing:(NSText *)textObject
{
	if (textObject != commentView) return YES;
	return [self commitPendingEdits];
}

/// Escape puts the saved comment back.
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
	if (textView == commentView && commandSelector == @selector(cancelOperation:)) {
		[commentView setString:savedComment];
		commentEdited = NO;
		return YES;
	}
	return NO;
}

@end
