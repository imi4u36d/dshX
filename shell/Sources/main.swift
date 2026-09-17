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
   - 外观上是原生 App 不是浏览器：右键菜单只留文本编辑那几项（检查元素 / 翻译 /
     查询 / 搜索 / 分享 / 朗读这些一律不出），标题栏（红绿灯那一条）跟着页面主题
     走，不在顶上留一条异色。细节见下面「原生外观」一节。
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

// MARK: - 原生外观：右键菜单与标题栏
//
// 两件「像网页」的事在这里收掉：
//   1. 右键菜单。WebKit 会奉上一整套浏览器菜单——检查元素、翻译、查询、用某引擎
//      搜索、分享、朗读、重新载入……这个壳是原生 App，只该留文本编辑那几项。
//   2. 标题栏。红绿灯那一条默认是系统材质色，浮在深色/浅色页面顶上就是一条接缝。
//      把标题栏做成透明、再让窗口背景色跟着页面底色走，两者同色。
//
// 页面主题由它自己的 ui-theme 设置决定（light / dark / system），跟系统外观不一定
// 一致，所以底色得由页面报上来（见 themeBridgeScript）。刻意不动 window.appearance：
// 页面里的 `prefers-color-scheme` 取的就是这个视图的外观，一动它就等于改了页面
// 「跟随系统」的解析结果，会把 ui-theme 的 system 卡死在我们设的那一档。
//
// 排查开关：
//   DSHX_ALLOW_WEB_MENU=1          恢复网页全套右键菜单，并打开 developerExtrasEnabled
//                                  与 isInspectable（要用 Web Inspector 就靠它）
//   DSHX_CAPTURE_WINDOW=<png 路径> 页面载入后把窗口自身抓一张图；进程内抓自己的
//                                  窗口不需要「屏幕录制」权限，核对标题栏配色用它
private let webContextMenuAllowed = ProcessInfo.processInfo.environment["DSHX_ALLOW_WEB_MENU"] == "1"

/// 页面回报主题用的消息名：注入脚本与 WKScriptMessageHandler 必须一致。
private let themeMessageName = "dshxTheme"

/// 过滤后允许留在右键菜单里的标题。
/// WebKit 的条目**全部**共用 `forwardContextMenuAction:`（实测 "Reload"、"Inspect
/// Element"、"Cut"、"Translate" 都是这一个 selector），按 selector 根本分不出谁是谁，
/// 只能按标题认；而标题会跟系统语言变（同一台机器上中英混着来），所以中英两套都列，
/// 认不出来的一律丢掉——将来系统加了什么新条目也不会漏出来。留下的都是原生文本编辑动作。
private let nativeEditMenuTitles: Set<String> = [
    "cut", "copy", "paste", "delete", "select all", "paste and match style",
    "剪切", "拷贝", "复制", "粘贴", "删除", "全选", "粘贴并匹配样式",
]

/// 右键落在「能编辑或已有选区」的地方才让 WebKit 弹它自己的菜单，其余一律取消。
/// WebKit 只在页面没取消 contextmenu 时才弹原生菜单，所以这一下就把链接 / 图片 /
/// 空白处的浏览器菜单挡在门外，也就不会出现「白名单筛完一项不剩」的空菜单盒子。
/// 页面自己的右键菜单不受影响：ui-primitives 那几个 onContextMenu 本来就 preventDefault
/// 之后自己弹 UI（JsonTree 的拷贝菜单、dockkit 的页签菜单），取消默认动作不影响它们。
private let contextMenuGuardScript = """
(function () {
  function editable(event) {
    var path = (event.composedPath && event.composedPath()) || [event.target];
    for (var i = 0; i < path.length; i++) {
      var node = path[i];
      if (!node || node.nodeType !== 1) { continue; }
      var tag = (node.tagName || '').toUpperCase();
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') { return true; }
      if (node.isContentEditable) { return true; }
    }
    return false;
  }
  function hasSelection() {
    try {
      var selection = window.getSelection();
      return !!(selection && !selection.isCollapsed && String(selection).length > 0);
    } catch (error) { return false; }
  }
  window.addEventListener('contextmenu', function (event) {
    if (editable(event) || hasSelection()) { return; }
    event.preventDefault();
  }, true);
})();
"""

/// 页面主题 → 原生窗口的消息。页面那边 ui-theme 会把主题投影到 DOM 上：
/// `html { color-scheme }`、`body[data-ds-dark-theme]`、body 内联的主题 token，
/// 另外 ThemePresenter 还会维护一个 `meta[name="theme-color"]`（内容就是它算出来的
/// body 底色）。这里优先读那个 meta，其次自己算 body 底色，最后退到 `--dsw-alias-bg-base`；
/// 都读不到就报空串，原生侧会忽略这一次（窗口底色保持不动）。主题变化（切 light/dark/system、
/// 跟着系统变）靠 MutationObserver + matchMedia 监听重报。
private let themeBridgeScript = """
(function () {
  var name = '\(themeMessageName)';
  function readBackground() {
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta && meta.content) { return meta.content; }
    var body = document.body;
    if (!body) { return ''; }
    var computed = getComputedStyle(body);
    var color = computed.backgroundColor;
    if (!color || color === 'rgba(0, 0, 0, 0)' || color === 'transparent') {
      color = (computed.getPropertyValue('--dsw-alias-bg-base') || '').trim();
    }
    return color || '';
  }
  function report() {
    var root = document.documentElement;
    var scheme = root && root.style ? root.style.colorScheme : '';
    var dark = scheme
      ? scheme === 'dark'
      : !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
    try {
      window.webkit.messageHandlers[name].postMessage({ dark: dark, background: readBackground() });
    } catch (error) { /* 原生侧还没就绪；后面 DOMContentLoaded / load 还会再报 */ }
  }
  report();
  document.addEventListener('DOMContentLoaded', report);
  window.addEventListener('load', report);
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  if (media && media.addEventListener) { media.addEventListener('change', report); }
  if (window.MutationObserver) {
    new MutationObserver(report)
      .observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
    document.addEventListener('DOMContentLoaded', function () {
      if (!document.body) { return; }
      new MutationObserver(report)
        .observe(document.body, { attributes: true, attributeFilter: ['style', 'data-ds-dark-theme'] });
      report();
    });
  }
})();
"""

/// 启动页底色。HTML 与窗口标题栏共用一份：`loadHTMLString` 载入的启动页拿不到
/// 主题桥（WKUserScript 不进这种载入），标题栏只能由壳自己按这个色设，不然后端
/// 起来前那几十秒顶上还是一条系统材质色压在深色启动页上——同一个接缝，只是时间短。
private let bootPageBackgroundCSS = "#111418"
private let bootPageBackground = NSColor(srgbRed: 17 / 255, green: 20 / 255,
                                         blue: 24 / 255, alpha: 1)

/// 解析页面回报的 CSS 颜色（`rgb()` / `rgba()` / `#rrggbb`）。
/// 全透明（alpha≈0）按「没报」处理，交给调用方兜底。
func parseCSSColor(_ text: String) -> NSColor? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("#") {
        var hex = String(value.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count >= 6, let number = UInt32(hex.prefix(6), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((number >> 16) & 0xff) / 255,
                       green: CGFloat((number >> 8) & 0xff) / 255,
                       blue: CGFloat(number & 0xff) / 255, alpha: 1)
    }
    let numbers = value.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
    guard numbers.count >= 3 else { return nil }
    let alpha = numbers.count >= 4 ? numbers[3] : 1
    guard alpha > 0.01 else { return nil }
    return NSColor(srgbRed: CGFloat(numbers[0] / 255), green: CGFloat(numbers[1] / 255),
                   blue: CGFloat(numbers[2] / 255), alpha: 1)
}

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
        // Contents/Resources/tools/bin，`dsh plugin` 的安装链路靠 execvp('pnpm') 找它。
        // 图形界面启动不继承终端 PATH，本机也没有 npm/corepack，漏掉这一项
        // 内置 pnpm 就形同虚设，插件安装一律报「找不到 npm/corepack」。
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

/// 往日志文件追加一段。**每条都先 seek 到末尾**：`FileHandle(forWritingTo:)` 的游标
/// 停在 0，不挪就是从文件头开始覆盖，把先前的日志（连后端的输出一起）整段冲掉——
/// 「检查更新」到底查到什么，原本就是这么查不到的。这个坑当初只修了 `shellLog`，
/// 后端那两条管道（stdout/stderr 各一个 readabilityHandler，各在自己的线程上写同一个
/// handle）还在冲掉文件开头：一次启动的 header 会盖住上一次的记录。锁 + 每条 seek
/// 一起上，才算把「日志是追加的」这件事做对。
private let logWriteLock = NSLock()

private func writeLine(_ handle: FileHandle?, _ text: String) {
    guard let handle, let data = text.data(using: .utf8) else { return }
    logWriteLock.lock()
    defer { logWriteLock.unlock() }
    try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

/// 壳自己那一侧的诊断日志（后端原始输出也写同一个文件）。
func shellLog(_ text: String) {
    guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
    defer { try? handle.close() }
    writeLine(handle, "[shell] \(text)\n")
}

// MARK: - 原生外观（WebView / 主题桥）

/// 只承载页面的 WKWebView：把网页式右键菜单拦在原生这一侧。
final class ShellWebView: WKWebView {
    /// WebKit 弹菜单前会走这里：先跑 `super`（别打断它自己的记账），再把菜单重排成白名单。
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard !webContextMenuAllowed else { return }
        let keep = menu.items.filter { item in
            !item.isSeparatorItem
                && nativeEditMenuTitles.contains(item.title.trimmingCharacters(in: .whitespaces).lowercased())
        }
        // 整个清空、再按原顺序放回：分隔线一起丢掉（删剩下的分隔线还会撑出一格空段）。
        // 既不能编辑又没有选区时，注入脚本已经不让 WebKit 弹菜单了，所以这里不会
        // 出现「一项都不剩」的空盒子；真剩 0 项也照旧清空——宁可没有菜单，也不给网页菜单。
        menu.removeAllItems()
        for item in keep { menu.addItem(item) }
    }
}

/// 页面主题 → 窗口外观。单独一个类：WKUserContentController 会强引用 handler，
/// 让它直接持 ShellController 就成了循环引用。
final class ThemeBridge: NSObject, WKScriptMessageHandler {
    weak var controller: ShellController?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        self.controller?.applyPageTheme(dark: payload["dark"] as? Bool ?? false,
                                        background: payload["background"] as? String)
    }
}

// MARK: - 壳控制器

final class ShellController: NSObject, WKNavigationDelegate, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: ShellWebView!
    private var backend: Backend?
    private var currentURL: URL?
    private var navigationRetries = 0
    private var workspaceOverride: String?
    private var isShuttingDown = false
    /// 上一次页面报上来的底色，用来避免同一档主题重复写日志。
    private var lastReportedBackground: String?
    /// DSHX_CAPTURE_WINDOW 只抓一次。
    private var capturedWindow = false

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
        // 标题栏透明：那一条底色就由窗口背景色决定，而背景色跟着页面底色走
        // （见 applyPageTheme）。不隐藏标题文字的话，「dshX — 127.0.0.1:端口」
        // 会直接压在页面顶部的内容上。刻意不加 .fullSizeContentView：那会让
        // 页面顶到红绿灯底下（侧栏第一行控件正好在左上角），得反过来给页面让位。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // 「开发者附加功能」默认关：它就是右键里那项 Inspect Element 的来源
        // （实测关掉后 WebKit 自己就不再往菜单里加这一项），isInspectable 同理。
        // 要用 Web Inspector 排查页面时给 DSHX_ALLOW_WEB_MENU=1。
        configuration.preferences.setValue(webContextMenuAllowed, forKey: "developerExtrasEnabled")
        let contentController = configuration.userContentController
        contentController.addUserScript(WKUserScript(source: themeBridgeScript,
                                                     injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: true))
        if !webContextMenuAllowed {
            // 子框架也要注入：菜单是每个框架各弹各的，漏了 iframe 就等于漏了菜单。
            contentController.addUserScript(WKUserScript(source: contextMenuGuardScript,
                                                         injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: false))
        }
        let bridge = ThemeBridge()
        bridge.controller = self
        contentController.add(bridge, name: themeMessageName)
        if !pageScrollAllowed {
            contentController.addUserScript(WKUserScript(
                source: fixedShellGuardScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }
        let webView = ShellWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        // 默认关：放大后整页可四下拖动，就是「整个 App 能滚」的那个现象。
        webView.allowsMagnification = pinchZoomEnabled
        if #available(macOS 13.3, *) { webView.isInspectable = webContextMenuAllowed }
        self.webView = webView

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentBootPage(_ detail: String) {
        // 标题栏是透明的，先把窗口背景设成启动页那个色，顶上才不会有第二条色。
        window.backgroundColor = bootPageBackground
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="dark light">
        <style>
          body{margin:0;height:100vh;display:grid;place-items:center;background:\(bootPageBackgroundCSS);color:#c9d1d9;
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
        captureWindowIfRequested()
    }

    // MARK: 原生外观

    /// 页面报上来的主题：标题栏是透明的，透出来的就是窗口背景色，所以两者必须同色。
    ///
    /// 只改背景色，不动 `window.appearance`：页面里 `prefers-color-scheme` 取的就是
    /// 这个视图的外观，一改就等于替页面把「跟随系统」解析成了我们设的那一档，
    /// ui-theme 的 system 会卡住。系统材质色（菜单、弹窗）继续跟系统，页面自己一套，
    /// 这是有意的取舍。
    func applyPageTheme(dark: Bool, background: String?) {
        // 页面还没报出底色（documentStart 时 body 还没建）就什么都不做：这里若退回
        // 系统窗口底色，「深色启动页 → 真页面」之间会在标题栏闪一下浅色。
        guard let background, let color = parseCSSColor(background) else { return }
        if window.backgroundColor != color { window.backgroundColor = color }
        guard background != lastReportedBackground else { return }
        lastReportedBackground = background
        shellLog("页面主题：\(dark ? "dark" : "light")，标题栏底色 \(background)")
    }

    /// DSHX_CAPTURE_WINDOW=<png 路径>：页面载入后把窗口自身抓一张图，只抓一次。
    /// 进程内抓自己的窗口不需要「屏幕录制」权限（抓别的窗口才需要），核标题栏
    /// 那条底色有没有跟页面一致就靠它。启动页（后端还没就绪）不算，等真页面。
    private func captureWindowIfRequested() {
        guard !capturedWindow, currentURL != nil,
              let path = envString("DSHX_CAPTURE_WINDOW"), !path.isEmpty else { return }
        capturedWindow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                      CGWindowID(self.window.windowNumber),
                                                      [.boundsIgnoreFraming]),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else {
                shellLog("窗口截图失败：\(path)")
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                shellLog("窗口截图已写出：\(path)")
            } catch {
                shellLog("窗口截图写不出去：\(error.localizedDescription)")
            }
        }
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

    /// WebKit 没有公开的「打开 Web Inspector」API，本壳默认也没开开发者附加功能
    /// （页面里右键那项 Inspect Element 已经不出）；临时要排查页面就给
    /// DSHX_ALLOW_WEB_MENU=1。这里留给菜单的动作是拷贝带 token 的后端地址。
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
}

// MARK: - 环境变量

func envString(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
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
    // 「检查更新…」按 macOS 惯例挨着「关于」放：它换的是整个 .app（后端跟着一起换），
    // 与开发机链路的 update.sh 不是一回事，那条链路已经不在菜单里了。
    add(appMenu, "检查更新…", #selector(ShellController.checkForUpdate), "u")
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