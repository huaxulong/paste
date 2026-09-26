#!/usr/bin/env bash
#
# 构建 Paste.app。
# 只用 Command Line Tools 就能跑，不需要完整 Xcode。
#
#   ./build.sh                  # release 构建
#   ./build.sh debug            # debug 构建
#   ./build.sh release install  # 构建完再装到 /Applications（开机自启需要）
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
ACTION="${2:-}"
APP_NAME="Paste"
APP_DIR="$PWD/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# 去掉符号表。__LINKEDIT 段占了二进制的一大半（590KB → 344KB），
# 而这是个本地工具，不需要调试符号。
# ⚠️ 必须在 codesign **之前**做：strip 会改二进制，签名会失效。
if strip -x "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null; then
  echo "==> strip 符号表（$(du -k "$APP_DIR/Contents/MacOS/$APP_NAME" | cut -f1) KB）"
else
  echo "    strip 失败，跳过（不影响功能）"
fi

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "    ⚠️ 没找到 Resources/AppIcon.icns，图标会缺失"
  echo "       跑一次: swift Tools/make_icon.swift"
fi

# 签名身份：优先用 setup-signing-cert.sh 建的自签名证书。
#
# 用证书的意义：签名的 designated requirement 只跟证书绑定
# （identifier "com.local.paste" and certificate leaf = H"…"），
# 重新编译不会变，macOS 就一直认得这个 App，「辅助功能」授权不会失效。
#
# ad-hoc 签名（--sign -）的 DR 是 cdhash H"…"，直接绑定二进制哈希，
# 每次编译都变 → 每次都要重新授权。
SIGN_IDENTITY="${PASTE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -p codesigning 2>/dev/null \
     | grep -qF '"Paste Self Signed"'; then
  SIGN_IDENTITY="Paste Self Signed"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> codesign (证书「${SIGN_IDENTITY}」)"
  if codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
    echo "    签名完成，重新编译不会让辅助功能授权失效"
  else
    echo "    签名失败，退回 ad-hoc"
    SIGN_IDENTITY=""
  fi
fi

if [ -z "$SIGN_IDENTITY" ]; then
  echo "==> codesign (ad-hoc)"
  codesign --force --sign - "$APP_DIR" 2>/dev/null || echo "    签名失败（本机运行通常仍然可用）"
  echo "    ⚠️ ad-hoc 签名每次编译都变，改代码后需要重新授予辅助功能权限。"
  echo "       跑一次 ./setup-signing-cert.sh 就能免掉这个麻烦。"
fi

if [ "$ACTION" = "install" ]; then
  echo
  echo "==> 安装到 /Applications"
  DEST="/Applications/$APP_NAME.app"

  OLD_HASH=""
  if [ -f "$DEST/Contents/MacOS/$APP_NAME" ]; then
    OLD_HASH="$(shasum -a 256 "$DEST/Contents/MacOS/$APP_NAME" | awk '{print $1}')"
  fi
  NEW_HASH="$(shasum -a 256 "$APP_DIR/Contents/MacOS/$APP_NAME" | awk '{print $1}')"

  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5

  # 用 ditto **原地更新**，而不是 rm -rf 之后重建整个 bundle。
  # 删掉再建会换掉目录 inode，系统里已授予的「辅助功能」权限很可能就失效了。
  mkdir -p "$DEST"
  if ditto "$APP_DIR" "$DEST" 2>/dev/null; then
    echo "    已安装: $DEST"
    if [ -n "$OLD_HASH" ] && [ "$OLD_HASH" != "$NEW_HASH" ]; then
      echo "    ⚠️ 可执行文件有变化。如果之前已授予「辅助功能」，可能需要重新授权："
      echo "       系统设置 → 隐私与安全性 → 辅助功能 → 把 Paste 用 − 移除，再用 + 重新添加"
    fi
    echo "    运行:  open \"$DEST\""
    APP_DIR="$DEST"
  else
    echo "    拷贝失败（可能需要管理员权限），可以手动把 $APP_DIR 拖进「应用程序」"
  fi
fi

echo
echo "==> 完成: $APP_DIR"
echo "    运行:  open \"$APP_DIR\""
echo "    日志:  launchctl setenv PASTE_LOG_FILE /tmp/paste.log && open \"$APP_DIR\""
echo "    退出:  菜单栏图标 → 退出 Paste"
