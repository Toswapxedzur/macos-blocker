# Mac Vault kod kılavuzu

[Kullanıcı kılavuzu](../manual/tr.md)

## Kural sözleşmesi

Source: tek bir function expression `(on, v) => { ... }`. Yalnızca eşzamanlı JavaScript ve aşağıdaki API desteklenir; timers, network, native system APIs veya browser sayfasına erişim yoktur. Zamana dayalı kurallar `ev.now` ve events kullanır. Safari kuralları browser code manual kullanır ve Safari Vault'un kendi container app'i içinde çalışır.

- Düzenleme taslak kaydeder; **Run** kuralı etkinleştirip grubu açar. Dondurulmuş gruplar Run çalıştıramaz. Boş source kuralı kaldırır.
- Başarılı Run handlers/panels öğelerini değiştirir ve `v.state` değerini koruyarak bu grubun app-block set değerini temizler. Derleme/kayıt başarısızsa önceki kural korunur; timeout kuralı durdurabilir. Restart son etkinleştirilen source değerini yeniden kaydeder; closure variables ve app-block sets sıfırlanır.
- Kayıt state başlatabilir, handlers kaydedebilir, panels gösterebilir ve log yazabilir. Uygulama/dosya işlemleri ve emits handlers içinde olmalıdır; kayıt sırasındaki kuyruk atılır.
- Disable handlers değerlerini bastırır, panels/app blocks değerlerini kaldırır. Enable yüklü rule ile saklanan panels/blocks değerlerini geri yükler. Delete handlers/state/effects değerlerini kaldırır. Önceden kapatılan uygulamalar yeniden açılmaz; file writes geri alınmaz.
- Events normal grup targets değerleriyle sınırlı değildir; uygulamaları rule içinde seçin. Actions kuyruğa alınır ve dispatch sonrasında uygulanır. Exceptions, state/actions değerlerini geri almadan ilgili handler'ı durdurur; sonraki handlers çalışabilir. Yalnızca file actions result events içerir.

## API

- `on(type, handler)` → boolean. `handler(ev)` kaydeder; handlers kayıt sırasıyla çalışır. False, geçersiz arguments veya handler limitine ulaşıldığı anlamına gelir. `ev = { type: string, now: number, data }`; `now` Unix milisaniyesidir.
- `v.state`: event dispatch sonrasında kaydedilen değiştirilebilir JSON object. Mevcut state üzerine yazmak yerine eksik fields değerlerini başlatın. Non-object veya array atamak `{}` değerine sıfırlar; serileştirilemeyen/aşırı büyük güncellemeler kaydedilmez.
- `v.log(...values)`: bu grubun Log kaydının tek kaynağı. Logs/Clear her grupta bağımsızdır. Yükleme hataları Run durumunda görünür; handler diagnostics Log'u doldurmaz.
- `v.emit(type, data)`: geçerli event sonrasında bu grubun handlers değerlerine `data` öğesinin JSON kopyasını yeni bir `now` ile kuyruğa alır; eşzamanlı çağrı değildir.
- `v.panel(id, spec)`: grubun adlandırılmış floating panel değerini değiştirir; null `spec` paneli kaldırır. Panels'e bakın.
- `v.file(op, path, payload?)` → request ID string. Files'a bakın.
- `v.block(appId, on)`: true uygulama engelini sürdürür, false grubun engelini kaldırır. Etkin grupların engelleri birleşir; bu çağrı başka grubun hedefini engelden çıkaramaz. Engelleme normal kapatma ister ve Settings aralığında yeniden dener; process launch değerini engellemez veya uygulamanın Quit'ı kabul edeceğini garanti etmez.
- `v.quit(appId)`: aynı koruma/yeniden deneme ilkesiyle bir normal kapatma isteği; sürekli engelleme değildir.
- `v.open(appId)`: macOS'tan yüklü bir uygulamayı açmasını ister; başarı callback'i yoktur.

Diğer çağrılar `undefined` döndürür. App IDs bundle identifiers (örneğin `com.valvesoftware.steam`) olup events içinde bulunur. Block/Quit `com.apple.*`, tarayıcıları, Vault'u ve yardımcılarını ve boş IDs değerlerini yok sayar. Panel IDs/state grubuna aittir, görünen adına değil.

## Events

Aşağıdaki payload gösterimi yürütülebilir kod değil, types bilgisi verir. `?` isteğe bağlı fields alanlarını belirtir.

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

- `tick` yaklaşık değerdir; ticks saymak yerine timestamps kullanın. Running, bundle IDs bulunan foreground, menu-bar ve background `.app` süreçlerini içerir; her Unix sürecini içermez. Frontmost null veya boş app ID olabilir.
- `app`, o tick'in `tick` event değerinden önce gözlemlenen yaşam döngüsü değişikliklerini bildirir. Yalnızca focus `previousAppId` içerir (bilinmiyorsa null). Names görünen adlardır, kararlı IDs değildir.
- `snooze`, grubun Snooze düğmesine basıldığı anlamına gelir. Tek başına duraklama uygulamaz.
- File replies isteği yapan gruba gider. `requestId` ile eşleştirin, `ok` değerini denetleyin ve ticks ile deadline belirleyin: rule yeniden yüklenirse/devre dışı bırakılırsa replies kaybolabilir. Request IDs Run sonrasında tekrarlanabilir; bekleyen requests kalıcı iş değildir.

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Varsayılan: sağ alt konum, genişlik 300px; small/medium/large presetleri 220/280/360px; sayısal genişlik 180–520px aralığıyla sınırlıdır ve pixel strings kabul eder. Native panels/sections controls öğelerini dikey dizer; browser layout, alignment, role, autofocus ve control-dimension fields native renderer değerini etkilemez.

IDs ASCII letters/digits/`_`/`-` biçimine normalize edilir (en fazla 80); benzersiz ve kararlı IDs seçin. Atlanan control ID `control-N`, atlanan/bilinmeyen type text olur. Atlanan text/lists boş, disabled false olur. Her çağrı tüm spec değerini değiştirir. Açık `value` önceliklidir; atlanırsa son event value kullanılır, ardından type normalization uygulanır. Native events strings sağlar: güncellenmiş paneli oluşturmadan önce belirtilen value type değerine dönüştürün. Bilinmeyen fields atılır; panel colors/fonts/CSS Vault'a aittir.

Control alanları ve başlangıç değerleri:

- `text`: string `text`; varsayılan label olur. `html`: string `html`, sanitize edilir ve Mac'te düz metin olarak gösterilir.
- `button`: `label`, isteğe bağlı `action: "submit" | "cancel" | "close"`. Click value, action string veya boş olur. Actions otomatik olarak bir şeyi göndermez/kapatmaz.
- `checkbox`, `toggle`: boolean `value` (varsayılan false); event value `"true"`/`"false"` olur.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (varsayılan boş). Boş option values kaldırılır; labels varsayılan olarak value olur. Seçimden sonra panelin typed value değerini güncelleyin.
- `textInput`, `textarea`: string value (varsayılan boş); textInput `placeholder`; textarea `rows` 1–12 (varsayılan 3). Native textarea placeholder değerini yok sayar.
- `numberInput`, `range`: numeric value (varsayılan 0), `min`, `max`, pozitif `step`. Panel updates sırasında values sınırlar içinde tutulur; belirtilmeyen normalization sınırları −1000000…1000000. Native numberInput metin girişidir: `Number(event.value)` değerini kendiniz doğrulayın; min/max/step yazmayı sınırlamaz. Native range varsayılan 0…100 ve step 1 olur.
- `date`, `time`: metin girişi; başlangıç formatları `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (geçersiz başlangıç biçimleri boş olur). Düzenlemeleri kendiniz doğrulayın. `color`: `#RRGGBB` (varsayılan `#000000`).
- `pin`: rakam string'i; `length` 3–12 (varsayılan 6), `masked` varsayılan true, `autoSubmit` false. `section`: `text`, `controls`; depth 3'te child sections children içermez (root controls depth 0).

Panel events: sıradan girdiler `change`; buttons yalnızca `click`; PIN autoSubmit tamamlandığında `change` ve `submit` gönderir. Native mount/unmount/focus/key events yoktur. Values, numbers/booleans dâhil strings değerleridir. `values`, oluşturulan snapshot'ın giriş değerlerini içerir ve tetikleyen düzenlemenin gerisinde kalabilir; `value` bu düzenlemeyi belirtir. Güvenilir forms için `v.state` içine kaydedip typed values oluşturun. Click dışı events, control başına 100ms içinde birleştirilir; events değerlerini tuş vuruşu saymayın.

Metin sınırları: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; diğer value strings 512; option value/label 256. Fazlası kısaltılır.

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Settings içinde **Özel kural klasörü** ve izin gerekir.

- `path` görecelidir; `/` directories öğelerini ayırır. Segmentler ASCII letters/digits, boşluk ve `_.,@()-` kabul eder; başında nokta, `.`/`..`, absolute path veya URL kabul etmez. Dosya uzantısı: `.txt`, `.csv`, `.json` (büyük/küçük harf duyarsız). List path directory'dir; `""` seçilen root'u listeler. Symlinks üzerinden olanlar dâhil seçilen klasörün dışına çıkan paths reddedilir.
- Read UTF-8 text döndürür. Write değiştirir/oluşturur; append otomatik newline olmadan oluşturur/ekler. Yazarken üst dizinler oluşturulur. String payload aynen yazılır; diğer JSON payloads serileştirilir; null/atlanmış değer boş text demektir. JSON/CSV parsing rule'a aittir. En büyük dosya boyutu: 1048576 UTF-8 bytes.
- List doğrudan görünen alt dizinleri ve desteklenen dosyaları döndürür. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; files içindeki extension noktayı içerir. Exists, desteklenen file path için boolean döndürür.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Kullanılmayan result fields null; başarıda error boş olur. Hatalara invalid-path, unsupported-file-type, klasör kullanılamıyor, dosya eksik ve file-too-large dahildir. error değerini sabit ve eksiksiz enum değil, string olarak ele alın. Transaction API yoktur; her path için read-modify-write işlemlerini serileştirin.

## Sınırlar

Her event/grup için: 256 queued actions, 200 log calls, 64 emits; fazlası atılır. Her rule için: 1000 handlers, 24 panels; her control list 32 entries ve her choice 64 options içerir; fazlası yok sayılır/kısaltılır. Emit chains 16 generation sonrasında durur. Serialized state limit: 65536 JavaScript string characters. Kayıt işlemi ve her event'in birleşik handlers süresini 1 saniyenin altında tutun; tekrarlanan aşımlar veya hard timeout rule'u Run'a kadar durdurur. Log grup başına 200 entries tutar. Timing/replies best-effort çalışır; gerçek zamanlılık garantisi değildir.

## Tam kural

Steam, Snooze veya panel düğmesiyle başlatılan beş dakikalık duraklama dışında engellenir:

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
