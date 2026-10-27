#import "SPPostgresTestServers.h"
#import <XCTest/XCTest.h>
#import <PostgresKit/PostgresKit.h>

@implementation SPPostgresTestServers

+ (NSArray<NSNumber *> *)ports
{
	return @[@55412, @55418];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port
{
	return [self connectedConnectionOnPort:port database:@"pgkit_test"];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database
{
	return [self connectedConnectionOnPort:port database:database delegate:nil];
}

+ (PGPostgresConnection *)connectedConnectionOnPort:(NSUInteger)port database:(NSString *)database
										   delegate:(NSObject<PGPostgresConnectionDelegate> *)delegate
{
	PGPostgresConnection *connection = delegate ? [[PGPostgresConnection alloc] initWithDelegate:delegate] : [[PGPostgresConnection alloc] init];
	connection.host = @"127.0.0.1";
	connection.port = port;
	connection.user = @"pgkit_test";
	connection.password = @"pgkit";
	connection.database = database;

	// -connect is asynchronous: wait for success or failure, up to 10 seconds.
	[connection connect];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
	while (!connection.isConnected && !connection.connectionError && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}

	if (!connection.isConnected) {
		XCTFail(@"Could not connect to test server on port %lu: %@", (unsigned long)port,
				connection.connectionError ?: @"timed out after 10 s");
		return nil;
	}
	return connection;
}

#pragma mark - Fixtures

// Fixtures are read from PostgresTests/Fixtures/ next to this source file (located via __FILE__), not bundled
// as test resources.
+ (void)loadFixtureNamed:(NSString *)name onPort:(NSUInteger)port
{
	NSString *path = [[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
					   stringByAppendingPathComponent:@"Fixtures"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"sql"]];
	NSError *readError = nil;
	NSString *sql = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
	if (!sql) { XCTFail(@"Cannot read fixture: %@", readError); return; }

	PGPostgresConnection *connection = [self connectedConnectionOnPort:port];
	if (!connection) return;

	for (NSString *chunk in [sql componentsSeparatedByString:@"\n-- @@"]) {
		NSMutableArray *lines = [[chunk componentsSeparatedByString:@"\n"] mutableCopy];
		NSString *directive = [lines.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([chunk hasPrefix:@"-- @@"]) { // very first chunk starts with the marker itself
			directive = [[chunk substringFromIndex:5] componentsSeparatedByString:@"\n"].firstObject;
		}
		[lines removeObjectAtIndex:0];
		NSString *statement = [[lines componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		directive = [directive stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

		if ([directive hasPrefix:@"db "]) {
			[connection disconnect];
			connection = [self connectedConnectionOnPort:port database:[directive substringFromIndex:3]];
			if (!connection) return;
		} else if ([directive hasPrefix:@"createdb "]) {
			NSString *dbName = [directive substringFromIndex:9];
			PGPostgresResult *exists = [connection execute:@"SELECT 1 FROM pg_database WHERE datname = $1::text" values:@[dbName]];
			if (exists.numberOfRows == 0) {
				// Name comes from the fixture file, quoted as an identifier.
				NSString *quoted = [dbName stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
				NSString *create = [NSString stringWithFormat:@"CREATE DATABASE \"%@\"", quoted];
				XCTAssertNotNil([connection execute:create], @"CREATE DATABASE: %@", connection.lastError.errorPrimaryMessage);
			}
		}
		if (statement.length) {
			XCTAssertNotNil([connection execute:statement], @"%@ failed: %@", statement, connection.lastError.errorPrimaryMessage);
		}
	}
	[connection disconnect];
}

@end
