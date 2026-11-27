// 自检辅助：列出指定进程名的窗口，并报告是否在屏与尺寸
// 用法: windowinfo <ownerName>   → 输出 onscreen=N largest=WxH
import AppKit
import CoreGraphics

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "WeiboRecorder"

func dump(_ opts: CGWindowListOption) -> [(CGFloat, CGFloat)] {
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [(CGFloat, CGFloat)] = []
    for w in list {
        let name = (w[kCGWindowOwnerName as String] as? String) ?? ""
        guard name.contains(owner) || name.contains("微博直播录制") else { continue }
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        guard layer == 0 else { continue }
        let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
        let wd = (b["Width"] as? Double) ?? 0
        let ht = (b["Height"] as? Double) ?? 0
        if ht > 200 { out.append((CGFloat(wd), CGFloat(ht))) }
    }
    return out
}

let onscreen = dump([.optionOnScreenOnly, .excludeDesktopElements])
let all = dump([.optionAll])
let largest = all.max { $0.1 < $1.1 } ?? (0, 0)
print("onscreen=\(onscreen.count) total=\(all.count) largest=\(Int(largest.0))x\(Int(largest.1))")
