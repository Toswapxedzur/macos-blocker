# Adamancia Vault — Mac için kod kılavuzu

[Kullanıcı kılavuzu](../manual/tr.md)

## Kural sözleşmesi

Source: tek bir function expression `(on, v) => { ... }`. Yalnızca eşzamanlı JavaScript ve aşağıdaki API desteklenir; JavaScript zamanlama geri çağrıları, ağ, yerel sistem API’leri veya tarayıcı sayfasına erişim yoktur. Zamana dayalı kurallar aşağıdaki yönetilen zamanlayıcıları/izleyicileri veya `ev.now` ve olayları kullanır. Safari kuralları browser code manual kullanır ve Safari Vault'un kendi container app'i içinde çalışır.

- Düzenleme taslak kaydeder; **Run** kuralı etkinleştirip grubu açar. Dondurulmuş gruplar Run çalıştıramaz. Boş source kuralı kaldırır.
- Başarılı Run handlers/panels öğelerini değiştirir ve `v.state` değerini koruyarak bu grubun app-block set değerini temizler. Derleme/kayıt başarısızsa önceki kural korunur; timeout kuralı durdurabilir. Restart son etkinleştirilen source değerini yeniden kaydeder; closure variables ve app-block sets sıfırlanır.
- Kayıt state başlatabilir, handlers kaydedebilir, panels gösterebilir ve log yazabilir. Uygulama/dosya işlemleri ve emits handlers içinde olmalıdır; kayıt sırasındaki kuyruk atılır.
- Disable handlers değerlerini bastırır, panels/app blocks değerlerini kaldırır. Enable yüklü rule ile saklanan panels/blocks değerlerini geri yükler. Delete handlers/state/effects değerlerini kaldırır. Önceden kapatılan uygulamalar yeniden açılmaz; file writes geri alınmaz.
- Events normal grup targets değerleriyle sınırlı değildir; uygulamaları rule içinde seçin. Actions kuyruğa alınır ve dispatch sonrasında uygulanır. Exceptions, state/actions değerlerini geri almadan ilgili handler'ı durdurur; sonraki handlers çalışabilir. Yalnızca file actions result events içerir.

## Yönetilen zamanlayıcılar ve kayan kullanım

`v.timer(id, {direction:"down", durationMs:300000})` başlangıçta duraklatılmış, adlandırılmış bir geri sayım oluşturur veya mevcut olanı döndürür. İleri sayan bir zamanlayıcı için `{direction:"up"}` kullanın. Döndürülen nesne `start()`, `pause()`, `resume()`, `reset()` ve `snapshot()` yöntemlerini sunar. Start/resume idempotenttir; reset, geçen süreyi sıfırlayıp duraklatılmış duruma döndürür. Anlık görüntü alanları `ready`, `error`, `elapsedMs`, `remainingMs` (ileri sayımda null), `running` ve `completed` içerir.

Çalışan zamanlayıcılar, uygulama/tarayıcı kapalıyken veya kural devre dışıyken gerçek zamanla ilerler. Tamamlanan geri sayım, `timerEnded` olayını `{id, direction, durationMs, generation, incarnation}` verisiyle, her zamanlayıcı örneklenmesi ve nesli için her üyeye kuralı bir sonraki kez çalıştığında bir kez iletir; Run bunu yeniden oynatmaz. İletim, ana sistemin olaylarına bağlıdır; bu gerçek zamanlı bir alarm değildir. Mevcut metin denetimi üzerinden göstermek için bir panele `{type:"timer", timerId:"focus", label:"Focus"}` ekleyin.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` adlandırılmış bir aktif kullanım izleyicisi oluşturur veya mevcut olanı döndürür. `assign({websites:["youtube.com","reddit.com"], apps:[]})` bu üyenin hedef atamalarını değiştirir. Yerel kurallar bunun yerine platforma ait uygulama kimliklerini atayabilir. Alan adları alt alan adlarını da kapsar. Bir izleyici hedeflerinin kullanımını ortak havuzda toplar; diğer kimliklerin bağımsız hakları vardır. `snapshot()`, `ready`, `error`, `usedMs`, `remainingMs`, `available` ve `nextReturnAtMs` (kaydedilmiş herhangi bir kullanımın geçerliliğini yitireceği en yakın milisaniye) döndürür. `available(target?)`, bir hedef verildiğinde atamayı da denetler. `reset()` bu nesnenin geçmişini temizler.

Hak sınırını aşan kullanım dahil, gözlemlenen uygun kullanımın tamamı sayılır; izleyici kendi başına sayfa/uygulama engellemez. Görünür sayfaların çakışan aralıkları bir kez sayılır; yerel uygulamalarda gözlemlenen ön plan kullanımı sayılır. Devre dışı kurallar kullanım eklemez; geçmişin süresi yine aralıkların tam sınırlarında dolar. Kullanılabilirlik, yalnızca kalan geçmiş limitin altına düştüğünde geri gelir. Düzenli etkinlik sinyali örnekleri beş saniyeyle sınırlıdır; kapatma/devre dışı kalma boşlukları etkinlik üretmez. Kullanıcının yaydığı olaylar kullanım eklemez.

Bağlı özel gruplardaki aynı nesne kimlikleri, tek bir yerel merkez yetkili durum kaynağını paylaşır. Bağlama, izleyici geçmişini ve atamalarını birleştirir ve bağlantıyı başlatan üyenin zamanlayıcı durumunu korur; uyumsuz yapılandırmalarda bağlama reddedilir. Her üye kendi tamamlanma olayını alır. Bağlantının kopması, güncel yetkili kaynak geri gelene kadar paylaşılan izleyicileri kullanılamaz kılar ve zamanlayıcı denetimlerini reddeder. Bağ kaldırıldığında her üye son paylaşılan kullanımı ve zamanlayıcı durumunu korur, kendi hedeflerini geri yükler ve eski bağdan gelen komutları bırakır. Merkez, geri dönen üye son anlık görüntüyü kaydedip onaylayana kadar onu saklar; yeni bir bağlantı kullanılabilir olmadan önce bekleyen devirler tamamlanır.

Adlandırılmış nesneler, ayrılmış `v.state.$vaultTime` alanında Run ve yeniden başlatma sonrasında korunur; bu alanı doğrudan düzenlemeyin. Açıkça kaldırmak için `v.removeTime(id)` kullanın. Kimlikler 1–80 ASCII harfi, rakam, `_` veya `-` içerir; ayrılmış özellik adları reddedilir. En fazla 32 nesne, kuralın 64 KiB UTF-8 durum limitini paylaşır. Süreler, en fazla 365 gün olmak üzere tam sayı milisaniyelerle belirtilir. Kayan geçmiş 1024 dakikalık kova ve 2048 birleştirilmiş aralıkla sınırlıdır. Geçmiş kapasitesi hataları, açıkça sıfırlanana kadar izleyiciyi kullanılamaz durumda bırakır; geçersiz yapılandırmalar ve aşırı büyük kayıtlar, kayıtlı verileri silmeden hata bildirir.

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

- `on(type, handler)` → boolean. `handler(ev)` kaydeder; birden çok handler kayıt sırasıyla çalışır. False, geçersiz bağımsız değişkenleri veya handler sınırına ulaşıldığını belirtir. `ev = { type: string, now: number, origin: "host" | "user" | "rule", data }`; `now` Unix milisaniyesidir. Yerel panel girdisinde `origin: "user"`; `v.emit` için `origin: "rule"` bulunur.
- `v.state`: event dispatch sonrasında kaydedilen değiştirilebilir JSON object. Mevcut state üzerine yazmak yerine eksik fields değerlerini başlatın. Non-object veya array atamak `{}` değerine sıfırlar; serileştirilemeyen/aşırı büyük güncellemeler kaydedilmez.
- `v.log(...values)`: bu grubun Log kaydına ekleme yapar. Yürütme ve iletim hataları aynı akışta açık hata girdileri olarak görünür. Logs/Clear her grup için bağımsızdır. Yükleme hataları Run durumunda da görünür; kısmen yürütülmüş olaylar otomatik olarak yeniden oynatılmaz.
- `v.emit(type, data)`: geçerli event sonrasında bu grubun handlers değerlerine `data` öğesinin JSON kopyasını yeni bir `now` ile kuyruğa alır; eşzamanlı çağrı değildir.
- `v.panel(id, spec)`: grubun adlandırılmış floating panel değerini değiştirir; null `spec` paneli kaldırır. Panels'e bakın.
- `v.file(op, path, payload?)` → request ID string. Files'a bakın.
- `v.store(request)` → istek kimliği dizesi. Grup kayıtlarına bakın.
- `v.block(appId, on)`: true uygulama engelini sürdürür, false grubun engelini kaldırır. Etkin grupların engelleri birleşir; bu çağrı başka grubun hedefini engelden çıkaramaz. Engelleme normal kapatma ister ve Settings aralığında yeniden dener; process launch değerini engellemez veya uygulamanın Quit'ı kabul edeceğini garanti etmez.
- `v.quit(appId)`: aynı koruma/yeniden deneme ilkesiyle bir normal kapatma isteği; sürekli engelleme değildir.
- `v.open(appId)`: macOS'tan yüklü bir uygulamayı açmasını ister; başarı callback'i yoktur.

Diğer çağrılar `undefined` döndürür. App IDs, olaylarda bulunan paket tanımlayıcılarıdır (örneğin `com.valvesoftware.steam`). Block/Quit, Apple uygulamalarını ve tarayıcıların tamamını hedefleyebilir. Vault’un paket tanımlayıcısını ve yardımcılarını, bu kimliği paylaşan diğer uygulamalar dahil olmak üzere, ve boş kimlikleri yok sayarlar. Panel IDs/state gruba aittir, görünen adına değil.

## Olaylar

Aşağıdaki payload gösterimi yürütülebilir kod değil, types bilgisi verir. `?` isteğe bağlı fields alanlarını belirtir.

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

- `tick` yaklaşık değerdir; ticks saymak yerine timestamps kullanın. Running, bundle IDs bulunan foreground, menu-bar ve background `.app` süreçlerini içerir; her Unix sürecini içermez. Frontmost null veya boş app ID olabilir.
- `app`, o tick'in `tick` event değerinden önce gözlemlenen yaşam döngüsü değişikliklerini bildirir. Yalnızca focus `previousAppId` içerir (bilinmiyorsa null). Names görünen adlardır, kararlı IDs değildir.
- `snooze`, grubun Snooze düğmesine basıldığı anlamına gelir. Tek başına duraklama uygulamaz.
- File replies isteği yapan gruba gider. `requestId` ile eşleştirin, `ok` değerini denetleyin ve ticks ile deadline belirleyin: rule yeniden yüklenirse/devre dışı bırakılırsa replies kaybolabilir. Request IDs Run sonrasında tekrarlanabilir; bekleyen requests kalıcı iş değildir.

## Paneller

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

## Dosyalar

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

## Grup kayıtları

`v.store(request)` bir handler içinde asenkron JSON kayıt işlemi başlatır. Kayıtlar gruba özeldir, Run ve yeniden başlatma sonrasında kalır ve grupla silinir. Bağlı grupların store'ları ayrıdır. Key, value, version, cache invalidation ve feedback önceliğini kural belirler. Mac ve tarayıcı kuralları aynı API'yi kullanır ancak her app/tarayıcı store'u ayrıdır.

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` veya `null` |
| `{op:"put", key, value, version?, ifRevision?}` | kaydedilen `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | sıralı `entries` ve `next` |
| `{op:"clear", prefix?}` | `deleted` sayısı |

Her kayıt `{value, revision, version, updatedAt}` biçimindedir. Opaque revision gerçek yazmada değişir; `version` çağıranın metadata'sıdır. `list` değerler olmadan başlıkları döndürür; okumak için `get`, sonraki sayfa için `after: next` kullanın. `put`/`delete`, `ifRevision` yoksa put/delete koşulsuzdur; `null` anahtarın bulunmamasını, revision metni tam eşleşmeyi şart koşar. Uyuşmazlık `ok:false`, `error:"store-conflict"` ve güncel `record` döndürür; geciken otomatik yanıtın kullanıcı geri bildirimini ezmesini önler. `v.context.revision` kuralın sürümüne katabileceği opaque yapılandırma işaretidir; framework cache politikası dayatmaz.

Sınırlar: key 1–2048 karakter, version ≤128, JSON value ≤64KiB, depth ≤32, grup başına10000 key, tüm belge16MiB. `list` sayfa başına en çok100 başlık ve96KiB döndürür. Grup başına32 request, toplam saniyede128 başlangıç. Aşırı yükte grup başına saniyede bir `store-busy` hatası bildirilir ve fazlası atılır. Storage hatası `ok:false` döndürür; gelecekteki/bozuk belge korunup `store-unavailable` bildirilir. Otomatik retry/eviction yoktur. Deadline için ticks kullanın.

## Sınırlar

Grup başına her olay için: kuyrukta 256 eylem, 200 günlük çağrısı, 64 olay yayımı; fazlası atılır. Kural başına: 1000 işleyici, 24 panel; her denetim listesi 32 girdi ve her seçim 64 seçenek içerir; fazlası yok sayılır/kesilir. Olay yayım zincirleri 16 nesilden sonra durur. Serileştirilmiş durum limiti: 65536 UTF-8 baytı. Kayıt işlemini ve her olayın işleyicilerinin toplam süresini 1 saniyenin altında tutun; tekrarlanan aşımlar veya kesin zaman aşımı, Run çalıştırılana kadar kuralı durdurur. Log grup başına 200 girdi tutar. Zamanlama/yanıtlar olanaklar ölçüsünde çalışır; gerçek zaman garantisi yoktur.

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


## Çalışan bir kuraldan AI çağrıları

Her `v.ai` çağrısı bağlantıyı ve modeli belirtir; grup varsayılanı yoktur. **AI calls** içinden model ID kopyalayın veya Vault kural AI modeli aracıyla kimlik bilgisi gerektirmeyen kataloğu görüntüleyin. Akıl yürütme düzeyi her çağrıda seçilir. Tarayıcı istekleri için masaüstü Vault bağlantısı gerekir; sağlayıcı kimlik bilgileri orada kalır. Bağlı gruplar isteğe bağlı günlük isteği paylaşır. Boş değer grup sınırı olmadığı, hesap sınırlarının geçerli olduğu anlamına gelir. Sınır UTC gününe göre işler, yeniden başlatma sonrası korunur ve başarısızlar dahil gönderilen denemeleri sayar. Bağlama mevcut kullanımı birleştirir; ayırma korur.

İsteğe bağlı kaydedilmiş prompt ve context bağlı gruplarda paylaşılır ve yeniden başlatma sonrasında da kalır. Handler içinde `v.context.ai.prompt` ve `v.context.ai.context` olarak kullanılabilir; Vault bunları otomatik göndermez. Her `v.ai` çağrısına ne ekleneceğine kural karar verir. Bunlardan birini düzenlemek eski yapılandırmanın yanıtlarını geçersiz kılar.

`conversation` isteğe bağlı bir addır. Olmadan çağrı durumsuzdur. Ad verilirse masaüstü Vault kullanıcı/asistan dökümünün tamamını yerel kaydeder ve sonraki çağrıya en yeni mesajların16KB kadarını ekler. Aynı konuşma model değiştirebilir; yeni modele yalnızca taşınabilir metin aktarılır. Ad bu cihazdaki tüm kural ve gruplarda ortaktır. Grubu silmek veya ayırmak adlı konuşmaları silmez. Toplam yerel döküm sınırı varsayılan1 GB'dır ve Vault Settings'ten değiştirilebilir. Dolunca Vault en uzun süredir kullanılmayan konuşmaları kaldırır. Eski bir özel derleme grup başına aynı adlı ayrı geçmişler kaydettiyse Vault bunları farklı adlarla içe aktarır ve değişen adları `preservedConversations` olarak bildirir.

Paylaşılan bir konuşmayı açıkça silmek için `v.ai({op:"delete", conversation:"name"})` çağırın; yanıt `ai` olayı olarak gelir. Aynı adlı etkin çağrı `ai-conversation-busy` döndürür; yanıtından sonra yeniden deneyin. Depolama hatası başarılı yanıtı sessizce unutmak yerine hata bildirir. Konuşma metni sıradan kural durumuna otomatik eklenmez.

`v.ai({ model, reasoningEffort?, conversation?, prompt, input? })` hemen istek ID'si döndürür. Kural kaydederken değil, handler içinde çağırın. `model` kullanılabilir bir ID'dir; belirtilmezse effort `default`, destekleniyorsa `low`, `medium` veya `high` olur. `input` herhangi bir JSON değeri olabilir; prompt/input ayrı ayrı20KB ile sınırlıdır. Yanıtlar `ai` olayları olarak gelir: `{requestId, ok, text, citations,
error, preservedConversations?}` Başarılı metin en fazla48KB olur; alıntılar `{url,title}` biçimindedir..
Web aramasına dayalı yanıtları gösterirken kaynak bağlantılarını görünür ve tıklanabilir tutun. Model aramayı her zaman kullanabilir. Üretim için sabit uygulama süresi yoktur. Birden çok adlı konuşma aynı anda çalışabilir; aynı adlı çağrılar sırayla yürür. Sonraki çağrıyı `ai` olayından başlatın. Vault henüz gecikmeli çağrıları zamanlamaz. Sağlayıcı kapasitesi ve kotası isteği bekletebilir veya reddedebilir; sağlayıcı yedeği ya da otomatik yeniden deneme yoktur. Yanıtlar veridir, JavaScript olarak çalıştırılmaz. Mevcut eylemleri kural seçer.

`ask` düğmesi ve `note` alanı olan panel için:

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

Bekleyen çağrılar yeniden başlatma sonrasında tekrarlanmaz. Run, devre dışı bırakıp yeniden etkinleştirme ve silme eski yanıtları atar; bağlantısı kesilen tarayıcı `ai-unavailable` bildirir. Diğer hatalar: `ai-not-configured`, `ai-invalid-input`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`, `ai-conversation-storage-unavailable`. Başarısız çağrılar kuralın korumayı seçtiği önceki sonucu değiştirmez. Kural durumu64KB sınırını korur.

Araçlar kimlik bilgisi gerektirmeyen seçenekleri Mac'te `rule_ai_models` veya tarayıcıda `settings-rule-ai-models` ile bulabilir ve mevcut set-group yoluyla `ruleAI` yapılandırabilir. Alanlar: `dailyRequestLimit` (null veya1–100000), `prompt`, `context` (isteğe bağlı dizeler, her biri en fazla16KB). Model ve effort her çağrıda belirtilir; kayıtlı grup varsayılanı yoktur. Döndürülen seçeneği kullanın; kural kaynağına anahtar veya sağlayıcı URL'si koymayın.
