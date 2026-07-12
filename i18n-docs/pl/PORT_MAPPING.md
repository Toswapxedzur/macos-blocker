# Mapa implementacji Mac Vault

Ta mapa pochodzi z bieżącego drzewa źródłowego. Jest to pomoc w nawigacji, a nie twierdzenie, że każda funkcja przeglądarki ma natywny odpowiednik.

| Obawa | Obecna implementacja macOS |
| --- | --- |
| Grupa i model polityki | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` i `Schedule.swift` |
| Edytor stron internetowych | `Sources/MacBlockerWebUI/` i `WebAssets/` wewnątrz `WKWebView` |
| Wytrwałość redaktora | `BlockerWebStore.swift` i mostek WebView |
| Spis aplikacji natywnych | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` i `MacAppInventoryJSON.swift` |
| Plan wykonania | `Sources/MacBlockerCore/EnforcementPlan.swift` i `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Natywne adaptery kontrolne | `Sources/MacBlockerMacControl/` i `Sources/MacBlockerScreenTime/` |
| Zasady niestandardowe | `CustomJavaScriptPolicyRuntime.swift` oraz zasoby środowiska wykonawczego JavaScript |
| Węzeł mostowy | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Cykl życia aplikacji | `BlockerAppDelegate.swift`, `BlockerMainView.swift` i `MacBlockerPanelApp.swift` |

## Granica produktu

Edytor WebView współdzieli model użytkownika zorientowany na grupę z rozszerzeniem Vault, ale to host decyduje, co może zrobić dana akcja. Działania wykonywane wyłącznie w przeglądarce nie są dyskretnie traktowane jako wymuszanie natywne. Wykonanie natywne zależy od uprawnień, celu i adaptera dostępnych na komputerze Mac.

## Aktualizowanie zasobów

Instrukcja obsługi w języku angielskim to `WebAssets/manual/en.md`; przetłumaczone podręczniki mają ten sam katalog ze swoim kodem regionalnym. Katalogi tłumaczeń pozostają w `WebAssets/translation/`, natomiast przetłumaczone kopie pozostałych utrzymywanych dokumentów znajdują się w `i18n-docs/<locale>/`.

Zmieniając ciąg edytora, najpierw zaktualizuj jego klucz angielski, następnie zaktualizuj katalogi ustawień regionalnych i przeprowadź kontrolę tłumaczenia udostępnionego.
