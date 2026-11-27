"""本地图形界面后端（仅标准库）。

启动一个本地 HTTP 服务：
- 页面：链接输入、直播状态、录制状态、成片预览；
- 控制：启停录制（复用 recorder.py 子进程）；
- 媒体：在成片目录范围内提供带 Range 的文件访问，供 <video> 预览。
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import urlparse, parse_qs

from . import resolve as resolve_mod
from .ffmpeg_tools import find_binary, probe_media

LOGGER = logging.getLogger("weibo-ui")
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
WEB_DIR = PACKAGE_ROOT / "weibo_recorder" / "web"

STATUS_LABEL = {0: "未开播", 1: "直播中", 2: "已结束", 3: "已结束"}
MIN_FREE_BYTES = 6 * 1024 ** 3


class Controller:
    def __init__(self, out_dir: Path, host: str, port: int):
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.runtime_dir = self.out_dir / ".runtime"
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.stop_file = self.runtime_dir / "stop.flag"
        self.state_file = self.runtime_dir / "session.txt"
        self.host = host
        self.port = port
        self.proc: Optional[subprocess.Popen] = None
        self.url: str = ""
        self.started_at: Optional[float] = None
        self._live_cache: Dict[str, object] = {"at": 0.0, "data": {}}
        self._probe_cache: Dict[str, Dict[str, object]] = {}
        self._lock = threading.Lock()

    # ---------- 阶段 / 接管 ----------
    def _phase(self) -> Dict[str, object]:
        """读会话内的 phase.json；用于显示「录制中 / 正在合并」以及接管重启后的录制。"""
        session = self._session_dir()
        if not session:
            return {}
        p = session / "phase.json"
        if not p.exists():
            return {}
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        pid = int(data.get("pid") or 0)
        alive = False
        if pid > 0:
            try:
                os.kill(pid, 0)
                alive = True
            except OSError:
                alive = False
        data["pid"] = pid
        data["alive"] = alive
        return data

    def _adopted_running(self) -> bool:
        ph = self._phase()
        return bool(ph.get("alive")) and ph.get("phase") in ("starting", "recording", "merging")

    def _probe_cached(self, path: Path, stat: os.stat_result, ffprobe: Optional[str]) -> Dict[str, object]:
        key = f"{path}:{stat.st_size}:{int(stat.st_mtime)}"
        hit = self._probe_cache.get(key)
        if hit is not None:
            return hit
        data = probe_media(str(path), ffprobe) if ffprobe else {}
        self._probe_cache[key] = data
        if len(self._probe_cache) > 300:
            self._probe_cache.clear()
        return data

    # ---------- 录制控制 ----------
    def start(self, url: str, segment_seconds: int, max_seconds: int,
              no_audio: bool) -> Dict[str, object]:
        live_id = resolve_mod.extract_live_id(url)
        if not live_id:
            return {"ok": False, "error": "无法从链接解析 live_id"}
        with self._lock:
            if self.proc and self.proc.poll() is None:
                return {"ok": False, "error": "已有录制在运行"}
            if self._adopted_running():
                return {"ok": False, "error": "已有录制在运行（上次启动的录制仍在继续）"}

            free = shutil.disk_usage(str(self.out_dir)).free
            if free < MIN_FREE_BYTES:
                return {"ok": False,
                        "error": f"磁盘剩余 {free / 1024 ** 3:.1f}GB，至少需要 {MIN_FREE_BYTES / 1024 ** 3:.0f}GB"}
            segment_seconds = max(30, min(int(segment_seconds), 3600))
            max_seconds = max(0, int(max_seconds))

            # 清理旧标记
            self.stop_file.unlink(missing_ok=True)
            self.state_file.unlink(missing_ok=True)

            cmd = [
                sys.executable, "-m", "weibo_recorder.recorder",
                "--url", url,
                "--out-dir", str(self.out_dir),
                "--segment-seconds", str(segment_seconds),
                "--max-seconds", str(max_seconds),
                "--stop-file", str(self.stop_file),
                "--state-file", str(self.state_file),
            ]
            if no_audio:
                cmd.append("--no-audio")

            env = os.environ.copy()
            env["PYTHONPATH"] = f"{PACKAGE_ROOT}{':' + env['PYTHONPATH'] if env.get('PYTHONPATH') else ''}"
            log_fh = open(self.runtime_dir / "recorder.out.log", "ab")
            self.proc = subprocess.Popen(cmd, env=env, stdout=log_fh, stderr=subprocess.STDOUT)
            self.url = url
            self.started_at = time.time()
            LOGGER.info("录制已启动 pid=%s url=%s", self.proc.pid, url)
            return {"ok": True, "pid": self.proc.pid}

    def check(self, url: str) -> Dict[str, object]:
        live_id = resolve_mod.extract_live_id(url)
        if not live_id:
            return {"ok": False, "error": "无法从链接解析 live_id"}
        self.url = url
        self._live_cache = {"at": 0.0, "data": {}}
        return {"ok": True, "live": self._live_status()}

    def stop(self) -> Dict[str, object]:
        with self._lock:
            own = bool(self.proc and self.proc.poll() is None)
            if not own and not self._adopted_running():
                return {"ok": True, "running": False}
            self.stop_file.touch()
            LOGGER.info("已写入停止标记，录制进程会立刻收尾当前分段并合并")
            return {"ok": True, "running": True}

    def _session_dir(self) -> Optional[Path]:
        if self.state_file.exists():
            try:
                p = Path(self.state_file.read_text(encoding="utf-8").strip())
            except OSError:
                return None
            if p.is_dir():
                return p
        return None

    def _live_status(self) -> Dict[str, object]:
        if not self.url:
            return {"status": -1, "label": "未输入链接"}
        # 界面 2s 轮询，缓存 15s：3 小时从 ~2000 次微博请求降到 ~700 次，降低被限流风险
        if time.time() - float(self._live_cache["at"]) < 15:
            return self._live_cache["data"]
        try:
            info = resolve_mod.resolve(resolve_mod.extract_live_id(self.url))
            data = {
                "status": info["status"],
                "label": STATUS_LABEL.get(info["status"], "未知"),
                "title": info.get("title", ""),
            }
        except Exception as e:  # noqa: BLE001
            data = {"status": -1, "label": "解析失败", "error": str(e)}
        self._live_cache = {"at": time.time(), "data": data}
        return data

    def status(self) -> Dict[str, object]:
        own_running = bool(self.proc and self.proc.poll() is None)
        phase = self._phase()
        adopted = (not own_running) and bool(phase.get("alive")) and phase.get("phase") in (
            "starting", "recording", "merging")
        running = own_running or adopted
        session = self._session_dir()
        segments: List[Path] = []
        latest_size = 0
        latest_mtime = 0.0
        if session:
            segments = sorted((session / "segments").glob("seg_*.ts"))
            if segments:
                latest = segments[-1]
                try:
                    latest_size = latest.stat().st_size
                    latest_mtime = latest.stat().st_mtime
                except OSError:
                    pass

        if own_running and self.started_at:
            elapsed = int(time.time() - self.started_at)
        elif adopted:
            started = float(phase.get("started_at") or 0)
            elapsed = int(time.time() - started) if started else 0
        else:
            elapsed = 0
        if not running:
            elapsed = 0
        try:
            free = shutil.disk_usage(str(self.out_dir)).free
        except OSError:
            free = -1
        return {
            "live": self._live_status(),
            "recording": {
                "running": running,
                "pid": (self.proc.pid if self.proc else (phase.get("pid") if adopted else None)),
                "session_dir": str(session) if session else None,
                "segments": len(segments),
                "latest_size": latest_size,
                "latest_mtime": latest_mtime,
                "elapsed": elapsed,
                "phase": phase.get("phase") if running else "idle",
                "adopted": adopted,
                "disk_free": free,
            },
            "recordings": self._scan_recordings(),
        }

    def _scan_recordings(self) -> List[Dict[str, object]]:
        items: List[Dict[str, object]] = []
        if not self.out_dir.exists():
            return items
        ffprobe = None
        try:
            ffprobe = find_binary("ffprobe", os.environ.get("FFPROBE_BIN"))
        except Exception:  # noqa: BLE001
            ffprobe = None

        for mp4 in sorted(self.out_dir.glob("*/*/video/*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True):
            try:
                stat = mp4.stat()
            except OSError:
                continue
            item: Dict[str, object] = {
                "name": mp4.stem,
                "rel": mp4.relative_to(self.out_dir).as_posix(),
                "size": stat.st_size,
                "mtime": stat.st_mtime,
                "mtime_str": dt.datetime.fromtimestamp(stat.st_mtime).strftime("%m-%d %H:%M"),
                "duration": None,
                "video": None,
                "audio": None,
                "m4a": None,
            }
            m4a = mp4.parent.parent / "audio" / f"{mp4.stem}.m4a"
            if m4a.exists():
                item["m4a"] = m4a.relative_to(self.out_dir).as_posix()
            if ffprobe:
                probe = self._probe_cached(mp4, stat, ffprobe)
                if probe.get("error") and time.time() - stat.st_mtime < 5:
                    # 刚写完/正在合并的 mp4（moov 还没落盘），先不列，避免预览到半成品
                    continue
                item["duration"] = probe.get("duration")
                item["video"] = probe.get("video")
                item["audio"] = probe.get("audio")
            items.append(item)
        return items

    def safe_media_path(self, rel: str) -> Optional[Path]:
        root = self.out_dir.resolve()
        try:
            cand = (root / rel).resolve()
            cand.relative_to(root)
        except (ValueError, OSError):
            return None
        if cand.is_file():
            return cand
        return None


class Handler(BaseHTTPRequestHandler):
    controller: Controller

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        msg = fmt % args
        # 界面每 2 秒轮询一次状态，不写日志，避免 ui.out.log 无限增长
        if "/api/status" in msg:
            return
        LOGGER.info("%s - %s", self.address_string(), msg)

    def _send_json(self, obj: Dict[str, object], status: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/" or parsed.path == "/index.html":
            self._serve_index()
        elif parsed.path == "/api/status":
            self._send_json(self.controller.status())
        elif parsed.path == "/media":
            self._serve_media(parse_qs(parsed.query).get("path", [""])[0])
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        payload = {}
        if length:
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except json.JSONDecodeError:
                self._send_json({"ok": False, "error": "请求体不是合法 JSON"}, 400)
                return

        if parsed.path == "/api/start":
            res = self.controller.start(
                url=payload.get("url", ""),
                segment_seconds=int(payload.get("segment_seconds", 180)),
                max_seconds=int(payload.get("max_seconds", 0)),
                no_audio=bool(payload.get("no_audio", False)),
            )
            self._send_json(res, 200 if res["ok"] else 409)
        elif parsed.path == "/api/check":
            res = self.controller.check(payload.get("url", ""))
            self._send_json(res, 200 if res["ok"] else 400)
        elif parsed.path == "/api/stop":
            self._send_json(self.controller.stop())
        else:
            self._send_json({"error": "not found"}, 404)

    def _serve_index(self) -> None:
        html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_media(self, rel: str) -> None:
        path = self.controller.safe_media_path(rel)
        if not path:
            self._send_json({"error": "文件不存在或越界"}, 404)
            return
        size = path.stat().st_size
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng and rng.startswith("bytes="):
            part = rng[6:].split("-")
            start = int(part[0]) if part[0] else 0
            end = int(part[1]) if len(part) > 1 and part[1] else size - 1
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", "video/mp4" if path.suffix == ".mp4" else "audio/mpeg")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description="微博直播录制 · 本地图形界面")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--out-dir", default=str(Path.home() / "Movies" / "WeiboLive"))
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    controller = Controller(Path(args.out_dir), args.host, args.port)
    Handler.controller = controller
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    LOGGER.info("界面已启动: http://%s:%d", args.host, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOGGER.info("退出界面")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
