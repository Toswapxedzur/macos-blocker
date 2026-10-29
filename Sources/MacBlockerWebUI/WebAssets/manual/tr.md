# Mac Vault Kullanım Kılavuzu

Mac Vault üç sayfadan oluşur: **Vault** yerel uygulamaları engeller, **İçerik etiketleme** desteklenen tarayıcı içeriğini etiketler, **Etkinlik** kaydedilen kullanımı gösterir. Tarayıcı uzantısı desteklenen içeriği toplar ve tarayıcı engellemesini uygular. Kullandığınız tarayıcıya yükleyip bağlayın.

## Hızlı başlangıç

1. **Vault** içinde bir grubu Engelle ve Apps hedefi ekleyin; + seçicisinden uygulamaları seçin.
2. Engelleme davranışını seçip grubu etkinleştirin.
3. **İçerik etiketleme** içinde grup oluşturun, platformlarını seçin ve açıklamalı etiketler ekleyin.
4. Ayarlar → **Yapay zekâ bağlantıları** içinde ChatGPT subscription, OpenAI API, Gemini API veya Grok API seçin. Hesabı bağlayın ya da anahtarı girip modelleri alın; ardından grupta bağlantı/model seçin. Etiketlemeyi etkinleştirip grubu sürdürün.
5. Bağlı tarayıcıda desteklenen içeriği açın. Etiketlerin engellemeyi yönetmesini istiyorsanız tarayıcı grubu Engelle içinde tag filter ayarlayın.

## Engelleme grupları

**Grubu Engelle** engelleme ilkesi uygular. **İçerik etiketleme** içeriğe etiket verir, tek başına engelleme yapmaz. Grup ekleyip adlandırın, **Uygulandığı yer** altında hedefleri seçin, engellemenin ne zaman uygulanacağını belirleyip zaman çizelgesi veya süre sınırı ayarlayın ve grubu etkinleştirin. Olağan düzenlemeler otomatik kaydedilir. Hata, değişikliğin kabul edilmediğini belirtir; alanı düzeltip yeniden deneyin. Grubu devre dışı bırakmak ayarları tutar ve ilkeyi durdurur; **Grubu sil** siler. Sıralamak için grupları sürükleyin. Aynı hedefe birden fazla grup uygulanabilir; birini snooze etmek diğerinin engelini kaldırmaz. **İhracat** yapılandırmayı kopyalar; **İçe aktarmak** onaydan sonra seçili grubun yapılandırmasını değiştirir.

### Süre sınırı ve zaman çizelgesi

**Block immediately**, etkin grup eşleştiğinde ve zaman çizelgesi etkin olduğunda engeller. **Block when the time allowance is used**, süre hakkı bitene kadar kullanıma izin verir. Hakkı dakika, sıfırlama aralığını saat olarak ayarlayın. Kayan sınır önceki pencerenin kullanımını sayar. Gece yarısı sıfırlaması, kayan sınırda da yerel gece yarısında yeni dönem başlatır. Etkin haftanın günlerini ve isteğe bağlı yerel saat aralıklarını satır başına bir tane seçin; örneğin **09:00-12:00**. Aralık listesi boşsa seçilen günlerin tamamında geçerlidir. Aralık aynı gün içinde başlangıçtan sonra bitmelidir; geceyi aşan çizelgeyi günlere bölün.

### Erteleme

Her grubu Engelle için snooze yapılandırın. **Pause blocking** grup ilkesini belirlenen süre boyunca askıya alır. **Add to the time allowance** süre sınırlı gruba kullanılabilir dakika ekler. Snoozed time olarak yalnızca kullanılan ek süre sayılır. Kullanılmayan ek süre sonraki sıfırlamada biter; kayan sınırda bir pencere sonra veya etkinse gece yarısında daha erken sona erer. **Activation delay**, engelleme sürerken snooze'u geciktirir. **Cooldown**, snooze bittikten sonraki isteğe kadar beklemedir. **Required confirmations** onay adımlarının sayısını belirler. Dondurulmuş grupta snooze yalnızca freeze öncesinde izin verildiyse kullanılabilir.

### Freeze ve PIN

**Freeze** olağan düzenlemeleri engeller. Dondurmayı kaldırmak için beş saniye arayla on onay, yapılandırılmış bekleme ve altı haneli PIN gerekir. **Wait before unfreezing** 0–72 saat kabul eder; 0 bekleme eklemez. Dondurulmuşken bekleme uzatılabilir ve yoksa PIN eklenebilir, fakat çözülene kadar koşullar gevşetilemez. Silme de kalan bekleme ve PIN koşullarına tabidir.

### Bağlı gruplar

Diğer Vault programlarında açıkça seçilen grupları bağlamak için **Bağla** kullanın. Adı, desteklenen ilke ayarlarını, hedefleri, kullanımı ve freeze koşullarını paylaşırlar. Her program yalnızca desteklediği hedef türlerini düzenler ve uygular; diğer hedefler bağlı programlarda kullanılabilir. **Bağlantıyı kaldır** bağlantıyı keser, grupları ve ayarlarını tutar. Bir üye çevrimdışıysa Mac Vault ve bağlı tarayıcıyı açıp yeniden bağlanın. Yerel kayıtlı ilke çevrimdışıyken uygulanmayı sürdürebilir.

## Yardım

Açıklama için alanın yanındaki küçük **i** simgesine tıklayın; kapatmak için dışarı tıklayın veya Escape'e basın. Listeler kaydırılabilir kutulardadır; arama girdileri silmeden görünür listeyi filtreler. Özel kuralların [Code manual](../code-manual/tr.md) belgesi düzenleyiciyi, etkinleştirmeyi, günlükleri, dosya erişimini ve API'yi açıklar.

## Yerel uygulamalar

Apps hedefinin + seçicisinden yüklü veya çalışmakta olan uygulamaları seçin. Başka klasörden uygulama başlattıktan sonra listeyi yenilemek için seçiciyi yeniden açın. **Burada listelenenler dışındaki tüm uygulamaları engelle** listeyi izin listesine dönüştürür. Mac Vault sıradan Apple uygulamalarını ve tüm tarayıcıları engelleyebilir; Mac Vault'un kendisi ve aynı bundle identifier'ı paylaşan uygulamalar korunur. Engellenen uygulamadan çıkması istenir; **Yasaklanan uygulamanın kapatılmasını şu aralıkla yeniden iste (dakika)** yeniden isteme aralığını ayarlar. Site yönlendirmeleri, sayfa duraklatmaları ve feed gizleme tarayıcı uzantısınca uygulanır; yerel uygulama eylemi değildir.

## İçerik etiketleme

Her İçerik etiketleme, atanan platformların içeriğini kendi tag tree ve model ayarlarıyla etiketler. Her platform tek gruba aittir; oluştururken seçin, sonra değiştirilemez. Engelleme gruplarının çizelge ve filtreleri etiketlemeyi denetlemez. Ayarlar'te etiketlemeyi açın; her grupta **Etiketlemeyi duraklat / Etiketlemeyi sürdür** ayrı çalışır. **Etkinlik → Kayıt** içinde platform feed kaydını kapatmak onun etiketlemesini de durdurur.

### Etiketler ve model ayarları

Etiket oluşturun, anlamını açıklayın ve tree içinde üst etiketini ayarlayın veya kaldırın. Sürüklemek dalı taşır. Açık açıklamalar benzer etiketleri ayırmaya yardım eder. Grup ayarları bağımsızdır. **En düşük etiket güveni** her tahmin edilen etiket için gereken kanıt derecesini 1–5 belirler; yeni gruplar 4 (güçlü destek) ile başlar. Hedef etiket sayısı yoktur; öğe etiketsiz kalabilir. **Etiketleme talimatları** grup tercihlerini tutar. Olağan düzenlemeler otomatik kaydolur; her grup açıkça seçilmiş bağlantı, model ve reasoning effort kullanır.

### AI bağlantıları

Ayarlar'te ChatGPT subscription, OpenAI API, Gemini API ve Grok API vardır. Abonelik Vault'un kendi oturum açmasını ve uygun planı kullanır. API anahtarları seçilen sağlayıcının ücretlendirme ve kullanım sınırlarına tabidir. Sağlayıcıyı seçip anahtarı ortak açılır listenin altına girin; anahtar düzenlemeleri otomatik kaydolur, alanı temizlemek anahtarı siler. **Model listesini getir** modelleri getirir; İçerik etiketleme veya custom-rule grubunda modeli ayrıca seçin.

**Akıl yürütme düzeyi** modelin ne kadar düşüneceğini belirler: destekleniyorsa Model default, Low, Medium veya High. Yeni seçimler Medium ile başlar; eskiler kayıtlı kalır. Yüksek düzey süreyi ve token kullanımını artırabilir. Etiketleme için web search daima açıktır; ne zaman kullanılacağına model karar verir. Arama ve yapılandırılmış etiketlemeyi destekleyen model seçin. Başarısız/erişilemeyen istekler geçerli önbellek sonuçlarını korur; **Bulut sınıflandırmasını yeniden dene** seçilene kadar yeni öğeler çözümsüz kalır. Vault sağlayıcıyı otomatik değiştirmez; her bağlantının retry aralığı ve deneme sınırı ayrıdır. Tarayıcı uzantısında **+ tag** ile arayıp etiket ekleyin; kaldırma kontrolüyle ya da etiketi seçip Delete'e bir kez basarak silin. **Etiketsiz** etiketleme bitti ama etiket yok demektir; **Etiketleniyor** sonuç bekleniyor demektir. Düzeltmeniz o öğede geçerlidir.

## Etkinlik

Etkinlik etkin uygulama kullanımını, web sitesi ziyaretlerini ve desteklenen **Görüntülenen içerik** içeriğini yerel olarak kaydeder. Grafikler kaydedilen veriyi yansıtır; boş alan Mac'in boşta olduğunu kanıtlamaz. Tarih aralığı seçin. **Zaman çizelgesi** günün saatine göre kullanım gösterir, **Toplamlar** süreleri toplar, **Zaman aralığı** her aralığın kullanımını dikey bloklarda birleştirir. **Renkler** tıklanabilir bir lejanttır; kaynağı seçerek grafikleri ona odaklayın. Bir gün seçip o günden sonraki kullanımı görün.

### Etkinlik grupları

Seçilen uygulama ve siteleri Usage içinde birlikte göstermek için grup oluşturun. **Merge**, Etkinlik boyunca üyeler için tek ad ve renk kullanır. Etkinlik group kayıtlı kullanımı düzenler; blocking ve İçerik etiketleme gruplarından ayrıdır. Düzenleyiciyi açıkça **Save** ile kaydedin.

### Kayıt ve saklama

**Kayıt** içinde kategori veya tekil kaynak kaydını açıp kapatın. **Sakla** geçmişin ne kadar saklanacağını belirler; **Sonsuza dek** otomatik sona erme olmadan tutar. Tekil seçimler üst ayarı izleyebilir. Kaydı kapatmak yeni kayıtları durdurur; geçmişi silmek kayıtlı girdileri kaldırır. Platform feed'leri desteklenen sayfalarda gösterilen içeriği, açılmış olsun ya da olmasın toplar. **Etiketleme destekleniyor** feed, kayıt açıkken İçerik etiketleme'e içerik sağlayabilir. Saklama süresi uygulama ve site kullanımından ayrıdır. Tagging grubunu duraklatmak kaydı kendiliğinden kapatmaz.

## Ayarlar

Ayarlar'te arayüz dilini seçin. Alan açıklamaları seçilen dildeki Info düğmelerindedir.

## Kaydetme ve sorun giderme

Olağan Vault ve İçerik etiketleme düzenlemeleri otomatik kaydolur; Etkinlik group düzenleyicisi **Save** gerektirir. Ekleme, silme, bağlantı testleri ve model listesi getirme açık işlemlerdir. Etiketler yoksa tarayıcı bağlantısını, genel tagging anahtarını, grup duraklatmasını, platform kaydını, seçilen bağlantı/modeli ve kimlik bilgilerini kontrol edin. AI istekleri başarısızsa sağlayıcı sınırlarını ve grup Log'unu da inceleyin. Bağlı grup düzenlenemiyorsa programlarını yeniden bağlayın veya belirtildiği gibi freeze'i kaldırın.
