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

    expect(releasesPageURL(feed: "https://api.github.com/repos/imi4u36d/dshX/releases?per_page=30")
           == "https://github.com/imi4u36d/dshX/releases", "从 API 地址推出 Releases 页")
    // tag 的三种真实写法：dshX 仓库的 v0.1.1、上游的 dsh-v0.1.6-alpha.1、裸版本号。
    expect(extractVersion("v0.1.1") == "0.1.1", "从 v0.1.1 里认出版本号")
    expect(extractVersion("dsh-v0.1.6-alpha.1") == "0.1.6-alpha.1",
           "预发布 tag 的后缀要跟着版本号一起认出来")
    expect(extractVersion("0.2.0") == "0.2.0", "裸版本号")
    expect(extractVersion("no-version-here") == nil, "没有版本号时不硬凑")
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
} else {
    runVersionCases()
    runResolveCases()
}

if failures.isEmpty {
    print("\n全部通过。")
    exit(0)
}
print("\n\(failures.count) 项不通过：")
for item in failures { print("  - \(item)") }
exit(1)
