#pragma once
#import <Foundation/Foundation.h>

/// 候选名覆盖（适配用）。
///
/// 为什么需要它：微信内部类名/方法名会随版本变化，插件内置的是一组"候选名"。
/// 在未越狱的 TrollStore 环境里，改代码意味着重新编译 + 重新注入，成本很高；
/// 有了它，只要在设置里粘贴一小段文本，就能把你这版微信的真实名字喂给插件，
/// 保存后重启微信（或点"重试挂载"）即可生效，不用重新注入。
///
/// 文本格式（每行一条，# 开头是注释，逗号分隔多个名字）：
///
///     msgclass = CMessageMgr
///     incoming = AsyncOnAddMsg:MsgWrap:
///     svrid    = m_n64MesSvrID
///
@interface WXROverrides : NSObject

/// 支持的键 → 含义说明（用于设置页提示与报错信息）
+ (NSDictionary<NSString *, NSString *> *)supportedKeys;

/// 用户为某个键提供的名字（可能为空数组）
+ (NSArray<NSString *> *)namesForKey:(NSString *)key;

/// 用户覆盖的名字在前，内置候选在后（去重、保序）
+ (NSArray<NSString *> *)mergeKey:(NSString *)key fallback:(NSArray<NSString *> *)fallback;

/// 当前覆盖文本（设置页回显用）
+ (NSString *)rawText;
/// 当前生效的覆盖条数
+ (NSInteger)overrideCount;

/// 校验并保存；失败时 error 里是具体原因（未知键 / 空值等）
+ (BOOL)applyText:(NSString *)text error:(NSString **)error;

/// 诊断报告用的一行摘要
+ (NSString *)summary;

@end
