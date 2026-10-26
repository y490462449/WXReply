#pragma once
#import <Foundation/Foundation.h>

typedef void (^WXRMessageHandler)(id wrap);

/// 微信内部对象的定位与安全访问层。
/// 微信没有公开 API，所有类名/字段名都是"候选列表 + 存在才用"，
/// 具体版本的真实名字请用 设置 → 诊断 → 导出类名，把结果发回给维护者补全。
@interface WXRWeChat : NSObject

/// 记录自身身份、探测服务是否可用（可重复调用，内部有缓存与重试）
+ (void)start;

/// 收消息回调的接收者就是真实的（没被包装的）消息服务实例，收到消息时记下来
+ (void)rememberMessageManager:(id)manager;
/// 从别的对象（如代理）抓到的真实服务实例，记下来备用
+ (void)rememberContactManager:(id)manager;
/// 抓到真实的服务总线实例就用它（有些版本 MMServiceCenter defaultCenter 返回 nil）
+ (void)adoptServiceCenter:(id)center;
/// 装"抓服务实例"的钩子（只读捕获 + 照常放行）
+ (void)installServiceCaptureHooks;

/// 列出某个类的实例方法名（含父类链）；类不存在时返回空数组
+ (NSArray<NSString *> *)selectorsOfClassNamed:(NSString *)className;

/// 取微信内部服务对象（等价于 [MMServiceCenter getService:]）
+ (id)serviceForClass:(NSString *)className;
+ (id)messageManager;
+ (id)contactManager;
+ (id)groupManager;
+ (id)selfContact;
+ (NSString *)selfUserName;
+ (NSString *)selfDisplayName;
/// 群名/好友备注/昵称解析（群 ID 传 @chatroom 会返回群名称）；查不到返回 nil
+ (NSString *)displayNameForUser:(NSString *)userName;
/// 只读诊断：某个微信号的 CContact 解析过程与真实字段（把结果发回给维护者）
+ (NSString *)describeContactForUser:(NSString *)userName;
/// 只读诊断：服务中心/服务获取全过程（contactManager 为 nil 时用它定位）
+ (NSString *)serviceDiagnosticText;
/// 只读诊断：列出某个类里名字包含关键字的实例方法
+ (NSString *)methodNamesOfClass:(NSString *)className containing:(NSString *)keyword;
/// 只读诊断：列出对象上所有"非空字符串"字段（名字字段一般都能在这里看到）
+ (NSString *)nonEmptyStringFieldsOfObject:(id)object maxLength:(NSUInteger)maxLength;

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
/// 依次试遍所有"出站插入"方式，每种等 3 秒看有没有上传成功回调；成功就记住
+ (void)tryAllSendAttemptsForSession:(NSString *)session text:(NSString *)text;
/// 消息的本地 id（读会话历史时用）
+ (NSInteger)localIDOfWrap:(id)wrap;
/// 读会话历史（给 AI 当上下文）：从 endingAtLocalID 往前逐条读，返回 正文/发送者/是否自己 的字典
+ (NSArray<NSDictionary *> *)historyForSession:(NSString *)session
                                 endingAtLocalID:(NSInteger)localID
                                           limit:(NSInteger)limit;

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
