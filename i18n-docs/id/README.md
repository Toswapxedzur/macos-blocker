# Gudang Mac

Mac Vault adalah anggota macOS asli dari rangkaian produk Vault. Ini menggabungkan mesin kebijakan Swift, editor WebView, inventaris aplikasi asli dan adaptor penegakan, dukungan aturan khusus, dan hub jembatan aplikasi web lokal.

Kode saat ini adalah sumber kebenaran. Referensi dalam aplikasi berbahasa Inggris adalah [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Apa yang diterapkan

- Grup default untuk aplikasi macOS yang dipilih dan Grup khusus untuk aturan kebijakan lanjutan.
- Mode pemblokiran segera, tunjangan, dan hitung mundur.
- Jadwal, mode bekukan, aliran tunda, impor/ekspor, dan status grup persisten.
- Inventaris aplikasi, status izin kontrol perangkat, adaptor penegakan asli, dan permukaan status mengambang.
- Runtime kebijakan JavaScript yang terkontrol dengan logging dan pemeriksaan sintaksis.
- Hub jembatan WebSocket loopback untuk grup kompatibel yang tertaut secara eksplisit.
- Editor WebView dengan model grup inti yang sama dengan rangkaian produk Vault.

## Pengembangan

Jalankan tes paket Swift:

```bash
swift test
```

Paket ini mencakup pengujian kebijakan inti, jadwal, aturan khusus, jembatan, impor, dan kontrol macOS.

## Proyek Xcode

Proyek Xcode opsional dihasilkan dari [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Baca [XcodeProject/README.md](XcodeProject/README.md) sebelum mengonfigurasi target penandatanganan atau distribusi.

## Kebijakan dokumentasi

Dokumen berbahasa Inggris tetap kanonik. UI editor memiliki katalog lokal yang lengkap, terjemahan manual langsung di samping `WebAssets/manual/en.md`, dan salinan terjemahan dari sisa dokumen yang dikelola ada di bawah `i18n-docs/<locale>/`.

Persyaratan hukum dan pemberitahuan privasi tetap merupakan dokumen hukum yang terpisah; README ini tidak menggantikannya.
