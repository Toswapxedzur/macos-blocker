# Mac Vault-codemanual

[Gebruikershandleiding](../manual/nl.md)

## Contract van de regel

Source: één functie-expressie `(on, v) => { ... }`. Alleen synchrone JavaScript en de onderstaande API worden ondersteund; geen timers, netwerk, native systeem-API's of browserpaginatoegang. Tijdregels gebruiken `ev.now` en events. Safari-regels gebruiken de browsercodemanual en draaien in de eigen container-app van Safari Vault.

- Wijzigingen slaan een concept op; **Run** activeert de regel en schakelt de groep in. Bevroren groepen kunnen niet Run uitvoeren. Een lege source laadt de regel uit.
- Een geslaagde Run vervangt handlers/panels en wist de app-block set van de groep, met behoud van `v.state`. Bij compilatie-/registratiefouten blijft de vorige regel behouden; een timeout kan deze stoppen. Restart registreert de laatst geactiveerde source opnieuw; closure variables en app-block sets worden gereset.
- Registratie kan state initialiseren, handlers registreren, panels tonen en loggen. App-/bestandsacties en emits horen in handlers; de wachtrij tijdens registratie wordt weggegooid.
- Disable onderdrukt handlers en heft panels/app blocks op. Enable herstelt de geladen regel en bewaarde panels/blocks. Delete verwijdert handlers/state/effecten. Eerder afgesloten apps worden niet opnieuw geopend; bestandsschrijfacties worden niet ongedaan gemaakt.
- Events zijn niet beperkt tot gewone groepsdoelen; kies apps in de regel. Acties worden in de wachtrij gezet en na dispatch toegepast. Exceptions stoppen die handler zonder state/actions terug te draaien; volgende handlers kunnen nog werken. Alleen file-acties hebben result-events.

## API

- `on(type, handler)` → boolean. Registreert `handler(ev)`; meerdere handlers werken in registratievolgorde. False betekent ongeldige argumenten of dat de handlerlimiet is bereikt. `ev = { type: string, now: number, data }`; `now` is Unix-milliseconden.
- `v.state`: wijzigbaar JSON-object, opgeslagen na eventdispatch. Initialiseer ontbrekende fields in plaats van bestaande state te overschrijven. Toewijzing van een non-object of array reset naar `{}`; niet-serialiseerbare/te grote updates worden niet opgeslagen.
- `v.log(...values)`: de enige producent van de Log van deze groep. Logs/Clear zijn per groep onafhankelijk. Laadfouten staan in Run-status; handlerdiagnostiek komt niet in Log.
- `v.emit(type, data)`: zet een JSON-kopie van `data` in de wachtrij voor de handlers van deze groep na het huidige event, met een nieuwe `now`; dit is geen synchrone aanroep.
- `v.panel(id, spec)`: vervangt het benoemde zwevende panel van deze groep; null `spec` verwijdert het. Zie Panels.
- `v.file(op, path, payload?)` → request-ID-string. Zie Files.
- `v.block(appId, on)`: true houdt een app-blokkering actief, false verwijdert die van deze groep. Blokkeringen van ingeschakelde groepen worden gecombineerd; deze aanroep kan het doel van een andere groep niet deblokkeren. Blokkeren vraagt om normaal afsluiten en probeert opnieuw na het interval in Settings; het voorkomt geen processtart en garandeert niet dat een app Quit accepteert.
- `v.quit(appId)`: één normaal afsluitverzoek onder hetzelfde beveiligings-/herhaalbeleid; geen doorlopende blokkering.
- `v.open(appId)`: vraagt macOS een geïnstalleerde app te openen; geen succescallback.

Andere aanroepen retourneren `undefined`. App IDs zijn bundle identifiers (bijvoorbeeld `com.valvesoftware.steam`) die beschikbaar zijn in events. Block/Quit negeren `com.apple.*`, browsers, Vault en de helpers ervan, en lege IDs. Panel IDs/state horen bij één groep, niet bij de weergavenaam.

## Events

De payloadnotatie hieronder beschrijft typen en is geen uitvoerbare code. `?` markeert optionele fields.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
App = { appId: string, name: string }
```

- `tick` is bij benadering; gebruik timestamps in plaats van ticks te tellen. Running omvat foreground-, menu-bar- en background `.app`-processen met bundle IDs; niet elk Unix-proces. Frontmost kan null zijn of een lege app-ID hebben.
- `app` meldt waargenomen levenscycluswijzigingen vóór het `tick`-event van die tick. Alleen focus bevat `previousAppId` (null als onbekend). Namen zijn weergavenamen, geen stabiele IDs.
- `snooze` betekent dat de Snooze-knop van de groep is ingedrukt. Dit pauzeert zelf niets.
- File-antwoorden gaan naar de aanvragende groep. Koppel `requestId`, controleer `ok` en stel een deadline met ticks in: antwoorden kunnen verloren gaan als de regel wordt herladen/uitgeschakeld. Request IDs kunnen na Run herhaald worden; openstaande verzoeken zijn geen duurzaam werk.

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Standaard: rechtsonder, breedte 300px; presets small/medium/large zijn 220/280/360px; numerieke breedte is begrensd tot 180–520px en accepteert pixel strings. Native panels/sections stapelen controls verticaal; browserlayout, alignment, role, autofocus en control-dimension-fields beïnvloeden de native renderer niet.

IDs worden genormaliseerd naar ASCII letters/cijfers/`_`/`-` (max. 80); kies unieke, stabiele IDs. Weggelaten control-ID wordt `control-N`; ontbrekende/onbekende type wordt text. Weggelaten text/lists zijn leeg; disabled is false. Elke aanroep vervangt de volledige spec. Expliciete `value` krijgt voorrang; zonder die waarde wordt de laatste eventwaarde gebruikt en daarna wordt het type genormaliseerd. Native events leveren strings: parse deze naar het opgegeven value-type voordat je het bijgewerkte panel rendert. Onbekende fields worden verwijderd; panelkleuren/fonts/CSS zijn van Vault.

Controlvelden en beginwaarden:

- `text`: string `text`; standaard label. `html`: string `html`, opgeschoond en op Mac als platte tekst weergegeven.
- `button`: `label`, optionele `action: "submit" | "cancel" | "close"`. Clickwaarde is de action-string of leeg. Actions submitten/sluiten niets automatisch.
- `checkbox`, `toggle`: boolean `value` (standaard false); eventwaarde is `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (standaard leeg). Lege option values verwijderd; labels standaard gelijk aan value. Werk de getypeerde panelwaarde na selectie bij.
- `textInput`, `textarea`: string value (standaard leeg); textInput `placeholder`; textarea `rows` 1–12 (standaard 3). Native textarea negeert placeholder.
- `numberInput`, `range`: numeric value (standaard 0), `min`, `max`, positieve `step`. Bij panelupdates worden values binnen de grenzen gehouden; niet-opgegeven normalisatiegrenzen zijn −1000000…1000000. Native numberInput is tekstinvoer: valideer `Number(event.value)` zelf; min/max/step beperken typen niet. Native range standaard 0…100 met step 1.
- `date`, `time`: tekstinvoer; beginformaten `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (ongeldige formaten worden leeg). Valideer wijzigingen zelf. `color`: `#RRGGBB` (standaard `#000000`).
- `pin`: cijferstring; `length` 3–12 (standaard 6), `masked` standaard true, `autoSubmit` false. `section`: `text`, `controls`; child sections op depth 3 hebben geen children (root controls depth 0).

Panel-events: gewone inputs sturen `change`; buttons alleen `click`; PIN stuurt `change` plus `submit` als autoSubmit is voltooid. Geen native mount/unmount/focus/key-events. Values zijn strings, ook numbers/booleans. `values` bevat invoerwaarden van de weergegeven momentopname en kan achterlopen op de triggerende wijziging; `value` geeft die wijziging aan. Sla de waarde op in `v.state` en render getypeerde values voor betrouwbare formulieren. Niet-click-events worden binnen 100ms per control samengevoegd; tel ze niet als toetsaanslagen.

Tekstlimieten: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; overige value strings 512; option value/label 256. Extra tekst wordt afgekapt.

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Vereist **Map voor aangepaste regels** in Settings en de bijbehorende machtiging.

- `path` is relatief; `/` scheidt directories. Segmenten mogen ASCII letters/cijfers, spaties en `_.,@()-` bevatten; geen voorloopdot, `.`/`..`, absolute path of URL. Bestandsextensies: `.txt`, `.csv`, `.json` (hoofdletterongevoelig). List path is een directory; `""` geeft de gekozen root weer. Paden buiten de gekozen map, ook via symlinks, worden geweigerd.
- Read retourneert UTF-8-tekst. Write vervangt/maakt; append maakt/voegt toe zonder automatische newline. Parent directories worden aangemaakt bij schrijven. String-payload wordt letterlijk geschreven; andere JSON-payloads worden geserialiseerd; null/weggelaten betekent lege tekst. JSON/CSV-parsing is taak van de regel. Maximale bestandsgrootte: 1048576 UTF-8 bytes.
- List retourneert direct zichtbare subdirectories en ondersteunde bestanden. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension bevat bij bestanden een punt. Exists retourneert een boolean voor een ondersteund bestandspad.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Ongebruikte result fields zijn null; succes heeft een lege error. Fouten omvatten invalid-path, unsupported-file-type, map niet beschikbaar, bestand ontbreekt en file-too-large. Behandel error als string, niet als vaste uitputtende enum. Er is geen transaction-API; serialiseer read-modify-write-bewerkingen per path.

## Limieten

Per event per group: 256 queued actions, 200 log calls, 64 emits; overschrijding wordt weggegooid. Per rule: 1000 handlers, 24 panels; elke control list heeft 32 entries en elke choice 64 options; overschrijding genegeerd/afgekapt. Emit chains stoppen na 16 generaties. Serialized state limit: 65536 JavaScript string characters. Houd registratie en gecombineerde handlers per event onder 1 seconde; herhaalde overschrijdingen of hard timeout stoppen de regel tot Run. Log bewaart 200 entries per groep. Timing/replies zijn best-effort, geen real-timegaranties.

## Volledige regel

Steam wordt geblokkeerd, behalve tijdens een pauze van vijf minuten gestart door Snooze of de panelknop ervan:

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
