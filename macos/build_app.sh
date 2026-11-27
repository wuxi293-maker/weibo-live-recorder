#!/bin/bash
# 从源码构建原生 macOS 应用包（AppKit 窗口，不依赖浏览器/终端）
# 用法: macos/build_app.sh [输出 .app 路径]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$HERE/.." && pwd)"
APP_PATH="${1:-$HOME/Applications/微博直播录制.app}"

SWIFTC="${WLR_SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}"
SDK="${WLR_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
ICON_SRC="$HERE/assets/AppIcon.png"

if [ ! -x "$SWIFTC" ]; then
  echo "找不到 swiftc：$SWIFTC（请安装 Xcode Command Line Tools: xcode-select --install）" >&2
  exit 1
fi

echo "→ 编译原生应用"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
"$SWIFTC" -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -o "$APP_PATH/Contents/MacOS/WeiboRecorder" \
  "$HERE/native/main.swift" \
  -framework AVKit -framework AVFoundation

chmod +x "$APP_PATH/Contents/MacOS/WeiboRecorder"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

echo "→ 写入 Info.plist"
TOOL_DIR="$TOOL_DIR" OUT_DIR="$HOME/Movies/WeiboLive" PLIST="$APP_PATH/Contents/Info.plist" /usr/bin/python3 - <<'PY'
import os, plistlib
d = {
    "CFBundleName": "微博直播录制",
    "CFBundleDisplayName": "微博直播录制",
    "CFBundleExecutable": "WeiboRecorder",
    "CFBundleIdentifier": "com.guowei.weibo.live.recorder",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.2.0",
    "CFBundleVersion": "3",
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSSupportsAutomaticTermination": False,
    "WLRToolDir": os.environ["TOOL_DIR"],
    "WLROutDir": os.environ["OUT_DIR"],
}
with open(os.environ["PLIST"], "wb") as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_XML)
PY

if [ -f "$ICON_SRC" ]; then
  echo "→ 内置工具目录（自包含，换机器也能直接跑）"
rm -rf "$APP_PATH/Contents/Resources/tool"
mkdir -p "$APP_PATH/Contents/Resources/tool"
rsync -a \
  "$TOOL_DIR/weibo_recorder" \
  "$TOOL_DIR/bin" \
  "$TOOL_DIR/config.example.env" \
  "$TOOL_DIR/README.md" \
  "$APP_PATH/Contents/Resources/tool/" 2>/dev/null || true
if [ -f "$TOOL_DIR/env.local" ]; then
  cp "$TOOL_DIR/env.local" "$APP_PATH/Contents/Resources/tool/env.local"
fi
find "$APP_PATH/Contents/Resources/tool" -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

echo "→ 生成图标"
  TMP_SET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$TMP_SET"
  for s in 16 32 128 256 512; do
    /usr/bin/sips -z "$s" "$s" "$ICON_SRC" --out "$TMP_SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    /usr/bin/sips -z "$d" "$d" "$ICON_SRC" --out "$TMP_SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$TMP_SET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$TMP_SET")"
fi

echo "→ 临时签名"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_PATH" >/dev/null 2>&1 || true

echo "✅ 构建完成: $APP_PATH"
