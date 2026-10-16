#pragma once
#import <UIKit/UIKit.h>

/// 自动回复的设置界面。
/// 入口：微信「我 → 设置」顶部那一行，或长按底部标签栏 1 秒。
@interface WXRSettings : NSObject

+ (void)present;
/// 以只读文本页展示一段内容（日志 / 诊断报告）
+ (void)presentTextPageWithTitle:(NSString *)title text:(NSString *)text;

@end
