#!/usr/bin/env bash
#
# 纯逻辑测试（不需要 XCTest，也不需要图形界面）
#
set -euo pipefail

cd "$(dirname "$0")"

OUT="$(mktemp -d)/paste_logictest"

echo "==> 编译逻辑测试"
swiftc -O \
  -o "$OUT" \
  Tools/LogicTest/main.swift \
  Sources/Paste/ClipItem.swift \
  Sources/Paste/ClipStore.swift \
  Sources/Paste/ClipPersistence.swift \
  Sources/Paste/ClipboardSnapshot.swift \
  Sources/Paste/ClipboardMonitor.swift \
  Sources/Paste/Preferences.swift \
  Sources/Paste/Log.swift

echo "==> 运行"
"$OUT"
