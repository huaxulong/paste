#!/usr/bin/env bash
#
# 一眼看全 Paste 的状态。
#
#   ./status.sh            # 检查
#   ./status.sh start      # 没在跑就启动
#   ./status.sh restart    # 重启
#   ./status.sh log        # 实时跟踪日志
#
# Paste 是个 .accessory 后台应用：没有 Dock 图标、没有窗口，
# 所以「它到底在不在跑」从界面上看不出来 —— 需要主动查。
#
set -uo pipefail

APP="/Applications/Paste.app"
BINARY="$APP/Contents/MacOS/Paste"
SUPPORT="$HOME/Library/Application Support/com.local.paste"
LOG="$SUPPORT/paste.log"
ITEMS="$SUPPORT/items"
NAME="Paste"

# ---------------------------------------------------------------- 子命令

case "${1:-}" in
  start)
    if pgrep -x "$NAME" >/dev/null; then
      echo "已经在运行（PID $(pgrep -x "$NAME")）"
    else
      open "$APP" && sleep 2 && echo "已启动（PID $(pgrep -x "$NAME" 2>/dev/null || echo '?'))"
    fi
    exit 0
    ;;
  restart)
    pkill -x "$NAME" 2>/dev/null
    sleep 1.5
    pkill -9 -x "$NAME" 2>/dev/null
    sleep 0.5
    open "$APP" && sleep 2
    echo "已重启（PID $(pgrep -x "$NAME" 2>/dev/null || echo '启动失败'))"
    exit 0
    ;;
  log)
    if [ ! -f "$LOG" ]; then
      echo "还没有日志（应用没运行过？）"
      exit 1
    fi
    echo "跟踪 ${LOG}"
    echo "（Ctrl+C 退出）"
    echo
    tail -f "$LOG"
    exit 0
    ;;
  stop)
    if pgrep -x "$NAME" >/dev/null; then
      pkill -x "$NAME" 2>/dev/null
      sleep 1.5
      pkill -9 -x "$NAME" 2>/dev/null
      sleep 0.5
      pgrep -x "$NAME" >/dev/null && echo "退出失败" || echo "已退出"
    else
      echo "本来就没在运行"
    fi
    exit 0
    ;;
  icon)
    # 没有菜单栏图标时，这是唯一的开关方式（改完要重启应用才生效）
    case "${2:-}" in
      on)
        defaults write com.local.paste showMenuBarIcon -bool true
        echo "菜单栏图标：已开启（重启应用后生效）"
        "$0" restart
        ;;
      off)
        defaults write com.local.paste showMenuBarIcon -bool false
        echo "菜单栏图标：已隐藏（重启应用后生效）"
        "$0" restart
        ;;
      *)
        cur=$(defaults read com.local.paste showMenuBarIcon 2>/dev/null || echo "false（默认）")
        echo "菜单栏图标当前设置: ${cur}"
        echo "用法: $0 icon on|off"
        ;;
    esac
    exit 0
    ;;
  logfile)
    # 在访达里定位日志文件
    if [ -f "$LOG" ]; then
      open -R "$LOG"
      echo "已在访达中定位：${LOG}"
    else
      open "$SUPPORT"
      echo "日志还没生成，已打开目录：${SUPPORT}"
    fi
    exit 0
    ;;
  cat)
    # 直接打印最近 60 行，适合复制给人看
    if [ ! -f "$LOG" ]; then
      echo "还没有日志"
      exit 1
    fi
    tail -60 "$LOG"
    exit 0
    ;;
esac

# ---------------------------------------------------------------- 各项检查

# 只在真终端里上色，管道/重定向时保持纯文本
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[90m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_WARN=''; C_DIM=''; C_OFF=''
fi

ok()   { printf '  %s✓%s %-14s %s\n' "$C_OK" "$C_OFF" "$1" "$2"; }
bad()  { printf '  %s✗%s %-14s %s\n' "$C_BAD" "$C_OFF" "$1" "$2"; }
warn() { printf '  %s!%s %-14s %s\n' "$C_WARN" "$C_OFF" "$1" "$2"; }
info() { printf '  %s·%s %-14s %s\n' "$C_DIM" "$C_OFF" "$1" "$2"; }

echo
echo "Paste 状态"
echo "──────────────────────────────────────────────────────────"

# 1) 应用包
if [ -x "$BINARY" ]; then
  file_count="$(find "$APP" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if codesign --verify --strict "$APP" 2>/dev/null; then
    ok "应用包" "${APP}（${file_count} 个文件，签名有效）"
  else
    warn "应用包" "$APP 存在，但签名验证失败"
  fi
elif [ -e "$APP" ]; then
  bad "应用包" "$APP 存在但可执行文件缺失 —— 跑 ./build.sh release install 修复"
else
  bad "应用包" "$APP 不存在 —— 跑 ./build.sh release install 安装"
fi

# 2) 进程
if pgrep -x "$NAME" >/dev/null; then
  pid="$(pgrep -x "$NAME" | head -1)"
  started="$(ps -p "$pid" -o lstart= 2>/dev/null | xargs)"
  ok "进程" "运行中（PID ${pid}，启动于 ${started}）"
  RUNNING=1
else
  bad "进程" "未运行 —— 没有进程就没人响应 Ctrl+V。跑 ./status.sh start"
  RUNNING=0
fi

# 3) 热键
if [ "$RUNNING" = "1" ]; then
  if grep -q 'Ctrl+V 注册成功' "$LOG" 2>/dev/null; then
    ok "Ctrl+V 热键" "已注册"
  elif grep -q 'Ctrl+V 注册失败' "$LOG" 2>/dev/null; then
    bad "Ctrl+V 热键" "注册失败 —— 可能已被别的 App 占用"
  else
    info "Ctrl+V 热键" "日志里没有记录"
  fi
else
  info "Ctrl+V 热键" "进程没跑，无从谈起"
fi

# 4) 辅助功能权限（读日志里最近一次判断）
if [ -f "$LOG" ]; then
  last_perm="$(grep -E '自动粘贴就绪=|辅助功能权限：' "$LOG" | tail -1)"
  when="$(echo "$last_perm" | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
  if echo "$last_perm" | grep -q '就绪=true\|已授权'; then
    ok "辅助功能权限" "已授权，自动粘贴可用（${when} 判断）"
  elif [ -n "$last_perm" ]; then
    bad "辅助功能权限" "未授权 —— 回车只会复制，不会粘贴（${when} 判断）"
    echo "                 系统设置 → 隐私与安全性 → 辅助功能 → 添加 $APP"
  else
    info "辅助功能权限" "日志里没有记录"
  fi
else
  info "辅助功能权限" "还没有日志（应用未运行过）"
fi

# 4.5) 菜单栏图标
if [ "$(defaults read com.local.paste showMenuBarIcon 2>/dev/null || echo 0)" = "1" ]; then
  ok "菜单栏图标" "显示中（可用 $0 icon off 隐藏）"
else
  info "菜单栏图标" "已隐藏（只用 Ctrl+V；要显示就跑 $0 icon on）"
fi

# 5) 开机自启
if sfltool dumpbtm 2>/dev/null | grep -q 'Name: Paste'; then
  ok "开机自启" "已开启（下次登录会自动启动）"
else
  info "开机自启" "未开启（菜单栏图标里可以开）"
fi

# 6) 历史
if [ -d "$ITEMS" ]; then
  count="$(find "$ITEMS" -name '*.plist' 2>/dev/null | wc -l | tr -d ' ')"
  size="$(du -sh "$ITEMS" 2>/dev/null | cut -f1)"
  if [ "$count" -gt 0 ]; then
    ok "历史" "${count} 条，占用 ${size}"
  else
    info "历史" "空的"
  fi
else
  info "历史" "还没有历史目录"
fi

# 7) 日志位置
if [ -f "$LOG" ]; then
  info "日志" "$LOG"
else
  info "日志" "尚未生成"
fi

echo "──────────────────────────────────────────────────────────"

# 根据状态给一句最该做的事
if [ "$RUNNING" = "0" ]; then
  echo "下一步：./status.sh start"
elif [ -f "$LOG" ] && ! grep -qE '自动粘贴就绪=true|辅助功能权限：已授权' <(tail -200 "$LOG"); then
  echo "下一步：去「辅助功能」里把 ${APP} 加上并打开开关（授权后不用重启应用）"
else
  echo "一切正常。Ctrl+V 呼出面板，↑↓ 选择，回车粘贴。"
fi
echo
