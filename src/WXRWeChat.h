#pragma once
#import <Foundation/Foundation.h>

typedef void (^WXRMessageHandler)(id wrap);

/// 微信内部对象的定位与安全访问层。
/// 微信没有公开 API，所有类名/字段名都是"候选列表 + 存在才用"，
/// 具体版本的真实名字请用 设置 → 诊断 → 导出类名，把结果发回给维护者补全。
@interface WXRWeChat : NSObject

/// 记录自身身份、探测服务是否可用（可重复调用，内部有缓存与重试）
+ (void)start;

/// 取微信内部服务对象（等价于 [MMServiceCenter getService:]）
+ (id)serviceForClass:(NSString *)className;
+ (id)messageManager;
+ (id)contactManager;
+ (id)groupManager;
+ (id)selfContact;
+ (NSString *)selfUserName;
+ (NSString *)selfDisplayName;

/* ---------- CMessageWrap 字段读取（字段名按版本候选） ---------- */
+ (NSString *)contentOfWrap:(id)wrap;
+ (NSString *)msgSourceOfWrap:(id)wrap;      // 原始 m_nsMsgSource（群消息来源 XML）
+ (NSInteger)typeOfWrap:(id)wrap;
+ (NSString *)fromOfWrap:(id)wrap;
+ (NSString *)toOfWrap:(id)wrap;
+ (NSString *)sessionOfWrap:(id)wrap;
+ (NSString *)actualSenderOfWrap:(id)wrap;   // 群消息里的真实发送者
+ (long long)messageIdOfWrap:(id)wrap;
+ (long long)serverIdOfWrap:(id)wrap;
+ (NSTimeInterval)timeOfWrap:(id)wrap;
+ (BOOL)isSystemWrap:(id)wrap;
+ (BOOL)isGroupSession:(NSString *)session;

/* ---------- 发消息 ---------- */
+ (BOOL)sendText:(NSString *)text toSession:(NSString *)session;

/* ---------- 收消息管线 ---------- */
+ (void)addMessageHandler:(WXRMessageHandler)handler;
/// 处理一条原始 MsgWrap（由 hook 回调进来，也可手工调用做测试）
+ (void)handleRawWrap:(id)wrap;
/// 挂上"新消息"回调（尝试所有已知候选 selector，第一个挂上的生效）
+ (BOOL)installMessageHooks;
/// 新消息回调是否已经挂上（自检用）
+ (BOOL)messageHooksInstalled;

/* ---------- 诊断 ---------- */
/// 把一个对象的全部 ivar（含父类）转成文本，用于确认字段真实名字
+ (NSString *)describeObject:(id)object maxLength:(NSUInteger)maxLength;
/// 本插件依赖的类/方法探测表：类名 -> 关心的 selector 列表
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)diagnosticProbes;
/// 探测报告：哪些类/方法在你这个微信版本里真实存在（把结果发回给维护者即可补全 hook）
+ (NSString *)diagnosticReport;
/// 当前生效的候选名清单（含用户在设置里做的覆盖）
+ (NSString *)candidateReport;

@end
