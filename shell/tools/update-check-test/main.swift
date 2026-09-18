import Foundation

/*
 dshX 更新链路的验证工具。不是 App 的一部分，也不打进 .app。

 跟 App 编的是同一份 Sources/updater.swift，所以「有没有新版」这件事只有一套判断：
 界面里看到的和这里跑出来的是同一个 resolveUpdate()。

 用法（都在仓库根目录）：

   bash shell/tools/update-check-test/run.sh              跑离线用例（不联网）
   bash shell/tools/update-check-test/run.sh --check      真查一次更新源
   bash shell/tools/update-check-test/run.sh --update     真查 + 真下载/校验/换包

 --update 会真的替换 DSH_UPDATE_TARGET 指定的 .app，务必指到沙盒目录，例如：

   DSH_UPDATE_TARGET=$PWD/.tmp/sandbox/Applications/dshX.app \
   DSH_UPDATE_FEED_URL=http://127.0.0.1:8731/releases.json \
   bash shell/tools/update-check-test/run.sh --update
*/

// 下面这几个全局量，在壳里由 Sources/main.swift 提供；单独编这个工具时给一份同名
// 替身，好让 updater.swift 脱离 .app 也能跑。行为保持一致。
let appTitle = "dshX"

let stateDirectory: URL = {
    let root = ProcessInfo.processInfo.environment["DSHX_TEST_HOME"]
        ?? NSTemporaryDirectory() + "dshx-test"
    return URL(fileURLWithPath: root + "/dshX", isDirectory: true)
}()

var logFileURL: URL { stateDirectory.appendingPathComponent("backend.log") }

func shellLog(_ text: String) {
    FileHandle.standardError.write(Data("[shell] \(text)\n".utf8))
}

func envString(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
}

// MARK: - 断言

var failures: [String] = []

func expect(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        failures.append(what)
    }
}

func name(_ result: ComparisonResult) -> String {
    switch result {
    case .orderedAscending: return "旧"
    case .orderedSame: return "同"
    case .orderedDescending: return "新"
    }
}

func detail(_ result: UpdateCheck) -> String {
    switch result {
    case .upToDate(let current, let latest):
        return "upToDate current=\(current) latest=\(latest ?? "-")"
    case .available(let release, let package):
        return "available version=\(release.version) package=\(package.name)"
    case .failure(let message):
        return "failure \(message)"
    }
}

func isFailure(_ result: UpdateCheck) -> Bool {
    if case .failure = result { return true }
    return false
}

// MARK: - 离线用例

func runVersionCases() {
    print("版本比较（左边相对右边）：")
    let cases: [(String, String, ComparisonResult)] = [
        ("0.1.2", "0.1.1", .orderedDescending),              // 常规：本地更新
        ("0.1.1", "0.1.2", .orderedAscending),               // 常规：源上更新
        ("0.1.2", "0.1.2", .orderedSame),
        ("0.2.0", "0.1.9", .orderedDescending),
        ("0.10.0", "0.9.9", .orderedDescending),             // 别按字典序把 0.9.9 判大
        ("1.0.0", "0.999.999", .orderedDescending),
        ("0.1.2", "0.1.2-rc.1", .orderedDescending),         // 稳定版比同版本预发布新
        ("0.1.2-rc.2", "0.1.2-rc.1", .orderedDescending),
        ("0.1.2-rc.10", "0.1.2-rc.9", .orderedDescending),   // 预发布段按数字比
        ("0.1.3-rc.1", "0.1.2", .orderedDescending),         // 跨小版本的 rc 也算新
        ("0.1.2-alpha.1", "0.1.2-beta.1", .orderedAscending),
        ("0.1.2+build.5", "0.1.2", .orderedSame),              // build 段不参与比较
        ("0.1.2", "0.1.2+build.5", .orderedSame),
        ("2.0", "2.0.1", .orderedAscending),
    ]
    for (left, right, want) in cases {
        let got = versionOrder(left, right)
        expect(got == want, "\(left) vs \(right) 应为「\(name(want))」，实际「\(name(got))」")
    }
}

let arm64DMG = """
{"name":"dshX-9.9.9-arm64.dmg","browser_download_url":"http://127.0.0.1:8731/dshX-9.9.9-arm64.dmg",\
"size":2048,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}
"""

let arm64DMGNoDigest = """
{"name":"dshX-9.9.9-arm64.dmg","browser_download_url":"http://127.0.0.1:8731/dshX-9.9.9-arm64.dmg","size":2048}
"""

let arm64Sha = """
{"name":"dshX-9.9.9-arm64.dmg.sha256","browser_download_url":"http://127.0.0.1:8731/dshX-9.9.9-arm64.dmg.sha256","size":87}
"""

let x86DMG = """
{"name":"dshX-9.9.9-x86_64.dmg","browser_download_url":"http://127.0.0.1:8731/i.dmg","size":2048}
"""

func fixture(_ body: String) -> Data { Data(("[" + body + "]").utf8) }

func runResolveCases() {
    print("选型（resolveUpdate）：")

    // 源上只有更旧的 0.1.1，本地 0.1.2 —— 应该报「已最新」。
    let older = fixture("""
    {"tag_name":"v0.1.1","prerelease":false,"html_url":"u","assets":[\
    {"name":"dshX-0.1.1-arm64.dmg","browser_download_url":"http://127.0.0.1:8731/x.dmg","size":100}]}
    """)
    let olderResult = resolveUpdate(data: older, current: "0.1.2", arch: "arm64",
                                    includePrerelease: false)
    if case .upToDate(_, let latest) = olderResult {
        expect(latest == "0.1.1", "本地比源上更新时报已最新，latest 取到 0.1.1")
    } else {
        expect(false, "本地比源上更新时应报已最新，实际 \(detail(olderResult))")
    }

    let newer = fixture("""
    {"tag_name":"v9.9.9","prerelease":false,"html_url":"u","assets":[\(arm64DMG)]}
    """)
    let newerResult = resolveUpdate(data: newer, current: "0.1.2", arch: "arm64",
                                    includePrerelease: false)
    if case .available(let release, let package) = newerResult {
        expect(release.version == "9.9.9", "有新版时认出 9.9.9")
        expect(package.size == 2048, "读出包大小")
        expect(package.digest?.hasPrefix("sha256:") == true, "读出资产 digest")
        expect(package.sidecarURL == nil, "没有 .sha256 资产时 sidecar 为空")
    } else {
        expect(false, "应认出可用更新，实际 \(detail(newerResult))")
    }

    let intel = resolveUpdate(data: newer, current: "0.1.2", arch: "x86_64",
                              includePrerelease: false)
    expect(isFailure(intel), "只有 arm64 包时，Intel 上报 failure 而不是假装能装")

    let matched = fixture("""
    {"tag_name":"v9.9.9","prerelease":false,"html_url":"u","assets":[\(x86DMG)]}
    """)
    if case .available(_, let package) = resolveUpdate(data: matched, current: "0.1.2",
                                                        arch: "x86_64", includePrerelease: false) {
        expect(package.name.contains("x86_64"), "Intel 上挑到 x86_64 的包")
    } else {
        expect(false, "Intel 上应挑到 x86_64 的包")
    }

    let sidecarOnly = fixture("""
    {"tag_name":"v9.9.9","prerelease":false,"html_url":"u","assets":[\(arm64DMGNoDigest),\(arm64Sha)]}
    """)
    if case .available(_, let package) = resolveUpdate(data: sidecarOnly, current: "0.1.2",
                                                        arch: "arm64", includePrerelease: false) {
        expect(package.digest == nil && package.sidecarURL?.hasSuffix(".sha256") == true,
               "没有 digest 时改用 .sha256 边车")
    } else {
        expect(false, "边车场景应认出可用更新")
    }

    let noAsset = fixture("""
    {"tag_name":"v9.9.9","prerelease":false,"html_url":"u","assets":[]}
    """)
    expect(isFailure(resolveUpdate(data: noAsset, current: "0.1.2", arch: "arm64",
                                   includePrerelease: false)),
           "Release 里没有 DMG 时报 failure")

    let onlyPrerelease = fixture("""
    {"tag_name":"v9.9.9","prerelease":true,"html_url":"u","assets":[\(arm64DMG)]}
    """)
    let strict = resolveUpdate(data: onlyPrerelease, current: "0.1.2", arch: "arm64",
                               includePrerelease: false)
    expect(!isFailure(strict) && detail(strict).hasPrefix("upToDate"),
           "默认不跟预发布（稳定版不该被换成 rc）")
    let loose = resolveUpdate(data: onlyPrerelease, current: "0.1.2", arch: "arm64",
                              includePrerelease: true)
    if case .available = loose {
        expect(true, "DSHX_ALLOW_PRERELEASE=1 时允许跟预发布")
    } else {
        expect(false, "开开关后应能跟预发布，实际 \(detail(loose))")
    }

    let twoReleases = fixture("""
    {"tag_name":"v0.2.0","prerelease":false,"html_url":"u","assets":[\
    {"name":"dshX-0.2.0-arm64.dmg","browser_download_url":"http://127.0.0.1:8731/b.dmg","size":1}]},
    {"tag_name":"v0.3.0","prerelease":false,"html_url":"u","assets":[\
    {"name":"dshX-0.3.0-arm64.dmg","browser_download_url":"http://127.0.0.1:8731/c.dmg","size":1}]}
    """)
    if case .available(let release, _) = resolveUpdate(data: twoReleases, current: "0.1.2",
                                                        arch: "arm64", includePrerelease: false) {
        expect(release.version == "0.3.0", "多个 Release 时取最高的那个，不看返回顺序")
    } else {
        expect(false, "两个 Release 时应认出 0.3.0")
    }

    let garbage = Data("<html>542 Too Many Requests</html>".utf8)
    expect(isFailure(resolveUpdate(data: garbage, current: "0.1.2", arch: "arm64",
                                   includePrerelease: false)),
           "认不出的正文（限流页 / 坏镜像）报 failure")

    // tag 的三种真实写法：dshX 仓库的 v0.1.1、上游的 dsh-v0.1.6-alpha.1、裸版本号。
    expect(extractVersion("v0.1.1") == "0.1.1", "从 v0.1.1 里认出版本号")
    expect(extractVersion("dsh-v0.1.6-alpha.1") == "0.1.6-alpha.1",
           "预发布 tag 的后缀要跟着版本号一起认出来")
    expect(extractVersion("0.2.0") == "0.2.0", "裸版本号")
    expect(extractVersion("no-version-here") == nil, "没有版本号时不硬凑")
}

// MARK: - 离线：403/429 诊断

func runRateLimitCases() {
    print("403/429 诊断（describeRateLimitFailure）：")

    let resetAt = Date(timeIntervalSince1970: 1789639007)
    let resetClock = { () -> String in
        // 跟实现用同一套格式化，免得用例绑死在某个时区上。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: resetAt)
    }()

    // 真实形态：走共享代理出口，那个 IP 的匿名配额被别人用光，GitHub 在正文里点了名。
    let exhausted = describeRateLimitFailure(status: 403, headers: [
        "x-ratelimit-limit": "60",
        "x-ratelimit-remaining": "0",
        "x-ratelimit-reset": "1789639007",
    ], body: Data((#"{"message":"API rate limit exceeded for 81.168.109.157. (But here's the good news: Authenticated requests get a higher rate limit.)","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}"#).utf8))
    expect(exhausted.message.contains("81.168.109.157"), "正文里的出口 IP 要出现在提示里")
    expect(exhausted.message.contains("0/60"), "说清匿名配额已用尽")
    expect(exhausted.message.contains(resetClock), "带上配额重置时间 \(resetClock)")
    expect(exhausted.message.contains("共享出口"), "点明可能是共享出口被占，而不是本机点多了")
    expect(exhausted.message.contains("DSH_GITHUB_TOKEN"), "给出绕过办法")
    expect(exhausted.logLine.contains("HTTP 403"), "日志行带状态码")
    expect(exhausted.logLine.contains("0/60"), "日志行带配额")
    expect(exhausted.logLine.contains("出口 IP 81.168.109.157"), "日志行带出口 IP")
    expect(exhausted.logLine.contains(resetClock), "日志行带重置时间")

    // 配额还剩着却照样 403：二级限流/滥用判定，不能再说「配额用尽」。
    let secondary = describeRateLimitFailure(status: 403, headers: [
        "x-ratelimit-limit": "60",
        "x-ratelimit-remaining": "45",
    ], body: Data((#"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#).utf8))
    expect(secondary.message.contains("还剩 45"), "配额没满时要说还剩多少")
    expect(!secondary.message.contains("已用尽"), "配额没满时别说「已用尽」")
    expect(secondary.message.contains("二级限流"), "指向二级限流")

    // 代理/网关自己回的 403：正文是 HTML，跟 GitHub 的配额无关。
    let gateway = describeRateLimitFailure(status: 403, headers: [:],
                                           body: Data("<html><body>403 Forbidden</body></html>".utf8))
    expect(gateway.message.contains("代理"), "非 JSON 正文要提示可能是代理/网关拦的")
    expect(gateway.message.contains("不是 GitHub 的匿名限流"), "别把网关 403 说成 GitHub 限流")
    expect(gateway.logLine.contains("不是 GitHub 的 JSON"), "日志行记下正文形态")

    // 429 带 Retry-After：把服务器要求的等待时间说出来。
    let throttled = describeRateLimitFailure(status: 429, headers: [
        "x-ratelimit-remaining": "0",
        "retry-after": "60",
    ], body: Data((#"{"message":"API rate limit exceeded for 203.0.113.9."}"#).utf8))
    expect(throttled.message.contains("60 秒后再试"), "429 要说清 Retry-After")
    expect(throttled.logLine.contains("Retry-After 60s"), "日志行带 Retry-After")

    // 头/正文的解析边界。
    expect(rateLimitSummary(headers: [:]) == "", "没有 x-ratelimit 头时摘要为空")
    expect(rateLimitSummary(headers: ["x-ratelimit-limit": "60",
                                      "x-ratelimit-remaining": "46",
                                      "x-ratelimit-reset": "1789641615"]).contains("46/60"),
           "有头时摘要带剩余/上限")
    expect(normalizedHeaders(["X-RateLimit-Remaining": "0"])["x-ratelimit-remaining"] == "0",
           "头名统一小写后再查")
    expect(githubErrorMessage(in: Data((#"{"message":"boom"}"#).utf8)) == "boom", "读出 GitHub 的 message")
    expect(githubErrorMessage(in: Data("<html>403</html>".utf8)) == nil, "HTML 正文不算 GitHub message")
    expect(exitIP(inGitHubMessage: "API rate limit exceeded for 2001:db8::1.") == "2001:db8::1",
           "IPv6 出口也能认出来")
    expect(exitIP(inGitHubMessage: "API rate limit exceeded for user ID 12345.") == nil,
           "不是 IP 的字段不许硬认")
}

// MARK: - 离线：dsh 后端（runtime-updater）
//
// 「更新 dsh 后端…」与「检查更新…」是两条独立的链路，判断逻辑也各有一套。
// 这里先对纯函数；提升/回滚这类真动目录的事，在下面的 runPromotionRehearsal 里
// 用假 runtime 走一遍真代码。

func runBackendRuntimeCases() {
    print("dsh 后端更新（runtime-updater）：")

    // 样本就是 npm 缩写元数据的形状（dist-tags + versions）。
    let registry = Data("""
    {"name":"@deepseek-ai/dsh",
     "dist-tags":{"latest":"0.1.5-rc.2","next":"0.1.5-rc.2","alpha":"0.1.6-alpha.2"},
     "versions":{"0.1.5-rc.1":{},"0.1.5-rc.2":{},"0.1.6-alpha.1":{},"0.1.6-alpha.2":{}}}
    """.utf8)

    expect(latestPublishedVersion(in: registry) == "0.1.6-alpha.2", "最高发布版本要含预发布")
    expect(resolveBackendCandidate(data: registry, current: "0.1.6-alpha.1")?.version == "0.1.6-alpha.2",
           "比当前新的预发布也要认（上游把新版发在 next/alpha 上）")
    expect(resolveBackendCandidate(data: registry, current: "0.1.6-alpha.2") == nil,
           "已经最高了就不该再「发现新版」")
    expect(resolveBackendCandidate(data: registry, current: "9.9.9") == nil, "比源上还新时不许降级")

    // latest 落后于当前、但 versions 里有更新的一条：兜底必须捞得到。
    let untagged = Data("""
    {"dist-tags":{"latest":"0.1.5-rc.2"},"versions":{"0.1.5-rc.2":{},"0.1.7":{}}}
    """.utf8)
    let fallback = resolveBackendCandidate(data: untagged, current: "0.1.6-alpha.1")
    expect(fallback?.version == "0.1.7" && fallback?.origin == "versions 列表",
           "所有标签都落后时从版本列表兜底")

    // 同一个版本被多个标签指着：报告里优先说是 latest，别报成 alpha。
    let shared = Data("""
    {"dist-tags":{"alpha":"1.0.0","latest":"1.0.0","next":"1.0.0"},"versions":{"1.0.0":{}}}
    """.utf8)
    expect(resolveBackendCandidate(data: shared, current: "0.9.0")?.origin == "dist-tag latest",
           "同版本多标签时优先报 latest")

    // 演练开关：指名版本照做，但源上没有的版本不许硬装。
    expect(resolveBackendCandidate(data: registry, current: "0.1.0",
                                   pinnedVersion: "0.1.5-rc.1")?.version == "0.1.5-rc.1",
           "DSHX_BACKEND_VERSION 指定的版本照做")
    expect(resolveBackendCandidate(data: registry, current: "0.1.0",
                                   pinnedVersion: "9.9.9") == nil,
           "指定了源上没有的版本就什么都不做")
    expect(resolveBackendCandidate(data: Data("not json".utf8), current: "0.1.0") == nil,
           "元数据不是 JSON 时不硬猜")

    // 现行的版本从包自己的 package.json 读；别把 dependencies 里的版本号读串。
    expect(packageVersion(in: Data(#"{"name":"@deepseek-ai/dsh","version":"1.2.3"}"#.utf8)) == "1.2.3",
           "从 package.json 读版本")
    expect(packageVersion(in: Data(#"{"dependencies":{"x":"9.9.9"}}"#.utf8)) == nil,
           "没有 version 时不许把依赖版本当成自己的")
    expect(packageVersion(in: Data("nope".utf8)) == nil, "不是 JSON 就没有版本")

    // 进度条：八个步骤按顺序首尾相接，权重合计正好 1；任意时刻都不能倒着走。
    let totalWeight = RuntimeStage.allCases.reduce(0.0) { $0 + $1.weight }
    expect(abs(totalWeight - 1) < 0.0001, "八个步骤的权重加起来是 1")
    expect(overallProgress(.prepare) == 0, "第一步开始前是 0")
    expect(abs(overallProgress(.install, within: 0) - RuntimeStage.prepare.weight) < 0.0001,
           "装依赖开始时接在准备步骤之后")
    expect(abs(overallProgress(.install, within: 1) - 0.72) < 0.0001,
           "装依赖装满是 2% + 70%")
    expect(overallProgress(.restart) < 1 && overallProgress(.restart, within: 1) == 1,
           "最后一步走满才是 100%")
    var previousProgress = -1.0
    var monotonic = true
    for stage in RuntimeStage.allCases {
        for within in [-1.0, 0.0, 0.5, 1.0] {
            let value = overallProgress(stage, within: within)
            if value + 0.0001 < previousProgress { monotonic = false }
            previousProgress = value
        }
    }
    expect(monotonic, "按执行顺序取任意步内进度，整体进度都不会倒退")

    // pnpm 输出 → 「这一步在做什么」+ 步内进度。没有分母时不许假装在装包。
    var installState = PnpmInstallProgress.start
    installState = parsePnpmProgress(
        "Progress: resolved 1, reused 0, downloaded 0, added 0", state: installState)
    expect(installState.total == nil && installState.fraction < 0.01,
           "还没拿到 Packages 分母时按解析进度小幅前进")
    expect(installState.text.contains("已解析 1 个包"), "解析阶段文案说明在解析什么")
    installState = parsePnpmProgress("Packages: +483", state: installState)
    expect(installState.total == 483, "从 Packages 行拿到真实分母")
    installState = parsePnpmProgress(
        "Progress: resolved 550, reused 0, downloaded 24, added 24", state: installState)
    let expectedInstall = 0.3 + 0.69 * 24.0 / 483.0
    expect(abs(installState.fraction - expectedInstall) < 0.0001,
           "装包阶段用 added/总数算进度")
    expect(installState.text.contains("24/483"), "当前步骤文案带上第几个包")
    installState = parsePnpmProgress(
        "Progress: resolved 550, reused 0, downloaded 482, added 483, done", state: installState)
    expect(installState.fraction == 1, "pnpm 报 done 时安装步走满")
    installState = parsePnpmProgress("WARN  some warning", state: installState)
    expect(installState.fraction == 1, "认不出的行不许把进度拉回去")
    expect(installState.text == "WARN  some warning", "认不出的行原样作为当前动作显示")

    // 共用 DSH_HOME 的其它后端：只认 node 的回环 LISTEN，别的进程/监听不算。
    let lsofSample = """
    COMMAND     PID     USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    node      97636 wangzhuo   15u  IPv4 0xabc      0t0  TCP 127.0.0.1:54338 (LISTEN)
    node      49040 wangzhuo   15u  IPv4 0xdef      0t0  TCP [::1]:56973 (LISTEN)
    python       42 wangzhuo    3u  IPv4 0x123      0t0  TCP 127.0.0.1:8000 (LISTEN)
    node        777 wangzhuo   15u  IPv6 0x456      0t0  TCP *:9999 (LISTEN)
    """
    let listeners = parseListeningNodeBackends(lsofSample)
    expect(listeners.count == 2, "只挑 node 的回环 LISTEN")
    expect(listeners.first == BackendConflict(pid: 97636, address: "127.0.0.1:54338",
                                              port: 54338),
           "IPv4 监听的 PID/端口要解析出来")
    expect(listeners.last?.port == 56973, "IPv6 回环监听也要认")
    expect(!listeners.contains { $0.port == 8000 || $0.port == 9999 },
           "别的进程与 *:port 不算 dsh 后端")

    // 目录命名：staging 与备份的名字决定了「提升」是不是一次同卷 rename。
    let runtime = URL(fileURLWithPath: "/tmp/dshx-runtime-case", isDirectory: true)
    expect(stagingDirectory(in: runtime, version: "1.2.3").lastPathComponent == ".staged-1.2.3",
           "staging 目录名带版本")
    expect(stagedVersion(fromDirectoryName: ".staged-1.2.3") == "1.2.3", "从目录名反解版本")
    expect(stagedVersion(fromDirectoryName: "node_modules") == nil, "普通目录不是 staging")
    expect(backupDirectory(in: runtime, version: nil).lastPathComponent == "node_modules.bak-unknown",
           "版本未知时备份名也不能空着")

    let steps = promotionSteps(runtimeDir: runtime, stagedVersion: "1.2.3", currentVersion: "1.2.2")
    expect(steps.count == 2, "提升就是两步改名")
    expect(steps[0].from.path == runtime.appendingPathComponent("node_modules").path
        && steps[0].to.lastPathComponent == "node_modules.bak-1.2.2",
           "第一步把现行 node_modules 挪成备份")
    expect(steps[1].from.path.hasSuffix(".staged-1.2.3/node_modules")
        && steps[1].to.path == runtime.appendingPathComponent("node_modules").path,
           "第二步把 staging 里那棵树挪进来")

    // staging 标记：启动时的「接管上次没切完的更新」就认它。
    let marker = Data(#"{"version":"1.2.3","installedAt":"2026-01-01T00:00:00Z","registry":"https://registry.npmjs.org"}"#.utf8)
    expect(parseStagedRuntime(marker)?.version == "1.2.3", "读出 staging 标记")
    expect(parseStagedRuntime(Data(#"{"installedAt":"x"}"#.utf8)) == nil, "没有版本的标记不算数")

    // 原生签名靠魔数认文件：*.node 与 spawn-helper 这类都要覆盖到。
    let probe = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dshx-macho-\(getpid())")
    try? Data([0xcf, 0xfa, 0xed, 0xfe, 0x00]).write(to: probe)
    expect(isMachO(at: probe), "认得出 arm64 Mach-O 魔数")
    try? Data("#!/bin/sh\n".utf8).write(to: probe)
    expect(!isMachO(at: probe), "脚本不是 Mach-O")
    try? FileManager.default.removeItem(at: probe)
}

/// 用假 runtime 走一遍真的提升与回滚：不联网，也不碰真 app。
/// 需要本机有 node（探活就是跑 `<node> …/bin.js --version`）；没有就跳过。
func runPromotionRehearsal() {
    print("提升/回滚演练（假 runtime，真代码）：")
    guard bundledNodePath() != nil else {
        print("  跳过：找不到 node（可用 DSHX_NODE 指定）")
        return
    }
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dshx-promote-\(getpid())", isDirectory: true)
    try? fm.removeItem(at: root)
    let runtime = root.appendingPathComponent("runtime", isDirectory: true)

    // 假的后端树：package.json 定版本，lib/bin.js 只回一句 --version。
    func makeTree(version: String, reporting: String, at nodeModules: URL) throws {
        let packageDir = nodeModules.appendingPathComponent("@deepseek-ai/dsh", isDirectory: true)
        try fm.createDirectory(at: packageDir.appendingPathComponent("lib", isDirectory: true),
                               withIntermediateDirectories: true)
        let manifest = #"{"name":"@deepseek-ai/dsh","version":"\#(version)","bin":{"dsh":"lib/bin.js"}}"#
        try Data(manifest.utf8).write(to: packageDir.appendingPathComponent("package.json"))
        try Data("console.log(\"\(reporting)\");\n".utf8)
            .write(to: packageDir.appendingPathComponent("lib/bin.js"))
    }

    do {
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try makeTree(version: "0.0.1", reporting: "0.0.1",
                     at: runtime.appendingPathComponent("node_modules"))
        let staging = stagingDirectory(in: runtime, version: "1.2.3")
        try makeTree(version: "1.2.3", reporting: "1.2.3",
                     at: staging.appendingPathComponent("node_modules"))
        // 真的 staging 里也有这么一份（由 stage() 写），收尾要把现行那份换掉。
        try stagingPackageJSON(version: "1.2.3")
            .write(to: staging.appendingPathComponent("package.json"))
        try writeStagedMarker(in: staging, version: "1.2.3")

        switch promoteRuntime(runtimeDir: runtime, staging: staging,
                              version: "1.2.3", currentVersion: "0.0.1") {
        case .success: expect(true, "探活通过时提升成功")
        case .failure(let message): expect(false, "提升本应成功：\(message)")
        }
        expect(installedBackendVersion(in: runtime) == "1.2.3", "提升后现行版本变成新版")
        expect(fm.fileExists(atPath: backupDirectory(in: runtime, version: "0.0.1").path),
               "旧树留了一份备份")
        expect(!fm.fileExists(atPath: staging.appendingPathComponent("node_modules").path),
               "staging 里那棵树已经挪走（是 rename，不是复制）")

        finishPromotion(runtimeDir: runtime, staging: staging)
        expect(fm.fileExists(atPath: runtime.appendingPathComponent("package.json").path),
               "收尾把 package.json 换成新树的")
        expect(!fm.fileExists(atPath: staging.path), "收尾删掉 staging 目录")
        expect(fm.fileExists(atPath: backupDirectory(in: runtime, version: "0.0.1").path),
               "默认留 1 份备份")

        // 新树自报的版本跟期望不符 = 装坏了：提升必须整体回滚。
        let broken = stagingDirectory(in: runtime, version: "2.0.0")
        try makeTree(version: "2.0.0", reporting: "1.9.9",
                     at: broken.appendingPathComponent("node_modules"))
        switch promoteRuntime(runtimeDir: runtime, staging: broken,
                              version: "2.0.0", currentVersion: "1.2.3") {
        case .success: expect(false, "探活失败时不该当成功")
        case .failure: expect(true, "探活失败时拒绝提升")
        }
        expect(installedBackendVersion(in: runtime) == "1.2.3", "回滚后现行版本没变")
        expect(!fm.fileExists(atPath: backupDirectory(in: runtime, version: "1.2.3").path),
               "回滚把备份挪回原位，不留空备份目录")

        // 「切换被拆成两半」的现场：没有 node_modules、只剩备份 —— 启动时要能救回来，
        // 否则 App 下次启动直接找不到 dsh 入口。有两份备份时挑最新的那份。
        try fm.moveItem(at: runtime.appendingPathComponent("node_modules"),
                        to: runtime.appendingPathComponent("node_modules.bak-1.2.3"))
        let older = runtime.appendingPathComponent("node_modules.bak-0.9.0")
        try fm.createDirectory(at: older, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                             ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date()],
                             ofItemAtPath: runtime.appendingPathComponent("node_modules.bak-1.2.3").path)
        expect(rescueCandidate(in: runtime)?.lastPathComponent == "node_modules.bak-1.2.3",
               "两份备份时救最新的那份")
        if let rescue = rescueCandidate(in: runtime) {
            try fm.moveItem(at: rescue, to: runtime.appendingPathComponent("node_modules"))
        }
        expect(rescueCandidate(in: runtime) == nil, "node_modules 已经在位就不需要救")
        expect(installedBackendVersion(in: runtime) == "1.2.3", "救回来的是那份完好的树")
    } catch {
        expect(false, "演练搭台失败：\(error)")
    }
    try? fm.removeItem(at: root)
}

// MARK: - 联网：查 / 全程演练

func runLive(update: Bool, timeout: TimeInterval) {
    print("更新源：\(updateFeedURL())")
    print("当前版本：\(currentAppVersion())　架构：\(machineArch())")
    print("替换目标：\(updateTargetApp())\n")

    let engine = UpdateEngine()
    var done = false
    engine.onProgress = { text, fraction in
        print(String(format: "  进度 %5.1f%%  %@", max(fraction, 0) * 100, text))
    }
    engine.onNotice = { message in
        print("  注意 \(message)")
        done = true
        failures.append(message)
    }
    engine.onQuitRequest = {
        print("  换包脚本已拉起，等它跑完…")
        done = true
    }
    engine.onCheck = { [weak engine] result in
        print("结论：\(detail(result))")
        if case .failure(let message) = result {
            // 查源失败不是「没有更新」，别混在一起悄悄过。
            failures.append(message)
            done = true
            return
        }
        guard update else {
            done = true
            return
        }
        guard case .available(_, let package) = result else {
            print("没有可用更新，演练到此为止。")
            done = true
            return
        }
        engine?.start(package: package)
    }
    engine.check()
    let deadline = Date().addingTimeInterval(timeout)
    while !done && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    if !done { failures.append("超时（\(Int(timeout)) 秒）") }
    // 换包脚本脱离本进程在跑，给它几秒把包换完，好让调用方接着检查文件。
    if update { Thread.sleep(forTimeInterval: 8) }
}

// MARK: - 联网：dsh 后端

/// 只读：真查一次 npm registry，看它会给「更新 dsh 后端…」挑哪个版本。
func runRuntimeCheck() {
    print("registry：\(npmPackageDocumentURL().absoluteString)")
    print("runtime： \(runtimeDirectory().path)")
    let current = installedBackendVersion(in: runtimeDirectory())
    print("当前后端：\(current ?? "未知（DSHX_RUNTIME_DIR 没指到装好的 runtime）")")
    let installer = RuntimeInstaller()
    var done = false
    installer.check { result in
        switch result {
        case .failure(let message):
            // 查不到不是「没有更新」，别混在一起悄悄过。
            print("查询失败：\(message)")
            failures.append(message)
        case .success(let query):
            print("源上最高：\(query.latestPublished ?? "未知")")
            print("候选：    \(query.candidate.map { "\($0.version)（\($0.origin)）" } ?? "无（已是最新）")")
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(60)
    while !done && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    if !done { failures.append("查询 npm registry 超时（60 秒）") }
}

/// 真装一次 dsh 后端到临时 runtime，并走完「提升」：网络、pnpm、签名、改名、
/// 探活全都真发生，只是发生在临时目录里。**不碰** /Applications 里那份 App。
/// 目标 runtime 由 DSHX_RUNTIME_DIR 决定；显式给了就在成功后保留现场，否则删掉。
func runRuntimeRehearse(version: String?) {
    let fm = FileManager.default
    let explicit = envString("DSHX_REHEARSE_DIR")
    let base = URL(fileURLWithPath: explicit
        ?? (fm.currentDirectoryPath + "/.tmp/runtime-rehearse"), isDirectory: true)
    let runtime = base.appendingPathComponent("runtime", isDirectory: true)
    // 引擎按环境变量找 runtime，这里显式指到沙盒。
    setenv("DSHX_RUNTIME_DIR", runtime.path, 1)

    try? fm.removeItem(at: runtime)
    do {
        // 先摆一棵「现行」的假树（0.0.1）：提升时它会被挪成备份，这样备份/
        // 回滚两条路都真的走到，而不必先复制 400M 真运行时。
        let packageDir = runtime.appendingPathComponent("node_modules/@deepseek-ai/dsh", isDirectory: true)
        try fm.createDirectory(at: packageDir.appendingPathComponent("lib", isDirectory: true),
                               withIntermediateDirectories: true)
        try Data(#"{"name":"@deepseek-ai/dsh","version":"0.0.1","bin":{"dsh":"lib/bin.js"}}"#.utf8)
            .write(to: packageDir.appendingPathComponent("package.json"))
        try Data("console.log(\"0.0.1\");\n".utf8)
            .write(to: packageDir.appendingPathComponent("lib/bin.js"))
    } catch {
        failures.append("搭演练现场失败：\(error)")
        return
    }

    print("演练 runtime：\(runtime.path)")
    print("内置 node：   \(bundledNodePath() ?? "找不到（DSHX_NODE 可指定）")")
    print("内置 pnpm：   \(bundledPnpmScript() ?? "找不到（DSHX_PNPM 可指定）")")

    let installer = RuntimeInstaller()
    var stops = 0
    var starts = 0
    installer.stopBackend = { stops += 1 }
    installer.startBackend = { starts += 1 }
    installer.onProgress = { print("  · \($0)") }
    installer.onPhase = { print("  · 阶段：\($0)") }

    // 版本：命令行给了就用它，否则真查一次 registry。
    var candidate: BackendCandidate?
    if let version, !version.isEmpty {
        candidate = BackendCandidate(version: version, origin: "命令行指定")
    } else {
        var queried = false
        installer.check { result in
            switch result {
            case .failure(let message):
                print("查询失败：\(message)")
                failures.append(message)
            case .success(let query):
                print("当前 0.0.1，源上最高 \(query.latestPublished ?? "未知")，"
                    + "候选 \(query.candidate.map { $0.version } ?? "无")")
                candidate = query.candidate
            }
            queried = true
        }
        let deadline = Date().addingTimeInterval(60)
        while !queried && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        if !queried { failures.append("查询 npm registry 超时（60 秒）"); return }
    }

    guard let candidate else {
        print("没有可装的候选版本，演练到此为止。")
        return
    }
    print("\n开始真装 \(dshPackageName)@\(candidate.version)（会下几百 MB，几分钟）…")

    var done = false
    installer.install(candidate: candidate) { result in
        switch result {
        case .failure(let message):
            print("安装/提升失败：\(message)")
            failures.append(message)
        case .success(let outcome):
            print("装好了：\(outcome.version)")
            print("备份：  \(outcome.backupPath ?? "无")")
            if installedBackendVersion(in: runtime) != outcome.version {
                failures.append("提升后 runtime 里的版本不是 \(outcome.version)")
            }
            if stops != 1 { failures.append("换目录前应当正好停一次后端，实际 \(stops) 次") }
            if starts != 1 { failures.append("换完后应当正好起一次后端，实际 \(starts) 次") }
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(900)
    while !done && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    if !done { failures.append("演练超时（900 秒）") }

    if explicit != nil {
        print("\n现场保留在 \(base.path)（DSHX_REHEARSE_DIR 是显式给的）。")
    } else {
        try? fm.removeItem(at: base)
    }
}

// MARK: - 入口

print("dshX 更新链路检查")
let arguments = CommandLine.arguments

// --cmp A B：只比两个版本号，打印 new/same/old。用来跟 update.sh 里那段 awk
// 对拍（两边声称用的是同一套规则，对一遍才知道是不是真的同一套）。
if let index = arguments.firstIndex(of: "--cmp"), index + 2 < arguments.count {
    switch versionOrder(arguments[index + 1], arguments[index + 2]) {
    case .orderedDescending: print("new")
    case .orderedSame: print("same")
    case .orderedAscending: print("old")
    }
    exit(0)
}

if arguments.contains("--check") || arguments.contains("--update") {
    // --update 会真替换包。不显式给沙盒目标就拒跑：默认目标是 /Applications 里
    // 那份真 App，把「演练」变成「线上实验」不值当。
    if arguments.contains("--update"), (envString("DSH_UPDATE_TARGET") ?? "").isEmpty {
        print("--update 需要先设 DSH_UPDATE_TARGET 指向沙盒里的 .app（默认会动 \(updateTargetApp())）。")
        exit(2)
    }
    runLive(update: arguments.contains("--update"), timeout: 240)
} else if arguments.contains("--runtime-check") {
    runRuntimeCheck()
} else if let index = arguments.firstIndex(of: "--runtime-rehearse") {
    // 后面那个参数可有可无；有就是「装这个版本」，没有就去 registry 挑。
    let next = arguments.count > index + 1 ? arguments[index + 1] : nil
    runRuntimeRehearse(version: (next?.hasPrefix("-") ?? true) ? nil : next)
} else {
    runVersionCases()
    runResolveCases()
    runRateLimitCases()
    runBackendRuntimeCases()
    runPromotionRehearsal()
}

if failures.isEmpty {
    print("\n全部通过。")
    exit(0)
}
print("\n\(failures.count) 项不通过：")
for item in failures { print("  - \(item)") }
exit(1)
