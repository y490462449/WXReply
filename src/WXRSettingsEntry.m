#import "WXRSettingsEntry.h"
#import "WXRSettings.h"
#import "WXRWeChat.h"
#import "WXRHook.h"
#import "WXRPrefs.h"
#import "WXRLog.h"
#import "WXRCommon.h"
#import <objc/runtime.h>

static const void *kWXRTabBarGestureKey = &kWXRTabBarGestureKey;
static NSInteger const kWXRRowTag = 0x5752;    // 'WR'
static NSInteger const kWXRDetailTag = 0x5753;

static IMP gOrigVCViewWillAppear = NULL;
static IMP gOrigTabBarViewDidAppear = NULL;
static UIViewController *gSettingsPage = nil;   // 最近一次识别到的设置页

@interface WXRSettingsEntry ()
+ (BOOL)looksLikeWeChatSettings:(NSString *)className;
+ (UITableView *)firstTableViewIn:(UIView *)view;
+ (void)installRowInTable:(UITableView *)table;
+ (UIView *)makeRowView:(CGRect)frame;
+ (NSString *)compactState;
+ (void)updateDetailLabelIn:(UIView *)row;
+ (void)showLoadedNoticeOnce;
+ (UIViewController *)topViewController;
@end

@interface WXRRowTarget : NSObject
- (void)openSettings;
- (void)longPressed:(UILongPressGestureRecognizer *)press;
@end

@implementation WXRRowTarget

- (void)openSettings {
    WXRLog(@"[entry] 从设置页那一行打开设置");
    [WXRSettings present];
}

- (void)longPressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (![[WXRPrefs shared] boolForKey:WXRKeyTabBarLongPress]) {
        return;
    }
    WXRLog(@"[entry] 长按标签栏打开设置");
    [WXRSettings present];
}

@end

// 手势/点击的 target 不会被持有，必须自己强引用住
static WXRRowTarget *gRowTarget = nil;

/* ---------------- 系统类 hook ---------------- */

static void WXRVCViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigVCViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigVCViewWillAppear)(self, cmd, animated);
    }
    @try {
        [WXRSettingsEntry considerViewController:(UIViewController *)self];
    } @catch (NSException *e) {
        WXRLog(@"[entry] 检查设置页出错：%@", e.reason);
    }
}

static void WXRTabBarViewDidAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigTabBarViewDidAppear) {
        ((void (*)(id, SEL, BOOL))gOrigTabBarViewDidAppear)(self, cmd, animated);
    }
    @try {
        UITabBarController *tab = (UITabBarController *)self;
        [WXRSettingsEntry attachLongPressToTabBar:tab.tabBar];
    } @catch (NSException *e) {
        WXRLog(@"[entry] 安装标签栏长按出错：%@", e.reason);
    }
}

/* ---------------- 入口实现 ---------------- */

@implementation WXRSettingsEntry

+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gRowTarget) {
            gRowTarget = [[WXRRowTarget alloc] init];
        }
        BOOL hookedPage = [WXRHook hookClass:@"UIViewController"
                                    selector:@"viewWillAppear:"
                               isClassMethod:NO
                                 replacement:(IMP)WXRVCViewWillAppear
                                    original:&gOrigVCViewWillAppear
                                        note:@"识别微信设置页并插入自动回复入口"];
        BOOL hookedTab = [WXRHook hookClass:@"UITabBarController"
                                   selector:@"viewDidAppear:"
                              isClassMethod:NO
                                replacement:(IMP)WXRTabBarViewDidAppear
                                   original:&gOrigTabBarViewDidAppear
                                       note:@"长按标签栏打开设置（兜底入口）"];
        WXRLog(@"[entry] 入口安装完成：设置页=%@，标签栏=%@",
               hookedPage ? @"已挂上" : @"没挂上", hookedTab ? @"已挂上" : @"没挂上");
        [self showLoadedNoticeOnce];
    });
}

+ (void)considerViewController:(UIViewController *)viewController {
    if (![viewController isKindOfClass:[UIViewController class]]) {
        return;
    }
    NSString *className = NSStringFromClass([viewController class]);
    if (![self looksLikeWeChatSettings:className]) {
        return;
    }
    UITableView *table = [self firstTableViewIn:viewController.view];
    if (!table) {
        return;
    }
    if (gSettingsPage != viewController) {
        gSettingsPage = viewController;
        WXRLog(@"[entry] 找到设置页：%@", className);
    }
    [self installRowInTable:table];
}

+ (BOOL)looksLikeWeChatSettings:(NSString *)className {
    if (!className.length) {
        return NO;
    }
    NSString *lower = className.lowercaseString;
    // 只认"设置根页面"，避免在设置里的各个二级页面也插一行
    return [lower containsString:@"newsetting"] || [lower isEqualToString:@"settingsviewcontroller"];
}

+ (UITableView *)firstTableViewIn:(UIView *)view {
    if (!view) {
        return nil;
    }
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }
    for (UIView *sub in view.subviews) {
        UITableView *found = [self firstTableViewIn:sub];
        if (found) {
            return found;
        }
    }
    return nil;
}

+ (void)installRowInTable:(UITableView *)table {
    UIView *header = table.tableHeaderView;
    if (header && header.tag == kWXRRowTag) {
        [self updateDetailLabelIn:header];
        return;                      // 已经插过了，只刷新状态
    }

    CGFloat width = table.bounds.size.width;
    if (width < 1) {
        width = UIScreen.mainScreen.bounds.size.width;
    }
    CGFloat rowHeight = 54;
    CGFloat existingHeight = header ? header.frame.size.height : 0;

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, rowHeight + existingHeight)];
    container.tag = kWXRRowTag;
    container.backgroundColor = UIColor.clearColor;

    UIView *row = [self makeRowView:CGRectMake(0, 0, width, rowHeight)];
    [container addSubview:row];

    if (header) {                    // 保留微信原本的头部（一般是占位），放到我们下面
        header.frame = CGRectMake(0, rowHeight, width, existingHeight);
        [container addSubview:header];
    }
    table.tableHeaderView = container;
    WXRLog(@"[entry] 已插入「自动回复」入口行（表宽 %.0f）", width);
}

+ (UIView *)makeRowView:(CGRect)frame {
    UIView *row = [[UIView alloc] initWithFrame:frame];
    row.backgroundColor = UIColor.whiteColor;
    row.userInteractionEnabled = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, frame.size.width - 130, frame.size.height)];
    title.text = @"自动回复";
    title.font = [UIFont systemFontOfSize:17];
    title.textColor = UIColor.blackColor;
    [row addSubview:title];

    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(frame.size.width - 116, 0, 86, frame.size.height)];
    detail.tag = kWXRDetailTag;
    detail.text = [self compactState];
    detail.textAlignment = NSTextAlignmentRight;
    detail.font = [UIFont systemFontOfSize:13];
    detail.textColor = [UIColor grayColor];
    [row addSubview:detail];

    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(frame.size.width - 26, 0, 18, frame.size.height)];
    chevron.text = @"\u203a";
    chevron.textAlignment = NSTextAlignmentCenter;
    chevron.font = [UIFont systemFontOfSize:20];
    chevron.textColor = [UIColor lightGrayColor];
    [row addSubview:chevron];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - 0.5, frame.size.width, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [row addSubview:line];

    [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gRowTarget
                                                                     action:@selector(openSettings)]];
    return row;
}

+ (NSString *)compactState {
    WXRPrefs *prefs = [WXRPrefs shared];
    if (![prefs boolForKey:WXRKeyEnabled]) {
        return @"未开启";
    }
    return [prefs boolForKey:WXRKeyAIEnabled] ? @"AI 回复" : @"规则回复";
}

+ (void)updateDetailLabelIn:(UIView *)row {
    for (UIView *sub in row.subviews) {
        if (sub.tag == kWXRDetailTag && [sub isKindOfClass:[UILabel class]]) {
            ((UILabel *)sub).text = [self compactState];
        }
    }
}

+ (void)refreshRowState {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *page = gSettingsPage;
        if (!page) {
            return;
        }
        UITableView *table = [self firstTableViewIn:page.view];
        UIView *header = table.tableHeaderView;
        if (header && header.tag == kWXRRowTag) {
            [self updateDetailLabelIn:header];
        }
    });
}

+ (void)attachLongPressToTabBar:(UITabBar *)tabBar {
    if (![tabBar isKindOfClass:[UITabBar class]]) {
        return;
    }
    if (objc_getAssociatedObject(tabBar, kWXRTabBarGestureKey)) {
        return;
    }
    objc_setAssociatedObject(tabBar, kWXRTabBarGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:gRowTarget
                                                                                        action:@selector(longPressed:)];
    press.minimumPressDuration = 1.0;
    press.cancelsTouchesInView = NO;
    [tabBar addGestureRecognizer:press];
    WXRLog(@"[entry] 已安装「长按底部标签栏 1 秒打开设置」");
}

/* ---------------- 首次加载提示 ---------------- */

+ (void)showLoadedNoticeOnce {
    WXRPrefs *prefs = [WXRPrefs shared];
    if ([prefs boolForKey:WXRKeyLoadedNotice]) {
        return;
    }
    [prefs setBool:YES forKey:WXRKeyLoadedNotice];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {
            WXRLog(@"[entry] 首次提示：找不到可弹窗的控制器");
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"WXReply 已加载"
                             message:@"自动回复的设置入口：微信「我 \u2192 设置」顶部新增的一行「自动回复」。\n也可以长按底部标签栏 1 秒打开。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"打开设置" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [WXRSettings present];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"诊断报告" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSArray<NSString *> *lines = WXRLogSnapshot();
            NSString *text = [NSString stringWithFormat:@"%@\n\n%@\n\n===== 最近日志 =====\n%@",
                              [WXRWeChat diagnosticReport],
                              [WXRWeChat candidateReport],
                              [lines componentsJoinedByString:@"\n"]];
            [WXRSettings presentTextPageWithTitle:@"WXReply 诊断" text:text];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

+ (UIViewController *)topViewController {
    UIWindow *key = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.isKeyWindow) {
            key = window;
            break;
        }
    }
    if (!key) {
        key = UIApplication.sharedApplication.windows.firstObject;
    }
    UIViewController *top = key.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

@end
