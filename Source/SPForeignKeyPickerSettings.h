//
//  SPForeignKeyPickerSettings.h
//  Sequel Plus
//
//  Remembers which columns the foreign key value picker shows, per referenced table,
//  in an injected defaults object (tests pass a throwaway suite).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface SPForeignKeyPickerSettings : NSObject

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;

/// A key for one referenced table: kind is @"mysql" or @"postgres"; schema is nil for MySQL.
+ (NSString *)tableKeyWithKind:(NSString *)kind host:(nullable NSString *)host port:(NSInteger)port database:(nullable NSString *)database schema:(nullable NSString *)schema table:(NSString *)table;

/// The key column first, then the remembered columns still in `available`, in `available` order;
/// with nothing remembered, every column of `available` (key first).
- (NSArray<NSString *> *)shownColumnsForTableKey:(NSString *)key available:(NSArray<NSString *> *)available keyColumn:(NSString *)keyColumn;

/// nil removes the entry (Reset to Default).
- (void)setShownColumns:(nullable NSArray<NSString *> *)columns forTableKey:(NSString *)key;

/// The Preferences ▸ Tables switch; on unless set off.
- (BOOL)pickerEnabled;

@end

NS_ASSUME_NONNULL_END
