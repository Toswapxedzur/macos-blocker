# Mac Vault Codehandbuch

[Benutzerhandbuch](../manual/de.md)

## Regelvertrag

Quelle: ein einzelner Funktionsausdruck `(on, v) => { ... }`. Unterstützt werden ausschließlich synchrones JavaScript und die unten beschriebene API; keine JavaScript-Zeitplanungs-Callbacks, Netzwerkzugriffe, nativen System-APIs oder Browserseitenzugriffe. Zeitabhängige Regeln verwenden die unten beschriebenen verwalteten Timer/Tracker oder `ev.now` und Ereignisse. Safari-Regeln verwenden das Browser-Codehandbuch und laufen in der eigenen übergeordneten App von Safari Vault.

- Bearbeiten speichert einen Entwurf; **Ausführen** aktiviert ihn und die Gruppe. Eingefrorene Gruppen können nicht ausgeführt werden. Leerer Quelltext entlädt die Regel.
- Erfolgreiches Ausführen ersetzt Handler/Panels und leert die App-Blockierungsmenge dieser Gruppe, während `v.state` erhalten bleibt. Bei einem Kompilierungs-/Registrierungsfehler bleibt die vorherige Regel erhalten; ein Timeout kann sie stoppen. Neustarten registriert den zuletzt aktivierten Quelltext erneut; Closure-Variablen und App-Blockierungsmengen werden zurückgesetzt.
- Die Registrierung darf Zustand initialisieren, Handler registrieren, Panels anzeigen und protokollieren. App-/Dateiaktionen und Emits gehören in Handler; ihre während der Registrierung angelegte Warteschlange wird verworfen.
- Deaktivieren unterdrückt Handler und hebt Panels/App-Blockierungen auf. Aktivieren setzt die geladene Regel und ihre erhaltenen Panels/Blockierungen fort. Löschen entfernt ihre Handler/ihren Zustand/ihre Wirkungen. Zuvor beendete Apps werden nicht erneut geöffnet; Dateischreibvorgänge werden nicht rückgängig gemacht.
- Ereignisse sind nicht auf gewöhnliche Gruppenziele beschränkt; wählen Sie Apps in der Regel aus. Aktionen werden eingereiht und anschließend nach der Ereignisverteilung angewendet. Ausnahmen stoppen den betreffenden Handler, ohne seinen Zustand/seine Aktionen zurückzusetzen; spätere Handler können weiterlaufen. Nur Dateiaktionen haben Ergebnisereignisse.

## Verwaltete Timer und gleitende Nutzung

`v.timer(id, {direction:"down", durationMs:300000})` erstellt einen benannten Countdown oder gibt ihn zurück; anfangs ist er pausiert. Verwenden Sie `{direction:"up"}` für einen aufwärtszählenden Timer. Das Handle bietet `start()`, `pause()`, `resume()`, `reset()` und `snapshot()`. Start/Fortsetzen sind idempotent; Zurücksetzen pausiert den Timer mit null verstrichener Zeit. Die Snapshot-Felder umfassen `ready`, `error`, `elapsedMs`, `remainingMs` (null bei aufwärtszählenden Timern), `running` und `completed`.

Laufende Timer laufen anhand der real verstrichenen Zeit weiter, während die App/der Browser geschlossen oder die Regel deaktiviert ist. Ein abgelaufener Countdown liefert `timerEnded` mit `{id, direction, durationMs, generation, incarnation}` einmal pro Timer-Inkarnation und Generation an jedes Mitglied, wenn dessen Regel das nächste Mal läuft; Ausführen wiederholt es nicht. Die Zustellung hängt von Ereignissen des Hosts ab; dies ist kein Echtzeitalarm. Fügen Sie `{type:"timer", timerId:"focus", label:"Focus"}` in ein Panel ein, um ihn über das vorhandene Text-Steuerelement anzuzeigen.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` erstellt einen benannten Tracker für aktive Nutzung oder gibt ihn zurück. `assign({websites:["youtube.com","reddit.com"], apps:[]})` ersetzt die Zielzuweisungen dieses Mitglieds. Native Regeln können stattdessen App-IDs der Plattform zuweisen. Domains schließen Subdomains ein. Ein Tracker fasst seine Ziele zusammen; andere IDs haben unabhängige Kontingente. `snapshot()` liefert `ready`, `error`, `usedMs`, `remainingMs`, `available` und `nextReturnAtMs` (die nächste Millisekunde, in der aufgezeichnete Nutzung verfällt). `available(target?)` prüft auch die Zuweisung, wenn ein Ziel angegeben ist. `reset()` löscht den Verlauf dieses Objekts.

Jede beobachtete anrechenbare Nutzung zählt, auch über das Kontingent hinaus; der Tracker selbst blockiert keine Seite/App. Überlappende Intervalle sichtbarer Seiten zählen einmal, und native Apps zählen die beobachtete Vordergrundnutzung. Deaktivierte Regeln fügen keine Nutzung hinzu; der Verlauf verfällt weiterhin an den exakten Intervallgrenzen. Verfügbarkeit kehrt erst zurück, wenn der verbleibende Verlauf unter dem Limit liegt. Heartbeat-Stichproben sind auf fünf Sekunden begrenzt; Lücken durch Beenden oder Deaktivieren erzeugen keine Aktivität. Vom Benutzer ausgelöste Ereignisse fügen keine Nutzung hinzu.

Gleiche Objekt-IDs in verknüpften benutzerdefinierten Gruppen teilen eine lokale maßgebliche Instanz im nativen Hub. Verknüpfen kombiniert Tracker-Verlauf und Zuweisungen und behält den Timer-Zustand des initiierenden Mitglieds; inkompatible Konfigurationen verhindern die Verknüpfung. Jedes Mitglied erhält sein eigenes Abschlussereignis. Bei einer Trennung sind gemeinsame Tracker nicht verfügbar und Timer-Steuerbefehle werden abgelehnt, bis wieder aktuelle maßgebliche Daten vorliegen. Beim Aufheben der Verknüpfung behält jedes Mitglied die endgültige gemeinsame Nutzung und den Timer-Zustand, stellt seine eigenen Ziele wieder her und verwirft Befehle der alten Verknüpfung. Der Hub behält den endgültigen Snapshot, bis das zurückkehrende Mitglied ihn speichert und bestätigt; ausstehende Übergaben werden abgeschlossen, bevor eine neue Verknüpfung verfügbar wird.

Benannte Objekte überstehen Ausführen und Neustarts im reservierten Feld `v.state.$vaultTime`; bearbeiten Sie dieses Feld nicht direkt. Entfernen Sie sie ausdrücklich mit `v.removeTime(id)`. IDs bestehen aus 1–80 ASCII-Buchstaben, Ziffern, `_` oder `-`; reservierte Eigenschaftsnamen werden abgelehnt. Bis zu 32 Objekte teilen sich das Zustandslimit der Regel von 64 KiB UTF-8. Zeitdauern sind ganzzahlige Millisekunden bis zu 365 Tagen. Der gleitende Verlauf ist auf 1024 Minuten-Buckets und 2048 zusammengeführte Intervalle begrenzt. Fehler wegen ausgeschöpfter Verlaufskapazität lassen den Tracker bis zum ausdrücklichen Zurücksetzen nicht verfügbar; ungültige Konfigurationen und zu große Speichervorgänge melden Fehler, ohne gespeicherte Daten zu löschen.

```js
(on, v) => {
  const timer = v.timer("focus", {durationMs: 300000});
  v.panel("focus", {controls: [
    {type: "timer", timerId: "focus", label: "Focus"},
    {id: "start", type: "button", label: "Start"},
    {id: "pause", type: "button", label: "Pause"},
    {id: "reset", type: "button", label: "Reset"}
  ]});
  on("panel", ev => {
    if (ev.data.eventName !== "click") return;
    if (ev.data.controlId === "start") timer.start();
    if (ev.data.controlId === "pause") timer.pause();
    if (ev.data.controlId === "reset") timer.reset();
  });
  on("timerEnded", ev => v.log("Finished", ev.data.id));
}
```

## API

- `on(type, handler)` → boolescher Wert. Registriert `handler(ev)`; mehrere Handler laufen in Registrierungsreihenfolge. False bedeutet ungültige Argumente oder erreichtes Handlerlimit. `ev = { type: string, now: number, data }`; `now` sind Unix-Millisekunden.
- `v.state`: veränderliches JSON-Objekt, das nach der Ereignisverteilung gespeichert wird. Initialisieren Sie fehlende Felder, statt bestehenden Zustand zu überschreiben. Das Zuweisen eines Nicht-Objekts oder Arrays setzt es auf `{}` zurück; nicht serialisierbare/zu große Änderungen werden nicht gespeichert.
- `v.log(...values)`: hängt Einträge an das Log dieser Gruppe an. Ausführungs- und Zustellungsfehler erscheinen als ausdrückliche Fehlereinträge im selben Feed. Logs/Leeren sind pro Gruppe unabhängig. Ladefehler erscheinen auch im Ausführungsstatus; teilweise ausgeführte Ereignisse werden nicht automatisch wiederholt.
- `v.emit(type, data)`: stellt eine JSON-Kopie von `data` nach dem aktuellen Ereignis für die Handler dieser Gruppe mit einem neuen `now` in die Warteschlange; kein synchroner Aufruf.
- `v.panel(id, spec)`: ersetzt das benannte schwebende Panel dieser Gruppe; null als `spec` entfernt es. Siehe Panels.
- `v.file(op, path, payload?)` → Anfrage-ID als Zeichenfolge. Siehe Dateien.
- `v.block(appId, on)`: true hält eine App-Blockierung aufrecht, false entfernt die Blockierung dieser Gruppe. Blockierungen werden über aktivierte Gruppen kombiniert; dieser Aufruf kann das Ziel einer anderen Gruppe nicht freigeben. Blockieren fordert normales Beenden an und wiederholt es im Einstellungsintervall; es verhindert keinen Prozessstart und garantiert nicht, dass eine App Beenden akzeptiert.
- `v.quit(appId)`: eine normale Beenden-Anfrage unter derselben Schutz-/Wiederholungsrichtlinie; keine fortlaufende Blockierung.
- `v.open(appId)`: fordert macOS auf, eine installierte App zu öffnen; kein Erfolgs-Callback.

Andere Aufrufe geben `undefined` zurück. App-IDs sind Bundle-Kennungen (beispielsweise `com.valvesoftware.steam`), die in Ereignissen verfügbar sind. Block/Quit können Apple-Apps und ganze Browser als Ziele verwenden. Sie ignorieren die Bundle-Kennung von Mac Vault und seine Helfer, einschließlich anderer Apps mit derselben Identität, sowie leere IDs. Panel-IDs/Zustand gehören zu einer Gruppe, nicht zu ihrem Anzeigenamen.

## Ereignisse

Die folgende Nutzdatennotation beschreibt Typen; sie ist kein ausführbarer Code. `?` kennzeichnet optionale Felder.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
App = { appId: string, name: string }
```

- `tick` ist näherungsweise; verwenden Sie Zeitstempel statt Tick-Zähler. Running enthält Vordergrund-, Menüleisten- und Hintergrundprozesse von `.app` mit Bundle-IDs; nicht jeden Unix-Prozess. Frontmost kann null sein oder eine leere App-ID haben.
- `app` meldet beobachtete Lebenszyklusänderungen vor dem `tick`-Ereignis dieses Ticks. Nur focus enthält `previousAppId` (null, falls unbekannt). Namen sind Anzeigenamen, keine stabilen IDs.
- `snooze` bedeutet, dass die Aufschieben-Schaltfläche der Gruppe gedrückt wurde. Es löst selbst keine Pause aus.
- Dateiantworten richten sich an die anfragende Gruppe. Ordnen Sie sie über `requestId` zu, prüfen Sie `ok` und setzen Sie mit Ticks eine Frist: Antworten können beim Neuladen/Deaktivieren der Regel verloren gehen. Anfrage-IDs können sich nach Ausführen wiederholen; ausstehende Anfragen sind keine dauerhaft gespeicherten Aufgaben.

## Bedienfelder

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Standardwerte: Position unten rechts, Breite 300px; Vorgaben small/medium/large sind 220/280/360px; numerische Breite wird auf 180–520px begrenzt und akzeptiert Pixelzeichenfolgen. Native Panels/Abschnitte ordnen Steuerelemente vertikal an; Browserfelder für Layout, Ausrichtung, Rolle, Autofokus und Steuerelementabmessungen beeinflussen den nativen Renderer nicht.

IDs werden auf ASCII-Buchstaben/-Ziffern/`_`/`-` normalisiert (maximal 80); wählen Sie eindeutige stabile IDs. Ohne Steuerelement-ID wird `control-N` verwendet, ohne/unbekanntem Typ text. Weggelassene Texte/Listen sind leer; disabled ist false. Jeder Aufruf ersetzt die gesamte Spezifikation. Ein ausdrückliches `value` überschreibt die gespeicherte Eingabe; ein weggelassener Wert verwendet den letzten Ereigniswert und anschließend die Typnormalisierung. Native Ereignisse liefern Zeichenfolgen: Parsen Sie sie in den deklarierten Werttyp, bevor Sie ein aktualisiertes Panel rendern. Unbekannte Felder werden verworfen; Panel-Farben/Schriften/CSS gehören zu Vault.

Steuerelementfelder und Anfangswerte:

- `text`: Zeichenfolge `text`; standardmäßig Beschriftung. `html`: Zeichenfolge `html`, bereinigt und auf Mac als Klartext angezeigt.
- `button`: `label`, optional `action: "submit" | "cancel" | "close"`. Der Klickwert ist die Aktionszeichenfolge oder leer. Aktionen senden/schließen nichts automatisch.
- `checkbox`, `toggle`: boolesches `value` (standardmäßig false); der Ereigniswert ist `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; Zeichenfolgenwert (standardmäßig leer). Leere Optionswerte werden entfernt; Beschriftungen entsprechen standardmäßig dem Wert. Aktualisieren Sie den typisierten Panelwert nach der Auswahl.
- `textInput`, `textarea`: Zeichenfolgenwert (standardmäßig leer); textInput `placeholder`; textarea `rows` 1–12 (standardmäßig 3). Native textarea ignoriert placeholder.
- `numberInput`, `range`: numerischer Wert (standardmäßig 0), `min`, `max`, positives `step`. Werte werden bei Panelaktualisierungen auf Grenzen begrenzt; nicht angegebene Normalisierungsgrenzen sind −1000000…1000000. Native numberInput ist eine Texteingabe: Validieren Sie `Number(event.value)` selbst; min/max/step begrenzen das Tippen nicht. Native range verwendet standardmäßig 0…100 mit Schritt 1.
- `date`, `time`: Texteingabe; Anfangswertformate `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (ungültige Anfangsformate werden leer). Validieren Sie Änderungen selbst. `color`: `#RRGGBB` (standardmäßig `#000000`).
- `pin`: Ziffernzeichenfolge; `length` 3–12 (standardmäßig 6), `masked` standardmäßig true, `autoSubmit` false. `section`: `text`, `controls`; untergeordnete Abschnitte bei Tiefe 3 haben keine Kinder (Wurzel-Steuerelemente Tiefe 0).

Panelereignisse: Gewöhnliche Eingaben senden `change`; Schaltflächen nur `click`; PIN sendet `change` und zusätzlich `submit`, wenn autoSubmit sie vollständig ausfüllt. Keine nativen mount/unmount/focus/key-Ereignisse. Werte sind Zeichenfolgen, auch Zahlen/boolesche Werte. `values` enthält die Eingabewerte des gerenderten Snapshots und kann hinter der auslösenden Änderung zurückliegen; `value` identifiziert diese Änderung. Speichern Sie sie in `v.state` und rendern Sie typisierte Werte für zuverlässige Formulare. Nicht-Klick-Ereignisse werden pro Steuerelement innerhalb von 100ms zusammengefasst; zählen Sie Ereignisse nicht als Tastendrücke.

Textlimits: title/label 240; description/text 1000; HTML 20000; placeholder 500; Eingabetext 2000; andere Wertezeichenfolgen 512; Optionswert/-beschriftung 256. Überschreitungen werden abgeschnitten.

## Dateien

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Erfordert **Ordner für benutzerdefinierte Regeln** in den Einstellungen und dessen Berechtigung.

- `path` ist relativ; `/` trennt Verzeichnisse. Segmente erlauben ASCII-Buchstaben/-Ziffern, Leerzeichen und `_.,@()-`; keinen führenden Punkt, `.`/`..`, absoluten Pfad oder URL. Dateiendungen: `.txt`, `.csv`, `.json` (Groß-/Kleinschreibung egal). Der List-Pfad ist ein Verzeichnis; `""` listet die gewählte Wurzel auf. Pfade, die den gewählten Ordner verlassen, auch durch symbolische Links, werden abgewiesen.
- Read liefert UTF-8-Text. Write ersetzt/erstellt; append erstellt/hängt ohne automatische neue Zeile an. Schreibvorgänge erstellen übergeordnete Verzeichnisse. Zeichenfolgen-Nutzdaten werden unverändert geschrieben; andere JSON-Nutzdaten werden serialisiert; null/weggelassen bedeutet leeren Text. JSON/CSV zu parsen ist Aufgabe der Regel. Maximale Dateigröße: 1048576 UTF-8-Bytes.
- List liefert direkt enthaltene sichtbare Unterverzeichnisse und unterstützte Dateien. Einträge: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension enthält bei Dateien den Punkt. Exists liefert für einen unterstützten Dateipfad einen booleschen Wert.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Ungenutzte Ergebnisfelder sind null; bei Erfolg ist error leer. Fehler umfassen invalid-path, unsupported-file-type, nicht verfügbaren Ordner, fehlende Datei und file-too-large. Behandeln Sie error als Zeichenfolge, nicht als festes vollständiges Enum. Keine Transaktions-API; führen Sie Lesen-Ändern-Schreiben-Vorgänge pro Pfad nacheinander aus.

## Gruppen-Datensätze

`v.store(request)` startet in einem Handler einen asynchronen JSON-Datensatzvorgang. Datensätze sind gruppenintern, bleiben über Run und Neustart erhalten und werden mit der Gruppe gelöscht. Verknüpfte Gruppen haben getrennte Datensätze. Schlüssel, Werte, Versionen, Cache-Invalidierung und Vorrang von Rückmeldungen bestimmt die Regel. Mac- und Browserregeln verwenden dieselbe API, aber getrennte Speicher je App/Browser.

| Anfrage | Ergebnis |
|---|---|
| `{op:"get", key}` | `record` oder `null` |
| `{op:"put", key, value, version?, ifRevision?}` | gespeicherter `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | sortierte `entries` und `next` |
| `{op:"clear", prefix?}` | Anzahl `deleted` |

Ein Datensatz hat `{value, revision, version, updatedAt}`. Die opake `revision` ändert sich bei echtem Schreiben; `version` sind vom Aufrufer verwaltete Metadaten. `list` gibt Header ohne Werte zurück; `get` liest einen Datensatz, `after: next` lädt die nächste Seite. Ohne `ifRevision` sind put/delete unbedingt; `null` verlangt einen fehlenden Schlüssel, eine Revisionszeichenfolge exakte Übereinstimmung. Bei Konflikt kommen `ok:false`, `error:"store-conflict"` und der aktuelle `record` zurück. So überschreibt eine verspätete automatische Antwort keine Benutzerrückmeldung. `v.context.revision` ist eine opake Konfigurationsmarke, die eine Regel in ihre Version aufnehmen kann. Das Framework gibt keine Cache-Regel vor.

Grenzen: Schlüssel 1–2048 Zeichen, Version ≤128, JSON-Wert ≤64KiB, Tiefe ≤32, 10000 Schlüssel je Gruppe, gesamtes Dokument 16MiB. `list` höchstens100 Header und96KiB je Seite. Maximal32 Anfragen je Gruppe und128 Starts pro Sekunde insgesamt; Überlast meldet einmal pro Gruppe/Sekunde `store-busy` und verwirft weitere Anfragen. Speicherfehler liefern `ok:false`; zukünftige/fehlerhafte Dokumente bleiben erhalten und melden `store-unavailable`. Keine automatische Wiederholung oder Bereinigung; Fristen mit ticks setzen.

## Grenzen

Pro Ereignis und Gruppe: 256 eingereihte Aktionen, 200 Log-Aufrufe, 64 Emits; Überschreitungen werden verworfen. Pro Regel: 1000 Handler, 24 Panels; jede Steuerelementliste hat 32 Einträge und jede Auswahl 64 Optionen; Überschreitungen werden ignoriert/abgeschnitten. Emit-Ketten stoppen nach 16 Generationen. Limit des serialisierten Zustands: 65536 UTF-8-Bytes. Halten Sie die Registrierung und die kombinierten Handler jedes Ereignisses unter 1 Sekunde; wiederholte Überschreitungen oder ein harter Timeout stoppen die Regel bis zum Ausführen. Das Log behält 200 Einträge pro Gruppe. Zeitsteuerung/Antworten erfolgen nach bestem Bemühen, ohne Echtzeitgarantie.

## Vollständige Regel

Steam wird blockiert, außer während einer fünfminütigen Pause, ausgelöst durch Aufschieben oder die Schaltfläche ihres Panels:

```javascript
(on, v) => {
  v.state.pauseUntil ??= 0;
  const pause = ev => { v.state.pauseUntil = ev.now + 300000; };
  v.panel("pause", { controls: [{ id: "pause", type: "button", label: "Pause 5 min" }] });
  on("snooze", pause);
  on("panel", ev => {
    if (ev.data.panelId === "pause" && ev.data.controlId === "pause" && ev.data.eventName === "click") pause(ev);
  });
  on("tick", ev => v.block("com.valvesoftware.steam", ev.now >= v.state.pauseUntil));
}
```

## KI-Aufrufe aus einer laufenden Regel

Jede benutzerdefinierte Gruppe wählt unter **AI calls** eine Verbindung/ein Modell und Reasoning effort. Mac- und Browserregeln verwenden dieselbe API. Browseranfragen benötigen ein verbundenes Mac Vault; Anbieterdaten bleiben dort. Verknüpfte Gruppen teilen Auswahl und optionales Tageslimit. Leer bedeutet kein Gruppenlimit; Kontolimits gelten weiter. Das Limit gilt pro UTC-Tag, bleibt nach Neustart bestehen und zählt gesendete Versuche einschließlich Fehlern. Verknüpfen addiert bisherigen Verbrauch; Trennen behält ihn.

`v.ai({ prompt, input? })` liefert sofort eine Request-ID. Innerhalb eines Handlers aufrufen, nicht bei der Registrierung. `input` kann jeder JSON-Wert sein; prompt und input sind je auf20KB begrenzt. Antworten kommen als `ai`-Events: `{requestId, ok, text, citations, error}`. Erfolgstext höchstens48KB; Zitate `{url,title}`. Bei Websuche sichtbare, anklickbare Quellenlinks beibehalten. Suche ist für das Modell immer verfügbar. Keine feste App-Frist, begrenzte Gleichzeitigkeit, kein Provider-Fallback und keine automatische Wiederholung. Antworten sind Daten und werden nicht als JavaScript ausgeführt; die Regel entscheidet über bestehende Aktionen.

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ prompt: "Summarize this text.", input: data.values?.note ?? "" });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

Offene Aufrufe werden nach Neustart nicht wiederholt. Run, Deaktivieren/Aktivieren und Löschen verwerfen alte Antworten; ein getrennter Browser meldet `ai-unavailable`. Weitere Fehler: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. Fehlgeschlagene Aufrufe überschreiben kein vorheriges, von der Regel behaltenes Ergebnis. Zustandslimit bleibt64KB.

Anmeldedatenfreie Optionen: Mac `rule_ai_models`, Browser `settings-rule-ai-models`. `ruleAI` über den vorhandenen set-group-Pfad konfigurieren. Felder: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`), `dailyRequestLimit` (null oder1–100000). Eine zurückgegebene Auswahl nutzen; keinen Schlüssel oder Anbieter-URL in den Regelquelltext schreiben.
