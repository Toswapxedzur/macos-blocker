#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

# SwiftPM's default ad-hoc signature uses the binary's changing CDHash as its
# designated requirement. Keychain therefore sees each rebuild as a different
# app and cannot retain an “Always Allow” decision for the local-hub secret.
# Give this development launcher a stable Developer ID requirement instead.
signing_identity="${VAULT_CLASSIFIER_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\([^"]*Developer ID Application[^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
  echo "Vault Classifier needs a valid Developer ID Application signing identity for stable Keychain access." >&2
  echo "Set VAULT_CLASSIFIER_SIGNING_IDENTITY to a value shown by: security find-identity -v -p codesigning" >&2
  exit 1
fi

binary_dir="$(swift build --show-bin-path)"

# Build and install a development-only Native Messaging host. Its compile-time
# environment, host name, extension origin, Keychain service, and loopback port
# are all disjoint from production.
swift build --product VaultLocalHubNativeHost -Xswiftc -DVAULT_DEVELOPMENT_NATIVE_HOST
native_binary="$binary_dir/VaultLocalHubNativeHost"
codesign --force --sign "$signing_identity" \
  --identifier "com.adamancia.vault.local-hub.development" \
  --timestamp=none \
  "$native_binary"
native_root="$HOME/Library/Application Support/AdamanciaVaultDevelopment/NativeMessaging"
native_host="$native_root/VaultLocalHubNativeHostDevelopment"
mkdir -p "$native_root"
install -m 755 "$native_binary" "$native_host"

template="$script_dir/native-host/com.adamancia.vault.local_hub.development.json.template"
for browser_root in \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"; do
  mkdir -p "$browser_root"
  manifest="$browser_root/com.adamancia.vault.local_hub.development.json"
  escaped_native_host="${native_host//\\/\\\\}"
  escaped_native_host="${escaped_native_host//&/\\&}"
  sed "s|__ABSOLUTE_PATH_TO_VAULT_LOCAL_HUB_NATIVE_HOST__|$escaped_native_host|g" \
    "$template" > "$manifest"
  chmod 644 "$manifest"
done

swift build --product VaultClassifierApp
binary="$binary_dir/VaultClassifierApp"
codesign --force --sign "$signing_identity" \
  --identifier "com.adamancia.vault.classifier.development" \
  --timestamp=none \
  "$binary"
export ADAMANCIA_VAULT_ENVIRONMENT=development
exec "$binary"
