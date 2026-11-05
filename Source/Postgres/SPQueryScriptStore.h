#import <Cocoa/Cocoa.h>

/// Engine names used in query script keys
extern NSString * const SPQueryScriptEngineMySQL __attribute__((visibility("default")));
extern NSString * const SPQueryScriptEnginePostgreSQL __attribute__((visibility("default")));

/**
 * The Query editor's text, saved per connection (MySQL and PostgreSQL): one UTF-8 file per connection key in
 * one folder. The file's name is a hash of the key. An empty script removes the file.
 */
__attribute__((visibility("default")))
@interface SPQueryScriptStore : NSObject

/// The store in ~/Library/Application Support/Sequel Plus/Data/Query Scripts.
+ (instancetype)sharedStore;

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL;

@property (readonly) NSURL *directoryURL;

- (NSURL *)fileURLForKey:(NSString *)key;
/// The saved script, or nil.
- (NSString *)scriptForKey:(NSString *)key;
/// Saves `script` (an empty one removes the saved script).
- (BOOL)saveScript:(NSString *)script forKey:(NSString *)key error:(NSError **)error;

/// A saved favorite's key: the same however the favorite is renamed or edited.
+ (NSString *)keyForEngine:(NSString *)engine favoriteID:(NSString *)favoriteID;
/// A connection without a saved favorite (Quick Connect): its server details. The host is compared ignoring case.
+ (NSString *)keyForEngine:(NSString *)engine type:(NSInteger)type host:(NSString *)host port:(NSString *)port user:(NSString *)user socket:(NSString *)socket sshHost:(NSString *)sshHost sshUser:(NSString *)sshUser;

@end

/**
 * Saves a Query editor's text to a store as the user edits it: shortly after each edit (`delay`), when the app
 * quits, and on -invalidate. Only the user's edits are saved, so an editor that wasn't edited never replaces
 * what is saved.
 */
__attribute__((visibility("default")))
@interface SPQueryScriptAutosaver : NSObject

- (instancetype)initWithTextView:(NSTextView *)textView store:(SPQueryScriptStore *)store key:(NSString *)key;

@property (readonly) NSString *key;
@property (readonly) NSTextView *textView;
/// Seconds between the last edit and the save (default 1).
@property (assign) NSTimeInterval delay;

/**
 * When the editor is empty and a script is saved, puts the script in the editor with `insert` (nil: -setString:)
 * and returns YES. That doesn't count as an edit.
 */
- (BOOL)loadIntoEmptyEditorUsing:(void (^)(NSString *script))insert;

/// Saves now if the editor was edited since the last save.
- (void)saveIfEdited;

/// Saves an edit not saved yet, then stops watching the editor.
- (void)invalidate;

@end
