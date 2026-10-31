#import <Foundation/Foundation.h>

@class PGPostgresConnection;

/**
 * The CSV dialect, as COPY … WITH (FORMAT csv) takes it. delimiter, quote and escape are each one ASCII character
 * other than CR and LF, the delimiter differing from the quote; nullString holds neither CR, LF, the delimiter nor
 * the quote. Settings outside these rules fail with SPPostgresErrorInvalidSettings.
 */
__attribute__((visibility("default")))
@interface SPPostgresCSVOptions : NSObject <NSCopying>
{
	NSString *delimiter;
	NSString *quote;
	NSString *escape;
	BOOL header;
	NSString *nullString;
}

/// Default @",".
@property (copy) NSString *delimiter;
/// Default @"\"".
@property (copy) NSString *quote;
/// Default @"\"" (a quote inside a quoted field is doubled); @"\\" makes it \".
@property (copy) NSString *escape;
/// The first row holds the column names. Default YES.
@property BOOL header;
/// How NULL is written: an unquoted field equal to it is NULL, a quoted one is text. Default @"".
@property (copy) NSString *nullString;

@end

/**
 * CSV export and import. Synchronous, on the caller's thread (a background one in the app), on a connection of the
 * job's own. Files are read and written in chunks, never whole. Errors are in SPPostgresErrorDomain:
 * SPPostgresErrorInvalidSettings for options or a mapping that can't be used, SPPostgresErrorCancelled for a cancel,
 * SPPostgresErrorQueryFailed otherwise (the server's message with its DETAIL and CONTEXT, a file that can't be read
 * or written, or CSV that can't be parsed).
 *
 * CSV is read as UTF-8 (a leading BOM skipped) by the rules of PostgreSQL's COPY FROM (FORMAT csv): a field is
 * quoted when it starts with the quote; inside quotes, delimiters and line breaks are data, and the escape followed
 * by the quote or the escape stands for that character; text after a closing quote continues the field; an unquoted
 * field equal to nullString is NULL; rows end with LF, CR LF or CR; an empty line is one empty field. gzip and bzip2
 * files are read transparently (SPPostgresCompressedFileReader); a damaged or truncated one fails with "The file is
 * damaged or truncated (near row <n>).". Reading errors name data rows, counted from 1 after the header (the header
 * itself is "the header row"), as the server's "COPY t, line N" does: "Row <n> has a quoted field that isn't
 * closed.", "Row <n> isn't valid UTF-8 text." and the import's short-row message name the same n for the same row.
 */
__attribute__((visibility("default")))
@interface SPPostgresCSV : NSObject

/**
 * Writes the table (or view) with COPY (SELECT * FROM "schema"."table") TO STDOUT WITH (FORMAT csv, DELIMITER,
 * QUOTE, ESCAPE, HEADER, NULL), the options as literals. shouldCancel (may be nil) is asked before every chunk;
 * YES cancels the COPY. On failure or cancel the file is deleted. A transaction open on the connection is left to
 * the caller (a cancelled COPY aborts it); outside one, the connection is left idle.
 */
+ (BOOL)exportTable:(NSString *)table schema:(NSString *)schema connection:(PGPostgresConnection *)connection
			options:(SPPostgresCSVOptions *)options toPath:(NSString *)path cancel:(BOOL (^)(void))shouldCancel
			  error:(NSError **)error;

/**
 * Writes a query result held by the client: rows is an array of arrays of NSString or NSNull (anything else is
 * written as its description). The output is byte for byte what the server's CSV COPY writes for the same values:
 * a field is quoted when it holds the delimiter, the quote, CR or LF, equals nullString while not NULL, or is \. as
 * the only column; inside quotes, the quote and the escape are each preceded by the escape (doubled when they are
 * the same). The header row follows the same rules. On failure the file is deleted.
 */
+ (BOOL)exportRows:(NSArray *)rows columnNames:(NSArray *)names options:(SPPostgresCSVOptions *)options
			toPath:(NSString *)path error:(NSError **)error;

/// The first limit data rows (after the header when options.header is set), each an array of NSString or NSNull
/// with as many fields as the row has. nil with an error when the file can't be read or parsed.
+ (NSArray *)previewRowsAtPath:(NSString *)path options:(SPPostgresCSVOptions *)options limit:(NSUInteger)limit
						 error:(NSError **)error;

/// The column names: the first row's fields when options.header is set (an empty or NULL name becomes
/// "Column <n>"), otherwise "Column 1"… as many as the widest of the first 10 rows has. Empty for an empty file.
+ (NSArray *)headerAtPath:(NSString *)path options:(SPPostgresCSVOptions *)options error:(NSError **)error;

/**
 * Imports the file into "schema"."table". mapping holds one entry per column of the table (dropped ones left out)
 * in attnum order: an NSNumber, the 0-based CSV field that fills it, or NSNull when the column isn't imported (it
 * takes its default). A generated column must be NSNull, and at least one column must be mapped.
 *
 * The rows (after the header when options.header is set) are sent as COPY "schema"."table" (mapped columns) FROM
 * STDIN in text format, between BEGIN and COMMIT, so line N of the server's "COPY t, line N" is data row N. A row
 * with too few fields fails with "Row <n> has <k> fields; column “<c>” needs field <i>." (n counting data rows from
 * 1, i from 1). progress (may be nil) is called after each chunk sent; NO cancels. On any error or a cancel the
 * transaction is rolled back, so the table is unchanged. The connection must have no transaction open.
 */
+ (BOOL)importPath:(NSString *)path options:(SPPostgresCSVOptions *)options intoTable:(NSString *)table
			schema:(NSString *)schema columnMapping:(NSArray *)mapping connection:(PGPostgresConnection *)connection
		  progress:(BOOL (^)(unsigned long long bytesRead, unsigned long long fileSize))progress
			 error:(NSError **)error;

@end
