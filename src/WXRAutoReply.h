#pragma once
#import <Foundation/Foundation.h>

/// 自动回复引擎（本项目唯一的功能）。
///
/// 回复来源有两级，先命中先用：
///   1) 关键词规则：设置里一行一条「关键词 => 回复内容」；
///   2) 默认回复：没命中规则时用它；
///   3) 可选 AI：开关打开且填好接口/Key/模型时，改为让模型生成（规则与默认回复都不再用）。
///
/// 触发条件：总开关打开、是收到的文本消息、按设置过滤私聊/群聊、同会话冷却未到。
@interface WXRAutoReply : NSObject

+ (void)start;
+ (void)handleWrap:(id)wrap;

/// 设置页/诊断里显示的一行状态
+ (NSString *)statusLine;
/// 清空会话冷却（设置页用）
+ (void)clearCooldown;
/// 测试 AI 接口是否可用
+ (void)testAIConnection:(void (^)(BOOL ok, NSString *message))completion;

@end
