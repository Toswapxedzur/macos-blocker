# Mac Vault Xcode projesi

`project.yml`, paylaşılan Swift paketini kullanan macOS ve iOS hedeflerine yönelik yerleşik XcodeGen spesifikasyonudur.

## Projeyi oluştur

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

`project.yml`'yi, hedefleri, yetkileri veya kaynak üyeliğini değiştirdikten sonra yeniden oluşturun. Oluşturulan proje dosyalarını standart konfigürasyon olarak kullanmayın.

## Mevcut hedef aileler

- `AdamanciaVaultMac`, `MacBlockerAppFeature` tarafından desteklenen macOS uygulama hedefidir.
- `macosBlocker` iOS uygulamasının hedefidir.
- iOS projesi Cihaz Etkinliği, Kalkan Yapılandırması ve Kalkan Eylemi uzantılarını içerir.

Geçerli tanımlayıcılar, dağıtım hedefleri, sürüm alanları ve yetenekler `project.yml` ve başvurulan yetkilendirme dosyalarında tanımlanmıştır. Dağıtımdan önce bunları imzalama ortamında inceleyin.

## İmzalama ve yetenekler

Dağıtım hesabına ait bir ekip ve paket tanımlayıcıları kullanın. Oluşturmakta olduğunuz hedefin gerektirdiği yetenekleri doğrulayın. Bu depoya asla imzalama sırları, ön hazırlık profilleri veya hesap kimlik bilgileri eklemeyin.

## Önce test edin

Arşiv oluşturmadan önce paylaşılan paket testlerini çalıştırın:

```bash
cd ..
swift test
```
