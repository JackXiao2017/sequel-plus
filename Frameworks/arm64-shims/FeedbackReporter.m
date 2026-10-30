//
//  FeedbackReporter.m
//  sequel-pro
//
//  Minimal arm64 replacement for FeedbackReporter.framework. The original
//  posted crash/feedback reports to a server that no longer exists; this
//  keeps the API so the app links and runs, and logs exceptions instead.
//

#import <Cocoa/Cocoa.h>
#import "FRFeedbackReporter.h"
#import "FRExceptionReportingApplication.h"

@implementation FRFeedbackReporter

+ (FRFeedbackReporter *)sharedReporter
{
	static FRFeedbackReporter *sharedReporter = nil;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		sharedReporter = [[FRFeedbackReporter alloc] init];
	});

	return sharedReporter;
}

- (id<FRFeedbackReporterDelegate>)delegate
{
	return delegate;
}

- (void)setDelegate:(id<FRFeedbackReporterDelegate>)aDelegate
{
	delegate = aDelegate;
}

- (BOOL)reportFeedback
{
	return NO;
}

- (BOOL)reportIfCrash
{
	return NO;
}

- (BOOL)reportException:(NSException *)exception
{
	NSLog(@"Uncaught exception: %@\n%@", exception, [exception callStackSymbols]);

	return NO;
}

@end

@implementation FRExceptionReportingApplication

- (void)reportException:(NSException *)exception
{
	[[FRFeedbackReporter sharedReporter] reportException:exception];

	[super reportException:exception];
}

@end
