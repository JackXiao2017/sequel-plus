#import <XCTest/XCTest.h>
#import <objc/message.h>
#import "../Source/Postgres/SPPostgresFavorite.h"
#import "../Source/Postgres/SPPostgresFavoriteNode.h"

// App classes without exported symbols: looked up at run time
@interface NSObject (SPPGTreeTestsAppClasses)
+ (id)groupNodeWithName:(NSString *)name;
+ (id)favoriteNodeWithDictionary:(NSMutableDictionary *)dictionary;
+ (id)sharedFavoritesController;
- (NSString *)nodeName;
- (NSDictionary *)nodeFavorite;
- (BOOL)isGroup;
- (NSDictionary *)dictionaryRepresentation;
- (NSDictionary *)mysqlDictionaryRepresentation;
- (id)_constructBranchForNodeData:(NSDictionary *)nodeData;
- (id)_addFavoriteNodeWithData:(NSMutableDictionary *)data asChildOfNode:(id)parent;
- (void)setDelegate:(id)delegate;
- (void)writeFavorites:(NSArray *)favorites toFile:(NSString *)path;
@end

/// PostgreSQL favorites as leaves of the one favorites tree (Favorites.plist), and the MySQL-only places that read
/// the tree: favorites export, favorites import and the Default favorite pop-up. Nothing here writes a file except
/// the export, into a temporary folder; SPFavoritesController is only asked to build branches (no load, no save).
@interface SPPostgresFavoritesTreeTests : XCTestCase
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, strong) NSError *exportError;
@property (nonatomic, assign) BOOL exportDone;
@end

@implementation SPPostgresFavoritesTreeTests

- (void)setUp
{
	self.continueAfterFailure = NO;
	NSString *name = [@"SPPGTreeTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	self.dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtURL:self.dir error:nil];
}

#pragma mark - Fixtures

- (NSDictionary *)mysqlDictionary:(NSInteger)favoriteID
{
	return @{ @"id": @(favoriteID), @"name": [NSString stringWithFormat:@"m%ld", (long)favoriteID], @"host": @"mysqlhost", @"type": @0,
	          @"user": @"root", @"port": @"", @"colorIndex": @(-1), @"useSSL": @0, @"sshKeyLocationEnabled": @0, @"database": @"" };
}

- (NSDictionary *)postgresDictionary:(NSString *)name
{
	return @{ SPFavoriteEngineKey: SPFavoriteEnginePostgreSQL, SPPostgresFavoriteUUIDKey: [@"uuid-" stringByAppendingString:name],
	          @"name": name, @"host": @"pghost", @"port": @5432, @"type": @2, @"user": @"alice", @"database": @"appdb",
	          @"colorIndex": @1, @"useSSL": @YES, @"sslCACertPath": @"/ca.pem", @"sshHost": @"bastion", @"sshUser": @"bob", @"sshPort": @22 };
}

/// A Favorites.plist group dictionary: G (m2, p, Sub (m3, q))
- (NSDictionary *)mixedGroupDictionary
{
	NSDictionary *sub = @{ @"Name": @"Sub", @"IsExpanded": @NO, @"Children": @[[self mysqlDictionary:3], [self postgresDictionary:@"q"]] };
	return @{ @"Name": @"G", @"IsExpanded": @YES, @"Children": @[[self mysqlDictionary:2], [self postgresDictionary:@"p"], sub] };
}

- (id)favoritesController
{
	id controller = [NSClassFromString(@"SPFavoritesController") sharedFavoritesController];
	XCTAssertNotNil(controller);
	return controller;
}

- (id)branchFor:(NSDictionary *)dictionary
{
	return [[self favoritesController] _constructBranchForNodeData:dictionary];
}

- (id)section:(NSArray *)children
{
	NSTreeNode *node = [NSClassFromString(@"SPTreeNode") treeNodeWithRepresentedObject:[NSClassFromString(@"SPGroupNode") groupNodeWithName:@"FAVORITES"]];
	[[node mutableChildNodes] addObjectsFromArray:children];
	return node;
}

#pragma mark - Loading and saving

/// Favorites.plist dictionaries -> tree -> dictionaries: MySQL favorites and groups come back unchanged, and the
/// PostgreSQL favorites are leaves (in groups at any depth) that come back unchanged too.
- (void)testTreeRoundTripsMySQLAndPostgresFavorites
{
	NSDictionary *groupDictionary = [self mixedGroupDictionary];
	NSTreeNode *group = [self branchFor:groupDictionary];
	XCTAssertTrue([(id)group isGroup]);
	XCTAssertEqual([[group childNodes] count], 3u);

	NSTreeNode *p = [group childNodes][1];
	XCTAssertFalse([(id)p isGroup]);
	XCTAssertTrue([[p representedObject] isKindOfClass:[SPPostgresFavoriteNode class]]);
	XCTAssertNil([[p representedObject] nodeFavorite], @"MySQL code sees no MySQL favorite");
	SPPostgresFavorite *favorite = SPPostgresFavoriteForNode(p);
	XCTAssertEqualObjects(favorite.favoriteID, @"uuid-p");
	XCTAssertEqual(favorite.type, SPPostgresSSHConnection);
	XCTAssertEqualObjects(favorite.sshHost, @"bastion");
	XCTAssertEqual(favorite.sshPort, 22u);
	XCTAssertTrue(favorite.useSSL);
	XCTAssertEqualObjects(favorite.sslCACertPath, @"/ca.pem");
	XCTAssertEqualObjects([favorite keychainName], @"Sequel Plus (PostgreSQL) : p (uuid-p)", @"the keychain names don't change");
	XCTAssertNotNil(SPPostgresFavoriteForNode([[group childNodes][2] childNodes][1]), @"nested");

	// Saved back (as -saveFavorites does, through the section)
	NSTreeNode *section = [self section:@[group]];
	NSDictionary *saved = [[(id)section dictionaryRepresentation] objectForKey:@"Children"][0];
	XCTAssertEqualObjects(saved, groupDictionary);

	// MySQL favorites alone: exactly as before
	NSDictionary *mysqlOnly = @{ @"Name": @"M", @"IsExpanded": @NO, @"Children": @[[self mysqlDictionary:5], @{ @"Name": @"Empty", @"IsExpanded": @NO, @"Children": @[] }] };
	XCTAssertEqualObjects([[(id)[self section:@[[self branchFor:mysqlOnly]]] dictionaryRepresentation] objectForKey:@"Children"][0], mysqlOnly);
}

/// The PostgreSQL dictionary has no MySQL "id", so the MySQL lookups by numeric ID (default and last favorite,
/// keychain names) never match it; a later version's extra keys are kept.
- (void)testPostgresDictionaryHasNoMySQLIDAndKeepsUnknownKeys
{
	NSMutableDictionary *dictionary = [[self postgresDictionary:@"p"] mutableCopy];
	dictionary[@"futureKey"] = @"kept";
	NSTreeNode *node = [self branchFor:dictionary];
	SPPostgresFavorite *favorite = SPPostgresFavoriteForNode(node);
	favorite.host = nil;
	favorite.name = @"renamed";

	NSDictionary *saved = [(id)node dictionaryRepresentation];
	XCTAssertNil(saved[@"id"]);
	XCTAssertEqualObjects(saved[SPPostgresFavoriteUUIDKey], @"uuid-p");
	XCTAssertEqualObjects(saved[SPFavoriteEngineKey], SPFavoriteEnginePostgreSQL);
	XCTAssertEqualObjects(saved[@"futureKey"], @"kept");
	XCTAssertEqualObjects(saved[@"name"], @"renamed");
	XCTAssertNil(saved[@"host"], @"a cleared field is gone, not restored from what was loaded");

	XCTAssertTrue([SPPostgresFavoriteNode isPostgresFavoriteDictionary:saved]);
	XCTAssertFalse([SPPostgresFavoriteNode isPostgresFavoriteDictionary:[self mysqlDictionary:1]]);
	XCTAssertFalse([SPPostgresFavoriteNode isPostgresFavoriteDictionary:@{ SPFavoriteEngineKey: @"mysql" }]);
	XCTAssertFalse([SPPostgresFavoriteNode isPostgresFavoriteDictionary:@"not a dictionary"]);
}

/// The sort menu's keys give a PostgreSQL favorite a value: "type" sorts it after MySQL's connection types.
- (void)testSortValues
{
	NSTreeNode *p = [self branchFor:[self postgresDictionary:@"p"]];
	NSTreeNode *m = [self branchFor:[self mysqlDictionary:1]];
	XCTAssertEqualObjects(SPFavoritesSortValueForNode((id)p, @"name"), @"p");
	XCTAssertEqualObjects(SPFavoritesSortValueForNode((id)p, @"host"), @"pghost");
	XCTAssertEqualObjects(SPFavoritesSortValueForNode((id)p, @"type"), @102);
	XCTAssertEqualObjects(SPFavoritesSortValueForNode((id)p, @"colorIndex"), @1);
	XCTAssertEqualObjects(SPFavoritesSortValueForNode((id)m, @"type"), @0);
	XCTAssertEqualObjects(SPFavoritesSortValueForNode((id)m, @"name"), @"m1");
}

#pragma mark - MySQL-only places

- (void)testMySQLRepresentationLeavesPostgresFavoritesOut
{
	NSTreeNode *group = [self branchFor:[self mixedGroupDictionary]];
	NSDictionary *mysql = [(id)group mysqlDictionaryRepresentation];
	XCTAssertEqualObjects([mysql[@"Children"] valueForKey:@"name"], (@[@"m2", [NSNull null]]));
	XCTAssertEqualObjects([mysql[@"Children"][1][@"Children"] valueForKey:@"name"], (@[@"m3"]));
	XCTAssertNil([(id)[group childNodes][1] mysqlDictionaryRepresentation]);
}

- (void)favoritesExportCompletedWithError:(NSError *)error
{
	self.exportError = error;
	self.exportDone = YES;
}

/// Favorites export writes MySQL favorites and groups only, whatever is selected.
- (void)testExportWritesOnlyMySQLFavorites
{
	NSTreeNode *group = [self branchFor:[self mixedGroupDictionary]];
	NSTreeNode *lone = [self branchFor:[self postgresDictionary:@"lone"]];
	NSTreeNode *mysql = [self branchFor:[self mysqlDictionary:9]];
	[self section:@[group, lone, mysql]];

	id exporter = [[NSClassFromString(@"SPFavoritesExporter") alloc] init];
	XCTAssertNotNil(exporter);
	[exporter setDelegate:self];
	NSString *path = [[self.dir path] stringByAppendingPathComponent:@"export.plist"];
	[exporter writeFavorites:@[group, lone, mysql] toFile:path];

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while (!self.exportDone && [deadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	XCTAssertTrue(self.exportDone);
	XCTAssertNil(self.exportError);

	NSData *data = [NSData dataWithContentsOfFile:path];
	XCTAssertNotNil(data);
	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	XCTAssertFalse([text containsString:SPFavoriteEngineKey], @"no PostgreSQL favorite: %@", text);
	XCTAssertFalse([text containsString:@"pghost"]);
	NSArray *exported = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL][@"SPConnectionFavorites"];
	XCTAssertEqual([exported count], 2u, @"the group and the MySQL favorite");
	XCTAssertEqualObjects(exported[1][@"name"], @"m9");
	XCTAssertEqualObjects([exported[0][@"Children"] valueForKey:@"name"], (@[@"m2", [NSNull null]]));
}

/// Favorites import adds MySQL favorites only: a PostgreSQL favorite dictionary (alone or in a group) is skipped.
- (void)testFavoritesImportSkipsPostgresFavorites
{
	id controller = [self favoritesController];
	NSTreeNode *parent = [self section:@[]];

	XCTAssertNil([controller _addFavoriteNodeWithData:[[self postgresDictionary:@"p"] mutableCopy] asChildOfNode:parent]);
	XCTAssertEqual([[parent childNodes] count], 0u);

	NSTreeNode *group = [controller _addFavoriteNodeWithData:[[self mixedGroupDictionary] mutableCopy] asChildOfNode:parent];
	XCTAssertNotNil(group);
	XCTAssertEqual([[parent childNodes] count], 1u);
	XCTAssertEqualObjects([[group childNodes] valueForKeyPath:@"representedObject.nodeName"], (@[@"m2", @"Sub"]));
	XCTAssertEqualObjects([[[group childNodes][1] childNodes] valueForKeyPath:@"representedObject.nodeName"], (@[@"m3"]));
}

/// The Default favorite pop-up in General preferences lists MySQL favorites only.
- (void)testDefaultFavoritePopUpSkipsPostgresFavorites
{
	id pane = [[NSClassFromString(@"SPGeneralPreferencePane") alloc] init];
	XCTAssertNotNil(pane);
	SEL selector = NSSelectorFromString(@"_constructMenuItemsForNode:atLevel:");
	XCTAssertTrue([pane respondsToSelector:selector]);
	NSArray *(*construct)(id, SEL, id, NSUInteger) = (NSArray *(*)(id, SEL, id, NSUInteger))objc_msgSend;

	NSArray *items = construct(pane, selector, [self branchFor:[self mixedGroupDictionary]], 0);
	XCTAssertEqualObjects([items valueForKey:@"title"], (@[@"G", @"m2", @"Sub", @"m3"]));
	XCTAssertEqualObjects([items valueForKey:@"tag"], (@[@0, @2, @0, @3]));

	XCTAssertEqual([construct(pane, selector, [self branchFor:[self postgresDictionary:@"p"]], 0) count], 0u);
}

@end
