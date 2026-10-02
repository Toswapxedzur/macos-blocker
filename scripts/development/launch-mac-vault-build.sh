#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$script_dir"

delivery_checkout="$(git config --get vault.deliveryCheckout 2>/dev/null || true)"
if [[ -n "$delivery_checkout" ]]; then
  if [[ "$script_dir" != "$delivery_checkout" || "${VAULT_DELIVERY_COMMIT:-}" != "$(git rev-parse HEAD)" ]]; then
    echo "Laptop app delivery must use vault-delivery launch from the verified shared checkout." >&2
    exit 1
  fi
fi

signing_identity="${MAC_VAULT_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\([^"]*Developer ID Application[^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
  echo "Mac Vault needs a valid Developer ID Application signing identity for stable development Keychain access." >&2
  echo "Set MAC_VAULT_SIGNING_IDENTITY to a value shown by: security find-identity -v -p codesigning" >&2
  exit 1
fi

"$script_dir/scripts/development/migrate_state_once.sh"

# The Vault Classifier is a component of this app: install the development
# Native Messaging host that hands the browser extension the local-hub secret.
VAULT_SIGNING_IDENTITY="$signing_identity" "$script_dir/classifier/scripts/install-dev-native-host.sh"

swift build --product MacBlockerPanel
binary_dir="$(swift build --show-bin-path)"
binary="$binary_dir/MacBlockerPanel"
app_profile="${MAC_VAULT_APP_PROVISIONING_PROFILE:-}"
if [[ -n "$app_profile" ]]; then
  app="$binary_dir/Mac Vault Development.app"
  entitlements="$binary_dir/MacVaultDevelopment.entitlements"
  python3 "$script_dir/scripts/signing/vault-app-group.py" prepare \
    --environment development --profile "$app_profile" --app "$app" \
    --binary "$binary" --entitlements "$entitlements" >/dev/null
  # Sign nested resource bundles first without the app's restricted group
  # entitlements; apply those only to the containing app's final signature.
  codesign --force --deep --sign "$signing_identity" --timestamp=none "$app"
  codesign --force --sign "$signing_identity" \
    --identifier "com.adamancia.vault.mac.development" --timestamp=none \
    --entitlements "$entitlements" "$app"
  codesign --verify --deep --strict "$app"
  python3 "$script_dir/scripts/signing/vault-app-group.py" verify \
    --environment development --profile "$app_profile" --app "$app"
  binary="$app/Contents/MacOS/MacBlockerPanel"
else
  codesign --force --sign "$signing_identity" \
    --identifier "com.adamancia.vault.mac.development" \
    --timestamp=none \
    "$binary"
  echo "Safari pairing unavailable: no development Mac App Group provisioning profile was selected." >&2
fi
export ADAMANCIA_VAULT_ENVIRONMENT=development
exec "$binary"
