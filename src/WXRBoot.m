//
//  WXRBoot.m
//  插件入口：dylib 被 dyld 加载时构造函数就会跑（早于微信的 main）。
//  这里只做三件事：读配置、装自动回复、装设置入口。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "WXRCommon.h"
#import "WXRLog.h"
#import "WXRPrefs.h"
#import "WXRWeChat.h"
#import "WXRAutoReply.h"
#import "WXRSettingsEntry.h"

static NSInteger gHookRetry = 0;

/// 微信的"新消息回调"类名/方法名各版本可能不同，第一次挂不上就退避重试；
/// 全都挂不上时不是崩溃，而是留日志，让使用者用「候选名覆盖」自己填。
static void WXRInstallMessageHooks(void) {
    if ([WXRWeChat installMessageHooks]) {
        return;
    }
    if (gHookRetry++ >= 10) {
        WXRLog(@"[init] 自动挂新消息回调失败；请在设置→诊断报告里查看候选名，再用「候选名覆盖」修正");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WXRInstallMessageHooks();
    });
}

__attribute__((constructor)) static void WXRBoot(void) {
    @autoreleasepool {
        // 构造函数跑得太早，UIKit 还没就绪，丢到主队列尾部
        dispatch_async(dispatch_get_main_queue(), ^{
            NSBundle *bundle = [NSBundle mainBundle];
            WXRLog(@"[init] ===== %@ %@ 启动 =====", WXR_NAME, WXR_VERSION);
            WXRLog(@"[init] 宿主=%@ 版本=%@", [bundle bundleIdentifier] ?: @"?",
                   [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");

            [WXRPrefs shared];        // 建档配置（默认值 + 磁盘覆盖）
            [WXRWeChat start];        // 记录自身身份、探测服务
            [WXRAutoReply start];     // 唯一的业务：自动回复
            WXRInstallMessageHooks();
            [WXRSettingsEntry install];
        });
    }
}
