#import "SPPostgresCSV.h"
#import "SPPostgresTableData.h"
#import "SPPostgresErrors.h"
#import "SPPostgresCompressedFileReader.h"
#import <PostgresKit/PostgresKit.h>
#include <sys/stat.h>

/// Bytes read from a CSV file at a time, and the size of the COPY data chunks sent to the server.
static const size_t SPCSVReadSize = 64 * 1024;
static const NSUInteger SPCSVSendSize = 256 * 1024;

#pragma mark - Options

@implementation SPPostgresCSVOptions

@synthesize delimiter;
@synthesize quote;
@synthesize escape;
@synthesize header;
@synthesize nullString;

- (instancetype)init
{
	if ((self = [super init])) {
		delimiter = [@"," copy];
		quote = [@"\"" copy];
		escape = [@"\"" copy];
		header = YES;
		nullString = [@"" copy];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	SPPostgresCSVOptions *copy = [[[self class] allocWithZone:zone] init];
	copy.delimiter = delimiter;
	copy.quote = quote;
	copy.escape = escape;
	copy.header = header;
	copy.nullString = nullString;
	return copy;
}

- (void)dealloc
{
	[delimiter release];
	[quote release];
	[escape release];
	[nullString release];
	[super dealloc];
}

@end

#pragma mark - Shared

static NSError *SPCSVError(NSInteger code, NSString *message)
{
	return SPPostgresMakeError(code, message, nil);
}

static NSError *SPCSVCancelledError(BOOL import)
{
	return SPCSVError(SPPostgresErrorCancelled, import ? NSLocalizedString(@"The import was cancelled.", @"Postgres import: cancelled")
										   : NSLocalizedString(@"The export was cancelled.", @"Postgres export: cancelled"));
}

/// The option as its one ASCII byte, or -1 when it isn't a single ASCII character other than CR and LF.
static int SPCSVByte(NSString *option)
{
	if ([option length] != 1) return -1;
	unichar c = [option characterAtIndex:0];
	if (c == 0 || c >= 0x80 || c == '\r' || c == '\n') return -1;
	return (int)c;
}

/// The options' bytes, or NO with an SPPostgresErrorInvalidSettings error (the same rules COPY applies).
static BOOL SPCSVCheckOptions(SPPostgresCSVOptions *options, unsigned char *delimiter, unsigned char *quote, unsigned char *escape, NSError **error)
{
	NSString *message = nil;
	int d = SPCSVByte([options delimiter]), q = SPCSVByte([options quote]), e = SPCSVByte([options escape]);
	NSString *nullString = [options nullString] ?: @"";
	if (!options) message = NSLocalizedString(@"No CSV options were given.", @"Postgres CSV: no options");
	else if (d < 0) message = NSLocalizedString(@"The delimiter must be one ASCII character other than a line break.", @"Postgres CSV: bad delimiter");
	else if (q < 0) message = NSLocalizedString(@"The quote must be one ASCII character other than a line break.", @"Postgres CSV: bad quote");
	else if (e < 0) message = NSLocalizedString(@"The escape must be one ASCII character other than a line break.", @"Postgres CSV: bad escape");
	else if (d == q) message = NSLocalizedString(@"The delimiter and the quote must differ.", @"Postgres CSV: delimiter is the quote");
	else if ([nullString rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location != NSNotFound)
		message = NSLocalizedString(@"The NULL text can't hold a line break.", @"Postgres CSV: line break in NULL");
	else if ([nullString rangeOfString:[options delimiter]].location != NSNotFound)
		message = NSLocalizedString(@"The NULL text can't hold the delimiter.", @"Postgres CSV: delimiter in NULL");
	else if ([nullString rangeOfString:[options quote]].location != NSNotFound)
		message = NSLocalizedString(@"The NULL text can't hold the quote.", @"Postgres CSV: quote in NULL");
	if (message) {
		if (error) *error = SPCSVError(SPPostgresErrorInvalidSettings, message);
		return NO;
	}
	if (delimiter) *delimiter = (unsigned char)d;
	if (quote) *quote = (unsigned char)q;
	if (escape) *escape = (unsigned char)e;
	return YES;
}

/// "schema"."table"
static NSString *SPCSVQualified(NSString *schema, NSString *table)
{
	return [NSString stringWithFormat:@"%@.%@", SPPostgresQuoteIdentifier(schema ?: @""), SPPostgresQuoteIdentifier(table ?: @"")];
}

static NSError *SPCSVFileError(NSString *format, NSString *path)
{
	return SPCSVError(SPPostgresErrorQueryFailed, [NSString stringWithFormat:format, [path lastPathComponent], strerror(errno ?: EIO)]);
}

#pragma mark - Writing

/// A file written with fwrite, every write checked; deleted unless finished.
@interface SPPostgresCSVOutput : NSObject
{
	NSString *path;
	FILE *file;
	NSError *error;
}
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;
- (BOOL)write:(const void *)bytes length:(NSUInteger)length;
/// Closes the file (checking the close); NO with -error set on failure.
- (BOOL)finish;
/// Closes and deletes the file.
- (void)discard;
@property (readonly) NSError *error;
@end

@implementation SPPostgresCSVOutput

@synthesize error;

- (instancetype)initWithPath:(NSString *)aPath error:(NSError **)outError
{
	if ((self = [super init])) {
		path = [aPath copy];
		file = fopen([path fileSystemRepresentation], "wb");
		if (!file) {
			if (outError) *outError = SPCSVFileError(NSLocalizedString(@"“%@” can't be written: %s.", @"Postgres export: the file can't be created"), path);
			[self release];
			return nil;
		}
	}
	return self;
}

- (void)dealloc
{
	if (file) [self discard];
	[path release];
	[error release];
	[super dealloc];
}

- (BOOL)write:(const void *)bytes length:(NSUInteger)length
{
	if (error || !file) return NO;
	if (length && fwrite(bytes, 1, length, file) != length) {
		error = [SPCSVFileError(NSLocalizedString(@"“%@” can't be written: %s.", @"Postgres export: a write failed"), path) retain];
		return NO;
	}
	return YES;
}

- (BOOL)finish
{
	if (!file) return NO;
	int closed = fclose(file);
	file = NULL;
	if (closed != 0 && !error) error = [SPCSVFileError(NSLocalizedString(@"“%@” can't be written: %s.", @"Postgres export: a write failed"), path) retain];
	if (error) {
		unlink([path fileSystemRepresentation]);
		return NO;
	}
	return YES;
}

- (void)discard
{
	if (file) {
		fclose(file);
		file = NULL;
	}
	unlink([path fileSystemRepresentation]);
}

@end

/// Appends one field as PostgreSQL's CSV COPY writes it (CopyAttributeOutCSV).
static void SPCSVAppendField(NSMutableData *line, id value, NSData *nullBytes, unsigned char delimiter, unsigned char quote, unsigned char escape, BOOL singleColumn)
{
	if (!value || value == [NSNull null]) {
		[line appendData:nullBytes];
		return;
	}
	NSString *string = [value isKindOfClass:[NSString class]] ? value : [value description];
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
	const unsigned char *bytes = [data bytes];
	NSUInteger length = [data length];

	BOOL quoted = [data isEqualToData:nullBytes];
	if (!quoted && singleColumn && length == 2 && bytes[0] == '\\' && bytes[1] == '.') quoted = YES;
	for (NSUInteger i = 0; !quoted && i < length; i++) {
		unsigned char c = bytes[i];
		if (c == delimiter || c == quote || c == '\n' || c == '\r') quoted = YES;
	}
	if (!quoted) {
		[line appendData:data];
		return;
	}
	[line appendBytes:&quote length:1];
	NSUInteger start = 0;
	for (NSUInteger i = 0; i < length; i++) {
		if (bytes[i] == quote || bytes[i] == escape) {
			[line appendBytes:bytes + start length:i - start];
			[line appendBytes:&escape length:1];
			start = i; // the character itself goes with the next run
		}
	}
	[line appendBytes:bytes + start length:length - start];
	[line appendBytes:&quote length:1];
}

static void SPCSVAppendRow(NSMutableData *line, NSArray *fields, NSData *nullBytes, unsigned char delimiter, unsigned char quote, unsigned char escape, BOOL singleColumn)
{
	NSUInteger index = 0;
	for (id value in fields) {
		if (index++) [line appendBytes:&delimiter length:1];
		SPCSVAppendField(line, value, nullBytes, delimiter, quote, escape, singleColumn);
	}
	[line appendBytes:"\n" length:1];
}

#pragma mark - Reading

typedef NS_ENUM(NSInteger, SPCSVState) {
	SPCSVUnquoted,          // outside quotes (also at the start of a field)
	SPCSVQuoted,            // inside quotes
	SPCSVQuotedSawQuote,    // inside quotes, just after a quote when the escape is the quote: doubled, or the end?
	SPCSVQuotedSawEscape    // inside quotes, just after an escape that isn't the quote
};

/// "Row <n>", or "The header row" for row 0 (the header), as the subject of a reading error's message.
static NSString *SPCSVRowMessage(NSUInteger dataRow, NSString *rowFormat, NSString *headerMessage)
{
	if (!dataRow) return headerMessage;
	return [NSString stringWithFormat:rowFormat, (unsigned long)dataRow];
}

/// Whether bytes[0..<length] is valid UTF-8 (no overlongs, surrogates or values past U+10FFFF).
static BOOL SPCSVIsValidUTF8(const unsigned char *bytes, NSUInteger length)
{
	NSUInteger i = 0;
	while (i < length) {
		unsigned char c = bytes[i];
		if (c < 0x80) { i++; continue; }
		NSUInteger extra;
		unsigned char low = 0x80, high = 0xBF;
		if (c >= 0xC2 && c <= 0xDF) extra = 1;
		else if (c == 0xE0) { extra = 2; low = 0xA0; }
		else if (c == 0xED) { extra = 2; high = 0x9F; }
		else if (c >= 0xE1 && c <= 0xEF) extra = 2;
		else if (c == 0xF0) { extra = 3; low = 0x90; }
		else if (c >= 0xF1 && c <= 0xF3) extra = 3;
		else if (c == 0xF4) { extra = 3; high = 0x8F; }
		else return NO;
		if (extra >= length - i) return NO; // cut short
		for (NSUInteger k = 1; k <= extra; k++) {
			unsigned char next = bytes[i + k];
			if (k == 1 ? (next < low || next > high) : (next < 0x80 || next > 0xBF)) return NO;
		}
		i += extra + 1;
	}
	return YES;
}

/**
 * Reads a CSV file (plain, gzip or bzip2: SPPostgresCompressedFileReader) in chunks by COPY FROM (FORMAT csv)'s
 * rules, row by row. A row is an array of NSData (the field's bytes, UTF-8 not checked) or NSNull. Its errors name
 * data rows, counted from 1 after the header (the header itself is "the header row"), as the server's "COPY t,
 * line N" and the import's short-row message do.
 */
@interface SPPostgresCSVReader : NSObject
{
	SPPostgresCompressedFileReader *source;
	NSString *path;
	NSUInteger headerRows;
	unsigned char delimiter, quote, escape;
	NSData *nullBytes;

	SPCSVState state;
	NSMutableData *field;
	BOOL fieldQuoted;
	NSMutableArray *row;
	BOOL rowStarted;
	BOOL skipLineFeed;
	BOOL atStart;
	BOOL atEnd;
	NSMutableArray *ready;
	NSUInteger rowsParsed;
	NSUInteger rowsReturned;
	NSError *readError;
}
- (instancetype)initWithPath:(NSString *)path options:(SPPostgresCSVOptions *)options error:(NSError **)error;
/// The next row, or nil at the end (error untouched) or on an error (set).
- (NSArray *)nextRow:(NSError **)error;
/// The data row number of the last row returned: 0 for the header, then 1, 2… (the header not counted).
@property (readonly) NSUInteger lastDataRow;
@property (readonly) unsigned long long bytesRead;
@property (readonly) unsigned long long fileSize;
@end

@implementation SPPostgresCSVReader

- (instancetype)initWithPath:(NSString *)aPath options:(SPPostgresCSVOptions *)options error:(NSError **)error
{
	if ((self = [super init])) {
		if (!SPCSVCheckOptions(options, &delimiter, &quote, &escape, error)) {
			[self release];
			return nil;
		}
		path = [aPath copy];
		source = [[SPPostgresCompressedFileReader alloc] initWithPath:path error:error];
		if (!source) {
			[self release];
			return nil;
		}
		headerRows = [options header] ? 1 : 0;
		nullBytes = [[[options nullString] ?: @"" dataUsingEncoding:NSUTF8StringEncoding] retain];
		field = [[NSMutableData alloc] init];
		row = [[NSMutableArray alloc] init];
		ready = [[NSMutableArray alloc] init];
		state = SPCSVUnquoted;
		atStart = YES;
	}
	return self;
}

- (void)dealloc
{
	[source release];
	[path release];
	[nullBytes release];
	[field release];
	[row release];
	[ready release];
	[readError release];
	[super dealloc];
}

- (NSUInteger)lastDataRow
{
	return rowsReturned > headerRows ? rowsReturned - headerRows : 0;
}

- (unsigned long long)bytesRead
{
	return [source bytesRead];
}

- (unsigned long long)fileSize
{
	return [source fileSize];
}

/// The data row number of the row being parsed (0: the header).
- (NSUInteger)_parsingDataRow
{
	return rowsParsed + 1 > headerRows ? rowsParsed + 1 - headerRows : 0;
}

- (void)_endField
{
	id value;
	if (!fieldQuoted && [field isEqualToData:nullBytes]) value = [NSNull null];
	else value = [NSData dataWithBytes:[field bytes] length:[field length]];
	[row addObject:value];
	[field setLength:0];
	fieldQuoted = NO;
}

- (void)_endRow
{
	[self _endField];
	[ready addObject:[NSArray arrayWithArray:row]];
	[row removeAllObjects];
	rowStarted = NO;
	rowsParsed++;
}

- (void)_parseBytes:(const unsigned char *)bytes length:(size_t)length
{
	size_t i = 0;
	while (i < length) {
		unsigned char c = bytes[i];
		switch (state) {
			case SPCSVUnquoted: {
				if (skipLineFeed) {
					skipLineFeed = NO;
					if (c == '\n') { i++; continue; }
				}
				if (c == delimiter) { rowStarted = YES; [self _endField]; i++; }
				else if (c == '\n' || c == '\r') {
					[self _endRow];
					skipLineFeed = (c == '\r');
					i++;
				}
				else if (c == quote) { rowStarted = YES; fieldQuoted = YES; state = SPCSVQuoted; i++; }
				else {
					rowStarted = YES;
					size_t run = i + 1;
					while (run < length && bytes[run] != delimiter && bytes[run] != quote && bytes[run] != '\n' && bytes[run] != '\r') run++;
					[field appendBytes:bytes + i length:run - i];
					i = run;
				}
				break;
			}
			case SPCSVQuoted: {
				if (c == quote) { state = (escape == quote) ? SPCSVQuotedSawQuote : SPCSVUnquoted; i++; }
				else if (c == escape) { state = SPCSVQuotedSawEscape; i++; }
				else {
					size_t run = i + 1;
					while (run < length && bytes[run] != quote && bytes[run] != escape) run++;
					[field appendBytes:bytes + i length:run - i];
					i = run;
				}
				break;
			}
			case SPCSVQuotedSawQuote: {
				if (c == quote) { [field appendBytes:&quote length:1]; state = SPCSVQuoted; i++; }
				else state = SPCSVUnquoted; // the field's closing quote: c is read again outside quotes
				break;
			}
			case SPCSVQuotedSawEscape: {
				// Only the escape before the quote or the escape is special
				if (c != quote && c != escape) [field appendBytes:&escape length:1];
				[field appendBytes:&c length:1];
				state = SPCSVQuoted;
				i++;
				break;
			}
		}
	}
}

/// Reads and parses the next chunk, setting *got to its length (0 at the end of the file). NO on a read error.
- (BOOL)_readChunk:(NSUInteger *)got
{
	*got = 0;
	unsigned char *buffer = malloc(SPCSVReadSize);
	if (!buffer) {
		readError = [SPCSVError(SPPostgresErrorQueryFailed, NSLocalizedString(@"Out of memory reading the file.", @"Postgres import: out of memory")) retain];
		return NO;
	}
	NSUInteger length = 0;
	BOOL damaged = NO;
	if (![source readBytes:buffer count:SPCSVReadSize read:&length damaged:&damaged]) {
		free(buffer);
		if (damaged) {
			NSString *message = SPCSVRowMessage([self _parsingDataRow],
				NSLocalizedString(@"The file is damaged or truncated (near row %lu).", @"Postgres CSV: damaged or truncated compressed file (data row)"),
				NSLocalizedString(@"The file is damaged or truncated (near the header row).", @"Postgres CSV: damaged or truncated compressed file (header)"));
			readError = [SPCSVError(SPPostgresErrorQueryFailed, message) retain];
		}
		else readError = [SPCSVFileError(NSLocalizedString(@"“%@” can't be read: %s.", @"Postgres import: a read failed"), path) retain];
		return NO;
	}
	*got = length;
	const unsigned char *bytes = buffer;
	if (atStart && length) {
		atStart = NO;
		if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
			bytes += 3;
			length -= 3;
		}
	}
	[self _parseBytes:bytes length:length];
	free(buffer);
	return YES;
}

/// The end of the file: the last row (without a line break) ends, or an open quote is an error.
- (BOOL)_finish
{
	atEnd = YES;
	if (state == SPCSVQuotedSawQuote) state = SPCSVUnquoted;
	if (state != SPCSVUnquoted) {
		NSString *message = SPCSVRowMessage([self _parsingDataRow],
			NSLocalizedString(@"Row %lu has a quoted field that isn't closed.", @"Postgres CSV: unterminated quoted field"),
			NSLocalizedString(@"The header row has a quoted field that isn't closed.", @"Postgres CSV: unterminated quoted field in the header"));
		readError = [SPCSVError(SPPostgresErrorQueryFailed, message) retain];
		return NO;
	}
	if (rowStarted || [row count] || [field length]) [self _endRow];
	return YES;
}

- (NSArray *)nextRow:(NSError **)error
{
	while (![ready count] && !atEnd && !readError) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSUInteger got = 0;
		if ([self _readChunk:&got] && !got) [self _finish];
		[pool drain];
	}
	if ([ready count]) {
		NSArray *next = [[[ready objectAtIndex:0] retain] autorelease];
		[ready removeObjectAtIndex:0];
		rowsReturned++;
		return next;
	}
	if (readError && error) *error = [[readError retain] autorelease];
	return nil;
}

@end

/// The row's fields as NSString / NSNull, or nil with an error naming dataRow (0: the header) when one isn't UTF-8.
static NSArray *SPCSVStrings(NSArray *fields, NSUInteger dataRow, NSError **error)
{
	NSMutableArray *strings = [NSMutableArray arrayWithCapacity:[fields count]];
	for (id value in fields) {
		if (value == [NSNull null]) {
			[strings addObject:value];
			continue;
		}
		NSString *string = [[[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] autorelease];
		if (!string) {
			if (error) *error = SPCSVError(SPPostgresErrorQueryFailed, SPCSVRowMessage(dataRow,
				NSLocalizedString(@"Row %lu isn't valid UTF-8 text.", @"Postgres CSV: row not UTF-8"),
				NSLocalizedString(@"The header row isn't valid UTF-8 text.", @"Postgres CSV: header not UTF-8")));
			return nil;
		}
		[strings addObject:string];
	}
	return strings;
}

/// Appends the field in COPY's text format.
static void SPCSVAppendCopyText(NSMutableData *out, id value)
{
	if (value == [NSNull null]) {
		[out appendBytes:"\\N" length:2];
		return;
	}
	const unsigned char *bytes = [value bytes];
	NSUInteger length = [value length], start = 0;
	for (NSUInteger i = 0; i < length; i++) {
		const char *replacement = NULL;
		switch (bytes[i]) {
			case '\\': replacement = "\\\\"; break;
			case '\t': replacement = "\\t"; break;
			case '\n': replacement = "\\n"; break;
			case '\r': replacement = "\\r"; break;
			default: continue;
		}
		[out appendBytes:bytes + start length:i - start];
		[out appendBytes:replacement length:2];
		start = i + 1;
	}
	[out appendBytes:bytes + start length:length - start];
}

#pragma mark -

@implementation SPPostgresCSV

#pragma mark Export

+ (BOOL)exportTable:(NSString *)table schema:(NSString *)schema connection:(PGPostgresConnection *)connection
			options:(SPPostgresCSVOptions *)options toPath:(NSString *)path cancel:(BOOL (^)(void))shouldCancel
			  error:(NSError **)error
{
	if (!SPCSVCheckOptions(options, NULL, NULL, NULL, error)) return NO;

	NSString *sql = [NSString stringWithFormat:@"COPY (SELECT * FROM %@) TO STDOUT WITH (FORMAT csv, DELIMITER %@, QUOTE %@, ESCAPE %@, HEADER %@, NULL %@)",
					 SPCSVQualified(schema, table), SPPostgresQuoteLiteral([options delimiter]), SPPostgresQuoteLiteral([options quote]),
					 SPPostgresQuoteLiteral([options escape]), [options header] ? @"true" : @"false", SPPostgresQuoteLiteral([options nullString] ?: @"")];

	SPPostgresCSVOutput *output = [[[SPPostgresCSVOutput alloc] initWithPath:path error:error] autorelease];
	if (!output) return NO;

	BOOL wasIdle = ([connection transactionStatus] == PGPostgresTransactionIdle);
	__block BOOL cancelled = NO;
	NSError *copyError = nil;
	BOOL copied = [connection copyOut:sql handler:^BOOL(NSData *chunk) {
		if (shouldCancel && shouldCancel()) {
			cancelled = YES;
			return NO;
		}
		return [output write:[chunk bytes] length:[chunk length]];
	} error:&copyError];

	if (copied && [output finish]) return YES;

	[output discard];
	// Outside a transaction the connection is left idle; one the caller opened is the caller's to end
	if (wasIdle && [connection transactionStatus] != PGPostgresTransactionIdle) [connection execute:@"ROLLBACK"];
	if (error) {
		if (cancelled) *error = SPCSVCancelledError(NO);
		else if ([output error]) *error = [[[output error] retain] autorelease];
		else *error = SPCSVError(SPPostgresErrorQueryFailed, [copyError localizedDescription] ?: NSLocalizedString(@"The export failed.", @"Postgres export: unknown failure"));
	}
	return NO;
}

+ (BOOL)exportRows:(NSArray *)rows columnNames:(NSArray *)names options:(SPPostgresCSVOptions *)options
			toPath:(NSString *)path error:(NSError **)error
{
	unsigned char delimiter, quote, escape;
	if (!SPCSVCheckOptions(options, &delimiter, &quote, &escape, error)) return NO;
	NSData *nullBytes = [[options nullString] ?: @"" dataUsingEncoding:NSUTF8StringEncoding];

	SPPostgresCSVOutput *output = [[[SPPostgresCSVOutput alloc] initWithPath:path error:error] autorelease];
	if (!output) return NO;

	NSUInteger columns = [names count];
	if (!columns && [rows count]) columns = [[rows objectAtIndex:0] count];
	BOOL singleColumn = (columns == 1);

	NSMutableData *buffer = [NSMutableData dataWithCapacity:SPCSVSendSize + 4096];
	BOOL ok = YES;
	if ([options header]) SPCSVAppendRow(buffer, names ?: @[], nullBytes, delimiter, quote, escape, singleColumn);
	NSUInteger count = [rows count];
	for (NSUInteger index = 0; ok && index < count; index++) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		SPCSVAppendRow(buffer, [rows objectAtIndex:index], nullBytes, delimiter, quote, escape, singleColumn);
		if ([buffer length] >= SPCSVSendSize) {
			ok = [output write:[buffer bytes] length:[buffer length]];
			[buffer setLength:0];
		}
		[pool drain];
	}
	if (ok) ok = [output write:[buffer bytes] length:[buffer length]];
	if (ok && [output finish]) return YES;

	[output discard];
	if (error) *error = [[[output error] retain] autorelease];
	return NO;
}

#pragma mark Reading

+ (NSArray *)previewRowsAtPath:(NSString *)path options:(SPPostgresCSVOptions *)options limit:(NSUInteger)limit
						 error:(NSError **)error
{
	SPPostgresCSVReader *reader = [[[SPPostgresCSVReader alloc] initWithPath:path options:options error:error] autorelease];
	if (!reader) return nil;
	NSMutableArray *rows = [NSMutableArray array];
	NSError *readError = nil;
	if ([options header] && ![reader nextRow:&readError] && readError) {
		if (error) *error = readError;
		return nil;
	}
	while ([rows count] < limit) {
		NSArray *fields = [reader nextRow:&readError];
		if (!fields) {
			if (readError) {
				if (error) *error = readError;
				return nil;
			}
			break;
		}
		NSArray *strings = SPCSVStrings(fields, [reader lastDataRow], error);
		if (!strings) return nil;
		[rows addObject:strings];
	}
	return rows;
}

+ (NSArray *)headerAtPath:(NSString *)path options:(SPPostgresCSVOptions *)options error:(NSError **)error
{
	SPPostgresCSVReader *reader = [[[SPPostgresCSVReader alloc] initWithPath:path options:options error:error] autorelease];
	if (!reader) return nil;
	NSError *readError = nil;
	NSMutableArray *names = [NSMutableArray array];

	if ([options header]) {
		NSArray *fields = [reader nextRow:&readError];
		if (!fields) {
			if (readError && error) *error = readError;
			return readError ? nil : names;
		}
		NSArray *strings = SPCSVStrings(fields, 0, error);
		if (!strings) return nil;
		for (id name in strings) {
			if (name == [NSNull null] || ![name length]) name = [NSString stringWithFormat:NSLocalizedString(@"Column %lu", @"Postgres CSV: a column without a name"), (unsigned long)([names count] + 1)];
			[names addObject:name];
		}
		return names;
	}

	NSUInteger widest = 0;
	for (NSUInteger index = 0; index < 10; index++) {
		NSArray *fields = [reader nextRow:&readError];
		if (!fields) {
			if (readError) {
				if (error) *error = readError;
				return nil;
			}
			break;
		}
		widest = MAX(widest, [fields count]);
	}
	for (NSUInteger column = 1; column <= widest; column++) {
		[names addObject:[NSString stringWithFormat:NSLocalizedString(@"Column %lu", @"Postgres CSV: a column without a name"), (unsigned long)column]];
	}
	return names;
}

#pragma mark Import

+ (BOOL)importPath:(NSString *)path options:(SPPostgresCSVOptions *)options intoTable:(NSString *)table
			schema:(NSString *)schema columnMapping:(NSArray *)mapping connection:(PGPostgresConnection *)connection
		  progress:(BOOL (^)(unsigned long long bytesRead, unsigned long long fileSize))progress
			 error:(NSError **)error
{
	if (!SPCSVCheckOptions(options, NULL, NULL, NULL, error)) return NO;
	if ([connection transactionStatus] != PGPostgresTransactionIdle) {
		if (error) *error = SPCSVError(SPPostgresErrorQueryFailed, NSLocalizedString(@"The import needs a connection with no transaction open.", @"Postgres import: connection busy"));
		return NO;
	}

	// The table's columns, in attnum order
	NSString *qualified = SPCSVQualified(schema, table);
	PGPostgresResult *result = SPPostgresExecuteWithDetails(connection,
		@"SELECT a.attname::text, (a.attgenerated <> '')::text FROM pg_catalog.pg_attribute a"
		" WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum", @[qualified], error);
	if (!result) return NO;
	NSMutableArray *columnNames = [NSMutableArray array];
	NSMutableArray *generated = [NSMutableArray array];
	for (unsigned long long index = 0; index < [result numberOfRows]; index++) {
		id name = [result textValueAtRow:index column:0];
		[columnNames addObject:[name isKindOfClass:[NSString class]] ? name : @""];
		[generated addObject:@([[result textValueAtRow:index column:1] isEqual:@"true"])];
	}

	// The mapping: one entry per column
	NSString *mappingProblem = nil;
	NSMutableArray *targets = [NSMutableArray array];     // quoted column names
	NSMutableArray *sources = [NSMutableArray array];     // NSNumber field index, same order
	NSMutableArray *targetNames = [NSMutableArray array];
	if ([mapping count] != [columnNames count]) {
		mappingProblem = [NSString stringWithFormat:NSLocalizedString(@"The column mapping has %lu entries, but “%@” has %lu columns.", @"Postgres CSV import: mapping of the wrong size"),
						  (unsigned long)[mapping count], table, (unsigned long)[columnNames count]];
	}
	for (NSUInteger index = 0; !mappingProblem && index < [mapping count]; index++) {
		id entry = [mapping objectAtIndex:index];
		if (entry == [NSNull null]) continue;
		if (![entry isKindOfClass:[NSNumber class]] || [entry longLongValue] < 0) {
			mappingProblem = [NSString stringWithFormat:NSLocalizedString(@"The column mapping for “%@” isn't a field number.", @"Postgres CSV import: bad mapping entry"), columnNames[index]];
		}
		else if ([generated[index] boolValue]) {
			mappingProblem = [NSString stringWithFormat:NSLocalizedString(@"Column “%@” is generated, so it can't be imported.", @"Postgres CSV import: generated column mapped"), columnNames[index]];
		}
		else {
			[targets addObject:SPPostgresQuoteIdentifier(columnNames[index])];
			[targetNames addObject:columnNames[index]];
			[sources addObject:entry];
		}
	}
	if (!mappingProblem && ![targets count]) mappingProblem = NSLocalizedString(@"Choose at least one column to import.", @"Postgres CSV import: nothing mapped");
	if (mappingProblem) {
		if (error) *error = SPCSVError(SPPostgresErrorInvalidSettings, mappingProblem);
		return NO;
	}

	SPPostgresCSVReader *reader = [[[SPPostgresCSVReader alloc] initWithPath:path options:options error:error] autorelease];
	if (!reader) return NO;
	NSError *readError = nil;
	if ([options header] && ![reader nextRow:&readError] && readError) {
		if (error) *error = readError;
		return NO;
	}

	if (!SPPostgresExecuteWithDetails(connection, @"BEGIN", nil, error)) return NO;

	NSUInteger mappedCount = [sources count];
	NSUInteger *fieldIndexes = malloc(sizeof(NSUInteger) * mappedCount);
	for (NSUInteger index = 0; index < mappedCount; index++) fieldIndexes[index] = [[sources objectAtIndex:index] unsignedIntegerValue];

	__block NSError *dataError = nil;
	__block BOOL cancelled = NO;
	__block BOOL finished = NO;
	NSError *copyError = nil;
	NSString *sql = [NSString stringWithFormat:@"COPY %@ (%@) FROM STDIN", qualified, [targets componentsJoinedByString:@", "]];
	BOOL copied = [connection copyIn:sql provider:^NSData *(BOOL *cancel) {
		if (finished) return nil;
		NSMutableData *chunk = [NSMutableData dataWithCapacity:SPCSVSendSize + 4096];
		while ([chunk length] < SPCSVSendSize) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSError *rowError = nil;
			NSArray *fields = [reader nextRow:&rowError];
			if (!fields) {
				if (rowError) dataError = [rowError retain];
				else finished = YES;
				[pool drain];
				break;
			}
			NSUInteger fieldCount = [fields count];
			for (NSUInteger index = 0; index < mappedCount; index++) {
				if (fieldIndexes[index] >= fieldCount) {
					NSString *message = [NSString stringWithFormat:(fieldCount == 1
						? NSLocalizedString(@"Row %lu has %lu field; column “%@” needs field %lu.", @"Postgres CSV import: row too short (one field)")
						: NSLocalizedString(@"Row %lu has %lu fields; column “%@” needs field %lu.", @"Postgres CSV import: row too short")),
						(unsigned long)[reader lastDataRow], (unsigned long)fieldCount, targetNames[index], (unsigned long)(fieldIndexes[index] + 1)];
					dataError = [SPCSVError(SPPostgresErrorQueryFailed, message) retain];
					break;
				}
				id value = [fields objectAtIndex:fieldIndexes[index]];
				// Checked here so the message names the row as the other reading errors do
				if (value != [NSNull null] && !SPCSVIsValidUTF8([value bytes], [value length])) {
					dataError = [SPCSVError(SPPostgresErrorQueryFailed, [NSString stringWithFormat:NSLocalizedString(@"Row %lu isn't valid UTF-8 text.", @"Postgres CSV: row not UTF-8"), (unsigned long)[reader lastDataRow]]) retain];
					break;
				}
				if (index) [chunk appendBytes:"\t" length:1];
				SPCSVAppendCopyText(chunk, value);
			}
			[chunk appendBytes:"\n" length:1];
			[pool drain];
			if (dataError) break;
		}
		if (dataError) {
			*cancel = YES;
			return nil;
		}
		if (progress && !progress([reader bytesRead], [reader fileSize])) {
			cancelled = YES;
			*cancel = YES;
			return nil;
		}
		if (![chunk length]) return nil;
		return chunk;
	} error:&copyError];
	free(fieldIndexes);

	NSError *failure = nil;
	if (copied) {
		NSError *commitError = nil;
		if (SPPostgresExecuteWithDetails(connection, @"COMMIT", nil, &commitError)) return YES;
		failure = commitError;
	}
	else if (dataError) failure = [dataError autorelease];
	else if (cancelled) failure = SPCSVCancelledError(YES);
	else failure = SPCSVError(SPPostgresErrorQueryFailed, [copyError localizedDescription] ?: NSLocalizedString(@"The import failed.", @"Postgres import: unknown failure"));

	// A failed or cancelled COPY leaves the transaction aborted; a second ROLLBACK covers a late cancel
	for (NSUInteger attempt = 0; attempt < 2 && [connection transactionStatus] != PGPostgresTransactionIdle; attempt++) {
		[connection execute:@"ROLLBACK"];
	}
	if (error) *error = failure;
	return NO;
}

@end
