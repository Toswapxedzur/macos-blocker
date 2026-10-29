# Mac Vault-Benutzerhandbuch

Mac Vault hat drei Seiten: **Vault** blockiert native Apps, **Content tagging** versieht unterstützte Browserinhalte mit Tags und **Activity** zeigt aufgezeichnete Nutzung. Die Browsererweiterung sammelt unterstützte Inhalte und setzt Browserblockierungen um. Installieren und verbinden Sie sie in Ihrem Browser.

## Schnellstart

1. Fügen Sie in **Vault** eine Blocking-Gruppe und ein Apps-Ziel hinzu und wählen Sie Apps mit dem + Auswahlfeld.
2. Wählen Sie das Blockierverhalten und aktivieren Sie die Gruppe.
3. Erstellen Sie unter **Content tagging** eine Gruppe, wählen Sie Plattformen und fügen Sie Tags mit Beschreibungen hinzu.
4. ## Einstellungen

Wählen Sie unter Einstellungen → **AI connections** ChatGPT subscription, OpenAI API, Gemini API oder Grok API. Verbinden Sie das Konto oder geben Sie den Schlüssel ein und rufen Sie die Modelle ab. Wählen Sie dann Verbindung/Modell in der Gruppe, aktivieren Sie Tagging und setzen Sie die Gruppe fort.
5. Öffnen Sie unterstützte Inhalte im verbundenen Browser. Ein Tag-Filter in einer Browser-Blocking-Gruppe kann die Blockierung anhand der Tags steuern.

## Blocking-Gruppen

Eine **Blocking-Gruppe** setzt eine Blockierregel um. Eine **Content-tagging-Gruppe** weist Inhalte Tags zu und blockiert selbst nichts. Geben Sie der Gruppe einen Namen, wählen Sie Ziele unter **Applies to**, legen Sie Zeitplan oder Zeitkontingent fest und aktivieren Sie sie. Übliche Änderungen werden automatisch gespeichert. Ein Fehler bedeutet, dass die Änderung nicht angenommen wurde. Deaktivieren stoppt die Regel und behält die Konfiguration; **Delete group** löscht sie. Ziehen Sie Gruppen zum Sortieren. Mehrere Gruppen können dasselbe Ziel betreffen; Snooze einer Gruppe hebt eine andere Sperre nicht auf. **Export** kopiert die Konfiguration; **Import** ersetzt nach Bestätigung die ausgewählte Gruppe.

### Zeitkontingent und Zeitplan

**Block immediately** blockiert, wenn Gruppe und Zeitplan zutreffen. **Block when the time allowance is used** lässt Nutzung bis zum Verbrauch des Kontingents zu. Stellen Sie Kontingent in Minuten und Zurücksetzen in Stunden ein. Ein rollierendes Limit zählt im vorherigen Zeitfenster. Wählen Sie Wochentage und optionale lokale Zeitfenster, je Zeile eines, etwa **09:00-12:00**; eine leere Liste gilt den ganzen Tag. Übernachtzeiten auf Tage aufteilen.

**Pause blocking** setzt die Gruppenregel für die Pausendauer aus. **Add to the time allowance** fügt einer zeitbegrenzten Gruppe nutzbare Minuten hinzu; nur verbrauchte Zusatzzeit zählt als Snooze. Nicht genutzte Zeit verfällt beim nächsten Reset. **Activation delay**, **Cooldown** und **Required confirmations** bestimmen Verzögerung, Wartezeit und Anzahl der Bestätigungen. ### Freeze und PIN

**Freeze** verhindert normale Änderungen. Zum Auftauen sind zehn Bestätigungen im Abstand von fünf Sekunden sowie die Wartezeit und eine sechsstellige PIN erforderlich. **Wait before unfreezing** erlaubt 0–72 Stunden; 0 bedeutet keine Wartezeit. Im Freeze kann die Wartezeit verlängert und eine PIN ergänzt, aber die Bedingungen können nicht gelockert werden. Löschen beachtet ebenfalls Wartezeit und PIN.

### Snooze

Konfigurieren Sie Snooze pro Blocking-Gruppe. **Pause blocking** setzt die Regel für die Pausendauer aus. **Add to the time allowance** fügt einer zeitbegrenzten Gruppe nutzbare Minuten hinzu. Nur verbrauchte Zusatzzeit zählt als Snooze; nicht verbrauchte verfällt beim nächsten Reset. Bei rollierendem Limit verfällt sie nach einem Fenster oder bei aktiviertem Mitternachtsreset früher. **Activation delay** verzögert Snooze, während die Blockierung weiterläuft. **Cooldown** ist die Wartezeit nach dem Snooze. **Required confirmations** legt die Zahl der Bestätigungsschritte fest. Snooze ist bei eingefrorener Gruppe nur verfügbar, wenn es vor dem Freeze erlaubt wurde.

### Freeze und PIN

**Freeze** verhindert normale Änderungen. Zum Auftauen sind zehn Bestätigungen im Abstand von fünf Sekunden, die konfigurierte Wartezeit und eine sechsstellige PIN nötig. **Wait before unfreezing** erlaubt 0–72 Stunden; 0 bedeutet keine Wartezeit. Im Freeze kann die Wartezeit verlängert und eine PIN ergänzt werden, aber die Bedingungen können bis zum Auftauen nicht gelockert werden. Löschen beachtet die verbleibende Wartezeit und PIN.

### Verknüpfte Gruppen

Mit **Link** verbinden Sie ausdrücklich ausgewählte Gruppen anderer Vault-Programme. Name, unterstützte Einstellungen, Ziele, Nutzung und Freeze-Bedingungen werden geteilt. Jedes Programm bearbeitet nur unterstützte Zieltypen. **Unlink** trennt, behält Gruppen und Einstellungen aber bei. Ist ein Mitglied offline, verbinden Sie Mac Vault und den Browser erneut.

## Hilfe

Klicken Sie auf das kleine **i** neben einem Feld, um die Erklärung zu sehen. Klicken Sie außerhalb oder drücken Sie Escape, um sie zu schließen. Listen bleiben in scrollbaren Feldern; die Suche filtert sichtbare Einträge, ohne sie zu löschen. Benutzerdefinierte Regeln haben ein eigenes [Code-Handbuch](../code-manual/de.md) zu Editor, Aktivierung, Protokollen, Dateizugriff und API.

## Native Apps

Das **i** neben einem Feld zeigt Erklärungen; außerhalb klicken oder Escape schließt sie. Listen bleiben in scrollbaren Feldern, Suche filtert sichtbare Einträge ohne sie zu löschen. Für benutzerdefinierte Regeln siehe [Code-Handbuch](../code-manual/de.md) zu Editor, Aktivierung, Protokollen, Dateizugriff und API.

Im + Auswahlfeld eines Apps-Ziels wählen Sie installierte oder laufende Apps; öffnen Sie es erneut, um die Liste nach Start einer App aus einem anderen Ordner zu aktualisieren. **Block every app except these** erstellt eine Zulassungsliste. Mac Vault kann gewöhnliche Apple-Apps und ganze Browser blockieren; Mac Vault und Apps mit derselben Bundle-ID bleiben geschützt. Eine blockierte App wird zum Beenden aufgefordert; **Ask a blocked app to quit again every (minutes)** steuert Wiederholungen. Weiterleitungen, Seitenpausen und Feed-Ausblendung setzt die Browsererweiterung um.

## Content tagging

Eine Content-tagging-Gruppe versieht Inhalte ihrer Plattformen mit einem eigenen Tag-Baum und Modelleinstellungen. Jede Plattform gehört zu einer Gruppe; wählen Sie sie bei der Erstellung, später kann sie nicht geändert werden. Blocking-Zeitpläne und Filter steuern kein Tagging. Aktivieren Sie Tagging in Einstellungen und pausieren/fortsetzen Sie jede Gruppe separat. Wird die Feed-Aufzeichnung unter **Activity → Recording** ausgeschaltet, stoppt auch das Tagging.

### Tags und Modelleinstellungen

Erstellen Sie Tags, beschreiben Sie ihre Bedeutung und setzen oder entfernen Sie Eltern im Baum. Ziehen verschiebt einen Zweig. Klare Beschreibungen helfen dem Modell, ähnliche Tags zu unterscheiden. **Minimum confidence** setzt die Evidenzstufe von 1 bis 5; neue Gruppen beginnen bei 4 (starke Unterstützung). Es gibt keine Zielanzahl; ein Element kann ohne Tags bleiben. **Tagging instructions** speichert Gruppenpräferenzen. Änderungen werden automatisch gespeichert; jede Gruppe verwendet ausdrücklich eine Verbindung, ein Modell und einen Reasoning-Aufwand.

### AI connections

Unter **AI connections** stehen ChatGPT subscription, OpenAI API, Gemini API und Grok API. Das Abo verwendet Vault-Anmeldung und einen berechtigten Tarif. API-Schlüssel folgen Abrechnung und Limits des Anbieters. Anbieter wählen und Schlüssel unter der gemeinsamen Liste eingeben; Änderungen speichern automatisch, Leeren löscht den Schlüssel. **Fetch model list** abrufen und danach ein Modell in der Tagging- oder Regelgruppe wählen; der Abruf wählt keines aus. **Reasoning effort** bietet Standard, Low, Medium oder High, soweit unterstützt. Neue Auswahl beginnt mit Medium, vorhandene bleibt gespeichert. Höherer Aufwand kann Zeit und Tokens erhöhen. Websuche ist immer aktiviert; das Modell wählt ihren Einsatz. Bei Fehlern bleiben gültige Cache-Ergebnisse erhalten; neue Inhalte bleiben ungelöst bis **Retry cloud classification**. Vault wechselt den Anbieter nicht automatisch; jede Verbindung hat eigenes Intervall und Versuchslimit. Korrigieren Sie Tags in der Erweiterung mit **+ tag**; Entfernen-Steuerung oder einmal Delete entfernt sie. **Untagged** bedeutet abgeschlossen ohne Tags, **Tagging** bedeutet ausstehend. Ihre Korrektur bleibt maßgeblich.

## Activity

### Activity-Gruppen

Erstellen Sie eine Gruppe, um ausgewählte Apps und Websites gemeinsam unter Usage anzuzeigen. **Merge** verwendet für Mitglieder überall in Activity einen Namen und eine Farbe. Activity-Gruppen ordnen aufgezeichnete Nutzung und sind von Blocking- und Content-tagging-Gruppen getrennt. Speichern Sie den Editor ausdrücklich mit **Save**.

### Aufzeichnung und Aufbewahrung

Unter **Recording** Aufzeichnung je Kategorie oder Quelle schalten. **Keep** bestimmt die Aufbewahrung, **Forever** läuft nicht ab. Ausschalten stoppt neue Aufzeichnungen; Löschen entfernt Historie. Plattform-Feeds sammeln angezeigte Inhalte unterstützter Seiten, unabhängig davon, ob sie geöffnet wurden. **Tagging supported**-Feeds können bei aktiver Aufzeichnung Tagging speisen; die Aufbewahrung ist von App- und Webnutzung getrennt. Eine pausierte Tagging-Gruppe stoppt die Aufzeichnung nicht.

## Settings

Wählen Sie unter Einstellungen die Oberflächensprache; Info-Schaltflächen zeigen lokalisierte Erklärungen. ## Speichern und Fehlerbehebung

## Saving and troubleshooting

Übliche Vault-/Tagging-Änderungen speichern automatisch; Activity-Gruppen brauchen **Save**. Hinzufügen, Löschen, Verbindungstests und Modellabruf sind ausdrückliche Aktionen. Fehlen Tags, prüfen Sie Browserverbindung, globalen Schalter, Pause, Plattformaufzeichnung, Verbindung/Modell und Zugangsdaten. Bei KI-Fehlern prüfen Sie Anbieterlimits und Gruppenprotokoll. Verbinden Sie bei nicht bearbeitbaren verknüpften Gruppen die Programme erneut oder tauen Sie die Gruppe wie angegeben auf.
