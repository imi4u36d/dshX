#!/usr/bin/env bash
#
# update.sh —— 更新本项目依赖的上游 dsh（@deepseek-ai/dsh）
#
# 本地自用脚本：把仓库 runtime/ 里装的 @deepseek-ai/dsh 升到更新的版本，然后
# 重跑 make-app.sh 重建 dshX.app。非官方、ad-hoc 签名，不可分发。
#
# 为什么需要脚本、而不是在 App 里点一下就换后端：
#   dshX.app 运行中的后端，正是 runtime/ 里那份 @deepseek-ai/dsh。页面没法把
#   正在跑的自己替换掉，所以真正的更新必须在 App 外部做——换 runtime/、重建
#   .app，再重开。本脚本就是这条「外部执行者」。原生壳里的「更新」菜单只是在
#   能发现本脚本时，替你打开终端跑它（见 main.swift）。
#
# 用法
#   ./update.sh                      # = check：只看有没有新版，不改动任何东西
#   ./update.sh check                # 同上（只读，一次网络请求）
#   ./update.sh update               # 执行更新（需要 npm；默认装「比当前新的最高版本」）
#   ./update.sh check --json         # 机器可读输出（给壳/CI 用）
#   ./update.sh update --dry-run     # 只打印将要执行的命令，不真的装
#   ./update.sh update --tag next    # 跟踪某个 dist-tag（latest|next|alpha 等）
#   ./update.sh update --version 0.2.0   # 指定确切版本，跳过自动判断
#   ./update.sh update --install     # 重建后再装到 /Applications（会先要求退出 App）
#   ./update.sh update --install --keep-src   # 装完保留 build/dshX.app（还要拿它打 DMG 时用）
#   ./update.sh update --yes         # 更新前不再交互确认（自动化用）
#   ./update.sh --runtime <dir> ...  # 覆盖 runtime 目录（默认为本脚本上一级的 runtime/）
#
# 约定与安全
#   - 只动 runtime/ 与 build/；绝不碰 ~/.dsh，也不碰你正在跑的 App，除非 --install。
#     --install 装成功后默认删掉 build/dshX.app（那 400M 双份），--keep-src 保留。
#   - check 全程只读；没有 npm 也能跑。
#   - 上游常用 next 标签发预发布版（latest 可能落后），所以默认把所有 dist-tag
#     里比当前新的最高版本当候选；若各标签都不更新，再回退去 versions 里找更新的。
#
set -euo pipefail

# ---------- 配置 ----------
PKG="@deepseek-ai/dsh"
PKG_ENC="%40deepseek-ai%2Fdsh"                 # URL 里 @ 与 / 的转义
REGISTRY="${DSH_REGISTRY:-https://registry.npmjs.org/${PKG_ENC}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME="${RUNTIME:-$ROOT/runtime}"
MAKE_APP="$SCRIPT_DIR/make-app.sh"
APP_NAME="dshX"
INSTALL_TARGET="/Applications/${APP_NAME}.app"

# ---------- 小工具 ----------
c_err()  { printf '\033[1;31m%s\033[0m\n' "$1" >&2; }
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$1"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }
say()    { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# 判断 A 相对 B 的新旧（语义化版本，含预发布）。打印 newer|same|older。
version_cmp() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=index(a,"-"); if(n==0){acore=a; arest=""} else {acore=substr(a,1,n-1); arest=substr(a,n+1)}
    m=index(b,"-"); if(m==0){bcore=b; brest=""} else {bcore=substr(b,1,m-1); brest=substr(b,m+1)}
    split(acore,ap,"."); split(bcore,bp,".")
    for(i=1;i<=3;i++){ x=ap[i]+0; y=bp[i]+0
      if(x>y){print "newer";exit} if(x<y){print "older";exit} }
    if(arest=="" && brest==""){print "same";exit}
    if(arest==""){print "newer";exit}
    if(brest==""){print "older";exit}
    na=split(arest,aq,"."); nb=split(brest,bq,"."); L=(na>nb)?nb:na
    for(i=1;i<=L;i++){ av=aq[i]; bv=bq[i]
      an=(av ~ /^[0-9]+$/); bn=(bv ~ /^[0-9]+$/)
      if(an&&bn){ if(av+0>bv+0){print "newer";exit} if(av+0<bv+0){print "older";exit} }
      else if(an&&!bn){print "older";exit}
      else if(!an&&bn){print "newer";exit}
      else { if(av>bv){print "newer";exit} if(av<bv){print "older";exit} } }
    if(na>nb){print "newer";exit} if(na<nb){print "older";exit}
    print "same"
  }'
}

# 取 registry JSON 里 dist-tags 的某个键值（不依赖 jq）。
dist_tag_value() { # $1=json $2=tag
  printf '%s' "$1" | tr ',' '\n' \
    | grep -oE "\"$2\":\"[^\"]+\"" | head -1 \
    | sed -E 's/.*:"([^"]+)"/\1/'
}

# 取整个 versions 段里、作为对象键出现的真实发布版本（排掉 24.20.0 这种噪音）。
all_version_keys() { # $1=json
  printf '%s' "$1" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+([.-][^"]*)?":\{' \
    | sed -E 's/[":{]//g' | sort -u
}

# 找到可用的 npm。优先 PATH，其次常见安装位置与 nvm/volta。
find_npm() {
  if command -v npm >/dev/null 2>&1; then command -v npm; return 0; fi
  local cand
  for cand in \
    "${DSH_APP_NPM:-}" \
    /opt/homebrew/bin/npm /usr/local/bin/npm /usr/bin/npm \
    "$HOME/.volta/bin/npm" \
    "$HOME/.nvm/versions/node"/*/bin/npm; do
    [[ -n "$cand" && -x "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

# 发一次 HTTPS GET，取 registry 内容；curl 优先，没有就用内嵌 node。
fetch_registry() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m "${DSH_HTTP_TIMEOUT:-25}" "$REGISTRY" 2>/dev/null && return 0
  fi
  if command -v node >/dev/null 2>&1; then
    node -e '
      const https=require("https");
      https.get(process.argv[1],{timeout:25000},r=>{let d="";r.on("data",c=>d+=c);
        r.on("end",()=>process.stdout.write(r.statusCode>=200&&r.statusCode<300?d:""));})
        .on("error",()=>process.exit(3));
    ' "$REGISTRY" 2>/dev/null && return 0
  fi
  return 1
}

# 当前版本要到参数解析完（可能带 --runtime 覆盖）后才在 main 里读，这里先留空。
current=""
RESOLVED_TARGET=""

# 在候选集合里挑出比 $1 新的最高版本，打印它（没有则空）。
pick_newest_newer() {
  local cur="$1"; shift
  local best="" v
  for v in "$@"; do
    [[ -z "$v" ]] && continue
    [[ "$v" == "$cur" ]] && continue
    if [[ "$(version_cmp "$v" "$cur")" == "newer" ]]; then
      if [[ -z "$best" || "$(version_cmp "$v" "$best")" == "newer" ]]; then best="$v"; fi
    fi
  done
  printf '%s' "$best"
}


# ---------- 解析参数 ----------
MODE="check"
DRY_RUN=0
ASSUME_YES=0
DO_INSTALL=0
KEEP_SRC=0
FORCE=0
JSON=0
PIN_TAG=""
PIN_VERSION=""
seen_mode=0
while [[ $# -gt 0 ]]; do
  arg="$1"; shift
  case "$arg" in
    check|update) MODE="$arg"; seen_mode=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --install)  DO_INSTALL=1 ;;
    --keep-src) KEEP_SRC=1 ;;
    --force)    FORCE=1 ;;
    --json)     JSON=1 ;;
    --tag)       PIN_TAG="${1:-}"; shift || true ;;
    --version)   PIN_VERSION="${1:-}"; shift || true ;;
    --runtime)   RUNTIME="${1:-}"; shift || true ;;
    --tag=*)     PIN_TAG="${arg#*=}" ;;
    --version=*) PIN_VERSION="${arg#*=}" ;;
    --runtime=*) RUNTIME="${arg#*=}" ;;
    -h|--help)   sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) c_warn "忽略未知参数：$arg" ;;
  esac
done

# ---------- 报告 / 解析目标版本 ----------
report_and_resolve() {
  local json="$1"
  local latest next alpha
  latest="$(dist_tag_value "$json" latest)"
  next="$(dist_tag_value "$json" next)"
  alpha="$(dist_tag_value "$json" alpha)"

  if [[ -z "$current" ]]; then
    say "上游 $PKG 版本"
    c_warn "  runtime/ 里没找到 @deepseek-ai/dsh。先在 runtime/ 执行： npm install $PKG"
    return 3
  fi

  # 候选：先各 dist-tag；都不比当前新时，回退到 versions 里找更新的。
  local target="" src="dist-tag"
  target="$(pick_newest_newer "$current" "$latest" "$next" "$alpha")"
  if [[ -z "$target" ]]; then
    local -a vkeys=()
    while IFS= read -r line; do [[ -n "$line" ]] && vkeys+=("$line"); done \
      < <(all_version_keys "$json")
    target="$(pick_newest_newer "$current" "${vkeys[@]:-}")"
    src="versions"
  fi

  local src_note="$src"
  if [[ -n "$PIN_VERSION" ]]; then
    target="$PIN_VERSION"; src_note="指定版本"
  elif [[ -n "$PIN_TAG" ]]; then
    local tv; tv="$(dist_tag_value "$json" "$PIN_TAG")"
    if [[ -z "$tv" ]]; then c_err "registry 里没有 dist-tag: $PIN_TAG"; return 2; fi
    target="$tv"; src_note="标签 $PIN_TAG"
  fi
  RESOLVED_TARGET="$target"

  if [[ $JSON -eq 1 ]]; then
    printf '{"package":"%s","current":"%s","latest":"%s","next":"%s","alpha":"%s","target":"%s","updateAvailable":%s}\n' \
      "$PKG" "$current" "${latest:-}" "${next:-}" "${alpha:-}" "${target:-}" \
      "$([[ -n "$target" ]] && echo true || echo false)"
    return 0
  fi

  say "上游 $PKG 版本"
  printf '  当前(runtime)： %s\n' "$current"
  printf '  标签 latest：   %s\n' "${latest:-（无）}"
  printf '  标签 next：     %s\n' "${next:-（无）}"
  printf '  标签 alpha：    %s\n' "${alpha:-（无）}"

  if [[ -z "$target" ]]; then
    c_ok "  已是最新，没有比 $current 更新的版本。"
    RESOLVED_TARGET=""
    return 0
  fi
  c_warn "  发现可更新： $current → $target   [$src_note]"
  return 0
}

# ---------- 主流程 ----------
main() {
  if [[ $JSON -eq 0 ]]; then
    say "参数"
    printf '  模式：%s   runtime：%s\n' "$MODE" "$RUNTIME"
  fi
  if [[ ! -d "$RUNTIME/node_modules" ]]; then
    c_err "runtime 目录不对：$RUNTIME 下没有 node_modules。用 --runtime <dir> 指定。"
    exit 1
  fi

  # 现在才读当前版本：$RUNTIME 可能已被 --runtime 覆盖。
  local pkg_json="$RUNTIME/node_modules/@deepseek-ai/dsh/package.json"
  if [[ -f "$pkg_json" ]]; then
    current="$(grep -m1 '"version"' "$pkg_json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
  fi

  if [[ $JSON -eq 0 ]]; then say "查询 registry"; fi
  local json; json="$(fetch_registry || true)"
  if [[ -z "$json" ]]; then
    c_err "取不到 ${REGISTRY}（离线或包不可达）。check 需要一次网络请求。"
    exit 4
  fi

  report_and_resolve "$json"; local rc=$?
  if [[ $rc -eq 2 || $rc -eq 3 ]]; then exit $rc; fi

  if [[ "$MODE" == "check" ]]; then
    if [[ $JSON -eq 0 && -n "${RESOLVED_TARGET:-}" ]]; then
      printf '\n下一步（在本目录）：  ./update.sh update --yes\n'
      printf '跟踪某个标签：       ./update.sh update --tag next --yes\n'
    fi
    exit 0
  fi
}

run_update() {
  local target="$RESOLVED_TARGET"
  [[ -z "$target" ]] && { c_ok "没有需要更新的内容。"; exit 0; }

  local npm; if ! npm="$(find_npm)"; then
    c_err "找不到 npm，无法执行更新。"
    echo "  check 模式不需要 npm，已完成。要真正更新，请先装好 Node/npm，例如："
    echo "    brew install node        # 或从 nodejs.org 装，或用 nvm/volta"
    echo "  然后（在 shell/ 目录）：  ./update.sh update --yes"
    exit 5
  fi

  say "将执行更新"
  printf '  %s → %s\n' "$current" "$target"
  printf '  1) 在 %s 内：%s install %s@%s\n' "$RUNTIME" "$npm" "$PKG" "$target"
  printf '  2) 重跑 make-app.sh 重建 %s.app\n' "$APP_NAME"
  if [[ $DO_INSTALL -eq 1 ]]; then
    if [[ $KEEP_SRC -eq 1 ]]; then
      printf '  3) 再安装到 %s（--keep-src：保留 build 产物）\n' "$INSTALL_TARGET"
    else
      printf '  3) 再安装到 %s，装成后删掉 build/%s.app\n' "$INSTALL_TARGET" "$APP_NAME"
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    c_warn "  --dry-run：以上命令未执行。"
    exit 0
  fi

  if [[ $ASSUME_YES -ne 1 ]]; then
    printf '\n执行以上更新？[y/N] '
    read -r reply || reply=""
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
  fi

  say "在 runtime/ 更新 $PKG@$target"
  ( cd "$RUNTIME" && "$npm" install "$PKG@$target" )

  say "重建 $APP_NAME.app"
  if [[ ! -f "$MAKE_APP" ]]; then
    c_err "找不到 $MAKE_APP"; exit 7
  fi
  ( cd "$SCRIPT_DIR" && bash "$MAKE_APP" )

  if [[ $DO_INSTALL -eq 1 ]]; then
    say "安装到 /Applications"
    local installer="$SCRIPT_DIR/install-app.sh"
    if [[ -x "$installer" ]]; then
      # 交给 install-app.sh：它拦「还有进程在用旧包」、做备份、装后校验签名，
      # 三件都过了才删 build/dshX.app（--keep-src 则保留）。
      local -a iargs=()
      [[ $FORCE -eq 1 ]] && iargs+=(--force)
      if [[ $KEEP_SRC -eq 1 ]]; then iargs+=(--keep-src); fi
      bash "$installer" "${iargs[@]}"
    else
      c_warn "没有 install-app.sh，退回手动安装提示。装前先退出 dshX。"
      echo "  手动（有权限的终端里）：  bash \"$SCRIPT_DIR/install-app.sh\"   或"
      echo "    ditto \"$ROOT/build/$APP_NAME.app\" \"$INSTALL_TARGET\""
    fi
  fi

  echo
  c_ok "更新完成：$PKG $current → $target"
  if [[ $DO_INSTALL -eq 1 ]]; then
    if [[ $KEEP_SRC -eq 1 ]]; then
      echo "重开 dshX.app 即用上新的后端；build/$APP_NAME.app 已按 --keep-src 保留。"
    else
      echo "重开 dshX.app 即用上新的后端；build/$APP_NAME.app 已清理（要保留加 --keep-src）。"
    fi
  else
    echo "新后端在 build/$APP_NAME.app；要用它请走安装： ./update.sh update --install（或 bash install-app.sh）。"
  fi
}

main
if [[ "$MODE" == "update" ]]; then run_update; fi