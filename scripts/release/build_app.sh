#!/usr/bin/env bash

set -euo pipefail

# ---- Configurable release values ------------------------------------------
APP_NAME="${APP_NAME:-AdamanciaVault}"
DISPLAY_NAME="${DISPLAY_NAME:-Adamancia Vault}"
BUNDLE_ID="${BUNDLE_ID:-com.adamancia.vault.mac}"
TEAM_ID="${TEAM_ID:-9KCD8QL2LN}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Wenyi Cui (9KCD8QL2LN)}"
DMG_NAME="${DMG_NAME:-AdamanciaInstaller.dmg}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"
VERSION="${VERSION:-0.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SWIFTPM_PRODUCT="${SWIFTPM_PRODUCT:-MacBlockerPanel}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-13.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE="$(cd "$ROOT/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/release/build}"
APP_PATH="${APP_PATH:-$BUILD_DIR/$APP_NAME.app}"
RELEASE_BINARY="$ROOT/.build/arm64-apple-macosx/release/$SWIFTPM_PRODUCT"
ICON_SOURCE="${ICON_SOURCE:-$WORKSPACE/customBlocker/icons/icon-master.png}"

echo "[build_app] root=$ROOT"
echo "[build_app] version=$VERSION build=$BUILD_NUMBER bundle=$BUNDLE_ID"

swift build -c release --product "$SWIFTPM_PRODUCT" --package-path "$ROOT"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$RELEASE_BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$APP_NAME"

cp -R "$ROOT/.build/arm64-apple-macosx/release/macosBlocker_MacBlockerCore.bundle" \
  "$APP_PATH/Contents/Resources/"
cp -R "$ROOT/.build/arm64-apple-macosx/release/macosBlocker_MacBlockerWebUI.bundle" \
  "$APP_PATH/Contents/Resources/"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$BUILD_DIR/$APP_NAME.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    name="${spec#* }"
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/$APP_NAME.icns"
fi

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MACOS_MIN_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Adamancia Vault. All rights reserved.</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP_PATH/Contents/PkgInfo"
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null

echo "[build_app] wrote $APP_PATH"
