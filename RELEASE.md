# Release Guide

This repository supports two macOS release channels:

1. Mac App Store build
2. Website download as a signed, notarized, stapled `.dmg`

Default release values:

```text
APP_NAME=AdamanciaVault
BUNDLE_ID=com.adamancia.vault.mac
TEAM_ID=9KCD8QL2LN
SIGNING_IDENTITY=Developer ID Application: Wenyi Cui (9KCD8QL2LN)
VERSION=0.0.1
BUILD_NUMBER=1
DMG_NAME=AdamanciaInstaller.dmg
NOTARY_PROFILE=notary-profile
```

## Current Project Audit

- Developer ID Application identity is installed: `Developer ID Application: Wenyi Cui (9KCD8QL2LN)`.
- `XcodeProject/project.yml` now sets `MARKETING_VERSION` to `0.0.1`, `CURRENT_PROJECT_VERSION` to `1`, and `DEVELOPMENT_TEAM` to `9KCD8QL2LN`.
- The website DMG bundle identifier is `com.adamancia.vault.mac`.
- The iOS/Screen Time App Store bundle identifiers are under `com.adamancia.vault.ios`.
- The App Group identifier is `group.com.adamancia.vault`.
- A sandboxed macOS App Store target is declared as `AdamanciaVaultMac` in the XcodeGen project.
- The website DMG pipeline is under `scripts/release/`.
- Release outputs are ignored by git under `release/`.

## Mac App Store Build

Generate the Xcode project:

```bash
cd /Users/fengyue.john.zhu/Desktop/blockerGroup/macosBlocker/XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Use the `AdamanciaVaultMac` target for a macOS App Store archive. It is configured with:

- Bundle ID: `com.adamancia.vault.mac`
- Team ID: `9KCD8QL2LN`
- Marketing version: `0.0.1`
- Build number: `1`
- App Sandbox: enabled in `XcodeScaffold/Entitlements/AdamanciaVaultMacStore.entitlements`

Before archiving, check Xcode:

- Signing & Capabilities uses team `9KCD8QL2LN`.
- `AdamanciaVaultMac` has App Sandbox enabled.
- The entitlements do not include Developer ID-only or restricted entitlements.
- The version is `0.0.1` and build number is `1`.
- The bundle identifier matches the App Store Connect app record.

Archive and upload:

```text
Xcode -> Product -> Archive
Organizer -> Distribute App -> App Store Connect -> Upload
```

Do not submit for App Review automatically. Upload first, then inspect warnings in App Store Connect.

Important: the existing app links shared code that includes macOS control features. The Mac App Store sandbox target does not include Endpoint Security entitlements. If App Review rejects app-control behavior or permission usage, ship that behavior only through the Developer ID website channel.

## Website DMG Build

Create the notary profile once:

```bash
xcrun notarytool store-credentials "notary-profile" --team-id "9KCD8QL2LN"
```

Then run the complete website release:

```bash
cd /Users/fengyue.john.zhu/Desktop/blockerGroup/macosBlocker
VERSION=0.0.1 BUILD_NUMBER=1 scripts/release/full_release_dmg.sh
```

The final DMG is written to:

```text
release/dist/0.0.1/AdamanciaInstaller.dmg
```

The DMG contains:

- `AdamanciaVault.app`
- `Applications` symlink
- `README.txt`
- `uninstall.command`

## Step-by-Step Website Pipeline

Build the app bundle:

```bash
scripts/release/build_app.sh
```

Sign with Developer ID and hardened runtime:

```bash
scripts/release/sign_app.sh
```

Create and sign the DMG:

```bash
scripts/release/create_dmg.sh
```

Submit, wait, staple:

```bash
scripts/release/notarize_dmg.sh
```

Verify:

```bash
scripts/release/verify_release.sh
```

## Uninstaller Behavior

The DMG includes `uninstall.command`. It:

- Asks for confirmation.
- Asks separately before removing settings/support files.
- Quits `Adamancia Vault` if it is running.
- Runs `AdamanciaVault --unregister-login-item` when possible to unregister the `SMAppService.mainApp` login item.
- Removes `/Applications/AdamanciaVault.app`.
- Logs every remove or skip action to `~/Library/Logs/AdamanciaVault-Uninstall.log`.

If the user chooses to remove settings/support files, it removes only these exact known paths:

```text
~/Library/Application Support/macosBlocker
~/Library/Application Support/Blocker/policy.json
/Library/Application Support/Blocker/policy.json
~/Library/Preferences/com.adamancia.vault.mac.plist
~/Library/Preferences/MacBlockerPanel.plist
~/Library/Group Containers/group.com.adamancia.vault
~/Library/Group Containers/group.com.example.macosBlocker
~/Library/LaunchAgents/com.adamancia.vault.mac.plist
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.adamancia.vault.mac.json
~/Library/Application Support/Chromium/NativeMessagingHosts/com.adamancia.vault.mac.json
~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.adamancia.vault.mac.json
~/Library/Application Support/Mozilla/NativeMessagingHosts/com.adamancia.vault.mac.json
~/Library/Application Support/com.apple.Safari/NativeMessagingHosts/com.adamancia.vault.mac.json
```

It removes `~/Library/Application Support/Blocker` and `/Library/Application Support/Blocker` only if they are empty after the exact policy file is removed.

## Legal Files

Permanent legal files for the macOS app are in:

```text
LEGAL/PRIVACY.md
LEGAL/TERMS.md
```

Keep these files in git for every public release.

## Troubleshooting

### Missing private key

Symptom: `codesign` sees the certificate but signing fails with a keychain/private-key error.

Fix: open Keychain Access and confirm the Developer ID certificate has a disclosure triangle with a private key under it. If the private key is missing, import the original `.p12` that contains both certificate and private key.

### Codesign identity not found

Symptom: `scripts/release/sign_app.sh` prints `codesign identity not found`.

Fix:

```bash
security find-identity -v -p codesigning
```

Confirm it lists:

```text
Developer ID Application: Wenyi Cui (9KCD8QL2LN)
```

If the name differs, override it:

```bash
SIGNING_IDENTITY="Developer ID Application: Exact Name (TEAMID)" scripts/release/full_release_dmg.sh
```

### Notarization failed

Symptom: `notarytool submit` fails.

Fix: read the notarization log from the failed submission:

```bash
xcrun notarytool log <submission-id> --keychain-profile "notary-profile" --team-id "9KCD8QL2LN"
```

Common causes are unsigned nested code, missing hardened runtime, invalid bundle, or embedded private/secrets files.

### Hardened runtime missing

Symptom: notarization reports hardened runtime problems.

Fix: make sure signing used:

```bash
codesign --options runtime --timestamp --sign "Developer ID Application: Wenyi Cui (9KCD8QL2LN)" AdamanciaVault.app
```

The release script already does this.

### App rejected by Gatekeeper

Symptom: macOS says the app cannot be opened or is from an unidentified developer.

Fix:

```bash
spctl -a -vvv --type open release/dist/0.0.1/AdamanciaInstaller.dmg
xcrun stapler validate release/dist/0.0.1/AdamanciaInstaller.dmg
```

If stapling is missing, rerun `scripts/release/notarize_dmg.sh`.

### Wrong entitlements

Symptom: App Store upload or notarization complains about unsupported entitlements.

Fix:

```bash
codesign -d --entitlements :- release/build/AdamanciaVault.app
```

For Mac App Store, use the sandboxed `AdamanciaVaultMac` target and `AdamanciaVaultMacStore.entitlements`. For website Developer ID releases, avoid App Store-only or restricted entitlements unless Apple explicitly granted them to the Developer ID profile.
