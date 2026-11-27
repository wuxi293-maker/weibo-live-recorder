// 微博直播录制 · 原生 macOS 应用（AppKit + AVKit）
// 自带窗口，不依赖浏览器、不启动终端；后台以隐藏子进程方式运行本地录制服务。

import Cocoa
import AVKit

// MARK: - 格式化工具

func fmtBytes(_ v: Double) -> String {
    if v <= 0 { return "—" }
    if v < 1024 { return String(format: "%.0f B", v) }
    if v < 1_048_576 { return String(format: "%.1f KB", v / 1024) }
    if v < 1_073_741_824 { return String(format: "%.1f MB", v / 1_048_576) }
    return String(format: "%.2f GB", v / 1_073_741_824)
}

func fmtDur(_ v: Double?) -> String {
    guard let v = v, v > 0 else { return "—" }
    let t = Int(v.rounded())
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}

func fmtHMS(_ v: Double) -> String {
    let t = Int(v)
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}

func pctEncoded(_ s: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=?+#")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// JSON 里的数字可能是 Int / Double / 字符串（ffprobe 时长是字符串），统一取值
func numOf(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

// MARK: - 配色与外观组件

enum Palette {
    static let canvas    = NSColor(srgbRed: 0.949, green: 0.965, blue: 0.988, alpha: 1) // 页面底色 浅蓝白
    static let panel     = NSColor(srgbRed: 0.969, green: 0.980, blue: 0.996, alpha: 1) // 列表面板
    static let surface   = NSColor.white
    static let border    = NSColor(srgbRed: 0.878, green: 0.914, blue: 0.965, alpha: 1)
    static let blue      = NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 1) // 主色
    static let blueDeep  = NSColor(srgbRed: 0.106, green: 0.306, blue: 0.780, alpha: 1)
    static let blueSoft  = NSColor(srgbRed: 0.918, green: 0.945, blue: 1.000, alpha: 1)
    static let blueLine  = NSColor(srgbRed: 0.784, green: 0.855, blue: 0.988, alpha: 1)
    static let yellow    = NSColor(srgbRed: 1.000, green: 0.773, blue: 0.239, alpha: 1) // 辅色
    static let yellowDeep = NSColor(srgbRed: 0.976, green: 0.690, blue: 0.125, alpha: 1)
    static let yellowSoft = NSColor(srgbRed: 1.000, green: 0.976, blue: 0.898, alpha: 1)
    static let red       = NSColor(srgbRed: 0.867, green: 0.267, blue: 0.286, alpha: 1) // 停止/危险
    static let redDeep   = NSColor(srgbRed: 0.741, green: 0.196, blue: 0.216, alpha: 1)
    static let redSoft   = NSColor(srgbRed: 0.996, green: 0.929, blue: 0.929, alpha: 1)
    static let redLine   = NSColor(srgbRed: 0.949, green: 0.776, blue: 0.776, alpha: 1)
    static let redFaint  = NSColor(srgbRed: 0.788, green: 0.529, blue: 0.537, alpha: 1)
    static let navy      = NSColor(srgbRed: 0.055, green: 0.094, blue: 0.188, alpha: 1)
    static let ink       = NSColor(srgbRed: 0.098, green: 0.137, blue: 0.208, alpha: 1)
    static let inkSub    = NSColor(srgbRed: 0.392, green: 0.443, blue: 0.529, alpha: 1)
    static let inkFaint  = NSColor(srgbRed: 0.588, green: 0.639, blue: 0.714, alpha: 1)
    static let inkOnNavy = NSColor(srgbRed: 0.741, green: 0.816, blue: 0.941, alpha: 1)
}

final class Card: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let l = layer else { return }
        l.backgroundColor = Palette.surface.cgColor
        l.cornerRadius = 14
        l.borderWidth = 1
        l.borderColor = Palette.border.cgColor
        l.shadowColor = NSColor(srgbRed: 0.09, green: 0.20, blue: 0.42, alpha: 1).cgColor
        l.shadowOpacity = 0.07
        l.shadowRadius = 12
        l.shadowOffset = CGSize(width: 0, height: -3)
        l.masksToBounds = false
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("不支持") }
}

final class Dot: NSView {
    private let size: CGFloat
    var color: NSColor = Palette.inkFaint { didSet { applyStyle() } }
    var pulsing: Bool = false { didSet { applyStyle() } }

    init(size: CGFloat = 8) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    private func applyStyle() {
        guard let l = layer else { return }
        l.backgroundColor = color.cgColor
        l.cornerRadius = size / 2
        l.removeAnimation(forKey: "pulse")
        if pulsing {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.35
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = .infinity
            l.add(a, forKey: "pulse")
        }
    }
}

/// 状态胶囊：白底描边 / 浅蓝底 / 浅黄底
final class Pill: NSView {
    enum Tone { case neutral, blue, yellow }
    let dot = Dot()
    let label = NSTextField(labelWithString: "")
    var tone: Tone = .neutral { didSet { refreshTone() } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { paint() }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = Palette.ink
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 11, bottom: 5, right: 13)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    private func refreshTone() {
        needsDisplay = true
        paint()
    }

    private func paint() {
        guard let l = layer else { return }
        l.cornerRadius = bounds.height / 2
        l.borderWidth = 1
        switch tone {
        case .neutral:
            l.backgroundColor = Palette.surface.cgColor
            l.borderColor = Palette.border.cgColor
        case .blue:
            l.backgroundColor = Palette.blueSoft.cgColor
            l.borderColor = Palette.blueLine.cgColor
        case .yellow:
            l.backgroundColor = Palette.yellowSoft.cgColor
            l.borderColor = Palette.yellow.cgColor
        }
    }
}

/// 自绘按钮：实心主色 / 描边次要 / 黄色强调
final class Btn: NSButton {
    enum Kind { case primary, secondary, accent, danger }
    private let kind: Kind
    private var hovering = false
    private var tracker: NSTrackingArea?

    private let hHeight: CGFloat
    private let hPad: CGFloat

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]).width
        return NSSize(width: ceil(w) + hPad * 2, height: hHeight)
    }

    init(_ text: String, kind: Kind, target: AnyObject?, action: Selector?,
         height: CGFloat = 30, padding: CGFloat = 22) {
        self.kind = kind
        self.hHeight = height
        self.hPad = padding
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        self.title = text
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    func setEnabledStyle(_ on: Bool) {
        isEnabled = on
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracker = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    private func refresh() {
        guard let l = layer else { return }
        var bg: NSColor
        var fg: NSColor
        var borderWidth: CGFloat = 0
        var borderColor: NSColor = Palette.blueLine
        switch kind {
        case .primary:
            bg = isEnabled ? (hovering ? Palette.blueDeep : Palette.blue) : Palette.blueSoft
            fg = isEnabled ? .white : Palette.inkFaint
        case .accent:
            bg = isEnabled ? (hovering ? Palette.yellowDeep : Palette.yellow) : Palette.yellowSoft
            fg = isEnabled ? Palette.ink : Palette.inkFaint
        case .secondary:
            bg = hovering && isEnabled ? Palette.blueSoft : Palette.surface
            fg = isEnabled ? Palette.blue : Palette.inkFaint
            borderWidth = 1
            borderColor = Palette.blueLine
        case .danger:
            // 录制中可停：红色实心；悬停加深；空闲禁用：浅红底 + 浅红描边
            if isEnabled {
                bg = hovering ? Palette.redDeep : Palette.red
                fg = .white
            } else {
                bg = Palette.redSoft
                fg = Palette.redFaint
            }
        }
        l.backgroundColor = bg.cgColor
        l.cornerRadius = 8
        l.borderWidth = borderWidth
        l.borderColor = borderColor.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
    }
}

final class EditField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

/// 输入框容器：白底 8pt 圆角（与按钮一致）、1pt 描边、文字左对齐且垂直居中；
/// 聚焦时描边由浅蓝渐显为品牌蓝（0.18s 渐隐渐显，不做跳变）
final class FieldBox: NSView {
    let field: NSTextField
    private var focused = false
    private var observers: [NSObjectProtocol] = []

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { paint() }

    init(_ field: NSTextField, placeholder: String = "", width: CGFloat? = nil, inset: CGFloat = 11) {
        self.field = field
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: 13)
        field.textColor = Palette.ink
        field.alignment = .left
        if !placeholder.isEmpty {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: Palette.inkFaint,
                .font: NSFont.systemFont(ofSize: 12.5)
            ])
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        var cons = [
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30)
        ]
        if let w = width { cons.append(widthAnchor.constraint(equalToConstant: w)) }
        NSLayoutConstraint.activate(cons)

        let click = NSClickGestureRecognizer(target: self, action: #selector(focusField))
        addGestureRecognizer(click)

        if let e = field as? EditField {
            e.onFocusChange = { [weak self] on in self?.setFocused(on) }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSControl.textDidBeginEditingNotification,
                                        object: field, queue: .main) { [weak self] _ in
            self?.setFocused(true)
        })
        observers.append(nc.addObserver(forName: NSControl.textDidEndEditingNotification,
                                        object: field, queue: .main) { [weak self] _ in
            self?.setFocused(false)
        })
    }
    required init?(coder: NSCoder) { fatalError("不支持") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    @objc private func focusField() { window?.makeFirstResponder(field) }

    private var targetBorder: NSColor { focused ? Palette.blue : Palette.border }

    private func paint() {
        guard let l = layer else { return }
        l.cornerRadius = 8
        l.borderWidth = focused ? 2 : 1
        l.borderColor = targetBorder.cgColor
        l.backgroundColor = Palette.surface.cgColor
    }

    func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        guard let l = layer else { return }
        let to = targetBorder.cgColor
        let a = CABasicAnimation(keyPath: "borderColor")
        a.fromValue = l.borderColor
        a.toValue = to
        a.duration = 0.18
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.borderColor = to
        l.borderWidth = focused ? 2 : 1
        l.add(a, forKey: "focusFade")
    }
}

// MARK: - 本地服务管理

final class ServerManager {
    let toolDir: URL
    let outDir: URL
    private(set) var process: Process?
    private(set) var base: URL?

    init(toolDir: URL) {
        self.toolDir = toolDir
        self.outDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/WeiboLive")
    }

    // 读取 env.local 中的 export KEY="VALUE"
    private func localEnv() -> [String: String] {
        var out: [String: String] = [:]
        let f = toolDir.appendingPathComponent("env.local")
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return out }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("export ") else { continue }
            let kv = line.dropFirst(7)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let k = String(kv[kv.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !k.isEmpty && !v.isEmpty { out[k] = v }
        }
        return out
    }

    private func probe(port: Int, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/status")!)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, data != nil { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1.0)
        return ok
    }

    private func spawn(port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [
            "-m", "weibo_recorder.server",
            "--port", String(port),
            "--out-dir", outDir.path
        ]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in localEnv() { env[k] = v }
        env["PYTHONPATH"] = toolDir.path
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.currentDirectoryURL = toolDir

        let logURL = AppPaths.logsDir().appendingPathComponent("ui.out.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }
        do {
            try p.run()
        } catch {
            return false
        }
        self.process = p

        // 等待服务就绪
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if probe(port: port, timeout: 1.0) {
                self.base = URL(string: "http://127.0.0.1:\(port)")
                return true
            }
            if !p.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.35)
        }
        return false
    }

    func ensureServer(completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 已有服务在跑则直接复用
            for p in [8765, 8766, 8767] {
                if self.probe(port: p, timeout: 0.8) {
                    self.base = URL(string: "http://127.0.0.1:\(p)")
                    DispatchQueue.main.async { completion(self.base) }
                    return
                }
            }
            for p in [8765, 8766, 8767, 8768] {
                if self.spawn(port: p) {
                    DispatchQueue.main.async { completion(self.base) }
                    return
                }
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    func shutdown() {
        guard let p = process else { return }
        if p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

// MARK: - 网络访问

final class API {
    var base: URL?
    private func url(_ path: String) -> URL? {
        guard let b = base else { return nil }
        return URL(string: b.absoluteString + path)
    }
    func get(_ path: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let u = url(path) else { completion(nil); return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var obj: [String: Any]?
            if let d = data { obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            DispatchQueue.main.async { completion(obj) }
        }.resume()
    }
    func post(_ path: String, _ body: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let u = url(path) else { completion(nil); return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var obj: [String: Any]?
            if let d = data { obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            DispatchQueue.main.async { completion(obj) }
        }.resume()
    }
}

// MARK: - 主控制器

final class MainController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let server: ServerManager
    let api = API()
    var window: NSWindow!

    // 输入
    let urlField = EditField()
    let segField = EditField()
    let maxField = EditField()
    let noAudioBox = NSButton(checkboxWithTitle: "只录画面", target: nil, action: nil)
    var urlBox: FieldBox!
    var segMinusBtn: Btn!
    var segPlusBtn: Btn!
    var maxMinusBtn: Btn!
    var maxPlusBtn: Btn!
    var segBox: FieldBox!
    var maxBox: FieldBox!
    var checkBtn: Btn!
    var startBtn: Btn!
    var stopBtn: Btn!
    var revealBtn: Btn!

    // 状态
    let livePill = Pill()
    let recPill = Pill()
    let svcPill = Pill()
    var segValue: NSTextField!
    var sizeValue: NSTextField!
    var elapsedValue: NSTextField!
    let sessionLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")

    // 成片
    let table = NSTableView()
    let scroll = NSScrollView()
    let playerView = AVPlayerView()
    let previewBox = NSView()
    let placeholder = NSTextField(labelWithString: "选中上方列表中的成片，即可在此预览")
    let placeholderGlyph = NSTextField(labelWithString: "▶")
    let countPill = Pill()
    let fileLabel = NSTextField(labelWithString: "")
    var recordings: [[String: Any]] = []
    var selectedRel: String?
    var programmaticSelection = false
    var isRecording = false
    var timer: Timer?
    var isRefreshing = false
    var stopRequested = false
    var currentPhase = "idle"
    var sleepActivity: NSObjectProtocol?

    init(server: ServerManager) {
        self.server = server
        super.init()
        buildWindow()
        wireActions()
        boot()
    }

    // MARK: 界面搭建

    private func label(_ text: String, size: CGFloat = 13, color: NSColor = .secondaryLabelColor,
                      weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func col(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = spacing
        s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func sectionHeader(_ text: String) -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Palette.blue.cgColor
        bar.layer?.cornerRadius = 1.5
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let title = label(text, size: 13, color: Palette.ink, weight: .semibold)
        return row([bar, title], spacing: 8)
    }

    private func statBlock(_ caption: String) -> (NSView, NSTextField) {
        let cap = label(caption, size: 11, color: Palette.inkFaint)
        let val = label("—", size: 15, color: Palette.blue, weight: .semibold)
        let box = col([cap, val], spacing: 2)
        return (box, val)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "微博直播录制"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 680)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.canvas

        // ---- 顶部品牌区 ----
        let iconView = NSImageView()
        iconView.image = NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let brandTitle = label("微博直播录制", size: 19, color: Palette.ink, weight: .bold)
        let brandSub = label("直链拉流 · 流拷贝录制 · 不录屏不转码", size: 12, color: Palette.inkSub)
        let brandCol = col([brandTitle, brandSub], spacing: 2)

        svcPill.tone = .blue
        svcPill.dot.color = Palette.blue
        svcPill.label.stringValue = "正在启动本地服务…"
        let header = row([iconView, brandCol, NSView(), svcPill], spacing: 12)

        // ---- 卡片一：录制来源 ----
        let inputCard = Card()
        checkBtn = Btn("查询状态", kind: .secondary, target: self, action: #selector(onCheck))
        startBtn = Btn("开始录制", kind: .primary, target: self, action: #selector(onStart))
        stopBtn = Btn("停止并合并", kind: .danger, target: self, action: #selector(onStop))
        stopBtn.setEnabledStyle(false)

        urlBox = FieldBox(urlField,
                          placeholder: "粘贴微博直播页链接")
        urlField.target = self
        urlField.action = #selector(onCheck)

        segField.alignment = .left
        segField.stringValue = "180"
        segBox = FieldBox(segField, width: 64)

        maxField.alignment = .left
        maxField.stringValue = "0"
        maxBox = FieldBox(maxField, width: 64)

        noAudioBox.translatesAutoresizingMaskIntoConstraints = false
        noAudioBox.font = .systemFont(ofSize: 12.5)
        noAudioBox.contentTintColor = Palette.blue

        let r1 = row([urlBox], spacing: 10)
        urlBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        segMinusBtn = Btn("−", kind: .secondary, target: self, action: #selector(onStep), height: 30, padding: 8)
        segPlusBtn = Btn("+", kind: .secondary, target: self, action: #selector(onStep), height: 30, padding: 8)
        maxMinusBtn = Btn("−", kind: .secondary, target: self, action: #selector(onStep), height: 30, padding: 8)
        maxPlusBtn = Btn("+", kind: .secondary, target: self, action: #selector(onStep), height: 30, padding: 8)
        segMinusBtn.tag = 1
        segPlusBtn.tag = 2
        maxMinusBtn.tag = 3
        maxPlusBtn.tag = 4

        maxField.toolTip = "填 0 表示一直录到直播结束"

        let segGroup = row([label("分段秒数", size: 12, color: Palette.inkSub), segBox,
                            segMinusBtn, segPlusBtn], spacing: 6)
        let maxGroup = row([label("最长秒数", size: 12, color: Palette.inkSub), maxBox,
                            maxMinusBtn, maxPlusBtn], spacing: 6)
        let r2 = row([segGroup, maxGroup,
                      label("0 = 录到结束", size: 11.5, color: Palette.inkFaint),
                      NSView(), noAudioBox], spacing: 12)

        for b in [checkBtn!, startBtn!, stopBtn!] {
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let r3 = row([NSView(), checkBtn, startBtn, stopBtn], spacing: 10)

        let inputStack = col([sectionHeader("录制来源"), r1, r2, r3], spacing: 12)
        inputCard.addSubview(inputStack)
        NSLayoutConstraint.activate([
            inputStack.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor, constant: 18),
            inputStack.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor, constant: -18),
            inputStack.topAnchor.constraint(equalTo: inputCard.topAnchor, constant: 16),
            inputStack.bottomAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: -16),
            r1.widthAnchor.constraint(equalTo: inputStack.widthAnchor),
            r2.widthAnchor.constraint(equalTo: inputStack.widthAnchor),
            r3.widthAnchor.constraint(equalTo: inputStack.widthAnchor)
        ])

        // ---- 卡片二：运行状态 ----
        let statusCard = Card()
        livePill.label.stringValue = "未输入链接"
        recPill.label.stringValue = "空闲"

        let (segBox1, segVal) = statBlock("分段数")
        segValue = segVal
        segValue.stringValue = "0"
        let (sizeBox1, sizeVal) = statBlock("最新分段")
        sizeValue = sizeVal
        sizeValue.stringValue = "—"
        let (elapsedBox1, elapsedVal) = statBlock("已录时长")
        elapsedValue = elapsedVal
        elapsedValue.stringValue = "00:00"

        sessionLabel.font = .systemFont(ofSize: 11)
        sessionLabel.textColor = Palette.inkFaint
        sessionLabel.lineBreakMode = .byTruncatingMiddle
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = Palette.inkSub
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let statsRow = row([segBox1, sizeBox1, elapsedBox1], spacing: 26)
        let badgesRow = row([livePill, recPill, NSView(), statsRow], spacing: 14)
        let statusStack = col([sectionHeader("运行状态"), badgesRow, sessionLabel, hintLabel], spacing: 10)
        statusCard.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 18),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -18),
            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 16),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -16),
            badgesRow.widthAnchor.constraint(equalTo: statusStack.widthAnchor),
            sessionLabel.widthAnchor.constraint(equalTo: statusStack.widthAnchor)
        ])

        // ---- 卡片三：成片列表（左）----
        let recCard = Card()
        revealBtn = Btn("在 Finder 中显示", kind: .secondary, target: self, action: #selector(onReveal), height: 28)
        revealBtn.setEnabledStyle(false)
        countPill.tone = .yellow
        countPill.dot.isHidden = true
        countPill.label.stringValue = "0 条成片"
        let recHead = row([sectionHeader("成片列表"), countPill, NSView(), revealBtn], spacing: 10)

        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Palette.panel
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.style = .plain
        addColumns()

        table.autoresizingMask = [.width]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.panel
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Palette.border.cgColor
        scroll.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let recStack = col([recHead, scroll], spacing: 12)
        recCard.addSubview(recStack)
        NSLayoutConstraint.activate([
            recStack.leadingAnchor.constraint(equalTo: recCard.leadingAnchor, constant: 18),
            recStack.trailingAnchor.constraint(equalTo: recCard.trailingAnchor, constant: -18),
            recStack.topAnchor.constraint(equalTo: recCard.topAnchor, constant: 16),
            recStack.bottomAnchor.constraint(equalTo: recCard.bottomAnchor, constant: -16),
            recHead.widthAnchor.constraint(equalTo: recStack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: recStack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])

        // ---- 卡片四：预览（右）----
        let previewCard = Card()

        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFrameSteppingButtons = false
        playerView.translatesAutoresizingMaskIntoConstraints = false

        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = Palette.navy.cgColor
        previewBox.layer?.cornerRadius = 10
        previewBox.layer?.borderWidth = 1
        previewBox.layer?.borderColor = Palette.blueLine.withAlphaComponent(0.5).cgColor
        previewBox.layer?.masksToBounds = true
        previewBox.addSubview(playerView)

        placeholderGlyph.font = .systemFont(ofSize: 26, weight: .semibold)
        placeholderGlyph.textColor = Palette.inkOnNavy.withAlphaComponent(0.85)
        placeholderGlyph.alignment = .center
        placeholderGlyph.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(placeholderGlyph)

        placeholder.stringValue = "选中左侧列表中的成片，即可在此预览"
        placeholder.font = .systemFont(ofSize: 12.5)
        placeholder.textColor = Palette.inkOnNavy
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(placeholder)

        fileLabel.font = .systemFont(ofSize: 11.5)
        fileLabel.textColor = Palette.inkFaint
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.stringValue = "未选择成片"
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: previewBox.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            placeholderGlyph.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            placeholderGlyph.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor, constant: -12),
            placeholder.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: placeholderGlyph.bottomAnchor, constant: 6)
        ])

        let previewStack = col([sectionHeader("预览"), previewBox, fileLabel], spacing: 12)
        previewCard.addSubview(previewStack)
        NSLayoutConstraint.activate([
            previewStack.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 16),
            previewStack.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -16),
            previewStack.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 16),
            previewStack.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -16),
            previewBox.widthAnchor.constraint(equalTo: previewStack.widthAnchor),
            previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            fileLabel.widthAnchor.constraint(equalTo: previewStack.widthAnchor)
        ])

        // ---- 总装：左侧内容 + 右侧预览 ----
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.canvas.cgColor
        for v in [header, inputCard, statusCard, recCard, previewCard] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        window.contentView = content
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),

            inputCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            inputCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            inputCard.widthAnchor.constraint(equalToConstant: 600),
            inputCard.trailingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: -16),

            statusCard.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor),
            statusCard.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor),
            statusCard.topAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: 16),

            recCard.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor),
            recCard.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor),
            recCard.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 16),
            recCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),

            previewCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            previewCard.topAnchor.constraint(equalTo: inputCard.topAnchor),
            previewCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            previewCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 340)
        ])
        window.minSize = NSSize(width: 1000, height: 700)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.center()
    }

    private func addColumns() {
        let cols: [(String, String, CGFloat, Bool)] = [
            ("name", "成片", 300, true),
            ("dur", "时长", 76, false),
            ("size", "大小", 92, false),
            ("time", "时间", 104, false)
        ]
        for (id, title, w, flex) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = w
            if flex {
                c.minWidth = 160
                c.resizingMask = .autoresizingMask
            } else {
                c.minWidth = w
                c.resizingMask = []
            }
            let hc = NSTableHeaderCell()
            hc.font = .systemFont(ofSize: 11.5, weight: .semibold)
            hc.textColor = Palette.inkSub
            hc.alignment = .left
            let ps = NSMutableParagraphStyle()
            ps.firstLineHeadIndent = 5
            ps.headIndent = 5
            hc.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: Palette.inkSub,
                .paragraphStyle: ps
            ])
            c.headerCell = hc
            table.addTableColumn(c)
        }
    }

    private func wireActions() {
        noAudioBox.target = self
        noAudioBox.action = #selector(onNoAudioToggle)
    }

    private func boot() {
        hintLabel.stringValue = "正在启动本地服务…"
        server.ensureServer { [weak self] base in
            guard let self = self else { return }
            guard let base = base else {
                self.hintLabel.stringValue = "本地服务启动失败，请查看 ~/Library/Logs/WeiboLiveRecorder/ui.out.log"
                self.svcPill.tone = .neutral
                self.svcPill.dot.color = Palette.inkSub
                self.svcPill.label.stringValue = "服务未启动"
                self.startBtn.setEnabledStyle(false)
                return
            }
            self.api.base = base
            self.hintLabel.stringValue = ""
            self.svcPill.tone = .blue
            self.svcPill.dot.color = Palette.blue
            self.svcPill.label.stringValue = "服务已就绪 · 127.0.0.1:\(base.port ?? 8765)"
            self.startBtn.setEnabledStyle(true)
            self.refresh()
            self.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func show() {
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 状态刷新

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        api.get("/api/status") { [weak self] obj in
            guard let self = self else { return }
            self.isRefreshing = false
            guard let obj = obj else { return }
            self.apply(obj)
        }
    }

    /// 录制期间持有防睡眠断言：屏幕熄灭后系统不会进入睡眠，3 小时无人值守也不会断流
    func syncSleepAssertion(_ recording: Bool) {
        if recording, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "微博直播录制进行中，禁止系统睡眠")
        } else if !recording, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
    }

    /// 退出/关窗时同步写停止标记：录制进程 0.5s 内收尾当前分段，再在后台合并
    func stopRecordingSync(timeout: TimeInterval = 3) {
        guard isRecording, let base = api.base else { return }
        var req = URLRequest(url: URL(string: base.absoluteString + "/api/stop")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout)
        isRecording = false
        syncSleepAssertion(false)
    }

    private func apply(_ obj: [String: Any]) {
        // 直播
        if let live = obj["live"] as? [String: Any] {
            let st = live["status"] as? Int ?? -1
            var text = live["label"] as? String ?? "未知"
            if let title = live["title"] as? String, !title.isEmpty { text += " · " + title }
            livePill.label.stringValue = text
            switch st {
            case 1:
                livePill.tone = .blue
                livePill.dot.color = Palette.blue
                livePill.dot.pulsing = true
            case 0:
                livePill.tone = .neutral
                livePill.dot.color = Palette.inkFaint
                livePill.dot.pulsing = false
            case 2, 3:
                livePill.tone = .neutral
                livePill.dot.color = Palette.inkSub
                livePill.dot.pulsing = false
            default:
                livePill.tone = .neutral
                livePill.dot.color = Palette.inkFaint
                livePill.dot.pulsing = false
            }
        }
        // 录制
        if let rec = obj["recording"] as? [String: Any] {
            isRecording = rec["running"] as? Bool ?? false
            let phase = rec["phase"] as? String ?? (isRecording ? "recording" : "idle")
            currentPhase = phase
            let merging = phase == "merging"
            let starting = phase == "starting"
            recPill.label.stringValue = merging ? "正在合并" : (starting ? "启动中" : (isRecording ? "录制中" : "空闲"))
            recPill.tone = isRecording ? .yellow : .neutral
            recPill.dot.color = isRecording ? (merging ? Palette.blue : Palette.yellowDeep) : Palette.inkFaint
            recPill.dot.pulsing = isRecording
            syncSleepAssertion(isRecording)

            let segs = rec["segments"] as? Int ?? 0
            segValue.stringValue = "\(segs)"
            sizeValue.stringValue = segs > 0 ? fmtBytes(numOf(rec["latest_size"]) ?? 0) : "—"
            elapsedValue.stringValue = fmtHMS(numOf(rec["elapsed"]) ?? 0)

            let session = (rec["session_dir"] as? String) ?? ""
            sessionLabel.stringValue = session.isEmpty ? "" : "会话目录  " + session
            sessionLabel.isHidden = session.isEmpty

            startBtn.setEnabledStyle(!isRecording && api.base != nil)
            stopBtn.setEnabledStyle(isRecording && !merging)
            if merging {
                hintLabel.stringValue = "正在合并分段，完成后自动出现在成片列表"
            } else if !isRecording {
                let free = numOf(rec["disk_free"]) ?? -1
                if free >= 0, free < 10 * 1024 * 1024 * 1024 {
                    hintLabel.stringValue = "磁盘剩余 " + fmtBytes(free) + "，不足 10GB，建议先清理"
                }
            }
        }
        // 成片
        recordings = (obj["recordings"] as? [[String: Any]]) ?? []
        countPill.label.stringValue = "\(recordings.count) 条成片"
        table.reloadData()
        if let rel = selectedRel, !recordings.contains(where: { ($0["rel"] as? String) == rel }) {
            clearPreview()
        }
        // 有历史成片但尚未选中时，自动选中最新一条并显示首帧（不自动播放）
        if selectedRel == nil, recordings.count > 0 {
            programmaticSelection = true
            selectedRel = recordings[0]["rel"] as? String
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            programmaticSelection = false
            loadPreview(autoplay: false)
        }
        revealBtn.setEnabledStyle(selectedRel != nil)
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { recordings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < recordings.count, let colID = tableColumn?.identifier.rawValue else { return nil }
        let item = recordings[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTextField
        if let reuse = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reuse
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = .systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
        }
        switch colID {
        case "name":
            cell.stringValue = item["name"] as? String ?? "—"
            cell.textColor = Palette.ink
            cell.font = .systemFont(ofSize: 12, weight: .medium)
        case "dur":
            cell.stringValue = fmtDur(numOf(item["duration"]))
            cell.textColor = Palette.blue
            cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        case "size":
            cell.stringValue = fmtBytes(numOf(item["size"]) ?? 0)
            cell.textColor = Palette.inkSub
            cell.font = .systemFont(ofSize: 12)
        case "time":
            cell.stringValue = item["mtime_str"] as? String ?? "—"
            cell.textColor = Palette.inkFaint
            cell.font = .systemFont(ofSize: 12)
        default:
            cell.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard r >= 0, r < recordings.count else { return }
        selectedRel = recordings[r]["rel"] as? String
        revealBtn.setEnabledStyle(selectedRel != nil)
        loadPreview(autoplay: !programmaticSelection)
    }

    private func loadPreview(autoplay: Bool = true) {
        guard let rel = selectedRel, let base = api.base else { return }
        guard let u = URL(string: base.absoluteString + "/media?path=" + pctEncoded(rel)) else { return }
        placeholder.isHidden = true
        placeholderGlyph.isHidden = true
        let name = recordings.first(where: { ($0["rel"] as? String) == rel })?["name"] as? String
        fileLabel.stringValue = name ?? (rel as NSString).lastPathComponent
        let item = AVPlayerItem(url: u)
        if let p = playerView.player {
            p.replaceCurrentItem(with: item)
            p.seek(to: .zero)
        } else {
            let p = AVPlayer(playerItem: item)
            playerView.player = p
            p.seek(to: .zero)
        }
        if autoplay { playerView.player?.play() } else { playerView.player?.pause() }
    }

    private func clearPreview() {
        playerView.player?.pause()
        playerView.player = nil
        placeholder.isHidden = false
        placeholderGlyph.isHidden = false
        fileLabel.stringValue = "未选择成片"
        selectedRel = nil
        revealBtn.setEnabledStyle(false)
    }

    // MARK: 动作

    @objc func onCheck() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        hintLabel.stringValue = "正在查询直播状态…"
        api.post("/api/check", ["url": url]) { [weak self] res in
            guard let self = self else { return }
            if let err = res?["error"] as? String {
                self.hintLabel.stringValue = "查询失败：" + err
            } else {
                self.hintLabel.stringValue = "状态已更新"
            }
            self.refresh()
        }
    }

    @objc func onStart() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            let a = NSAlert()
            a.messageText = "请先粘贴直播链接"
            a.addButton(withTitle: "好")
            a.runModal()
            return
        }
        let seg = Int(segField.stringValue) ?? 180
        let maxs = Int(maxField.stringValue) ?? 0
        startBtn.setEnabledStyle(false)
        hintLabel.stringValue = "正在启动录制…"
        api.post("/api/start", [
            "url": url,
            "segment_seconds": seg,
            "max_seconds": maxs,
            "no_audio": noAudioBox.state == .on
        ]) { [weak self] res in
            guard let self = self else { return }
            if let ok = res?["ok"] as? Bool, ok {
                self.hintLabel.stringValue = "录制已启动"
            } else {
                self.hintLabel.stringValue = "启动失败：" + (res?["error"] as? String ?? "未知错误")
                self.startBtn.isEnabled = true
            }
            self.refresh()
        }
    }

    @objc func onStop() {
        hintLabel.stringValue = "正在停止，等待当前分段结束并合并…"
        api.post("/api/stop", [:]) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 分段/最长秒数的 +/- 步进：每次 30 秒
    @objc func onStep(_ sender: NSButton) {
        let delta = (sender.tag == 1 || sender.tag == 3) ? -30 : 30
        switch sender.tag {
        case 1, 2:
            let cur = Int(segField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 180
            segField.stringValue = "\(max(30, cur + delta))"
        default:
            let cur = Int(maxField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            maxField.stringValue = "\(max(0, cur + delta))"
        }
    }

    @objc func onNoAudioToggle() {
        // 仅作为下次开始录制的参数，无需即时请求
    }

    @objc func onReveal() {
        guard let rel = selectedRel else { return }
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/WeiboLive")
        let full = root.appendingPathComponent(rel)
        NSWorkspace.shared.selectFile(full.path, inFileViewerRootedAtPath: root.path)
    }

    // MARK: 关闭与退出保护

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isRecording else { return true }
        let a = NSAlert()
        a.messageText = "正在录制"
        a.informativeText = "关闭窗口会停止拉流，并在后台合并当前分段（通常 1 分钟内完成）。是否继续？"
        a.addButton(withTitle: "继续录制")
        a.addButton(withTitle: "停止并关闭")
        if a.runModal() == .alertFirstButtonReturn { return false }
        stopRequested = true
        stopRecordingSync()
        return true
    }

    func confirmQuit() -> Bool {
        if stopRequested { return true }
        guard isRecording else { return true }
        let a = NSAlert()
        a.messageText = "正在录制"
        a.informativeText = "退出会立即停止拉流，并在后台合并当前分段（通常 1 分钟内完成，成片下次打开可见）。是否继续退出？"
        a.addButton(withTitle: "继续录制")
        a.addButton(withTitle: "停止并退出")
        return a.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainController?
    let server = ServerManager(toolDir: AppPaths.toolDir())
    private var signalSources: [DispatchSourceSignal] = []

    /// 被 kill / 系统注销等场景结束时，也要回收后台服务，避免留下孤儿进程
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.server.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        installSignalHandlers()
        buildMenu()
        controller = MainController(server: server)
        controller?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = controller else { return .terminateNow }
        if !c.confirmQuit() { return .terminateCancel }
        c.stopRecordingSync()
        c.timer?.invalidate()
        server.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.syncSleepAssertion(false)
        server.shutdown()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 微博直播录制",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 微博直播录制",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 微博直播录制",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

enum AppPaths {
    /// 工具目录：优先用应用内置的 Resources/tool（自包含安装包），其次 Info.plist 的 WLRToolDir
    static func toolDir() -> URL {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("tool")
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("weibo_recorder").path) {
                return bundled
            }
        }
        if let s = Bundle.main.object(forInfoDictionaryKey: "WLRToolDir") as? String, !s.isEmpty {
            let u = URL(fileURLWithPath: s)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("weibo_recorder").path) {
                return u
            }
        }
        // 兜底：应用包同级../ ../
        let b = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return b
    }

    /// 日志目录：~/Library/Logs/WeiboLiveRecorder（应用装在只读位置也能写）
    static func logsDir() -> URL {
        let u = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/WeiboLiveRecorder")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
