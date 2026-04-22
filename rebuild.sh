#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# rebuild.sh — VerantyxIDE をビルドして再起動する
# 使い方: bash rebuild.sh
# ─────────────────────────────────────────────────────────────────

set -e
APP_PATH="/Users/motonishikoudai/Library/Developer/Xcode/DerivedData/Verantyx-bpyayjzaotjnfcehmawblbjjzwdn/Build/Products/Debug/Verantyx.app"
PROJECT_DIR="$(dirname "$0")"

export PATH="$PATH:/opt/homebrew/bin"

echo "🔨 ビルド中..."
xcodebuild \
  -project "$PROJECT_DIR/Verantyx.xcodeproj" \
  -scheme Verantyx \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | grep -v "objc\|deprecated" || true

# ビルド成功チェック
if [ $? -ne 0 ]; then
  echo "❌ ビルドに失敗しました"
  exit 1
fi

echo "✅ ビルド完了"

# 旧プロセスを終了
echo "🔄 旧プロセスを終了中..."
pkill -x Verantyx 2>/dev/null || true
sleep 0.5

# 新しいバイナリを起動
echo "🚀 起動中..."
open "$APP_PATH"
echo "✨ Verantyx が再起動しました"
