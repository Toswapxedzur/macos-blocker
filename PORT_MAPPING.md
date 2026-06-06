# Port Mapping

This document maps `customBlocker` browser-extension features to the native
`macosBlocker` implementation.

## Editor UI: Ported Verbatim

The editor front end is reused 1:1, not redesigned. `popup.html`, `popup.css`,
`popup.js`, `translations.js`, `popup-markdown.js`, every `templates/*.js`
preset, every `translation/*.json` locale, and every `manual/*.md` page are
copied into `Sources/MacBlockerWebUI/WebAssets/` and run unchanged inside a
`WKWebView`. A single added `chrome-shim.js` maps the Chrome extension API
surface the editor uses (`storage`, `runtime`, `permissions`, `i18n`) onto
`localStorage` plus a native `cbBridge` message handler. So every visual detail,
modal, template, language, and the instruction manual are identical to the
extension.

| `customBlocker` feature | iPhone/iPad port | Mac port |
| --- | --- | --- |
| Default URL block group | Screen Time web-domain shield | Screen Time/domain adapter or browser automation |
| Platform groups | User-selected app/category/domain targets | App bundle IDs, domains, Accessibility metadata |
| Immediate block | `ManagedSettingsStore` shield | Shield, hide, terminate, or switch away |
| Timed block | `DeviceActivity` threshold plus shared usage state | Shared usage state plus Mac adapter enforcement |
| Fixed countdown | Shared timer state plus shield when expired | Shared timer state plus floating status window |
| Schedule | `DeviceActivitySchedule` request model | Shared schedule evaluator |
| Freeze | Shared model and editor lockout | Shared model and editor lockout |
| Strict freeze | Shared model and editor lockout | Shared model and editor lockout |
| Snooze | Shared model plus Shield Action extension entry | Shared model plus floating window/menu entry |
| Editor popup UI | Verbatim `popup.html/.css/.js` in WKWebView | Same, verbatim in WKWebView |
| Translations (20 locales) | Verbatim `translation/*.json` | Verbatim `translation/*.json` |
| Instruction manual (20 locales) | Verbatim `manual/*.md` + `popup-markdown.js` | Same |
| Rule templates (10 files) | Verbatim `templates/*.js` | Verbatim `templates/*.js` |
| `chrome.storage.local` | `chrome-shim.js` -> `cbBridge` -> `web-store.json` | Same |
| In-page overlay | Shield text, app status screen, Live Activity later | Floating status window |
| Debug toasts | In-app log/status surface | In-app log/status surface |
| DOM/feed hiding | Not available | Optional Accessibility/Screen Recording best effort |
| Skip to next video | Not available | Optional Accessibility automation best effort |
| Custom JS rules | Policy decisions over authorized targets (full event + helper engine) | Policy decisions plus Mac enforcement modes |
| Custom-rule helpers | Functional: log, domain/platform classifiers, timers, persistence, storage, redirect | Same |
| Custom-rule DOM/nav/tab/panel/localFolder helpers | Inert no-ops that log "unsupported on iOS" (browser-only) | Same |
| Offscreen sandbox | JavaScriptCore engine in `custom-rule-runtime.js` | Same runtime |
| Chrome storage | App Group storage in app targets | App Group/shared app container |
| `declarativeNetRequest` | Screen Time shielding | Screen Time/domain/automation adapter |

## Key Rule

The port keeps intent, not browser internals. A JavaScript rule may say
`ev.block("reason")`, `ev.allow()`, or `helpers.overlay.show(...)`; the platform
adapter decides how to express that action safely.

## iOS Boundary

iOS and iPadOS cannot grant arbitrary app UI manipulation permission. Even with
all available public permissions, the app can only manage selected apps,
categories, and domains through Screen Time APIs.

## Mac Boundary

macOS can do more after the user grants permissions. The current Mac adapter
models Accessibility-gated enforcement modes:

- `shieldOnly`
- `hideApplication`
- `terminateApplication`
- `switchAway`

Future Mac-only modules can add Screen Recording, OCR, browser automation, and
Network Extension support without changing the shared policy engine.
