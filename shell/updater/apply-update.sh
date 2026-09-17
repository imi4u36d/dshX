#!/usr/bin/env bash
#
# apply-update.sh —— dshX 的「换包」执行者。
#
# 谁调用它：App 里点「更新并重启」后，壳把 DMG 下好并校验过 SHA-256，然后拉起
# 本脚本（nohup 脱离 App 进程）并立刻退出。脚本等旧进程散场，再挂载 DMG、替换
# .app、重新 open。
#
# 为什么必须放在 App 外面：正在跑的后端就是从被替换的那份包里 mmap 出来的文件，
# 页面没法把正在跑的自己换掉；而且替换途中若把壳杀了，新包会停在半路。
#
# 用法
#   apply-update.sh <dmg 路径> <目标 .app 路径> <日志文件>
#
# 环境变量（都为排查/测试留的口子，默认走正常路径）
#   DSHX_WAIT_PID        要先等它退出的 pid（App 自己的 pid），最多等 30 秒
#   DSHX_UPDATE_DRY_RUN=1 只打印要做什么，不挂载、不替换、不重启
#   DSHX_UPDATE_BACKUPS  保留几份旧包备份（默认 1；0 = 不备份）。每个备份约 400M
#   DSHX_NO_RESTART=1    只换包，不重新 open（排查/测试用）
#
# 约定
#   - 只动目标 .app 与它旁边的备份、DMG、挂载点，别的一律不碰（不碰 ~/.dsh）。
#   - 全程写日志到第三个参数。出错时把 DMG 所在目录在 Finder 里打开，让人能接手。
#   - 备份只在 ditto 失败时回滚回去；换成功后不回滚，避免留下半新半旧的包。
#
set -uo pipefail

DMG="${1:-}"
TARGET="${2:-}"
LOG="${3:-}"

WAIT_PID="${DSHX_WAIT_PID:-}"
DRY="${DSHX_UPDATE_DRY_RUN:-0}"
BACKUPS="${DSHX_UPDATE_BACKUPS:-1}"
NO_RESTART="${DSHX_NO_RESTART:-0}"

say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >> "${LOG:-/dev/null}"; }
fail() { say "失败：$1"; }

if [[ -z "$DMG" || -z "$TARGET" ]]; then
  echo "用法：apply-update.sh <dmg> <目标 .app> [日志]" >&2
  exit 1
fi
TARGET_DIR="$(dirname "$TARGET")"
TARGET_NAME="$(basename "$TARGET")"

say "===== 开始换包 ====="
say "DMG    = $DMG"
say "目标   = $TARGET"

if [[ ! -f "$DMG" ]]; then
  fail "DMG 不存在：$DMG"
  exit 1
fi
if [[ ! -d "$TARGET_DIR" ]]; then
  fail "目标目录不存在：$TARGET_DIR"
  exit 1
fi
if [[ ! -w "$TARGET_DIR" && $EUID -ne 0 ]]; then
  fail "$TARGET_DIR 不可写（可能需要「App 管理」授权，或要用有权限的终端手动装）。"
  [[ $DRY == 1 ]] || open "$(dirname "$DMG")" 2>/dev/null
  exit 3
fi

run() { if [[ "$DRY" == 1 ]]; then say "  [dry-run] $*"; else "$@"; fi; }

# ---------- 1) 等旧进程散场 ----------
# 覆盖正在被 mmap 的包会把跑着的会话连根拔起，也会让新包只拷进去一半。
if [[ -n "$WAIT_PID" ]]; then
  # 变量一律带花括号：紧跟全角括号/逗号时，bash 会把后面那几个字节算进变量名，
  # set -u 下脚本会当场退出（这个坑真踩过：换包脚本一个字没干就死了）。
  say "等 App（pid ${WAIT_PID}）退出"
  for _ in $(seq 1 60); do
    kill -0 "$WAIT_PID" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$WAIT_PID" 2>/dev/null; then
    say "警告：等了 30 秒 App 还在，继续（可能拷坏新包）。"
  fi
fi

# 再等引用旧包的进程（内置 node 后端从包里跑）。ps 的 comm 给的是可执行文件全路径，
# 按前缀匹配就不会把本脚本自己（命令行里带着目标路径）算进去。
stale_exe() {
  ps -Ao pid=,comm= 2>/dev/null | awk -v p="$TARGET/" 'index($2, p) == 1 {print $1}'
}
for _ in $(seq 1 40); do
  leftover="$(stale_exe)"
  [[ -z "$leftover" ]] && break
  sleep 0.5
done
if [[ -n "${leftover:-}" ]]; then
  say "警告：还有进程在引用旧包（pid: $(echo $leftover | tr '\n' ' ')），继续替换。"
fi

# ---------- 2) 挂载 DMG ----------
WORK="$(dirname "$DMG")"
MNT="$WORK/mnt-$$"
cleanup() {
  if [[ -d "$MNT" ]]; then
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1
    rmdir "$MNT" 2>/dev/null
  fi
}
trap cleanup EXIT

if [[ "$DRY" == 1 ]]; then
  say "  [dry-run] hdiutil attach '$DMG' -mountpoint '$MNT'"
  say "  [dry-run] 下面按 DMG 里已有 dshX.app 继续演一遍。"
  SRC_APP="$TARGET"   # dry-run 不真的挂载，后面都跳过
else
  run hdiutil detach "$MNT" -quiet >/dev/null 2>&1
  mkdir -p "$MNT"
  if ! run hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$MNT"; then
    fail "挂载 DMG 失败。"
    open "$WORK" 2>/dev/null
    exit 4
  fi
fi

# ---------- 3) 找包 ----------
APP_NAME=""
if [[ -d "$MNT/dshX.app" ]]; then
  APP_NAME="dshX.app"
else
  for candidate in "$MNT"/*.app; do
    [[ -d "$candidate" ]] && { APP_NAME="$(basename "$candidate")"; break; }
  done
fi
if [[ "$DRY" != 1 ]]; then
  if [[ -z "$APP_NAME" ]]; then
    fail "DMG 里没有 .app，没法自动换。"
    open "$WORK" 2>/dev/null
    exit 5
  fi
  SRC_APP="$MNT/$APP_NAME"
fi
if [[ ! -d "$SRC_APP" ]]; then
  fail "源包不存在：$SRC_APP"
  exit 5
fi

# ---------- 4) 备份 + 替换 ----------
BAK=""
if [[ -d "$TARGET" && "$BACKUPS" != "0" ]]; then
  BAK="$TARGET_DIR/${TARGET_NAME}.bak.$(date +%Y%m%d-%H%M%S)"
  say "备份旧包 → $BAK"
  if ! run mv "$TARGET" "$BAK"; then
    fail "备份（mv）失败，放弃替换。"
    exit 6
  fi
fi

say "写入新包"
if ! run ditto "$SRC_APP" "$TARGET"; then
  fail "ditto 失败"
  # 这里必须无条件回滚：写坏一半的比不装更糟（连旧版都开不了）。被 TCC
  # 「App 管理」拦下时就是这种半截状态。
  if [[ -n "$BAK" && -d "$BAK" && "$DRY" != 1 ]]; then
    say "回滚到备份：$BAK"
    rm -rf "$TARGET"
    mv "$BAK" "$TARGET" || say "回滚也失败了，旧包在 ${BAK}，手动改回来。"
  fi
  exit 7
fi

if [[ "$DRY" != 1 && ! -d "$TARGET" ]]; then
  fail "换完以后目标包不存在，异常。备份在 $BAK"
  exit 7
fi

# ---------- 5) 收尾 ----------
if [[ "$DRY" != 1 ]]; then
  if codesign --verify --verbose=1 "$TARGET" >/dev/null 2>&1; then
    say "签名校验通过"
  else
    say "签名校验没过（ad-hoc 包偶尔如此）。先用着，不行就从备份回退。"
  fi
  hdiutil detach "$MNT" -quiet >/dev/null 2>&1
  # 只留最近的 N 份备份，别把 400M × N 堆在 /Applications。
  if [[ "$BACKUPS" != "0" ]]; then
    ls -1dt "$TARGET_DIR"/${TARGET_NAME}.bak.* 2>/dev/null | tail -n +$((BACKUPS + 1)) | while read -r old; do
      say "清理较旧备份：$old"
      rm -rf "$old"
    done
  fi
  say "删掉已用过的 DMG：$DMG"
  rm -f "$DMG"
fi

# 「完成」这条是 rehearsal 脚本判断跑没跑完的记号，两条出口都要写。
if [[ "$NO_RESTART" == "1" ]]; then
  say "DSHX_NO_RESTART=1：不自动重启。"
  say "===== 完成 ====="
  exit 0
fi

say "重新打开 $TARGET"
if ! run open "$TARGET"; then
  fail "自动重启失败，手动双击 ${TARGET}。"
  exit 8
fi
say "===== 完成 ====="
exit 0