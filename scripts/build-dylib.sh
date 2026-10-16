#!/usr/bin/env bash
# 用 Xcode 自带的 clang 直接编译出可注入的 dylib（不需要 Theos、不需要越狱）。
# 产物：build/WXReply.dylib —— 用 TrollFools 注入微信即可。
#
# 按阶段执行并打印阶段标记：一旦失败，最后几行会写明
#   [WXReply] ❌ BUILD FAILED at stage=... line=...
set -uo pipefail

STAGE="init"
on_error() {
    local code=$?
    echo ""
    echo "[WXReply] ❌ BUILD FAILED at stage=${STAGE} line=${1} exit=${code}"
    echo "[WXReply] 把上面最后 30 行（或 artifact 里的 build-log.txt）发给维护者即可定位。"
    exit "$code"
}
trap 'on_error $LINENO' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 阶段 1/5：工具链 ----------
STAGE="1/5 工具链"
echo "[WXReply] 阶段 1/5：检查工具链"
command -v xcrun >/dev/null 2>&1 || { echo "[WXReply] 找不到 xcrun（这台机器没有 Xcode 命令行工具）"; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "        SDK = ${SDK}"
xcrun --sdk iphoneos clang --version | head -n 3

OUT_DIR="${WXR_OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT_DIR"

SOURCES=$(find src -name '*.m' | sort)
SOURCE_COUNT=$(printf '%s\n' "$SOURCES" | grep -c '\.m$' || true)
echo "        源文件 ${SOURCE_COUNT} 个"

# ---------- 阶段 2/5：编译 ----------
STAGE="2/5 编译"
echo "[WXReply] 阶段 2/5：编译 WXReply.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=14.0 \
    -isysroot "$SDK" \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -install_name @executable_path/WXReply.dylib \
    -Isrc \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
    -Wno-unused-variable -Wno-deprecated-declarations \
    -o "$OUT_DIR/WXReply.dylib" \
    $SOURCES
echo "[WXReply] 阶段 2/5：编译完成"

# ---------- 阶段 3/5：产物 ----------
STAGE="3/5 产物检查"
echo "[WXReply] 阶段 3/5：检查产物"
test -f "$OUT_DIR/WXReply.dylib" || { echo "[WXReply] 编译没有产出 dylib"; exit 1; }
ls -lh "$OUT_DIR/WXReply.dylib"
file "$OUT_DIR/WXReply.dylib" || true

# ---------- 阶段 4/5：依赖（信息性，失败不影响构建） ----------
STAGE="4/5 依赖报告"
echo "[WXReply] 阶段 4/5：依赖库（只作参考；这几行失败不算构建失败）"
if command -v otool >/dev/null 2>&1; then
    otool -L "$OUT_DIR/WXReply.dylib" || echo "        （otool 读取失败，忽略）"
else
    echo "        （没有 otool，跳过）"
fi

# ---------- 阶段 5/5：完成 ----------
STAGE="5/5 完成"
echo ""
echo "[WXReply] ✅ BUILD OK：${OUT_DIR}/WXReply.dylib"
echo "[WXReply] 下一步：传到 iPhone，用 TrollFools 注入微信。"
