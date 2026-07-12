# Mappa di implementazione di Mac Vault

Questa mappa è derivata dall'albero dei sorgenti corrente. Si tratta di un aiuto alla navigazione, non di un'affermazione secondo cui ogni funzionalità del browser ha un equivalente nativo.

| Preoccupazione | Attuale implementazione di macOS |
| --- | --- |
| Gruppo e modello politico | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` e `Schedule.swift` |
| Redattore web | `Sources/MacBlockerWebUI/` e `WebAssets/` all'interno di un `WKWebView` |
| Persistenza dell'editor | `BlockerWebStore.swift` e il bridge WebView |
| Inventario delle app native | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` e `MacAppInventoryJSON.swift` |
| Piano di esecuzione | `Sources/MacBlockerCore/EnforcementPlan.swift` e `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Adattatori di controllo nativo | `Sources/MacBlockerMacControl/` e `Sources/MacBlockerScreenTime/` |
| Regole personalizzate | `CustomJavaScriptPolicyRuntime.swift` più le risorse runtime JavaScript |
| Mozzo del ponte | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Ciclo di vita dell'app | `BlockerAppDelegate.swift`, `BlockerMainView.swift` e `MacBlockerPanelApp.swift` |

## Confine del prodotto

L'editor WebView condivide un modello utente orientato al gruppo con l'estensione Vault, ma l'host decide cosa può fare un'azione. Le azioni eseguite solo sul browser non vengono trattate automaticamente come applicazione nativa. L'esecuzione nativa dipende dall'autorizzazione, dalla destinazione e dall'adattatore disponibili sul Mac.

## Mantenere le risorse aggiornate

Il manuale di istruzioni in inglese è `WebAssets/manual/en.md`; i manuali tradotti condividono la stessa directory con il loro codice locale. I cataloghi di traduzione rimangono in `WebAssets/translation/`, mentre le copie tradotte dei restanti documenti conservati si trovano in `i18n-docs/<locale>/`.

Quando si modifica una stringa dell'editor, aggiornare prima la chiave inglese, quindi aggiornare i cataloghi locali ed eseguire il controllo della traduzione condivisa.
