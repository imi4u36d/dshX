#!/usr/bin/env bash
#
# hscroll-test/run.sh —— 跑壳「整页横向平移」守卫（Sources/wheel-guard.swift）的回归测试。
#
# 把同一串「精确滚动 + phase」的横向事件分别送进裸 WKWebView 与 ShellWebView：
# 前者文档被横向滚走（问题可复现），后者必须纹丝不动；同时确认纵向精确滚动没被误伤。
# 改 wheel-guard.swift / 换 macOS 或 WebKit 之后跑一遍。
#
#   bash shell/tools/hscroll-test/run.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$ROOT/.tmp" "$ROOT/.modulecache"
BIN="$ROOT/.tmp/hscroll-test"

TMPDIR="$ROOT/.tmp" xcrun swiftc -swift-version 5 -O \
  -target "$(uname -m)-apple-macosx12.0" \
  -module-cache-path "$ROOT/.modulecache" \
  -framework AppKit -framework WebKit \
  "$ROOT/shell/Sources/wheel-guard.swift" \
  "$ROOT/shell/tools/hscroll-test/main.swift" \
  -o "$BIN"

"$BIN"
