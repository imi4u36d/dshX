# dshX —— 给 deepseek-harness 套的一个 macOS 壳

把 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI 包成一个原生 macOS 应用：
双击 `.app` 就拉起本地 dsh 后端，并用原生窗口（WKWebView）承载界面。
**非官方**：ad-hoc 签名、没有公证，所以分发出去对方首次打开要手动放行 Gatekeeper
（步骤见仓库根 `README.md`），也不要以任何形式宣传成官方出品
（命名沿用官方推荐的 `DSH` 简称，见 `THIRD_PARTY_NOTICES.md` 与上游 BRAND_GUIDELINES）。

## 图标

`iconsrc/official.icns` 直接取自官方 DSH Desktop.app 的 `Contents/Resources/icon.icns`，
也就是官方的鲸鱼标（11 个尺寸 16→1024 齐全，不是我拼的）。它的原始素材对应
`packages/client/ui-primitives/src/FishLogo.tsx` 里的 `FISH_LOGO_PATH`——
`packages/client/ui-brand-official` 把它称作 "the official whale mark"。
想换掉：`ICNS=/path/to/别的.icns ./make-app.sh`（缺文件也只是退回通用图标）。

注意它会和你已装的官方 DSH Desktop 在 Dock 里长得一模一样，需要区分的话建议换个
背景色/描边的变体，或者改 `CFBundleName` 之外的显示文案。

## 它跟仓库自带的 apps/desktop 有什么区别

仓库里已有官方的 Electron 桌面壳 `apps/desktop`（无监听端口、走 `dsh-app://` 私有协议）。
那条路的 macOS 打包**强制要求** Developer ID 证书 + 公证凭据，并且会硬校验签名身份。
本项目改成自己写一个几百行的 AppKit 壳，绕开发布链路，只满足「在自己机器上跑起来」：

| | 官方 apps/desktop | 这里的 dshX |
| --- | --- | --- |
| 承载方式 | Electron + `dsh-app://` 帧管道 | WKWebView + `http://127.0.0.1:<随机端口>` |
| dsh 来源 | 打包时生成离线 seed store | 直接内嵌 `npm install` 好的 node_modules |
| 签名 | Developer ID + 公证（必须） | ad-hoc，仅本机可用 |
| 用途 | 发版 | 本地自用 / 改着玩 |

## 目录

```
dsh-app/
  runtime/           dsh 运行时：package.json + package-lock.json（锁死版本，npm ci 复现），
                     装出来的 node_modules 打进 .app 的 Resources/runtime
  iconsrc/           图标来源素材（official.icns / official-app-icon-mac.png）
  licenses/          Node 与 dsh 的许可原文（随 DMG 一起发出去）
  shell/
    Sources/main.swift        壳本体
    tools/list-windows.swift  验证用：列出某进程的窗口（不需要截图权限）
    make-app.sh               一键组装 .app
    make-dmg.sh               把 .app 打成 DMG（含回挂校验与 SHA-256）
    update.sh                 更新上游 dsh（「更新」菜单与手跑都用它）
    install-app.sh            把 build/dshX.app 装到 /Applications（运行态保护 + 备份 + 装完默认清掉产物）
  .github/workflows/          CI：自动打 DMG，打 tag 就发 Release
  build/dshX.app              产物
```

## 构建

前置：`runtime/` 里装好 dsh（一次即可）。仓库里已经带了 `package.json` 与
`package-lock.json`（版本锁死），所以直接用 `npm ci` 即可复现：

```sh
cd dsh-app/runtime && npm ci
```

> 想跟到更新的 dsh 版本，用同目录的 `update.sh`，别手改 `package.json`：
> `./update.sh update --yes` 会升级版本、重建 `.app`。

> npm 11 的 allow-scripts 会跳过 node-pty / dsh-subprocess-local 的安装脚本。
> 实测不影响启动（node-pty 的 `spawn-helper` 在 tarball 里已带执行位）；
> 若终端/PTY 相关能力异常，再单独补跑那两个 postinstall。

然后：

```sh
cd dsh-app/shell
./make-app.sh                  # 组装到 build/dshX.app（产物留着）
./make-dmg.sh                  # 再打成 build/dshX-<版本>-<架构>.dmg（+ .sha256）
INSTALL=1 ./make-app.sh        # 想直接装：组装完交给 install-app.sh，装成功后删掉 build 产物
INSTALL=1 KEEP=1 ./make-app.sh # 同上，但保留 build 产物（还要接着打 DMG 就这么跑）
```

`INSTALL=1` 不再自己 `rm + ditto`，而是叫 `install-app.sh` 干：它会先查「有没有
进程还在用旧包」（那个 .app 里跑着的就是你自己，强装会把会话连根拔），默认
备份旧包，`ditto` 完再对**目标**校一次签名；运行态拦截没过去就整个安装不做。
`FORCE=1` 跳过运行态拦截（自负风险）。

> 写权限之外还可能卡 macOS 14+ 的「App 管理」：系统设置 › 隐私与安全性 ›
> App 管理，给跑脚本的终端打勾，否则 `rm`/`ditto` 会给你个 `Operation not permitted`。
> 自测这类脚本一定用 `--dest` 指到临时目录：漏一次就把真 app 盖了（本仓库踩过）。

脚本做五件事：编译 Swift 壳 → ditto 拷运行时 → 下载并校验 Node 24.17.0（官方
tarball，SHA-256 比对）→ 拷图标 + 写 Info.plist → ad-hoc 签名。全程约 20 秒，
产物约 404 MB；`make-dmg.sh` 压出来约 117 MB。

`VERSION`（写进 Info.plist 与 DMG 文件名）和 `NODE_ARCH`（默认跟随本机架构）
都可以用环境变量覆盖，例如 `NODE_ARCH=x86_64 ./make-app.sh`。

编译必须带这三样，少一样都会出「编得过、启动不了」：

```
TMPDIR=<可写目录> -module-cache-path=<可写目录>   # 少了在受限环境里写不了缓存
-target <arch>-apple-macosx<版本>              # 少了 minos 会跟着 SDK 走
```

`-target` 这个最容易省：不给时 `swiftc` 把 SDK 自己的版本号写进 Mach-O 的
`LC_BUILD_VERSION`（实测 `minos 28.0`），LaunchServices 按「要求比当前系统还新」
直接拒启动，报 `-10825`；`Info.plist` 里的 `LSMinimumSystemVersion` 拦不下它，
它以 Mach-O 为准。脚本现在默认 `-target …-macosx12.0`（`DEPLOY_TARGET` 可改），
并在编完后拿 `minos` 与本机系统版本号比一句，不匹配就退出而不是给你个跑不起来的包。

装完想确认它真能启动（别只看签名，签名过不代表能启动）：

```sh
otool -l /Applications/dshX.app/Contents/MacOS/dshX | grep -A4 LC_BUILD_VERSION  # minos 应 ≤ 系统
open /Applications/dshX.app            # 报 -10825 就是上面那个坑
swift shell/tools/list-windows.swift   # 健在时窗口标题会带后端端口
```

## 壳的行为约定

- 后端命令：`node <内嵌>/dsh/lib/bin.js web --host 127.0.0.1 --port 0 --no-open`
  端口由内核分配；地址（含 token）从后端 stdout 里抓。token 是进程级凭据，
  不是单次消费，所以探活不会把它用掉。
- **先探活再加载**：拿到地址后先用 URLSession GET 一次，确认 2xx/3xx 才交给
  WebView；失败重试三次再报错。启动期窗口里有一页「正在启动后端」的占位页。
- 只允许导航到回环地址，外部链接交给系统默认浏览器。
- **整页不滚、不缩放**（壳这一侧兜住，不依赖页面 CSS）：`allowsMagnification` 关掉，
  并在每个页面 `documentStart` 注入一条 `html,body,#root{overflow:hidden;
  overscroll-behavior:none}`。针对的是同一个现象——「整个 App 能往上/下滚」，
  它有两个来源：① 双指缩放把整页放大成可四下拖动的图层（macOS 上
  `allowsMagnification` 默认是关的，本壳以前显式打开过）；② 终端输出 / 代码块 /
  右侧面板这些 `overflow:auto` 的容器滚到底后把滚动链交给文档层，而前端只写了
  `html,body,#root{height:100%}`，没有 `overflow` 限制，于是整页跟着橡皮筋。
  注入只钉文档层，内部滚动区（终端、代码块、面板）照旧能滚。
  调试开关：`DSHX_PINCH_ZOOM=1` 恢复双指缩放、`DSHX_ALLOW_PAGE_SCROLL=1`
  不注入样式（真出现某个页面必须靠整页滚动才能够到底时，用它验证是不是这条规则的锅）。
- 子进程环境**剔除全部 `DSH_*` 变量**再重设 `DSH_HOME`，避免继承别的 harness
  会话状态（`DSH_SHELL` / `DSH_SESSION_ID` / `DSH_WEB_URL` 这些会被误认）。
- `DSH_HOME` 默认 `~/Library/Application Support/dshX/home`，**不动 `~/.dsh`**
  （那个可能正被另一个 harness 实例独占，抢它会打架）。
- 退出必须带走后端，不留孤儿端口，三条路径都覆盖：
  正常退出（`applicationShouldTerminate` → `stop()`）、`SIGTERM`/`SIGINT` 的
  DispatchSource 兜底、以及 `kill -9`/Force Quit 时由内嵌的 sh 看门狗按
  「父进程还在不在」收掉 node。
- 菜单：**文件 › 选择工作目录并重启后端**（⌘O）、**查看 › 重启后端**（⌘⇧R）、
  拷贝后端地址（⌘⇧C，含 token，可粘给浏览器）、在默认浏览器中打开（⌘⇧B）、
  以及一个 **更新 ›** 菜单（见「更新上游 dsh」一节）。
  调试用：页面里右键 › Inspect Element（developerExtrasEnabled 已开；WebKit 没有
  公开的「打开 Web Inspector」API）。

## 更新上游 dsh（「更新」菜单 / `update.sh`）

dshX 只是壳，**真正跑的后端是打包进 `.app` 的 npm 包 `@deepseek-ai/dsh`**
（`Contents/Resources/runtime/node_modules/@deepseek-ai/dsh`）。所以「更新上游」
= 把这份包升到新版 → 重跑 `make-app.sh` 重建 `.app` → 重开。这一步没法由页面
自己完成（页面正跑在被替换的那份后端上），必须在 App 外部做。

**`update.sh`** 就是这条外部链路（在本目录 `shell/`）：

```sh
./update.sh                       # 只看有没有新版（只读，一次网络请求，不改动）
./update.sh update --dry-run      # 打印将要执行的命令，不真的装
./update.sh update --yes          # 升级 runtime/ 里的 @deepseek-ai/dsh 并重建 build/dshX.app
./update.sh update --yes --install  # 再装到 /Applications（需先完全退出 dshX；装成后默认删 build 产物）
./update.sh update --yes --install --keep-src  # 同上，但保留 build/dshX.app（还要打 DMG 用）
./update.sh update --tag next --yes   # 跟 next 标签（上游预发布常发在 next）
./update.sh update --version 0.2.0 --yes  # 指定确切版本
```

要点：

- **认版本看 `latest` + `next` + `alpha` 三个标签**，取比当前新的最高者当候选。
  上游把预发布版发在 `next`（如 `0.1.5-rc.2`）而 `latest` 可能还停在 `rc.1`，
  只看 `latest` 会漏。`--tag` 可强制只跟某个标签。
- `update` 需要 `npm`（`check` 不需要）。装了 Node 即带 npm；没有会直接告诉你
  怎么装，不会瞎跑。默认会弹一次 `y/N` 确认。
- 只动 `runtime/` 与 `build/`，不碰 `~/.dsh`。`--install` 才写 `/Applications`，
  且要求 dshX 没在跑（避免覆盖正在运行的后端），否则停下让你先退。装成功后
  它会把 `build/dshX.app` 交给 `install-app.sh` 删掉（那 400M 双份），`--keep-src` 保留。

**「更新」菜单**（菜单栏 `更新 ›`）：顶部显示当前 dsh 版本，下面「检查更新…」
「更新并重建（终端）…」会**打开一个终端窗口跑 `update.sh`**，你能直接看到它
的判断与日志；找不到脚本时退回到「把命令复制到剪贴板」。菜单靠下面任一方式找到
`update.sh`（都不满足就只能手抄命令跑）：

- 环境变量 `DSH_UPDATE_SCRIPT=/绝对路径/update.sh`（最直接）；
- `~/Library/Application Support/dshX/update.sh`（放一份进去）；
- 用**仓库工作目录**启动 App（`DSH_APP_WORKSPACE=/path/to/dsh-app`，它会去
  `<工作目录>/shell/update.sh` 找）；
- 或 `~/Library/Application Support/dshX/update-script.txt` 写一行脚本路径。

> 菜单里的一键只是**入口**：真正的更新在你自己的终端里发生，`npm install` +
> 重建都在那里面完成。本仓库的 `update.sh` 默认不改 `/Applications`、不自动重开
> App——这些留给你手动确认，符合「本机自用、改动可控」的取向。

## 改了壳（main.swift）怎么装回去

`main.swift` 是**编译进 `.app`** 的，改完必须重建 + 替换 `/Applications` 里的旧包
才会生效；正在跑的那份还是旧产物。三步：

```sh
cd dsh-app/shell
bash make-app.sh                 # 1) 离线重建到 build/dshX.app（约 20 秒，用缓存的 Node）
open ../build/dshX.app           # 2) 想先试试：直接跑 build 里这份，独立于已装的、也独立于当前会话
bash install-app.sh --launch     # 3) 想常驻：先退出已装的 dshX，再装、重开，并删掉 build 里那份
```

第 2 步和第 3 步要二选一：`install-app.sh` 默认装完就删 `build/dshX.app`（省那 400M
双份），所以先试再装请用 `--keep-src`，或者直接 `open` 完了再装。

`install-app.sh` 的保护：

- **还有进程在用旧包就直接拒绝**（界面进程，或某个还在引用
  `/Applications/dshX.app` 的后端——比如正承载你当前会话的那个）。**别在还开着
  dshX 窗口 / 会话时强装**，会把正在跑的后端连根拔起。先退出再装。
- 默认把旧包备份到同目录 `dshX.app.bak.<时间戳>`（留最近 3 份），可回退。
- 装后只对**目标**校验签名；不过就只给警告（ad-hoc 包偶尔这样）并且不删源包，
  方便你拿原产物重试。`/Applications` 不可写时给出手动 `ditto` 命令。
- 装成功后默认删掉 `build/dshX.app`（副本之间不互相引用，删源不影响已装那份）。
  但只有源确实位于本仓库 `build/` 下才删 —— `--src` 指到别处时只装不删。
- `--dry-run` 只看会做什么、不动（连删产物也只打印）；`--force` 跳过运行态检查
  （自负风险）；`--keep-src` 保留源包；`--src <path>` / `--dest <path>` 换源与换目标
  （拿 `--dest` 指到临时目录就能不碰真 app 地验证脚本）。

> 让「更新」菜单能一键找到脚本：用**仓库工作目录**启动（
> `DSH_APP_WORKSPACE=/path/to/dsh-app`），或给 App 设 `DSH_UPDATE_SCRIPT=/路径/update.sh`。
> 否则菜单只会「复制命令」让你粘到终端手跑。

日志：`~/Library/Application Support/dshX/backend.log`（后端原始输出 +
`[shell]` 前缀的壳自身判断，启动失败先看它）。

## 验证过的点

- `--port 0` 起服务 → 窗口标题变为 `dshX — 127.0.0.1:<port>`，
  `lsof` 里能看到 WebKit Networking 到后端端口的 ESTABLISHED 连接。
- 图标确认生效：`tools/check-icon.swift` 比的是渲染后的像素。dshX 的 App 图标
  vs 包内 icns 平均差 5.17，vs 通用文档图标 73.84；官方 DSH Desktop（同一份
  icns）也是 5.17 / 73.84；无自定义图标的对照（/etc/hosts）是 0.00。
  残留的 5.17 是 macOS 26 把图标塞进 "icon island" 容器时的边缘/圆角合成。
- 怎么确认「整页不滚」生效：重建装好后，滚到终端输出或长代码块的底部再继续滚，
  页面整体不该位移；右键 › Inspect Element 里跑
  `getComputedStyle(document.body).overflow` 应返回 `hidden`，
  `document.scrollingElement.scrollHeight === document.scrollingElement.clientHeight`
  说明文档层没有剩余滚动量。
- 曾经踩到的两个真问题（都已修，留个记录）:
  1. ATS 把 `http://127.0.0.1` 拦成「需要安全连接」。只有
     `NSAllowsArbitraryLoads` 不够，WKWebView 的网页内容读
     `NSAllowsArbitraryLoadsInWebContent`；例外域的正确键名是
     `NSExceptionAllowsInsecureHTTPLoads`（不是 `NSTemporary...`）。
  2. **一个假 bug，别再照着查**：我两次量到 126x128 / 126x143 的"小窗口"，
     认定是 `setFrameAutosaveName` 干的，去掉了 autosave。实际是我开了
     **台前调度**，`CGWindowListCopyWindowInfo` 量到的是左侧缩略图几何，
     窗口一直是 1280x852。去掉 autosave + 加 `contentMinSize` 本身没问题，
     但它没修过任何东西；用窗口尺寸做验证前先确认台前调度是关的。
- `kill -9` 壳之后，后端与看门狗都会自行退出（这是三条退出路径里唯一
  能自动化验证的一条；⌘Q 路径只有代码保证，Apple Events 被权限拦了）。

## 卸载

```sh
rm -rf "/Applications/dshX.app"
rm -rf "$HOME/Library/Application Support/dshX"       # 私有 DSH_HOME + 日志
rm -rf "$HOME/Library/WebKit/local.dshx.shell"        # WebView 缓存
```

## 已知限制

- ad-hoc 签名、**无公证**：拷给别人后首次打开会被 Gatekeeper 拦下，需要手动放行
  （`xattr -dr com.apple.quarantine` 或「系统设置 › 隐私与安全性 › 仍要打开」）。
- 图标用的是官方鲸鱼标，且观感与官方相近：仅作本机/自用；对外分发或商用前建议换成
  自己的图标（`ICNS=/path/to/your.icns ./make-app.sh`，见 `THIRD_PARTY_NOTICES.md`）。
- 没有单实例锁。正常 `open` 不会重复启动，但 `open -n` 会起第二个实例，
  两个后端会共用同一个私有 `DSH_HOME`。
- 「能不能真跑一轮对话」没验证过：只确认了后端起来了、页面加载了、
  本地模型服务 `127.0.0.1:8000` 可达、且把 `~/.dsh/settings.yaml` 复制进了
  私有 home（里面没有明文凭据，只有 `apiKeyEnv: MTPLX_API_KEY`）。
- 工作目录默认是 `~/Library/Application Support/dshX/workspace`。要拿它
  改真实项目，用 **文件 › 选择工作目录并重启后端**，或者干脆
  `DSH_APP_WORKSPACE=/path/to/project open "/Applications/dshX.app"`。
- 覆盖式安装：每次 `make-app.sh` 会 `rm -rf` 重建，不复用上次的产物。
