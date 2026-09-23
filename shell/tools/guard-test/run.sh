#!/usr/bin/env bash
#
# guard-test/run.sh —— 跑壳注入脚本（整页滚动守卫 + 输入框守卫）的回归测试。
#
# 直接把 .tmp/guard-test 编出来跑一个离屏 WKWebView（与壳同引擎），断言：
# 输入框在非 hero 会话里钉底、正文照常能滚、任何「把输入框一起带走的祖先滚动」被归零并留日志、
# hero 时不钉。改 shell/Sources/main.swift 里的 fixedShellStyle / fixedShellGuardScript 之后
# 跑一遍，避免又出现「CSS 写进单引号字符串里、整段脚本语法错误」这类静默失效。
#
#   bash shell/tools/guard-test/run.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$ROOT/.tmp" "$ROOT/.modulecache"
BIN="$ROOT/.tmp/guard-test"

TMPDIR="$ROOT/.tmp" xcrun swiftc -swift-version 5 -O \
  -target "$(uname -m)-apple-macosx12.0" \
  -module-cache-path "$ROOT/.modulecache" \
  -framework AppKit -framework WebKit \
  "$ROOT/shell/tools/guard-test/main.swift" \
  -o "$BIN"

"$BIN"
