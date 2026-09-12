// 诊断用：确认 Finder/Dock 会不会取到包内自定义图标。
// macOS 26 的 icon(forFile:) 对任何文件都返回一整套 NSISIconImageRep，比 rep
// 数量没意义；要比渲染出来的像素。判据：
//   与包内 icns 的差值 ≈ 与「无自定义图标的对照组」的差值 → 说明没生效。
import AppKit
import Foundation

func render(_ image: NSImage?, _ side: Int = 256) -> [UInt8]? {
    guard let image, let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]),
          let check = NSBitmapImageRep(data: data) else { return nil }
    guard let pointer = check.bitmapData else { return nil }
    return Array(UnsafeBufferPointer(start: pointer, count: check.bytesPerRow * check.pixelsHigh))
}

/// 两张图的平均像素差（0…255，忽略全透明像素）。
func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    let count = min(a.count, b.count)
    var total = 0.0
    var used = 0
    var index = 0
    while index + 3 < count {
        if a[index + 3] > 8, b[index + 3] > 8 {
            for channel in 0..<3 {
                total += fabs(Double(Int(a[index + channel])) - Double(Int(b[index + channel])))
            }
            used += 1
        }
        index += 4
    }
    return used == 0 ? -1 : total / Double(used * 3)
}

let appPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Applications/dshX.app"
let workspace = NSWorkspace.shared

guard let fromApp = render(workspace.icon(forFile: appPath)) else {
    print("取不到 App 图标")
    exit(2)
}

let icnsPath = appPath + "/Contents/Resources/icon.icns"
if let data = FileManager.default.contents(atPath: icnsPath), let icns = NSImage(data: data),
   let fromIcns = render(icns) {
    print("App 图标 vs 包内 icns 平均像素差：\(String(format: "%.2f", meanDifference(fromApp, fromIcns)))")
} else {
    print("包内没有 icon.icns，无从比对")
}

// 对照组：没有自定义图标的普通文件，用的是系统通用文档图标。
let control = "/etc/hosts"
if let generic = render(workspace.icon(forFile: control)) {
    print("App 图标 vs 通用文档图标平均像素差：\(String(format: "%.2f", meanDifference(fromApp, generic)))")
}