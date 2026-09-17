#!/usr/bin/env bash
#
# rehearse-update.sh —— 用一份假包把「下载 → 校验 SHA-256 → 挂载 → 换包」整条链路
# 演一遍。不联网（走本机 127.0.0.1 的假更新源）、不碰 /Applications、不碰真 App。
#
#   ./rehearse-update.sh                演练：Release 带资产 digest
#   ./rehearse-update.sh --sidecar      演练：改用 .sha256 边车提供校验值
#   ./rehearse-update.sh --tampered     把包改坏，预期被拒绝安装
#
# 为什么要这么绕：这条链路平时碰不到（要等 CI 发出下一个 DMG 才有东西可更），
# 真出错时最坏是把自己关在门外，所以先在沙盒目录里跑一遍。
#
# 需要：hdiutil（造/挂 DMG）、python3（假更新源）。造像与挂载要磁盘映像权限，
# 在受限环境里会被拦——那是环境限制，不是脚本的错。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SB="$ROOT/.tmp/rehearse"
PORT="${REHEARSE_PORT:-8731}"
MODE="${1:-}"
LOG="$SB/home/dshX/updater.log"
DMG="$SB/srv/dshX-9.9.9-arm64.dmg"
TARGET="$SB/target/Applications/dshX.app"

fail() { echo "FAIL: $1"; exit 1; }

# 卸载本脚本上次留下的挂载点（挂载目录在 DMG 旁边：srv/mnt-<pid>）。
unmount_all() {
  for mount in "$SB"/srv/mnt-*; do
    [ -d "$mount" ] && hdiutil detach "$mount" -quiet >/dev/null 2>&1
  done
}

echo "==> 准备假包与沙盒目标（${SB}）"
unmount_all
rm -rf "$SB"
mkdir -p "$SB/payload/dshX.app/Contents/MacOS" "$SB/target/Applications/dshX.app/Contents/MacOS" \
         "$SB/srv" "$SB/home/dshX" || fail "造沙盒目录失败"

# 「新版本」：打进 DMG 的那份
printf 'NEW-BINARY\n' > "$SB/payload/dshX.app/Contents/MacOS/dshX"
printf 'NEW-INFO\n'   > "$SB/payload/dshX.app/Contents/Info.plist"
# 「当前已装版本」：待会被换掉的对象，放在沙盒的 Applications 里
printf 'OLD-BINARY\n' > "$TARGET/Contents/MacOS/dshX"
printf 'OLD-INFO\n'   > "$TARGET/Contents/Info.plist"

hdiutil create -volname Rehearse -srcfolder "$SB/payload" -fs HFS+ -format UDZO -ov \
  "$DMG" >/dev/null 2>&1 || fail "造 DMG 失败（多半是缺磁盘映像权限）"
[ -f "$DMG" ] || fail "没有 DMG 产物"

# 先记下「干净包」的哈希，喂给假更新源；--tampered 随后换掉包内容，让真哈希对不上。
SHA="$(cd "$SB/srv" && shasum -a 256 dshX-9.9.9-arm64.dmg | awk '{print $1}')"
(cd "$SB/srv" && printf '%s  dshX-9.9.9-arm64.dmg\n' "$SHA" > dshX-9.9.9-arm64.dmg.sha256)

if [[ "$MODE" == "--tampered" ]]; then
  echo "==> 往包里塞一个多余文件，重打 DMG（预期：校验不通过，不换包）"
  printf 'TAMPERED\n' > "$SB/payload/extra.txt"
  hdiutil create -volname RehearseBad -srcfolder "$SB/payload" -fs HFS+ -format UDZO -ov \
    "$DMG" >/dev/null 2>&1 || fail "重打 DMG 失败"
fi
SIZE="$(stat -f %z "$DMG")"

# 拼假更新源：形状照 api.github.com 的真实返回，校验值按模式给。
if [[ "$MODE" == "--sidecar" ]]; then
  ASSETS="{\"name\":\"dshX-9.9.9-arm64.dmg\",\"browser_download_url\":\"http://127.0.0.1:$PORT/dshX-9.9.9-arm64.dmg\",\"size\":$SIZE},{\"name\":\"dshX-9.9.9-arm64.dmg.sha256\",\"browser_download_url\":\"http://127.0.0.1:$PORT/dshX-9.9.9-arm64.dmg.sha256\",\"size\":87}"
  echo "==> 校验值走 .sha256 边车"
else
  ASSETS="{\"name\":\"dshX-9.9.9-arm64.dmg\",\"browser_download_url\":\"http://127.0.0.1:$PORT/dshX-9.9.9-arm64.dmg\",\"size\":$SIZE,\"digest\":\"sha256:$SHA\"}"
fi
printf '[{"tag_name":"v9.9.9","prerelease":false,"html_url":"http://127.0.0.1:%s/","assets":[%s]}]\n' \
  "$PORT" "$ASSETS" > "$SB/srv/releases.json"
# 假源写坏了的话，工具只会说「认不出 Release」，排查起来绕远路，先当场验一遍。
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SB/srv/releases.json" \
  || fail "假更新源的 JSON 不合法：$SB/srv/releases.json"

echo "==> 起假更新源 127.0.0.1:$PORT"
# 上一次跑剩下的服务器会让端口被占：那时 curl 通的是旧目录的假源，演出来的
# 结果跟这次的包没关系，先把它收掉。
pkill -f "http.server $PORT" >/dev/null 2>&1 && sleep 0.5
(cd "$SB/srv" && python3 -m http.server "$PORT" >/dev/null 2>&1) &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; unmount_all' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/releases.json" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$PORT/releases.json" >/dev/null 2>&1 || fail "假更新源没起来"
cmp -s <(curl -fsS "http://127.0.0.1:$PORT/releases.json") "$SB/srv/releases.json" \
  || fail "端口 $PORT 上的假更新源不是这次准备的那份（有残留服务器？）"

echo "==> 跑工具（编译 + 查 + 下载 + 校验 + 换包）"
DSHX_TEST_HOME="$SB/home" \
DSH_UPDATE_FEED_URL="http://127.0.0.1:$PORT/releases.json" \
DSH_UPDATE_FAKE_VERSION=0.1.2 \
DSH_UPDATE_TARGET="$TARGET" \
DSH_UPDATE_NO_RESTART=1 \
DSH_APP_WORKSPACE="$ROOT" \
  bash "$ROOT/shell/tools/update-check-test/run.sh" --update > "$SB/run.log" 2>&1
cat "$SB/run.log"

# 换包脚本脱离工具在跑，等它把包换完（最多 60 秒）。
for _ in $(seq 1 120); do
  grep -q "===== 完成 =====\|失败" "$LOG" 2>/dev/null && break
  sleep 0.5
done

echo
echo "==> 检查结果"
if [[ "$MODE" == "--tampered" ]]; then
  grep -q "SHA-256 对不上" "$SB/run.log" \
    || fail "被改坏的包没被拦住（应报 SHA-256 对不上）"
  [ "$(cat "$TARGET/Contents/MacOS/dshX")" = "OLD-BINARY" ] \
    || fail "被改坏的包居然装上去了"
  echo "  ok   校验不通过时没有换包，旧包保持原样"
else
  [ "$(cat "$TARGET/Contents/MacOS/dshX")" = "NEW-BINARY" ] \
    || fail "没换成新包，里面还是 $(cat "$TARGET/Contents/MacOS/dshX")"
  echo "  ok   换成了新包"
  ls -d "$SB/target/Applications"/dshX.app.bak.* >/dev/null 2>&1 \
    || fail "没留旧包备份，出事时没法回退"
  echo "  ok   留了旧包备份：$(ls -d "$SB/target/Applications"/dshX.app.bak.*)"
  [ ! -f "$SB/home/dshX/updates/dshX-9.9.9-arm64.dmg" ] \
    || fail "换完没删下载下来的 DMG，下次还得重下一遍"
  echo "  ok   用过的 DMG 已删除"
  grep -q "===== 完成 =====" "$LOG" || fail "换包脚本没跑到最后（见 ${LOG}）"
  echo "  ok   updater.log 走到了「完成」"
fi

echo
echo "演练通过。产物留在 ${SB}（rm -rf 即可清掉）。"
