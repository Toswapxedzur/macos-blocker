#!/usr/bin/env bash
# Builds and installs the DEVELOPMENT Native Messaging host — the helper that
# hands the browser extension the local-hub secret — and registers it with
# Chrome and Edge. Shared by Mac Vault's launcher (../run-mac-vault.sh), which
# hosts the classifier, and by the standalone classifier shell launcher.
# Requires VAULT_SIGNING_IDENTITY (a Developer ID Application identity).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$script_dir"
signing_identity="${VAULT_SIGNING_IDENTITY:?set VAULT_SIGNING_IDENTITY}"

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
