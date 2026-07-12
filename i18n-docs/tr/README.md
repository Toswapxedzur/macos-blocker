# Mac Kasası

Mac Vault, Vault ürün ailesinin yerel macOS üyesidir. Swift politika motorunu, WebView düzenleyicisini, yerel uygulama envanterini ve uygulama bağdaştırıcılarını, Özel kural desteğini ve yerel bir web uygulaması köprü merkezini birleştirir.

Mevcut kod gerçeğin kaynağıdır. İngilizce uygulama içi referans şu şekildedir: [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Uygulanan şey

- Seçilen macOS uygulamaları için varsayılan gruplar ve gelişmiş ilke kuralları için Özel gruplar.
- Anında, ödenek ve geri sayım engelleme modları.
- Programlar, dondurma modları, erteleme akışları, içe/dışa aktarma ve kalıcı grup durumu.
- Uygulama envanteri, cihaz kontrolü izin durumu, yerel uygulama bağdaştırıcıları ve değişken durum yüzeyi.
- Günlüğe kaydetme ve sözdizimi kontrolüne sahip kontrollü bir JavaScript politikası çalışma zamanı.
- Açıkça bağlantılı uyumlu gruplar için bir geridöngü WebSocket köprü merkezi.
- Vault ürün ailesiyle aynı çekirdek grup modeline sahip bir WebView düzenleyicisi.

## Geliştirme

Swift paket testlerini çalıştırın:

```bash
swift test
```

Paket, temel politika, zamanlama, özel kural, köprü, içe aktarma ve macOS kontrol testlerini içerir.

## Xcode projesi

İsteğe bağlı Xcode projesi, [XcodeProject/project.yml](XcodeProject/project.yml) dosyasından oluşturulur:

```bash
cd XcodeProject
./generate.sh
```

İmzalama veya dağıtım hedeflerini yapılandırmadan önce [XcodeProject/README.md](XcodeProject/README.md) dosyasını okuyun.

## Dokümantasyon politikası

İngilizce belgeler kanonik olarak kalır. Editör kullanıcı arayüzünde eksiksiz yerel kataloglar bulunur, canlı olarak çevrilmiş kılavuzlar `WebAssets/manual/en.md` yanında bulunur ve bakımı yapılan geri kalan belgelerin çevrilmiş kopyaları `i18n-docs/<locale>/` altında bulunur.

Yasal şartlar ve gizlilik bildirimleri ayrı yasal belgeler olarak kalır; bu README bunların yerini almaz.
