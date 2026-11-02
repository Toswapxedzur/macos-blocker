# Adamancia Vault — Codehandleiding voor Mac

[Gebruikershandleiding](../manual/nl.md)

## Contract van de regel

Source: één functie-expressie `(on, v) => { ... }`. Alleen synchrone JavaScript en de onderstaande API worden ondersteund; geen JavaScript-planningscallbacks, netwerk, native systeem-API's of browserpaginatoegang. Tijdregels gebruiken de hieronder beschreven beheerde timers/trackers, of `ev.now` en events. Safari-regels gebruiken de browsercodemanual en draaien in de eigen container-app van Safari Vault.

- Wijzigingen slaan een concept op; **Run** activeert de regel en schakelt de groep in. Bevroren groepen kunnen niet Run uitvoeren. Een lege source laadt de regel uit.
- Een geslaagde Run vervangt handlers/panels en wist de app-block set van de groep, met behoud van `v.state`. Bij compilatie-/registratiefouten blijft de vorige regel behouden; een timeout kan deze stoppen. Restart registreert de laatst geactiveerde source opnieuw; closure variables en app-block sets worden gereset.
- Registratie kan state initialiseren, handlers registreren, panels tonen en loggen. App-/bestandsacties en emits horen in handlers; de wachtrij tijdens registratie wordt weggegooid.
- Disable onderdrukt handlers en heft panels/app blocks op. Enable herstelt de geladen regel en bewaarde panels/blocks. Delete verwijdert handlers/state/effecten. Eerder afgesloten apps worden niet opnieuw geopend; bestandsschrijfacties worden niet ongedaan gemaakt.
- Events zijn niet beperkt tot gewone groepsdoelen; kies apps in de regel. Acties worden in de wachtrij gezet en na dispatch toegepast. Exceptions stoppen die handler zonder state/actions terug te draaien; volgende handlers kunnen nog werken. Alleen file-acties hebben result-events.

## Beheerde timers en voortschrijdend gebruik

`v.timer(id, {direction:"down", durationMs:300000})` maakt een benoemde afteltimer aan of retourneert deze, aanvankelijk gepauzeerd. Gebruik `{direction:"up"}` voor een opteltimer. De handle heeft `start()`, `pause()`, `resume()`, `reset()` en `snapshot()`. Start/resume zijn idempotent; reset keert terug naar gepauzeerd met nul verstreken tijd. Snapshotvelden omvatten `ready`, `error`, `elapsedMs`, `remainingMs` (null bij optellen), `running` en `completed`.

Lopende timers gaan verder volgens de kloktijd terwijl de app/browser gesloten is of de regel uitgeschakeld is. Een voltooide afteltimer levert `timerEnded` met `{id, direction, durationMs, generation, incarnation}` eenmaal per timerincarnatie en generatie aan elk lid wanneer diens regel de volgende keer draait; Run herhaalt dit niet. Levering hangt af van events van de host; dit is geen realtimealarm. Plaats `{type:"timer", timerId:"focus", label:"Focus"}` in een panel om de timer via de bestaande tekstcontrol weer te geven.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` maakt een benoemde tracker voor actief gebruik aan of retourneert deze. `assign({websites:["youtube.com","reddit.com"], apps:[]})` vervangt de doeltoewijzingen van dit lid. Native regels kunnen in plaats daarvan platformgebonden app-IDs toewijzen. Domeinen omvatten subdomeinen. Eén tracker bundelt zijn doelen; andere IDs hebben onafhankelijke tegoeden. `snapshot()` retourneert `ready`, `error`, `usedMs`, `remainingMs`, `available` en `nextReturnAtMs` (de eerstvolgende milliseconde waarop enig vastgelegd gebruik vervalt). `available(target?)` controleert ook de toewijzing wanneer een doel wordt meegegeven. `reset()` wist de geschiedenis van dit object.

Al het waargenomen gebruik dat aan de voorwaarden voldoet telt mee, ook gebruik boven het tegoed; de tracker blokkeert zelf geen pagina/app. Overlappende intervallen van zichtbare pagina's tellen eenmaal, en native apps tellen waargenomen gebruik op de voorgrond. Uitgeschakelde regels voegen geen gebruik toe; geschiedenis vervalt nog steeds op de exacte intervalgrenzen. Beschikbaarheid keert pas terug wanneer de resterende geschiedenis onder de limiet ligt. Heartbeatmetingen zijn begrensd tot vijf seconden; onderbrekingen door afsluiten/uitschakelen creëren geen activiteit. Door de gebruiker uitgezonden events voegen geen gebruik toe.

Dezelfde object-IDs in gekoppelde aangepaste groepen delen één lokale native-hubautoriteit. Koppelen voegt trackergeschiedenis en toewijzingen samen en behoudt de timerstatus van de initiatiefnemer; incompatibele configuraties weigeren de koppeling. Elk lid ontvangt zijn eigen voltooiingsevent. Bij verbindingsverlies worden gedeelde trackers onbeschikbaar en worden timerbedieningen geweigerd totdat een actuele autoriteit terugkeert. Bij ontkoppelen behoudt elk lid het uiteindelijke gedeelde gebruik en de timerstatus, herstelt zijn eigen doelen en laat opdrachten van de oude koppeling vallen. De hub bewaart de laatste snapshot totdat het terugkerende lid deze opslaat en bevestigt; openstaande overdrachten worden voltooid voordat een nieuwe koppeling beschikbaar wordt.

Benoemde objecten overleven Run en herstarten in het gereserveerde `v.state.$vaultTime`; bewerk dat veld niet rechtstreeks. Verwijder ze expliciet met `v.removeTime(id)`. IDs zijn 1–80 ASCII-letters, cijfers, `_` of `-`; gereserveerde eigenschapsnamen worden geweigerd. Maximaal 32 objecten delen de statelimiet van 64 KiB UTF-8 van de regel. Tijdsduur wordt opgegeven in gehele milliseconden, tot 365 dagen. Voortschrijdende geschiedenis is begrensd tot 1024 minuutvakken en 2048 samengevoegde intervallen. Fouten door volle geschiedeniscapaciteit laten de tracker onbeschikbaar totdat deze expliciet wordt gereset; ongeldige configuraties en te grote opslagacties melden fouten zonder opgeslagen gegevens te wissen.

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

- `on(type, handler)` → boolean. Registreert `handler(ev)`; meerdere handlers worden in registratievolgorde uitgevoerd. False betekent ongeldige argumenten of de handlerlimiet bereikt. `ev = { type: string, now: number, origin: "host" | "user" | "rule", data }`; `now` is Unix-tijd in milliseconden. Native paneelinvoer heeft `origin: "user"`; `v.emit` heeft `origin: "rule"`.
- `v.state`: wijzigbaar JSON-object, opgeslagen na eventdispatch. Initialiseer ontbrekende fields in plaats van bestaande state te overschrijven. Toewijzing van een non-object of array reset naar `{}`; niet-serialiseerbare/te grote updates worden niet opgeslagen.
- `v.log(...values)`: voegt entries toe aan de Log van deze groep. Uitvoerings- en leveringsfouten verschijnen als expliciete foutentries in dezelfde feed. Logs/Clear zijn per groep onafhankelijk. Laadfouten staan ook in de Run-status; gedeeltelijk uitgevoerde events worden niet automatisch herhaald.
- `v.emit(type, data)`: zet een JSON-kopie van `data` in de wachtrij voor de handlers van deze groep na het huidige event, met een nieuwe `now`; dit is geen synchrone aanroep.
- `v.panel(id, spec)`: vervangt het benoemde zwevende panel van deze groep; null `spec` verwijdert het. Zie Panels.
- `v.file(op, path, payload?)` → request-ID-string. Zie Files.
- `v.store(request)` → tekenreeks met request-ID. Zie Groepsrecords.
- `v.block(appId, on)`: true houdt een app-blokkering actief, false verwijdert die van deze groep. Blokkeringen van ingeschakelde groepen worden gecombineerd; deze aanroep kan het doel van een andere groep niet deblokkeren. Blokkeren vraagt om normaal afsluiten en probeert opnieuw na het interval in Settings; het voorkomt geen processtart en garandeert niet dat een app Quit accepteert.
- `v.quit(appId)`: één normaal afsluitverzoek onder hetzelfde beveiligings-/herhaalbeleid; geen doorlopende blokkering.
- `v.open(appId)`: vraagt macOS een geïnstalleerde app te openen; geen succescallback.

Andere aanroepen retourneren `undefined`. App IDs zijn bundle identifiers (bijvoorbeeld `com.valvesoftware.steam`), beschikbaar in events. Block/Quit kunnen Apple-apps en volledige browsers als doel hebben. Ze negeren de bundle identifier van Vault en de helpers ervan, inclusief andere apps met diezelfde identiteit, en lege IDs. Panel IDs/state horen bij één groep, niet bij de weergavenaam.

## Gebeurtenissen

De payloadnotatie hieronder beschrijft typen en is geen uitvoerbare code. `?` markeert optionele fields.

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

- `tick` is bij benadering; gebruik timestamps in plaats van ticks te tellen. Running omvat foreground-, menu-bar- en background `.app`-processen met bundle IDs; niet elk Unix-proces. Frontmost kan null zijn of een lege app-ID hebben.
- `app` meldt waargenomen levenscycluswijzigingen vóór het `tick`-event van die tick. Alleen focus bevat `previousAppId` (null als onbekend). Namen zijn weergavenamen, geen stabiele IDs.
- `snooze` betekent dat de Snooze-knop van de groep is ingedrukt. Dit pauzeert zelf niets.
- File-antwoorden gaan naar de aanvragende groep. Koppel `requestId`, controleer `ok` en stel een deadline met ticks in: antwoorden kunnen verloren gaan als de regel wordt herladen/uitgeschakeld. Request IDs kunnen na Run herhaald worden; openstaande verzoeken zijn geen duurzaam werk.

## Panelen

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

## Bestanden

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

## Groepsrecords

`v.store(request)` start binnen een handler een asynchrone JSON-recordbewerking. Records zijn privé per groep, blijven bestaan na Run en herstart en worden met de groep verwijderd. Gekoppelde groepen hebben aparte stores. De regel kiest sleutels, waarden, versies, cache-invalidatie en voorrang van feedback. Mac- en browserregels gebruiken dezelfde API, maar elke app/browser heeft een eigen store.

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` of `null` |
| `{op:"put", key, value, version?, ifRevision?}` | opgeslagen `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | gesorteerde `entries` en `next` |
| `{op:"clear", prefix?}` | aantal `deleted` |

Een record bevat `{value, revision, version, updatedAt}`. De ondoorzichtige revision verandert bij een echte schrijfoperatie; `version` is metadata van de aanroeper. `list` retourneert headers zonder waarden; gebruik `get` om er een te lezen en `after: next` voor de volgende pagina. Zonder `put`/`delete`, `ifRevision` zijn put/delete onvoorwaardelijk; `null` vereist een ontbrekende sleutel, een revision-string een exacte overeenkomst. Een conflict retourneert `ok:false`, `error:"store-conflict"` en de huidige `record`. Zo overschrijft een late automatische reactie geen gebruikersfeedback. `v.context.revision` is een ondoorzichtige configuratiemarker die een regel in zijn versie kan opnemen. Het framework legt geen cachebeleid op.

Limieten: sleutel 1–2048 tekens, versie ≤128, JSON-waarde ≤64KiB, diepte ≤32, 10000 sleutels per groep, volledig document16MiB. `list` retourneert maximaal100 headers en96KiB per pagina. Maximaal32 verzoeken per groep en128 starts per seconde totaal. Bij overbelasting meldt het systeem één `store-busy` per groep per seconde en laat overige verzoeken vallen. Opslagfouten geven `ok:false`; toekomstige of beschadigde documenten blijven behouden en melden `store-unavailable`. Geen automatische retry of verwijdering. Gebruik ticks voor deadlines.

## Limieten

Per event per groep: 256 acties in de wachtrij, 200 logaanroepen, 64 emits; het meerdere wordt weggegooid. Per regel: 1000 handlers, 24 panels; elke lijst met controls heeft 32 entries en elke keuzelijst 64 opties; het meerdere wordt genegeerd/afgekapt. Emitketens stoppen na 16 generaties. Limiet voor geserialiseerde state: 65536 UTF-8-bytes. Houd registratie en de gecombineerde handlers van elk event onder 1 seconde; herhaalde overschrijdingen of een harde timeout stoppen de regel tot Run. Log bewaart 200 entries per groep. Timing/antwoorden zijn naar beste vermogen, zonder realtimegaranties.

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


## AI-aanroepen vanuit een actieve regel

Elke `v.ai`-aanroep vermeldt verbinding en model; er is geen groepsstandaard. Kopieer een model-ID uit **AI calls** of bekijk de catalogus zonder referenties via Vaults regeltool voor AI-modellen. De redeneerkracht kies je per aanroep. Browserverzoeken vereisen een verbonden desktop-Vault; providerreferenties blijven daar. Gekoppelde groepen delen de optionele dagelijkse aanvraaglimiet. Leeg betekent geen groepslimiet; accountlimieten gelden wel. De limiet volgt de UTC-dag, blijft na herstart bestaan en telt ingediende pogingen, ook mislukte. Koppelen voegt bestaand gebruik samen; ontkoppelen behoudt het.

De optioneel opgeslagen prompt en context worden gedeeld door gekoppelde groepen en blijven na herstart bestaan. Ze zijn in handlers beschikbaar als `v.context.ai.prompt` en `v.context.ai.context`; Vault verzendt ze niet automatisch. De regel bepaalt wat elke `v.ai`-aanroep bevat. Wijziging van een van beide maakt antwoorden van de oude configuratie ongeldig.

`conversation` is een optionele naam. Zonder naam is de aanroep stateless. Met een naam bewaart desktop-Vault lokaal het volledige transcript van gebruiker en assistent en voegt het bij de volgende aanroep maximaal16KB van de nieuwste berichten toe. Dezelfde conversatie kan van model wisselen; alleen overdraagbare tekst gaat naar het nieuwe model. De naam wordt gedeeld door alle regels en groepen op dit apparaat. Een groep verwijderen of ontkoppelen laat benoemde conversaties bestaan. De totale lokale transcriptlimiet is standaard1 GB en kan in Vault-instellingen worden gewijzigd. Als de limiet vol is, verwijdert Vault de minst recent gebruikte conversaties. Als een eerdere privébuild per groep afzonderlijke geschiedenissen met dezelfde naam bewaarde, importeert Vault beide onder verschillende namen en meldt de gewijzigde namen als `preservedConversations`.

Gebruik `v.ai({op:"delete", conversation:"name"})` om een gedeelde conversatie expliciet te verwijderen; het antwoord komt als `ai`-event. Een actieve aanroep met dezelfde naam geeft `ai-conversation-busy`; probeer het na het antwoord opnieuw. Een opslagfout wordt gemeld in plaats van een geslaagd antwoord stilzwijgend te verliezen. Conversatietekst wordt niet automatisch aan de gewone regelstatus toegevoegd.

`v.ai({ model, reasoningEffort?, conversation?, prompt, input? })` geeft direct een aanvraag-ID terug. Roep dit aan in een handler, niet bij het registreren van de regel. `model` is een beschikbaar model-ID; effort is `default` als die ontbreekt, of `low`, `medium`, `high` indien ondersteund. `input` kan elke JSON-waarde zijn; prompt/input is elk beperkt tot20KB. Antwoorden komen als `ai`-events: `{requestId, ok, text, citations,
error, preservedConversations?}` Succesvolle tekst is maximaal48KB; citaties hebben de vorm `{url,title}`..
Houd bronlinks zichtbaar en aanklikbaar bij antwoorden op basis van webzoeken. Zoeken is altijd beschikbaar voor het model. Generatie heeft geen vaste app-deadline. Meerdere benoemde conversaties kunnen tegelijk lopen; oproepen met dezelfde naam worden op volgorde uitgevoerd. Start de volgende aanroep vanuit een `ai`-event. Vault plant nog geen uitgestelde aanroepen. Providercapaciteit en quota kunnen verzoeken vertragen of weigeren; er is geen providerfallback of automatische nieuwe poging. Antwoorden zijn gegevens en worden nooit als JavaScript uitgevoerd. De regel kiest welke bestaande acties worden uitgevoerd.

Voor een paneel met een `ask`-knop en `note`-veld:

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ model: "chatgpt:MODEL_ID", conversation: "notes", prompt: v.context.ai.prompt || "Summarize this text.", input: {context:v.context.ai.context, note:data.values?.note ?? ""} });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

Openstaande oproepen worden na herstart niet opnieuw afgespeeld. Run, uitschakelen/opnieuw inschakelen en verwijderen laten verouderde antwoorden vervallen; een niet-verbonden browser meldt `ai-unavailable`. Andere fouten: `ai-not-configured`, `ai-invalid-input`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable` en `ai-conversation-storage-unavailable`. Mislukte oproepen overschrijven geen eerder resultaat dat de regel behield. De regelstatus blijft beperkt tot64KB.

Tools kunnen keuzes zonder referenties vinden met `rule_ai_models` op Mac of `settings-rule-ai-models` in de browser en `ruleAI` instellen via het bestaande set-group-pad. Velden: `dailyRequestLimit` (null of1–100000), `prompt` en `context` (optionele strings, elk maximaal16KB). Model en effort worden per aanroep opgegeven; er is geen opgeslagen groepsstandaard. Gebruik een geretourneerde keuze; zet geen sleutel of provider-URL in de regelbron.
