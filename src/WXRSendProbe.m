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

static void WXRProbeNoteCall(NSString *selector, id a1, id a2, BOOL hasSecond) {
    BOOL outgoing = WXRLooksOutgoing(a1) || WXRLooksOutgoing(a2);
    if (outgoing) {
        WXRLog(@"[probe] 微信自己发消息时调用了 %@：a1=%@ a2=%@", selector, WXRBriefArg(a1),
               hasSecond ? WXRBriefArg(a2) : @"(无)");
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

@implementation WXRSendProbe

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

    WXRLog(@"[probe] 发送路径探针已安装：在微信里手动发一条消息，就能看出微信自己用的是哪个方法");
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
