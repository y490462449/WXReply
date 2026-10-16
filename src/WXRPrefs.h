#pragma once
#import <Foundation/Foundation.h>

/// 极简配置存储：<微信容器>/Library/Application Support/WXReply/config.plist
/// 用文件而不是 NSUserDefaults，避免污染微信自己的偏好域。
@interface WXRPrefs : NSObject

+ (instancetype)shared;
+ (NSString *)configDirectory;
+ (NSString *)configPath;

- (NSDictionary *)allValues;
- (void)reload;
- (void)resetAll;

- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;

- (void)setObject:(id)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setDouble:(double)value forKey:(NSString *)key;

/* ---- 常用快捷属性 ---- */
@property (nonatomic, readonly) BOOL boolEnabled;        // 自动回复总开关
@property (nonatomic, readonly) BOOL boolAIEnabled;
@property (nonatomic, readonly) BOOL boolVerbose;
@property (nonatomic, readonly) BOOL boolLogContent;
@property (nonatomic, readonly) BOOL boolTabBarLongPress;

@end
