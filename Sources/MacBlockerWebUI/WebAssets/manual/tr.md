# Vault masaüstü uygulaması işlevsel referansı

## Amaç ve sınır

Bu, Vault masaüstü uygulama arayüzünün yetkili referansıdır. Vault tarayıcı uzantısı kılavuzundan kasıtlı olarak ayrıdır.

Masaüstü uygulaması **yerel uygulamaları ve uygulama pencerelerini** yönetir. Tarayıcı uzantısı web sitelerini, tarayıcı sekmelerini ve desteklenen web platformu yayınlarını yönetir. Aynı fikirleri paylaşıyorlar (gruplar, programlar, zamanlayıcılar, dondurmalar, ertelemeler, Özel kurallar ve isteğe bağlı köprü) ancak aynı uygulama yüzeyine sahip değiller.

Masaüstü uygulaması davranışını yapılandırmak, denetlemek, yeniden oluşturmak veya sürdürmek için bu belgeyi kullanın. Bir uygulama ve bu kılavuz farklıysa kod kanoniktir.

## 1. Masaüstü uygulamasının kontrol edebildiği ve kontrol edemediği şeyler

Apps Kasası, seçilen yerel uygulamalar için odaklanma politikasını değerlendirir. Yerel uygulama yeteneği mevcut olduğunda, mevcut planı eşleşen uygulama hedeflerine uygulayabilir ve ana bilgisayar kullanıcı arayüzüne bir kalkan/durum sonucu bildirebilir.

Şunları yapabilir:

- grupları oluşturma, etkinleştirme, devre dışı bırakma, yeniden sıralama, içe aktarma, dışa aktarma, dondurma, erteleme ve kaldırma;
- uygulama seçici aracılığıyla seçilen yerel uygulamaları hedefleyin;
- anında blok, süreli izin veya yalnızca ileri sayım zamanlayıcısı uygulayın;
- normal grupları hafta içi günlerle ve yerel saat pencereleriyle sınırlandırın;
- uygulama yaşam döngüsü olayları için Özel JavaScript ilkesi kurallarını çalıştırın;
- ana bilgisayar aracılığıyla kuralla oluşturulan yerel durum/panel bilgilerini gösterin;
- desteklenen Özel kural dosyası istekleri için isteğe bağlı bir yerel klasörü yönetin;
- Yerel Vault köprüsü aracılığıyla uyumlu ve açıkça bağlantılı gruplara katılın.

Şunları yapamaz:

- tarayıcı uzantısı olarak hareket etmek, bir web sitesinin DOM'sini denetlemek veya tarayıcı besleme kartlarını değiştirmek;
- bir işletim sisteminin her uygulamanın, işlemin, pencerenin veya sistem hizmetinin kontrol edilmesine izin vereceğini garanti eder;
- uygulama seçimini uzaktan yönetime, cihaz gözetimine veya güvenlik duvarına dönüştürün;
- DOM, gezinme, yeniden yönlendirme veya sekme kontrolü gibi yalnızca tarayıcıya özel Özel yardımcıların yerel çalışma zamanında çalışmasını sağlayın;
- yalnızca yerel köprü çalıştığı için her grubu otomatik olarak senkronize edin.

## 2. Kelime Bilgisi

| Dönem | Anlamı |
| --- | --- |
| Grup | Adlandırılmış bir odak politikası nesnesi. Grup adları geçerli Apps Kasası uç noktasında benzersiz olmalıdır. |
| Hedef | Bir grup için seçilen yerel uygulama kimliği. |
| Varsayılan uygulama grubu | Hedefleri uygulama seçicideki yerel uygulamalar olan normal bir grup. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Maç | Geçerli ön plan/çalışan uygulama, etkin ve etkin bir grup hedefiyle veya Özel kural koşuluyla eşleşiyor. |
| Aktif | Normal program dahilinde etkindir ve aktif olarak ertelenmez. |
| Uygulama planı | Yerel ana bilgisayarın geçerli grupları değerlendirdikten sonra ortaya çıkan izin verme/kalkan/durum kararı. |
| Dondur | Bir grubun olağan değişikliğine karşı koruma. |
| Ertele | Normal bir grup ilkesinin geçici bir istisnası. |

## 3. Hedef kimliği ve uygulama seçici

Varsayılan uygulama grubundaki **+** seçiciyi kullanarak uygulamaları seçin. Apps Kasası, görünen adın yanı sıra normalleştirilmiş bir kimliği de saklar.

| Sunucu | Eşleştirme için kullanılan hedef kimliği |
| --- | --- |
| macOS | Varsa uygulama paketi tanımlayıcısı. |
| Windows | Uygulama seçici tarafından sağlanan normalleştirilmiş yürütülebilir yol veya işlem adı. |

Görünen ad düzenleyici içindir. Normalleştirilmiş değer, yerel uygulama katmanı tarafından kullanılan kimliktir. Bir uygulamanın kullanıcı arayüzünde yeniden adlandırılması kimliği değiştirmez. Bir hedef ayrıca Özel kural ilkesi kullanımına yönelik etiketler de taşıyabilir.

Uygulama hedefi alanına bir web sitesi URL'si girmeyin ve yerel uygulamanın uygulanmasını beklemeyin. Web sitesi engelleme için uzantının Site grubunu kullanın.

## 4. Grubun yaşam döngüsü ve önceliği

Yeni bir grup varsayılan olarak etkindir. Grup listesi seçim, etkinleştirme/devre dışı bırakma, sürükleme sıralaması, Ekleme, Temizleme, içe aktarma, dışa aktarma ve silme işlemlerini destekler. Seçilen grup düzenleyicide açılır.

Normal alan düzenlemeleri, editörün otomatik kaydetme politikası aracılığıyla kaydedilir. Dondurulmuş bir grup sıradan düzenleme kontrollerini devre dışı bırakır. Özel kaynak farklıdır: Metnin kaydedilmesi onu etkin hale getirmez; **Çalıştır** geçerli kaynağı politika çalışma zamanına yükleyen işlemdir.

Birkaç grup aynı uygulamayla eşleşebilir. Apps Kasası, grup ilkesini depolanmış sırayla değerlendirir ve yerel bir yaptırım planı oluşturur. Özellikle gruplar farklı zamanlanmış politikalar kullandığında veya Özel kurallar izin verme/koruma kararları verdiğinde çakışmaları bilinçli tutun. Amaçlanan önceliği netleştirmek için grupları yeniden sıralayın; Çakışan bir yapılandırmanın belirli, kullanıcı dostu bir yöntemle çözülmesine güvenmeyin.

## 5. Normal uygulama grupları

### 5.1 Grup durumu

| Alan | Fonksiyonel sözleşme |
| --- | --- |
| İsim | Bu uç nokta içinde boş olmayan, kırpılmış, benzersiz, büyük/küçük harfe duyarlı olmayan. |
| Etkin | Engelli gruplar muhafaza ediliyor ancak normal yaptırımlarda yer almıyor. |
| Hedefler | Seçiciden seçilen bir veya daha fazla uygulama kimliği. |
| Davranış | Anında bloke etme, izin verdikten sonra bloke etme veya zamanlayıcı/geri sayım. |
| Program | Seçilen hafta içi günler ve isteğe bağlı yerel saat pencereleri. |
| Dondur | Yok, Dondurulmuş, Kesinlikle dondurulmuş veya Ebeveyn dondurulmuş. |
| Ertele | Grup başına geçici istisna politikası. |
| Geri dönüş/durum mesajı | Yerel ana bilgisayarın bir kalkan/durum yanıtı uyguladığında gösterebileceği mesaj. |

Boş bir Varsayılan grubun seçilmiş bir uygulama hedefi yoktur ve bu nedenle bir uygulamayı yalnızca mevcut olmasıyla eşleştirmez.

### 5.2 Davranışları engelleme

| Davranış | Sonuç |
| --- | --- |
| Hemen engelle | Eşleşen aktif bir hedef anında yerel bir blok/kalkan kararı üretir. |
| Birkaç dakika sonra engelle | Eşleşen kullanım, grup ödeneğine tahakkuk eder. Ödenek tükendiğinde grup, kullanım süresi sıfırlanana veya başka bir durum grubu devre dışı bırakana kadar yerel bir engelleme/kalkan kararı üretir. |
| Zamanlayıcı (ileriye doğru sayın, blok yok) | Eşleşen kullanım ölçülür ve görüntülenebilir, ancak bu zamanlayıcı tek başına hiçbir zaman bir blok oluşturmaz. |

Yeni gruplar, değiştirilmediği sürece 15 dakikalık izin ve 24 saatlik sıfırlama aralığı kullanır. Zamanlanmış kullanım gruba ait olduğundan eşleşen tüm hedefler bu grup ilkesini paylaşır. Bir bloğa verilen tam yanıt, yerel ana bilgisayar tarafından uygulanır ve işletim sistemi izinleri ve desteklenen uygulama mekanizması tarafından kısıtlanır.

### 5.3 Programlar

Programlar normal gruplar için geçerlidir. Özel bir grup, JavaScript'te kendi zaman kararlarını verir.

Pazartesi'den Pazar'a kadar herhangi bir kombinasyonu seçin. Her zaman penceresi yerel saatte bir satırdır:

```text
0900-1200
1330-1730
```

Kabul edilen tam format HHMM-HHMM'dir. Saatler 00'dan 23'e, dakikalar 00'dan 59'a kadar olmalı ve başlangıç, aynı günün bitişinden daha erken olmalıdır. Bir pencere başlangıcını içerir ve sonunu hariç tutar. Gece yarısına kadar pencereler kabul edilmez. Boş pencereler seçilen günün tamamı anlamına gelir.

Normal grup yalnızca şu durumlarda etkindir:

1. etkindir;
2. haftanın geçerli günü seçilir;
3. yerel saat yapılandırılmış bir pencerenin içindedir veya grupta pencere yoktur;
4. Aktif bir erteleme durumunda değil.

### 5.4 Erteleme

Erteleme, normal bir grubu etkin yaptırımdan geçici olarak kaldırır. Aşamaları şunlardır:

| Aşama | Sonuç |
| --- | --- |
| Beklemede | İstek mevcut ancak etkinleştirme gecikmesi geçmedi; grup aktif kalır. |
| Aktif | Grup, erteleme süresi boyunca geçici olarak devre dışıdır. |
| Bekleme Süresi | Erteleme sona erdi ve grup yeniden aktif ancak yeni bir erteleme henüz mevcut değil. |

| Ayar | Kural |
| --- | --- |
| Ertelemeye izin ver | Kapalıyken grup normalde ertelenemez. |
| Erteleme süresi | Pozitif dakika sayısı. Yeni bir grup için varsayılan süre 30 dakikadır. |
| Etkinleştirme gecikmesi | Erteleme aktif hale gelmeden sıfır veya daha fazla dakika önce. |
| Bekleme Süresi | Aktif erteleme sona erdikten beş dakika sonra sıfırdan beş dakikaya kadar. |
| Onaylar | Gerekli onay etkileşimlerinin negatif olmayan tam sayısı. |

Etkin bir erteleme, silme veya dondurmanın çözülmesi değil, geçici bir politika istisnasıdır. Grup yapılandırması bozulmadan kalır.

### 5.5 Dondur

Donma, kasıtlı bir değişiklik engelidir.

| Modu | Sözleşme |
| --- | --- |
| Dondurulmuş | Ürünün dondurmayı çözme onay akışı başarılı olana kadar olağan düzenlemeler ve olağan durum değişiklikleri kilitli kalır. |
| Kesinlikle dondurulmuş | Grubun dondurma süresi, tam dondurma süresi sona ermeden çözülemez. Süre pozitiftir ve 72 saat ile sınırlıdır. |
| Ebeveyn dondurulmuş | Dondurma/çözme işlemleri için koruyucu şifre yönetimi gereklidir. |

Düzenleyicide bir mod seçmek, grubu tek başına dondurmaz; uygulamak için dondurma eylemini kullanın. Köprü bağlantılı bir grup, gerekli bir üye çevrimdışıyken de koordineli dondurma kontrollerini kilitleyebilir.

## 6. Yerel uygulama ve cihaz kontrolü

Düzenleyici, işletim sistemi tarafından uygulama olanağı verilmemiş olsa bile bir grubu doğru bir şekilde kaydedebilir. İzinleri değiştirdikten sonra daima **Ayarlar → Cihaz Kontrolü** ve canlı yerel durumu kontrol edin.

Yerel ana bilgisayar, geçerli işletim sistemi, uygulama, pencere ve izin durumu için hangi eylemlerin mümkün olduğuna karar verir. Aşağıdaki durumlarda bir kural doğru şekilde yapılandırılabilir ancak görünür bir etkisi olmayabilir:

- Cihaz Kontrolü verilmedi veya iptal edildi;
- grubun devre dışı bırakılması, planlanması veya aktif olarak ertelenmesi;
- odaklanılan süreç seçilen normalleştirilmiş hedefle eşleşmiyor;
- işletim sistemi bu hedef için bir eylemi reddeder;
- Koordineli durum gerektiren bir eylem için köprü bağımlılığı çevrimdışıdır.

Başarılı bir kaydetme tostunu, aktif yaptırımın mevcut olduğunun kanıtı olarak görmeyin. Seçilen hedefi grup etkinken test edin ve ana bilgisayar durumunu inceleyin.

## 7. Özel gruplar ve yerel politika kuralları

Özel gruplar yerel JavaScript ilkesi çalışma zamanında çalışır. Bunlar tarayıcının Özel kuralları değildir. Tarayıcı DOM'si, sekmesi, gezinmesi, URL yönlendirmesi ve yayın denetimi davranışı kasıtlı olarak kullanılamaz.

### 7.1 Kaynak yaşam döngüsü

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Yerel yerleşik etkinlikler

| Etkinlik | Anlamı |
| --- | --- |
| onayOlay | Periyodik ana bilgisayar işareti. IntervalMs kayıt seçeneği bir işleyicinin hızını sınırlayabilir. |
| zamanlayıcıSonlandı | Kurala ait geri sayım sıfıra ulaşır. |
| ertelemeBasın | Kullanıcı, Özel bir grup için Ertelemeyi Başlat'a basar. |
| panelEtkinliği | Özel panel kontrolü kullanılır. |
| yerelDosyaOlay | İstenen bir yerel klasör eylemi tamamlanır. |
| openAppEvent | İzlenen bir uygulama açılır. |
| CloseAppEvent | İzlenen bir uygulama kapanır. |
| odak Olayı | Ön plan uygulaması bir uygulamaya dönüşür. |
| odak dışıEtkinlik | Ön plandaki uygulama bir uygulamadan uzaklaşarak değişir. |
| Olayı küçült / Olayı küçült | Ana bilgisayar, desteklenen bir pencere simge durumuna küçültme geçişini bildirir. |
| switchAppEvent | Ön plan uygulaması bir uygulamadan diğerine değişir. |
| appChangedEvent | Genel uygulama yaşam döngüsü/değişim olayı. |

Olay nesnesi tür, grup kimliği/grup kimliği, grup adı, URL/ana bilgisayar adı eşdeğerlerini, zamanı, verileri ve hedefi içerir. Yerel bir uygulama için hedef, odak hedefi yapılandırılmış bir hedefle eşleştiğinde bir kimliği, türü, displayName'i, normalleştirilmiş değeri ve etiketleri gösterir.

Uygulama yaşam döngüsü olay verileri, geçerli uygulama kimliğini/adını, grup adını, serileştirilmiş çalışan uygulama anlık görüntüsünü ve bundleId, öncekiAppId, currentAppId veya değişiklik nedeni gibi etkinliğe özgü değerleri içerir.

### 7.3 Etkinlik API'si ve kararlar

Kayıt defteri, açma/kayıt, kapatma/kaydı silme, unregisterAll, countRegistered, getEvent ve getEvents seçeneklerini sağlar. Daha yüksek öncelikli önce çalıştırılır; eşit öncelik kayıt sırasını korur. Kayıt defterinde grup başına bir işleyici sınırı vardır.

Olay nesnesi şunları destekler:

| Yöntem | Sonuç |
| --- | --- |
| setResult(-1) | Yerel bir kalkan/blok kararı üretin. Bir dize sonucu aynı zamanda yerel bir blok haline gelir çünkü masaüstü kurallarında tarayıcı yönlendirme hedefi yoktur. |
| izin ver(sebep) veya setResult(1) | Etkinlik için bir izin verme kararı üretin. |
| setShieldMessage(mesaj) | Yerel bir blok için insana dönük kalkan/durum mesajını ayarlayın. |
| Yayılımı durdur() | Geçerli olayın sonraki işleyicilerini durdurun. |
| blok(appId), engellemeyi kaldır(appId) | Dinamik bir yerel uygulama bloğu ekleyin/kaldırın. |
| kapat(uygulamaKimliği), aç(uygulamaKimliği) | Desteklenen bir yerel kapatma/açma eylemi isteyin. |
| yazı(tür, veri) | Yerel çalışma zamanı içinde iç içe geçmiş bir Özel olay gönderin. |

Uygulama çalışma zamanı, zamanlayıcılara, kalıcılığa, panellere, günlüklere, yerel klasör işlemlerine, uygulama penceresi yardımcılarına ve URL sınıflandırıcı yardımcı programlarına olanak tanır. DOM, gezinme, yeniden yönlendirme ve tarayıcı sekmesi yardımcılarını kasıtlı olarak kullanılamaz/etkin olarak ele alır.

### 7.4 Yerli yardımcılar

| Yardımcı | Yerel davranış |
| --- | --- |
| getLogHelper | Uygulama/açılır pencere/ekran günlüğü kararlarını yayar. |
| getTimerHelper | Sınırlar, adımlar, kapsam/etki alanı yüklemleri, duraklatma/devam ettirme, durum denetimi ve timerEnded geçişleri ile ileri/geri zamanlayıcılar oluşturur. Zamanlayıcılar kendi başlarına koruma sağlamazlar. |
| getPersistenceHelper | Grup başına JSON durumu: al, ayarla, sil, sahip, anahtarlar, girişler, temizle, boyut. |
| getStorageHelper | Kalıcılığın yanı sıra ana bilgisayar eşzamansız istek yer tutucuları; eşzamanlı bir dış yanıt varsaymayın. |
| getWindowHelper | Geçerli/çalışan uygulamaları okur ve uygulama eylemlerini kapatma/açma/engelleme/engellemeyi kaldırma isteğinde bulunur. |
| getPanelHelper | Doğrulanmış yerel panel anlık görüntüleri, kontroller, satır içi işleyiciler ve panelEvent reaksiyonları oluşturur. |
| getLocalFolderHelper | Kuyruklar, kullanıcı tarafından verilen kök altında göreli .txt, .csv ve .json işlemlerine izin verdi. Tamamlama localFileEvent'tir. |
| getDomainHelper / getDomainUtility | URL benzeri değerlere de neden olan kurallar için URL ve platform sınıflandırıcıları. |
| getPlatformHelper / platform | URL sınıflandırıcıları kullanılabilir durumda kalır; yerel besleme/DOM kontrolü çağrıları etkisizdir çünkü masaüstü ana bilgisayarında web sitesi DOM yoktur. |

Özel paneller, tarayıcı çalışma zamanı ile aynı bildirime dayalı kontrol kelime dağarcığını kullanır: metin, onay kutusu, seçme, textInput, textarea, düğme, bölüm, zamanlayıcı, numberInput, aralık, geçiş, radyo, tarih, saat, renk, pin ve arındırılmış html. Yerel sunucu, mevcut platformda bir panelin ne kadarının görüntülenebileceğine karar verir.

## 8. Yerel Dosya Klasörü

Yerel Dosya Klasörü, Özel kurallar için kullanıcı tarafından verilen isteğe bağlı bir sınırdır. Kurallar, metin/CSV/JSON okuma, yazma, ekleme, listeleme, varlık testleri ve JSON işlemlerini talep edebilir. Yollar her zaman seçilen köke göredir. Mutlak yollar, çapraz bölümler, gizli yol bileşenleri, desteklenmeyen uzantılar ve kök dışındaki işlemler reddedilir.

Bir kuralın artık ona ihtiyacı kalmadığında klasörü iptal edin. Bir kuralın, kullanılamayan izinleri ve başarısız localFileEvent sonuçlarını ele alması gerekir; seçilen bir klasörün yeniden başlatmanın ardından yetkili kaldığını varsaymamalıdır.

## 9. Web uygulaması köprüsü

Köprü, uyumlu Vault programları arasında isteğe bağlı yerel senkronizasyondur. Yerel bir masaüstü uygulaması yerel merkezi barındırabilir; istemciler desteklenen yerel adrese bağlanır.

Bağlantı durumları Kapalı, Bağlanıyor, Bağlantı Kesildi, Bağlandı/Çalışıyor ve Hata'dır. Bir programın bağlanması tüm grupları birleştirmez. Kullanıcının uygun eşleşen grupları açıkça bağlaması gerekir.

Grup bağlantısı için:

1. Ayarlar'da yerel hub'ı başlatın.
2. Diğer uyumlu Vault uç noktasını bağlayın.
3. Aynı ad ve türde eşleşen, dondurulmamış gruplar oluşturun.
4. Grup köprüsü bölümünde programı seçin ve grubu bağlayın.

Bağlantılı bir grup bir küme oluşturur. Desteklenen ortak politika değerleri, kullanım ve erteleme durumu, üyeler bağlıyken senkronize edilebilir. Bağlantının kesilmesi senkronizasyonu duraklatır ve yerel grupları korur. Yalnızca tarayıcıya özgü hedeflerin, desteklenmeyen Özel eylemlerin ve platforma özgü alanların aktarılacağı garanti edilmez.

## 10. İçe aktarma, dışa aktarma, sıfırlama ve denetleme

Dışa aktarma, uyumlu bir grup temsilini kaydeder. İçe aktarma, uyumlu grup verilerini doğrular/normalleştirir ve yine de yerel ad benzersizliğini zorunlu kılar. Grubu Sil, seçilen grubu ve ilişkili durumunu kaldırır. Temizle, onaylandıktan sonra tüm grupları kaldırır. Varsayılanlara sıfırlama genel düzenleyici ayarlarını etkiler; Öncelikle saklanması gereken her şeyi dışa aktarın.

Bir masaüstü kuralına güvenmeden önce:

1. Cihaz Kontrolü'nün verildiğini doğrulayın.
2. Seçilen hedefin normalleştirilmiş kimliğini doğrulayın.
3. Etkin durumu, programı, dondurma durumunu ve erteleme aşamasını doğrulayın.
4. Anında, zamanlı ve ileri sayım davranışını ayrı ayrı test edin.
5. Özel bir grup için tam kaynağı çalıştırın ve kayıtlı her uygulama olayını test edin.
6. Başarılı işlemlerin yanı sıra yerel klasör hatalarını da doğrulayın.
7. Grup bağlıysa köprü çevrimdışı/bağlı davranışını doğrulayın.

## 11. Platforma özel notlar

Temel politika kavramları paylaşılır ancak yerel uygulama ana bilgisayara özeldir:

| macOS | Windows |
| --- | --- |
| Hedefler normalde uygulama paketi tanımlayıcılarına çözümlenir. Cihaz Kontrolü ve geçerli macOS izin durumu geçidi uygulaması. | Hedefler normalde normalleştirilmiş bir yürütülebilir yola veya işlem adına çözümlenir. Windows uygulama katmanı hangi geçerli pencerelerin/işlemlerin yönetilebileceğine karar verir. |

Bu masaüstü referansı, web sitesi engelleme listelerini, yayın seçicileri, YouTube içerik oluşturucu sınıflandırmasını, tarayıcı yönlendirmelerini veya tarayıcı sekmesi işlemlerini kasıtlı olarak açıklamamaktadır. Bunlar Vault eklenti kılavuzuna aittir.
