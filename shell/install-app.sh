#!/usr/bin/env bash
#
# install-app.sh —— 把 build/dshX.app 装到 /Applications（本地自用）。
#
# 用途：改完 shell/Sources/main.swift 后，先 make-app.sh 重建出 build/dshX.app，
# 再用本脚本装到 /Applications 替换旧的。改的是「壳」（比如「更新」菜单），
# 不是后端版本；升后端请改用 update.sh。
#
# 用法
#   ./install-app.sh                 # 装 build/dshX.app 到 /Applications
#   ./install-app.sh --dry-run       # 只打印要做什么，不动
#   ./install-app.sh --launch        # 装完顺手 open 新 app
#   ./install-app.sh --src <path>    # 换源（默认 build/dshX.app）
#   ./install-app.sh --no-backup     # 不备份旧 app（默认会备份，可回退）
#
# 保护
#   - dshX 正在运行时**直接拒绝**：正在跑的后端从旧包里 mmap 了文件，覆盖它会
#     把当前实例连根拔起（若你的会话正跑在这个 app 里，还会把会话一起带掉）。
#     请先在 Dock 里完全退出 dshX，再来装。--force 可跳过（自负风险）。
#   - 默认把旧 /Applications/dshX.app 备份到同目录 dshX.app.bak.<时间戳>，可回退。
#   - 只做替换 + 校验签名，不 ad-hoc 重签（make-app.sh 那步已签好）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="dshX"
SRC="${DSH_INSTALL_SRC:-$ROOT/build/$APP_NAME.app}"
DEST="/Applications/$APP_NAME.app"
DRY=0; DO_LAUNCH=0; DO_BACKUP=1; FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --launch)  DO_LAUNCH=1 ;;
    --no-backup) DO_BACKUP=0 ;;
    --force)   FORCE=1 ;;
    --src)     shift; SRC="${1:-}" ;;
    --src=*)   SRC="${1#*=}" ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '\033[1;33m忽略未知参数：%s\033[0m\n' "$1" >&2 ;;
  esac
  shift
done

err(){ printf '\033[1;31m%s\033[0m\n' "$1" >&2; }
ok(){ printf '\033[1;32m%s\033[0m\n' "$1"; }

echo "==> 安装 $APP_NAME"
echo "  源：$SRC"
echo "  到：$DEST"

if [[ ! -d "$SRC" ]]; then
  err "没有源包：$SRC"
  echo "  先重建： (cd $SCRIPT_DIR && bash make-app.sh)"
  exit 1
fi
if [[ ! -x "$SRC/Contents/MacOS/$APP_NAME" ]]; then
  err "源包里没有可执行的 $APP_NAME，八成是没重建或路径不对。"
  exit 1
fi

# 「还在用旧包」的两种情况都要拦下：
#   1) dshX 界面进程在跑；
#   2) 有别的进程（比如正承载你当前会话的 node 后端）命令行里引用了
#      /Applications/dshX.app——它 mmap 着旧包里的文件，覆盖会把连根拔起。
running=0
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then running=1; fi
if pgrep -f "$APP_NAME.app/Contents" >/dev/null 2>&1; then running=1; fi
if [[ $running -eq 1 && $FORCE -ne 1 ]]; then
  err "检测到还有进程在用旧的 $APP_NAME.app（界面进程，或引用了 $DEST 的后端）。"
  echo "  继续会把这些进程（可能还有你当前的会话）从旧包里连根拔起。"
  echo "  请先退出 dshX（Dock 右键 › 退出，或 ⌘Q），确认没有进程再引用它，再来装。"
  echo "  确认知道自己在做什么、要强行装：加 --force。"
  exit 2
fi

if [[ ! -w "/Applications" && $EUID -ne 0 ]]; then
  err "/Applications 不可写，需要管理员权限。"
  echo "  要么用有权限的终端跑本脚本，要么手动："
  echo "    ditto \"$SRC\" \"$DEST\""
  exit 3
fi

run(){ if [[ $DRY -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }

# 备份旧包
if [[ -d "$DEST" && $DO_BACKUP -eq 1 ]]; then
  bak="/Applications/${APP_NAME}.app.bak.$(date +%Y%m%d-%H%M%S)"
  echo "==> 备份旧包到 $bak"
  run cp -R "$DEST" "$bak"
  # 只保留最近 3 份备份，免得堆一堆 400M
  if [[ $DRY -eq 0 ]]; then
    ls -1dt /Applications/${APP_NAME}.app.bak.* 2>/dev/null | tail -n +4 | while read -r old; do
      echo "  清理较旧备份：$old"; rm -rf "$old"
    done
  fi
elif [[ -d "$DEST" ]]; then
  echo "==> --no-backup：将直接覆盖 $DEST"
fi

echo "==> 拷贝新包到 $DEST"
run rm -rf "$DEST"
run ditto "$SRC" "$DEST"

if [[ $DRY -eq 1 ]]; then echo "  [dry-run] 未实际改动。"; exit 0; fi

if [[ -d "$DEST" ]]; then
  if codesign --verify --verbose=1 "$DEST" >/dev/null 2>&1; then
    ok "已安装，签名校验通过：$DEST"
  else
    printf '\033[1;33m已安装，但签名校验没过（ad-hoc 包偶尔会这样）；本机若能用可忽略。\033[0m\n'
  fi
else
  err "安装后目标不存在，异常。"
  exit 4
fi

if [[ $DO_LAUNCH -eq 1 ]]; then
  echo "==> 打开新 app"
  open "$DEST" || err "open 失败，手动双击 $DEST。"
else
  echo "在 Dock/启动台重开 $APP_NAME 即生效；或： open \"$DEST\""
fi