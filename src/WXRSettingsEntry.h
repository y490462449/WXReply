#pragma once
#import <UIKit/UIKit.h>

/// 设置入口。没有悬浮窗，入口就两条：
///   1) 微信「我 → 设置」页面顶部插入一行「自动回复」（主入口）；
///   2) 长按底部标签栏 1 秒（兜底，用系统类实现，不依赖任何微信内部类名）。
/// 另外首次加载会弹一次提示，兼作"dylib 到底加载了没"的正向信号。
@interface WXRSettingsEntry : NSObject

+ (void)install;
/// 配置变化后刷新那一行的状态文字
+ (void)refreshRowState;
/// 检查某个控制器是不是微信的设置页，是就往里插入口
+ (void)considerViewController:(UIViewController *)viewController;
/// 给标签栏装长按手势（可重复调用）
+ (void)attachLongPressToTabBar:(UITabBar *)tabBar;

@end
