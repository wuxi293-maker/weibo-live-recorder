"""ffmpeg/ffprobe 路径探测与媒体校验工具。"""
from __future__ import annotations

import json
import shutil
import subprocess
import re
from pathlib import Path
from typing import Dict, Optional

# macOS Homebrew (Apple Silicon / Intel) 与常见路径
MAC_EXTRA_PATHS = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
]


def find_binary(name: str, override: Optional[str] = None) -> str:
    """查找 ffmpeg / ffprobe；优先 override，其次 PATH，再补 macOS 常见路径。"""
    if override:
        p = Path(override)
        if p.is_file() and os_accessible(p):
            return str(p)
        raise FileNotFoundError(f"{name} override 不可执行: {override}")

    found = shutil.which(name)
    if found:
        return found

    for d in MAC_EXTRA_PATHS:
        cand = Path(d) / name
        if cand.is_file() and os_accessible(cand):
            return str(cand)

    raise FileNotFoundError(
        f"未找到 {name}，请先安装（macOS: brew install ffmpeg），或用环境变量指定路径"
    )


def os_accessible(p: Path) -> bool:
    import os
    return os.access(p, os.X_OK)


def probe_media(path: str, ffprobe: str) -> Dict[str, object]:
    """读取媒体元数据：时长、大小、视频轨、音频轨。"""
    cmd = [
        ffprobe, "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", path,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        return {"error": out.stderr.strip()}

    info: Dict[str, object] = {"streams": []}
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": "ffprobe 输出解析失败"}

    fmt = data.get("format", {}) or {}
    info["duration"] = fmt.get("duration")
    info["size"] = fmt.get("size")
    info["bit_rate"] = fmt.get("bit_rate")

    v = next((s for s in data.get("streams", []) if s.get("codec_type") == "video"), None)
    a = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), None)
    if v:
        info["video"] = {
            "codec": v.get("codec_name"),
            "width": v.get("width"),
            "height": v.get("height"),
            "fps": v.get("r_frame_rate"),
            "frames": v.get("nb_frames"),
        }
    if a:
        info["audio"] = {
            "codec": a.get("codec_name"),
            "channels": a.get("channels"),
            "sample_rate": a.get("sample_rate"),
            "frames": a.get("nb_frames"),
        }
    return info


def volumedetect(path: str, ffmpeg: str, audio_index: int = 0) -> Dict[str, str]:
    """检测音频电平，返回 mean / max（无音频轨时返回空）。"""
    cmd = [
        ffmpeg, "-hide_banner", "-i", path,
        "-map", f"0:a:{audio_index}", "-af", "volumedetect",
        "-f", "null", "-",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    text = out.stderr
    mean = re.search(r"mean_volume:\s*(-?[\d.]+)\s*dB", text)
    peak = re.search(r"max_volume:\s*(-?[\d.]+)\s*dB", text)
    result: Dict[str, str] = {}
    if mean:
        result["mean_db"] = mean.group(1)
    if peak:
        result["max_db"] = peak.group(1)
    return result
