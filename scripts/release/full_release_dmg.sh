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

export APP_NAME DISPLAY_NAME BUNDLE_ID TEAM_ID SIGNING_IDENTITY DMG_NAME NOTARY_PROFILE VERSION BUILD_NUMBER

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/build_app.sh"
"$SCRIPT_DIR/sign_app.sh"
"$SCRIPT_DIR/create_dmg.sh"
"$SCRIPT_DIR/notarize_dmg.sh"
"$SCRIPT_DIR/verify_release.sh"

echo "[full_release_dmg] done"
