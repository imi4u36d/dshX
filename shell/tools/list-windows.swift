// 诊断用：把当前屏上窗口连同宿主进程名、尺寸一起列出来。
// 坑：开了台前调度（Stage Manager）时，这里量到的是左侧缩略图的几何（126x143
// 这种），不是真实窗口尺寸；判断尺寸前先确认台前调度是关的，或者和
// 「Window Server / Dock」这类已知尺寸对照一下。
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("取不到窗口列表")
    exit(2)
}
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
for window in info {
    guard let owner = window[kCGWindowOwnerName as String] as? String else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? CGFloat ?? 0
    let height = bounds["Height"] as? CGFloat ?? 0
    let title = window[kCGWindowName as String] as? String ?? ""
    let number = window[kCGWindowNumber as String] as? Int ?? -1
    if !filter.isEmpty, owner != filter { continue }
    print(String(format: "#%d %-22@ %5dx%-5d %@", number, owner as NSString, Int(width), Int(height),
                 title.isEmpty ? "(无标题)" : title))
}