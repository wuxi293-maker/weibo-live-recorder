"""微博直播房间状态与直链解析。

仅依赖 Python 标准库。接口为网页版房间状态 JSON，游客可见的公开直播无需 cookie；
受限/付费流可通过 cookie 字段携带本人登录态。
"""
from __future__ import annotations

import json
import re
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional

API = "https://weibo.com/l/!/2/wblive/room/show_pc_live.json"
DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)

# status 口径（与今晚实测一致）：1=直播中，0=未开播，2/3=已结束
STATUS_LIVE = 1
STATUS_ENDED = (2, 3)


def extract_live_id(text: str) -> str:
    """从直播页 URL、接口链接或裸 ID 中提取 live_id。"""
    if not text:
        return ""
    text = text.strip()
    m = re.search(r"show/([0-9]+:[0-9]+)", text)
    if m:
        return m.group(1)
    m = re.search(r"live_id=([0-9:]+)", text)
    if m:
        return m.group(1)
    if re.fullmatch(r"[0-9]+:[0-9]+", text):
        return text
    return ""


def resolve(
    live_id: str,
    cookie: Optional[str] = None,
    ua: str = DEFAULT_UA,
    timeout: float = 8.0,
) -> Dict[str, Any]:
    """请求房间接口，返回状态、直链、标题。

    返回 dict: status(int), stream(str), title(str), raw(dict)
    异常时抛出，由调用方决定重试。
    """
    if not live_id:
        raise ValueError("empty live_id")

    url = f"{API}?live_id={urllib.parse.quote(live_id)}"
    headers = {
        "Referer": "https://weibo.com/",
        "User-Agent": ua,
        "Accept": "application/json, text/plain, */*",
    }
    if cookie:
        headers["Cookie"] = cookie

    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)

    room = data.get("data", {}) or {}
    status = room.get("status", 0)
    try:
        status = int(status)
    except (TypeError, ValueError):
        status = 0
    stream = room.get("live_origin_flv_url") or room.get("live_origin_hls_url") or ""
    title = (
        room.get("title")
        or room.get("name")
        or room.get("nickname")
        or room.get("anchor_name")
        or live_id
    )
    return {"status": status, "stream": stream, "title": title, "raw": room}


def is_live(status: int) -> bool:
    return status == STATUS_LIVE


def is_ended(status: int) -> bool:
    return status in STATUS_ENDED
