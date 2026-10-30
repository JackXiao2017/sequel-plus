#import <Cocoa/Cocoa.h>
#import "../SPHelpViewerController.h"

/**
 * The data of MySQL's help window (SPHelpViewerController) for PostgreSQL. Nothing is queried and nothing is fetched:
 * a page is the help topic's title and one link to its page in the PostgreSQL documentation for the server's major
 * version (https://www.postgresql.org/docs/<major>/…), which the help window opens in the browser when it is clicked
 * (its existing link policy). The pages are those of the documentation's "SQL Commands" list (PostgreSQL 18), keyed
 * by the command's words lowercased ("alter table" → sql-altertable.html); any other keyword links to that list
 * (sql-commands.html). The magic search string SPHelpViewerSearchTOC lists the commands as help links.
 * The page is MySQL's help template (SPMySQLHelpTemplate.html). Use on the main thread.
 */
__attribute__((visibility("default")))
@interface SPPostgresHelpDataSource : NSObject <SPHelpViewerDataSource>

/// major: @"18" (PostgreSQL 10 and later), or @"9.6" for servers before 10 (see +majorVersionFromServerVersion:).
- (instancetype)initWithServerMajorVersion:(NSString *)major;

/// The major version in the documentation's links (changed when the tab connects to another server version).
@property (copy) NSString *serverMajorVersion;

/// The documentation's version for a server version string ("18.6" → @"18", "9.6.24" → @"9.6"); @"current" when
/// it can't be read (e.g. @"unknown").
+ (NSString *)majorVersionFromServerVersion:(NSString *)serverVersion;

/**
 * The documentation page for keyword, one or more words in any case ("select" → @"sql-select.html", "create table" →
 * @"sql-createtable.html"): the longest leading words that are a command, else the first word's command, else, when
 * the first word is a keyword (SPPostgresSQLTokenizer), @"sql-commands.html". nil when the first word is not a keyword.
 */
+ (NSString *)documentationPathForKeyword:(NSString *)keyword;

/// The help topic's title for keyword: the command's (or the keyword's) words, uppercased (@"CREATE TABLE"); nil when
/// +documentationPathForKeyword: is nil.
+ (NSString *)titleForKeyword:(NSString *)keyword;

@end

/// MySQL's help window, titled "PostgreSQL Help" ("PostgreSQL Help (<page title>)" while a page is shown).
__attribute__((visibility("default")))
@interface SPPostgresHelpViewerController : SPHelpViewerController
@end
