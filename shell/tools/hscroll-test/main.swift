import AppKit
import WebKit

/*
 dshX 壳「整页横向平移」守卫（Sources/wheel-guard.swift）的回归测试。不是 App 的一部分。

 背景：带左右滚轮的鼠标发出的是「精确滚动 + phase」事件，WebKit 会拿它做整页横向平移。
 这个测试把同一类事件直接送进两个 WKWebView，断言：

   1. 裸 WKWebView：文档被横向滚走（> 0）——测试前提成立，事件真的能复现问题
   2. ShellWebView：文档 scrollLeft 保持 0（横向分量被清零，WebKit 收不到）
   3. ShellWebView：纵向精确滚动照旧（没误伤纵向平滑滚动）
   4. 判定函数的边界：精确横向=拦；非精确横向=放；精确纵向=放

 用法（仓库根目录）：

   bash shell/tools/hscroll-test/run.sh

 退出码 0 = 全部通过。
*/

// MARK: - 造事件

func wheelEvent(dx: Double, dy: Double, precise: Bool, phase: Int64) -> NSEvent? {
    let units: CGScrollEventUnit = precise ? .pixel : .line
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units,
                           wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
        return nil
    }
    if precise {
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    }
    if phase != 0 {
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    }
    return NSEvent(cgEvent: cg)
}

/// 直接投给目标 view 的 `scrollWheel(with:)`。
///
/// 这里不用 `NSWindow.sendEvent` 走 hit test：这种「附属进程 + 离屏窗口」的跑法下，
/// 合成事件的窗口派发不稳定（裸 WKWebView 的对照项也会失败），会让测试本身失去意义。
/// ShellWebView 的 override 在真实事件路径上是否真的被调到，已经用另一个探针验证过：
/// 真实鼠标滚轮事件会进到 WKWebView 子类的 `scrollWheel(with:)`（一次滚动收到
/// 1000+ 条事件）。
func post(_ event: NSEvent, to window: NSWindow, view: WKWebView) {
    guard let cg = event.cgEvent else { return }
    let point = window.convertPoint(toScreen: NSPoint(x: view.bounds.midX,
                                                      y: view.bounds.midY))
    cg.location = point
    if let relocated = NSEvent(cgEvent: cg) {
        view.scrollWheel(with: relocated)
    }
}

/// 一串「手势型」横向滚动：began → changed×n → ended，跟真实鼠标驱动发出的序列一致。
func sendHorizontalGesture(to window: NSWindow, view: WKWebView, dx: Int32, count: Int) {
    for i in 0..<count {
        let phase: Int64 = i == 0 ? 1 : (i == count - 1 ? 3 : 2)
        guard let event = wheelEvent(dx: Double(dx), dy: 0, precise: true, phase: phase) else { continue }
        post(event, to: window, view: view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

/// 一串「手势型」纵向滚动，用来确认守卫没误伤纵向。
func sendVerticalGesture(to window: NSWindow, view: WKWebView, dy: Int32, count: Int) {
    for i in 0..<count {
        let phase: Int64 = i == 0 ? 1 : (i == count - 1 ? 3 : 2)
        guard let event = wheelEvent(dx: 0, dy: Double(dy), precise: true, phase: phase) else { continue }
        post(event, to: window, view: view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

// MARK: - 页面：文档层横向可滚（复刻「没有注入守卫时」的局面）+ 一个纵向滚动区

let page = """
<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;height:100%}
  #root{height:100%}
  .frame{height:100%;overflow:hidden;position:relative}
  .center{height:100%;overflow-y:auto;overflow-x:auto}
  .tall{height:3000px;width:600px;background:linear-gradient(#fff,#ccd)}
  /* 页面级横向溢出：文档层因此可以横向滚动（正是壳要挡的那种局面） */
  #bleed{position:absolute;left:0;top:0;width:1800px;height:2200px;background:#333}
</style>
<div id="root">
  <div class="frame">
    <div class="center" id="center"><div class="tall">正文</div></div>
  </div>
</div>
<div id="bleed"></div>
"""

let measureJS = """
JSON.stringify({
  docLeft: (document.scrollingElement || document.documentElement).scrollLeft,
  docTop: (document.scrollingElement || document.documentElement).scrollTop,
  docScrollWidth: (document.scrollingElement || document.documentElement).scrollWidth,
  docClientWidth: (document.scrollingElement || document.documentElement).clientWidth,
  centerTop: document.getElementById('center').scrollTop
})
"""

// MARK: - 跑

final class ScrollTest: NSObject, WKNavigationDelegate {
    var plain: WKWebView!
    var guarded: ShellWebView!
    var plainWindow: NSWindow!
    var guardedWindow: NSWindow!
    var failures: [String] = []
    var ready = 0

    func start() {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        plain = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        guarded = ShellWebView(frame: frame, configuration: WKWebViewConfiguration())
        for view in [plain as WKWebView, guarded as WKWebView] {
            view.navigationDelegate = self
        }
        // 窗口要真的在屏上、能成为 key window，sendEvent 才会按 hit test 派发给 webView
        let host = NSRect(x: 120, y: 120, width: frame.width, height: frame.height)
        plainWindow = NSWindow(contentRect: host, styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        plainWindow.contentView = plain
        guardedWindow = NSWindow(contentRect: host, styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
        guardedWindow.contentView = guarded
        plainWindow.orderBack(nil)
        guardedWindow.orderBack(nil)
        plain.loadHTMLString(page, baseURL: nil)
        guarded.loadHTMLString(page, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready += 1
        if ready == 2 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.run() } }
    }

    func expect(_ condition: Bool, _ label: String) {
        print((condition ? "  ✓ " : "  ✗ ") + label)
        if !condition { failures.append(label) }
    }

    func measure(_ view: WKWebView, _ done: @escaping (Int, Int, Int, Int, Int) -> Void) {
        view.evaluateJavaScript(measureJS) { result, error in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("  ✗ 取样失败：\(String(describing: error))")
                self.failures.append("取样失败")
                done(0, 0, 0, 0, 0)
                return
            }
            done(object["docLeft"] as? Int ?? -1,
                 object["docTop"] as? Int ?? -1,
                 object["docScrollWidth"] as? Int ?? 0,
                 object["docClientWidth"] as? Int ?? 0,
                 object["centerTop"] as? Int ?? 0)
        }
    }

    func run() {
        measure(plain) { _, _, plainWidth, plainClient, _ in
            print("测试前提：文档横向可滚？scrollWidth=\(plainWidth) clientWidth=\(plainClient)")
            self.expect(plainWidth > plainClient,
                        "测试页面确实有页面级横向溢出（否则测不到东西）")

            sendHorizontalGesture(to: self.plainWindow, view: self.plain, dx: -80, count: 12)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.measure(self.plain) { plainLeft, _, _, _, _ in
                    print("第一步：裸 WKWebView 收精确横向手势")
                    self.expect(plainLeft > 0, "裸 WKWebView 的文档被横向滚走（\(plainLeft)px，问题可复现）")

                    sendHorizontalGesture(to: self.guardedWindow, view: self.guarded, dx: -80, count: 12)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.measure(self.guarded) { guardedLeft, _, _, _, _ in
                            print("第二步：ShellWebView 收同样的手势")
                            self.expect(guardedLeft == 0, "ShellWebView 的文档没有被横向滚走")

                            // 精确纵向手势：文档层竖向必须照旧能滚（横向守卫不该误伤纵向）。
                            // 这里只能从文档层验证（WebKit 的落点判定用的是真实指针位置，
                            // 合成事件的 location 落不到内部滚动区上——裸 WKWebView 也一样）。
                            sendVerticalGesture(to: self.guardedWindow, view: self.guarded, dy: -120, count: 10)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.measure(self.guarded) { guardedLeft, guardedTop, _, _, _ in
                                    print("第三步：ShellWebView 收精确纵向手势")
                                    self.expect(guardedTop > 0,
                                                "纵向精确滚动照旧（document.scrollTop=\(guardedTop)）")
                                    self.expect(guardedLeft == 0, "纵向手势没把文档横向带走")
                                    self.checkDecisions()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func checkDecisions() {
        print("第四步：判定函数边界")
        if let preciseHorizontal = wheelEvent(dx: -60, dy: 0, precise: true, phase: 2) {
            expect(HorizontalWheelGuard.shouldNeutralize(preciseHorizontal),
                   "精确横向 → 拦")
            expect(HorizontalWheelGuard.neutralized(preciseHorizontal)?.scrollingDeltaX == 0,
                   "拦过之后 scrollingDeltaX 归零")
        } else {
            expect(false, "造精确横向事件失败")
        }
        if let plainHorizontal = wheelEvent(dx: -3, dy: 0, precise: false, phase: 0) {
            expect(!HorizontalWheelGuard.shouldNeutralize(plainHorizontal),
                   "非精确（普通滚轮）横向 → 放行，代码块还能左右滚")
        } else {
            expect(false, "造普通横向事件失败")
        }
        if let preciseVertical = wheelEvent(dx: 0, dy: -60, precise: true, phase: 2) {
            expect(!HorizontalWheelGuard.shouldNeutralize(preciseVertical),
                   "精确纵向 → 放行，平滑滚动不受影响")
        } else {
            expect(false, "造精确纵向事件失败")
        }
        print(failures.isEmpty
              ? "\n全部通过"
              : "\n失败 \(failures.count) 项：\(failures.joined(separator: "；"))")
        exit(failures.isEmpty ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let test = ScrollTest()
test.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    FileHandle.standardError.write(Data("超时\n".utf8))
    exit(2)
}
app.run()
