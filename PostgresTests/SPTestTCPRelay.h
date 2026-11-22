//
//  SPTestTCPRelay.h
//  Sequel Plus
//
//  A TCP relay on 127.0.0.1 for tests: every connection made to localPort is forwarded to 127.0.0.1:port. -freeze
//  makes it go silent the way a dropped NAT entry or a dead network does: the sockets stay open, nothing more is
//  passed in either direction and nothing is closed, so the client only notices by timing out. -stop closes
//  everything (the client sees the connection reset).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPTestTCPRelay : NSObject

/// Listening at once; nil when no port could be opened.
- (nullable instancetype)initForwardingToPort:(NSUInteger)port;

@property (readonly) NSUInteger localPort;

/// Stops relaying (both directions), keeping every socket open.
- (void)freeze;
/// Closes the listener and every relayed connection. Idempotent.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
