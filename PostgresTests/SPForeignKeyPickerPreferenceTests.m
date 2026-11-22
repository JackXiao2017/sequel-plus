#import <XCTest/XCTest.h>
#import <Cocoa/Cocoa.h>

/// Preferences ▸ Tables: the foreign key picker's checkbox, bound to ForeignKeyPickerEnabled in the shared defaults.
@interface SPForeignKeyPickerPreferenceTests : XCTestCase
@property (strong) NSArray *topLevelObjects;
@end

@implementation SPForeignKeyPickerPreferenceTests

- (NSButton *)buttonTitled:(NSString *)title inView:(NSView *)view
{
	if ([view isKindOfClass:[NSButton class]] && [[(NSButton *)view title] isEqualToString:title]) return (NSButton *)view;
	for (NSView *subview in [view subviews]) {
		NSButton *found = [self buttonTitled:title inView:subview];
		if (found) return found;
	}
	return nil;
}

- (NSButton *)buttonTitled:(NSString *)title
{
	for (id object in self.topLevelObjects) {
		NSView *view = [object isKindOfClass:[NSWindow class]] ? [object contentView] : object;
		if (![view isKindOfClass:[NSView class]]) continue;
		NSButton *found = [self buttonTitled:title inView:view];
		if (found) return found;
	}
	return nil;
}

- (void)testTablesPaneHasPickerCheckboxBoundToDefault
{
	NSNib *nib = [[NSNib alloc] initWithNibNamed:@"Preferences" bundle:[NSBundle mainBundle]];
	XCTAssertNotNil(nib);
	NSArray *objects = nil;
	XCTAssertTrue([nib instantiateWithOwner:nil topLevelObjects:&objects]);
	self.topLevelObjects = objects;

	NSButton *checkbox = [self buttonTitled:@"Open the value picker when editing a foreign key"];
	XCTAssertNotNil(checkbox);
	NSDictionary *binding = [checkbox infoForBinding:NSValueBinding];
	XCTAssertEqualObjects(binding[NSObservedKeyPathKey], @"values.ForeignKeyPickerEnabled");
	XCTAssertEqualObjects(binding[NSObservedObjectKey], [NSUserDefaultsController sharedUserDefaultsController]);

	// In the Tables pane, with the other table checkboxes, without overlapping any of them
	NSButton *nulls = [self buttonTitled:@"New fields should allow nulls"];
	XCTAssertNotNil(nulls);
	XCTAssertEqual([checkbox superview], [nulls superview]);
	for (NSView *sibling in [[checkbox superview] subviews]) {
		if (sibling == checkbox) continue;
		XCTAssertFalse(NSIntersectsRect([sibling frame], [checkbox frame]), @"overlaps %@", sibling);
	}
	XCTAssertTrue(NSContainsRect([[checkbox superview] bounds], [checkbox frame]));

	for (id object in objects) if ([object isKindOfClass:[NSWindow class]]) [object close];
}

@end
