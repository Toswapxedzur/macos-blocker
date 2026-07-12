# Carte d'implémentation de Mac Vault

Cette carte est dérivée de l'arborescence source actuelle. Il s'agit d'une aide à la navigation et non d'une affirmation selon laquelle chaque fonctionnalité du navigateur a un équivalent natif.

| Préoccupation | Implémentation actuelle de macOS |
| --- | --- |
| Modèle de groupe et de politique | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` et `Schedule.swift` |
| Éditeur Web | `Sources/MacBlockerWebUI/` et `WebAssets/` à l'intérieur d'un `WKWebView` |
| Persistance de l'éditeur | `BlockerWebStore.swift` et le pont WebView |
| Inventaire d'applications natives | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` et `MacAppInventoryJSON.swift` |
| Plan d'exécution | `Sources/MacBlockerCore/EnforcementPlan.swift` et `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Adaptateurs de contrôle natifs | `Sources/MacBlockerMacControl/` et `Sources/MacBlockerScreenTime/` |
| Règles personnalisées | `CustomJavaScriptPolicyRuntime.swift` ainsi que les ressources d'exécution JavaScript |
| Moyeu du pont | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Cycle de vie des applications | `BlockerAppDelegate.swift`, `BlockerMainView.swift` et `MacBlockerPanelApp.swift` |

## Limite du produit

L'éditeur WebView partage un modèle utilisateur orienté groupe avec l'extension Vault, mais l'hôte décide de ce qu'une action peut faire. Les actions du navigateur uniquement ne sont pas traitées silencieusement comme une application native. L'exécution native dépend de l'autorisation, de la cible et de l'adaptateur disponibles sur le Mac.

## Garder les actifs à jour

Le manuel d'instructions en anglais est `WebAssets/manual/en.md` ; les manuels traduits partagent le même répertoire avec leur code local. Les catalogues de traduction restent sous `WebAssets/translation/`, tandis que les copies traduites des documents conservés restants se trouvent sous `i18n-docs/<locale>/`.

Lorsque vous modifiez une chaîne d'éditeur, mettez d'abord à jour sa clé anglaise, puis mettez à jour les catalogues de paramètres régionaux et exécutez l'audit de traduction partagé.
