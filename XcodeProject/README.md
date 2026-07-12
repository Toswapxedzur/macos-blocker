# Mac Vault Xcode project

`project.yml` is the checked-in XcodeGen specification for the macOS and iOS targets that use the shared Swift package.

## Generate the project

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Regenerate after changing `project.yml`, targets, entitlements, or source membership. Do not use generated project files as the canonical configuration.

## Current target families

- `AdamanciaVaultMac` is the macOS application target backed by `MacBlockerAppFeature`.
- `macosBlocker` is the iOS application target.
- The iOS project includes Device Activity, Shield Configuration, and Shield Action extensions.

The current identifiers, deployment targets, version fields, and capabilities are defined in `project.yml` and the referenced entitlement files. Review them in the signing environment before distribution.

## Signing and capabilities

Use a team and bundle identifiers that belong to the distribution account. Confirm the capabilities required by the target you are building. Never add signing secrets, provisioning profiles, or account credentials to this repository.

## Test first

Run the shared package tests before creating an archive:

```bash
cd ..
swift test
```
