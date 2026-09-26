#!/usr/bin/env bash
#
# 卸载 Paste —— 不只是删 .app。
#
#   ./uninstall.sh               # 交互确认后卸载（保留剪贴板历史）
#   ./uninstall.sh --dry-run     # 只列出会删什么，不动任何东西
#   ./uninstall.sh --purge       # 连剪贴板历史和签名证书一起删干净
#   ./uninstall.sh --yes         # 跳过确认
#
# 需要删掉的东西比想象的多，见下面每一步的注释。
#
set -uo pipefail

APP="/Applications/Paste.app"
BUNDLE_ID="com.local.paste"
SUPPORT="$HOME/Library/Application Support/com.local.paste"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

DRY_RUN=0
PURGE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge)   PURGE=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

say()  { printf '  %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }
run()  {
  if [ "$DRY_RUN" = "1" ]; then
    say "[dry-run] $*"
  else
    "$@"
  fi
}

echo
echo "Paste 卸载$( [ "$DRY_RUN" = "1" ] && echo "（预演，不会改动任何东西）" )"
echo "══════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────
step "1/7 退出应用"
if pgrep -x Paste >/dev/null; then
  run pkill -x Paste
  [ "$DRY_RUN" = "0" ] && sleep 1.5 && pkill -9 -x Paste 2>/dev/null
  say "已退出"
else
  say "没在运行"
fi

# ─────────────────────────────────────────────────────────
# 开机自启项存在「后台任务数据库」(BTM) 里，**删掉 .app 不会自动清掉它**。
# 应用自己有注销接口，趁 .app 还在先用它。
step "2/7 注销开机自启项"
if [ -x "$APP/Contents/MacOS/Paste" ] && sfltool dumpbtm 2>/dev/null | grep -q 'Name: Paste'; then
  if [ "$DRY_RUN" = "1" ]; then
    say "[dry-run] 用 PASTE_DEBUG_LOGIN_ITEM=disable 启动一次以注销自启项"
  else
    PASTE_DEBUG_LOGIN_ITEM=disable "$APP/Contents/MacOS/Paste" >/dev/null 2>&1 &
    sleep 2.5
    pkill -x Paste 2>/dev/null
    sleep 0.5
    if sfltool dumpbtm 2>/dev/null | grep -q 'Name: Paste'; then
      say "⚠️ 自启项仍在，可能需要在「系统设置 → 通用 → 登录项」里手动移除"
    else
      say "已注销"
    fi
  fi
else
  say "没有自启项（或 .app 已不存在）"
fi

# ─────────────────────────────────────────────────────────
step "3/7 删除应用本体"
APP_WILL_BE_GONE=0
if [ -e "$APP" ]; then
  run rm -rf "$APP"
  APP_WILL_BE_GONE=1
  say "$APP"
else
  say "（不存在）"
fi
# 项目目录里的构建产物也算上
for p in "$(cd "$(dirname "$0")" && pwd)/Paste.app" "$(cd "$(dirname "$0")" && pwd)/dist"; do
  [ -e "$p" ] && { run rm -rf "$p"; say "$(basename "$p")（项目内构建产物）"; }
done

# ─────────────────────────────────────────────────────────
# 剪贴板历史和日志，含你自己的剪贴板内容
step "4/7 数据目录"
if [ -e "$SUPPORT" ]; then
  if [ "$PURGE" = "1" ]; then
    size=$(du -sh "$SUPPORT" 2>/dev/null | cut -f1)
    run rm -rf "$SUPPORT"
    say "${SUPPORT}（${size}）"
  else
    say "保留（加 --purge 才删）: $SUPPORT"
  fi
else
  say "（不存在）"
fi

# ─────────────────────────────────────────────────────────
step "5/7 偏好设置"
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  run defaults delete "$BUNDLE_ID"
  say "defaults delete $BUNDLE_ID"
else
  say "（无）"
fi

# ─────────────────────────────────────────────────────────
# 辅助功能授权。tccutil 只能重置、不能查询，所以直接重置。
# 注意：这里**带 bundle id**，只影响 Paste，不会动别的应用的授权。
step "6/7 辅助功能授权"
if [ "$DRY_RUN" = "1" ]; then
  say "[dry-run] tccutil reset Accessibility $BUNDLE_ID"
else
  tccutil reset Accessibility "$BUNDLE_ID" 2>&1 | sed 's/^/  /'
fi

# ─────────────────────────────────────────────────────────
step "7/7 收尾"
# 用步骤 3 记录的状态判断，不要事后查文件系统 ——
# dry-run 时 .app 并没有真被删，查文件系统会误判。
if [ "$APP_WILL_BE_GONE" = "1" ]; then
  run "$LSREGISTER" -u "$APP" 2>/dev/null
  say "已从 LaunchServices 注销"
else
  say "（应用本来就不存在，无需注销）"
fi

if [ "$PURGE" = "1" ]; then
  if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q 'Paste Self Signed'; then
    if [ "$DRY_RUN" = "1" ]; then
      say "[dry-run] 删除签名证书「Paste Self Signed」"
    else
      codesign_script="$(dirname "$0")/setup-signing-cert.sh"
      [ -x "$codesign_script" ] && "$codesign_script" --remove
    fi
  else
    say "（没有签名证书）"
  fi
else
  say "保留签名证书（--purge 才删）。它只是本地一张证书，留着以后重装还能用"
fi

# ─────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════"
if [ "$DRY_RUN" = "1" ]; then
  echo "这是预演。真正执行：./uninstall.sh"
else
  echo "卸载完成。"
  [ "$PURGE" = "0" ] && echo "剪贴板历史还在：${SUPPORT}（要删就加 --purge）"
  echo
  echo "如果「系统设置 → 隐私与安全性 → 辅助功能」里还留着 Paste 条目，"
  echo "选中它按 − 移除即可（tccutil 通常已经清掉了，但列表刷新有延迟）。"
fi
echo
