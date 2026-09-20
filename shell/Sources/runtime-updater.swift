import AppKit
import Foundation

/*
 「更新 dsh 后端…」——只替换 .app 里的 dsh 运行时，不换壳、不用重新发版。

 与菜单里「检查更新…」（换整个 .app）的分工：

   检查更新…（⌘U）   数据源是 dshX 自己的 GitHub Releases，换的是整个 .app
                     （壳 + 后端一起走，见 updater.swift）
   更新 dsh 后端…     数据源是 npm registry 上的 @deepseek-ai/dsh，只换
                     Contents/Resources/runtime/node_modules

 上游只改了 dsh 的时候走后者：不用重打 DMG、不用发新版本，App 也不退出。

 为什么这件事能在 App 里做（而整包替换必须退到 App 外面）：
   被换的只是 runtime 这一个子目录，而且换之前先把后端子进程停掉——没有进程还
   mmap 着里头那些 .js/.node 之后，同卷改名就是安全的。提升只做 rename，不复制。
   整包替换做不到这一点：壳自己和 WebKit 就跑在被换的那个包里（见 apply-update.sh）。

 装法：用 .app 自带的 Node + pnpm 把 @deepseek-ai/dsh@<版本> 装进
   runtime/.staged-<版本>/（同卷，提升时一次 rename 就位），装完先跑
   `node …/dsh/lib/bin.js --version` 探活，版本对不上就不提升；提升后再探一次，
   失败自动把备份挪回去。原生文件（*.node / Mach-O helper）按 make-app.sh 同样的
   办法逐个 ad-hoc 签名——arm64 上没签名的原生代码会被内核直接杀掉。

 调试/演练开关（设了才生效）：
   DSHX_RUNTIME_DIR      换要操作的 runtime 目录（离线用例、不碰真 app 的演练）
   DSHX_NPM_REGISTRY     换 registry 根地址（国内可指镜像，如 registry.npmmirror.com）
   DSHX_BACKEND_VERSION  指定确切版本，跳过「只升不降」的判断（演练用）
   DSHX_PNPM_STORE       换 pnpm store 位置（默认 <私有目录>/pnpm-store，用完删）
   DSHX_KEEP_PNPM_STORE=1 保留 store（下次更新省下载，代价是多占一份盘）
   DSHX_RUNTIME_BACKUPS  旧后端备份留几份（默认 1，0 = 不留）
   DSHX_NODE / DSHX_PNPM 换内置 Node / pnpm 的路径（源码方式直跑壳时用）
 */

// MARK: - 常量与路径

let dshPackageName = "@deepseek-ai/dsh"

/// 现行后端所在的运行时目录：`<app>/Contents/Resources/runtime`。
/// 环境变量可覆盖，用例与演练都靠它指到临时目录。
func runtimeDirectory() -> URL {
    if let override = envString("DSHX_RUNTIME_DIR"), !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let resources = Bundle.main.resourceURL {
        return resources.appendingPathComponent("runtime", isDirectory: true)
    }
    // 源码方式直跑壳（没有 bundle）时退到可执行文件旁边找。
    let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().appendingPathComponent("runtime", isDirectory: true)
}

/// registry 根地址（不带尾斜杠）。只影响「更新 dsh 后端」这条链路，
/// 壳自己的更新源（GitHub Releases）不受影响。
func npmRegistryRoot() -> String {
    var raw = (envString("DSHX_NPM_REGISTRY") ?? envString("npm_config_registry") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while raw.hasSuffix("/") { raw.removeLast() }
    return raw.isEmpty ? "https://registry.npmjs.org" : raw
}

/// 包文档地址。@ 与 / 都要转义：不然请求会落到 /deepseek-ai/dsh 上，404。
func npmPackageDocumentURL() -> URL {
    let encoded = dshPackageName
        .replacingOccurrences(of: "@", with: "%40")
        .replacingOccurrences(of: "/", with: "%2F")
    return URL(string: npmRegistryRoot() + "/" + encoded)
        ?? URL(string: "https://registry.npmjs.org/%40deepseek-ai%2Fdsh")!
}

/// 装好的 dsh 包目录——决定「当前后端是哪个版本」的那个 package.json 在这里。
func dshPackageDirectory(in runtimeDir: URL) -> URL {
    runtimeDir.appendingPathComponent("node_modules/\(dshPackageName)", isDirectory: true)
}

/// 现行后端版本：读它自己的 package.json，跟 `dsh --version` 同源。
func installedBackendVersion(in runtimeDir: URL) -> String? {
    let url = dshPackageDirectory(in: runtimeDir).appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return packageVersion(in: data)
}

/// 只认顶层 `"version"`。别去正文里正则捞：dependencies 里全是版本号，一捞就串。
func packageVersion(in data: Data) -> String? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let version = (root["version"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          !version.isEmpty else { return nil }
    return version
}

// MARK: - 成败与失败话术

/// 这一族函数统一「要么成，要么给一句能直接读给人看的话」。不用 Swift 的
/// `Result`：它的 Failure 必须 conform Error，为一句人话再包一个 error 类型
/// 只是噪音（updater.swift 里的 UpdateCheck 也是这个取向）。
enum RuntimeStep<Value> {
    case success(Value)
    case failure(String)
}

// MARK: - 步骤与整体进度（纯函数，能离线对）

/// 「更新 dsh 后端…」要走的步骤，**按实际执行顺序**排列（进度只许往前走）。
/// 每一步有一个权重，大致是它在整条链路里占的时间比例，加起来正好 1；
/// 步内再有 0~1 的进度，合起来就是「已做完的权重 + 当前步内进度 × 本步权重」。
/// 权重只决定进度条走多快，不参与任何实际动作，也不追求精确——它唯一的责任是
/// 别让进度条倒着走，也别在没做事的时候假装在走。
enum RuntimeStage: Int, CaseIterable {
    case prepare    // 建 staging 目录、写它的 package.json
    case install    // pnpm 把依赖装进 staging（有真分母：Packages: +N 与 added）
    case verify     // 探活：`node …/dsh/lib/bin.js --version`
    case sign       // 给树里的原生模块逐个 ad-hoc 签名（有真分母：Mach-O 个数）
    case promote    // 停后端 → 换目录 → 再探活
    case finish     // 收尾：换 package.json、裁备份、删 staging 与 pnpm store
    case resign     // 重新 ad-hoc 签整个 .app
    case restart    // 把后端重新拉起来

    /// 时间占比。真实一轮里 pnpm 是绝对大头（实测 24 秒），签名次之，
    /// 其余几步都是 rename / 读写几个小文件，加起来也就几秒。
    var weight: Double {
        switch self {
        case .prepare: return 0.02
        case .install: return 0.70
        case .verify:  return 0.03
        case .sign:    return 0.12
        case .promote: return 0.06
        case .finish:  return 0.02
        case .resign:  return 0.03
        case .restart: return 0.02
        }
    }

    /// 面板上「第 n/8 步」用的序号（1 起）。
    var stepNumber: Int { rawValue + 1 }
    static var stepCount: Int { allCases.count }
}

/// 某一步走到 `within`（0~1）时整条链路的进度。
/// `within < 0` = 这一步没有可报的分母（rename、codesign 这类）：停在它的起点，
/// 靠面板上的文案与计时说明它还活着，而不是编一个假进度往前爬。
func overallProgress(_ stage: RuntimeStage, within: Double = -1) -> Double {
    let done = RuntimeStage.allCases
        .prefix { $0.rawValue < stage.rawValue }
        .reduce(0.0) { $0 + $1.weight }
    guard within >= 0 else { return done }
    return done + stage.weight * min(max(within, 0), 1)
}

/// 引擎报给界面的一帧：在第几步、这一步在做什么、整条链路走到哪。
/// 与「检查更新…」那条链路一样把「做什么」和「到哪了」一起报，界面就不用猜。
struct RuntimeProgress {
    let stage: RuntimeStage
    let text: String
    /// 整条链路的 0~1。
    let fraction: Double
}

// MARK: - staging / 备份的命名（纯函数）

let stagingDirectoryPrefix = ".staged-"
let stagedMarkerName = ".dshx-runtime.json"

/// staging 目录：`<runtime>/.staged-<版本>`。放在 runtime 目录里不是随手放的——
/// 同卷才能让「提升」只是 rename，而不是把 400M 复制一遍。
func stagingDirectory(in runtimeDir: URL, version: String) -> URL {
    runtimeDir.appendingPathComponent(stagingDirectoryPrefix + version, isDirectory: true)
}

/// 从目录名反解 staging 的版本；不是 staging 目录就返回 nil。
func stagedVersion(fromDirectoryName name: String) -> String? {
    guard name.hasPrefix(stagingDirectoryPrefix) else { return nil }
    let version = String(name.dropFirst(stagingDirectoryPrefix.count))
    return version.isEmpty ? nil : version
}

func stagedDirectories(in runtimeDir: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path)) ?? []
    return names.compactMap { name -> URL? in
        guard stagedVersion(fromDirectoryName: name) != nil else { return nil }
        return runtimeDir.appendingPathComponent(name, isDirectory: true)
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// 旧后端的备份目录：`node_modules.bak-<版本>`。
func backupDirectory(in runtimeDir: URL, version: String?) -> URL {
    let suffix = (version?.isEmpty == false) ? version! : "unknown"
    return runtimeDir.appendingPathComponent("node_modules.bak-\(suffix)", isDirectory: true)
}

func backupDirectories(in runtimeDir: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path)) ?? []
    return names.compactMap { name -> URL? in
        guard name.hasPrefix("node_modules.bak-") else { return nil }
        return runtimeDir.appendingPathComponent(name, isDirectory: true)
    }
}

/// 备份留几份。整个后端 400M 起，默认只留 1 份，别调大。
func runtimeBackupLimit() -> Int {
    guard let raw = envString("DSHX_RUNTIME_BACKUPS"), let value = Int(raw) else { return 1 }
    return max(0, value)
}

// MARK: - registry 元数据 → 候选版本（纯函数）

struct BackendCandidate: Equatable {
    let version: String
    /// 命中来源。弹窗里要写明白它凭什么是「新版」，不然没法核对。
    let origin: String
}

struct BackendUpdateQuery: Equatable {
    let current: String?
    /// nil = 没有比当前更新的版本。
    let candidate: BackendCandidate?
    /// registry 上发布的最高版本；不参与判断，只为「已是最新」时能两个版本都写出来。
    let latestPublished: String?
    let registry: String
}

/// dist-tag 的优先顺序（同一版本被多个标签指着时，报告更像「正式渠道」的那个）。
private let distTagPreference = ["latest", "next", "alpha"]

/// 从 registry 的包文档里挑候选版本。
///
/// 规则与 shell/update.sh 保持一致——两条链路必须挑同一个版本，否则会出现
/// 「命令行说有新版、菜单里却没有」这种自相矛盾。上游把预发布发在 next/alpha 上
/// （latest 常常落后），所以标签要全看，不能只认 latest：
///   1. 所有 dist-tags 里，比当前新的最高版本；
///   2. 都更新不了，再去 versions 列表里找比当前新的最高版本。
func resolveBackendCandidate(data: Data, current: String,
                             pinnedVersion: String? = nil) -> BackendCandidate? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }
    let tags = ((root["dist-tags"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
    let versions = ((root["versions"] as? [String: Any]) ?? [:]).keys.sorted()

    // 演练/调试：指名道姓要哪个版本，连「不比当前新」也不再拦。
    if let pinned = pinnedVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !pinned.isEmpty {
        guard versions.contains(pinned) || tags.values.contains(pinned) else { return nil }
        return BackendCandidate(version: pinned, origin: "指定版本（DSHX_BACKEND_VERSION）")
    }

    var best: BackendCandidate?
    for tag in tags.keys.sorted(by: distTagOrder) {
        guard let version = tags[tag] else { continue }
        guard versionOrder(version, current) == .orderedDescending else { continue }
        if best == nil || versionOrder(version, best!.version) == .orderedDescending {
            best = BackendCandidate(version: version, origin: "dist-tag \(tag)")
        }
    }
    if let best { return best }

    let newer = versions.filter { versionOrder($0, current) == .orderedDescending }
    guard let top = newer.max(by: { versionOrder($0, $1) == .orderedAscending }) else { return nil }
    return BackendCandidate(version: top, origin: "versions 列表")
}

/// registry 上发布过的最高版本（含预发布）。只用于展示。
func latestPublishedVersion(in data: Data) -> String? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }
    return ((root["versions"] as? [String: Any]) ?? [:]).keys
        .max { versionOrder($0, $1) == .orderedAscending }
}

private func distTagOrder(_ a: String, _ b: String) -> Bool {
    let ia = distTagPreference.firstIndex(of: a) ?? distTagPreference.count
    let ib = distTagPreference.firstIndex(of: b) ?? distTagPreference.count
    return ia == ib ? a < b : ia < ib
}

// MARK: - staging 标记（纯函数 + 一次落盘）

/// staging 里那份「装好了」的凭据。启动时的接管逻辑就认它：
/// 有 marker 才算装完，版本还比现装的新才值得提升。
struct StagedRuntime: Equatable {
    let version: String
    let installedAt: String
    let registry: String
    let shellVersion: String
}

func parseStagedRuntime(_ data: Data) -> StagedRuntime? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let version = (root["version"] as? String)?.trimmingCharacters(in: .whitespaces),
          !version.isEmpty else { return nil }
    return StagedRuntime(version: version,
                         installedAt: root["installedAt"] as? String ?? "",
                         registry: root["registry"] as? String ?? "",
                         shellVersion: root["shellVersion"] as? String ?? "")
}

func stagedRuntime(in stagingDir: URL) -> StagedRuntime? {
    let url = stagingDir.appendingPathComponent(stagedMarkerName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return parseStagedRuntime(data)
}

func writeStagedMarker(in stagingDir: URL, version: String) throws {
    var payload: [String: String] = [
        "version": version,
        "installedAt": ISO8601DateFormatter().string(from: Date()),
        "registry": npmRegistryRoot(),
        "shellVersion": currentAppVersion(),
    ]
    if let node = bundledNodePath() { payload["node"] = node }
    if let pnpm = bundledPnpmScript() { payload["pnpm"] = pnpm }
    let data = try JSONSerialization.data(withJSONObject: payload,
                                          options: [.prettyPrinted, .sortedKeys])
    try data.write(to: stagingDir.appendingPathComponent(stagedMarkerName))
}

// MARK: - 提升与回滚（能离线演练的目录动作）

struct RenameStep: Equatable {
    let from: URL
    let to: URL
}

/// 「提升」要做的改名动作，按顺序：现行的 node_modules 先挪去备份，再把 staging 的
/// 那份挪进来。纯函数，只算不做（真动手的是 promoteRuntime，失败时倒序回滚）。
func promotionSteps(runtimeDir: URL, stagedVersion: String, currentVersion: String?) -> [RenameStep] {
    let staged = stagingDirectory(in: runtimeDir, version: stagedVersion)
        .appendingPathComponent("node_modules", isDirectory: true)
    let current = runtimeDir.appendingPathComponent("node_modules", isDirectory: true)
    return [
        RenameStep(from: current, to: backupDirectory(in: runtimeDir, version: currentVersion)),
        RenameStep(from: staged, to: current),
    ]
}

/// 倒着把已经做完的改名撤回去。只撤真做过的那些 step。
func rollbackRenames(_ done: [RenameStep]) {
    let fm = FileManager.default
    for step in done.reversed() {
        guard fm.fileExists(atPath: step.to.path) else { continue }
        try? fm.removeItem(at: step.from)
        try? fm.moveItem(at: step.to, to: step.from)
    }
}

/// 把 staging 里装好的树换成现行的。**调用前必须已经停掉后端**：node 正 mmap 着
/// 要被换掉的那些文件，进程还在的时候改名等于把正在跑的会话连根拔。
///
/// 换完再探一次活（`dsh --version`）：新树起不来就把备份挪回原位 —— 宁可这次更新
/// 白做，也不能把一个起不来的后端留在 App 里。
func promoteRuntime(runtimeDir: URL, staging: URL, version: String,
                    currentVersion: String?) -> RuntimeStep<Void> {
    let fm = FileManager.default
    let steps = promotionSteps(runtimeDir: runtimeDir, stagedVersion: version,
                               currentVersion: currentVersion)
    var done: [RenameStep] = []
    do {
        for step in steps where fm.fileExists(atPath: step.from.path) {
            // 同名备份先清掉：同一个版本重装时会撞上自己上次留下的那份。
            if fm.fileExists(atPath: step.to.path) { try fm.removeItem(at: step.to) }
            try fm.moveItem(at: step.from, to: step.to)
            done.append(step)
        }
    } catch {
        rollbackRenames(done)
        return .failure("切换后端失败：\(error.localizedDescription)\n"
            + permissionHint(for: error, target: runtimeDir.path))
    }

    let entry = dshPackageDirectory(in: runtimeDir).appendingPathComponent("lib/bin.js")
    let reported = runDshVersion(entry: entry)
    guard reported == version else {
        rollbackRenames(done)
        return .failure("新后端探活失败（自报 \(reported ?? "无输出")，期望 \(version)），"
            + "已经把备份挪回原位。")
    }
    return .success(())
}

/// 「切换被打断」的现场：没有 node_modules，但还留着一份备份。挑最新的一份救回来。
/// 提升是两步改名（旧的→备份、staging→现行），正好在这两步之间崩溃/被强杀就会
/// 留下这个状态；不救的话 App 下次启动会报「找不到 dsh 入口 bin.js」。
func rescueCandidate(in runtimeDir: URL) -> URL? {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: runtimeDir.appendingPathComponent("node_modules").path) else {
        return nil
    }
    return backupDirectories(in: runtimeDir).max { a, b in
        let left = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        let right = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        return left < right
    }
}

/// 提升成功后的收尾：package.json 换成新树的、裁掉多余备份、删掉 staging。
func finishPromotion(runtimeDir: URL, staging: URL) {
    let fm = FileManager.default
    let stagedManifest = staging.appendingPathComponent("package.json")
    if let data = try? Data(contentsOf: stagedManifest) {
        try? data.write(to: runtimeDir.appendingPathComponent("package.json"))
    }
    try? fm.removeItem(at: staging)
    pruneRuntimeBackups(in: runtimeDir)
    removePnpmStoreIfTemporary()
}

/// 备份按修改时间倒序，只留 DSHX_RUNTIME_BACKUPS 份（默认 1）。
func pruneRuntimeBackups(in runtimeDir: URL) {
    let keep = runtimeBackupLimit()
    let backups = backupDirectories(in: runtimeDir).sorted { a, b in
        let left = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        let right = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        return left > right
    }
    for url in backups.dropFirst(keep) {
        shellLog("删掉多余的 dsh 后端备份：\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: url)
    }
}

/// 把「没权限」翻译成能照做的下一步。写 /Applications 失败时不说清楚，
/// 只会让人以为是 dshX 坏了，其实多半是 macOS 14+ 的「App 管理」。
func permissionHint(for error: Error, target: String) -> String {
    let ns = error as NSError
    let denied = ns.code == Int(EPERM) || ns.code == Int(EACCES)
        || ns.code == NSFileWriteNoPermissionError
    guard denied else { return "" }
    return "\n写不进 \(target)。除了文件权限，macOS 14+ 还可能是"
        + "「系统设置 › 隐私与安全性 › App 管理」拦住了：给 dshX 打开这一项再试。"
}

// MARK: - pnpm store

let pnpmStoreDirectoryName = "pnpm-store"

func pnpmStoreDirectory() -> URL {
    if let override = envString("DSHX_PNPM_STORE"), !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return stateDirectory.appendingPathComponent(pnpmStoreDirectoryName, isDirectory: true)
}

/// 默认删掉自己建的那个 store：装完的 node_modules 已经是一份完整克隆，
/// store 再留一份只是重复占盘（clone/硬链接共享的是块，删掉 store 才能真正还回去）。
/// 想留着加速下次更新就 DSHX_KEEP_PNPM_STORE=1；用户自己用 DSHX_PNPM_STORE
/// 指定的 store 一律不动——那不是我们的地盘。
func removePnpmStoreIfTemporary() {
    guard envString("DSHX_KEEP_PNPM_STORE") != "1" else { return }
    guard (envString("DSHX_PNPM_STORE") ?? "").isEmpty else { return }
    let store = pnpmStoreDirectory()
    guard FileManager.default.fileExists(atPath: store.path) else { return }
    shellLog("清理 pnpm store：\(store.path)")
    try? FileManager.default.removeItem(at: store)
}

// MARK: - 子进程：内置 Node / pnpm、短命令、原生签名

func bundledNodePath() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let override = envString("DSHX_NODE"), !override.isEmpty { candidates.append(override) }
    if let resources = Bundle.main.resourceURL {
        candidates.append(resources.appendingPathComponent("node/bin/node").path)
    }
    candidates.append(contentsOf: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"])
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

func bundledPnpmScript() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let override = envString("DSHX_PNPM"), !override.isEmpty { candidates.append(override) }
    if let resources = Bundle.main.resourceURL {
        candidates.append(resources.appendingPathComponent("tools/pnpm/package/bin/pnpm.cjs").path)
    }
    return candidates.first { fm.fileExists(atPath: $0) }
}

/// 子进程环境：跟壳启动后端时同一套白名单，不继承任何 DSH_*（别的 harness
/// 会话状态混进来会被误认），再补上内置 pnpm 需要的 PATH。
func childEnvironment(node: String) -> [String: String] {
    var env: [String: String] = [:]
    for key in ["HOME", "USER", "LANG", "TMPDIR"] {
        if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
    }
    var paths = [URL(fileURLWithPath: node).deletingLastPathComponent().path]
    if let resources = Bundle.main.resourceURL {
        paths.append(resources.appendingPathComponent("tools/bin").path)
    }
    paths.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin",
                              "/opt/homebrew/bin", "/usr/local/bin"])
    env["PATH"] = paths.joined(separator: ":")
    env["NODE_ENV"] = "production"
    return env
}

/// 跑一条短命令并收好输出；超时就杀掉。给 codesign 与 `dsh --version` 用。
@discardableResult
func runProcess(_ executable: String, _ arguments: [String],
                currentDirectory: URL? = nil, environment: [String: String]? = nil,
                timeout: TimeInterval = 120) -> (status: Int32, output: String, timedOut: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "无法启动 \(executable)：\(error.localizedDescription)", false)
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    var timedOut = false
    if process.isRunning {
        timedOut = true
        process.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self), timedOut)
}

// MARK: - 其它 dsh 后端冲突（同一个 DSH_HOME）

/// 另一个正在监听、且打开着同一个私有 home 的 dsh 后端。
/// 它可能是插件市场「重启」留下的孤儿，也可能是 `open -n` 起的第二个实例。
struct BackendConflict: Equatable {
    let pid: pid_t
    let address: String
    let port: Int

    var text: String { "PID \(pid)（\(address)）" }
}

/// 从 `lsof -nP -iTCP -sTCP:LISTEN` 的输出里挑出 node 的回环监听。
/// 纯函数，离线用例直接喂样例；非回环（`*:port`）不算——dsh 自己只绑 127.0.0.1。
func parseListeningNodeBackends(_ output: String) -> [BackendConflict] {
    var result: [BackendConflict] = []
    for raw in output.split(whereSeparator: { $0.isNewline }) {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2,
              fields[0] == "node",
              fields[fields.count - 1] == "(LISTEN)",
              let pid = pid_t(fields[1]) else { continue }
        let address = fields[fields.count - 2]
        guard address.hasPrefix("127.0.0.1:") || address.hasPrefix("[::1]:") else { continue }
        guard let colon = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: colon)...]) else { continue }
        result.append(BackendConflict(pid: pid, address: address, port: port))
    }
    return result
}

/// 找出「也在监听、且打开着同一个 DSH_HOME」的 dsh 后端。
/// 调用方用 `excludingPorts` 排除自己：壳知道当前后端的端口。
/// lsof 拿不到就返回空——守卫宁可漏报，也不误杀别的进程。
func conflictingBackends(excludingPorts excludedPorts: Set<Int> = []) -> [BackendConflict] {
    guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [] }
    let listing = runProcess("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"], timeout: 10)
    guard listing.status == 0 else { return [] }
    let home = stateDirectory.appendingPathComponent("home", isDirectory: true).path
    return parseListeningNodeBackends(listing.output).filter { candidate in
        guard !excludedPorts.contains(candidate.port) else { return false }
        let files = runProcess("/usr/sbin/lsof", ["-nP", "-p", "\(candidate.pid)", "-Fn"], timeout: 10)
        guard files.status == 0 else { return false }
        return files.output.split(whereSeparator: { $0.isNewline }).contains { line in
            line.hasPrefix("n") && String(line.dropFirst()).hasPrefix(home)
        }
    }
}

/// 跑 `<node> <入口> --version`，拿它自报的版本号。探活用的就是这一下：
/// 树里缺依赖、装坏了，这里要么没输出、要么报出别的版本。
func runDshVersion(entry: URL) -> String? {
    guard let node = bundledNodePath() else { return nil }
    let result = runProcess(node, [entry.path, "--version"],
                            environment: childEnvironment(node: node), timeout: 60)
    guard result.status == 0, !result.timedOut else { return nil }
    return result.output.split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}

/// Mach-O 魔数：thin 的 32/64 位（大小端）+ FAT。本机 arm64 命中的是 cf fa ed fe。
func isMachO(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
    let magic = [UInt8](data)
    let known: [[UInt8]] = [
        [0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf],
        [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe],
        [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
    ]
    return known.contains(magic)
}

/// 从 pnpm 的 `--reporter=append-only` 输出里抠出安装进度。纯函数，离线可对。
///
/// 真实输出长这样（两段合起来才是完整故事）：
///
///     Progress: resolved 1, reused 0, downloaded 0, added 0
///     ...
///     Packages: +483                 ← 分母只在这一行，得先记住
///     +++++++++++++++++++++++++++++  ← 进度条本体，没用，忽略
///     Progress: resolved 550, reused 0, downloaded 24, added 24
///     ...
///     Progress: resolved 550, reused 0, downloaded 482, added 483, done
///
/// `Packages` 之前那一段是解析依赖，added 恒为 0（拿它当分子进度条会一直贴地，
/// 看着像卡住），所以那一段用 resolved 的增量算，只给它安装阶段的前三成；
/// 见到 `Packages` 之后才是真装包，用 done/total，占后七成。
struct PnpmInstallProgress: Equatable {
    /// 安装步内的 0~1。
    var fraction: Double
    /// 给面板的「这一步在做什么」。
    var text: String
    /// pnpm 报的「这次要装几个包」；还没解析出来时是 nil。
    var total: Int?

    static let start = PnpmInstallProgress(fraction: 0, text: "正在向 registry 解析依赖…",
                                           total: nil)
}

/// 解析一行 pnpm 输出，返回新的一帧。**进度只增不减**：解析不出进度信息的行
/// （进度条 `+++…`、WARN、空行）原样沿用上一帧的 fraction，进度条绝不倒着走。
func parsePnpmProgress(_ raw: String, state: PnpmInstallProgress) -> PnpmInstallProgress {
    let line = raw.trimmingCharacters(in: .whitespaces)
    var next = state
    next.text = raw

    // `Packages: +483`：分母只出现在这一行。它之前的 added 全是 0。
    if line.hasPrefix("Packages:") {
        if let total = firstNumber(in: line), total > 0 {
            next.total = total
            next.text = "依赖解析完了，一共 \(total) 个包，开始装…"
        }
        return next
    }

    guard line.hasPrefix("Progress:"), let counters = pnpmCounters(in: line) else {
        return next
    }
    let resolved = counters["resolved"] ?? 0
    let added = counters["added"] ?? 0

    if let total = next.total {
        // 有真分母：装包阶段走后七成，留 1% 给 pnpm 写完最后那点收尾。
        if added >= total || line.hasSuffix("done") {
            next.fraction = 1
            next.text = "依赖装好了（\(added)/\(total) 个包），正在收尾…"
        } else {
            next.fraction = max(state.fraction,
                                min(0.99, 0.3 + 0.69 * Double(added) / Double(total)))
            next.text = "正在装依赖…（\(added)/\(total) 个包）"
        }
    } else {
        // 还没拿到分母（只有极短的安装才会这样）：按解析进度估前三成，
        // 上限压在 0.29，绝不越过「Packages」本该占的位置。
        next.fraction = max(state.fraction, min(0.29, 0.29 * min(Double(resolved) / 550.0, 1)))
        next.text = "正在解析依赖…（已解析 \(resolved) 个包）"
    }
    return next
}

/// 抠出 `resolved 550, reused 0, downloaded 24, added 24` 这样的计数。
func pnpmCounters(in line: String) -> [String: Int]? {
    var counters: [String: Int] = [:]
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    var index = 0
    while index + 1 < tokens.count {
        if let value = Int(tokens[index + 1]) { counters[tokens[index]] = value }
        index += 1
    }
    return counters.isEmpty ? nil : counters
}

/// 一行里第一个整数，用来读 `Packages: +483`。
func firstNumber(in line: String) -> Int? {
    var digits = ""
    for character in line {
        if character.isNumber {
            digits.append(character)
        } else if !digits.isEmpty {
            break
        }
    }
    return Int(digits)
}

/// 把树里所有原生代码逐个 ad-hoc 签名。arm64 上没签名的原生代码会被内核直接杀掉，
/// 所以这一步不能省（make-app.sh 对打进包的运行时做的是同一件事）。
/// 按魔数认，而不是只认 `*.node`：spawn-helper 这类可执行 helper 也要签。
/// `onProgress` 报 (签完几个, 一共几个)——先数一遍再动手，所以这个分母是真的。
func signNativeArtifacts(in root: URL, log: (String) -> Void = { _ in },
                         onProgress: ((Int, Int) -> Void)? = nil)
    -> (signed: Int, failed: [String]) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return (0, []) }
    // 先把要签的挑出来：codesign 每个要几百毫秒，222 个文件就是一分多钟，
    // 先数一遍才好给出「第 37/222 个」这种真进度（分母是真的，不是估的）。
    var targets: [URL] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        guard isMachO(at: url) else { continue }
        targets.append(url)
    }
    var signed = 0
    var failed: [String] = []
    onProgress?(0, targets.count)
    for url in targets {
        let result = runProcess("/usr/bin/codesign",
                                ["--force", "--sign", "-", "--timestamp=none", url.path],
                                timeout: 120)
        if result.status == 0 {
            signed += 1
        } else {
            failed.append(url.path)
            log("签名失败 \(url.path)：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        onProgress?(signed + failed.count, targets.count)
    }
    return (signed, failed)
}

/// 重签 .app 时该用哪个身份：**沿用 App 当前的身份**——证书签的包继续用同一张
/// 证书，ad-hoc 的包继续 ad-hoc。
///
/// 这一步不能写死 `-`。macOS 的隐私授权（录屏、麦克风、自动化…）是按 designated
/// requirement 存的：证书签名的 requirement 是「bundle id + 证书」，重新打包不会
/// 变；ad-hoc 的 requirement 就是 cdhash 本身，二进制一变授权立刻作废。换过
/// Resources 之后无脑 ad-hoc 重签，等于每次「更新 dsh 后端…」都把用户的授权清掉，
/// 表现就是「设置里明明勾了允许，却还在反复弹窗」。
///
/// 封条此时已经对不上（刚换过 Resources），但 CodeDirectory 还在，
/// `codesign -dvvv` 照样读得出当初用的证书。`DSHX_CODESIGN_IDENTITY` 可强制指定
/// （`-` 表示 ad-hoc）。
func currentSigningIdentity(of bundle: URL = Bundle.main.bundleURL) -> String {
    if let override = ProcessInfo.processInfo.environment["DSHX_CODESIGN_IDENTITY"],
       !override.isEmpty {
        return override
    }
    let result = runProcess("/usr/bin/codesign", ["-dvvv", bundle.path], timeout: 30)
    for line in result.output.split(separator: "\n") where line.hasPrefix("Authority=") {
        let value = String(line.dropFirst("Authority=".count)).trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return value }
    }
    return "-"
}

// MARK: - 引擎（只做事，不画界面）

/// 查 / 装 / 提升 / 重启。界面回调都在主线程。
/// 与界面分开是为了能脱离 App 跑：update-check-test 直接驱动它做演练。
final class RuntimeInstaller {
    enum Phase { case staging, promoting }

    struct Outcome {
        let version: String
        let backupPath: String?
        let registry: String
    }

    /// 进度（主线程）：第几步、这一步在做什么、整条链路走到哪。
    var onProgress: ((RuntimeProgress) -> Void)?
    /// 阶段变化：staging 阶段可以取消，promoting 阶段不能（改目录改到一半更糟）。
    var onPhase: ((Phase) -> Void)?
    /// 换目录之前必须停掉后端子进程；换完（无论成败）都要重新拉起来。
    var stopBackend: (() -> Void)?
    var startBackend: (() -> Void)?
    /// 换目录前的冲突检查：壳会排除自己那个后端，返回还剩下的其它后端。
    /// 测试/演练不注入就跳过（临时 runtime 不会有人共用）。
    var otherBackends: (() -> [BackendConflict])?

    private(set) var isRunning = false
    private var child: Process?
    private var cancelled = false
    private let lock = NSLock()

    // MARK: 查

    /// 查 registry 上有没有比现装更新的版本。nil candidate = 已是最新。
    func check(completion: @escaping (RuntimeStep<BackendUpdateQuery>) -> Void) {
        let runtime = runtimeDirectory()
        let current = installedBackendVersion(in: runtime)
        var request = URLRequest(url: npmPackageDocumentURL(),
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        // 缩写元数据：只要 dist-tags 与版本列表，不必拖整个 manifest 下来。
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        request.setValue("\(appTitle)/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")
        shellLog("检查 dsh 后端：GET \(request.url?.absoluteString ?? "?")（当前 \(current ?? "未知")）")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: RuntimeStep<BackendUpdateQuery>
            if let error {
                result = .failure("取不到 npm registry：\(error.localizedDescription)\n"
                    + "这一步只要一次 GET；离线、代理、DNS 出问题都长这样。"
                    + "国内慢或不通可以用 DSHX_NPM_REGISTRY 指到镜像。")
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200...299).contains(status) {
                    result = .failure("npm registry 返回 HTTP \(status)。")
                } else if let data, !data.isEmpty {
                    let latest = latestPublishedVersion(in: data)
                    let candidate = resolveBackendCandidate(
                        data: data, current: current ?? "0.0.0",
                        pinnedVersion: envString("DSHX_BACKEND_VERSION"))
                    shellLog("dsh 后端：当前 \(current ?? "未知")，registry 最高 \(latest ?? "未知")，"
                        + "候选 \(candidate.map { "\($0.version)（\($0.origin)）" } ?? "无")")
                    result = .success(BackendUpdateQuery(current: current, candidate: candidate,
                                                         latestPublished: latest,
                                                         registry: npmRegistryRoot()))
                } else {
                    result = .failure("npm registry 返回空内容。")
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: 装 + 提升

    func install(candidate: BackendCandidate,
                 completion: @escaping (RuntimeStep<Outcome>) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        onPhase?(.staging)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch self.stage(candidate) {
            case .failure(let message):
                DispatchQueue.main.async {
                    self.isRunning = false
                    completion(.failure(message))
                }
            case .success(let staging):
                // 换目录放主线程：要先停后端（壳的 stopBackend 只在主线程用），
                // 换完还要在同一个 runloop 里把后端带起来。
                DispatchQueue.main.async {
                    let outcome = self.promoteAndRestart(staging: staging, version: candidate.version)
                    self.isRunning = false
                    completion(outcome)
                }
            }
        }
    }

    /// 取消只对 staging 阶段有意义：pnpm 还没装完，杀了它、删掉半成品，后端一点没动。
    func cancel() {
        lock.lock()
        cancelled = true
        let process = child
        lock.unlock()
        process?.terminate()
    }

    // MARK: staging（后台线程）

    private func stage(_ candidate: BackendCandidate) -> RuntimeStep<URL> {
        let runtime = runtimeDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtime.path) else {
            return .failure("找不到运行时目录：\(runtime.path)")
        }
        guard fm.isWritableFile(atPath: runtime.path) else {
            return .failure("没有写权限：\(runtime.path)\n"
                + "macOS 14+ 还可能是「系统设置 › 隐私与安全性 › App 管理」拦着，"
                + "给 dshX 打开这一项再试。")
        }

        let staging = stagingDirectory(in: runtime, version: candidate.version)
        report(.prepare, "正在准备 staging 目录…")
        do {
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try stagingPackageJSON(version: candidate.version)
                .write(to: staging.appendingPathComponent("package.json"))
        } catch {
            return .failure("准备 staging 失败：\(error.localizedDescription)\n"
                + permissionHint(for: error, target: staging.path))
        }

        report(.install, "正在安装 \(dshPackageName)@\(candidate.version)…", within: 0)
        if case .failure(let message) = runPnpmInstall(staging: staging) {
            try? fm.removeItem(at: staging)
            return .failure(message)
        }

        let stagedNodeModules = staging.appendingPathComponent("node_modules", isDirectory: true)
        report(.verify, "正在探活新树（dsh --version）…")
        let entry = stagedNodeModules.appendingPathComponent("\(dshPackageName)/lib/bin.js")
        guard let reported = runDshVersion(entry: entry) else {
            try? fm.removeItem(at: staging)
            return .failure("新树跑不起来：`node …/dsh/lib/bin.js --version` 没有输出。\n"
                + "多半是依赖没装全；pnpm 的原始输出在日志里。")
        }
        guard reported == candidate.version else {
            try? fm.removeItem(at: staging)
            return .failure("装出来的版本是 \(reported)，不是 \(candidate.version)，"
                + "已放弃这次更新（staging 已删，后端没动）。")
        }

        report(.sign, "正在给原生模块签名…")
        let signing = signNativeArtifacts(
            in: stagedNodeModules,
            log: { line in shellLog("[runtime] \(line)") },
            onProgress: { [weak self] done, total in
                self?.report(.sign, "正在给原生模块签名…（\(done)/\(total)）",
                             within: total > 0 ? Double(done) / Double(total) : -1)
            })
        shellLog("dsh 后端 \(candidate.version)：原生文件签名 \(signing.signed) 个，"
            + "失败 \(signing.failed.count) 个")
        guard signing.failed.isEmpty else {
            try? fm.removeItem(at: staging)
            return .failure("有 \(signing.failed.count) 个原生文件签名失败，已放弃这次更新"
                + "（arm64 上没签名的原生代码会被内核直接杀掉）。")
        }

        if cancelled {
            try? fm.removeItem(at: staging)
            return .failure("已取消这次更新（staging 已删，后端没动）。")
        }
        do {
            try writeStagedMarker(in: staging, version: candidate.version)
        } catch {
            try? fm.removeItem(at: staging)
            return .failure("写 staging 标记失败：\(error.localizedDescription)")
        }
        return .success(staging)
    }

    /// 用内置 Node 跑内置 pnpm，把依赖装进 staging。输出实时转成进度与日志。
    private func runPnpmInstall(staging: URL) -> RuntimeStep<Void> {
        guard let node = bundledNodePath() else {
            return .failure("找不到可执行的 Node（DSHX_NODE 可指定）。")
        }
        guard let pnpm = bundledPnpmScript() else {
            return .failure("找不到内置的 pnpm（\(dshPackageName) 的依赖得靠它装）。"
                + "DSHX_PNPM 可指定其它 pnpm.cjs。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        // hoisted 布局：跟打进包的 npm ci 那棵树一样是扁平 node_modules，
        // 少一类「上游代码假设了目录形状」的兼容问题。store 用完就删，见 removePnpmStoreIfTemporary。
        process.arguments = [pnpm, "install",
                             "--prod",
                             "--node-linker=hoisted",
                             "--no-frozen-lockfile",
                             "--reporter=append-only",
                             // 别在进度里插「pnpm 有新版本」的横幅：那是给开发者看的，
                             // 对这次更新没用，还会把进度文案顶掉（顺带省一次网络检查）。
                             "--config.update-notifier=false",
                             "--store-dir", pnpmStoreDirectory().path,
                             "--registry", npmRegistryRoot()]
        process.currentDirectoryURL = staging
        process.environment = childEnvironment(node: node)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // pnpm 的进度是一行行刷的：每行都写进 backend.log，能解析出计数的行
        // （`Progress:` / `Packages:`）额外转成进度——见 parsePnpmProgress。
        let handle = pipe.fileHandleForReading
        let progressLock = NSLock()
        var progressState = PnpmInstallProgress.start
        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(whereSeparator: { $0.isNewline }) where !line.isEmpty {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                shellLog("[pnpm] \(trimmed)")
                // 管道回调在后台线程，解析状态要串起来；两个管道共用一个 handler，
                // 不加锁会让 resolved/added 交错着丢帧。
                progressLock.lock()
                progressState = parsePnpmProgress(trimmed, state: progressState)
                let frame = progressState
                progressLock.unlock()
                self?.report(.install, frame.text, within: frame.fraction)
            }
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return .failure("无法启动内置 pnpm：\(error.localizedDescription)")
        }
        lock.lock(); child = process; lock.unlock()
        process.waitUntilExit()
        lock.lock(); child = nil; lock.unlock()
        handle.readabilityHandler = nil

        if cancelled {
            return .failure("已取消这次更新（staging 已删，后端没动）。")
        }
        guard process.terminationStatus == 0 else {
            return .failure("pnpm 安装失败（退出码 \(process.terminationStatus)）。\n"
                + "常见原因：网络/代理到不了 \(npmRegistryRoot())（可设 DSHX_NPM_REGISTRY "
                + "指镜像）、磁盘空间不够。pnpm 的原始输出在日志里。")
        }
        let lockFile = staging.appendingPathComponent("pnpm-lock.yaml")
        if !FileManager.default.fileExists(atPath: lockFile.path) {
            return .failure("pnpm 报告成功但没有产出 pnpm-lock.yaml，安装不完整。")
        }
        return .success(())
    }

    // MARK: 提升（主线程）

    private func promoteAndRestart(staging: URL, version: String) -> RuntimeStep<Outcome> {
        let runtime = runtimeDirectory()
        let current = installedBackendVersion(in: runtime)
        if let otherBackends {
            let conflicts = otherBackends()
            if !conflicts.isEmpty {
                let list = conflicts.map { "  • \($0.text)" }.joined(separator: "\n")
                return .failure("还有其它 dsh 后端在使用同一个 DSH_HOME：\n\(list)\n"
                    + "它们会占住会话写锁，也可能正 mmap 着要替换的 runtime。"
                    + "先退出这些后端再更新；重启 dshX 时启动检查会帮你清理。")
            }
        }
        onPhase?(.promoting)
        report(.promote, "正在停掉后端，准备切换目录…")
        stopBackend?()
        let result = promoteRuntime(runtimeDir: runtime, staging: staging,
                                   version: version, currentVersion: current)
        switch result {
        case .success:
            report(.finish, "正在收尾（换 package.json、裁备份、删 staging 与 pnpm store）…")
            finishPromotion(runtimeDir: runtime, staging: staging)
            resignAppBundle()
        case .failure:
            break
        }
        // 不管成没成，后端都得带起来：失败时用的是回滚后的旧树。
        report(.restart, "正在重新拉起 dsh 后端…")
        startBackend?()
        switch result {
        case .failure(let message):
            return .failure(message)
        case .success:
            let backup = backupDirectory(in: runtime, version: current).path
            return .success(Outcome(version: version, backupPath: backup,
                                    registry: npmRegistryRoot()))
        }
    }

    /// 换过 Resources 之后包内封条已经对不上，按原身份重新签一次，让
    /// `codesign --verify` 重新通过、并保住 macOS 隐私授权。签不动也只记日志，
    /// 不影响已经跑起来的 App。
    @discardableResult
    private func resignAppBundle() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let identity = currentSigningIdentity(of: bundle)
        report(.resign, "正在重新签名 .app（整个包，几百 MB，要一会儿）…")
        shellLog("重新签名 .app，身份：\(identity)")
        var result = runProcess("/usr/bin/codesign",
                                ["--force", "--sign", identity, "--timestamp=none", bundle.path],
                                timeout: 300)
        if result.status != 0, identity != "-" {
            // 证书用不了（钥匙串被锁、证书过期、用户拒绝了钥匙串授权…）时不能就这么
            // 收场：那会把包留在「封条已坏」的状态，下次启动可能被判成损坏。退回
            // ad-hoc 至少让包重新可校验——代价是 requirement 变成 cdhash，录屏等
            // 隐私授权要重新允许一次。
            shellLog("用身份「\(identity)」重签失败，退回 ad-hoc 补救（隐私授权会失效）："
                + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            result = runProcess("/usr/bin/codesign",
                                ["--force", "--sign", "-", "--timestamp=none", bundle.path],
                                timeout: 300)
        }
        guard result.status == 0 else {
            shellLog("重新签名 .app 失败（不影响使用）："
                + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        let verify = runProcess("/usr/bin/codesign", ["--verify", "--verbose=1", bundle.path],
                                timeout: 120)
        shellLog(verify.status == 0
            ? "换完后 .app 签名校验通过：\(bundle.path)"
            : "换完后 .app 签名校验没过（不影响使用）：\(verify.output)")
        return verify.status == 0
    }

    private func report(_ stage: RuntimeStage, _ text: String, within: Double = -1) {
        let frame = RuntimeProgress(stage: stage, text: text,
                                    fraction: overallProgress(stage, within: within))
        if Thread.isMainThread {
            onProgress?(frame)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onProgress?(frame) }
        }
    }
}

/// staging 的 package.json：只钉一个依赖，版本写死（不给 ^，免得又解析到别的版本）。
func stagingPackageJSON(version: String) -> Data {
    let payload: [String: Any] = [
        "name": "dshX-runtime-staging",
        "private": true,
        "version": "1.0.0",
        "dependencies": [dshPackageName: version],
    ]
    return (try? JSONSerialization.data(withJSONObject: payload,
                                        options: [.prettyPrinted, .sortedKeys]))
        ?? Data(#"{"private":true,"dependencies":{"@deepseek-ai/dsh":"\#(version)"}}"#.utf8)
}

// MARK: - 界面（菜单「更新 dsh 后端…」的宿主）

/// 只管展示：结论弹窗、进度面板、取消。判断与执行都在 RuntimeInstaller 里。
final class RuntimeUpdater: NSObject {
    static let shared = RuntimeUpdater()

    private let installer = RuntimeInstaller()
    private var panelWindow: NSWindow?
    private var stepLabel: NSTextField?
    private var doingLabel: NSTextField?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var cancelButton: NSButton?
    private var ticker: Timer?
    private var tickStarted = Date()
    /// 当前这一步在做什么（面板第二行）。计时每秒重画一次，所以得留着。
    private var currentFrame: RuntimeProgress?
    private var busy = false

    override init() {
        super.init()
        installer.onProgress = { [weak self] frame in self?.setProgress(frame) }
        installer.onPhase = { [weak self] phase in
            self?.cancelButton?.isEnabled = (phase == .staging)
        }
    }

    /// 壳在启动时注入：换目录前必须停掉后端，换完立刻重启；
    /// `conflicts` 要排除壳自己那个后端，只报剩下的其它 dsh 后端。
    func wireBackend(stop: @escaping () -> Void, start: @escaping () -> Void,
                     conflicts: @escaping () -> [BackendConflict]) {
        installer.stopBackend = stop
        installer.startBackend = start
        installer.otherBackends = conflicts
    }

    /// 菜单入口：查 npm registry 上有没有比现装更新的 dsh 后端。
    @objc func check() {
        guard !busy else { return }
        busy = true
        installer.check { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.present(result)
        }
    }

    /// 启动时收尾：上一次更新如果装完了却没来得及切换（崩溃、强杀），在这一刻补上。
    /// 此刻后端还没起来，没有任何进程还在用旧树，是换目录最安全的时机。
    func adoptStagedAtLaunchIfAny() {
        let runtime = runtimeDirectory()
        let nodeModules = runtime.appendingPathComponent("node_modules", isDirectory: true)
        // 先处理「上次切换被拆成两半」的现场：没有 node_modules 但有备份时，把最新的
        // 那份挪回去。这一幕只可能由崩溃/强杀造成（正常路径两步是连着做完的）。
        if let rescue = rescueCandidate(in: runtime) {
            shellLog("启动修复：把 \(rescue.lastPathComponent) 挪回 node_modules")
            do {
                try FileManager.default.moveItem(at: rescue, to: nodeModules)
            } catch {
                shellLog("挪回失败：\(error.localizedDescription)")
            }
        }
        let installed = installedBackendVersion(in: runtime)
        for staged in stagedDirectories(in: runtime) {
            guard let info = stagedRuntime(in: staged) else {
                shellLog("清理没装完的 dsh 后端 staging：\(staged.lastPathComponent)")
                try? FileManager.default.removeItem(at: staged)
                continue
            }
            guard versionOrder(info.version, installed ?? "0.0.0") == .orderedDescending else {
                shellLog("staging \(info.version) 不比现装版本 \(installed ?? "无") 新，删掉")
                try? FileManager.default.removeItem(at: staged)
                continue
            }
            shellLog("接管上次没切换完的 dsh 后端 \(info.version)（现装 \(installed ?? "未知")）")
            switch promoteRuntime(runtimeDir: runtime, staging: staged,
                                  version: info.version, currentVersion: installed) {
            case .success:
                finishPromotion(runtimeDir: runtime, staging: staged)
                shellLog("启动时切换完成：dsh 后端 \(info.version)")
            case .failure(let message):
                shellLog("启动时切换失败，继续用旧后端：\(message)")
            }
        }
    }

    // MARK: 弹窗

    private func present(_ result: RuntimeStep<BackendUpdateQuery>) {
        switch result {
        case .failure(let message):
            alert(style: .warning, title: "检查 dsh 后端更新失败",
                  body: message + "\n\n日志：\(logFileURL.path)")
        case .success(let query):
            guard let candidate = query.candidate else {
                alert(title: "dsh 后端已是最新", body: """
                    当前后端：\(query.current ?? "未知")
                    源上最新：\(query.latestPublished ?? "未知")
                    更新源：  \(query.registry)/\(dshPackageName)
                    安装位置：\(runtimeDirectory().path)/node_modules

                    壳（dshX）本身的更新走另一条：菜单「检查更新…」（⌘U）。
                    """)
                return
            }
            confirm(candidate: candidate, query: query)
        }
    }

    private func confirm(candidate: BackendCandidate, query: BackendUpdateQuery) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "发现新版 dsh 后端 \(candidate.version)"
            + "（当前 \(query.current ?? "未知")）"
        alert.informativeText = """
        当前后端：\(query.current ?? "未知")
        最新后端：\(candidate.version)（\(candidate.origin)）
        更新源：  \(query.registry)/\(dshPackageName)
        安装到：  \(runtimeDirectory().path)/node_modules
        可用空间：\(freeDiskText(at: runtimeDirectory()))

        「更新并重启后端」= 用 App 内置的 Node + pnpm 把新版装到 runtime 里（先装到
        staging、探活、给原生模块签名）→ 停掉后端 → 换目录 → 重新拉起后端。
        壳不退出，dshX 的版本号也不变；旧后端留一份备份可回退。
        会中断当前正在跑的会话；安装通常一两分钟，取决于网速与上游依赖大小。
        """
        alert.addButton(withTitle: "更新并重启后端")
        alert.addButton(withTitle: "取消")
        guard run(alert) == .alertFirstButtonReturn else {
            shellLog("用户取消了 dsh 后端更新。")
            return
        }

        busy = true
        showPanel("正在安装 \(dshPackageName)@\(candidate.version)…", cancellable: true)
        shellLog("开始更新 dsh 后端：\(candidate.version)（\(candidate.origin)）")
        installer.install(candidate: candidate) { [weak self] result in
            guard let self else { return }
            self.closePanel()
            self.busy = false
            switch result {
            case .failure(let message):
                self.alert(style: .warning, title: "dsh 后端更新没有完成",
                           body: message + "\n\n日志：\(logFileURL.path)")
            case .success(let outcome):
                var body = "后端已重启，页面正在重新载入。\n"
                    + "版本：\(outcome.version)\n"
                    + "更新源：\(outcome.registry)/\(dshPackageName)"
                if let backup = outcome.backupPath,
                   FileManager.default.fileExists(atPath: backup) {
                    body += "\n旧版本备份：\(backup)"
                        + "\n（想回退：退出 dshX，删掉新的 node_modules，"
                        + "把这份备份改回 node_modules 再打开。）"
                }
                body += "\n日志：\(logFileURL.path)"
                self.alert(title: "dsh 后端已更新到 \(outcome.version)", body: body)
            }
        }
    }

    @discardableResult
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.mainWindow ?? NSApp.keyWindow)?.makeKeyAndOrderFront(nil)
        return alert.runModal()
    }

    private func alert(style: NSAlert.Style = .informational, title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        run(alert)
    }

    // MARK: 进度面板

    /// 面板上四行：第几步 → 这一步在做什么 → 确定的进度条 → 计时。
    /// 进度条是**确定型**的：整条链路的百分比由 RuntimeStage 的权重算出来
    /// （见 overallProgress），不再是以前那个只会转圈的 spinner——「装到哪了」
    /// 是这条链路最该回答的问题，转圈答不了。
    private func showPanel(_ title: String, cancellable: Bool) {
        closePanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 126),
                              styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "\(appTitle) 后端更新"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 126))
        let step = NSTextField(labelWithString: title)
        step.frame = NSRect(x: 20, y: 92, width: 440, height: 20)
        step.lineBreakMode = .byTruncatingMiddle
        step.font = .boldSystemFont(ofSize: 13)
        let doing = NSTextField(labelWithString: "准备中…")
        doing.frame = NSRect(x: 20, y: 70, width: 440, height: 18)
        doing.lineBreakMode = .byTruncatingTail
        doing.textColor = .secondaryLabelColor
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 44, width: 440, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        let hint = NSTextField(labelWithString:
            "装到 staging，装完探活通过才切换；进度按步骤加权，切换那一步改目录改到一半不能取消。")
        hint.frame = NSRect(x: 20, y: 24, width: 440, height: 16)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelUpdate))
        cancel.frame = NSRect(x: 380, y: 0, width: 80, height: 24)
        cancel.isEnabled = cancellable
        content.addSubview(step)
        content.addSubview(doing)
        content.addSubview(bar)
        content.addSubview(hint)
        content.addSubview(cancel)
        window.contentView = content
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panelWindow = window
        stepLabel = step
        doingLabel = doing
        progressBar = bar
        cancelButton = cancel
        tickStarted = Date()
        // 计时每秒重画一次：某个步骤没有可报的分母（rename、codesign）时，
        // 「已 N 秒」是唯一能证明它还在动的东西。
        ticker = Timer.scheduledTimer(timeInterval: 1, target: self,
                                      selector: #selector(tick), userInfo: nil, repeats: true)
    }

    private func setProgress(_ frame: RuntimeProgress) {
        currentFrame = frame
        // 引擎只管报进度，面板在这里按需长出来（第一帧就是「准备 staging」）。
        if panelWindow == nil {
            showPanel("正在更新 dsh 后端…", cancellable: true)
        }
        render()
    }

    /// 把当前这一帧画出来。计时器每秒也走这里，所以文案拼装只有一处。
    private func render() {
        guard let frame = currentFrame else { return }
        let seconds = Int(Date().timeIntervalSince(tickStarted))
        stepLabel?.stringValue = "第 \(frame.stage.stepNumber)/\(RuntimeStage.stepCount) 步"
            + "　\(Int((frame.fraction * 100).rounded()))%"
        doingLabel?.stringValue = "\(frame.text)（已 \(seconds) 秒）"
        progressBar?.doubleValue = min(max(frame.fraction, 0), 1)
        panelWindow?.displayIfNeeded()
    }

    @objc private func tick() {
        render()
    }

    private func closePanel() {
        ticker?.invalidate()
        ticker = nil
        panelWindow?.orderOut(nil)
        panelWindow = nil
        stepLabel = nil
        doingLabel = nil
        progressBar = nil
        cancelButton = nil
        currentFrame = nil
    }

    @objc private func cancelUpdate() {
        cancelButton?.isEnabled = false
        currentFrame = RuntimeProgress(stage: currentFrame?.stage ?? .install,
                                       text: "正在取消…",
                                       fraction: currentFrame?.fraction ?? 0)
        render()
        installer.cancel()
    }
}

// MARK: - 零碎

func freeDiskText(at url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    if let capacity = values?.volumeAvailableCapacityForImportantUsage {
        return String(format: "%.1f GB", Double(capacity) / 1_073_741_824)
    }
    return "未知"
}
