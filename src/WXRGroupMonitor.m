#import "WXRGroupMonitor.h"
#import "WXRCommon.h"
#import "WXRLog.h"
#import "WXRPrefs.h"
#import "WXRWeChat.h"
#import "WXRHook.h"

static NSMutableSet<NSString *> *gSeen = nil;      // 去重：群名 + 本地消息 id
static NSString *gLastHit = nil;                   // 最近一次命中的记录文本
static NSString *gLastGroupSession = nil;          // 最近一条群消息的群 id（诊断用）
static NSString *gLastSenderId = nil;              // 最近一条群消息的发送者 id（诊断用）
static NSInteger gHitCount = 0;
#define WXR_MONITOR_MAX_RECORDS 300

@implementation WXRGroupMonitor

/* ---------------- 记录文件 ---------------- */

+ (NSString *)recordPath {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *logPath = WXRLogFilePath();
        NSString *dir = logPath.length ? [logPath stringByDeletingLastPathComponent] : NSTemporaryDirectory();
        path = [dir stringByAppendingPathComponent:@"monitor_hits.log"];
    });
    return path;
}

+ (NSString *)timestampText {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"MM-dd HH:mm:ss";
    return [formatter stringFromDate:[NSDate date]];
}

+ (void)appendRecord:(NSString *)line {
    if (!line.length) {
        return;
    }
    NSString *path = [self recordPath];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (old.length) {
        [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];
    }
    [lines addObject:line];
    while ((NSInteger)lines.count > WXR_MONITOR_MAX_RECORDS) {
        [lines removeObjectAtIndex:0];
    }
    NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

+ (NSString *)recentHitsText {
    NSString *old = [NSString stringWithContentsOfFile:[self recordPath] encoding:NSUTF8StringEncoding error:NULL];
    if (!old.length) {
        return @"还没有命中记录。\n\n提示：打开「监控群消息关键词」，并在群聊里出现关键词时才会记录。";
    }
    NSArray<NSString *> *lines = [old componentsSeparatedByString:@"\n"];
    NSInteger limit = 100;
    NSInteger start = MAX(0, (NSInteger)lines.count - limit);
    NSMutableArray<NSString *> *tail = [NSMutableArray array];
    for (NSInteger i = start; i < (NSInteger)lines.count; i++) {
        if (lines[(NSUInteger)i].length) {
            [tail addObject:lines[(NSUInteger)i]];
        }
    }
    return [NSString stringWithFormat:@"最近 %lu 条命中记录：\n\n%@",
            (unsigned long)tail.count, [tail componentsJoinedByString:@"\n"]];
}

/* ---------------- 关键词 ---------------- */

+ (NSArray<NSString *> *)keywords {
    NSString *text = [[WXRPrefs shared] stringForKey:WXRKeyMonitorKeywords];
    if (!text.length) {
        return @[];
    }
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n\r,，;；"];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:separators]) {
        NSString *word = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (word.length && ![word hasPrefix:@"#"]) {
            [out addObject:word];
        }
    }
    return out;
}

// 匹配前把空白都去掉：消息里常见「苹果 14pro Max」这种写法，
// 关键词「苹果14」也应该命中（大小写也统一成小写）。
+ (NSString *)normalizedForMatch:(NSString *)text {
    if (!text.length) {
        return @"";
    }
    NSArray<NSString *> *parts =
        [text.lowercaseString componentsSeparatedByCharactersInSet:
         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *joined = [parts componentsJoinedByString:@""];
    return [joined stringByReplacingOccurrencesOfString:@"　" withString:@""];
}

+ (NSString *)matchedKeywordIn:(NSString *)content {
    NSString *normalized = [self normalizedForMatch:content];
    for (NSString *word in [self keywords]) {
        NSString *key = [self normalizedForMatch:word];
        if (key.length && [normalized rangeOfString:key].location != NSNotFound) {
            return word;
        }
    }
    return nil;
}

/* ---------------- 消息处理 ---------------- */

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSeen = [NSMutableSet set];
        [WXRWeChat addMessageHandler:^(id wrap) {
            [self handleWrap:wrap];
        }];
        WXRLog(@"[monitor] 群消息监控已装载（开关：%@，关键词 %lu 个，转发：%@，记录：%@）",
               [[WXRPrefs shared] boolForKey:WXRKeyMonitorEnabled] ? @"开" : @"关",
               (unsigned long)[self keywords].count,
               [[WXRPrefs shared] boolForKey:WXRKeyMonitorForward] ? @"开" : @"关",
               [[WXRPrefs shared] boolForKey:WXRKeyMonitorRecord] ? @"开" : @"关");
    });
}

+ (void)handleWrap:(id)wrap {
    WXRPrefs *prefs = [WXRPrefs shared];
    if (![prefs boolForKey:WXRKeyMonitorEnabled]) {
        return;
    }
    if ([WXRWeChat isSystemWrap:wrap]) {
        return;
    }
    NSString *session = [WXRWeChat sessionOfWrap:wrap];
    if (![WXRWeChat isGroupSession:session]) {
        return;      // 只监控群消息
    }
    NSString *content = [WXRWeChat contentOfWrap:wrap];
    if (!content.length || [content hasPrefix:@"<"]) {
        return;
    }
    NSString *sender = [WXRWeChat fromOfWrap:wrap];
    NSString *senderId = [WXRWeChat actualSenderOfWrap:wrap];
    if (!senderId.length) {
        senderId = sender;      // 取不到真实发送者时的兜底
    }
    // 注意：这里【不】跳过自己发的群消息 ——
    //   1) 自己发消息测试是最方便的方式，跳过会让功能看起来"失效"；
    //   2) 转发目标是私聊（自己），不会回到群消息管线，所以没有循环风险。
    NSInteger localID = [WXRWeChat localIDOfWrap:wrap];
    NSString *dedupeKey = [NSString stringWithFormat:@"%@#%ld", session ?: @"", (long)localID];
    @synchronized (gSeen) {
        if ([gSeen containsObject:dedupeKey]) {
            return;
        }
        [gSeen addObject:dedupeKey];
        if (gSeen.count > 500) {
            [gSeen removeAllObjects];
        }
    }
    gLastGroupSession = [session copy];
    gLastSenderId = [senderId copy];
    NSString *hit = [self matchedKeywordIn:content];
    if (!hit.length) {
        WXRLogVerbose(@"[monitor] 群消息未命中：群=%@ 发送者=%@ 内容=%@",
                      session ?: @"?", senderId ?: @"?", content);
        return;
    }

    // 名字解析 + 记录 + 转发都放到主线程做；微信刚启动时通讯录服务可能还没就绪，
    // 解析不到会自动重试几次，避免把「群名/昵称」永久显示成 ID。
    [self deliverReminderForSession:session senderId:senderId content:content hit:hit wrap:wrap attempt:0];
}

+ (void)deliverReminderForSession:(NSString *)session
                         senderId:(NSString *)senderId
                          content:(NSString *)content
                              hit:(NSString *)hit
                             wrap:(id)wrap
                          attempt:(NSInteger)attempt {
    void (^work)(void) = ^{
        WXRPrefs *prefs = [WXRPrefs shared];
        NSString *senderName = [self cachedNameForUser:senderId];
        if (!senderName.length) {
            id pushTitle = WXRValueAny(wrap, @[@"m_nsPushTitle", @"m_nsDisplayName"]);
            if ([pushTitle isKindOfClass:[NSString class]] && [pushTitle length]) {
                senderName = (NSString *)pushTitle;
            }
        }
        NSString *groupName = [self cachedNameForUser:session];
        // 微信刚启动时通讯录服务可能几十秒才就绪：先退避重试几次（总共约 5 秒）
        if ((!groupName.length || !senderName.length) && attempt < 5) {
            double delay = 0.3 * (double)(1 << attempt);      // 0.3 / 0.6 / 1.2 / 2.4
            WXRLogVerbose(@"[monitor] 名字还没解析出来（第 %ld 次尝试），%.1fs 后重试",
                          (long)attempt + 1, delay);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self deliverReminderForSession:session senderId:senderId content:content
                                            hit:hit wrap:wrap attempt:attempt + 1];
            });
            return;
        }
        // 仍然解析不到：这次就先用 ID 发出去，但把名字缓存偷偷预热，
        // 这样后面几条提醒就能显示群名/昵称了
        if (!groupName.length) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self cachedNameForUser:session];
            });
        }
        if (!senderName.length) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self cachedNameForUser:senderId];
            });
        }
        if (!senderName.length) {
            senderName = senderId ?: @"?";
        }
        NSString *groupText = groupName.length
            ? [NSString stringWithFormat:@"%@（%@）", groupName, session]
            : (session ?: @"?");
        NSString *senderText = (senderId.length && ![senderName isEqualToString:senderId])
            ? [NSString stringWithFormat:@"%@（%@）", senderName, senderId]
            : (senderName ?: @"?");
        WXRLog(@"[monitor] 名字解析：群「%@」→「%@」；发送者「%@」→「%@」",
               session ?: @"?", groupName ?: @"(未解析)", senderId ?: @"?", senderName ?: @"(未解析)");
        if (!groupName.length) {
            id manager = [WXRWeChat contactManager];
            id contact = manager ? WXRCall1(manager, @"getContactByName:", session) : nil;
            WXRLog(@"[monitor] 群名解析失败原因：contactManager=%@，getContactByName=%@，群=%@",
                   manager ? @"有" : @"nil", contact ? @"有" : @"nil", session ?: @"?");
        }
        NSString *line = [NSString stringWithFormat:@"%@ 群=%@ 发送者=%@ 关键词=%@ 内容=%@",
                          [self timestampText], groupText, senderText, hit, content];
        gLastHit = line;
        gHitCount++;
        WXRLog(@"[monitor] 命中关键词「%@」：%@", hit, line);
        if ([prefs boolForKey:WXRKeyMonitorRecord]) {
            [self appendRecord:line];
        }
        if ([prefs boolForKey:WXRKeyMonitorForward]) {
            NSString *shortContent = content.length > 400 ? [content substringToIndex:400] : content;
            NSString *text = [NSString stringWithFormat:
                              @"【群关键词提醒】\n群：%@\n发送者：%@\n关键词：%@\n时间：%@\n内容：%@",
                              groupText, senderText, hit, [self timestampText], shortContent];
            BOOL sent = [WXRWeChat sendText:text toSession:[WXRWeChat selfUserName]];
            WXRLog(@"[monitor] 转发给自己：%@", sent ? @"已调用发送" : @"没有可用的发送接口");
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

// 通讯录查名字比较贵，缓存一下（同一个群/好友多次命中时只查一次）
+ (NSString *)cachedNameForUser:(NSString *)userName {
    if (!userName.length) {
        return nil;
    }
    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    @synchronized (cache) {
        NSString *cached = cache[userName];
        if (cached.length) {
            return cached;
        }
    }
    NSString *name = [WXRWeChat displayNameForUser:userName];
    if (name.length) {
        @synchronized (cache) {
            if (cache.count > 800) {
                [cache removeAllObjects];
            }
            cache[userName] = name;
        }
    }
    return name;
}

/// 自检文本：一眼看出监控为什么没触发
+ (NSString *)diagnosticText {
    WXRPrefs *prefs = [WXRPrefs shared];
    NSArray<NSString *> *words = [self keywords];
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"监控开关：%@\n", [prefs boolForKey:WXRKeyMonitorEnabled] ? @"开" : @"关（这是最常见的失效原因）"];
    [text appendFormat:@"命中后转发：%@\n", [prefs boolForKey:WXRKeyMonitorForward] ? @"开" : @"关"];
    [text appendFormat:@"记录命中：%@\n", [prefs boolForKey:WXRKeyMonitorRecord] ? @"开" : @"关"];
    [text appendFormat:@"关键词 %lu 个：%@\n", (unsigned long)words.count,
     words.count ? [words componentsJoinedByString:@" / "] : @"（空！请在设置里填关键词）"];
    [text appendFormat:@"消息管线已挂上：%@\n", [WXRWeChat messageHooksInstalled] ? @"是" : @"否（重启微信试试）"];
    [text appendFormat:@"消息服务：%@\n", [WXRWeChat messageManager] ? @"已获取" : @"还没获取到（等收到一条消息后会自动获取）"];
    [text appendFormat:@"自己身份：%@\n", [WXRWeChat selfUserName] ?: @"未解析"];
    [text appendFormat:@"本次命中次数：%ld\n", (long)gHitCount];
    [text appendString:@"\n最近一次命中：\n"];
    [text appendString:gLastHit.length ? gLastHit : @"（还没有命中过）"];
    [text appendString:@"\n\n提示：命中时日志里会有 [monitor] 开头的行；打开「详细日志」还能看到每条群消息是否命中。"];
    return text;
}

/// 名字解析诊断（只读）：把这段发回给维护者，就能把群名/昵称补全
+ (NSString *)nameResolutionDiagnostic {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"===== 服务获取诊断 =====\n"];
    [text appendString:[WXRWeChat serviceDiagnosticText]];
    [text appendString:@"\n===== 名字解析 =====\n"];
    [text appendFormat:@"最近一条群消息：\n  群 = %@\n  发送者 = %@\n\n",
     gLastGroupSession ?: @"(还没收到过群消息)", gLastSenderId ?: @"(无)"];
    // 直接用插件自己的解析逻辑算一遍：这里显示的名字，就是提醒里会用的名字
    [text appendFormat:@"解析结果（提醒里就显示这个）：\n  群 → %@\n  发送者 → %@\n\n",
     [WXRWeChat displayNameForUser:gLastGroupSession] ?: @"(未解析)",
     [WXRWeChat displayNameForUser:gLastSenderId] ?: @"(未解析)"];
    [text appendString:[WXRWeChat describeContactForUser:gLastGroupSession]];
    [text appendString:@"\n"];
    [text appendString:[WXRWeChat describeContactForUser:gLastSenderId]];
    [text appendString:@"\n===== 候选方法 =====\n"];
    [text appendString:[WXRWeChat methodNamesOfClass:@"CContactMgr" containing:@"contact"]];
    [text appendString:@"\n"];
    [text appendString:[WXRWeChat methodNamesOfClass:@"CContactMgr" containing:@"name"]];
    [text appendString:@"\n"];
    [text appendString:[WXRWeChat methodNamesOfClass:@"CGroupMgr" containing:@"group"]];
    [text appendString:@"\n"];
    [text appendString:[WXRWeChat methodNamesOfClass:@"CGroupMgr" containing:@"name"]];
    return text;
}

+ (void)testForwardLastHit {
    NSString *selfName = [WXRWeChat selfUserName];
    NSString *text = gLastHit.length
        ? [NSString stringWithFormat:@"【转发测试】最近一次命中：\n%@", gLastHit]
        : @"【转发测试】群监控已就绪（还没有命中过关键词）";
    BOOL sent = [WXRWeChat sendText:text toSession:selfName ?: @""];
    WXRLog(@"[monitor] 转发测试 → 自己：%@", sent ? @"已调用发送" : @"没有可用的发送接口");
}

+ (NSString *)statusLine {
    NSString *old = [NSString stringWithContentsOfFile:[self recordPath] encoding:NSUTF8StringEncoding error:NULL];
    NSArray<NSString *> *recordLines = old.length ? [old componentsSeparatedByString:@"\n"] : @[];
    NSInteger recorded = (NSInteger)recordLines.count;
    WXRPrefs *prefs = [WXRPrefs shared];
    return [NSString stringWithFormat:@"%@ · 关键词 %lu 个 · 本次命中 %ld 次 · 记录 %ld 条 · 最近：%@",
            [prefs boolForKey:WXRKeyMonitorEnabled] ? @"监控已开启" : @"监控未开启",
            (unsigned long)[self keywords].count, (long)gHitCount, (long)recorded,
            gLastHit.length ? gLastHit : @"还没命中过"];
}

@end
