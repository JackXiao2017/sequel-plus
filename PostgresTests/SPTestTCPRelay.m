//
//  SPTestTCPRelay.m
//  Sequel Plus
//

#import "SPTestTCPRelay.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

@implementation SPTestTCPRelay
{
	int listener;
	NSUInteger targetPort;
	NSMutableArray<NSNumber *> *sockets; // every relayed socket, both ends
	BOOL frozen;
	BOOL stopped;
}

@synthesize localPort;

- (instancetype)initForwardingToPort:(NSUInteger)port
{
	if (!(self = [super init])) return nil;
	targetPort = port;
	sockets = [NSMutableArray array];

	listener = socket(AF_INET, SOCK_STREAM, 0);
	if (listener < 0) return nil;
	int yes = 1;
	setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	struct sockaddr_in address = {0};
	address.sin_len = sizeof(address);
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	address.sin_port = 0;
	socklen_t length = sizeof(address);
	if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 8) != 0
		|| getsockname(listener, (struct sockaddr *)&address, &length) != 0) {
		close(listener);
		return nil;
	}
	localPort = ntohs(address.sin_port);

	int theListener = listener;
	__weak SPTestTCPRelay *weakSelf = self;
	[NSThread detachNewThreadWithBlock:^{
		for (;;) {
			int client = accept(theListener, NULL, NULL);
			if (client < 0) return; // closed by -stop
			SPTestTCPRelay *relay = weakSelf;
			if (!relay) { close(client); return; }
			[relay _relayClient:client];
		}
	}];
	return self;
}

- (void)dealloc
{
	[self stop];
}

- (void)_relayClient:(int)client
{
	int server = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in address = {0};
	address.sin_len = sizeof(address);
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	address.sin_port = htons((uint16_t)targetPort);
	if (server < 0 || connect(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
		if (server >= 0) close(server);
		close(client);
		return;
	}
	@synchronized (self) {
		[sockets addObject:@(client)];
		[sockets addObject:@(server)];
	}
	[self _pumpFrom:client to:server];
	[self _pumpFrom:server to:client];
}

/// Copies from one socket to the other until either closes or the relay stops; frozen, it reads and passes nothing.
- (void)_pumpFrom:(int)from to:(int)to
{
	__weak SPTestTCPRelay *weakSelf = self;
	[NSThread detachNewThreadWithBlock:^{
		char buffer[16384];
		for (;;) {
			SPTestTCPRelay *relay = weakSelf;
			BOOL isFrozen, isStopped;
			if (!relay) return;
			@synchronized (relay) {
				isFrozen = relay->frozen;
				isStopped = relay->stopped;
			}
			relay = nil;
			if (isStopped) return;
			if (isFrozen) { usleep(50000); continue; }

			struct pollfd descriptor = { .fd = from, .events = POLLIN };
			int ready = poll(&descriptor, 1, 100);
			if (ready < 0) return;
			if (ready == 0) continue;
			ssize_t count = read(from, buffer, sizeof(buffer));
			if (count <= 0) { shutdown(to, SHUT_WR); return; }
			// Frozen while this read was under way: lost, as on a dead network
			relay = weakSelf;
			if (!relay) return;
			@synchronized (relay) {
				isFrozen = relay->frozen;
			}
			relay = nil;
			if (isFrozen) continue;
			ssize_t written = 0;
			while (written < count) {
				ssize_t n = write(to, buffer + written, (size_t)(count - written));
				if (n <= 0) return;
				written += n;
			}
		}
	}];
}

- (void)freeze
{
	@synchronized (self) {
		frozen = YES;
	}
}

- (void)stop
{
	NSArray<NSNumber *> *open;
	@synchronized (self) {
		if (stopped) return;
		stopped = YES;
		open = [sockets copy];
		[sockets removeAllObjects];
	}
	shutdown(listener, SHUT_RDWR);
	close(listener);
	for (NSNumber *descriptor in open) {
		shutdown([descriptor intValue], SHUT_RDWR);
		close([descriptor intValue]);
	}
}

@end
