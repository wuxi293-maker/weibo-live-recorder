#!/bin/bash
# 原生应用自检：应用包完整性、窗口行为、无终端启动、退出回收
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$HERE/.." && pwd)"
APP="${WLR_APP:-$HOME/Applications/微博直播录制.app}"
LINK="${WLR_LINK:-$HOME/Desktop/微博直播录制.app}"
SWIFTC="${WLR_SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}"
SDK="${WLR_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
PORT_EXPECT=8765

PASS=0
FAIL=0
ok()  { echo "✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "❌ $1"; FAIL=$((FAIL + 1)); }

echo "=== 1. 应用包结构与 Info.plist ==="
if [ -d "$APP" ] && [ -x "$APP/Contents/MacOS/WeiboRecorder" ]; then
  PLIST="$APP/Contents/Info.plist" /usr/bin/python3 - <<'PY'
import os, plistlib, sys
p = os.environ["PLIST"]
d = plistlib.load(open(p, "rb"))
need = ["CFBundleName", "CFBundleExecutable", "CFBundleIdentifier", "CFBundlePackageType", "WLRToolDir"]
missing = [k for k in need if k not in d]
if missing:
    print("缺字段:", missing); sys.exit(1)
if d.get("CFBundlePackageType") != "APPL":
    print("PackageType 非 APPL"); sys.exit(1)
td = d["WLRToolDir"]
if not os.path.isdir(os.path.join(td, "weibo_recorder")):
    print("WLRToolDir 无效:", td); sys.exit(1)
print("plist OK")
PY
  [ $? -eq 0 ] && ok "Info.plist 合法且工具目录有效" || bad "Info.plist 异常"
else
  bad "应用包不存在或不可执行: $APP"
fi

echo "=== 2. 二进制架构 ==="
ARCH="$(/usr/bin/lipo -info "$APP/Contents/MacOS/WeiboRecorder" 2>/dev/null || true)"
if echo "$ARCH" | grep -q "arm64"; then
  ok "二进制为 arm64"
else
  bad "二进制架构异常: $ARCH"
fi

echo "=== 3. 应用图标 ==="
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  ok "图标已打包"
else
  bad "缺少 AppIcon.icns"
fi

echo "=== 4. 源码可编译（类型检查）==="
if "$SWIFTC" -typecheck -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDK" \
      "$TOOL_DIR/macos/native/main.swift" 2>/tmp/wlr_app_typecheck.log; then
  ok "Swift 源码类型检查通过"
else
  bad "Swift 源码类型检查失败（见 /tmp/wlr_app_typecheck.log）"
fi

echo "=== 5. 启动：窗口在屏 / 服务就绪 / 不弹终端 ==="
"$SWIFTC" -O -target arm64-apple-macos13.0 -sdk "$SDK" \
  -o /tmp/wlr_windowinfo "$HERE/helpers/windowinfo.swift" 2>/dev/null

TERM_BEFORE="$(pgrep -x Terminal | sort | tr '\n' ' ')"
P="$(pgrep -x WeiboRecorder || true)"; [ -n "$P" ] && kill -TERM "$P" && sleep 3
open "$APP"
sleep 8

WIN="$(/tmp/wlr_windowinfo WeiboRecorder 2>/dev/null)"
echo "  窗口: $WIN"
if echo "$WIN" | grep -q "onscreen=1"; then
  ok "主窗口已在屏幕上显示"
else
  bad "主窗口未在屏（$WIN）"
fi

if lsof -nP -iTCP:$PORT_EXPECT -sTCP:LISTEN >/dev/null 2>&1; then
  ok "本地服务已监听 127.0.0.1:$PORT_EXPECT"
else
  bad "本地服务未监听"
fi

TERM_AFTER="$(pgrep -x Terminal | sort | tr '\n' ' ')"
if [ "$TERM_BEFORE" = "$TERM_AFTER" ]; then
  ok "启动过程未拉起终端"
else
  bad "启动时拉起了终端（前:$TERM_BEFORE 后:$TERM_AFTER）"
fi

echo "=== 6. 优雅退出：服务回收 / 端口释放 ==="
P="$(pgrep -x WeiboRecorder || true)"
if [ -n "$P" ]; then
  kill -TERM "$P"
  sleep 4
fi
if pgrep -f "weibo_recorder.server" >/dev/null 2>&1; then
  bad "退出后仍有本地服务进程残留"
else
  ok "本地服务已随应用退出"
fi
if lsof -nP -iTCP:$PORT_EXPECT -sTCP:LISTEN >/dev/null 2>&1; then
  bad "端口 $PORT_EXPECT 仍被占用"
else
  ok "端口已释放"
fi

echo "=== 7. 桌面入口 ==="
if [ -L "$LINK" ] || [ -d "$LINK" ]; then
  ok "桌面入口存在: $LINK"
else
  bad "桌面入口缺失: $LINK"
fi
if [ -f "$HOME/Desktop/微博直播录制.command" ]; then
  bad "仍存在旧的 .command 启动方式"
else
  ok "旧 .command 启动方式已清理"
fi

echo "=== 自检结果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
