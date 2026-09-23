import AppKit
import WebKit

/*
 dshX 壳注入脚本（整页滚动守卫 + 输入框守卫）的回归测试。不是 App 的一部分。

 它直接读 `shell/Sources/main.swift` 里的 `fixedShellStyle` / `fixedShellGuardScript`，
 把拼好的脚本注入一个合成页面的 WKWebView（跟壳同一个引擎），断言四件事：

   1. 非 hero 会话：`[data-composer-seat]` 被钉成 position:sticky / bottom:0
   2. 滚会话自己的滚动区：输入框不动，而且滚动区的 scrollTop 不被归零（不能误伤正文）
   3. 「包含输入框、又不是会话滚动区」的祖先一旦被滚走：立刻归零，并 console.error 报出类名
   4. hero（欢迎页）：输入框不被钉成 sticky（居中布局要保留）

 用法（仓库根目录）：

   bash shell/tools/guard-test/run.sh

 退出码 0 = 全部通过。
*/

// MARK: - 从 main.swift 里取出真实注入脚本

enum SourceError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let what): return "在 shell/Sources/main.swift 里没找到 \(what)"
        }
    }
}

/// 把 Swift 一等号右侧那一串 `"..." + "..."` 字面量按顺序拼起来（只处理 \" 与 \\ 两种转义）。
func concatenatedSwiftLiterals(_ expression: String) -> String {
    var result = ""
    var index = expression.startIndex
    while index < expression.endIndex {
        guard expression[index] == "\"" else {
            index = expression.index(after: index)
            continue
        }
        index = expression.index(after: index)
        var literal = ""
        while index < expression.endIndex {
            let character = expression[index]
            if character == "\\" {
                let next = expression.index(after: index)
                if next < expression.endIndex {
                    let escaped = expression[next]
                    switch escaped {
                    case "n": literal.append("\n")
                    case "t": literal.append("\t")
                    default: literal.append(escaped)
                    }
                    index = expression.index(after: next)
                    continue
                }
            }
            if character == "\"" { index = expression.index(after: index); break }
            literal.append(character)
            index = expression.index(after: index)
        }
        result += literal
    }
    return result
}

func loadGuard() throws -> (css: String, script: String) {
    // 用 #filePath 定位仓库根，免得依赖调用时的 cwd：
    // <root>/shell/tools/guard-test/main.swift → 去掉文件名与三层目录。
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<3 { root = root.deletingLastPathComponent() }
    let sourceURL = root.appendingPathComponent("shell/Sources/main.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    // fixedShellStyle
    guard let styleStart = source.range(of: "private let fixedShellStyle =") else {
        throw SourceError.missing("fixedShellStyle")
    }
    guard let styleEnd = source.range(of: "\n\n", range: styleStart.upperBound..<source.endIndex) else {
        throw SourceError.missing("fixedShellStyle 结尾")
    }
    let css = concatenatedSwiftLiterals(String(source[styleStart.upperBound..<styleEnd.lowerBound]))
    guard !css.isEmpty else { throw SourceError.missing("fixedShellStyle 内容") }

    // fixedShellGuardScript
    guard let scriptOpen = source.range(of: "private let fixedShellGuardScript = \"\"\"") else {
        throw SourceError.missing("fixedShellGuardScript")
    }
    guard let scriptClose = source.range(of: "\"\"\"", range: scriptOpen.upperBound..<source.endIndex) else {
        throw SourceError.missing("fixedShellGuardScript 结尾")
    }
    var script = String(source[scriptOpen.upperBound..<scriptClose.lowerBound])
    guard let functionStart = script.range(of: "(function ()") else {
        throw SourceError.missing("fixedShellGuardScript 主体")
    }
    script = String(script[functionStart.lowerBound...]).replacingOccurrences(
        of: "\\(fixedShellStyle)", with: css)
    return (css, script)
}

// MARK: - 合成页面

let page = """
<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;height:100%}
  #root{height:100%}
  .pI_x6G_frame{height:100%;overflow:hidden;position:relative}
  .outerWrap{height:100%;overflow:hidden}
  [data-content-phase]{height:100%;display:flex;flex-direction:column;min-height:0}
  [data-content-phase].tall{height:200%}
  [data-conversation-scroll]{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column}
  [data-slot="conversation.session"]{flex:none;height:3000px;background:linear-gradient(#fff,#ddd)}
  [data-composer-seat]{flex:none;height:120px;background:#cfe}
</style>
<div id="root">
  <div class="pI_x6G_frame">
    <div class="outerWrap" id="outerWrap">
      <div data-content-phase="active" id="phaseHolder">
        <div data-conversation-scroll id="scroller">
          <div data-slot="conversation.session">长正文</div>
          <div data-composer-seat id="seat">输入框</div>
        </div>
      </div>
    </div>
  </div>
</div>
"""

let stepOneJS = """
(function () {
  var seat = document.getElementById('seat');
  var scroller = document.getElementById('scroller');
  var outer = document.getElementById('outerWrap');
  var phaseHolder = document.getElementById('phaseHolder');
  var out = {};
  out.guardPresent = !!document.getElementById('__dshx_fixed_shell__');
  out.styleInjected = !!document.getElementById('__dshx_fixed_shell__');
  out.seatPosition = getComputedStyle(seat).position;
  out.seatBottom = getComputedStyle(seat).bottom;

  scroller.scrollTop = 500;
  out.scrollerAfterOwnScroll = scroller.scrollTop;
  var scrollerRect = scroller.getBoundingClientRect();
  var seatRect = seat.getBoundingClientRect();
  out.seatPinnedAfterOwnScroll = Math.abs(seatRect.bottom - scrollerRect.bottom) < 2;

  phaseHolder.className = 'tall';
  outer.scrollTop = 220;
  out.outerRightAfterSet = outer.scrollTop;
  return JSON.stringify(out);
})()
"""

let stepTwoJS = """
(function () {
  var outer = document.getElementById('outerWrap');
  var scroller = document.getElementById('scroller');
  var seat = document.getElementById('seat');
  var scrollerRect = scroller.getBoundingClientRect();
  var seatRect = seat.getBoundingClientRect();
  return JSON.stringify({
    outerAfterGuard: outer.scrollTop,
    outerLeftAfterGuard: outer.scrollLeft,
    scrollerStillScrolled: scroller.scrollTop,
    seatPinned: Math.abs(seatRect.bottom - scrollerRect.bottom) < 2
  });
})()
"""

let heroJS = """
(function () {
  document.getElementById('phaseHolder').setAttribute('data-content-phase', 'hero');
  var seat = document.getElementById('seat');
  return JSON.stringify({
    seatPosition: getComputedStyle(seat).position,
    seatBottom: getComputedStyle(seat).bottom
  });
})()
"""

// MARK: - 跑

final class GuardTest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var logs: [String] = []
    var failures: [String] = []

    func start(injection: String) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        controller.add(self, name: "guardtest")
        controller.addUserScript(WKUserScript(source: """
        (function () {
          var original = console.error.bind(console);
          console.error = function () {
            try {
              window.webkit.messageHandlers.guardtest.postMessage(
                Array.prototype.slice.call(arguments).join(' '));
            } catch (error) {}
            original.apply(console, arguments);
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: injection, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        webView.loadHTMLString(page, baseURL: nil)
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        logs.append("\(message.body)")
    }

    func expect(_ condition: Bool, _ label: String) {
        print((condition ? "  ✓ " : "  ✗ ") + label)
        if !condition { failures.append(label) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.webView.evaluateJavaScript(stepOneJS) { result, error in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let step = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print("  ✗ 第一步脚本失败：\(String(describing: error))")
                    exit(1)
                }
                print("第一步：注入与合成 DOM")
                self.expect(step["guardPresent"] as? Bool == true, "守卫样式已注入")
                self.expect(step["seatPosition"] as? String == "sticky", "非 hero 时输入框座位是 sticky")
                self.expect(step["seatBottom"] as? String == "0px", "非 hero 时座位 bottom 是 0")
                self.expect(step["scrollerAfterOwnScroll"] as? Int == 500, "会话正文可以正常滚（未被误伤）")
                self.expect(step["seatPinnedAfterOwnScroll"] as? Bool == true, "滚正文时输入框仍贴在底部")
                self.expect(step["outerRightAfterSet"] as? Int == 220, "祖先容器确实被滚走了（测试前提成立）")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.webView.evaluateJavaScript(stepTwoJS) { result, error in
                        print("第二步：祖先滚动兜底")
                        guard let json = result as? String,
                              let data = json.data(using: .utf8),
                              let step = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            print("  ✗ 第二步脚本失败：\(String(describing: error))")
                            exit(1)
                        }
                        self.expect(step["outerAfterGuard"] as? Int == 0, "祖先的纵向滚动被归零")
                        self.expect(step["outerLeftAfterGuard"] as? Int == 0, "祖先的横向滚动被归零")
                        self.expect(step["scrollerStillScrolled"] as? Int == 500, "正文滚动位置保留")
                        self.expect(step["seatPinned"] as? Bool == true, "输入框仍贴在底部")
                        self.expect(self.logs.contains { $0.contains("[dshx]") },
                                    "命中时 console.error 报出容器类名（会进 backend.log）")

                        self.webView.evaluateJavaScript(heroJS) { result, _ in
                            print("第三步：hero 情况")
                            guard let json = result as? String,
                                  let data = json.data(using: .utf8),
                                  let step = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                print("  ✗ 第三步脚本失败")
                                exit(1)
                            }
                            self.expect(step["seatPosition"] as? String != "sticky",
                                        "hero 时输入框不被钉（居中布局保留）")
                            print(self.failures.isEmpty
                                  ? "\n全部通过"
                                  : "\n失败 \(self.failures.count) 项：\(self.failures.joined(separator: "；"))")
                            exit(self.failures.isEmpty ? 0 : 1)
                        }
                    }
                }
            }
        }
    }
}

let injection: (css: String, script: String)
do {
    injection = try loadGuard()
} catch {
    FileHandle.standardError.write(Data("读取注入脚本失败：\(error)\n".utf8))
    exit(2)
}
print("注入 CSS：\(injection.css.prefix(120))…\n")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let test = GuardTest()
test.start(injection: injection.script)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    FileHandle.standardError.write(Data("超时\n".utf8))
    exit(2)
}
app.run()
