"""微博直播本地录制主程序（macOS / Linux 通用，低占用：直链拉流 + 流拷贝）。

连续性策略（v2）：
- 一次 ffmpeg 进程内用 segment muxer 连续切片（-f segment），切点之间没有空档，
  不再「每段退出 + sleep 5 + 重新解析 + 再启动」；
- 只有在断流 / 直链过期 / 进程异常退出时才重新解析并续录（-segment_start_number 接号）；
- 停止标记由录制循环 0.5s 轮询，收到后向 ffmpeg 发 SIGINT，让它立刻收尾当前段；
- 90 秒没有新字节写入视为卡死，自动重连。

其它：
- 视频/音频轨原样拷贝（-c copy），不录屏、不转码、不抓声卡；音频映射用 0:a:0?，
  没有音轨的直播不会被 ffmpeg 直接判错；
- 开始前检查剩余磁盘；同一天同一房间再次录制时自动顺延到 v2/v3，避免把上一次的分段混进本次；
- 结束后 concat 拷贝合并 mp4，抽出独立 m4a，做 ffprobe 校验并对比分段总时长（连续性报告）。
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

from . import resolve as resolve_mod
from .ffmpeg_tools import find_binary, probe_media, volumedetect

LOGGER = logging.getLogger("weibo-recorder")

# 3 小时 720p 约 2.5GB，合并峰值约 3 倍；低于这个余量直接拒绝开始，避免录到一半磁盘满
MIN_FREE_BYTES = 6 * 1024 ** 3
STALL_SECONDS = 90


def sanitize(name: str) -> str:
    name = re.sub(r"[^\w一-龥-]+", "_", name.strip())
    return name.strip("_") or "weibo_live"


def setup_logging(log_dir: Path) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    fh = logging.FileHandler(log_dir / f"recorder_{stamp}.log", encoding="utf-8")
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    LOGGER.handlers.clear()
    LOGGER.setLevel(logging.INFO)
    LOGGER.addHandler(fh)
    LOGGER.addHandler(sh)


def existing_segments(seg_dir: Path) -> List[Path]:
    return sorted(seg_dir.glob("seg_*.ts"))


def next_seg_number(seg_dir: Path) -> int:
    """取已有分段的最大编号 + 1，绝不复用已存在的编号。"""
    top = 0
    for p in existing_segments(seg_dir):
        try:
            top = max(top, int(p.stem.split("_")[1]))
        except (IndexError, ValueError):
            continue
    return top + 1


def build_headers(cookie: Optional[str], ua: str) -> str:
    lines = [f"Referer: https://weibo.com/", f"User-Agent: {ua}"]
    if cookie:
        lines.append(f"Cookie: {cookie}")
    return "\r\n".join(lines) + "\r\n"


def dir_has_recording(path: Path) -> bool:
    segs = path / "segments"
    video = path / "video"
    if segs.is_dir() and any(segs.glob("seg_*.ts")):
        return True
    if video.is_dir() and any(video.glob("*.mp4")):
        return True
    return False


def pick_session_dir(base_dir: Path, version: str) -> Path:
    """同日同房间第二次录制自动顺延版本，避免旧分段被合并进新片、成片同名覆盖。"""
    cand = base_dir / version
    if not dir_has_recording(cand):
        return cand
    n = 2
    while True:
        cand = base_dir / f"v{n}"
        if not dir_has_recording(cand):
            LOGGER.info("会话目录已有内容，本次改用 %s", cand.name)
            return cand
        n += 1


def write_phase(path: Path, phase: str, **extra: object) -> None:
    """阶段文件：界面据此区分「录制中 / 正在合并 / 空闲」，也用于重启后接管仍在跑的录制。"""
    data = {"phase": phase, "pid": os.getpid(), "updated_at": time.time()}
    data.update(extra)
    tmp = path / "phase.json.tmp"
    try:
        tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path / "phase.json")
    except OSError as e:  # noqa: BLE001
        LOGGER.warning("写阶段文件失败: %s", e)


def tail_file(path: Path, limit: int = 1500) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    text = data[-limit:].decode("utf-8", "replace")
    return text.strip().splitlines()[-1] if text.strip() else ""


def progress_signature(seg_dir: Path) -> Tuple[str, int, int]:
    """当前正在写的分段（名字、大小、mtime），用于判断拉流是否还在进数据。"""
    segs = existing_segments(seg_dir)
    if not segs:
        return ("", 0, 0)
    p = segs[-1]
    try:
        st = p.stat()
    except OSError:
        return (p.name, 0, 0)
    return (p.name, st.st_size, int(st.st_mtime))


def record_continuous(
    stream: str,
    seg_dir: Path,
    ffmpeg: str,
    headers: str,
    segment_seconds: int,
    with_audio: bool,
    remaining: Optional[int],
    start_number: int,
    stop_file: str,
    ffmpeg_log: Path,
) -> Tuple[int, str]:
    """启动单个 ffmpeg 连续切段；返回 (退出码, 结束原因: stopped/stall/exit)。"""
    pattern = seg_dir / "seg_%03d.ts"
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "warning", "-y",
        "-rw_timeout", "5000000",
        "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
        "-headers", headers,
        "-i", stream,
        "-map", "0:v:0",
    ]
    if with_audio:
        # 可选音频：房间没有音轨时不会直接失败
        cmd += ["-map", "0:a:0?"]
    cmd += [
        "-c", "copy",
        "-f", "segment",
        "-segment_time", str(segment_seconds),
        "-segment_format", "mpegts",
        "-reset_timestamps", "1",
        "-segment_start_number", str(start_number),
    ]
    if remaining and remaining > 0:
        cmd += ["-t", str(int(remaining))]
    cmd.append(str(pattern))

    LOGGER.info("ffmpeg: %s", " ".join(cmd))
    reason = "exit"

    def ask_quit(p: subprocess.Popen) -> None:
        """让 ffmpeg 优雅收尾当前分段。

        本机这版 ffmpeg 8.1.2 对 SIGINT/SIGTERM 不响应（实测），只能走 stdin 的 'q'；
        'q' 不生效时由调用方超时强杀。
        """
        try:
            if p.stdin:
                p.stdin.write(b"q\n")
                p.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    with open(ffmpeg_log, "ab") as fh:
        fh.write(f"\n=== {dt.datetime.now():%Y-%m-%d %H:%M:%S} start seg #{start_number} ===\n".encode())
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=fh, stderr=subprocess.STDOUT)
        last_sig = progress_signature(seg_dir)
        last_change = time.time()
        ask_at: Optional[float] = None
        while proc.poll() is None:
            if ask_at is None:
                if stop_file and Path(stop_file).exists():
                    LOGGER.info("收到停止标记，要求 ffmpeg 收尾当前分段")
                    reason = "stopped"
                    ask_quit(proc)
                    ask_at = time.time()
                else:
                    sig = progress_signature(seg_dir)
                    if sig != last_sig:
                        last_sig = sig
                        last_change = time.time()
                    elif time.time() - last_change > STALL_SECONDS:
                        LOGGER.warning("%ss 没有新数据写入，判定卡死，重连", STALL_SECONDS)
                        reason = "stall"
                        ask_quit(proc)
                        ask_at = time.time()
            elif time.time() - ask_at > 8:
                LOGGER.warning("'q' 8s 未生效，强制结束 ffmpeg（当前分段会被截断）")
                proc.kill()
                break
            time.sleep(0.5)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            LOGGER.warning("ffmpeg 未在 15s 内退出，强制结束")
            proc.kill()
            proc.wait()
    return (proc.returncode if proc.returncode is not None else -1), reason


def disk_free(out_dir: Path) -> int:
    try:
        return shutil.disk_usage(str(out_dir)).free
    except OSError:
        return -1


def merge_segments(
    segments: List[Path],
    mp4: Path,
    m4a: Optional[Path],
    ffmpeg: str,
    ffprobe: str,
    with_audio: bool,
) -> dict:
    """concat 拷贝合并；不重编码。返回校验报告 dict（含连续性对比）。"""
    if not segments:
        raise RuntimeError("无有效分段可合并")

    seg_dir = segments[0].parent
    concat_list = seg_dir / "concat_list.txt"
    concat_list.write_text(
        "".join(f"file '{s.as_posix()}'\n" for s in segments), encoding="utf-8"
    )

    LOGGER.info("合并 mp4: %s", mp4)
    mp4.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
         "-f", "concat", "-safe", "0", "-i", str(concat_list),
         "-c", "copy", "-movflags", "+faststart", str(mp4)],
        capture_output=True, text=True, timeout=1800,
    )
    LOGGER.info("合并 mp4 退出码=%s", r.returncode)
    if r.returncode != 0:
        LOGGER.error("合并失败: %s", r.stderr[-800:])
        raise RuntimeError("mp4 合并失败")

    report = {"mp4": probe_media(str(mp4), ffprobe)}

    if with_audio and m4a is not None:
        # 仅当成片确有音频轨时抽 m4a
        if report["mp4"].get("audio"):
            m4a.parent.mkdir(parents=True, exist_ok=True)
            ra = subprocess.run(
                [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                 "-i", str(mp4), "-map", "0:a:0", "-c:a", "copy", str(m4a)],
                capture_output=True, text=True, timeout=1800,
            )
            LOGGER.info("抽出 m4a 退出码=%s", ra.returncode)
            if ra.returncode == 0:
                report["m4a"] = probe_media(str(m4a), ffprobe)
            else:
                LOGGER.error("抽 m4a 失败: %s", ra.stderr[-400:])

    # 连续性对比：成片时长 vs 各分段时长之和，差值就是切点间丢失的时长
    seg_total = 0.0
    seg_count = 0
    for s in segments:
        p = probe_media(str(s), ffprobe)
        try:
            seg_total += float(p.get("duration") or 0)
            seg_count += 1
        except (TypeError, ValueError):
            continue
    report["segments"] = {"count": seg_count, "sum_duration": round(seg_total, 3)}
    try:
        mp4_dur = float(report["mp4"].get("duration") or 0)
    except (TypeError, ValueError):
        mp4_dur = 0.0
    delta = round(mp4_dur - seg_total, 3)
    report["continuity"] = {
        "delta_seconds": delta,
        "ok": abs(delta) <= max(2.0, seg_total * 0.005),
    }
    if not report["continuity"]["ok"]:
        LOGGER.warning("成片与分段总时长差 %.3fs，请检查切点", delta)

    report["audio_level"] = volumedetect(str(mp4), ffmpeg) if with_audio else {}
    return report


def parse_end_epoch(end_str: Optional[str]) -> Optional[float]:
    if not end_str:
        return None
    dt_obj = dt.datetime.strptime(end_str.strip(), "%Y-%m-%d %H:%M:%S")
    return dt_obj.timestamp()


def run(args: argparse.Namespace) -> int:
    live_id = resolve_mod.extract_live_id(args.url or args.id or "")
    if not live_id:
        LOGGER.error("无法从输入解析 live_id: %s", args.url or args.id)
        return 2

    ffmpeg = find_binary("ffmpeg", args.ffmpeg)
    ffprobe = find_binary("ffprobe", args.ffprobe)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    free = disk_free(out_dir)
    if 0 <= free < MIN_FREE_BYTES:
        LOGGER.error("剩余磁盘空间不足：%.1f GB（至少需要 %.0f GB），已取消录制",
                     free / 1024 ** 3, MIN_FREE_BYTES / 1024 ** 3)
        return 5

    # 先解析一次取标题命名目录（失败不阻塞，等待开播后再解析）
    title = args.title or live_id
    try:
        first = resolve_mod.resolve(live_id, cookie=args.cookie)
        title = first.get("title") or title
    except Exception as e:  # noqa: BLE001
        LOGGER.warning("首次解析失败（将在循环中重试）: %s", e)

    date_slug = dt.datetime.now().strftime("%Y%m%d")
    base_dir = out_dir / f"{date_slug}_{sanitize(title)}"
    session_dir = pick_session_dir(base_dir, args.version)
    seg_dir = session_dir / "segments"
    log_dir = session_dir / "logs"
    video_dir = session_dir / "video"
    audio_dir = session_dir / "audio"
    for d in (seg_dir, log_dir, video_dir, audio_dir):
        d.mkdir(parents=True, exist_ok=True)

    setup_logging(log_dir)
    ffmpeg_log = log_dir / "ffmpeg.log"
    start_epoch = time.time()
    LOGGER.info("=== 微博直播录制启动（连续切片）===")
    LOGGER.info("live_id=%s 会话目录=%s", live_id, session_dir)
    LOGGER.info("ffmpeg=%s ffprobe=%s 剩余空间=%.1fGB", ffmpeg, ffprobe, free / 1024 ** 3)

    deadline = time.time() + args.max_seconds if args.max_seconds and args.max_seconds > 0 else None
    with_audio = not args.no_audio
    headers = build_headers(args.cookie, resolve_mod.DEFAULT_UA)
    stop_file = getattr(args, "stop_file", "") or ""

    if getattr(args, "state_file", None):
        Path(args.state_file).parent.mkdir(parents=True, exist_ok=True)
        Path(args.state_file).write_text(session_dir.as_posix(), encoding="utf-8")

    write_phase(session_dir, "starting", session_dir=str(session_dir),
                segment_seconds=args.segment_seconds, with_audio=with_audio,
                started_at=start_epoch)

    consecutive_failures = 0
    recorded_any = False
    while True:
        now = time.time()
        if stop_file and Path(stop_file).exists():
            LOGGER.info("启动前已存在停止标记，直接收尾")
            break
        if deadline and now >= deadline:
            LOGGER.info("到达最大录制时长 %ss，停止", args.max_seconds)
            break

        try:
            info = resolve_mod.resolve(live_id, cookie=args.cookie)
        except Exception as e:  # noqa: BLE001
            LOGGER.warning("解析异常: %s；%ss 后重试", e, args.poll_interval)
            time.sleep(args.poll_interval)
            continue

        status = info["status"]
        stream = info["stream"]
        LOGGER.info("房间状态 status=%s stream=%s", status, (stream or "")[:70])

        if resolve_mod.is_ended(status):
            LOGGER.info("直播已结束(status=%s)，停止录制", status)
            break
        if not resolve_mod.is_live(status) or not stream:
            LOGGER.info("未开播或暂无直链，%ss 后重试", args.poll_interval)
            time.sleep(args.poll_interval)
            continue

        remaining = int(deadline - time.time()) if deadline else None
        start_number = next_seg_number(seg_dir)
        write_phase(session_dir, "recording", session_dir=str(session_dir),
                    segment_seconds=args.segment_seconds, with_audio=with_audio,
                    started_at=start_epoch)
        rc, reason = record_continuous(
            stream, seg_dir, ffmpeg, headers, args.segment_seconds, with_audio,
            remaining, start_number, stop_file, ffmpeg_log,
        )
        segs = existing_segments(seg_dir)
        LOGGER.info("ffmpeg 退出码=%s 原因=%s 分段数=%d", rc, reason, len(segs))
        if len(segs) > 0:
            recorded_any = True

        if reason == "stopped":
            LOGGER.info("已按停止标记停止拉流")
            break
        if reason == "stall":
            consecutive_failures += 1
            continue
        if rc != 0:
            LOGGER.warning("ffmpeg 异常退出，最近输出: %s", tail_file(ffmpeg_log) or "(无)")
            consecutive_failures += 1
            if consecutive_failures >= 3:
                backoff = min(30, 5 * consecutive_failures)
                LOGGER.warning("连续失败 %d 次，退避 %ss 后重试", consecutive_failures, backoff)
                time.sleep(backoff)
        else:
            consecutive_failures = 0

        if deadline and time.time() >= deadline:
            break

    segs = existing_segments(seg_dir)
    # 丢掉过小/无效分段（例如断流残段）
    valid: List[Path] = []
    for s in segs:
        try:
            if s.stat().st_size >= args.min_segment_bytes:
                valid.append(s)
            else:
                LOGGER.warning("分段 %s 过小（%d 字节），丢弃", s.name, s.stat().st_size)
                s.unlink(missing_ok=True)
        except OSError:
            continue

    if not valid:
        LOGGER.error("未生成任何有效分段，无成片（%s）", "磁盘不足" if 0 <= free < MIN_FREE_BYTES else "直播未提供可用数据")
        write_phase(session_dir, "done", ok=False, error="无有效分段", session_dir=str(session_dir))
        return 4

    mp4 = video_dir / f"{sanitize(title)}_{session_dir.name}.mp4"
    m4a = audio_dir / f"{sanitize(title)}_{session_dir.name}.m4a" if with_audio else None

    write_phase(session_dir, "merging", session_dir=str(session_dir), segments=len(valid),
                started_at=start_epoch)
    report = merge_segments(valid, mp4, m4a, ffmpeg, ffprobe, with_audio)

    report["session_dir"] = str(session_dir)
    report["recorded_segments"] = len(valid)
    report["started_by_pid"] = os.getpid()
    report_path = log_dir / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    LOGGER.info("成片: %s", mp4)
    LOGGER.info("报告: %s", report_path)
    LOGGER.info("=== 录制结束 ===")
    write_phase(session_dir, "done", ok=True, mp4=str(mp4), session_dir=str(session_dir))
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="微博直播本地录制（直链拉流 + 流拷贝 + 连续切片）")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--url", help="微博直播页 URL")
    src.add_argument("--id", help="裸 live_id，如 1022:2321325368838937510380")
    p.add_argument("--out-dir", default=str(Path.home() / "Movies" / "WeiboLive"))
    p.add_argument("--segment-seconds", type=int, default=180)
    p.add_argument("--max-seconds", type=int, default=0, help="0=直到直播结束")
    p.add_argument("--end", help="截止时间 YYYY-MM-DD HH:MM:SS（本机时区）")
    p.add_argument("--cookie", default=os.environ.get("WEIBO_COOKIE"))
    p.add_argument("--title", default="", help="覆盖会话/成片命名标题")
    p.add_argument("--version", default="v1")
    p.add_argument("--no-audio", action="store_true", help="只录画面，不拷音频轨")
    p.add_argument("--min-segment-bytes", type=int, default=50000)
    p.add_argument("--poll-interval", type=int, default=15)
    p.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN"))
    p.add_argument("--ffprobe", default=os.environ.get("FFPROBE_BIN"))
    p.add_argument("--stop-file", default="", help="存在该文件即优雅停止并合并")
    p.add_argument("--state-file", default="", help="回写当前会话目录路径")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
