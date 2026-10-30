#import "SPPostgresHelp.h"
#import "SPPostgresSQLTokenizer.h"
#import "SPConstants.h"
#import <WebKit/WebKit.h>

// The PostgreSQL documentation's pages: https://www.postgresql.org/docs/<major>/<page>
static NSString * const SPPostgresDocumentationURLFormat = @"https://www.postgresql.org/docs/%@/%@";
// Its search, within one version's pages
static NSString * const SPPostgresDocumentationSearchURLFormat = @"https://www.postgresql.org/search/?u=%%2Fdocs%%2F%@%%2F&q=%@";
// The "SQL Commands" list: the page of a keyword without a page of its own
static NSString * const SPPostgresCommandsPage = @"sql-commands.html";
// The longest command ("create text search configuration", "alter foreign data wrapper")
static const NSUInteger SPPostgresHelpMaxCommandWords = 4;

/// The HTML-escaped string.
static NSString *SPPostgresHelpEscapedHTML(NSString *string)
{
	NSMutableString *escaped = [NSMutableString stringWithString:string ?: @""];
	[escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, [escaped length])];
	return escaped;
}

@interface SPPostgresHelpDataSource () <SPHelpViewerDataSource>
@end

@implementation SPPostgresHelpDataSource
{
	NSString *serverMajorVersion;
	NSString *helpHTMLTemplate;
}

@synthesize serverMajorVersion;

/**
 * The commands of the PostgreSQL 18 documentation's "SQL Commands" list (https://www.postgresql.org/docs/18/sql-commands.html,
 * 183 entries), keyed by their words lowercased.
 */
+ (NSDictionary<NSString *, NSString *> *)_commandPages
{
	static NSDictionary *pages = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		pages = [@{
			@"abort": @"sql-abort.html",
			@"alter aggregate": @"sql-alteraggregate.html",
			@"alter collation": @"sql-altercollation.html",
			@"alter conversion": @"sql-alterconversion.html",
			@"alter database": @"sql-alterdatabase.html",
			@"alter default privileges": @"sql-alterdefaultprivileges.html",
			@"alter domain": @"sql-alterdomain.html",
			@"alter event trigger": @"sql-altereventtrigger.html",
			@"alter extension": @"sql-alterextension.html",
			@"alter foreign data wrapper": @"sql-alterforeigndatawrapper.html",
			@"alter foreign table": @"sql-alterforeigntable.html",
			@"alter function": @"sql-alterfunction.html",
			@"alter group": @"sql-altergroup.html",
			@"alter index": @"sql-alterindex.html",
			@"alter language": @"sql-alterlanguage.html",
			@"alter large object": @"sql-alterlargeobject.html",
			@"alter materialized view": @"sql-altermaterializedview.html",
			@"alter operator": @"sql-alteroperator.html",
			@"alter operator class": @"sql-alteropclass.html",
			@"alter operator family": @"sql-alteropfamily.html",
			@"alter policy": @"sql-alterpolicy.html",
			@"alter procedure": @"sql-alterprocedure.html",
			@"alter publication": @"sql-alterpublication.html",
			@"alter role": @"sql-alterrole.html",
			@"alter routine": @"sql-alterroutine.html",
			@"alter rule": @"sql-alterrule.html",
			@"alter schema": @"sql-alterschema.html",
			@"alter sequence": @"sql-altersequence.html",
			@"alter server": @"sql-alterserver.html",
			@"alter statistics": @"sql-alterstatistics.html",
			@"alter subscription": @"sql-altersubscription.html",
			@"alter system": @"sql-altersystem.html",
			@"alter table": @"sql-altertable.html",
			@"alter tablespace": @"sql-altertablespace.html",
			@"alter text search configuration": @"sql-altertsconfig.html",
			@"alter text search dictionary": @"sql-altertsdictionary.html",
			@"alter text search parser": @"sql-altertsparser.html",
			@"alter text search template": @"sql-altertstemplate.html",
			@"alter trigger": @"sql-altertrigger.html",
			@"alter type": @"sql-altertype.html",
			@"alter user": @"sql-alteruser.html",
			@"alter user mapping": @"sql-alterusermapping.html",
			@"alter view": @"sql-alterview.html",
			@"analyze": @"sql-analyze.html",
			@"begin": @"sql-begin.html",
			@"call": @"sql-call.html",
			@"checkpoint": @"sql-checkpoint.html",
			@"close": @"sql-close.html",
			@"cluster": @"sql-cluster.html",
			@"comment": @"sql-comment.html",
			@"commit": @"sql-commit.html",
			@"commit prepared": @"sql-commit-prepared.html",
			@"copy": @"sql-copy.html",
			@"create access method": @"sql-create-access-method.html",
			@"create aggregate": @"sql-createaggregate.html",
			@"create cast": @"sql-createcast.html",
			@"create collation": @"sql-createcollation.html",
			@"create conversion": @"sql-createconversion.html",
			@"create database": @"sql-createdatabase.html",
			@"create domain": @"sql-createdomain.html",
			@"create event trigger": @"sql-createeventtrigger.html",
			@"create extension": @"sql-createextension.html",
			@"create foreign data wrapper": @"sql-createforeigndatawrapper.html",
			@"create foreign table": @"sql-createforeigntable.html",
			@"create function": @"sql-createfunction.html",
			@"create group": @"sql-creategroup.html",
			@"create index": @"sql-createindex.html",
			@"create language": @"sql-createlanguage.html",
			@"create materialized view": @"sql-creatematerializedview.html",
			@"create operator": @"sql-createoperator.html",
			@"create operator class": @"sql-createopclass.html",
			@"create operator family": @"sql-createopfamily.html",
			@"create policy": @"sql-createpolicy.html",
			@"create procedure": @"sql-createprocedure.html",
			@"create publication": @"sql-createpublication.html",
			@"create role": @"sql-createrole.html",
			@"create rule": @"sql-createrule.html",
			@"create schema": @"sql-createschema.html",
			@"create sequence": @"sql-createsequence.html",
			@"create server": @"sql-createserver.html",
			@"create statistics": @"sql-createstatistics.html",
			@"create subscription": @"sql-createsubscription.html",
			@"create table": @"sql-createtable.html",
			@"create table as": @"sql-createtableas.html",
			@"create tablespace": @"sql-createtablespace.html",
			@"create text search configuration": @"sql-createtsconfig.html",
			@"create text search dictionary": @"sql-createtsdictionary.html",
			@"create text search parser": @"sql-createtsparser.html",
			@"create text search template": @"sql-createtstemplate.html",
			@"create transform": @"sql-createtransform.html",
			@"create trigger": @"sql-createtrigger.html",
			@"create type": @"sql-createtype.html",
			@"create user": @"sql-createuser.html",
			@"create user mapping": @"sql-createusermapping.html",
			@"create view": @"sql-createview.html",
			@"deallocate": @"sql-deallocate.html",
			@"declare": @"sql-declare.html",
			@"delete": @"sql-delete.html",
			@"discard": @"sql-discard.html",
			@"do": @"sql-do.html",
			@"drop access method": @"sql-drop-access-method.html",
			@"drop aggregate": @"sql-dropaggregate.html",
			@"drop cast": @"sql-dropcast.html",
			@"drop collation": @"sql-dropcollation.html",
			@"drop conversion": @"sql-dropconversion.html",
			@"drop database": @"sql-dropdatabase.html",
			@"drop domain": @"sql-dropdomain.html",
			@"drop event trigger": @"sql-dropeventtrigger.html",
			@"drop extension": @"sql-dropextension.html",
			@"drop foreign data wrapper": @"sql-dropforeigndatawrapper.html",
			@"drop foreign table": @"sql-dropforeigntable.html",
			@"drop function": @"sql-dropfunction.html",
			@"drop group": @"sql-dropgroup.html",
			@"drop index": @"sql-dropindex.html",
			@"drop language": @"sql-droplanguage.html",
			@"drop materialized view": @"sql-dropmaterializedview.html",
			@"drop operator": @"sql-dropoperator.html",
			@"drop operator class": @"sql-dropopclass.html",
			@"drop operator family": @"sql-dropopfamily.html",
			@"drop owned": @"sql-drop-owned.html",
			@"drop policy": @"sql-droppolicy.html",
			@"drop procedure": @"sql-dropprocedure.html",
			@"drop publication": @"sql-droppublication.html",
			@"drop role": @"sql-droprole.html",
			@"drop routine": @"sql-droproutine.html",
			@"drop rule": @"sql-droprule.html",
			@"drop schema": @"sql-dropschema.html",
			@"drop sequence": @"sql-dropsequence.html",
			@"drop server": @"sql-dropserver.html",
			@"drop statistics": @"sql-dropstatistics.html",
			@"drop subscription": @"sql-dropsubscription.html",
			@"drop table": @"sql-droptable.html",
			@"drop tablespace": @"sql-droptablespace.html",
			@"drop text search configuration": @"sql-droptsconfig.html",
			@"drop text search dictionary": @"sql-droptsdictionary.html",
			@"drop text search parser": @"sql-droptsparser.html",
			@"drop text search template": @"sql-droptstemplate.html",
			@"drop transform": @"sql-droptransform.html",
			@"drop trigger": @"sql-droptrigger.html",
			@"drop type": @"sql-droptype.html",
			@"drop user": @"sql-dropuser.html",
			@"drop user mapping": @"sql-dropusermapping.html",
			@"drop view": @"sql-dropview.html",
			@"end": @"sql-end.html",
			@"execute": @"sql-execute.html",
			@"explain": @"sql-explain.html",
			@"fetch": @"sql-fetch.html",
			@"grant": @"sql-grant.html",
			@"import foreign schema": @"sql-importforeignschema.html",
			@"insert": @"sql-insert.html",
			@"listen": @"sql-listen.html",
			@"load": @"sql-load.html",
			@"lock": @"sql-lock.html",
			@"merge": @"sql-merge.html",
			@"move": @"sql-move.html",
			@"notify": @"sql-notify.html",
			@"prepare": @"sql-prepare.html",
			@"prepare transaction": @"sql-prepare-transaction.html",
			@"reassign owned": @"sql-reassign-owned.html",
			@"refresh materialized view": @"sql-refreshmaterializedview.html",
			@"reindex": @"sql-reindex.html",
			@"release savepoint": @"sql-release-savepoint.html",
			@"reset": @"sql-reset.html",
			@"revoke": @"sql-revoke.html",
			@"rollback": @"sql-rollback.html",
			@"rollback prepared": @"sql-rollback-prepared.html",
			@"rollback to savepoint": @"sql-rollback-to.html",
			@"savepoint": @"sql-savepoint.html",
			@"security label": @"sql-security-label.html",
			@"select": @"sql-select.html",
			@"select into": @"sql-selectinto.html",
			@"set": @"sql-set.html",
			@"set constraints": @"sql-set-constraints.html",
			@"set role": @"sql-set-role.html",
			@"set session authorization": @"sql-set-session-authorization.html",
			@"set transaction": @"sql-set-transaction.html",
			@"show": @"sql-show.html",
			@"start transaction": @"sql-start-transaction.html",
			@"truncate": @"sql-truncate.html",
			@"unlisten": @"sql-unlisten.html",
			@"update": @"sql-update.html",
			@"vacuum": @"sql-vacuum.html",
			@"values": @"sql-values.html",
		} retain];
	});
	return pages;
}

/// keyword's words, lowercased (at most SPPostgresHelpMaxCommandWords).
+ (NSArray<NSString *> *)_wordsOfKeyword:(NSString *)keyword
{
	NSMutableArray *words = [NSMutableArray array];
	for (NSString *word in [[keyword lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
		if (![word length]) continue;
		[words addObject:word];
		if ([words count] == SPPostgresHelpMaxCommandWords) break;
	}
	return words;
}

/// The command (its lowercased words) or keyword that keyword's help is about, and its page; nil when there is none.
+ (NSString *)_topicForKeyword:(NSString *)keyword page:(NSString **)page
{
	NSArray *words = [self _wordsOfKeyword:keyword];
	if (![words count]) return nil;

	NSDictionary *pages = [self _commandPages];
	// The longest leading words that are a command ("create table" before "create")
	for (NSUInteger count = [words count]; count > 0; count--) {
		NSString *command = [[words subarrayWithRange:NSMakeRange(0, count)] componentsJoinedByString:@" "];
		NSString *commandPage = [pages objectForKey:command];
		if (commandPage) {
			if (page) *page = commandPage;
			return command;
		}
	}

	NSString *first = [words objectAtIndex:0];
	if ([[SPPostgresSQLTokenizer keywords] containsObject:first]) {
		if (page) *page = SPPostgresCommandsPage;
		return first;
	}
	return nil;
}

+ (NSString *)documentationPathForKeyword:(NSString *)keyword
{
	NSString *page = nil;
	return [self _topicForKeyword:keyword page:&page] ? page : nil;
}

+ (NSString *)titleForKeyword:(NSString *)keyword
{
	return [[self _topicForKeyword:keyword page:NULL] uppercaseString];
}

+ (NSString *)majorVersionFromServerVersion:(NSString *)serverVersion
{
	NSArray *parts = [serverVersion componentsSeparatedByString:@"."];
	NSInteger major = [[parts firstObject] integerValue];
	if (major >= 10) return [NSString stringWithFormat:@"%ld", (long)major];
	if (major > 0 && [parts count] > 1) return [NSString stringWithFormat:@"%ld.%ld", (long)major, (long)[[parts objectAtIndex:1] integerValue]];
	return @"current";
}

- (instancetype)initWithServerMajorVersion:(NSString *)major
{
	if ((self = [super init])) {
		serverMajorVersion = [([major length] ? major : @"current") copy];

		// MySQL's help page template (as SPHelpViewerClient)
		NSString *path = [[NSBundle mainBundle] pathForResource:SPHTMLHelpTemplate ofType:@"html"];
		helpHTMLTemplate = path ? [[NSString alloc] initWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
		if (!helpHTMLTemplate) helpHTMLTemplate = [@"<html><head><title>{{title}}</title></head><body class=\"{{bodyClass}}\">{{body}}</body></html>" copy];
	}
	return self;
}

- (void)dealloc
{
	[serverMajorVersion release];
	[helpHTMLTemplate release];
	[super dealloc];
}

- (NSString *)_documentationURLForPage:(NSString *)page
{
	return [NSString stringWithFormat:SPPostgresDocumentationURLFormat, serverMajorVersion ?: @"current", page];
}

/// A help link (the help window shows that topic when it is clicked), as SPHelpViewerClient's.
+ (NSString *)_linkToHelpTopic:(NSString *)topic title:(NSString *)title
{
	NSString *href = [topic stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
	NSString *tooltip = [NSString stringWithFormat:NSLocalizedString(@"Show PostgreSQL help for “%@”", @"Postgres help viewer: help link tooltip"), title];
	return [NSString stringWithFormat:@"<a title='%@' href='%@' class='internallink'>%@</a>",
			SPPostgresHelpEscapedHTML(tooltip), SPPostgresHelpEscapedHTML(href), SPPostgresHelpEscapedHTML(title)];
}

- (NSString *)HTMLHelpContentsForSearchString:(NSString *)searchString autoHelp:(BOOL)autoHelp
{
	if (![searchString length]) return @"";

	NSMutableString *theTitle = [NSMutableString stringWithFormat:NSLocalizedString(@"Version %@", @"Mysql Help Viewer : window title : mysql server version"), serverMajorVersion];
	NSMutableString *theHelp = [NSMutableString string];

	if ([searchString isEqualToString:SPHelpViewerSearchTOC]) {
		// The table of contents: the SQL commands, as help links, and the documentation's list
		[theTitle appendFormat:@": %@", NSLocalizedString(@"Table of Contents", @"Mysql Help Viewer : window title : TOC")];
		NSString *listURL = [self _documentationURLForPage:SPPostgresCommandsPage];
		[theHelp appendFormat:@"<br><b><a href=\"%@\">%@</a>:</b><br><ul>", SPPostgresHelpEscapedHTML(listURL), NSLocalizedString(@"SQL Commands", @"Postgres help viewer: table of contents title")];
		for (NSString *command in [[[[self class] _commandPages] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
			[theHelp appendFormat:@"<li>%@</li>", [[self class] _linkToHelpTopic:command title:[command uppercaseString]]];
		}
		[theHelp appendString:@"</ul>"];
	}
	else {
		NSString *page = nil;
		NSString *topic = [[self class] _topicForKeyword:searchString page:&page];
		if (topic) {
			// The topic's title and one link to its page
			NSString *title = [topic uppercaseString];
			NSString *url = [self _documentationURLForPage:page];
			[theTitle appendFormat:@": %@", title];
			[theHelp appendFormat:@"<h2 class='header'>%@</h2>", SPPostgresHelpEscapedHTML(title)];
			[theHelp appendFormat:@"<p><a href=\"%@\">%@</a></p>", SPPostgresHelpEscapedHTML(url),
			 SPPostgresHelpEscapedHTML([NSString stringWithFormat:NSLocalizedString(@"PostgreSQL %1$@ Documentation: %2$@", @"Postgres help viewer: documentation link ($1: major version, $2: topic)"), serverMajorVersion, title])];
		}
		else {
			// As MySQL's
			[theTitle appendFormat:@": %@", NSLocalizedString(@"No Results", @"Mysql Help Viewer : window title : nothing found")];
			[theHelp appendFormat:@"<em class='nothing'>%@</em>", NSLocalizedString(@"No results found.", @"Mysql Help Viewer : Search : No results")];
		}
	}

	// As SPHelpViewerClient: the dark style in dark mode
	NSString *bodyClass = @"";
	NSString *match = [[NSApp effectiveAppearance] bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
	if ([NSAppearanceNameDarkAqua isEqualToString:match]) bodyClass = @"dark";

	NSMutableString *html = [NSMutableString stringWithString:helpHTMLTemplate];
	[html replaceOccurrencesOfString:@"{{title}}" withString:SPPostgresHelpEscapedHTML(theTitle) options:0 range:NSMakeRange(0, [html length])];
	[html replaceOccurrencesOfString:@"{{bodyClass}}" withString:bodyClass options:0 range:NSMakeRange(0, [html length])];
	[html replaceOccurrencesOfString:@"{{body}}" withString:theHelp options:0 range:NSMakeRange(0, [html length])];
	return html;
}

/// The help window's Web search: the topic's page, else a search of this version's documentation, in the browser.
- (void)openOnlineHelpForTopic:(NSString *)searchString
{
	NSString *page = [[self class] documentationPathForKeyword:searchString];
	NSString *url;
	if (page && ![page isEqualToString:SPPostgresCommandsPage]) {
		url = [self _documentationURLForPage:page];
	}
	else {
		NSString *query = [searchString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
		query = [query stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
		url = [NSString stringWithFormat:SPPostgresDocumentationSearchURLFormat, serverMajorVersion ?: @"current", query ?: @""];
	}
	NSURL *theURL = [NSURL URLWithString:url];
	if (theURL) [[NSWorkspace sharedWorkspace] openURL:theURL];
}

@end

#pragma mark -

// SPHelpViewerController's private title update (Source/SPHelpViewerController.m), overridden below
@interface SPHelpViewerController (SPPostgresHelpTitle)
- (void)updateWindowTitle;
@end

@implementation SPPostgresHelpViewerController

/// As SPHelpViewerController's, titled for PostgreSQL. Overrides a private SPHelpViewerController method;
/// testAutoHelpShowsWordAtCaret (SPPostgresQueryGearTests) guards the title.
- (void)updateWindowTitle
{
	NSString *title = NSLocalizedString(@"PostgreSQL Help", @"Postgres help viewer: window title");

	NSString *webTitle = [helpWebView mainFrameTitle];
	if ([webTitle length]) title = [title stringByAppendingFormat:@" (%@)", webTitle];

	[[self window] setTitle:title];
}

@end
