# Funktionsreferenz zur Vault-Desktop-App

## Zweck und Grenze

Dies ist die maßgebliche Referenz für die Vault-Desktopanwendungsoberfläche. Es ist absichtlich getrennt vom Handbuch zur Vault-Browsererweiterung.

Die Desktop-App verwaltet **native Anwendungen und Anwendungsfenster**. Die Browsererweiterung verwaltet Websites, Browser-Registerkarten und unterstützte Webplattform-Feeds. Sie haben die gleichen Ideen – Gruppen, Zeitpläne, Timer, Einfrieren, Schlummern, benutzerdefinierte Regeln und die optionale Bridge –, verfügen jedoch nicht über die gleiche Durchsetzungsoberfläche.

Verwenden Sie dieses Dokument, um das Verhalten der Desktop-App zu konfigurieren, zu prüfen, zu reproduzieren oder zu verwalten. Der Code ist kanonisch, wenn sich eine Implementierung und dieses Handbuch unterscheiden.

## 1. Was die Desktop-App steuern kann und was nicht

Vault bewertet die Fokusrichtlinie für ausgewählte native Anwendungen. Wenn seine native Durchsetzungsfunktion verfügbar ist, kann es den aktuellen Plan auf passende Anwendungsziele anwenden und ein Schutz-/Statusergebnis an die Host-Benutzeroberfläche melden.

Es kann:

- Gruppen erstellen, aktivieren, deaktivieren, neu anordnen, importieren, exportieren, einfrieren, in den Schlummermodus versetzen und entfernen;
- Zielen Sie auf native Anwendungen, die über die Anwendungsauswahl ausgewählt wurden;
- eine sofortige Blockierung, eine zeitgesteuerte Zulage oder einen nur hochzählenden Timer anwenden;
- normale Gruppen auf Wochentage und lokale Zeitfenster beschränken;
- Benutzerdefinierte JavaScript-Richtlinienregeln für Anwendungslebenszyklusereignisse ausführen;
- Durch Regeln erstellte native Status-/Panel-Informationen über den Host anzeigen;
- Verwalten Sie einen optionalen lokalen Ordner für unterstützte Dateianforderungen nach benutzerdefinierten Regeln.
- Treten Sie kompatiblen, explizit verknüpften Gruppen über die lokale Vault-Brücke bei.

Es kann nicht:

- als Browser-Erweiterung fungieren, den DOM einer Website inspizieren oder Browser-Feedkarten manipulieren;
- garantieren, dass ein Betriebssystem die Steuerung aller Anwendungen, Prozesse, Fenster oder Systemdienste ermöglicht;
- Anwendungsauswahl in Fernverwaltung, Geräteüberwachung oder eine Firewall umwandeln;
– Sorgen Sie dafür, dass nur browserbasierte benutzerdefinierte Hilfsprogramme wie DOM, Navigation, Umleitung oder Tab-Steuerung in der nativen Laufzeit funktionieren.
- Synchronisieren Sie jede Gruppe automatisch, nur weil die lokale Bridge läuft.

## 2. Wortschatz

| Begriff | Bedeutung |
| --- | --- |
| Gruppe | Ein benanntes Fokusrichtlinienobjekt. Gruppennamen müssen innerhalb des aktuellen Vault-Endpunkts eindeutig sein. |
| Ziel | Eine für eine Gruppe ausgewählte native Anwendungsidentität. |
| Standardanwendungsgruppe | Eine normale Gruppe, deren Ziele native Anwendungen aus der App-Auswahl sind. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Übereinstimmung | Die aktuell im Vordergrund stehende/laufende Anwendung entspricht einem aktivierten und aktiven Gruppenziel oder einer benutzerdefinierten Regelbedingung. |
| Aktiv | Aktiviert, innerhalb des normalen Zeitplans und nicht aktiv im Schlummermodus. |
| Durchsetzungsplan | Die daraus resultierende Zulassungs-/Schutz-/Statusentscheidung des nativen Hosts, nachdem er die entsprechenden Gruppen ausgewertet hat. |
| Einfrieren | Schutz vor gewöhnlicher Änderung einer Gruppe. |
| Schlummern | Eine vorübergehende Ausnahme von einer normalen Gruppenrichtlinie. |

## 3. Zielidentität und Anwendungsauswahl

Wählen Sie Anwendungen über die *****-Auswahl in einer Standardanwendungsgruppe aus. Vault speichert eine normalisierte Identität sowie einen Anzeigenamen.

| Gastgeber | Für den Abgleich verwendete Zielidentität |
| --- | --- |
| macOS | Anwendungspaket-ID, sofern verfügbar. |
| Windows | Normalisierter ausführbarer Pfad oder Prozessname, der von der Anwendungsauswahl bereitgestellt wird. |

Der Anzeigename ist für den Editor. Der normalisierte Wert ist die von der nativen Durchsetzungsschicht verwendete Identität. Durch das Umbenennen einer Anwendung in der Benutzeroberfläche wird die Identität nicht geändert. Ein Ziel kann auch Tags für die Verwendung durch benutzerdefinierte Regelrichtlinien enthalten.

Geben Sie keine Website-URL in ein Anwendungszielfeld ein und erwarten Sie eine native Anwendungsdurchsetzung. Verwenden Sie die Site-Gruppe der Erweiterung zum Blockieren von Websites.

## 4. Gruppenlebenszyklus und Priorität

Eine neue Gruppe ist standardmäßig aktiviert. Die Gruppenliste unterstützt Auswahl, Aktivieren/Deaktivieren, Drag-Sortierung, Hinzufügen, Löschen, Importieren, Exportieren und Löschen. Die ausgewählte Gruppe wird im Editor geöffnet.

Normale Feldbearbeitungen werden über die Autosave-Richtlinie des Editors gespeichert. Eine eingefrorene Gruppe deaktiviert normale Bearbeitungssteuerelemente. Bei einer benutzerdefinierten Quelle ist das anders: Durch das Speichern von Text wird dieser nicht aktiviert. **Ausführen** ist der Vorgang, der die aktuelle Quelle in die Richtlinienlaufzeit lädt.

Mehrere Gruppen können derselben Anwendung entsprechen. Vault wertet Gruppenrichtlinien in gespeicherter Reihenfolge aus und erstellt einen nativen Durchsetzungsplan. Sorgen Sie dafür, dass es zu Überschneidungen kommt, insbesondere wenn Gruppen unterschiedliche zeitgesteuerte Richtlinien verwenden oder benutzerdefinierte Regeln Entscheidungen zum Zulassen/Abschirmen treffen. Ordnen Sie die Gruppen neu an, um die beabsichtigte Priorität deutlich zu machen. Verlassen Sie sich nicht darauf, dass eine widersprüchliche Konfiguration auf besonders benutzerfreundliche Weise gelöst wird.

## 5. Normale Anwendungsgruppen

### 5.1 Gruppenstatus

| Feld | Funktionsvertrag |
| --- | --- |
| Name | Nicht leer, gekürzt, eindeutig, ohne Berücksichtigung der Groß- und Kleinschreibung innerhalb dieses Endpunkts. |
| Aktiviert | Behindertengruppen bleiben erhalten, nehmen aber nicht an der normalen Durchsetzung teil. |
| Ziele | Eine oder mehrere aus der Auswahl ausgewählte Anwendungsidentitäten. |
| Verhalten | Sofortige Blockierung, Blockierung nach einer Zulage oder Timer/Aufwärtszählung. |
| Zeitplan | Ausgewählte Wochentage und optionale lokale Zeitfenster. |
| Einfrieren | „Keine“, „Eingefroren“, „Strikt eingefroren“ oder „Kindersicherung eingefroren“. |
| Schlummern | Temporäre Ausnahmerichtlinie pro Gruppe. |
| Fallback/Statusmeldung | Nachricht, die der native Host anzeigen kann, wenn er eine Schutz-/Statusantwort anwendet. |

Eine leere Standardgruppe hat kein ausgewähltes Anwendungsziel und passt daher nicht allein aufgrund ihrer Existenz zu einer Anwendung.

### 5.2 Blockierendes Verhalten

| Verhalten | Ergebnis |
| --- | --- |
| Sofort sperren | Ein passendes aktives Ziel führt zu einer sofortigen nativen Block-/Schild-Entscheidung. |
| Blockierung nach einigen Minuten | Die entsprechende Nutzung wird auf die Gruppenpauschale angerechnet. Wenn das Kontingent erschöpft ist, trifft die Gruppe eine native Block/Shield-Entscheidung, bis ihr Nutzungszeitraum zurückgesetzt wird oder ein anderer Status die Gruppe inaktiv macht. |
| Timer (hochzählen, kein Block) | Die übereinstimmende Nutzung wird gemessen und möglicherweise angezeigt, aber dieser Timer allein führt nie zu einer Blockierung. |

Neue Gruppen nutzen ein 15-minütiges Zeitintervall und ein 24-Stunden-Reset-Intervall, sofern keine Änderung vorgenommen wird. Die zeitgesteuerte Nutzung gehört zur Gruppe, sodass alle übereinstimmenden Ziele diese Gruppenrichtlinie gemeinsam nutzen. Die genaue Reaktion auf eine Blockierung wird vom nativen Host implementiert und durch die Betriebssystemberechtigungen und den unterstützten Durchsetzungsmechanismus eingeschränkt.

### 5.3 Zeitpläne

Die Zeitpläne gelten für normale Gruppen. Eine benutzerdefinierte Gruppe trifft ihre eigenen Zeitentscheidungen in JavaScript.

Wählen Sie eine beliebige Kombination von Montag bis Sonntag. Jedes Zeitfenster ist eine Zeile in Ortszeit:

```text
0900-1200
1330-1730
```

Das genaue akzeptierte Format ist HHMM-HHMM. Die Stunden müssen zwischen 00 und 23 Uhr liegen, die Minuten zwischen 00 und 59 Uhr, und der Beginn muss vor dem Ende am selben Tag liegen. Ein Fenster schließt seinen Anfang ein und schließt sein Ende aus. Fenster, die nach Mitternacht geöffnet sind, werden nicht akzeptiert. Leere Fenster bedeuten den gesamten ausgewählten Tag.

Die normale Gruppe ist nur aktiv, wenn:

1. es ist aktiviert;
2. Der aktuelle Wochentag wird ausgewählt;
3. Die Ortszeit liegt innerhalb eines konfigurierten Fensters oder die Gruppe verfügt über keine Fenster.
4. Es befindet sich nicht im aktiven Schlummermodus.

### 5.4 Schlummern

Snooze entfernt eine normale Gruppe vorübergehend aus der aktiven Durchsetzung. Seine Phasen sind:

| Phase | Ergebnis |
| --- | --- |
| Ausstehend | Die Anfrage existiert, aber die Aktivierungsverzögerung ist noch nicht abgelaufen; Die Gruppe bleibt aktiv. |
| Aktiv | Die Gruppe ist während der Schlummerdauer vorübergehend inaktiv. |
| Abklingzeit | Die Schlummerfunktion ist beendet und die Gruppe ist wieder aktiv, es ist jedoch noch keine neue Schlummerfunktion verfügbar. |

| Einstellung | Regel |
| --- | --- |
| Schlummerfunktion zulassen | Wenn diese Option deaktiviert ist, kann die Gruppe nicht normal in den Schlummermodus versetzt werden. |
| Schlummerdauer | Positive Anzahl an Minuten. Der Standardwert für eine neue Gruppe beträgt 30 Minuten. |
| Aktivierungsverzögerung | Null oder mehr Minuten, bevor die Schlummerfunktion aktiv wird. |
| Abklingzeit | Null bis fünf Minuten nach Ende der aktiven Schlummerfunktion. |
| Bestätigungen | Nicht negative ganze Anzahl erforderlicher Bestätigungsinteraktionen. |

Eine aktive Schlummerfunktion ist eine vorübergehende Richtlinienausnahme, kein Löschen oder Aufheben der Sperrung. Die Gruppenkonfiguration bleibt erhalten.

### 5.5 Einfrieren

Einfrieren ist eine absichtliche Änderungsbarriere.

| Modus | Vertrag |
| --- | --- |
| Gefroren | Gewöhnliche Bearbeitungen und gewöhnliche Statusänderungen bleiben gesperrt, bis der Bestätigungsfluss zum Auftauen des Produkts erfolgreich ist. |
| Streng gefroren | Die Sperrung der Gruppe kann nicht aufgehoben werden, bevor die Dauer des strikten Einfrierens abgelaufen ist. Die Dauer ist positiv und auf 72 Stunden begrenzt. |
| Eltern eingefroren | Für Freeze-/Unfreeze-Aktionen ist eine Verwaltung des Guardian-Passworts erforderlich. |

Durch die Auswahl eines Modus im Editor wird die Gruppe nicht automatisch eingefroren. Verwenden Sie die Freeze-Aktion, um es anzuwenden. Eine über eine Brücke verbundene Gruppe kann auch koordinierte Einfriersteuerungen sperren, während ein erforderliches Mitglied offline ist.

## 6. Native Durchsetzung und Gerätekontrolle

Der Editor kann eine Gruppe auch dann korrekt speichern, wenn das Betriebssystem die Möglichkeit, dies zu erzwingen, nicht gewährt hat. Überprüfen Sie immer **Einstellungen → Gerätesteuerung** und den nativen Live-Status, nachdem Sie Berechtigungen geändert haben.

Der native Host entscheidet, welche Aktionen für das aktuelle Betriebssystem, die Anwendung, das Fenster und den Berechtigungsstatus möglich sind. Eine Regel kann korrekt konfiguriert sein, hat aber keine sichtbare Auswirkung, wenn:

- Die Gerätekontrolle wurde nicht gewährt oder wurde widerrufen.
– Die Gruppe ist deaktiviert, ausgeplant oder aktiv im Ruhezustand.
– der fokussierte Prozess stimmt nicht mit einem ausgewählten normalisierten Ziel überein;
– Das Betriebssystem lehnt eine Aktion für dieses Ziel ab.
– Eine Bridge-Abhängigkeit ist für eine Aktion, die einen koordinierten Status erfordert, offline.

Betrachten Sie einen erfolgreichen Save-Toast nicht als Beweis dafür, dass eine aktive Durchsetzung verfügbar ist. Testen Sie das ausgewählte Ziel, während die Gruppe aktiv ist, und überprüfen Sie den Hoststatus.

## 7. Benutzerdefinierte Gruppen und native Richtlinienregeln

Benutzerdefinierte Gruppen werden in der nativen JavaScript-Richtlinienlaufzeit ausgeführt. Es handelt sich nicht um benutzerdefinierte Browserregeln. Browser-DOM, Tab, Navigation, URL-Umleitung und Feed-Kontrollverhalten sind absichtlich nicht verfügbar.

### 7.1 Lebenszyklus der Quelle

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Native integrierte Ereignisse

| Veranstaltung | Bedeutung |
| --- | --- |
| tickEvent | Periodischer Wirtszick. Eine IntervallMs-Registrierungsoption kann die Rate eines Handlers begrenzen. |
| timerEnded | Ein regeleigener Countdown erreicht Null. |
| snoozePress | Der Benutzer drückt Snooze starten für eine benutzerdefinierte Gruppe. |
| PanelEvent | Es wird ein benutzerdefiniertes Panel-Steuerelement verwendet. |
| localFileEvent | Eine angeforderte Aktion für einen lokalen Ordner wird abgeschlossen. |
| openAppEvent | Eine verfolgte Anwendung wird geöffnet. |
| closeAppEvent | Eine nachverfolgte Anwendung wird geschlossen. |
| focusEvent | Die Vordergrundanwendung wird zu einer Anwendung. |
| unfocusEvent | Die Vordergrundanwendung wechselt von einer Anwendung weg. |
| minimizeEvent / unminimizeEvent | Der Host meldet einen unterstützten Übergang zur Fensterminimierung. |
| switchAppEvent | Die Vordergrundanwendung wechselt von einer App zur anderen. |
| appChangedEvent | Allgemeiner Anwendungslebenszyklus/Änderungsereignis. |

Das Ereignisobjekt enthält Typ, Gruppen-ID/Gruppen-ID, Gruppenname, URL-/Hostnamen-Äquivalente, Zeit, Daten und Ziel. Bei einer nativen Anwendung stellt das Ziel eine ID, einen Typ, einen Anzeigenamen, einen normalisierten Wert und Tags bereit, wenn das Fokusziel mit einem konfigurierten Ziel übereinstimmt.

Zu den Anwendungslebenszyklus-Ereignisdaten gehören die aktuelle App-ID/der aktuelle App-Name, der Gruppenname, ein serialisierter aktueller App-Snapshot und ereignisspezifische Werte wie bundleId, previousAppId, currentAppId oder Änderungsgrund.

### 7.3 Ereignis-API und Entscheidungen

Die Registrierung bietet on/register, off/unregister, unregisterAll, countRegistered, getEvent und getEvents. Die Ausführung mit höherer Priorität erfolgt zuerst; Bei gleicher Priorität bleibt die Registrierungsreihenfolge erhalten. Die Registrierung verfügt über eine Handler-Obergrenze pro Gruppe.

Das Ereignisobjekt unterstützt:

| Methode | Ergebnis |
| --- | --- |
| setResult(-1) | Erstellen Sie eine native Schutz-/Blockierungsentscheidung. Ein String-Ergebnis wird auch zu einem nativen Block, da Desktop-Regeln kein Browser-Umleitungsziel haben. |
| Allow(reason) oder setResult(1) | Erstellen Sie eine Genehmigungsentscheidung für die Veranstaltung. |
| setShieldMessage(message) | Legen Sie die dem Menschen zugewandte Schild-/Statusmeldung für einen nativen Block fest. |
| stopPropagation() | Stoppen Sie spätere Handler für das aktuelle Ereignis. |
| block(appId), unblock(appId) | Einen dynamischen nativen Anwendungsblock hinzufügen/entfernen. |
| close(appId), open(appId) | Fordern Sie eine unterstützte native Aktion zum Schließen/Öffnen an. |
| Beitrag(Typ, Daten) | Versenden Sie ein verschachteltes benutzerdefiniertes Ereignis innerhalb der nativen Laufzeit. |

Die App-Laufzeit ermöglicht Timer, Persistenz, Bedienfelder, Protokolle, Vorgänge für lokale Ordner, Hilfsprogramme für Anwendungsfenster und Dienstprogramme zur URL-Klassifizierung. Es behandelt DOM-, Navigations-, Umleitungs- und Browser-Tab-Hilfsprogramme bewusst als nicht verfügbar/inaktiv.

### 7.4 Native Helfer

| Helfer | Natives Verhalten |
| --- | --- |
| getLogHelper | Gibt App-/Popup-/Bildschirmprotokollentscheidungen aus. |
| getTimerHelper | Erstellt Vorwärts-/Rückwärts-Timer mit Grenzen, Schritten, Bereichs-/Domänenprädikaten, Pause/Fortsetzung, Zustandsüberprüfung und timerEnded-Übergängen. Timer schirmen sich nicht selbst ab. |
| getPersistenceHelper | JSON-Status pro Gruppe: abrufen, festlegen, löschen, hat, Schlüssel, Einträge, löschen, Größe. |
| getStorageHelper | Persistenz plus Host-Async-Request-Platzhalter; Gehen Sie nicht von einer synchronen externen Reaktion aus. |
| getWindowHelper | Liest aktuelle/laufende Anwendungen und fordert Aktionen zum Schließen/Öffnen/Blockieren/Entsperren von Anwendungen an. |
| getPanelHelper | Erstellt validierte native Panel-Snapshots, Steuerelemente, Inline-Handler und PanelEvent-Reaktionen. |
| getLocalFolderHelper | Warteschlangen erlaubten relative .txt-, .csv- und .json-Vorgänge unter dem vom Benutzer gewährten Root. Der Abschluss ist localFileEvent. |
| getDomainHelper / getDomainUtility | URL- und Plattformklassifikatoren für Regeln, die auch URL-ähnliche Werte berücksichtigen. |
| getPlatformHelper / Plattform | URL-Klassifikatoren bleiben verfügbar; Native Feed-/DOM-Steuerungsaufrufe sind inaktiv, da der Desktop-Host über kein Website-DOM verfügt. |

Benutzerdefinierte Bedienfelder verwenden dasselbe deklarative Steuervokabular wie die Browser-Laufzeit: Text, Kontrollkästchen, Auswahl, Texteingabe, Textbereich, Schaltfläche, Abschnitt, Timer, Zahleneingabe, Bereich, Umschalten, Radio, Datum, Uhrzeit, Farbe, Pin und bereinigtes HTML. Der native Host entscheidet, wie viel von einem Panel auf der aktuellen Plattform angezeigt werden kann.

## 8. Lokaler Dateiordner

Der lokale Dateiordner ist eine optionale, vom Benutzer gewährte Grenze für benutzerdefinierte Regeln. Regeln können Text-/CSV-/JSON-Lesevorgänge, Schreibvorgänge, Anhänge, Listen, Existenztests und JSON-Vorgänge anfordern. Pfade sind immer relativ zum ausgewählten Stamm. Absolute Pfade, Traversierungssegmente, versteckte Pfadkomponenten, nicht unterstützte Erweiterungen und Operationen außerhalb des Stammverzeichnisses werden abgelehnt.

Sperren Sie den Ordner, wenn eine Regel ihn nicht mehr benötigt. Eine Regel muss nicht verfügbare Berechtigungen und fehlgeschlagene localFileEvent-Ergebnisse verarbeiten. Es darf nicht davon ausgegangen werden, dass ein ausgewählter Ordner nach einem Neustart weiterhin autorisiert bleibt.

## 9. Web-App-Brücke

Die Brücke ist eine optionale lokale Synchronisierung zwischen kompatiblen Vault-Programmen. Eine native Desktop-App kann den lokalen Hub hosten; Clients stellen eine Verbindung über die unterstützte lokale Adresse her.

Die Verbindungsstatus sind „Aus“, „Verbindung wird hergestellt“, „Getrennt“, „Verbunden/Wird ausgeführt“ und „Fehler“. Durch das Verbinden eines Programms werden nicht alle Gruppen zusammengeführt. Der Benutzer muss berechtigte Matching-Gruppen explizit verknüpfen.

Für einen Gruppenlink:

1. Starten Sie den nativen Hub in den Einstellungen.
2. Verbinden Sie den anderen kompatiblen Vault-Endpunkt.
3. Erstellen Sie passende, nicht eingefrorene Gruppen mit demselben Namen und Typ.
4. Wählen Sie im Abschnitt „Gruppenbrücke“ das Programm aus und verbinden Sie die Gruppe.

Eine verknüpfte Gruppe bildet einen Cluster. Unterstützte allgemeine Richtlinienwerte, Nutzung und Schlummerstatus können synchronisiert werden, während Mitglieder verbunden sind. Durch das Trennen der Verbindung wird die Synchronisierung angehalten und lokale Gruppen bleiben erhalten. Bei Nur-Browser-Zielen, nicht unterstützten benutzerdefinierten Aktionen und plattformspezifischen Feldern kann die Übertragung nicht garantiert werden.

## 10. Importieren, exportieren, zurücksetzen und prüfen

Beim Exportieren wird eine kompatible Gruppendarstellung gespeichert. Der Import validiert/normalisiert kompatible Gruppendaten und erzwingt dennoch die Eindeutigkeit lokaler Namen. Gruppe löschen entfernt die ausgewählte Gruppe und den zugehörigen Status. Clear entfernt alle Gruppen nach der Bestätigung. Das Zurücksetzen auf die Standardeinstellungen wirkt sich auf die globalen Editoreinstellungen aus; Exportieren Sie alles, was zuerst aufbewahrt werden muss.

Bevor Sie sich auf eine Desktop-Regel verlassen:

1. Überprüfen Sie, ob die Gerätekontrolle gewährt wird.
2. Überprüfen Sie die normalisierte Identität des ausgewählten Ziels.
3. Überprüfen Sie den Aktivierungsstatus, den Zeitplan, den Einfrierstatus und die Schlummerphase.
4. Testen Sie das Sofort-, Zeit- und Count-Up-Verhalten separat.
5. Führen Sie für eine benutzerdefinierte Gruppe die genaue Quelle aus und testen Sie jedes registrierte App-Ereignis.
6. Überprüfen Sie lokale Ordnerfehler sowie erfolgreiche Vorgänge.
7. Überprüfen Sie das Offline-/Verbunden-Verhalten der Bridge, wenn die Gruppe verknüpft ist.

## 11. Plattformspezifische Hinweise

Die Kernrichtlinienkonzepte werden gemeinsam genutzt, die native Durchsetzung ist jedoch hostspezifisch:

| macOS | Windows |
| --- | --- |
| Ziele werden normalerweise in Anwendungspaket-IDs aufgelöst. Gerätekontrolle und die aktuelle Durchsetzung des macOS-Berechtigungsstatus-Gates. | Ziele werden normalerweise in einen normalisierten ausführbaren Pfad oder Prozessnamen aufgelöst. Die Windows-Durchsetzungsschicht entscheidet, welche aktuellen Fenster/Prozesse verwaltet werden können. |

Diese Desktop-Referenz beschreibt absichtlich keine Website-Blocklisten, Feed-Auswahl, YouTube-Creator-Klassifizierung, Browser-Weiterleitungen oder Browser-Tab-Aktionen. Diese gehören zum Vault-Erweiterungshandbuch.
