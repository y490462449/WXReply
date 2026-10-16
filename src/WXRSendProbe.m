#import "WXRSendProbe.h"
#import "WXRWeChat.h"
#import "WXRHook.h"
#import "WXRLog.h"

static BOOL gProbeInstalled = NO;
static NSString *gLastSentContent = nil;
static NSTimeInterval gLastSentAt = 0;
static NSInteger gSentCount = 0;
static NSString *gAttemptedContent = nil;
static NSTimeInterval gAttemptedAt = 0;

static NSString *WXRBriefWrap(id wrap) {
    if (!wrap) {
        return @"nil";
    }
    NSString *from = [WXRWeChat fromOfWrap:wrap];
    NSString *to = [WXRWeChat toOfWrap:wrap];
    NSString *content = [WXRWeChat contentOfWrap:wrap];
    return [NSString stringWithFormat:@"from=%@ to=%@ type=%ld 正文=%@",
            from ?: @"?", to ?: @"?", (long)[WXRWeChat typeOfWrap:wrap],
            content.length ? [NSString stringWithFormat:@"<%lu 字>", (unsigned long)content.length] : @"(空)"];
}

static NSString *WXRBriefArg(id arg) {
    if (!arg) {
        return @"nil";
    }
    if ([arg isKindOfClass:[NSString class]]) {
        return (NSString *)arg;
    }
    if ([arg isKindOfClass:[NSNumber class]]) {
        return [arg stringValue];
    }
    NSString *className = NSStringFromClass(object_getClass(arg));
    if ([className containsString:@"Wrap"]) {
        return WXRBriefWrap(arg);
    }
    return className;
}

static BOOL WXRLooksOutgoing(id wrap) {
    if (!wrap) {
        return NO;
    }
    NSString *from = [WXRWeChat fromOfWrap:wrap];
    NSString *selfName = [WXRWeChat selfUserName];
    return from.length && selfName.length && [from isEqualToString:selfName];
}

/* ---------------- 发送结果回调：确认到底发出去没有 ---------------- */

static void (*gOrigSentBySender)(id, SEL, id) = NULL;
static void WXRProbeSentBySender(id self, SEL _cmd, id a1) {
    [WXRSendProbe noteSentContent:[WXRWeChat contentOfWrap:a1]];
    WXRLog(@"[probe] ✅ 微信发出成功回调 %@：%@", NSStringFromSelector(_cmd), WXRBriefWrap(a1));
    if (gOrigSentBySender) {
        gOrigSentBySender(self, _cmd, a1);
    }
}

static void (*gOrigSendFail)(id, SEL, id) = NULL;
static void WXRProbeSendFail(id self, SEL _cmd, id a1) {
    WXRLog(@"[probe] ❌ 微信发送失败回调 %@：%@", NSStringFromSelector(_cmd), WXRBriefWrap(a1));
    if (gOrigSendFail) {
        gOrigSendFail(self, _cmd, a1);
    }
}

/* ---------------- 出站插入：看微信自己发消息时调哪个 ---------------- */

static BOOL gOurCallInProgress = NO;

static void WXRProbeNoteCall(NSString *selector, id a1, id a2, BOOL hasSecond) {
    BOOL firstOutgoing = WXRLooksOutgoing(a1);
    BOOL secondOutgoing = WXRLooksOutgoing(a2);
    if (gOurCallInProgress) {
        WXRLogVerbose(@"[probe] 我们自己调用了 %@（插入本地消息）", selector);
        return;
    }
    if (firstOutgoing || secondOutgoing) {
        WXRLog(@"[probe] 微信自己发消息时调用了 %@：a1=%@ a2=%@", selector, WXRBriefArg(a1),
               hasSecond ? WXRBriefArg(a2) : @"(无)");
        // 出站消息的真实字段，是我们构造 wrap 的唯一参照（少了字段就会"一直转圈发不出去"）
        id wrap = secondOutgoing ? a2 : a1;
        WXRLog(@"[probe] 出站消息的完整字段（照这个构造）：\n%@",
               [WXRWeChat describeObject:wrap maxLength:5000]);
    } else {
        WXRLogVerbose(@"[probe] %@ 被调用（a1=%@）", selector, WXRBriefArg(a1));
    }
}

static void (*gOrigAddLocal)(id, SEL, id, id) = NULL;
static void WXRProbeAddLocal(id self, SEL _cmd, id a1, id a2) {
    WXRProbeNoteCall(NSStringFromSelector(_cmd), a1, a2, YES);
    if (gOrigAddLocal) {
        gOrigAddLocal(self, _cmd, a1, a2);
    }
}

static void (*gOrigAddUniqueLocal)(id, SEL, id, id) = NULL;
static void WXRProbeAddUniqueLocal(id self, SEL _cmd, id a1, id a2) {
    WXRProbeNoteCall(NSStringFromSelector(_cmd), a1, a2, YES);
    if (gOrigAddUniqueLocal) {
        gOrigAddUniqueLocal(self, _cmd, a1, a2);
    }
}

static void (*gOrigAddMsg)(id, SEL, id, id) = NULL;
static void WXRProbeAddMsg(id self, SEL _cmd, id a1, id a2) {
    WXRProbeNoteCall(NSStringFromSelector(_cmd), a1, a2, YES);
    if (gOrigAddMsg) {
        gOrigAddMsg(self, _cmd, a1, a2);
    }
}

static void (*gOrigModMsg)(id, SEL, id, id) = NULL;
static void WXRProbeModMsg(id self, SEL _cmd, id a1, id a2) {
    WXRProbeNoteCall(NSStringFromSelector(_cmd), a1, a2, YES);
    if (gOrigModMsg) {
        gOrigModMsg(self, _cmd, a1, a2);
    }
}

static void (*gOrigResendMsg)(id, SEL, id, id) = NULL;
static void WXRProbeResendMsg(id self, SEL _cmd, id a1, id a2) {
    WXRProbeNoteCall(NSStringFromSelector(_cmd), a1, a2, YES);
    if (gOrigResendMsg) {
        gOrigResendMsg(self, _cmd, a1, a2);
    }
}

static void (*gOrigAddLocal4)(id, SEL, id, id, id, id) = NULL;
static void WXRProbeAddLocal4(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    WXRProbeNoteCall(NSStringFromSelector(_cmd), a1, a2, YES);
    if (gOrigAddLocal4) {
        gOrigAddLocal4(self, _cmd, a1, a2, a3, a4);
    }
}

/* ---------------- 广谱探针：找出"插入之后到底谁负责上传" ---------------- */

static NSMutableDictionary<NSString *, NSValue *> *gBroadOriginals = nil;
static NSMutableSet<NSString *> *gBroadHooked = nil;

static void WXRBroadNote(SEL _cmd, NSArray<NSString *> *args) {
    NSString *selector = NSStringFromSelector(_cmd);
    if (gOurCallInProgress) {
        WXRLogVerbose(@"[probe] 我们自己调用了 %@", selector);
        return;
    }
    NSString *lower = selector.lowercaseString;
    NSString *line = [NSString stringWithFormat:@"微信调用了 %@（%@）", selector,
                      args.count ? [args componentsJoinedByString:@", "] : @"无参数"];
    if ([lower containsString:@"send"] || [lower containsString:@"upload"]) {
        WXRLog(@"[probe] %@", line);
    } else {
        WXRLogVerbose(@"[probe] %@", line);
    }
}

static IMP WXRBroadOriginal(SEL _cmd) {
    NSValue *value = nil;
    @synchronized (gBroadOriginals) {
        value = gBroadOriginals[NSStringFromSelector(_cmd)];
    }
    return value ? (IMP)[value pointerValue] : NULL;
}

static void WXRBroadCall0(id self, SEL _cmd) {
    WXRBroadNote(_cmd, @[]);
    IMP original = WXRBroadOriginal(_cmd);
    if (original) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
}

static void WXRBroadCall1(id self, SEL _cmd, id a1) {
    WXRBroadNote(_cmd, @[WXRBriefArg(a1)]);
    IMP original = WXRBroadOriginal(_cmd);
    if (original) {
        ((void (*)(id, SEL, id))original)(self, _cmd, a1);
    }
}

static void WXRBroadCall2(id self, SEL _cmd, id a1, id a2) {
    WXRBroadNote(_cmd, @[WXRBriefArg(a1), WXRBriefArg(a2)]);
    IMP original = WXRBroadOriginal(_cmd);
    if (original) {
        ((void (*)(id, SEL, id, id))original)(self, _cmd, a1, a2);
    }
}

static void WXRBroadCall3(id self, SEL _cmd, id a1, id a2, id a3) {
    WXRBroadNote(_cmd, @[WXRBriefArg(a1), WXRBriefArg(a2), WXRBriefArg(a3)]);
    IMP original = WXRBroadOriginal(_cmd);
    if (original) {
        ((void (*)(id, SEL, id, id, id))original)(self, _cmd, a1, a2, a3);
    }
}

@implementation WXRSendProbe

+ (void)installBroadProbes {
    gBroadOriginals = [NSMutableDictionary dictionary];
    gBroadHooked = [NSMutableSet set];

    NSMutableSet<NSString *> *alreadyHooked = [NSMutableSet set];
    for (WXRHookRecord *record in [WXRHook records]) {
        if (record.attached && record.selector.length) {
            [alreadyHooked addObject:[NSString stringWithFormat:@"%@-%@",
                                      record.className ?: @"", record.selector]];
        }
    }

    NSArray<NSString *> *classNames = @[@"CMessageMgr", @"BaseMsgContentViewController",
                                        @"MMMsgContentViewController", @"ChatRoomViewController",
                                        @"MMInputToolView", @"ChatInputToolView", @"BaseChatViewController"];
    NSInteger hooked = 0;
    for (NSString *className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            continue;
        }
        for (NSString *selector in [WXRWeChat selectorsOfClassNamed:className]) {
            NSString *lower = selector.lowercaseString;
            if (!([lower containsString:@"send"] || [lower containsString:@"upload"] ||
                  [lower containsString:@"sync"] || [lower containsString:@"push"] ||
                  [lower containsString:@"post"])) {
                continue;
            }
            if ([alreadyHooked containsObject:[NSString stringWithFormat:@"%@-%@", className, selector]]) {
                continue;
            }
            SEL sel = NSSelectorFromString(selector);
            NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:sel];
            if (!signature) {
                continue;
            }
            NSInteger count = (NSInteger)signature.numberOfArguments - 2;   // 去掉 self / _cmd
            if (count < 0 || count > 3) {
                continue;
            }
            BOOL allObjects = YES;
            for (NSInteger i = 2; i < (NSInteger)signature.numberOfArguments; i++) {
                const char *type = [signature getArgumentTypeAtIndex:(NSUInteger)i];
                if (!type || type[0] != '@') {
                    allObjects = NO;      // 参数里有标量：用对象 trampoline 会 ABI 错位，宁可不挂
                    break;
                }
            }
            if (!allObjects) {
                continue;
            }
            IMP replacement = (count == 0) ? (IMP)WXRBroadCall0 :
                              (count == 1) ? (IMP)WXRBroadCall1 :
                              (count == 2) ? (IMP)WXRBroadCall2 : (IMP)WXRBroadCall3;
            IMP originalOut = NULL;
            if ([WXRHook hookClass:className selector:selector isClassMethod:NO
                       replacement:replacement original:&originalOut
                              note:@"发送路径广谱探针"]) {
                if (originalOut) {
                    @synchronized (gBroadOriginals) {
                        gBroadOriginals[selector] = [NSValue valueWithPointer:(void *)originalOut];
                    }
                }
                [gBroadHooked addObject:[NSString stringWithFormat:@"%@-%@", className, selector]];
                hooked++;
            }
        }
    }
    WXRLog(@"[probe] 广谱发送探针挂了 %ld 个方法：你在微信里手动发一条消息，就能看到完整调用序列", (long)hooked);
}

+ (void)install {
    if (gProbeInstalled) {
        return;
    }
    gProbeInstalled = YES;
    NSArray<NSString *> *classes = @[@"CMessageMgr", @"MessageService", @"CMessageService", @"MessageMgr"];

    [WXRHook hookAnyClass:classes selector:@"OnMessageSentBySender:" isClassMethod:NO
              replacement:(IMP)WXRProbeSentBySender original:(IMP *)&gOrigSentBySender
                     note:@"发送成功回调"];
    [WXRHook hookAnyClass:classes selector:@"OnSendMessageFail:" isClassMethod:NO
              replacement:(IMP)WXRProbeSendFail original:(IMP *)&gOrigSendFail
                     note:@"发送失败回调"];
    [WXRHook hookAnyClass:classes selector:@"AddLocalMsg:MsgWrap:" isClassMethod:NO
              replacement:(IMP)WXRProbeAddLocal original:(IMP *)&gOrigAddLocal
                     note:@"出站消息插入(AddLocalMsg)"];
    [WXRHook hookAnyClass:classes selector:@"AddUniqueLocalMsg:MsgWrap:" isClassMethod:NO
              replacement:(IMP)WXRProbeAddUniqueLocal original:(IMP *)&gOrigAddUniqueLocal
                     note:@"出站消息插入(AddUniqueLocalMsg)"];
    [WXRHook hookAnyClass:classes selector:@"AddMsg:MsgWrap:" isClassMethod:NO
              replacement:(IMP)WXRProbeAddMsg original:(IMP *)&gOrigAddMsg
                     note:@"消息插入(AddMsg)"];
    [WXRHook hookAnyClass:classes selector:@"ModMsg:MsgWrap:" isClassMethod:NO
              replacement:(IMP)WXRProbeModMsg original:(IMP *)&gOrigModMsg
                     note:@"消息修改(ModMsg)"];
    [WXRHook hookAnyClass:classes selector:@"ResendMsg:MsgWrap:" isClassMethod:NO
              replacement:(IMP)WXRProbeResendMsg original:(IMP *)&gOrigResendMsg
                     note:@"消息重发(ResendMsg)"];
    [WXRHook hookAnyClass:classes selector:@"AddLocalMsg:MsgWrap:fixTime:NewMsgArriveNotify:" isClassMethod:NO
              replacement:(IMP)WXRProbeAddLocal4 original:(IMP *)&gOrigAddLocal4
                     note:@"出站消息插入(AddLocalMsg 4 参数)"];

    WXRLog(@"[probe] 发送路径探针已安装：在微信里手动发一条消息，就能看出微信自己用的是哪个方法");
    [self installBroadProbes];
}

+ (void)beginOurCall {
    @synchronized ([self class]) {
        gOurCallInProgress = YES;
    }
}

+ (void)endOurCall {
    @synchronized ([self class]) {
        gOurCallInProgress = NO;
    }
}

+ (void)noteSentContent:(NSString *)content {
    @synchronized ([self class]) {
        gSentCount++;
        gLastSentAt = [[NSDate date] timeIntervalSince1970];
        gLastSentContent = [content copy];
    }
}

+ (void)noteAttemptedContent:(NSString *)content {
    @synchronized ([self class]) {
        gAttemptedAt = [[NSDate date] timeIntervalSince1970];
        gAttemptedContent = [content copy];
    }
}

+ (BOOL)wasConfirmedAfter:(NSTimeInterval)timestamp content:(NSString *)content {
    @synchronized ([self class]) {
        if (gLastSentAt < timestamp) {
            return NO;
        }
        if (!content.length || !gLastSentContent.length) {
            return YES;      // 时间对得上就算确认
        }
        return [gLastSentContent isEqualToString:content];
    }
}

+ (NSString *)summary {
    @synchronized ([self class]) {
        if (!gSentCount) {
            return @"还没观察到发送成功回调";
        }
        return [NSString stringWithFormat:@"已确认发出 %ld 条，最近一次：%@", (long)gSentCount,
                gLastSentContent.length ? gLastSentContent : @"(空内容)"];
    }
}

@end
