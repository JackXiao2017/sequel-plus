#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SPPostgresConnectionType) {
	SPPostgresTCPIPConnection = 0,
	SPPostgresSocketConnection = 1,
	SPPostgresSSHConnection = 2
};

/**
 * A saved PostgreSQL connection. Passwords are never stored here; they live in the
 * Keychain under names starting with "Sequel Pro (PostgreSQL)".
 */
__attribute__((visibility("default")))
@interface SPPostgresFavorite : NSObject <NSCopying>

@property (nonatomic, copy) NSString *favoriteID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSInteger colorIndex;
@property (nonatomic, assign) SPPostgresConnectionType type;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, copy) NSString *user;
@property (nonatomic, copy) NSString *database;
@property (nonatomic, copy) NSString *socketPath;
@property (nonatomic, assign) BOOL useSSL;
@property (nonatomic, copy) NSString *sslCACertPath;
@property (nonatomic, copy) NSString *sslCertPath;
@property (nonatomic, copy) NSString *sslKeyPath;
@property (nonatomic, copy) NSString *sshHost;
@property (nonatomic, copy) NSString *sshUser;
@property (nonatomic, assign) NSUInteger sshPort;
@property (nonatomic, copy) NSString *sshKeyPath;

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)favoriteWithDictionary:(NSDictionary *)dictionary;

- (NSString *)keychainName;
- (NSString *)keychainAccount;
- (NSString *)sshKeychainName;
- (NSString *)sshKeychainAccount;

@end
