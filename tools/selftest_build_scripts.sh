#!/usr/bin/env bash
# 构建脚本自测：不需要 macOS、不需要 Xcode。
# 用"假 xcrun"驱动 scripts/build-dylib.sh，验证语法、成功路径、失败路径。
# 产物写在临时目录（WXR_OUT_DIR 覆盖），不会污染 build/。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build-selftest"
rm -rf "$WORK"
mkdir -p "$WORK"

fail=0
check() { # 说明 期望退出码 实际退出码
    if [[ "$2" == "$3" ]]; then
        echo "OK   $1 (exit=$3)"
    else
        echo "FAIL $1（期望 exit=$2，实际 exit=$3）"
        fail=1
    fi
}

# 假 xcrun：用导出的 shell 函数实现，子 bash 也能看到
xcrun() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --show-sdk-path) echo "/fake/iPhoneOS.sdk"; return 0 ;;
            --version)       echo "Apple clang version 15.0.0 (fake)"; return 0 ;;
        esac
    done
    if [[ "${FAKE_XCRUN_FAIL:-0}" == "1" ]]; then
        echo "src/WXRFake.m:42:9: error: fake compile error（测试失败路径）" >&2
        return 1
    fi
    local out="" prev=""
    for arg in "$@"; do
        if [[ "$prev" == "-o" ]]; then out="$arg"; fi
        prev="$arg"
    done
    if [[ -n "$out" ]]; then
        mkdir -p "$(dirname "$out")"
        echo "fake dylib payload" > "$out"
    fi
    return 0
}
export -f xcrun
export WXR_OUT_DIR="$WORK/build"

echo "== 1) 语法检查 =="
bash -n "$ROOT/scripts/build-dylib.sh" && echo "OK   build-dylib.sh 语法通过" || { echo "FAIL 语法"; fail=1; }

echo
echo "== 2) 成功路径 =="
bash "$ROOT/scripts/build-dylib.sh" > "$WORK/ok.log" 2>&1
check "build-dylib.sh 成功路径" 0 $?
if grep -q 'BUILD OK' "$WORK/ok.log"; then echo "OK   日志含 BUILD OK"; else echo "FAIL 日志缺少 BUILD OK"; fail=1; fi
if [[ -f "$WORK/build/WXReply.dylib" ]]; then echo "OK   产物已生成"; else echo "FAIL 产物未生成"; fail=1; fi

echo
echo "== 3) 失败路径 =="
FAKE_XCRUN_FAIL=1 bash "$ROOT/scripts/build-dylib.sh" > "$WORK/fail.log" 2>&1
check "build-dylib.sh 失败路径" 1 $?
if grep -q 'BUILD FAILED at stage=' "$WORK/fail.log"; then
    echo "OK   失败时打印了阶段标记：$(grep 'BUILD FAILED at stage=' "$WORK/fail.log")"
else
    echo "FAIL 失败时没有打印阶段标记"; fail=1
fi

rm -rf "$WORK"
echo
if [[ "$fail" == 0 ]]; then echo "构建脚本自测：全部通过"; else echo "构建脚本自测：有失败项"; fi
exit "$fail"
