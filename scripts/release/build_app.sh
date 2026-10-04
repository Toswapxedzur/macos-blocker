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
VERSION="${VERSION:-1.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-4}"
SWIFTPM_PRODUCT="${SWIFTPM_PRODUCT:-MacBlockerPanel}"
MACOS_MIN_VERSION="13.3"
VAULT_BUILD_ARCH="${VAULT_BUILD_ARCH:-$(uname -m)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE="$(cd "$ROOT/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/release/build}"
APP_PATH="${APP_PATH:-$BUILD_DIR/$APP_NAME.app}"
case "$VAULT_BUILD_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $VAULT_BUILD_ARCH" >&2; exit 1 ;; esac
runtime_work="${VAULT_RUNTIME_WORK:-$ROOT/release/runtime-$VAULT_BUILD_ARCH}"
if [[ -z "${VAULT_LLAMA_PREFIX:-}" ]]; then
  python3 "$SCRIPT_DIR/build-macos-runtime.py" --architecture "$VAULT_BUILD_ARCH" --work "$runtime_work"
  export VAULT_LLAMA_PREFIX="$runtime_work/install"
fi
python3 "$SCRIPT_DIR/verify-macos-runtime.py" --prefix "$VAULT_LLAMA_PREFIX" --architecture "$VAULT_BUILD_ARCH"
export PKG_CONFIG_PATH="$VAULT_LLAMA_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
BUILD_FLAGS=(-c release --arch "$VAULT_BUILD_ARCH")
binary_dir="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path --package-path "$ROOT")"
RELEASE_BINARY="$binary_dir/$SWIFTPM_PRODUCT"
ICON_SOURCE="${ICON_SOURCE:-$ROOT/Assets/Branding/mac-vault-master.png}"

echo "[build_app] root=$ROOT"
echo "[build_app] version=$VERSION build=$BUILD_NUMBER bundle=$BUNDLE_ID"

swift build "${BUILD_FLAGS[@]}" --product "$SWIFTPM_PRODUCT" --package-path "$ROOT"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$RELEASE_BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$APP_NAME"

# Every SwiftPM resource bundle: Mac Vault's own (Core, WebUI) and the Vault
# Classifier component's (its page assets and seed resources).
for bundle in "$binary_dir"/*.bundle; do
  cp -R "$bundle" "$APP_PATH/Contents/Resources/"
done

# The classifier's on-device engine links llama.cpp: carry its runtime inside
# the app so nothing is loaded from Homebrew on a user's Mac.
"$ROOT/classifier/scripts/bundle-llama-runtime.sh" "$APP_PATH" "$APP_NAME"

# The production Native Messaging host — the helper that hands the browser
# extension the local-hub secret. The app registers it with each installed
# browser on launch (NativeMessagingHostRegistration), so there is no installer
# step and the registration follows the app if it is moved.
swift build "${BUILD_FLAGS[@]}" --product VaultLocalHubNativeHost --package-path "$ROOT/classifier"
native_dir="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path --package-path "$ROOT/classifier")"
cp "$native_dir/VaultLocalHubNativeHost" "$APP_PATH/Contents/MacOS/"

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

python3 "$SCRIPT_DIR/verify-macos-runtime.py" --app "$APP_PATH" --architecture "$VAULT_BUILD_ARCH"
echo "[build_app] wrote $APP_PATH"
