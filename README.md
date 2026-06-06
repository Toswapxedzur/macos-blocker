# macosBlocker

`macosBlocker` is the first native port of `customBlocker` into a shared
Swift codebase for iPhone, iPad, and Mac.

The original project is a Chrome Manifest V3 extension. This port keeps the
parts that can exist outside the browser:

- block groups
- schedules and time windows
- immediate and timed blocking
- freeze and snooze state
- import from the Chrome extension group schema
- custom JavaScript rules as a policy engine
- status/overlay intent as shield text, status page state, or a Mac floating
  window model

It does not pretend iOS can manipulate arbitrary app UI. On iPhone and iPad,
blocking is implemented through Apple's Screen Time family of APIs. On Mac,
permission-gated Accessibility control is modeled as a separate adapter.

## The UI Is The Original, Verbatim

The editor UI is **not** a re-implementation. The entire `customBlocker`
front end — `popup.html`, `popup.css`, `popup.js`, `translations.js`,
`popup-markdown.js`, all 10 `templates/*.js` rule presets, all 20
`translation/*.json` locales, and all 20 `manual/*.md` files — is copied
verbatim into `Sources/MacBlockerWebUI/WebAssets/` and runs unchanged inside a
`WKWebView` on iPhone, iPad, and Mac.

The only addition is `chrome-shim.js`, injected as the first script in
`popup.html`. It provides the small slice of the Chrome extension API the
editor actually touches, so the unmodified code runs outside a browser
extension:

- `chrome.storage.local.get/set/remove` + `chrome.storage.onChanged`
- `chrome.runtime.getURL/sendMessage/onMessage/id/getManifest`
- `chrome.permissions.contains/request` (always granted; hides the
  Chrome-only site-access banner)
- `chrome.i18n.getMessage/getUILanguage`

Storage is mirrored to `localStorage` (so the page also works opened directly
in a browser) and pushed to the native host through a `WKScriptMessageHandler`
named `cbBridge`. The host persists it as the same `blockedGroups` /
`globalSettings` / usage snapshot the extension used, so the native policy core
can read it back via `ChromeExtensionImporter`. The editor's **Run** button
also loads the custom rule into the native `CustomJavaScriptPolicyRuntime`.

`check-custom-group-syntax` runs in-page (the shim evaluates the rule with a
counting event registry), so syntax errors and handler counts behave exactly
like the extension's sandbox check.

## Package Layout

```text
Sources/
  MacBlockerCore/
    Shared models, schedule parsing, policy evaluation, import, JS runtime.
  MacBlockerScreenTime/
    iPhone/iPad Screen Time shielding and Device Activity adapter seams.
  MacBlockerMacControl/
    Mac Accessibility control and floating status window adapter seams.
  MacBlockerWebUI/
    The verbatim customBlocker web UI (WebAssets/) hosted in a cross-platform
    WKWebView, plus the chrome.* shim and the native storage bridge.
  MacBlockerAppFeature/
    Combined app surface: web Editor tab + native Status panel, plus sample
    data and persistence.
  MacBlockerPanel/
    macOS launchable panel executable for local testing.
Tests/
  MacBlockerCoreTests/
    Unit tests for schedules, evaluator, import, and custom JS decisions.
XcodeScaffold/
  Source and entitlement templates for the real iOS app and Screen Time
  extensions.
```

## See The Real UI Now

Fastest way to confirm pixel fidelity — open the bundled page directly:

```bash
cd /Users/fengyue.john.zhu/Desktop/blockerGroup/macosBlocker
open Sources/MacBlockerWebUI/WebAssets/popup.html
```

The `chrome-shim.js` makes the editor fully usable in a plain browser (state
saved to `localStorage`). This is the exact UI that renders inside the app.

To run the native app shell (Editor tab = web UI, Status tab = native policy
panel), open the package in Xcode and run the `MacBlockerPanel` scheme on
**My Mac**:

```bash
open Package.swift
```

The panel installs an `NSApplicationDelegate` that calls
`NSApp.setActivationPolicy(.regular)` + `activate(...)` at launch, so the
window appears and the app gets a Dock icon even though it is a SwiftPM
executable (without that, macOS runs it as a windowless background agent).

Native host state (the editor's chrome.storage snapshot) is persisted in the
App Group container on a real device, falling back to Application Support when
no entitlement is present (panel/tests):

```text
<AppGroup container>/macosBlocker/web-store.json   (real app + extensions)
~/Library/Application Support/macosBlocker/web-store.json   (panel / tests)
```

## App Store / Real iOS Enforcement Architecture

Because the `DeviceActivityMonitor` extension runs under a strict (~6 MB)
memory budget, it must not run JavaScript. The design splits responsibilities:

```text
Main app (can run JS)                 App Group (shared files)            Extensions (no JS)
--------------------------            ----------------------------        -----------------------------
editor saves chrome.storage  ───────► web-store.json
BlockerWebStore.rebuild...   ───────► enforcement-plan.json  ◄─────────── DeviceActivityMonitor reads
FamilyActivityPicker tokens  ───────► screentime-tokens.json ◄─────────── ScreenTimeEnforcer resolves
app approves snoozes         ◄─────── snooze-requests.json   ◄─────────── ShieldAction writes
app writes snooze windows    ───────► usage-snapshot.json    ◄─────────── DeviceActivityMonitor honors
picker assigns app targets   ───────► group-targets.json     ──┐
                                                               └─► merged into enforcement-plan.json
```

### Snooze loop (fully wired)

1. User taps the shield's **Request Snooze** button → `ShieldActionExtension`
   appends a `SnoozeRequest` to `snooze-requests.json` and keeps the shield up.
2. Next time the app is active, `ScreenTimeRefresher` runs
   `SnoozeApprovalService.process(...)`, which approves the request against the
   group's snooze rules (allowSnooze, confirmations, cooldown, activation
   delay) and writes the resulting snooze window into `usage-snapshot.json`.
3. The app clears the request queue and re-applies shields for active,
   non-snoozed groups.
4. `DeviceActivityMonitorExtension` checks `usage-snapshot.json` and skips
   shielding any group whose snooze is currently `.active`.

### App / category targets (what the web editor can't express)

The web UI only knows web domains. Real app/category blocking uses
`ScreenTimeSelectionView`: the user picks via `FamilyActivityPicker`, the tokens
are saved to `screentime-tokens.json`, and the generated `BlockTarget`s are
assigned to a chosen group in `group-targets.json`. The plan builder merges
those into each group by ID, so app/category shields flow through the same
enforcement pipeline as domains.

Shared code lives in the package:

- `MacBlockerCore`
  - `AppGroup` — the shared identifier + container resolution.
  - `SharedAppGroupStore` — reads/writes the JSON files above.
  - `EnforcementPlan` / `EnforcementPlanBuilder` — the JavaScript-free,
    serializable shield plan the monitor extension applies.
  - `SnoozeRequest` — shield-tap requests for the app to approve.
- `MacBlockerScreenTime` (iOS-only code, compiled out on macOS)
  - `ScreenTimeAuthorization` — `requestAuthorization(for: .individual)`.
  - `ScreenTimeTokenStore` / `ScreenTimeTokenSet` — persists FamilyControls
    tokens keyed to `BlockTarget` IDs; builds targets from a picker selection.
  - `ScreenTimeEnforcer` — resolves plan target IDs into tokens and sets
    `ManagedSettingsStore.shield.{applications,applicationCategories,webDomains}`.
  - `TokenBackedTargetProvider` — backs `ScreenTimePolicyAdapter` authorization.

Extension implementations are filled in under `XcodeScaffold/`:

- `macosBlockerApp/macosBlockerApp.swift` — sets `AppGroup.identifier` at launch and
  syncs DeviceActivity monitoring from the plan.
- `macosBlockerApp/ScreenTimeSelectionView.swift` — picker → token persistence.
- `macosBlockerApp/ScreenTimeScheduler.swift` — `DeviceActivityCenter` scheduling
  (activity name == group ID).
- `macosBlockerApp/ScreenTimeRefresher.swift` — foreground refresh: approves
  snoozes, re-syncs schedules, applies active shields.
- `macosBlockerDeviceActivityMonitor/...` — reads the plan + tokens and shields.
- `macosBlockerShieldAction/...` — records snooze requests to the App Group.
- `Shared/AppGroupIdentifier.swift` — single source of truth for the group ID;
  add to every target.

> The hard gate for App Store distribution is Apple's **Family Controls
> (Distribution)** entitlement. You can build and test on your own devices with
> the development entitlement, but publishing requires Apple's approval of a
> separate request form. Frame the app as a self-control / focus tool for the
> user's own device.

## Platform Strategy

### iPhone and iPad

Use:

- `FamilyControls` for user-authorized app/category/domain selection.
- `ManagedSettings` for shields.
- `DeviceActivity` for schedule and usage threshold callbacks.
- Shield Configuration and Shield Action extensions for block UI and snooze
  entry points.

Do not use:

- private APIs
- arbitrary overlays above other apps
- forced app termination
- reading or clicking another app's UI

### Mac

Use:

- the shared policy engine
- a floating status window
- Accessibility permission for app/window enforcement
- optional Screen Recording or Automation later, if the user explicitly opts in

Mac enforcement is best effort. Some apps expose richer Accessibility metadata
than others.

## Custom JavaScript Rules

The port preserves the event-driven shape:

```js
(event, helpers) => {
  event.registerUsageThresholdReached("short-video-limit", (ev, h) => {
    ev.block("Daily limit reached");
    ev.setShieldMessage("Go back to work");
  });

  event.registerScheduleChanged("work-hours", (ev, h) => {
    helpers.overlay.show({
      title: "Focus time",
      message: "Social apps are blocked during work hours",
      timerId: "work-hours"
    });
  });
}
```

The JavaScript runtime emits structured policy decisions. Swift validates those
decisions against user-authorized targets before applying shields or Mac
controls.

### What the custom-rule engine actually supports

The engine lives in `Sources/MacBlockerCore/Resources/custom-rule-runtime.js`
and runs in JavaScriptCore. It implements the iOS-portable slice of the
original `helpers.js` contract:

- **Events** — all 11 browser event types (`tickEvent`, `openWebEvent`,
  `closeWebEvent`, `switchWebEvent`, `switchDomainEvent`, `webChangedEvent`,
  `timerEnded`, `snoozePress`, `panelEvent`, `localFileEvent`,
  `pageHeartbeatEvent`) plus iOS ones (`usageThresholdReached`,
  `scheduleChanged`, `shieldAction`), with typed registrars, priorities,
  `intervalMs` throttling, `post()`, and unregister/counts.
- **`ev`** — `preventDefault`, `stopPropagation`, `setResult`/`getResult`,
  `post`, `setRedirectLink`/`getRedirectLink`, `block`, `allow`,
  `setShieldMessage`, plus `time` fields.
- **Helpers (functional)** — `getLogHelper`, `getDomainHelper`/
  `getDomainUtility` (host/path/query parsing + platform URL classifiers),
  `getTimerHelper`, `getPersistenceHelper`, `getStorageHelper`,
  `getRedirectionHelper`, `getPlatformHelper` (URL classifiers).
- **Helpers (inert on iOS)** — `getDOMHelper`, `getNavigationHelper`,
  `getTabHelper`, `getLocalFolderHelper`, `getPanelHelper`. These exist so
  existing rules/templates load and run, but each call is a no-op that emits a
  single "not available on iOS" log entry. They depend on manipulating a web
  page / browser tabs, which has no equivalent when shielding native apps.

So a rule that limits time, classifies URLs/platforms, persists counters, and
blocks/redirects works natively. A rule whose only effect is hiding DOM
elements or scrolling a feed cannot — that capability does not exist outside a
browser, by iOS design.

## Build The Real iOS App (one command)

The app + all three Screen Time extensions are generated from a single
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec:

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

See `XcodeProject/README.md` for the target layout and the required
bundle-ID / App-Group / signing edits. The manual Xcode steps below are the
equivalent if you prefer to wire the project by hand.

## Xcode Targets For Real iPhone/iPad Blocking

This Swift package is the shared core plus a runnable Mac panel. Real iOS
shielding still needs signed Xcode app-extension targets:

- `macosBlockerApp`: SwiftUI editor for iPhone/iPad.
- `macosBlockerDeviceActivityMonitor`: `DeviceActivityMonitor` extension.
- `macosBlockerShieldConfiguration`: Shield text/icon/button configuration.
- `macosBlockerShieldAction`: shield button handling and snooze entry.
- `macBlockerApp`: SwiftUI/AppKit app with a floating status window and
  Accessibility permission onboarding.

Starter source files and entitlement templates live in:

```text
XcodeScaffold/
```

In Xcode:

1. Create an iOS app project named `macosBlocker`.
2. Add this Swift package as a local package dependency.
3. Link the app target with `MacBlockerAppFeature`, `MacBlockerWebUI`,
   `MacBlockerCore`, and `MacBlockerScreenTime`. `MacBlockerWebUI` bundles the
   web editor assets automatically via SwiftPM resources.
4. Copy `XcodeScaffold/macosBlockerApp` into the app target.
5. Add Device Activity Monitor, Shield Configuration, and Shield Action
   extension targets.
6. Copy the matching `XcodeScaffold/macosBlocker*` extension files into those
   targets.
7. Add `XcodeScaffold/Shared/AppGroupIdentifier.swift` to the app target AND
   every extension target, and set its value to your real App Group.
8. Apply the entitlements from `XcodeScaffold/Entitlements`, replacing
   `group.com.example.macosBlocker` with that same App Group identifier.
9. Enable Family Controls, App Groups, and required Screen Time capabilities
   for the app and extensions.

Real Screen Time shielding must be tested on a signed app target, preferably on
a physical iPhone or iPad.

## Verification

Run from this folder:

```bash
swift test
```

Build the runnable panel without launching it:

```bash
swift build --product MacBlockerPanel
```
