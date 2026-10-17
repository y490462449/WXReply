#pragma once
#import <Foundation/Foundation.h>

/// 群消息监控：群聊里命中关键词 → 记录 + 转发到本人微信。
///
/// 关键词在设置里一行一个（也支持逗号分隔），命中任意一个就触发。
@interface WXRGroupMonitor : NSObject

+ (void)start;
/// 设置页显示的一行状态
+ (NSString *)statusLine;
/// 最近命中的记录（文本，给设置页看）
+ (NSString *)recentHitsText;
/// 把最近一次命中（或一条测试消息）转发给自己，用来验证转发链路
+ (void)testForwardLastHit;
/// 自检文本：开关/关键词/管线状态/命中情况，用来看"为什么没触发"
+ (NSString *)diagnosticText;
/// 名字解析诊断（只读）：把结果发回给维护者即可补全群名/昵称
+ (NSString *)nameResolutionDiagnostic;

@end
