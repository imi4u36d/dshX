import AppKit
import WebKit

/*
 dshX —— DeepSeek Harness 的原生 macOS 壳（非官方，本地自用）。

 职责
   1. 拉起 dsh Web 后端：node <bundle>/runtime/.../dsh/lib/bin.js web --host 127.0.0.1 --port 0 --no-open
   2. 从后端 stdout 抓出它自己打印的服务地址（含进程级 token），端口由内核分配。
   3. 用 WKWebView 原生窗口承载 UI；启动失败或后端退出时给出可读告警。
   4. 退出应用时收掉后端进程，不留孤儿监听端口。

 刻意保持的边界
   - 子进程环境剔除全部 DSH_* 变量，再显式设置 DSH_HOME；不继承任何已有 harness
     会话的状态（DSH_SHELL / DSH_SESSION_ID / DSH_WEB_URL 等）。
   - DSH_HOME 默认落在 Application Support 下的私有目录，不去抢默认的 ~/.dsh
     （那里可能正被另一个 harness 实例独占）。
   - 导航只留在回环地址内；外部链接交给系统默认浏览器。
 */

let appTitle = "dshX"
let bootTimeoutSeconds: TimeInterval = 120

// MARK: - 整页滚动 / 缩放开关
//
// 壳把网页当「固定尺寸的原生界面」用：整页不该滚、也不该被放大后拖动。
// 两种「整个 App 都能滚」的来源都在壳这一侧，跟页面内容无关：
//   1. 双指缩放。macOS 上 WKWebView 的 allowsMagnification 默认是 NO，本页
//      以前显式打开了；一旦放大，整个页面就变成可四下拖动的图层。
//   2. 橡皮筋（rubber band）。前端 html/body 只有 height:100%，没有 overflow 限制，
//      终端输出 / 代码块 / 面板这些 overflow:auto 的容器也缺 overscroll-behavior，
//      滚到底就链到文档层，整个页面跟着动。
// 所以这里两样都关掉。想临时复原（排查问题、或者真想把字放大看）：
//   DSHX_PINCH_ZOOM=1        恢复双指缩放（代价是回到「整页能拖着走」）
//   DSHX_ALLOW_PAGE_SCROLL=1 不注入固定布局样式（文档层重新可滚 / 橡皮筋）

private let pinchZoomEnabled = ProcessInfo.processInfo.environment["DSHX_PINCH_ZOOM"] == "1"
private let pageScrollAllowed = ProcessInfo.processInfo.environment["DSHX_ALLOW_PAGE_SCROLL"] == "1"

/// 只钉文档层，内部 overflow:auto 的滚动区不受影响，仍然正常滚。
private let fixedShellStyle = """
html,body,#root{overflow:hidden !important;overscroll-behavior:none !important}
"""

/// 用 documentStart 的 <style> 注入：React 挂载前规则就已生效，
/// 注入点在 document.head 还没建好时退回 documentElement，再不行等 DOMContentLoaded 补一次。
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
})();
"""

// MARK: - 运行资源解析

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

/// 解析结果；失败时带一句能直接读给人看的说明。
enum PlanOutcome {
    case success(RuntimePlan)
    case failure(String)
}

/// 解析可用的 node、dsh 入口、私有 DSH_HOME、工作目录。
func resolvePlan(workspaceOverride: String? = nil) -> PlanOutcome {
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
    entryCandidates.append(resources.appendingPathComponent("runtime/node_modules/@deepseek-ai/dsh/lib/bin.js").path)
    entryCandidates.append(stateDirectory.appendingPathComponent("runtime/node_modules/@deepseek-ai/dsh/lib/bin.js").path)
    guard let entry = entryCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        return .failure("找不到 dsh 入口 bin.js。已尝试：\n" + entryCandidates.joined(separator: "\n"))
    }

    var home = stateDirectory.appendingPathComponent("home").path
    if let override = env["DSH_APP_HOME"], !override.isEmpty { home = override }
    let workspace = workspaceOverride
        ?? env["DSH_APP_WORKSPACE"].flatMap { $0.isEmpty ? nil : $0 }
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

// MARK: - 后端进程

/// 后端启动包装：让 node 与壳共存亡。
/// 壳如果以非正常方式消失（Force Quit、kill -9、崩溃），子进程在 Unix 上默认会
/// 变成孤儿继续跑，留下一个带完整文件访问权限的 harness 后端。这里用 1 秒轮询
/// 「父进程还在不在」来兜底：父壳一没，立刻收掉 node。
/// 正常退出走 applicationShouldTerminate → stop()，两条路径互补。
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

/// 一个 dsh 后端子进程。整类只在主线程使用，IO 回调内部再切回主线程。
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
        // 日志只用于诊断：打不开也要照常启动。
        let handle = try? FileHandle(forWritingTo: logFileURL)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", supervisorScript, "dsh-serve", plan.node.path, plan.entry.path,
                           "web", "--host", "127.0.0.1", "--port", "0", "--no-open"]
        child.currentDirectoryURL = plan.workspace

        // 白名单继承环境变量；DSH_* 一律清洗后重建。
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LANG", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        // 内置 pnpm 必须出现在这条 PATH 上：make-app.sh 把它打进
        // Contents/Resources/tools/bin，插件安装链路靠 execvp('pnpm') 找它。
        // 图形界面启动不继承终端 PATH，本机也没有 npm/corepack，漏掉这一项
        // 内置 pnpm 就形同虚设，插件市场一律报「找不到 npm/corepack」。
        // bundle 取不到（源码方式直跑壳）时从 node 路径上推三层回到 Resources。
        let resources = Bundle.main.resourceURL
            ?? plan.node.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        let paths = [plan.node.deletingLastPathComponent().path,
                     resources.appendingPathComponent("tools/bin").path,
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = paths.joined(separator: ":")
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

        child.terminationHandler = { terminated in
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
        // 先让后端自己收子进程，超时再强杀，避免留下监听端口。
        for _ in 0..<30 {
            if !child.isRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(child.processIdentifier, SIGKILL)
    }
}

// MARK: - 退出兜底

private var childPID: pid_t = 0
private var signalSources: [DispatchSourceSignal] = []

/// 用 kill/pkill 结束壳时，默认处置会直接带走进程而不管后端。这里接管 SIGTERM
/// 与 SIGINT：先收掉后端子进程再退出，避免留下没人认领的监听端口。
/// 正常退出（⌘Q、关窗）走 applicationShouldTerminate，不经过这里。
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

private func writeLine(_ handle: FileHandle?, _ text: String) {
    guard let handle, let data = text.data(using: .utf8) else { return }
    try? handle.write(contentsOf: data)
}

/// 壳自己那一侧的诊断日志（后端原始输出也写同一个文件）。
///
/// 必须先 seek 到末尾：`FileHandle(forWritingTo:)` 的游标停在 0，不挪就是从文件头
/// 开始覆盖，把先前的日志（连后端的输出一起）整段冲掉——「检查更新」到底查到什么，
/// 原本就是这么查不到的。
func shellLog(_ text: String) {
    guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[shell] \(text)\n".utf8))
    } catch {
        // 日志写不进去就算了，不该影响主流程。
    }
}

// MARK: - 壳控制器

final class ShellController: NSObject, WKNavigationDelegate, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var backend: Backend?
    private var currentURL: URL?
    private var navigationRetries = 0
    private var workspaceOverride: String?
    private var isShuttingDown = false

    static let shared = ShellController()

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        boot()
        // DSHX_AUTO_CHECK_UPDATE=1：启动 3 秒后自动跑一次「检查更新」。默认不开
        // （每次启动白给一次网络请求；用户要的是手动点）。留它是为了拿假更新源
        // 演练整条更新链路——平时碰不到更新，出事偏偏又最难查、最难复现。
        if envString("DSHX_AUTO_CHECK_UPDATE") == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UpdateController.shared.check()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isShuttingDown = true
        backend?.stop()
        return .terminateNow
    }

    private func boot() {
        switch resolvePlan(workspaceOverride: workspaceOverride) {
        case .failure(let message):
            presentFailure(message)
        case .success(let plan):
            presentBootPage("node  \(plan.node.path)\nentry \(plan.entry.path)\n"
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
        loadPage(url, attempt: 1)
    }

    /// 后端打印地址时 socket 只是刚 bind，未必已经能服务。先探一次再交给 WebView，
    /// 避免第一个请求被拒之后整个窗口停在错误页上。
    private func loadPage(_ url: URL, attempt: Int) {
        guard !isShuttingDown else { return }
        probePage(url) { [weak self] ready in
            guard let self, !self.isShuttingDown else { return }
            if ready {
                shellLog("第 \(attempt) 次探测通过，交给 WebView 载入")
                self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 30))
            } else if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.loadPage(url, attempt: attempt + 1)
                }
            } else {
                self.reportDeath("后端给出了服务地址，但 6 秒内没有响应任何请求。")
            }
        }
    }

    /// 带 token 的 GET：拿到 2xx/3xx 就说明 HTTP 层与鉴权链路都通。
    /// 这个 token 是进程级凭据（不是单次消费），探测不会把它用掉。
    private func probePage(_ url: URL, completion: @escaping (Bool) -> Void) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 1.5)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ready = (200...399).contains(status) && data?.isEmpty == false
            DispatchQueue.main.async { completion(ready) }
        }.resume()
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

    // MARK: 界面

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appTitle
        window.isReleasedWhenClosed = false
        // 不做 frame autosave，也不照这个下手排查过：那两次 126x128 / 126x143 的
        // 「窗口变小」其实是台前调度（Stage Manager）左侧缩略图的几何，被
        // CGWindowListCopyWindowInfo 当成了窗口尺寸。这里只是顺手收紧尺寸约束。
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if !pageScrollAllowed {
            configuration.userContentController.addUserScript(WKUserScript(
                source: fixedShellGuardScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        // 默认关：放大后整页可四下拖动，就是「整个 App 能滚」的那个现象。
        webView.allowsMagnification = pinchZoomEnabled
        if #available(macOS 13.3, *) { webView.isInspectable = true }
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
          .card{max-width:46rem;padding:1.6rem 1.9rem;border:1px solid #2b3138;border-radius:10px;background:#171b21}
          h1{font:600 14px/1.4 -apple-system,system-ui,sans-serif;margin:0 0 .9rem}
          pre{margin:0;white-space:pre-wrap;word-break:break-all;opacity:.75}
        </style>
        <div class="card"><h1>dshX · 正在启动后端（首次约 10–30 秒）</h1><pre>\(escapeHTML(detail))</pre></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// 只服务于启动页那一小段调试文本；& 必须先替换。
    private func escapeHTML(_ text: String) -> String {
        var result = text
        for (character, entity) in [("&", "amp"), ("<", "lt"), (">", "gt")] {
            result = result.replacingOccurrences(of: character, with: "&" + entity + ";")
        }
        return result
    }

    // MARK: WKNavigationDelegate —— 只留在回环地址内

    func webView(_ view: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel); return
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

    /// 载入失败不静默：重试三次，仍失败就把话说清楚并给出出口。
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

    // MARK: 菜单动作

    @objc func reloadPage() {
        guard let url = currentURL else { restartBackend(); return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: 30))
    }

    @objc func restartBackend() {
        isShuttingDown = false
        currentURL = nil
        window.title = appTitle
        backend?.stop()
        boot()
    }

    /// 插件市场窗口（market.swift）。目录数据面是 npm 的 dsh-bundle 生态，
    /// 执行面与手敲 `dsh plugin add` 完全一致；安装成功后的重启从这里回来。
    @objc func openMarket() {
        MarketController.shared.show()
    }

    /// WebKit 没有公开的「打开 Web Inspector」API；已开 developerExtrasEnabled，
    /// 页面里右键 → Inspect Element 可用。这里改为拷贝带 token 的后端地址。
    @objc func copyServerURL() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func openInBrowser() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "以此目录重启后端"
        panel.message = "dsh 的工作目录：工具与文件操作的默认根目录"
        panel.directoryURL = URL(fileURLWithPath: workspaceOverride
            ?? stateDirectory.appendingPathComponent("workspace").path)
        guard panel.runModal() == .OK, let directory = panel.url?.path else { return }
        workspaceOverride = directory
        restartBackend()
    }

    // MARK: 上游更新

    /// 「检查更新」＝查 GitHub Releases 上有没有更新版的 dshX，然后弹窗让人决定。
    /// 有新版时选「更新并重启」会下载 DMG、校验、换掉整个 .app 再重开（细节见
    /// updater.swift）；这条链路不需要本机有源码或 npm。
    @objc func checkForUpdate() {
        UpdateController.shared.check()
    }

    @objc func openReleasesPage() {
        UpdateController.shared.openReleasesPage()
    }

    /// 开发机链路：在终端里跑 `update.sh update`，改的是仓库 runtime/ 里的
    /// @deepseek-ai/dsh 并重打包。真正换后端无法由页面完成，必须在 App 外部执行。
    @objc func updateUpstream() {
        guard let script = findUpdateScript() else {
            presentManualFallback(
                "没有检测到 update.sh",
                "更新 dsh 依赖要在 App 外部做：改 runtime/、重跑 make-app.sh 重建 .app，再重开。"
                + "设 DSH_UPDATE_SCRIPT=/路径/update.sh，或用带 shell/update.sh 的仓库工作目录启动 App，即可一键触发。",
                command: "cd <dsh-app>/shell && ./update.sh update")
            return
        }
        shellLog("一键更新：bash \(script) update")
        openInTerminal("bash '\(script)' update")
    }

    @objc func copyUpdateCommand() {
        let command = "cd <dsh-app>/shell && ./update.sh check"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

// MARK: - 上游更新（dsh 版本）

private let dshPackageName = "@deepseek-ai/dsh"

/// 读出当前实际运行的 dsh 版本：先查随 App 交付的私有 runtime，再查工作目录里
/// 的仓库 runtime。读不到返回 nil（菜单据此显示「版本未知」）。
private func currentDshVersion() -> String? {
    let fm = FileManager.default
    let resources = Bundle.main.resourceURL
        ?? URL(fileURLWithPath: "/nonexistent")
    var candidates = [
        resources.appendingPathComponent("runtime/node_modules/\(dshPackageName)/package.json").path,
    ]
    if let workspace = envString("DSH_APP_WORKSPACE"), !workspace.isEmpty {
        candidates.append(workspace + "/runtime/node_modules/\(dshPackageName)/package.json")
    }
    for path in candidates {
        guard let data = fm.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { continue }
        // 顶层第一个 "version": "x.y.z"（package.json 的 name 之后紧跟 version）。
        guard let range = text.range(of: "\"version\"") else { continue }
        let tail = text[range.upperBound...]
        guard let q1 = tail.firstIndex(of: "\"") else { continue }
        let after = tail[tail.index(after: q1)...]
        guard let q2 = after.firstIndex(of: "\"") else { continue }
        let version = String(after[after.startIndex..<after.index(before: q2)])
        if !version.isEmpty { return version }
    }
    return nil
}

func envString(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
}

/// 找到 update.sh。顺序：环境变量 DSH_UPDATE_SCRIPT → 私有目录下的一份
/// → 记录在 update-script.txt 里的路径 → 工作目录/当前目录里的 shell/update.sh。
/// 返回能执行到的那个绝对路径，找不到返回 nil。
private func findUpdateScript() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let override = envString("DSH_UPDATE_SCRIPT"), !override.isEmpty {
        candidates.append(override)
    }
    candidates.append(stateDirectory.appendingPathComponent("update.sh").path)
    if let data = fm.contents(atPath: stateDirectory.appendingPathComponent("update-script.txt").path),
       let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        candidates.append(text)
    }
    if let workspace = envString("DSH_APP_WORKSPACE"), !workspace.isEmpty {
        candidates.append(workspace + "/shell/update.sh")
        candidates.append(workspace + "/update.sh")
    }
    for path in candidates where fm.isExecutableFile(atPath: path) { return path }
    return nil
}

/// 在一个新的终端窗口里跑给定命令。用 `open` 打开临时 .command 文件，走的是
/// LaunchServices，不触发 Apple Events（那在这个环境里被权限拦）。没有终端或
/// 打开失败时返回 false，调用方退回到「拷贝命令」。
@discardableResult
private func openInTerminal(_ command: String) -> Bool {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dshX-update", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("update-\(Int(Date().timeIntervalSince1970)).command")
    // 末尾保留交互：命令结束后不立刻关窗，方便看日志、看 y/N 提示。
    let body = "#!/bin/bash\n\(command)\necho\necho \"［按任意键关闭］\"; read -rsn1\n"
    guard (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil else { return false }
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-a", "Terminal", file.path]
    let pipe = Pipe()
    opener.standardError = pipe
    do {
        try opener.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        opener.waitUntilExit()
        if opener.terminationStatus == 0 { return true }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            shellLog("打开终端失败：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } catch {
        shellLog("打开终端失败：\(error.localizedDescription)")
    }
    return false
}

/// 弹一个能读的解释框，并把命令写进剪贴板，方便粘到任意终端手跑。
private func presentManualFallback(_ title: String, _ detail: String, command: String) {
    DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = detail + "\n\n已把命令复制到剪贴板：\n\(command)"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 菜单装配

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
    add(appMenu, "隐藏 \(appTitle)", #selector(NSApplication.hide(_:)), "h")
    appMenu.addItem(.separator())
    add(appMenu, "退出 \(appTitle)", #selector(NSApplication.terminate(_:)), "q")

    let fileMenu = addSection("文件", to: menu)
    add(fileMenu, "选择工作目录并重启后端…", #selector(ShellController.chooseWorkspace), "o")
    add(fileMenu, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")

    let editMenu = addSection("编辑", to: menu)
    add(editMenu, "撤销", Selector(("undo:")), "z")
    add(editMenu, "重做", Selector(("redo:")), "Z")
    editMenu.addItem(.separator())
    add(editMenu, "剪切", #selector(NSText.cut(_:)), "x")
    add(editMenu, "拷贝", #selector(NSText.copy(_:)), "c")
    add(editMenu, "粘贴", #selector(NSText.paste(_:)), "v")
    add(editMenu, "全部选中", #selector(NSText.selectAll(_:)), "a")

    let viewMenu = addSection("查看", to: menu)
    add(viewMenu, "重新载入", #selector(ShellController.reloadPage), "r")
    add(viewMenu, "重启后端", #selector(ShellController.restartBackend), "r", [.command, .shift])
    add(viewMenu, "拷贝后端地址（含 token）", #selector(ShellController.copyServerURL), "c", [.command, .shift])
    add(viewMenu, "在默认浏览器中打开", #selector(ShellController.openInBrowser), "b", [.command, .shift])

    // 「更新」有两条链路，别混：
    //   1. 检查更新…：查 GitHub Releases（dshX 仓库）有没有更新版的 App，弹窗选
    //      「更新并重启 / 取消」。装好的 App 走这条，不需要源码与 npm。
    //   2. 更新后端 dsh…：开发机链路，打开终端跑仓库里的 update.sh，改 runtime/
    //      里的 @deepseek-ai/dsh 再重打包。找不到脚本时退回「复制命令」。
    let updateMenu = addSection("更新", to: menu)
    let currentLine = "当前 dshX \(currentAppVersion()) · 后端 dsh \(currentDshVersion() ?? "未知")"
    let info = updateMenu.addItem(withTitle: currentLine, action: nil, keyEquivalent: "")
    info.isEnabled = false
    updateMenu.addItem(.separator())
    add(updateMenu, "检查更新…", #selector(ShellController.checkForUpdate), "u")
    add(updateMenu, "在浏览器里打开 Releases 页", #selector(ShellController.openReleasesPage), "")
    updateMenu.addItem(.separator())
    add(updateMenu, "更新后端 dsh（终端跑 update.sh）…",
        #selector(ShellController.updateUpstream), "u", [.command, .shift])
    add(updateMenu, "拷贝更新命令", #selector(ShellController.copyUpdateCommand), "")

    // 「插件」：dsh 的插件分发面就是 npm（上游约定的标记是 `dsh-plugin`），安装链路
    // 与手敲 `dsh plugin add` 完全一致，数据源与细节见 market.swift。
    let pluginMenu = addSection("插件", to: menu)
    add(pluginMenu, "插件市场…", #selector(ShellController.openMarket), "p", [.command, .shift])

    let windowMenu = addSection("窗口", to: menu)
    add(windowMenu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(windowMenu, "缩放", #selector(NSWindow.performZoom(_:)), "")
    NSApp.windowsMenu = windowMenu
    return menu
}

// MARK: - 入口

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = ShellController.shared
installShutdownSignalNet()
application.mainMenu = buildMainMenu()
application.run()