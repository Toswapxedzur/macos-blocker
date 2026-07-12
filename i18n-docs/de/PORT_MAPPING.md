# Mac Vault-Implementierungskarte

Diese Karte wird aus dem aktuellen Quellbaum abgeleitet. Es handelt sich um eine Navigationshilfe und nicht um den Anspruch, dass es für jede Browserfunktion ein natives Äquivalent gibt.

| Sorge | Aktuelle macOS-Implementierung |
| --- | --- |
| Gruppen- und Richtlinienmodell | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` und `Schedule.swift` |
| Web-Editor | `Sources/MacBlockerWebUI/` und `WebAssets/` innerhalb eines `WKWebView` |
| Editor-Persistenz | `BlockerWebStore.swift` und die WebView-Brücke |
| Natives App-Inventar | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` und `MacAppInventoryJSON.swift` |
| Durchsetzungsplan | `Sources/MacBlockerCore/EnforcementPlan.swift` und `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Native Steueradapter | `Sources/MacBlockerMacControl/` und `Sources/MacBlockerScreenTime/` |
| Benutzerdefinierte Regeln | `CustomJavaScriptPolicyRuntime.swift` plus die JavaScript-Laufzeitressourcen |
| Brückennabe | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| App-Lebenszyklus | `BlockerAppDelegate.swift`, `BlockerMainView.swift` und `MacBlockerPanelApp.swift` |

## Produktgrenze

Der WebView-Editor teilt ein gruppenorientiertes Benutzermodell mit der Vault-Erweiterung, aber der Host entscheidet, was eine Aktion bewirken kann. Nur-Browser-Aktionen werden nicht stillschweigend als native Durchsetzung behandelt. Die native Ausführung hängt von der Berechtigung, dem Ziel und dem Adapter ab, die auf dem Mac verfügbar sind.

## Vermögenswerte auf dem aktuellen Stand halten

Die englische Bedienungsanleitung lautet `WebAssets/manual/en.md`; Übersetzte Handbücher teilen sich dasselbe Verzeichnis mit ihrem Gebietsschemacode. Übersetzungskataloge verbleiben in `WebAssets/translation/`, während übersetzte Kopien der verbleibenden gepflegten Dokumente unter `i18n-docs/<locale>/` liegen.

Wenn Sie eine Editorzeichenfolge ändern, aktualisieren Sie zuerst den englischen Schlüssel, aktualisieren Sie dann die Gebietsschemakataloge und führen Sie die gemeinsame Übersetzungsprüfung durch.
