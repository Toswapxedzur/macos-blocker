# Mac Vault-implementatiekaart

Deze kaart is afgeleid van de huidige bronboom. Het is een navigatiehulpmiddel, en niet een claim dat elke browsermogelijkheid een native equivalent heeft.

| Zorg | Huidige macOS-implementatie |
| --- | --- |
| Groeps- en beleidsmodel | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` en `Schedule.swift` |
| Webredacteur | `Sources/MacBlockerWebUI/` en `WebAssets/` in een `WKWebView` |
| Doorzettingsvermogen van de redactie | `BlockerWebStore.swift` en de WebView-bridge |
| Native app-inventaris | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` en `MacAppInventoryJSON.swift` |
| Handhavingsplan | `Sources/MacBlockerCore/EnforcementPlan.swift` en `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Native besturingsadapters | `Sources/MacBlockerMacControl/` en `Sources/MacBlockerScreenTime/` |
| Aangepaste regels | `CustomJavaScriptPolicyRuntime.swift` plus de JavaScript-runtimebronnen |
| Brughub | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| App-levenscyclus | `BlockerAppDelegate.swift`, `BlockerMainView.swift` en `MacBlockerPanelApp.swift` |

## Productgrens

De WebView-editor deelt een groepsgericht gebruikersmodel met Vault-extensie, maar de host bepaalt wat een actie kan doen. Alleen-browseracties worden niet stilzwijgend behandeld als native handhaving. Native uitvoering is afhankelijk van de toestemming, het doel en de adapter die beschikbaar zijn op de Mac.

## Activa actueel houden

De Engelse handleiding is `WebAssets/manual/en.md`; vertaalde handleidingen delen dezelfde map met hun landcode. Vertaalcatalogi blijven in `WebAssets/translation/`, terwijl vertaalde exemplaren van de overige bijgehouden documenten onder `i18n-docs/<locale>/` staan.

Wanneer u een editortekenreeks wijzigt, moet u eerst de Engelse sleutel bijwerken, vervolgens de localecatalogi bijwerken en de gedeelde vertalingsaudit uitvoeren.
