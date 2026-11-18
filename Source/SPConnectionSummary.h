//
//  SPConnectionSummary.h
//  Sequel Plus
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * How many connections a server has open against its limit, as both databases' Server Processes lists show it:
 * "12 of 151 connections" (MySQL), "5 of 100 connections (3 reserved for superusers)" (PostgreSQL).
 */
__attribute__((visibility("default")))
@interface SPConnectionSummary : NSObject

@property (readonly) NSUInteger current;   // open client connections
@property (readonly) NSUInteger max;       // the server's max_connections
@property (readonly) NSUInteger reserved;  // of max, kept for superusers (PostgreSQL's superuser_reserved_connections)

+ (instancetype)summaryWithCurrent:(NSUInteger)current max:(NSUInteger)max reserved:(NSUInteger)reserved;

/// Threads_connected against max_connections; nil when either can't be read. Runs queries on connection (an
/// SPMySQLConnection), so call it where the connection may be used.
+ (nullable instancetype)summaryForMySQLConnection:(id)connection;

- (NSString *)text;
/// YES once ordinary users can't connect any more (every slot but the reserved ones is in use).
- (BOOL)isFull;

@end

NS_ASSUME_NONNULL_END
