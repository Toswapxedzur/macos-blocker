# Podręcznik kodu Mac Vault

[Podręcznik użytkownika](../manual/pl.md)

## Zasady działania reguły

Source: jedno wyrażenie funkcji `(on, v) => { ... }`. Obsługiwane są tylko synchroniczne JavaScript i poniższe API; bez timers, network, native system APIs i dostępu do strony browser. Reguły czasowe używają `ev.now` i events. Reguły Safari korzystają z browser code manual i działają we własnej aplikacji kontenerowej Safari Vault.

- Edycja zapisuje wersję roboczą; **Run** aktywuje ją i włącza grupę. Zamrożonych grup nie można uruchomić przyciskiem Run. Pusty source wyładowuje regułę.
- Udany Run zastępuje handlers/panels i czyści app-block set tej grupy, zachowując `v.state`. Błąd kompilacji/rejestracji pozostawia poprzednią regułę; timeout może ją zatrzymać. Restart rejestruje ponownie ostatni aktywowany source; closure variables i app-block sets są resetowane.
- Rejestracja może inicjować state, rejestrować handlers, wyświetlać panels i zapisywać log. Akcje app/file i emits należą do handlers; kolejka rejestracji jest odrzucana.
- Disable wstrzymuje handlers i usuwa panels/app blocks. Enable przywraca załadowaną regułę i zachowane panels/blocks. Delete usuwa handlers/state/effects. Wcześniej zamknięte aplikacje nie są otwierane ponownie; zapisy plików nie są cofane.
- Events nie są ograniczone zwykłymi celami grupy; wybieraj aplikacje w regule. Actions trafiają do kolejki i są stosowane po dispatch. Wyjątki zatrzymują handler bez cofania state/actions; kolejne handlers mogą nadal działać. Tylko file actions mają result events.

## API

- `on(type, handler)` → boolean. Rejestruje `handler(ev)`; wiele handlers działa w kolejności rejestracji. False oznacza nieprawidłowe argumenty lub osiągnięcie limitu handlerów. `ev = { type: string, now: number, data }`; `now` to milisekundy Unix.
- `v.state`: modyfikowalny obiekt JSON, zapisywany po event dispatch. Inicjalizuj brakujące fields zamiast nadpisywać istniejący state. Przypisanie non-object lub tablicy resetuje go do `{}`; aktualizacje niepodlegające serializacji lub zbyt duże nie są zapisywane.
- `v.log(...values)`: jedyny twórca Log tej grupy. Logs/Clear są niezależne dla grup. Błędy ładowania pojawiają się w statusie Run; diagnostyka handlerów nie trafia do Log.
- `v.emit(type, data)`: umieszcza kopię JSON `data` w kolejce handlers tej grupy po bieżącym evencie, ze świeżym `now`; to nie jest wywołanie synchroniczne.
- `v.panel(id, spec)`: zastępuje nazwany pływający panel grupy; null `spec` go usuwa. Zobacz Panels.
- `v.file(op, path, payload?)` → string request ID. Zobacz Files.
- `v.block(appId, on)`: true utrzymuje blokadę aplikacji, false usuwa blokadę tej grupy. Blokady włączonych grup łączą się; to wywołanie nie odblokuje celu innej grupy. Blokowanie żąda normalnego zamknięcia i ponawia je w odstępie ustawionym w Settings; nie zapobiega uruchomieniu procesu ani nie gwarantuje, że aplikacja zaakceptuje Quit.
- `v.quit(appId)`: jedna prośba o normalne zamknięcie zgodnie z tą samą ochroną/zasadami ponawiania; bez stałej blokady.
- `v.open(appId)`: prosi macOS o otwarcie zainstalowanej aplikacji; nie ma callbacku powodzenia.

Pozostałe wywołania zwracają `undefined`. App IDs to bundle identifiers (np. `com.valvesoftware.steam`), dostępne w events. Block/Quit ignorują `com.apple.*`, przeglądarki, Vault i jego helpery oraz puste IDs. Panel IDs/state należą do grupy, nie do wyświetlanej nazwy.

## Events

Notacja payload opisuje typy, nie kod wykonywalny. `?` oznacza opcjonalne fields.

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

- `tick` jest przybliżony; używaj timestamps, nie liczby ticków. Running obejmuje procesy `.app` foreground, menu-bar i background z bundle IDs; nie każdy proces Unix. Frontmost może być null lub mieć puste app ID.
- `app` zgłasza zaobserwowane zmiany cyklu życia przed `tick` event tego ticka. Tylko focus zawiera `previousAppId` (null, gdy nieznany). Nazwy są wyświetlane, a nie stabilne IDs.
- `snooze` oznacza naciśnięcie przycisku Snooze grupy. Samo nie powoduje pauzy.
- Odpowiedzi file trafiają do grupy żądającej. Dopasuj `requestId`, sprawdź `ok` i ustaw deadline przy użyciu ticks: odpowiedzi mogą zaginąć po przeładowaniu/wyłączeniu reguły. Request IDs mogą się powtarzać po Run; oczekujące requests nie są trwałą pracą.

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Domyślnie: prawy dół, szerokość 300px; presety small/medium/large to 220/280/360px; szerokość liczbowa ograniczona do 180–520px, obsługuje pixel strings. Natywne panels/sections układają controls pionowo; browser layout, alignment, role, autofocus i control-dimension fields nie wpływają na native renderer.

IDs normalizują się do ASCII letters/digits/`_`/`-` (maks. 80); wybieraj unikalne, stabilne IDs. Pominięte control ID staje się `control-N`; pominięty/nieznany type staje się text. Pominięte text/lists są puste; disabled to false. Każde wywołanie zastępuje całą spec. Jawne `value` ma pierwszeństwo; bez niego używana jest ostatnia event value, a potem normalizacja typu. Native events dostarczają strings: sparsuj je do zadeklarowanego value type przed renderowaniem panelu. Nieznane fields są odrzucane; panel colors/fonts/CSS należą do Vault.

Pola i wartości początkowe controls:

- `text`: string `text`; domyślnie label. `html`: string `html`, oczyszczany i wyświetlany jako zwykły tekst na Mac.
- `button`: `label`, opcjonalne `action: "submit" | "cancel" | "close"`. Click value to ciąg action albo pusty. Actions same niczego nie przesyłają/nie zamykają.
- `checkbox`, `toggle`: boolean `value` (domyślnie false); event value to `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (domyślnie pusty). Puste option values są usuwane; labels domyślnie równe value. Po wyborze zaktualizuj typowaną wartość panelu.
- `textInput`, `textarea`: string value (domyślnie pusty); textInput `placeholder`; textarea `rows` 1–12 (domyślnie 3). Native textarea ignoruje placeholder.
- `numberInput`, `range`: numeric value (domyślnie 0), `min`, `max`, dodatni `step`. Przy aktualizacji panelu values ograniczane są do granic; nieokreślone granice normalizacji to −1000000…1000000. Native numberInput to pole tekstowe: samodzielnie sprawdź `Number(event.value)`; min/max/step nie ograniczają wpisywania. Native range domyślnie 0…100 z step 1.
- `date`, `time`: tekst; formaty początkowe `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (nieprawidłowe formaty stają się puste). Samodzielnie sprawdzaj zmiany. `color`: `#RRGGBB` (domyślnie `#000000`).
- `pin`: ciąg cyfr; `length` 3–12 (domyślnie 6), `masked` domyślnie true, `autoSubmit` false. `section`: `text`, `controls`; child sections na depth 3 nie mają children (root controls depth 0).

Panel events: zwykłe wejścia wysyłają `change`; buttons tylko `click`; PIN wysyła `change` oraz `submit`, gdy autoSubmit zostanie wypełnione. Brak native mount/unmount/focus/key events. Values to strings, również dla numbers/booleans. `values` zawiera wartości wejściowe wyrenderowanej migawki i może nie uwzględniać wywołującej zmiany; `value` wskazuje tę zmianę. Zapisuj w `v.state` i renderuj typowane values dla niezawodnych formularzy. Non-click events są łączone w ciągu 100ms dla każdego control; nie licz ich jako naciśnięć klawiszy.

Limity tekstu: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; inne value strings 512; option value/label 256. Nadmiar jest obcinany.

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Wymaga **Folderu reguł niestandardowych** w Settings i jego uprawnienia.

- `path` jest względny; `/` oddziela katalogi. Segmenty dopuszczają ASCII letters/digits, spacje i `_.,@()-`; bez początkowej kropki, `.`/`..`, absolute path lub URL. Rozszerzenia: `.txt`, `.csv`, `.json` (bez rozróżniania wielkości liter). List path to directory; `""` wyświetla wybrany root. Ścieżki poza wybrany folder, również przez symlinks, są odrzucane.
- Read zwraca tekst UTF-8. Write zastępuje/tworzy; append tworzy/dopisuje bez automatycznego newline. Katalogi nadrzędne tworzone są podczas zapisu. String payload zapisywany dosłownie; inne JSON payloads serializowane; null/pominięcie oznacza pusty tekst. Parsowanie JSON/CSV należy do reguły. Maksymalny rozmiar pliku: 1048576 UTF-8 bytes.
- List zwraca bezpośrednio widoczne podkatalogi i obsługiwane pliki. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension pliku zawiera kropkę. Exists zwraca boolean dla obsługiwanego file path.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Nieużywane result fields są null; sukces ma pusty error. Błędy obejmują invalid-path, unsupported-file-type, folder unavailable, missing file i file-too-large. Traktuj error jako string, nie stały pełny enum. Brak transaction API; serializuj operacje read-modify-write dla każdego path.

## Limity

Na event na group: 256 queued actions, 200 log calls, 64 emits; nadmiar jest odrzucany. Na rule: 1000 handlers, 24 panels; każda control list ma 32 entries, a każdy choice 64 options; nadmiar ignorowany/obcinany. Emit chains zatrzymują się po 16 generacjach. Serialized state limit: 65536 JavaScript string characters. Utrzymuj registration i łączne handlers każdego event poniżej 1 sekundy; powtarzające się przekroczenia lub hard timeout zatrzymują regułę do Run. Log przechowuje 200 entries na grupę. Timing/replies są best-effort, bez gwarancji czasu rzeczywistego.

## Pełna reguła

Steam jest blokowany, z wyjątkiem pięciominutowej pauzy uruchomionej przez Snooze lub jego panel button:

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
