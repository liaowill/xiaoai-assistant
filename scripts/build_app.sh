#!/usr/bin/env bash
# 从源码编译并组装 macOS 应用。由 安装.command 调用，也能单独重跑。
# 可用环境变量覆盖目标位置，便于演练：
#   XIAOAI_APP_DEST=/tmp/test.app XIAOAI_WORK_DIR=/tmp/test bash scripts/build_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP_NAME="小爱助手.app"
DEST="${XIAOAI_APP_DEST:-/Applications/$APP_NAME}"
WORK="${XIAOAI_WORK_DIR:-$HOME/Library/Application Support/XiaoAIAssistant}"

echo "==> 检查编译工具"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "缺少 Xcode 命令行工具。请先执行 xcode-select --install，再重新双击 安装.command。"
  exit 1
fi

echo "==> 编译 main.swift（本机架构自动适配 Intel / Apple Silicon）"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/XiaoAIAssistant" "$ROOT/main.swift" \
  -framework AppKit -framework Foundation

echo "==> 组装应用包"
rm -rf "$BUILD/$APP_NAME"
mkdir -p "$BUILD/$APP_NAME/Contents/MacOS" "$BUILD/$APP_NAME/Contents/Resources"
cp "$BUILD/XiaoAIAssistant" "$BUILD/$APP_NAME/Contents/MacOS/"
cp "$ROOT/Info.plist" "$BUILD/$APP_NAME/Contents/Info.plist"
cp "$ROOT/assets/AppIcon.icns" "$BUILD/$APP_NAME/Contents/Resources/AppIcon.icns"

echo "==> 本机签名（本地编译，不经过网络下载，不会被系统拦截）"
codesign -s - --force --deep "$BUILD/$APP_NAME"
codesign -v "$BUILD/$APP_NAME"

echo "==> 安装到 $DEST"
mkdir -p "$(dirname "$DEST")"
if [ -d "$DEST" ]; then
  BACKUP="$WORK/旧版本备份-$(date +%Y%m%d%H%M%S).app"
  mkdir -p "$WORK"
  mv "$DEST" "$BACKUP"
  echo "旧版本已移到：$BACKUP（确认新版没问题后可自行删除）"
fi
cp -R "$BUILD/$APP_NAME" "$DEST"
codesign -v "$DEST"

# 让启动台 / 访达立刻刷新图标；演练安装到临时目录时不注册
if [ "$DEST" = "/Applications/$APP_NAME" ]; then
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$LSREG" ] && "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
fi

echo "完成：$DEST"
