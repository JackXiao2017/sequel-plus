//
//  UniversalDetector.m
//  sequel-pro
//
//  arm64 replacement for UniversalDetector.framework, backed by Foundation's
//  own encoding detection instead of the bundled Mozilla universalchardet.
//

#import <Foundation/Foundation.h>
#import "UniversalDetector.h"

@implementation UniversalDetector

+ (UniversalDetector *)detector
{
	return [[[UniversalDetector alloc] init] autorelease];
}

- (id)init
{
	if ((self = [super init])) {
		detectorPtr = [[NSMutableData alloc] init];
		charsetName = nil;
		confidence = 0;
	}

	return self;
}

- (void)dealloc
{
	[(NSMutableData *)detectorPtr release];
	[charsetName release];

	[super dealloc];
}

- (void)analyzeData:(NSData *)data
{
	[(NSMutableData *)detectorPtr appendData:data];
	[charsetName release], charsetName = nil;
}

- (void)analyzeBytes:(const char *)data length:(int)len
{
	[self analyzeData:[NSData dataWithBytes:data length:(NSUInteger)len]];
}

- (void)reset
{
	[(NSMutableData *)detectorPtr setLength:0];
	[charsetName release], charsetName = nil;
	confidence = 0;
}

- (BOOL)done
{
	return NO;
}

- (NSStringEncoding)encoding
{
	NSData *data = (NSMutableData *)detectorPtr;

	if (![data length]) return 0;

	// Lossy conversion stays allowed: callers pass a fixed-size prefix of a
	// file, which may end part-way through a multi-byte character.
	BOOL usedLossy = NO;
	NSStringEncoding encoding = [NSString stringEncodingForData:data
												encodingOptions:@{}
												convertedString:NULL
											usedLossyConversion:&usedLossy];

	confidence = (encoding && !usedLossy) ? 1.0f : 0.0f;

	return encoding;
}

- (NSString *)MIMECharset
{
	if (!charsetName) {
		NSStringEncoding encoding = [self encoding];

		if (encoding) {
			CFStringRef name = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(encoding));
			charsetName = [(NSString *)name copy];
		}
	}

	return charsetName;
}

- (float)confidence
{
	[self encoding];

	return confidence;
}

@end
