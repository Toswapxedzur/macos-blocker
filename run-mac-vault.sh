#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
delivery_checkout="$(git -C "$script_dir" config --get vault.deliveryCheckout 2>/dev/null || true)"
if [[ -n "$delivery_checkout" ]]; then
  exec python3 "$delivery_checkout/scripts/development/vault-delivery.py" launch
fi
# A mini1 source export has no shared laptop Git configuration.
exec bash "$script_dir/scripts/development/launch-mac-vault-build.sh"
