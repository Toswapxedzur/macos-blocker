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
VERSION="${VERSION:-0.0.2}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/release/build}"
DIST_DIR="${DIST_DIR:-$ROOT/release/dist/$VERSION}"
APP_PATH="${APP_PATH:-$BUILD_DIR/$APP_NAME.app}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/$DMG_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[verify_release] missing app bundle: $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
  echo "[verify_release] missing DMG: $DMG_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv "$APP_PATH" 2>&1 | sed 's/^/[verify_release] /'

spctl -a -vvv --type execute "$APP_PATH"
spctl -a -vvv --type open --context context:primary-signature "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

MOUNT_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
echo "$MOUNT_OUTPUT"
VOLUME="$(printf '%s\n' "$MOUNT_OUTPUT" | awk 'index($0, "/Volumes/") {print substr($0, index($0, "/Volumes/")); exit}')"
if [[ -z "$VOLUME" || ! -d "$VOLUME" ]]; then
  echo "[verify_release] could not find mounted volume" >&2
  exit 1
fi
trap 'hdiutil detach "$VOLUME" >/dev/null 2>&1 || true' EXIT

[[ -d "$VOLUME/$APP_NAME.app" ]] || { echo "[verify_release] missing app in DMG" >&2; exit 1; }
[[ -L "$VOLUME/Applications" ]] || { echo "[verify_release] missing Applications symlink" >&2; exit 1; }
[[ -f "$VOLUME/README.txt" ]] || { echo "[verify_release] missing README.txt" >&2; exit 1; }
[[ -x "$VOLUME/uninstall.command" ]] || { echo "[verify_release] missing executable uninstall.command" >&2; exit 1; }

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
cat "$DMG_PATH.sha256"

echo "[verify_release] release verified"
