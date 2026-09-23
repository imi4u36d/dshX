import AppKit
import WebKit

/*
 dshX: a small native macOS shell for DeepSeek Harness.

 The shell starts the bundled dsh web backend, reads the loopback URL from its
 output, shows it in WKWebView, and terminates the backend when the app exits.
 */

let appTitle = "dshX"
let bootTimeoutSeconds: TimeInterval = 120
private let webLogMessageName = "dshxLog"

private let webLogScript = """
(function () {
  var name = '\(webLogMessageName)';
  function text(value) {
    if (value && typeof value === 'object') {
      if (typeof value.stack === 'string') { return value.stack; }
      if (typeof value.message === 'string') {
        return (typeof value.name === 'string' ? value.name + ': ' : '') + value.message;
      }
    }
    if (value instanceof Error) { return value.stack || value.message || String(value); }
    if (typeof value === 'string') { return value; }
    try { return JSON.stringify(value); } catch (error) { return String(value); }
  }
  function send(values) {
    try {
      window.webkit.messageHandlers[name].postMessage(values.map(text).join(' '));
    } catch (error) {}
  }
  var originalError = console.error.bind(console);
  console.error = function () {
    var values = Array.prototype.slice.call(arguments);
    send(values);
    originalError.apply(console, values);
  };
  window.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target !== window) {
      send(['Resource load failed:', target.tagName, target.src || target.href || '']);
      return;
    }
    send(['Window error:', event.message, event.filename + ':' + event.lineno + ':' + event.colno, event.error]);
  }, true);
  window.addEventListener('unhandledrejection', function (event) {
    send(['Unhandled rejection:', event.reason]);
  });
})();
"""

/// WebKit 与 Chromium 的焦点行为差异补丁（模型切换点不动的根因）。
///
/// Safari 引擎在 mousedown 时会把焦点从当前元素上拿走，却不把焦点给被点的
/// `<button>`（Chromium 会给）。dsh 的弹层（模型、推理等级等）打开或进入下一层时
/// 会把当前选中行 focus 住，并在 onBlur 时关掉自己：于是真实鼠标点下去的那一瞬间
/// 焦点先丢、弹层随之关闭，`mouseup` / `click` 落到页面其它元素上，行的 onClick
/// 从来没执行过——表现就是「菜单弹得出来，点模型没反应」。
/// 在弹层内的行上按下鼠标时阻止默认的焦点迁移，焦点留在弹层里，click 才能派发。
/// 键盘操作（Tab / Enter / 方向键）不走 mousedown，本来就不受影响。
/// 想要复现原始问题：`DSHX_DISABLE_MENU_FOCUS_SHIM=1 open -a dshX`。
private let menuFocusShimEnabled =
    ProcessInfo.processInfo.environment["DSHX_DISABLE_MENU_FOCUS_SHIM"] != "1"

private let menuFocusShimScript = """
(function () {
  var ROWS = 'button,[role="menuitem"],[role="menuitemradio"],[role="option"],[role="tab"]';
  var POPUPS = '[role="menu"],[role="listbox"]';
  document.addEventListener('mousedown', function (event) {
    var target = event.target;
    if (!target || typeof target.closest !== 'function') { return; }
    var row = target.closest(ROWS);
    if (!row || row.closest(POPUPS) === null) { return; }
    event.preventDefault();
  }, true);
})();
"""

/// 整页滚动 / 双指缩放守卫。
///
/// 壳把网页当「固定尺寸的原生界面」用：整页不该滚、也不该被放大后四下拖动。
/// 三个「整个 App 都能滚」的来源，全都在壳这一侧，跟页面内容无关：
///
///   1. 双指缩放。macOS 上 WKWebView 的 allowsMagnification 默认是 NO；一旦打开，
///      整个页面就变成可四方拖动的图层。
///   2. 文档层滚动。前端根样式只有 `html,body,#root{height:100%;margin:0}`，没有
///      overflow 限制，也没有 overscroll-behavior；某个 overflow:auto 的容器滚到边界后
///      滚动链交给文档层，整页跟着上下、左右弹。
///   3. **程序化滚动（真正难缠的那个）**。`overflow:hidden` 的盒子仍然是滚动容器，
///      只是不给用户滚动条——`scrollIntoView` / `focus` 照样能把它滚走。dsh 的布局容器
///      `[class*="_frame"]`（AppFrame）正是 `overflow:hidden`，而它的网格比视口宽一列
///      右侧栏：实测 1280 宽的窗口里 `scrollWidth` 是 1856。于是页面里任何一次
///      `scrollIntoView`（聚焦输入框、选中会话行、插件打开面板都算）落在离屏区域，
///      就会把整个 AppFrame 横移最多 576px——表现就是「偶尔整个页面左右滚」。纵向同理，
///      只要 frame 或文档层竖向溢出，就会被同样地推走。
///
/// 所以这里三层一起上：
///   - allowsMagnification 默认 NO；
///   - documentStart 注入 CSS 把文档层钉死（`overflow:hidden` 兜底 + `overflow:clip`）；
///   - `overflow:clip` 而不是 `hidden`：`clip` 不产生滚动容器，程序化滚动也动不了它。
///     框架容器上这条覆盖面最大，另外再用一段 scroll 捕获兜底（见下）。
/// 只钉「整页级」容器，内部 overflow:auto 的滚动区（终端、代码块、消息列表）照旧能滚。
///
/// 第 4 条（0.2.8 起）不在这段注入里：**左右滚轮把整页拖走** 是「精确滚动 + phase」
/// 手势在文档/合成层上做的横向平移，注入的 CSS 挡不可靠，所以在 AppKit 层拦
/// （`Sources/wheel-guard.swift` 的 ShellWebView：把这类事件的横向分量清零）。
///
/// 历史：这段守卫在 0.2.3 的 `8ad0668`（重写 main.swift 修模型切换）里被整段丢掉，
/// 0.2.3 起又回到了「整页能滚」；0.2.6 恢复成 `hidden` 版本，实测对第 3 条无效，
/// 0.2.7 才补上 `clip` 与兜底。
///
/// 排查开关（三者任一都可能让「整页又能滚」回来，用来定位是不是这条规则的锅）：
///   DSHX_PINCH_ZOOM=1        恢复双指缩放（代价是回到「整页能拖着走」）
///   DSHX_ALLOW_PAGE_SCROLL=1 完全不注入这段样式与兜底
private let pinchZoomEnabled = ProcessInfo.processInfo.environment["DSHX_PINCH_ZOOM"] == "1"
private let pageScrollAllowed = ProcessInfo.processInfo.environment["DSHX_ALLOW_PAGE_SCROLL"] == "1"

/// `overflow:hidden` 先写、`overflow:clip` 后写：老引擎（Safari 15.4 以前）不认识 `clip`，
/// 会丢掉后面那条、留下 `hidden`，至少不会比从前更差。
/// 必须写成一整行：它会被拼进 JS 的单引号字符串里，换行会让整段脚本语法错误。
///
/// 第 3、4 条是「输入框被正文带着滚」的对症补丁（见下面 fixedShellGuardScript 的说明）：
///   - `overscroll-behavior:contain`：会话滚动区滚到边界后不再把滚动链交给外层，
///     也压掉这块区域的橡皮筋回弹——回弹会把 sticky 的输入框一起拖走。
///   - `[data-phase]:not(hero/settling) [data-composer-seat]{position:sticky;bottom:0}`：
///     上游只在 `.wSkVaW_root[data-phase=active]` 下给输入框座位加 sticky；这条用稳定
///     属性名再钉一遍，万一上游类名改了、或 phase 属性没落到位，输入框也仍然贴在底部。
///     hero（欢迎页输入框居中）与 settling（隐藏）两种情况不能钉，所以显式排除。
private let fixedShellStyle = "html,body,#root{overflow:hidden !important;overflow:clip !important;"
    + "overscroll-behavior:none !important}"
    + "#root [class*=\"_frame\"]{overflow:hidden !important;overflow:clip !important}"
    + "#root [data-conversation-scroll]{overscroll-behavior:contain !important}"
    + "#root [data-composer-seat]{overscroll-behavior:contain !important}"
    + "[data-phase]:not([data-phase=\"hero\"]):not([data-phase=\"settling\"]) [data-composer-seat]"
    + "{position:sticky !important;bottom:0 !important}"
    + "[data-content-phase]:not([data-content-phase=\"hero\"]):not([data-content-phase=\"settling\"])"
    + " [data-composer-seat]{position:sticky !important;bottom:0 !important}"

/// 用 documentStart 的 <style> 注入：React 挂载前规则就已生效，
/// 注入点在 document.head 还没建好时退回 documentElement，再不行等 DOMContentLoaded 补一次。
/// 页面重新导航（换会话、热更新）时脚本会重新注入，所以没必要监听 SPA 路由。
///
/// 末尾那段 scroll 捕获是兜底，两条规则：
///
///   1. 「输入框跟着滚」的兜底（0.2.7 之后补的）。会话的滚动结构是
///      `[data-conversation-scroll] > (消息列表 + 输入框座位)`，输入框靠
///      `position:sticky` 贴在滚动视口底部。只要**任何别的祖先**也被滚走
///      （程序化 `scrollIntoView`、上下文菜单、上游改版后的新容器……），
///      sticky 的坐标系就跟着整块上移——表现就是「输入框离开底部，跟着消息一起滚」。
///      所以这里定一条更省的规则：凡是「包含输入框座位、又不是会话自己的滚动区」
///      的容器，一旦被滚，立刻归零。会话滚动区（以及它内部的消息、代码块等）之外
///      一律不许滚，比按尺寸猜「整页级容器」更准，也不会误伤正文滚动。
///   2. 整页级容器（`overflow:hidden` 的老兜底）：CSS 里那条 `[class*="_frame"]`
///      依赖上游的类名约定，万一将来改了名，这里还能在容器被程序化滚走的那一刻
///      把它钉回原点，并就地换成 `overflow:clip`（只动真正被滚、且当前是 hidden 的
///      那一个方向，避免误伤 `overflow-x:hidden; overflow-y:auto` 这类正常滚动区）。
///
/// 命中「输入框被带走」时用 console.error 记一条（最多 5 条，壳会把页面 console.error
/// 写进 backend.log）：真出现过一次，日志里就有那个容器的类名，定位不用再靠猜。
private let fixedShellGuardScript = """
(function () {
  var id = '__dshx_fixed_shell__';
  var css = '\(fixedShellStyle)';
  function inject() {
    if (document.getElementById(id)) { return; }
    var host = document.head || document.documentElement;
    if (!host) { return; }
    var style = document.createElement('style');
    style.id = id;
    style.textContent = css;
    host.appendChild(style);
  }
  inject();
  document.addEventListener('DOMContentLoaded', inject);
  window.addEventListener('load', inject);

  function describe(element) {
    var name = element.tagName || '?';
    if (element.id) { name += '#' + element.id; }
    var cls = element.className;
    if (typeof cls === 'string' && cls) { name += '.' + cls.slice(0, 40); }
    return name;
  }
  var reported = 0;
  function report(element, axis, value) {
    if (reported >= 5) { return; }
    reported += 1;
    try {
      console.error('[dshx] 输入框被「' + describe(element) + '」的' + axis
        + '滚动带走 ' + Math.round(value) + 'px，已归零');
    } catch (error) {}
  }

  function pin(element) {
    if (!element || element.nodeType !== 1) { return; }
    if (element === document.documentElement || element === document.body) { return; }
    if (element.closest && element.closest('[data-conversation-scroll]') !== null) { return; }
    // 主会话与面板里的会话各有一份座位，这里是「有没有座位在我里面」，
    // 不问是第几份；querySelector 只看后代，滚动区本身不会是座位。
    if (element.querySelector && element.querySelector('[data-composer-seat]') !== null) {
      if (element.scrollTop !== 0) {
        var draggedTop = element.scrollTop;
        element.scrollTop = 0;
        report(element, '纵向', draggedTop);
      }
      if (element.scrollLeft !== 0) {
        var draggedLeft = element.scrollLeft;
        element.scrollLeft = 0;
        report(element, '横向', draggedLeft);
      }
      return;
    }
    var style = getComputedStyle(element);
    var rect = element.getBoundingClientRect();
    var wide = rect.width >= window.innerWidth * 0.8;
    var tall = rect.height >= window.innerHeight * 0.8;
    if (style.overflowX === 'hidden' && wide && element.scrollLeft !== 0) {
      element.scrollLeft = 0;
      element.style.setProperty('overflow-x', 'clip', 'important');
    }
    if (style.overflowY === 'hidden' && tall && element.scrollTop !== 0) {
      element.scrollTop = 0;
      element.style.setProperty('overflow-y', 'clip', 'important');
    }
  }
  document.addEventListener('scroll', function (event) { pin(event.target); }, true);
})();
"""

// MARK: - Runtime

struct RuntimePlan {
    let node: URL
    let entry: URL
    let home: URL
    let workspace: URL
}

let stateDirectory: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return support.appendingPathComponent("dshX", isDirectory: true)
}()

var logFileURL: URL { stateDirectory.appendingPathComponent("backend.log") }

enum PlanOutcome {
    case success(RuntimePlan)
    case failure(String)
}

func resolvePlan() -> PlanOutcome {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment
    let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent")

    var nodeCandidates: [String] = []
    if let override = env["DSH_APP_NODE"], !override.isEmpty { nodeCandidates.append(override) }
    nodeCandidates.append(resources.appendingPathComponent("node/bin/node").path)
    nodeCandidates.append(contentsOf: [
        "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
        NSHomeDirectory() + "/.volta/bin/node",
    ])

    let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
    if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
        nodeCandidates.append(contentsOf: versions.sorted(by: >).map { "\(nvmRoot)/\($0)/bin/node" })
    }
    guard let node = nodeCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        return .failure("找不到可执行的 Node.js。已尝试：\n" + nodeCandidates.joined(separator: "\n"))
    }

    var entryCandidates: [String] = []
    if let override = env["DSH_APP_ENTRY"], !override.isEmpty { entryCandidates.append(override) }
    entryCandidates.append(resources.appendingPathComponent(
        "runtime/node_modules/@deepseek-ai/dsh/lib/bin.js").path)
    entryCandidates.append(stateDirectory.appendingPathComponent(
        "runtime/node_modules/@deepseek-ai/dsh/lib/bin.js").path)
    guard let entry = entryCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        return .failure("找不到 dsh 入口 bin.js。已尝试：\n" + entryCandidates.joined(separator: "\n"))
    }

    let home = env["DSH_APP_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? stateDirectory.appendingPathComponent("home").path
    let workspace = env["DSH_APP_WORKSPACE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? stateDirectory.appendingPathComponent("workspace").path

    do {
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    } catch {
        return .failure("无法创建私有目录：\(error.localizedDescription)")
    }

    return .success(RuntimePlan(
        node: URL(fileURLWithPath: node),
        entry: URL(fileURLWithPath: entry),
        home: URL(fileURLWithPath: home),
        workspace: URL(fileURLWithPath: workspace)))
}

// MARK: - Backend process

private let supervisorScript = """
node="$1"; shift
watch="$PPID"
"$node" "$@" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; exit 0' TERM INT
while kill -0 "$child" 2>/dev/null; do
  sleep 1
  kill -0 "$watch" 2>/dev/null || { kill -TERM "$child" 2>/dev/null; exit 0; }
done
"""

private let logWriteLock = NSLock()

private func writeLine(_ handle: FileHandle?, _ text: String) {
    guard let handle, let data = text.data(using: .utf8) else { return }
    logWriteLock.lock()
    defer { logWriteLock.unlock() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

func shellLog(_ text: String) {
    guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
    defer { try? handle.close() }
    writeLine(handle, "[shell] \(text)\n")
}

final class Backend {
    private var process: Process?
    private var pending = Data()
    private var reportedURL = false
    private let lock = NSLock()
    private let onURL: (URL) -> Void
    private let onDeath: (String) -> Void

    init(onURL: @escaping (URL) -> Void, onDeath: @escaping (String) -> Void) {
        self.onURL = onURL
        self.onDeath = onDeath
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start(_ plan: RuntimePlan) {
        try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            try? Data().write(to: logFileURL)
        }
        let handle = try? FileHandle(forWritingTo: logFileURL)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", supervisorScript, "dsh-serve", plan.node.path, plan.entry.path,
                           "web", "--host", "127.0.0.1", "--port", "0", "--no-open"]
        child.currentDirectoryURL = plan.workspace

        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LANG", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        let resources = Bundle.main.resourceURL
            ?? plan.node.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        env["PATH"] = [
            plan.node.deletingLastPathComponent().path,
            resources.appendingPathComponent("tools/bin").path,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ].joined(separator: ":")
        env["DSH_HOME"] = plan.home.path
        env["NODE_ENV"] = "production"
        env["DSH_TELEMETRY_DISABLED"] = "1"
        child.environment = env

        let output = Pipe()
        let error = Pipe()
        child.standardOutput = output
        child.standardError = error

        let urlPattern = try? NSRegularExpression(
            pattern: #"https?://(?:127\.0\.0\.1|localhost)(?::\d+)?/(?:\S*)"#)

        let consume: (Data) -> Void = { [weak self] chunk in
            guard let self else { return }
            writeLine(handle, String(data: chunk, encoding: .utf8) ?? "")
            self.lock.lock()
            self.pending.append(chunk)
            let tail = self.pending.suffix(8192)
            let text = String(decoding: tail, as: UTF8.self)
            var found: String?
            if !self.reportedURL,
               let match = urlPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                found = String(text[range]).split(separator: " ").first.map(String.init)
                self.reportedURL = found != nil
            }
            self.lock.unlock()
            if let text = found, let url = URL(string: text) {
                DispatchQueue.main.async { [weak self] in self?.onURL(url) }
            }
        }

        for source in [output.fileHandleForReading, error.fileHandleForReading] {
            source.readabilityHandler = { readable in
                let chunk = readable.availableData
                if chunk.isEmpty { return }
                consume(chunk)
            }
        }

        child.terminationHandler = { [weak self, output, error, handle] terminated in
            for pipe in [output, error] { pipe.fileHandleForReading.readabilityHandler = nil }
            try? handle?.close()
            let message = "dsh 后端已退出（status \(terminated.terminationStatus)）。"
            DispatchQueue.main.async { [weak self] in self?.onDeath(message) }
        }

        writeLine(handle, "\n===== \(Date()) 启动 =====\n"
            + "\(plan.node.path) \(plan.entry.path) web --host 127.0.0.1 --port 0 --no-open\n"
            + "cwd = \(plan.workspace.path)\nDSH_HOME = \(plan.home.path)\n")
        do {
            try child.run()
            process = child
            childPID = child.processIdentifier
        } catch {
            try? handle?.close()
            onDeath("无法启动 dsh 后端：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard let child = process, child.isRunning else { return }
        child.terminationHandler = nil
        childPID = 0
        child.terminate()
        for _ in 0..<30 {
            if !child.isRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(child.processIdentifier, SIGKILL)
    }
}

final class WebLogBridge: NSObject, WKScriptMessageHandler {
    weak var controller: ShellController?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        self.controller?.appendWebLog(text)
    }
}

final class AuthSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let completion: (Result<[HTTPCookie], Error>) -> Void
    private var cookies: [HTTPCookie] = []

    init(completion: @escaping (Result<[HTTPCookie], Error>) -> Void) {
        self.completion = completion
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String {
                result[key] = value
            }
        }
        let url = response.url ?? task.originalRequest?.url
        if let url {
            cookies.append(contentsOf: HTTPCookie.cookies(withResponseHeaderFields: headers,
                                                           for: url))
        }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            completion(.failure(error))
        } else {
            completion(.success(cookies))
        }
    }
}

// MARK: - Shutdown fallback

private var childPID: pid_t = 0
private var signalSources: [DispatchSourceSignal] = []

private func installShutdownSignalNet() {
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            if childPID > 0 { kill(childPID, SIGTERM) }
            _exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

// MARK: - Shell controller

final class ShellController: NSObject, WKNavigationDelegate, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var backend: Backend?
    private var currentURL: URL?
    private var authSession: URLSession?
    private var authDelegate: AuthSessionDelegate?
    private var navigationRetries = 0
    private var isShuttingDown = false

    static let shared = ShellController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()

        guard resolveBackendConflictsOrExit() else {
            NSApp.terminate(nil)
            return
        }

        RuntimeUpdater.shared.wireBackend(
            stop: { [weak self] in
                guard let self else { return }
                self.currentURL = nil
                self.window.title = appTitle
                self.backend?.stop()
                self.backend = nil
            },
            start: { [weak self] in self?.boot() },
            conflicts: { [weak self] in
                guard let self else { return [] }
                var excluded: Set<Int> = []
                if let port = self.currentURL?.port { excluded.insert(port) }
                return conflictingBackends(excludingPorts: excluded)
            })
        RuntimeUpdater.shared.adoptStagedAtLaunchIfAny()
        boot()
    }

    private func resolveBackendConflictsOrExit() -> Bool {
        var conflicts = conflictingBackends()
        guard !conflicts.isEmpty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "有另一个 dsh 后端正在使用同一个 DSH_HOME"
        alert.informativeText = """
            检测到：\(conflicts.map(\.text).joined(separator: "、"))
            它会占住会话，更新后端时也可能换到一半。

            结束这些进程后 dshX 会正常启动；它们正在服务的其它页面会断开。
            """
        alert.addButton(withTitle: "结束它们并继续")
        alert.addButton(withTitle: "仍然打开")
        alert.addButton(withTitle: "退出 dshX")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for conflict in conflicts { kill(conflict.pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 1)
            for conflict in conflictingBackends() { kill(conflict.pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.2)
            conflicts = conflictingBackends()
            if !conflicts.isEmpty {
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = "没能结束这些 dsh 后端"
                failed.informativeText = conflicts.map(\.text).joined(separator: "、")
                    + "\n这次先继续启动，但模型切换可能仍会失败。"
                failed.addButton(withTitle: "好")
                failed.runModal()
            }
            return true
        case .alertSecondButtonReturn:
            shellLog("检测到其它 dsh 后端，用户选择仍然打开："
                + conflicts.map(\.text).joined(separator: "、"))
            return true
        default:
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isShuttingDown = true
        backend?.stop()
        return .terminateNow
    }

    private func boot() {
        switch resolvePlan() {
        case .failure(let message):
            presentFailure(message)
        case .success(let plan):
            let backendVersion = installedBackendVersion(in: runtimeDirectory()) ?? "版本未知"
            presentBootPage("dsh   \(backendVersion)\n"
                + "node  \(plan.node.path)\nentry \(plan.entry.path)\n"
                + "cwd   \(plan.workspace.path)\nDSH_HOME \(plan.home.path)")
            let backend = Backend(
                onURL: { [weak self] url in self?.connect(to: url) },
                onDeath: { [weak self] message in self?.reportDeath(message) })
            self.backend = backend
            backend.start(plan)
            DispatchQueue.main.asyncAfter(deadline: .now() + bootTimeoutSeconds) { [weak self] in
                guard let self, self.currentURL == nil, !self.isShuttingDown,
                      self.backend?.isRunning == true else { return }
                self.presentFailure("启动超时：\(Int(bootTimeoutSeconds)) 秒内后端没有就绪。\n"
                    + "日志：\(logFileURL.path)")
            }
        }
    }

    private func connect(to url: URL) {
        guard !isShuttingDown, url != currentURL else { return }
        currentURL = url
        navigationRetries = 0
        window.title = "\(appTitle) — \(url.host ?? ""):\(url.port ?? 0)"
        shellLog("后端地址已就绪：\(url.absoluteString)")
        authenticate(url)
    }

    private func authenticate(_ url: URL) {
        let delegate = AuthSessionDelegate { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authSession = nil
                self.authDelegate = nil
                switch result {
                case .failure(let error):
                    self.reportDeath("无法连接 dsh 后端：\(error.localizedDescription)")
                case .success(let cookies):
                    shellLog("认证响应已返回，注入 \(cookies.count) 个 cookie")
                    self.installCookies(cookies, rootURL: url)
                }
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: delegate,
                                 delegateQueue: nil)
        authDelegate = delegate
        authSession = session
        session.dataTask(with: url).resume()
    }

    private func installCookies(_ cookies: [HTTPCookie], rootURL url: URL) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] existing in
            guard let self else { return }
            let stale = existing.filter {
                $0.name.hasPrefix("dsh-auth-")
                    && ($0.domain == "127.0.0.1" || $0.domain == "localhost")
            }
            let group = DispatchGroup()
            for cookie in stale {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                let root: URL
                if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.path = "/"
                    components.query = nil
                    components.fragment = nil
                    root = components.url ?? url
                } else {
                    root = url
                }
                self.webView.load(URLRequest(url: root,
                                             cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 30))
            }
        }
    }

    private func reportDeath(_ message: String) {
        guard !isShuttingDown else { return }
        currentURL = nil
        window.title = appTitle

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "日志：\(logFileURL.path)"
        alert.addButton(withTitle: "重新启动后端")
        alert.addButton(withTitle: "退出应用")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            boot()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func presentFailure(_ message: String) {
        currentURL = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法启动 DeepSeek Harness 后端"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        isShuttingDown = true
        backend?.stop()
        NSApp.terminate(nil)
    }

    // MARK: Window

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appTitle
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        let bridge = WebLogBridge()
        bridge.controller = self
        configuration.userContentController.add(bridge, name: webLogMessageName)
        var pageScripts = [webLogScript]
        if menuFocusShimEnabled { pageScripts.append(menuFocusShimScript) }
        if !pageScrollAllowed { pageScripts.append(fixedShellGuardScript) }
        for source in pageScripts {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }

        // ShellWebView 见 Sources/wheel-guard.swift：在 AppKit 层吃掉「手势型横向滚动」
        // 的横向分量，挡掉注入 CSS 挡不住的整页横移。
        let webView = ShellWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = pinchZoomEnabled
        if #available(macOS 13.3, *) { webView.isInspectable = false }
        self.webView = webView

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentBootPage(_ detail: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="dark light">
        <style>
          body{margin:0;height:100vh;display:grid;place-items:center;background:#111418;color:#c9d1d9;
               font:13px/1.8 ui-monospace,SFMono-Regular,Menlo,monospace}
          main{max-width:46rem;padding:1.6rem 1.9rem;border:1px solid #2b3138;border-radius:8px;background:#171b21}
          h1{font:600 14px/1.4 -apple-system,system-ui,sans-serif;margin:0 0 .9rem}
          pre{margin:0;white-space:pre-wrap;word-break:break-all;opacity:.75}
        </style>
        <main><h1>dshX · 正在启动后端（首次约 10–30 秒）</h1><pre>\(escapeHTML(detail))</pre></main>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func escapeHTML(_ text: String) -> String {
        var result = text
        for (character, entity) in [("&", "amp"), ("<", "lt"), (">", "gt")] {
            result = result.replacingOccurrences(of: character, with: "&" + entity + ";")
        }
        return result
    }

    // MARK: Navigation

    func webView(_ view: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        let host = (url.host ?? "").lowercased()
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "[::1]"
        if loopback, scheme == "http" || scheme == "https" {
            decisionHandler(.allow)
        } else if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        shellLog("页面载入完成：\(view.url?.absoluteString ?? "")")
    }

    func webView(_ view: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !isShuttingDown else { return }
        shellLog("页面载入失败：\(error.localizedDescription)")
        navigationRetries += 1
        guard navigationRetries <= 3, let url = currentURL else {
            reportDeath("页面载入失败：\(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 30))
        }
    }

    func appendWebLog(_ text: String) {
        shellLog("[web] \(text)")
    }

    // MARK: Updates

    @objc func checkForUpdate() {
        UpdateController.shared.check()
    }

    @objc func updateBackend() {
        RuntimeUpdater.shared.check()
    }
}

// MARK: - Environment

func envString(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
}

// MARK: - Menu

private func buildMainMenu() -> NSMenu {
    let menu = NSMenu()

    func addSection(_ title: String, to parent: NSMenu) -> NSMenu {
        let item = NSMenuItem()
        parent.addItem(item)
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }

    func add(_ submenu: NSMenu, _ title: String, _ selector: Selector?, _ key: String,
             _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = submenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
    }

    let appMenu = addSection(appTitle, to: menu)
    add(appMenu, "关于 \(appTitle)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
    appMenu.addItem(.separator())
    add(appMenu, "检查更新…", #selector(ShellController.checkForUpdate), "u")
    add(appMenu, "更新 dsh 后端…", #selector(ShellController.updateBackend), "b")
    appMenu.addItem(.separator())
    add(appMenu, "隐藏 \(appTitle)", #selector(NSApplication.hide(_:)), "h")
    add(appMenu, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h",
        [.command, .option])
    add(appMenu, "显示全部", #selector(NSApplication.unhideAllApplications(_:)), "")
    appMenu.addItem(.separator())
    add(appMenu, "退出 \(appTitle)", #selector(NSApplication.terminate(_:)), "q")

    let fileMenu = addSection("文件", to: menu)
    add(fileMenu, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")

    let editMenu = addSection("编辑", to: menu)
    add(editMenu, "撤销", Selector(("undo:")), "z")
    add(editMenu, "重做", Selector(("redo:")), "Z")
    editMenu.addItem(.separator())
    add(editMenu, "剪切", #selector(NSText.cut(_:)), "x")
    add(editMenu, "拷贝", #selector(NSText.copy(_:)), "c")
    add(editMenu, "粘贴", #selector(NSText.paste(_:)), "v")
    add(editMenu, "全部选中", #selector(NSText.selectAll(_:)), "a")

    let windowMenu = addSection("窗口", to: menu)
    add(windowMenu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(windowMenu, "缩放", #selector(NSWindow.performZoom(_:)), "")
    NSApp.windowsMenu = windowMenu
    return menu
}

// MARK: - Entry

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = ShellController.shared
installShutdownSignalNet()
application.mainMenu = buildMainMenu()
application.run()
