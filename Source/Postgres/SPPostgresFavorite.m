#import "SPPostgresFavorite.h"

@implementation SPPostgresFavorite

@synthesize favoriteID, name, colorIndex, type, host, port, user, database, socketPath;
@synthesize useSSL, sslCACertPath, sslCertPath, sslKeyPath;
@synthesize sshHost, sshUser, sshPort, sshKeyPath;

- (instancetype)init
{
	if ((self = [super init])) {
		NSString *uuid = [[NSUUID UUID] UUIDString];
		favoriteID = [uuid copy];
		colorIndex = -1;
		type = SPPostgresTCPIPConnection;
		port = 5432;
	}
	return self;
}

- (void)dealloc
{
	[favoriteID release];
	[name release];
	[host release];
	[user release];
	[database release];
	[socketPath release];
	[sslCACertPath release];
	[sslCertPath release];
	[sslKeyPath release];
	[sshHost release];
	[sshUser release];
	[sshKeyPath release];
	[super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
	SPPostgresFavorite *copy = [[[self class] allocWithZone:zone] init];
	copy.favoriteID = favoriteID;
	copy.name = name;
	copy.colorIndex = colorIndex;
	copy.type = type;
	copy.host = host;
	copy.port = port;
	copy.user = user;
	copy.database = database;
	copy.socketPath = socketPath;
	copy.useSSL = useSSL;
	copy.sslCACertPath = sslCACertPath;
	copy.sslCertPath = sslCertPath;
	copy.sslKeyPath = sslKeyPath;
	copy.sshHost = sshHost;
	copy.sshUser = sshUser;
	copy.sshPort = sshPort;
	copy.sshKeyPath = sshKeyPath;
	return copy;
}

- (NSDictionary *)dictionaryRepresentation
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	void (^put)(NSString *, id) = ^(NSString *key, id value) {
		if (value) [d setObject:value forKey:key];
	};
	put(@"id", favoriteID);
	put(@"name", name);
	put(@"colorIndex", @(colorIndex));
	put(@"type", @((NSInteger)type));
	put(@"host", host);
	put(@"port", @(port));
	put(@"user", user);
	put(@"database", database);
	put(@"socketPath", socketPath);
	put(@"useSSL", @(useSSL));
	put(@"sslCACertPath", sslCACertPath);
	put(@"sslCertPath", sslCertPath);
	put(@"sslKeyPath", sslKeyPath);
	put(@"sshHost", sshHost);
	put(@"sshUser", sshUser);
	put(@"sshPort", @(sshPort));
	put(@"sshKeyPath", sshKeyPath);
	return d;
}

+ (instancetype)favoriteWithDictionary:(NSDictionary *)dictionary
{
	if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;

	SPPostgresFavorite *f = [[[SPPostgresFavorite alloc] init] autorelease];
	NSString * (^str)(NSString *) = ^NSString *(NSString *key) {
		id v = [dictionary objectForKey:key];
		return [v isKindOfClass:[NSString class]] ? v : nil;
	};
	NSNumber * (^num)(NSString *) = ^NSNumber *(NSString *key) {
		id v = [dictionary objectForKey:key];
		return [v isKindOfClass:[NSNumber class]] ? v : nil;
	};

	if ([str(@"id") length]) f.favoriteID = str(@"id");
	f.name = str(@"name");
	if (num(@"colorIndex")) f.colorIndex = [num(@"colorIndex") integerValue];
	if (num(@"type")) f.type = (SPPostgresConnectionType)[num(@"type") integerValue];
	f.host = str(@"host");
	if (num(@"port")) f.port = [num(@"port") unsignedIntegerValue];
	f.user = str(@"user");
	f.database = str(@"database");
	f.socketPath = str(@"socketPath");
	f.useSSL = [num(@"useSSL") boolValue];
	f.sslCACertPath = str(@"sslCACertPath");
	f.sslCertPath = str(@"sslCertPath");
	f.sslKeyPath = str(@"sslKeyPath");
	f.sshHost = str(@"sshHost");
	f.sshUser = str(@"sshUser");
	f.sshPort = [num(@"sshPort") unsignedIntegerValue];
	f.sshKeyPath = str(@"sshKeyPath");
	return f;
}

- (NSString *)keychainName
{
	return [NSString stringWithFormat:@"Sequel Pro (PostgreSQL) : %@ (%@)", name ? name : @"", favoriteID];
}

- (NSString *)keychainAccount
{
	return [NSString stringWithFormat:@"%@@%@/%@", user ? user : @"", host ? host : @"", database ? database : @""];
}

- (NSString *)sshKeychainName
{
	return [NSString stringWithFormat:@"Sequel Pro (PostgreSQL) SSHTunnel : %@ (%@)", name ? name : @"", favoriteID];
}

- (NSString *)sshKeychainAccount
{
	return [NSString stringWithFormat:@"%@@%@", sshUser ? sshUser : @"", sshHost ? sshHost : @""];
}

@end
