# dshX

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的
Web UI 包成一个原生 macOS 应用。

dshX 只做三件事：

- 启动内嵌的 dsh Web 后端
- 用 `WKWebView` 原生窗口承载界面
- 退出时回收后端子进程

另外保留两条更新链路：

- `dshX > 检查更新…` 更新整个 App
- `dshX > 更新 dsh 后端…` 只更新内嵌的 dsh runtime

这不是 DeepSeek 官方产品，与 DeepSeek 没有隶属或合作关系。图标来自上游项目，
授权边界见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 环境要求

- macOS 12+
- Apple Silicon
- Xcode 命令行工具，需要 `xcrun swiftc`
- Node.js 24 与 npm，仅构建时需要
- 网络，用于下载并校验官方 Node 二进制

Intel 机器可以这样构建：

```sh
NODE_ARCH=x86_64 bash shell/make-app.sh
```

## 构建

先安装锁定的 dsh runtime：

```sh
cd runtime
npm ci
cd ..
```

然后组装 `.app`：

```sh
bash shell/make-app.sh
open build/dshX.app
```

需要安装到 `/Applications`：

```sh
INSTALL=1 bash shell/make-app.sh
```

需要 DMG：

```sh
bash shell/make-dmg.sh
```

产物位于 `build/`。

常用构建变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `VERSION` | `0.2.3` | App 与 DMG 版本号 |
| `NODE_ARCH` | 当前架构 | 内嵌 Node 架构 |
| `NODE_VERSION` | `24.17.0` | 内嵌 Node 版本 |
| `DEPLOY_TARGET` | `12.0` | 最低 macOS 版本 |
| `ICNS` | `iconsrc/official.icns` | 应用图标 |
| `INSTALL` | `0` | 置为 `1` 时安装到 `/Applications` |
| `KEEP` | `0` | 安装后是否保留 `build/dshX.app` |

## 更新

### 检查更新

菜单：`dshX > 检查更新…`，快捷键 `⌘U`。

更新源是 dshX 的 GitHub Releases。发现更高版本后，App 会下载对应架构的 DMG，
校验 SHA-256，退出，再由内置的 `updater/apply-update.sh` 替换 `.app` 并重新打开。
旧包会保留为同目录下的 `dshX.app.bak.<时间戳>`。

### 更新 dsh 后端

菜单：`dshX > 更新 dsh 后端…`，快捷键 `⌘B`。

更新源是 npm registry 上的 `@deepseek-ai/dsh`。更新器会把新版本装进
`Contents/Resources/runtime`，探活成功后停掉后端、切换 runtime，再重新启动后端。
App 本身不退出，`DSH_HOME` 和会话数据不动。

更新过程与错误都会写入：

```text
~/Library/Application Support/dshX/backend.log
```

更新源与演练相关环境变量：

| 变量 | 用途 |
| --- | --- |
| `DSH_UPDATE_FEED_URL` | 替换 App 更新源 |
| `DSH_UPDATE_TARGET` | 替换目标 `.app`，用于沙盒演练 |
| `DSHX_ALLOW_PRERELEASE` | 置为 `1` 时接受预发布版本 |
| `DSHX_NPM_REGISTRY` | 替换 dsh runtime 的 npm registry |
| `DSHX_BACKEND_VERSION` | 指定要安装的 dsh runtime 版本 |
| `DSHX_RUNTIME_DIR` | 替换要更新的 runtime 目录 |
| `DSHX_DISABLE_MENU_FOCUS_SHIM` | 置为 `1` 时不注入 WebKit 兼容补丁（只为排查用，见下） |

## WebKit 兼容补丁

壳在页面里注入一小段脚本，目的是让「模型 / 推理等级 / 访问模式」这类弹层在
鼠标下能正常选中。原因不在 dsh 本身，也不在右键菜单：

- Safari 引擎（WKWebView 就是它）在 `mousedown` 时会把焦点从当前元素上拿走，
  却不把焦点给被点的 `<button>`；Chromium（Chrome、Electron）会给。
- dsh 的弹层打开或进入下一层时，会把当前选中行 `focus` 住，并在 `onBlur` 时关闭自己。
- 两者相遇的表现：菜单弹得出来，真实鼠标点行时焦点先丢、弹层随即关闭，
  `mouseup` / `click` 落到页面其它元素上，行的 `onClick` 从未执行 —— 就像「点了没反应」。

补丁只做一件事：在弹层（`[role=menu]` / `[role=listbox]`）里的行上按下鼠标时
`preventDefault()`，不让焦点迁移；焦点留在弹层里，`click` 就能正常派发。
键盘操作（Tab / Enter / 方向键）不走 `mousedown`，不受影响。

复现原始问题（排查用）：

```sh
DSHX_DISABLE_MENU_FOCUS_SHIM=1 open -a /Applications/dshX.app
```

## 数据目录

默认运行状态放在：

```text
~/Library/Application Support/dshX/
  backend.log
  home/
  workspace/
```

壳会从后端环境里剔除已有 `DSH_*` 变量，再显式写入自己的 `DSH_HOME`，避免继承
其它 dsh 会话状态。

## 仓库结构

```text
dshX/
  shell/
    Sources/main.swift         原生 App 与后端起停
    Sources/updater.swift      App 自更新
    Sources/runtime-updater.swift
                               dsh 后端更新
    updater/apply-update.sh    App 退出后替换 .app
    make-app.sh                组装 build/dshX.app
    make-dmg.sh                生成 DMG 与 SHA-256
    install-app.sh             安装到 /Applications
  runtime/                     dsh 与 Node 运行时声明
  iconsrc/                     应用图标素材
  licenses/                    第三方许可原文
  .github/workflows/           tag 发布 DMG
```

## 从命令行更新开发环境

`shell/update.sh` 用于升级仓库里的 `runtime/` 并重建 App：

```sh
cd shell
./update.sh
./update.sh update --dry-run
./update.sh update --yes
```

## 许可

本仓库代码使用 MIT 许可，见 [`LICENSE`](LICENSE)。打包进 App 的 Node、dsh
运行时及图标另有许可或品牌约束，见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
