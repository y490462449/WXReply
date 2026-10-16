//
//  WXRCommon.h
//  WXReply —— 只做一件事：微信自动回复。
//
//  设计约束（按使用者要求）：
//   - 只有一个功能：自动回复；不做防撤回、媒体、抢红包等任何其它模块；
//   - 没有悬浮窗：设置入口放在微信「我 → 设置」页面里；
//   - 纯 Objective-C runtime 方法交换，不链接 CydiaSubstrate，可在 TrollStore+TrollFools 下加载。
//

#pragma once
#import <Foundation/Foundation.h>

#define WXR_VERSION   @"1.0.0"
#define WXR_NAME      @"WXReply"
#define WXR_LOG_FILE  @"wxreply.log"
// 编译时间戳：用来一眼确认"手机上跑的到底是哪一版"（排查时最省时间的一条信息）
#define WXR_BUILD_STAMP (@"built " __DATE__ " " __TIME__)

/// 配置变化通知（收到后重新读 WXRPrefs 即可）
extern NSString *const WXRPrefsChangedNotification;

/* ---------------- 自动回复 ---------------- */
extern NSString *const WXRKeyEnabled;            // BOOL 总开关
extern NSString *const WXRKeyPrivateOnly;        // BOOL 只回私聊
extern NSString *const WXRKeyGroupMentionOnly;   // BOOL 群里仅在 @我 时回复
extern NSString *const WXRKeyCooldown;           // int  同一会话冷却秒数
extern NSString *const WXRKeyDefaultReply;       // 文本 没命中关键词时用的回复
extern NSString *const WXRKeyRules;              // 文本 关键词规则，一行一条：关键词 => 回复内容

/* ---------------- AI 回复（可选，可不填） ---------------- */
extern NSString *const WXRKeyAIEnabled;          // BOOL 用 AI 生成回复（填了下面几项才有用）
extern NSString *const WXRKeyAIBaseURL;          // OpenAI 兼容接口，如 https://api.deepseek.com/v1
extern NSString *const WXRKeyAIAPIKey;
extern NSString *const WXRKeyAIModel;
extern NSString *const WXRKeyAISystemPrompt;
extern NSString *const WXRKeyAIMaxLength;        // int 回复最大字数
extern NSString *const WXRKeyAITemperature;      // double
extern NSString *const WXRKeyAIContextMessages;  // int 带上文条数

/* ---------------- 入口与诊断 ---------------- */
extern NSString *const WXRKeyTabBarLongPress;    // BOOL 长按底部标签栏也能进设置（设置页入口的兜底）
extern NSString *const WXRKeyLoadedNotice;       // BOOL 首次加载提示是否已弹过
extern NSString *const WXRKeyVerboseLog;         // BOOL 详细日志
extern NSString *const WXRKeyLogContent;         // BOOL 日志是否记录消息正文（默认关）
extern NSString *const WXRKeyOverrideText;       // 候选名覆盖原文（适配不同微信版本）
extern NSString *const WXRKeyOverrideMap;        // 解析后的候选名覆盖表
extern NSString *const WXRKeySendStrategy;       // int 已确认可用的发送方式编号（-1 = 还没确定）
