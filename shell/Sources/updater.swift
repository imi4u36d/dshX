import AppKit
import CryptoKit

/*
 dshX 自更新：查 GitHub Releases → 比版本 → 下载 DMG → 校验 SHA-256 → 换包重启。

 跟开发机链路的 `update.sh`（改**仓库里** runtime/ 的 @deepseek-ai/dsh 再重打包）不同，
 这里面向「已经装好的 App」：把整个 .app 换掉。DMG 里带着内置 Node 与整个
 runtime，后端也跟着一起换；本机不需要源码、npm 或 Xcode。

 数据来源是 dshX 仓库自己的 Releases（打 tag 时 CI 把 DMG 与 .sha256 挂上去，见
 .github/workflows/release-dmg.yml）。匿名读即可，未认证 API 限流 60 次/小时，
 手动点着用不完；真被限流了给 App 设 DSH_GITHUB_TOKEN 就能绕过。

 换包本身在 App 外面执行（shell/updater/apply-update.sh）：正在跑的后端就是从被替换
 的那份包里 mmap 出来的文件，让 App 自己覆盖自己只会把当前会话连根拔起。

 分成两层：UpdateEngine 只做事不画界面，UpdateController 负责弹窗与进度条。
 命令行工具 tools/update-check-test.swift 复用同一个引擎，所以「有更新吗」这件事
 只有一套判断，界面上的和测试里跑的不会各说各话。
 */

// MARK: - 配置

private let defaultUpdateFeedURL = "https://api.github.com/repos/imi4u36d/dshX/releases?per_page=30"

/// 更新源。DSH_UPDATE_FEED_URL 可指向镜像或本地 mock（排查用；ATS 已放行任意源）。
func updateFeedURL() -> String {
    if let override = envString("DSH_UPDATE_FEED_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
        return override
    }
    return defaultUpdateFeedURL
}

/// 当前版本：默认读 Info.plist。DSH_UPDATE_FAKE_VERSION 可临时改口径——想预览
/// 「有新版」那个弹窗、或者拿假包演练整条链路时用它，正常用不着。
func currentAppVersion() -> String {
    if let override = envString("DSH_UPDATE_FAKE_VERSION")?
        .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
        return override
    }
    return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "未知"
}

/// 要替换的目标包。默认就是「正在跑的这份」，源码直跑时也能用。
func updateTargetApp() -> String {
    if let override = envString("DSH_UPDATE_TARGET"), !override.isEmpty { return override }
    let bundle = Bundle.main.bundlePath
    if bundle.hasSuffix(".app") { return bundle }
    return "/Applications/\(appTitle).app"
}

// MARK: - 数据形状

/// 一个 Release 里可用的安装包。
struct UpdatePackage {
    let name: String
    let url: String
    let size: Int64
    let digest: String?       // GitHub 资产自带的 "sha256:…"
    let sidecarURL: String?   // 同名 .sha256 资产
}

struct ReleaseInfo {
    let tag: String
    let version: String
    let htmlURL: String
    let prerelease: Bool
    let assets: [(name: String, url: String, size: Int64, digest: String?)]
}

enum UpdateCheck {
    case upToDate(current: String, latest: String?)
    case available(ReleaseInfo, UpdatePackage)
    case failure(String)
}

// MARK: - 纯函数：版本比较 / 解析 / 选型（tools/update-check-test 测的就是这几个）

/// 从 tag 或文件名里捞出第一个像版本号的东西：`v0.1.1`、`dshX-0.2.0-arm64.dmg` 都认。
func extractVersion(_ text: String) -> String? {
    guard let pattern = try? NSRegularExpression(
        pattern: #"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.]+)?"#) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pattern.firstMatch(in: text, range: range),
          let found = Range(match.range, in: text) else { return nil }
    return String(text[found])
}

private func splitVersion(_ version: String) -> (core: [Int], pre: [String]) {
    // 先剥掉 build metadata（`+` 后面那截）：语义化版本里它不参与新旧比较，
    // update.sh 的 awk 也是直接当它不存在。不剥的话 "2+build.5" 会被当成一段。
    let main = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
    let parts = main.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
    let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    return (core, pre)
}

/// a 相对 b 的新旧。规则与 update.sh 里那段 awk 一致，连预发布的坑一起照抄：
/// 三段主版本按数字比；`1.2.3` 比 `1.2.3-rc.1` 新；预发布段里数字比字母小。
func versionOrder(_ a: String, _ b: String) -> ComparisonResult {
    let left = splitVersion(a)
    let right = splitVersion(b)
    for index in 0..<3 {
        let x = index < left.core.count ? left.core[index] : 0
        let y = index < right.core.count ? right.core[index] : 0
        if x != y { return x > y ? .orderedDescending : .orderedAscending }
    }
    if left.pre.isEmpty && right.pre.isEmpty { return .orderedSame }
    if left.pre.isEmpty { return .orderedDescending }
    if right.pre.isEmpty { return .orderedAscending }
    for index in 0..<min(left.pre.count, right.pre.count) {
        let x = left.pre[index]
        let y = right.pre[index]
        if x == y { continue }
        if let xNumber = Int(x), let yNumber = Int(y) {
            if xNumber != yNumber {
                return xNumber > yNumber ? .orderedDescending : .orderedAscending
            }
        } else if Int(x) != nil {
            return .orderedAscending      // 数字段 < 字母段
        } else if Int(y) != nil {
            return .orderedDescending
        } else if x != y {
            return x > y ? .orderedDescending : .orderedAscending
        }
    }
    if left.pre.count != right.pre.count {
        return left.pre.count > right.pre.count ? .orderedDescending : .orderedAscending
    }
    return .orderedSame
}

func parseReleases(_ data: Data) -> [ReleaseInfo] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return []
    }
    return root.compactMap { item in
        guard let tag = item["tag_name"] as? String, !tag.isEmpty,
              let version = extractVersion(tag) else { return nil }
        let assets: [(name: String, url: String, size: Int64, digest: String?)] =
        (item["assets"] as? [[String: Any]] ?? []).compactMap { asset in
            guard let name = asset["name"] as? String,
                  let url = asset["browser_download_url"] as? String, !url.isEmpty else { return nil }
            let size = (asset["size"] as? Int64) ?? Int64((asset["size"] as? Double) ?? 0)
            let digest = (asset["digest"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, url, max(size, 0), (digest?.hasPrefix("sha256:") ?? false) ? digest : nil)
        }
        return ReleaseInfo(tag: tag, version: version,
                           htmlURL: (item["html_url"] as? String) ?? "",
                           prerelease: (item["prerelease"] as? Bool) ?? false,
                           assets: assets)
    }
}

/// 这个 Release 里有没有适配本机架构的 DMG。DMG 是单架构产物（README「已知限制」），
/// 拿错架构的包装上也是白装，所以宁可说清楚。
func pickPackage(in release: ReleaseInfo, arch: String) -> UpdatePackage? {
    let dmgs = release.assets.filter { $0.name.hasSuffix(".dmg") }
    guard !dmgs.isEmpty else { return nil }
    let matched = dmgs.filter { $0.name.contains("-\(arch).") || $0.name.contains(".\(arch).") }
    let chosen = matched.first
        ?? dmgs.first { !$0.name.contains("arm64") && !$0.name.contains("x86_64") }
    guard let asset = chosen else { return nil }
    let sidecar = release.assets.first { $0.name == asset.name + ".sha256" }?.url
    return UpdatePackage(name: asset.name, url: asset.url, size: asset.size,
                         digest: asset.digest, sidecarURL: sidecar)
}

/// 从 Releases 里挑「比当前新的最高版本」，并配一个本机能装的包。
func resolveUpdate(data: Data, current: String, arch: String,
                   includePrerelease: Bool) -> UpdateCheck {
    let releases = parseReleases(data)
    guard !releases.isEmpty else {
        return .failure("更新源返回的内容里没有能认出的 Release 条目"
            + "（限流页、镜像换了格式、或地址被 DSH_UPDATE_FEED_URL 改坏了都会这样）。")
    }
    let latest = releases.map(\.version).max()
    // 全是预发布：宁可什么都不做，也别把稳定版换成 rc。
    var candidates = releases.filter { !$0.prerelease || includePrerelease }
    candidates = candidates.filter { versionOrder($0.version, current) == .orderedDescending }
    guard !candidates.isEmpty else { return .upToDate(current: current, latest: latest) }
    candidates.sort { versionOrder($0.version, $1.version) == .orderedDescending }
    let best = candidates[0]
    if let package = pickPackage(in: best, arch: arch) {
        return .available(best, package)
    }
    return .failure("最新是 \(best.tag)，但那个 Release 里没有 \(arch) 用的 .dmg。"
        + "要么这个版本没发本架构的包，要么只能手动换（见 shell/README.md）。")
}

// MARK: - 引擎（只做事，不画界面）

/// 查 / 下 / 校验 / 换包。回调都在主线程，宿主自己决定怎么展示。
final class UpdateEngine: NSObject, URLSessionDownloadDelegate {
    /// 进度文案 + 0~1 的比例（<0 表示不确定）。
    var onProgress: ((String, Double) -> Void)?
    /// 任何「没做成」都要出声，别静默失败。
    var onNotice: ((String) -> Void)?
    /// 检查结论。
    var onCheck: ((UpdateCheck) -> Void)?
    /// 换包脚本已拉起，宿主该退出了（App 退掉，CLI 测试工具等着看结果）。
    var onQuitRequest: (() -> Void)?

    private(set) var checking = false
    private(set) var updating = false
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var expectedHash: String?
    private var downloadName: String?
    private var movedTo: URL?

    private var updatesDirectory: URL {
        stateDirectory.appendingPathComponent("updates", isDirectory: true)
    }

    // MARK: 查

    func check() {
        guard !checking, !updating else {
            onNotice?(updating ? "已经在更新中了。要重来的话先重启 dshX。"
                               : "上一次检查还没回来（20 秒超时），等它先结束。")
            return
        }
        checking = true
        performCheck(reset: { [weak self] in self?.checking = false })
    }

    private func performCheck(reset: @escaping () -> Void) {
        guard let url = URL(string: updateFeedURL()) else {
            reset()
            onNotice?("更新源地址不合法：\(updateFeedURL())")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(appTitle)/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")
        if let token = envString("DSH_GITHUB_TOKEN") ?? envString("GITHUB_TOKEN"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        shellLog("检查更新：GET \(url.absoluteString)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: UpdateCheck
            if let error {
                result = .failure("取不到更新源：\(error.localizedDescription)\n"
                    + "这一步只要一次 GET；离线、代理、DNS 出问题都长这样。")
            } else if status == 403 || status == 429 {
                result = .failure("GitHub API 限流（HTTP \(status)）。"
                    + "给 App 设 DSH_GITHUB_TOKEN=<token> 可以绕过匿名限流。")
            } else if !(200...299).contains(status) {
                result = .failure("更新源返回 HTTP \(status)。")
            } else if let data, !data.isEmpty {
                result = resolveUpdate(data: data, current: currentAppVersion(),
                                       arch: machineArch(),
                                       includePrerelease: envString("DSHX_ALLOW_PRERELEASE") == "1")
            } else {
                result = .failure("更新源返回空内容。")
            }
            DispatchQueue.main.async {
                reset()
                self.onCheck?(result)
            }
        }.resume()
    }

    // MARK: 下 + 校验 + 换

    func start(package: UpdatePackage) {
        guard !updating else {
            onNotice?("已经有一个更新在跑了。")
            return
        }
        updating = true
        expectedHash = nil
        downloadName = package.name
        movedTo = nil

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
            // 清掉上一轮残留：一次 100 多 MB，攒几份就是一个 G。
            for item in (try? fm.contentsOfDirectory(at: updatesDirectory,
                                                     includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "dmg" || item.pathExtension == "part" {
                    try? fm.removeItem(at: item)
                }
            }
        } catch {
            abort("更新目录不可用：\(error.localizedDescription)")
            return
        }
        guard fm.isWritableFile(atPath: updatesDirectory.path) else {
            abort("\(updatesDirectory.path) 不可写。")
            return
        }
        guard isTargetReplaceable() else {
            abort("换不了：\(updateTargetApp()) 不可写。"
                + (updateTargetApp().contains("AppTranslocation")
                   ? "这个 App 是从 DMG 里直接跑的（Gatekeeper 转场保护，跑在只读的随机路径上），"
                     + "把 DMG 里的 dshX.app 拖到「应用程序」里再打开。"
                   : "可能需要管理员权限，或 macOS 14+ 的「App 管理」授权"
                     + "（系统设置 › 隐私与安全性 › App 管理）。"))
            return
        }
        guard findApplyScript() != nil else {
            abort("找不到换包脚本 apply-update.sh（正常应打在 Contents/Resources/updater/ 里）。"
                + "这次只能手动装：下 DMG 拖进 Applications，或从源码重打包。")
            return
        }
        guard let url = URL(string: package.url) else {
            abort("下载地址不合法：\(package.url)")
            return
        }

        // 先把校验值拿到手再下 128 MB：边下边等校验值会有「包先到、哈希后到」的竞态，
        // 而且没有任何校验值的包本来就不该自动装。
        if let digest = package.digest {
            expectedHash = String(digest.dropFirst("sha256:".count)).lowercased()
            startDownload(url: url, package: package)
        } else if let sidecar = package.sidecarURL {
            onProgress?("正在取校验值（.sha256）…", 0)
            fetchSidecar(sidecar) { [weak self] expected in
                guard let self, self.updating else { return }
                guard let expected else {
                    self.abort("这个 Release 既没有资产 digest 也读不到 .sha256，"
                        + "没有校验值就不自动装。")
                    return
                }
                self.expectedHash = expected
                self.startDownload(url: url, package: package)
            }
        } else {
            abort("这个 Release 没有提供任何校验值，不自动安装。")
        }
    }

    private func startDownload(url: URL, package: UpdatePackage) {
        onProgress?("正在下载 \(package.name)（\(sizeText(package.size))）…", 0)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration, delegate: self,
                                 delegateQueue: OperationQueue.main)
        self.session = session
        let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 1800))
        downloadTask = task
        task.resume()
    }

    private func fetchSidecar(_ raw: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: raw) else { completion(nil); return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let hash = text.split(separator: " ").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            DispatchQueue.main.async {
                completion((hash?.count == 64) ? hash : nil)
            }
        }.resume()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let done = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?("正在下载… \(sizeText(totalBytesWritten)) / \(sizeText(totalBytesExpectedToWrite))",
                    done)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 临时文件出了这个回调就会被系统删掉，必须在这儿同步挪走。
        let name = downloadName ?? downloadTask.response?.suggestedFilename ?? "update.dmg"
        let destination = updatesDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            movedTo = destination
        } catch {
            shellLog("挪走下载文件失败：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard task is URLSessionDownloadTask else { return }
        downloadTask = nil
        session.invalidateAndCancel()
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            DispatchQueue.main.async {
                self.abort(cancelled ? "已取消下载。" : "下载失败：\(error.localizedDescription)")
            }
            return
        }
        guard let file = movedTo else {
            DispatchQueue.main.async {
                self.abort("下载没拿到文件（细节见 backend.log）。")
            }
            return
        }
        // 哈希放后台队列：128 MB 在主线程算会把界面钉住半秒以上。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let actual = sha256(of: file)
            DispatchQueue.main.async {
                guard let expected = self.expectedHash else {
                    self.abort("拿不到校验值，不自动安装。")
                    return
                }
                guard let actual, actual == expected else {
                    self.abort("SHA-256 对不上（期望 \(String(expected.prefix(16)))…，"
                        + "实际 \(String(actual ?? "读不出来").prefix(16))…）。"
                        + "下载可能被截断，或者中间被人动过。")
                    return
                }
                self.applyUpdate(dmg: file)
            }
        }
    }

    // MARK: 换包

    private func applyUpdate(dmg: URL) {
        guard let script = findApplyScript() else {
            abort("找不到 apply-update.sh，换不了包。DMG 留在 \(dmg.path)。")
            return
        }
        onProgress?("下载完成，正在换包（dshX 马上退出，稍等会自动重开）…", 1)
        shellLog("校验通过，交给 \(script)：\(dmg.path) → \(updateTargetApp())")
        let log = stateDirectory.appendingPathComponent("updater.log").path
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + & 让脚本脱离本进程：App 退出后还要靠它把包换掉并重开。
        child.arguments = ["-c",
            "nohup /bin/sh '\(script)' '\(dmg.path)' '\(updateTargetApp())' '\(log)' "
            + ">/dev/null 2>&1 &"]
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOME": NSHomeDirectory(),
                   "LANG": "zh_CN.UTF-8",
                   "DSHX_WAIT_PID": String(ProcessInfo.processInfo.processIdentifier)]
        if let backups = envString("DSH_UPDATE_BACKUPS"), !backups.isEmpty {
            env["DSHX_UPDATE_BACKUPS"] = backups
        }
        if envString("DSH_UPDATE_NO_RESTART") == "1" { env["DSHX_NO_RESTART"] = "1" }
        child.environment = env
        do {
            try child.run()
        } catch {
            abort("拉不起换包脚本：\(error.localizedDescription)")
            return
        }
        // 换包脚本要等这个进程没了才动手，所以这里请宿主退出。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.onQuitRequest?()
        }
    }

    private func abort(_ message: String) {
        updating = false
        session = nil
        expectedHash = nil
        downloadName = nil
        movedTo = nil
        shellLog("更新中止：\(message)")
        onNotice?(message)
    }

    func cancel() {
        updating = false
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func isTargetReplaceable() -> Bool {
        let target = updateTargetApp()
        if target.contains("AppTranslocation") { return false }
        return FileManager.default.isWritableFile(atPath: (target as NSString)
            .deletingLastPathComponent)
    }
}

/// 给日志用的一行结论。
private func checkSummary(_ result: UpdateCheck) -> String {
    switch result {
    case .upToDate(let current, let latest):
        return "已最新（当前 \(current) / 源上 \(latest ?? "没有可用 Release")）"
    case .available(let release, let package):
        return "有新版 \(release.version)（当前 \(currentAppVersion())，包 \(package.name)）"
    case .failure(let message):
        return "失败：\(message)"
    }
}

// MARK: - 界面（菜单「检查更新…」的宿主）

/// 只管展示：结论弹窗、下载进度条、取消。判断与执行都在 UpdateEngine 里。
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let engine = UpdateEngine()
    private var panelWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?

    override init() {
        super.init()
        engine.onProgress = { [weak self] text, fraction in
            self?.updatePanel(text, fraction: fraction)
        }
        engine.onNotice = { [weak self] message in
            self?.closePanel()
            self?.notify(message)
        }
        engine.onCheck = { [weak self] result in
            self?.present(result)
        }
        engine.onQuitRequest = { [weak self] in
            self?.closePanel()
            // 立刻退出：换包脚本要等这个进程没了才动手。
            // applicationShouldTerminate 会顺手收掉后端，不留孤儿端口。
            NSApp.terminate(nil)
        }
    }

    @objc func check() {
        engine.check()
    }

    // MARK: 弹窗

    private func present(_ result: UpdateCheck) {
        // 把结论写进日志：弹窗一闪而过，事后「刚才到底查到啥了」得有地方查。
        shellLog("检查结果：\(checkSummary(result))")
        switch result {
        case .upToDate(let current, let latest):
            let alert = NSAlert()
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前版本：\(current)\n"
                + "GitHub 最新：\(latest ?? "没有可用的 Release")\n"
                + "更新源：\(updateFeedURL())"
            alert.addButton(withTitle: "好")
            run(alert)
        case .failure(let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "检查更新失败"
            alert.informativeText = message + "\n\n日志：\(logFileURL.path)"
            alert.addButton(withTitle: "好")
            run(alert)
        case .available(let release, let package):
            presentAvailable(release: release, package: package)
        }
    }

    private func presentAvailable(release: ReleaseInfo, package: UpdatePackage) {
        let current = currentAppVersion()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "发现新版本 dshX \(release.version)（当前 \(current)）"
        alert.informativeText = """
        当前版本：\(current)
        最新版本：\(release.version)（tag \(release.tag)\(release.prerelease ? "，预发布" : "")）
        安装包：  \(package.name)，\(sizeText(package.size))
        要替换：  \(updateTargetApp())

        「更新并重启」= 下载 → 校验 SHA-256 → 退出 dshX → 换包 → 自动重开。
        换包会中断当前会话；下载 100 多 MB，通常 1–3 分钟。
        不想自动换：点「取消」，去 \(release.htmlURL) 自己下 DMG。
        """
        alert.addButton(withTitle: "更新并重启")
        alert.addButton(withTitle: "取消")
        if run(alert) == .alertFirstButtonReturn {
            shellLog("选了「更新并重启」，开始下载 \(package.name)")
            engine.start(package: package)
        } else {
            shellLog("用户取消了这次更新。")
        }
    }

    /// 弹在前台：不 activate 的话弹窗会躲在窗口后面，用户以为没反应。
    @discardableResult
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.mainWindow ?? NSApp.keyWindow)?.makeKeyAndOrderFront(nil)
        return alert.runModal()
    }

    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更新没有完成"
        alert.informativeText = message + "\n\n日志："
            + stateDirectory.appendingPathComponent("updater.log").path
            + "\n想要回退：删掉新包，把同目录下 dshX.app.bak.* 那份改回原名即可。"
        alert.addButton(withTitle: "好")
        run(alert)
    }

    // MARK: 进度面板

    private func showPanel(_ title: String) {
        closePanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 104),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "\(appTitle) 更新"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 104))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 20, y: 58, width: 420, height: 20)
        label.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 32, width: 420, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelUpdate))
        cancel.frame = NSRect(x: 360, y: 4, width: 80, height: 24)
        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancel)
        window.contentView = content
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panelWindow = window
        progressLabel = label
        progressBar = bar
        bar.startAnimation(nil)
    }

    private func updatePanel(_ text: String, fraction: Double) {
        // 引擎只管报进度，面板在这里按需长出来（第一次进度就是「开始下载」）。
        if panelWindow == nil { showPanel(text) }
        progressLabel?.stringValue = text
        progressBar?.doubleValue = fraction >= 0 ? min(max(fraction, 0), 1) : 0
        panelWindow?.displayIfNeeded()
    }

    private func closePanel() {
        progressBar?.stopAnimation(nil)
        panelWindow?.orderOut(nil)
        panelWindow = nil
        progressLabel = nil
        progressBar = nil
    }

    @objc private func cancelUpdate() {
        engine.cancel()
        closePanel()
        notify("已取消。")
    }
}

// MARK: - 零碎工具

func sizeText(_ bytes: Int64) -> String {
    bytes <= 0 ? "大小未知" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

/// 本机架构。DMG 文件名里带的就是这个字符串，用来挑对架构的包。
func machineArch() -> String {
    var info = utsname()
    if uname(&info) == 0 {
        var machine = info.machine      // 先调 uname 再取快照，不然拿到的是全零
        let text = withUnsafeBytes(of: &machine) { raw in
            String(decoding: Data(raw.prefix(while: { $0 != 0 })), as: UTF8.self).lowercased()
        }
        if text.contains("arm") || text.contains("aarch") { return "arm64" }
        if text.contains("x86") || text.contains("amd64") { return "x86_64" }
        if !text.isEmpty { return text }
    }
    return "arm64"
}

func sha256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    let chunk = 4 * 1024 * 1024
    while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// 找换包脚本：环境变量 → 随 App 打包的那份 → 私有目录 → 仓库工作目录。
/// 用 `/bin/sh 脚本` 起，所以只要求能读。
func findApplyScript() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let override = envString("DSH_APPLY_SCRIPT"), !override.isEmpty {
        candidates.append(override)
    }
    if let resources = Bundle.main.resourceURL {
        candidates.append(resources.appendingPathComponent("updater/apply-update.sh").path)
    }
    candidates.append(stateDirectory.appendingPathComponent("apply-update.sh").path)
    if let workspace = envString("DSH_APP_WORKSPACE"), !workspace.isEmpty {
        candidates.append(workspace + "/shell/updater/apply-update.sh")
        candidates.append(workspace + "/updater/apply-update.sh")
    }
    for path in candidates where fm.fileExists(atPath: path) { return path }
    return nil
}