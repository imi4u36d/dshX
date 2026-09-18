# dshX

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI 包成一个原生 macOS 应用：
双击 `.app` 就拉起本地 dsh 后端，用原生窗口（WKWebView）承载界面。
打 tag 就自动出 DMG，见 [自动打包](#自动打包github-actions)。

[![Build dmg](https://github.com/imi4u36d/dshX/actions/workflows/release-dmg.yml/badge.svg)](https://github.com/imi4u36d/dshX/actions/workflows/release-dmg.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2012%2B%20arm64-lightgrey)

> ## ⚠️ 非官方声明
>
> **dshX 是第三方自建壳，不是 DeepSeek 官方产品**，与 DeepSeek 之间没有隶属、合作、
> 赞助或授权关系。它只是把官方开源的 dsh 后端套了个自己的窗口。
>
> 项目名里的 "DSH" 沿用上游品牌指南建议的社区简称；"DeepSeek Harness" 仅用于如实
> 说明技术依赖。**图标是 DeepSeek 的品牌素材，不属于本仓库的 MIT 授权范围**，
> 详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
>
> 官方桌面端请用上游仓库自带的 `apps/desktop`（那个是 Electron、有 Developer ID
> 签名与公证、走正式发版链路）。

## 下载安装

1. 到 [Releases](https://github.com/imi4u36d/dshX/releases) 下载最新的
   `dshX-<版本>-arm64.dmg`。
2. 打开 DMG，把 **dshX** 拖进 **Applications**。
3. 首次打开会被 Gatekeeper 拦下——因为它是 **ad-hoc 签名、没有 Apple 公证**。
   放行方式二选一：

   ```sh
   # 方式 A：去掉下载隔离标记（最省事）
   xattr -dr com.apple.quarantine "/Applications/dshX.app"
   open "/Applications/dshX.app"
   ```

   方式 B：先双击一次让它弹窗，然后去
   **系统设置 › 隐私与安全性**，下拉到「安全性」一栏点 **「仍要打开」**，
   再确认一次。macOS 15 之后右键「打开」的快捷绕过已经失效，只能走这里。

4. 想要校验完整性，把 `.dmg` 和同名 `.sha256` 放在同一目录：

   ```sh
   shasum -a 256 -c dshX-0.2.2-arm64.dmg.sha256
   ```

**系统要求**：macOS 12+、Apple Silicon（arm64）。Intel 机器需要自己改
`NODE_ARCH=x86_64` 重新构建，见[从源码构建](#从源码构建)。

## 从源码构建

前置：Xcode 命令行工具（要 `xcrun swiftc`）、Node 24（要有 `npm`）、以及联网
（下载并校验 Node 官方二进制）。

```sh
git clone https://github.com/imi4u36d/dshX.git
cd dshX

# 1) 装 dsh 运行时（锁文件里定死版本，可复现）
cd runtime && npm ci && cd ..

# 2) 组装 .app → build/dshX.app
bash shell/make-app.sh

# 3) 打成 DMG → build/dshX-<版本>-<架构>.dmg + .sha256
bash shell/make-dmg.sh
```

`make-app.sh` 干五件事：编译 Swift 壳（`main.swift` + `updater.swift` +
`runtime-updater.swift`）
→ `ditto` 拷入 dsh 运行时、拷入 `updater/apply-update.sh`（自更新的换包脚本）→ 下载官方
Node 并按 `SHASUMS256.txt` 校验 SHA-256 → 写图标与 `Info.plist` → ad-hoc 签名并回验。
全程约 20 秒，产物约 404 MB（`node_modules` 是主要体积）；`make-dmg.sh` 再压成
约 117 MB 的 DMG。

只想在本机跑、不打 DMG，可加 `INSTALL=1`：组装完交给 `shell/install-app.sh`，
它带运行态保护与旧包备份，**装成功后默认删掉 `build/dshX.app`**（省掉那 400M
双份）。要打 DMG 就别用 `INSTALL=1`，或加 `KEEP=1` 把产物留下。

可覆盖的环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `VERSION` | `0.2.2` | 写进 `Info.plist` 的版本号，也进 DMG 文件名 |
| `NODE_ARCH` | `uname -m` | 内置 Node 的架构，必须与壳同架构 |
| `DEPLOY_TARGET` | `12.0` | 壳的最低 macOS。别去掉：不带 `-target` 时 `minos` 会跟 SDK 走，比对方系统还新就启动不了（-10825） |
| `NODE_VERSION` | `24.17.0` | 内置 Node 版本 |
| `ICNS` | `iconsrc/official.icns` | 换图标；给不存在的路径只会退回通用图标 |
| `RUNTIME` | `runtime/` | dsh 运行时目录 |
| `INSTALL` | `0` | 置 1 则组装完交给 `install-app.sh` 安装（只在本机自用时用） |
| `KEEP` | `0` | 置 1 则安装后保留 `build/dshX.app`（默认删） |
| `FORCE` | `0` | 置 1 则跳过「dshX 还在跑」拦截（自负风险） |

```sh
# 例：Intel 机器上构建
NODE_ARCH=x86_64 bash shell/make-app.sh

# 例：换成自己的图标、临时换个版本号（默认版本见上表）
VERSION=0.2.3 ICNS=~/my.icns bash shell/make-app.sh && bash shell/make-dmg.sh
```

更多细节（壳的行为约定、菜单快捷键、日志位置、卸载、踩过的坑）在
[`shell/README.md`](shell/README.md)。

## 自动打包（GitHub Actions）

[`.github/workflows/release-dmg.yml`](.github/workflows/release-dmg.yml) 跑在
`macos-15`（arm64，当前 GA 镜像）上，流程是
`npm ci` → `make-app.sh` → `make-dmg.sh` → 上传 artifact（→ 打 tag 时再建 Release）。

| 触发方式 | 结果 |
| --- | --- |
| 推 tag `v*` | 构建 + **创建 Release**，DMG 与 `.sha256` 作为附件 |
| 网页 Actions › Build dmg › Run workflow | 只出 artifact（可填版本号） |
| push 到 `main` / PR | **不触发**（日常提交不跑构建） |

**发一个版本**：

```sh
git tag v0.2.2
git push origin v0.2.2        # 走完 CI 后 Release 就带好了 DMG
```

tag 重推也不会撞车：workflow 检测到同名 Release 已存在时改为覆盖上传附件。

**手动跑一次**（不发布，只拿 artifact）：

```sh
gh workflow run release-dmg.yml -f version=0.2.2-test
```

几点说明：

- CI 里的 `actions/setup-node` 只是为了拿到 `npm`；**真正打进 `.app` 的 Node 由
  `make-app.sh` 自己下载并校验 SHA-256**，两者互不影响。
- 版本号取自 tag（去掉 `v` 前缀），同时用于 `Info.plist` 与 DMG 文件名。
- artifact 保留 14 天；要长期留存就发 Release。
- 产物是 **ad-hoc 签名、未公证**的，所以 CI 不做签名/公证步骤，对方首次打开要按
  [下载安装](#下载安装)第 3 步放行。真要免放行，得自己配 Developer ID 证书与
  `notarytool` 凭据。

## 仓库结构

```
dshX/
  shell/
    Sources/main.swift        壳本体（Swift + AppKit + WebKit）
    Sources/updater.swift     检查更新：查 GitHub Releases、比版本、下载校验、换包重启
    Sources/runtime-updater.swift 更新 dsh 后端：查 npm registry、装进 staging、
                              探活、签名、换 runtime、重启后端（不换壳）
    updater/apply-update.sh   换包执行者（App 退出后接管：挂 DMG → 替换 → 重开）
    tools/                    验证用小工具：列窗口、比对图标、update-check-test（演练更新链路）
    make-app.sh               组装 build/dshX.app
    make-dmg.sh               把 .app 打成 DMG（含回挂校验 + SHA-256）
    update.sh                 升级 runtime/ 里的 dsh 并重建（开发机链路，跟自更新是两回事）
    install-app.sh            装到 /Applications（运行态保护、备份、装完默认清掉 build 产物）
    README.md                 壳的行为约定、验证记录、卸载方式
  iconsrc/                    图标素材（品牌约束见 THIRD_PARTY_NOTICES.md）
  runtime/
    package.json              只声明一个依赖 @deepseek-ai/dsh
    package-lock.json         锁到具体版本，CI 用 npm ci 复现
  licenses/                   Node 与 dsh 的许可原文（随 DMG 一起发出去）
  .github/workflows/
    release-dmg.yml           自动打包 DMG
  build/                      产物目录（不入库）
```

`runtime/node_modules/`、`build/`、`home/`、`.downloads/` 等都已在
[`.gitignore`](.gitignore) 里排除——尤其 `home/` 下面有本机凭据与私有 profile，
**不要**提交。

## 更新

三条路，各管各的：

| 场景 | 入口 | 数据源 | 换掉什么 |
| --- | --- | --- | --- |
| **上游只更新了 dsh** | **dshX › 更新 dsh 后端…**（⌘B） | npm registry 上的 `@deepseek-ai/dsh` | 只换 `.app` 里那份 dsh 运行时（`Contents/Resources/runtime`）；App 不退出，dshX 版本号不变 |
| dshX 自己发了新版 | **dshX › 检查更新…**（⌘U） | dshX 仓库的 GitHub Releases | 整个 `.app`（壳 + 后端一起换） |
| 开发机改壳、改仓库 | [`shell/update.sh`](shell/README.md) | npm registry，重建仓库 `runtime/` | 重建 `build/dshX.app`（不在菜单里） |

上游频繁发 dsh 的时候走第一条：不用为它重打 DMG、不用发新版本号，装好的人点一下菜单就能跟上。

### 更新 dsh 后端…（⌘B）——只换后端，不发新版本

上游只改了 dsh 时用这条。它读 npm registry（默认 `https://registry.npmjs.org`），
拿 `@deepseek-ai/dsh` 的 **dist-tags（latest / next / alpha 全看）** 里比当前新的最高版本
当候选——挑法跟 `shell/update.sh` 完全一致（上游常把新版发在 `next`/`alpha` 上，
只看 `latest` 会漏），弹窗里当前版本与候选版本都写出来：

- 没有更高的版本 → 弹「dsh 后端已是最新」，列出当前后端与源上最高版本。
- 有更高的版本 → 弹「发现新版 dsh 后端 X（当前 Y）」，写明来源 dist-tag、更新源、
  要替换到哪个目录、磁盘可用空间；给两个按钮：**更新并重启后端** / **取消**。

选「更新并重启后端」之后：用 `.app` 里自带的 **Node + pnpm** 把新版本装进
`runtime/.staged-<版本>/` → 跑 `node …/dsh/lib/bin.js --version` 探活，版本对不上就
不往下走 → 给树里的原生文件（`*.node`、可执行 helper）逐个 ad-hoc 签名（arm64 上没签名的
原生代码会被内核直接杀掉）→ **停掉后端** → 把现行 `node_modules` 挪成
`node_modules.bak-<旧版本>`、staging 那棵改名为 `node_modules`（同卷 rename，不复制
400M）→ 再探一次活，失败就把备份挪回去 → 重新拉起后端。壳不退出，dshX 的版本号也不变。

- **为什么这条能在 App 里做，整包替换却不行**：被换的只是 runtime 这一个子目录，
  而且换之前先把后端子进程停掉——没有进程还 mmap 着里头那些文件之后，改名就是安全的。
  整包替换做不到这一点：壳自己和 WebKit 就跑在被换的包里（见 `apply-update.sh`）。
- **会中断当前会话**：后端要重启，页面会重新载入（`DSH_HOME` 不动，历史会话还在盘上）。
- **装不动会明说**：`/Applications` 不可写、macOS 14+ 的「App 管理」拦着、pnpm 装失败、
  探活不过——staging 会被删掉、后端继续用旧树，弹窗里给原因和日志路径。
- **回退**：旧后端留在 `runtime/node_modules.bak.<旧版本>`（默认留 1 份，
  `DSHX_RUNTIME_BACKUPS` 改份数，`0` 关）。要回退就退出 dshX，删掉新的 `node_modules`，
  把备份改回 `node_modules`。
- **装的不是锁文件里的树**：这条按 registry 上的版本现解析依赖（跟开发机
  `update.sh` 一样），不像 DMG 那样走 `runtime/package-lock.json`。所以上游换了依赖
  （比如 0.1.6-alpha.2 多出 `@deepseek-ai/libreoffice-kit-darwin-arm64`，解包多 260M），
  更新后的体积会跟着变——弹窗里的「可用空间」就是给你先看一眼的。
- **装完的 `.app` 会重新 ad-hoc 签名**：改了 `Resources` 之后原来的封条已经对不上，
  更新器会自己重签一次，让 `codesign --verify` 继续通过（签不动只记日志，不影响运行）。
- 更新相关的调试开关见下面那张表。

### 检查更新…（⌘U）——自更新整个 App

装好之后想升级整个 App，就点菜单栏 **dshX › 检查更新…**。它读 GitHub Releases
（默认 `https://api.github.com/repos/imi4u36d/dshX/releases`），拿上面最新的 tag
跟**当前 App 自己的版本**比，弹窗里两个版本号都写出来，好让你自己核对：

- 没有更高的版本 → 弹「已是最新版本」，列出当前版本与更新源上的最新版本
  （0.2.0 对着 0.1.1 会说「已是最新」，不会让你降级）。
- 有更高的版本 → 弹「发现新版本 dshX X（当前 Y）」，写明版本、tag、包名与大小、
  要替换掉哪个 `.app`，给两个按钮：**更新并重启** / **取消**；取消的弹窗里也带着
  Releases 页地址，想手动下就去那儿。

选「更新并重启」之后：下载对应架构的 `.dmg`（100 多 MB，一两分钟）→ 按 Releases
给的 SHA-256 校验（下载项没带 `digest` 就改取同名的 `.sha256`；对不上直接停下，
不装）→ **dshX 退出** → 剩下的交给 `shell/updater/apply-update.sh`：挂 DMG、备份旧包、
`ditto` 写入新包、卸载 DMG、`open` 重开新 App。

- **整包替换为什么不能在 App 里做**：壳自己和 WebKit 就跑在被替换的那个包里，后端
  也正 mmap 着里面的 `.js`/`.node`，让 App 自己覆盖自己等于把当前会话连根拔掉。所以
  脚本先等主进程退出，再确认没有任何进程的镜像还落在旧包里，才动手。
  （只换 runtime 子目录不在此列——那种情况先停掉后端就能安全改名，见「更新 dsh 后端…」。）
- 旧包备份在同目录 `dshX.app.bak.<时间戳>`，默认留 1 份（`DSH_UPDATE_BACKUPS` 调，`0` 关）；
  新包写坏会自动把备份挪回去。
- 前提是对目标 `.app` 有写权限。macOS 14+ 可能因「App 管理」权限拒绝写入——脚本不会
  硬来，会保留备份，弹窗里给出日志路径和 Releases 页。
- 换完的新包仍是 ad-hoc 签名。App 内下载的文件不带 quarantine 标记，正常不会再被
  Gatekeeper 拦一次；从别处拷来的 DMG 仍要先按上面「下载安装」的办法放行。

### 更新相关的调试开关（设了才生效，重启 dshX）

**「检查更新…」（换整个 App）**：`DSH_UPDATE_FEED_URL` 换更新源（可以是本地
`http://127.0.0.1:…/releases.json`）·
`DSH_UPDATE_TARGET` 换要替换的 `.app`（指到沙盒目录里演练）· `DSH_UPDATE_NO_RESTART=1`
换完不自动重启 · `DSH_UPDATE_FAKE_VERSION` 把「当前版本」当成本地开发版本 ·
`DSHX_ALLOW_PRERELEASE=1` 允许跟预发布版 · `DSH_GITHUB_TOKEN` 缓解 API 限流 ·
`DSHX_AUTO_CHECK_UPDATE=1` 启动 3 秒后自动查一次（只为演练，平时别开）。

**「更新 dsh 后端…」（只换 runtime）**：`DSHX_NPM_REGISTRY` 换 registry 根地址
（国内可指镜像，如 `https://registry.npmmirror.com`）· `DSHX_BACKEND_VERSION` 指定确切
版本、跳过「只升不降」的判断（演练用）· `DSHX_RUNTIME_BACKUPS` 旧后端备份留几份（默认 1，
`0` 不留）· `DSHX_PNPM_STORE` 换 pnpm store 位置 · `DSHX_KEEP_PNPM_STORE=1` 保留 store
（默认用完就删，省一份盘，代价是下次更新要重新下载）· `DSHX_RUNTIME_DIR` 换要操作的
runtime 目录（演练用）· `DSHX_NODE` / `DSHX_PNPM` 换内置 Node / pnpm 的路径。

匿名读 GitHub 的配额是 **60 次/小时，按出口 IP 算**：走代理/VPN 时出口是共享的，
别人用光也会记到同一个 IP 上（跟本机点了几次无关），于是「检查更新」弹 403。
App 的日志（`~/Library/Application Support/dshX/backend.log`）会记下每次响应的
`x-ratelimit` 余量、重置时间、GitHub 点名的出口 IP，先看那几行再决定怎么办。
绕过的办法按省事排序：等配额重置 · 让 `api.github.com` 直连或换节点 ·
给 App 设 token——`launchctl setenv DSH_GITHUB_TOKEN <token>` 后重启 dshX
（GUI App 读的是 launchd 环境，不是你的 shell；认证后按 token 计 5000 次/小时）。
token 只需要公开仓库只读，别再给它多余权限。

整条链路可以在不动 `/Applications` 的前提下演完：

```sh
bash shell/tools/update-check-test/run.sh            # 离线用例：版本比较 + 取包逻辑
bash shell/tools/update-check-test/rehearse-update.sh # 假更新源 + 假 App，演整条链路

# 只换后端那条链路（真联网、真装、真换目录，但发生在 .tmp 里的假 runtime）
bash shell/tools/update-check-test/run.sh --runtime-check      # 只读：查 npm registry 挑哪个版本
bash shell/tools/update-check-test/run.sh --runtime-rehearse   # 真装一遍并走完提升（几百 MB、几分钟）
```

## 运行时行为速查

- 后端命令：`node <内嵌>/dsh/lib/bin.js web --host 127.0.0.1 --port 0 --no-open`，
  端口由内核分配，地址（含进程级 token）从后端 stdout 里抓。
- **先探活再加载**：拿到地址先用 URLSession GET 一次，确认 2xx/3xx 才交给 WebView。
- 只允许导航到回环地址，外部链接交给系统默认浏览器。
- 私有 `DSH_HOME`：`~/Library/Application Support/dshX/home`，**不动 `~/.dsh`**；
  默认工作目录 `~/Library/Application Support/dshX/workspace`。
- 日志：`~/Library/Application Support/dshX/backend.log`（启动失败先看它）。
- 退出会带走后端，不留孤儿端口（正常退出 / `SIGTERM` / `kill -9` 三条路径都覆盖）。
- 菜单：**dshX › 检查更新…**（⌘U，换整个 App）、**dshX › 更新 dsh 后端…**（⌘B，只换
  `.app` 里的 dsh 运行时），详见「更新」一节；还有
  **文件 › 选择工作目录并重启后端**（⌘O）、**查看 › 重启后端**（⌘⇧R）、
  拷贝后端地址（⌘⇧C）、在默认浏览器中打开（⌘⇧B）。
- 整页不滚、不缩放（壳侧注入 CSS + 关掉缩放），内部滚动区照旧能滚。
- 外观按原生 App 来，不按浏览器来：页面里右键只有文本编辑项（检查元素 / 翻译 /
  查询 / 搜索 / 分享 / 朗读都不出；链接、图片、空白处连菜单都不弹），标题栏
  （红绿灯那一条）跟着页面主题同色。要 Web Inspector 查页面得带
  `DSHX_ALLOW_WEB_MENU=1` 启动，细节见 [`shell/README.md`](shell/README.md)。

## 已知限制

- **ad-hoc 签名、无公证**：别人首次打开必须手动放行 Gatekeeper；拷贝分发时
  「已损坏」提示通常就是隔离标记没去掉。
- **仅 arm64**：内置 Node 与 Swift 壳都是单架构。Intel 上要自己
  `NODE_ARCH=x86_64` 重建。
- 体积大：装好约 404 MB，主要来自完整 `node_modules`。「更新 dsh 后端…」装哪个版本
  取决于上游当时依赖了多少东西（0.1.6-alpha.2 起多了一个 260M 的 LibreOffice kit），
  所以点更新前先看弹窗里的可用空间。
- 「更新 dsh 后端…」要把文件写进 `/Applications/dshX.app`，因此同样受「App 管理」权限
  约束；写不进去时它会明说，不会留下半截的 runtime。
- 没有单实例锁：正常 `open` 不会重复启动，但 `open -n` 会起第二个实例，
  两个后端会共用同一个私有 `DSH_HOME`。
- 模型切换提示「当前会话已被占用」时，通常是有另一个 dsh 后端共用同一个
  `DSH_HOME`（插件市场的「重启」可能留下孤儿进程）。启动 dshX 时会检测并让你
  一键结束；运行期间新出现的仍可用
  `lsof -nP -iTCP -sTCP:LISTEN | grep node` 找到后退出它。
- 图标是官方品牌素材，仅作本机/自用观感；对外分发或商用前请换成自己的图标。

## 许可

- 本仓库自己的代码（`shell/`、`.github/`）：[MIT](LICENSE)。
- 打包进 `.app` 的 `@deepseek-ai/dsh`（MIT，© 2026 DeepSeek）与 Node.js v24.17.0
  （MIT 及一批随附许可）：原文在 [`licenses/`](licenses/)，随 DMG 一起分发。
- 图标**不在** MIT 范围内，见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
