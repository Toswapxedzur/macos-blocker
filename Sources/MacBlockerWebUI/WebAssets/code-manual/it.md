# Manuale del codice Mac Vault

[Manuale utente](../manual/it.md)

## Contratto della regola

Source: una sola espressione di funzione `(on, v) => { ... }`. Sono supportati solo JavaScript sincrono e l’API seguente; nessun callback di pianificazione JavaScript, accesso alla rete, API native di sistema o accesso alle pagine del browser. Le regole temporali usano i timer/tracciatori gestiti descritti di seguito, oppure `ev.now` ed eventi. Le regole Safari usano il manuale del codice browser e vengono eseguite nell'app contenitore di Safari Vault.

- Le modifiche salvano una bozza; **Run** attiva la regola e abilita il gruppo. I gruppi congelati non possono eseguire Run. Una source vuota scarica la regola.
- Un Run riuscito sostituisce handlers/panels e cancella l'app-block set del gruppo, mantenendo `v.state`. Se compilazione/registrazione fallisce, resta la regola precedente; un timeout può fermarla. Restart registra di nuovo l'ultima source attivata; closure variables e app-block sets vengono azzerati.
- La registrazione può inizializzare state, registrare handlers, mostrare panels e scrivere log. Azioni app/file ed emits appartengono agli handlers; la coda creata durante la registrazione viene scartata.
- Disable sospende gli handlers e rimuove panels/app blocks. Enable ripristina la regola caricata e i panels/blocks conservati. Delete rimuove handlers/state/effects. Le app già chiuse non vengono riaperte; le scritture di file non vengono annullate.
- Gli events non sono limitati agli obiettivi normali del gruppo; scegli le app nella regola. Gli actions vengono messi in coda e applicati dopo il dispatch. Le eccezioni fermano quell'handler senza ripristinare state/actions; gli handlers successivi possono ancora funzionare. Solo le azioni file hanno result events.

## Timer gestiti e utilizzo a finestra mobile

`v.timer(id, {direction:"down", durationMs:300000})` crea o restituisce un conto alla rovescia con nome, inizialmente in pausa. Usa `{direction:"up"}` per un timer crescente. L’oggetto offre `start()`, `pause()`, `resume()`, `reset()` e `snapshot()`. Avvio/ripresa sono idempotenti; il ripristino riporta il timer in pausa con zero tempo trascorso. I campi dello snapshot includono `ready`, `error`, `elapsedMs`, `remainingMs` (null per il timer crescente), `running` e `completed`.

I timer in esecuzione avanzano in base al tempo reale trascorso mentre l’app/il browser è chiuso o la regola è disabilitata. Un conto alla rovescia completato invia `timerEnded` con `{id, direction, durationMs, generation, incarnation}` una volta per incarnazione e generazione del timer a ciascun membro quando la sua regola viene eseguita di nuovo; Run non lo ripete. La consegna dipende dagli eventi dell’host; non è una sveglia in tempo reale. Inserisci `{type:"timer", timerId:"focus", label:"Focus"}` in un pannello per visualizzarlo tramite il controllo di testo esistente.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` crea o restituisce un tracciatore con nome dell’utilizzo attivo. `assign({websites:["youtube.com","reddit.com"], apps:[]})` sostituisce le assegnazioni dei destinatari di questo membro. Le regole native possono invece assegnare identificatori di app della piattaforma. I domini includono i sottodomini. Un tracciatore raggruppa i propri destinatari; altri identificatori hanno quote indipendenti. `snapshot()` restituisce `ready`, `error`, `usedMs`, `remainingMs`, `available` e `nextReturnAtMs` (il prossimo millisecondo in cui scade un utilizzo registrato). `available(target?)` verifica anche l’assegnazione quando viene fornito un destinatario. `reset()` cancella la cronologia di questo oggetto.

Tutto l’utilizzo idoneo osservato viene conteggiato, anche oltre la quota; il tracciatore da solo non blocca pagine/app. Gli intervalli sovrapposti delle pagine visibili contano una sola volta e le app native conteggiano l’utilizzo osservato in primo piano. Le regole disabilitate non aggiungono utilizzo; la cronologia continua a scadere ai confini esatti degli intervalli. La disponibilità torna solo quando la cronologia rimanente è inferiore al limite. I campioni periodici sono limitati a cinque secondi; le interruzioni dovute a chiusura o disabilitazione non generano attività. Gli eventi emessi dall’utente non aggiungono utilizzo.

Gli stessi identificatori di oggetto nei gruppi personalizzati collegati condividono un’unica autorità locale nell’hub nativo. Il collegamento combina cronologia e assegnazioni dei tracciatori e mantiene lo stato del timer che avvia il collegamento; le configurazioni incompatibili impediscono il collegamento. Ogni membro riceve il proprio evento di completamento. La disconnessione rende indisponibili i tracciatori condivisi e rifiuta i comandi dei timer finché non torna disponibile un’autorità aggiornata. Quando il collegamento viene rimosso, ogni membro conserva l’utilizzo condiviso finale e lo stato del timer, ripristina i propri destinatari e scarta i comandi del vecchio collegamento. L’hub conserva lo snapshot finale finché il membro che ritorna non lo salva e ne conferma la ricezione; i trasferimenti in sospeso terminano prima che sia disponibile un nuovo collegamento.

Gli oggetti con nome sopravvivono a Run e al riavvio nel campo riservato `v.state.$vaultTime`; non modificare direttamente questo campo. Rimuovili esplicitamente con `v.removeTime(id)`. Gli identificatori sono composti da 1–80 lettere ASCII, cifre, `_` o `-`; i nomi di proprietà riservati vengono rifiutati. Fino a 32 oggetti condividono il limite di stato della regola di 64 KiB in UTF-8. Le durate sono millisecondi interi fino a 365 giorni. La cronologia mobile è limitata a 1024 contenitori da un minuto e 2048 intervalli uniti. Gli errori di capacità della cronologia lasciano il tracciatore indisponibile fino al ripristino esplicito; le configurazioni non valide e i salvataggi troppo grandi segnalano errori senza cancellare i dati salvati.

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

- `on(type, handler)` → booleano. Registra `handler(ev)`; più handler vengono eseguiti nell’ordine di registrazione. False indica argomenti non validi o il raggiungimento del limite di handler. `ev = { type: string, now: number, origin: "host" | "user" | "rule", data }`; `now` è in millisecondi Unix. L’input dei pannelli nativi ha `origin: "user"`; `v.emit` ha `origin: "rule"`.
- `v.state`: oggetto JSON modificabile, salvato dopo l'event dispatch. Inizializza i fields mancanti senza sovrascrivere lo state esistente. Assegnare un non-object o un array lo reimposta a `{}`; aggiornamenti non serializzabili/troppo grandi non vengono salvati.
- `v.log(...values)`: aggiunge voci al Log di questo gruppo. Gli errori di esecuzione e consegna appaiono come voci di errore esplicite nello stesso flusso. Logs/Clear sono indipendenti per gruppo. Gli errori di caricamento appaiono anche nello stato Run; gli eventi eseguiti parzialmente non vengono ripetuti automaticamente.
- `v.emit(type, data)`: mette in coda una copia JSON di `data` per gli handlers del gruppo dopo l'event corrente, con un nuovo `now`; non è una chiamata sincrona.
- `v.panel(id, spec)`: sostituisce il panel floating nominato del gruppo; `spec` null lo rimuove. Vedi Panels.
- `v.file(op, path, payload?)` → stringa request ID. Vedi Files.
- `v.store(request)` → stringa con l’ID della richiesta. Vedi Record di gruppo.
- `v.block(appId, on)`: true mantiene il blocco dell'app, false rimuove quello del gruppo. I blocchi dei gruppi abilitati si combinano; la chiamata non può sbloccare l'obiettivo di un altro gruppo. Il blocco richiede una chiusura normale e riprova all'intervallo di Settings; non impedisce l'avvio del processo né garantisce che l'app accetti Quit.
- `v.quit(appId)`: una richiesta di chiusura normale secondo la stessa policy di protezione/tentativo; non è un blocco continuo.
- `v.open(appId)`: chiede a macOS di aprire un'app installata; non restituisce callback di successo.

Le altre chiamate restituiscono `undefined`. Gli identificatori delle app sono identificatori di bundle (per esempio `com.valvesoftware.steam`), disponibili negli eventi. Block/Quit possono agire su app Apple e interi browser. Ignorano l’identificatore di bundle di Mac Vault e i suoi helper, incluse altre app che condividono la stessa identità, oltre agli ID vuoti. IDs/state dei panel appartengono al gruppo, non al nome visualizzato.

## Eventi

La notazione del payload descrive i tipi, non è codice eseguibile. `?` indica fields facoltativi.

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

- `tick` è approssimativo; usa timestamps, non il conteggio dei tick. Running include processi `.app` foreground, menu-bar e background con bundle IDs; non tutti i processi Unix. Frontmost può essere null o avere un app ID vuoto.
- `app` segnala i cambiamenti di ciclo di vita osservati prima dell'event `tick` di quel tick. Solo focus include `previousAppId` (null se sconosciuto). I nomi sono nomi visualizzati, non ID stabili.
- `snooze` indica che è stato premuto il pulsante Snooze del gruppo. Non applica una pausa da solo.
- Le risposte file sono inviate al gruppo richiedente. Abbina `requestId`, controlla `ok` e imposta una scadenza con ticks: le risposte possono perdersi se la regola viene ricaricata o disabilitata. I request ID possono ripetersi dopo Run; le richieste in sospeso non sono lavoro durevole.

## Pannelli

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Predefinito: posizione in basso a destra, larghezza 300px; preset small/medium/large 220/280/360px; la larghezza numerica è limitata a 180–520px e accetta pixel strings. I pannelli/sezioni native dispongono i controlli in verticale; i campi browser layout, alignment, role, autofocus e control-dimension non influenzano il renderer native.

Gli IDs vengono normalizzati in ASCII letters/digits/`_`/`-` (max 80); scegli IDs univoci e stabili. Un control ID omesso diventa `control-N`; type omesso/sconosciuto diventa text. text/lists omessi sono vuoti; disabled è false. Ogni chiamata sostituisce lo spec completo. `value` esplicito ha la precedenza; se omesso viene usato l'ultimo event value, quindi la normalizzazione del type. Gli events native forniscono strings: analizzale nel value type dichiarato prima di renderizzare il panel aggiornato. I fields sconosciuti vengono scartati; colori/fonts/CSS dei panel appartengono a Vault.

Campi e valori iniziali dei controlli:

- `text`: string `text`; predefinito al label. `html`: string `html`, sanificata e mostrata come testo semplice su Mac.
- `button`: `label`, `action: "submit" | "cancel" | "close"` facoltativo. Il valore click è la stringa action o vuoto. Gli actions non inviano/chiudono nulla automaticamente.
- `checkbox`, `toggle`: boolean `value` (predefinito false); l'event value è `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (predefinito vuoto). I valori option vuoti vengono rimossi; labels predefiniti uguali a value. Aggiorna il value tipizzato del panel dopo la selezione.
- `textInput`, `textarea`: string value (predefinito vuoto); textInput `placeholder`; textarea `rows` 1–12 (predefinito 3). La textarea native ignora placeholder.
- `numberInput`, `range`: numeric value (predefinito 0), `min`, `max`, `step` positivo. Negli aggiornamenti panel, i values restano entro i limiti; limiti di normalizzazione non specificati: −1000000…1000000. numberInput native è un campo testo: convalida `Number(event.value)` autonomamente; min/max/step non limitano la digitazione. Il range native va da 0…100 con step 1.
- `date`, `time`: testo; formati iniziali `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (formati non validi diventano vuoti). Convalida le modifiche autonomamente. `color`: `#RRGGBB` (predefinito `#000000`).
- `pin`: stringa di cifre; `length` 3–12 (predefinito 6), `masked` true per impostazione predefinita, `autoSubmit` false. `section`: `text`, `controls`; child sections al depth 3 non hanno children (root controls depth 0).

Panel events: gli input normali inviano `change`; i pulsanti solo `click`; PIN invia `change` e `submit` quando autoSubmit è completo. Nessun event native mount/unmount/focus/key. I values sono strings, inclusi numbers/booleans. `values` contiene gli input del rendered snapshot e potrebbe non includere l'ultima modifica; `value` identifica quella modifica. Salva in `v.state` e renderizza values tipizzati per moduli affidabili. Gli events diversi da click vengono raggruppati entro 100ms per control; non contarli come pressioni dei tasti.

Limiti testo: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; altre value strings 512; option value/label 256. L'eccesso viene troncato.

## File

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Richiede **Cartella regole personalizzate** in Settings e la relativa autorizzazione.

- `path` è relativo; `/` separa le directory. I segmenti consentono ASCII letters/digits, spazi e `_.,@()-`; niente punto iniziale, `.`/`..`, absolute path o URL. Estensioni: `.txt`, `.csv`, `.json` (senza distinzione maiuscole/minuscole). List path è una directory; `""` elenca la root scelta. I percorsi che escono dalla cartella scelta, anche tramite symlink, vengono rifiutati.
- Read restituisce testo UTF-8. Write sostituisce/crea; append crea/aggiunge senza newline automatico. Le directory genitore vengono create in scrittura. String payload viene scritto letteralmente; altri payload JSON vengono serializzati; null/omesso significa testo vuoto. Il parsing JSON/CSV è compito della regola. Dimensione massima file: 1048576 UTF-8 bytes.
- List restituisce sottodirectory e file supportati visibili immediatamente. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; sui file extension include il punto. Exists restituisce boolean per un file supportato.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

I result fields inutilizzati sono null; il successo ha error vuoto. Gli errori includono invalid-path, unsupported-file-type, folder unavailable, missing file e file-too-large. Considera error una stringa, non un enum esaustivo fisso. Non esiste una transaction API; serializza le operazioni read-modify-write per ogni path.

## Record del gruppo

`v.store(request)` avvia un’operazione asincrona di record JSON dentro un handler. I record sono privati del gruppo, persistono dopo Run e riavvio, e vengono eliminati con il gruppo. I gruppi collegati hanno store distinti. La regola sceglie chiavi, valori, versioni, invalidazione cache e priorità dei feedback. Le regole Mac e browser usano la stessa API, ma ogni app/browser ha uno store separato.

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` o `null` |
| `{op:"put", key, value, version?, ifRevision?}` | `record` salvato |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | `entries` ordinate e `next` |
| `{op:"clear", prefix?}` | conteggio `deleted` |

Ogni record è `{value, revision, version, updatedAt}`. revision opaco cambia con una scrittura reale; `version` è metadato scelto dal chiamante. `list` restituisce header senza valori; usa `get` per leggerne uno e `after: next` per la pagina successiva. Senza `put`/`delete`, `ifRevision`, put/delete sono incondizionati; `null` richiede chiave assente e una stringa revision una corrispondenza esatta. Un conflitto restituisce `ok:false`, `error:"store-conflict"` e il `record` attuale, evitando che una risposta automatica tardiva sovrascriva il feedback utente. `v.context.revision` è un marker opaco della configurazione che la regola può includere nella propria versione; il framework non impone politiche cache.

Limiti: chiave 1–2048 caratteri, version ≤128, valore JSON ≤64KiB, profondità ≤32, 10000 chiavi per gruppo e documento completo16MiB. `list` restituisce al massimo100 header e96KiB per pagina. Massimo32 richieste per gruppo e128 avvii al secondo complessivi; overload segnala un `store-busy` per gruppo al secondo e scarta le altre richieste. Errori di storage restituiscono `ok:false`; un documento futuro o malformato viene conservato e segnala `store-unavailable`. Nessun retry o eviction automatici; usa ticks per le deadline.

## Limiti

Per evento e gruppo: 256 azioni in coda, 200 chiamate di log, 64 emissioni; l’eccesso viene scartato. Per regola: 1000 handler, 24 pannelli; ogni elenco di controlli ha 32 voci e ogni selezione 64 opzioni; l’eccesso viene ignorato/troncato. Le catene di emissioni si fermano dopo 16 generazioni. Limite dello stato serializzato: 65536 byte UTF-8. Mantieni la registrazione e gli handler combinati di ogni evento sotto 1 secondo; superamenti ripetuti o un timeout rigido fermano la regola fino a Run. Il Log conserva 200 voci per gruppo. Tempi/risposte sono forniti al meglio delle possibilità, senza garanzie in tempo reale.

## Regola completa

Steam è bloccato tranne durante una pausa di cinque minuti attivata da Snooze o dal pulsante del suo panel:

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

## Chiamate IA da una regola in esecuzione

Ogni custom group sceglie una connessione/modello e reasoning effort in **AI calls**. Le regole Mac e browser usano la stessa API; le richieste browser richiedono Mac Vault collegato e le credenziali provider restano lì. I gruppi collegati condividono la selezione e un limite giornaliero facoltativo. Campo vuoto significa nessun limite di gruppo, ma restano i limiti account. Il limite usa il giorno UTC, persiste al riavvio e conta i tentativi inviati inclusi quelli falliti. Link combina l’uso già fatto; unlink mantiene l’uso precedente.

`v.ai({ prompt, input? })` restituisce subito un request ID. Chiamala dentro un handler, non durante la registrazione della regola. `input` può essere qualsiasi valore JSON; prompt/input sono limitati a20KB ciascuno. Le risposte arrivano come eventi `ai`: `{requestId, ok, text, citations,
error}`. Testo riuscito massimo48KB; citazioni `{url,title}`. Mantieni visibili e cliccabili i link alle fonti nelle risposte della ricerca Web. Search è sempre disponibile al modello. Nessuna deadline fissa dell’app, concorrenza limitata, nessun fallback provider o retry automatico. Le risposte sono dati, non vengono eseguite come JavaScript; la regola decide quali azioni esistenti intraprendere.

Per un pannello con un pulsante `ask` e un campo `note`:

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

Le chiamate pendenti non vengono riprodotte dopo il riavvio. Run, disabilita/riabilita ed elimina scartano risposte obsolete; un browser disconnesso segnala `ai-unavailable`. Altri errori: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. Le chiamate fallite non sovrascrivono un risultato precedente conservato dalla regola. Il limite di stato resta64KB.

Scopri opzioni senza credenziali con `rule_ai_models` su Mac o `settings-rule-ai-models` nel browser; configura `ruleAI` tramite il percorso set-group esistente. Campi: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) e `dailyRequestLimit` (null o1–100000). Usa una scelta restituita; non inserire chiavi o URL provider nel sorgente della regola.
