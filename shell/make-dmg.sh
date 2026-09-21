#!/usr/bin/env bash
# 把组装好的 .app 打成 DMG：挂载后把 dshX 拖进 Applications 就算装完。
#
#   ./make-dmg.sh                     # build/dshX.app → build/dshX-<版本>-<架构>.dmg
#   APP=/path/别的.app ./make-dmg.sh  # 换源
#   VERSION=0.2.5 ./make-dmg.sh       # 覆盖文件名与卷标里的版本号
#   OUT_DIR=dist ./make-dmg.sh        # 换输出目录
#
# 产物旁边会留一个 .dmg.sha256；CI 把两者一起传上去。
# 说明：DMG 本身不做签名/公证（壳用 Apple Development 证书签；CI 的机器上没有
# 这张证书，会回退 ad-hoc），所以对方首次打开要手动放行 Gatekeeper，README 里有步骤。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/build/dshX.app}"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP_NAME="$(basename "$APP" .app)"
ARCH="${NODE_ARCH:-$(uname -m)}"
PLIST="$APP/Contents/Info.plist"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP —— 先跑 ./make-app.sh 组装 .app。" >&2
  exit 1
fi

# 版本号优先用显式 VERSION，否则读 make-app.sh 写进 Info.plist 的那个。
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
  VERSION="${VERSION:-0.0.0}"
fi
DMG="$OUT_DIR/${APP_NAME}-${VERSION}-${ARCH}.dmg"

say "校验 .app（版本 ${VERSION}，架构 ${ARCH}）"
plutil -lint "$PLIST" >/dev/null
codesign --verify --verbose=1 "$APP"
if [[ -f "$APP/Contents/Resources/node/bin/node" ]]; then
  codesign --verify --verbose=1 "$APP/Contents/Resources/node/bin/node"
fi

say "搭 DMG 暂存目录"
mkdir -p "$ROOT/.tmp" "$OUT_DIR"
STAGE="$(mktemp -d "$ROOT/.tmp/dmg.XXXXXX")"
MOUNT_POINT=""
cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# 包里有 MIT 的 dsh 与 Node，许可原文跟着 DMG 一起发出去。
for f in LICENSE THIRD_PARTY_NOTICES.md; do
  if [[ -f "$ROOT/$f" ]]; then
    cp "$ROOT/$f" "$STAGE/$f"
  fi
done
if [[ -d "$ROOT/licenses" ]]; then
  ditto "$ROOT/licenses" "$STAGE/licenses"
fi

say "生成 $DMG"
rm -f "$DMG"
# HFS+ 而不是 APFS：老系统的 DiskImages 也能挂。UDZO = zlib 压缩的只读镜像。
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

say "回挂校验"
MOUNT_POINT="$(mktemp -d "$ROOT/.tmp/mnt.XXXXXX")"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" >/dev/null
test -d "$MOUNT_POINT/$APP_NAME.app" || { echo "DMG 里没有 $APP_NAME.app" >&2; exit 1; }
codesign --verify --verbose=1 "$MOUNT_POINT/$APP_NAME.app"
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true
MOUNT_POINT=""

say "产物"
du -sh "$DMG"
# 校验文件里只写文件名：对方下载到同一个目录后 `shasum -a 256 -c` 就能直接验。
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )
echo
echo "$DMG"
echo
# 提示语按实际签名来源来，而不是写死 ad-hoc：本机默认用 Apple Development 证书签，
# CI 机器上没有这张证书才会回退 ad-hoc（回退逻辑见 make-app.sh）。
# 注意 codesign 要 `-dvv` 才打印 Authority，`-dv` 只有 TeamIdentifier。
SIGN_AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -n "$SIGN_AUTHORITY" ]]; then
  SIGN_KIND="证书签名：${SIGN_AUTHORITY}"
else
  SIGN_KIND="ad-hoc 签名"
fi
echo "对方首次打开要放行 Gatekeeper（${SIGN_KIND}、未经 Apple 公证）："
echo "  xattr -dr com.apple.quarantine \"/Applications/${APP_NAME}.app\""
