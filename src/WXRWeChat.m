#import "WXRWeChat.h"
#import "WXRSendProbe.h"
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
    NSString *hostName = [[NSProcessInfo processInfo] processName];
    NSString *wxVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    WXRLog(@"[bridge] 宿主=%@ 微信=%@（服务对象在收到消息时惰性获取）", hostName, wxVersion);

    // 实测确认：微信自己发消息用的就是第 1 种（AddMsg:MsgWrap:，参数是「会话名, wrap」）。
    // 每次启动固定回它，避免残留的轮转指针继续去试别的（那些尝试只会多插气泡）。
    [[WXRPrefs shared] setInteger:0 forKey:WXRKeySendStrategy];
    WXRLog(@"[send] 发送方式固定为第 1 种：AddMsg:MsgWrap:（会话名, wrap）");
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

// 微信的 MMServiceCenter 返回的常常不是服务本身，而是包装代理 MMServiceWrapper：
// 方法不在它身上实现，而是转发给真实服务。于是 respondsToSelector: 会说 NO，
// 但直接调用其实是通的。这里尽量把里面的真实对象拆出来。
static id WXRUnwrapService(id service) {
    if (!service) {
        return nil;
    }
    NSString *className = NSStringFromClass(object_getClass(service));
    if (![className containsString:@"Wrapper"] && ![className containsString:@"Proxy"]) {
        return service;
    }
    // 1) 让代理自己告诉我们它转发给谁
    for (NSString *probe in @[@"AsyncSendMsg:", @"SendMsg:", @"AsyncOnAddMsg:MsgWrap:", @"SendMsg:MsgWrap:"]) {
        id target = WXRCallSEL(service, @"forwardingTargetForSelector:", NSSelectorFromString(probe));
        if (target && target != service) {
            WXRLog(@"[bridge] %@ 转发给 %@", className, NSStringFromClass(object_getClass(target)));
            return target;
        }
    }
    // 2) 常见字段名
    id inner = WXRValueAny(service, @[@"m_service", @"m_target", @"m_obj", @"m_wrappedService",
                                      @"service", @"target", @"m_delegate", @"m_realService"]);
    if (inner && inner != service) {
        WXRLog(@"[bridge] 从 %@ 里拆出 %@", className, NSStringFromClass(object_getClass(inner)));
        return inner;
    }
    WXRLog(@"[bridge] %@ 拆不开，先原样使用。它的字段：\n%@",
           className, [WXRWeChat describeObject:service maxLength:600]);
    return service;
}

// 收消息回调的 self 就是真实消息服务实例（不经过代理），这是最可靠的获取方式
static id gObservedMessageManager = nil;

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
        service = WXRUnwrapService(service);
        @synchronized (b.serviceCache) {
            b.serviceCache[className] = service;
        }
        WXRLog(@"[bridge] 取到服务 %@（实际对象 %@）", className,
               NSStringFromClass(object_getClass(service)));
    }
    return service;
}

+ (NSArray<NSString *> *)selectorsOfClassNamed:(NSString *)className {
    if (!className.length) {
        return @[];
    }
    return WXRSelectorsOfClass(objc_getClass(className.UTF8String));
}

+ (void)rememberMessageManager:(id)manager {
    if (!manager) {
        return;
    }
    @synchronized ([self class]) {
        if (gObservedMessageManager != manager) {
            gObservedMessageManager = manager;
            WXRLog(@"[bridge] 记下真实消息服务 = %@（来自收消息回调）",
                   NSStringFromClass(object_getClass(manager)));
        }
    }
}

+ (id)messageManager {
    WXRWeChat *b = [self shared];
    // 收消息回调里抓到的实例优先：它是真实服务，不是 MMServiceWrapper
    @synchronized ([self class]) {
        if (gObservedMessageManager) {
            return gObservedMessageManager;
        }
    }
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

// 群名/好友名字解析：备注优先，其次群名/昵称/别名；查不到返回 nil
+ (NSString *)displayNameForUser:(NSString *)userName {
    if (!userName.length) {
        return nil;
    }
    id manager = [self contactManager];
    if (!manager) {
        return nil;
    }
    id contact = WXRCall1(manager, @"getContactByName", userName);
    if (!contact) {
        return nil;
    }
    for (NSString *key in @[@"m_nsRemark", @"m_nsNickName", @"m_nsAliasName", @"m_nsDisplayName"]) {
        id value = WXRValueAny(contact, @[key]);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
            return (NSString *)value;
        }
    }
    return nil;
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
    // ① 最可靠：m_nsRealChatUsr —— 群消息里它就是真实发送者的 wxid
    //    （私聊消息这个字段为空，所以会继续往下走 from）
    NSString *realChatUsr = WXRStringValue(WXRValueAny(wrap, @[@"m_nsRealChatUsr", @"m_nsRealChatUser"]));
    if (realChatUsr.length) {
        return realChatUsr;
    }
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
                if (found.length) {
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

/* ---------------- 发送 ---------------- */

static NSArray<NSString *> *WXRSelectorsOfClass(Class cls) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            [out addObject:NSStringFromSelector(method_getName(methods[i]))];
        }
        if (methods) {
            free(methods);
        }
        cls = class_getSuperclass(cls);
    }
    return out;
}

// 列出对象的实例方法（含父类链）。
// 注意：object_getClass(实例) 就是它的类对象，要传给 class_copyMethodList 的是这个；
// 再套一层 object_getClass 就变成元类了，那样只能枚举到类方法（发送方法都是实例方法）。
static NSArray<NSString *> *WXRInstanceSelectors(id object) {
    return WXRSelectorsOfClass(object_getClass(object));
}

// 这些不是"给会话发消息"，自动识别时一律排除（8.0.76 上就踩过：
// onOpenUploadSendBypassMsg: / sendBypassMsg: / ResendMsg:MsgWrap: 之类都是内部边角方法）
static NSArray<NSString *> *WXRBlockedSendWords(void) {
    return @[@"file", @"img", @"image", @"video", @"voice", @"audio", @"red", @"pay", @"emoji",
             @"location", @"verify", @"invite", @"friend", @"card", @"gift", @"sticker", @"game",
             @"bypass", @"notification", @"updatemsgsource", @"opensend", @"resend"];
}

static BOOL WXRSelectorLooksLikeMedia(NSString *selector) {
    NSString *lower = selector.lowercaseString;
    for (NSString *word in WXRBlockedSendWords()) {
        if ([lower containsString:word]) {
            return YES;
        }
    }
    return NO;
}

// 名字像"直接发文本"：含 send 且含 text/content/message
static BOOL WXRSelectorLooksLikeSendText(NSString *selector) {
    NSString *lower = selector.lowercaseString;
    if (![lower containsString:@"send"] || WXRSelectorLooksLikeMedia(selector)) {
        return NO;
    }
    return [lower containsString:@"text"] || [lower containsString:@"content"] ||
           [lower containsString:@"message"];
}

// 名字像"发 MsgWrap"：含 send 且含 msg
static BOOL WXRSelectorLooksLikeSendWrap(NSString *selector) {
    NSString *lower = selector.lowercaseString;
    if (![lower containsString:@"send"] || WXRSelectorLooksLikeMedia(selector)) {
        return NO;
    }
    return ![lower containsString:@"text"] && [lower containsString:@"msg"];
}

// 第一个参数标签听起来是"内容"吗？微信惯例是先内容后会话
static BOOL WXRSelectorTakesContentFirst(NSString *selector) {
    NSString *first = [[selector componentsSeparatedByString:@":"] firstObject].lowercaseString;
    if ([first containsString:@"text"] || [first containsString:@"content"] || [first containsString:@"msg"]) {
        return YES;
    }
    if ([first containsString:@"session"] || [first containsString:@"usr"] ||
        [first containsString:@"user"] || [first containsString:@"chat"] || [first isEqualToString:@"to"]) {
        return NO;
    }
    return YES;
}

// 优先"第二个参数像会话名"的，其次名字短的
static NSArray<NSString *> *WXROrderedSendTextSelectors(NSArray<NSString *> *selectors) {
    return [selectors sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *la = a.lowercaseString;
        NSString *lb = b.lowercaseString;
        BOOL targetA = [la containsString:@"session"] || [la containsString:@"usr"] || [la containsString:@"user"];
        BOOL targetB = [lb containsString:@"session"] || [lb containsString:@"usr"] || [lb containsString:@"user"];
        if (targetA != targetB) {
            return targetA ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.length != b.length) {
            return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a compare:b];
    }];
}

// 造一条"发出去的文本消息"包装对象
static id WXRMakeOutgoingTextWrap(NSString *text, NSString *session, NSString *from) {
    Class wrapClass = objc_getClass("CMessageWrap");
    if (!wrapClass) {
        return nil;
    }
    id wrap = nil;
    if ([wrapClass instancesRespondToSelector:NSSelectorFromString(@"initWithMsgType:")]) {
        wrap = WXRCall1(WXRCall(wrapClass, @"alloc"), @"initWithMsgType:", @(1));
    }
    if (!wrap) {
        wrap = WXRCall(WXRCall(wrapClass, @"alloc"), @"init");
    }
    if (!wrap) {
        return nil;
    }
    WXRSetAny(wrap, WXRContentKeys(), text);
    WXRSetAny(wrap, WXRTypeKeys(), @(1));                 // 1 = 文本
    if (from.length) {
        WXRSetAny(wrap, WXRFromKeys(), from);
    }
    WXRSetAny(wrap, WXRToKeys(), session);
    WXRSetAny(wrap, WXRTimeKeys(), @([[NSDate date] timeIntervalSince1970]));
    WXRSetAny(wrap, @[@"m_uiStatus", @"m_nStatus"], @(1));
    WXRSetAny(wrap, @[@"m_uiUploadStatus", @"m_nUploadStatus"], @(0));
    WXRSetAny(wrap, @[@"m_uiSendTime", @"m_nSendTime"], @([[NSDate date] timeIntervalSince1970]));
    // 出站消息通常还需要一个"客户端消息 id"；缺了它上传就可能一直不完成（气泡一直转圈）
    WXRSetAny(wrap, @[@"m_nsClientMsgID", @"m_nsClientMsgId", @"nsClientMsgID"],
              [[NSUUID UUID] UUIDString]);
    return wrap;
}

// 服务代理（MMServiceWrapper）方法不在自己身上，而是转发给真实服务，
// 所以 respondsToSelector: 会说 NO，但直接调用是通的。
static BOOL WXRIsForwardingProxy(id object) {
    NSString *className = NSStringFromClass(object_getClass(object));
    return [className containsString:@"Wrapper"] || [className containsString:@"Proxy"];
}

+ (BOOL)trySendTextVia:(NSArray<NSString *> *)selectors
               manager:(id)manager
                  text:(NSString *)text
               session:(NSString *)session {
    for (NSString *selector in selectors) {
        if (WXRSelectorArity(selector) != 2) {
            continue;
        }
        if (![manager respondsToSelector:NSSelectorFromString(selector)] && !WXRIsForwardingProxy(manager)) {
            continue;
        }
        BOOL contentFirst = WXRSelectorTakesContentFirst(selector);
        WXRLog(@"[send] 尝试 %@（参数顺序：%@）", selector, contentFirst ? @"文本,会话" : @"会话,文本");
        if (contentFirst) {
            WXRCall2(manager, selector, text, session);
        } else {
            WXRCall2(manager, selector, session, text);
        }
        WXRLog(@"[send] 已调用 %@", selector);
        return YES;
    }
    return NO;
}

+ (BOOL)trySendWrapVia:(NSArray<NSString *> *)selectors manager:(id)manager wrap:(id)wrap {
    if (!wrap) {
        return NO;
    }
    for (NSString *selector in selectors) {
        if (![manager respondsToSelector:NSSelectorFromString(selector)] && !WXRIsForwardingProxy(manager)) {
            continue;
        }
        NSUInteger arity = WXRSelectorArity(selector);
        if (arity == 1) {
            WXRLog(@"[send] 尝试 %@（wrap）", selector);
            WXRCall1(manager, selector, wrap);
            WXRLog(@"[send] 已调用 %@", selector);
            return YES;
        }
        if (arity == 2) {
            WXRLog(@"[send] 尝试 %@（wrap,nil）", selector);
            WXRCall2(manager, selector, wrap, nil);
            WXRLog(@"[send] 已调用 %@", selector);
            return YES;
        }
    }
    return NO;
}

typedef NS_ENUM(NSInteger, WXRSendShape) {
    WXRSendShapeSessionWrap = 0,       // (会话名, wrap)
    WXRSendShapeZeroWrap,              // (@0, wrap)
    WXRSendShapeSessionWrapNotify,     // (会话名, wrap, fixTime=NO, NewMsgArriveNotify=YES)
};

/* ---------------- 读取会话历史（给 AI 当上下文） ---------------- */

+ (NSInteger)localIDOfWrap:(id)wrap {
    id value = WXRValueAny(wrap, @[@"m_uiMesLocalID", @"m_nMesLocalID", @"m_uiMesLocalId"]);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

// 用 GetMsg:LocalID: 从当前消息往前逐条读。
// 参数类型各版本可能不同：按运行时签名决定传对象还是传整数，整体 @try 兜住。
+ (id)messageAtSession:(NSString *)session localID:(NSInteger)localID manager:(id)manager {
    if (!session.length || localID <= 0 || !manager) {
        return nil;
    }
    for (NSString *selector in @[@"GetMsg:LocalID:", @"GetMsg:LocalID:hasError:needOriginContent:"]) {
        SEL sel = NSSelectorFromString(selector);
        NSMethodSignature *signature = nil;
        @try {
            signature = [manager methodSignatureForSelector:sel];
        } @catch (NSException *e) {
            signature = nil;
        }
        if (!signature || signature.numberOfArguments != 4) {   // self + _cmd + 两个参数
            continue;
        }
        const char *returnType = signature.methodReturnType;
        const char *firstType = [signature getArgumentTypeAtIndex:2];
        const char *secondType = [signature getArgumentTypeAtIndex:3];
        if (!returnType || returnType[0] != '@' || !firstType || firstType[0] != '@' || !secondType) {
            continue;
        }
        @try {
            IMP imp = [manager methodForSelector:sel];
            if (!imp) {
                continue;
            }
            if (secondType[0] == '@') {
                id result = ((id (*)(id, SEL, id, id))imp)(manager, sel, session, @(localID));
                if (result) {
                    return result;
                }
            } else if (secondType[0] == 'q' || secondType[0] == 'Q' || secondType[0] == 'l') {
                id result = ((id (*)(id, SEL, id, long long))imp)(manager, sel, session, (long long)localID);
                if (result) {
                    return result;
                }
            } else if (secondType[0] == 'i' || secondType[0] == 'I') {
                id result = ((id (*)(id, SEL, id, int))imp)(manager, sel, session, (int)localID);
                if (result) {
                    return result;
                }
            }
        } @catch (NSException *e) {
            WXRLogVerbose(@"[history] %@ 调用异常：%@", selector, e.reason);
        }
    }
    return nil;
}

+ (NSArray<NSDictionary *> *)historyForSession:(NSString *)session
                                 endingAtLocalID:(NSInteger)localID
                                           limit:(NSInteger)limit {
    if (!session.length || localID <= 1 || limit <= 0) {
        return @[];
    }
    id manager = [self messageManager];
    if (!manager) {
        return @[];
    }
    NSInteger want = MIN(limit, 30);
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSInteger lowest = MAX(1, localID - want * 4);      // 中间可能有空洞/已删除，多扫一些
    for (NSInteger lid = localID - 1; lid >= lowest && (NSInteger)out.count < want; lid--) {
        id wrap = [self messageAtSession:session localID:lid manager:manager];
        if (!wrap) {
            continue;
        }
        NSString *content = [self contentOfWrap:wrap];
        if (!content.length) {
            continue;        // 图片/语音等没有正文的先跳过，不塞给 AI
        }
        NSString *from = [self fromOfWrap:wrap];
        NSString *selfName = [self selfUserName];
        BOOL outgoing = from.length && selfName.length && [from isEqualToString:selfName];
        [out insertObject:@{@"content": content,
                            @"from": from ?: @"",
                            @"outgoing": @(outgoing)} atIndex:0];
    }
    return out;
}

// 出站消息可以试的几种调用方式。参数形状都按各方法真实的类型编码来（都是对象或 BOOL，ABI 安全）。
// 顺序按"最像真正的发送路径"排：已实测 AddMsg / AddUniqueLocalMsg / AddLocalMsg 都只入库不上传，
// 所以把带 fixTime/NewMsgArriveNotify 的那个放在后面继续试。
static NSArray<NSArray *> *WXROutgoingAttempts(void) {
    return @[@[@"AddMsg:MsgWrap:", @(WXRSendShapeSessionWrap)],
             @[@"AddUniqueLocalMsg:MsgWrap:", @(WXRSendShapeSessionWrap)],
             @[@"AddLocalMsg:MsgWrap:", @(WXRSendShapeSessionWrap)],
             @[@"AddLocalMsg:MsgWrap:fixTime:NewMsgArriveNotify:", @(WXRSendShapeSessionWrapNotify)],
             @[@"ResendMsg:MsgWrap:", @(WXRSendShapeSessionWrap)],
             @[@"AddLocalMsg:MsgWrap:", @(WXRSendShapeZeroWrap)],
             @[@"AddMsg:MsgWrap:", @(WXRSendShapeZeroWrap)]];
}

// 4 参数那个方法的签名是 v40@0:8@16@24B32B36（最后两个是 BOOL 标量），必须按真实类型调
static void WXRCallAddLocal4(id target, NSString *selector, id a1, id a2, BOOL a3, BOOL a4) {
    SEL sel = NSSelectorFromString(selector);
    @try {
        IMP imp = [target methodForSelector:sel];
        if (!imp) {
            return;
        }
        ((void (*)(id, SEL, id, id, BOOL, BOOL))imp)(target, sel, a1, a2, a3, a4);
    } @catch (NSException *e) {
        WXRLog(@"[send] %@ 异常: %@", selector, e.reason);
    }
}

static NSInteger gSendAttemptIndex = -1;   // 本次用的轮转编号（-1 = 不是轮转）
static NSInteger gSendRotation = 0;        // 下一次该试第几种
static BOOL gLastAttemptInserted = NO;     // 上一次调用是否真的把消息插进会话了
static id gLastAttemptWrap = nil;          // 上一次用的 wrap（留着回读状态，判断有没有真的发出去）

// 真机验证：OnMessageSentBySender: 这个"发送成功回调"在 8.0.76 上不一定触发
// （微信自己手动发消息时也没触发），所以主力判据改成"回读我们自己那个 wrap 的状态"：
//   m_uiStatus：1 = 发送中；变成别的值说明状态已经流转
//   m_n64MesSvrID：变成非 0 说明服务器已经受理
+ (NSString *)lastAttemptStateText {
    id wrap = gLastAttemptWrap;
    if (!wrap) {
        return @"(没有 wrap)";
    }
    return [NSString stringWithFormat:@"状态=%@ svrID=%@",
            WXRValueAny(wrap, @[@"m_uiStatus", @"m_nStatus"]),
            WXRValueAny(wrap, @[@"m_n64MesSvrID", @"m_n64MesSvrId", @"m_uiMesSvrID"])];
}

+ (BOOL)lastAttemptLooksSent {
    id wrap = gLastAttemptWrap;
    if (!wrap) {
        return NO;
    }
    id serverId = WXRValueAny(wrap, @[@"m_n64MesSvrID", @"m_n64MesSvrId", @"m_uiMesSvrID"]);
    if ([serverId respondsToSelector:@selector(longLongValue)] && [serverId longLongValue] != 0) {
        return YES;
    }
    id status = WXRValueAny(wrap, @[@"m_uiStatus", @"m_nStatus"]);
    NSInteger value = [status respondsToSelector:@selector(integerValue)] ? [status integerValue] : 0;
    return (value != 0 && value != 1);
}

// 判据（按可靠性排序，实测得出）：
//   ① 收到明确的失败回调 → 失败
//   ② 消息已经成功入库 → 成功：微信会负责把它上传发出去
//      （实测：对方确实能收到；但本机 wrap 的状态不一定被回写，
//        所以"只看状态"会把成功判成失败——这正是之前误报的原因）
//   ③ wrap 状态流转 / 服务器 id 非 0 / 发送成功回调 → 也算成功
+ (BOOL)lastAttemptSucceededAfter:(NSTimeInterval)attemptedAt content:(NSString *)text {
    if ([WXRSendProbe failedAfter:attemptedAt]) {
        return NO;
    }
    if (gLastAttemptInserted) {
        return YES;
    }
    if ([self lastAttemptLooksSent]) {
        return YES;
    }
    return [WXRSendProbe wasConfirmedAfter:attemptedAt content:text];
}

+ (BOOL)invokeOutgoingAttemptAtIndex:(NSInteger)index
                                 text:(NSString *)text
                              session:(NSString *)session
                                 wrap:(id)wrap {
    NSArray<NSArray *> *attempts = WXROutgoingAttempts();
    if (index < 0 || index >= (NSInteger)attempts.count || !wrap) {
        return NO;
    }
    id manager = [self messageManager];
    if (!manager) {
        return NO;
    }
    NSString *selector = attempts[(NSUInteger)index][0];
    WXRSendShape shape = (WXRSendShape)[attempts[(NSUInteger)index][1] integerValue];
    if (![manager respondsToSelector:NSSelectorFromString(selector)] && !WXRIsForwardingProxy(manager)) {
        WXRLog(@"[send] 第 %ld 种方式 %@ 在这个版本里不存在，跳过", (long)index + 1, selector);
        return NO;
    }
    gLastAttemptWrap = wrap;
    [WXRSendProbe beginOurCall];
    switch (shape) {
        case WXRSendShapeSessionWrap:
            WXRLog(@"[send] 试第 %ld 种发送方式：%@（会话名, wrap）", (long)index + 1, selector);
            WXRCall2(manager, selector, session, wrap);
            break;
        case WXRSendShapeZeroWrap:
            WXRLog(@"[send] 试第 %ld 种发送方式：%@（@0, wrap）", (long)index + 1, selector);
            WXRCall2(manager, selector, @(0), wrap);
            break;
        case WXRSendShapeSessionWrapNotify:
            WXRLog(@"[send] 试第 %ld 种发送方式：%@（会话名, wrap, fixTime=NO, notify=YES）",
                   (long)index + 1, selector);
            WXRCallAddLocal4(manager, selector, session, wrap, NO, YES);
            break;
    }
    [WXRSendProbe endOurCall];
    // 调用后回读 wrap：插入成功后微信通常会就地补上 localID / 状态，回读能看出插入到底成功没有
    id localID = WXRValueAny(wrap, @[@"m_uiMesLocalID", @"m_nMesLocalID"]);
    gLastAttemptInserted = (localID != nil) && ([localID integerValue] != 0);
    WXRLog(@"[send] 调用后 wrap 状态：localID=%@ status=%@ uploadStatus=%@ clientMsgID=%@（插入%@）",
           localID,
           WXRValueAny(wrap, @[@"m_uiStatus", @"m_nStatus"]),
           WXRValueAny(wrap, @[@"m_uiUploadStatus", @"m_nUploadStatus"]),
           WXRValueAny(wrap, @[@"m_nsClientMsgID", @"m_nsClientMsgId"]),
           gLastAttemptInserted ? @"成功" : @"没成功");
    gSendAttemptIndex = index;
    return YES;
}

/* ---------------- 名字解析诊断（只读，用来确认真实字段/方法名） ---------------- */

+ (NSString *)describeContactForUser:(NSString *)userName {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"查「%@」\n", userName.length ? userName : @"(空)"];
    id manager = [self contactManager];
    [text appendFormat:@"  contactManager = %@\n",
     manager ? NSStringFromClass(object_getClass(manager)) : @"nil"];
    if (!manager || !userName.length) {
        return text;
    }
    Class contactClass = objc_getClass("CContactMgr");
    for (NSString *selector in @[@"getContactByName:", @"getContact:", @"contactWithUsername:"]) {
        BOOL exists = contactClass && class_getInstanceMethod(contactClass, NSSelectorFromString(selector)) != NULL;
        [text appendFormat:@"  %@ %@\n", selector, exists ? @"存在" : @"不存在"];
        NSInteger arity = (NSInteger)[[selector componentsSeparatedByString:@":"] count] - 1;
        if (!exists || arity != 1) {
            continue;
        }
        id contact = WXRCall1(manager, selector, userName);
        [text appendFormat:@"    → %@\n", contact ? [self describeObject:contact maxLength:1500] : @"nil"];
        if (contact) {
            break;
        }
    }
    return text;
}

+ (NSString *)methodNamesOfClass:(NSString *)className containing:(NSString *)keyword {
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) {
        return [NSString stringWithFormat:@"%@：类不存在", className];
    }
    NSMutableArray<NSString *> *matched = [NSMutableArray array];
    for (NSString *selector in WXRSelectorsOfClass(cls)) {
        if (keyword.length &&
            [selector rangeOfString:keyword options:NSCaseInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        [matched addObject:selector];
    }
    [matched sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"%@（%lu 个）：%@", className, (unsigned long)matched.count,
            [matched componentsJoinedByString:@", "]];
}

+ (BOOL)sendText:(NSString *)text toSession:(NSString *)session {
    if (!text.length || !session.length) return NO;
    id manager = [self messageManager];
    if (!manager) {
        WXRLog(@"[send] 没有消息服务，发不出去");
        return NO;
    }
    WXRLog(@"[send] 消息服务对象 = %@%@", NSStringFromClass(object_getClass(manager)),
           WXRIsForwardingProxy(manager) ? @"（是转发代理，可能藏在它后面）" : @"");

    // 自动发现：不再依赖硬编码名单，直接看这个微信版本里到底有哪些"像发消息"的方法
    NSMutableArray<NSString *> *discoveredText = [NSMutableArray array];
    NSMutableArray<NSString *> *discoveredWrap = [NSMutableArray array];
    for (NSString *selector in WXRInstanceSelectors(manager)) {
        if (WXRSelectorLooksLikeSendText(selector)) {
            [discoveredText addObject:selector];
        } else if (WXRSelectorLooksLikeSendWrap(selector)) {
            [discoveredWrap addObject:selector];
        }
    }
    NSArray<NSString *> *textSelectors = WXROrderedSendTextSelectors(discoveredText);
    // 单参数的 wrap 发送方法先试（最像微信原来的 SendMsg:，风险也最低）
    NSArray<NSString *> *wrapSelectors = [discoveredWrap sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger arityA = WXRSelectorArity(a);
            NSUInteger arityB = WXRSelectorArity(b);
            if (arityA != arityB) {
                return arityA < arityB ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a compare:b];
        }];
    WXRLog(@"[send] 自动发现：发文本=%@；发 wrap=%@",
           textSelectors.count ? [textSelectors componentsJoinedByString:@", "] : @"（无）",
           wrapSelectors.count ? [wrapSelectors componentsJoinedByString:@", "] : @"（无）");

    id wrap = WXRMakeOutgoingTextWrap(text, session, [self selfUserName]);
    if (!wrap) {
        WXRLog(@"[send] 没能构造 CMessageWrap，只能走「发文本」这一路");
    }

    gSendAttemptIndex = -1;
    BOOL invoked = NO;

    // ① 上次已被微信回调确认过的方式，优先用
    NSArray<NSArray *> *attempts = WXROutgoingAttempts();
    NSInteger working = [[WXRPrefs shared] integerForKey:WXRKeySendStrategy];
    if (working >= 0 && working < (NSInteger)attempts.count) {
        invoked = [self invokeOutgoingAttemptAtIndex:working text:text session:session wrap:wrap];
        if (!invoked) {
            WXRLog(@"[send] 上次确认的方式（第 %ld 种）这次调不通，回到轮转", (long)working + 1);
        }
    }

    // ② 用户显式指定的候选名（含设置里的「候选名覆盖」）
    if (!invoked && [self trySendTextVia:WXRSendTextSelectors() manager:manager text:text session:session]) {
        invoked = YES;
    }
    if (!invoked && [self trySendWrapVia:WXRSendMsgSelectors() manager:manager wrap:wrap]) {
        invoked = YES;
    }

    // ③ 自动发现（名字相近的方法，结果仅供参考）
    if (!invoked && (textSelectors.count || wrapSelectors.count)) {
        WXRLog(@"[send] 候选名都不匹配，改用自动发现（结果仅供参考）");
        if ([self trySendTextVia:textSelectors manager:manager text:text session:session]) {
            invoked = YES;
        } else if ([self trySendWrapVia:wrapSelectors manager:manager wrap:wrap]) {
            invoked = YES;
        }
    }

    // ④ 都失败 → 轮转试一种"出站插入"方式，靠微信自己的回调验证并记住
    if (!invoked && attempts.count) {
        NSInteger next = gSendRotation % (NSInteger)attempts.count;
        invoked = [self invokeOutgoingAttemptAtIndex:next text:text session:session wrap:wrap];
    }

    if (invoked) {
        [WXRSendProbe noteAttemptedContent:text];
        [self scheduleSendConfirmationCheck:text];
        return YES;
    }

    [[self shared] logSendDiagnostics];
    return NO;
}

// 一键试遍所有方式：每个试一次、等 3 秒，没等到上传成功回调就换下一个。
// 这是给使用者自助定案用的（设置里的「试遍所有发送方式」）。
+ (void)tryAllSendAttemptsForSession:(NSString *)session text:(NSString *)text {
    if (!session.length || !text.length) {
        WXRLog(@"[send] 试遍所有方式：缺少会话或内容");
        return;
    }
    WXRLog(@"[send] ===== 开始试遍所有发送方式（共 %lu 种）=====", (unsigned long)WXROutgoingAttempts().count);
    [self trySendAttemptAtIndex:0 session:session text:text];
}

+ (void)trySendAttemptAtIndex:(NSInteger)index session:(NSString *)session text:(NSString *)text {
    NSArray<NSArray *> *attempts = WXROutgoingAttempts();
    if (index < 0 || index >= (NSInteger)attempts.count) {
        WXRLog(@"[send] ===== 所有方式都试完了，都没等到上传成功回调 =====");
        WXRLog(@"[send] 说明问题不在「用哪个方法插入」，而在出站消息的字段或上传触发上："
               @"请打开 设置 → 自动回复 → 发送路径普查（只读），把结果发回；"
               @"同时手动发一条消息，把 [probe] 的「微信自己发消息时调用了…」和「出站消息的完整字段」发回");
        return;
    }
    id wrap = WXRMakeOutgoingTextWrap(text, session, [self selfUserName]);
    if (![self invokeOutgoingAttemptAtIndex:index text:text session:session wrap:wrap]) {
        [self trySendAttemptAtIndex:index + 1 session:session text:text];
        return;
    }
    NSTimeInterval attemptedAt = [[NSDate date] timeIntervalSince1970];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self lastAttemptSucceededAfter:attemptedAt content:text]) {
            [[WXRPrefs shared] setInteger:index forKey:WXRKeySendStrategy];
            WXRLog(@"[send] ✅ 第 %ld 种方式成功，已记住（以后固定用它）：%@",
                   (long)index + 1, [self lastAttemptStateText]);
            return;
        }
        WXRLog(@"[send] 第 %ld 种方式没成功（%@），继续试下一种", (long)index + 1,
               [self lastAttemptStateText]);
        [self trySendAttemptAtIndex:index + 1 session:session text:text];
    });
}

// 调完发送接口后，用微信自己的"发出成功"回调来确认（3 秒窗口）。
// 确认成功 → 记住这种方式；失败 → 下一条消息换下一种，逐条收敛。
+ (void)scheduleSendConfirmationCheck:(NSString *)text {
    NSTimeInterval attemptedAt = [[NSDate date] timeIntervalSince1970];
    NSInteger index = gSendAttemptIndex;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self lastAttemptSucceededAfter:attemptedAt content:text]) {
            if (index >= 0) {
                [[WXRPrefs shared] setInteger:index forKey:WXRKeySendStrategy];
                WXRLog(@"[send] ✅ 已发出，并记住第 %ld 种发送方式：%@", (long)index + 1,
                       [self lastAttemptStateText]);
            } else {
                WXRLog(@"[send] ✅ 已发出：%@", text);
            }
            return;
        }
        if (index >= 0) {
            gSendRotation = index + 1;
            WXRLog(@"[send] ⚠️ 第 %ld 种方式没等到上传成功回调%@，下一条消息改试第 %ld 种",
                   (long)index + 1,
                   gLastAttemptInserted ? @"（消息已入库但没上传）" : @"（连入库都没成功）",
                   (long)(gSendRotation + 1));
        } else {
            WXRLog(@"[send] ⚠️ 3 秒内没等到发送成功回调，这条可能没发出去；"
                   @"请在微信里手动发一条消息，从 [probe] 日志看微信自己用的是哪个方法");
        }
    });
}

// 发送接口可能不在 CMessageMgr 上（8.0.76 就是如此），这儿把可能的类和方法都探一遍。
// 用 class_getInstanceMethod 判断存在性：这是准的，不受 MMServiceWrapper 代理影响。
static NSArray<NSString *> *WXRSendProbeClasses(void) {
    return @[@"CMessageMgr", @"MessageService", @"CMessageService", @"MessageMgr", @"CMsgMgr",
             @"MMMessageService", @"MessageLogicMgr", @"MMMsgLogicMgr", @"CMessageLogicMgr",
             @"MessageSender", @"CMessageSender", @"MMMessageMgr", @"MsgService", @"CMsgService"];
}

static NSArray<NSString *> *WXRSendProbeSelectors(void) {
    return @[@"AsyncSendMsg:", @"SendMsg:", @"SendMsg:Ext:", @"AsyncSendMsg:Ext:",
             @"sendMsg:", @"sendMsg:Ext:", @"SendMsgWrap:", @"sendMsgWrap:",
             @"SendTextMsg:toSession:", @"SendTextMsg:toUsrName:", @"SendTextMsg:",
             @"AsyncSendTextMsg:toSession:", @"AsyncSendTextMsg:toUsrName:",
             @"sendTextMessage:toSession:", @"sendText:toSession:", @"sendText:toUsr:",
             @"sendMessage:toSession:", @"sendMessage:", @"SendMsgToSession:content:",
             @"AddMsgToSendQueue:", @"PostMsg:", @"PushMsg:", @"InsertMsg:",
             @"AddMsg:MsgWrap:", @"AddMsg:", @"SendMsgToUsr:", @"sendTextMsg:toUsr:"];
}

- (void)probeSendInterfaces {
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *className in WXRSendProbeClasses()) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            continue;
        }
        NSMutableArray<NSString *> *related = [NSMutableArray array];
        for (NSString *selector in WXRSelectorsOfClass(cls)) {
            NSString *lower = selector.lowercaseString;
            if ([lower containsString:@"send"] || [lower containsString:@"msg"]) {
                [related addObject:[NSString stringWithFormat:@"%@(%lu)", selector,
                                    (unsigned long)WXRSelectorArity(selector)]];
            }
        }
        if (related.count) {
            [related sortUsingSelector:@selector(compare:)];
            WXRLog(@"[send] 类 %@ 上与发送相关的方法：%@", className,
                   [related componentsJoinedByString:@", "]);
        }
        for (NSString *selector in WXRSendProbeSelectors()) {
            if (class_getInstanceMethod(cls, NSSelectorFromString(selector))) {
                [hits addObject:[NSString stringWithFormat:@"%@ -%@", className, selector]];
            }
        }
    }
    WXRLog(@"[send] 发送接口探测命中：%@",
           hits.count ? [hits componentsJoinedByString:@", "] : @"（候选名字一个都没命中）");
}

- (void)logSendDiagnostics {
    id manager = [[self class] messageManager];
    if (!manager) {
        return;
    }
    NSString *className = NSStringFromClass(object_getClass(manager));
    NSMutableArray<NSString *> *relevant = [NSMutableArray array];
    NSMutableArray<NSString *> *usable = [NSMutableArray array];
    NSMutableArray<NSString *> *everything = [NSMutableArray array];
    for (NSString *selector in WXRInstanceSelectors(manager)) {
        NSString *lower = selector.lowercaseString;
        NSString *described = [NSString stringWithFormat:@"%@(%lu)", selector,
                               (unsigned long)WXRSelectorArity(selector)];
        [everything addObject:described];
        if ([lower containsString:@"send"] || [lower containsString:@"msg"] ||
            [lower containsString:@"text"] || [lower containsString:@"message"]) {
            [relevant addObject:described];
            if (!WXRSelectorLooksLikeMedia(selector)) {
                [usable addObject:described];
            }
        }
    }
    [relevant sortUsingSelector:@selector(compare:)];
    [everything sortUsingSelector:@selector(compare:)];
    WXRLog(@"[send] %@ 上与发送相关的方法（名字(参数个数)），请把这一行发回：%@",
           className, relevant.count ? [relevant componentsJoinedByString:@", "] : @"（一个都没有）");
    // 这两件事每次失败都要做：探明发送接口到底在哪个类上，并给出自救办法
    [self probeSendInterfaces];
    WXRLog(@"[send] 也可以自己在 设置 → 候选名覆盖 里填一行：sendtext=真实方法名（或 sendmsg=真实方法名）");
    if (!usable.count) {
        // 一个像样的都没有 → 把整张方法表也打出来（截断），人工挑出真正的发送接口
        NSString *all = [everything componentsJoinedByString:@", "];
        if (all.length > 4000) {
            all = [[all substringToIndex:4000] stringByAppendingString:@" …(截断)"];
        }
        WXRLog(@"[send] %@ 的全部实例方法（用于人工确认真正的发送接口）：%@", className, all);
    }
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
    [WXRWeChat rememberMessageManager:self];
    // 绝大多数版本 MsgWrap 是第 2 个参数
    dispatch_async(dispatch_get_main_queue(), ^{
        [WXRWeChat handleRawWrap:a2];
    });
}
static void (*gOrig3)(id, SEL, id, id, id) = NULL;
static void WXROnAddMsg3(id self, SEL _cmd, id a1, id a2, id a3) {
    if (gOrig3) gOrig3(self, _cmd, a1, a2, a3);
    [WXRWeChat rememberMessageManager:self];
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
