# Mac Vault uygulama haritası

Bu harita mevcut kaynak ağacından türetilmiştir. Bu bir gezinme yardımcısıdır, her tarayıcı özelliğinin yerel bir eşdeğeri olduğu iddiası değildir.

| endişe | Mevcut macOS uygulaması |
| --- | --- |
| Grup ve politika modeli | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` ve `Schedule.swift` |
| Web editörü | `Sources/MacBlockerWebUI/` ve `WebAssets/`, `WKWebView` |
| Düzenleyici kalıcılığı | `BlockerWebStore.swift` ve WebView köprüsü |
| Yerel uygulama envanteri | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` ve `MacAppInventoryJSON.swift` |
| Uygulama planı | `Sources/MacBlockerCore/EnforcementPlan.swift` ve `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Yerel kontrol adaptörleri | `Sources/MacBlockerMacControl/` ve `Sources/MacBlockerScreenTime/` |
| Özel kurallar | `CustomJavaScriptPolicyRuntime.swift` artı JavaScript çalışma zamanı kaynakları |
| Köprü merkezi | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Uygulama yaşam döngüsü | `BlockerAppDelegate.swift`, `BlockerMainView.swift` ve `MacBlockerPanelApp.swift` |

## Ürün sınırı

WebView düzenleyicisi, Vault uzantısıyla grup odaklı bir kullanıcı modelini paylaşır, ancak bir eylemin ne yapabileceğine ana bilgisayar karar verir. Yalnızca tarayıcıya yönelik eylemler, sessizce yerel yaptırım olarak değerlendirilmez. Yerel yürütme, Mac'te bulunan izne, hedefe ve bağdaştırıcıya bağlıdır.

## Varlıkları güncel tutmak

İngilizce kullanım kılavuzu: `WebAssets/manual/en.md`; çevrilmiş kılavuzlar yerel ayar kodlarıyla aynı dizini paylaşır. Çeviri katalogları `WebAssets/translation/` konumunda kalırken, geri kalan korunan belgelerin çevrilmiş kopyaları `i18n-docs/<locale>/` altında bulunur.

Bir düzenleyici dizesini değiştirirken önce İngilizce anahtarını güncelleyin, ardından yerel ayar kataloglarını güncelleyin ve paylaşılan çeviri denetimini çalıştırın.
