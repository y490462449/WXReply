#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对静态检查器做变异测试：故意注入几类硬错误，验证检查器真的能报出来。

用法： python tools/selftest_checker.py
（只在开发检查器时用；CI 里不跑，因为要复制工程。）
"""
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKER = ROOT / "tools" / "check_sources.py"

MUTATIONS = [
    # 注意：候选名数组里的字符串（比如 "AsyncOnAddMsg:MsgWrap:"）不是编译错误，
    # 静态检查器无法判断它对不对 —— 那只能靠真机的诊断报告或解密二进制核对。
    # 所以这里只列"能被静态检查发现"的错误类型。
    ("C 函数参数个数少传",
     "src/WXRWeChat.m",
     "WXRCall2(manager, selector, text, session);",
     "WXRCall2(manager, selector, text);"),
    ("丢失 @end",
     "src/WXRSettings.m",
     "@end\n",
     ""),
    ("同一 @implementation 里重复方法",
     "src/WXRSettings.m",
     "- (void)close {\n    [self dismissViewControllerAnimated:YES completion:nil];\n}",
     "- (void)close { return; }\n"
     "- (void)close {\n    [self dismissViewControllerAnimated:YES completion:nil];\n}"),
    ("中文串引号写错",
     "src/WXRAutoReply.m",
     "（当前开关：%@）",
     '（"当前开关：%@）'),
    ("给自家类发未声明的 selector（.m 里的私有类）",
     "src/WXRSettings.m",
     '[WXRRow row:@"只回私聊"',
     '[WXRRow rowXX:@"只回私聊"'),
    ("声明了却没实现",
     "src/WXRSettings.m",
     "- (void)close {\n    [self dismissViewControllerAnimated:YES completion:nil];\n}\n",
     ""),
    # 下面两条来自旧项目在真机 CI 上的真实报错（2026-10-16，微信 8.0.76）
    ("点语法用于带参数的方法（真机编译错误）",
     "src/WXRSettings.m",
     "[[WXRPrefs shared] boolForKey:row.key]",
     "[WXRPrefs shared].boolForKey:row.key"),
    ("带类型变量用点语法访问不存在的属性",
     "src/WXRSettings.m",
     "cell.textLabel.text = row.title;",
     "cell.textLabel.text = row.titles;"),
]


def run_case(name, rel, old, new):
    # 工作目录放在工程内（沙箱下 tempfile 建的目录可能没有子目录写权限），用完即删
    base = ROOT / ".checker-mutations"
    os.makedirs(base, exist_ok=True)
    work = None
    for i in range(1, 100):
        candidate = base / f"mut{i}"
        if not candidate.exists():
            work = candidate
            break
    if work is None:
        return name, "SKIP", "无法创建变异工作目录"
    try:
        os.makedirs(work / "proj", exist_ok=True)
        shutil.copytree(ROOT, work / "proj", dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".git", "__pycache__", ".checker-mutations"))
        target = work / "proj" / rel
        text = target.read_text(encoding="utf-8")
        if old not in text:
            return name, "SKIP", f"锚点没找到: {old[:40]!r}"
        target.write_text(text.replace(old, new, 1), encoding="utf-8")
        proc = run_checker(work / "proj")
        return name, ("CAUGHT" if proc.returncode != 0 else "MISSED"), proc.stdout.strip()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_checker(root):
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    return subprocess.run([sys.executable, str(CHECKER), str(root)],
                          capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=env)


def main():
    failures = 0
    for name, rel, old, new in MUTATIONS:
        _, verdict, output = run_case(name, rel, old, new)
        mark = {"CAUGHT": "✅ 抓到", "MISSED": "❌ 漏掉", "SKIP": "⚠️ 跳过"}[verdict]
        print(f"{mark}  {name}")
        if verdict != "CAUGHT":
            failures += 1
        for line in output.splitlines()[:3]:
            print(f"        {line}")
    # 干净工程必须是通过的
    proc = run_checker(ROOT)
    print(f"{'✅' if proc.returncode == 0 else '❌'}  干净工程: {proc.stdout.strip().splitlines()[-1]}")
    if proc.returncode != 0:
        failures += 1
        print(proc.stdout)
    print(f"\n变异测试结果：{'全部通过' if failures == 0 else f'{failures} 项不达标'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
