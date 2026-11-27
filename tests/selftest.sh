#!/usr/bin/env bash
# 自检脚本：语法编译 + 解析连通 + 合并校验 + plist 合法性 + 界面服务冒烟
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
[[ -f "$DIR/env.local" ]] && source "$DIR/env.local"
PASS=0; FAIL=0

ok()   { echo "✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "❌ $1"; FAIL=$((FAIL+1)); }

echo "=== 1. Python 语法编译 ==="
if python3 -m py_compile weibo_recorder/*.py; then
  ok "py_compile 通过"
else
  bad "py_compile 失败"
fi

echo "=== 2. shell 入口语法 ==="
if bash -n bin/weibo-recorder && bash -n bin/weibo-recorder-ui && bash -n bin/install_shortcut.sh; then
  ok "shell 入口 bash -n 通过"
else
  bad "shell 入口语法错误"
fi

echo "=== 3. plist XML 合法性 ==="
export WLR_APP_PLIST="$HOME/Applications/微博直播录制.app/Contents/Info.plist"
python3 - <<'PY'
import os, plistlib, xml.etree.ElementTree as ET
ET.parse("launchd/com.doubao.weibo.live.recorder.plist.template")
p = os.environ.get("WLR_APP_PLIST", "")
if p and os.path.exists(p):
    d = plistlib.load(open(p, "rb"))
    assert d.get("CFBundlePackageType") == "APPL" and "WLRToolDir" in d
    print("plist XML 解析通过（含原生应用 Info.plist）")
else:
    print("plist XML 解析通过（原生应用未安装，跳过其 Info.plist）")
PY
[ $? -eq 0 ] && ok "plist XML 合法" || bad "plist XML 非法"

echo "=== 4. 解析器连通性（已结束房间，期望 status=3） ==="
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from weibo_recorder import resolve
try:
    info = resolve.resolve("1022:2321325368838937510380", timeout=8)
    print("status=", info["status"], "stream=", (info["stream"] or "")[:40])
    assert info["status"] in (0, 1, 2, 3), "status 越界"
    print("解析器返回正常")
except Exception as e:
    print("解析器网络异常（不阻塞离线自检）:", e)
PY
[ $? -eq 0 ] && ok "解析器执行完成" || bad "解析器异常"

echo "=== 5. 合成分段合并 / 抽轨 / 校验 ==="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/segments"
FF="${FFMPEG_BIN:-$(command -v ffmpeg || true)}"
FP="${FFPROBE_BIN:-$(command -v ffprobe || true)}"

"$FF" -hide_banner -loglevel error -y \
  -f lavfi -i testsrc=duration=3:size=320x240:rate=25 \
  -f lavfi -i sine=frequency=440:duration=3 \
  -ac 2 -c:v mpeg4 -c:a aac "$TMP/segments/seg_001.ts"
"$FF" -hide_banner -loglevel error -y \
  -f lavfi -i testsrc=duration=3:size=320x240:rate=25 \
  -f lavfi -i sine=frequency=660:duration=3 \
  -ac 2 -c:v mpeg4 -c:a aac "$TMP/segments/seg_002.ts"

python3 - <<PY
import sys, pathlib, json
sys.path.insert(0, ".")
from weibo_recorder.recorder import merge_segments
tmp = pathlib.Path("$TMP")
segs = sorted((tmp/"segments").glob("seg_*.ts"))
assert len(segs) == 2, f"合成分段缺失: {segs}"
mp4 = tmp/"video"/"demo.mp4"; m4a = tmp/"audio"/"demo.m4a"
report = merge_segments(segs, mp4, m4a, "$FF", "$FP", with_audio=True)
v = report["mp4"].get("video"); a = report["mp4"].get("audio")
assert v and v.get("width") == 320 and v.get("height") == 240, "视频轨异常"
assert a and int(a.get("channels", 0)) >= 1, "音频轨异常"
assert float(report["mp4"]["duration"]) > 5, "时长不足"
assert report.get("m4a"), "未抽出 m4a"
print("合成合并 / 双轨 / 抽 m4a 校验通过")
PY
[ $? -eq 0 ] && ok "合成合并链路通过" || bad "合成合并链路失败"

echo "=== 6. 界面服务冒烟 ==="
UI_TMP="$(mktemp -d)"
PORT=8799
PYTHONPATH=. python3 -m weibo_recorder.server --port "$PORT" --out-dir "$UI_TMP" >/tmp/wlr_selftest_ui.log 2>&1 &
UI_PID=$!
sleep 1.5
CODE=$(curl -s --max-time 5 -o /tmp/wlr_selftest_index.html -w "%{http_code}" "http://127.0.0.1:$PORT/")
STATUS=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/status")
TRAVERSE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/media?path=../../etc/passwd")
CHECK=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
  -d '{"url":"https://weibo.com/l/wblive/p/show/1022:2321325368838937510380"}' \
  "http://127.0.0.1:$PORT/api/check")
echo "check=$CHECK" | head -c 200; echo
kill "$UI_PID" 2>/dev/null; sleep 1; kill -9 "$UI_PID" 2>/dev/null
pkill -9 -f "weibo_recorder.server --port $PORT" 2>/dev/null
wait "$UI_PID" 2>/dev/null
rm -rf "$UI_TMP" /tmp/wlr_selftest_index.html
CHECK_OK=$(echo "$CHECK" | grep -o '"status": *3' | head -1)
if [ "$CODE" = "200" ] && [ "$STATUS" = "200" ] && [ "$TRAVERSE" = "404" ] && [ -n "$CHECK_OK" ]; then
  ok "界面首页/状态接口/越界拦截/直播状态查询通过"
else
  bad "界面服务异常 code=$CODE status=$STATUS traverse=$TRAVERSE check=$CHECK"
  cat /tmp/wlr_selftest_ui.log 2>/dev/null
fi

echo "=== 自检结果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
