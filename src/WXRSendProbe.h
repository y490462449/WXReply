#pragma once
#import <Foundation/Foundation.h>

/// 发送路径探针：只记录、照常放行（不改任何行为）。
///
/// 用来回答两个问题：
///   1) 微信自己发消息时，到底是调哪个方法？（你在微信里手动发一条，日志就会显示）
///   2) 我们调用的那个方法，真的把消息发出去了吗？（靠 OnMessageSentBySender: 回调确认）
@interface WXRSendProbe : NSObject

+ (void)install;

/// 微信回调告知"已发出"时记录（由钩子内部调用）
+ (void)noteSentContent:(NSString *)content;
/// 我们自己尝试发送时记录，便于和上面的回调对上
+ (void)noteAttemptedContent:(NSString *)content;
/// 在 timestamp 之后是否收到过与 content 对应的发送成功回调
+ (BOOL)wasConfirmedAfter:(NSTimeInterval)timestamp content:(NSString *)content;
/// 状态摘要（设置页显示）
+ (NSString *)summary;

@end
