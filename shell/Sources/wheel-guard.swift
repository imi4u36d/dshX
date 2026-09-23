import AppKit
import WebKit

/// 整页横向平移守卫（壳这一侧的硬拦；和注入的 CSS/JS 守卫互补）。
///
/// 现象：带左右滚轮的鼠标横向滚动时，**整个界面**（左侧会话列表一起）被横向拖走，
/// 停在偏移位置；而 DOM 侧量不到任何容器 `scrollLeft` 变了、`window.scrollX` 也一直是 0。
///
/// 成因：这类鼠标/驱动发的是「精确滚动」事件（`hasPreciseScrollingDeltas == true`，
/// 并且带 `.began` / `.changed` 的 phase 序列，方向键抖动、正负反复）。WebKit 把它当成
/// 滚动手势处理，在文档层 / 合成层上直接做横向平移——这条路 CSS 的 `overflow: clip`
/// 挡不住（它不产生滚动条，也不一定发 scroll 事件，所以注入脚本的兜底看不到）。
///
/// 同引擎探针实测（把真实事件参数复刻进 WKWebView）：
///   - 没有注入守卫的页面：一串带 phase 的横向手势之后，
///     `document.scrollingElement.scrollLeft = 69`，整页横移且松手不回弹；
///   - 注入了 `html,body,#root{overflow:clip}` 的页面：`scrollLeft` 一直是 0。
/// 也就是说注入 CSS 能挡，但只要注入没生效（进程里跑的是旧代码、样式被上游覆盖、
/// 或将来上游换了根节点结构），整页横移就会回来。这里换一条与 CSS 无关的路：
/// 在 AppKit 层把「精确横向」分量清零，WebKit 根本收不到横向增量。
///
/// 刻意保留的部分：
///   - 纵向增量与 phase 原样保留 → 纵向平滑滚动 / 惯性不受影响；
///   - 非精确增量（普通滚轮、倾斜滚轮）的横向滚动照旧 → 正文里的代码块、表格
///     仍然可以左右滚（实测这类事件不会把整页拖走）。
///
/// 排查开关：`DSHX_ALLOW_HORIZONTAL_SCROLL=1`（直接运行 app 里的可执行文件时才带得上
/// 环境变量）关掉这条守卫复现原问题。

private let horizontalWheelAllowed =
    ProcessInfo.processInfo.environment["DSHX_ALLOW_HORIZONTAL_SCROLL"] == "1"

enum HorizontalWheelGuard {
    static var isEnabled: Bool { !horizontalWheelAllowed }

    /// 「手势型」精确横向滚动：有精确增量，或带 phase / momentum 相位。
    static func shouldNeutralize(_ event: NSEvent) -> Bool {
        guard isEnabled, event.scrollingDeltaX != 0 else { return false }
        return event.hasPreciseScrollingDeltas
            || !event.phase.isEmpty
            || !event.momentumPhase.isEmpty
    }

    /// 复制事件并把横向增量清零。点增量、定点增量、整数增量三个字段都要清，
    /// WebKit 读哪一个都拿不到横向分量。
    static func neutralized(_ event: NSEvent) -> NSEvent? {
        guard let copy = event.cgEvent?.copy() else { return nil }
        copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        return NSEvent(cgEvent: copy)
    }
}

/// 壳里唯一的 webView 类型：除了把「手势型横向滚动」的横向分量吃掉，不改别的行为。
final class ShellWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        guard HorizontalWheelGuard.shouldNeutralize(event),
              let neutralized = HorizontalWheelGuard.neutralized(event) else {
            super.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: neutralized)
    }

    /// 横向 swipe（触控板/驱动模拟的左右划）也一律不接：这个壳里没有「滑一下翻页」
    /// 的语义（`allowsBackForwardNavigationGestures` 本来就是关的），放过去只会变成
    /// 另一种整页横移的入口。
    override func swipe(with event: NSEvent) {
        guard HorizontalWheelGuard.isEnabled else {
            super.swipe(with: event)
            return
        }
    }
}
