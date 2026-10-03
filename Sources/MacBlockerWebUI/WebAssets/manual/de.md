# Mac Vault Benutzerhandbuch

Mac Vault hat drei Seiten: **Vault** blockiert native Apps, **Klassifizierung** weist unterstützten Browserinhalten Tags zu und **Aktivität** zeigt aufgezeichnete Nutzung. Die Browsererweiterung erfasst unterstützte Inhalte und setzt die Browserblockierung durch. Installieren und verbinden Sie sie in dem Browser, den Sie verwenden.

## Schnellstart

1. Fügen Sie in **Vault** eine Blockierungsgruppe und ein Apps-Ziel hinzu und wählen Sie mit der + Auswahl Apps aus.
2. Wählen Sie das Blockierungsverhalten der Gruppe und aktivieren Sie sie.
3. Erstellen Sie in **Klassifizierung** eine Gruppe, wählen Sie ihre Plattformen und fügen Sie Tags mit Beschreibungen hinzu.
4. Wählen Sie eine lokale Modellstufe und laden Sie sie bei Bedarf herunter. Aktivieren Sie die Tag-Zuweisung in den Einstellungen und setzen Sie die Gruppe fort.
5. Öffnen Sie unterstützte Inhalte im verbundenen Browser. Konfigurieren Sie einen Tag-Filter in einer Browser-Blockierungsgruppe, wenn die Tags die Blockierung steuern sollen.

## Blockierungsgruppen

Eine **Blockierungsgruppe** wendet eine Blockierungsrichtlinie an. Eine **Klassifizierungsgruppe** weist Inhalten Tags zu; sie blockiert selbst nichts.

1. Fügen Sie eine Blockierungsgruppe hinzu und geben Sie ihr einen Namen.
2. Wählen Sie unter **Gilt für** die Ziele aus.
3. Legen Sie fest, wann die Blockierung gilt, und stellen Sie gegebenenfalls einen Zeitplan oder ein Zeitkontingent ein.
4. Aktivieren Sie die Gruppe. Ihre Ziele verwenden die gemeinsame Richtlinie der Gruppe.

Gewöhnliche Änderungen werden automatisch gespeichert. Eine Fehlermeldung bedeutet, dass die Änderung nicht angenommen wurde; korrigieren Sie das Feld und versuchen Sie es erneut. Deaktivieren Sie eine Gruppe, um ihre Richtlinie auszusetzen und ihre Konfiguration zu behalten. **Gruppe löschen** entfernt sie. Ziehen Sie Gruppen, um ihre Reihenfolge zu ändern. Mehrere Gruppen können für dasselbe Ziel gelten; das Aufschieben einer Gruppe hebt die Blockierung einer anderen nicht auf.

**Exportieren** kopiert eine Gruppenkonfiguration. **Importieren** ersetzt nach Bestätigung die Konfiguration der ausgewählten Gruppe.

### Zeitkontingent und Zeitplan

**Sofort blockieren** gilt immer dann, wenn die aktivierte Gruppe zutrifft und ihr Zeitplan aktiv ist. **Nach Verbrauch des Zeitkontingents blockieren** erlaubt die betreffende Nutzung, bis das Kontingent aufgebraucht ist.

Stellen Sie das Kontingent in Minuten und das Rücksetzintervall in Stunden ein. Ein gleitendes Limit zählt die Nutzung im vorangegangenen Zeitfenster. Das Zurücksetzen um Mitternacht beginnt zur lokalen Mitternacht einen neuen Zeitraum, auch bei einem gleitenden Limit.

Wählen Sie aktive Wochentage und optional lokale Zeitfenster, eines pro Zeile, beispielsweise **09:00-12:00**. Eine leere Fensterliste gilt während der gesamten ausgewählten Tage. Ein Fenster muss am selben Tag später enden als beginnen; teilen Sie einen Zeitplan über Nacht auf getrennte Tage auf.

### Aufschieben

Konfigurieren Sie das Aufschieben für jede Blockierungsgruppe. **Blockierung pausieren** setzt die Richtlinie dieser Gruppe für die Pausendauer aus. **Zum Zeitkontingent hinzufügen** ergänzt nutzbare Minuten für eine zeitlich begrenzte Gruppe. Nur verbrauchtes Zusatzkontingent zählt als aufgeschobene Zeit. Ungenutztes Zusatzkontingent verfällt beim nächsten Zurücksetzen; bei einem gleitenden Limit nach einem Zeitfenster oder, falls aktiviert, bereits um Mitternacht.

**Aktivierungsverzögerung** verzögert das Aufschieben, während die Blockierung weiter gilt. **Wartezeit** ist die Zeit nach dem Ende des Aufschiebens bis zur nächsten Anfrage. **Erforderliche Bestätigungen** legt die Anzahl der Bestätigungsschritte fest. Für eine eingefrorene Gruppe ist Aufschieben nur verfügbar, wenn es vor dem Einfrieren erlaubt wurde.

### Einfrieren und PIN

**Einfrieren** verhindert gewöhnliche Änderungen. Zum Auftauen sind zehn Bestätigungen im Abstand von fünf Sekunden sowie eine gegebenenfalls konfigurierte Wartezeit und sechsstellige PIN erforderlich. **Wartezeit vor dem Auftauen** akzeptiert 0–72 Stunden; 0 fügt keine Wartezeit hinzu.

Im eingefrorenen Zustand kann die Wartezeit verlängert und eine PIN hinzugefügt werden, sofern noch keine vorhanden ist. Diese Bedingungen lassen sich erst nach dem Auftauen der Gruppe abschwächen. Auch das Löschen berücksichtigt die verbleibende Wartezeit und die PIN.

### Verknüpfte Gruppen

Verwenden Sie **Verknüpfen**, um ausdrücklich ausgewählte Gruppen in anderen Vault-Programmen zu verbinden. Verknüpfte Gruppen teilen ihren Namen, unterstützte Richtlinieneinstellungen, Ziele, Nutzung und Einfrierbedingungen. Jedes Programm bearbeitet und setzt die von ihm unterstützten Zieltypen durch; andere Zieleinträge bleiben für verknüpfte Programme verfügbar. Beim Aufheben der Verknüpfung bleiben jede Gruppe und ihre Einstellungen erhalten.

Ist ein verknüpftes Mitglied offline, kann die Bearbeitung nicht verfügbar sein. Öffnen Sie Mac Vault und den verknüpften Browser, um die Verbindung wiederherzustellen. Eine lokal gespeicherte Richtlinie kann weiter gelten, während ein Mitglied offline ist.

## Hilfe erhalten

Klicken Sie auf das kleine **i** neben einem Feld, um dessen Erklärung anzuzeigen. Klicken Sie außerhalb der Erklärung oder drücken Sie Escape, um sie zu schließen. Listen bleiben in scrollbaren Bereichen; scrollen Sie innerhalb des Bereichs, um weitere Einträge zu erreichen. Die Suche filtert die sichtbare Liste, ohne Einträge zu löschen.

Benutzerdefinierte Regeln haben ein eigenes [Codehandbuch](../code-manual/de.md). Es erklärt den Editor, die Aktivierung, Protokolle, den Dateizugriff und die unterstützte API.

## Native Apps

Verwenden Sie die + Auswahl eines Apps-Ziels, um installierte Apps auszuwählen. **Alle Apps außer diesen blockieren** macht die Liste zu einer Freigabeliste. System-Apps, Browser und Vault selbst sind von der nativen App-Blockierung ausgeschlossen.

Eine blockierte App wird zum Beenden aufgefordert. **Eine blockierte App erneut zum Beenden auffordern alle (Minuten)** steuert Wiederholungen. Websiteweiterleitungen, Seitenpausen und das Verbergen von Feed-Inhalten werden von der Browsererweiterung durchgesetzt; sie werden nicht zu nativen App-Aktionen.

## Klassifizierung

Eine Klassifizierungsgruppe weist Inhalten ihrer zugeordneten Plattformen mit ihrem eigenen Tag-Baum und ihren eigenen Modelleinstellungen Tags zu. Jede Plattform gehört zu einer Gruppe. Wählen Sie Plattformen beim Erstellen der Gruppe; sie lassen sich danach nicht ändern. Zeitpläne und Filter von Blockierungsgruppen steuern die Tag-Zuweisung nicht.

Aktivieren Sie die Tag-Zuweisung in den Einstellungen. Verwenden Sie **Tag-Zuweisung pausieren / Tag-Zuweisung fortsetzen** für jede Gruppe getrennt. Das Ausschalten der Aufzeichnung eines Plattformfeeds in **Aktivität → Aufzeichnung** stoppt auch dessen Tag-Zuweisung.

### Tags und Modelleinstellungen

Erstellen Sie Tags, beschreiben Sie ihre Bedeutung und setzen oder entfernen Sie ihre Eltern im Tag-Baum. Ziehen Sie einen Tag, um seinen Zweig zu verschieben. Klare Beschreibungen helfen dem Modell, ähnliche Tags zu unterscheiden. Die Einstellungen jeder Gruppe sind unabhängig.

- **Geschwindigkeit ↔ Qualität** wählt eine lokale Modellstufe. Größere Modelle benötigen mehr Arbeitsspeicher; Geschwindigkeit und Ergebnisse hängen von Mac und Arbeitslast ab. Downloads werden von Gruppen gemeinsam genutzt.
- **Streng ↔ Breit** legt Konfidenzanforderungen und standardmäßige Tag-Anzahlen fest.
- **Minimum an Tags / Maximum an Tags** unter Mehr ersetzen diese Standardanzahlen. Streng ↔ Breit steuert weiterhin die Konfidenz für zusätzliche Tags. Lassen Sie eines der Felder leer, um seinen Standardwert zu verwenden.
- **Anweisungen zur Tag-Zuweisung** ergänzt optionale Anweisungen für diese Gruppe.

Gewöhnliche Klassifizierungsänderungen werden automatisch gespeichert. Eine ausgewählte Stufe muss heruntergeladen sein, bevor sie Tags zuweisen kann. Gruppen derselben Stufe teilen ein geladenes Modell; bis zu zwei Stufen bleiben gleichzeitig geladen.

Korrigieren Sie die Tags eines Inhalts in der Browsererweiterung. Klicken Sie auf **+ Tag**, durchsuchen Sie die vorhandenen Tags der Klassifizierung und wählen Sie einen zum Hinzufügen. Verwenden Sie die Entfernen-Steuerung eines Tags oder wählen Sie ihn aus und drücken Sie einmal Entf. **Ohne Tag** bedeutet, dass die Tag-Zuweisung ohne Tags abgeschlossen wurde; **Tag-Zuweisung läuft** bedeutet, dass ein Ergebnis aussteht. Korrekturen beeinflussen künftige Tag-Zuweisungen.

## Wissen und Webrecherche

Wissen speichert auf diesem Mac kurze Beschreibungen für das lokale Tag-Modell. **Inhaltsquellen** umfassen Ersteller, Konten, Kanäle und Communitys. Quellbeschreibungen begleiten deren Inhalte. **Bekannte Begriffe** gelten, wenn ein Begriff in einem Titel vorkommt.

Fügen Sie eine Quelle oder einen Begriff und deren Beschreibung hinzu oder lassen Sie die Beschreibung leer, um bei aktivierter Recherche eine Recherche anzufordern. Erstellervorschläge helfen beim Finden einer bereits von der Klassifizierung erfassten Quelle. Listen mit sechs oder mehr Einträgen haben direkt darüber eine Suche: Begriffe und die Inhaltsquellen jeder Plattform haben getrennte Suchen nach Name, Kennung oder Beschreibung. Das Bearbeiten einer Beschreibung beeinflusst künftige Tag-Zuweisungen; das Löschen von Quellenwissen verhindert nicht, dass spätere Recherche es erneut erstellt.

### Rechercheanbieter konfigurieren

1. Öffnen Sie **Einstellungen → API-Schlüssel und Anbieter**.
2. Wählen Sie einen Anbietertyp und **Anbieter hinzufügen**. Dies erstellt eine Konfiguration; es stellt keinen API-Schlüssel aus.
3. Besorgen Sie Anmeldedaten bei diesem Anbieter und tragen Sie sie ein. Konfigurieren Sie bei einem kompatiblen benutzerdefinierten Endpunkt auch dessen Endpunkt- und Protokollfelder.
4. Wählen Sie in **Webrecherche** einen Anbieter mit integrierter Websuche. Rufen Sie dessen Modellliste ab und wählen Sie ein Recherchemodell. Verwenden Sie die Suche der Modellauswahl, um die Liste einzugrenzen; aktualisieren Sie sie zum erneuten Abruf.
5. Lesen Sie die Einwilligungserklärung und aktivieren Sie die Einwilligung. Wählen Sie in jeder Gruppe **Ein**, **Aus** oder **Einstellungen folgen**.

**Webrecherche einrichten…** führt Sie bei fehlender Konfiguration zu den Einstellungen. Eine Gruppe kann die Rechercheeinwilligung nicht umgehen. **Verbindung testen** bestätigt den Erfolg der Testanfrage, nicht, dass jedes Modell Recherche unterstützt. Das Testmodell eines Anbieters ist vom ausgewählten Recherchemodell getrennt.

Schlüssel werden im Unterstützungsordner der App auf diesem Mac gespeichert, nicht im Systemschlüsselbund. Sie authentifizieren Anfragen beim konfigurierten Anbieter; Vault lädt sie nicht auf seinen eigenen Server hoch. Recherche sendet bereinigte öffentliche Themen an den ausgewählten Anbieter, keine privaten Inhaltskörper oder Zusammenfassungen. Lesen Sie die Einwilligungserklärung für die genauen gesendeten Felder. Zur Anbieternutzung gehören Verbindungstests und Modelllistenanfragen ebenso wie Recherche.

Der Recherchestatus zeigt eingereihte Anfragen, Wartezeiten für Wiederholungen, Fehler und den Tokenverbrauch des Tages. **Fehlgeschlagene Themen jetzt erneut versuchen** wiederholt geeignete Fehler; es umgeht weder das Tageskontingent noch die Einwilligung.

## Aktivität

Aktivität zeichnet aktivierte App-Nutzung, Websitebesuche und unterstützte **Angesehene Inhalte** lokal auf. Ihre Diagramme spiegeln aufgezeichnete Daten wider; ein leerer Bereich beweist nicht, dass Mac ungenutzt war.

Wählen Sie einen Datumsbereich. **Zeitleiste** zeigt die Nutzung zur jeweiligen Tageszeit; **Gesamtsummen** summiert die Dauer. **Zeitintervall** fasst die Nutzung innerhalb jedes Intervalls zu vertikalen Blöcken zusammen. **Farben** ist eine anklickbare Legende: Wählen Sie eine Quelle, um die Diagramme darauf zu fokussieren. Wählen Sie einen Tag, um die Nutzung seit diesem Tag anzuzeigen.

### Aktivitätsgruppen

Erstellen Sie eine Gruppe, um ihre ausgewählten Apps und Websites gemeinsam in Nutzung anzuzeigen. **Zusammenführen** verwendet für ihre Mitglieder überall in Aktivität einen Namen und eine Farbe. Eine Aktivitätsgruppe organisiert aufgezeichnete Nutzung; sie ist von einer Blockierungsgruppe oder Klassifizierungsgruppe getrennt. Speichern Sie den Aktivitätsgruppeneditor ausdrücklich mit **Speichern**.

### Aufzeichnung und Aufbewahrung

Schalten Sie in **Aufzeichnung** die Aufzeichnung für jede Kategorie oder einzelne Quelle ein oder aus. **Aufbewahren** steuert, wie lange der Verlauf erhalten bleibt; **Für immer** behält ihn ohne automatischen Ablauf. Einzelne Auswahlmöglichkeiten können der übergeordneten Einstellung folgen. Das Ausschalten der Aufzeichnung stoppt neue Aufzeichnungen; das Löschen des Verlaufs entfernt aufgezeichnete Einträge.

Plattformfeeds erfassen Inhalte auf unterstützten Plattformseiten, unabhängig davon, ob diese geöffnet wurden. Ein Feed mit **Tag-Zuweisung unterstützt** kann bei eingeschalteter Aufzeichnung die Klassifizierung versorgen. Seine Aufbewahrung steuert erfasste Inhalte getrennt von App- und Websitenutzung. Eine pausierte Klassifizierungsgruppe schaltet die Aufzeichnung nicht selbst aus.

## Einstellungen

Wählen Sie die Oberflächensprache in den Einstellungen. Felderklärungen sind über die kleinen Info-Schaltflächen in der gewählten Oberflächensprache verfügbar.

## Speichern und Fehlerbehebung

Gewöhnliche Vault- und Klassifizierungsänderungen werden automatisch gespeichert. Die Bearbeitung von Aktivitätsgruppen verwendet **Speichern**. Hinzufügen, Löschen, Modelldownload, Verbindungstest und Abruf einer Modellliste bleiben ausdrückliche Aktionen.

Fehlen Tags, prüfen Sie die Browserverbindung, den globalen Tag-Schalter, den Pausenstatus der Gruppe, die Plattformaufzeichnung und den Modelldownload. Läuft Recherche nicht, prüfen Sie Einwilligung, Gruppenauswahl, Anbieteranmeldedaten, Recherchemodell und Recherchestatus. Lässt sich eine verknüpfte Gruppe nicht bearbeiten, verbinden Sie ihre Programme erneut oder tauen Sie sie wie angezeigt auf.
