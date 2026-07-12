# Anleitung zur Mac Vault-Veröffentlichung

Diese Anleitung folgt den eingecheckten Build-Skripten. Es enthält bewusst keine persönliche Signaturidentität, kein Beglaubigungsprofil, kein Passwort oder keine Kontodaten.

## Vor einer Veröffentlichung

1. Führen Sie `swift test` im Repository-Stammverzeichnis aus.
2. Legen Sie die Release-Version und die Build-Nummer in der kontrollierten Projekt-/Build-Konfiguration fest.
3. Überprüfen Sie das englische Handbuch, die lokalisierten Handbücher und die Übersetzungsprüfung des Editors.
4. Überprüfen Sie den Release-Zweig, das Tag und die Meilensteinrichtlinie, bevor Sie ein Artefakt veröffentlichen.

## Website-DMG-Pipeline

Die Skripte befinden sich in `scripts/release/`. Ihre Standardwerte können mit Umgebungsvariablen überschrieben werden, einschließlich `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` und `BUILD_NUMBER`.

Führen Sie die gesamte Pipeline nur auf einem konfigurierten Signiercomputer aus:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

Die Pipeline besteht aus den vorhandenen Build-, Signierungs-, DMG-, Beglaubigungs- und Verifizierungsskripts. Behandeln Sie die Ausgabe als Release-Kandidat, bis der Überprüfungsschritt erfolgreich ist.

## Xcode-Verteilungsziele

Generieren Sie das Xcode-Projekt aus `XcodeProject/project.yml`, konfigurieren Sie das entsprechende Signaturteam und die entsprechenden Funktionen in der genehmigten Umgebung und archivieren Sie dann das relevante Ziel. Übertragen Sie keine generierten Anmeldeinformationen, Bereitstellungsdateien oder Beglaubigungsprofile.

## Nach einer Veröffentlichung

1. Erstellen Sie das unveränderliche Versions-Tag und den permanenten Release-Zweig gemäß der Release-Management-Richtlinie.
2. Veröffentlichen Sie das Release-Artefakt und die Prüfsumme.
3. Aktualisieren Sie die öffentliche Release-Registrierung erst, nachdem die Artefakt-URL endgültig ist.
4. Halten Sie die Versionshinweise in englischer Sprache bereit, es sei denn, es wird ein überprüfter lokalisierter Versionshinweis bereitgestellt.
