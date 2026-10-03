# Manuale del codice Mac Vault

[Manuale utente](../manual/it.md)

## Contratto della regola

Source: una sola espressione di funzione `(on, v) => { ... }`. Sono supportati solo JavaScript sincrono e l'API seguente; niente timers, network, native system APIs o accesso alle pagine del browser. Le regole temporali usano `ev.now` ed events. Le regole Safari usano il manuale del codice browser e vengono eseguite nell'app contenitore di Safari Vault.

- Le modifiche salvano una bozza; **Run** attiva la regola e abilita il gruppo. I gruppi congelati non possono eseguire Run. Una source vuota scarica la regola.
- Un Run riuscito sostituisce handlers/panels e cancella l'app-block set del gruppo, mantenendo `v.state`. Se compilazione/registrazione fallisce, resta la regola precedente; un timeout può fermarla. Restart registra di nuovo l'ultima source attivata; closure variables e app-block sets vengono azzerati.
- La registrazione può inizializzare state, registrare handlers, mostrare panels e scrivere log. Azioni app/file ed emits appartengono agli handlers; la coda creata durante la registrazione viene scartata.
- Disable sospende gli handlers e rimuove panels/app blocks. Enable ripristina la regola caricata e i panels/blocks conservati. Delete rimuove handlers/state/effects. Le app già chiuse non vengono riaperte; le scritture di file non vengono annullate.
- Gli events non sono limitati agli obiettivi normali del gruppo; scegli le app nella regola. Gli actions vengono messi in coda e applicati dopo il dispatch. Le eccezioni fermano quell'handler senza ripristinare state/actions; gli handlers successivi possono ancora funzionare. Solo le azioni file hanno result events.

## API

- `on(type, handler)` → boolean. Registra `handler(ev)`; più handlers vengono eseguiti nell'ordine di registrazione. False indica argomenti non validi o limite degli handlers raggiunto. `ev = { type: string, now: number, data }`; `now` è Unix in millisecondi.
- `v.state`: oggetto JSON modificabile, salvato dopo l'event dispatch. Inizializza i fields mancanti senza sovrascrivere lo state esistente. Assegnare un non-object o un array lo reimposta a `{}`; aggiornamenti non serializzabili/troppo grandi non vengono salvati.
- `v.log(...values)`: unica fonte del Log del gruppo. Logs/Clear indipendenti per gruppo. Gli errori di caricamento appaiono nello stato Run; i diagnostici degli handlers non popolano Log.
- `v.emit(type, data)`: mette in coda una copia JSON di `data` per gli handlers del gruppo dopo l'event corrente, con un nuovo `now`; non è una chiamata sincrona.
- `v.panel(id, spec)`: sostituisce il panel floating nominato del gruppo; `spec` null lo rimuove. Vedi Panels.
- `v.file(op, path, payload?)` → stringa request ID. Vedi Files.
- `v.block(appId, on)`: true mantiene il blocco dell'app, false rimuove quello del gruppo. I blocchi dei gruppi abilitati si combinano; la chiamata non può sbloccare l'obiettivo di un altro gruppo. Il blocco richiede una chiusura normale e riprova all'intervallo di Settings; non impedisce l'avvio del processo né garantisce che l'app accetti Quit.
- `v.quit(appId)`: una richiesta di chiusura normale secondo la stessa policy di protezione/tentativo; non è un blocco continuo.
- `v.open(appId)`: chiede a macOS di aprire un'app installata; non restituisce callback di successo.

Le altre chiamate restituiscono `undefined`. Gli App IDs sono bundle identifiers (per esempio `com.valvesoftware.steam`), disponibili negli events. Block/Quit ignorano `com.apple.*`, i browser, Vault e i suoi helper, oltre agli ID vuoti. IDs/state dei panel appartengono al gruppo, non al nome visualizzato.

## Events

La notazione del payload descrive i tipi, non è codice eseguibile. `?` indica fields facoltativi.

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

- `tick` è approssimativo; usa timestamps, non il conteggio dei tick. Running include processi `.app` foreground, menu-bar e background con bundle IDs; non tutti i processi Unix. Frontmost può essere null o avere un app ID vuoto.
- `app` segnala i cambiamenti di ciclo di vita osservati prima dell'event `tick` di quel tick. Solo focus include `previousAppId` (null se sconosciuto). I nomi sono nomi visualizzati, non ID stabili.
- `snooze` indica che è stato premuto il pulsante Snooze del gruppo. Non applica una pausa da solo.
- Le risposte file sono inviate al gruppo richiedente. Abbina `requestId`, controlla `ok` e imposta una scadenza con ticks: le risposte possono perdersi se la regola viene ricaricata o disabilitata. I request ID possono ripetersi dopo Run; le richieste in sospeso non sono lavoro durevole.

## Panels

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

## Files

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

## Limiti

Per event per group: 256 queued actions, 200 log calls, 64 emits; l'eccesso viene scartato. Per rule: 1000 handlers, 24 panels; ogni control list ha 32 entries e ogni choice 64 options; l'eccesso viene ignorato/troncato. Le emit chains terminano dopo 16 generazioni. Serialized state limit: 65536 JavaScript string characters. Mantieni registration e handlers combinati di ogni event sotto 1 secondo; superamenti ripetuti o hard timeout fermano la regola fino a Run. Log conserva 200 entries per gruppo. Timing/replies sono best-effort, non garanzie real-time.

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
