# Mac Vault Xcode-Projekt

`project.yml` ist die eingecheckte XcodeGen-Spezifikation für die macOS- und iOS-Ziele, die das gemeinsam genutzte Swift-Paket verwenden.

## Generieren Sie das Projekt

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Nach Änderung von `project.yml`, Zielen, Berechtigungen oder Quellmitgliedschaft neu generieren. Verwenden Sie keine generierten Projektdateien als kanonische Konfiguration.

## Aktuelle Zielfamilien

- `AdamanciaVaultMac` ist das macOS-Anwendungsziel, das von `MacBlockerAppFeature` unterstützt wird.
- `macosBlocker` ist das iOS-Anwendungsziel.
– Das iOS-Projekt umfasst die Erweiterungen „Device Activity“, „Shield Configuration“ und „Shield Action“.

Die aktuellen Bezeichner, Bereitstellungsziele, Versionsfelder und Funktionen werden in `project.yml` und den referenzierten Berechtigungsdateien definiert. Überprüfen Sie sie vor der Verteilung in der Signaturumgebung.

## Signierung und Funktionen

Verwenden Sie ein Team und Bundle-IDs, die zum Verteilungskonto gehören. Bestätigen Sie die erforderlichen Fähigkeiten für das Ziel, das Sie erstellen. Fügen Sie diesem Repository niemals Signaturgeheimnisse, Bereitstellungsprofile oder Kontoanmeldeinformationen hinzu.

## Zuerst testen

Führen Sie die freigegebenen Pakettests aus, bevor Sie ein Archiv erstellen:

```bash
cd ..
swift test
```
