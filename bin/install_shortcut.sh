#!/bin/bash
# 一键安装：构建原生应用 + 桌面入口（不弹终端窗口、不依赖浏览器）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$HERE/.." && pwd)"
APP_PATH="$HOME/Applications/微博直播录制.app"
LINK_PATH="$HOME/Desktop/微博直播录制.app"

bash "$TOOL_DIR/macos/build_app.sh" "$APP_PATH"

# 桌面入口：指向应用的链接，双击即启动原生窗口，不经过终端
mkdir -p "$HOME/Desktop"
rm -f "$LINK_PATH"
ln -s "$APP_PATH" "$LINK_PATH"

# 清理旧版基于 .command / 浏览器窗口的启动方式
rm -f "$HOME/Desktop/微博直播录制.command"
rm -rf "$TOOL_DIR/macos/WeiboRecorder.app"

echo "应用: $APP_PATH"
echo "桌面入口: $LINK_PATH"
echo "提示：首次启动如被 Gatekeeper 拦截，右键选择「打开」一次即可。"
