# Peta implementasi Mac Vault

Peta ini berasal dari pohon sumber saat ini. Ini adalah bantuan navigasi, bukan klaim bahwa setiap kemampuan browser memiliki padanan aslinya.

| Kekhawatiran | Implementasi macOS saat ini |
| --- | --- |
| Model kelompok dan kebijakan | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, dan `Schedule.swift` |
| Penyunting web | `Sources/MacBlockerWebUI/` dan `WebAssets/` di dalam `WKWebView` |
| Kegigihan editor | `BlockerWebStore.swift` dan jembatan WebView |
| Inventaris aplikasi asli | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` dan `MacAppInventoryJSON.swift` |
| Rencana penegakan | `Sources/MacBlockerCore/EnforcementPlan.swift` dan `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Adaptor kontrol asli | `Sources/MacBlockerMacControl/` dan `Sources/MacBlockerScreenTime/` |
| Aturan adat | `CustomJavaScriptPolicyRuntime.swift` ditambah sumber daya runtime JavaScript |
| Pusat jembatan | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Siklus hidup aplikasi | `BlockerAppDelegate.swift`, `BlockerMainView.swift`, dan `MacBlockerPanelApp.swift` |

## Batas produk

Editor WebView berbagi model pengguna berorientasi grup dengan ekstensi Vault, namun host memutuskan tindakan apa yang dapat dilakukan. Tindakan khusus browser tidak diperlakukan secara diam-diam sebagai penegakan asli. Eksekusi asli bergantung pada izin, target, dan adaptor yang tersedia di Mac.

## Menjaga aset tetap terkini

Manual instruksi bahasa Inggris adalah `WebAssets/manual/en.md`; manual yang diterjemahkan berbagi direktori yang sama dengan kode lokalnya. Katalog terjemahan tetap berada di `WebAssets/translation/`, sedangkan salinan terjemahan dari dokumen yang disimpan lainnya berada di bawah `i18n-docs/<locale>/`.

Saat mengubah string editor, perbarui kunci bahasa Inggrisnya terlebih dahulu, lalu perbarui katalog lokal dan jalankan audit terjemahan bersama.
