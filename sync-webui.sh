#!/usr/bin/env bash
# Sync the Mac Vault web editor from the extension (customBlocker).
#
# The Mac app hosts the SAME editor as the browser extension (popup.html/js/css
# and their modules) inside its one WKWebView; the only Mac-specific files are
# chrome-shim.js (the chrome.* surface backed by the native bridge), scenes.js/
# scenes.css (the Classifier and Activity scenes beside the editor, in the same
# document), the activity scene, the icons and the Mac manual. Never hand-edit
# a synced file here — change customBlocker and re-run this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$ROOT/../customBlocker" && pwd)"
DEST="$ROOT/Sources/MacBlockerWebUI/WebAssets"

# A canonical runtime-contract update need not resync unrelated editor assets.
if [[ "${1:-}" == "--rule-core-only" && $# -eq 1 ]]; then
  cp "$SRC/rule-core.js" "$DEST/rule-core.js"
  cp "$SRC/rule-core.js" "$ROOT/Sources/MacBlockerCore/Resources/rule-core.js"
  exit 0
fi

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
  storage-schema.js
  rule-core.js
  vault-ui.css
  vault-ui.js
  vault-info.js
  vault-info.css
)

for file in "${SYNCED_FILES[@]}"; do
  cp "$SRC/$file" "$DEST/$file"
done

# popup.html: identical, except that chrome-shim.js must load before any other
# script (it defines the chrome.* surface the editor expects) and that the
# Mac's other scenes (scenes.css/js) join the document after the editor.
python3 - "$SRC/popup.html" "$DEST/popup.html" <<'PY'
import sys
src, dest = sys.argv[1], sys.argv[2]
html = open(src, encoding="utf-8").read()
def insert(marker, before="", after=""):
    global html
    assert html.count(marker) == 1, "popup.html: expected one " + marker.strip()
    html = html.replace(marker, before + marker + after)
insert('    <script src="browser-compat.js"></script>\n',
       before='    <!-- Mac Vault: chrome-shim.js provides chrome.* over the native bridge; it must load first. -->\n    <script src="desktop-config.js"></script>\n    <script src="chrome-shim.js"></script>\n')
insert('    <link rel="stylesheet" href="popup.css" />\n',
       after='    <link rel="stylesheet" href="scenes.css" />\n')
insert('    <script src="popup.js"></script>\n',
       after='    <!-- Mac Vault: the Classifier and Activity scenes, in this same document. -->\n    <script src="scenes.js"></script>\n')
open(dest, "w", encoding="utf-8").write(html)
PY

rm -rf "$DEST/translation"
cp -R "$SRC/translation" "$DEST/translation"

python3 - "$ROOT" <<'PYVERSIONS'
import json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path
root = Path(sys.argv[1])
mac = re.search(r'MARKETING_VERSION: "?([0-9.]+)', (root / "XcodeProject/project.yml").read_text()).group(1)
windows = ET.parse(root / "../windowsBlocker/src/WindowsBlocker/WindowsBlocker.csproj").findtext("PropertyGroup/Version")
(root / "classifier/Sources/VaultClassifierCore/Resources/storage-product-versions.json").write_text(json.dumps({"mac": mac, "windows": windows}, indent=2) + "\n")
(root / "Sources/MacBlockerWebUI/WebAssets/desktop-config.js").write_text('window.__CB_DESKTOP_MANIFEST=' + json.dumps({"version": mac, "name": "Mac Vault"}) + ';\n')
PYVERSIONS

echo "[sync-webui] synced ${#SYNCED_FILES[@]} files + popup.html + translation/ from $SRC"

# JavaScriptCore runs the editor's group policies and Mac Vault's native rules.
# Safari's browser-rule engine belongs to its separate containing app.
for file in platform-profiles.js group-scopes.js parental-pin.js group-actions.js rule-core.js; do
  cp "$SRC/$file" "$ROOT/Sources/MacBlockerCore/Resources/$file"
done
