# dshX Shell

这是 dshX 的 macOS 原生壳。实现范围只包括：

- 找到内嵌的 Node 与 dsh 入口
- 启动 `dsh web --host 127.0.0.1 --port 0 --no-open`
- 从后端输出中读取带 token 的回环地址
- 用 `WKWebView` 展示页面
- 退出时结束后端
- 提供 App 自更新与 dsh runtime 更新

`main.swift` 负责壳和后端生命周期；`updater.swift` 与
`runtime-updater.swift` 负责两条更新链路。

## 构建

在仓库根目录运行：

```sh
cd runtime && npm ci && cd ..
bash shell/make-app.sh
open build/dshX.app
```

`make-app.sh` 会：

1. 编译 `main.swift`、`updater.swift`、`runtime-updater.swift`
2. 拷入 `runtime/node_modules`
3. 下载官方 Node 并按 `SHASUMS256.txt` 校验
4. 写入图标与 `Info.plist`
5. 用本机 Apple Development 证书签名并回验（钥匙串里没有该证书时回退 ad-hoc）

安装到 `/Applications`：

```sh
INSTALL=1 bash shell/make-app.sh
```

已有 dshX 正在运行时，`install-app.sh` 默认拒绝覆盖，避免把正在使用的 runtime
从旧包里拔掉。确认要强制安装时使用 `FORCE=1`。

## 运行约定

- 后端只监听 `127.0.0.1`，端口由系统分配。
- 页面地址只从后端进程 stdout/stderr 读取，不写死端口。
- 环境变量先从父进程白名单继承，再清除并重建 `DSH_HOME`。
- 默认数据目录是 `~/Library/Application Support/dshX/`。
- 正常退出、`SIGTERM`、`SIGINT` 都会回收后端。
- `kill -9` 或强制退出时，由内嵌的 sh 看门狗回收 Node 子进程。

后端输出与壳日志写入：

```text
~/Library/Application Support/dshX/backend.log
```

## WebKit 兼容补丁

壳在 `documentStart` 注入两段脚本，都是 WebKit 与 Chromium 的差异补偿：

- **整页不滚、不缩放**：`allowsMagnification` 关掉，并注入 CSS + 一段 scroll 兜底，
  把「整页级」容器钉死。三个来源：
  1. 双指缩放——一旦打开，整页变成可四方拖动的图层；
  2. 文档层滚动——前端根样式只有 `height:100%`，`overflow:auto` 的容器滚到边界后把
     滚动链交给文档层，整页跟着上下、左右弹；
  3. **程序化滚动**——`overflow:hidden` 的盒子仍然是滚动容器，`scrollIntoView` /
     `focus` 照样能把它滚走。dsh 的布局容器 `[class*="_frame"]`（AppFrame）就是
     `overflow:hidden`，而它的网格比视口宽一列右侧栏（1280 宽的窗口里 `scrollWidth`
     是 1856），于是页面里任何一次 `scrollIntoView` 落在离屏区域，就会把整个 AppFrame
     横移最多 576px——这才是「偶尔整页左右滚」的真正原因，前两条的解释都不对。
  所以用 `overflow:clip` 而不是 `hidden`：`clip` 不产生滚动容器，程序化滚动也动不了它。
  只钉整页级容器，内部 `overflow:auto` 的滚动区照旧能滚（已实测：`overflow:auto` 和
  `overflow-x:hidden; overflow-y:auto` 的大滚动区都不受影响）。
  调试开关：`DSHX_PINCH_ZOOM=1` 恢复双指缩放、`DSHX_ALLOW_PAGE_SCROLL=1` 完全不注入。
- **弹层里的行点得动**：Safari 引擎在 `mousedown` 时会把焦点从当前元素上拿走，却不给
  被点的 `<button>`（Chromium 会给）；dsh 的弹层在 `onBlur` 里关自己，于是「菜单弹得
  出来、点模型没反应」。补丁在 `[role=menu]` / `[role=listbox]` 内的行上按下鼠标时
  `preventDefault`，不让焦点迁移。
  调试开关：`DSHX_DISABLE_MENU_FOCUS_SHIM=1` 关掉补丁复现原问题。

> 整页滚动这段补丁曾在 `8ad0668` 重写 `main.swift` 时被整段丢掉（0.2.3 起回归）；
> 0.2.6 恢复成 `overflow:hidden` 版本后**实测无效**，0.2.7 才换成 `clip` 并补上兜底。
> 改这块代码时注意：`fixedShellStyle` 会被拼进 JS 的单引号字符串，**不能有换行**。

## App 自更新

入口：`dshX > 检查更新…`，快捷键 `⌘U`。

流程：

1. 读取 GitHub Releases
2. 比较当前 `CFBundleShortVersionString`
3. 下载当前架构的 DMG
4. 校验 Release digest 或同名 `.sha256`
5. App 退出
6. `updater/apply-update.sh` 挂载 DMG、备份旧 App、替换并重新打开

换包脚本位于 `updater/apply-update.sh`，构建时会复制到
`Contents/Resources/updater/`。

## dsh 后端更新

入口：`dshX > 更新 dsh 后端…`，快捷键 `⌘B`。

数据源是 npm registry 上的 `@deepseek-ai/dsh`。更新器会：

1. 选择比当前版本新的最高版本
2. 安装到 runtime 下的 staging 目录
3. 探活并给原生文件重新签名
4. 停止后端
5. 切换 `node_modules`
6. 重新启动后端

如果启动失败，旧 runtime 会自动回滚。更新不退出 App，也不修改用户的
`DSH_HOME`。

## 发布

```sh
bash shell/make-dmg.sh
```

输出：

```text
build/dshX-<版本>-<架构>.dmg
build/dshX-<版本>-<架构>.dmg.sha256
```

GitHub Actions 在推送 `v*` tag 时构建 DMG 并创建 Release。

## 开发环境更新

`update.sh` 用于升级仓库里的 dsh runtime 并重建 App：

```sh
./update.sh
./update.sh update --dry-run
./update.sh update --yes
./update.sh update --yes --install
```
