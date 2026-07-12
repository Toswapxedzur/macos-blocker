# Mac Vault

Mac Vault ist das native macOS-Mitglied der Vault-Produktfamilie. Es kombiniert eine Swift-Richtlinien-Engine, einen WebView-Editor, native Anwendungsinventur- und Durchsetzungsadapter, Unterstützung für benutzerdefinierte Regeln und einen lokalen Web-App-Bridge-Hub.

Der aktuelle Code ist die Quelle der Wahrheit. Die englische In-App-Referenz lautet [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Was ist implementiert?

– Standardgruppen für ausgewählte macOS-Anwendungen und benutzerdefinierte Gruppen für erweiterte Richtlinienregeln.
- Sofort-, Zuschuss- und Countdown-Blockierungsmodi.
- Zeitpläne, Freeze-Modi, Snooze-Flows, Import/Export und persistenter Gruppenstatus.
- Anwendungsinventar, Status der Gerätesteuerungsberechtigungen, native Durchsetzungsadapter und eine schwebende Statusoberfläche.
– Eine kontrollierte JavaScript-Richtlinienlaufzeit mit Protokollierung und Syntaxprüfung.
– Ein Loopback-WebSocket-Bridge-Hub für explizit verknüpfte kompatible Gruppen.
– Ein WebView-Editor mit demselben Kerngruppenmodell wie die Vault-Produktfamilie.

## Entwicklung

Führen Sie die Swift-Pakettests aus:

```bash
swift test
```

Das Paket umfasst Kernrichtlinien-, Zeitplan-, benutzerdefinierte Regel-, Bridge-, Import- und macOS-Steuerungstests.

## Xcode-Projekt

Das optionale Xcode-Projekt wird aus [XcodeProject/project.yml](XcodeProject/project.yml) generiert:

```bash
cd XcodeProject
./generate.sh
```

Lesen Sie [XcodeProject/README.md](XcodeProject/README.md), bevor Sie Signierungs- oder Verteilungsziele konfigurieren.

## Dokumentationsrichtlinie

Englische Dokumente bleiben kanonisch. Die Editor-Benutzeroberfläche verfügt über vollständige Gebietsschemakataloge, übersetzte Handbücher direkt unter `WebAssets/manual/en.md` und übersetzte Kopien der übrigen gepflegten Dokumente befinden sich unter `i18n-docs/<locale>/`.

Rechtliche Bestimmungen und Datenschutzhinweise bleiben separate Rechtsdokumente; Diese README-Datei ersetzt sie nicht.
