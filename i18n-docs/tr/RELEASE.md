# Mac Vault sürüm kılavuzu

Bu kılavuz, teslim edilen derleme komut dosyalarını takip eder. Kasıtlı olarak hiçbir kişisel imza kimliği, noter tasdik profili, şifre veya hesap verisi içermez.

## Yayınlanmadan önce

1. Depo kökünden `swift test` komutunu çalıştırın.
2. Kontrollü proje/yapı yapılandırmasında yayın sürümünü ve yapı numarasını ayarlayın.
3. İngilizce kılavuzu, yerelleştirilmiş kılavuzları ve editör çeviri denetimini inceleyin.
4. Bir yapıyı yayınlamadan önce yayın dalını, etiketi ve kilometre taşı politikasını doğrulayın.

## Web sitesi DMG hattı

Komut dosyaları `scripts/release/`'de yayınlanmaktadır. Varsayılanları, `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` ve `BUILD_NUMBER` dahil olmak üzere ortam değişkenleri ile geçersiz kılınabilir.

İşlem hattının tamamını yalnızca yapılandırılmış bir imzalama makinesinde çalıştırın:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

İşlem hattı mevcut derleme, imzalama, DMG, noter onayı ve doğrulama komut dosyalarını oluşturur. Doğrulama adımı başarılı olana kadar çıktısını sürüm adayı olarak değerlendirin.

## Xcode dağıtım hedefleri

`XcodeProject/project.yml` adresinden Xcode projesini oluşturun, onaylanan ortamda uygun imzalama ekibini ve yeteneklerini yapılandırın, ardından ilgili hedefi arşivleyin. Oluşturulan kimlik bilgilerini, ön hazırlık dosyalarını veya noter tasdik profillerini taahhüt etmeyin.

## Yayınlandıktan sonra

1. Sürüm yönetimi politikasına göre değişmez sürüm etiketini ve kalıcı sürüm dalını oluşturun.
2. Sürüm yapısını ve sağlama toplamını yayınlayın.
3. Genel yayın kaydını yalnızca yapı URL'si nihai hale geldikten sonra güncelleyin.
4. İncelenmiş yerelleştirilmiş bir sürüm notu sağlanmadığı sürece sürüm notlarını İngilizce olarak saklayın.
