#import "WXRAutoReply.h"
#import "WXRWeChat.h"
#import "WXRPrefs.h"
#import "WXRLog.h"
#import "WXRCommon.h"

#define WXR_CONTEXT_MAX 100

static NSMutableDictionary<NSString *, NSNumber *> *gLastReplyAt = nil;  // 会话 -> 上次回复时间
static NSMutableSet<NSString *> *gPending = nil;                         // 正在生成回复的会话
static NSMutableArray<NSString *> *gSentContents = nil;                  // 自己发出过的内容（防自问自答）
static NSMutableArray<NSDictionary *> *gRecent = nil;                    // 最近消息（给 AI 当上下文）
static NSString *gLastStatus = @"还没触发过";

@implementation WXRAutoReply

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLastReplyAt = [NSMutableDictionary dictionary];
        gPending = [NSMutableSet set];
        gSentContents = [NSMutableArray array];
        gRecent = [NSMutableArray array];
        [WXRWeChat addMessageHandler:^(id wrap) {
            [self handleWrap:wrap];
        }];
        WXRLog(@"[reply] 自动回复已装载（当前开关：%@）",
               [WXRPrefs shared].boolEnabled ? @"开" : @"关");
    });
}

+ (NSString *)statusLine {
    WXRPrefs *prefs = [WXRPrefs shared];
    NSInteger ruleCount = [self parsedRules].count;
    NSString *ai = prefs.boolAIEnabled ? @"开" : @"关";
    return [NSString stringWithFormat:@"%@ · 规则 %ld 条 · AI %@ · %@ · 最近：%@",
            prefs.boolEnabled ? @"已开启" : @"未开启", (long)ruleCount, ai, WXR_BUILD_STAMP, gLastStatus];
}

+ (void)clearCooldown {
    @synchronized (gLastReplyAt) {
        [gLastReplyAt removeAllObjects];
    }
    gLastStatus = @"已清空冷却";
    WXRLog(@"[reply] 已清空会话冷却");
}

+ (void)handleWrap:(id)wrap {
    WXRPrefs *prefs = [WXRPrefs shared];
    if (!prefs.boolEnabled) {
        return;
    }
    if ([WXRWeChat isSystemWrap:wrap]) {
        return;
    }

    NSString *content = [WXRWeChat contentOfWrap:wrap];
    if (!content.length || [content hasPrefix:@"<"]) {
        return;   // 空内容或 XML（系统/卡片）
    }
    NSInteger type = [WXRWeChat typeOfWrap:wrap];
    if (type != 0 && type != 1) {
        WXRLogVerbose(@"[reply] 跳过非文本消息 type=%ld", (long)type);
        return;
    }

    NSString *session = [WXRWeChat sessionOfWrap:wrap];
    NSString *sender = [WXRWeChat actualSenderOfWrap:wrap];
    NSString *selfName = [WXRWeChat selfUserName];
    BOOL outgoing = selfName.length && [sender isEqualToString:selfName];

    [self rememberSession:session content:content sender:sender outgoing:outgoing];

    if (outgoing) {
        return;
    }
    if (!session.length) {
        return;
    }

    // 跳过自己刚发出去的内容（有的版本会把本机发送也回灌到回调里）
    @synchronized (gSentContents) {
        if ([gSentContents containsObject:content]) {
            [gSentContents removeObject:content];
            WXRLogVerbose(@"[reply] 忽略自己刚发出的内容");
            return;
        }
    }

    BOOL isGroup = [WXRWeChat isGroupSession:session];
    if ([prefs boolForKey:WXRKeyPrivateOnly] && isGroup) {
        WXRLogVerbose(@"[reply] 设置里只回私聊，群聊跳过");
        return;
    }
    if (isGroup && [prefs boolForKey:WXRKeyGroupMentionOnly] && ![self isMentioned:wrap content:content]) {
        WXRLogVerbose(@"[reply] 群里没 @我，跳过");
        return;
    }

    NSInteger cooldown = MAX(0, [prefs integerForKey:WXRKeyCooldown]);
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (gLastReplyAt) {
        NSNumber *last = gLastReplyAt[session];
        if (last && cooldown > 0 && now - last.doubleValue < cooldown) {
            WXRLogVerbose(@"[reply] %@ 还在冷却（剩 %.0fs）", session, cooldown - (now - last.doubleValue));
            return;
        }
    }
    @synchronized (gPending) {
        if ([gPending containsObject:session]) {
            WXRLogVerbose(@"[reply] %@ 上一条还在处理", session);
            return;
        }
        [gPending addObject:session];
    }

    WXRLog(@"[reply] 触发自动回复：会话=%@ 群=%@ 内容=%@", session, isGroup ? @"是" : @"否",
           prefs.boolLogContent ? content : [NSString stringWithFormat:@"<%lu 字>", (unsigned long)content.length]);

    BOOL useAI = prefs.boolAIEnabled
        && [prefs stringForKey:WXRKeyAIBaseURL].length
        && [prefs stringForKey:WXRKeyAIAPIKey].length
        && [prefs stringForKey:WXRKeyAIModel].length;

    if (useAI) {
        [self requestAIReplyForSession:session text:content completion:^(NSString *reply, NSString *error) {
            @synchronized (gPending) {
                [gPending removeObject:session];
            }
            if (!reply.length) {
                gLastStatus = error ?: @"AI 没有返回内容";
                WXRLog(@"[reply] AI 生成失败：%@", gLastStatus);
                return;
            }
            [self deliverReply:reply toSession:session];
        }];
        return;
    }

    NSString *rule = [self ruleReplyFor:content];
    NSString *fixed = rule.length ? rule : [prefs stringForKey:WXRKeyDefaultReply];
    @synchronized (gPending) {
        [gPending removeObject:session];
    }
    if (!fixed.length) {
        gLastStatus = @"没有可用的回复内容（规则未命中且默认回复为空）";
        WXRLog(@"[reply] %@", gLastStatus);
        return;
    }
    [self deliverReply:fixed toSession:session];
}

+ (void)deliverReply:(NSString *)reply toSession:(NSString *)session {
    @synchronized (gLastReplyAt) {
        gLastReplyAt[session] = @([[NSDate date] timeIntervalSince1970]);
    }
    gLastStatus = [NSString stringWithFormat:@"已回复：%@", reply];
    // 稍等一小会儿再发，避免和微信自身的消息处理抢时序
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (gSentContents) {
            [gSentContents addObject:reply];
            while (gSentContents.count > 20) {
                [gSentContents removeObjectAtIndex:0];
            }
        }
        if ([WXRWeChat sendText:reply toSession:session]) {
            WXRLog(@"[reply] 已调用发送接口（会话=%@）：%@", session, reply);
        } else {
            gLastStatus = @"生成了回复但没找到可用的发送接口（见日志 [send] 行）";
            WXRLog(@"[reply] 发送失败，内容：%@", reply);
        }
    });
}

/* ---------------- 关键词规则 ---------------- */

+ (NSArray<NSArray<NSString *> *> *)parsedRules {
    NSMutableArray<NSArray<NSString *> *> *rules = [NSMutableArray array];
    NSString *text = [[WXRPrefs shared] stringForKey:WXRKeyRules];
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length || [line hasPrefix:@"#"]) {
            continue;
        }
        NSRange sep = [line rangeOfString:@"=>"];
        if (sep.location == NSNotFound) {
            sep = [line rangeOfString:@"="];
        }
        if (sep.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:sep.location]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:sep.location + sep.length]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (key.length && value.length) {
            [rules addObject:@[key, value]];
        }
    }
    return rules;
}

+ (NSString *)ruleReplyFor:(NSString *)text {
    for (NSArray<NSString *> *rule in [self parsedRules]) {
        if ([text rangeOfString:rule[0]].location != NSNotFound) {
            return rule[1];
        }
    }
    return nil;
}

/* ---------------- 群聊 @我 判断 ---------------- */

+ (BOOL)isMentioned:(id)wrap content:(NSString *)content {
    NSString *source = [WXRWeChat msgSourceOfWrap:wrap] ?: @"";
    NSString *selfName = [WXRWeChat selfUserName];
    if (selfName.length && [source containsString:selfName]) {
        return YES;
    }
    NSString *display = [WXRWeChat selfDisplayName];
    if (display.length && [content containsString:[@"@" stringByAppendingString:display]]) {
        return YES;
    }
    return NO;   // "@所有人" 不算，避免刷屏
}

/* ---------------- 上下文（给 AI 用） ---------------- */

+ (void)rememberSession:(NSString *)session content:(NSString *)content
                 sender:(NSString *)sender outgoing:(BOOL)outgoing {
    if (!content.length) {
        return;
    }
    NSDictionary *item = @{@"session": session ?: @"", @"content": content,
                           @"sender": sender ?: @"", @"outgoing": @(outgoing),
                           @"time": @([[NSDate date] timeIntervalSince1970])};
    @synchronized (gRecent) {
        [gRecent addObject:item];
        while (gRecent.count > WXR_CONTEXT_MAX) {
            [gRecent removeObjectAtIndex:0];
        }
    }
}

+ (NSArray<NSDictionary *> *)recentForSession:(NSString *)session limit:(NSInteger)limit {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    @synchronized (gRecent) {
        for (NSDictionary *item in gRecent.reverseObjectEnumerator) {
            if (session.length && ![item[@"session"] isEqualToString:session]) {
                continue;
            }
            [out insertObject:item atIndex:0];
            if ((NSInteger)out.count >= limit) {
                break;
            }
        }
    }
    return out;
}

/* ---------------- AI（OpenAI 兼容） ---------------- */

+ (NSURL *)endpointURL {
    NSString *base = [[WXRPrefs shared] stringForKey:WXRKeyAIBaseURL];
    base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!base.length) {
        return nil;
    }
    if ([base hasSuffix:@"/chat/completions"]) {
        return [NSURL URLWithString:base];
    }
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length - 1];
    }
    return [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
}

+ (void)requestAIReplyForSession:(NSString *)session
                            text:(NSString *)text
                      completion:(void (^)(NSString *reply, NSString *error))completion {
    WXRPrefs *prefs = [WXRPrefs shared];
    NSURL *url = [self endpointURL];
    NSString *key = [prefs stringForKey:WXRKeyAIAPIKey];
    NSString *model = [prefs stringForKey:WXRKeyAIModel];
    if (!url || !key.length || !model.length) {
        completion(nil, @"AI 配置不完整（Base URL / API Key / 模型名）");
        return;
    }

    NSMutableArray *messages = [NSMutableArray array];
    NSString *systemPrompt = [prefs stringForKey:WXRKeyAISystemPrompt];
    if (systemPrompt.length) {
        [messages addObject:@{@"role": @"system", @"content": systemPrompt}];
    }
    NSInteger contextCount = MAX(1, MIN(30, [prefs integerForKey:WXRKeyAIContextMessages]));
    for (NSDictionary *item in [self recentForSession:session limit:contextCount]) {
        NSString *content = item[@"content"];
        if (!content.length || [content hasPrefix:@"<"]) {
            continue;
        }
        [messages addObject:@{@"role": [item[@"outgoing"] boolValue] ? @"assistant" : @"user",
                              @"content": content}];
    }
    if (!messages.count || ![messages.lastObject[@"content"] isEqualToString:text]) {
        [messages addObject:@{@"role": @"user", @"content": text}];
    }

    NSInteger maxLength = MAX(32, MIN(2000, [prefs integerForKey:WXRKeyAIMaxLength]));
    NSDictionary *body = @{@"model": model,
                           @"messages": messages,
                           @"temperature": @([prefs doubleForKey:WXRKeyAITemperature]),
                           @"max_tokens": @(maxLength),
                           @"stream": @NO};

    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!payload) {
        completion(nil, @"请求体序列化失败");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = payload;

    WXRLog(@"[reply] POST %@ model=%@ 上下文=%lu 条", url.absoluteString, model, (unsigned long)messages.count);

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, [NSString stringWithFormat:@"网络错误：%@", error.localizedDescription]);
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *replyText = [self textFromResponseJSON:json];
        if (status / 100 != 2 || !replyText.length) {
            NSString *detail = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                detail = json[@"error"][@"message"] ?: json[@"message"];
            }
            completion(nil, [NSString stringWithFormat:@"HTTP %ld %@", (long)status, detail ?: @""]);
            return;
        }
        completion(replyText, nil);
    }] resume];
}

+ (NSString *)textFromResponseJSON:(id)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id choices = json[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || ![choices count]) {
        return nil;
    }
    id first = [choices firstObject];
    if (![first isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id message = first[@"message"];
    NSString *text = nil;
    if ([message isKindOfClass:[NSDictionary class]]) {
        text = message[@"content"];
    } else if ([first[@"text"] isKindOfClass:[NSString class]]) {
        text = first[@"text"];
    }
    if (![text isKindOfClass:[NSString class]]) {
        return nil;
    }
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length ? text : nil;
}

+ (void)testAIConnection:(void (^)(BOOL, NSString *))completion {
    WXRPrefs *prefs = [WXRPrefs shared];
    NSURL *url = [self endpointURL];
    NSString *key = [prefs stringForKey:WXRKeyAIAPIKey];
    NSString *model = [prefs stringForKey:WXRKeyAIModel];
    if (!url || !key.length || !model.length) {
        completion(NO, @"配置不完整：Base URL / API Key / 模型名都要填");
        return;
    }
    NSDictionary *body = @{@"model": model,
                           @"messages": @[@{@"role": @"user", @"content": @"回复两个字：可用"}],
                           @"max_tokens": @(16),
                           @"stream": @NO};
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(NO, [NSString stringWithFormat:@"网络错误：%@", error.localizedDescription]);
            return;
        }
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *text = [self textFromResponseJSON:json];
        if (status / 100 == 2 && text.length) {
            completion(YES, [NSString stringWithFormat:@"连接正常，模型回复：%@", text]);
        } else {
            completion(NO, [NSString stringWithFormat:@"HTTP %ld %@", (long)status,
                            text ?: [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""]);
        }
    }] resume];
}

@end
