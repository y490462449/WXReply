#import "WXROverrides.h"
#import "WXRCommon.h"
#import "WXRPrefs.h"
#import "WXRLog.h"

@implementation WXROverrides

+ (NSDictionary<NSString *, NSString *> *)supportedKeys {
    static NSDictionary *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @{
            @"servicecenter": @"服务总线类名（MMServiceCenter）",
            @"servicecenterinit": @"服务总线单例方法（defaultCenter 等）",
            @"msgclass": @"消息服务类名（CMessageMgr 等）",
            @"incoming": @"收消息回调 selector（AsyncOnAddMsg:MsgWrap: 等）",
            @"sendmsg": @"发消息 selector（收 MsgWrap）",
            @"sendtext": @"发消息 selector（收文本 + 会话）",
            @"contactclass": @"通讯录服务类名（CContactMgr 等）",
            @"content": @"消息正文 ivar 名",
            @"type": @"消息类型 ivar 名",
            @"from": @"发送者 ivar 名",
            @"to": @"接收者 ivar 名",
            @"svrid": @"服务端消息 id ivar 名",
            @"localid": @"本地消息 id ivar 名",
            @"msgsource": @"消息来源 XML ivar 名",
        };
    });
    return keys;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)storedMap {
    id stored = [[WXRPrefs shared] objectForKey:WXRKeyOverrideMap];
    if ([stored isKindOfClass:[NSDictionary class]]) {
        return stored;
    }
    return @{};
}

+ (NSArray<NSString *> *)namesForKey:(NSString *)key {
    if (!key.length) {
        return @[];
    }
    id value = [self storedMap][key];
    if ([value isKindOfClass:[NSArray class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]] && [value length]) {
        return @[value];
    }
    return @[];
}

+ (NSArray<NSString *> *)mergeKey:(NSString *)key fallback:(NSArray<NSString *> *)fallback {
    NSArray<NSString *> *user = [self namesForKey:key];
    if (!user.count) {
        return fallback ?: @[];
    }
    NSMutableArray<NSString *> *merged = [NSMutableArray arrayWithArray:user];
    for (NSString *name in (fallback ?: @[])) {
        if (![merged containsObject:name]) {
            [merged addObject:name];
        }
    }
    return merged;
}

+ (NSString *)rawText {
    NSString *text = [[WXRPrefs shared] stringForKey:WXRKeyOverrideText];
    return text ?: @"";
}

+ (NSInteger)overrideCount {
    return (NSInteger)[self storedMap].count;
}

+ (BOOL)applyText:(NSString *)text error:(NSString **)error {
    NSDictionary<NSString *, NSString *> *supported = [self supportedKeys];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *parsed = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *badLines = [NSMutableArray array];

    NSArray<NSString *> *lines = [(text ?: @"") componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length || [line hasPrefix:@"#"] || [line hasPrefix:@"//"]) {
            continue;
        }
        NSRange separator = [line rangeOfString:@"="];
        if (separator.location == NSNotFound) {
            separator = [line rangeOfString:@":"];
        }
        // 注意：selector 本身含冒号，所以"键:值"这种写法不可靠，优先用 =
        if (separator.location == NSNotFound) {
            [badLines addObject:line];
            continue;
        }
        NSString *key = [[line substringToIndex:separator.location]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *valuePart = [[line substringFromIndex:separator.location + 1]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!key.length || !valuePart.length) {
            [badLines addObject:line];
            continue;
        }
        if (!supported[key]) {
            [badLines addObject:[NSString stringWithFormat:@"%@（未知的键）", line]];
            continue;
        }
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *piece in [valuePart componentsSeparatedByString:@","]) {
            NSString *name = [piece stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            name = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
            if (name.length && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
        if (!names.count) {
            [badLines addObject:line];
            continue;
        }
        parsed[key] = names;
    }

    if (badLines.count) {
        if (error) {
            *error = [NSString stringWithFormat:@"这些行无法识别：\n%@\n\n支持的键：\n%@",
                      [badLines componentsJoinedByString:@"\n"],
                      [[supported.allKeys sortedArrayUsingSelector:@selector(compare:)]
                       componentsJoinedByString:@", "]];
        }
        return NO;
    }

    WXRPrefs *prefs = [WXRPrefs shared];
    [prefs setObject:(text ?: @"") forKey:WXRKeyOverrideText];
    [prefs setObject:[parsed copy] forKey:WXRKeyOverrideMap];
    WXRLog(@"[override] 已保存 %lu 条候选名覆盖", (unsigned long)parsed.count);
    return YES;
}

+ (NSString *)summary {
    NSInteger count = [self overrideCount];
    if (!count) {
        return @"未使用候选名覆盖（全部走内置候选）";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSDictionary<NSString *, NSArray<NSString *> *> *map = [self storedMap];
    for (NSString *key in [map.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, [map[key] componentsJoinedByString:@","]]];
    }
    return [NSString stringWithFormat:@"已覆盖 %ld 项：%@", (long)count, [parts componentsJoinedByString:@"  "]];
}

@end
