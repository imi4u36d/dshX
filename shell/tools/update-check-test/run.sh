#!/usr/bin/env bash
# 编 + 跑 update-check-test（dshX 更新链路的验证工具）。
#
#   ./run.sh              离线用例：版本比较、Releases 解析、选型
#   ./run.sh --check      真查一次更新源（默认 GitHub，可用 DSH_UPDATE_FEED_URL 换）
#   ./run.sh --update     真查 + 真下载校验换包（要先配好沙盒目标，见 main.swift 顶部）
#
# 产物与缓存都落在仓库 .tmp/、.modulecache/ 里，跟 make-app.sh 用同一套。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/.tmp/update-check-test"
ARCH="$(uname -m)"

mkdir -p "$ROOT/.tmp" "$ROOT/.modulecache"

echo "==> 编译（${ARCH}）"
xcrun swiftc -swift-version 5 -O \
  -target "${ARCH}-apple-macosx12.0" \
  -module-cache-path "$ROOT/.modulecache" \
  -framework AppKit \
  "$ROOT/shell/Sources/updater.swift" \
  "$ROOT/shell/tools/update-check-test/main.swift" \
  -o "$OUT"

echo "==> 运行"
exec "$OUT" "$@"
