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

VAULT_SIGNING_IDENTITY="$signing_identity" "$script_dir/scripts/install-dev-native-host.sh"

binary_dir="$(swift build --show-bin-path)"
swift build --product VaultClassifierShell
binary="$binary_dir/VaultClassifierShell"
codesign --force --sign "$signing_identity" \
  --identifier "com.adamancia.vault.classifier.development" \
  --timestamp=none \
  "$binary"
export ADAMANCIA_VAULT_ENVIRONMENT=development
exec "$binary"
