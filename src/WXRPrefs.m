#import "WXRPrefs.h"
#import "WXRCommon.h"
#import "WXRLog.h"
#import <pthread.h>

static pthread_mutex_t gPrefsLock = PTHREAD_MUTEX_INITIALIZER;

@interface WXRPrefs ()
@property (nonatomic, strong) NSMutableDictionary *store;
@end

@implementation WXRPrefs

+ (instancetype)shared {
    static WXRPrefs *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[WXRPrefs alloc] init];
        [shared reload];
    });
    return shared;
}

+ (NSDictionary *)defaults {
    return @{
        WXRKeyEnabled:            @NO,      // 默认不开，避免装上就开始自动回复
        WXRKeyPrivateOnly:        @YES,
        WXRKeyGroupMentionOnly:   @YES,
        WXRKeyCooldown:           @(15),
        WXRKeyDefaultReply:       @"我现在不在，稍后回复你。",
        WXRKeyRules:              @"# 一行一条规则，格式：关键词 => 回复内容\n# 例：在吗 => 在的，稍等我一下",

        WXRKeyAIEnabled:          @NO,
        WXRKeyAIBaseURL:          @"",
        WXRKeyAIAPIKey:           @"",
        WXRKeyAIModel:            @"",
        WXRKeyAISystemPrompt:     @"你是「我」本人（微信主人）的替身，用第一人称「我」直接回复，语气自然像真人聊天，简短（60 字以内）。绝不要承认或暗示自己是 AI、模型、机器人、助手、DeepSeek、ChatGPT、程序，也不要解释技术细节。被问「你是谁」「你是机器人吗」时，按人设自然回答（例如「我是本人啊，怎么了」）。",
        WXRKeyAIMaxLength:        @(120),
        WXRKeyAITemperature:      @(0.8),
        WXRKeyAIContextMessages:  @(6),

        WXRKeyMonitorEnabled:     @NO,
        WXRKeyMonitorKeywords:    @"在吗\n报价\n合作\n电话",
        WXRKeyMonitorForward:     @YES,
        WXRKeyMonitorRecord:      @YES,

        WXRKeyTabBarLongPress:    @YES,
        WXRKeyLoadedNotice:       @NO,
        WXRKeyVerboseLog:         @NO,
        WXRKeyLogContent:         @NO,
        WXRKeySendStrategy:       @(-1),
    };
}

+ (NSString *)configDirectory {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WXReply"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        dir = base;
    });
    return dir;
}

+ (NSString *)configPath {
    return [[self configDirectory] stringByAppendingPathComponent:@"config.plist"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)reload {
    NSMutableDictionary *merged = [[[self class] defaults] mutableCopy];
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:[[self class] configPath]];
    if (onDisk.count) {
        [merged addEntriesFromDictionary:onDisk];
    }
    // 老版本的默认提示词会让 AI 自称「我是 DeepSeek」；用户没改过就自动升级成新人设提示词
    static NSString *const oldPrompt = @"你是一个简洁、友好的中文聊天助手，回复控制在 60 字以内。";
    NSString *storedPrompt = merged[WXRKeyAISystemPrompt];
    if ([storedPrompt isEqualToString:oldPrompt]) {
        merged[WXRKeyAISystemPrompt] = [[self class] defaults][WXRKeyAISystemPrompt];
        WXRLog(@"[prefs] 已把默认 AI 提示词升级为「以本人身份回复」");
    }
    pthread_mutex_lock(&gPrefsLock);
    self.store = merged;
    pthread_mutex_unlock(&gPrefsLock);
}

- (NSDictionary *)allValues {
    pthread_mutex_lock(&gPrefsLock);
    NSDictionary *copy = [self.store copy];
    pthread_mutex_unlock(&gPrefsLock);
    return copy;
}

- (void)resetAll {
    pthread_mutex_lock(&gPrefsLock);
    self.store = [[[self class] defaults] mutableCopy];
    pthread_mutex_unlock(&gPrefsLock);
    [self persistAndNotify];
}

- (id)objectForKey:(NSString *)key {
    if (!key.length) {
        return nil;
    }
    pthread_mutex_lock(&gPrefsLock);
    id value = self.store[key];
    pthread_mutex_unlock(&gPrefsLock);
    return value;
}

- (NSString *)stringForKey:(NSString *)key {
    id value = [self objectForKey:key];
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    return value ? [value description] : nil;
}

- (BOOL)boolForKey:(NSString *)key {
    id value = [self objectForKey:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (NSInteger)integerForKey:(NSString *)key {
    id value = [self objectForKey:key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

- (double)doubleForKey:(NSString *)key {
    id value = [self objectForKey:key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (!key.length) {
        return;
    }
    pthread_mutex_lock(&gPrefsLock);
    if (value) {
        self.store[key] = value;
    } else {
        [self.store removeObjectForKey:key];
    }
    pthread_mutex_unlock(&gPrefsLock);
    [self persistAndNotify];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key         { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key     { [self setObject:@(value) forKey:key]; }

- (void)persistAndNotify {
    NSDictionary *values = [self allValues];
    NSString *path = [[self class] configPath];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (![values writeToFile:path atomically:YES]) {
            WXRLog(@"[prefs] 写入失败: %@", path);
        }
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:WXRPrefsChangedNotification object:nil];
    });
}

- (BOOL)boolEnabled          { return [self boolForKey:WXRKeyEnabled]; }
- (BOOL)boolAIEnabled        { return [self boolForKey:WXRKeyAIEnabled]; }
- (BOOL)boolVerbose          { return [self boolForKey:WXRKeyVerboseLog]; }
- (BOOL)boolLogContent       { return [self boolForKey:WXRKeyLogContent]; }
- (BOOL)boolTabBarLongPress  { return [self boolForKey:WXRKeyTabBarLongPress]; }

@end
