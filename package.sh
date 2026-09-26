#!/usr/bin/env bash
#
# 打包成可安装的 .dmg。
#
#   ./package.sh
#
# 产物：dist/Paste-<版本>.dmg
# 双击挂载后，把 Paste 拖进「应用程序」即可。
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Paste"
APP_DIR="$PWD/$APP_NAME.app"
PLIST="$PWD/Resources/Info.plist"
DIST="$PWD/dist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

echo "==> 构建（release，不装到 /Applications）"
./build.sh release 2>&1 | grep -vE 'xcrun|PlatformPath' | tail -4

if [ ! -x "$APP_DIR/Contents/MacOS/$APP_NAME" ]; then
  echo "✗ 构建产物不完整：$APP_DIR"
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> 准备挂载后的内容"
# ditto 是 macOS 推荐的 bundle 拷贝方式，能保住签名和扩展属性
ditto "$APP_DIR" "$STAGE/$APP_NAME.app"
# 指向 /Applications 的软链接，挂载后可以直接拖进去
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'EOF'
Paste —— macOS 剪贴板历史工具

安装
----
把左边的 Paste 拖进右边的「应用程序」文件夹，然后从「应用程序」里打开它。

首次使用
--------
它是一个菜单栏应用（没有 Dock 图标、没有窗口）：
  · 菜单栏上会出现一个剪贴板图标，那说明它在运行
  · 按 Ctrl+V 呼出面板，↑↓ 选择，回车粘贴，Esc 关闭

自动粘贴需要授权
----------------
合成 Cmd+V 需要「辅助功能」权限：
  系统设置 → 隐私与安全性 → 辅助功能 → 添加 Paste 并打开开关
没授权也能用，只是内容会放进剪贴板，需要你自己按 Cmd+V。

如果提示「无法打开，因为无法验证开发者」
----------------------------------------
这是因为本包用的是自签名证书（没有 Apple 开发者账号）。
右键点 Paste → 打开；或者执行：
  xattr -dr com.apple.quarantine /Applications/Paste.app

卸载
----
1. 菜单栏图标 → 退出
2. 系统设置 → 通用 → 登录项 里移除 Paste
3. 删掉 /Applications/Paste.app
EOF

echo "==> 生成 dmg"
mkdir -p "$DIST"
rm -f "$DMG"
# 压缩格式选 UDBZ（bzip2）而不是默认的 UDZO（zlib）：同样内容 0.96 MB vs 1.03 MB。
#
# 试过 ULMO（lzfse，只有 0.82 MB），但 `hdiutil attach` 挂不上
# （报「资源暂时不可用」）—— 压得再小、挂不上也没用，所以不用它。
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDBZ \
  "$DMG" >/dev/null

echo
echo "==> 完成"
echo "    路径: $DMG"
echo "    大小: $(du -h "$DMG" | cut -f1)"
echo
echo "    安装: 双击挂载 → 把 Paste 拖进「应用程序」"
