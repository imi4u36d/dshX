#!/usr/bin/env bash
# 编 + 跑 update-check-test（dshX 更新链路的验证工具）。
#
#   ./run.sh              离线用例：版本比较、Releases 解析、选型、后端候选与提升步骤
#   ./run.sh --check      真查一次更新源（默认 GitHub，可用 DSH_UPDATE_FEED_URL 换）
#   ./run.sh --update     真查 + 真下载校验换包（要先配好沙盒目标，见 main.swift 顶部）
#   ./run.sh --runtime-check           真查一次 npm registry：dsh 后端有没有新版
#   ./run.sh --runtime-rehearse [版本] 真装一次后端到临时 runtime 并走完提升（不碰真 app）
#
# 产物与缓存都落在仓库 .tmp/、.modulecache/ 里，跟 make-app.sh 用同一套。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/.tmp/update-check-test"
ARCH="$(uname -m)"

# 提升/回滚演练要真跑一次 `node …/dsh/lib/bin.js --version` 做探活，真装演练还要 pnpm。
# 从 PATH 与已装的 dshX 里认出这两个；认不出也不影响离线用例（演练会自己跳过）。
if [[ -z "${DSHX_NODE:-}" ]] && command -v node >/dev/null 2>&1; then
  export DSHX_NODE="$(command -v node)"
fi
if [[ -z "${DSHX_PNPM:-}" ]]; then
  for candidate in \
    "/Applications/dshX.app/Contents/Resources/tools/pnpm/package/bin/pnpm.cjs" \
    "$HOME/Applications/dshX.app/Contents/Resources/tools/pnpm/package/bin/pnpm.cjs"; do
    if [[ -f "$candidate" ]]; then export DSHX_PNPM="$candidate"; break; fi
  done
fi

mkdir -p "$ROOT/.tmp" "$ROOT/.modulecache"

echo "==> 编译（${ARCH}）"
xcrun swiftc -swift-version 5 -O \
  -target "${ARCH}-apple-macosx12.0" \
  -module-cache-path "$ROOT/.modulecache" \
  -framework AppKit \
  "$ROOT/shell/Sources/updater.swift" \
  "$ROOT/shell/Sources/runtime-updater.swift" \
  "$ROOT/shell/tools/update-check-test/main.swift" \
  -o "$OUT"

echo "==> 运行"
exec "$OUT" "$@"
