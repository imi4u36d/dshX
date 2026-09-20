#!/usr/bin/env bash
# 组装 "dshX.app"：编译原生壳 → 装入 dsh runtime 与 Node → 写 Info.plist（含图标）→ ad-hoc 签名。
#
#   ./make-app.sh            只组装到 build/dshX.app（产物留着，供 make-dmg.sh / 先试装）
#   INSTALL=1 ./make-app.sh  组装完交给 install-app.sh：运行态保护 + 备份 + 装后
#                            校验签名，都过了才删掉 build 里的产物（省那 400M 双份）
#
# 可覆盖的环境变量：
#   VERSION     写进 Info.plist 的 CFBundleShortVersionString/CFBundleVersion（默认 0.2.3）
#   NODE_ARCH   内置 Node 的架构（默认取本机 uname -m，即与壳同架构）
#   NODE_VERSION / ICNS / RUNTIME  见下面各默认值
#   DEPLOY_TARGET 编译目标的最低 macOS（默认 12.0；别拿掉，否则 -10825）
#   INSTALL=1   组装完顺带安装（走 install-app.sh，没它只组装）
#   KEEP=1      安装后保留 build 产物（配合 INSTALL=1；还要打 DMG 时用）
#   FORCE=1     跳过「dshX 还在跑」拦截（自负风险）
#
# 前置一：runtime/ 里已 npm install 好 @deepseek-ai/dsh（见 README.md）。
# 前置二：iconsrc/official.icns 存在；它取自官方 DSH Desktop.app 的
#         Contents/Resources/icon.icns（官方鲸鱼标，11 个尺寸齐全）。
#         注意产物是 ad-hoc 签名、没有 Developer ID 与公证：别人拿到 DMG 后
#         首次打开要手动放行 Gatekeeper；也不要以「官方出品」的名义宣传
#         （见 README 的「非官方声明」与上游 BRAND_GUIDELINES.md）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="$ROOT/shell"
BUILD="$ROOT/build"
APP="$BUILD/dshX.app"
APP_NAME="dshX"
BUNDLE_ID="local.dshx.shell"
ICNS="${ICNS:-$ROOT/iconsrc/official.icns}"
VERSION="${VERSION:-0.2.3}"
NODE_VERSION="${NODE_VERSION:-24.17.0}"
# 内置的 Node 必须和壳同架构：Intel 上装 arm64 的 node 会直接跑不起来。
NODE_ARCH="${NODE_ARCH:-$(uname -m)}"
# 编译必须钉住 deployment target：不给 -target 时 swiftc 会拿 SDK 自己的版本号当
# minos（实测写成 28.0），LaunchServices 会按「要求比当前系统更新」直接拒启动，
# 报 -10825（Info.plist 里的 LSMinimumSystemVersion 拦不住它，以 Mach-O 为准）。
DEPLOY_TARGET="${DEPLOY_TARGET:-12.0}"
NODE_DIR="node-v${NODE_VERSION}-darwin-${NODE_ARCH}"
NODE_TARBALL="${NODE_DIR}.tar.gz"
CACHE="$ROOT/.downloads"
# 下载缓存必须在任何 curl 之前就已存在：pnpm 那一步排在 Node 前面，而 mkdir 原先
# 只写在 Node 那一步里。本机 .downloads/ 早就存在，这个坑只有干净机器（CI、新克隆）
# 才会踩到——报的是 curl 56「写不出文件」，看着像网络问题，其实是没目录。
mkdir -p "$CACHE"
RUNTIME="${RUNTIME:-$ROOT/runtime}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

say "清理 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/node/bin"

say "编译原生壳（Swift + AppKit + WebKit，target ${NODE_ARCH}-apple-macosx${DEPLOY_TARGET}）"
mkdir -p "$ROOT/.tmp" "$ROOT/.modulecache"
TMPDIR="$ROOT/.tmp" xcrun swiftc -swift-version 5 -O \
  -target "${NODE_ARCH}-apple-macosx${DEPLOY_TARGET}" \
  -module-cache-path "$ROOT/.modulecache" \
  -framework AppKit -framework WebKit \
  "$SHELL_DIR/Sources/main.swift" "$SHELL_DIR/Sources/updater.swift" \
  "$SHELL_DIR/Sources/runtime-updater.swift" \
  -o "$APP/Contents/MacOS/$APP_NAME"

# 编译成功不代表能启动：minos 一旦高于用户系统，双击只会得 -10825。
MINOS="$(otool -l "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | awk '/minos/{print $2; exit}')"
HOST_OS="$(sw_vers -productVersion | cut -d. -f1)"
if [[ -n "$MINOS" ]]; then
  MAJ="${MINOS%%.*}"
  if [[ "$MAJ" -gt "$HOST_OS" ]]; then
    echo "二进制要求 macOS ${MINOS}，本机只有 ${HOST_OS} —— 这样编出来的包启动不了。" >&2
    echo "  检查 DEPLOY_TARGET（当前 ${DEPLOY_TARGET}）。" >&2
    exit 1
  fi
  echo "minos ${MINOS} ≤ 本机 ${HOST_OS}，可启动"
fi

if [[ ! -d "$RUNTIME/node_modules/@deepseek-ai/dsh" ]]; then
  echo "缺少 $RUNTIME/node_modules/@deepseek-ai/dsh，先执行：" >&2
  echo "  cd $RUNTIME && npm install @deepseek-ai/dsh" >&2
  exit 1
fi

say "拷入 dsh 运行时（ditto 保留权限与签名）"
ditto "$RUNTIME/node_modules" "$APP/Contents/Resources/runtime/node_modules"
cp "$RUNTIME/package.json" "$APP/Contents/Resources/runtime/package.json"

# 插件安装链路 = dsh CLI 的 plugin 子命令 + pnpm（CLI 在 profile 目录里 execvp
# 找名为 pnpm 的可执行）。这里把 pnpm 打进 .app：子进程 PATH 会前置
# Contents/Resources/tools/bin，那里放一个名为 pnpm 的包装脚本。
# 默认钉 10.20.0：tgz 自带纯 JS CLI（pnpm.cjs），随内置 Node 直接跑，
# 不像 12.x 那样首跑还要再联网下载原生二进制。
PNPM_VERSION="${PNPM_VERSION:-10.20.0}"
PNPM_SHA256="${PNPM_SHA256:-47a3352808501b8d1ef20112273b6a5dcfa53d28a55bcce36d268e878bd6bfe9}"
PNPM_TGZ="pnpm-${PNPM_VERSION}.tgz"

say "准备内置 pnpm v${PNPM_VERSION}（插件安装转发目标）"
PNPM_DIR="$APP/Contents/Resources/tools/pnpm"
mkdir -p "$PNPM_DIR" "$APP/Contents/Resources/tools/bin"
if [[ ! -f "$CACHE/$PNPM_TGZ" ]]; then
  curl -fsSL -o "$CACHE/$PNPM_TGZ.part" "https://registry.npmjs.org/pnpm/-/$PNPM_TGZ"
  mv "$CACHE/$PNPM_TGZ.part" "$CACHE/$PNPM_TGZ"
fi
PNPM_ACTUAL="$(shasum -a 256 "$CACHE/$PNPM_TGZ" | awk '{print $1}')"
if [[ "$PNPM_ACTUAL" != "$PNPM_SHA256" ]]; then
  echo "pnpm 归档校验失败（期望 ${PNPM_SHA256}，实际 ${PNPM_ACTUAL}）" >&2
  echo "  版本真要升级时，同步改 PNPM_VERSION 与 PNPM_SHA256（或用同名环境变量覆盖）。" >&2
  exit 1
fi
tar xzf "$CACHE/$PNPM_TGZ" -C "$PNPM_DIR"
cat > "$APP/Contents/Resources/tools/bin/pnpm" <<'SH'
#!/bin/sh
# dshX：dsh 安装插件时 execvp('pnpm') 按 PATH 找的就是这个文件名。
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec node "$DIR/../pnpm/package/bin/pnpm.cjs" "$@"
SH
chmod +x "$APP/Contents/Resources/tools/bin/pnpm"

say "拷入换包脚本（「检查更新」用）"
# 「换包」这一步没法在 App 里做（后端正跑在被替换的那份包里），由 App 退出后
# 拉起的这个脚本接手。打进 .app；源码方式跑壳时也会从工作目录找同一份，
# 顺序见 Sources/updater.swift 里的 findApplyScript。
mkdir -p "$APP/Contents/Resources/updater"
cp "$SHELL_DIR/updater/apply-update.sh" "$APP/Contents/Resources/updater/apply-update.sh"
chmod +x "$APP/Contents/Resources/updater/apply-update.sh"

say "准备内置 Node v${NODE_VERSION}（${NODE_ARCH} 官方 tarball，校验 SHA-256）"
if [[ ! -f "$CACHE/$NODE_TARBALL" ]]; then
  curl -fsSL -o "$CACHE/$NODE_TARBALL.part" "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
  curl -fsSL -o "$CACHE/SHASUMS256.txt" "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
  mv "$CACHE/$NODE_TARBALL.part" "$CACHE/$NODE_TARBALL"
fi
EXPECTED="$(grep " ${NODE_TARBALL}\$" "$CACHE/SHASUMS256.txt" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$CACHE/$NODE_TARBALL" | awk '{print $1}')"
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Node 归档校验失败（期望 ${EXPECTED}，实际 ${ACTUAL}）" >&2
  exit 1
fi
echo "SHA-256 校验通过：$ACTUAL"
tar -xzf "$CACHE/$NODE_TARBALL" -C "$CACHE" "$NODE_DIR/bin/node"
install -m 755 "$CACHE/$NODE_DIR/bin/node" "$APP/Contents/Resources/node/bin/node"
"$APP/Contents/Resources/node/bin/node" --version

say "拷贝应用图标"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$APP/Contents/Resources/icon.icns"
  echo "图标来源：$ICNS"
else
  # 没有图标也要能装出来；只是 Dock 里会是通用图标。
  echo "警告：找不到 ${ICNS}，跳过图标。" >&2
fi

say "写 Info.plist（版本 ${VERSION}）"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>icon.icns</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>本地自建的 DeepSeek Harness 壳（非官方，与 DeepSeek 无隶属关系）；ad-hoc 签名、未经 Apple 公证。dsh 后端遵循上游 MIT 许可。</string>
  <!-- 后端只在 127.0.0.1 上以 http/ws 提供，必须放行非加密的回环流量。
       WKWebView 的网页内容读的是 NSAllowsArbitraryLoadsInWebContent，
       只有 NSAllowsArbitraryLoads 在 macOS 26 上会被拦成「需要安全连接」；
       例外域的正确键名是 NSExceptionAllowsInsecureHTTPLoads。 -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>127.0.0.1</key>
      <dict>
        <key>NSIncludesSubdomains</key>
        <false/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key>
        <true/>
      </dict>
      <key>localhost</key>
      <dict>
        <key>NSIncludesSubdomains</key>
        <false/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key>
        <true/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

say "ad-hoc 签名"
# Node 官方二进制保留它自己的 Developer ID 签名与 entitlements（含
# disable-library-validation）；重签会把 entitlements 抹掉，反而可能让原生
# 插件加载失败。所以这里只签我们自己的东西。
find "$APP" -type f -name '*.node' -print0 \
  | xargs -0 -n1 codesign --force --sign - --timestamp=none 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" && echo "app 包签名校验通过"
codesign --verify --verbose=1 "$APP/Contents/Resources/node/bin/node" && echo "内置 node 签名完好"

say "产物"
du -sh "$APP"
echo "$APP"

if [[ "${INSTALL:-0}" == "1" ]]; then
  say "安装到 /Applications（交给 install-app.sh）"
  INSTALLER="$SHELL_DIR/install-app.sh"
  if [[ ! -f "$INSTALLER" ]]; then
    echo "缺少 ${INSTALLER}，不能自动安装。手动装前先退出 dshX："
    echo "  bash $SCRIPT_DIR/install-app.sh   或  ditto \"$APP\" /Applications/"
    exit 9
  fi
  # 不在这里自己 rm + ditto：运行态拦截、旧包备份、装后校验签名都在
  # install-app.sh 里，两处各写一份只会慢慢走形。产物删不删也由它判定。
  iargs=(--src "$APP")
  if [[ "${KEEP:-0}" == "1" ]]; then iargs+=(--keep-src); fi
  if [[ "${FORCE:-0}" == "1" ]]; then iargs+=(--force); fi
  if ! bash "$INSTALLER" "${iargs[@]}"; then
    echo "没装上。产物保留在 ${APP}，按上面的原因处理完重试即可。"
    exit 9
  fi
fi
