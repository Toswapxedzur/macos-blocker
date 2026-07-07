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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/release/build}"
DIST_DIR="${DIST_DIR:-$ROOT/release/dist/$VERSION}"
APP_PATH="${APP_PATH:-$BUILD_DIR/$APP_NAME.app}"
DMG_ROOT="$BUILD_DIR/dmg-root"
DMG_PATH="${DMG_PATH:-$DIST_DIR/$DMG_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[create_dmg] missing app bundle: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$DMG_ROOT" "$DMG_PATH"
mkdir -p "$DMG_ROOT"

cp -R "$APP_PATH" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

cat > "$DMG_ROOT/README.txt" <<README
$DISPLAY_NAME $VERSION ($BUILD_NUMBER)

Install:
1. Drag $APP_NAME.app to Applications.
2. Open it from Applications.
3. If macOS warns that this app was downloaded from the internet, choose Open.

Uninstall:
Run uninstall.command from this disk image. It asks for confirmation, quits the
app if it is running, removes /Applications/$APP_NAME.app, and optionally removes
only known support files created by this app.

This release is signed with:
$SIGNING_IDENTITY
README

cat > "$DMG_ROOT/uninstall.command" <<UNINSTALL
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="$APP_NAME"
DISPLAY_NAME="$DISPLAY_NAME"
BUNDLE_ID="$BUNDLE_ID"
APP_PATH="/Applications/$APP_NAME.app"
LOG_FILE="\$HOME/Library/Logs/$APP_NAME-Uninstall.log"

USER_SUPPORT="\$HOME/Library/Application Support/macosBlocker"
USER_POLICY="\$HOME/Library/Application Support/Blocker/policy.json"
USER_POLICY_DIR="\$HOME/Library/Application Support/Blocker"
SYSTEM_POLICY="/Library/Application Support/Blocker/policy.json"
SYSTEM_POLICY_DIR="/Library/Application Support/Blocker"
PREF_PRIMARY="\$HOME/Library/Preferences/$BUNDLE_ID.plist"
PREF_LEGACY="\$HOME/Library/Preferences/MacBlockerPanel.plist"
GROUP_CONTAINER="\$HOME/Library/Group Containers/group.com.adamancia.vault"
GROUP_CONTAINER_LEGACY="\$HOME/Library/Group Containers/group.com.example.macosBlocker"
LAUNCH_AGENT="\$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
NATIVE_CHROME="\$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$BUNDLE_ID.json"
NATIVE_CHROMIUM="\$HOME/Library/Application Support/Chromium/NativeMessagingHosts/$BUNDLE_ID.json"
NATIVE_EDGE="\$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts/$BUNDLE_ID.json"
NATIVE_FIREFOX="\$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/$BUNDLE_ID.json"
NATIVE_SAFARI="\$HOME/Library/Application Support/com.apple.Safari/NativeMessagingHosts/$BUNDLE_ID.json"

mkdir -p "\$(dirname "\$LOG_FILE")"
touch "\$LOG_FILE"

log() {
  printf '[%s] %s\\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" | tee -a "\$LOG_FILE"
}

remove_file() {
  local path="\$1"
  if [[ -e "\$path" || -L "\$path" ]]; then
    log "remove file: \$path"
    rm -f "\$path"
  else
    log "skip missing file: \$path"
  fi
}

remove_dir() {
  local path="\$1"
  if [[ -d "\$path" && ! -L "\$path" ]]; then
    log "remove directory: \$path"
    rm -rf "\$path"
  else
    log "skip missing directory: \$path"
  fi
}

remove_dir_if_empty() {
  local path="\$1"
  if [[ -d "\$path" && -z "\$(find "\$path" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    log "remove empty directory: \$path"
    rmdir "\$path"
  else
    log "keep directory because missing or not empty: \$path"
  fi
}

remove_system_file() {
  local path="\$1"
  if [[ -e "\$path" || -L "\$path" ]]; then
    log "remove system file with sudo: \$path"
    sudo rm -f "\$path"
  else
    log "skip missing system file: \$path"
  fi
}

remove_system_dir_if_empty() {
  local path="\$1"
  if [[ -d "\$path" && -z "\$(find "\$path" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    log "remove empty system directory with sudo: \$path"
    sudo rmdir "\$path"
  else
    log "keep system directory because missing or not empty: \$path"
  fi
}

echo "This will uninstall \$DISPLAY_NAME from this Mac."
echo "A log will be written to: \$LOG_FILE"
read -r -p "Continue? [y/N] " confirm
if [[ ! "\$confirm" =~ ^[Yy]$ ]]; then
  log "cancelled by user"
  exit 0
fi

read -r -p "Also remove known settings/support files created by this app? [y/N] " remove_data

log "begin uninstall"

osascript -e "tell application id \\"\$BUNDLE_ID\\" to quit" >/dev/null 2>&1 || true
osascript -e "tell application \\"\$DISPLAY_NAME\\" to quit" >/dev/null 2>&1 || true
sleep 2

if [[ -x "\$APP_PATH/Contents/MacOS/\$APP_NAME" ]]; then
  log "ask app to unregister SMAppService login item"
  "\$APP_PATH/Contents/MacOS/\$APP_NAME" --unregister-login-item >/dev/null 2>&1 || true
else
  log "skip login item unregister because app executable is missing"
fi

pkill -x "\$APP_NAME" >/dev/null 2>&1 || true

if [[ -d "\$APP_PATH" ]]; then
  log "remove app with sudo: \$APP_PATH"
  sudo rm -rf "\$APP_PATH"
else
  log "skip missing app: \$APP_PATH"
fi

if [[ "\$remove_data" =~ ^[Yy]$ ]]; then
  remove_dir "\$USER_SUPPORT"
  remove_file "\$USER_POLICY"
  remove_dir_if_empty "\$USER_POLICY_DIR"
  remove_system_file "\$SYSTEM_POLICY"
  remove_system_dir_if_empty "\$SYSTEM_POLICY_DIR"
  remove_file "\$PREF_PRIMARY"
  remove_file "\$PREF_LEGACY"
  remove_dir "\$GROUP_CONTAINER"
  remove_dir "\$GROUP_CONTAINER_LEGACY"
  remove_file "\$LAUNCH_AGENT"
  remove_file "\$NATIVE_CHROME"
  remove_file "\$NATIVE_CHROMIUM"
  remove_file "\$NATIVE_EDGE"
  remove_file "\$NATIVE_FIREFOX"
  remove_file "\$NATIVE_SAFARI"
else
  log "kept settings/support files by user choice"
fi

log "uninstall complete"
echo "Done. Log: \$LOG_FILE"
UNINSTALL
chmod 755 "$DMG_ROOT/uninstall.command"

hdiutil create \
  -volname "$DISPLAY_NAME $VERSION" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
echo "[create_dmg] wrote $DMG_PATH"
cat "$DMG_PATH.sha256"
