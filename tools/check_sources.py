#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WXRit 源码静态检查（在没有编译器的机器上尽可能提前发现问题）。

检查项：
  1. 括号配平（花括号 / 圆括号 / 方括号）
  2. #import "..." 的本地头文件是否存在
  3. 头文件里 @interface 声明的方法，.m 里是否都有实现
  4. 给「本工程自己的类」发消息时，selector 是否声明过、参数个数是否对得上
     —— 这类错误在真机上表现是 unrecognized selector 崩溃或传参错位崩溃，必须在交付前查出来
  5. WXRxxx(...) 形式的 C 函数是否有声明
用法： python tools/check_sources.py [项目根目录]
退出码：0 = 无问题
"""

import pathlib
import re
import sys

NSOBJECT_SELECTORS = {
    "alloc", "init", "new", "class", "self", "description", "debugDescription",
    "respondsToSelector:", "conformsToProtocol:", "isKindOfClass:", "isMemberOfClass:",
    "performSelector:", "performSelector:withObject:", "performSelector:withObject:withObject:",
    "methodForSelector:", "release", "retain", "autorelease", "copy", "mutableCopy",
    "isEqual:", "hash", "valueForKey:", "setValue:forKey:", "addObserver:selector:name:object:",
    "string", "array", "dictionary", "set", "data", "numberWithBool:", "numberWithInt:",
    "numberWithInteger:", "numberWithDouble:", "numberWithLongLong:", "stringWithFormat:",
    "stringWithUTF8String:", "stringWithString:", "arrayWithArray:", "dictionaryWithDictionary:",
}

SIMPLE_SELECTOR = re.compile(r"^[A-Za-z_]\w*$")

# 中文字符（含全角标点）。正常只出现在字符串字面量和注释里；
# 去注释去字符串后还有中文，基本就是引号写错导致字符串提前结束。
CJK = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")

# 点语法只能用于属性；`[obj foo].bar:baz` 这种"给带参数的方法用点语法"是硬错误。
# 真机上就是这么挂的： [WXRPrefs shared].integerForKey:KEY
DOT_ARG = re.compile(r"\]\s*\.\s*[A-Za-z_]\w*\s*:")

# 已知的"参数类型容易写错"的 API：writeData: 要 NSData，
# 传字符串字面量 / stringWithFormat: / stringByAppendingString: 的结果都是 bug。
WRITE_DATA = re.compile(r"writeData:\s*(?:\[?@\"|[^\]]*stringWithFormat:|[^\]]*stringByAppendingString:)")


PROPERTY_DECL = re.compile(r"@property\s*\([^)]*\)\s*([^;]*);")
BLOCK_PROPERTY = re.compile(r"\(\s*\^\s*([A-Za-z_]\w*)\s*\)")
# 只检查"返回自身类型"的单例访问器：`[WXRPrefs shared].xxx`。
# 不能用任意访问器 —— `[WXRWeChat selfDisplayName].length` 的点语法作用在返回的字符串上，那样会误报。
SINGLETON_ACCESSORS = (r"(?:shared|defaultCenter|sharedInstance|sharedCenter|"
                       r"sharedServiceCenter|sharedManager|defaultInstance)")
SINGLETON_DOT = re.compile(r"\[\s*(WXR\w+)\s+(" + SINGLETON_ACCESSORS + r")\s*\]\s*\.\s*([A-Za-z_]\w*)")
NSOBJECT_DOT = {"description", "debugDescription", "hash", "class", "superclass", "self", "isProxy"}

# 块参数名（^Ret(NSString *a, NSString *b)）会和同名局部变量串味，必须排除
BLOCK_PARAMS = re.compile(r"\^\s*[A-Za-z_][\w\s\*<>,]*?\(\s*([^)]*)\)")


def block_parameter_names(code):
    names = set()
    for match in BLOCK_PARAMS.finditer(code):
        for part in match.group(1).split(","):
            identifiers = re.findall(r"[A-Za-z_]\w*", part)
            if identifiers:
                names.add(identifiers[-1])
    return names


# 方法声明行（行首的 + / -），用来区分类方法与实例方法
SIGNED_METHOD_LINE = re.compile(r"(?m)^\s*([+-])\s*\(([^)]*)\)\s*([^;{\n]*)")


def collect_signed_methods(text):
    """粗略收集 + / - 方法名：够用来判断"在类方法里发了实例方法"这类错误。"""
    plus, minus = set(), set()
    for match in SIGNED_METHOD_LINE.finditer(text):
        sign = match.group(1)
        rest = match.group(3)
        labels = re.findall(r"([A-Za-z_]\w*)\s*:", rest)
        if labels:
            selector = "".join(label + ":" for label in labels)
        else:
            identifiers = re.findall(r"[A-Za-z_]\w*", rest)
            if not identifiers:
                continue
            selector = identifiers[0]
        (plus if sign == "+" else minus).add(selector)
    return plus, minus


def collect_class_methods(text):
    """{类名: (类方法集合, 实例方法集合)}，@interface 与 @implementation 都算。"""
    result = {}
    for match in re.finditer(r"@(?:interface|implementation)\s+(WXR\w+)", text):
        cls = match.group(1)
        end = text.find("@end", match.end())
        block = text[match.end(): end if end > 0 else len(text)]
        plus, minus = collect_signed_methods(block)
        entry = result.setdefault(cls, (set(), set()))
        entry[0].update(plus)
        entry[1].update(minus)
    return result


def class_method_receiver_issues(path, code, plus_by_class, minus_by_class):
    """在 + 方法里给 self / 类对象发实例方法 —— 编译报 no known class method for selector。

    真机上就是这么挂的：sendText:（类方法）里写了 [self logSendDiagnostics]，
    而它是 - (void)logSendDiagnostics。
    """
    issues = []
    for impl in re.finditer(r"@implementation\s+(WXR\w+)", code):
        cls = impl.group(1)
        end = code.find("@end", impl.end())
        block = code[impl.end(): end if end > 0 else len(code)]
        plus_methods = plus_by_class.get(cls, set())
        minus_methods = minus_by_class.get(cls, set())
        if not minus_methods:
            continue
        receiver = re.compile(r"\[\s*(?:self|" + re.escape(cls) + r")\s+([A-Za-z_]\w*)\s*\]")
        current_kind = None
        for line in block.split("\n"):
            head = re.match(r"\s*([+-])\s*\(", line)
            if head:
                current_kind = head.group(1)
            if current_kind != "+":
                continue
            for match in receiver.finditer(line):
                selector = match.group(1)
                if selector in minus_methods and selector not in plus_methods:
                    issues.append(
                        f"{path.name}: {cls} 的 + 方法里给 self 发了实例方法 {selector}"
                        f"（编译报 no known class method）")
    return issues


def collect_properties(text):
    """从 @interface 块里收集 @property 名字（按类分组）。

    要处理两种写法：
        @property (nonatomic, copy) NSString *pageTitle;
        @property (nonatomic, copy) void (^action)(void);   ← block 属性，不能按"最后一个标识符"取
    """
    result = {}
    for match in re.finditer(r"@interface\s+(WXR\w+)", text):
        name = match.group(1)
        end = text.find("@end", match.end())
        if end == -1:
            continue
        block = text[match.end():end]
        names = set()
        for decl_match in PROPERTY_DECL.finditer(block):
            decl = decl_match.group(1)
            block_prop = BLOCK_PROPERTY.search(decl)
            if block_prop:
                names.add(block_prop.group(1))
                continue
            cleaned = re.sub(r"<[^>]*>", "", decl)      # 去掉泛型参数
            identifiers = re.findall(r"[A-Za-z_]\w*", cleaned)
            if identifiers:
                names.add(identifiers[-1])
        result.setdefault(name, set()).update(names)
    return result


def find_properties(text):
    return collect_properties(text)


def singleton_dot_issues(path, code, declared, properties_by_class):
    """`[WXRPrefs shared].xxx` —— xxx 必须是该类声明的属性或无参方法，否则编译不过。"""
    issues = []
    for match in SINGLETON_DOT.finditer(code):
        cls, _accessor, name = match.group(1), match.group(2), match.group(3)
        known = set(properties_by_class.get(cls, set()))
        known |= {sel for sel, arity in declared.get(cls, {}).items() if arity == 0 and ":" not in sel}
        known |= NSOBJECT_DOT
        if not known:
            continue          # 这个类没有收集到声明信息，跳过（避免误报）
        if name not in known:
            line = code[:match.start()].count("\n") + 1
            snippet = code.split("\n")[line - 1].strip()[:70]
            issues.append(f"{path.name}:{line} {cls} 上没有名为 {name} 的属性/无参方法: {snippet}")
    return issues


def typed_dot_variable_issues(path, code, declared, properties_by_class, superclasses):
    """`WXRPrefs *p = ...; p.foo` —— foo 不存在于该类声明的属性/无参方法时编译不过。

    只检查 NSObject 直接子类的变量：UI 子类会继承大量 UIKit 属性，容易误报。
    真机编译已认可的 WXRWeChat/WXRHook/WXRLog/WXRMsgStore 四个文件必须零误报。
    """
    issues = []
    # 局部/成员声明： WXRXxx *name = ...  也包括 for (WXRXxx *name in ...) 与参数列表
    var_types = {}
    for match in re.finditer(r"\b(WXR[A-Z]\w*)\s*\*+\s*([A-Za-z_]\w*)\s*(?:[=;),]|\bin\b)", code):
        cls, var = match.group(1), match.group(2)
        if superclasses.get(cls) == "NSObject":
            var_types.setdefault(var, set()).add(cls)
    if not var_types:
        return issues
    # 块参数同名（比如块里也叫 b）会让类型判断失效，直接跳过这些名字
    block_names = block_parameter_names(code)
    for var, classes in var_types.items():
        # 同名变量在同一个文件里出现在不同作用域/不同类型 → 无法安全判断，跳过（避免误报）
        if len(classes) != 1 or var in block_names:
            continue
        cls = next(iter(classes))
        known = set(properties_by_class.get(cls, set()))
        known |= {sel for sel, arity in declared.get(cls, {}).items() if arity == 0 and ":" not in sel}
        known |= NSOBJECT_DOT
        if not known:
            continue
        for match in re.finditer(r"\b" + re.escape(var) + r"\s*\.\s*([A-Za-z_]\w*)", code):
            name = match.group(1)
            if name in known:
                continue
            line = code[:match.start()].count("\n") + 1
            snippet = code.split("\n")[line - 1].strip()[:70]
            issues.append(f"{path.name}:{line} {cls} 变量 {var} 上用点语法访问了不存在的 {name}: {snippet}")
    return issues


# 这些助手的参数是 id；把 SEL / Class 这类非对象指针传进去，ARC 下直接编译报错
ID_ARG_HELPERS = ("WXRCall1", "WXRCall2", "WXRCall3")
NON_OBJECT_ARG = re.compile(r"(@selector\s*\(|NSSelectorFromString\s*\(|sel_registerName\s*\(|"
                            r"NSSelectorFromName\s*\(|objc_getClass\s*\(|objc_getMetaClass\s*\()")


def non_object_argument_issues(path, code):
    """把 SEL/Class 当 id 传 —— 真机上报 implicit conversion ... disallowed with ARC。"""
    issues = []
    for helper in ID_ARG_HELPERS:
        for match in re.finditer(r"\b" + helper + r"\s*\(", code):
            start = match.end() - 1
            depth = 0
            end = start
            for index in range(start, len(code)):
                char = code[index]
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        end = index
                        break
            args = [piece.strip() for piece in code[start + 1:end].split(",")]
            for position, argument in enumerate(args):
                if position < 2:            # 第 1 个是 target，第 2 个是 selector 字符串
                    continue
                if NON_OBJECT_ARG.search(argument):
                    line = code[:match.start()].count("\n") + 1
                    issues.append(f"{path.name}:{line} 把 SEL/Class 当 id 传给 {helper}"
                                  f"（ARC 报 implicit conversion）: {argument[:60]}")
    return issues


def dot_arg_issues(path, code):
    """点语法后跟冒号 = 把带参数的方法当属性用，编译不过。"""
    issues = []
    for match in DOT_ARG.finditer(code):
        line = code[:match.start()].count("\n") + 1
        snippet = code.split("\n")[line - 1].strip()[:70]
        issues.append(f"{path.name}:{line} 非法点语法（带参数的方法不能用点语法）: {snippet}")
    return issues


def write_data_issues(path, code):
    """writeData: 收到字符串而不是 NSData。"""
    issues = []
    for match in WRITE_DATA.finditer(code):
        line = code[:match.start()].count("\n") + 1
        snippet = code.split("\n")[line - 1].strip()[:70]
        issues.append(f"{path.name}:{line} writeData: 的参数看起来是 NSString，应为 NSData: {snippet}")
    return issues


def cjk_outside_string_issues(path, code):
    issues = []
    lines = code.split("\n")
    for match in CJK.finditer(code):
        line_no = code[:match.start()].count("\n") + 1
        raw_line = lines[line_no - 1] if line_no - 1 < len(lines) else ""
        stripped = raw_line.strip()
        if stripped.startswith("#"):
            continue   # #pragma mark 之类允许中文
        issues.append(f"{path.name}:{line_no} 字符串/注释之外出现中文字符（常见原因：引号写错），"
                      f"该行: {stripped[:60]}")
        if len(issues) >= 3:
            break
    return issues


def strip_comments_and_strings(text):
    """返回 (去掉注释和字符串的代码, 原文本)。字符串替换成等长空格以便定位。"""
    out = []
    i, n = 0, len(text)
    state = None
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                i += 2
                continue
            if c == '"' or c == "'":
                state = "str" if c == '"' else "chr"
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "line":
            if c == "\n":
                state = None
                out.append(c)
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = None
                i += 2
                continue
            i += 1
            continue
        # 字符串内部
        if c == "\\":
            i += 2
            continue
        if (state == "str" and c == '"') or (state == "chr" and c == "'"):
            state = None
        i += 1
    return "".join(out)


def balance_issues(path, code):
    issues = []
    for open_ch, close_ch, label in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        delta = code.count(open_ch) - code.count(close_ch)
        if delta:
            issues.append(f"{path.name}: {label}不配平 {delta:+d}")
    return issues


def collect_method_list(code):
    """按出现顺序返回 [(selector, arity)]，重复定义要能被看见（dict 会吃掉重复项）。"""
    methods = []
    lines = code.split("\n")
    buffer = ""
    collecting = False
    for line in lines:
        stripped = line.strip()
        if not collecting:
            if re.match(r"^[+-]\s*\(", stripped) or re.match(r"^[+-]\s*[A-Za-z_]", stripped):
                collecting = True
                buffer = stripped
            else:
                continue
        else:
            buffer += " " + stripped
        if ";" in buffer or "{" in buffer:
            selector, arity = selector_from_declaration(buffer)
            if selector:
                methods.append((selector, arity))
            collecting = False
            buffer = ""
    return methods


def collect_methods(text, code):
    """返回 {selector: arity}，来自 @interface / @implementation 中的方法声明与实现。"""
    return dict(collect_method_list(code))


def strip_parens(part):
    out = []
    depth = 0
    for ch in part:
        if ch == "(":
            depth += 1
            continue
        if ch == ")":
            depth = max(0, depth - 1)
            continue
        if depth == 0:
            out.append(ch)
    return "".join(out)


def selector_from_declaration(declaration):
    # 截断到方法体/分号之前，避免把函数体里的关键字也当成 selector 段
    cut = len(declaration)
    for mark in ("{", ";"):
        idx = declaration.find(mark)
        if idx != -1:
            cut = min(cut, idx)
    body = strip_parens(declaration[:cut]).lstrip("+-").strip()
    parts = re.findall(r"([A-Za-z_]\w*)\s*:", body)
    if parts:
        return "".join(p + ":" for p in parts), len(parts)
    match = re.match(r"([A-Za-z_]\w*)", body)
    if match:
        return match.group(1), 0
    return None, 0


def find_interfaces(text):
    """返回 {类名: 方法字典}，来自所有 @interface 块（含类扩展）。"""
    result = {}
    for match in re.finditer(r"@interface\s+(WXR\w+)", text):
        name = match.group(1)
        end = text.find("@end", match.end())
        if end == -1:
            continue
        block = text[match.end():end]
        methods = collect_methods(text, strip_comments_and_strings(block))
        result.setdefault(name, {}).update(methods)
    return result


def find_implementations(text):
    result = {}
    for match in re.finditer(r"@implementation\s+(WXR\w+)", text):
        name = match.group(1)
        end = text.find("@end", match.end())
        if end == -1:
            continue
        block = text[match.end():end]
        methods = collect_methods(text, strip_comments_and_strings(block))
        result.setdefault(name, {}).update(methods)
    return result


def scan_message_sends(code, own_classes):
    """找出 [WXRXxx sel:...] / [self sel:...] 形式的消息发送，返回 (receiver, selector, arity, offset)。"""
    results = []
    for match in re.finditer(r"\[(WXR\w+|self|super)(?=\s)", code):
        start = match.end()
        depth = 1
        i = start
        n = len(code)
        paren = 0
        while i < n:
            ch = code[i]
            if ch == "(":
                paren += 1
            elif ch == ")":
                paren = max(0, paren - 1)
            elif ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= n:
            continue
        inner = code[start:i]
        selector, arity = selector_from_expression(inner)
        if selector:
            results.append((match.group(1), selector, arity, match.start()))
    return results


def selector_from_expression(inner):
    """从消息表达式中提取 selector 链（只取顶层、括号与外层方括号之外的标识符:）。"""
    parts = []
    i, n = 0, len(inner)
    depth_paren = 0
    rest = inner
    # 逐段匹配：标识符 + 可选空格 + 冒号 + 参数（跳过平衡的括号/方括号/引号内容）
    while i < n:
        match = re.match(r"\s*([A-Za-z_]\w*)\s*:", rest[i:])
        if not match:
            break
        parts.append(match.group(1))
        i += match.end()
        # 跳过参数
        skip = 0
        depth = 0
        while i < n:
            ch = rest[i]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
            if depth == 0 and ch == " ":
                # 可能是下一个 selector 段的开始
                look = re.match(r"\s*[A-Za-z_]\w*\s*:", rest[i:])
                if look:
                    break
            i += 1
        if i >= n:
            break
    if parts:
        return "".join(p + ":" for p in parts), len(parts)
    match = re.match(r"\s*([A-Za-z_]\w*)", inner)
    if match:
        return match.group(1), 0
    return None, 0


def block_end_issues(path, code):
    """@interface / @implementation 的个数必须与 @end 相同（缺 @end 是硬错误）。"""
    opens = len(re.findall(r"@(?:interface|implementation)\b", code))
    ends = len(re.findall(r"@end\b", code))
    if opens != ends:
        return [f"{path.name}: @interface/@implementation {opens} 个但 @end {ends} 个（缺或多 @end）"]
    return []


def duplicate_method_issues(path, code):
    """同一个 @implementation 里重复定义同一个 selector 是硬错误。"""
    issues = []
    for match in re.finditer(r"@implementation\s+(WXR\w+)", code):
        name = match.group(1)
        end = code.find("@end", match.end())
        if end == -1:
            continue
        block = code[match.end():end]
        seen = set()
        for sel, _arity in collect_method_list(block):
            if sel in seen:
                issues.append(f"{path.name}: @implementation {name} 里重复定义了 {sel}")
            seen.add(sel)
    return issues


def parse_c_function_arity(text):
    """解析 C 函数参数个数：名字 -> (arity, is_variadic)。

    关键点：必须只在"声明/定义"上下文里取签名（行首、带返回类型），
    否则 `WXRLog(@"...")` 这种调用会被误当成声明 —— 字符串在预处理阶段已被剥离，
    调用看起来和声明一模一样。
    """
    result = {}
    type_prefix = (r"(?:static\s+)?(?:void|id|BOOL|instancetype|Class|SEL|IMP|NSInteger|NSUInteger|"
                   r"CGFloat|NSTimeInterval|NSString|NSArray|NSDictionary|NSMutableArray|"
                   r"NSMutableDictionary|NSMutableString|WXR\w+)")
    pattern = re.compile(
        type_prefix + r"[\w\s\*<>]*?\b(WXR[A-Z]\w+)\s*\(([^;{)]*)\)\s*"
        r"(?:NS_FORMAT_FUNCTION\([^)]*\))?\s*[;{]")
    for match in pattern.finditer(text):
        name, params = match.group(1), match.group(2).strip()
        if not params or params == "void":
            result[name] = (0, False)
            continue
        variadic = "..." in params
        clean = params.replace("...", "").strip()
        commas = clean.count(",")
        arity = commas + 1 if clean else 0
        if variadic:
            arity = max(0, arity - 1)
        result[name] = (arity, variadic)
    return result


def count_call_args(code, open_index):
    """从 '(' 位置开始数顶层逗号，返回 (参数个数, 结束位置)；空参数算 0 个。"""
    depth = 0
    i = open_index
    n = len(code)
    commas = 0
    has_content = False
    while i < n:
        ch = code[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return (0 if not has_content else commas + 1), i
        elif ch == "," and depth == 1:
            commas += 1
        elif depth == 1 and not ch.isspace() and ch not in "([{":
            has_content = True
        i += 1
    return -1, n


def c_call_arity_issues(path, code, arity_table, definition_offsets):
    issues = []
    for match in re.finditer(r"\b(WXR[A-Z]\w+)\s*\(", code):
        name = match.group(1)
        if name not in arity_table:
            continue
        if match.start() in definition_offsets.get(name, ()):
            continue
        open_index = code.index("(", match.start())
        args, _ = count_call_args(code, open_index)
        if args < 0:
            continue   # 括号不配平，交给 balance 检查
        arity, variadic = arity_table[name]
        if variadic:
            if args < arity:
                issues.append(f"{path.name}: {name} 至少需要 {arity} 个参数，这里只传了 {args} 个")
        elif args != arity:
            issues.append(f"{path.name}: {name} 需要 {arity} 个参数，这里传了 {args} 个")
    return issues


def resolve_root(argument):
    """允许在仓库根目录或 WXRit 目录下运行：找不到 src 时自动向下找一层。"""
    root = pathlib.Path(argument)
    if (root / "src").is_dir():
        return root
    for candidate in sorted(root.glob("*/src")):
        return candidate.parent
    return root


SOURCE_DIRS = ("src", "probe")


def gather_files(root):
    """src/ 与 probe/ 下的 .m/.h 都要查（探针是独立产物，但同样不能有低级错误）。"""
    headers, sources = [], []
    for name in SOURCE_DIRS:
        base = root / name
        if not base.is_dir():
            continue
        headers += sorted(base.rglob("*.h"))
        sources += sorted(base.rglob("*.m"))
    return headers, sources


def main():
    root = resolve_root(sys.argv[1] if len(sys.argv) > 1 else r"E:\DEB\WXRit")
    src = root / "src"
    if not src.is_dir():
        print(f"找不到源码目录：{src}")
        return 1
    headers, sources = gather_files(root)
    all_files = headers + sources
    header_names = {p.name for p in headers}

    issues = []
    codes = {}
    texts = {}
    for path in all_files:
        raw = path.read_text(encoding="utf-8")
        code = strip_comments_and_strings(raw)
        texts[path] = raw
        codes[path] = code
        issues += balance_issues(path, code)
        issues += cjk_outside_string_issues(path, code)
        issues += block_end_issues(path, code)
        issues += duplicate_method_issues(path, code)
        issues += dot_arg_issues(path, code)
        issues += write_data_issues(path, code)
        issues += non_object_argument_issues(path, code)
        for match in re.finditer(r'#import\s+"([^"]+)"', raw):
            if match.group(1) not in header_names:
                issues.append(f"{path.name}: 找不到头文件 {match.group(1)}")

    declared = {}
    implemented = {}
    # 声明也要看 .m：私有方法通常写成 @interface X () … @end，只查头文件会漏掉它们
    for path in headers + sources:
        for name, methods in find_interfaces(texts[path]).items():
            declared.setdefault(name, {}).update(methods)
    for path in sources:
        for name, methods in find_implementations(texts[path]).items():
            implemented.setdefault(name, {}).update(methods)

    for name, methods in declared.items():
        for selector in methods:
            if selector not in implemented.get(name, {}):
                issues.append(f"{name}: 声明了 {selector} 但没有实现")

    own_classes = set(declared) | set(implemented)
    declared_c_functions = set()
    for path in headers:
        declared_c_functions |= set(re.findall(r"\b(WXR[A-Z]\w+)\s*\(", texts[path]))
    defined_c_functions = set()
    for path in sources:
        # 函数定义（含带 __attribute__ 前缀的），例如： static void WXREntry(void) {
        defined_c_functions |= set(
            re.findall(r"\b(WXR[A-Z]\w+)\s*\([^)\n]*\)\s*\{", texts[path]))

    # C 函数参数个数：自家函数调用传错参数个数是硬错误
    arity_table = {}
    for path in headers + sources:
        arity_table.update(parse_c_function_arity(codes[path]))

    # [WXRXxx shared].prop 的合法性检查需要"每个类声明了哪些属性/无参方法"
    properties_by_class = {}
    for path in headers + sources:
        for name, props in find_properties(codes[path]).items():
            properties_by_class.setdefault(name, set()).update(props)

    # 类 → 直接父类（用于判断是否可以安全地做"点语法属性存在性"检查）
    superclasses = {}
    for path in headers + sources:
        for match in re.finditer(r"@interface\s+(WXR\w+)\s*:\s*(\w+)", codes[path]):
            superclasses[match.group(1)] = match.group(2)

    # 类 → 类方法 / 实例方法（判断"在 + 方法里发实例方法"这种编译错误）
    plus_by_class = {}
    minus_by_class = {}
    for path in headers + sources:
        for cls, (plus_methods, minus_methods) in collect_class_methods(codes[path]).items():
            plus_by_class.setdefault(cls, set()).update(plus_methods)
            minus_by_class.setdefault(cls, set()).update(minus_methods)

    scanned_messages = 0
    for path in sources:
        code = codes[path]
        definition_offsets = {}
        for match in re.finditer(r"\b(WXR[A-Z]\w+)\s*\([^)\n]*\)\s*\{", code):
            definition_offsets.setdefault(match.group(1), set()).add(match.start())
        issues += c_call_arity_issues(path, code, arity_table, definition_offsets)
        issues += singleton_dot_issues(path, code, declared, properties_by_class)
        issues += typed_dot_variable_issues(path, code, declared, properties_by_class, superclasses)
        issues += class_method_receiver_issues(path, code, plus_by_class, minus_by_class)
        for receiver, selector, arity, offset in scan_message_sends(code, own_classes):
            if receiver in ("self", "super"):
                continue
            scanned_messages += 1
            target = receiver
            # 注意：类可能只声明在 .m 里（如 WXRProbeDetail / WXRRow），
            # 所以"已知方法"要同时取头文件声明和 .m 实现，否则这些类根本不会被检查。
            known = {}
            known.update(declared.get(target, {}))
            known.update(implemented.get(target, {}))
            if not known:
                continue
            if selector in NSOBJECT_SELECTORS:
                continue
            if selector not in known:
                line = code[:offset].count("\n") + 1
                issues.append(f"{path.name}:{line} 给 {target} 发了未声明的 selector {selector}")
                continue
            if known[selector] != arity:
                line = code[:offset].count("\n") + 1
                issues.append(
                    f"{path.name}:{line} {target} 的 {selector} 参数个数不符：实发 {arity}，声明 {known[selector]}")

        for match in re.finditer(r"\b(WXR[A-Z]\w+)\s*\(", code):
            name = match.group(1)
            if name in declared_c_functions or name in defined_c_functions or name in own_classes:
                continue
            if name.startswith("WXRRowKind") or name.startswith("WXRKey"):
                continue
            line = code[:match.start()].count("\n") + 1
            issues.append(f"{path.name}:{line} 调用了未声明的 C 函数 {name}")

    for issue in issues:
        print(issue)
    print(f"检查文件 {len(all_files)} 个，类 {len(own_classes)} 个，"
          f"扫描到类消息 {scanned_messages} 处，问题 {len(issues)} 处")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
