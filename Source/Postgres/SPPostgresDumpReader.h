#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SPPostgresDumpItemKind) {
	/// A SQL statement (sql holds it without its semicolon).
	SPPostgresDumpItemStatement = 0,
	/// A COPY … FROM stdin statement; its data follows, read with -[SPPostgresDumpReader nextCopyData:].
	SPPostgresDumpItemCopy = 1,
	/// A psql meta-command line between statements (sql holds the line, starting with its backslash).
	SPPostgresDumpItemMetaCommand = 2
};

/// One item of a SQL dump: a statement, a COPY … FROM stdin, or a psql meta-command.
__attribute__((visibility("default")))
@interface SPPostgresDumpItem : NSObject
{
	SPPostgresDumpItemKind kind;
	NSString *sql;
	NSUInteger line;
}

- (instancetype)initWithKind:(SPPostgresDumpItemKind)kind sql:(NSString *)sql line:(NSUInteger)line;

@property (readonly) SPPostgresDumpItemKind kind;
/// The statement (trimmed, without its semicolon; leading comments left out), or the meta-command line.
@property (readonly) NSString *sql;
/// The 1-based line where it starts (its first character that isn't whitespace or a comment).
@property (readonly) NSUInteger line;

@end

@class SPFileHandle;

/**
 * Reads a SQL dump (plain pg_dump output, or our own) item by item, in chunks, so files of any size can be run:
 * statements are split with SPPostgresStatementSplitter's lexer, a statement or dollar-quoted body spanning chunks is
 * read whole, COPY … FROM stdin data is handed out in chunks through -nextCopyData:, and psql meta-commands between
 * statements are items of their own. The file is read through SPFileHandle (gzip and bzip2 transparently), decoded
 * as UTF-8, a leading BOM skipped. Not thread-safe: use it from one thread at a time.
 */
__attribute__((visibility("default")))
@interface SPPostgresDumpReader : NSObject
{
	SPFileHandle *fileHandle;
	NSUInteger chunkSize;
	unsigned long long fileSize;

	unichar *characters;     // decoded text not yet handed out, from position to length
	NSUInteger capacity;
	NSUInteger length;
	NSUInteger position;
	NSUInteger currentLine;  // the line at position (1-based)

	NSMutableData *pendingBytes; // the end of the last chunk read: an incomplete UTF-8 sequence
	BOOL endOfFile;
	BOOL atStart;            // nothing decoded yet (a BOM is still to be skipped)

	BOOL inCopy;             // the last item was a Copy whose data hasn't been read to its \. line
	NSUInteger copyLine;
	NSError *readError;
}

/// Opens path for reading; nil with an error (SPPostgresErrorDomain) when it can't be opened.
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;

/// How many bytes are read from the file at a time. Default 1 MiB.
@property (nonatomic) NSUInteger chunkSize;

/**
 * The next item, or nil at the end of the file (error untouched) or on an error (set). After a Copy item, call
 * -nextCopyData: until it returns nil before asking for the next item; an unread COPY's data is skipped.
 */
- (SPPostgresDumpItem *)nextItem:(NSError **)error;

/**
 * Valid only after a Copy item: the next chunk of its data lines (UTF-8, whole lines, each ending in \n), up to but
 * not including the \. line. nil once the \. line is reached (the reader then continues after it), or nil with an
 * error, e.g. when the file ends before the \. line.
 */
- (NSData *)nextCopyData:(NSError **)error;

/// Bytes read from the file so far, and its size (both compressed for a compressed file), for progress.
@property (readonly) unsigned long long bytesRead;
@property (readonly) unsigned long long fileSize;

@end
