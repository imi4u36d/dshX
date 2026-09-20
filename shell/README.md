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
5. ad-hoc 签名并回验

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
