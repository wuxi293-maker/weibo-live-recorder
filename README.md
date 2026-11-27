# 微博直播本地录制工具（macOS）

直链拉流 + 流拷贝（`-c copy`）的低占用录制工具：不录屏、不转码、不抓声卡，后台拉微博直播流并分段落盘，结束后自动合并 mp4 并抽出独立 m4a。

连续性：录制时只起 **一个** ffmpeg 进程，用 segment muxer 连续切片，切点之间没有空档；只有断流 / 直链过期时才重新解析续录。3 小时实测（本地实时 FLV 源）录制 60.0s、分段合计 60.023s，成片与分段总时长差 0.000s。

## 适用与边界

- **适用**：本人可正常观看的公开微博直播；流为 H.264 + AAC。
- **不适用 / 需兜底**：AES 加密 / DRM 流、需特殊鉴权的付费流；视频号、抖音未在本版本适配。
- 本工具只录制你本人账号可观看的内容，留存自用，遵守平台条款。

## 一、安装依赖（macOS）

```bash
# 1. ffmpeg / ffprobe
brew install ffmpeg

# 2. Python 3 与编译工具链（原生窗口需要 swiftc）
xcode-select --install
python3 --version
```

本机已有 arm64 原生 ffmpeg 时，可不装 brew，改为在工具目录的 `env.local` 里指定绝对路径：

```bash
export FFMPEG_BIN="/path/to/ffmpeg"
export FFPROBE_BIN="/path/to/ffprobe"
```

应用启动时会自动读取 `env.local` 并传给后台服务，无需写入 shell 配置。

无需授予「屏幕录制」「麦克风」权限——工具不拉屏幕、不抓系统声卡。

## 二、目录结构

```
weibo-live-recorder/
├── bin/
│   ├── weibo-recorder        # 命令行录制入口
│   ├── weibo-recorder-ui     # 仅调试用：起本地服务并打开浏览器（日常请用桌面应用）
│   └── install_shortcut.sh   # 一键构建原生应用 + 创建桌面入口
├── weibo_recorder/
│   ├── resolve.py            # 房间状态 / 直链解析
│   ├── recorder.py           # 录制循环、分段、合并、校验
│   ├── server.py             # 本地服务（状态 / 启停 / 成片媒体流）
│   ├── ffmpeg_tools.py       # ffmpeg/ffprobe 探测与校验
│   └── web/index.html        # 调试用网页界面
├── macos/
│   ├── native/main.swift     # 原生窗口源码（AppKit + AVKit）
│   ├── assets/AppIcon.png    # 应用图标源图
│   └── build_app.sh          # 从源码构建 .app
├── launchd/
│   └── com.doubao.weibo.live.recorder.plist.template
├── config.example.env
└── tests/
    ├── selftest.sh           # 录制/合并/服务链路自检
    └── app_selftest.sh       # 原生应用自检
```

成片默认输出到 `~/Movies/WeiboLive/YYYYMMDD_<标题>/v1/`：

```
v1/
├── video/<标题>_v1.mp4      # 画面 + 原声
├── audio/<标题>_v1.m4a      # 独立音频
├── segments/seg_001.ts ...   # 原始分段（合并前保留）
├── logs/recorder_*.log
├── logs/report.json         # 时长 / 编码 / 分辨率 / 电平报告
└── heartbeat.txt            # 录制心跳（供外部看护探测）
```

## 三、命令行使用

```bash
cd /path/to/weibo-live-recorder

# 按直播页链接录制（直到直播结束）
./bin/weibo-recorder --url "https://weibo.com/l/wblive/p/show/1022:xxxxxxxx"

# 或直接给 live_id
./bin/weibo-recorder --id "1022:xxxxxxxx"

# 限时录制 3 小时；分段每 3 分钟；只录画面
./bin/weibo-recorder --url "<链接>" --max-seconds 10800 --segment-seconds 180 --no-audio

# 指定截止时间（本机时区）
./bin/weibo-recorder --url "<链接>" --end "2026-11-26 21:00:00"

# 受限直播：携带本人登录 Cookie
WEIBO_COOKIE="SINAGLOBAL=..." ./bin/weibo-recorder --url "<链接>"
```

### 主要参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--url` / `--id` | 必填 | 直播页链接或裸 live_id（二选一） |
| `--out-dir` | `~/Movies/WeiboLive` | 成片根目录 |
| `--segment-seconds` | 180 | 单段 TS 时长（秒）；只影响落盘粒度，不影响连续性，调大不影响漏录 |
| `--max-seconds` | 0 | 最长录制秒数，0 为直到结束 |
| `--end` | 无 | 截止时间 `YYYY-MM-DD HH:MM:SS` |
| `--no-audio` | 关 | 只录画面，不拷音频轨 |
| `--cookie` | 环境变量 `WEIBO_COOKIE` | 本人登录态 Cookie |
| `--version` | v1 | 版本号，同主题递增保留各版本 |
| `--poll-interval` | 15 | 未开播/断链重试间隔（秒） |

## 四、桌面应用（推荐）

独立的原生 macOS 窗口（AppKit 构建），**不弹终端、不打开浏览器**，退出应用即回收后台服务。

**安装（一次即可）：**

```bash
cd /path/to/weibo-live-recorder
bash bin/install_shortcut.sh
```

脚本会做三件事：编译原生应用到 `~/Applications/微博直播录制.app`、生成桌面入口「微博直播录制.app」、清理旧的 `.command` 启动方式。

**启动方式：**

- 双击桌面「微博直播录制」；
- 或在启动台 / `~/Applications` 打开；
- 应用已在运行时再点 Dock 图标，会把窗口重新唤到前台。

窗口功能：

- **链接输入**：粘贴微博直播页链接，可设分段秒数、最长秒数、只录画面；回车或点「查询状态」立即解析；
- **直播状态**：徽标显示 未开播 / 直播中（绿点呼吸）/ 已结束（红点）与直播间标题；
- **录制状态**：录制中/空闲、分段数、最新分段大小、已录时长、会话目录，每 2 秒刷新；
- **成片预览**：表格列出历史成片（时长/大小/时间），点击行即在下方播放器内预览；有历史成片时默认选中最新一条并显示首帧。

后台机制：应用启动时以隐藏子进程方式运行本地服务（`127.0.0.1:8765`，仅本机可访问），前端通过 `WLR_PORT` 可改端口。

稳定性：

- 录制中应用持有 `PreventUserIdleSystemSleep` 断言，屏幕熄灭后系统不会睡眠，3 小时无人值守不会断流；停止录制后自动释放。
- 录制中关窗或退出会先弹确认；选择停止会同步写入停止标记，录制进程约 0.5s 内收尾当前分段，再在后台合并（成片下次打开可见）。
- 开始录制前检查剩余空间（低于 6GB 拒绝）；同一天同一房间再次录制自动顺延到 `v2`/`v3`，不会把旧分段混进新片。
- 音频映射用 `0:a:0?`，直播没有音轨时仍可正常录制（成片无音轨）。

**仅调试需要浏览器时**：`./bin/weibo-recorder-ui` 仍保留，会起服务并打开网页版界面。

## 五、launchd 后台常驻（崩溃自动拉起）

1. 复制模板并替换占位符：`__TOOL_DIR__`、`__URL__`、`__OUT_DIR__`、`__LOG_DIR__`、`__WEIBO_COOKIE__`。
2. 安装：

```bash
cp launchd/com.doubao.weibo.live.recorder.plist.template \
   ~/Library/LaunchAgents/com.doubao.weibo.live.recorder.plist
launchctl load ~/Library/LaunchAgents/com.doubao.weibo.live.recorder.plist
```

- `KeepAlive` 配置为仅异常退出时重启；录制正常结束（退出码 0）不会重复拉起。
- 卸载：`launchctl unload ~/Library/LaunchAgents/com.doubao.weibo.live.recorder.plist`。

## 六、低占用说明

- ffmpeg 只做解封装 + 写文件，视频/音频原样拷贝，不重编码；CPU 个位数百分比，内存几十 MB。
- 磁盘写入 ≈ 源流码率（约 1.7Mbps，3 小时约 2.3GB）；网络单路下行。
- 不开启本地预览渲染，不采集屏幕，不挂音频 Tap。

## 七、自检

```bash
bash tests/selftest.sh      # 录制 / 合并 / 服务链路
bash tests/app_selftest.sh  # 原生应用（窗口、启动方式、退出回收）
```

- `selftest.sh` 覆盖：Python 语法、shell 入口语法、plist 合法性、解析器连通性、合成分段的合并 / 双轨校验 / 抽 m4a、服务接口、直播状态查询、越界拦截。
- `app_selftest.sh` 覆盖：应用包结构与 Info.plist、二进制架构（arm64）、图标、Swift 源码类型检查、启动后窗口在屏、服务监听、**启动过程不拉起终端**、优雅退出后服务回收与端口释放、桌面入口存在。

## 八、故障排查

| 现象 | 处理 |
|---|---|
| 找不到 ffmpeg | `brew install ffmpeg`，或用 `--ffmpeg/--ffprobe` 指定路径 |
| 一直「未开播或暂无直链」 | 确认直播已开始；受限流检查 Cookie 是否有效 |
| 分段过小被丢弃 | 多为流地址失效或鉴权失败，查 `logs/recorder_*.log` |
| 合并报编码不兼容 | 源流可能非 H.264/AAC，需先 `ffprobe` 查编码 |
| 中途机器睡眠/断网 | 系统设置关闭睡眠；网络恢复后脚本会重新解析续录 |
| 双击应用被 Gatekeeper 拦截 | 在应用上右键「打开」一次；或执行 `xattr -dr com.apple.quarantine ~/Applications/微博直播录制.app` |
| 编译应用报找不到 swiftc | 安装 Xcode Command Line Tools：`xcode-select --install` |
| 移动了工具目录后应用打不开 | 重新执行 `bash bin/install_shortcut.sh`（会重写 Info.plist 里的工具目录） |
| 界面显示「本地服务启动失败」 | 查看 `logs/ui.out.log`；确认 `/usr/bin/python3` 可用、8765 端口未被占用 |
