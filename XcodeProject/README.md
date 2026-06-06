# macosBlocker Xcode Project Generator

This folder turns the shared Swift package + `XcodeScaffold/` sources into a
real, buildable iOS app project with the three Screen Time app extensions
already wired up.

SwiftPM alone cannot produce app extensions or an App Store binary, so the
project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from a single spec.

## Generate

```bash
cd macosBlocker/XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

`generate.sh` installs XcodeGen via Homebrew if it is missing.

## What the project contains

| Target | Type | Bundle ID (default) | Sources |
| --- | --- | --- | --- |
| `macosBlocker` | iOS app | `com.example.macosBlocker` | `XcodeScaffold/macosBlockerApp` + `Shared` |
| `macosBlockerDeviceActivityMonitor` | app extension | `…​.DeviceActivityMonitor` | `XcodeScaffold/macosBlockerDeviceActivityMonitor` + `Shared` |
| `macosBlockerShieldConfiguration` | app extension | `…​.ShieldConfiguration` | `XcodeScaffold/macosBlockerShieldConfiguration` |
| `macosBlockerShieldAction` | app extension | `…​.ShieldAction` | `XcodeScaffold/macosBlockerShieldAction` + `Shared` |

All targets link the local Swift package products they need
(`MacBlockerCore`, `MacBlockerScreenTime`, `MacBlockerAppFeature`,
`MacBlockerWebUI`). The web editor assets ride along automatically via the
`MacBlockerWebUI` resource bundle. The three extensions are embedded in the app.

The `NSExtensionPointIdentifier` for each extension is set in `project.yml`:

- DeviceActivityMonitor → `com.apple.deviceactivity.monitor-extension`
- ShieldConfiguration → `com.apple.ManagedSettingsUI.shield-configuration-service`
- ShieldAction → `com.apple.ManagedSettings.shield-action-service`

## Required edits before shipping

1. **Bundle IDs / prefix** — edit `options.bundleIdPrefix` and each
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
2. **App Group** — replace `group.com.example.macosBlocker` in:
   - `XcodeScaffold/Shared/AppGroupIdentifier.swift`
   - `XcodeScaffold/Entitlements/macosBlockerApp.entitlements`
   - `XcodeScaffold/Entitlements/macosBlockerExtensions.entitlements`
3. **Signing team** — set `DEVELOPMENT_TEAM` in `project.yml` (uncomment) or
   pick your team per target in Xcode's Signing & Capabilities.
4. **Capabilities** — confirm Family Controls and App Groups are enabled on the
   app and every extension (the entitlements files declare them; Xcode shows
   them under Signing & Capabilities).
5. **Family Controls (Distribution)** — request and get approved by Apple
   before uploading to App Store Connect. Development builds on your own device
   work without it.

## Run

Screen Time shields do **not** work in the Simulator. Build and run on a real
iPhone/iPad, authorize Screen Time when prompted (Status/Targets flow), pick
apps in the FamilyActivityPicker, and assign them to a group.

After editing `project.yml` or adding files, re-run `./generate.sh`. Do not
hand-edit the generated `.xcodeproj` (regeneration overwrites it). It's common
to gitignore `macosBlocker.xcodeproj` and commit only `project.yml`.
