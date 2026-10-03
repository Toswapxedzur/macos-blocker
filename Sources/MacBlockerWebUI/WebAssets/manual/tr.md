# Mac Vault kullanıcı kılavuzu

Mac Vault üç sayfaya sahiptir: **Vault** native uygulamaları engeller, **Classifier** desteklenen tarayıcı içeriğini etiketler, **Activity** kaydedilen kullanımı gösterir. Tarayıcı uzantısı desteklenen içeriği toplar ve tarayıcı engellemesini uygular. Kullandığınız tarayıcıya kurup bağlayın.

## Hızlı başlangıç

1. **Vault** içinde bir engelleme grubu ve Apps hedefi ekleyin; ardından + seçicisiyle uygulamaları seçin.
2. Grubun engelleme davranışını seçip etkinleştirin.
3. **Classifier** içinde grup oluşturun, platformları seçin ve açıklamalarıyla etiket ekleyin.
4. Yerel model katmanı seçin, gerekiyorsa indirin. Classifier ayarlarında etiketlemeyi etkinleştirin ve grubu sürdürün.
5. Bağlı tarayıcıda desteklenen içeriği açın. Etiketlerin engellemeyi denetlemesini istiyorsanız tarayıcı engelleme grubunda etiket filtresi yapılandırın.

## Engelleme grupları

**Engelleme grubu** bir engelleme ilkesi uygular. **Classifier grubu** içeriğe etiket atar; tek başına hiçbir şeyi engellemez.

1. Bir engelleme grubu ekleyip ad verin.
2. **Uygulandığı yerler** altında hedefleri seçin.
3. Engellemenin ne zaman uygulanacağını seçin, ardından gerekirse zamanlama veya izin verilen süre belirleyin.
4. Grubu etkinleştirin. Hedefleri grubun ilkesini paylaşır.

Rutin düzenlemeler otomatik kaydedilir. Hata, düzenlemenin kabul edilmediği anlamına gelir; alanı düzeltip yeniden deneyin. Yapılandırmasını koruyarak ilkesini durdurmak için grubu devre dışı bırakın. **Grubu sil** grubu kaldırır. Grupları yeniden sıralamak için sürükleyin. Bir hedefe birden fazla grup uygulanabilir; birini ertelemek diğer grubun engelini kaldırmaz.

**Dışa aktar** grup yapılandırmasını kopyalar. **İçe aktar** onaydan sonra seçilen grubun yapılandırmasını değiştirir.

### İzin verilen süre ve zamanlama

**Hemen engelle**, etkin grup eşleştiğinde ve zamanlaması etkin olduğunda uygulanır. **İzin verilen süre dolduğunda engelle**, süre bitene kadar eşleşen kullanıma izin verir.

İzin verilen süreyi dakika, sıfırlama aralığını saat olarak belirleyin. Kayan sınır, önceki zaman aralığındaki kullanımı sayar. Gece yarısı sıfırlama, kayan sınır için de yerel gece yarısında yeni dönem başlatır.

Etkin hafta günlerini ve isteğe bağlı yerel saat aralıklarını satır başına bir tane olacak şekilde seçin; örneğin **09:00-12:00**. Aralık listesi boşsa seçilen gün boyunca uygulanır. Aralık aynı gün içinde başladığından daha geç bitmelidir; geceyi aşan zamanlamayı ayrı günlere bölün.

### Erteleme

Ertelemeyi her engelleme grubunda yapılandırın. **Engellemeyi duraklat**, grubun ilkesini belirlenen duraklama süresince askıya alır. **İzin verilen süreye ekle**, süre sınırlı gruba kullanılabilir dakika ekler. Ertelenmiş süre olarak yalnızca tüketilen ek süre sayılır. Kullanılmayan ek süre bir sonraki sıfırlamada sona erer; kayan sınırda bir aralık sonra, ayar açıksa daha önce gece yarısında biter.

**Etkinleştirme gecikmesi**, engelleme sürerken ertelemeyi geciktirir. **Bekleme süresi**, erteleme bittikten sonraki yeni isteğe kadar beklenecek süredir. **Gerekli onay sayısı**, onay adımlarını belirler. Erteleme, dondurulmuş grupta yalnızca dondurmadan önce izin verilmişse kullanılabilir.

### Dondurma ve PIN

**Dondur**, rutin düzenlemeleri engeller. Dondurmayı kaldırmak için beş saniye arayla on onay, ayarlanmış bekleme süresi ve altı haneli PIN gerekir. **Dondurmayı kaldırmadan önce bekle** 0–72 saat kabul eder; 0 ek bekleme koymaz.

Grup donmuşken bekleme uzatılabilir ve yoksa PIN eklenebilir. Grup çözülene kadar bu koşullar gevşetilemez. Silme işlemi de kalan bekleme süresine ve PIN'e tabidir.

### Bağlı gruplar

Diğer Vault programlarında açıkça seçilen grupları bağlamak için **Bağla** seçeneğini kullanın. Bağlı gruplar adlarını, desteklenen ilke ayarlarını, hedefleri, kullanımı ve dondurma koşullarını paylaşır. Her program desteklediği hedef türlerini düzenler ve uygular; diğer hedef kayıtları bağlı programlar için kullanılabilir kalır. Bağlantıyı kaldırmak grupları ve ayarlarını korur.

Bağlı bir üye çevrimdışıysa düzenleme kullanılamayabilir. Yeniden bağlanmak için Mac Vault ve bağlı tarayıcıyı açın. Yerel olarak kaydedilen ilke, üye çevrimdışıyken uygulanmaya devam edebilir.

## Yardım alma

Açıklamasını görmek için alanın yanındaki küçük **i** simgesine tıklayın. Kapatmak için dışına tıklayın veya Escape tuşuna basın. Listeler kaydırılabilir kutulardadır; daha fazla öğe için kutuyu kaydırın. Arama öğeleri silmeden görünür listeyi filtreler.

Özel kuralların ayrı bir [Kod kılavuzu](../code-manual/tr.md) vardır. Düzenleyiciyi, etkinleştirmeyi, günlükleri, dosya erişimini ve desteklenen API'yi açıklar.

## Native uygulamalar

Yüklü uygulamaları seçmek için bir Apps hedefinin + seçicisini kullanın. **Bunlar dışındaki tüm uygulamaları engelle** listeyi izin listesine dönüştürür. Sistem uygulamaları, tarayıcılar ve Vault'un kendisi native uygulama engellemesine dâhil değildir.

Engellenen bir uygulamadan çıkması istenir. **Engellenen uygulamadan her (dakikada) yeniden çıkmasını iste** tekrar denemeleri denetler. Web sitesi yönlendirmeleri, sayfa duraklatmaları ve akış gizleme tarayıcı uzantısı tarafından uygulanır; native uygulama işlemlerine dönüşmez.

## Classifier

Classifier grubu, kendine ait etiket ağacı ve model ayarlarıyla atanan platformlardaki içeriği etiketler. Her platform bir gruba aittir. Grubu oluştururken platformları seçin; sonradan değiştirilemez. Engelleme gruplarının zamanlamaları ve filtreleri etiketlemeyi denetlemez.

Classifier ayarlarında etiketlemeyi etkinleştirin. Her grubun **Etiketlemeyi duraklat / Etiketlemeyi sürdür** seçeneklerini ayrı ayrı kullanın. **Activity → Kayıt** bölümünde platform akışının kaydını kapatmak da o akışın etiketlemesini durdurur.

### Etiketler ve model ayarları

Etiketler oluşturun, anlamlarını açıklayın ve etiket ağacında üst etiketlerini ayarlayın veya kaldırın. Dalını taşımak için etiketi sürükleyin. Açık açıklamalar modelin benzer etiketleri ayırt etmesine yardım eder. Her grubun ayarları bağımsızdır.

- **Hız ↔ Kalite** yerel model katmanını seçer. Büyük modeller daha çok bellek kullanır; hız ve sonuçlar Mac ile iş yüküne bağlıdır. İndirmeler gruplar arasında paylaşılır.
- **Katı ↔ Geniş** güven gereksinimlerini ve varsayılan etiket sayılarını belirler.
- Daha Fazla içindeki **En az etiket / En çok etiket** bu varsayılan sayıları değiştirir. Katı ↔ Geniş ek etiketler için güven düzeyini denetlemeyi sürdürür. Varsayılanı kullanmak için alanı boş bırakın.
- **Etiketleme yönergeleri** bu gruba isteğe bağlı talimat ekler.

Classifier'daki rutin düzenlemeler otomatik kaydedilir. İçeriği etiketlemeden önce seçilen katman indirilmelidir. Aynı katmanı kullanan gruplar yüklü modeli paylaşır; aynı anda en fazla iki katman yüklü kalır.

Bir içerik öğesinin etiketlerini tarayıcı uzantısında düzeltin. **+ tag** düğmesine tıklayın, Classifier'ın mevcut etiketlerini arayın ve eklemek için birini seçin. Etiketi kaldırma kontrolünü kullanın ya da etiketi seçip silmek için Delete tuşuna bir kez basın. **Etiketsiz**, etiketleme tamamlanmış ve etiket bulunmamış demektir; **Etiketleniyor**, sonucun beklemede olduğunu belirtir. Düzeltmeler gelecekteki etiketlemeyi iyileştirir.

## Knowledge ve web araştırması

Knowledge, yerel etiketleme modeli için bu Mac üzerinde kısa açıklamalar saklar. **İçerik kaynakları** içerik üreticilerini, hesapları, kanalları ve toplulukları kapsar. Kaynak açıklamaları içerikleriyle birlikte kullanılır. **Bilinen terimler**, terim başlıkta geçtiğinde uygulanır.

Açıklamasıyla bir kaynak veya terim ekleyin ya da etkinleştirildiğinde araştırma isteği için açıklamayı boş bırakın. İçerik üreticisi önerileri Classifier'ın topladığı bir kaynağı bulmaya yardımcı olur. Altı veya daha fazla öğeli listelerin hemen üstünde arama bulunur: Terms ve her platformun Content sources listeleri ad, tanımlayıcı veya açıklama için ayrı aramalara sahiptir. Açıklama düzenlemek gelecekteki etiketlemeyi etkiler; kaynak bilgisini silmek araştırmanın daha sonra yeniden oluşturmasını engellemez.

### Araştırma sağlayıcısını yapılandırma

1. **Classifier ayarları → API keys & providers** bölümünü açın.
2. Sağlayıcı türünü seçin ve **Sağlayıcı ekle** seçeneğine basın. Bu bir yapılandırma oluşturur; API key vermez.
3. Sağlayıcıdan kimlik bilgilerini alın ve girin. Uyumlu bir özel endpoint için endpoint ve protocol alanlarını da yapılandırın.
4. **Web araştırması** bölümünde yerleşik web search özelliği olan bir sağlayıcı seçin. Model listesini alıp araştırma modelini seçin. Listeyi daraltmak için model seçicinin aramasını kullanın; listeyi yeniden almak için yenileyin.
5. Onay açıklamasını okuyup onayı etkinleştirin. Her grupta **Açık**, **Kapalı** veya **Classifier ayarlarını izle** seçin.

**Web araştırmasını ayarla…** yapılandırma eksik olduğunda ayarlara götürür. Grup araştırma onayını atlayamaz. **Bağlantıyı test et**, test isteğinin başarılı olduğunu doğrular; tüm modellerin araştırmayı desteklediğini doğrulamaz. Sağlayıcının test modeli, seçilen araştırma modelinden ayrıdır.

Keys, system Keychain'de değil, bu Mac üzerindeki uygulamanın support klasöründe saklanır. Yapılandırılan sağlayıcıya gönderilen istekleri doğrular; Vault bunları kendi sunucusuna yüklemez. Araştırma, temizlenmiş herkese açık konuları seçilen sağlayıcıya gönderir; özel içerik gövdelerini veya özetlerini göndermez. Gönderilen tam fields listesi için onay açıklamasını okuyun. Sağlayıcı kullanımı, araştırmanın yanında bağlantı testleri ve model listesi isteklerini de içerir.

Araştırma durumu kuyruktaki istekleri, yeniden deneme bekleme sürelerini, hataları ve günlük token kullanımını gösterir. **Başarısız konuları şimdi yeniden dene**, uygun hataları yeniden dener; günlük sınırı veya onayı atlamaz.

## Activity

Activity etkin uygulama kullanımını, web sitesi ziyaretlerini ve desteklenen **Görüntülenen içerikleri** yerel olarak kaydeder. Grafikleri kaydedilen verileri yansıtır; boş bir alan Mac'ın boşta olduğunu kanıtlamaz.

Tarih aralığı seçin. **Zaman çizelgesi** kullanımı gün içindeki saatinde gösterir; **Toplamlar** süreyi toplar. **Zaman aralığı** her aralıktaki kullanımı dikey bloklarda birleştirir. **Renkler** tıklanabilir bir açıklamadır: grafikleri bir kaynağa odaklamak için onu seçin. O günden itibaren kullanımı görmek için bir gün seçin.

### Activity grupları

Seçilen uygulamaları ve web sitelerini Usage içinde birlikte göstermek için grup oluşturun. **Birleştir**, tüm Activity'de üyeler için tek ad ve renk kullanır. Activity grubu kaydedilen kullanımı düzenler; engelleme veya Classifier grubundan ayrıdır. Activity grubu düzenleyicisini **Kaydet** düğmesiyle açıkça kaydedin.

### Kayıt ve saklama

**Kayıt** bölümünde her kategori veya kaynak için kaydı açıp kapatın. **Sakla**, geçmişin ne kadar tutulacağını belirler; **Sonsuza dek** otomatik süre sonu olmadan saklar. Tek tek seçimler daha genel ayarı izleyebilir. Kaydı kapatmak yeni kaydı durdurur; geçmişi silmek kaydedilmiş öğeleri kaldırır.

Platform akışları, açık olup olmadıklarına bakmadan desteklenen platform sayfalarında gösterilen içeriği toplar. **Etiketleme destekleniyor** yazan akış, kayıt açıkken Classifier'a içerik sağlayabilir. Akış saklaması, toplanan içeriği uygulama ve web sitesi kullanımından ayrı denetler. Duraklatılmış Classifier grubu kaydı kendiliğinden kapatmaz.

## Ayarlar

Settings bölümünden arayüz dilini seçin. Alan açıklamaları, seçilen arayüz dilindeki küçük Info düğmelerinden edinilebilir.

## Kaydetme ve sorun giderme

Vault ve Classifier rutin düzenlemeleri otomatik kaydedilir. Activity grubu düzenleme **Kaydet** gerektirir. Ekleme, silme, model indirme, bağlantı testi ve model listesi alma açıkça başlatılan işlemlerdir.

Etiketler eksikse tarayıcı bağlantısını, genel etiketleme düğmesini, grup duraklatma durumunu, platform kaydını ve model indirmesini denetleyin. Araştırma çalışmıyorsa onayı, grup seçimini, sağlayıcı kimlik bilgilerini, araştırma modelini ve araştırma durumunu kontrol edin. Bağlı bir grup düzenlenemiyorsa programları yeniden bağlayın veya belirtildiği gibi dondurmayı kaldırın.
