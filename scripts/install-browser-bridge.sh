#!/bin/zsh
# Register the product native-messaging host for the stable Vault extension.
#
# This produces no network traffic and stores no credentials. The native host
# and visible app remain sibling executables in the SwiftPM release directory;
# the host launches that exact sibling only when the app-owned IPC socket is
# unavailable.
set -euo pipefail

extension_id="mcbmcmephdaapjepopobikobjmfdeamm"
host_name="com.adamancia.vault_classifier"
script_directory="$(cd -- "$(dirname -- "$0")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
requested_browser="all"

usage() {
  print "Usage: $0 [--browser chrome|edge|all]"
}

while (( $# > 0 )); do
  case "$1" in
    --browser)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      requested_browser="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

case "$requested_browser" in
  chrome|edge|all) ;;
  *) usage >&2; exit 64 ;;
esac

cd "$project_directory"
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
host_path="$binary_directory/VaultClassifierNativeHost"
app_path="$binary_directory/VaultClassifierApp"

if [[ ! -x "$host_path" || ! -x "$app_path" ]]; then
  print -u2 "Release build did not produce both Vault Classifier executables."
  exit 1
fi

user_home="$(python3 -c 'from pathlib import Path; print(Path.home())')"
typeset -a manifest_directories
manifest_directories=()
if [[ "$requested_browser" == "chrome" || "$requested_browser" == "all" ]]; then
  manifest_directories+=("$user_home/Library/Application Support/Google/Chrome/NativeMessagingHosts")
fi
if [[ "$requested_browser" == "edge" || "$requested_browser" == "all" ]]; then
  manifest_directories+=("$user_home/Library/Application Support/Microsoft Edge/NativeMessagingHosts")
fi

for manifest_directory in "${manifest_directories[@]}"; do
  mkdir -p -- "$manifest_directory"
  manifest_path="$manifest_directory/$host_name.json"
  temporary_manifest="$(mktemp "$manifest_directory/.$host_name.XXXXXX")"
  python3 - "$temporary_manifest" "$host_path" "$host_name" "$extension_id" <<'PY'
import json
import os
import sys

destination, host_path, host_name, extension_id = sys.argv[1:]
payload = {
    "name": host_name,
    "description": "Vault Classifier browser bridge",
    "path": os.path.realpath(host_path),
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"],
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
  chmod 0644 "$temporary_manifest"
  mv -f -- "$temporary_manifest" "$manifest_path"
  print "Registered $host_name for $manifest_directory"
done

print "Vault Classifier browser bridge is registered for extension $extension_id."
print "Open the Vault extension’s Settings and explicitly enable the Vault Classifier bridge."
