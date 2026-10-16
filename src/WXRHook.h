#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/// 一条 hook 的结果记录，设置界面"诊断"页会展示
@interface WXRHookRecord : NSObject
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *selector;
@property (nonatomic, assign) BOOL attached;    // YES 挂上了，NO 没找到
@property (nonatomic, copy) NSString *note;
@end

/// 纯 runtime 方法交换，不依赖 CydiaSubstrate / ElleKit。
/// 找不到类或方法时只记录，不抛异常，保证在任何微信版本下都能安全加载。
@interface WXRHook : NSObject

/// 挂一个实例方法或类方法。original 可为 NULL（不需要调原实现时）
+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selector
    isClassMethod:(BOOL)isClassMethod
      replacement:(IMP)replacement
         original:(IMP *)originalOut
             note:(NSString *)note;

/// 依次尝试多个候选类名，命中第一个就返回 YES（微信版本间类名漂移时很有用）
+ (BOOL)hookAnyClass:(NSArray<NSString *> *)classNames
            selector:(NSString *)selector
       isClassMethod:(BOOL)isClassMethod
         replacement:(IMP)replacement
            original:(IMP *)originalOut
                note:(NSString *)note;

/// 依次尝试多个候选 selector，命中第一个就返回 YES
+ (BOOL)hookClass:(NSString *)className
 anySelector:(NSArray<NSString *> *)selectors
    isClassMethod:(BOOL)isClassMethod
      replacement:(IMP)replacement
         original:(IMP *)originalOut
             note:(NSString *)note;

+ (NSArray<WXRHookRecord *> *)records;
+ (void)clearRecords;

@end

/* ---------------- 安全调用小工具 ---------------- */

/// 目标类是否存在
BOOL WXRClassExists(NSString *className);
/// 取第一个存在且响应 selector 的类
Class WXRFirstClassResponding(NSArray<NSString *> *classNames, NSString *selector, BOOL isClassMethod);

/// 安全消息发送：先 respondsToSelector，再 @try 包裹，失败返回 nil
id WXRCall(id target, NSString *selector);
id WXRCall1(id target, NSString *selector, id a1);
id WXRCall2(id target, NSString *selector, id a1, id a2);
id WXRCall3(id target, NSString *selector, id a1, id a2, id a3);
/// 对类对象（类方法）调用
id WXRCallClass(NSString *className, NSString *selector);

/// 用 KVC 依次尝试多个 ivar/getter 名，取第一个非 nil 的值（微信内部字段名各版本有差异）
id WXRValueAny(id object, NSArray<NSString *> *keyCandidates);
