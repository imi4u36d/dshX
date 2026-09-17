import AppKit
import WebKit

/*
 插件市场（壳侧）：把「npm 上标记 dsh-bundle 的官方插件生态」做成一键安装。

 机制与上游一致，不新造安装协议：
   dsh 的插件安装通道只有一条 —— `dsh plugin --profile <name> add <spec>`
   （它在 $DSH_HOME/profiles/<name>/ 里转发给 pnpm，装完把声明了 dsh.bundle
   的包 reconcile 进 profile manifest 的 dsh.profile.bundles 层栈）。本文件只是
   给这条通道配一个目录数据源 + 原生入口：
   1. 目录（catalog）：默认取 npm registry 的 search API（keywords:dsh-bundle），
      这是当前事实上「官方插件市场」的数据面；缓存进私有目录，24 小时内复用，
      失败退回缓存/App 内置的 catalog.json。
      search 响应里其实带着 keywords / publisher / license / links / downloads /
      score / updated，全部保留下来——热门榜（周下载量）与详情页都要用。
   2. 一键安装：页面按钮 → WKScriptMessageHandler 桥 → 后台起子进程
      `node <bin.js> plugin --profile <active> add|remove <spec>`，成功后可一键
      重启后端让新层栈生效。

 界面（壳侧自绘的 HTML，不加载任何远程代码）：
   · 正方形网格卡片：展示图 + 名称/版本/下载量/两行简介 + 安装状态角标
   · 搜索：名称、描述、关键词三路匹配，纯本地过滤（目录最多几百条）
   · 榜单：热门（npm 周下载量，默认）/ 最新（updated）/ 名称
   · 点卡片 → 大尺寸详情弹窗：横幅大图、作者、许可、更新时间、下载量、
     关键词、npm/仓库/主页外链、将要执行的确切 spec、安装/卸载按钮
   · 主题：读 $DSH_HOME/settings.yaml 的 ui-theme.preference（light/dark/system），
     与 APP 里的外观设置保持一致；system 时跟随系统外观实时切换

 关于展示图：npm 元数据里没有图标字段，所以从 repository 推导 GitHub 归属者
 头像（正方形，适合卡片）与仓库 OG 卡片图（宽图，适合详情横幅）。OG 图会被
 GitHub 间歇性限流（429），所以只当渐进增强——加载失败就退回「首字母 + 名字
 哈希配色」的图块，永不空白。图片一律 no-referrer 直连，不经任何中转。

 刻意保持的边界：
    - ad-hoc 签名的本地自用壳：一键安装 = 在你的机器上跑第三方代码。所以每个
      动作都先弹确认框（spec 全文），且市场窗口一次只跑一个安装。
    - catalog 只是数据：目录里的描述/关键词全部以 textContent 注入，不当 HTML 解析；
      页面不加载任何远程脚本，只加载远程图片。
 */

// MARK: - 目录数据

/// 一条插件（把两种数据源归一化后的形状）。除 name/version 外全部可选：
/// 内置 catalog.json 的 v1 只有 name/version/description，npm 原始响应又缺
/// iconURL/coverURL，所以每一层都按「能拿到就用，拿不到就退」处理。
private struct Plugin {
    let name: String
    let version: String
    let summary: String
    let keywords: [String]
    let publisher: String?
    let license: String?
    let updated: String?
    let npmURL: String?
    let repoURL: String?
    let homepageURL: String?
    let weekly: Int?
    let monthly: Int?
    let score: Double?
    let iconURL: String?
    let coverURL: String?
}

/// 策展/内置形态：{catalogVersion,plugins:[…]}。v1 只有三个字段，v2 起带上热度与链接。
/// 同时可编码：在线合并出来的目录也按这个形状写进缓存，缓存与内置种子因此同构。
private struct CatalogDoc: Codable {
    struct Links: Codable {
        let npm: String?
        let repository: String?
        let homepage: String?
    }
    struct Downloads: Codable {
        let weekly: Int?
        let monthly: Int?
    }
    struct Score: Codable {
        let final: Double?
        let popularity: Double?
    }
    struct Entry: Codable {
        let name: String
        let version: String
        let description: String?
        let keywords: [String]?
        let publisher: String?
        let license: String?
        let updated: String?
        let links: Links?
        let downloads: Downloads?
        let score: Score?
        let iconURL: String?
        let coverURL: String?

        init(plugin: Plugin) {
            name = plugin.name
            version = plugin.version
            description = plugin.summary
            keywords = plugin.keywords
            publisher = plugin.publisher
            license = plugin.license
            updated = plugin.updated
            links = Links(npm: plugin.npmURL, repository: plugin.repoURL, homepage: plugin.homepageURL)
            downloads = Downloads(weekly: plugin.weekly, monthly: plugin.monthly)
            score = Score(final: plugin.score, popularity: nil)
            iconURL = plugin.iconURL
            coverURL = plugin.coverURL
        }
    }
    let catalogVersion: Int?
    let plugins: [Entry]
}

/// npm search 原始响应：{objects:[{package:{…},downloads:{…},score:{…}}]}。
/// 字段比内置的深一层（publisher.username、score.detail.popularity）。
private struct CatalogSearch: Decodable {
    struct Row: Decodable {
        struct Publisher: Decodable { let username: String? }
        struct Package: Decodable {
            let name: String
            let version: String
            let description: String?
            let keywords: [String]?
            let license: String?
            let date: String?
            let links: CatalogDoc.Links?
            let publisher: Publisher?
        }
        struct Downloads: Decodable {
            let weekly: Int?
            let monthly: Int?
        }
        struct Score: Decodable {
            struct Detail: Decodable { let popularity: Double? }
            let final: Double?
            let detail: Detail?
        }
        let package: Package
        let downloads: Downloads?
        let updated: String?
        let searchScore: Double?
        let score: Score?
    }
    let objects: [Row]
    /// 该关键词命中的总数：翻页要靠它判断何时拉完。
    let total: Int?
}

/// 从 GitHub 链接里抠 owner/repo，用来推导展示图；非 GitHub 返回 nil。
private func githubParts(_ url: String?) -> (owner: String, repo: String)? {
    guard let url, !url.isEmpty,
          let regex = try? NSRegularExpression(pattern: #"github\.com[:/]+([^/]+)/([^/#?]+)"#,
                                              options: [.caseInsensitive]) else { return nil }
    let text = url as NSString
    guard let match = regex.firstMatch(in: url, range: NSRange(location: 0, length: text.length)),
          match.numberOfRanges >= 3 else { return nil }
    let owner = text.substring(with: match.range(at: 1))
    var repo = text.substring(with: match.range(at: 2))
    if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
    guard !owner.isEmpty, !repo.isEmpty, owner.lowercased() != "github.com" else { return nil }
    return (owner, repo)
}

/// 数据里已带图就直接用；否则从 repository/homepage 推导。两者都拿不到就留空，
/// 由页面退回生成图块。
private func derivedImages(repository: String?, homepage: String?,
                           icon: String?, cover: String?) -> (icon: String?, cover: String?) {
    if icon != nil || cover != nil { return (icon, cover) }
    guard let parts = githubParts(repository) ?? githubParts(homepage) else { return (nil, nil) }
    return ("https://github.com/\(parts.owner).png?size=200",
            "https://opengraph.githubassets.com/1/\(parts.owner)/\(parts.repo)")
}

private func plugin(from entry: CatalogDoc.Entry) -> Plugin {
    let images = derivedImages(repository: entry.links?.repository,
                              homepage: entry.links?.homepage,
                              icon: entry.iconURL, cover: entry.coverURL)
    return Plugin(name: entry.name, version: entry.version, summary: entry.description ?? "",
                  keywords: entry.keywords ?? [], publisher: entry.publisher,
                  license: entry.license, updated: entry.updated,
                  npmURL: entry.links?.npm ?? "https://www.npmjs.com/package/\(entry.name)",
                  repoURL: entry.links?.repository, homepageURL: entry.links?.homepage,
                  weekly: entry.downloads?.weekly, monthly: entry.downloads?.monthly,
                  score: entry.score?.final, iconURL: images.icon, coverURL: images.cover)
}

private func plugin(from row: CatalogSearch.Row) -> Plugin {
    let images = derivedImages(repository: row.package.links?.repository,
                              homepage: row.package.links?.homepage,
                              icon: nil, cover: nil)
    return Plugin(name: row.package.name, version: row.package.version,
                  summary: row.package.description ?? "", keywords: row.package.keywords ?? [],
                  publisher: row.package.publisher?.username, license: row.package.license,
                  updated: row.updated ?? row.package.date,
                  npmURL: row.package.links?.npm ?? "https://www.npmjs.com/package/\(row.package.name)",
                  repoURL: row.package.links?.repository, homepageURL: row.package.links?.homepage,
                  weekly: row.downloads?.weekly, monthly: row.downloads?.monthly,
                  score: row.score?.final ?? row.searchScore,
                  iconURL: images.icon, coverURL: images.cover)
}

private enum Catalog {
    case curated([Plugin], source: String)   // 策展清单：全部未验证
    case packages([Plugin], source: String)  // npm 原始数据：官方生态
    case empty

    var entries: [Plugin] {
        switch self {
        case .curated(let list, _): return list
        case .packages(let list, _): return list
        case .empty: return []
        }
    }

    var source: String {
        switch self {
        case .curated(_, let source): return "策展清单 \(source)（未验证）"
        // 不再在这里写死关键词：内置种子与在线缓存都出自 npm，具体查了什么由调用方说清。
        case .packages(_, let source): return "npm 官方生态 · \(source)"
        case .empty: return "没有目录（检查网络，或设 DSH_PLUGIN_CATALOG 指到本地文件）"
        }
    }

    var unvetted: Bool {
        if case .curated = self { return true }
        return false
    }
}

/// 同样一份 `{catalogVersion,plugins}`，出自 npm（内置种子、在线缓存）还是用户自备的
/// 策展文件，语义完全不同：前者是官方生态清单，后者是人工维护的未验证清单。
/// **按来源判定，而不是按 JSON 形状判定**——内置种子和在线缓存也是这个形状。
private enum CatalogOrigin {
    case npm
    case file
}

/// 解析一种 catalog 形态；失败返回 nil 让调用方退回下一级来源。
private func decodeCatalog(_ data: Data, source: String,
                           origin: CatalogOrigin = .file) -> Catalog? {
    if let doc = try? JSONDecoder().decode(CatalogDoc.self, from: data),
       doc.catalogVersion == nil || (1...2).contains(doc.catalogVersion ?? 0) {
        let plugins = doc.plugins.map(plugin(from:))
        return origin == .npm ? .packages(plugins, source: source)
                              : .curated(plugins, source: source)
    }
    // npm search 的原始响应只有一种解读：官方生态。
    if let search = try? JSONDecoder().decode(CatalogSearch.self, from: data) {
        return .packages(search.objects.map(plugin(from:)), source: source)
    }
    return nil
}

/// 读取顺序：env 指定的本地文件 → 24h 内缓存 → App 内置 → 过期缓存 → 空。
private func loadCatalog(privateFile: String?, cacheFile: URL, bundledFile: URL) -> Catalog {
    let fm = FileManager.default
    if let path = privateFile, !path.isEmpty, let data = fm.contents(atPath: path),
       let catalog = decodeCatalog(data, source: path, origin: .file) {
        return catalog
    }
    let cacheAge: TimeInterval? = (try? fm.attributesOfItem(atPath: cacheFile.path)[.modificationDate])
        .flatMap { ($0 as? Date).map { Date().timeIntervalSince1970 - $0.timeIntervalSince1970 } }
    if let age = cacheAge, age < 86_400,
       let data = fm.contents(atPath: cacheFile.path),
       let catalog = decodeCatalog(data, source: "缓存 \(Int(age / 3600))h 前刷新", origin: .npm) {
        return catalog
    }
    if let data = fm.contents(atPath: bundledFile.path),
       let catalog = decodeCatalog(data, source: "App 内置种子（建议刷新）", origin: .npm) {
        return catalog
    }
    if let data = fm.contents(atPath: cacheFile.path),
       let catalog = decodeCatalog(data, source: "缓存，已过期，建议刷新", origin: .npm) {
        return catalog
    }
    return .empty
}

/// 复用 resolvePlan 的解析链（node、bin.js、DSH_HOME、workspace）。失败返回 nil，
/// 由调用方决定退路：市场入口直接报错，子进程参数退回可执行名与默认目录。
private func currentPlan() -> RuntimePlan? {
    if case .success(let plan) = resolvePlan() { return plan }
    return nil
}

/// 从 profile 的 package.json 读「已安装 / 在层栈」。
private func loadProfileState(profileDir: URL) -> (installed: Set<String>, active: Set<String>) {
    guard let data = FileManager.default.contents(atPath: profileDir.appendingPathComponent("package.json").path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (Set(), Set())
    }
    let installed = Set((json["dependencies"] as? [String: Any])?.keys ?? [:].keys)
    let bundles = ((json["dsh"] as? [String: Any])?["profile"] as? [String: Any])?["bundles"] as? [String] ?? []
    return (installed, Set(bundles))
}

/// 一次 GET 的结果。URLSession 的回调在别的线程上跑，而调用方可能已经等超时走了，
/// 所以用锁包一层，避免读写捕获变量时的竞态。
private final class HTTPResult {
    private let lock = NSLock()
    private var data: Data?
    private var status = 0
    private var retryAfter: Double?

    func record(data: Data?, status: Int, retryAfter: Double?) {
        lock.lock(); defer { lock.unlock() }
        self.data = data
        self.status = status
        self.retryAfter = retryAfter
    }

    var snapshot: (data: Data?, status: Int, retryAfter: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (data, status, retryAfter)
    }
}

// MARK: - 市场控制器

final class MarketController: NSObject, WKScriptMessageHandler {
    static let shared = MarketController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var profileName = "web"
    private var themePref = "system"
    private var keyObserver: NSObjectProtocol?
    private var busy = false
    /// 已渲染内容的名字/版本/状态/主题指纹：全量目录下重载整页代价不小，
    /// 在线刷新若拿回同样的内容就跳过，免得丢掉用户已输入的搜索词与滚动位置。
    private var renderedSignature: String?

    // MARK: 入口（菜单「插件」→「插件市场…」）

    @objc func show() {
        switch resolvePlan() {
        case .failure(let message):
            presentAlert("无法定位插件安装所需的文件：\(message)")
            return
        case .success:
            break
        }
        profileName = envString("DSH_APP_PROFILE").flatMap { $0.isEmpty ? nil : $0 } ?? "web"

        if window == nil {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(self, name: "dshxMarket")
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780),
                                    configuration: configuration)
            webView.allowsMagnification = false
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "dshX · 插件市场"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 520)
            window.center()
            window.contentView = webView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = window
            self.webView = webView
            // 市场窗口开着时用户回主界面切了日/夜，再切回来要能跟上。
            self.keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.refreshThemeIfChanged()
            }
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // 每次打开都重读一次外观偏好：用户可能刚在 APP 里切过主题。
        if let window { themePref = applyTheme(to: window) }
        showPage(refreshingRemote: true)
    }

    /// 主线程。先用本地数据画出页面，再在后台刷远程目录，回来重画。
    /// 主线程。先用本地数据画出页面，再在后台刷远程目录。
    /// - Parameter applyRemote: 远程结果是否立刻换到界面上。
    ///   自动刷新（打开市场时）传 false：全量目录的在线结果几乎必然与本地种子不同
    ///   ——下载量一直在变——直接重画会把用户正在输入的搜索词和滚动位置冲掉。
    ///   写进缓存、下次打开生效即可；用户显式点「刷新」时才立刻换。
    private func showPage(refreshingRemote: Bool, applyRemote: Bool = false) {
        guard let webView else { return }
        let privateFile = envString("DSH_PLUGIN_CATALOG")
        let cacheFile = catalogCacheURL
        let bundledFile = (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))
            .appendingPathComponent("catalog.json")
        let local = loadCatalog(privateFile: privateFile, cacheFile: cacheFile,
                                bundledFile: bundledFile)
        render(catalog: local, in: webView, note: "载入本地目录…")
        guard refreshingRemote else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let remote = self.fetchRemoteCatalog()
            DispatchQueue.main.async {
                guard let webView = self.webView else { return }
                guard let remote else {
                    self.render(catalog: self.loadLocalCatalog(privateFile: privateFile,
                                                               cacheFile: cacheFile,
                                                               bundledFile: bundledFile),
                                in: webView, note: "远程目录取不到，退回本地数据")
                    return
                }
                // 本地是空的（内置种子缺失）时，远程结果必须立刻用上。
                guard applyRemote || local.entries.isEmpty else {
                    shellLog("市场远程目录已写入缓存（\(remote.entries.count) 条），下次打开生效")
                    return
                }
                self.render(catalog: remote, in: webView, note: "目录已是最新")
            }
        }
    }

    private func loadLocalCatalog(privateFile: String?, cacheFile: URL, bundledFile: URL) -> Catalog {
        loadCatalog(privateFile: privateFile, cacheFile: cacheFile, bundledFile: bundledFile)
    }

    // MARK: 远程目录（后台线程）

    /// 上游约定插件仓库打 `dsh-plugin` 话题（见 deepseek-harness 的 README 与
    /// CONTRIBUTING：https://github.com/topics/dsh-plugin）。壳最初只查了
    /// `keywords:dsh-bundle`——那是个与字段名同款、几乎没人用的标签，只覆盖生态的
    /// 约 2%（实测 83 / 4972）。所以这里两路都查、取并集：dsh-plugin 为主，
    /// dsh-bundle 兜住早期条目。
    private static let searchKeywords = ["dsh-plugin", "dsh-bundle"]
    private static let searchPageSize = 250   // npm search 的单页上限
    private static let searchPageLimit = 24   // 6000 条上限，防跑飞

    private func fetchRemoteCatalog() -> Catalog? {
        if let custom = envString("DSH_PLUGIN_CATALOG"), !custom.isEmpty { return nil }
        if let override = envString("DSH_PLUGIN_CATALOG_URL"), !override.isEmpty {
            return fetchCatalog(from: override)
        }
        var merged: [String: Plugin] = [:]
        var parts: [String] = []
        for keyword in Self.searchKeywords {
            let plugins = fetchKeyword(keyword)
            guard !plugins.isEmpty else { continue }
            parts.append("\(keyword) \(plugins.count) 条")
            for plugin in plugins {
                // 同名时保留下载量更高的那份记录
                if let existing = merged[plugin.name], (existing.weekly ?? 0) >= (plugin.weekly ?? 0) {
                    continue
                }
                merged[plugin.name] = plugin
            }
        }
        guard !merged.isEmpty else { return nil }
        let plugins = merged.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        writeCatalogCache(plugins)
        return .packages(plugins, source: parts.joined(separator: " + ") + "（在线）")
    }

    /// 单个关键词翻页拉全。中途失败就返回已拿到的部分，由调用方与另一路合并——
    /// 半份目录也比空手而归强，且页面上会如实标出条数。
    private func fetchKeyword(_ keyword: String) -> [Plugin] {
        var plugins: [Plugin] = []
        var total = Int.max
        var from = 0
        var page = 0
        while from < total && page < Self.searchPageLimit {
            // 页间限速：全量约 20 页，不限速必然被 registry 打成 429。
            if page > 0 { Thread.sleep(forTimeInterval: 0.4) }
            guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://registry.npmjs.org/-/v1/search"
                                + "?text=keywords:\(encoded)&size=\(Self.searchPageSize)&from=\(from)"),
                  let data = httpGet(url) else { break }
            guard let search = try? JSONDecoder().decode(CatalogSearch.self, from: data),
                  !search.objects.isEmpty else { break }
            total = search.total ?? search.objects.count
            plugins.append(contentsOf: search.objects.map(plugin(from:)))
            from += Self.searchPageSize
            page += 1
        }
        shellLog("市场远程目录：keywords:\(keyword) 拉到 \(plugins.count) 条")
        return plugins
    }

    /// 单次 GET，429/5xx/无响应退避重试。返回 nil 表示这一页最终没拿到。
    private func httpGet(_ url: URL, attempts: Int = 5) -> Data? {
        for attempt in 0..<attempts {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 20)
            request.httpMethod = "GET"
            let semaphore = DispatchSemaphore(value: 0)
            let result = HTTPResult()
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let http = response as? HTTPURLResponse
                result.record(data: data, status: http?.statusCode ?? 0,
                              retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 25)

            let (data, status, retryAfter) = result.snapshot
            if status == 200, let data { return data }
            guard attempt < attempts - 1, status == 0 || status == 429 || status >= 500 else { return data }
            let wait = retryAfter ?? min(pow(2, Double(attempt)), 15)
            shellLog("市场远程目录：HTTP \(status)，\(Int(wait))s 后重试（第 \(attempt + 1)/\(attempts) 次）")
            Thread.sleep(forTimeInterval: wait)
        }
        return nil
    }

    /// env 覆盖用的单 URL 形态：可能指向 npm search，也可能指向自备的策展文件。
    private func fetchCatalog(from urlString: String) -> Catalog? {
        guard let url = URL(string: urlString), let data = httpGet(url, attempts: 2),
              let catalog = decodeCatalog(data, source: url.host ?? "远程") else { return nil }
        try? data.write(to: catalogCacheURL)
        return catalog
    }

    /// 把在线合并的结果按与内置种子同构的形状写缓存（CatalogDoc 可编码）。
    /// 只缓存 npm 形态：env 指定的自备目录不该被在线数据覆盖掉。
    private func writeCatalogCache(_ plugins: [Plugin]) {
        let doc = CatalogDoc(catalogVersion: 2, plugins: plugins.map(CatalogDoc.Entry.init(plugin:)))
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? data.write(to: catalogCacheURL)
    }

    /// 目录缓存的位置。文件名带版本是必需的：目录的数据面换过一次
    /// （只查 dsh-bundle 的 83 条 → 按上游约定查 dsh-plugin 的近 5000 条），
    /// 而读取链会优先采用 24h 内的缓存。若沿用旧文件名，装完新版本第一次打开
    /// 市场会拿那份几十条的旧缓存盖住全量种子。换名字让它自然失效——不删除，
    /// 当惰性用户数据留着（与本仓库对旧格式缓存的一贯处理一致）。
    private var catalogCacheURL: URL {
        stateDirectory.appendingPathComponent("plugin-catalog-cache-v2.json")
    }

    private var stateDirectoryURL: URL { stateDirectory }

    // MARK: 主题（跟随 APP 的外观设置）

    /// DSH 的主题偏好存在 $DSH_HOME/settings.yaml 的 ui-theme.preference，取值
    /// light/dark/system。这里只做一次定向扫描、不引 YAML 依赖：顶格键换块，
    /// 块内找 preference；也兼容 `ui-theme: {preference: dark}` 的行内写法。
    private func themePreference() -> String {
        let home = currentPlan()?.home ?? stateDirectory.appendingPathComponent("home")
        guard let text = try? String(contentsOf: home.appendingPathComponent("settings.yaml"),
                                     encoding: .utf8) else { return "system" }
        var inThemeBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // 用 whitespacesAndNewlines：settings.yaml 若被外部工具存成 CRLF，
            // 行尾的 \r 不属于 .whitespaces，会把取值弄成 "light\r" 而静默失配。
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !indented {
                inThemeBlock = trimmed.hasPrefix("ui-theme:")
                if inThemeBlock, let value = self.preferenceValue(in: trimmed) { return value }
                continue
            }
            if inThemeBlock, trimmed.hasPrefix("preference:"),
               let value = self.preferenceValue(in: trimmed) { return value }
        }
        return "system"
    }

    /// 从 "preference: dark" / "ui-theme: {preference: dark}" 里取出并校验取值。
    private func preferenceValue(in text: String) -> String? {
        guard let range = text.range(of: "preference:") else { return nil }
        var value = String(text[range.upperBound...])
        if let end = value.firstIndex(where: { $0 == "," || $0 == "}" || $0 == "#" }) {
            value = String(value[..<end])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
        return ["light", "dark", "system"].contains(value) ? value : nil
    }

    /// 把偏好落到窗口外观上：显式 light/dark 直接钉住（标题栏也跟着变），
    /// system 交回系统。返回实际偏好，供页面内联脚本决定 data-theme。
    @discardableResult
    private func applyTheme(to window: NSWindow) -> String {
        let preference = themePreference()
        switch preference {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
        return preference
    }

    /// 窗口重新获得焦点时重读一次外观偏好：用户可能刚在主界面切过日/夜。
    /// 只做增量更新（改 data-theme），不整页重画，免得丢掉搜索词与滚动位置。
    private func refreshThemeIfChanged() {
        guard let window else { return }
        let preference = themePreference()
        guard preference != themePref else { return }
        themePref = preference
        applyTheme(to: window)
        webView?.evaluateJavaScript("window.__dshxSetTheme && window.__dshxSetTheme('\(preference)')",
                                    completionHandler: nil)
        shellLog("市场窗口主题跟随为 \(preference)")
    }

    // MARK: 页面渲染与桥

    private func render(catalog: Catalog, in webView: WKWebView, note: String) {
        let profileDir = (currentPlan()?.home ?? stateDirectory.appendingPathComponent("home"))
            .appendingPathComponent("profiles/\(profileName)")
        let state = loadProfileState(profileDir: profileDir)

        var items: [[String: Any]] = []
        for plugin in catalog.entries.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            let status = state.installed.contains(plugin.name)
                ? (state.active.contains(plugin.name) ? 1 : 2) : 0
            var item: [String: Any] = [
                "name": plugin.name,
                "version": plugin.version,
                "desc": plugin.summary,
                "status": status,
                "kw": plugin.keywords,
            ]
            if let value = plugin.publisher { item["pub"] = value }
            if let value = plugin.license { item["lic"] = value }
            if let value = plugin.updated { item["updated"] = value }
            if let value = plugin.npmURL { item["npm"] = value }
            if let value = plugin.repoURL { item["repo"] = value }
            if let value = plugin.homepageURL { item["home"] = value }
            if let value = plugin.weekly { item["weekly"] = value }
            if let value = plugin.monthly { item["monthly"] = value }
            if let value = plugin.score { item["score"] = value }
            if let value = plugin.iconURL { item["icon"] = value }
            if let value = plugin.coverURL { item["cover"] = value }
            items.append(item)
        }

        let meta: [String: Any] = [
            "source": note,
            "unvetted": catalog.unvetted,
            "theme": themePref,
            "profile": profileName,
        ]
        let payload = Self.scriptSafe(items)
        let metaPayload = Self.scriptSafe(meta)
        let signature = Self.fingerprint(payload, themePref, profileName)
        if signature == renderedSignature {
            shellLog("市场页面内容未变化，跳过重载（保留搜索词与滚动位置）")
            return
        }
        renderedSignature = signature
        let html = Self.pageTemplate
            .replacingOccurrences(of: "__DATA__", with: payload)
            .replacingOccurrences(of: "__META__", with: metaPayload)
        webView.loadHTMLString(html, baseURL: nil)
        shellLog("市场页面刷新：\(catalog.source)（\(items.count) 条）")
    }

    /// FNV-1a：内容指纹只用来比对，不做安全用途。
    private static func fingerprint(_ parts: String...) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    /// 把 JSON 封进 <script> 前，掐掉能在 JS 里闭合标签的行分隔符与 `</`。
    private static func scriptSafe(_ object: Any) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return json
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    struct Action: Decodable {
        let action: String
        let name: String?
        let spec: String?
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let action = try? JSONDecoder().decode(Action.self, from: data) else { return }
        switch action.action {
        case "refresh":
            // 显式刷新：拿回来的目录要立刻换到界面上
            showPage(refreshingRemote: true, applyRemote: true)
        case "openURL":
            openExternal(action.spec)
        case "install", "remove":
            confirm(action: action)
        default:
            break
        }
    }

    /// 外链一律丢给系统默认浏览器，不在市场窗口里导航（那会把目录页顶掉）。
    private func openExternal(_ raw: String?) {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            presentAlert("拒绝打开这个链接：\(raw ?? "（空）")")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: 确认与执行 —— 与手敲「dsh plugin …」完全同一条链路

    private func confirm(action: Action) {
        guard !busy else {
            presentAlert("已经有一个安装在执行中（市场页一次只跑一个，稍等即可）。")
            return
        }
        guard let name = action.name, let spec = action.spec else { return }
        let install = action.action == "install"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = install ? "安装这个插件？" : "卸载这个插件？"
        alert.informativeText = "将执行：dsh plugin --profile \(profileName) "
            + (install ? "add" : "remove") + " \(spec)\n\n"
            + "插件是在你机器上运行第三方代码的 npm 包，目录里的条目未经任何验证。"
        alert.addButton(withTitle: install ? "安装" : "卸载")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(action: Action(action: action.action, name: name, spec: spec))
    }

    private func run(action: Action) {
        guard !busy, let spec = action.spec else { return }
        let pnpm = pluginToolPath()
        let entry = pluginEntryPath()
        guard FileManager.default.isExecutableFile(atPath: pnpm),
              FileManager.default.fileExists(atPath: entry) else {
            presentAlert("""
            装不了：市场需要「dsh CLI + pnpm」这一条安装链。

            内置 pnpm 缺失时：重新跑 shell/make-app.sh（它会下载 pnpm 并打进 .app），\
            或在 PATH 里放一个 pnpm（brew install pnpm / npm i -g pnpm），然后重启 dshX。\
            当前解析到的 pnpm：\(pnpm.isEmpty ? "无" : pnpm)
            当前解析到的 dsh CLI：\(entry)
            """)
            return
        }
        busy = true

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 同 supervisorScript 的形态：sh -c <script> <name> <node> <dsh> <args…>。
        child.arguments = ["-c", Self.pluginScript, "dsh-plugin",
                           (currentPlan()?.node.path ?? "/usr/bin/env"),
                           entry, "plugin", "--profile", profileName,
                           action.action == "install" ? "add" : "remove", spec]
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LANG", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                    "NO_PROXY", "npm_config_registry"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        let pnpmDir = (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))
            .appendingPathComponent("tools/bin").path
        let nodeDir = currentPlan()?.node.deletingLastPathComponent().path ?? "/usr/bin"
        env["PATH"] = [pnpmDir, nodeDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        if let plan = currentPlan() { env["DSH_HOME"] = plan.home.path }
        child.environment = env
        child.currentDirectoryURL = currentPlan()?.workspace
            ?? stateDirectory.appendingPathComponent("workspace")

        let output = Pipe()
        let collected = Outbox()
        output.fileHandleForReading.readabilityHandler = { readable in
            let chunk = readable.availableData
            if !chunk.isEmpty { collected.append(chunk) }
        }
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { [weak self] terminated in
            output.fileHandleForReading.readabilityHandler = nil
            let tail = collected.tail(4096)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.finished(action: action, code: terminated.terminationStatus, output: tail)
            }
        }
        do {
            try child.run()
            shellLog("市场安装开始：plugin --profile \(profileName) \(action.action) \(spec)")
        } catch {
            busy = false
            presentAlert("无法启动安装：\(error.localizedDescription)")
        }
    }

    /// 收集安装子进程的输出（线程安全，上限 8KB 只留尾部）。
    private final class Outbox {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk)
            if data.count > 8192 { data.removeFirst(data.count - 8192) }
            lock.unlock()
        }
        func tail(_ count: Int) -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data.suffix(count), as: UTF8.self)
        }
    }

    private func finished(action: Action, code: Int32, output: String) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if code == 0 {
            alert.messageText = action.action == "install"
                ? "已安装 \(action.spec ?? "")." : "已卸载 \(action.name ?? "")."
            alert.informativeText = "插件层在重启后端后才生效：profile 的 bundles 清单此刻已更新，"
                + "重启后按新清单组装。日志：\(logFileURL.path)"
            alert.addButton(withTitle: "立即重启后端并生效")
            alert.addButton(withTitle: "稍后自己重启")
            if alert.runModal() == .alertFirstButtonReturn {
                showPage(refreshingRemote: false)
                ShellController.shared.restartBackend()
            } else {
                showPage(refreshingRemote: false)
            }
        } else {
            alert.alertStyle = .warning
            alert.messageText = "安装失败（退出码 \(code)），没有改动任何配置"
            let summary = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            alert.informativeText = "最近输出：\n\(summary)\n\n完整日志：\(logFileURL.path)"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: 子进程要用的绝对路径

    /// 与 resolvePlan 同思路解析 pnpm：env 覆盖 → App 内置 → 私有目录 → PATH 候选。
    private func pluginToolPath() -> String {
        let fm = FileManager.default
        if let override = envString("DSH_APP_PNPM_DIR"), !override.isEmpty {
            let candidate = override.hasSuffix("/pnpm") ? override : override + "/pnpm"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent")
        let workspace = envString("DSH_APP_WORKSPACE").flatMap { $0.isEmpty ? nil : $0 }
            ?? stateDirectory.appendingPathComponent("workspace").path
        for candidate in [
            resources.appendingPathComponent("tools/bin/pnpm").path,
            stateDirectory.appendingPathComponent("plugin-tools/pnpm").path,
            workspace + "/shell/tools/bin/pnpm",
            "/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm",
            NSHomeDirectory() + "/.volta/bin/pnpm",
        ] where fm.isExecutableFile(atPath: candidate) { return candidate }
        return ""
    }

    private func pluginEntryPath() -> String {
        if let override = envString("DSH_APP_ENTRY"), !override.isEmpty { return override }
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent")
        let fm = FileManager.default
        for candidate in [
            resources.appendingPathComponent("runtime/node_modules/@deepseek-ai/dsh/lib/bin.js").path,
            stateDirectory.appendingPathComponent("runtime/node_modules/@deepseek-ai/dsh/lib/bin.js").path,
        ] where fm.fileExists(atPath: candidate) { return candidate }
        return ""
    }

    private func presentAlert(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: 页面模板

    private static let pluginScript = """
    node="$1"; shift
    "$node" "$@"
    """

    // 用 Swift 原始字符串（#"""）：模板里的 CSS/JS 含大量反斜杠与 \( 序列，
    // 走普通字面量会一路踩转义坑。取值一律通过 __DATA__/__META__ 注入。
    private static let pageTemplate = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <title>dshX · 插件市场</title>
    <script>
    // 尽早定主题，避免首帧闪一下深色。
    (function () {
      const META = __META__;
      const mq = window.matchMedia('(prefers-color-scheme: light)');
      function resolve() {
        const p = META.theme;
        if (p === 'light') return 'light';
        if (p === 'dark') return 'dark';
        return mq.matches ? 'light' : 'dark';
      }
      function apply() { document.documentElement.dataset.theme = resolve(); }
      apply();
      try { mq.addEventListener('change', apply); } catch (e) {}
      // 主界面切主题后，壳会在窗口重新获得焦点时回调这里做增量换肤。
      window.__dshxSetTheme = function (pref) { META.theme = pref; apply(); };
    })();
    </script>
    <style>
    :root{
      --bg:#0f1216; --panel:#161b22; --panel2:#1b222b; --border:#262d37;
      --text:#e6edf3; --muted:#8b949e; --accent:#e0703f; --accent-fg:#fff;
      --ok:#3fb950; --warn:#d29922; --chip:#20262e; --hover:#1d242d;
    }
    :root[data-theme="light"]{
      --bg:#f7f8fa; --panel:#ffffff; --panel2:#f1f3f6; --border:#dde1e6;
      --text:#1f2328; --muted:#6b7280; --accent:#c2521f; --accent-fg:#fff;
      --ok:#1a7f37; --warn:#9a6700; --chip:#eef1f4; --hover:#f4f6f8;
    }
    *{box-sizing:border-box}
    html,body{height:100%}
    body{margin:0;background:var(--bg);color:var(--text);
         font:13px/1.55 -apple-system,BlinkMacSystemFont,system-ui,"Helvetica Neue",sans-serif;
         -webkit-font-smoothing:antialiased}
    a{color:inherit}
    header{position:sticky;top:0;z-index:6;background:var(--bg);
           border-bottom:1px solid var(--border);padding:12px 16px 10px}
    .bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
    h1{font-size:15px;font-weight:650;margin:0 6px 0 0;white-space:nowrap}
    input[type=search]{flex:1 1 220px;min-width:160px;padding:7px 11px;border-radius:9px;
      border:1px solid var(--border);background:var(--panel);color:var(--text);font:inherit;outline:none}
    input[type=search]:focus{border-color:var(--accent)}
    .seg{display:flex;border:1px solid var(--border);border-radius:9px;overflow:hidden;flex:0 0 auto}
    .seg button{border:0;background:transparent;color:var(--muted);font:inherit;
      padding:7px 12px;cursor:pointer}
    .seg button + button{border-left:1px solid var(--border)}
    .seg button.on{background:var(--panel2);color:var(--text);font-weight:600}
    .ghost{border:1px solid var(--border);background:var(--panel);color:var(--text);
      font:inherit;padding:7px 12px;border-radius:9px;cursor:pointer;flex:0 0 auto}
    .ghost:hover{background:var(--hover)}
    .ghost:disabled{opacity:.5;cursor:default}
    .sub{display:flex;gap:12px;align-items:center;margin-top:8px;
         font-size:11.5px;color:var(--muted)}
    .sub .flag{color:var(--warn)}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(184px,1fr));
          gap:14px;padding:16px 16px 30px}
    .card{position:relative;aspect-ratio:1/1;display:flex;flex-direction:column;
      background:var(--panel);border:1px solid var(--border);border-radius:14px;
      overflow:hidden;cursor:pointer;text-align:left;padding:0;color:inherit;font:inherit;
      transition:transform .12s ease,border-color .12s ease,box-shadow .12s ease}
    .card:hover{transform:translateY(-2px);border-color:var(--accent);
      box-shadow:0 10px 26px rgba(0,0,0,.28)}
    .card:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    /* 卡片缩略图：图块常驻打底，远程图加载完再淡入覆盖——
       头像要经 GitHub 302 跳转，首帧必然有空窗期，不能让格子白着。 */
    .thumb{position:relative;flex:1 1 auto;min-height:0;display:flex;align-items:center;
      justify-content:center;padding:14px;background:var(--panel2)}
    .thumb img{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);
      max-width:calc(100% - 26px);max-height:calc(100% - 26px);border-radius:12px;
      object-fit:contain;opacity:0;transition:opacity .18s ease}
    .thumb img.shown{opacity:1}
    .mono{width:62px;height:62px;border-radius:16px;display:flex;align-items:center;
      justify-content:center;font-weight:700;font-size:25px;color:#fff;letter-spacing:.5px}
    .info{padding:9px 11px 11px;display:flex;flex-direction:column;gap:2px}
    .pname{font-weight:620;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .pmeta{font-size:10.5px;color:var(--muted);display:flex;gap:8px}
    .pdesc{font-size:10.8px;color:var(--muted);line-height:1.42;margin-top:2px;
      display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
    .chip{position:absolute;top:8px;right:8px;font-size:10px;padding:2px 7px;border-radius:999px;
      background:var(--chip);border:1px solid var(--border);color:var(--muted)}
    .chip.active{color:var(--ok);border-color:var(--ok)}
    .chip.pending{color:var(--warn);border-color:var(--warn)}
    .empty{padding:40px 18px;color:var(--muted);text-align:center;line-height:1.8}
    /* 全量目录分段渲染：滚到底自动续，按钮是兜底入口 */
    .more{display:block;margin:22px auto 8px;padding:10px 22px;border-radius:10px;
      border:1px solid var(--border);background:var(--panel);color:var(--text);
      cursor:pointer;font:inherit;font-size:13px}
    .more:hover{border-color:var(--accent);color:var(--accent)}
    .more[hidden]{display:none}
    /* 详情弹窗 */
    .modal{position:fixed;inset:0;z-index:20;background:rgba(0,0,0,.55);
      display:flex;align-items:center;justify-content:center;padding:24px}
    .modal[hidden]{display:none}
    .sheet{position:relative;width:min(920px,94vw);height:min(86vh,780px);
      background:var(--panel);border:1px solid var(--border);border-radius:16px;
      overflow:hidden;display:flex;flex-direction:column;
      box-shadow:0 24px 70px rgba(0,0,0,.5)}
    .close{position:absolute;top:10px;right:12px;z-index:3;width:30px;height:30px;border-radius:8px;
      border:1px solid var(--border);background:var(--panel);color:var(--text);
      font-size:17px;line-height:1;cursor:pointer}
    .close:hover{background:var(--hover)}
    .banner{position:relative;flex:0 0 168px;overflow:hidden;
      display:flex;align-items:flex-end;padding:14px 18px}
    .banner img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:.55}
    .banner .fade{position:absolute;inset:0;
      background:linear-gradient(180deg,rgba(0,0,0,.05),var(--panel))}
    .mhead{position:relative;z-index:2;display:flex;gap:14px;align-items:flex-end;width:100%}
    .miconwrap{position:relative;width:76px;height:76px;flex:0 0 auto}
    .miconwrap .mono{position:absolute;inset:0;width:76px;height:76px;border-radius:18px}
    .miconwrap img{position:absolute;inset:0;width:76px;height:76px;border-radius:18px;
      border:1px solid var(--border);background:var(--panel2);object-fit:cover;
      opacity:0;transition:opacity .18s ease}
    .miconwrap img.shown{opacity:1}
    .mtitle{min-width:0;flex:1 1 auto;padding-bottom:2px}
    .mtitle h2{margin:0;font-size:17px;font-weight:650;overflow:hidden;
      text-overflow:ellipsis;white-space:nowrap}
    .mtitle .ver{font-size:12px;color:var(--muted);margin-top:2px}
    .mact{flex:0 0 auto;display:flex;gap:8px;align-items:center;padding-bottom:2px}
    .primary{border:0;border-radius:9px;background:var(--accent);color:var(--accent-fg);
      font:inherit;font-weight:600;padding:9px 16px;cursor:pointer}
    .primary:disabled{opacity:.55;cursor:default}
    .danger{border:1px solid var(--accent);border-radius:9px;background:transparent;
      color:var(--accent);font:inherit;font-weight:600;padding:9px 16px;cursor:pointer}
    .mbody{flex:1 1 auto;overflow:auto;padding:4px 20px 22px}
    .mdesc{font-size:13px;line-height:1.7;margin:10px 0 14px;white-space:pre-wrap}
    .kw{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:16px}
    .kw span{font-size:11px;padding:2px 9px;border-radius:999px;
      background:var(--chip);border:1px solid var(--border);color:var(--muted)}
    .facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
      gap:10px 18px;margin-bottom:16px}
    .fact{font-size:12px}
    .fact b{display:block;font-size:10.5px;font-weight:600;color:var(--muted);
      text-transform:uppercase;letter-spacing:.04em;margin-bottom:2px}
    .links{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:16px}
    .links button{border:1px solid var(--border);background:var(--panel2);color:var(--text);
      font:inherit;padding:7px 13px;border-radius:9px;cursor:pointer}
    .links button:hover{border-color:var(--accent)}
    .spec{font:11.5px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);
      background:var(--panel2);border:1px solid var(--border);border-radius:10px;
      padding:10px 12px;word-break:break-all}
    .spec b{display:block;color:var(--text);font-weight:600;margin-bottom:4px;
      font-family:-apple-system,system-ui,sans-serif}
    </style>
    </head>
    <body>
    <header>
      <div class="bar">
        <h1>插件市场</h1>
        <input id="q" type="search" placeholder="搜索插件名、描述或关键词…" autocomplete="off">
        <div class="seg" id="sorts">
          <button data-sort="hot" class="on">热门</button>
          <button data-sort="updated">最新</button>
          <button data-sort="name">名称</button>
        </div>
        <button id="refresh" class="ghost">刷新目录</button>
      </div>
      <div class="sub">
        <span id="count"></span>
        <span id="src"></span>
        <span id="flag" class="flag"></span>
      </div>
    </header>
    <div id="grid" class="grid"></div>
    <div id="empty" class="empty" hidden></div>
    <button id="more" class="more" type="button" hidden></button>

    <div id="modal" class="modal" hidden>
      <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="m-name">
        <button class="close" id="m-close" title="关闭">×</button>
        <div class="banner" id="m-banner">
          <img id="m-cover" alt="" hidden>
          <div class="fade"></div>
          <div class="mhead">
            <div class="miconwrap">
              <div class="mono" id="m-mono"></div>
              <img id="m-icon" alt="">
            </div>
            <div class="mtitle">
              <h2 id="m-name"></h2>
              <div class="ver" id="m-ver"></div>
            </div>
            <div class="mact"><button id="m-action"></button></div>
          </div>
        </div>
        <div class="mbody">
          <p class="mdesc" id="m-desc"></p>
          <div class="kw" id="m-kw"></div>
          <div class="facts" id="m-facts"></div>
          <div class="links" id="m-links"></div>
          <div class="spec"><b>将要执行</b><span id="m-spec"></span></div>
        </div>
      </div>
    </div>

    <script>
    const META = __META__;
    const DATA = __DATA__;

    function send(m){ window.webkit.messageHandlers.dshxMarket.postMessage(JSON.stringify(m)); }
    function openURL(u){ if (u) send({action:'openURL', spec:u}); }

    // 无图时的确定性图块：名字哈希出色相，取前两个字母。
    function hueOf(s){
      let h = 0;
      for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
      return h;
    }
    function initialsOf(name){
      const base = name.replace(/^@[^/]*\//, '');
      const cleaned = base.replace(/[^a-zA-Z0-9]+/g, '');
      return (cleaned.slice(0, 2) || base.slice(0, 2) || '?').toUpperCase();
    }
    // 图块：名字定色相。先铺图块，远程图加载完再淡入覆盖，避免空白格。
    function paintMonogram(el, name){
      el.textContent = initialsOf(name);
      const hue = hueOf(name);
      el.style.background = 'linear-gradient(135deg,hsl(' + hue + ',62%,48%),hsl(' +
        ((hue + 38) % 360) + ',58%,36%))';
    }
    function fmtCount(n){
      if (typeof n !== 'number') return null;
      if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
      if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
      return String(n);
    }
    function hostOf(u){
      try { return new URL(u).host.replace(/^www\./, ''); } catch (e) { return '链接'; }
    }
    function statusLabel(s){
      return s === 1 ? '已启用' : (s === 2 ? '已安装·未生效' : '');
    }
    // 缩略图：图块常驻打底，远程图成功才淡入，失败就只是留住图块。
    function decorateThumb(thumb, p){
      const mono = document.createElement('div');
      mono.className = 'mono';
      paintMonogram(mono, p.name);
      thumb.append(mono);
      if (!p.icon) return;
      const img = document.createElement('img');
      img.alt = '';
      img.loading = 'lazy';
      img.referrerPolicy = 'no-referrer';
      img.onload = function(){ img.classList.add('shown'); };
      img.onerror = function(){ img.remove(); };
      img.src = p.icon;
      thumb.append(img);
      if (img.complete && img.naturalWidth > 0) img.classList.add('shown');
    }

    // ---- 过滤与排序 ----
    let sortKey = 'hot';
    let query = '';
    function matches(p){
      if (!query) return true;
      const q = query.toLowerCase();
      if (p.name.toLowerCase().indexOf(q) >= 0) return true;
      if ((p.desc || '').toLowerCase().indexOf(q) >= 0) return true;
      return (p.kw || []).some(function(k){ return k.toLowerCase().indexOf(q) >= 0; });
    }
    function compare(a, b){
      if (sortKey === 'hot'){
        const d = (b.weekly === undefined ? -1 : b.weekly) - (a.weekly === undefined ? -1 : a.weekly);
        if (d) return d;
      } else if (sortKey === 'updated'){
        const d = String(b.updated || '').localeCompare(String(a.updated || ''));
        if (d) return d;
      }
      return a.name.localeCompare(b.name);
    }

    const grid = document.getElementById('grid');
    const empty = document.getElementById('empty');
    const countEl = document.getElementById('count');
    const more = document.getElementById('more');

    function card(p){
      const el = document.createElement('button');
      el.className = 'card';
      el.type = 'button';
      el.title = p.name;
      const thumb = document.createElement('div');
      thumb.className = 'thumb';
      decorateThumb(thumb, p);
      el.append(thumb);

      const label = statusLabel(p.status);
      if (label){
        const chip = document.createElement('span');
        chip.className = 'chip ' + (p.status === 1 ? 'active' : 'pending');
        chip.textContent = label;
        el.append(chip);
      }

      const info = document.createElement('div');
      info.className = 'info';
      const name = document.createElement('div');
      name.className = 'pname';
      name.textContent = p.name;
      const meta = document.createElement('div');
      meta.className = 'pmeta';
      const v = document.createElement('span');
      v.textContent = 'v' + p.version;
      meta.append(v);
      const weekly = fmtCount(p.weekly);
      if (weekly){
        const dl = document.createElement('span');
        dl.textContent = '↓ ' + weekly + '/周';
        meta.append(dl);
      }
      info.append(name, meta);
      if (p.desc){
        const desc = document.createElement('div');
        desc.className = 'pdesc';
        desc.textContent = p.desc;
        info.append(desc);
      }
      el.append(info);
      el.onclick = function(){ openDetail(p); };
      return el;
    }

    // 目录是全量的（近 5000 条），一次铺完要同时建几千个 DOM 节点和几千个 <img>，
    // 所以分屏渲染：先铺一屏，滚到底自动续。搜索或排序变化时回到第一屏。
    const PAGE = 60;
    let visible = PAGE;
    let matched = [];

    function appendRange(from, to){
      const frag = document.createDocumentFragment();
      const end = Math.min(to, matched.length);
      for (let i = from; i < end; i++) frag.append(card(matched[i]));
      grid.append(frag);
    }

    function renderGrid(){
      matched = DATA.filter(matches).sort(compare);
      visible = PAGE;
      grid.replaceChildren();
      appendRange(0, visible);
      updateFooter();
    }

    function showMore(){
      if (visible >= matched.length) return;
      const next = Math.min(visible + PAGE, matched.length);
      appendRange(visible, next);
      visible = next;
      updateFooter();
    }

    function updateFooter(){
      const installed = DATA.filter(function(p){ return p.status > 0; }).length;
      countEl.textContent = '共 ' + DATA.length + ' 个插件 · 匹配 ' + matched.length +
        ' 个 · 已显示 ' + Math.min(visible, matched.length) + ' 个' +
        (installed ? ' · 已装 ' + installed + ' 个' : '');
      if (!matched.length){
        empty.hidden = false;
        empty.textContent = DATA.length
          ? '没有匹配「' + query + '」的插件。'
          : '目录为空：检查到 registry.npmjs.org 的网络，或设 DSH_PLUGIN_CATALOG 指向一个本地 catalog 文件。';
      } else {
        empty.hidden = true;
      }
      const remain = matched.length - visible;
      more.hidden = remain <= 0;
      more.textContent = '加载更多（还有 ' + remain + ' 个）';
    }

    more.addEventListener('click', showMore);
    if ('IntersectionObserver' in window){
      // 兜底按钮同时兼作哨兵：接近底部就自动续一屏。
      new IntersectionObserver(function(entries){
        if (entries.some(function(e){ return e.isIntersecting; })) showMore();
      }, { rootMargin: '800px' }).observe(more);
    }

    // ---- 详情弹窗 ----
    const modal = document.getElementById('modal');
    const mCover = document.getElementById('m-cover');
    const mIcon = document.getElementById('m-icon');
    const mMono = document.getElementById('m-mono');
    const mName = document.getElementById('m-name');
    const mVer = document.getElementById('m-ver');
    const mDesc = document.getElementById('m-desc');
    const mKw = document.getElementById('m-kw');
    const mFacts = document.getElementById('m-facts');
    const mLinks = document.getElementById('m-links');
    const mSpec = document.getElementById('m-spec');
    const mAction = document.getElementById('m-action');

    function fact(label, value){
      if (value === null || value === undefined || value === '') return null;
      const d = document.createElement('div');
      d.className = 'fact';
      const b = document.createElement('b');
      b.textContent = label;
      const s = document.createElement('span');
      s.textContent = value;
      d.append(b, s);
      return d;
    }

    function openDetail(p){
      const hue = hueOf(p.name);
      const banner = document.getElementById('m-banner');
      banner.style.background = 'linear-gradient(120deg,hsl(' + hue + ',58%,42%),hsl(' +
        ((hue + 42) % 360) + ',52%,30%))';

      mCover.hidden = true;
      mCover.onerror = function(){ mCover.hidden = true; };
      mCover.onload = function(){ mCover.hidden = false; };
      if (p.cover){ mCover.src = p.cover; } else { mCover.removeAttribute('src'); }

      paintMonogram(mMono, p.name);
      mIcon.classList.remove('shown');
      mIcon.onload = function(){ mIcon.classList.add('shown'); };
      mIcon.onerror = function(){ mIcon.classList.remove('shown'); mIcon.removeAttribute('src'); };
      if (p.icon){
        mIcon.src = p.icon;
        if (mIcon.complete && mIcon.naturalWidth > 0) mIcon.classList.add('shown');
      } else {
        mIcon.removeAttribute('src');
      }

      mName.textContent = p.name;
      mVer.textContent = 'v' + p.version + (p.pub ? ' · ' + p.pub : '');
      mDesc.textContent = p.desc || '（这个包没有写描述）';

      mKw.replaceChildren();
      for (const k of (p.kw || [])){
        const s = document.createElement('span');
        s.textContent = k;
        mKw.append(s);
      }

      mFacts.replaceChildren();
      const weekly = fmtCount(p.weekly);
      const monthly = fmtCount(p.monthly);
      const rows = [
        fact('安装状态', statusLabel(p.status) || '未安装'),
        fact('周下载量', weekly ? weekly : null),
        fact('月下载量', monthly ? monthly : null),
        fact('许可', p.lic),
        fact('更新时间', p.updated ? String(p.updated).slice(0, 10) : null),
        fact('搜索热度', typeof p.score === 'number' ? p.score.toFixed(1) : null),
      ];
      for (const r of rows) if (r) mFacts.append(r);

      mLinks.replaceChildren();
      const links = [
        ['npm 页面', p.npm],
        ['代码仓库', p.repo],
        ['主页', p.home],
      ];
      for (const kv of links){
        if (!kv[1]) continue;
        const b = document.createElement('button');
        b.textContent = kv[0] + ' · ' + hostOf(kv[1]);
        b.onclick = function(){ openURL(kv[1]); };
        mLinks.append(b);
      }

      const spec = p.name + '@' + p.version;
      if (p.status === 1){
        mAction.textContent = '已在层栈 · 重启后端才变化';
        mAction.disabled = true;
        mAction.className = 'primary';
        mSpec.textContent = 'dsh plugin --profile ' + META.profile + ' add ' + spec +
          '（已安装，无需重复执行）';
      } else if (p.status === 2){
        mAction.textContent = '卸载（当前未生效）';
        mAction.disabled = false;
        mAction.className = 'danger';
        mAction.onclick = function(){
          modal.hidden = true;
          send({action:'remove', name:p.name, spec:p.name});
        };
        mSpec.textContent = 'dsh plugin --profile ' + META.profile + ' remove ' + p.name;
      } else {
        mAction.textContent = '安装';
        mAction.disabled = false;
        mAction.className = 'primary';
        mAction.onclick = function(){
          modal.hidden = true;
          send({action:'install', name:p.name, spec:spec});
        };
        mSpec.textContent = 'dsh plugin --profile ' + META.profile + ' add ' + spec;
      }

      modal.hidden = false;
    }

    function closeDetail(){ modal.hidden = true; }

    document.getElementById('m-close').onclick = closeDetail;
    modal.onclick = function(e){ if (e.target === modal) closeDetail(); };
    document.addEventListener('keydown', function(e){
      if (e.key === 'Escape' && !modal.hidden) closeDetail();
    });

    // ---- 顶部交互 ----
    document.getElementById('q').addEventListener('input', function(e){
      query = e.target.value.trim();
      renderGrid();
    });
    const sorts = document.getElementById('sorts');
    sorts.addEventListener('click', function(e){
      const btn = e.target.closest('button');
      if (!btn) return;
      sortKey = btn.dataset.sort;
      for (const b of sorts.querySelectorAll('button')) b.classList.toggle('on', b === btn);
      renderGrid();
    });
    document.getElementById('refresh').addEventListener('click', function(e){
      e.target.disabled = true;
      send({action:'refresh'});
    });

    document.getElementById('src').textContent = META.source;
    if (META.unvetted) document.getElementById('flag').textContent = '⚠ 这是一份未验证的策展清单';
    renderGrid();
    </script>
    </body>
    </html>
    """#
}
