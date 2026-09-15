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
   shasum -a 256 -c dshX-0.1.0-arm64.dmg.sha256
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

`make-app.sh` 干五件事：编译 Swift 壳 → `ditto` 拷入 dsh 运行时 → 下载官方 Node
并按 `SHASUMS256.txt` 校验 SHA-256 → 写图标与 `Info.plist` → ad-hoc 签名并回验。
全程约 20 秒，产物约 404 MB（`node_modules` 是主要体积）；`make-dmg.sh` 再压成
约 117 MB 的 DMG。

只想在本机跑、不打 DMG，可加 `INSTALL=1`：组装完交给 `shell/install-app.sh`，
它带运行态保护与旧包备份，**装成功后默认删掉 `build/dshX.app`**（省掉那 400M
双份）。要打 DMG 就别用 `INSTALL=1`，或加 `KEEP=1` 把产物留下。

可覆盖的环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `VERSION` | `0.1.0` | 写进 `Info.plist` 的版本号，也进 DMG 文件名 |
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

# 例：换成自己的图标、带上版本号
VERSION=0.2.0 ICNS=~/my.icns bash shell/make-app.sh && bash shell/make-dmg.sh
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
| push 到 `main` | 只出 artifact，当作构建门禁 |
| 改动 `shell/`、`iconsrc/`、`runtime/package*.json` 的 PR | 只出 artifact（**不会**发布） |

**发一个版本**：

```sh
git tag v0.2.0
git push origin v0.2.0        # 走完 CI 后 Release 就带好了 DMG
```

tag 重推也不会撞车：workflow 检测到同名 Release 已存在时改为覆盖上传附件。

**手动跑一次**（不发布，只拿 artifact）：

```sh
gh workflow run release-dmg.yml -f version=0.2.0-test
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
    tools/                    验证用小工具：列窗口、比对图标是否真的生效
    make-app.sh               组装 build/dshX.app
    make-dmg.sh               把 .app 打成 DMG（含回挂校验 + SHA-256）
    update.sh                 升级 runtime/ 里的 dsh 并重建
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

## 运行时行为速查

- 后端命令：`node <内嵌>/dsh/lib/bin.js web --host 127.0.0.1 --port 0 --no-open`，
  端口由内核分配，地址（含进程级 token）从后端 stdout 里抓。
- **先探活再加载**：拿到地址先用 URLSession GET 一次，确认 2xx/3xx 才交给 WebView。
- 只允许导航到回环地址，外部链接交给系统默认浏览器。
- 私有 `DSH_HOME`：`~/Library/Application Support/dshX/home`，**不动 `~/.dsh`**；
  默认工作目录 `~/Library/Application Support/dshX/workspace`。
- 日志：`~/Library/Application Support/dshX/backend.log`（启动失败先看它）。
- 退出会带走后端，不留孤儿端口（正常退出 / `SIGTERM` / `kill -9` 三条路径都覆盖）。
- 菜单：**文件 › 选择工作目录并重启后端**（⌘O）、**查看 › 重启后端**（⌘⇧R）、
  拷贝后端地址（⌘⇧C）、在默认浏览器中打开（⌘⇧B），以及 **更新 ›**。
- 整页不滚、不缩放（壳侧注入 CSS + 关掉缩放），内部滚动区照旧能滚。

## 已知限制

- **ad-hoc 签名、无公证**：别人首次打开必须手动放行 Gatekeeper；拷贝分发时
  「已损坏」提示通常就是隔离标记没去掉。
- **仅 arm64**：内置 Node 与 Swift 壳都是单架构。Intel 上要自己
  `NODE_ARCH=x86_64` 重建。
- 体积大：装好约 404 MB，主要来自完整 `node_modules`。
- 没有单实例锁：正常 `open` 不会重复启动，但 `open -n` 会起第二个实例，
  两个后端会共用同一个私有 `DSH_HOME`。
- 图标是官方品牌素材，仅作本机/自用观感；对外分发或商用前请换成自己的图标。

## 许可

- 本仓库自己的代码（`shell/`、`.github/`）：[MIT](LICENSE)。
- 打包进 `.app` 的 `@deepseek-ai/dsh`（MIT，© 2026 DeepSeek）与 Node.js v24.17.0
  （MIT 及一批随附许可）：原文在 [`licenses/`](licenses/)，随 DMG 一起分发。
- 图标**不在** MIT 范围内，见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
