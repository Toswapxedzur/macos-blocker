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
DIST_DIR="${DIST_DIR:-$ROOT/release/dist/$VERSION}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/$DMG_NAME}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "[notarize_dmg] missing DMG: $DMG_PATH" >&2
  exit 1
fi

echo "[notarize_dmg] checking notarytool profile: $NOTARY_PROFILE"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" >/dev/null 2>&1; then
  cat >&2 <<MSG
[notarize_dmg] notarytool profile '$NOTARY_PROFILE' is missing or invalid.
Create it manually, without committing credentials:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" --team-id "$TEAM_ID"

MSG
  exit 1
fi

echo "[notarize_dmg] submitting $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --team-id "$TEAM_ID" \
  --wait

echo "[notarize_dmg] stapling $DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "[notarize_dmg] notarized and stapled $DMG_PATH"
