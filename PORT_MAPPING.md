# Mac Vault implementation map

This map is derived from the current source tree. It is a navigation aid, not a claim that every browser capability has a native equivalent.

| Concern | Current macOS implementation |
| --- | --- |
| Group and policy model | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, and `Schedule.swift` |
| Web editor | `Sources/MacBlockerWebUI/` and `WebAssets/` inside a `WKWebView` |
| Editor persistence | `BlockerWebStore.swift` and the WebView bridge |
| Native app inventory | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` and `MacAppInventoryJSON.swift` |
| Enforcement plan | `Sources/MacBlockerCore/EnforcementPlan.swift` and `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Native control adapters | `Sources/MacBlockerMacControl/` and `Sources/MacBlockerScreenTime/` |
| Custom rules | `CustomJavaScriptPolicyRuntime.swift` plus the JavaScript runtime resources |
| Bridge hub | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| App lifecycle | `BlockerAppDelegate.swift`, `BlockerMainView.swift`, and `MacBlockerPanelApp.swift` |

## Product boundary

The WebView editor shares a group-oriented user model with Vault extension, but the host decides what an action can do. Browser-only actions are not silently treated as native enforcement. Native execution depends on the permission, target, and adapter available on the Mac.

## Keeping assets current

The English instruction manual is `WebAssets/manual/en.md`; translated manuals share the same directory with their locale code. Translation catalogs remain in `WebAssets/translation/`, while translated copies of the remaining maintained documents are under `i18n-docs/<locale>/`.

When changing an editor string, update its English key first, then update the locale catalogs and run the shared translation audit.
