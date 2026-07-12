# Adamancia Vault-Datenschutzrichtlinie

Letzte Aktualisierung: 7. Juli 2026

Adamancia Vault ist eine Fokus- und Blockierungs-App. Diese Richtlinie beschreibt die Veröffentlichung der macOS-App.

## Zusammenfassung

Adamancia Vault ist so konzipiert, dass Blockierungsregeln und Nutzungsstatus standardmäßig lokal auf Ihrem Mac bleiben. Die App verkauft keine personenbezogenen Daten, zeigt keine Werbung an und gibt keine personenbezogenen Daten an Datenbroker weiter.

## Daten lokal gespeichert

Die App speichert möglicherweise die folgenden lokalen Daten auf Ihrem Mac:

- Blockieren von Gruppen, Zeitplänen, Timern, Einfrier-/Schlummerstatus und App-Einstellungen.
- Lokaler Web-Editor-Speicher, gespiegelt von der mitgelieferten Weboberfläche.
– Lokaler Bridge-/Link-Status, wenn Sie die macOS-App mit Browsererweiterungen verbinden.
– Richtliniendateien zur App-Durchsetzung, die von der macOS-Blockierungs-Engine verwendet werden.
– App-Gruppen-Containerdaten, wenn ein App Store-Build oder Erweiterungsbuild eine App-Gruppe verwendet.

Bekannte lokale Pfade sind in `RELEASE.md` und im Deinstallationsskript dokumentiert.

## Netzwerknutzung

Die App öffnet möglicherweise einen lokalen Netzwerk-Listener für ihre Web-App-Bridge, sodass Browsererweiterungen eine Verbindung zur Mac-App herstellen können. Die App kann auch Netzwerkanfragen stellen, wenn eine gebündelte Funktion mit Adamancia-Diensten kommunizieren muss, beispielsweise optionale Konto- oder Synchronisierungsfunktionen.

## Analysen und Anzeigen

Die macOS-App enthält keine Werbe-SDKs von Drittanbietern. Es sollten keine Analysen gesendet werden, es sei denn, eine Funktion gibt ausdrücklich an, dass sie einen Onlinedienst nutzt.

## Optionale Konten und Synchronisierung

Wenn Konto- oder Synchronisierungsfunktionen in einer Version aktiviert sind, senden diese Funktionen möglicherweise die Mindestdaten, die zur Bereitstellung dieser Funktion erforderlich sind, z. B. Kontoidentität und Synchronisierungsnutzlasten. Für Downloads und lokale Sperrungen darf kein Konto erforderlich sein.

## Berechtigungen

Abhängig vom Kanal und den aktivierten Funktionen fragt Adamancia Vault macOS möglicherweise nach Berechtigungen wie Barrierefreiheit, Netzwerkzugriff, Registrierung von Anmeldeelementen oder App-Gruppenzugriff. Diese Berechtigungen werden verwendet, um Blockierungs-, App-Start-, Bridge- und Persistenzfunktionen bereitzustellen.

## Deinstallation

Die DMG enthält `uninstall.command`. Es fragt nach einer Bestätigung, beendet die App, wenn sie ausgeführt wird, hebt die Registrierung des Anmeldeelements der App auf, wenn möglich, entfernt `/Applications/AdamanciaVault.app` und entfernt optional nur bekannte Dateien, die von dieser App erstellt wurden.

## Kontakt

Bei Fragen zum Datenschutz öffnen Sie ein Problem im öffentlichen GitHub-Repository oder nutzen Sie den auf der Adamancia Vault-Website veröffentlichten Kontaktkanal.
