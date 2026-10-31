#import <Foundation/Foundation.h>

/**
 * Reads a file's bytes, decompressing it transparently when it is gzip or bzip2 (told by its first bytes: 1f 8b,
 * "BZh"; several concatenated bzip2 streams are read in turn). Every read is checked: a damaged compressed file, or
 * one that ends before its stream does, is a failure, never a silent end. Shared by SPPostgresDumpReader (SQL dumps)
 * and SPPostgresCSV (CSV imports), which word the errors with their own line or row numbers. Not thread-safe: use it
 * from one thread at a time.
 */
__attribute__((visibility("default")))
@interface SPPostgresCompressedFileReader : NSObject

/// Opens path; nil with an error (SPPostgresErrorDomain, SPPostgresErrorQueryFailed: "The file “<name>” can't be
/// opened.") when it can't be.
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;

/**
 * Reads up to count (decompressed) bytes into bytes, setting *read (0 at the end of the file). NO when the file can't
 * be read (*damaged NO; errno tells why) or a compressed file is damaged or truncated (*damaged YES).
 */
- (BOOL)readBytes:(void *)bytes count:(NSUInteger)count read:(NSUInteger *)read damaged:(BOOL *)damaged;

/// YES for a gzip or bzip2 file.
@property (readonly, getter=isCompressed) BOOL compressed;

/// Bytes read from the file so far, and its size (both compressed for a compressed file), for progress.
@property (readonly) unsigned long long bytesRead;
@property (readonly) unsigned long long fileSize;

@end
