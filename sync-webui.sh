#!/usr/bin/env bash
# Sync the Mac Vault web editor from the extension (customBlocker).
#
# The Mac app hosts the SAME editor as the browser extension (popup.html/js/css
# and their modules) inside a WKWebView; the only Mac-specific files are
# chrome-shim.js (the chrome.* surface backed by the native bridge), the
# activity page, the icons and the Mac manual. Never hand-edit a synced file
# here — change customBlocker and re-run this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$ROOT/../customBlocker" && pwd)"
DEST="$ROOT/Sources/MacBlockerWebUI/WebAssets"

SYNCED_FILES=(
  popup.js
  popup.css
  group-scopes.js
  parental-pin.js
  group-actions.js
  platform-profiles.js
  translations.js
  popup-markdown.js
  bridge-protocol.js
  browser-compat.js
  custom-rule-ai-reference.js
)

for file in "${SYNCED_FILES[@]}"; do
  cp "$SRC/$file" "$DEST/$file"
done

# popup.html: identical, except that chrome-shim.js must load before any other
# script (it defines the chrome.* surface the editor expects).
python3 - "$SRC/popup.html" "$DEST/popup.html" <<'PY'
import sys
src, dest = sys.argv[1], sys.argv[2]
html = open(src, encoding="utf-8").read()
marker = '    <script src="browser-compat.js"></script>\n'
assert html.count(marker) == 1, "popup.html: expected one browser-compat.js script tag"
html = html.replace(marker, '    <!-- Mac Vault: chrome-shim.js provides chrome.* over the native bridge; it must load first. -->\n    <script src="chrome-shim.js"></script>\n' + marker)
open(dest, "w", encoding="utf-8").write(html)
PY

rm -rf "$DEST/translation"
cp -R "$SRC/translation" "$DEST/translation"

echo "[sync-webui] synced ${#SYNCED_FILES[@]} files + popup.html + translation/ from $SRC"

# The Mac app's AI tools run the same lock rules in JavaScriptCore.
for file in parental-pin.js group-actions.js; do
  cp "$SRC/$file" "$ROOT/Sources/MacBlockerCore/Resources/$file"
done
