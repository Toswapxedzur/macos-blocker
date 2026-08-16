# Development environment isolation

Vault development binaries opt in with
`ADAMANCIA_VAULT_ENVIRONMENT=development`. Production binaries launched
normally do not set that variable.

The environments use disjoint local surfaces:

| Surface | Production | Development |
| --- | --- | --- |
| Browser extension ID | `mcbmcmephdaapjepopobikobjmfdeamm` | `fjichnkbaoilbfbjcjkggllmbicmeegk` |
| Native Messaging host | `com.adamancia.vault.local_hub` | `com.adamancia.vault.local_hub.development` |
| Loopback hub | `127.0.0.1:8787` | `127.0.0.1:18787` |
| Classifier state | `VaultClassifier` | `VaultClassifier-Development` |
| Local-hub Keychain service | `com.adamancia.vault.local-hub` | `com.adamancia.vault.local-hub.development` |
| Mac Vault App Group | `group.com.adamancia.vault` | `group.com.adamancia.vault.development` |
| Mac Vault fallback state | `macosBlocker` | `macosBlocker-Development` |

The development launchers are `run-vault-classifier.sh` and the Mac Vault
repository's `run-mac-vault.sh`. The Classifier launcher installs only the
development native-host manifest for the unpacked development extension.
Production native-host registration remains a signed-installer responsibility.

An unrecognized Chromium extension ID has no hub address or native-host
fallback and therefore fails closed.

The development extension ID is **pinned** by a `"key"` in
`customBlocker/manifest.json` (public key in `misc/vault-dev-extension-key.pem`),
so the unpacked extension keeps the same ID
(`fjichnkbaoilbfbjcjkggllmbicmeegk`) regardless of where the repo lives on disk.
Before the key was added, the ID was derived from the load path, so moving the
repo silently changed the ID and broke the hub handshake. If the ID ever needs
to change, update it in `local-hub-environment.js` (extension env),
`VaultRuntimeEnvironment.swift` (native auth origin), the native-host
`allowed_origins` template, and `tests/runner-local-hub-environment.js`, then
re-run `run-vault-classifier.sh`.
