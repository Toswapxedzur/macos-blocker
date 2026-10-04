#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Configurable release values ------------------------------------------
APP_NAME="${APP_NAME:-AdamanciaVault}"
DISPLAY_NAME="${DISPLAY_NAME:-Adamancia Vault}"
BUNDLE_ID="${BUNDLE_ID:-com.adamancia.vault.mac}"
TEAM_ID="${TEAM_ID:-9KCD8QL2LN}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Wenyi Cui (9KCD8QL2LN)}"
DMG_NAME="${DMG_NAME:-AdamanciaInstaller.dmg}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"
VERSION="${VERSION:-$(python3 "$SCRIPT_DIR/version.py" version)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(python3 "$SCRIPT_DIR/version.py" build)}"

ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/release/build}"
APP_PATH="${APP_PATH:-$BUILD_DIR/$APP_NAME.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "[sign_app] missing app bundle: $APP_PATH" >&2
  echo "[sign_app] run scripts/release/build_app.sh first" >&2
  exit 1
fi

APP_PROFILE="${MAC_VAULT_APP_PROVISIONING_PROFILE:?Select the production Mac App Group provisioning profile before signing}"
ENTITLEMENTS="$BUILD_DIR/MacVaultProduction.entitlements"
python3 "$ROOT/scripts/signing/vault-app-group.py" prepare \
  --environment production --profile "$APP_PROFILE" --app "$APP_PATH" \
  --entitlements "$ENTITLEMENTS" >/dev/null

if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null; then
  echo "[sign_app] codesign identity not found: $SIGNING_IDENTITY" >&2
  echo "[sign_app] installed identities:" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

echo "[sign_app] signing $APP_PATH"
# Nested code receives hardened runtime signing without the outer app's group.
# The outer signature alone carries its validated production entitlement.
codesign --force --deep --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS" "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [[ -n "$APP_PROFILE" ]]; then
  python3 "$ROOT/scripts/signing/vault-app-group.py" verify \
    --environment production --profile "$APP_PROFILE" --app "$APP_PATH"
fi
codesign -dv "$APP_PATH" 2>&1 | sed 's/^/[sign_app] /'

echo "[sign_app] signed $APP_PATH"
