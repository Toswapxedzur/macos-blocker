# Adamancia Vault Gizlilik Politikası

Son güncelleme: 7 Temmuz 2026

Adamancia Vault bir odaklama ve engelleme uygulamasıdır. Bu politika, macOS uygulamasının sürümünü açıklamaktadır.

## Özet

Adamancia Vault, engelleme kurallarını ve kullanım durumunu varsayılan olarak Mac'inizde yerel tutacak şekilde tasarlanmıştır. Uygulama kişisel verileri satmaz, reklam göstermez ve kişisel verileri veri komisyoncularıyla paylaşmaz.

## Yerel Olarak Depolanan Veriler

Uygulama aşağıdaki yerel verileri Mac'inizde saklayabilir:

- Grupları, programları, zamanlayıcıları, dondurma/erteleme durumunu ve uygulama ayarlarını engelleme.
- Birlikte verilen web arayüzünden yansıtılan yerel web düzenleyici depolama alanı.
- macOS uygulamasını tarayıcı uzantılarına bağladığınızda yerel köprü/bağlantı durumu.
- MacOS engelleme motoru tarafından kullanılan uygulama uygulama ilkesi dosyaları.
- Bir App Store derlemesi veya uzantı derlemesi bir Uygulama Grubu kullandığında Uygulama Grubu kapsayıcı verileri.

Bilinen yerel yollar `RELEASE.md` ve kaldırma komut dosyasında belgelenmiştir.

## Ağ Kullanımı

Uygulama, tarayıcı uzantılarının Mac uygulamasına bağlanabilmesi için web uygulaması köprüsü için bir yerel ağ dinleyicisi açabilir. Uygulama ayrıca, isteğe bağlı hesap veya senkronizasyonla ilgili özellikler gibi paket halindeki bir özelliğin Adamancia hizmetleriyle iletişim kurması gerekiyorsa ağ isteklerinde bulunabilir.

## Analizler ve Reklamlar

MacOS uygulaması üçüncü taraf reklam SDK'larını içermez. Bir özellik açıkça bir çevrimiçi hizmet kullandığını belirtmediği sürece analiz göndermemelidir.

## İsteğe Bağlı Hesaplar ve Senkronizasyon

Bir sürümde hesap veya senkronizasyon özellikleri etkinleştirilirse bu özellikler, söz konusu özelliği sağlamak için gereken hesap kimliği ve senkronizasyon verileri gibi minimum verileri gönderebilir. İndirmeler ve yerel engelleme bir hesap gerektirmemelidir.

## İzinler

Adamancia Vault, kanala ve etkinleştirilmiş özelliklere bağlı olarak macOS'tan Erişilebilirlik, ağ erişimi, oturum açma öğesi kaydı veya Uygulama Grubu erişimi gibi izinler isteyebilir. Bu izinler engelleme, uygulama başlatma, köprüleme ve kalıcılık özelliklerini sağlamak için kullanılır.

## Kaldırma

DMG, `uninstall.command`'yi içerir. Onay ister, çalışıyorsa uygulamadan çıkar, mümkün olduğunda uygulamanın oturum açma öğesinin kaydını siler, `/Applications/AdamanciaVault.app`'yi kaldırır ve isteğe bağlı olarak yalnızca bu uygulama tarafından oluşturulan bilinen dosyaları kaldırır.

## İletişim

Gizlilikle ilgili sorularınız için halka açık GitHub deposunda bir konu açın veya Adamancia Vault web sitesinde yayınlanan iletişim kanalını kullanın.
