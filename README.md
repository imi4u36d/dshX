# dshX

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI
包成一个原生 macOS 应用：内嵌 Node 与 dsh 后端，用 `WKWebView` 打开界面，
退出时回收后端。

不是 DeepSeek 官方产品。图标来自上游项目，授权边界见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 使用

从 [Releases](https://github.com/imi4u36d/dshX/releases) 下载 DMG，拖进
`/Applications` 后打开即可。要求 macOS 12+ / Apple Silicon。

菜单里有两个更新入口：

- `dshX > 检查更新…`（`⌘U`）：更新整个 App
- `dshX > 更新 dsh 后端…`（`⌘B`）：只更新内嵌的 dsh runtime

日志在 `~/Library/Application Support/dshX/backend.log`。

## 自行构建

需要 Xcode 命令行工具（`xcrun swiftc`）、Node.js 24 与 npm。

```sh
cd runtime && npm ci && cd ..
bash shell/make-app.sh          # 产物：build/dshX.app
INSTALL=1 bash shell/make-app.sh # 顺带装到 /Applications
bash shell/make-dmg.sh          # 出 DMG
```

Intel 机器加 `NODE_ARCH=x86_64`。

## 许可

仓库代码 MIT，见 [`LICENSE`](LICENSE)。
