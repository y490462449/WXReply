#import "WXRWeChat.h"
#import "WXRHook.h"
#import "WXRLog.h"
#import "WXRPrefs.h"
#import "WXRCommon.h"
#import "WXROverrides.h"
#import <objc/runtime.h>
/* ============================================================
   候选名字表：微信改版时只需要在这里补名字，不用改逻辑。
   设置页里粘一段"候选名覆盖"文本可以覆盖这里的值（用户在前、内置在后），
   这样在未越狱环境里适配新版本不必重新编译注入。
   ============================================================ */

static NSArray<NSString *> *WXRServiceCenterClasses(void) {
    return [WXROverrides mergeKey:@"servicecenter"
                         fallback:@[@"MMServiceCenter", @"MMServiceCenterLogic", @"ServiceCenter"]];
}
static NSArray<NSString *> *WXRServiceCenterSingletonSelectors(void) {
    return [WXROverrides mergeKey:@"servicecenterinit"
                         fallback:@[@"defaultCenter", @"sharedInstance", @"sharedServiceCenter",
                                    @"sharedCenter", @"center"]];
}
static NSArray<NSString *> *WXRMessageManagerClasses(void) {
    return [WXROverrides mergeKey:@"msgclass"
                         fallback:@[@"CMessageMgr", @"MessageService", @"MessageMgr",
                                    @"MMMsgLogicMgr", @"CMessageService"]];
}
static NSArray<NSString *> *WXRContactManagerClasses(void) {
    return [WXROverrides mergeKey:@"contactclass"
                         fallback:@[@"CContactMgr", @"ContactService", @"CContactService"]];
}
static NSArray<NSString *> *WXRGroupManagerClasses(void) {
    return @[@"CGroupMgr", @"GroupService", @"CGroupService"];
}

// 新消息回调（2 参数形式，MsgWrap 为第 2 个参数）
static NSArray<NSString *> *WXRIncomingMessageSelectors(void) {
    return [WXROverrides mergeKey:@"incoming"
                         fallback:@[@"AsyncOnAddMsg:MsgWrap:",
                                    @"OnAddMsg:MsgWrap:",
                                    @"onAddMsg:MsgWrap:",
                                    @"AddMsg:MsgWrap:",
                                    @"AsyncOnAddMsg:MsgWrap:Ext:",
                                    @"OnAddMsg:MsgWrap:Ext:"]];
}

static NSArray<NSString *> *WXRSendMsgSelectors(void) {
    return [WXROverrides mergeKey:@"sendmsg"
                         fallback:@[@"SendMsg:", @"AsyncSendMsg:", @"sendMsg:",
                                    @"SendMessage:", @"AsyncSendMessage:"]];
}
// 直接发文本（(text, session) 或 (session, text) 两种顺序都试）
static NSArray<NSString *> *WXRSendTextSelectors(void) {
    return [WXROverrides mergeKey:@"sendtext"
                         fallback:@[@"AsyncSendTextMsg:toSession:",
                                    @"SendTextMsg:toSession:",
                                    @"SendTextMessage:ToSession:",
                                    @"sendText:toSession:",
                                    @"SendTextMessage:toUser:",
                                    @"AsyncSendText:ToSession:"]];
}

/* ---------------- 字段候选 ---------------- */
static NSArray<NSString *> *WXRContentKeys(void) {
    return [WXROverrides mergeKey:@"content" fallback:@[@"m_nsContent", @"nsContent", @"content"]];
}
static NSArray<NSString *> *WXRTypeKeys(void) {
    return [WXROverrides mergeKey:@"type" fallback:@[@"m_uiMessageType", @"uiMessageType",
                                                      @"m_nMessageType", @"messageType"]];
}
static NSArray<NSString *> *WXRFromKeys(void) {
    return [WXROverrides mergeKey:@"from" fallback:@[@"m_nsFromUsr", @"nsFromUsr",
                                                     @"fromUsr", @"m_nsFromUserName"]];
}
static NSArray<NSString *> *WXRToKeys(void) {
    return [WXROverrides mergeKey:@"to" fallback:@[@"m_nsToUsr", @"nsToUsr", @"toUsr"]];
}
static NSArray<NSString *> *WXRMsgSourceKeys(void) {
    return [WXROverrides mergeKey:@"msgsource" fallback:@[@"m_nsMsgSource", @"nsMsgSource", @"msgSource"]];
}
static NSArray<NSString *> *WXRSvrIdKeys(void) {
    return [WXROverrides mergeKey:@"svrid" fallback:@[@"m_n64MesSvrID", @"m_n64MesSvrId",
                                                      @"m_uiMesSvrID", @"m_nMesSvrID"]];
}
static NSArray<NSString *> *WXRLocalIdKeys(void) {
    return [WXROverrides mergeKey:@"localid" fallback:@[@"m_uiMesLocalID", @"m_nMesLocalID",
                                                        @"m_uiMesLocalId"]];
}
static NSArray<NSString *> *WXRTimeKeys(void) {
    return @[@"m_uiCreateTime", @"m_nCreateTime", @"m_uiCreateTime"];
}

/* ============================================================ */

@interface WXRWeChat ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *serviceCache;
@property (nonatomic, copy) NSString *selfUserName;
@property (nonatomic, copy) NSString *selfDisplayName;
@property (nonatomic, strong) NSMutableArray<WXRMessageHandler> *handlers;
@property (nonatomic, assign) BOOL hooksInstalled;

- (id)serviceCenter;            // 惰性 + 限流重试
- (void)resolveSelfIdentity;    // 惰性解析"我是谁"
@end

@implementation WXRWeChat

+ (instancetype)shared {
    static WXRWeChat *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[WXRWeChat alloc] init];
        shared.serviceCache = [NSMutableDictionary dictionary];
        shared.handlers = [NSMutableArray array];
    });
    return shared;
}

+ (void)start {
    WXRLog(@"[bridge] 宿主=%@ 微信=%@（服务对象在收到消息时惰性获取）",
           [[NSProcessInfo processInfo] processName],
           [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
}

// 取 MMServiceCenter 单例。
// 注意：微信启动早期这个单例还不存在，所以「取不到」绝不能缓存成永久失败，
// 否则整个插件会一直拿不到服务；这里做 2 秒一次的限流重试。
- (id)serviceCenter {
    @synchronized (self.serviceCache) {
        id cached = self.serviceCache[@"__center"];
        if (cached && cached != [NSNull null]) {
            return cached;
        }
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSNumber *lastAttempt = self.serviceCache[@"__centerRetryAt"];
        if (lastAttempt && now - lastAttempt.doubleValue < 2.0) {
            return nil;
        }
        self.serviceCache[@"__centerRetryAt"] = @(now);
    }

    id center = nil;
    for (NSString *clsName in WXRServiceCenterClasses()) {
        for (NSString *sel in WXRServiceCenterSingletonSelectors()) {
            center = WXRCallClass(clsName, sel);
            if (center) {
                WXRLog(@"[bridge] 服务中心 = %@ -%@", clsName, sel);
                break;
            }
        }
        if (center) break;
    }
    if (center) {
        @synchronized (self.serviceCache) {
            self.serviceCache[@"__center"] = center;
        }
    } else {
        WXRLogVerbose(@"[bridge] MMServiceCenter 暂不可用，稍后自动重试");
    }
    return center;
}

// 解析"我是谁"：群聊 @我 判断、以及区分自己发的消息都要用
- (void)resolveSelfIdentity {
    if (self.selfUserName.length) {
        return;
    }
    id contact = [[self class] contactManager];
    if (!contact) {
        return;   // 服务还没起来，下次再来
    }
    id selfContact = nil;
    for (NSString *sel in @[@"getSelfContact", @"getMyContact", @"getSelf", @"selfContact"]) {
        selfContact = WXRCall(contact, sel);
        if (selfContact) break;
    }
    if (!selfContact) {
        return;
    }
    self.selfUserName = WXRValueAny(selfContact, @[@"m_nsUsrName", @"m_nsUserName", @"userName", @"m_nsRemark"]);
    self.selfDisplayName = WXRValueAny(selfContact, @[@"m_nsNickName", @"m_nsRemark", @"nickName"]) ?: self.selfUserName;
    WXRLog(@"[bridge] 自己 = %@(%@)", self.selfDisplayName ?: @"?", self.selfUserName ?: @"?");
}

+ (id)serviceForClass:(NSString *)className {
    WXRWeChat *b = [self shared];
    if (!className.length) return nil;
    @synchronized (b.serviceCache) {
        id cached = b.serviceCache[className];
        if (cached && cached != [NSNull null]) {
            return cached;
        }
    }
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) {
        WXRLogVerbose(@"[bridge] 类不存在：%@", className);
        return nil;
    }

    id service = nil;
    id center = [b serviceCenter];
    if (center) {
        service = WXRCall1(center, @"getService:", cls);
    }
    // 退路：有些服务本身就是单例
    if (!service) {
        for (NSString *sel in @[@"sharedInstance", @"defaultInstance", @"sharedManager"]) {
            service = WXRCallClass(className, sel);
            if (service) break;
        }
    }
    if (service) {
        @synchronized (b.serviceCache) {
            b.serviceCache[className] = service;
        }
        WXRLog(@"[bridge] 取到服务 %@", className);
    }
    return service;
}

+ (id)messageManager {
    WXRWeChat *b = [self shared];
    @synchronized (b.serviceCache) {
        id cached = b.serviceCache[@"__messageManager"];
        if (cached && cached != [NSNull null]) {
            return cached;
        }
    }
    for (NSString *name in WXRMessageManagerClasses()) {
        id service = [self serviceForClass:name];
        if (service) {
            @synchronized (b.serviceCache) {
                b.serviceCache[@"__messageManager"] = service;
            }
            WXRLog(@"[bridge] 消息服务 = %@", name);
            return service;
        }
    }
    WXRLogVerbose(@"[bridge] 消息服务尚未就绪（候选：%@）",
                  [WXRMessageManagerClasses() componentsJoinedByString:@", "]);
    return nil;
}

+ (id)contactManager {
    WXRWeChat *b = [self shared];
    @synchronized (b.serviceCache) {
        id cached = b.serviceCache[@"__contactManager"];
        if (cached && cached != [NSNull null]) {
            return cached;
        }
    }
    for (NSString *name in WXRContactManagerClasses()) {
        id service = [self serviceForClass:name];
        if (service) {
            @synchronized (b.serviceCache) {
                b.serviceCache[@"__contactManager"] = service;
            }
            return service;
        }
    }
    return nil;
}

+ (id)groupManager {
    for (NSString *name in WXRGroupManagerClasses()) {
        id service = [self serviceForClass:name];
        if (service) return service;
    }
    return nil;
}

+ (id)selfContact {
    id contact = [self contactManager];
    if (!contact) return nil;
    for (NSString *sel in @[@"getSelfContact", @"getMyContact", @"getSelf"]) {
        id c = WXRCall(contact, sel);
        if (c) return c;
    }
    return nil;
}

+ (NSString *)selfUserName {
    WXRWeChat *b = [self shared];
    [b resolveSelfIdentity];
    return b.selfUserName;
}

+ (NSString *)selfDisplayName {
    WXRWeChat *b = [self shared];
    [b resolveSelfIdentity];
    return b.selfDisplayName ?: @"";
}

/* ---------------- CMessageWrap 读取 ---------------- */

static NSString *WXRStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if ([value isKindOfClass:[NSData class]]) return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    return nil;
}

+ (NSString *)contentOfWrap:(id)wrap       { return WXRStringValue(WXRValueAny(wrap, WXRContentKeys())); }
+ (NSInteger)typeOfWrap:(id)wrap           { return [WXRValueAny(wrap, WXRTypeKeys()) integerValue]; }
+ (NSString *)fromOfWrap:(id)wrap          { return WXRStringValue(WXRValueAny(wrap, WXRFromKeys())); }
+ (NSString *)toOfWrap:(id)wrap            { return WXRStringValue(WXRValueAny(wrap, WXRToKeys())); }
+ (NSString *)msgSourceOfWrap:(id)wrap    { return WXRStringValue(WXRValueAny(wrap, WXRMsgSourceKeys())); }
+ (long long)serverIdOfWrap:(id)wrap       { return [WXRValueAny(wrap, WXRSvrIdKeys()) longLongValue]; }
+ (long long)messageIdOfWrap:(id)wrap      { return [WXRValueAny(wrap, WXRLocalIdKeys()) longLongValue]; }
+ (NSTimeInterval)timeOfWrap:(id)wrap      { return (NSTimeInterval)[WXRValueAny(wrap, WXRTimeKeys()) doubleValue]; }

+ (BOOL)isSystemWrap:(id)wrap {
    NSInteger type = [self typeOfWrap:wrap];
    if (type >= 10000 && type < 11000) {
        return YES;   // 微信把"撤回/拍一拍/入群"等系统提示放在 10000 段
    }
    NSString *content = [self contentOfWrap:wrap];
    return [content containsString:@"<sysmsg"] || [content containsString:@"<revokemsg"];
}

+ (BOOL)isGroupSession:(NSString *)session {
    return [session hasSuffix:@"@chatroom"];
}

+ (NSString *)sessionOfWrap:(id)wrap {
    NSString *from = [self fromOfWrap:wrap];
    NSString *to = [self toOfWrap:wrap];
    if ([self isGroupSession:from]) return from;
    if ([self isGroupSession:to])   return to;
    NSString *selfName = [self selfUserName];
    if (selfName.length) {
        if ([from isEqualToString:selfName]) return to;   // 自己发的
        return from ?: to;
    }
    return from ?: to;
}

+ (NSString *)actualSenderOfWrap:(id)wrap {
    NSString *from = [self fromOfWrap:wrap];
    NSString *source = [self msgSourceOfWrap:wrap];
    if (source.length) {
        // 群消息的真实发送者可能在 msgsource 里
        for (NSString *pattern in @[@"<member[^>]*username=\"([^\"]+)\"",
                                    @"<fromusername>([^<]+)</fromusername>",
                                    @"username=\"([^\"]+)\""]) {
            NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
            NSTextCheckingResult *m = [rx firstMatchInString:source options:0 range:NSMakeRange(0, source.length)];
            if (m && m.numberOfRanges > 1) {
                NSString *found = [source substringWithRange:[m rangeAtIndex:1]];
                if (found.length && ![found isEqualToString:[self selfUserName]]) {
                    return found;
                }
            }
        }
    }
    return from;
}

/* ---------------- 发消息 ---------------- */

static BOOL WXRSetAny(id object, NSArray<NSString *> *keys, id value) {
    for (NSString *key in keys) {
        @try {
            [object setValue:value forKey:key];
            return YES;
        } @catch (NSException *e) {
            // 字段不存在，试下一个
        }
    }
    return NO;
}

// selector 的参数个数 = 冒号个数。传错参数个数是这类插件最常见的崩溃原因，
// 所以每个候选 selector 都按真实签名匹配再用。
static NSUInteger WXRSelectorArity(NSString *selector) {
    if (!selector.length) return 0;
    return [[selector componentsSeparatedByString:@":"] count] - 1;
}

+ (BOOL)sendText:(NSString *)text toSession:(NSString *)session {
    if (!text.length || !session.length) return NO;
    id manager = [self messageManager];
    if (!manager) {
        WXRLog(@"[send] 没有消息服务，发不出去");
        return NO;
    }

    // 策略 1：构造 CMessageWrap，交给微信自己的发送方法
    Class wrapClass = objc_getClass("CMessageWrap");
    if (wrapClass) {
        id wrap = WXRCall(wrapClass, @"alloc");
        wrap = WXRCall(wrap, @"init");
        if (wrap) {
            WXRSetAny(wrap, WXRContentKeys(), text);
            WXRSetAny(wrap, WXRTypeKeys(), @(1));                       // 1 = 文本
            WXRSetAny(wrap, WXRFromKeys(), [self selfUserName] ?: @"");
            WXRSetAny(wrap, WXRToKeys(), session);
            WXRSetAny(wrap, WXRTimeKeys(), @([[NSDate date] timeIntervalSince1970]));
            WXRSetAny(wrap, @[@"m_uiStatus", @"m_nStatus"], @(1));
            WXRSetAny(wrap, @[@"m_uiUploadStatus", @"m_nUploadStatus"], @(0));
            for (NSString *sel in WXRSendMsgSelectors()) {
                if (WXRSelectorArity(sel) != 1) continue;   // 只调「单参数收 MsgWrap」的方法
                if ([manager respondsToSelector:NSSelectorFromString(sel)]) {
                    WXRCall1(manager, sel, wrap);
                    WXRLog(@"[send] 用 %@ 发出（会话=%@ 长度=%lu）", sel, session, (unsigned long)text.length);
                    return YES;
                }
            }
        }
    }

    // 策略 2：直接调"发文本"方法，两种参数顺序都试
    for (NSString *sel in WXRSendTextSelectors()) {
        if (WXRSelectorArity(sel) != 2) continue;           // 只调「(文本, 会话)」这种双参数方法
        if ([manager respondsToSelector:NSSelectorFromString(sel)]) {
            WXRCall2(manager, sel, text, session);
            WXRLog(@"[send] 用 %@ 发出（参数顺序 text,session）", sel);
            return YES;
        }
    }
    [[self shared] logSendDiagnostics];
    return NO;
}

- (void)logSendDiagnostics {
    id manager = [[self class] messageManager];
    if (!manager) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(manager), &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name.lowercaseString containsString:@"send"]) {
            [names addObject:name];
        }
    }
    if (methods) free(methods);
    WXRLog(@"[send] %@ 上所有含 send 的方法：%@", NSStringFromClass([manager class]),
           [names componentsJoinedByString:@", "]);
}

/* ---------------- 收消息 ---------------- */

+ (void)addMessageHandler:(WXRMessageHandler)handler {
    if (!handler) return;
    @synchronized ([self shared].handlers) {
        [[self shared].handlers addObject:[handler copy]];
    }
}

+ (void)dispatchWrap:(id)wrap {
    if (!wrap) return;
    NSArray<WXRMessageHandler> *snapshot;
    @synchronized ([self shared].handlers) {
        snapshot = [[self shared].handlers copy];
    }
    for (WXRMessageHandler handler in snapshot) {
        @try {
            handler(wrap);
        } @catch (NSException *e) {
            WXRLog(@"[pipeline] 处理消息异常: %@", e.reason);
        }
    }
}

// --- 候选回调的替换实现（参数个数不同，逐个写） ---

static void (*gOrig2)(id, SEL, id, id) = NULL;
static void WXROnAddMsg2(id self, SEL _cmd, id a1, id a2) {
    if (gOrig2) gOrig2(self, _cmd, a1, a2);
    // 绝大多数版本 MsgWrap 是第 2 个参数
    dispatch_async(dispatch_get_main_queue(), ^{
        [WXRWeChat handleRawWrap:a2];
    });
}
static void (*gOrig3)(id, SEL, id, id, id) = NULL;
static void WXROnAddMsg3(id self, SEL _cmd, id a1, id a2, id a3) {
    if (gOrig3) gOrig3(self, _cmd, a1, a2, a3);
    dispatch_async(dispatch_get_main_queue(), ^{
        [WXRWeChat handleRawWrap:a2];
    });
}

+ (void)handleRawWrap:(id)wrap {
    if (!wrap) return;
    static NSInteger logged = 0;
    if (logged < 3) {
        logged++;
        WXRLog(@"[pipeline] 新消息字段转储:\n%@", [self describeObject:wrap maxLength:1200]);
    }
    [self dispatchWrap:wrap];
}

+ (BOOL)installMessageHooks {
    WXRWeChat *b = [self shared];    if (b.hooksInstalled) return YES;
    NSArray<NSString *> *classes = WXRMessageManagerClasses();
    for (NSString *sel in WXRIncomingMessageSelectors()) {
        NSUInteger arity = [[sel componentsSeparatedByString:@":"] count] - 1;
        if (arity == 2) {
            if ([WXRHook hookAnyClass:classes selector:sel isClassMethod:NO
                          replacement:(IMP)WXROnAddMsg2 original:(IMP *)&gOrig2
                                 note:@"新消息回调(2参数)"]) {
                b.hooksInstalled = YES;
                WXRLog(@"[pipeline] 已挂新消息回调 %@", sel);
                return YES;
            }
        } else if (arity == 3) {
            if ([WXRHook hookAnyClass:classes selector:sel isClassMethod:NO
                          replacement:(IMP)WXROnAddMsg3 original:(IMP *)&gOrig3
                                 note:@"新消息回调(3参数)"]) {
                b.hooksInstalled = YES;
                WXRLog(@"[pipeline] 已挂新消息回调 %@", sel);
                return YES;
            }
        }
    }
    WXRLog(@"[pipeline] ⚠️ 没找到新消息回调，请在诊断页导出类名后补充 selector");
    return NO;
}

+ (BOOL)messageHooksInstalled {
    return [self shared].hooksInstalled;
}

/* ---------------- 诊断 ---------------- */

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)diagnosticProbes {
    NSMutableDictionary *probes = [NSMutableDictionary dictionary];
    for (NSString *cls in WXRServiceCenterClasses()) {
        probes[cls] = WXRServiceCenterSingletonSelectors();
    }
    NSMutableArray *messageSelectors = [NSMutableArray array];
    [messageSelectors addObjectsFromArray:WXRIncomingMessageSelectors()];
    [messageSelectors addObjectsFromArray:WXRSendMsgSelectors()];
    [messageSelectors addObjectsFromArray:WXRSendTextSelectors()];
    for (NSString *cls in WXRMessageManagerClasses()) {
        probes[cls] = messageSelectors;
    }
    for (NSString *cls in WXRContactManagerClasses()) {
        probes[cls] = @[@"getSelfContact", @"getMyContact", @"getSelf", @"getContact:", @"getContactByName:"];
    }
    for (NSString *cls in WXRGroupManagerClasses()) {
        probes[cls] = @[@"getGroupMemberList:", @"getGroupMember:", @"getGroupName:"];
    }
    probes[@"CMessageWrap"] = @[@"m_nsContent", @"m_uiMessageType", @"m_nsFromUsr", @"m_nsToUsr", @"m_nsMsgSource"];
    return probes;
}

+ (NSString *)candidateReport {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"WXRit %@ 当前生效的候选名\n微信 %@\n\n%@\n\n",
        WXR_VERSION,
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [WXROverrides summary]];
    void (^add)(NSString *, NSArray<NSString *> *) = ^(NSString *label, NSArray<NSString *> *names) {
        [out appendFormat:@"%@:\n  %@\n\n", label, [names componentsJoinedByString:@"\n  "]];
    };
    add(@"服务总线类", WXRServiceCenterClasses());
    add(@"服务总线单例方法", WXRServiceCenterSingletonSelectors());
    add(@"消息服务类", WXRMessageManagerClasses());
    add(@"收消息回调 selector", WXRIncomingMessageSelectors());
    add(@"发消息 selector（wrap）", WXRSendMsgSelectors());
    add(@"发消息 selector（文本）", WXRSendTextSelectors());
    add(@"通讯录服务类", WXRContactManagerClasses());
    add(@"字段·正文", WXRContentKeys());
    add(@"字段·类型", WXRTypeKeys());
    add(@"字段·发送者", WXRFromKeys());
    add(@"字段·接收者", WXRToKeys());
    add(@"字段·服务端消息 id", WXRSvrIdKeys());
    add(@"字段·本地消息 id", WXRLocalIdKeys());
    add(@"字段·消息来源 XML", WXRMsgSourceKeys());
    return out;
}

+ (NSString *)diagnosticReport {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"WXRit %@\n进程: %@\n微信版本: %@\n生成时间: %@\n\n",
        WXR_VERSION,
        [[NSProcessInfo processInfo] processName],
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [NSDate date]];
    NSDictionary<NSString *, NSArray<NSString *> *> *probes = [self diagnosticProbes];
    for (NSString *clsName in [probes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        Class cls = objc_getClass(clsName.UTF8String);
        [out appendFormat:@"=== %@ : %@\n", clsName, cls ? @"存在" : @"不存在"];
        if (!cls) continue;
        for (NSString *selName in probes[clsName]) {
            SEL sel = NSSelectorFromString(selName);
            BOOL instance = class_getInstanceMethod(cls, sel) != NULL;
            BOOL classM = class_getInstanceMethod(object_getClass(cls), sel) != NULL;
            if (instance || classM) {
                Method m = instance ? class_getInstanceMethod(cls, sel) : class_getInstanceMethod(object_getClass(cls), sel);
                const char *types = method_getTypeEncoding(m);
                [out appendFormat:@"  ✔ %@%@  types=%s\n", classM && !instance ? @"+" : @"-", selName, types ?: "?"];
            } else {
                [out appendFormat:@"  ✘ %@\n", selName];
            }
        }
    }
    [out appendFormat:@"\n=== 已挂 hook ===\n"];
    for (WXRHookRecord *r in [WXRHook records]) {
        [out appendFormat:@"%@\n", r];
    }
    return out;
}

+ (NSString *)describeObject:(id)object maxLength:(NSUInteger)maxLength {
    if (!object) return @"(nil)";
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"%@ <%p>\n", NSStringFromClass([object class]), object];
    BOOL logContent = [WXRPrefs shared].boolLogContent;
    Class cls = object_getClass(object);
    int guard = 0;
    while (cls && guard++ < 6) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!name) continue;
            // 只读「对象类型」和「标量」ivar：指针/结构体/C++ 对象用 KVC 取会有崩溃风险
            if (type) {
                char first = type[0];
                BOOL readable = (first == '@' || first == 'c' || first == 'i' || first == 's' ||
                                 first == 'l' || first == 'q' || first == 'C' || first == 'I' ||
                                 first == 'S' || first == 'L' || first == 'Q' || first == 'f' ||
                                 first == 'd' || first == 'B');
                if (!readable) continue;
            }
            NSString *key = [NSString stringWithUTF8String:name];
            NSString *valueText = @"?";
            @try {
                id value = [object valueForKey:key];
                if ([value isKindOfClass:[NSString class]]) {
                    NSString *s = value;
                    BOOL sensitive = [key.lowercaseString containsString:@"content"] ||
                                     [key.lowercaseString containsString:@"msgsource"] ||
                                     [key.lowercaseString containsString:@"path"] ||
                                     [key.lowercaseString containsString:@"url"];
                    if (sensitive && !logContent) {
                        valueText = [NSString stringWithFormat:@"<hidden len=%lu>", (unsigned long)s.length];
                    } else {
                        valueText = s.length > 200 ? [[s substringToIndex:200] stringByAppendingString:@"…"] : s;
                    }
                } else if (value) {
                    valueText = [value description];
                    if (valueText.length > 200) {
                        valueText = [[valueText substringToIndex:200] stringByAppendingString:@"…"];
                    }
                }
            } @catch (NSException *e) {
                valueText = @"(读取失败)";
            }
            [out appendFormat:@"  %s (%s) = %@\n", name, type ?: "?", valueText];
            if (out.length > maxLength) {
                [out appendString:@"  …(截断)\n"];
                if (ivars) free(ivars);
                return out;
            }
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
    }
    return out;
}

@end
