//
//  Growl.m
//  sequel-pro
//
//  Minimal arm64 replacement for the defunct Growl.framework. Only the
//  GrowlApplicationBridge methods Sequel Pro calls are implemented; the
//  notifications are delivered through the macOS Notification Center.
//

#import <Cocoa/Cocoa.h>
#import "GrowlApplicationBridge.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface SPGrowlShimCenterDelegate : NSObject <NSUserNotificationCenterDelegate>
@end

static id<GrowlApplicationBridgeDelegate> growlDelegate = nil;
static SPGrowlShimCenterDelegate *centerDelegate = nil;

@implementation SPGrowlShimCenterDelegate

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification
{
	return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification
{
	id clickContext = [[notification userInfo] objectForKey:@"clickContext"];

	if (clickContext && [growlDelegate respondsToSelector:@selector(growlNotificationWasClicked:)]) {
		[growlDelegate growlNotificationWasClicked:clickContext];
	}
}

@end

@implementation GrowlApplicationBridge

+ (BOOL)isGrowlInstalled { return YES; }
+ (BOOL)isGrowlRunning { return YES; }
+ (BOOL)isMistEnabled { return NO; }
+ (void)setShouldUseBuiltInNotifications:(BOOL)should { }
+ (BOOL)shouldUseBuiltInNotifications { return YES; }

+ (void)setGrowlDelegate:(id<GrowlApplicationBridgeDelegate>)inDelegate
{
	growlDelegate = inDelegate;

	if (!centerDelegate) {
		centerDelegate = [[SPGrowlShimCenterDelegate alloc] init];
		[[NSUserNotificationCenter defaultUserNotificationCenter] setDelegate:centerDelegate];
	}

	if ([growlDelegate respondsToSelector:@selector(growlIsReady)]) {
		[growlDelegate growlIsReady];
	}
}

+ (id<GrowlApplicationBridgeDelegate>)growlDelegate
{
	return growlDelegate;
}

+ (void)notifyWithTitle:(NSString *)title
			description:(NSString *)description
	   notificationName:(NSString *)notifName
			   iconData:(NSData *)iconData
			   priority:(signed int)priority
			   isSticky:(BOOL)isSticky
		   clickContext:(id)clickContext
{
	[self notifyWithTitle:title description:description notificationName:notifName iconData:iconData priority:priority isSticky:isSticky clickContext:clickContext identifier:nil];
}

+ (void)notifyWithTitle:(NSString *)title
			description:(NSString *)description
	   notificationName:(NSString *)notifName
			   iconData:(NSData *)iconData
			   priority:(signed int)priority
			   isSticky:(BOOL)isSticky
		   clickContext:(id)clickContext
			 identifier:(NSString *)identifier
{
	NSUserNotification *notification = [[[NSUserNotification alloc] init] autorelease];

	[notification setTitle:title];
	[notification setInformativeText:description];
	if (clickContext) [notification setUserInfo:@{@"clickContext" : clickContext}];

	[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

+ (void)notifyWithDictionary:(NSDictionary *)userInfo { }
+ (BOOL)registerWithDictionary:(NSDictionary *)regDict { return YES; }
+ (void)reregisterGrowlNotifications { }
+ (void)setWillRegisterWhenGrowlIsReady:(BOOL)flag { }
+ (BOOL)willRegisterWhenGrowlIsReady { return NO; }
+ (BOOL)isGrowlURLSchemeAvailable { return NO; }
+ (BOOL)openGrowlPreferences:(BOOL)showApp { return NO; }

@end

#pragma clang diagnostic pop
