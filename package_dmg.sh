#!/usr/bin/env bash
# =============================================================================
# package_dmg.sh — Verantyx IDE DMG パッケージ作成スクリプト
#
# 使い方: bash package_dmg.sh [version]
#   例:   bash package_dmg.sh 1.0.0
#
# 出力: ./dist/VerantyxIDE-<version>.dmg
#
# 前提: Xcode Command Line Tools インストール済み
#       (xcode-select --install)
# =============================================================================
set -euo pipefail

VERSION="${1:-1.0.0}"
SCHEME="Verantyx"
CONFIGURATION="Release"
APP_NAME="Verantyx"
BUNDLE_ID="com.verantyx.ide"
DMG_NAME="VerantyxIDE-${VERSION}"
DIST_DIR="$(pwd)/dist"
STAGING_DIR="$(pwd)/dist/.staging"

echo "▶ Verantyx IDE パッケージ作成 v${VERSION}"
echo "================================================"

# ── 1. Clean old artifacts ──────────────────────────────────────────────────
echo "[1/6] クリーンアップ..."
rm -rf "$STAGING_DIR" "$DIST_DIR/${DMG_NAME}.dmg"
mkdir -p "$STAGING_DIR"

# ── 2. Build Release ────────────────────────────────────────────────────────
echo "[2/6] Release ビルド中..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  CODE_SIGN_STYLE="Manual" \
  CODE_SIGN_IDENTITY="-" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  ONLY_ACTIVE_ARCH=NO \
  BUILD_DIR="$(pwd)/build" \
  build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | tail -20

# ── 3. Find the .app ────────────────────────────────────────────────────────
echo "[3/6] .app バンドルを探索..."
APP_PATH=$(find "$(pwd)/build" -name "${APP_NAME}.app" -maxdepth 8 | head -1)
if [ -z "$APP_PATH" ]; then
  echo "❌ Error: ${APP_NAME}.app が見つかりません"
  exit 1
fi
echo "   Found: $APP_PATH"

# ── 4. Copy app to staging ──────────────────────────────────────────────────
echo "[4/6] ステージングにコピー..."
cp -R "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"

# Remove quarantine attributes (ad-hoc signed apps often need this)
xattr -cr "$STAGING_DIR/${APP_NAME}.app" 2>/dev/null || true

# ── 5. Ad-hoc sign (Gatekeeper bypass instructions in README) ───────────────
echo "[5/6] Ad-hoc 署名を付与..."
codesign --force --deep --sign "-" \
  --options runtime \
  "$STAGING_DIR/${APP_NAME}.app" 2>/dev/null || \
codesign --force --deep --sign "-" \
  "$STAGING_DIR/${APP_NAME}.app"
echo "   署名完了 (ad-hoc)"

# ── 6. Create DMG ───────────────────────────────────────────────────────────
echo "[6/6] DMG を作成中..."
mkdir -p "$DIST_DIR"

# Use hdiutil to create a nice DMG
TEMP_DMG="$DIST_DIR/.tmp_${DMG_NAME}.dmg"
hdiutil create \
  -srcfolder "$STAGING_DIR" \
  -volname "Verantyx IDE ${VERSION}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,b=16" \
  -format UDRW \
  -size 512m \
  "$TEMP_DMG" > /dev/null

# Mount and add /Applications symlink
MOUNT_DIR="/Volumes/VerantyxIDE_${VERSION}"
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_DIR" -noautoopen -quiet
ln -sf /Applications "$MOUNT_DIR/Applications" 2>/dev/null || true

# Add a .DS_Store/appearance hint (background look) if possible
sleep 1
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only
hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey "zlib-level=9" \
  -o "$DIST_DIR/${DMG_NAME}.dmg" > /dev/null
rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

# ── Done ────────────────────────────────────────────────────────────────────
DMG_SIZE=$(du -sh "$DIST_DIR/${DMG_NAME}.dmg" | cut -f1)
echo ""
echo "================================================"
echo "✅ 完了!"
echo "   出力: dist/${DMG_NAME}.dmg (${DMG_SIZE})"
echo ""
echo "📌 使い方:"
echo "   1. DMG をダウンロードして開く"
echo "   2. Verantyx.app を Applications フォルダにドラッグ"
echo "   3. 初回起動時: 右クリック → '開く' でゲートキーパーを回避"
echo ""
echo "📌 GitHub Release に添付する場合:"
echo "   gh release create v${VERSION} dist/${DMG_NAME}.dmg --title 'Verantyx IDE v${VERSION}'"
echo "================================================"
